# Media stack (k3s-media node)

Everything runs in the `media` namespace (`clusters/pk3s/media/`), pinned to the dedicated
tainted node `k3s-media` (192.168.254.109; label `media=yes`, taint `media=yes:NoSchedule`). All
media pods get the nodeSelector and toleration from the shared `component-media-pin` kustomize
component. The node has the Arc B580 GPU (jellyfin QSV) and the 7.8T media disk at
`/home/new-media`. For how the node is set up and upgraded, see [platform.md](platform.md). Image
tags are in [inventory.md](inventory.md).

Public access for friends goes through the Pangolin VPS ([pangolin.md](pangolin.md)), never
through Cloudflare.

## Access (LAN only, through 192.168.254.50:30080)

| App | Hostname | Notes |
|---|---|---|
| jellyfin | jellyfin.local | QSV transcoding (privileged container plus an Intel driver init script) |
| seerr | seerr.local | requests UI |
| immich | immich.local | photos (central PG) |
| sonarr / radarr / lidarr | *.local | hardlinked imports from `/data/downloads` |
| prowlarr | prowlarr.local | indexer hub, syncs to sonarr, radarr and lidarr |
| bazarr | bazarr.local | subtitles |
| qbittorrent / sabnzbd | *.local | inside the VPN'd `download` pod (gluetun sidecar) |
| shelfmark | shelfmark.local | book and audiobook search and requests (`ghcr.io/calibrain/shelfmark`, Standard image) |
| flaresolverr | none | `http://flaresolverr:8191` ClusterIP, Prowlarr's proxy for Cloudflare-protected indexers |

## How it fits together

- **download pod:** gluetun runs as a sidecar initContainer (restartPolicy Always, NET_ADMIN plus
  `/dev/net/tun`, `FIREWALL=on` kill-switch, `FIREWALL_INPUT_PORTS` 8081,8080, and a postStart
  gate that waits for the VPN) alongside qbittorrent (`WEBUI_PORT=8081`) and sabnzbd. The pod uses
  `dnsPolicy: None` with the AirVPN tunnel DNS 10.128.0.1. `SERVER_HOSTNAMES` must be an AirVPN
  hostname (`sg.vpn.airdns.org`), not an IP. Sabnzbd has no usenet servers configured yet (the
  operator put that off).
- **`media-local-path` StorageClass:** a separate provisioner instance in the media namespace
  (`rancher.io/local-path-media`, nodePathMap `k3s-media` → `/home/rancher/k3s/storage`, **no**
  default entry). The agent's `--data-dir` doesn't move local-path volumes; the StorageClass is
  what puts the PVCs on `/home`.
- **`/data` mount:** pods mount `/home/new-media/Media` at `/data`, matching the paths from the
  migrated YAMS config. Each pod has **one** mount, so downloads and the tv/movies folders are on
  one filesystem and imports can hardlink.
- **immich DB:** central PostgreSQL ([postgres.md](postgres.md)), database `immich`, password in the
  sealed secret. Extensions are pre-installed: vector 0.8.6, vchord 1.1.1
  (`shared_preload_libraries=vchord.so`), cube, earthdistance. The immich server limit is 1.5Gi
  (1Gi runs out of memory during migrations).
- **Memory budget:** the node has 16G and nothing is overcommitted (pod limits total about
  14.6Gi). Raising one app's limit means lowering another's (usually immich ML, 3Gi → 2Gi).
- **Migration staging backups** are in `/home/backups/media-migration` on the node (configs tar,
  immich dump, immich library tar).

## Image pinning and bumps

Never go back to `:latest` or floating tags. Until 2026-11-26, the *arr apps, qbittorrent,
sabnzbd, flaresolverr and floci tracked `:latest` (gluetun `v3`) with `imagePullPolicy: Always`,
so every container restart quietly pulled whatever upstream had published. They're now pinned to
the exact build each pod was running:

- **LSIO images** use their immutable `<version>-ls<NNN>` build tag, not `version-<X>`, which moves
  when LSIO rebuilds the base.
- **Other images** use their release tag.
- **Jellyfin** has its own procedure (below).

To bump an image:

1. Pick the target. `skopeo inspect -n --format '{{index .Labels "org.opencontainers.image.version"}}' docker://ghcr.io/linuxserver/<app>:latest`
   gives the newest LSIO build tag (lscr.io is a slow redirect to ghcr.io). Read the upstream
   release notes for DB migrations.
