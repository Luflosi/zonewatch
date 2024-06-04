# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that specifying an include which we're not allowed to read generates the expected zone file

{ lib
, callPackage
, formats
, runCommand
, writeText
, zonewatch-minimal
}:
let
  base = callPackage ./base.nix { };

  config-no-includes = lib.recursiveUpdate base.config {
    zones."example.org".includes = [ ];
  };

  config-include-no-permission = lib.recursiveUpdate base.config {
    zones."example.org".includes = [
      "/tmp/no-permission"
    ];
  };

  config-file-include-no-permission = (formats.toml { }).generate "config-includes-no-permission.toml" config-include-no-permission;

  expected-zone-include-no-permission = let
    zone-string-no-includes = base.generate-zone-string "example.org" config-no-includes.zones."example.org" 1;
    zone-string = zone-string-no-includes + ''
      ; $INCLUDE /tmp/no-permission ; Commented out because we didn't have permission to read the file
    '';
  in writeText "expected.zone" zone-string;
in
  runCommand "zonewatch-test-include-no-permission" { } ''
    touch '/tmp/no-permission'
    chmod 000 '/tmp/no-permission'

    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file-include-no-permission}'
    if ! diff '${expected-zone-include-no-permission}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      echo 'Expected:'
      cat -v '${expected-zone-include-no-permission}'
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
