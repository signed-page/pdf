{
  description = "pdf-sign: lightweight PDF signing with OpenPGP (GPG) and Sigstore (keyless OIDC)";

  nixConfig = {
    extra-substituters = [
      "https://pdf-sign.cachix.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "pdf-sign.cachix.org-1:RjOq/uF6ksxVZsLfI9+SW4Nkhcc63+klWAoAtkZRF2U="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
    git-hooks.url = "github:cachix/git-hooks.nix";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      crane,
      git-hooks,
      rust-overlay,
      ...
    }:
    let
      homebrewSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      mkPackageFor =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          craneLib = crane.mkLib pkgs;
        in
        {
          inherit pkgs craneLib;
          package = import ./nix/package.nix {
            inherit pkgs craneLib;
            lib = pkgs.lib;
          };
        };

      perSystemOutputs = flake-utils.lib.eachDefaultSystem (
        system:
        let
          build = mkPackageFor system;
          inherit (build) pkgs craneLib package;
          autocast = import ./nix/demo.nix {
            inherit pkgs craneLib;
            lib = pkgs.lib;
          };
        in
        {
          checks = import ./nix/checks.nix {
            inherit
              pkgs
              craneLib
              package
              git-hooks
              system
              ;
          };

          packages = {
            default = package.pdfSign;
            pdf-sign = package.pdfSign;
            image = package.image;
            inherit autocast;
          }
          // pkgs.lib.optionalAttrs (builtins.elem system homebrewSystems) {
            homebrew-bottle = package.homebrewBottle;
          }
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            homebrew-source = package.homebrewSource;
          };

          devShells.default = import ./nix/shell.nix {
            inherit pkgs;
            pdfSign = package.pdfSign;
            inherit autocast;
            pre-commit-check = import ./nix/git-hooks.nix {
              inherit git-hooks system pkgs;
              src = ./.;
            };
          };
        }
      );

      darwinRelease = mkPackageFor "aarch64-darwin";
      armLinuxRelease = mkPackageFor "aarch64-linux";
      x86LinuxRelease = mkPackageFor "x86_64-linux";

      homebrewRelease = x86LinuxRelease.package.mkHomebrewRelease {
        sourceBundles = {
          "aarch64-darwin" = darwinRelease.package.homebrewSource;
          "aarch64-linux" = armLinuxRelease.package.homebrewSource;
          "x86_64-linux" = x86LinuxRelease.package.homebrewSource;
        };
        bottles = {
          arm64_sonoma = darwinRelease.package.homebrewBottle;
          arm64_linux = armLinuxRelease.package.homebrewBottle;
          x86_64_linux = x86LinuxRelease.package.homebrewBottle;
        };
        version = x86LinuxRelease.package.version;
        sourceRevision =
          if self ? rev then self.rev else throw "homebrew-release requires a clean Git revision";
      };
    in
    nixpkgs.lib.recursiveUpdate perSystemOutputs {
      packages."x86_64-linux".homebrew-release = homebrewRelease;
    };
}
