# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test that zonewatch detects a change made to a file while zonewatch is running

{
  lib,
  callPackage,
  formats,
  runCommand,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };

  config-includes-tmp = lib.recursiveUpdate base.config {
    zones."example.org".includes = [
      "/tmp/ns-ip.zone"
      "/tmp/ns-record.zone"
    ];
  };

  config-file-includes-tmp = (formats.toml { }).generate "config-includes-tmp.toml" config-includes-tmp;

  expected-zone-includes-tmp-serial = base.generate-zone "example.org" config-includes-tmp.zones."example.org";
in
  runCommand "zonewatch-test-dynamic-zone-update" { } ''
    mkdir --verbose db

    cp --verbose --no-preserve=mode '${base.ns-ip}' /tmp/ns-ip.zone
    cp --verbose --no-preserve=mode '${base.ns-record}' /tmp/ns-record.zone

    export RUST_LOG=zonewatch=trace
    '${zonewatch-minimal}/bin/zonewatch' --config '${config-file-includes-tmp}' &
    ZONEWATCH_PID="$!"

    seconds=0
    while [ ! -e 'flag' ] ; do
      if [ "$seconds" -ge 30 ]; then
        echo 'Timed out waiting for flag file'
        exit 1
      fi
      sleep 1
      seconds="$((seconds+1))"
    done

    if ! diff '${expected-zone-includes-tmp-serial 1}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e flag ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    rm --verbose 'flag'

    echo '@  IN A   1.1.1.1' >> /tmp/ns-record.zone

    seconds=0
    while [ ! -e 'flag' ] ; do
      if [ "$seconds" -ge 30 ]; then
        echo 'Timed out waiting for flag file'
        exit 1
      fi
      sleep 1
      seconds="$((seconds+1))"
    done

    kill "$ZONEWATCH_PID"
    if ! diff '${expected-zone-includes-tmp-serial 2}' 'zones/example.org.zone'; then
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
