# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that running zonewatch again without changes does not increase the serial number

{
  lib,
  callPackage,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };
in
  runCommand "zonewatch-test-no-change" { } ''
    cp --verbose --no-preserve=mode -r '${base.state-after-initial-run}' 'after-initial-run'
    cd 'after-initial-run'
    export RUST_LOG=zonewatch=trace
    '${lib.getExe zonewatch-minimal}' --only-init --config '${base.config-file}'
    if ! diff '${base.expected-zone}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e flag ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    touch "$out"
  ''
