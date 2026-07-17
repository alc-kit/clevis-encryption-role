#!/usr/bin/env bash
#
# crypttab-uuid-audit.sh — detect the LUKS UUID-collision failure mode in
# /etc/crypttab that leaves a ZFS mirror member (or any consumer of a mapper)
# UNAVAIL on every boot.
#
# Background
# ----------
# When two crypttab targets carry the SAME LUKS UUID, both units resolve the
# same /dev/disk/by-uuid device at boot; one wins and creates its mapper, the
# other silently fails (masked by nofail). The disk that should have become the
# loser's mapper never appears under that name, so a pool/vdev cached against it
# is never satisfied. Stale entries (a UUID no longer on any device) and open
# mappers whose backing device disagrees with crypttab are the same class of bug.
#
# This script parses /etc/crypttab and cross-references every UUID against the
# block devices actually present on the host, then reports:
#
#   HARD (exit 2):
#     - a UUID shared by more than one crypttab target        (the core bug)
#     - a crypttab UUID not present on any block device        (stale/orphan)
#     - an OPEN mapper whose backing device UUID != crypttab   (crossed entry)
#   SOFT (exit 3, only when no HARD finding):
#     - a crypto_LUKS device with no crypttab entry            (unrepresented)
#   CLEAN (exit 0):
#     - none of the above
#
# It is safe to run repeatedly and makes no changes. Run it ad hoc, from cron,
# or fleet-wide via Ansible ad-hoc to gate/alert. The clevis-encryption role
# also runs it as a post-deploy verification step.
#
# Usage
# -----
#   crypttab-uuid-audit.sh [--crypttab PATH] [--devmap FILE] [--quiet] [--help]
#
#   --crypttab PATH   crypttab to audit                (default: /etc/crypttab)
#   --devmap FILE     OFFLINE mode: FILE lists the LUKS UUIDs present on the
#                     host, one per line (blank lines / '#' comments ignored).
#                     Disables all live probing (blkid/lsblk/cryptsetup), so the
#                     audit is deterministic and needs no root or real devices —
#                     used by the CI regression fixtures. Omit in production to
#                     probe the real host.
#   --quiet           print findings only (suppress the per-entry OK lines)
#   --help            this help
#
set -uo pipefail

PROG="${0##*/}"
CRYPTTAB="/etc/crypttab"
DEVMAP=""
QUIET=0

die() { echo "$PROG: $*" >&2; exit 64; }

usage() {
  cat >&2 <<EOF
Usage: $PROG [--crypttab PATH] [--devmap FILE] [--quiet] [--help]

Audit /etc/crypttab for the LUKS UUID-collision failure mode: a UUID shared by
two targets, a UUID present on no device (stale), or an open mapper crossed to
the wrong device. Cross-references live block devices (or an offline --devmap).

  --crypttab PATH   crypttab to audit                (default: /etc/crypttab)
  --devmap FILE     offline mode: FILE lists the LUKS UUIDs present on the host,
                    one per line; disables live blkid/lsblk/cryptsetup probing
  --quiet           print findings only (suppress per-entry ok lines)
  --help            this help

Exit: 0 clean; 2 hard finding (duplicate / stale / crossed); 3 soft only
(a crypto_LUKS device with no crypttab entry).
EOF
  exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --crypttab) shift; [ "$#" -gt 0 ] || die "--crypttab needs an argument"; CRYPTTAB="$1" ;;
    --devmap)   shift; [ "$#" -gt 0 ] || die "--devmap needs an argument"; DEVMAP="$1" ;;
    --quiet)    QUIET=1 ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -r "$CRYPTTAB" ] || { echo "$PROG: $CRYPTTAB not present/readable — nothing to audit" >&2; exit 0; }
LIVE=1
[ -n "$DEVMAP" ] && LIVE=0
if [ "$LIVE" -eq 0 ] && [ ! -r "$DEVMAP" ]; then
  die "--devmap file not readable: $DEVMAP"
fi

note()  { [ "$QUIET" -eq 1 ] || echo "ok:   $*"; }
warn()  { echo "WARN: $*"; }
fail()  { echo "FAIL: $*"; }

# ── Resolve the set of LUKS UUIDs actually present on the host ────────────────
# Offline: read them from the devmap file. Live: enumerate crypto_LUKS devices.
present_uuids() {
  if [ "$LIVE" -eq 0 ]; then
    grep -Ev '^[[:space:]]*(#|$)' "$DEVMAP" | tr '[:upper:]' '[:lower:]' | awk '{print $1}'
    return
  fi
  # lsblk is the most reliable enumerator of fstype+uuid across block devices.
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -rno UUID,FSTYPE 2>/dev/null \
      | awk '$2 == "crypto_LUKS" && $1 != "" {print tolower($1)}'
  fi
}

# Is a given UUID present on the host? (offline: in devmap; live: blkid -U)
uuid_present() {
  local u="$1"
  if [ "$LIVE" -eq 0 ]; then
    printf '%s\n' "$PRESENT" | grep -qxF "$u"
    return
  fi
  blkid -U "$u" >/dev/null 2>&1
}

