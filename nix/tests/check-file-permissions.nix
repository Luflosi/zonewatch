# SPDX-FileCopyrightText: 2026 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Check that the generated zone file has the correct filesystem permissions

{
  lib,
  callPackage,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };
in
  runCommand "zonewatch-check-file-permissions" { } ''
    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    '${lib.getExe zonewatch-minimal}' --only-init --config '${base.config-file}'

    LS_OUTPUT="$(ls -l 'zones/example.org.zone')"
    if [[ "$LS_OUTPUT" != '-r--r--r-- '* ]]; then
      echo "The generated zone file has the wrong file permissions: $LS_OUTPUT"
      exit 1
    fi
    echo 'The file permissions of the generated zone file are exactly what we expected 🎉'

    touch "$out"
  ''
