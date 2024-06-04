# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that specifying an include which does not exist generates the expected zone file

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

  config-include-missing = lib.recursiveUpdate base.config {
    zones."example.org".includes = [
      "/path/does/not/exist"
    ];
  };

  config-file-include-missing = (formats.toml { }).generate "config-include-missing.toml" config-include-missing;

  expected-zone-include-missing = let
    zone-string-no-includes = base.generate-zone-string "example.org" config-no-includes.zones."example.org" 1;
    zone-string = zone-string-no-includes + ''
      ; $INCLUDE /path/does/not/exist ; Commented out because the file was not found
    '';
  in writeText "expected.zone" zone-string;
in
  runCommand "zonewatch-test-include-missing" { } ''
    mkdir --verbose db
    export RUST_LOG=zonewatch=trace
    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file-include-missing}'
    if ! diff '${expected-zone-include-missing}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      echo 'Expected:'
      cat -v '${expected-zone-include-missing}'
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