2. For SQLite-backed apps, back up `/config` first if the release migrates the DB.
3. Edit the tag, commit (`media: bump sonarr 4.0.20.3014-ls5 -> …`) and push.
4. Once it has landed, check that `kubectl get pod -n media -l app=<app> -o jsonpath='{..imageID}'`
   matches `skopeo inspect --raw docker://<image>:<tag> | sha256sum`.

Any change to the image string restarts the pod, even re-pinning the same digest. The *arr and
`download` Deployments use `maxSurge: 0` / `maxUnavailable: 1`, like seerr and shelfmark. The old
pod is told to stop before the new one is created, but the controller doesn't wait for it to
finish, so they still overlap for up to 30s while the old one shuts down (seen in the 2026-11-26
rollout: SIGTERM at 07:50:58, new containers up at 07:51:00–02). Only `strategy: Recreate` waits.
Expect a little downtime. Bumping `download` restarts gluetun, qbittorrent and sabnzbd together.

## Jellyfin

**GPU:** the container is privileged, because the k8s device cgroup otherwise blocks `/dev/dri`.
The `configmap-jellyfin-intel-init` custom-cont-init script installs `intel-opencl-icd`,
`libze-intel-gpu1` and `intel-ocloc` from the signed Ubuntu repos, and copies the system
libva/libdrm/iHD into `/usr/lib/jellyfin-ffmpeg/lib`.

- QSV needs the OpenCL/Level Zero runtime for HDR→SDR tonemapping. Without it, ffmpeg exits with
  code 237 (`Failed to get number of OpenCL platforms: -1001` on `-init_hw_device opencl=ocl@va`),
  so every transcode fails while direct play and remux still work. This showed up after the
  upgrade to 10.11 (tonemapping through `tonemap_opencl`).
- The LSIO image only ships `mesa-va-drivers`, not iHD. At every pod start the script installs
  `intel-media-va-driver-non-free` from the Ubuntu archive as a fallback. The Intel `noble` repo
  line fails as unsigned, which is harmless. After an upgrade, check the init log or
  `dpkg -l intel-media-va-driver-non-free`.
- The script runs again on every pod restart. After a change to only the ConfigMap, run
  `kubectl rollout restart deploy/jellyfin -n media`.

**Version (pinned to `version-12.4ubu2604`):** LSIO moved `latest` to 12.0 on release day, and
Jellyfin's DB migrations can't be undone without restoring `/config`, so never use `:latest`. The
Deployment has no `strategy` (the RollingUpdate default, kept on purpose), so a plain image bump
would start the new pod against the live SQLite DB while the old one is still running.

Upgrade procedure:

1. Commit `replicas: 0` and let it land.
2. Back up `/config` with a one-off helper pod (not in git; media nodeSelector and toleration, PVC
   `jellyfin-config` read-only, hostPath `/home/backups`) to
   `/home/backups/jellyfin-<new ver>/jellyfin-config-pre-<new ver>.tgz` on k3s-media, plus a
   `.sha256`. Check that the size is about 1.9G and that `gzip -t` passes.
3. Bump the pinned tag and commit `replicas: 1`.

Rollback: `replicas: 0`, empty the PVC and restore the matching tarball (helper pod,
`tar --numeric-owner -xpzf`), re-pin the previous tag, then `replicas: 1`.

History:

- **12.0:** `EnableLegacyAuthorization` is now `false` (the flag still exists as a fallback). A full
  library scan was required after the upgrade. seerr 3.5.0 is compatible.
- **12.0 → 12.4 (2026-11-26, `12.4ubu2604-ls61`):** no breaking or auth changes. 6 migrations ran in
  about 2s (including `MakeOwnerIdIndexesPartial`). The seerr 3.5.2 sync was checked, and no
  library scan was needed.
- Backups: `jellyfin-12.0/jellyfin-config-pre-12.0.tgz` (10.11 state) and
  `jellyfin-12.4/jellyfin-config-pre-12.4.tgz` (12.0 state).

## seerr

