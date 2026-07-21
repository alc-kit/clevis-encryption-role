# Migration & design plan: persistent `crypt-<LUKS-UUID>` mapper naming (local now, multipath-ready)

**Status:** gameplan LOCKED (§0), implementation starting. **Priority: HIGH** — a PCIe controller flap on `m-t-proxmox-06` (2026-07-20) re-exposed the pain of device-node-derived names.
**Scope now:** local HDD/SSD/NVMe. **Designed for** (not built now): true multipath / FC / iSCSI — async device appearance, random ordering (§8).
**Repos in scope:** `clevis-encryption-role` (owns naming/discovery), `proxmox-install/…/proxmox_encrypted_storage` (ZFS consumer), `encrypted-storage-pool` (btrfs/LVM consumer).
**Already shipped (PR #15, merged):** the crypttab UUID-collision guard (`files/crypttab-uuid-audit.sh`, pre-flight assert, `verify-crypttab.yml`), the `ansible_devices → ansible_facts["devices"]` swap, the numeric size-sort fix, and the discovery extraction (`tasks/discover-disks.yml`) + device-free tests. That guard stays as defense-in-depth; this work removes the *root cause*.

---

## 0. Locked gameplan (decisions)

1. **Mapper name = `crypt-<LUKS-UUID>`** (keep the `crypt-` prefix; the identity is the LUKS header UUID). Chosen over hardware-id (`crypt-SN_…`/`WWN_…`) because the LUKS UUID is the only identifier that is **still readable mid-incident** — during the 2026-07-20 flap, NVMe SMART/serial queries hung while the LUKS header (and its UUID via `blkid`) was still readable on the re-enumerated nodes — and it is immutable, universal (every device class), and **1:1 with the crypttab source key** (collision-proof, idempotent). Human/physical legibility (serials) is *recoverable* any time via `cryptsetup status` → `/dev/disk/by-id`; naming *stability* is not recoverable if the name is built on a source that vanishes under load. See the discussion trail; this reverses the earlier `luks-<uuid>` prefix only cosmetically — identity was always the LUKS UUID.
2. **Keeping the `crypt-` prefix is deliberate:** legacy `crypt-<node>` and new `crypt-<uuid>` **share the prefix**, so consumers' existing `^crypt-` matching already tolerates both — no dual-prefix logic. The only consumer fix is to **stop stripping `crypt-` to a device node** and use the full mapper name/path.
3. **Legacy migration = no resilver, and — for live-workload hosts — no reboot.** Rewrite crypttab (match old-*or*-new, write `crypt-<uuid>`, source stays `UUID=`), back it up. Preferred for live hosts: **`dmsetup rename`** the live mappers (§0.5). Simpler fallback (operator-scheduled maintenance window only): reboot. Either way ZFS re-imports by **pool GUID** (`zpool import -d /dev/mapper -o cachefile=none`), btrfs by **fs-UUID**, LVM by **PV-UUID** — path/name-agnostic → **zero resilver, zero data movement**.
4. **NEVER `zpool replace` for a rename.** `replace` = install-a-new-blank-device → forces a **full resilver** and does not diff the (identical) content. The no-resilver behavior lives in **import** (GUID match) and **online** (`offline→online` → small DTL delta only). Use those.
5. **`dmsetup rename crypt-<node> crypt-<uuid>` is the preferred live migration:** renames the running mapper with no I/O interruption and no resilver (ZFS keeps its open handle by dev-number; crypttab is updated for persistence; the stale on-disk path label self-corrects on the next operator-planned import/boot). Per disk, atomic.
6. **NEVER automated reboots.** Live workloads must be drained/managed by the operator first. Any reboot (migration fallback, or clearing a wedge) is an **operator-initiated, workload-managed** action — never triggered by the role or a watchdog.
7. **Both schemes coexist as READ-tolerance during transition; a disk is only ever OPEN under one name.** Two dm-crypt mappers over one LUKS backing = corruption. Cutover is **atomic per disk**; a pool may be a mix of old/new-named vdevs mid-migration (fine — matched by on-disk id).
8. **Producer/consumer contract (§2.4): the caller owns the device list; clevis is a pure enriching function; the contract is a naming *convention*, not a file.** The caller/inventory provides the list as stable `/dev/disk/by-id` ids; clevis LUKS-formats each and returns the list enriched with its `crypt-<uuid>` name (an ephemeral in-play fact — **no host file**). The authoritative, always-derivable contract is the rule `mapper = crypt-<LUKS-UUID>`. Consumers derive their encrypted members from their *own* list and decide *all* topology. In-role auto-discovery is **retired**.
9. **Self-healing (§10): live reconcile only, split along the `clevis-luks-unlocked.target` seam.** clevis-encryption-role owns the LUKS half (device-appearance-triggered re-unlock), the ZFS/btrfs/LVM consumer owns the storage re-attach half (non-disruptive; ZED for ZFS). They rendezvous on the reappeared `/dev/mapper/crypt-<uuid>` — no direct cross-repo calls. When redundancy is lost (pool suspended/wedged), reconcile **stands down**: detect + alert, leave the reboot to the operator. Persistent naming is the prerequisite (stable rendezvous path) but does not untangle a held/suspended pool.

---

## 1. Why, and what this does / does not fix

Mapper names are derived from the **unstable kernel device-node** (`crypt-nvme7n1`) and **re-derived on every apply**. When probe order reshuffles (a reboot, or a controller flap: `nvme2n1`→`nvme2n2` on 2026-07-20), entries drift, stale/duplicate lines accumulate, and `zpool status`/mappers reference nodes that no longer exist. Naming by the immutable **LUKS UUID** makes the name 1:1 with the crypttab key: collisions become structurally impossible, re-applies are idempotent, and the name never lies about a node.

**What this does NOT fix:** pool durability (already GUID/UUID-based — see §0.3), the underlying hardware fault, or the runtime *wedge* when a pool suspends with ZFS holding dead mappers (§10 boundary).

---

## 2. Target design

### 2.1 Naming
- Mapper name: `crypt-<LUKS-UUID>` (e.g. `crypt-50ca1601-5785-4ac0-b262-8cae7b29e011`).
- crypttab line: `crypt-<uuid> UUID=<uuid> none luks,discard,noauto,nofail,_netdev,x-systemd.after=network-online.target` (field 1 = dm name from the LUKS UUID; field 2 = the source key, unchanged — the incident confirmed UUID-keyed source is correct and survives node renaming).
- Computed **once** at provision/migration and persisted in crypttab; **never recomputed from live facts on later runs** (crypttab is authoritative — avoids any recompute churn).

### 2.2 The identity model
The pipeline's interchange token was a **bare kernel device node** — overloaded as the `/dev/<node>` path, the mapper-name suffix, and reverse-derived by stripping `crypt-`. Replace it with **two stable identities per disk**:

| Identity | Form | Used for |
|---|---|---|
| **Hardware id** (pre-LUKS) | `/dev/disk/by-id/…` (`nvme-eui`, `wwn-`, `ata-…-serial`; future `dm-uuid-mpath-<wwid>`) | *selecting* and *formatting* a raw disk |
| **LUKS id** (post-LUKS) | header UUID → mapper `crypt-<uuid>`, crypttab `UUID=<uuid>` | mapper name, crypttab join, unlock/rotate/audit |

Hand-off: format the by-id device → read its LUKS UUID → thereafter reference by `crypt-<uuid>` / `/dev/disk/by-uuid/<uuid>`. `tasks/validate-crypttab.yml` already builds the `{dev, uuid, name}` shape as `clevis_crypttab_pairs`. Rules: select/format/rotate via **by-id path** (or by-uuid once formatted), never `/dev/<kernel-name>`; name mappers and write crypttab from the **LUKS UUID**; consumers exchange **full mapper paths**, not bare nodes.

### 2.3 Discovery — retired
Auto-discovery does not belong in this role (§2.4): the device list always comes from the caller. `tasks/discover-disks.yml` (extracted + hardened in PR #15 — `ansible_facts["devices"]`, numeric size-sort, device-free tests) is therefore **retired**: emit a deprecation `warn` when it runs, then remove it. No more "which disks?" heuristic, no in-role multipath detection (multipath identity is just a `by-id` form in the caller's list — see §2.4).

### 2.4 Producer/consumer contract (encrypted devices) — topology-free, file-free

**Roles**
- **Caller (inventory / site playbook)** owns the device list — the *separated root hardware devices*, as stable `/dev/disk/by-id/…` ids. Choosing which disks are encrypted is inventory policy; in-role auto-discovery is retired (the list always comes from the caller).
- **clevis-encryption-role is a pure enriching function** over that list: given `[hardware devices]` it LUKS-formats + Clevis-binds + opens each as `crypt-<LUKS-UUID>`, writes crypttab, and returns the list **enriched** with each device's paired encrypted name. It invents no list and decides no topology.
- **The consumer** (`proxmox_encrypted_storage` / `encrypted-storage-pool` / any framework) takes the encrypted devices and does whatever it likes — partition them, join partitions across devices, mirror/stripe/raidz. It derives its encrypted members from *its own* provided list.

**The contract is a naming convention, not an artifact.** The one durable rule:
> a device's encrypted name is `crypt-<its-LUKS-UUID>` — mapper `/dev/mapper/crypt-<uuid>`, crypttab source `UUID=<uuid>`.

Given that rule and a hardware device, the pairing is *derivable*: `mapper(x) = /dev/mapper/crypt-$(blkid -s UUID -o value x)`. So the mapping is **never stored**. The only persisted artifacts are the ones that must exist anyway — the on-disk LUKS header, the crypttab line, the open mapper. **No `encrypted-devices.json` or any spare file:** a stored mapping is just a cache of a pure function and a guaranteed source of drift/rot.

**Enrichment is in-band and ephemeral.** clevis returns the enriched list as a per-play Ansible fact `clevis_encrypted_devices = [{hardware: <by-id>, luks_uuid, mapper: /dev/mapper/crypt-<uuid>}]` — in memory, no file. It is a *convenience* for the common composed case (the consumer runs right after clevis in one play). Nothing may *depend* on it: a standalone consumer re-derives the identical pairing from its own by-id list via the convention. One authoritative truth (convention + live devices); one optional shortcut (the fact).

**Transport lives in one column only.** The `hardware` id is the sole place local/remote/multipath identity appears (local → `nvme-eui`/`wwn-`; multipath → `dm-uuid-mpath-<wwid>`). Everything downstream references the transport-neutral `mapper`. Assembly is transport-agnostic; selection uses the transport-uniform `by-id`.

**Validation.** A consumer that lists a device with no LUKS UUID (clevis never encrypted it) must **fail loudly** — "you asked for a device that isn't an encrypted member."

**Work items.**
- clevis: accept the caller's `/dev/disk/by-id/…` list as `clevis_raw_disks`; provision/`blkid` via those paths; publish the ephemeral `clevis_encrypted_devices` fact; retire `discover-disks`.
- consumers: derive members from their *own* by-id list (via the convention, or the fact when composed); keep their own topology. The reintroduced consumer "device list" is the caller's by-id subset — **never bare nodes, never a topology schema clevis defines**. (This supersedes the earlier "deprecate the consumer list" idea: the list is not deprecated, it is the caller's by-id subset selector.)
- No host files introduced anywhere.

---

## 3. Change inventory (three-repo sweep; naming = the `crypt-<uuid>` work)

### 3.1 `clevis-encryption-role` — production code
| File:line | Class | Change |
|---|---|---|
| `templates/clevis-unlock-data.sh.j2:42` | parse | case glob stays `crypt-*)` — **no change** (both old and new names share the prefix; `$name` is read from crypttab verbatim). |
| `tasks/configure-disk.yml:60` | construct | crypttab field 1 → `crypt-{{ disk_uuid.stdout }}` (UUID already read at L33). |
| `tasks/configure-disk.yml:45` | match | `lineinfile regexp` → match the disk's **LUKS UUID in the source** (`\bUUID=<uuid>\b`), so it replaces *either* an old `crypt-<node>` line *or* a `crypt-<uuid>` line for that same volume. Register the change → set `disk_crypttab_changed` (consumers use it to decide migration). |
| `tasks/configure-disk.yml:87,115` | construct | live-mapper probe/`NAME=` → `crypt-<uuid>` (backing-device resolution at L126 already dynamic). |
| `tasks/provision-disk.yml:69,71,76,77,86` | construct | mapper name at luksOpen/close/guards/clevis-unlock. **Read the LUKS UUID after `luksFormat`** (`cryptsetup luksUUID /dev/<dev>`). |
| `tasks/validate-crypttab.yml:39` | construct | `name` → `crypt-<uuid>` (reorder so the uuid is available first). |
| `tasks/replace-disk.yml:48` | match | remove the **dead** disk's line by its recorded LUKS UUID (`clevis_replace_old_uuid`), not by node. |
| `tasks/replace-disk.yml:56-60` | parse | re-derive the disk set from open mappers → carry `(dev, uuid)` pairs, not stripped node names (§4.1). |
| `tasks/rotate-passphrase.yml:18-22`, `:64…130` | parse+construct | **deepest coupling:** stops stripping `crypt-` to a node used as `/dev/<node>`. → resolve each mapper's backing device via `cryptsetup status` or `/dev/disk/by-uuid/<uuid>`. |
| `tasks/cleanup-legacy.yml` | new | one-time legacy-line reconciliation: for each managed UUID, ensure exactly one `crypt-<uuid>` line, remove any stale `crypt-<node>` line for the same UUID (backed up first). |

### 3.2 Tests & docs (this role)
`molecule/default` + `molecule/vm` + `manual_test` verifies hardcode `crypt-<node>`; rework to derive the name from crypttab / iterate `/dev/mapper/crypt-*` (the `<uuid>` isn't statically knowable from `[vdb]`). Update README recovery examples.

Both consumers follow the §2.4 contract: `resolve-disks` derives members from the **caller's own `by-id` list** — `blkid <by-id>` → `crypt-<uuid>` mapper (the naming convention), or read the ephemeral `clevis_encrypted_devices` fact when composed. The crypttab-derive-*all* path stays only as the no-list convenience. Topology stays the consumer's.

### 3.3 `proxmox_encrypted_storage` (ZFS)
- `resolve-disks.yml` — resolve from the caller's by-id list per §2.4 → full `/dev/mapper/crypt-<uuid>` paths; fail loudly on a listed device with no LUKS UUID. Stop stripping `crypt-` to a node.
- `setup-pool.yml` — vdev spec consumes the resolved full mapper paths.
- `replace-disk.yml` — `zpool status` grep + replace target by full mapper path.
- **Add:** a state-aware migration task (§0.3/§10) — detect old-named vdevs, migrate via `dmsetup rename` (live, preferred) or an operator-scheduled reboot; **never `zpool replace`** for a pure rename.
- No change: import/scan (`-d /dev/mapper`, `cachefile=none`), destroy (reads ZFS paths), Proxmox registration (pool name).

### 3.4 `encrypted-storage-pool` (btrfs/LVM)
- `resolve-disks.yml` — same §2.4 by-id-derive → full mapper paths. (The earlier deprecation-warning commit on `feat/crypt-uuid-consumer` is superseded by this and must be reworked to the by-id-derive model.)
- `backends/btrfs.yml`, `backends/lvm.yml` — consume the resolved full mapper paths (drop the `crypt-` re-prefix).
- Boot assembly needs nothing (mounts by LABEL / activates by VG — name-agnostic). The `molecule/rename` scenario (validated) proves the live-rename mechanism.

---

## 4. Risk items
1. **Reverse-derivation break** (`rotate-passphrase`, `replace-disk`, consumers' `resolve-disks`): carry `(dev, uuid)` pairs; device-level ops via `/dev/disk/by-uuid/<uuid>` or `cryptsetup status` backing-device resolution.
2. **Dead-disk line removal** (`replace-disk`): use operator-supplied `clevis_replace_old_uuid` (deterministic); the audit already *detects* orphans.
3. **Legacy line handling**: match on the UUID source so the rewrite replaces an old `crypt-<node>` line for the same volume in place — no orphan, no dup. `cleanup-legacy.yml` sweeps any leftover.
4. **Provisioning learns the UUID**: `cryptsetup luksUUID` after format (or `--uuid=` to pin).
5. **Consumer input contract**: accept full mapper names/paths; default derivation from crypttab returns full names.
6. **Never two open mappers on one disk** (§0.6) — corruption.

---

## 5. Cut-over runbook (per host) — no resilver; no reboot for live hosts

Precondition: host healthy, pool `ONLINE`. Common steps 1–4, then pick Path A (live) or Path B (operator-scheduled window).

1. **Backup:** `cp -a /etc/crypttab /etc/crypttab.pre-cryptuuid-$(date +%s)`; note `zpool status -P`.
2. **Apply the new `clevis-encryption-role`** (`--tags systemd`): rewrites crypttab to `crypt-<uuid>` (UUID-source match → replaces the old `crypt-<node>` line in place), reconciles legacy lines, regenerates boot-ordering. Running mappers are **untouched** (data disks are `noauto`).
3. **Audit:** `crypttab-uuid-audit.sh` → clean (unique `crypt-<uuid>` entries, all UUIDs present).
4. **Apply consumer role(s):** resolve/create/replace now use full mapper names. Existing pool untouched.

**Path A — live, no reboot (preferred for hosts with running workloads):** per disk, atomically `dmsetup rename crypt-<node> crypt-<uuid>`. The running mapper keeps serving (ZFS/btrfs/LVM hold it by dev-number); no resilver, no I/O interruption. crypttab (step 2) already carries the new name for persistence; ZFS's stale on-disk path label self-corrects at the next operator-planned import. Verify after each: `zpool status`/`lsblk` still healthy.

**Path B — operator-scheduled maintenance window (simpler):** drain/stop the tenant workloads, then reboot. `clevis-unlock-data` opens `crypt-<uuid>` mappers; ZFS/btrfs/LVM re-attach by GUID/fs-UUID/PV-UUID — **no resilver**. Never automate this reboot (§0.6).

5. **Verify:** audit clean; `ls /dev/mapper/crypt-*`; `zpool status` (or `btrfs`/`lvs`) healthy; consumer `…-ready.target` active.

**ZFS import paths:** discovery is via `-d /dev/mapper` (the pool lives on dm-crypt devices); `cachefile=none` guarantees a fresh **GUID scan** each import, never a replay of pinned old paths. (Persistent config lives in `ZPOOL_IMPORT_PATH` / `/etc/default/zfs`; default with no `-d` is a libblkid enumeration.)

**Rollback:** restore `/etc/crypttab.pre-cryptuuid-*`, redeploy the previous role version; re-attach by GUID under the old names (Path A: `dmsetup rename` back; Path B: reboot in a managed window). Low risk — durability never depended on the name.

---

## 6. Test strategy
- **Device-free (CI):** `tests/crypttab-guard` + a new case proving a re-apply after a simulated node reshuffle is a **no-op** under UUID naming (the payoff).
- **Tier-1 (`molecule/default`):** open/assert by UUID (`blkid`→`crypt-<uuid>`).
- **Tier-2 (`molecule/vm`) — key:** provision → assemble → **reboot** → verify unlock + pool across the seam; then **re-run and assert crypttab unchanged** (idempotent). If feasible, a second reboot with a forced node reshuffle to prove re-attach (the whole point).
- **Consumers:** verify an existing pool re-imports after the rename; verify the migration task on an old-named pool.

---

## 7. Sequencing
- **Phase 1 — `clevis-encryption-role`**: `crypt-<uuid>` naming in provision/configure/validate + `disk_crypttab_changed` + legacy-line reconcile + rotate/replace rework + tests + docs.
- **Phase 2 — consumers**: stop-stripping fix + full-mapper-path + the state-aware migration task (§3.3/§10) + tests.
- **Phase 3 — fleet rollout**: per-host runbook (§5), one host first; drop the transition tolerance once the fleet is fully `crypt-<uuid>`.

---

## 8. Future extension: multipath / FC / iSCSI (design target)
Additive because identity is by-id + LUKS-UUID and names are `crypt-<uuid>`: a discovery branch that selects the mpath aggregate (`dm-uuid-mpath-<wwid>`) and excludes its paths (`holders`); tolerance for **async device appearance** (apply-time explicit by-id lists; boot-time `udevadm settle` + order after `iscsid`/`multipathd`); ordering chain `network-online → iscsid → multipathd → clevis-unlock-data → clevis-luks-unlocked.target → consumer`. Deferred test lift: a molecule scenario with an iSCSI target + `multipathd` + a path-flap.

---

## 9. Open decisions
1. **Dead-disk removal in `replace-disk`:** confirm `clevis_replace_old_uuid` (deterministic) — recommended.
2. **UUID origin:** `luksFormat --uuid=` (pin, reproducible) vs. read-back — *lean read-back* (simpler; UUID is stable once set).
3. ~~**Auto-discovery end state.**~~ *Resolved (§2.4):* the caller owns the by-id device list; in-role auto-discovery is **retired** (`discover-disks` gets a deprecation `warn`, then removal).
7. ~~**Producer/consumer contract.**~~ *Resolved (§2.4):* caller owns the by-id list; clevis is a pure enriching function returning an ephemeral `clevis_encrypted_devices` fact; the authoritative contract is the convention `mapper = crypt-<LUKS-UUID>` (always derivable, **no host file**); consumers derive their members from their own list and own all topology.
4. ~~**Naming.**~~ *Resolved (§0.1):* `crypt-<LUKS-UUID>`.
5. ~~**Migration mechanism.**~~ *Resolved (§0.3–0.6):* no resilver; **`dmsetup rename` (live, no reboot) preferred** for hosts with running workloads; operator-scheduled maintenance-window reboot as the simpler fallback; **never `zpool replace`**; **never automate a reboot**.
6. ~~**Self-healing scope.**~~ *Resolved (§10):* build **Tier-1 live reconcile** (split along the seam — LUKS half here, storage half in the consumer via ZED). **Tier-2 = detect + alert only, NO auto-reboot** (`failmode=panic`/watchdog rejected). Reboots are always operator-initiated after workload management.

---

## 10. Self-healing / runtime reconciliation (make it more than a boot process)

**Goal:** recover from a controller flap (devices vanish, reappear at new nodes) without a manual full reboot, as far as is *physically* possible.

**What persistent naming buys here:** the re-open is deterministic — `clevis-unlock-data` opens each device by `UUID=` (→ `/dev/disk/by-uuid` → current node) under its stable `crypt-<uuid>` name, regardless of how nodes reshuffled, and re-runs never drift. It is the *prerequisite* for reliable "restart the unit and it comes back." It does **not**, by itself, untangle a wedged pool.

**The honest boundary (from the 2026-07-20 incident).** When redundancy is lost *all at once* — all 6 drives dropped → a full mirror gone → pool **SUSPENDED**, and ZFS holds the dead mappers open (`cryptsetup status` → `device: (null)`; `dmsetup remove` → "Device or resource busy") — the stack **cannot be untangled at runtime**: `luksClose` fails (busy), `zpool export` fails (suspended). No naming scheme or unit restart changes this; it's a ZFS-holds-dead-device + suspended-pool deadlock. **Only a reboot clears it.** Persistent naming makes that reboot recovery *clean and deterministic*, but does not remove the reboot for a total-redundancy-loss event.

**Tier 1 — redundancy preserved (transient / partial flap; pool stays ONLINE/DEGRADED): self-heal live.**
A device-appearance-triggered reconcile (udev rule / systemd `.device` or path unit, not just boot):
1. tear down any stale `device:(null)` mapper **iff not busy**;
2. `clevis-unlock-data` re-opens the device by UUID under `crypt-<uuid>`;
3. poke the consumer to re-attach — `zpool online`/`clear`, `btrfs device scan`, `vgchange -ay` — **gated on the pool not being suspended**.
This converts the common case (one bay blips, mirror partner keeps serving) from a manual intervention into automatic recovery. Guard rails: never force-remove a busy mapper, never re-attach to a suspended pool (do no harm).

**Tier 2 — redundancy lost / pool suspended / wedged: NOT live-recoverable, and we do NOT auto-reboot.**
Live workloads must be drained/managed by a human before any reboot, so the reconcile **stands down**: detect the wedge, log it, and **alert loudly** (a failed/monitored unit state, a journal marker). It takes no destructive action and never reboots. Clearing the wedge — drain the tenant, then reboot into the deterministic `crypt-<uuid>` recovery — is an explicit operator decision. (`failmode=panic` + watchdog is deliberately **rejected** for the same reason.)

### 10.1 Ownership — split along the `clevis-luks-unlocked.target` seam (same boundary as boot)

The reconcile is the boot flow re-shaped around a device event, so it splits on the same boundary:

- **`clevis-encryption-role` — the LUKS half.** A device-appearance trigger (udev rule / systemd `.device` unit on `crypto_LUKS` add) → tear down a stale `device:(null)` mapper *iff not busy* → re-run `clevis-unlock-data` (already idempotent) to open the device by UUID as `crypt-<uuid>` → (re)reach `clevis-luks-unlocked.target`. It **never** runs `zpool`/`btrfs`/`vgchange`.
- **`proxmox_encrypted_storage` / `encrypted-storage-pool` — the storage half.** Notice the expected `/dev/mapper/crypt-<uuid>` reappear → re-attach the member **non-disruptively**: for ZFS prefer native **ZED** auto-online (built for "the vdev's device came back"), else a health-gated `zpool online`/`clear`; btrfs `device scan`; LVM `vgchange -ay`. It **never** runs cryptsetup/clevis, never `export`/reimports live, never acts on a suspended pool.
- **Rendezvous on the artifact, not by direct calls.** clevis produces the open mapper at the stable `/dev/mapper/crypt-<uuid>` path (persistent naming is what makes that path predictable); the consumer keys off it appearing — exactly as it already derives members from crypttab/mappers. clevis has no knowledge of the consumer; the seam remains the only contract, which keeps this role NBDE-only and reusable across all three storage backends.

**Do-no-harm invariants (both halves):** never force-remove a busy mapper; never re-attach to a suspended pool; every action must be additive (restore redundancy) and safe against the running workload.
