# homelab-apps — GitOps Guide for AI Agents

## Project Overview

GitOps repository for a **two-node k3s v1.36.4 homelab cluster** managed by **Flux Operator**
(FluxInstance `flux`, distribution 2.8.x). The cluster syncs from this repo
(`github.com/aplacaba/homelab-apps.git`) at `./clusters/pk3s`.

| Aspect | Detail |
|---|---|
| **Cluster** | pk3s — `k3s-master` (192.168.254.50, control plane) + `k3s-media` (192.168.254.109, label/taint `media=yes`); k3s v1.36.4+k3s1 on Debian 13 (trixie) |
| **GitOps** | Flux Operator (FluxInstance), one-way sync from GitHub; controllers `source`, `kustomize`, `helm`, `notification` |
| **Sync cadence** | GitRepository polls every **1m**, root Kustomization re-applies every **10m** (`prune: true`), each HelmRelease reconciles on its own interval (1h) |
| **Ingress** | Traefik v3.7 (chart 41.4.0) with IngressRoute CRD, NodePort 30080/30443 |
| **TLS** | cert-manager v1.20 + Let's Encrypt DNS-01 (Cloudflare) wildcard `*.watchtoken.org`; terminated on Traefik |
| **Auth** | None (previously Authentik) |
| **Tunnel** | Cloudflare Tunnel (cloudflared) for `alacaba.org`, `cv.alacaba.org`, `cv.watchtoken.org`, `fgit.watchtoken.org`, `ssh.watchtoken.org`, `sync.watchtoken.org`, `history.watchtoken.org`, `spec.watchtoken.org`, `budget.watchtoken.org`, `papra.watchtoken.org`, `hris.alacaba.org`. HTTPS hostnames route to Traefik `:443` (No TLS Verify); `ssh.watchtoken.org` routes directly to `forgejo-ssh` (raw TCP, no Traefik). Everything else public is 404 at the tunnel. |
| **Secrets** | SealedSecrets (`sealed-secrets` chart 2.5.19, controller 0.31.0) — encrypted at rest, master key backed up offline |
| **Internal DNS** | `.local` domains via `/etc/hosts` → `192.168.254.50:30080` |
| **Storage** | `local-path` (k3s built-in, master) + `media-local-path` (dedicated provisioner pinned to `k3s-media`) |
| **Forgejo** | `fgit.watchtoken.org` — self-hosted Git + Actions + Container Registry (Forgejo 15.0.6). SSH: LAN `ssh://git@192.168.254.50:30022`, public `git@ssh.watchtoken.org` (requires `cloudflared` ProxyCommand). |

## GitOps Workflow — git first, never manual kubectl

All cluster changes flow through this repo. Flux applies with server-side apply
and **reverts out-of-band changes** (`kubectl apply/edit/scale`) on the next
sync — manual cluster surgery is wasted work. Never `kubectl scale` to
deactivate an app (see Media Stack Rollback); commit `replicas: 0` instead.
`flux suspend/resume` is the only sanctioned manual action (migrations only).

1. Edit manifests under `clusters/pk3s/<app>/`, commit, push.
2. Let Flux pick it up — the GitRepository polls every **1m** and the root Kustomization re-applies
   every **10m**, so a push normally lands within a minute or two. Do NOT force a reconcile just to
   speed it up; watch it land instead:
   ```bash
   flux get kustomization flux-system -n flux-system
   ```
3. Verify before considering the change applied:
   `kubectl -n flux-system get kustomization,helmrelease` — all `True`.

`flux reconcile` is the exception, not the routine — reserve it for when a
change must land now (e.g. verifying a fix, un-sticking a failed sync).

## Directory Structure

```
AGENTS.md                      # short entry point loaded as workspace instructions
docs/
├── AGENT_INSTRUCTIONS.md      # ← this guide
├── papra.md                   # Papra runbook (ingestion, backup, probes)
├── cv-datastar-commands.md    # CV site release commands
├── patterns.md                # Reusable manifest patterns
├── authentik-forward-auth.md  # LEGACY — Authentik was removed; kept for history
└── superpowers/               # gitignored design docs/plans
.github/workflows/
└── terraform-cloudflare.yml   # fmt/validate/plan/apply on terraform/** (GitHub Actions)

terraform/
├── dns.tf              # Cloudflare DNS records
├── main.tf             # Cloudflare tunnel & vars
├── providers.tf        # Cloudflare provider + S3 backend
├── tokens.tf           # cert-manager API tokens
├── tunnel.tf           # Cloudflare tunnel ingress config
├── zone-settings.tf    # Zone security settings
├── r2.tf               # R2 bucket for HRIS uploads
├── outputs.tf          # Terraform outputs
├── Makefile            # Lint, fmt-check, validate (both roots)
├── scripts/            # seal-and-commit.sh helper
└── grafana/            # Grafana dashboard provisioning (local state)
    ├── providers.tf
    ├── variables.tf
    ├── bootstrap.tf
    ├── folders.tf
    ├── dashboards.tf
    ├── outputs.tf
    └── dashboards/*.json

clusters/pk3s/
├── kustomization.yaml         # Root — lists all app directories
├── atuin/                     # Atuin 18.17 shell history sync (raw manifests, external PostgreSQL at 192.168.254.104) — public history.watchtoken.org
├── actual-budget/             # Actual Budget 26.8 personal finance (raw manifests, SQLite on 2Gi PVC) — LAN budget.local, public budget.watchtoken.org
├── cert-manager/              # cert-manager v1.20 + Let's Encrypt DNS-01 (Cloudflare) ClusterIssuers + sealed CF token
├── cloudflared/               # Cloudflare Tunnel (raw manifests; token is a SealedSecret)
├── cv-datastar/               # CV site, chart 0.3.0 — served at alacaba.org (landing `/`, CV `/cv/`); cv.alacaba.org + cv.watchtoken.org 301 → alacaba.org/cv (OCI registry)
├── floci/                     # FLOCI tool (raw manifests, `floci/floci:latest`) — LAN floci.local
├── flux-dashboard/            # Flux web UI (raw manifests) — LAN fluxops.local
├── flux-monitoring/           # PodMonitors for the four Flux controllers (scraped by Prometheus)
├── forgejo/                   # Git + Actions + Registry (chart 17.1.4 → Forgejo 15.0.6, external PostgreSQL) — fgit.watchtoken.org
├── forgejo-runner/            # CI runner (chart 0.7.6 → runner 12.7.3 + DinD)
├── hris/                      # TALA HRIS applicant tracking (Rails 8 chart from GHCR, 4 external PG DBs, R2 storage) — public hris.alacaba.org
├── media/                     # Media stack on the k3s-media node (immich chart 0.13.1 + raw manifests) — all LAN-only *.local
├── monitoring/                # kube-prometheus-stack 87.0.1 + Loki 7.0.0 + Promtail 6.17.1 + Flux alerts — LAN grafana.local
├── neo4j/                     # Neo4j graph database (chart 5.26.28) — LAN neo4j.local + NodePort 30087
├── nextcloud/                 # File sync & share (chart 9.2.6 → Nextcloud 34.0.3 + MariaDB/Redis subcharts) — LAN sync.local, public sync.watchtoken.org
├── pangolin/                  # Pangolin newt agent 1.12.3 → VPS relay for public jellyfin/seerr (chart 1.4.0, no ingress)
├── papra/                     # Document archiving / OCR (raw manifests, Papra 26.6.1 on a 10Gi PVC) — public papra.watchtoken.org, no LAN route
├── pve/                       # Internal Proxmox VE web UI route — pve.local → 192.168.254.165:8006 (raw manifests)
├── sealed-secrets/            # SealedSecrets controller (Bitnami chart 2.5.19, decrypts in-cluster)
├── spec-frontend/             # Read-only Neo4j story-graph browser (chart 0.2.4) — LAN spec-frontend.local, public spec.watchtoken.org
├── traefik/                   # Ingress controller (chart 41.4.0 → Traefik v3.7.12, NodePort 30080/30443)
└── watcharr/                  # Media watch list / tracker 4.2.1 (raw manifests, SQLite on a 5Gi PVC) — LAN watcharr.local
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
| `neo4j` | default | `https://neo4j.github.io/helm-charts` | neo4j |
| `fossorial` | default | `https://charts.fossorial.io` | pangolin (newt) |
| `immich` | OCI | `oci://ghcr.io/immich-app/immich-charts` | media (immich) |
| `hris-charts` | OCI | `oci://ghcr.io/aplacaba/charts` | hris (needs `ghcr-registry-auth` in flux-system) |

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

