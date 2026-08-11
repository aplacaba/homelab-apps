# homelab-apps — GitOps Guide for AI Agents

## Project Overview

GitOps repository for a **k3s v1.34** homelab cluster managed by **Flux Operator**.
The cluster syncs from this repo (`github.com/aplacaba/homelab-apps.git`) at `./clusters/pk3s`.

| Aspect | Detail |
|---|---|
| **Cluster** | pk3s — single-node k3s |
| **GitOps** | Flux Operator (FluxInstance), one-way sync from GitHub |
| **Ingress** | Traefik v3 with IngressRoute CRD, NodePort 30080/30443 |
| **TLS** | cert-manager + Let's Encrypt DNS-01 (Cloudflare) wildcard `*.watchtoken.org`; terminated on Traefik |
| **Auth** | None (previously Authentik) |
| **Tunnel** | Cloudflare Tunnel (cloudflared) for public `.watchtoken.org`, `cv.alacaba.org`, and `ssh.watchtoken.org`. HTTPS hostnames route to Traefik `:443` (No TLS Verify); `ssh.watchtoken.org` routes directly to `forgejo-ssh` (raw TCP, no Traefik). |
| **Secrets** | SealedSecrets (`sealed-secrets` controller) — encrypted at rest, master key backed up offline |
| **Internal DNS** | `.local` domains via `/etc/hosts` → `192.168.254.50:30080` |
| **Storage** | `local-path` storage class (k3s built-in) |
| **Forgejo** | `fgit.watchtoken.org` — self-hosted Git + Actions + Container Registry. SSH: LAN `ssh://git@192.168.254.50:30022`, public `git@ssh.watchtoken.org` (requires `cloudflared` ProxyCommand). |

## Directory Structure

```
terraform/
├── dns.tf              # Cloudflare DNS records (Terraform)
├── main.tf             # Cloudflare tunnel & vars
├── providers.tf         # Cloudflare provider + S3 backend
├── tokens.tf            # cert-manager API tokens
├── tunnel.tf            # Cloudflare tunnel ingress config
├── zone-settings.tf     # Zone security settings
├── Makefile             # Lint, fmt-check, validate (both roots)
└── grafana/             # Grafana dashboard provisioning (local state)
    ├── providers.tf
    ├── variables.tf
    ├── bootstrap.tf
    ├── folders.tf
    ├── dashboards.tf
    ├── outputs.tf
    └── dashboards/*.json

clusters/pk3s/
├── kustomization.yaml         # Root — lists all app directories
├── atuin/                     # Atuin shell history sync server (raw manifests, external PostgreSQL at 192.168.254.104)
├── cert-manager/              # cert-manager + Let's Encrypt DNS-01 (Cloudflare) ClusterIssuers + sealed CF token
├── cloudflared/               # Cloudflare Tunnel (raw manifests; token is a SealedSecret)
├── cv-datastar/               # CV site — served at cv.alacaba.org (Helm chart, OCI registry)
├── floci/                     # FLOCI tool (raw manifests)
├── flux-dashboard/            # Flux web UI (raw manifests)
├── flux-monitoring/           # PodMonitors for the four Flux controllers (scraped by Prometheus)
├── forgejo/                   # Git + Actions + Registry (Helm chart 17.1.4, external PostgreSQL)
├── forgejo-runner/            # CI runner (Helm chart)
├── monitoring/                # Prometheus + Loki + Grafana + Flux alerts (Helm charts)
├── neo4j/                     # Neo4j graph database — backend for a personal app (Helm chart 5.26.28)
├── nextcloud/                 # File sync & share (Helm chart + MariaDB/Redis subcharts)
├── paperless-ngx/             # Document management / OCR (raw manifests, bundled Redis)
├── pdf-unlocker/              # PDF password unlocker for paperless-ngx (Helm chart, GHCR)
├── sealed-secrets/            # SealedSecrets controller (Bitnami chart, decrypts in-cluster)
├── spec-frontend/             # Read-only Neo4j story-graph browser — LAN spec-frontend.local, public spec.watchtoken.org (Helm chart, OCI registry)
├── traefik/                   # Ingress controller (Helm chart)
└── watcharr/                  # Media watch list / tracker (raw manifests, SQLite) — LAN watcharr.local
```

## App Deployment Pattern

Every app lives in its own directory under `clusters/pk3s/<app>/` and is referenced
from the root `kustomization.yaml`.

### Minimal pattern (Helm chart from repo)

```
clusters/pk3s/<app>/
├── namespace.yaml               # apiVersion: v1, kind: Namespace
├── helmrepository.yaml          # Flux HelmRepository (skip if reusing existing)
├── helmrelease.yaml             # Flux HelmRelease with chart values
├── ingressroute.yaml            # Traefik CRD (if exposing via web)
└── kustomization.yaml           # Lists all resources above
```

### Raw k8s pattern (no Helm chart)

Used when no suitable chart exists or for simple infrastructure.

```
clusters/pk3s/<app>/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── ingressroute.yaml
├── pvc.yaml                    # If persistent storage needed
└── kustomization.yaml
```

### Root kustomization

Add the new directory to `clusters/pk3s/kustomization.yaml`:

```yaml
resources:
  - <existing-apps>
  - <new-app-name>   # add here, alphabetically
```

## Conventions

