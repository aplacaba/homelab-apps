# homelab-apps — GitOps Guide for AI Agents

## Project Overview

GitOps repository for a **k3s v1.34** homelab cluster managed by **Flux Operator**.
The cluster syncs from this repo (`github.com/aplacaba/homelab-apps.git`) at `./clusters/pk3s`.

| Aspect | Detail |
|---|---|
| **Cluster** | pk3s — single-node k3s |
| **GitOps** | Flux Operator (FluxInstance), one-way sync from GitHub |
| **Ingress** | Traefik v3 with IngressRoute CRD, NodePort 30080/30443 |
| **Auth** | Authentik — forward-auth middleware in `traefik` namespace |
| **Tunnel** | Cloudflare Tunnel (cloudflared) for public `.watchtoken.org` domains |
| **Internal DNS** | `.local` domains via `/etc/hosts` → `192.168.254.50:30080` |
| **Storage** | `local-path` storage class (k3s built-in) |
| **Forgejo** | `fgit.watchtoken.org` — self-hosted Git + Actions + Container Registry |

## Directory Structure

```
clusters/pk3s/
├── kustomization.yaml         # Root — lists all app directories
├── authentik/                 # SSO/auth (Helm chart)
├── cloudflared/               # Cloudflare Tunnel (raw manifests)
├── cv-datastar/               # CV site (Helm chart, OCI registry)
├── excalidraw/                # Drawing app (Helm chart)
├── floci/                     # FLOCI tool (raw manifests)
├── flux-dashboard/            # Flux web UI (raw manifests)
├── forgejo/                   # Git + Actions + Registry (Helm chart)
├── forgejo-runner/            # CI runner (Helm chart)
├── it-tools/                  # IT tool collection (Helm chart)
├── monitoring/                # Prometheus + Loki + Grafana (Helm charts)
├── paperless/                 # Document management (Helm chart, gated)
└── traefik/                   # Ingress controller (Helm chart)
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

### Gating behind Authentik (SSO)

See full runbook in `docs/authentik-forward-auth.md`. Summary:

1. Authentik UI: create a **Proxy Provider** (Mode: Forward auth, External host = exact browser URL **with port**).
2. Authentik UI: create an **Application** bound to that provider.
3. Authentik UI: **assign the provider to the embedded outpost** (Outposts → `authentik Embedded Outpost` → Edit → Applications).
4. Kubernetes: write a **two-route IngressRoute** — one for `/outpost.goauthentik.io/` (direct to Authentik), one for the app (behind the `authentik-forwardauth` middleware).
5. See `clusters/pk3s/paperless/ingressroute.yaml` for a working example.

### HelmRelease values — override, don't copy

Only override values that differ from chart defaults. Use the `helmrelease.yaml`
to pass `values:` — don't duplicate the full `values.yaml` from the chart.
Reference existing patterns:

- **Paperless** (`clusters/pk3s/paperless/helmrelease.yaml`) — gated app with Redis, PVCs, env vars
- **it-tools** (`clusters/pk3s/it-tools/helmrelease.yaml`) — simple public app, chart ingress disabled
- **Forgejo** (`clusters/pk3s/forgejo/helmrelease.yaml`) — full app with PostgreSQL subchart
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
| `pascaliske` | default | `https://charts.pascaliske.dev` | paperless |
| `traefik` | default | `https://traefik.github.io/charts` | traefik |
| `forgejo` | OCI | `oci://codeberg.org/forgejo-contrib` | forgejo |
| `forgejo-runner` | OCI | `oci://codeberg.org/wrenix/helm-charts` | forgejo-runner |
| `prometheus-community` | default | `https://prometheus-community.github.io/helm-charts` | monitoring |
| `grafana` | default | `https://grafana.github.io/helm-charts` | monitoring (loki) |
| `excalidraw` | default | `https://excalidraw.github.io/excalidraw-chart` | excalidraw |
| `authentik` | default | `https://charts.goauthentik.io` | authentik |
| `cv-datastar` | OCI | `oci://fgit.watchtoken.org/forgejo-admin` | cv-datastar (needs secretRef) |

## Architecture Notes

### Cluster layout

```
┌───────────────┬──────────────────────────────────────────────────┐
│ flux-system   │ Flux Operator controllers                        │
│               │ GitRepository → Kustomization → HelmRelease      │
├───────────────┼──────────────────────────────────────────────────┤
│ traefik       │ Ingress controller (NodePort 30080/30443)        │
│               │ Middleware: authentik-forwardauth (cross-ns)      │
├───────────────┼──────────────────────────────────────────────────┤
│ authentik     │ SSO — embedded outpost + PostgreSQL              │
│               │ Service: authentik-server:80                     │
│               │ Outpost: ak-outpost-authentik-embedded-outpost:9000│
├───────────────┼──────────────────────────────────────────────────┤
│ cloudflared   │ Cloudflare Tunnel (token-based, no config)       │
│               │ Routes public DNS → internal services            │
├───────────────┼──────────────────────────────────────────────────┤
│ forgejo       │ Git server + Actions + OCI Container Registry    │
│               │ Service: forgejo-http:3000                       │
│               │ Registry: https://fgit.watchtoken.org/v2/        │
├───────────────┼──────────────────────────────────────────────────┤
│ ∀ apps        │ Each in its own namespace                        │
│               │ Can reference cross-ns services/middlewares       │
└───────────────┴──────────────────────────────────────────────────┘
```

### Cross-namespace references

Traefik has `providers.kubernetesCRD.allowCrossNamespace: true` enabled.
This allows any app's IngressRoute to reference:
- `authentik-server` service in `authentik` namespace
- `authentik-forwardauth` middleware in `traefik` namespace

### Public vs internal

- **Public** (`*.watchtoken.org`): routed through Cloudflare Tunnel → Traefik
  (no TLS termination on the cluster — handled by Cloudflare edge).
- **Internal** (`*.local`): accessed via `http://192.168.254.50:30080` on LAN.

## Common Gotchas

1. **Authentik 404:** Provider not assigned to the embedded outpost → always check Outposts → Edit → Applications first.
2. **Port mismatch:** Authentik External Host must match the browser URL byte-for-byte, port included (`:30080` on LAN).
3. **Chart ingress vs IngressRoute:** If writing a manual IngressRoute, always disable the chart's built-in ingress.
4. **OCI registry auth:** Charts pushed to `fgit.watchtoken.org` need a `forgejo-registry-auth` docker-registry Secret in `flux-system`.
5. **Reconciliation lag:** Flux syncs every 1h by default. Force with `kubectl -n flux-system reconcile helmrepository <name>` or `kubectl -n flux-system reconcile kustomization pk3s`.
6. **Local chart deployment:** Can't use upstream HelmRepository for local charts. Package → push to OCI registry → HelmRelease with `type: oci`.

## Forgejo Runner

The CI runner runs in `forgejo-runner` namespace, connects to the internal Forgejo
service (`forgejo-http.forgejo.svc:3000`). Uses Docker-in-Docker sidecar for
container builds. Labels: `ubuntu-latest` and `ubuntu-22.04` (both mapped to
`docker://node:16-bullseye`).

To check runner status:
```bash
kubectl get pods -n forgejo-runner
# or via Forgejo UI: fgit.watchtoken.org → Settings → Actions → Runners
```
