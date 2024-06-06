# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that incrementing the serial number past the unsigned 32 bit limit wraps around as expected

{ lib
, callPackage
, formats
, runCommand
, zonewatch-minimal
}:
let
  base = callPackage ./base.nix { };

  config-max-serial = lib.recursiveUpdate base.config {
    zones."example.org".soa.initial_serial = 4294967295;
  };
  config-soa-change = lib.recursiveUpdate base.config {
    zones."example.org".soa.expire = "1001h";
  };

  config-file-max-serial = (formats.toml { }).generate "config-max-serial.toml" config-max-serial;
  config-file-soa-change = (formats.toml { }).generate "config-soa-change.toml" config-soa-change;

  expected-zone-max-serial = base.generate-zone "example.org" config-max-serial.zones."example.org" 4294967295;
  expected-zone-soa-change = base.generate-zone "example.org" config-soa-change.zones."example.org" 0;
in
  runCommand "zonewatch-test-serial-overflow" { } ''
    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file-max-serial}'
    if ! diff '${expected-zone-max-serial}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e flag ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file-soa-change}'
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
