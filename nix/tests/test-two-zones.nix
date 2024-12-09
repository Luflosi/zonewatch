# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test with two zones

{
  lib,
  callPackage,
  formats,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };

  config = lib.recursiveUpdate base.config {
    zones = {
      "example.org" = {
        reload_program_args = [ "flag-example.org" ];
      };
      "example.com" = {
        dir = "zones";
        reload_program_args = [ "flag-example.com" ];
        ttl = "1d";
        includes = [
          "${base.ns-record}"
          "${base.ns-ip}"
        ];
        soa = {
          ttl = "1d";
          mname = "ns1.example.com.";
          rname = "john\\.doe.example.com.";
          initial_serial = 1;
          refresh = "1d";
          retry = "2h";
          expire = "1000h";
          minimum = "1h";
        };
      };
    };
  };

  config-file = (formats.toml { }).generate "config-two-zones.toml" config;

  expected-zone-example-org = base.generate-zone "example.org" config.zones."example.org" 1;
  expected-zone-example-com = base.generate-zone "example.com" config.zones."example.com" 1;
in
  runCommand "zonewatch-test-two-zones" { } ''
    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file}'
    if ! diff '${expected-zone-example-org}' 'zones/example.org.zone'; then
      echo 'The zone file for example.org is different from what was expected!'
      exit 1
    fi
    echo 'The zone file for example.org is exactly what we expected 🎉'

    if ! diff '${expected-zone-example-com}' 'zones/example.com.zone'; then
      echo 'The zone file for example.com is different from what was expected!'
      exit 1
    fi
    echo 'The zone file for example.com is exactly what we expected 🎉'

    if [ ! -e flag-example.org ]; then
      echo 'The update program for zone example.org was not called!'
      exit 1
    fi
    if [ ! -e flag-example.com ]; then
      echo 'The update program for zone example.com was not called!'
      exit 1
    fi

    touch "$out"
  ''
