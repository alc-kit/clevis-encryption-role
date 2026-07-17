# Migration & design plan: device identity + `luks-<UUID>` mapper naming (local now, multipath-ready)

**Status:** proposal, for review. No code written yet.
**Scope now:** local HDD/SSD/NVMe. **Designed for** (not built now): true multipath / FC / iSCSI, i.e. asynchronous device appearance and random device ordering — see §8.
**Repos in scope:** `clevis-encryption-role` (owns the naming/discovery), `proxmox-install/…/proxmox_encrypted_storage` (ZFS consumer), `encrypted-storage-pool` (btrfs/LVM consumer).
**Related:** the crypttab UUID-collision guard already shipped in `clevis-encryption-role` (pre-flight assert + `files/crypttab-uuid-audit.sh` + `tasks/verify-crypttab.yml`). That guard stays as defense-in-depth; this migration removes the *root cause* it guards against.

---

## 1. Why, and what this does / does not fix

The reported incident (a ZFS mirror member `UNAVAIL` every boot) was proximately a **duplicate LUKS UUID in `/etc/crypttab`**. The deeper cause is that mapper names are derived from the **unstable kernel device-node name** (`crypt-nvme7n1`) and **re-derived on every apply**. When NVMe probe order reshuffles between a provision and a later re-apply, entries drift and duplicate/stale lines accumulate.

Naming mappers by the immutable **LUKS header UUID** makes the mapper name and the crypttab join key **1:1 and identical**, so:

- A duplicate-UUID collision becomes **structurally impossible** (two entries with the same UUID would be the same mapper name → one idempotent line).
- Re-applies are **idempotent by UUID** regardless of device-node reshuffling.
- The name↔disk binding **cannot drift** across reboots or re-applies.

**What this does NOT need to fix (verified in code):** pool durability. All three consumers assemble by **on-disk identity, not mapper name**:

| Consumer | Assembly mechanism | Name-dependent? |
|---|---|---|
| ZFS (`proxmox_encrypted_storage`) | `zpool import -d /dev/mapper -o cachefile=none <pool>` — GUID scan | **No** |
| btrfs (`encrypted-storage-pool`) | `btrfs device scan` + `LABEL=` mount — fs-UUID | **No** |
| LVM (`encrypted-storage-pool`) | `vgchange -ay <vg>` — PV-UUID metadata | **No** |

So **an existing pool re-assembles cleanly under the new mapper names with zero pool-side surgery**, and a **reboot is the natural cut-over point** (no export/import dance). This is what makes the migration tractable.

---

## 2. Target design

### 2.1 Naming
- Mapper name: `luks-<LUKS-UUID>` (e.g. `luks-50ca1601-5785-4ac0-b262-8cae7b29e011`). This is the systemd/anaconda-native convention.
- crypttab line: `luks-<uuid> UUID=<uuid> none luks,discard,noauto,nofail,_netdev,x-systemd.after=network-online.target`
  (field 1 == the UUID in field 2; redundant but explicit — field 1 is the dm name, field 2 is the source key.)
- systemd-escaped unit form (rarely needed; data disks are `noauto`/clevis-opened): `systemd-cryptsetup@luks\x2d<uuid>.service`.

### 2.2 The identity model (the crux — and what makes multipath tractable later)
Today the pipeline's interchange token is a **bare kernel device node** (`clevis_raw_disks: [nvme7n1]`, consumer `..._devices: [vdb]`). It is overloaded three ways — the `/dev/<node>` path, the mapper-name suffix, and reverse-derived by stripping `crypt-` — and it is the *least* stable identifier the kernel offers (it changes with probe order, and a multipath LUN has no single node at all). Every failure in this document traces back to that choice.

The fix is to stop using kernel names as identity and carry **two stable identities per disk, with a clear hand-off:**

