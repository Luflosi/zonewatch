# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that the generated zone file is valid by piping it to BIND

{
  lib,
  callPackage,
  writeText,
  runCommand,
  bind,
}:
let
  base = callPackage ./base.nix { };

  bind-conf = writeText "named.conf" ''
    options {
      pid-file "/tmp/named.pid";
    };
    zone "example.org" {
      type master;
      file "${base.state-after-initial-run}/zones/example.org.zone";
    };
  '';
in
  runCommand "zonewatch-test-with-bind" { } ''
    stop () {
      echo 'Stopping BIND...'
      kill "$(<"/tmp/named.pid")"
    }

    echo 'Running BIND'
    '${lib.getExe' bind "named"}' -g -c '${bind-conf}' 2>&1 | while read -r line ; do
      echo "$line"

      if [[ "$line" == *'resolver priming query complete: failure'* ]]; then
        echo 'BIND seems to have finished starting'
        stop
      fi

      if [[ "$line" == *'dns_master_load:'* ]]; then
        echo 'Error detected'
        stop
        exit 1
      fi

      if [[ "$line" == *'.zone:'* ]]; then
        echo 'Warning detected?'
        stop
        exit 1
      fi
    done

    touch "$out"
  ''
