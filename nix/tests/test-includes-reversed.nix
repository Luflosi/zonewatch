# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that changing the config file by reordering two includes updates the zone file accordingly

{ lib
, callPackage
, formats
, runCommand
, zonewatch-minimal
}:
let
  base = callPackage ./base.nix { };

  config-includes-reversed = lib.recursiveUpdate base.config {
    zones."example.org".includes = [
      "${base.ns-ip}"
      "${base.ns-record}"
    ];
  };

  config-file-includes-reversed = (formats.toml { }).generate "config-includes-reversed.toml" config-includes-reversed;

  expected-zone-includes-reversed = base.generate-zone "example.org" config-includes-reversed.zones."example.org" 2;
in
  runCommand "zonewatch-test-includes-reversed" { } ''
    cp --verbose --no-preserve=mode -r '${base.state-after-initial-run}' 'after-initial-run'
    cd 'after-initial-run'
    export RUST_LOG=zonewatch=trace
    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file-includes-reversed}'
    if ! diff '${expected-zone-includes-reversed}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      echo 'Expected:'
      cat -v '${expected-zone-includes-reversed}'
      echo 'Actual:'
      cat -v 'zones/example.org.zone'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e flag ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    touch "$out"
  ''