| Identity | Form | Stable across | Used for |
|---|---|---|---|
| **Hardware id** (pre-LUKS) | `/dev/disk/by-id/…` — `nvme-<eui>`, `wwn-<…>`, `ata-<model>_<serial>`, and (future) `dm-uuid-mpath-<wwid>` | reboots, probe reorder, path failover | *selecting* and *formatting* a raw disk |
| **LUKS id** (post-LUKS) | header UUID → mapper `luks-<uuid>`, crypttab `UUID=<uuid>` | forever after format | mapper name, crypttab join, unlock/rotate/audit |

Hand-off: format the by-id device → read its LUKS UUID → thereafter reference it by `luks-<uuid>` / `/dev/disk/by-uuid/<uuid>`. Canonical per-disk record:

```
{ id: "/dev/disk/by-id/nvme-eui.0025…", uuid: "50ca1601-…", name: "luks-50ca1601-…" }
```

`tasks/validate-crypttab.yml` (from the guard work) already builds the `{dev, uuid, name}` shape as `clevis_crypttab_pairs`; this migration promotes `dev` from a bare node to a stable by-id path. Rules of thumb:
- Select/format/rotate a disk via its **by-id path** (or `/dev/disk/by-uuid/<uuid>` once formatted) — never `/dev/<kernel-name>`.
- Name mappers and write crypttab from the **LUKS UUID** → `luks-<uuid>`.
- **Consumers exchange full mapper paths** (`/dev/mapper/luks-<uuid>`), not bare nodes — no strip/re-prefix round-trip.

Why this matters beyond the rename: `luks-<uuid>` works identically whether the backing device is a local NVMe or a `/dev/mapper/mpathX`, and a by-id hardware id exists for every device class. Getting this model right **now** (local-only) is what makes the multipath/FC/iSCSI extension (§8) additive rather than a rewrite.

### 2.3 Discovery (local now; multipath-aware later)
Auto-discovery stays a **local-disk convenience**. Three changes make it correct and safe on the way to multipath:

0. **Read facts via `ansible_facts["devices"]`, not the top-level `ansible_devices`.** Ansible is phasing out injected `ansible_*` fact vars (`inject_facts_as_vars` heading to `false`); `ansible_facts["devices"]` is the durable form. The current discovery `set_fact` (`tasks/main.yml:102`) uses `ansible_devices` and must switch as part of this rework (see §3.1).
1. **Emit stable by-id paths, not bare kernel names.** The data is already in `ansible_facts["devices"][<dev>].links.ids`; pick a stable id per disk (prefer `nvme-eui`/`wwn-`, fall back to `ata-…-<serial>`).
2. **Refuse, don't mis-handle, multipath — loudly.** A path device is detectable by a non-empty `ansible_facts["devices"][<dev>].holders` pointing at a dm-mpath device (and `links.ids` containing `dm-uuid-mpath-…`). Until multipath is first-class, discovery must **exclude such paths and fail with a clear message** ("multipath device detected; set clevis_raw_disks explicitly by /dev/disk/by-id") rather than treating the N paths as N disks. (The UUID-collision guard is the backstop if this is bypassed — N paths → one LUKS UUID → it aborts.)

For SAN/multipath and any host with asynchronous device appearance, **explicit device lists (by stable id) are the supported path** — size-group auto-discovery is inherently unreliable when devices arrive late or a LUN is reachable by several nodes. The role already accepts a pre-set `clevis_raw_disks`; the change is that its entries become by-id paths.

### 2.4 Should device selection live in this role at all? (recommendation: no)

**Position: deprecate in-role auto-discovery; make an explicit device list the role's contract.** Choosing *which* physical devices become encrypted storage is a storage-topology / inventory decision — policy — whereas this role is the encryption *mechanism* ("encrypt the devices I'm given, bind Clevis, publish the unlock seam"). Reasons the heuristic doesn't belong here:

