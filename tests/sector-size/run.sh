#!/usr/bin/env bash
#
# Device-free tests for the LUKS sector-size decision and verdict
# (tasks/sector-size-decide.yml, tasks/sector-size-judge.yml).
#
# A bare `cryptsetup luksFormat` picks the encryption sector size per disk from the
# disk's physical sector size, so one data group came out with five 4096-byte
# mappers and one 512-byte mapper, and `vgcreate` refused it after the old pool was
# already gone. These fixtures pin the group rule — match existing members, else the
# configured size — and the verdict: mixed fails where uniformity is required.
#
# Usage: bash tests/sector-size/run.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX="$HERE/fixtures"

command -v ansible-playbook >/dev/null 2>&1 || { echo "error: ansible-playbook not on PATH" >&2; exit 1; }

pass=0
fail=0
for fixture in "$FIX"/*.json; do
  name="$(basename "$fixture" .json)"
  if ansible-playbook -i 'localhost,' -c local "$HERE/fixtures-play.yml" -e "@$fixture" >/dev/null 2>&1; then
    echo "PASS: sector-size $name"
    pass=$((pass + 1))
  else
    echo "FAIL: sector-size $name (re-run for detail:"
    echo "      ansible-playbook -i localhost, -c local $HERE/fixtures-play.yml -e @$fixture)"
    fail=$((fail + 1))
  fi
done

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
