# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Test what happens when one of the includes is a symlink

# The behaviour is not ideal but improving it would make the code much more complicated as
# we would need to dynamically add and remove file watches as symlinks are created, altered or deleted.
# There is a TODO item in the README.

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
    zones."example.org".includes = [
      "/tmp/ns-ip.zone"
      "/tmp/ns-record-symlink.zone"
    ];
  };

  config-file = (formats.toml { }).generate "config-includes-symlink.toml" config;

  expected-zone = base.generate-zone "example.org" config.zones."example.org";
in
  runCommand "zonewatch-test-symlink" { } ''
    mkdir --verbose db

    cp --verbose --no-preserve=mode '${base.ns-ip}' /tmp/ns-ip.zone
    cp --verbose --no-preserve=mode '${base.ns-record}' /tmp/ns-record.zone

    ln -s /tmp/ns-record.zone /tmp/ns-record-symlink.zone

    export RUST_LOG=zonewatch=trace

    { '${zonewatch-minimal}/bin/zonewatch' --config '${config-file}' & echo "$!" >"$TMPDIR/pid"; } 2>&1 | while read -r line ; do
      echo "output: $line"

      if [[ "$line" == *'Reloading the zone with command '* ]]; then
        echo 'Initial startup complete, modifying zone file...'
        echo '@  IN A   1.1.1.1' >> /tmp/ns-record.zone
      fi

      if [[ "$line" == *'None of the files we'"'"'re interested in were changed'* ]]; then
        echo 'No changes were detected, stopping...'
        kill "$(<"$TMPDIR/pid")"
      fi
    done

    if ! diff '${expected-zone 1}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e flag ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    rm --verbose 'flag'

    '${zonewatch-minimal}/bin/zonewatch' --only-init --config '${config-file}'

    if ! diff '${expected-zone 2}' 'zones/example.org.zone'; then
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
