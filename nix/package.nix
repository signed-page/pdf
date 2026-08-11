{
  pkgs,
  craneLib,
  lib,
}:
rec {
  # Filter source to include workspace crates
  src = lib.cleanSourceWith {
    src = craneLib.path ../.;
    filter =
      path: type:
      # Keep all Rust source, Cargo files, and the crates directory
      (lib.hasSuffix "\.rs" path)
      || (lib.hasSuffix "Cargo.toml" path)
      || (lib.hasSuffix "Cargo.lock" path)
      || (lib.hasInfix "/crates/" path)
      || (craneLib.filterCargoSources path type);
  };

  # Read version from Cargo.toml
  cargoToml = builtins.fromTOML (builtins.readFile ../Cargo.toml);
  version = cargoToml.workspace.package.version;

  commonArgs = {
    inherit src;
    strictDeps = true;

    # Explicitly set for workspace builds
    pname = "pdf-sign";
    inherit version;

    nativeBuildInputs = with pkgs; [
      pkg-config
      capnproto
    ];
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  pdfSign = craneLib.buildPackage (
    commonArgs
    // {
      inherit cargoArtifacts;

      # Build only the CLI binary from the workspace
      cargoExtraArgs = "--bin pdf-sign";

      meta = with lib; {
        description = "Lightweight PDF signing tool with OpenPGP (GPG) and Sigstore (keyless OIDC) backends";
        homepage = "https://github.com/signed-page/pdf";
        license = licenses.gpl3Only;
        mainProgram = "pdf-sign";
        platforms = platforms.unix;
      };

      passthru.image = image;
    }
  );

  image = pkgs.dockerTools.streamLayeredImage {
    name = "ghcr.io/signed-page/pdf";

    contents = [
      pdfSign
      pkgs.dockerTools.caCertificates
      pkgs.dockerTools.fakeNss
      pkgs.iana-etc
      pkgs.gnupg
    ];

    fakeRootCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
    '';

    config = {
      Entrypoint = [ "${lib.getExe pdfSign}" ];
      WorkingDir = "/data";
      Env = [
        "GNUPGHOME=/gnupg"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      ];
      Volumes = {
        "/gnupg" = { };
        "/data" = { };
      };
      ExposedPorts = {
        "8080/tcp" = { };
      };
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/signed-page/pdf";
        "org.opencontainers.image.description" =
          "Lightweight PDF signing with OpenPGP (GPG) and Sigstore (keyless OIDC)";
        "org.opencontainers.image.licenses" = "GPL-3.0-only";
      };
    };
  };

  homebrew = import ./homebrew.nix {
    inherit pkgs lib;
  };

  homebrewSourceTree = craneLib.path ../.;

  homebrewCargoVendorDir = craneLib.vendorCargoDeps {
    src = homebrewSourceTree;
  };

  homebrewSource = homebrew.mkSourceBundle {
    src = homebrewSourceTree;
    cargoVendorDir = homebrewCargoVendorDir;
    inherit version;
  };

  homebrewPlatform =
    ({
      "aarch64-darwin" = {
        bottleTag = "arm64_sonoma";
        ociPlatform = {
          architecture = "arm64";
          os = "darwin";
          "os.version" = "macOS 14";
        };
      };
      "aarch64-linux" = {
        bottleTag = "arm64_linux";
        ociPlatform = {
          architecture = "arm64";
          os = "linux";
        };
      };
      "x86_64-linux" = {
        bottleTag = "x86_64_linux";
        ociPlatform = {
          architecture = "amd64";
          os = "linux";
        };
      };
    }).${pkgs.stdenv.hostPlatform.system} or null;

  muslTarget =
    if pkgs.stdenv.isLinux then
      if pkgs.stdenv.hostPlatform.isAarch64 then
        "aarch64-unknown-linux-musl"
      else if pkgs.stdenv.hostPlatform.isx86_64 then
        "x86_64-unknown-linux-musl"
      else
        throw "Homebrew Linux bottles support only aarch64 and x86_64"
    else
      null;

  muslCraneLib =
    if muslTarget == null then
      null
    else
      craneLib.overrideToolchain (
        rustPkgs:
        rustPkgs.rust-bin.stable.latest.default.override {
          targets = [ muslTarget ];
        }
      );

  muslCC = if muslTarget == null then null else lib.getExe pkgs.pkgsStatic.stdenv.cc;

  muslTargetEnv =
    if muslTarget == null then
      null
    else
      lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] muslTarget);

  muslCcEnv =
    if muslTarget == null then null else "CC_${builtins.replaceStrings [ "-" ] [ "_" ] muslTarget}";

  muslCommonArgs =
    if muslTarget == null then
      null
    else
      commonArgs
      // {
        pname = "pdf-sign-homebrew";
        CARGO_BUILD_TARGET = muslTarget;
        CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
        "${muslCcEnv}" = muslCC;
        "CARGO_TARGET_${muslTargetEnv}_LINKER" = muslCC;
        nativeBuildInputs = commonArgs.nativeBuildInputs ++ [
          pkgs.binutils
          pkgs.file
          pkgs.gnugrep
        ];
      };

  muslCargoArtifacts = if muslTarget == null then null else muslCraneLib.buildDepsOnly muslCommonArgs;

  portableLinux =
    if muslTarget == null then
      null
    else
      muslCraneLib.buildPackage (
        muslCommonArgs
        // {
          cargoArtifacts = muslCargoArtifacts;
          cargoExtraArgs = "--bin pdf-sign";
          doCheck = false;
          dontPatchELF = true;

          postFixup = ''
            binary="$out/bin/pdf-sign"
            test -x "$binary"

            case "${muslTarget}" in
              aarch64-unknown-linux-musl)
                architecture='ARM aarch64'
                ;;
              x86_64-unknown-linux-musl)
                architecture='x86-64'
                ;;
              *)
                echo "unsupported musl target ${muslTarget}" >&2
                exit 1
                ;;
            esac

            if ! ${pkgs.file}/bin/file "$binary" | grep -q "$architecture"; then
              echo "Homebrew binary has the wrong ELF architecture" >&2
              exit 1
            fi
            if ${pkgs.binutils}/bin/readelf -l "$binary" | grep -q 'Requesting program interpreter'; then
              echo "Homebrew musl binary has a dynamic interpreter" >&2
              exit 1
            fi
            if ${pkgs.binutils}/bin/readelf -d "$binary" 2>/dev/null \
              | grep -E -q '(NEEDED|RPATH|RUNPATH)'; then
              echo "Homebrew musl binary has dynamic dependencies or search paths" >&2
              exit 1
            fi
            if grep -R -a -q '/nix/store' "$out"; then
              echo "Homebrew musl output contains a Nix store reference" >&2
              exit 1
            fi
          '';
        }
      );

  portableDarwin =
    if !(pkgs.stdenv.isDarwin && pkgs.stdenv.hostPlatform.isAarch64) then
      null
    else
      pkgs.runCommand "pdf-sign-homebrew-darwin-${version}"
        {
          nativeBuildInputs = [
            pkgs.coreutils
            pkgs.darwin.cctools
            pkgs.darwin.sigtool
            pkgs.findutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
          ];
        }
        ''
          set -euo pipefail
          export LC_ALL=C

          otool=${pkgs.darwin.cctools}/bin/otool
          install_name_tool=${pkgs.darwin.cctools}/bin/install_name_tool
          codesign=${lib.getExe' pkgs.darwin.sigtool "codesign"}
          source_executable="${pdfSign}/bin/pdf-sign"
          source_executable_dir=$(dirname "$source_executable")
          executable="$out/bin/pdf-sign"
          queue="$TMPDIR/dylib-queue"
          processed="$TMPDIR/dylib-processed"
          origins="$TMPDIR/dylib-origins"

          mkdir -p "$out/bin" "$out/lib"
          cp "$source_executable" "$executable"
          chmod u+w,ugo+rx "$executable"
          printf '%s\n' "$executable" > "$queue"
          : > "$processed"
          : > "$origins"
          printf '%s\t%s\n' "$executable" "$source_executable" >> "$origins"

          expand_path() {
            value="$1"
            owner="$2"
            case "$value" in
              @loader_path)
                dirname "$owner"
                ;;
              @loader_path/*)
                printf '%s/%s\n' "$(dirname "$owner")" "''${value#@loader_path/}"
                ;;
              @executable_path)
                printf '%s\n' "$source_executable_dir"
                ;;
              @executable_path/*)
                printf '%s/%s\n' "$source_executable_dir" "''${value#@executable_path/}"
                ;;
              /*)
                printf '%s\n' "$value"
                ;;
              *)
                return 1
                ;;
            esac
          }

          resolve_dependency() {
            dependency="$1"
            owner="$2"
            source_owner="$3"
            case "$dependency" in
              @rpath/*)
                suffix="''${dependency#@rpath/}"
                while IFS= read -r search_path; do
                  if expanded=$(expand_path "$search_path" "$source_owner"); then
                    candidate="$expanded/$suffix"
                    if test -e "$candidate"; then
                      realpath "$candidate"
                      return
                    fi
                  fi
                done < <(
                  "$otool" -l "$owner" | awk '
                    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
                    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
                  '
                )
                ;;
              *)
                if expanded=$(expand_path "$dependency" "$source_owner") && test -e "$expanded"; then
                  realpath "$expanded"
                  return
                fi
                ;;
            esac
            echo "cannot resolve non-system dependency $dependency from $owner" >&2
            return 1
          }

          while IFS= read -r binary; do
            if grep -F -x -q "$binary" "$processed"; then
              continue
            fi
            printf '%s\n' "$binary" >> "$processed"
            source_owner=$(
              awk -F '\t' -v destination="$binary" \
                '$1 == destination { print $2; exit }' "$origins"
            )
            if test -z "$source_owner"; then
              echo "missing source path for copied Mach-O $binary" >&2
              exit 1
            fi

            while IFS= read -r dependency; do
              test -n "$dependency" || continue
              case "$dependency" in
                /usr/lib/*|/System/Library/Frameworks/*)
                  continue
                  ;;
              esac

              resolved=$(resolve_dependency "$dependency" "$binary" "$source_owner")
              case "$resolved" in
                /usr/lib/*|/System/Library/Frameworks/*)
                  "$install_name_tool" -change "$dependency" "$resolved" "$binary"
                  continue
                  ;;
              esac

              if test "$(basename "$resolved")" = "libiconv.2.dylib"; then
                "$install_name_tool" -change "$dependency" "/usr/lib/libiconv.2.dylib" "$binary"
                continue
              fi

              basename=$(basename "$resolved")
              destination="$out/lib/$basename"
              recorded=$(
                awk -F '\t' -v destination="$destination" \
                  '$1 == destination { print $2; exit }' "$origins"
              )

              if test -n "$recorded"; then
                if test "$recorded" != "$resolved"; then
                  echo "dylib basename collision for $basename" >&2
                  exit 1
                fi
              else
                cp -L "$resolved" "$destination"
                chmod u+w "$destination"
                printf '%s\t%s\n' "$destination" "$resolved" >> "$origins"
                "$install_name_tool" -id "@loader_path/../lib/$basename" "$destination"
                printf '%s\n' "$destination" >> "$queue"
              fi

              "$install_name_tool" \
                -change "$dependency" "@loader_path/../lib/$basename" "$binary"
            done < <(
              "$otool" -L "$binary" \
                | sed -e '1d' -e 's/^[[:space:]]*//' \
                  -e 's/[[:space:]]*(compatibility version.*$//'
            )
          done < "$queue"

          while IFS= read -r binary; do
            while IFS= read -r rpath; do
              "$install_name_tool" -delete_rpath "$rpath" "$binary"
            done < <(
              "$otool" -l "$binary" | awk '
                $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
                in_rpath && $1 == "path" { print $2; in_rpath = 0 }
              ' | sort -u
            )
            min_os=$("$otool" -l "$binary" | awk '$1 == "minos" { print $2; exit }')
            if test "$binary" = "$executable" && test "$min_os" != "14.0"; then
              echo "Homebrew executable must target macOS 14.0, got $min_os" >&2
              exit 1
            fi
            if "$otool" -L "$binary" | sed -e '1d' | grep -q '/nix/store' \
              || "$otool" -l "$binary" | sed -e '1d' | grep -q '/nix/store'; then
              echo "rewritten Mach-O still has a Nix store load command: $binary" >&2
              exit 1
            fi
            while IFS= read -r dependency; do
              test -n "$dependency" || continue
              case "$dependency" in
                /usr/lib/*|/System/Library/Frameworks/*|@loader_path/../lib/*)
                  ;;
                *)
                  echo "unsupported Mach-O load command $dependency in $binary" >&2
                  exit 1
                  ;;
              esac
            done < <(
              "$otool" -L "$binary" \
                | sed -e '1d' -e 's/^[[:space:]]*//' \
                  -e 's/[[:space:]]*(compatibility version.*$//'
            )
          done < "$processed"

          while IFS= read -r binary; do
            sed -i 's|/nix/store|/src/build|g' "$binary"
          done < "$processed"

          if grep -R -a -q '/nix/store' "$out"; then
            echo "rewritten Darwin output contains a Nix store reference" >&2
            exit 1
          fi

          find "$out/lib" -type f -print0 \
            | sort -z \
            | while IFS= read -r -d "" dylib; do
                "$codesign" --force --sign - "$dylib"
              done
          "$codesign" --force --sign - "$executable"

          if ! find "$out/lib" -type f -print -quit | grep -q .; then
            rmdir "$out/lib"
          fi
        '';

  portablePdfSign =
    if pkgs.stdenv.isLinux then
      portableLinux
    else if pkgs.stdenv.isDarwin && pkgs.stdenv.hostPlatform.isAarch64 then
      portableDarwin
    else
      throw "Homebrew bottles are unsupported on ${pkgs.stdenv.hostPlatform.system}";

  homebrewBottle =
    if homebrewPlatform == null then
      throw "Homebrew bottles are unsupported on ${pkgs.stdenv.hostPlatform.system}"
    else
      homebrew.mkBottle {
        pdfSign = portablePdfSign;
        sourceBundle = homebrewSource;
        inherit version;
        inherit (homebrewPlatform) bottleTag ociPlatform;
      };

  mkHomebrewRelease = homebrew.mkRelease;
}