### Ingress — always Traefik IngressRoute CRD, never k8s Ingress

The cluster uses **Traefik CRD** (`traefik.io/v1alpha1`), not standard
`networking.k8s.io/v1` Ingress. Create `ingressroute.yaml` with:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: <app>
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`<app>.watchtoken.org`)
      services:
        - name: <service-name>   # Usually the Helm release service name
          port: <port>
```

- **Always host-based** matching (`Host(...)`). Never use `PathPrefix`.
- **Disable the chart's built-in ingress** when using a manual IngressRoute:
  `ingress.enabled: false` or `ingressRoute.create: false` in HelmRelease values.
- For internal apps use `<app>.local` domains; for public ones use `<app>.watchtoken.org`.

### HelmRelease values — override, don't copy

Only override values that differ from chart defaults. Use the `helmrelease.yaml`
to pass `values:` — don't duplicate the full `values.yaml` from the chart.
Reference existing patterns:

- **Forgejo** (`clusters/pk3s/forgejo/helmrelease.yaml`) — full app on external PostgreSQL 18.3 (no bundled subchart; see the Forgejo PostgreSQL section)
- **cv-datastar** (`clusters/pk3s/cv-datastar/helmrelease.yaml`) — static site, OCI chart, imagePullSecrets

### Local Helm charts (OCI registry)

When deploying a chart from the `~/Projects/cv-datastar` local repo (or similar):

1. **Package and push** to the Forgejo OCI registry:
   ```bash
   helm package charts/<chart>
   helm push <chart>-<version>.tgz oci://fgit.watchtoken.org/forgejo-admin
   ```
2. **Create a HelmRepository** with `type: oci` referencing the registry.
3. **Create a registry auth Secret** in `flux-system` namespace (type: `docker-registry`,
   server: `https://fgit.watchtoken.org`).
4. Reference the Secret in both `helmrepository.yaml` (`secretRef`) and
   `helmrelease.yaml` (`imagePullSecrets`).

## Existing HelmRepositories

These are available in `flux-system` namespace. Reference by name in HelmRelease
`sourceRef`:

| Name | Type | URL | Used by |
|---|---|---|---|
| `traefik` | default | `https://traefik.github.io/charts` | traefik |
| `forgejo` | OCI | `oci://codeberg.org/forgejo-contrib` | forgejo |
| `forgejo-runner` | OCI | `oci://codeberg.org/wrenix/helm-charts` | forgejo-runner |
| `prometheus-community` | default | `https://prometheus-community.github.io/helm-charts` | monitoring |
| `grafana` | default | `https://grafana.github.io/helm-charts` | monitoring (loki, promtail) |
| `jetstack` | default | `https://charts.jetstack.io` | cert-manager |
| `cv-datastar` | OCI | `oci://fgit.watchtoken.org/forgejo-admin` | cv-datastar, spec-frontend (needs secretRef) |
| `bitnami` | OCI | `oci://registry-1.docker.io/bitnamicharts` | sealed-secrets |
| `nextcloud` | default | `https://nextcloud.github.io/helm` | nextcloud |
| `ghcr-aplacaba` | OCI | `oci://ghcr.io/aplacaba/charts` | pdf-unlocker |
| `neo4j` | default | `https://neo4j.github.io/helm-charts` | neo4j |

## Secret Management (SealedSecrets)

