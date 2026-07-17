#!/usr/bin/env bash
#
# Device-free regression test for the crypttab UUID-collision guard
# (mitigation doc item 4).  Two layers, both runnable on any CI runner with no
# block devices, no root, and no VMs:
#
#   1. The audit script (files/crypttab-uuid-audit.sh) against fixture crypttab
#      files in --devmap (offline) mode — asserts the exit code per fixture.
#   2. The role's pure pre-flight assertions (tasks/assert-crypttab-unique.yml)
#      via assert-fixtures.yml with injected clevis_crypttab_pairs — asserts the
#      play passes for a unique/valid set and fails for a duplicate/unformatted
#      one.
#
# Usage: tests/crypttab-guard/run.sh   (exits non-zero on any unexpected result)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROLE_DIR="$(cd -P "$HERE/../.." >/dev/null 2>&1 && pwd)"
AUDIT="$ROLE_DIR/files/crypttab-uuid-audit.sh"
FIX="$HERE/fixtures"

pass=0
fail=0
ok()   { echo "PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $*"; fail=$((fail + 1)); }

# ── Layer 1: audit script exit codes against crypttab fixtures ────────────────
expect_audit() {
  local fixture="$1" want="$2" got
  bash "$AUDIT" --crypttab "$FIX/crypttab.$fixture" --devmap "$FIX/present.clean" --quiet >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    ok "audit crypttab.$fixture -> exit $got"
  else
    bad "audit crypttab.$fixture -> exit $got (expected $want)"
  fi
}

echo "== Layer 1: crypttab-uuid-audit.sh fixture exit codes =="
expect_audit clean  0   # unique, all present
expect_audit dup    2   # duplicate UUID (the m-p-proxmox-06 bug)  -> HARD
expect_audit orphan 2   # stale UUID absent from any device        -> HARD
expect_audit soft   3   # present crypto_LUKS device unrepresented -> SOFT only

# ── Layer 2: the role's pure Ansible assertions ───────────────────────────────
echo
echo "== Layer 2: assert-crypttab-unique.yml against injected pairs =="
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "SKIP: ansible-playbook not on PATH (Layer 2 skipped)"
else
  expect_play() {
    local fixture="$1" want="$2" got
    ansible-playbook -i 'localhost,' -c local \
      "$HERE/assert-fixtures.yml" -e "@$FIX/pairs-$fixture.json" >/dev/null 2>&1
    got=$?
    # ansible-playbook: 0 = play ok; non-zero = a task (our assert) failed.
    if { [ "$want" = "ok" ] && [ "$got" -eq 0 ]; } || \
       { [ "$want" = "fail" ] && [ "$got" -ne 0 ]; }; then
      ok "assert pairs-$fixture -> rc $got (expected $want)"
    else
      bad "assert pairs-$fixture -> rc $got (expected $want)"
    fi
  }
  expect_play unique  ok     # three unique valid pairs -> play passes
  expect_play dup     fail   # duplicate UUID           -> assert fails the play
  expect_play badtype fail   # empty uuid/type          -> assert fails the play
fi

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
