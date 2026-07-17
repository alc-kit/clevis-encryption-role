#!/usr/bin/env bash
#
# Device-free regression test for the local-disk auto-discovery selection
# (tasks/discover-disks.yml). Runs the REAL role task against synthetic device
# maps injected via `clevis_discovery_devices` and asserts the selected disk
# list — no block devices, no root, no gathered facts. Runs on any CI runner.
#
# Each fixture in fixtures/*.json supplies both `clevis_discovery_devices` and
# the `expected_disks` result; the assertion lives in select-fixtures.yml, so a
# non-zero ansible-playbook exit means the wrong disks were selected.
#
# Usage: tests/discovery/run.sh   (exits non-zero on any unexpected result)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIX="$HERE/fixtures"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "error: ansible-playbook not on PATH" >&2
  exit 1
fi

pass=0
fail=0

for fixture in "$FIX"/*.json; do
  name="$(basename "$fixture" .json)"
  if ansible-playbook -i 'localhost,' -c local \
       "$HERE/select-fixtures.yml" -e "@$fixture" >/dev/null 2>&1; then
    echo "PASS: discovery $name"
    pass=$((pass + 1))
  else
    echo "FAIL: discovery $name (re-run without -q for detail:"
    echo "      ansible-playbook -i localhost, -c local $HERE/select-fixtures.yml -e @$fixture)"
    fail=$((fail + 1))
  fi
done

echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
