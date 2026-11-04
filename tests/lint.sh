#!/usr/bin/env bash
# Syntax-check the installer. Vendored BC-250 scripts are checked with bash -n.
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

status=0

shellcheck -x -P SCRIPTDIR \
  install.sh \
  uninstall.sh \
  bin/update-all \
  lib/common.sh \
  tests/lint.sh \
  || status=1

bash -n install.sh || status=1
bash -n uninstall.sh || status=1
bash -n bin/update-all || status=1
bash -n lib/common.sh || status=1
bash -n system/bin/bc250-cu-live-manager || status=1
bash -n system/bin/bc250-thermal-guard || status=1
bash -n system/cec/usr/lib/bc250-cec/bc250-cec-daemon.sh || status=1
bash -n system/cec/usr/lib/bc250-cec/bc250-cec-keymap.sh || status=1

shellcheck -S error -s bash system/bin/bc250-cu-live-manager || status=1
python3 tests/test_edits.py || status=1

if [[ $status -eq 0 ]]; then
  printf 'lint ok\n'
fi

exit "$status"
