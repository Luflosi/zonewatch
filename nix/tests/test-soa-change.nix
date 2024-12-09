# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that changing the config file by modifying a SOA field updates the zone file accordingly

{
  lib,
  callPackage,
  formats,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };

  config-soa-change = lib.recursiveUpdate base.config {
    zones."example.org".soa.expire = "1001h";
  };

  config-file-soa-change = (formats.toml { }).generate "config-soa-change.toml" config-soa-change;

  expected-zone-soa-change = base.generate-zone "example.org" config-soa-change.zones."example.org" 2;
in
  runCommand "zonewatch-test-soa-change" { } ''
    cp --verbose --no-preserve=mode -r '${base.state-after-initial-run}' 'after-initial-run'
    cd 'after-initial-run'
    export RUST_LOG=zonewatch=trace
    '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file-soa-change}'
    if ! diff '${expected-zone-soa-change}' 'zones/example.org.zone'; then
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
