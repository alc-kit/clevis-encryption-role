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
#   3. The crypt-<uuid> in-place migration contract (migrate-inplace.yml).
#   4. The role's audit task (tasks/audit-crypttab.yml) via audit-fixtures.yml,
#      in real and --check mode — it must run and fail on a hard finding in both.
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

# ── Layer 3: crypt-<uuid> in-place migration contract (configure-disk) ────────
echo
echo "== Layer 3: crypttab in-place UUID migration (configure-disk contract) =="
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "SKIP: ansible-playbook not on PATH (Layer 3 skipped)"
elif ansible-playbook -i 'localhost,' -c local "$HERE/migrate-inplace.yml" >/dev/null 2>&1; then
  ok "in-place migration: legacy crypt-<node> -> crypt-<uuid>, idempotent, orphan-free"
else
  bad "in-place migration (re-run without -q: ansible-playbook -i localhost, -c local $HERE/migrate-inplace.yml)"
fi

# ── Layer 4: the role's audit TASK (audit-crypttab.yml), incl. check mode ─────
# The regression: under --check the audit used to be skipped (it ran an installed
# copy whose install was only simulated) and its empty output read as clean, on a
# host whose crypttab already carried a duplicate UUID. The audit must RUN and
# FAIL the play on a hard finding in both modes. Both outcomes are matched on
# output, not rc alone: a pass must show the script's own verdict line (so a
# skipped audit cannot pass), and a fail must be the audit assertion (so a play
# failing for any other reason, e.g. the script not found, does not count).
echo
echo "== Layer 4: audit-crypttab.yml against crypttab fixtures (real + --check) =="
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "SKIP: ansible-playbook not on PATH (Layer 4 skipped)"
else
  expect_task() {
    local fixture="$1" want="$2" mode="$3" out got
    # shellcheck disable=SC2086  # $mode is empty or a single flag, by design
    out="$(ansible-playbook -i 'localhost,' -c local $mode \
      "$HERE/audit-fixtures.yml" -e "fixture=$fixture" 2>&1)"
    got=$?
    local label="audit task crypttab.$fixture ${mode:-(real)}"
    if [ "$want" = "ok" ] && [ "$got" -eq 0 ] \
       && printf '%s' "$out" | grep -Eq 'crypttab-uuid-audit.sh: (crypttab UUID audit clean|0 hard findings)'; then
      ok "$label -> passes, and the audit actually ran"
    elif [ "$want" = "fail" ] && [ "$got" -ne 0 ] \
       && printf '%s' "$out" | grep -q 'failed the pre-flight audit'; then
      ok "$label -> fails on the audit assertion"
    else
      bad "$label -> rc $got, expected $want (re-run: ansible-playbook -i localhost, -c local $mode $HERE/audit-fixtures.yml -e fixture=$fixture)"
    fi
  }
  for mode in "" "--check"; do
    expect_task clean  ok   "$mode"
    expect_task dup    fail "$mode"   # the m-p-proxmox-06/-07 duplicate
    expect_task orphan fail "$mode"   # a UUID on no device (a reformatted disk)
    expect_task soft   ok   "$mode"   # soft-only is not fatal
  done
fi

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
