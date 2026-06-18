# Proxmox Single-VM Foundation Plan

> **Status: Design / pending execution.** This is the foundation plan that the
> `arr-stack` and `local-llm` plans build on. Resolve §2 prerequisites, then
> execute the phased build in §7. No cluster manifests are written until the VM
> and passthrough are in place.

**Goal:** Collapse the existing 3-node k3s cluster (3 small Proxmox VMs) into a
single high-spec VM on the repurposed media-server box, with the Intel Arc B580
passed through for Jellyfin transcode + the local LLM. This VM becomes the
foundation for the arr-stack, local-llm, Immich, and a general DB.

**Architecture:** One Proxmox VM runs single-node k3s (SQLite datastore, no etcd)
with all workloads. The B580 is PCI-passthrough'd into the VM. Media stays on the
host's 12 TB ZFS pool (NFS-exported); Immich gets the dedicated 4 TB reserve disk
as its own isolated zpool. Flux reconciles all workloads from this GitOps repo.

**Tech Stack:** Proxmox VE, k3s (single-node, SQLite), Flux Operator, ZFS, NFS,
Traefik IngressRoute CRD, SealedSecrets.

---

## 1. Hardware & decisions

| Aspect | Detail |
|--------|--------|
| **Physical box** | 10th-gen Intel, 10 cores / 20 threads, **32 GB RAM** (staying), Intel Arc **B580** (12 GB VRAM), **12 TB** ZFS pool (~8 TB media, ~4 TB free), **4 TB** reserve disk |
| **Topology** | **Single VM** on Proxmox (keep Proxmox mgmt/snapshots) running single-node k3s |
| **Datastore** | k3s single-node → **SQLite** (no etcd) — lighter, more tolerant of load |
| **GPU** | B580 PCI-passthrough into the VM; shared by Jellyfin (transcode) + llama-server (LLM). **Immich ML stays on CPU.** |
| **Exposure** | Internal-only (`.local`), no Cloudflare for new services |
| **RAM stance** | 32 GB is the binding constraint. LLM = **8B on-demand**, Immich ML = CPU, ARC capped, no simultaneous big jobs. |