Two nodes — `k3s-master` (192.168.254.50) and `k3s-media` (192.168.254.109, tainted
`media=yes:NoSchedule`) — with everything below reconciled from `clusters/pk3s/`:

| Namespace | What runs there | Reached as |
|---|---|---|
| `flux-system` | Flux Operator + the four controllers, HelmRepositories, `flux-dashboard` UI (`flux-operator:9080`) | LAN `fluxops.local` |
| `traefik` | Ingress controller (chart 41.4.0 → Traefik v3.7.12), wildcard `*.watchtoken.org` Certificate + default TLSStore | NodePort 30080 (`web`) / 30443 (`websecure`) |
| `cloudflared` | Cloudflare Tunnel connector (metrics on `:2000`, scraped) | — (dials out) |
| `cert-manager` | cert-manager v1.20 + Let's Encrypt DNS-01 ClusterIssuers | — |
| `sealed-secrets` | SealedSecrets controller (chart 2.5.19) | — |
| `forgejo` | Forgejo 15.0.6 + Actions + OCI registry (`forgejo-http:3000`, `forgejo-ssh:22`) | public `fgit.watchtoken.org`, SSH NodePort 30022 |
| `forgejo-runner` | CI runner 12.7.3 + DinD sidecar | — |
| `atuin` | Atuin 18.17 server (`atuin:8888`), external PostgreSQL | public `history.watchtoken.org` |
| `actual-budget` | Actual Budget 26.8, SQLite on a 2Gi PVC | LAN `budget.local`, public `budget.watchtoken.org` |
| `cv-datastar` | CV site (chart 0.3.0) | `alacaba.org`, `cv.alacaba.org`, `cv.watchtoken.org`, LAN `cv.local` |
| `floci` | FLOCI tool, 5Gi PVC | LAN `floci.local` |
| `hris` | TALA HRIS (Rails 8), chart range `>=0.1.0 <1.0.0`, 4 external PG databases | public `hris.alacaba.org` |
| `media` | jellyfin, seerr, immich 3.0 (+valkey), *arr suite, the VPN'd download pod, flaresolverr, shelfmark — pinned to `k3s-media` | LAN `*.local` only (friends reach jellyfin/seerr through the Pangolin VPS) |
| `monitoring` | kube-prometheus-stack 87.0.1 (Prometheus 3.12, 7d retention; Grafana 13.0.2), Loki 3.6.7 + Promtail 3.5.1, Alertmanager → Telegram | LAN `grafana.local` |
| `neo4j` | Neo4j 5.26.28 Community, pinned to `k3s-master` | LAN `neo4j.local`, Bolt NodePort 30087 |
| `nextcloud` | Nextcloud 34.0.3 + MariaDB + Redis (100Gi/8Gi/5Gi PVCs) | LAN `sync.local`, public `sync.watchtoken.org` |
| `pangolin` | newt 1.12.3 agent (chart 1.4.0) → Pangolin VPS relay | — (dials out over WireGuard) |
| `papra` | Papra 26.6.1, 10Gi PVC + hostPath ingest folder | public only: `papra.watchtoken.org` |
| `pve` | Reverse proxy to Proxmox VE `192.168.254.165:8006` | LAN `https://pve.local` (self-signed) |
| `spec-frontend` | Neo4j story-graph browser (chart 0.2.4) | LAN `spec-frontend.local`, public `spec.watchtoken.org` |
| `watcharr` | Watcharr 4.2.1, 5Gi PVC | LAN `watcharr.local` |
| `kube-system` | k3s internals: coredns 1.14.6, metrics-server 0.9.0, local-path-provisioner 0.0.37, svclb | — |

Stray resources **not** managed by Flux (leftovers from earlier node work, safe to delete by hand):
the `debug-tmp` namespace plus two `Completed` `node-debugger-k3s-master-*` pods — one in
`debug-tmp`, one in `default` (reconcile activity does not touch them).

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

## Cluster Inventory (verified 2026-09-13)

Everything here was read back from the running cluster; use it as the baseline when a change is
about to touch an app.

### HelmReleases

| Namespace | Release | Chart version |
|---|---|---|
| cert-manager | cert-manager | v1.20.2 |
| cv-datastar | cv-datastar | 0.3.0 |
| forgejo | forgejo | 17.1.4 |
| forgejo-runner | forgejo-runner | 0.7.6 |
| neo4j | neo4j | 5.26.28 |
| nextcloud | nextcloud | 9.2.6 |
| traefik | traefik | 41.4.0 |
| monitoring | kube-prometheus-stack / loki / promtail | 87.0.1 / 7.0.0 / 6.17.1 |
| media | immich | 0.13.1 |
| pangolin | newt | 1.4.0 |
| sealed-secrets | sealed-secrets | 2.5.19 |
| spec-frontend | spec-frontend | 0.2.4 |
| hris | hris | `>=0.1.0 <1.0.0` (currently 0.1.1) |