Secrets are **never committed in plaintext**. They are sealed (encrypted with the
`sealed-secrets` controller's public key) and committed as `SealedSecret` CRs; the
controller decrypts them in-cluster into ordinary `Secret` objects that apps
reference. Because decryption happens in-cluster, **Flux needs no changes to its
sync block** — the `SealedSecret` is applied like any other manifest.

| Component | Detail |
|-----------|--------|
| Controller | `sealed-secrets` namespace, Bitnami chart `2.5.x` (controller 0.31.0) |
| CLI | `kubeseal` at `~/.local/bin/kubeseal` |
| Example | `clusters/pk3s/cloudflared/sealedsecret.yaml` → decrypts to `Secret cloudflared/tunnel-credentials` |

### Seal a new secret (plaintext never touches git or chat)

```bash
cd ~/Projects/homelab-apps
printf 'Secret value: '; IFS= read -rs VAL; echo
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: <name>\n  namespace: <ns>\ntype: Opaque\nstringData:\n  key: %s\n' "$VAL" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace <ns> \
  > clusters/pk3s/<ns>/sealedsecret.yaml
unset VAL
```

Then add `sealedsecret.yaml` to the app's `kustomization.yaml` and commit the
encrypted form only.

### ⚠️ Back up the master key (out of band)

The controller's private key is **not** in git. Without it, a cluster rebuild
cannot decrypt any committed `SealedSecret`. Back up all key secrets to a secure
offline location (password manager / encrypted drive) — never into this repo:

```bash
kubectl get secret -n sealed-secrets -o custom-columns=NAME:.metadata.name --no-headers \
  | grep '^sealed-secrets-key' \
  | while read k; do kubectl get secret "$k" -n sealed-secrets -o yaml; done \
  > ~/sealed-secrets-key-backup.yaml
```

Current backup lives at `~/sealed-secrets-key-backup.yaml`. The controller rotates
keys (~every 30 days); re-export periodically so older `SealedSecret`s stay
recoverable after a rebuild.

## Architecture Notes

### Cluster layout

```
┌───────────────┬──────────────────────────────────────────────────┐
│ flux-system   │ Flux Operator controllers                        │
│               │ GitRepository → Kustomization → HelmRelease      │
├───────────────┼──────────────────────────────────────────────────┤
│ traefik       │ Ingress controller (NodePort 30080/30443)        │
├───────────────┼──────────────────────────────────────────────────┤
│ cloudflared   │ Cloudflare Tunnel (token-based, no config)       │
│               │ Routes public DNS → internal services            │
├───────────────┼──────────────────────────────────────────────────┤
│ forgejo       │ Git server + Actions + OCI Container Registry    │
│               │ Service: forgejo-http:3000                       │
│               │ Service: forgejo-ssh:22 (NodePort 30022)         │
│               │ Registry: https://fgit.watchtoken.org/v2/        │
│               │ DB: external PostgreSQL 18.3 at 192.168.254.104  │
├───────────────┼──────────────────────────────────────────────────┤
│ atuin         │ Shell history sync server                        │
│               │ Service: atuin:8888                              │
│               │ Public: history.watchtoken.org                   │
│               │ DB: external PostgreSQL at 192.168.254.104       │
├───────────────┼──────────────────────────────────────────────────┤
│ monitoring    │ Prometheus, Loki, Grafana, Flux alerting         │
├───────────────┼──────────────────────────────────────────────────┤
│ neo4j         │ Graph database (Community, pinned k3s-master)    │
│               │ Service: neo4j:7687 (NodePort 30087)             │
│               │ Browser: http://neo4j.local:30080                │
├───────────────┼──────────────────────────────────────────────────┤
│ nextcloud     │ File sync, MariaDB, Redis (100Gi PVC)              │
├───────────────┼──────────────────────────────────────────────────┤
│ ∀ apps        │ Each in its own namespace                        │
│               │ Can reference cross-ns services/middlewares       │
└───────────────┴──────────────────────────────────────────────────┘
```

### Cross-namespace references

Traefik has `providers.kubernetesCRD.allowCrossNamespace: true` enabled.
This allows any app's IngressRoute to reference services and middlewares in
other namespaces.

### Public vs internal

- **Public** (`*.watchtoken.org`): routed through Cloudflare Tunnel → Traefik
  (no TLS termination on the cluster — handled by Cloudflare edge).
  SSH (`ssh.watchtoken.org`) routes **straight to `forgejo-ssh`** via the
  tunnel, bypassing Traefik (raw TCP, no TLS).
- **Internal** (`*.local`): accessed via `http://192.168.254.50:30080` on LAN.
  SSH accessible via `ssh://git@192.168.254.50:30022`.

## Documentation Updates

After making implementation changes, update AGENTS.md to reflect the new state:

- **New app deployed** → Add to Directory Structure and Existing HelmRepositories (if new chart source)
- **New HelmRepository added** → Add to the HelmRepositories table
- **New gotcha discovered** → Add to Common Gotchas
- **Architecture changes** → Update Architecture Notes (cluster layout, cross-ns refs, public vs internal)
- **New operational procedure** → Add relevant section (health checks, restart procedures, shell access)

This document is the primary guide for AI agents working in this repo — keep it accurate.

## Common Gotchas

1. **Chart ingress vs IngressRoute:** If writing a manual IngressRoute, always disable the chart's built-in ingress.
2. **OCI registry auth:** Charts pushed to `fgit.watchtoken.org` need a `forgejo-registry-auth` docker-registry Secret in `flux-system`.
3. **Reconciliation lag:** Flux syncs every 1h by default. Force with `kubectl -n flux-system reconcile helmrepository <name>` or `kubectl -n flux-system reconcile kustomization pk3s`.
4. **Local chart deployment:** Can't use upstream HelmRepository for local charts. Package → push to OCI registry → HelmRelease with `type: oci`.
5. **Runner goes silent after cancellation:** The Forgejo runner can stop picking up jobs after a task is cancelled (poller process stays alive but doesn't fetch). Symptom: `status=waiting` in Forgejo UI but no recent runner logs. Fix: `kubectl rollout restart deploy/forgejo-runner -n forgejo-runner`.
6. **Runner labels must match workflow `runs-on`:** Runner labels are set at `runner.config.file.runner.labels` (not `runner.file.runner.labels`). Mismatch → jobs queue forever. If labels change, delete the `forgejo-runner-config` secret and restart.
7. **Bitnami charts are OCI:** Bitnami migrated to `oci://registry-1.docker.io/bitnamicharts`. An HTTP-typed `HelmRepository` fails with `unsupported protocol scheme "oci"` — declare it `type: oci` (see `sealed-secrets/helmrepository.yaml`).
8. **Loki requires `auth_enabled: false` for Promtail:** The Loki chart defaults `auth_enabled: true`, which requires a tenant ID (X-Scope-OrgID) header. Promtail requests get 401 without it. For single-tenant homelabs, set `loki.auth_enabled: false` in the Loki HelmRelease values.
9. **cert-manager CRD bootstrap is two-phase:** cert-manager's own CRDs (`ClusterIssuer`, `Certificate`) are installed by its HelmRelease, but if those CR objects sit in the *same* Flux kustomization pass, the dry-run aborts (`no matches for kind "Certificate"`) before cert-manager ever installs — deadlock. Fix: install cert-manager first (unreference the CRD-dependent objects), wait for CRDs, then re-add them. See `cert-manager/` history.
10. **Wildcard cert is a Traefik default TLSStore (cross-ns):** The `*.watchtoken.org` `Certificate` lives in `traefik` ns and is wired to a `default` TLSStore, so any app's IngressRoute just needs `entryPoints: [websecure]` + `tls: {}` — no per-route `secretName`. `allowCrossNamespace` (already on) makes this work across namespaces.
11. **HTTP→HTTPS redirect must be host-scoped, not global:** Do NOT use `ports.web.redirections.entryPoint` — it would redirect `*.local` (→ https, no cert/route) and break LAN access. Use the shared `redirect-to-https` Middleware (in `traefik/middlewares`) attached only to `*.watchtoken.org` routes on `web`.
12. **Cloudflare tunnel origin = `https://traefik.traefik.svc:443` with No TLS Verify:** The cert is `*.watchtoken.org` but cloudflared connects to host `traefik.traefik.svc`, so strict verify fails (502). Each public hostname in the Zero Trust dashboard uses `https://traefik.traefik.svc:443` + **No TLS Verify ON**. The hop is still TLS-encrypted; verification is skipped (fine — tunnel is already encrypted + intra-cluster hop).
13. **Grafana admin credentials are a SealedSecret, not plaintext:** Grafana admin auth is no longer the default `admin/admin` in the HelmRelease. The password is stored in `monitoring/sealedsecret-grafana-admin.yaml` (keys `admin-user` and `admin-password`), and the HelmRelease references it via `grafana.admin.existingSecret: grafana-admin-secret`. To rotate the Grafana password, re-seal into that `SealedSecret` — do not edit the HelmRelease values directly.
14. **cloudflared access SSH bypasses Traefik:** Public SSH (`ssh.watchtoken.org`) does NOT route through Traefik. The tunnel ingress routes directly to `forgejo-ssh.forgejo.svc:22` (raw TCP). This is configured in Terraform (`terraform/tunnel.tf`), not the dashboard. Do NOT add a Traefik TCP entryPoint for SSH — the tunnel handles it without one.
15. **Alertmanager configSecret propagation takes ~1 minute:** The Prometheus Operator watches the `alertmanager-config` Secret. When updated (via SealedSecret re-seal), the operator reads it, generates a new intermediate secret, and the Alertmanager config-reloader picks it up within ~1 minute. No pod restart needed — the StatefulSet config-volume is not updated, but the generated config file in `/etc/alertmanager/config_out/` is refreshed automatically.
16. **paperless-ngx requires Redis:** paperless-ngx depends on Redis as a Celery message broker for task processing (OCR, classification, indexing). Without Redis it will not start. The Redis Deployment runs ephemeral (no PVC) — it is a transient broker, so losing it loses only in-flight tasks, never documents. Redis is reachable only intra-namespace (`paperless-ngx-redis:6379`, no password).
17. **paperless-ngx uid 1000 vs `local-path` ownership:** The `paperless-ngx` image runs as uid 1000 and needs write access to the data PVC. The Deployment includes `securityContext.fsGroup: 1000`; if `local-path` does not honor it and the pod crashes with permission errors, add a root `initContainer` that `chown`-s the `/data` mount.
18. **paperless-ngx single-PVC with directory relocation:** paperless-ngx uses one PVC (`paperless-ngx-data`, `/data`) and relocates its data/media/consume directories under it via `PAPERLESS_DATA_DIR=/data/data`, `PAPERLESS_MEDIA_ROOT=/data/media`, `PAPERLESS_CONSUMPTION_DIR=/data/consume`. This keeps backup simple (one target). `local-path` default reclaim policy is `Delete` — if the app is removed from the kustomization, Flux prunes the PVC and all documents are lost. Back up `/data` out of band if it becomes important.
19. **Nextcloud reverse-proxy requires `trusted_proxies` + `overwritehost` via `extraEnv`, NOT `nextcloud.host`:** Behind Traefik, Nextcloud must trust the proxy's forwarded headers. The chart's `reverse-proxy.config.php` reads env vars (`OVERWRITEHOST`, `OVERWRITECLIURL`, `TRUSTED_PROXIES`, `OVERWRITEPROTOCOL`) and writes them to `$CONFIG`. But `nextcloud.host` only feeds `NEXTCLOUD_TRUSTED_DOMAINS` — it does NOT set `overwritehost` or `trusted_proxies`. Set these explicitly under `nextcloud.extraEnv`: `OVERWRITEHOST=sync.watchtoken.org`, `OVERWRITECLIURL=https://sync.watchtoken.org`, `TRUSTED_PROXIES=10.42.0.0/16` (k3s pod CIDR). Without these, sync clients see DAV hrefs pointing at `localhost`/`http` and fail with "Files not accessible on server." Symptom confirmed: `config.php` shows `overwrite.cli.url => 'https://localhost'` and no `overwritehost`/`trusted_proxies` entries. To fix a running instance immediately (before Flux re-reconciles), run `php occ config:system:set overwritehost --value=sync.watchtoken.org` + `trusted_proxies 0 --value=10.42.0.0/16` + `overwrite.cli.url --value=https://sync.watchtoken.org` as www-data inside the pod.
20. **Cloudflare Tunnel upload ceiling (~100 MB):** The Cloudflare free tier limits HTTP request bodies to ~100 MB through the tunnel. Large file uploads (videos, big archives) fail on the public `sync.watchtoken.org` route but work fine on LAN (`sync.local`). Photos and documents are unaffected.
21. **Two-PVC consistent backup required:** Nextcloud has two persistent volumes (data `/var/www/html` + MariaDB). They must be backed up together under maintenance mode (`occ maintenance:mode --on` → dump DB → copy data → `--off`). Backing up one without the other = data loss on restore.
22. **`overwritehost` is single-valued:** Setting it to `sync.watchtoken.org` means `.local` access generates public-host URLs for share links and WebDAV endpoints. This is expected and correct — the canonical hostname is the public one. Do not fight it with fragile workarounds.
 23. **`local-path` Delete reclaim on all PVCs:** Same as paperless-ngx (gotcha #18) — removing nextcloud from the root kustomization prunes all PVCs and their data. The chart's `helm.sh/resource-policy: keep` annotation prevents Helm uninstall from deleting them, but Flux pruning on kustomization removal will still delete them. Back up out of band.
 24. **In-cluster ClusterIP and public hostname are the SAME Forgejo registry:** The app CI pushes images to `10.43.55.141:3000` (the `forgejo-http` ClusterIP, plain HTTP) — but kubelet **cannot** pull from it: the nodes have no containerd mirror for the ClusterIP (k3s `registries.yaml` only mirrors `192.168.254.50:30080`). Pull from `fgit.watchtoken.org` (HTTPS, same registry via tunnel → Traefik → `forgejo-http:3000`) with an imagePullSecret in the workload's namespace. Never use the ClusterIP in an image reference.
 25. **spec-frontend chart/image must be published before deploy:** The app repo (`~/Projects/spec-frontend`) publishes its chart via a `v*` tag on main (CI `publish-chart` job, `helm-pusher`-less — the registry-account secrets live in Forgejo CI). The chart as of v0.1.0 shipped an invalid pod-level `readOnlyRootFilesystem` — fixed upstream (moved to the container `securityContext`); if a freshly published chart is rejected, check that fix. The image tag equals the chart's `appVersion` (`main-<sha>`); the HelmRelease leaves `image.tag` empty to follow it. Verify with `helm pull oci://fgit.watchtoken.org/forgejo-admin/spec-frontend --version <v>`.
 26. **spec-frontend credentials are derived, not invented:** `neo4j-creds` (SealedSecret in `spec-frontend` ns) is re-sealed from the in-cluster `neo4j-auth` secret (`kubectl get secret neo4j-auth -n neo4j -o jsonpath='{.data.NEO4J_AUTH}' | base64 -d` → `neo4j/<pw>`, strip the prefix) — the plaintext never enters git or chat. The `forgejo-registry-auth` imagePullSecret is a copy of the flux-system dockerconfigjson re-sealed for the workload namespace (pull secrets must be namespace-local).

## Forgejo Runner

The CI runner runs in `forgejo-runner` namespace, connects to the internal Forgejo
service (`forgejo-http.forgejo.svc:3000`). Uses Docker-in-Docker sidecar for
container builds. Labels: `ubuntu-latest` and `ubuntu-22.04` (both mapped to
`docker://node:22-bookworm`).

### Resource configuration

Sized for JVM-based workloads (Clojure/ClojureScript builds): job containers get
`--cpus=2 --memory=4g` via `runner.config.file.container.options`; runner
container limits 2000m/2Gi; dind sidecar limits 4000m/4Gi. Requests stay small
(100m, 128Mi/256Mi) to preserve headroom on the single-node cluster.

### Health check

```bash
# Pod status
kubectl get pods -n forgejo-runner

# Recent logs — should show "declared successfully" and "poller launched"
kubectl logs -n forgejo-runner deploy/forgejo-runner -c runner --tail=10

# Query Forgejo API for queued/active runs
kubectl exec -n forgejo-runner deploy/forgejo-runner -c runner -- wget -q -O- \
  http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1/repos/forgejo-admin/cv/actions/runs?limit=3

# Or via Forgejo UI: fgit.watchtoken.org → Settings → Actions → Runners
```

### When to restart

The runner can go silent after a task cancellation — the poller process stays
running but stops fetching new tasks. If a workflow run shows `status=waiting` in
Forgejo but the runner logs show no activity for several minutes, restart it:

```bash
kubectl rollout restart deploy/forgejo-runner -n forgejo-runner
```

The new pod registers within ~10 seconds and immediately picks up queued jobs.

### Re-registering with new labels

If the runner labels change in the HelmRelease, the runner must re-register.
Delete the old registration secret and restart:

```bash
kubectl delete secret forgejo-runner-config -n forgejo-runner
kubectl rollout restart deploy/forgejo-runner -n forgejo-runner
```

## Forgejo SSH

SSH access is available two ways:

| Path | Address | How |
|---|---|---|
| **LAN (direct)** | `ssh://git@192.168.254.50:30022` | NodePort 30022 on `forgejo-ssh` Service (in `helmrelease.yaml`) |
| **Public (tunnel)** | `git@ssh.watchtoken.org` | Cloudflare Tunnel + client `cloudflared` ProxyCommand |

The public SSH route is **Terraform-managed** (`terraform/tunnel.tf` ingress + `terraform/dns.tf` CNAME). It routes straight to `forgejo-ssh` (no Traefik). The SSH clone URL shown in the Forgejo UI is `git@ssh.watchtoken.org`.

### Client setup (one-time per machine)

```bash
# 1. Install cloudflared (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
# 2. Add to ~/.ssh/config:
: '
Host ssh.watchtoken.org
  ProxyCommand cloudflared access ssh --hostname %h
'
# 3. Authenticate (browser popup)
cloudflared access login ssh.watchtoken.org
```

### Verification

```bash
# LAN
ssh -T -p 30022 git@192.168.254.50

# Public (with ProxyCommand configured)
ssh -T git@ssh.watchtoken.org
```

Both should print the Forgejo greeting (`Hi <user>! You've successfully authenticated...`).

## Forgejo PostgreSQL (migration runbook)

Forgejo runs on the central PostgreSQL 18.3 instance at `192.168.254.104` (database `forgejo`, role `forgejo`, non-superuser). The SQLite-era data was migrated on 2026-08-11; a shutdown-consistent snapshot remains on the PVC at `/data/backup/forgejo-2026-08-11/` (checkpointed `forgejo.db` + `counts-sqlite.txt` + `forgejo-dump.zip`, 256 MB).

### Rollback runbook (only if a gate fails)

File operations run from a PVC-mounted pod (image `nouchka/sqlite3`, mount `gitea-shared-storage` at `/data`), since forgejo is scaled to 0 in both cases.

- **Phase A failure (lossless — forgejo never started on PG):** `rm -f /data/gitea/forgejo.db-wal /data/gitea/forgejo.db-shm` → `cp -a /data/backup/forgejo-2026-08-11/forgejo.db* /data/` (NOTE: the live DB path is `/data/forgejo.db`, NOT `/data/gitea/forgejo.db`) → revert `gitea.config.database` to `sqlite3` in git → push + merge → `flux reconcile kustomization flux-system -n flux-system --with-source` → reconcile-and-verify gate (release still suspended AND staged spec shows `DB_TYPE: sqlite3`) → `flux resume` → verify SQLite startup
- **Phase B hard failure (data-loss boundary applies):** `flux suspend helmrelease forgejo -n forgejo` FIRST → scale 0 → same PVC-pod file restore + git revert + gate as above → `flux resume`; the PostgreSQL database is retained as the authoritative copy of post-cutover writes

### Data-loss boundary

- Rollback to SQLite is **lossless only before forgejo has accepted post-cutover writes** on PostgreSQL (i.e. at the Phase A decision point, before normal traffic resumes)
- Any rollback after forgejo has accepted writes discards those writes
- Snapshot retention: the snapshot dir + dump zip stay on the PVC until the first successful monthly restore test (minimum 7 days)

## PostgreSQL backups (192.168.254.104)

The dedicated PostgreSQL box backs up both databases (`atuin`, `forgejo`) nightly at 02:30 via `/usr/local/bin/pg-backup.sh` (crontab as the `postgres` user, local peer auth). The wrapper dumps with `pg_dump -Fc --snapshot` and records dump-time primary-table counts in the SAME repeatable-read snapshot, so each `backup.log` line (`atuin`: `records`/`users`; `forgejo`: `user`/`repository`/`issue`/`action`) describes the exact dump content. Failures emit `pg_backup FAILED: <db>` on stdout (cron mail to the admin), log a `FAILED` line, and timestamp `/backups/postgres/last-failure`. Retention: 14 days (`find -mtime +14 -delete`). `/backups/postgres` is owned by `postgres:postgres`.

### Monthly restore test (manual)

Per database, most recent dump → restore into a scratch DB with `pg_restore --exit-on-error` → compare restored row counts against the most recent `backup.log` entry for that exact dump filename → drop the scratch DB. ANY failure — `pg_restore` exit != 0, a failing count query, or a count mismatch — emits a FAILED line and writes the `last-failure` sentinel (same alerting path as the nightly run). A successful test releases the migration snapshot retention hold (see Forgejo PostgreSQL).

## Neo4j

Graph database backend for a personal app. Neo4j Community (chart `5.26.28`, pinned in `helmrelease.yaml`), single instance, in the `neo4j` namespace.

### Access

| Path | Address | How |
|---|---|---|
| **Bolt (app)** | `bolt://192.168.254.50:30087` | NodePort 30087 → 7687 on `neo4j-lb-neo4j` service (chart sets `externalTrafficPolicy: Local`) |
| **Browser UI** | `http://neo4j.local:30080` | Traefik IngressRoute `Host(neo4j.local)` → ClusterIP service `neo4j` port `tcp-http` (7474) |

Auth: user `neo4j`, password from the `neo4j-auth` SealedSecret (key `NEO4J_AUTH`, value `neo4j/<password>`).

### Gotchas

1. **Pod is pinned to k3s-master — do not remove the `nodeSelector`:** `externalTrafficPolicy: Local` on the NodePort service means `192.168.254.50:30087` only answers on the node hosting the pod. The LAN endpoint is the master's IP, so the pod MUST stay on `k3s-master` (`nodeSelector: {kubernetes.io/hostname: k3s-master}` in HelmRelease values). Moving it silently breaks LAN bolt access.
2. **`passwordFromSecret` is initial-only:** Changing the `neo4j-auth` Secret does NOT change the database password. Rotate inside Neo4j first, then re-seal to match:
   ```bash
   # inside the pod (or via Browser):
   kubectl exec -it -n neo4j neo4j-0 -- cypher-shell -u neo4j -p '<old>' \
     "ALTER CURRENT USER SET PASSWORD FROM '<old>' TO '<new>'"
   # then re-seal neo4j-auth with the new password (see Secret Management above)
   ```
3. **`local-path` Delete reclaim:** The 10Gi data PVC is `local-path` (reclaim `Delete`) — removing `neo4j` from the root kustomization prunes all graph data. Back up out of band if it becomes important.
4. **Community edition = no Prometheus metrics:** `server.metrics.prometheus.enabled` is Enterprise-only. Don't add a ServiceMonitor for Neo4j on Community — it scrapes nothing.
5. **Image tag is unsuffixed for community:** the chart renders `neo4j:5.26.28` (community; only enterprise adds `-enterprise`). Don't add a suffix.

### Shell access

```bash
kubectl exec -it -n neo4j neo4j-0 -- cypher-shell -u neo4j -p '<password>'
```

## spec-frontend

Read-only browser over the Neo4j story graph (Project → Change → Story DAGs),
deployed from the app's own Helm chart (`spec-frontend` v0.2.4, pinned exactly)
via the shared `cv-datastar` OCI HelmRepository — no separate HelmRepository.

### Access

| Path | Address | How |
|---|---|---|
| **LAN** | `http://spec-frontend.local:30080` | Traefik IngressRoute `Host(spec-frontend.local)` → service `spec-frontend:80` (add `192.168.254.50 spec-frontend.local` to /etc/hosts) |
| **Public** | `https://spec.watchtoken.org` | Cloudflare tunnel → Traefik websecure, wildcard cert; `http://` 301-redirects via the shared `redirect-to-https` middleware |

**Auth:** HTTP Basic Auth is enforced by the app itself (not Traefik), on
**both** routes. Credentials come from the `BASIC_AUTH_USER` /
`BASIC_AUTH_PASSWORD` keys of the `neo4j-creds` SealedSecret (namespace
`spec-frontend`) — the chart's `existingSecret` `envFrom` injects every key as
an env var. The app exempts `GET /api/health` so the readiness probe stays
unauthenticated. The LAN route stays plain HTTP — accepted trust boundary
(home network); the protection target is the public route.

Neo4j creds: `neo4j-creds` SealedSecret (NEO4J_URI `bolt://neo4j.neo4j.svc:7687`),
injected by the chart's `existingSecret`. The app is strictly read-only
(MATCH-only guard in `src/sf/db` + tests, READ access mode) — the cluster does
not enforce this, it's the app's design.

**Rotating the Basic Auth password:** re-seal `neo4j-creds` with the new
`BASIC_AUTH_PASSWORD` (see Secret Management SOP), then `kubectl -n
spec-frontend rollout restart deploy/spec-frontend` — a Secret update via
`envFrom` does NOT restart the pod on its own.

### Version bump flow

1. App repo: fix/feature → tag `vX.Y.Z` on main → CI `build-image` pushes
   `forgejo-admin/spec-frontend:main-<sha>`, `publish-chart` pushes chart
   `X.Y.Z` with `appVersion: main-<sha>`.
2. This repo: bump the exact `version:` in `clusters/pk3s/spec-frontend/helmrelease.yaml`
   (leave `image.tag` empty — the chart's appVersion selects the matching image).
3. Reconcile (`flux reconcile kustomization flux-system -n flux-system
   --with-source`; the Kustomization is named `flux-system`, not `pk3s` — see
   gotcha #3) and check `kubectl -n spec-frontend get helmrelease` Ready + pod
   image tag matches the chart appVersion.

> Note: when a spec-frontend release changes auth-relevant behavior (e.g. adds
> `BASIC_AUTH_*` support), verify it against the target image with a throwaway
> pod (gate) before bumping — see the `spec-frontend-basic-auth` change history.

> Archive note (out of apply scope): after apply + verify pass, the
> `spec-frontend-basic-auth` delta spec is archived via the `openspec archive`
> flow so the five-key `neo4j-creds` secret and Basic Auth requirements land in
> the main spec (`openspec/specs/spec-frontend/spec.md`).

## Terraform Workflow

Terraform config lives in `terraform/`. Run locally after `terraform apply`:

```bash
# Lint before committing
cd terraform && make lint

# Or per-file
terraform fmt -check -diff

# Install pre-commit hooks (one-time)
make install-hooks
```

Hooks in `.githooks/pre-commit` check `terraform fmt` on staged `.tf` files.
SealedSecrets are generated locally with `scripts/seal-and-commit.sh`.

### Grafana dashboards (Terraform)

Grafana dashboards are **Terraform-managed** from `terraform/grafana/` (local
state in `terraform/grafana/terraform.tfstate`, not in S3). Dashboards are
authored as JSON in `terraform/grafana/dashboards/` — edit via the repo, not
the UI; manual UI edits are reverted on the next `terraform apply`
(`overwrite = true`).

**Auth** (env-driven, nothing committed):
- `GRAFANA_URL=http://grafana.local:30080`
- `GRAFANA_AUTH` — first apply: `admin:<admin-password>` (read from the
  `grafana-admin-secret` SealedSecret via a password manager). A `terraform`
  service account + token is created and recorded in state.
- Subsequent applies: set `GRAFANA_AUTH` to `terraform output -raw grafana_token`.

**Token rotation** (if token is lost or needs cycling):
```bash
cd terraform/grafana
GRAFANA_AUTH=admin:<admin-password> terraform apply -replace=grafana_service_account_token.terraform
terraform output -raw grafana_token   # new token
```

### Metric sources for custom dashboards
Several apps/components have explicit Prometheus metric scraping to feed the
custom dashboards:
- **Forgejo** (`clusters/pk3s/forgejo/`): `gitea.config.metrics.ENABLED: "true"`
  in the HelmRelease, plus a `ServiceMonitor` (`servicemonitor.yaml`) scraping
  the http port at `/metrics`.
- **cloudflared** (`clusters/pk3s/cloudflared/`): a dedicated `cloudflared-metrics`
  Service (`service-metrics.yaml`, port 2000) and a matching `ServiceMonitor`
  (`servicemonitor.yaml`). cloudflared already serves metrics on `:2000` via
  `--metrics 0.0.0.0:2000` but was not scraped before.
- **Flux controllers** (`clusters/pk3s/flux-monitoring/`): four `PodMonitor`s
  (one per controller — source, kustomize, helm, notification) scrape the
  `http-prom` port (8080) at `/metrics`. Uses `PodMonitor` rather than
  `ServiceMonitor` because the flux-system Services are operator-owned
  (`ssa: Ignore`) and only expose port 80→9090, not the metrics port 8080.
  Feeds the **Flux GitOps** dashboard (reconcile rate, errors, duration,
  per-resource churn). Prometheus discovers them via the existing
  `podMonitorSelectorNilUsesHelmValues: false` — no monitoring HelmRelease
  change.

## Flux Telegram Alerts

Flux reconciliation failures are proactively alerted via Telegram. When a
Kustomization, HelmRelease, or Source (GitRepository/HelmRepository/OCIRepository/Bucket)
fails for 5+ minutes, Prometheus fires an alert → Alertmanager → Telegram.

```
Flux controllers  →  PrometheusRule (flux-alerts)  →  Alertmanager  →  Telegram API
    (metrics)           (eval every 30s, 5m for)       (config from       (bot)
                                                        SealedSecret)
```

### Alert rules (3)

| Rule | Metric | For |
|---|---|---|
| `KustomizationFailed` | `gotk_reconcile_condition{status="False", kind="Kustomization"}` | 5m |
| `HelmReleaseFailed` | `gotk_reconcile_condition{status="False", kind="HelmRelease"}` | 5m |
| `SourceFailed` | `gotk_reconcile_condition{status="False", kind=~"GitRepository\|HelmRepository\|OCIRepository\|Bucket"}` | 5m |

### Routing behavior

- Alerts grouped by `alertname` + `namespace` (one Telegram message per alert type)
- First alert sent immediately (10s `group_wait`)
- New alerts in same group wait 5 min before sending
- Repeat every 4 hours while unresolved

### Rotating Telegram credentials

```bash
cd ~/Projects/homelab-apps
printf 'bot_token: '; IFS= read -rs BOT; echo
printf 'chat_id: '; IFS= read -rs CID; echo
cat <<SEOF | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml --namespace monitoring > clusters/pk3s/monitoring/sealedsecret-alertmanager-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'telegram'
    receivers:
      - name: 'telegram'
        telegram_configs:
          - bot_token: '$BOT'
            chat_id: $CID
            parse_mode: 'HTML'
SEOF
unset BOT CID
```

Then commit and push. Flux syncs automatically; the Prometheus Operator detects
the updated secret and reloads Alertmanager within ~1 minute (no pod restart needed).

### Adding new receivers

To add a notification channel (e.g., email, Slack) alongside Telegram:

1. Add a second receiver to `receivers:` in the `alertmanager.yaml` config above.
2. Optionally create a route for specific alerts. The default route (matches all)
   sends to `telegram` — additional routes must match specific matchers.
3. Re-seal and commit the updated config.

### Files

| File | Purpose |
|---|---|
| `monitoring/prometheusrule-flux.yaml` | PrometheusRule with 3 Flux alert rules |
| `monitoring/sealedsecret-alertmanager-config.yaml` | Alertmanager config (Telegram credentials sealed) |
| `monitoring/helmrelease.yaml` | References `configSecret: alertmanager-config` |

### Verification

```bash
# Prometheus rules exist
kubectl get prometheusrule -n monitoring flux-alerts -o yaml

# Alertmanager has Telegram config
kubectl get secret -n monitoring alertmanager-config -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -15

# Alertmanager actively using it
kubectl exec -n monitoring alertmanager-prometheus-alertmanager-0 -c config-reloader \
  -- cat /etc/alertmanager/config_out/alertmanager.env.yaml

# Rules firing? (port-forward prometheus-prometheus-prometheus-0:9090)
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[] | select(.name=="flux")'
```

### Shell access

```bash
# Runner container
kubectl exec -it -n forgejo-runner deploy/forgejo-runner -c runner -- /bin/sh

# Docker-in-Docker sidecar
kubectl exec -it -n forgejo-runner deploy/forgejo-runner -c dind -- /bin/sh
```
