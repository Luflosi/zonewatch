# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

# Check that the correct files are present in the package

{ runCommand
, zonewatch
, tree
}:
runCommand "zonewatch-check-package-files" { } ''
  '${tree}/bin/tree' '${zonewatch}'
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
