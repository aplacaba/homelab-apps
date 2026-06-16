# homelab-apps — GitOps Guide for AI Agents

## Project Overview

GitOps repository for a **k3s v1.34** homelab cluster managed by **Flux Operator**.
The cluster syncs from this repo (`github.com/aplacaba/homelab-apps.git`) at `./clusters/pk3s`.

| Aspect | Detail |
|---|---|
| **Cluster** | pk3s — single-node k3s |
| **GitOps** | Flux Operator (FluxInstance), one-way sync from GitHub |
| **Ingress** | Traefik v3 with IngressRoute CRD, NodePort 30080/30443 |
| **Auth** | None (previously Authentik) |
| **Tunnel** | Cloudflare Tunnel (cloudflared) for public `.watchtoken.org` domains |
| **Secrets** | SealedSecrets (`sealed-secrets` controller) — encrypted at rest, master key backed up offline |
| **Internal DNS** | `.local` domains via `/etc/hosts` → `192.168.254.50:30080` |
| **Storage** | `local-path` storage class (k3s built-in) |
| **Forgejo** | `fgit.watchtoken.org` — self-hosted Git + Actions + Container Registry |

## Directory Structure

```
clusters/pk3s/
├── kustomization.yaml         # Root — lists all app directories
├── cloudflared/               # Cloudflare Tunnel (raw manifests; token is a SealedSecret)
├── cv-datastar/               # CV site (Helm chart, OCI registry)
├── floci/                     # FLOCI tool (raw manifests)
├── flux-dashboard/            # Flux web UI (raw manifests)
├── forgejo/                   # Git + Actions + Registry (Helm chart)
├── forgejo-runner/            # CI runner (Helm chart)
├── monitoring/                # Prometheus + Loki + Grafana (Helm charts)
├── sealed-secrets/            # SealedSecrets controller (Bitnami chart, decrypts in-cluster)
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

### HelmRelease values — override, don't copy

Only override values that differ from chart defaults. Use the `helmrelease.yaml`
to pass `values:` — don't duplicate the full `values.yaml` from the chart.
Reference existing patterns:

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
| `traefik` | default | `https://traefik.github.io/charts` | traefik |
| `forgejo` | OCI | `oci://codeberg.org/forgejo-contrib` | forgejo |
| `forgejo-runner` | OCI | `oci://codeberg.org/wrenix/helm-charts` | forgejo-runner |
| `prometheus-community` | default | `https://prometheus-community.github.io/helm-charts` | monitoring |
| `grafana` | default | `https://grafana.github.io/helm-charts` | monitoring (loki) |
| `cv-datastar` | OCI | `oci://fgit.watchtoken.org/forgejo-admin` | cv-datastar (needs secretRef) |
| `bitnami` | OCI | `oci://registry-1.docker.io/bitnamicharts` | sealed-secrets |

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
│               │ Registry: https://fgit.watchtoken.org/v2/        │
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
- **Internal** (`*.local`): accessed via `http://192.168.254.50:30080` on LAN.

## Common Gotchas

1. **Chart ingress vs IngressRoute:** If writing a manual IngressRoute, always disable the chart's built-in ingress.
2. **OCI registry auth:** Charts pushed to `fgit.watchtoken.org` need a `forgejo-registry-auth` docker-registry Secret in `flux-system`.
3. **Reconciliation lag:** Flux syncs every 1h by default. Force with `kubectl -n flux-system reconcile helmrepository <name>` or `kubectl -n flux-system reconcile kustomization pk3s`.
4. **Local chart deployment:** Can't use upstream HelmRepository for local charts. Package → push to OCI registry → HelmRelease with `type: oci`.
5. **Runner goes silent after cancellation:** The Forgejo runner can stop picking up jobs after a task is cancelled (poller process stays alive but doesn't fetch). Symptom: `status=waiting` in Forgejo UI but no recent runner logs. Fix: `kubectl rollout restart deploy/forgejo-runner -n forgejo-runner`.
6. **Runner labels must match workflow `runs-on`:** Runner labels are set at `runner.config.file.runner.labels` (not `runner.file.runner.labels`). Mismatch → jobs queue forever. If labels change, delete the `forgejo-runner-config` secret and restart.
7. **Bitnami charts are OCI:** Bitnami migrated to `oci://registry-1.docker.io/bitnamicharts`. An HTTP-typed `HelmRepository` fails with `unsupported protocol scheme "oci"` — declare it `type: oci` (see `sealed-secrets/helmrepository.yaml`).

## Forgejo Runner

The CI runner runs in `forgejo-runner` namespace, connects to the internal Forgejo
service (`forgejo-http.forgejo.svc:3000`). Uses Docker-in-Docker sidecar for
container builds. Labels: `ubuntu-latest` and `ubuntu-22.04` (both mapped to
`docker://node:22-bookworm`).

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

### Shell access

```bash
# Runner container
kubectl exec -it -n forgejo-runner deploy/forgejo-runner -c runner -- /bin/sh

# Docker-in-Docker sidecar
kubectl exec -it -n forgejo-runner deploy/forgejo-runner -c dind -- /bin/sh
```
