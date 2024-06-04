# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

{
  description = "Build zonewatch";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    dyndnsd = {
      url = "github:Luflosi/dyndnsd";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.crane.follows = "crane";
      inputs.fenix.follows = "fenix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.advisory-db.follows = "advisory-db";
    };

    zonegen = {
      url = "github:Luflosi/zonegen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.crane.follows = "crane";
      inputs.fenix.follows = "fenix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.advisory-db.follows = "advisory-db";
      inputs.dyndnsd.follows = "dyndnsd";
    };
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, advisory-db, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            self.outputs.overlays.zonewatch
            self.inputs.zonegen.overlays.zonegen
            self.inputs.dyndnsd.overlays.dyndnsd
          ];
        };

        builder = import ./nix/builder.nix { inherit crane fenix pkgs system; };
        inherit (builder)
          lib
          craneLib
          src
          commonArgs
          craneLibLLvmTools
          cargoArtifacts
          zonewatch
          zonewatch-full
        ;
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit zonewatch;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          zonewatch-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          zonewatch-doc = craneLib.cargoDoc (commonArgs // {
            inherit cargoArtifacts;
          });

          # Check formatting
          zonewatch-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Audit dependencies
          zonewatch-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          zonewatch-deny = craneLib.cargoDeny {
            inherit src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `zonewatch` if you do not want
          # the tests to run twice
          zonewatch-nextest = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });

          zonewatch-reuse = pkgs.runCommand "run-reuse" {
            src = ./.;
            nativeBuildInputs = with pkgs; [ reuse ];
          } ''
            cd "$src"
            reuse lint
            touch "$out"
          '';

          zonewatch-check-example-config = pkgs.callPackage ./nix/tests/check-example-config.nix { };

        # NixOS tests don't run on macOS
        } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          zonewatch-e2e-test = pkgs.testers.runNixOSTest (import ./nix/tests/NixOS-integration-test.nix self);
        };

        packages = {
          zonewatch = zonewatch-full;
          default = self.packages.${system}.zonewatch;
        } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          zonewatch-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs // {
            inherit cargoArtifacts;
          });
        };

        apps.zonewatch = flake-utils.lib.mkApp {
          drv = zonewatch;
        };
        apps.default = self.apps.${system}.zonewatch;

        devShells.zonewatch = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = with pkgs; [
            sqlx-cli
          ];
        };
        devShells.default = self.devShells.${system}.zonewatch;
      }) // {
        nixosModules.zonewatch = import ./nix/module.nix;
        nixosModules.default = self.nixosModules.zonewatch;

        overlays.zonewatch = import ./nix/overlay.nix (import ./nix/builder.nix) crane fenix;
        overlays.default = self.overlays.zonewatch;
      };
}
