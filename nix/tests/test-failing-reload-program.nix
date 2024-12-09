# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that a failing reload command will cause zonewatch to exit with a non-zero exit code

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
    reload_program_bin = "false";
    zones."example.org" = {
      reload_program_args = [ ];
    };
  };

  config-file = (formats.toml { }).generate "config-failing-reload-program.toml" config;

  expected-zone = base.generate-zone "example.org" config.zones."example.org" 1;
in
  runCommand "zonewatch-test-failing-reload-program" { } ''
    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    echo 'Calling zonewatch is expected to fail:'
    ! '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file}'
    echo 'zonewatch failed as expected 🎉'
    if ! diff '${expected-zone}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    touch "$out"
  ''