- **It's a destructive guess.** The role `luksFormat`s whatever it selects; a wrong guess destroys the wrong disk. A "largest size group" heuristic cannot be made correct in general (it already mis-handles multipath, mixed-size intentional layouts, large OS disks, SANs) — and for a destructive op, explicit beats implicit.
- **It's a second, divergent source of truth.** The consumers (`proxmox_encrypted_storage`, `encrypted-storage-pool`) own the pool topology and already derive their members from the crypttab this role writes. Selection should flow **one direction**: inventory declares the devices → this role encrypts them + writes crypttab → consumers read crypttab. An independent heuristic here can disagree with what the operator/consumer intends.
- **It's the untested, bug-prone corner.** Molecule pre-sets `clevis_raw_disks`, so discovery had zero coverage — which is exactly how the lexicographic-sort mis-selection survived. Removing it shrinks the role's risk surface.

**Target contract:** `clevis_raw_disks` is a required input (a list of stable `/dev/disk/by-id/...` identifiers), declared in inventory / host_vars by the caller (the "upstream users"). The role fails fast with a clear message if it is absent.

**Transition (enabled by the extraction in this PR):** the heuristic now lives isolated in `tasks/discover-disks.yml` behind the `when: clevis_raw_disks is not defined` include guard, so it can be staged out without touching the rest of the role:
1. *Now:* keep it as a clearly-labelled, opt-in, local-only convenience; emit a deprecation `warn` when it runs; refuse multipath loudly (§2.3).
2. *Later:* flip to required — remove the fallback (or gate it behind an explicit `clevis_allow_disk_autodiscovery: true`), so the default path is always an explicit inventory list.

This is a small, low-risk change precisely because the extraction already isolated it; it does not block the `luks-<uuid>` work and can land on its own.

---

## 3. Change inventory (from a full three-repo sweep)

### 3.1 `clevis-encryption-role` — production code (functional)

| File:line | Class | Change |
|---|---|---|
| `templates/clevis-unlock-data.sh.j2:42` | parse | case glob `crypt-*)` → `luks-*)`. **Single functional line** — `$name` is read from crypttab and used verbatim (L47/L66 already name-agnostic). |
| `tasks/configure-disk.yml:60` | construct | crypttab field 1 → `luks-{{ disk_uuid.stdout }}` (UUID already read at L33). |
| `tasks/configure-disk.yml:45` | match | `lineinfile regexp` → key on the UUID (`\bUUID=<uuid>\b`) or `^luks-<uuid>\s`. **Hazard:** a new-name regexp won't match a legacy `crypt-<dev>` line → orphaned line; pair with legacy-line removal (§4.3). |
| `tasks/configure-disk.yml:87,115` | construct | live-mapper probe/`NAME=` → `luks-<uuid>` (backing-device resolution at L126 already dynamic). |
| `tasks/provision-disk.yml:69,71,76,77,86` | construct | mapper name at luksOpen/close/guards/clevis-unlock. **Must read the LUKS UUID after `luksFormat`** (`cryptsetup luksUUID /dev/<dev>`) — not read there today. |
| `tasks/validate-crypttab.yml:39` | construct | `name` → `luks-<uuid>` (reorder so the uuid computed at L41-43 is available first). |
| `tasks/replace-disk.yml:48` | match | remove the **dead** disk's crypttab line. **Hazard:** can't rebuild the name from a bare node and can't `blkid` a removed disk. → match by operator-supplied old UUID, or prune orphan (§4.4). |
| `tasks/replace-disk.yml:56-60` | parse | re-derive the disk set from `/dev/mapper/crypt-*` by stripping. → grep `^luks-`; stop treating the suffix as a device node (§4.1). |
| `tasks/rotate-passphrase.yml:18-22` + `:64,73-74,86,97,111,121,130` | parse+construct | **deepest coupling:** strips `crypt-` to a bare node then uses it as `/dev/<node>` for luksAddKey/RemoveKey/clevis regen. → resolve each `luks-*` mapper to its backing device (or use `/dev/disk/by-uuid/<uuid>`) (§4.1). |
| `tasks/main.yml:98-102` | parse | discovery `set_fact` — rework to emit stable by-id paths + refuse multipath (§2.3), **and switch `ansible_devices` → `ansible_facts["devices"]`** (top-level fact injection is being removed). |
| `tasks/main.yml:104` | — | reject regex already lists **both** `luks-` and `crypt` → **no change** (open mappers stay filtered under either scheme). |
| `tasks/boot-ordering-dropins.yml`, `handlers/main.yml`, `tasks/verify-crypttab.yml`, `tasks/assert-crypttab-unique.yml`, `files/crypttab-uuid-audit.sh` | — | **no change** (already name-agnostic; the audit parses crypttab by field, `assert` operates on `clevis_crypttab_pairs`). |

