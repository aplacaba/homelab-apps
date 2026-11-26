# Platform: nodes, k3s and Flux

Things below the apps that live on the nodes or were applied by hand rather than synced from
`clusters/pk3s`.

## Nodes

k3s was installed on both nodes with the `get.k3s.io` script (no system-upgrade-controller) and
is configured **only by CLI flags**. Neither node has an `/etc/rancher/k3s/config.yaml`, and only
the master has a `registries.yaml`. The datastore is **SQLite/kine**, not etcd.

| Node | SSH | Install flags (pass all of them on every install) |
|---|---|---|
| `k3s-master` (192.168.254.50) | `admin@192.168.254.50` (passwordless sudo) | `server --disable traefik --disable gateway-api-crd` |
| `k3s-media` (192.168.254.109) | `aplacaba@192.168.254.109` (passwordless sudo) | `agent --node-name k3s-media --node-label media=yes --node-taint media=yes:NoSchedule --data-dir /home/rancher/k3s` (plus `K3S_URL`/`K3S_TOKEN` from the root-only env file) |

`k3s-media` is the repurposed media VM. It keeps the Arc B580 GPU passthrough and the 7.8T media
disk at `/home/new-media` (UUID fstab entry, plus a `RequiresMountsFor` drop-in on
`k3s-agent.service`). See [media.md](media.md).

### Joining the media node

```bash
# from the media VM, token from the master
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<cluster-version> \
  K3S_URL=https://192.168.254.50:6443 K3S_TOKEN=<token> sh -s - agent \
  --node-name k3s-media --node-label media=yes \
  --node-taint media=yes:NoSchedule --data-dir /home/rancher/k3s
```

- Rename the host to `k3s-media` **before** joining. The `media-local-path` nodePathMap key must
  match the node name.
- k3s writes a ~233M static `data/` dir on the root filesystem even with `--data-dir`. That's
  normal.
- `k3s-agent-uninstall.sh` removes `/home/rancher/k3s` **only** when run with
  `K3S_DATA_DIR=/home/rancher/k3s`, and that directory holds the media PVC data.

## k3s upgrade runbook

Last run 2026-11-26: v1.36.4 → v1.36.6 → v1.37.2.

For each hop, upgrade the **server first, then the agent**, one minor version at a time, with the
version pinned. Check the target in `https://update.k3s.io/v1-release/channels` and read the k3s
and Kubernetes release notes for removed APIs.
`kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis` shows which deprecated APIs
are still being called. Download the installer once and copy the same file to both nodes.

**Never cordon or drain a node for an upgrade.** The upgrade redeploys the bundled CoreDNS (1
replica, `maxUnavailable: 1`). With `k3s-master` cordoned and `k3s-media` tainted, the new pod has
nowhere to run and the old one is already gone, so cluster DNS is down until you uncordon (this
happened on 2026-11-26, about 1 minute). Pods can't move off either node anyway (local-path
volumes, media pinning).