Raw-manifest apps (no HelmRelease): atuin 18.17.1, actual-budget 26.8.1, cloudflared 2026.6.1,
floci (`floci/floci:latest`), papra 26.6.1-rootless, watcharr v4.2.1, pve (proxy only), and the
media Deployments — jellyfin `version-12.0ubu2604`, seerr v3.4.1, shelfmark v1.3.9, immich valkey
9.1, flaresolverr `:latest`, and the LSIO *arr/download apps tracking `:latest`.

### Persistent volumes

| Namespace | PVC (storage class) | Size |
|---|---|---|
| actual-budget | `actual-budget-data` (local-path) | 2Gi |
| atuin | `atuin-config` (local-path) | 100Mi |
| floci | `floci-data` (local-path) | 5Gi |
| forgejo | `gitea-shared-storage` (local-path) | 10Gi |
| forgejo-runner | `dind-data` (local-path) | 20Gi |
| papra | `papra-data` (local-path) | 10Gi |
| watcharr | `watcharr-data` (local-path) | 5Gi |
| neo4j | `data-neo4j-0` (local-path) | 10Gi |
| nextcloud | `nextcloud-nextcloud` / `data-nextcloud-mariadb-0` / `redis-data-nextcloud-redis-master-0` | 100Gi / 8Gi / 5Gi |
| monitoring | prometheus / loki / grafana / alertmanager | 20Gi / 10Gi / 5Gi / 5Gi |
| media | `immich-library` + ten 2Gi app-config PVCs (media-local-path) | 200Gi + 20Gi |

Every one of these is reclaim `Delete`: removing an app from the root kustomization prunes its
volumes, and the data with them (see the gotcha list).

## Documentation Updates

After making implementation changes, update this guide to reflect the new state:

- **New app deployed** → Add to Directory Structure and Existing HelmRepositories (if new chart source)
- **New HelmRepository added** → Add to the HelmRepositories table
- **New gotcha discovered** → Add to Common Gotchas
- **Architecture changes** → Update Architecture Notes (cluster layout, cross-ns refs, public vs internal)
- **New operational procedure** → Add relevant section (health checks, restart procedures, shell access)

This document is the full guide for AI agents working in this repo — keep it accurate. It is reached
from [`AGENTS.md`](../AGENTS.md), the short entry point that carries the non-negotiable rules; this
file holds the detail (cluster layout, conventions, per-app runbooks, gotchas).

## Common Gotchas

