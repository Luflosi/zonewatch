# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

{ crane
, fenix
, pkgs
, system
}:
rec {
  inherit (pkgs) lib;

  craneLib = crane.mkLib pkgs;

  sqlFilter = path: _type: null != builtins.match ".*sql$" path;
  sqlOrCargo = path: type: (sqlFilter path type) || (craneLib.filterCargoSources path type);

  src = lib.cleanSourceWith {
    src = craneLib.path ../.; # The original, unfiltered source
    filter = sqlOrCargo;
  };

  # Common arguments can be set here to avoid repeating them later
  commonArgs = {
    inherit src;
    strictDeps = true;

    buildInputs = [
      # Add additional build inputs here
    ] ++ lib.optionals pkgs.stdenv.isDarwin [
      # Additional darwin specific inputs can be set here
      pkgs.libiconv
    ];

    # Additional environment variables can be set directly
    # MY_CUSTOM_VAR = "some value";
  };

  craneLibLLvmTools = craneLib.overrideToolchain
    (fenix.packages.${system}.complete.withComponents [
      "cargo"
      "llvm-tools"
      "rustc"
    ]);

  # Build *just* the cargo dependencies, so we can reuse
  # all of that work (e.g. via cachix) when running in CI
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  # Build the actual crate itself, reusing the dependency
  # artifacts from above.
  zonewatch = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });
}
