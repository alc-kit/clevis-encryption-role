#!/usr/bin/env bash
#
# Device-free regression test for the disk-provisioning GATE and its
# post-condition (tasks/assess-disks-classify.yml, tasks/assert-provisioned.yml).
#
# Background: the provisioning block used to be gated on a CONTROLLER-side file
# (`when: not clevis_recovery_key_stat.stat.exists`). That guard made a resumed
# run skip provisioning entirely and fail later somewhere unrelated. The gate now
# reads the disks themselves, and an unconditional post-condition proves the end
# state instead of trusting the skip. These fixtures exist so that guard can be
# shown to FAIL on bad input — a guard that cannot fail is worse than none.
#
# Every fixture is expected to PASS this playbook: fixtures whose post-condition
# is supposed to fire carry "expect_assert":"fail" and the playbook checks for
# exactly that. A non-zero exit therefore means the gate changed behaviour.
#
# Usage: tests/provisioning-gate/run.sh
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
       "$HERE/gate-fixtures.yml" -e "@$fixture" >/dev/null 2>&1; then
    echo "PASS: provisioning-gate $name"
    pass=$((pass + 1))
  else
    echo "FAIL: provisioning-gate $name (re-run for detail:"
    echo "      ansible-playbook -i localhost, -c local $HERE/gate-fixtures.yml -e @$fixture)"
    fail=$((fail + 1))
  fi
done

echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