Config is at `/app/config` (not `/config`). The image is pinned to
`ghcr.io/seerr-team/seerr:v3.5.2` with `maxSurge: 0` / `maxUnavailable: 1`, because the config is
a SQLite DB on a RWO volume and two pods must never mount it at once. The admin was created by
seeding the DB and `settings.json` (permissions=2 ADMIN). `X-Api-Key` header auth works where the
session cookie would otherwise be required.

**The manual seed skipped the media-server fields.** It set the Jellyfin host and apiKey, but left
`main.mediaServerType=4` (NOT_CONFIGURED), `jellyfin.libraries=[]`, and admin user id 1 without a
`jellyfinUserId`. As a result, no `jellyfin-recently-added-scan` or `jellyfin-full-scan` jobs were
registered, and the daily availability sync logged `An admin is not configured.` This was fixed
2026-09-08. All three steps are required:

1. `POST /api/v1/settings/main` `{"mediaServerType":2}` (JELLYFIN=2).
2. Sync libraries with `POST /api/v1/settings/jellyfin/library/sync`, then enable each one with
   `PUT /api/v1/settings/jellyfin/library/{libraryId}`. v3.5.0 removed the old
   `GET .../library?sync=true&enable=<ids>` form.
3. Set `user.id=1.jellyfinUserId` to the Jellyfin admin's user id. There's no API for this, so
   edit the DB while the pod is stopped.

Restart the pod afterwards so `schedule.ts` registers the Jellyfin jobs. The seerr config backup is
`/home/backups/seerr/seerr-config-pre-fix.tgz`.

## Shelfmark

- **Memory limit is 1.5Gi**, not the roughly 2Gi upstream recommends. The Standard image bundles
  Chromium to get past Cloudflare on Direct Download sources. Typical sessions work, since problems
  start around 1Gi. If you see `403 detected; switching to bypasser` followed by `No download URL
  found` in a loop, raise the limit and lower another app's (for example immich ML 3Gi → 2Gi), or
  switch to the Lite image with an external FlareSolverr.
- **It runs as non-root:** `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`,
  `fsGroup: 1000`. It isn't an LSIO image, so there's no PUID/PGID. The entrypoint needs writable
  `/tmp/shelfmark`, `/config` and HOME, which fsGroup covers. The TZ env is accepted, but
  `/etc/localtime` doesn't change in non-root mode (only cosmetic).
- **It's a manual search and request tool.** It doesn't watch authors, series or new releases
  (upstream doesn't plan to). Downloads go to `INGEST_DIR=/data/books`. Indexers and download
  clients are configured in its UI. The 2Gi `shelfmark-config` PVC uses `media-local-path`, so if
  it's removed from the kustomization, the config is lost.

## Indexers and FlareSolverr

- **FlareSolverr** runs at `http://flaresolverr:8191` (ClusterIP) with a 512Mi limit, and has no
  PVC or ingress. If it's OOM-killed (`kubectl -n media get events`), raise it to 1Gi and lower
  immich ML from 3Gi to 2Gi to make room.
- **Prowlarr's FlareSolverr settings live in its DB and are lost on a rebuild.** Reconfigure them
  in the UI: Settings → Indexers → FlareSolverr Proxy → `http://flaresolverr:8191`, then assign the
  proxy per indexer (ZkTorrent must have it).
- **The zetorrents and zktorrent definitions point at stale domains** (their rotation lists now
  redirect to parked pages), so update the baseUrls by hand. The zktorrent definition is also out of
  date with the site's markup (the title selector breaks with "Invalid Release ... No title
  provided"). Upstream replaced it with `world-torrent`, so use the World-torrent indexer with a
  live clone domain such as `https://www.worldivx.cc/`.

## Rollback to the old docker containers

During the migration from docker, every cutover kept the old container available until its
replacement was verified. Rollback works per app:

1. Stop the replacement through git first: commit `replicas: 1 → 0` in
   `clusters/pk3s/media/deployment-*.yaml` and confirm the pod has stopped. Never use
   `kubectl scale`, because Flux reverts it.
2. Only then start the old container (`docker start <app>` on the VM).
3. The download unit rolls back all at once: stop the `download` Deployment through git first, then
   start the old `gluetun`, `qbittorrent` and `sabnzbd` containers together.

**Rule: never run two writers on the same state.** The old container stays stopped while its
replacement runs, and the replacement is confirmed stopped before the old one starts.