# ── Parse /etc/crypttab into parallel name/uuid arrays ────────────────────────
# Fields: name source keyfile options. We skip comments, blanks, swap entries
# and random-keyed volumes (source /dev/urandom|/dev/random), which never carry
# a stable UUID. Source forms handled: UUID=..., /dev/disk/by-uuid/..., and a
# raw device path (resolved via blkid when live).
# Assign (not just `declare -a`) so `${#C_NAME[@]}` and `${!C_NAME[@]}` are safe
# under `set -u` when the crypttab has no auditable entries (older bash treats a
# declared-but-never-assigned array as unset).
C_NAME=()
C_UUID=()
C_SRC=()
while read -r name source _rest; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac
  opts="${_rest#* }"   # keyfile is the first token of _rest; options follow
  [ "$opts" = "$_rest" ] && opts=""   # no options column
  case ",$opts," in *,swap,*) continue ;; esac
  case "$source" in /dev/urandom|/dev/random) continue ;; esac

  uuid=""
  case "$source" in
    UUID=*)                     uuid="${source#UUID=}"; uuid="${uuid#\"}"; uuid="${uuid%\"}" ;;
    /dev/disk/by-uuid/*)        uuid="${source#/dev/disk/by-uuid/}" ;;
    /dev/*)
      if [ "$LIVE" -eq 1 ]; then
        uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
      fi
      ;;
  esac
  uuid="$(printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]')"

  C_NAME+=("$name")
  C_UUID+=("$uuid")
  C_SRC+=("$source")
done < "$CRYPTTAB"

if [ "${#C_NAME[@]}" -eq 0 ]; then
  note "no auditable crypttab entries in $CRYPTTAB"
  exit 0
fi

PRESENT="$(present_uuids | sort -u)"

hard=0
soft=0

# ── HARD 1: duplicate UUID across two or more targets ─────────────────────────
declare -A seen_first=()
for i in "${!C_NAME[@]}"; do
  u="${C_UUID[$i]}"
  [ -z "$u" ] && continue
  if [ -n "${seen_first[$u]:-}" ]; then
    fail "duplicate LUKS UUID $u shared by targets '${seen_first[$u]}' and '${C_NAME[$i]}' — one mapper will silently fail at boot"
    hard=$((hard + 1))
  else
    seen_first[$u]="${C_NAME[$i]}"
  fi
done

# ── HARD 2: crypttab UUID absent from every block device (stale/orphan) ───────
for i in "${!C_NAME[@]}"; do
  u="${C_UUID[$i]}"
  n="${C_NAME[$i]}"
  s="${C_SRC[$i]}"
  if [ -z "$u" ]; then
    fail "target '$n' source '$s' has no resolvable LUKS UUID (device missing or not LUKS-formatted)"
    hard=$((hard + 1))
    continue
  fi
  if uuid_present "$u"; then
    note "$n -> UUID=$u present"
  else
    fail "target '$n' UUID $u is not present on any block device (stale/orphan entry)"
    hard=$((hard + 1))
  fi
done

# ── HARD 3: open mapper whose backing device UUID != crypttab (crossed) ───────
# Live only, best-effort: needs cryptsetup + root. Skip silently if unavailable.
if [ "$LIVE" -eq 1 ] && command -v cryptsetup >/dev/null 2>&1; then
  for i in "${!C_NAME[@]}"; do
    n="${C_NAME[$i]}"
    u="${C_UUID[$i]}"
    [ -z "$u" ] && continue
    status="$(cryptsetup status "$n" 2>/dev/null)" || continue   # not open → skip
    dev="$(printf '%s\n' "$status" | awk '/^[[:space:]]*device:/{print $2; exit}')"
    [ -n "$dev" ] || continue
    live_uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    [ -n "$live_uuid" ] || continue
    if [ "$live_uuid" != "$u" ]; then
      fail "open mapper '$n' is backed by $dev (UUID=$live_uuid) but crypttab binds it to UUID=$u — crossed entry"
      hard=$((hard + 1))
    fi
  done
fi

# ── SOFT: a crypto_LUKS device on the host with no crypttab entry ─────────────
if [ -n "$PRESENT" ]; then
  # Build the set of UUIDs crypttab knows about.
  ct_uuids="$(printf '%s\n' "${C_UUID[@]}" | grep -v '^$' | sort -u)"
  while IFS= read -r pu; do
    [ -z "$pu" ] && continue
    if ! printf '%s\n' "$ct_uuids" | grep -qxF "$pu"; then
      warn "crypto_LUKS device UUID=$pu is present but has no /etc/crypttab entry"
      soft=$((soft + 1))
    fi
  done <<< "$PRESENT"
fi

echo "----"
if [ "$hard" -gt 0 ]; then
  echo "$PROG: $hard hard finding(s), $soft soft finding(s) in $CRYPTTAB"
  exit 2
elif [ "$soft" -gt 0 ]; then
  echo "$PROG: 0 hard findings, $soft soft finding(s) in $CRYPTTAB"
  exit 3
fi
echo "$PROG: crypttab UUID audit clean (${#C_NAME[@]} entries) in $CRYPTTAB"
exit 0