### 3.2 `clevis-encryption-role` — tests & docs
- Molecule/manual: `molecule/default/prepare.yml:136,153,156,158`, `molecule/default/verify.yml:30,40,49`, `molecule/vm/verify.yml:89,96`, `manual_test/verify.yml:35,42` — assertions/opens hardcode `crypt-vdb`/`crypt-<item>`. The `luks-<uuid>` name isn't statically knowable from `[vdb]`, so rework to derive from crypttab or iterate `/dev/mapper/luks-*`.
- `tests/crypttab-guard/fixtures/*` — update fixture crypttab/pairs to `luks-<uuid>` names for realism (audit + assert are name-agnostic, so tests still pass either way, but should reflect reality).
- `README.md` — prose + the one escaped unit ref (`systemd-cryptsetup@crypt\x2dnvme7n1.service`, ~L827) and the manual-recovery examples (`crypt-<device>` at ~L229, L771, L828, L832).

### 3.3 `proxmox_encrypted_storage` (ZFS) — only 3 load-bearing sites
- `tasks/resolve-disks.yml:20` — `awk '/^crypt-/…sub(/^crypt-/…)'` → match `luks-` (and `crypt-` during transition) and **emit the full mapper name/path** (stop stripping to a node).
- `tasks/setup-pool.yml:108` — vdev spec builds `/dev/mapper/crypt-<node>`; → `/dev/mapper/<full-mapper-name>`.
- `tasks/replace-disk.yml:40,58` — `zpool status` grep + `/dev/mapper/crypt-<new>` for `zpool replace`.
- **No change:** `encrypted-storage-import.sh.j2:26`, `setup-pool.yml:39,60,143`, check script, `destroy-pool.yml:24` (reads back ZFS-reported paths), Proxmox registration (keyed on pool name). Molecule `verify.yml:87,94` + the `_disks: [vdb,vdc]` input contract need the new identity model.

### 3.4 `encrypted-storage-pool` (btrfs/LVM) — mirror of the ZFS consumer
- `tasks/resolve-disks.yml:16` — same regex+strip fix.
- `tasks/backends/btrfs.yml:14,35`, `tasks/backends/lvm.yml:20,40,49` — stop prepending `/dev/mapper/crypt-`; use `/dev/mapper/` + full mapper name.
- `molecule/vm/verify.yml:84` — assertion rework.
- **No change:** `encrypted-storage-assemble.sh.j2`, `encrypted-storage-check.sh.j2` (mount by LABEL / activate by VG — never reference the mapper name).

---

## 4. The six risk items and proposed approach

