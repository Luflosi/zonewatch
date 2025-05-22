# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

{
  description = "Increment the serial number in a DNS zone file if something changes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

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
            reuse lint --lines
            touch "$out"
          '';

          zonewatch-zizmor = pkgs.runCommand "run-zizmor" {
            # zizmor needs this folder structure for some reason
            src = lib.fileset.toSource {
              root = ./.;
              fileset = ./.github/workflows;
            };
          } ''
            '${lib.getExe pkgs.zizmor}' --offline "$src"
            touch "$out"
          '';

          zonewatch-check-package-files = pkgs.callPackage ./nix/tests/check-package-files.nix { };
          zonewatch-check-example-config = pkgs.callPackage ./nix/tests/check-example-config.nix { };
          zonewatch-test-include-missing = pkgs.callPackage ./nix/tests/test-include-missing.nix { };
          zonewatch-test-include-no-permission = pkgs.callPackage ./nix/tests/test-include-no-permission.nix { };
          zonewatch-test-no-change = pkgs.callPackage ./nix/tests/test-no-change.nix { };
          zonewatch-test-includes-reversed = pkgs.callPackage ./nix/tests/test-includes-reversed.nix { };
          zonewatch-test-soa-change = pkgs.callPackage ./nix/tests/test-soa-change.nix { };
          zonewatch-test-dynamic-zone-update = pkgs.callPackage ./nix/tests/test-dynamic-zone-update.nix { };
          zonewatch-test-with-bind = pkgs.callPackage ./nix/tests/test-with-bind.nix { };
          zonewatch-test-serial-overflow = pkgs.callPackage ./nix/tests/test-serial-overflow.nix { };
          zonewatch-test-symlink = pkgs.callPackage ./nix/tests/test-symlink.nix { };
          zonewatch-test-two-zones = pkgs.callPackage ./nix/tests/test-two-zones.nix { };
          zonewatch-test-failing-reload-program = pkgs.callPackage ./nix/tests/test-failing-reload-program.nix { };

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
