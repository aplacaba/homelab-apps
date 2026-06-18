# Backup Strategy Implementation Plan

> **Status: Design / pending a storage check (P1).** Local-only strategy. Verify
> the ZFS pool redundancy (§2 P1) first — it gates whether the snapshot/vzdump
> layer alone is sufficient or whether a second physical copy is mandatory.

**Goal:** A local-only backup strategy for the single-VM k3s cluster that protects
against user error, bad updates, corruption, and ransomware — with instant
rollback — without offsite/cloud copying (accepted: total box loss is not covered).

**Architecture:** Three local layers, all host-side or in-cluster:
1. **ZFS snapshots (sanoid)** on every dataset — instant rollback, the workhorse.
2. **App DB dumps (k8s CronJobs)** → NFS PVCs, so snapshots catch consistent copies.
3. **Proxmox `vzdump`** of the VM → a local backup dataset — bare-metal node recovery.

Scope explicitly **excludes** offsite (cloud/restic/B2) and protecting the 8 TB
media library beyond local snapshots (it's re-acquirable via arr).

---

## 1. Scope & decisions

| Aspect | Decision |
|--------|----------|
| Strategy | **Local-only**, layered (snapshots + dumps + VM backup) |
| Offsite | ❌ none (accepted risk: box loss = data loss) |
| Media (8 TB) | Local snapshots only (re-acquirable via arr) |
| Photos (Immich) | Local snapshots, longest retention (irreplaceable, but no offsite) |
| Snapshot tool | **sanoid** (policy-driven ZFS snapshot automation on the host) |
| DB dumps | k8s **CronJobs** (Forgejo + Immich `pg_dump`, k3s SQLite `.backup`) → NFS PVC |
| VM backup | Proxmox **`vzdump`** → local dataset |
| Second physical copy | **Conditional on P1** — required if the pool isn't mirrored |

**What this protects against / doesn't:**

| Scenario | Covered? |
|----------|----------|
| Accidental deletion / bad arr reorg | ✅ ZFS rollback |
| Botched upgrade / bad config | ✅ ZFS rollback + git revert |
| Ransomware | ✅ snapshots are read-only/immutable |
| DB corruption | ✅ `pg_dump` + snapshots |
| Single disk failure | ⚠️ **only if pool is mirrored** (P1) |
| Total box loss (fire/theft/hardware death) | ❌ accepted |

## 2. Prerequisites & blockers

| # | Item | Blocks | How |
|---|------|--------|-----|
| P1 | **Check ZFS pool redundancy** | snapshot sufficiency | `zpool status` on the host. If mirrored/raidz → snapshots on the same pool are safe. **If single-disk → a disk failure takes data + all snapshots + vzdump; a second physical copy (syncoid → USB, or add a mirror) becomes mandatory.** |
| P2 | Provision a `tank/backup` dataset for `vzdump` output | VM backup | carve on the 12 TB pool (with a `refquota`), or a dedicated backup disk |
| P3 | Create a `tank/dumps` dataset for app DB dump output | CronJob dumps | NFS-exported to the VM; mounted as a PVC |

## 3. Layer 1 — ZFS snapshots (sanoid)

**Tool:** [sanoid](https://github.com/jimsalterjrs/sanoid) on the Proxmox host.
Policy-driven, declarative (`/etc/sanoid/sanoid.conf`), handles creation +
pruning + (optionally) replication via `syncoid`.

**Policy (per dataset, tiered by replaceability):**

| Dataset | Frequent (15m) | Hourly | Daily | Weekly | Monthly | Yearly |
|---------|----------------|--------|-------|--------|---------|--------|
| `tank-immich/immich` (photos — irreplaceable) | 4 | 24 | 14 | 8 | 12 | 2 |
| `tank/media` (media — re-acquirable) | — | 6 | 7 | 4 | — | — |
| `tank/llm-models` (re-downloadable) | — | — | 3 | — | — | — |
| `tank/backup` (vzdump targets) | — | — | 4 | — | — | — |
| `tank/dumps` (DB dumps) | — | 6 | 7 | — | — | — |

Photos get the deepest retention; models/media get shallow (cheap to regenerate).
Snapshots are instant and consume only changed blocks.

**Conditional replication (only if P1 = single-disk):**
```bash
# syncoid: send snapshots to an external USB pool, run weekly, unplug after
syncoid tank-immich/immich usb-backup/immich
syncoid tank/media         usb-backup/media
```
Unplugging after each run gives a poor-man's air gap against ransomware.

## 4. Layer 2 — App DB dumps (k8s CronJobs)

A live PostgreSQL over NFS isn't crash-consistent at the ZFS-snapshot instant, so
dump first, then let snapshots catch the dump file.

| Job | Schedule | Command | Output |
|-----|----------|---------|--------|
| Forgejo PG dump | nightly 02:00 | `pg_dump -Fc` of the forgejo DB | `tank/dumps/forgejo/` |
| Immich PG dump | nightly 02:30 | `pg_dump -Fc` of the immich DB | `tank/dumps/immich/` |
| k3s SQLite backup | nightly 03:00 | `sqlite3 state.db ".backup ..."` | `tank/dumps/k3s/` |
| SealedSecrets key | one-time | copy `~/sealed-secrets-key-backup.yaml` | `tank/dumps/sealed-secrets/` (then snapshot) |

Each runs as a k8s `CronJob` writing to an NFS-mounted PVC (so the file lands on
ZFS → covered by `tank/dumps` snapshots). Retention handled by sanoid's
`tank/dumps` policy. These are tiny (MBs–low GBs).

> Note: the SealedSecrets master key is also kept offline (per AGENTS.md). Adding
> it to `tank/dumps` gives a snapshotted on-box copy; the offline copy remains
> the real DR artifact.

## 5. Layer 3 — Proxmox VM backup (`vzdump`)

- **What:** whole-VM backup of the k3s node (OS, k3s SQLite, container images,
  in-VM state). Compressed archive on `tank/backup`.
- **Schedule:** weekly (e.g. Sunday 04:00), after the DB dumps/snapshots.
- **Mode:** snapshot-based (ZFS) for crash-consistency.
- **Restores:** the entire node without reinstalling k3s — complements Flux/git
  (which re-creates the *workloads* but not the running node itself).
- **Remember:** `vzdump` covers the **VM disk only**. The NFS-backed data
  (media/photos/models) is covered by sanoid, not by `vzdump`.

## 6. Restore procedures (test these once built)

| Loss | Restore from |
|------|--------------|
| Accidental file deletion / bad arr reorg | `zfs rollback tank/media@snapshot` (instant) |
| Corrupted Immich/Forgejo DB | restore the `pg_dump` from `tank/dumps/...` |
| Bad cluster upgrade | `zfs rollback` the relevant dataset + `git revert` in Flux |
| VM won't boot / node dead | Proxmox restore from the latest `vzdump` |
| Total box loss | ❌ not recoverable (accepted — local-only) |

## 7. Risks & gotchas

1. **Single-disk pool is a false sense of security** — data + all snapshots + the
   `vzdump` share one disk's fate. If P1 shows no redundancy, the syncoid→USB
   weekly copy (or adding a mirror) is the single highest-value action. (§2 P1, §3)
2. **No offsite = no box-loss protection** — photos are irreplaceable and would be
   lost in a total failure. Accepted; revisit if the photos library grows to
   something you truly can't lose (then add cheap B2 for just the photos, ~$3/mo).
3. **DB dumps before snapshots** — schedule dumps to finish *before* the daily
   snapshot window so snapshots always capture a consistent dump. (§4)
4. **`vzdump` ≠ data backup** — it only covers the VM disk. Don't mistake a green
   vzdump for protected media/photos. (§5)
5. **Snapshot retention eats space** — photos' deep retention (yearly) holds
   changed blocks for a long time; monitor `zfs list -o space` and trim if the
   pool fills.
6. **Ransomware reaches snapshots if it has host root** — snapshots are
   immutable from the VM, but a compromised Proxmox host could destroy them. The
   syncoid→USB-unplugged copy (§3) is the only true air gap in this design.

## 8. Open decisions

1. **Pool redundancy (P1)** — mirrored/raidz, or single-disk? Determines whether
   the optional syncoid→USB layer is mandatory.
2. **sanoid deployment** — install directly on the Proxmox host, or run in a
   dedicated LXC/VM? (Host-direct is simplest.)
3. **vzdump target** — `tank/backup` on the 12 TB pool, or a dedicated backup
   disk? (Same-pool shares the failure domain; dedicated disk is safer.)
4. **Photo retention depth** — confirm the sanoid policy for `tank-immich/immich`
   matches how far back you want rollback.

## 9. Target changes (when built)

This plan is mostly **host-side + a few CronJobs**:
- Host: install sanoid, `/etc/sanoid/sanoid.conf`, optional syncoid cron.
- Host: create `tank/backup` + `tank/dumps` datasets, NFS-export `tank/dumps`.
- Proxmox: configure weekly `vzdump` of the k3s VM → `tank/backup`.
- Repo: add `clusters/pk3s/<app>/cronjob-backup.yaml` for the DB dumps (Forgejo,
  Immich, k3s SQLite), each writing to the dumps PVC.
- AGENTS.md: add a Backup section documenting the three layers + restore recipes.