1. **Reverse-derivation break (`rotate-passphrase`, `replace-disk`, both consumers' `resolve-disks`).** Stripping `luks-` yields a UUID, not a device node. → Carry `(dev, uuid)` pairs (reuse `clevis_crypttab_pairs`); for device-level ops use `/dev/disk/by-uuid/<uuid>` (immutable) or resolve backing device via `cryptsetup status <name>` (pattern already in `configure-disk.yml:126`).
2. **Dead-disk crypttab-line removal (`replace-disk.yml:48`).** The removed disk can't be probed. → Add `clevis_replace_old_uuid` (operator-supplied) as the deterministic key; optionally offer an orphan-prune (remove any crypttab UUID present on no device — UUID-based, safe, but would also catch a merely-offline disk, so keep it opt-in). The guard's `crypttab-uuid-audit.sh` already *detects* the orphan.
3. **crypt-→luks- transition leaves orphaned old lines (`configure-disk.yml:45`).** A luks-keyed `lineinfile` won't replace the old `crypt-<dev>` line. → Add an explicit legacy-line removal (in `cleanup-legacy.yml` or a pre-step in `configure-disk`): for each disk, `lineinfile state=absent regexp=^crypt-<dev>\s`. Runs once; idempotent thereafter.
4. **Provisioning must learn the UUID (`provision-disk.yml`).** → After `luksFormat`, `cryptsetup luksUUID /dev/<dev>` (or `--uuid=` to pin at format), then open `-n luks-<uuid>`.
5. **Consumer input contract.** `_devices: [vdb, vdc]` (bare nodes) can't be prefixed into a valid mapper path. → Accept full mapper names or `/dev/mapper/...` paths; default (unset) derivation from crypttab returns full names. Document the contract change in both consumers' `defaults`/`argument_specs`/README.
6. **Mixed fleet during rollout.** → Consumers match `^(crypt|luks)-` and `clevis-unlock-data` can keep opening whatever crypttab lists; a half-migrated host stays bootable. Drop the `crypt-` branch after the whole fleet is migrated.

---

## 5. Cut-over runbook (per host)

Precondition: host healthy, pool ONLINE, maintenance window with a reboot allowed.

1. **Backup:** `cp -a /etc/crypttab /etc/crypttab.pre-luks-$(date +%s)` (and note current `zpool status -P`).
2. **Apply the new `clevis-encryption-role`** (`--tags systemd` is enough): rewrites crypttab to `luks-<uuid>`, removes legacy `crypt-` lines, regenerates `clevis-unlock-data` (`luks-*` glob) + boot-ordering. **Running `crypt-*` mappers are untouched** (data disks are `noauto`; the apply does not reopen them). Intermediate state — crypttab=`luks`, live mappers=`crypt`, pool imported on `crypt` paths — is consistent until reboot.
3. **Audit:** `crypttab-uuid-audit.sh` → expect clean (unique `luks-` entries, all UUIDs present).
4. **Apply the consumer role(s)** (ZFS and/or btrfs/LVM): resolve/create/replace paths now use full mapper names. Existing pool untouched (assembles by GUID/UUID). Import service already `-d /dev/mapper` (name-agnostic).
5. **Reboot.** On boot: `clevis-unlock-data` opens `luks-<uuid>` mappers → the pool's scan-import/`btrfs scan`/`vgchange` re-assembles by on-disk identity under the new paths → viability check → `…-ready.target`.
6. **Verify:** `crypttab-uuid-audit.sh` clean; `ls /dev/mapper/luks-*` present; `zpool status` (or `btrfs`/`lvs`) healthy on `luks-*`/`dm-uuid` paths; consumer ready-target active.

**Rollback (any step pre- or post-reboot):** restore `/etc/crypttab.pre-luks-*`, redeploy the previous role version, reboot. The pool re-imports by GUID/UUID under the old `crypt-*` names. Low risk because durability never depended on the name.

**Zero-reboot variant (advanced, not recommended for Proxmox):** stop guests → `zpool export` (or unmount btrfs / `vgchange -an`) → close `crypt-*` → reopen `luks-*` → re-import/scan. A reboot is cleaner on a dedicated box.

---

## 6. Test strategy
- **Device-free (CI):** update `tests/crypttab-guard` fixtures to `luks-<uuid>`; the audit + assert stay green. Add a case proving a re-apply after a simulated node-name reshuffle is a **no-op** under UUID naming (the payoff).
- **Tier-1 (`molecule/default`):** rework `prepare`/`verify` to open/assert by UUID (`blkid`→`luks-<uuid>`), proving crypttab + live mapper + discard land under the new name.
- **Tier-2 (`molecule/vm`) — the key one:** provision → assemble pool → **reboot** → verify unlock + pool across the seam, then **re-run the role and assert crypttab is unchanged** (idempotent by UUID). Add, if feasible, a second reboot with a forced device-node reshuffle to prove the pool still comes up (the whole point).
- **Consumers:** update their `molecule/vm` verify to derive `luks-*` names; confirm an existing pool re-imports after the rename.

---

## 7. Sequencing & effort

Phased, each phase shippable and fleet-safe on its own:

- **Phase 1 — `clevis-encryption-role`** (largest): naming in provision/configure/validate/unlock-template + the two hazards (replace, rotate) + legacy-line cleanup + tests + docs. This is the only repo that *must* change for the naming itself.
- **Phase 2 — consumers** (`proxmox_encrypted_storage`, `encrypted-storage-pool`): 3–5 call sites each + input-contract + tests. Can accept both prefixes, so they can be updated before or after Phase 1 hosts roll.
- **Phase 3 — fleet rollout**: per-host runbook (§5), one host first, then batch; drop the `crypt-` transition branch once complete.

Rough size: Phase 1 ≈ the bulk (6 task files + 1 template + tests + README); Phases 2 each ≈ a handful of lines + tests. Blast radius is wide but the individual edits are small and mostly mechanical once the `(dev, uuid)` model is in place.

---

## 8. Future extension: true multipath / FC / iSCSI (design target, not built now)

Scope now is local HDD/SSD/NVMe. This records what the eventual extension adds so Phase 1 is built to *accommodate* it, not rebuilt for it. Because identity is by-id + LUKS-UUID (§2.2) and mapper names are `luks-<uuid>`, the extension is additive:

- **Discovery branch.** Select the aggregate device (`/dev/disk/by-id/dm-uuid-mpath-<wwid>` / `/dev/mapper/mpathX`) and exclude its path devices via `holders`. WWID is the stable hardware id. LUKS is layered on the mpath device; `blkid` on it yields the LUKS UUID; open as `luks-<uuid>` — the crypttab/naming layer is unchanged.
- **Asynchronous device appearance.** iSCSI login and FC fabric scans make devices appear late and out of order:
  - *Apply time:* SAN hosts specify devices explicitly by by-id; size-group auto-discovery is not used (it races device appearance).
  - *Boot time:* the `clevis-unlock-data` retry loop already distinguishes "device missing" from "decrypt failed" and retries, which tolerates late appearance; add a `udevadm settle` and order unlock **after** `iscsid`/`open-iscsi` login and `multipathd` (`After=`), still in front of the `clevis-luks-unlocked.target` seam.
- **Random device ordering.** Already solved by the identity model — no kernel name is ever used as identity, so reorder/failover is transparent (by-id hardware id + `luks-<uuid>` + GUID/UUID pool assembly).
- **Boot-ordering chain (target):** `network-online` → `iscsid` login (`_netdev`) → `multipathd` assembles mpath → `clevis-unlock-data` opens `luks-<uuid>` → `clevis-luks-unlocked.target` → consumer import.
- **Test infra (deferred):** a molecule scenario with an iSCSI target (LIO/tgt) + `multipathd` exercising provision → unlock → pool across a reboot, plus a forced path-flap. This test lift is the main reason to defer the build.

## 9. Open decisions (need your call before Phase 1)

1. **Dead-disk removal in `replace-disk`:** add `clevis_replace_old_uuid` (deterministic, my recommendation) vs. opt-in orphan-prune vs. both?
2. **Pin the LUKS UUID at `luksFormat --uuid=` (deterministic, reproducible) vs. read it back after format (simpler)?**
3. **Keep the `crypt-` transition branch in consumers indefinitely, or set a removal milestone** (e.g. after the fleet is confirmed migrated)?
4. **Zero-reboot path:** document only, or actually implement the export/reopen/import `--tags migrate` flow for hosts where a reboot is expensive?
5. ~~**Naming literal.**~~ *Resolved:* `luks-<uuid>`. Multipath/FC/iSCSI have no stable bare node to key on, so the mapper name must come from the LUKS UUID; human-meaningful hardware identity is carried by the separate by-id id (§2.2), not the mapper name.