1. **Chart ingress vs IngressRoute:** If writing a manual IngressRoute, always disable the chart's built-in ingress.
2. **OCI registry auth:** Charts pushed to `fgit.watchtoken.org` need a `forgejo-registry-auth` docker-registry Secret in `flux-system`.
3. **Reconciliation lag:** the GitRepository polls every 1m and the root Kustomization re-applies every 10m, so a push normally lands in a minute or two — push and wait, don't force. If a change must land now, `flux reconcile kustomization flux-system -n flux-system --with-source` (the root Kustomization is named `flux-system`, NOT `pk3s` — see GitOps Workflow).
4. **Local chart deployment:** Can't use upstream HelmRepository for local charts. Package → push to OCI registry → HelmRelease with `type: oci`.
5. **Runner goes silent after cancellation:** The Forgejo runner can stop picking up jobs after a task is cancelled (poller process stays alive but doesn't fetch). Symptom: `status=waiting` in Forgejo UI but no recent runner logs. Fix: `kubectl rollout restart deploy/forgejo-runner -n forgejo-runner`.
6. **Runner labels must match workflow `runs-on`:** Runner labels are set at `runner.config.file.runner.labels` (not `runner.file.runner.labels`). Mismatch → jobs queue forever. If labels change, delete the `forgejo-runner-config` secret and restart.
7. **Bitnami charts are OCI:** Bitnami migrated to `oci://registry-1.docker.io/bitnamicharts`. An HTTP-typed `HelmRepository` fails with `unsupported protocol scheme "oci"` — declare it `type: oci` (see `sealed-secrets/helmrepository.yaml`).
8. **Loki requires `auth_enabled: false` for Promtail:** The Loki chart defaults `auth_enabled: true`, which requires a tenant ID (X-Scope-OrgID) header. Promtail requests get 401 without it. For single-tenant homelabs, set `loki.auth_enabled: false` in the Loki HelmRelease values.
9. **cert-manager CRD bootstrap is two-phase:** cert-manager's own CRDs (`ClusterIssuer`, `Certificate`) are installed by its HelmRelease, but if those CR objects sit in the *same* Flux kustomization pass, the dry-run aborts (`no matches for kind "Certificate"`) before cert-manager ever installs — deadlock. Fix: install cert-manager first (unreference the CRD-dependent objects), wait for CRDs, then re-add them. See `cert-manager/` history.
10. **Wildcard cert is a Traefik default TLSStore (cross-ns):** The `*.watchtoken.org` `Certificate` lives in `traefik` ns and is wired to a `default` TLSStore, so any app's IngressRoute just needs `entryPoints: [websecure]` + `tls: {}` — no per-route `secretName`. `allowCrossNamespace` (already on) makes this work across namespaces.
11. **HTTP→HTTPS redirect must be host-scoped, not global:** Do NOT use `ports.web.redirections.entryPoint` — it would redirect `*.local` (→ https, no cert/route) and break LAN access. Use the shared `redirect-to-https` Middleware (in `traefik/middlewares`) attached only to `*.watchtoken.org` routes on `web`.
12. **alacaba-family TLS is a per-host Certificate, not the default TLSStore:** the Traefik default TLSStore holds only `*.watchtoken.org` (gotcha #10). `alacaba.org` / `cv.alacaba.org` websecure IngressRoutes MUST pin `tls.secretName: cv-alacaba-org-tls` explicitly (cert-manager `Certificate cv-alacaba-org` in the cv-datastar namespace, DNS-01 via the alacaba Cloudflare token). The `cv-datastar-apex` IngressRoute even routes public HTTP (no TLS verify at the tunnel origin), so the cert only needs to be valid for browsers — the tunnel hop skips verification.
13. **Cloudflare `always_use_https` upgrades public HTTP before the tunnel:** both zones have `always_use_https = on` (`terraform/zone-settings.tf`). Public `http://` requests to proxied hosts are 301'd to HTTPS at the Cloudflare edge BEFORE reaching Traefik — Traefik's `web` entrypoint `redirect-to-https` middleware only serves LAN/direct connections (e.g. port 30080 with a public `Host` header). Redirect chains off public HTTP are therefore two hops (edge upgrade → Traefik host redirect).
14. **Cloudflare tunnel origin = `https://traefik.traefik.svc:443` with No TLS Verify:** The cert is `*.watchtoken.org` but cloudflared connects to host `traefik.traefik.svc`, so strict verify fails (502). Each public hostname in the Zero Trust dashboard uses `https://traefik.traefik.svc:443` + **No TLS Verify ON**. The hop is still TLS-encrypted; verification is skipped (fine — tunnel is already encrypted + intra-cluster hop).
15. **Grafana admin credentials are a SealedSecret, not plaintext:** Grafana admin auth is no longer the default `admin/admin` in the HelmRelease. The password is stored in `monitoring/sealedsecret-grafana-admin.yaml` (keys `admin-user` and `admin-password`), and the HelmRelease references it via `grafana.admin.existingSecret: grafana-admin-secret`. To rotate the Grafana password, re-seal into that `SealedSecret` — do not edit the HelmRelease values directly.
16. **cloudflared access SSH bypasses Traefik:** Public SSH (`ssh.watchtoken.org`) does NOT route through Traefik. The tunnel ingress routes directly to `forgejo-ssh.forgejo.svc:22` (raw TCP). This is configured in Terraform (`terraform/tunnel.tf`), not the dashboard. Do NOT add a Traefik TCP entryPoint for SSH — the tunnel handles it without one.
17. **Alertmanager configSecret propagation takes ~1 minute:** The Prometheus Operator watches the `alertmanager-config` Secret. When updated (via SealedSecret re-seal), the operator reads it, generates a new intermediate secret, and the Alertmanager config-reloader picks it up within ~1 minute. No pod restart needed — the StatefulSet config-volume is not updated, but the generated config file in `/etc/alertmanager/config_out/` is refreshed automatically.
18. **Papra is public-HTTPS-only (no LAN route):** Papra's auth (Better Auth) sets Secure session cookies when `APP_BASE_URL` is HTTPS, so cookie login can never work over plain HTTP `*.local`. LAN clients use `https://papra.watchtoken.org` (same pattern as nextcloud). Do not add a `papra.local` IngressRoute.
19. **Papra signup is blocked at Traefik, not in-app:** the `AUTH_IS_REGISTRATION_ENABLED` flag only hides the UI and disables OAuth sign-up — direct `POST /api/auth/sign-up/email` stays open (verified at `@papra/app@26.6.1`). The `papra-block-signup` IngressRoute (ipAllowList `127.0.0.1/32` → 403) is the actual control; keep it. When testing the block directly, send an explicit `Host: papra.watchtoken.org` header — a `--resolve` request to port 30443 puts the port in the Host and matches no router (404).
20. **Papra single-PVC with quiesced backup:** Papra stores SQLite db + document originals on one 10Gi `local-path` PVC (`papra-data`, `/app/app-data`, reclaim `Delete`). Removing `papra` from the root kustomization wipes all documents. Backup: commit `replicas: 0` → wait for pod termination → mount the PVC read-only in a throwaway helper pod and copy `/app/app-data` out → commit `replicas: 1`. No Papra CLI export command exists (import only) — never rely on a live SQLite file copy.
21. **Nextcloud reverse-proxy requires `trusted_proxies` + `overwritehost` via `extraEnv`, NOT `nextcloud.host`:** Behind Traefik, Nextcloud must trust the proxy's forwarded headers. The chart's `reverse-proxy.config.php` reads env vars (`OVERWRITEHOST`, `OVERWRITECLIURL`, `TRUSTED_PROXIES`, `OVERWRITEPROTOCOL`) and writes them to `$CONFIG`. But `nextcloud.host` only feeds `NEXTCLOUD_TRUSTED_DOMAINS` — it does NOT set `overwritehost` or `trusted_proxies`. Set these explicitly under `nextcloud.extraEnv`: `OVERWRITEHOST=sync.watchtoken.org`, `OVERWRITECLIURL=https://sync.watchtoken.org`, `TRUSTED_PROXIES=10.42.0.0/16` (k3s pod CIDR). Without these, sync clients see DAV hrefs pointing at `localhost`/`http` and fail with "Files not accessible on server." Symptom confirmed: `config.php` shows `overwrite.cli.url => 'https://localhost'` and no `overwritehost`/`trusted_proxies` entries. To fix a running instance immediately (before Flux re-reconciles), run `php occ config:system:set overwritehost --value=sync.watchtoken.org` + `trusted_proxies 0 --value=10.42.0.0/16` + `overwrite.cli.url --value=https://sync.watchtoken.org` as www-data inside the pod.
22. **Cloudflare Tunnel upload ceiling (~100 MB):** The Cloudflare free tier limits HTTP request bodies to ~100 MB through the tunnel. Large file uploads (videos, big archives) fail on the public `sync.watchtoken.org` route but work fine on LAN (`sync.local`). Photos and documents are unaffected.
23. **Consistent multi-PVC backup required:** Nextcloud spans **three** volumes — `nextcloud-nextcloud` 100Gi (`/var/www/html`), `data-nextcloud-mariadb-0` 8Gi and `redis-data-nextcloud-redis-master-0` 5Gi. Data + database must be backed up together under maintenance mode (`occ maintenance:mode --on` → dump DB → copy data → `--off`); the Redis volume is a cache and can be rebuilt. Backing up the data volume without the database = data loss on restore.
24. **`overwritehost` is single-valued:** Setting it to `sync.watchtoken.org` means `.local` access generates public-host URLs for share links and WebDAV endpoints. This is expected and correct — the canonical hostname is the public one. Do not fight it with fragile workarounds.
25. **`local-path` Delete reclaim on all PVCs:** Same as papra (gotcha #20) — removing nextcloud from the root kustomization prunes all PVCs and their data. The chart's `helm.sh/resource-policy: keep` annotation prevents Helm uninstall from deleting them, but Flux pruning on kustomization removal will still delete them. Back up out of band.
26. **In-cluster ClusterIP and public hostname are the SAME Forgejo registry:** The app CI pushes images to `10.43.55.141:3000` (the `forgejo-http` ClusterIP, plain HTTP) — but kubelet **cannot** pull from it: the nodes have no containerd mirror for the ClusterIP (k3s `registries.yaml` only mirrors `192.168.254.50:30080`). Pull from `fgit.watchtoken.org` (HTTPS, same registry via tunnel → Traefik → `forgejo-http:3000`) with an imagePullSecret in the workload's namespace. Never use the ClusterIP in an image reference.
27. **spec-frontend chart/image must be published before deploy:** The app repo (`~/Projects/spec-frontend`) publishes its chart via a `v*` tag on main (CI `publish-chart` job, `helm-pusher`-less — the registry-account secrets live in Forgejo CI). The chart as of v0.1.0 shipped an invalid pod-level `readOnlyRootFilesystem` — fixed upstream (moved to the container `securityContext`); if a freshly published chart is rejected, check that fix. The image tag equals the chart's `appVersion` (`main-<sha>`); the HelmRelease leaves `image.tag` empty to follow it. Verify with `helm pull oci://fgit.watchtoken.org/forgejo-admin/spec-frontend --version <v>`.
28. **spec-frontend credentials are derived, not invented:** `neo4j-creds` (SealedSecret in `spec-frontend` ns) is re-sealed from the in-cluster `neo4j-auth` secret (`kubectl get secret neo4j-auth -n neo4j -o jsonpath='{.data.NEO4J_AUTH}' | base64 -d` → `neo4j/<pw>`, strip the prefix) — the plaintext never enters git or chat. The `forgejo-registry-auth` imagePullSecret is a copy of the flux-system dockerconfigjson re-sealed for the workload namespace (pull secrets must be namespace-local).
29. **Media public DNS must stay gray-clouded:** the `watchtoken.org` apex plus `seerr`/`pangolin` A records (`proxied = false`) route straight to the Pangolin VPS. Setting `proxied = true` (or a stray wildcard A record) would send video through Cloudflare — a ToS §2.8 violation at 4-6 concurrent streams.
30. **Pangolin VPS is not in git:** `/opt/pangolin` (config + SQLite) is backed up weekly via a systemd timer on the master (`pangolin-backup.timer`, Sun 02:30) → `/home/backups/pangolin`. A VPS rebuild = reinstall + restore dir; newt credentials are unchanged so the cluster side needs nothing.
31. **CrowdSec can block friends:** residential IPs occasionally carry bad reputation. Unblock via `docker compose exec crowdsec cscli decisions delete --ip <ip>` and whitelist with `cscli decisions add --ip <ip> --duration 999999h --type whitelist` (run in `/opt/pangolin` on the VPS).
32. **actual-budget data is a single small PVC:** Actual Budget stores its SQLite DB + user files on a 2Gi `local-path` PVC (`actual-budget-data`, `/data`). Reclaim is `Delete` — removing the app from the root kustomization wipes your budget. Actual's built-in "Export data" (Settings → Export data) is the off-cluster recovery path; run it before any destructive change.

33. **Most of the media stack tracks `:latest`:** bazarr, lidarr, prowlarr, radarr, sonarr, qbittorrent,
sabnzbd, flaresolverr and floci carry no tag pin, so a pod restart can silently change the version —
"what is running" is not recorded in git for those. Jellyfin is the deliberate exception (pinned
`version-12.0ubu2604` with its own upgrade SOP). Pin a tag here when a version must be reproducible.

34. **Flux itself is managed by the FluxInstance, not by per-controller manifests:** `flux-instance.yaml`
declares distribution `2.8.x` plus the four components, and the Flux Operator re-renders the
controllers (`fluxcd.controlplane.io/reconcileEvery: "1h"`). Upgrading Flux means editing that file;
there are no controller Deployments to bump by hand.


## Forgejo Runner

The CI runner (runner 12.7.3) runs in `forgejo-runner` namespace, connects to the internal Forgejo
service (`forgejo-http.forgejo.svc:3000`). Uses a Docker-in-Docker sidecar (docker 29.5-dind) for
container builds. Labels: `ubuntu-latest` and `ubuntu-22.04` (both mapped to
`docker://node:22-bookworm`).

### Resource configuration

Sized for JVM-based workloads (Clojure/ClojureScript builds): job containers get
`--cpus=2 --memory=4g` via `runner.config.file.container.options`; runner
container limits 2000m/2Gi; dind sidecar limits 4000m/4Gi. Requests stay small
(100m, 128Mi/256Mi) to preserve headroom on `k3s-master` — the media node is
tainted and carries its own budget.

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

Forgejo runs on the central PostgreSQL 18.3 instance at `192.168.254.104` (database `forgejo`, role `forgejo`, non-superuser). The SQLite-era data was migrated on 2026-08-11; a shutdown-consistent snapshot is still on the PVC at `/data/backup/forgejo-2026-08-11/` (verified 2026-09-13: checkpointed `forgejo.db`, `forgejo-data.sql`, `counts-sqlite.txt`, `forgejo-dump.zip` ≈ 256 MB).

### Rollback runbook (only if a gate fails)

File operations run from a PVC-mounted pod (image `nouchka/sqlite3`, mount `gitea-shared-storage` at `/data`), since forgejo is scaled to 0 in both cases.

- **Phase A failure (lossless — forgejo never started on PG):** `rm -f /data/gitea/forgejo.db-wal /data/gitea/forgejo.db-shm` → `cp -a /data/backup/forgejo-2026-08-11/forgejo.db* /data/` (NOTE: the live DB path is `/data/forgejo.db`, NOT `/data/gitea/forgejo.db`) → revert `gitea.config.database` to `sqlite3` in git → push + merge → `flux reconcile kustomization flux-system -n flux-system --with-source` → reconcile-and-verify gate (release still suspended AND staged spec shows `DB_TYPE: sqlite3`) → `flux resume` → verify SQLite startup
- **Phase B hard failure (data-loss boundary applies):** `flux suspend helmrelease forgejo -n forgejo` FIRST → scale 0 → same PVC-pod file restore + git revert + gate as above → `flux resume`; the PostgreSQL database is retained as the authoritative copy of post-cutover writes

### Data-loss boundary

- Rollback to SQLite is **lossless only before forgejo has accepted post-cutover writes** on PostgreSQL (i.e. at the Phase A decision point, before normal traffic resumes)
- Any rollback after forgejo has accepted writes discards those writes
- Snapshot retention: the snapshot dir + dump zip stay on the PVC until the first successful monthly restore test (minimum 7 days)

## PostgreSQL backups (192.168.254.104)

The dedicated PostgreSQL box backs up both databases (`atuin`, `forgejo`) nightly at 02:30 — plus `immich` (HRIS pending) via `/usr/local/bin/pg-backup.sh` (crontab as the `postgres` user, local peer auth). The wrapper dumps with `pg_dump -Fc --snapshot` and records dump-time primary-table counts in the SAME repeatable-read snapshot, so each `backup.log` line (`atuin`: `records`/`users`; `forgejo`: `user`/`repository`/`issue`/`action`) describes the exact dump content. Failures emit `pg_backup FAILED: <db>` on stdout (cron mail to the admin), log a `FAILED` line, and timestamp `/backups/postgres/last-failure`. Retention: 14 days (`find -mtime +14 -delete`). `/backups/postgres` is owned by `postgres:postgres`.

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

## Papra

Document archiving / OCR (replaced paperless-ngx on 2026-08-31). Single Node container with SQLite,
public at `https://papra.watchtoken.org` — **no `.local` route** (gotcha #18) — with signup blocked at
Traefik (gotcha #19) and one 10Gi `local-path` PVC that needs a quiesced backup (gotcha #20).

Runbook — ingestion folder, backup procedure, probes and gotchas: [papra.md](papra.md).

## HRIS

TALA HRIS — Rails 8 applicant tracking (CSC form 9), the cluster's first app holding real PII. Chart +
image are published by the app repo (`aplacaba/tala-hris`, private) as `vX.Y.Z`; the HelmRelease
follows the whole pre-1.0 line (`image.tag: ""`), so the resolved chart version is the release.

- **Public:** `https://hris.alacaba.org` → CF Tunnel → Traefik websecure (per-host
  `Certificate hris-alacaba-org`, not the default TLSStore — gotcha #12) → `hris:8080`. No `hris.local`
  route (production runs `force_ssl`, so LAN HTTP would lose Secure cookies).
- **DB:** `192.168.254.104`, role `hris_ats`, four databases
  (`hris_ats_production{,_cache,_queue,_cable}`) driven by `DB_HOST`/`DB_PORT`; migrations run at
  container start (`db:prepare`) → single replica, `strategy: Recreate`.
- **Documents:** R2 bucket `tala-hris-uploads` (`terraform/r2.tf`), `ACTIVE_STORAGE_SERVICE=r2`, no PVC.
  **Mail:** Fastmail SMTP 465 via `hris-smtp`. **Jobs:** Solid Queue inside Puma.

**Secrets** (sealed, names frozen): `hris-rails-secrets`, `hris-db`, `hris-r2`, `hris-smtp`, `hris-ghcr`
in `hris` + `ghcr-registry-auth` in `flux-system`. **Rotate = re-seal + bump `secretsChecksum`.**

Sealing helper: `scripts/seal-hris-secrets.sh` (local, **untracked** — `scripts/` is gitignored on
purpose) — values come from one mode-600 file (`~/.secrets/hris.env`), `--bump` rolls the pod,
`--verify` lists the decrypted keys.

### Chart version policy (pre-1.0)

The HelmRelease carries a **semver range**, not a pin: `version: ">=0.1.0 <1.0.0"`. helm-controller
resolves the newest published tag inside it on every reconcile, so a chart release rolls out on its
own while the app is pre-1.0. **1.0.0 is the ceiling** — the range is the whole auto-update policy,
and a 1.0.0 (or later) release needs a deliberate manual bump to an exact version.

Two consequences to keep in mind:

- **No review step and no image gate.** An exact pin plus a PR could be checked before merging; a
  range cannot. The chart's `appVersion` names the image tag, so a chart published ahead of its image
  lands in `ImagePullBackOff` until the image appears (gotcha 3) — the fix is to push the image, not
  to intervene in the cluster.
- **Git no longer records the deployed version.** `version` is a range, so "what is running" is a
  question for `kubectl -n hris get helmrelease hris -o jsonpath='{.status.lastAttemptedRevision}'`
  (or the pod's image tag), not for this file.

If a release needs holding back, that is the moment to pin the exact version here (and the moment to
consider whether the 0.x line is still the right home for this app).

**Gotchas:** (1) provider v5.21 cannot manage R2 versioning — dashboard only. (2) The R2 token must be
Object Read & Write; a read-only token still boots, so uploads fail silently. (3) The chart's
`appVersion` must name a published image tag, or the pod hits `ImagePullBackOff` — nothing checks this
for you under the range, so publish the image before tagging the chart release.

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
SealedSecrets are generated locally with `kubeseal` (see Secret Management). The HRIS set has a
helper, `scripts/seal-hris-secrets.sh`, which is local-only (`scripts/` is untracked — see `.gitignore`).

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

## Media Stack Rollback (per-app cutover safety)

During the media migration, every cutover keeps the old docker container
available until its replacement is verified. Rollback is **per-app**:

1. Deactivate the replacement through Git/Flux first — commit `replicas: 1 → 0`
   in the app's `clusters/pk3s/media/deployment-*.yaml` and confirm the pod is
   stopped. NEVER `kubectl scale` (Flux reverts it).
2. Only then restart the old docker container (`docker start <app>` on the VM).
3. The download unit rolls back **atomically**: deactivate the `download`
   Deployment via Git first, then restart the old `gluetun`, `qbittorrent`
   and `sabnzbd` containers together.

**Invariant: never two writers on the same state** — the old container stays
stopped while its replacement runs, and the replacement is confirmed stopped
before the old container restarts.

## Media Stack (k3s-media node)

The media platform runs in the `media` namespace, pinned to the dedicated
tainted node `k3s-media` (192.168.254.109, the repurposed media VM): label
`media=yes`, taint `media=yes:NoSchedule`. All media pods carry the
`media` nodeSelector + toleration (shared `component-media-pin` kustomize
component). The node keeps the Arc B580 GPU passthrough (jellyfin QSV) and
the 7.8T media disk mounted at `/home/new-media` (UUID fstab entry +
`RequiresMountsFor` drop-in on the k3s-agent service).

### Access (LAN only, via 192.168.254.50:30080)

| App | Hostname | Notes |
|---|---|---|
| jellyfin | jellyfin.local | QSV transcode (privileged container + Intel driver init script) |
| seerr | seerr.local | requests UI |
| immich | immich.local | photos (central PG at 192.168.254.104) |
| sonarr / radarr / lidarr | *.local | hardlinked imports from /data/downloads |
| prowlarr | prowlarr.local | indexer hub; syncs to sonarr/radarr/lidarr |
| bazarr | bazarr.local | subtitles |
| qbittorrent / sabnzbd | *.local | inside the VPN'd `download` pod (gluetun sidecar) |
| shelfmark | shelfmark.local | book/audiobook search & request hub (ghcr.io/calibrain/shelfmark, Standard image) |
| flaresolverr | none (internal only) | `http://flaresolverr:8191` ClusterIP — Prowlarr's FlareSolverr proxy for Cloudflare-protected indexers |

### Key architecture facts

- **download pod**: gluetun (sidecar initContainer, restartPolicy Always,
  NET_ADMIN + /dev/net/tun, FIREWALL=on kill-switch, FIREWALL_INPUT_PORTS
  8081,8080, postStart VPN-health gate) + qbittorrent (WEBUI_PORT=8081) +
  sabnzbd. Pod dnsPolicy None + AirVPN tunnel DNS 10.128.0.1; SERVER_HOSTNAMES
  must be an AirVPN hostname (sg.vpn.airdns.org), not an IP. Sabnzbd has no
  usenet servers configured (deferred by operator).
- **media-local-path StorageClass**: dedicated provisioner instance in the
  media namespace (rancher.io/local-path-media, nodePathMap k3s-media ->
  /home/rancher/k3s/storage, NO default entry). The agent `--data-dir`
  (/home/rancher/k3s) does NOT relocate local-path provisioning — the SC is
  what pins PVCs to /home.
- **/data mount**: pods mount /home/new-media/Media at /data (matching the
  migrated YAMS config paths). ONE mount per pod = the hardlink-import
  contract (downloads -> tv/movies on one filesystem).
- **jellyfin GPU**: privileged container (k8s device cgroup blocks /dev/dri
  otherwise) + `configmap-jellyfin-intel-init` custom-cont-init script that
  installs `intel-opencl-icd` + `libze-intel-gpu1` + `intel-ocloc` (signed
  Ubuntu repos — the Intel GPU repo line in the script is unsigned and only
  covers iHD as a fallback; the LSIO base image already ships a
  Battlemage-capable iHD) and copies system libva/libdrm/iHD into
  /usr/lib/jellyfin-ffmpeg/lib. The OpenCL/Level Zero runtime is REQUIRED for
  HDR→SDR tonemap with QSV: without it ffmpeg aborts with exit code 237
  ("Failed to get number of OpenCL platforms: -1001" on
  `-init_hw_device opencl=ocl@va`) and every transcode fails while direct
  play/remux keeps working. Symptom after a Jellyfin upgrade to 10.11
  (tonemap via `tonemap_opencl`). Init script re-runs on pod restart — after a
  configmap-only change, `kubectl rollout restart deploy/jellyfin -n media`.
- **jellyfin 12.0 (image pinned `version-12.0ubu2604`)**: LSIO moved `latest`
  to 12.0 on release day, and 12.0's DB migration is irreversible without a
  `/config` restore — never use `:latest` here. Upgrade SOP: commit
  `replicas: 0` + reconcile, back up `/config` via a helper pod (tar to
  `/home/backups/jellyfin-<ver>/` on k3s-media), bump the pinned tag, commit
  `replicas: 1`. The Deployment has no `strategy` (RollingUpdate default), so
  a bare image bump would start the new pod against the live SQLite DB while
  the old one still runs. 12.0 notes: `EnableLegacyAuthorization` is now
  `false` (flag still exists as a fallback), a full library scan is required
  after the upgrade, and seerr 3.4.1 is compatible (modern
  `Authorization: MediaBrowser` auth, no removed routes used).
- **immich DB**: central PostgreSQL 192.168.254.104, database `immich`
  (role immich, password in the sealed secret). Extensions pre-installed:
  vector 0.8.6, vchord 1.1.1 (shared_preload_libraries=vchord.so),
  cube, earthdistance. Immich server limit 1.5Gi (1Gi OOMs on migrations).
  pg-backup.sh includes immich (tables users/assets).
- **seerr**: config at /app/config (not /config!), image pinned
  `ghcr.io/seerr-team/seerr:v3.4.1`. Admin bootstrapped via
  DB+settings.json (permissions=2 ADMIN); X-Api-Key header auth works where
  the session cookie is required. The manual bootstrap originally left
  `main.mediaServerType=4` (NOT_CONFIGURED), `jellyfin.libraries=[]` and
  admin user id 1 without a `jellyfinUserId` — fixed 2026-09-08 (see the
  seerr integration gotcha below).
- **Backups**: migration staging at /home/backups/media-migration on the
  node (configs tar, immich dump, immich library tar).

### Media stack gotchas

- **Node conversion**: rename host to k3s-media BEFORE the k3s join (the
  nodePathMap key must match); k3s writes a ~233M static data/ dir on root
  regardless of --data-dir (normal).
- **Uninstall semantics**: k3s-agent-uninstall.sh removes
  /home/rancher/k3s ONLY when invoked with K3S_DATA_DIR=/home/rancher/k3s —
  it contains the media-local-path PVC data.
- **Rollback (per-app)**: commit replicas 1->0 + confirm stopped, THEN
  restart the old docker container; download unit rolls back atomically.
  Never two writers on the same state.
- **Only `svclb-traefik` skips the media node** (verified 2026-09-13): `node-exporter` and `promtail`
  both carry `operator: Exists` tolerations and do run on `k3s-media`, so media-node metrics and logs
  are collected after all. The absent svclb pod is harmless — LAN entry is the master's NodePort,
  served from `k3s-master`.
- **Indexers**: zetorrents/zktorrent prowlarr definitions point at stale
  domains (rotation lists now redirect to parked pages) — update baseUrls
  manually. The zktorrent definition is ALSO outdated vs the current site
  markup (title selector breaks: "Invalid Release ... No title provided");
  upstream replaced it with `world-torrent` — use the World-torrent indexer
  (live clone domain like `https://www.worldivx.cc/`) instead. ZkTorrent
  routes through the in-cluster FlareSolverr proxy (see the FlareSolverr
  gotcha below).
- **FlareSolverr (Prowlarr proxy)**: runs in the media namespace
  (`http://flaresolverr:8191`, ClusterIP) with a 512Mi memory limit on the
  media node — no PVC, no ingress, no hostname. If it OOM-kills under load
  (`kubectl -n media get events`), raise it to 1Gi and compensate by
  reducing immich ML from 3Gi to 2Gi. The Prowlarr-side configuration
  (Settings → Indexers → FlareSolverr Proxy → `http://flaresolverr:8191`,
  then assign the proxy per indexer — ZkTorrent mandatory) lives in
  Prowlarr's DB and is LOST on rebuild: reconfigure in the UI.
- **Shelfmark memory cap is 1.5Gi, not upstream's recommended ~2Gi**: the
  Standard image bundles Chromium for Cloudflare bypass on Direct Download
  sources, and upstream recommends ~2Gi container memory. The media node's
  16G no-overcommit budget (pod limits ~14.6Gi total) caps shelfmark at
  1.5Gi. Typical Direct Download sessions work (above the "problems start at
  1Gi" threshold); if you see `403 detected; switching to bypasser` +
  `No download URL found` loops, raise the limit with a compensating
  reduction elsewhere (e.g. immich ML 3Gi→2Gi) or switch to the Lite image
  with an external FlareSolverr.
- **Shelfmark runs non-root (pod securityContext)**: `runAsUser: 1000`,
  `runAsGroup: 1000`, `runAsNonRoot: true`, `fsGroup: 1000` — NOT an LSIO
  image, no PUID/PGID. Its entrypoint requires writable `/tmp/shelfmark`,
  `/config` and runtime HOME (fsGroup covers them). TZ env is accepted but
  `/etc/localtime` is not changed in non-root mode (cosmetic).
- **Shelfmark is a manual search/request tool**: it does not monitor authors,
  series, or new releases (upstream non-goals). Downloads land in
  `INGEST_DIR=/data/books` on the media disk. Indexers/download clients
  (Prowlarr, qBittorrent, Sabnzbd) are configured in its UI. The 2Gi
  `shelfmark-config` PVC is `media-local-path` (reclaim Delete — removed from
  kustomization = config lost).
- **Proxmox upstream TLS uses the cluster CA**: the `pve` route validates
  `192.168.254.165:8006` with the CA stored in the `pve/sealedsecret-pve-ca.yaml`
  SealedSecret and sets `serverName: homelab.pve` because the node certificate
  SAN does not include the endpoint IP. The user-facing hostname remains
  `pve.local`. If the Proxmox cluster CA or node certificate is regenerated,
  re-seal `/etc/pve/pve-root-ca.pem` directly from the Proxmox host and reconcile
  Flux; never commit the plaintext CA.
- **PVE frontend TLS is self-signed**: cert-manager issues `pve-local-tls` for
  `pve.local`, and the HTTP route redirects to HTTPS. Clients must trust the
  generated certificate (or accept the browser warning) when opening
  `https://pve.local`; this certificate is separate from the Proxmox backend CA.
- **seerr's manual bootstrap skipped the media-server fields**: the DB +
  settings.json seed set the Jellyfin host/apiKey but left
  `main.mediaServerType=4` (NOT_CONFIGURED), `jellyfin.libraries=[]`, and
  admin user id 1 without a `jellyfinUserId`. Symptoms: no
  `jellyfin-recently-added-scan`/`jellyfin-full-scan` jobs registered, and the
  daily availability sync logs `An admin is not configured.`. Fix (all three
  are required): `POST /api/v1/settings/main` `{"mediaServerType":2}`
  (JELLYFIN=2), `GET /api/v1/settings/jellyfin/library?sync=true&enable=<ids>`,
  and set `user.id=1.jellyfinUserId` to the Jellyfin admin's user id (DB edit
  while the pod is stopped — no API exists for it). Restart the pod afterwards
  so `schedule.ts` registers the Jellyfin jobs. Seerr config backup:
  `/home/backups/seerr/seerr-config-pre-fix.tgz`.

### Node join/upgrade SOP

```bash
# join (from the media VM, token from master)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<cluster-version> \
  K3S_URL=https://192.168.254.50:6443 K3S_TOKEN=<token> sh -s - agent \
  --node-name k3s-media --node-label media=yes \
  --node-taint media=yes:NoSchedule --data-dir /home/rancher/k3s
# upgrades must match the cluster's k3s version
```

Upgrade gotchas (learned 2026-08-30, v1.34.4 → v1.36.4):

- **Upgrade the control plane one minor at a time** (1.34 → 1.35 → 1.36). Re-run
  the installer on the master with the same CLI flags (`server --disable=traefik`) —
  CLI flags are NOT preserved across reinstalls, only `K3S_*` env vars are.
- **Agent re-install must be run as root with the token passed explicitly.** The
  agent env file (`/etc/systemd/system/k3s-agent.service.env`) is root-owned and
  not readable by the SSH user — sourcing it as the user silently drops
  `K3S_TOKEN`/`K3S_URL`, and the installer overwrites the env file with empty
  values, leaving the agent crash-looping. Pipe the token from the master
  (`/var/lib/rancher/k3s/server/node-token`) via stdin to a `sudo sh -c` on the VM.
- The `media-mount.conf` systemd drop-in survives agent reinstalls.
- Running containers survive a k3s service restart (no pod restarts observed
  across the upgrade), so app downtime is near-zero for both hops.

## Pangolin Media Relay

Public access for the media stack (friends, ~10 users) runs through a
self-hosted Pangolin CE instance on a Hetzner VPS (Falkenstein, Debian 13,
2 vCPU/4GB, `root@178.105.27.201`) — NOT Cloudflare Tunnel, so video
streaming never violates CF ToS and the ~100 MB upload ceiling does not
apply. TLS terminates at the VPS (wildcard `*.watchtoken.org` + apex, LE
DNS-01 via a scoped Cloudflare token). Transcoding stays at home (B580 QSV).

| Hostname | App | Auth | Backend target |
|---|---|---|---|
| watchtoken.org (apex) | Jellyfin | Jellyfin users (no Pangolin auth) | http://jellyfin.media.svc:8096 |
| seerr.watchtoken.org | seerr | Pangolin SSO → Jellyfin SSO | http://seerr.media.svc:5055 |
| pangolin.watchtoken.org | Pangolin dashboard | admin + MFA | — |

### Key facts

- **DNS is gray-clouded on purpose:** the `watchtoken.org` apex, `seerr`, and
  `pangolin` A records have `proxied = false` in `terraform/dns.tf`. Never flip
  them to proxied — that routes video through Cloudflare (ToS §2.8).
- **Wildcard cert is config-file managed:** DNS-01 resolver (`cloudflare`
  provider) replaces HTTP-01 in `config/traefik/traefik_config.yml`,
  `CLOUDFLARE_DNS_API_TOKEN` env on the traefik container,
  `prefer_wildcard_cert: true` on `domains.domain1` in `config/config.yml`,
  and the dashboard router's `tls.domains` SAN (`watchtoken.org` +
  `*.watchtoken.org`) triggers issuance. NOT configured via the dashboard —
  the domain is file-managed from the installer.
- **newt agent** runs in the `pangolin` namespace via the `fossorial/newt`
  Helm chart 1.4.0, pinned to `k3s-master` (media node budget is constrained).
  Credentials are a SealedSecret (`newt-auth`). It dials OUT over WireGuard —
  no inbound ports at home.
- **VPS is not GitOps:** config + SQLite DB live in `/opt/pangolin`, backed up
  weekly by the `pangolin-backup` systemd timer on the master (rsync pull to
  `/home/backups/pangolin`, Sun 02:30). Rebuild: reinstall (installer), restore
  dir, newt reconnects on its own.
- **CrowdSec** runs on the VPS (installer `--crowdsec`). If a friend is
  blocked (false positive from residential IP reputation), whitelist their IP
  via `cscli decisions` (see gotcha #31).
- **Region note:** the VPS is Falkenstein, not Singapore as originally planned
  — fine for EU/NA friends; SEA friends get higher latency. Accepted
  divergence, recorded 2026-08-22.

### Emergency stopgap

If the VPS dies: point the apex A record at `cfargotunnel.com` (Cloudflare
flattens apex CNAMEs), add a tunnel ingress for jellyfin (temporary ToS gray
area), keep seerr dark until the VPS is rebuilt from the backup.
