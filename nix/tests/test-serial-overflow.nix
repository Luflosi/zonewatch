# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that incrementing the serial number past the unsigned 32 bit limit wraps around as expected

{ lib
, callPackage
, formats
, writeText
, runCommand
, sqlite
, zonewatch-minimal
}:
let
  base = callPackage ./base.nix { };

  config-soa-change = lib.recursiveUpdate base.config {
    zones."example.org".soa.expire = "1001h";
  };

  config-file-soa-change = (formats.toml { }).generate "config-soa-change.toml" config-soa-change;

  expected-zone-soa-change = base.generate-zone "example.org" config-soa-change.zones."example.org" 0;

  sql-script = writeText "script.sql" ''
    UPDATE zones
    SET soa_serial = 4294967295
    WHERE name = 'example.org';
  '';
in
  runCommand "zonewatch-test-serial-overflow" { } ''
    cp --verbose --no-preserve=mode -r '${base.state-after-initial-run}' 'after-initial-run'
    cd 'after-initial-run'
    '${sqlite}/bin/sqlite3' db/db.sqlite < '${sql-script}'
    export RUST_LOG=zonewatch=trace
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
