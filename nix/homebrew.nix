{
  pkgs,
  lib,
}:
let
  formulaName = "pdf";
  executableName = "pdf-sign";
  sourceRepository = "signed-page/pdf";
  ociRepository = "ghcr.io/signed-page/tap/pdf";
  bottleRootUrl = "https://ghcr.io/v2/signed-page/tap";
  formulaPath = "Library/Taps/signed-page/homebrew-tap/Formula/pdf.rb";
  description = "Lightweight PDF signing tool with OpenPGP (GPG) and Sigstore (keyless OIDC) backends";

  bottlePlatforms = {
    arm64_sonoma = {
      architecture = "arm64";
      os = "darwin";
      "os.version" = "macOS 14";
    };
    arm64_linux = {
      architecture = "arm64";
      os = "linux";
    };
    x86_64_linux = {
      architecture = "amd64";
      os = "linux";
    };
  };

  requiredBottleTags = [
    "arm64_sonoma"
    "arm64_linux"
    "x86_64_linux"
  ];

  requiredSourceSystems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];

  sortedNames = attrs: builtins.sort builtins.lessThan (builtins.attrNames attrs);
  sortedStrings = values: builtins.sort builtins.lessThan values;

  requireVersion =
    version:
    if builtins.match "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" version == null then
      throw "Homebrew release version must be a stable semantic version, got ${builtins.toJSON version}"
    else
      version;

  requireRevision =
    revision:
    if builtins.match "^[0-9a-f]{40}$" revision == null then
      throw "Homebrew release sourceRevision must be a lowercase 40-hex commit"
    else
      revision;

  requireExactAttrs =
    label: expected: attrs:
    if sortedNames attrs == sortedStrings expected then
      attrs
    else
      throw "${label} must contain exactly ${builtins.toJSON expected}, got ${builtins.toJSON (builtins.attrNames attrs)}";
