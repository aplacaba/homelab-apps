# Cluster inventory

What is running: versions and volumes. This is a snapshot, so update it when you bump something.
Last read back from the cluster on 2026-09-13; versions updated through the 2026-11-26 upgrades.
If this page and the manifests disagree, the manifests in `clusters/pk3s/` are right.

## Platform

| Component | Version |
|---|---|
| k3s | v1.37.2+k3s1 (containerd 2.3.7, SQLite datastore) on Debian 13 (trixie) |
| Flux | Flux Operator v0.63.1, FluxInstance `flux`, distribution 2.10.x |
| kube-system | coredns 1.14.7, metrics-server 0.9.0, local-path-provisioner 0.0.37, svclb |

## HelmReleases

| Namespace | Release | Chart | App |
|---|---|---|---|
| cert-manager | cert-manager | v1.21.3 | |
| cv-datastar | cv-datastar | 0.3.0 | |
| forgejo | forgejo | 17.3.3 | Forgejo 15.0.12 |
| forgejo-runner | forgejo-runner | 0.7.6 | runner 13.2.2 (image override), docker 29.10-dind |
| media | immich | 0.13.4 | Immich 3.4 |
| monitoring | kube-prometheus-stack | 93.11.0 | operator 0.95.2, Prometheus 3.16, Alertmanager 0.35, Grafana 13.3.2 |
| monitoring | loki / alloy | 7.7.0 / 1.16.0 | Loki 3.6.20 / Alloy v1.22.0 |
| nextcloud | nextcloud | 9.4.6 | Nextcloud 35.0.3 |
| pangolin | newt | 1.6.0 | newt 1.20.0 |
| sealed-secrets | sealed-secrets | 2.22.0 | controller 0.41.2 |
| traefik | traefik | 43.0.0 | Traefik v3.8.0 |

## Raw-manifest apps

| App | Image version |
|---|---|
| actual-budget | 26.11.0 |
| cloudflared | 2026.11.2 |
| cluster-digest | nginx 1.30.7-alpine, worker alpine/k8s:1.37.2 |
| floci | 2.5.0 |
| koito | 0.3.2 |
| multi-scrobbler | 0.21.3 |
| watcharr | v4.4.0 |
| windshift | 0.9.6 |
| pve | proxy only |

Media Deployments (pinned 2026-11-26 to the digests running at the time):

| App | Tag |
|---|---|
| jellyfin | `version-12.4ubu2604` |
| seerr | v3.5.2 |
| shelfmark | v1.7.1 |
| immich valkey | 9.2 |
| flaresolverr | v3.5.2 |
| sonarr | `4.0.20.3014-ls5` |
| radarr | `7.0.3.10918-ls328` |
| lidarr | `3.1.6.5079-ls49` |
| prowlarr | `3.0.2.5780-ls169` |
| bazarr | `v1.6.2-ls373` |
| download pod | gluetun v3.41.3, qbittorrent `5.3.0_v2.1.2-ls487`, sabnzbd `5.1.3-ls281` |

## Persistent volumes

Every one has reclaim `Delete`. Removing an app from the root kustomization deletes these volumes
and the data on them.

| Namespace | PVC (storage class) | Size |
|---|---|---|
| actual-budget | `actual-budget-data` (local-path) | 2Gi |
| cluster-digest | `digest-data` (local-path) | 100Mi |
| floci | `floci-data` (local-path) | 5Gi |
| forgejo | `gitea-shared-storage` (local-path) | 10Gi |
| forgejo-runner | `dind-data` (local-path) | 20Gi |
| koito | `koito-data` (local-path) | 5Gi |
| multi-scrobbler | `multi-scrobbler-data` (local-path) | 2Gi |
| watcharr | `watcharr-data` (local-path) | 5Gi |
| windshift | `windshift-data` (local-path) | 5Gi |
| nextcloud | `nextcloud-nextcloud` / `data-nextcloud-mariadb-0` / `redis-data-nextcloud-redis-master-0` | 100Gi / 8Gi / 5Gi |
| monitoring | prometheus / loki / grafana / alertmanager | 20Gi / 10Gi / 5Gi / 5Gi |
| media | `immich-library` plus ten 2Gi app-config PVCs (media-local-path) | 200Gi + 20Gi |