1. **Snapshot the master.** The datastore is `server/db/state.db`, and the `etcd/` dir there is an
   unused leftover, so `k3s etcd-snapshot` doesn't apply. There's no `sqlite3` on the host. Stop
   k3s and copy the files. The unit uses `KillMode=process`, so containers keep running. **Never**
   run `k3s-killall.sh`.
   ```bash
   D=/home/backups/k3s/<date>-pre-<target>; sudo mkdir -p $D
   sudo systemctl stop k3s
   sudo tar -C /var/lib/rancher/k3s -czf $D/k3s-server.tgz server/db server/token server/cred server/tls
   sudo tar -czf $D/etc.tgz /etc/rancher/k3s /etc/systemd/system/k3s.service{,.env}
   sudo cp /usr/local/bin/k3s $D/k3s-<current>.bin; sudo gzip -t $D/k3s-server.tgz
   ```
   Also copy it off the box (to `~/backups/k3s/` on the workstation) and re-export the
   sealed-secrets keys ([secrets.md](secrets.md#back-up-the-master-key-out-of-band)).
2. **Upgrade the master.** The installer starts k3s again, so the API is down for only about a
   minute:
   `sudo INSTALL_K3S_VERSION='<target>' sh /tmp/k3s-install.sh server --disable traefik --disable gateway-api-crd`
3. **Upgrade the agent.** Back up `k3s-agent.service{,.env,.d/}` to `/home/backups/k3s/` on the
   node. Then source the env file **as root**, inside the same `sudo`. If you source it as the SSH
   user, the token is dropped, the installer writes an empty env file and the agent crash-loops.
   ```bash
   sudo sh -c 'set -a; . /etc/systemd/system/k3s-agent.service.env; set +a
     [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ] || exit 1
     INSTALL_K3S_VERSION="<target>" sh /tmp/k3s-install.sh agent --node-name k3s-media \
       --node-label media=yes --node-taint media=yes:NoSchedule --data-dir /home/rancher/k3s'
   ```
   Afterwards, check that the env file still has both keys, that `media-mount.conf` is still in
   `k3s-agent.service.d/` (`systemctl show k3s-agent -p RequiresMountsFor` shows
   `/home/new-media`) and that `findmnt /home/new-media` works.
4. **Verify after each node:**
   - `kubectl get nodes -o wide` (version, Ready, `media` taint and label)
   - `kubectl get --raw '/readyz?verbose'`
   - kube-system pods and the CoreDNS rollout
   - no pods outside Running or Completed
   - `kubectl get ks,hr -A` all `True`
   - LAN ingress (`curl -H 'Host: grafana.local' http://192.168.254.50:30080/`) and public ingress
   - on the media hop, a jellyfin QSV encode:
     ```bash
     kubectl -n media exec deploy/jellyfin -- /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -loglevel error \
       -init_hw_device vaapi=va:/dev/dri/renderD128 -init_hw_device qsv=qs@va -init_hw_device opencl=ocl@va \
       -filter_hw_device qs -f lavfi -i testsrc2=duration=3:size=1920x1080:rate=30 \
       -vf 'format=nv12,hwupload=extra_hw_frames=64' -c:v h264_qsv -f null -
     ```
   - one real forgejo-runner job (DinD starts a `node:22-bookworm` job container; watch with
     `kubectl -n forgejo-runner exec deploy/forgejo-runner -c dind -- docker events --since 5m ...`)
5. **Rollback:** re-run the installer with the previous version, agent first if the server is also
   being rolled back. To roll the server back a minor version, also stop k3s and restore `server/`
   from the pre-hop tarball before installing the old version. Cluster-state changes made after the
   snapshot are lost, and Flux re-applies whatever is in git.

Upgrade notes:

- **CLI flags are not kept across reinstalls.** Only `K3S_*` env vars are, so always pass the full
  flag set.
- **`gateway-api-crd` (k3s 1.37 and later):** k3s 1.37 bundles a `gateway-api-crd` HelmChart
  (`takeOwnership`/`forceConflicts`) that `--disable traefik` doesn't turn off. It's disabled here
  so no Gateway API CRDs exist outside GitOps (nothing uses them). Only drop the flag if that
  changes.
- The agent may lag the server by a version during a hop.
- Running containers survive a k3s service restart. No pod or container restarted on either node
  during the 2026-08-30 and 2026-11-26 upgrades. Only the bundled kube-system addons roll (CoreDNS
  and local-path on version bumps).
- Snapshots from the 2026-11-26 run are in `/home/backups/k3s/2026-11-26-pre-v1.36.6+k3s1` and
  `…-pre-v1.37.2+k3s1` on the master (plus the old `k3s` binaries), agent unit backups under the
  same path on `k3s-media`, and copies in `~/backups/k3s/` on the workstation.

## Flux Operator and the FluxInstance

Neither Flux nor its operator is synced by Flux:

- `flux-instance.yaml` (repo root, outside `./clusters/pk3s`) declares distribution `2.10.x` and
  the four components. It was created with `kubectl apply -f flux-instance.yaml`. The operator
  re-renders the controllers every hour (`fluxcd.controlplane.io/reconcileEvery: "1h"`).
- The operator is a plain Helm release (`helm -n flux-system list` shows `flux-operator`, default
  values, CRDs in templates).

**Upgrades take two manual steps, operator first.** Each operator release supports a limited range
of Flux minors (Flux 2.9 needs operator v0.53 or later, Flux 2.10 needs v0.62 or later).

```bash
helm upgrade flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --version <v> -n flux-system
# then edit distribution.version in flux-instance.yaml and
kubectl apply -f flux-instance.yaml
```

- `migrateResources: true` (the default) migrates CRD stored versions.
- Before a Flux minor bump, grep the repo for `apiVersion`s that were removed. For example, 2.9
  dropped `notification.toolkit.fluxcd.io/v1beta2` and `image.toolkit.fluxcd.io/v1beta2`.
- Rollback: `helm rollback flux-operator -n flux-system`, then re-apply the previous
  `distribution.version`.
- Operator v0.63.x logs `failed to migrate resources to the latest storage version … continue list
  option is not supported by the cache` on every reconcile (upstream flux-operator#1110). The error
  is caught and the instance stays Ready. Its only effect here is that the `alerts`/`providers`
  CRDs keep storedVersions `["v1beta3","v1"]` (no such objects exist). Take an operator release
  with the fix before any Flux release that drops `v1beta3` from those CRDs.
