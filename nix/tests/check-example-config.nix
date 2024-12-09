# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Check the validity of the example config file

{
  lib,
  callPackage,
  runCommand,
  writeShellScriptBin,
  zonewatch-minimal,
}:
let
  base = callPackage ./base.nix { };

  config-file = runCommand "zonewatch-example-config-modified" { } ''
    cp '${../../example-config.toml}' 'example-config.toml'
    substituteInPlace 'example-config.toml' \
      --replace-fail '/var/lib/zonewatch/db.sqlite' 'db.sqlite' \
      --replace-fail '/var/lib/bind/zones' 'zones' \
      --replace-fail '/path/to/file 1.zone' '/tmp/file 1.zone' \
      --replace-fail '/path/to/file 2.zone' '/tmp/file 2.zone'
    cp 'example-config.toml' "$out"
  '';

  fake-rndc = writeShellScriptBin "rndc" "touch $@";

  config = lib.recursiveUpdate base.config {
    zones."example.org".includes = [
      "/tmp/file 1.zone"
      "/tmp/file 2.zone"
    ];
  };

  expected-zone = base.generate-zone "example.org" config.zones."example.org" 1;
in
  runCommand "zonewatch-check-example-config" { nativeBuildInputs = [ fake-rndc ]; } ''
    touch '/tmp/file 1.zone'
    touch '/tmp/file 2.zone'
    export RUST_LOG=zonewatch=trace
    '${lib.getExe zonewatch-minimal}' --only-init --config '${config-file}'
    if ! diff '${expected-zone}' 'zones/example.org.zone'; then
      echo 'The zone file is different from what was expected!'
      exit 1
    fi
    echo 'The zone file is exactly what we expected 🎉'

    if [ ! -e reload ] || [ ! -e example.org ]; then
      echo 'The update program was not called!'
      exit 1
    fi

    touch "$out"
  ''