in
rec {
  mkSourceBundle =
    {
      src,
      cargoVendorDir,
      version,
    }:
    let
      checkedVersion = requireVersion version;
      sourceRoot = "${executableName}-${checkedVersion}";
      sourceFilename = "${sourceRoot}-source.tar.gz";
    in
    pkgs.runCommand "${sourceRoot}-homebrew-source"
      {
        inherit
          src
          cargoVendorDir
          sourceRoot
          sourceFilename
          ;
        nativeBuildInputs = with pkgs; [
          coreutils
          findutils
          gnugrep
          gnused
          gnutar
          gzip
          jq
        ];
        SOURCE_DATE_EPOCH = "1";
      }
      ''
        set -euo pipefail
        export LC_ALL=C

        test -d "$src"
        test -f "$src/.cargo/config.toml"
        test -f "$cargoVendorDir/config.toml"

        work="$TMPDIR/source"
        root="$work/$sourceRoot"
        mkdir -p "$root"
        cp -R --preserve=mode,timestamps,links --no-preserve=ownership "$src"/. "$root"/
        chmod -R u+rwX "$root"

        if test -e "$root/vendor"; then
          echo "source tree already contains vendor/" >&2
          exit 1
        fi
        mkdir "$root/vendor"

        dependency_count=0
        for dependency in "$cargoVendorDir"/*; do
          name=$(basename "$dependency")
          if test "$name" = config.toml; then
            continue
          fi
          cp -RL --no-preserve=ownership "$dependency" "$root/vendor/$name"
          dependency_count=$((dependency_count + 1))
        done
        if test "$dependency_count" -eq 0; then
          echo "Crane vendorCargoDeps produced no vendored dependencies" >&2
          exit 1
        fi
        if find "$root/vendor" -type l -print -quit | grep -q .; then
          echo "vendored source contains an unresolved symlink" >&2
          exit 1
        fi

        printf '\n' >> "$root/.cargo/config.toml"
        sed "s|$cargoVendorDir|vendor|g" "$cargoVendorDir/config.toml" >> "$root/.cargo/config.toml"
        if grep -a -q '/nix/store' "$root/.cargo/config.toml"; then
          echo "archived Cargo configuration contains a Nix store path" >&2
          exit 1
        fi

        find "$root" -type d -exec chmod 0755 {} +
        find "$root" -type f -exec chmod u+rw,go+r,go-w {} +

        mkdir -p "$out"
        tar \
          --sort=name \
          --format=gnu \
          --mtime="@$SOURCE_DATE_EPOCH" \
          --owner=0 \
          --group=0 \
          --numeric-owner \
          --hard-dereference \
          -C "$work" \
          -cf - \
          "$sourceRoot" \
          | gzip --no-name --best > "$out/$sourceFilename"

        source_sha=$(sha256sum "$out/$sourceFilename" | cut -d ' ' -f 1)
        jq -cnS \
          --arg filename "$sourceFilename" \
          --arg sha256 "$source_sha" \
          '{filename:$filename,sha256:$sha256}' \
          | tr -d '\n' > "$out/source.json"
      '';

  mkBottle =
    {
      pdfSign,
      sourceBundle,
      version,
      bottleTag,
      ociPlatform,
    }:
    let
      checkedVersion = requireVersion version;
      expectedPlatform =
        bottlePlatforms.${bottleTag}
          or (throw "unsupported Homebrew bottle tag ${builtins.toJSON bottleTag}");
      checkedPlatform =
        if ociPlatform == expectedPlatform then
          ociPlatform
        else
          throw "OCI platform for ${bottleTag} must be ${builtins.toJSON expectedPlatform}";
      sourceFilename = "${executableName}-${checkedVersion}-source.tar.gz";
      kegRootName = "${formulaName}/${checkedVersion}";
      tarFilename = "${formulaName}--${checkedVersion}.${bottleTag}.bottle.tar";
      compressedFilename = "${tarFilename}.gz";
      tabArch = if checkedPlatform.architecture == "amd64" then "x86_64" else "arm64";
      platformJson = builtins.toJSON checkedPlatform;

      kegRoot =
        pkgs.runCommand "${formulaName}-${checkedVersion}-${bottleTag}-keg"
          {
            inherit
              pdfSign
              sourceBundle
              sourceFilename
              kegRootName
              ;
            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              gnugrep
              gnutar
              jq
            ];
          }
          ''
                      set -euo pipefail
                      export LC_ALL=C

                      if ! jq -e --arg filename "$sourceFilename" '
                        type == "object"
                        and keys == ["filename", "sha256"]
                        and .filename == $filename
                        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
                      ' "$sourceBundle/source.json" >/dev/null; then
                        echo "invalid source bundle metadata" >&2
                        exit 1
                      fi

                      source_sha=$(jq -er '.sha256' "$sourceBundle/source.json")
                      test -f "$sourceBundle/$sourceFilename"
                      actual_source_sha=$(sha256sum "$sourceBundle/$sourceFilename" | cut -d ' ' -f 1)
                      if test "$actual_source_sha" != "$source_sha"; then
                        echo "source archive digest does not match source.json" >&2
                        exit 1
                      fi

                      test -x "$pdfSign/bin/${executableName}"
                      keg="$out/$kegRootName"
                      mkdir -p "$keg/bin" "$keg/.brew" "$keg/share/licenses/${executableName}"
                      install -m755 "$pdfSign/bin/${executableName}" "$keg/bin/${executableName}"

                      for directory in lib libexec; do
                        if test -d "$pdfSign/$directory"; then
                          mkdir -p "$keg/$directory"
                          cp -RL --no-preserve=ownership "$pdfSign/$directory"/. "$keg/$directory"/
                        fi
                      done

                      tar -xOzf "$sourceBundle/$sourceFilename" "${executableName}-${checkedVersion}/LICENSE" \
                        > "$keg/share/licenses/${executableName}/LICENSE"
                      test -s "$keg/share/licenses/${executableName}/LICENSE"

                      source_url="https://github.com/${sourceRepository}/releases/download/v${checkedVersion}/$sourceFilename"
                      cat > "$keg/.brew/${formulaName}.rb" <<EOF
            class Pdf < Formula
              desc "${description}"
              homepage "https://signed.page"
              url "$source_url"
              sha256 "$source_sha"
              license "GPL-3.0-only"

              def install
                bin.install "${executableName}"
              end
            end
            EOF

                      find "$keg" -type d -exec chmod 0755 {} +
                      find "$keg" -type f -exec chmod 0644 {} +
                      chmod 0755 "$keg/bin/${executableName}"

                      if grep -R -a -n -E \
                        '/nix/store|/opt/homebrew(/Cellar)?|/home/linuxbrew/\.linuxbrew(/Cellar)?|/usr/local/(Cellar|Homebrew)' \
                        "$keg"; then
                        echo "Keg contains a build-time Nix or Homebrew prefix" >&2
                        exit 1
                      fi
          '';

      layerImage = pkgs.dockerTools.buildImage {
        name = "homebrew-${formulaName}-${bottleTag}";
        tag = checkedVersion;
        copyToRoot = kegRoot;
        compressor = "none";
        created = "1970-01-01T00:00:01Z";
      };
      layer = layerImage.layer;
    in
    pkgs.runCommand "${formulaName}-${checkedVersion}-${bottleTag}-bottle"
      {
        inherit
          layer
          sourceBundle
          sourceFilename
          kegRootName
          tarFilename
          compressedFilename
          bottleTag
          tabArch
          platformJson
          ;
        releaseVersion = checkedVersion;
        nativeBuildInputs = with pkgs; [
          coreutils
          findutils
          gawk
          gzip
          jq
          gnutar
        ];
      }
      ''
        set -euo pipefail
        export LC_ALL=C

        test -f "$layer/layer.tar"
        test -f "$sourceBundle/source.json"
        mkdir -p "$out" "$TMPDIR/unpacked"
        cp "$layer/layer.tar" "$out/$tarFilename"
        gzip --no-name --best --stdout "$out/$tarFilename" > "$out/$compressedFilename"
        gzip --decompress --stdout "$out/$compressedFilename" | cmp - "$out/$tarFilename"

        tar -xf "$out/$tarFilename" -C "$TMPDIR/unpacked"
        test -d "$TMPDIR/unpacked/$kegRootName"
        installed_size=$(
          find "$TMPDIR/unpacked/$kegRootName" -type f -printf '%s\n' \
            | awk '{ total += $1 } END { print total + 0 }'
        )

        uncompressed_sha=$(sha256sum "$out/$tarFilename" | cut -d ' ' -f 1)
        compressed_sha=$(sha256sum "$out/$compressedFilename" | cut -d ' ' -f 1)
        uncompressed_size=$(stat --format='%s' "$out/$tarFilename")
        compressed_size=$(stat --format='%s' "$out/$compressedFilename")
        source_sha=$(jq -er '.sha256' "$sourceBundle/source.json")
        source_url="https://github.com/${sourceRepository}/releases/download/v$releaseVersion/$sourceFilename"

        jq -cnS \
          --arg formula "${formulaName}" \
          --arg version "$releaseVersion" \
          --arg tag "$bottleTag" \
          --arg sourceFilename "$sourceFilename" \
          --arg sourceSha "$source_sha" \
          --arg sourceUrl "$source_url" \
          --argjson ociPlatform "$platformJson" \
          --arg filename "$compressedFilename" \
          --arg sha256 "$compressed_sha" \
          --argjson size "$compressed_size" \
          --argjson installedSize "$installed_size" \
          --arg uncompressedFilename "$tarFilename" \
          --arg uncompressedSha256 "$uncompressed_sha" \
          --argjson uncompressedSize "$uncompressed_size" \
          '{
            schema:1,
            formula:$formula,
            version:$version,
            tag:$tag,
            source:{filename:$sourceFilename,sha256:$sourceSha,url:$sourceUrl},
            ociPlatform:$ociPlatform,
            bottle:{
              filename:$filename,
              sha256:$sha256,
              size:$size,
              installedSize:$installedSize,
              uncompressedFilename:$uncompressedFilename,
              uncompressedSha256:$uncompressedSha256,
              uncompressedSize:$uncompressedSize,
              cellar:"any_skip_relocation"
            }
          }' \
          | tr -d '\n' > "$out/bottle.json"
      '';

  mkRelease =
    {
      sourceBundles,
      bottles,
      version,
      sourceRevision,
    }:
    let
      checkedVersion = requireVersion version;
      checkedRevision = requireRevision sourceRevision;
      checkedSources = requireExactAttrs "sourceBundles" requiredSourceSystems sourceBundles;
      checkedBottles = requireExactAttrs "bottles" requiredBottleTags bottles;
    in
    pkgs.runCommand "${formulaName}-${checkedVersion}-homebrew-release"
      {
        sourceAarch64Darwin = checkedSources."aarch64-darwin";
        sourceAarch64Linux = checkedSources."aarch64-linux";
        sourceX86_64Linux = checkedSources."x86_64-linux";
        bottleArm64Sonoma = checkedBottles.arm64_sonoma;
        bottleArm64Linux = checkedBottles.arm64_linux;
        bottleX86_64Linux = checkedBottles.x86_64_linux;
        platformArm64Sonoma = builtins.toJSON bottlePlatforms.arm64_sonoma;
        platformArm64Linux = builtins.toJSON bottlePlatforms.arm64_linux;
        platformX86_64Linux = builtins.toJSON bottlePlatforms.x86_64_linux;
        releaseVersion = checkedVersion;
        sourceRevision = checkedRevision;
        nativeBuildInputs = with pkgs; [
          coreutils
          findutils
          gawk
          gnugrep
          gzip
          jq
        ];
      }
      ''
        set -euo pipefail
        export LC_ALL=C

        sourceFilename="${executableName}-$releaseVersion-source.tar.gz"
        sourceUrl="https://github.com/${sourceRepository}/releases/download/v$releaseVersion/$sourceFilename"
        work="$TMPDIR/release"
        layout="$out/oci-layout"
        blobs="$layout/blobs/sha256"
        mkdir -p "$blobs" "$out/source" "$out/metadata" \
          "$work/configs" "$work/manifests" "$work/descriptors" \
          "$work/release-bottles" "$work/bottle-tags"

        canonical_json() {
          jq -cS "$@" | tr -d '\n'
        }

        validate_source() {
          label="$1"
          bundle="$2"
          metadata="$bundle/source.json"
          archive="$bundle/$sourceFilename"

          if ! jq -e --arg filename "$sourceFilename" '
            type == "object"
            and keys == ["filename", "sha256"]
            and .filename == $filename
            and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          ' "$metadata" >/dev/null; then
            echo "$label source.json is malformed" >&2
            return 1
          fi
          test -f "$archive"
          claimed=$(jq -er '.sha256' "$metadata")
          actual=$(sha256sum "$archive" | cut -d ' ' -f 1)
          if test "$claimed" != "$actual"; then
            echo "$label source archive digest mismatch" >&2
            return 1
          fi
          printf '%s' "$actual"
        }

        darwin_source_sha=$(validate_source aarch64-darwin "$sourceAarch64Darwin")
        arm_linux_source_sha=$(validate_source aarch64-linux "$sourceAarch64Linux")
        x86_linux_source_sha=$(validate_source x86_64-linux "$sourceX86_64Linux")
        if test "$darwin_source_sha" != "$x86_linux_source_sha" \
          || test "$arm_linux_source_sha" != "$x86_linux_source_sha"; then
          echo "native source archives are not byte-identical" >&2
          exit 1
        fi
        cp "$sourceX86_64Linux/$sourceFilename" "$out/source/$sourceFilename"

        make_platform() {
          tag="$1"
          input="$2"
          expected_platform="$3"
          tab_arch="$4"
          metadata="$input/bottle.json"
          expected_tar="${formulaName}--$releaseVersion.$tag.bottle.tar"
          expected_gzip="$expected_tar.gz"

          if ! jq -e \
            --arg formula "${formulaName}" \
            --arg version "$releaseVersion" \
            --arg tag "$tag" \
            --arg sourceFilename "$sourceFilename" \
            --arg sourceSha "$x86_linux_source_sha" \
            --arg sourceUrl "$sourceUrl" \
            --arg expectedTar "$expected_tar" \
            --arg expectedGzip "$expected_gzip" \
            --argjson platform "$expected_platform" '
              type == "object"
              and keys == ["bottle", "formula", "ociPlatform", "schema", "source", "tag", "version"]
              and .schema == 1
              and .formula == $formula
              and .version == $version
              and .tag == $tag
              and .ociPlatform == $platform
              and (.source | type == "object" and keys == ["filename", "sha256", "url"])
              and .source.filename == $sourceFilename
              and .source.sha256 == $sourceSha
              and .source.url == $sourceUrl
              and (.bottle | type == "object" and keys == ["cellar", "filename", "installedSize", "sha256", "size", "uncompressedFilename", "uncompressedSha256", "uncompressedSize"])
              and .bottle.cellar == "any_skip_relocation"
              and .bottle.filename == $expectedGzip
              and .bottle.uncompressedFilename == $expectedTar
              and (.bottle.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
              and (.bottle.uncompressedSha256 | type == "string" and test("^[0-9a-f]{64}$"))
              and (.bottle.size | type == "number" and . > 0)
              and (.bottle.uncompressedSize | type == "number" and . > 0)
              and (.bottle.installedSize | type == "number" and . > 0)
            ' "$metadata" >/dev/null; then
            echo "$tag bottle.json is malformed or mismatched" >&2
            return 1
          fi

          compressed="$input/$expected_gzip"
          uncompressed="$input/$expected_tar"
          test -f "$compressed"
          test -f "$uncompressed"

          compressed_sha=$(sha256sum "$compressed" | cut -d ' ' -f 1)
          uncompressed_sha=$(sha256sum "$uncompressed" | cut -d ' ' -f 1)
          compressed_size=$(stat --format='%s' "$compressed")
          uncompressed_size=$(stat --format='%s' "$uncompressed")
          installed_size=$(jq -er '.bottle.installedSize' "$metadata")

          test "$compressed_sha" = "$(jq -er '.bottle.sha256' "$metadata")"
          test "$uncompressed_sha" = "$(jq -er '.bottle.uncompressedSha256' "$metadata")"
          test "$compressed_size" = "$(jq -er '.bottle.size' "$metadata")"
          test "$uncompressed_size" = "$(jq -er '.bottle.uncompressedSize' "$metadata")"
          gzip --decompress --stdout "$compressed" | cmp - "$uncompressed"

          layer_blob="$blobs/$compressed_sha"
          if test -e "$layer_blob"; then
            cmp "$compressed" "$layer_blob"
          else
            cp "$compressed" "$layer_blob"
          fi

          config="$work/configs/$tag.json"
          canonical_json -n \
            --argjson platform "$expected_platform" \
            --arg diffId "sha256:$uncompressed_sha" \
            '$platform + {rootfs:{type:"layers",diff_ids:[$diffId]}}' \
            > "$config"
          config_sha=$(sha256sum "$config" | cut -d ' ' -f 1)
          config_size=$(stat --format='%s' "$config")
          cp "$config" "$blobs/$config_sha"

          tab_json=$(canonical_json -n --arg arch "$tab_arch" '{arch:$arch,runtime_dependencies:[]}')
          annotations=$(canonical_json -n \
            --arg refName "$releaseVersion.$tag" \
            --arg bottleDigest "$compressed_sha" \
            --arg bottleSize "$compressed_size" \
            --arg installedSize "$installed_size" \
            --arg tab "$tab_json" \
            '{
              "org.opencontainers.image.ref.name":$refName,
              "sh.brew.bottle.digest":$bottleDigest,
              "sh.brew.bottle.size":$bottleSize,
              "sh.brew.bottle.installed_size":$installedSize,
              "sh.brew.license":"GPL-3.0-only",
              "sh.brew.tab":$tab,
              "sh.brew.path_exec_files":"bin/pdf-sign"
            }')

          manifest="$work/manifests/$tag.json"
          canonical_json -n \
            --arg configDigest "sha256:$config_sha" \
            --argjson configSize "$config_size" \
            --arg layerDigest "sha256:$compressed_sha" \
            --argjson layerSize "$compressed_size" \
            --arg layerTitle "$expected_gzip" \
            --argjson annotations "$annotations" \
            '{
              schemaVersion:2,
              config:{
                mediaType:"application/vnd.oci.image.config.v1+json",
                digest:$configDigest,
                size:$configSize
              },
              layers:[{
                mediaType:"application/vnd.oci.image.layer.v1.tar+gzip",
                digest:$layerDigest,
                size:$layerSize,
                annotations:{"org.opencontainers.image.title":$layerTitle}
              }],
              annotations:$annotations
            }' > "$manifest"
          manifest_sha=$(sha256sum "$manifest" | cut -d ' ' -f 1)
          manifest_size=$(stat --format='%s' "$manifest")
          cp "$manifest" "$blobs/$manifest_sha"

          canonical_json -n \
            --arg digest "sha256:$manifest_sha" \
            --argjson size "$manifest_size" \
            --argjson platform "$expected_platform" \
            --argjson annotations "$annotations" \
            '{
              mediaType:"application/vnd.oci.image.manifest.v1+json",
              digest:$digest,
              size:$size,
              platform:$platform,
              annotations:$annotations
            }' > "$work/descriptors/$tag.json"

          canonical_json -n \
            --arg tag "$tag" \
            --arg sha256 "$compressed_sha" \
            --arg manifestDigest "sha256:$manifest_sha" \
            --argjson size "$compressed_size" \
            --argjson installedSize "$installed_size" \
            '{($tag):{
              sha256:$sha256,
              manifestDigest:$manifestDigest,
              size:$size,
              installedSize:$installedSize,
              cellar:"any_skip_relocation"
            }}' > "$work/release-bottles/$tag.json"

          canonical_json -n \
            --arg tag "$tag" \
            --arg filename "$expected_gzip" \
            --arg sha256 "$compressed_sha" \
            --argjson installedSize "$installed_size" \
            --argjson tab "$tab_json" \
            '{($tag):{
              filename:$filename,
              local_filename:$filename,
              sha256:$sha256,
              tab:$tab,
              path_exec_files:["bin/pdf-sign"],
              installed_size:$installedSize
            }}' > "$work/bottle-tags/$tag.json"
        }

        make_platform arm64_sonoma "$bottleArm64Sonoma" "$platformArm64Sonoma" arm64
        make_platform arm64_linux "$bottleArm64Linux" "$platformArm64Linux" arm64
        make_platform x86_64_linux "$bottleX86_64Linux" "$platformX86_64Linux" x86_64

        descriptors=$(canonical_json -s '.' \
          "$work/descriptors/arm64_sonoma.json" \
          "$work/descriptors/arm64_linux.json" \
          "$work/descriptors/x86_64_linux.json")
        index_annotations=$(canonical_json -n \
          --arg revision "$sourceRevision" \
          --arg version "$releaseVersion" \
          '{
            "com.github.package.type":"homebrew_bottle",
            "org.opencontainers.image.source":"https://github.com/${sourceRepository}",
            "org.opencontainers.image.version":$version,
            "org.opencontainers.image.licenses":"GPL-3.0-only",
            "org.opencontainers.image.revision":$revision
          }')
        image_index="$work/image-index.json"
        canonical_json -n \
          --argjson manifests "$descriptors" \
          --argjson annotations "$index_annotations" \
          '{schemaVersion:2,manifests:$manifests,annotations:$annotations}' \
          > "$image_index"
        image_index_sha=$(sha256sum "$image_index" | cut -d ' ' -f 1)
        image_index_size=$(stat --format='%s' "$image_index")
        cp "$image_index" "$blobs/$image_index_sha"

        canonical_json -n '{imageLayoutVersion:"1.0.0"}' > "$layout/oci-layout"
        canonical_json -n \
          --arg digest "sha256:$image_index_sha" \
          --argjson size "$image_index_size" \
          --arg version "$releaseVersion" \
          '{
            schemaVersion:2,
            manifests:[{
              mediaType:"application/vnd.oci.image.index.v1+json",
              digest:$digest,
              size:$size,
              annotations:{"org.opencontainers.image.ref.name":$version}
            }]
          }' > "$layout/index.json"

        release_bottles=$(canonical_json -s 'reduce .[] as $item ({}; . + $item)' \
          "$work/release-bottles/arm64_sonoma.json" \
          "$work/release-bottles/arm64_linux.json" \
          "$work/release-bottles/x86_64_linux.json")
        canonical_json -n \
          --arg formula "${formulaName}" \
          --arg version "$releaseVersion" \
          --arg sourceFilename "$sourceFilename" \
          --arg sourceSha "$x86_linux_source_sha" \
          --arg repository "${ociRepository}" \
          --arg indexDigest "sha256:$image_index_sha" \
          --argjson bottles "$release_bottles" \
          '{
            schema:1,
            formula:$formula,
            version:$version,
            source:{filename:$sourceFilename,sha256:$sourceSha},
            oci:{repository:$repository,indexDigest:$indexDigest},
            bottles:$bottles
          }' > "$out/metadata/release.json"

        bottle_tags=$(canonical_json -s 'reduce .[] as $item ({}; . + $item)' \
          "$work/bottle-tags/arm64_sonoma.json" \
          "$work/bottle-tags/arm64_linux.json" \
          "$work/bottle-tags/x86_64_linux.json")
        canonical_json -n \
          --arg formula "${formulaName}" \
          --arg version "$releaseVersion" \
          --arg path "${formulaPath}" \
          --arg desc "${description}" \
          --argjson tags "$bottle_tags" \
          '{($formula):{
            formula:{
              name:$formula,
              pkg_version:$version,
              path:$path,
              tap_git_path:"Formula/pdf.rb",
              desc:$desc,
              license:"GPL-3.0-only",
              homepage:"https://signed.page"
            },
            bottle:{
              root_url:"${bottleRootUrl}",
              cellar:"any_skip_relocation",
              rebuild:0,
              tags:$tags
            }
          }}' > "$out/metadata/pdf.bottle.json"

        for blob in "$blobs"/*; do
          name=$(basename "$blob")
          if ! [[ "$name" =~ ^[0-9a-f]{64}$ ]]; then
            echo "malformed OCI blob name $name" >&2
            exit 1
          fi
          actual=$(sha256sum "$blob" | cut -d ' ' -f 1)
          if test "$actual" != "$name"; then
            echo "OCI blob digest mismatch for $name" >&2
            exit 1
          fi
        done

        jq -e \
          --arg version "$releaseVersion" \
          --arg sourceSha "$x86_linux_source_sha" \
          --arg indexDigest "sha256:$image_index_sha" '
            .schema == 1
            and .formula == "pdf"
            and .version == $version
            and .source.sha256 == $sourceSha
            and .oci.repository == "ghcr.io/signed-page/tap/pdf"
            and .oci.indexDigest == $indexDigest
            and (.bottles | keys == ["arm64_linux", "arm64_sonoma", "x86_64_linux"])
          ' "$out/metadata/release.json" >/dev/null
      '';
}
