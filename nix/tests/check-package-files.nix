# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Check that the correct files are present in the package

{
  lib,
  runCommand,
  zonewatch,
  tree,
}:
runCommand "zonewatch-check-package-files" { } ''
  '${lib.getExe tree}' '${zonewatch}'
  if [ '${lib.getExe zonewatch}' != '${zonewatch}/bin/zonewatch' ]; then
    echo 'The main executable does not have the expected name!'
    exit 1
  fi
  if [ ! -e '${zonewatch}/bin/zonewatch' ]; then
    echo 'The executable was not found!'
    exit 1
  fi
  if [ ! -e '${zonewatch}/etc/systemd/system/zonewatch.service' ]; then
    echo 'No systemd unit file was found!'
    exit 1
  fi
  echo 'The package contains all the files we expected 🎉'

  touch "$out"
''
