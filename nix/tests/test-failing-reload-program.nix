# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that a failing reload command will cause zonewatch to exit with a non-zero exit code.
# Also check that the serial number is never decremented, even if the reload command fails.

{
  lib,
  callPackage,
  formats,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };

  config-failing = lib.recursiveUpdate base.config {
    reload_program_bin = "false";
    zones."example.org" = {
      reload_program_args = [ ];
      soa.expire = "1001h";
    };
  };
  config-working = base.config;

  config-file-failing = (formats.toml { }).generate "config-failing-reload-program.toml" config-failing;
  config-file-working = (formats.toml { }).generate "config-working-reload-program.toml" config-working;

  expected-zone-failing = base.generate-zone "example.org" config-failing.zones."example.org" 2;
  expected-zone-working = base.generate-zone "example.org" config-working.zones."example.org" 3;
in
  runCommand "zonewatch-test-failing-reload-program" { } ''
    cp --verbose --no-preserve=mode -r '${base.state-after-initial-run}' 'after-initial-run'
    cd 'after-initial-run'
    export RUST_LOG=zonewatch=trace

    echo 'Calling zonewatch is expected to fail:'
    ! '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file-failing}'
    echo 'zonewatch failed as expected 🎉'
    if ! diff '${expected-zone-failing}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    echo 'Calling zonewatch again with a different config file is expected to work:'
    '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file-working}'
    echo 'zonewatch failed as expected 🎉'
    if ! diff '${expected-zone-working}' 'zones/example.org.zone'; then
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