**Why single VM (not 3-node resize or bare metal):**
- One physical box gives no HA anyway; 3 nodes was never fault-tolerant.
- Single VM = flexible shared RAM pool (more efficient than partitioning 32 GB across VMs) + ×1 OS/kubelet overhead.
- Keeping Proxmox retains snapshot/backup management; cost is B580 PCI passthrough (vs bare metal's direct `/dev/dri`).

**Rejected alternatives:**
- *3-node resize* — more overhead, artificial RAM partitioning on a tight box.
- *Bare-metal single-node* — simplest + no passthrough, but loses Proxmox mgmt (user chose to keep Proxmox).

## 2. Prerequisites & blockers

| # | Item | Blocks | How |
|---|------|--------|-----|
| P1 | **Enable IOMMU/VT-d on the host** (BIOS + Proxmox) | B580 passthrough | `intel_iommu=on iommu=pt` in GRUB/cmdline; verify `dmesg \| grep -i IOMMU` |
| P2 | **Bind B580 to `vfio-pci`** on the host | B580 passthrough | identify B580 PCI id, add to `vfio-pci` ids, `update-initramfs`, reboot |
| P3 | **Survey storage** (confirm free space) | dataset layout | `zpool list` + `zfs list` — confirm 12 TB pool has ~4 TB free; confirm the 4 TB disk is unused |
| P4 | **Back up cluster state to migrate** | GitOps rebuild | SealedSecrets master key (`~/sealed-secrets-key-backup.yaml`); decide which PVC data to carry (Forgejo PG: yes; Prometheus history: no) |
| P5 | Confirm `xe` driver + B580 works **inside the VM** after passthrough | GPU pods | in VM: `xe` bound, `/dev/dri/renderD128` exists |
| P6 | Confirm `render` GID inside the VM | pod supplementalGroups | `getent group render` |

## 3. VM configuration

| Resource | Allocation | Notes |
|----------|-----------|-------|
| **vCPU** | **12** (1 socket × 12 cores, `cpu_type: host`) | 20 host threads → leave ~8 for Proxmox + ZFS + NFS. |
| **RAM** | **28 GB** | 32 − ~4 GB host (Proxmox ~1 GB + **ZFS ARC capped ~3 GB**). |
| **Boot disk** | **80 GB** virtio-scsi (qcow2/zvol on the 12 TB ZFS pool) | OS + k3s + container images + GGUF model files (~5 GB for 8B). |
| **GPU** | **B580** PCI passthrough (`hostpci0`, all-functions, ROM-bar, `mdev=off`) | 12 GB VRAM to the VM. |
| **Network** | virtio on the bridge | unchanged from current VMs. |

**ZFS ARC cap** is deliberate: with a 12 TB pool + a 4 TB Immich pool, ARC could
 balloon and starve the VM. Set on the host:
```bash
echo "options zfs zfs_arc_max=3221225472" > /etc/modprobe.d/zfs.conf   # 3 GB
update-initramfs -u
```

## 4. Storage layout

```
Proxmox host
├── 12 TB pool (existing, ~8 TB media + ~4 TB free)
│   ├── tank/media           → NFS-exported → VM mounts as /mnt/media (arr stack)
│   ├── tank/llm-models      → NFS-exported → VM mounts as /mnt/models (GGUF weights)
│   └── tank/forgejo-pg      (optional) migrated Forgejo Postgres data
│
└── 4 TB reserve disk  →  NEW dedicated zpool: tank-immich
    └── tank-immich/immich   → NFS-exported → VM mounts as /mnt/immich (photos, isolated)
```

- **NFS exports** (host `/etc/exports`) all use `all_squash,anonuid=1000,anongid=1000` so
  every container write maps to UID 1000 (the arr PUID/PGID). Same pattern as the arr-stack plan.
- **Immich on its own disk** so the photo library's growth can never fill the media pool.
- **ZFS snapshots** before any bulk operation (`zfs snapshot tank/media@pre-...`,
  `zfs snapshot tank-immich/immich@pre-...`).

## 5. Capacity budget (32 GB box, with Immich + DB)

| Consumer | Steady | Peak |
|----------|--------|------|
| Proxmox host + ZFS ARC (~3 GB cap) | ~4 | ~4 |
| VM: OS + k3s (SQLite) | ~2 | ~2 |
| Monitoring (Prom/Loki/Grafana) | ~3 | ~3 |
| Forgejo + runner | ~1 | ~2.5 (CI build) |
| Arr stack + qBittorrent/Gluetun | ~3 | ~3 |
| Jellyfin + infra | ~2 | ~2 |
| **DB (general)** | ~0.5–1 | ~1 |
| **Immich** (server+web+PG+Redis) | ~1.5 | ~2 |
| **Immich ML** (CPU, capped) | ~2–3 | ~3 (scan) |
| **LLM gemma-4-E4B (8B)** — on-demand | 0 (idle) | ~5 (load) |
| **VM total** | **~15–17** | **~24–26** |
| **Box total (VM + host)** | **~19–21** | **~28–30** |

**Steady with LLM off (~15–17 GB VM):** very comfortable in 28 GB.
**Peak with LLM loaded + Immich scan (~26 GB VM):** fits the 28 GB VM with thin margin.
**Rule:** don't load the LLM *and* run an Immich scan *and* a CI build at the same
instant. On-demand LLM loading makes this naturally true.

## 6. GPU allocation (12 GB VRAM)

| Consumer | VRAM | When |
|----------|------|------|
| llama-server (gemma-4-E4B 8B) | ~5 GB | on-demand (coding sessions) |
| Jellyfin transcode | ~0.5–1 GB | transient (playback) |
| **Immich ML** | **0** | **CPU-only** — keep off the GPU |

~6 GB used at peak, ~6 GB free. No OOM risk. The 12B LLM is **not used** (doesn't
fit the 32 GB RAM budget once Immich is resident — see local-llm plan, use 8B).

## 7. Build phases (gated)

| Phase | Contents | Gate |
|-------|----------|------|
| **0** | Host prep: enable IOMMU, bind B580 to `vfio-pci`, cap ZFS ARC, create `tank-immich` zpool on the 4 TB disk, set up NFS exports | `lspci -nnk` shows B580 on `vfio-pci`; exports visible |
| **1** | Create the VM (12 vCPU / 28 GB / 80 GB), attach B580 via `hostpci0`, install k3s single-node | VM boots; `/dev/dri/renderD128` present; `xe` driver bound (P5) |
| **2** | GitOps rebuild: install Flux Operator, **restore SealedSecrets master key** (P4), point Flux at `github.com/aplacaba/homelab-apps` | existing apps reconcile (cloudflared, forgejo, monitoring, traefik) and SealedSecrets decrypt |
| **3** | Migrate carried PVC data (Forgejo Postgres) | Forgejo serves existing repos/data |
| **4** | Decommission the 3 old VMs | only the new VM remains; box resources consolidated |
| **5** | Foundation ready → arr-stack, local-llm, Immich, DB build on top (their own plans) | — |

Phase 2 is where GitOps pays off: Flux re-creates nearly everything from git. The
irreplaceable bits are the SealedSecrets key (P4) and any PVC data you choose to carry.

## 8. Risks & gotchas

1. **RAM is the binding constraint** — 32 GB is tight once Immich lands. Mandatory:
   8B LLM, on-demand LLM loading, Immich ML on CPU, ARC capped. If it proves
   cramped, the only real lever is **adding RAM** (declined for now; revisit if
   OOMs occur).
2. **B580 passthrough is exclusive** — once passed to the VM, the host/other VMs
   lose it. No other VM can use the GPU.
3. **SealedSecrets master key is irreplaceable** — without restoring it, all
   committed `SealedSecret`s (cloudflared token, etc.) are unrecoverable. Back it
   up again before decommissioning old VMs.
4. **ZFS ARC starvation** — cap ARC (~3 GB) or it'll balloon across the 12 TB + 4 TB
   pools and squeeze the VM. Verify with `arc_summary`.
5. **Immich scan bursts** — a full library scan spikes CPU/RAM; schedule it for
   off-hours (not during coding/CI).
6. **Single node = single blast radius** — a kernel panic or OOM of a critical
   process takes down everything. Acceptable for a personal homelab; set resource
   limits on everything (the repo already does).
7. **Proxmox + passthrough firmware** — B580 is Battlemage (Xe2); ensure host
   kernel ≥ 6.12 and recent linux-firmware so the card initializes cleanly for
   passthrough.

## 9. What this enables (downstream plans)

- **arr-stack plan** (`2026-06-18-arr-stack.md`): media on `tank/media` (NFS),
  Jellyfin uses the passed-through B580. Unchanged by this plan.
- **local-llm plan** (`2026-06-18-local-llm.md`): llama-server on the VM with the
  B580. **Update:** model = **gemma-4-E4B-it (8B)** (not 12B), **on-demand loading**.
- **Immich** (new): on the dedicated 4 TB disk (`tank-immich/immich` via NFS),
  ML on CPU. Needs its own plan doc when built.
- **DB** (new): a general Postgres/MariaDB instance on the 12 TB pool. Small.

## 10. Target repo changes

This plan is mostly **off-cluster** (Proxmox/VM/host setup) — minimal repo changes:

- Create the `media` namespace resources (already in arr-stack plan).
- Update the local-llm plan doc: model → 8B, on-demand loading.
- Create new plan docs when Immich / DB are designed.
- Update AGENTS.md: cluster topology is now single-VM (not 3-node); add the ZFS
  ARC cap and the dedicated Immich disk to Architecture Notes.
