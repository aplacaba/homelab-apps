# homelab-apps — Guide for AI Agents

This is the map of the repo: what it is, how a change reaches the cluster, where things live and
which doc to open next. Detail lives in the topic docs listed in [Where to look next](#where-to-look-next).
The rules that always apply are in [`AGENTS.md`](../AGENTS.md).

## What this repo is

A GitOps repository for a two-node **k3s** homelab cluster called **pk3s**. **Flux Operator**
syncs it from `github.com/aplacaba/homelab-apps.git`, path `./clusters/pk3s`, branch `main`.
Everything that runs in the cluster is declared here, except a few things set up by hand (see
[Not managed by Flux](#not-managed-by-flux)).

| Aspect | Summary |
|---|---|
| **Nodes** | `k3s-master` (192.168.254.50, control plane, runs almost everything) and `k3s-media` (192.168.254.109, label/taint `media=yes`, runs only the media stack) |
| **GitOps** | Flux Operator with a `FluxInstance` (`flux-instance.yaml`); the source, kustomize, helm and notification controllers |
| **Ingress** | Traefik with the `IngressRoute` CRD, NodePort 30080 (`web`) / 30443 (`websecure`) |
| **TLS** | cert-manager + Let's Encrypt DNS-01 (Cloudflare), wildcard `*.watchtoken.org` as Traefik's default cert |
| **Public access** | Cloudflare Tunnel (`cloudflared`) for web apps; a Pangolin VPS for media streaming |
| **LAN access** | `<app>.local` hostnames in `/etc/hosts` → `192.168.254.50:30080` |
| **Secrets** | SealedSecrets, so only encrypted values are in git |
| **Storage** | `local-path` on the master; `media-local-path` pinned to `k3s-media` |
| **Databases** | Most apps use SQLite on a PVC. Forgejo, Immich and Windshift use the central PostgreSQL at `192.168.254.104` |
| **Auth** | No cluster-wide SSO. Authentik was removed. |

The current version of each component is in [inventory.md](inventory.md).

## How a change reaches the cluster

```
edit clusters/pk3s/<app>/ ─► commit ─► push to main ─► GitRepository polls (1m)
   ─► root Kustomization `flux-system` applies (10m, prune: true, server-side apply)
   ─► HelmReleases reconcile on their own interval (usually 1h)
```

1. Edit manifests under `clusters/pk3s/<app>/`, then commit and push. Flux reverts any change you
   make directly with `kubectl apply/edit/scale` on its next sync. To stop an app, commit
   `replicas: 0`.
2. Wait for it to land. A push is usually live within a minute or two:
   `flux get kustomization flux-system -n flux-system`.
3. Check it: `kubectl -n flux-system get kustomization,helmrelease` should all show `True`, and
   so should `kubectl get ks,hr -A`.

Only run `flux reconcile kustomization flux-system -n flux-system --with-source` when a change has
to land now, for example to verify a fix or un-stick a failed sync. The root Kustomization is
named `flux-system`, not `pk3s`. `flux suspend/resume` is only for migrations.

Terraform is the one exception to this flow. Cloudflare DNS, the tunnel, zone settings and R2 are
applied by GitHub Actions when `terraform/**` changes are merged to `main`. See [terraform.md](terraform.md).

## Repository layout

```
AGENTS.md                 # short entry point with the non-negotiable rules
flux-instance.yaml        # FluxInstance; applied by hand, not synced by Flux (platform.md)
clusters/pk3s/
├── kustomization.yaml    # root: one entry per app directory, alphabetical
└── <app>/                # one directory per app; see the namespace table below
terraform/                # Cloudflare (DNS, tunnel, zone settings, tokens, R2), applied in CI
└── grafana/              # Grafana dashboards as code; local state, applied by hand
.github/workflows/        # terraform-cloudflare.yml (fmt, validate, plan, apply)
.githooks/pre-commit      # terraform fmt check on staged .tf files
docs/                     # this guide plus the topic docs
```

`scripts/` (local operator helpers such as `seal-koito-secrets.sh` and `import-ytm-cookie.sh`) and
`docs/superpowers/` are gitignored on purpose. They exist on the operator workstation, not in a
clone.

Each app directory is one of two shapes. A **Helm app** has `namespace.yaml`, `helmrepository.yaml`
(unless it reuses one), `helmrelease.yaml`, `ingressroute.yaml` and `kustomization.yaml`. A
**raw-manifest app** has `namespace.yaml`, `deployment.yaml`, `service.yaml`, `pvc.yaml`,
`ingressroute.yaml` and `kustomization.yaml`. Templates and the list of chart sources are in
[patterns.md](patterns.md).

## What runs where

| Namespace | What it is | Reached at | Doc |
|---|---|---|---|
| `flux-system` | Flux controllers, HelmRepositories, Flux web UI | LAN `fluxops.local` | [platform.md](platform.md) |
| `traefik` | Ingress controller, wildcard cert, default TLSStore | NodePort 30080 / 30443 | [networking.md](networking.md) |
| `cert-manager` | Let's Encrypt DNS-01 ClusterIssuers | — | [networking.md](networking.md) |
| `cloudflared` | Cloudflare Tunnel connector | dials out | [networking.md](networking.md) |
| `sealed-secrets` | SealedSecrets controller | — | [secrets.md](secrets.md) |
| `monitoring` | kube-prometheus-stack, Loki, Alloy, Grafana, Alertmanager → Telegram | LAN `grafana.local` | [monitoring.md](monitoring.md) |
| `flux-monitoring` | PodMonitors for the Flux controllers | — | [monitoring.md](monitoring.md) |
| `cluster-digest` | Version-drift dashboard and a biweekly check worker | LAN `dash.local` | [cluster-digest.md](cluster-digest.md) |
| `forgejo` | Git, Actions and OCI registry | public `fgit.watchtoken.org`, SSH | [forgejo.md](forgejo.md) |
| `forgejo-runner` | CI runner with a DinD sidecar | — | [forgejo.md](forgejo.md) |
| `windshift` | Work management (Jira alternative) | public `windshift.watchtoken.org` only | [windshift.md](windshift.md) |
| `nextcloud` | File sync with MariaDB and Redis | LAN `sync.local`, public `sync.watchtoken.org` | [nextcloud.md](nextcloud.md) |
| `koito`, `multi-scrobbler` | Scrobble archive and the bridge that feeds it | LAN only | [koito.md](koito.md) |
| `media` | Jellyfin, Immich, seerr, the *arr apps, VPN download pod (on `k3s-media`) | LAN `*.local`; friends use the Pangolin VPS | [media.md](media.md) |
| `pangolin` | newt agent → Pangolin VPS relay | dials out | [pangolin.md](pangolin.md) |
| `cv-datastar` | CV site | `alacaba.org` (+ redirects) | [apps.md](apps.md) |
| `actual-budget`, `floci`, `watcharr`, `pve` | Small single-container apps and the Proxmox UI proxy | see doc | [apps.md](apps.md) |

## Things that apply everywhere

- **Ingress** is always a Traefik `IngressRoute` (`traefik.io/v1alpha1`), matched by host
  (`Host(...)`), never by `PathPrefix`. Turn off the chart's own ingress when you write one by
  hand. LAN apps use `<app>.local` on `web`. Public apps also need a tunnel hostname in Terraform.
  See [networking.md](networking.md).
- **Secrets** are sealed with `kubeseal` and committed only as a `SealedSecret`. Plaintext never
  goes into git, chat or a command line. Re-sealing does not restart a pod, so bump
  `secretsChecksum` (charts) or the `secrets-revision` annotation (raw manifests) in the same
  commit. Change the sealed source, never the decrypted `Secret`, because the controller undoes
  manual edits. See [secrets.md](secrets.md).
- **Data:** almost every PVC is `local-path` with reclaim `Delete`. Removing an app from the root
  kustomization deletes its volumes and the data on them, and Helm's `resource-policy: keep` does
  not stop that. Back up out of band first, and copy SQLite apps while they are stopped
  (`replicas: 0`, then a helper pod, then `replicas: 1`), never while they are running.
- **Images** are pinned to exact tags. Don't use `:latest` or a floating tag. Exceptions are
  written down in the app's doc (for example chart ranges like cv-datastar's `0.3.x`, see [patterns.md](patterns.md)).
- **Helm values** in a HelmRelease hold only what differs from the chart defaults. Don't copy the
  chart's whole `values.yaml`.
- **CRDs in a chart's `crds/` folder** are created on install but skipped on upgrade by default.
  Charts that ship CRDs (Traefik, kube-prometheus-stack, sealed-secrets) set
  `install/upgrade.crds: CreateReplace`.
- **Pull images from `fgit.watchtoken.org`**, not from the Forgejo ClusterIP. The nodes can't pull
  from the ClusterIP. See [forgejo.md](forgejo.md).
- **The central PostgreSQL box** (`192.168.254.104`) is hardcoded by IP in several apps, and its
  backups run there, not in the cluster. See [postgres.md](postgres.md).

## Not managed by Flux

| Thing | Managed how | Doc |
|---|---|---|
| k3s itself, both nodes | `get.k3s.io` installer with CLI flags | [platform.md](platform.md) |
| Flux Operator and `FluxInstance` | Helm release plus `kubectl apply -f flux-instance.yaml` | [platform.md](platform.md) |
| Cloudflare DNS, tunnel, zone, R2 | Terraform in CI | [terraform.md](terraform.md) |
| Grafana dashboards | Terraform, applied locally | [terraform.md](terraform.md) |
| Central PostgreSQL (LXC on Proxmox) | by hand, cron backups | [postgres.md](postgres.md) |
| Pangolin VPS | Docker compose in `/opt/pangolin` | [pangolin.md](pangolin.md) |
| Sealed-secrets master key backup | offline export | [secrets.md](secrets.md) |

Leftovers that Flux does not manage and that are safe to delete by hand: the `debug-tmp` namespace
and two `Completed` `node-debugger-k3s-master-*` pods, one in `debug-tmp` and one in `default`.

## Where to look next

| Need | Doc |
|---|---|
| Add or change an app, chart sources, manifest templates | [patterns.md](patterns.md) |
| Ingress, TLS, Cloudflare Tunnel, DNS, LAN vs public | [networking.md](networking.md) |
| Seal, rotate or back up secrets | [secrets.md](secrets.md) |
| k3s nodes and upgrades, Flux Operator upgrades | [platform.md](platform.md) |
| Running versions and PVC sizes | [inventory.md](inventory.md) |
| Prometheus, Loki, Alloy, Grafana, Telegram alerts | [monitoring.md](monitoring.md) |
| Terraform workflow and Grafana dashboards as code | [terraform.md](terraform.md) |
| Central PostgreSQL backups and restore tests | [postgres.md](postgres.md) |
| Per-app runbooks | [forgejo.md](forgejo.md), [media.md](media.md), [pangolin.md](pangolin.md), [nextcloud.md](nextcloud.md), [windshift.md](windshift.md), [koito.md](koito.md), [cluster-digest.md](cluster-digest.md), [apps.md](apps.md), [cv-datastar-commands.md](cv-datastar-commands.md) |
| Archived Authentik forward-auth notes | [authentik-forward-auth.md](authentik-forward-auth.md) |

## Keeping the docs accurate

Update the docs in the same change as the implementation:

- **New app:** add a row to the namespace table above and to the root kustomization, put its
  versions and PVCs in [inventory.md](inventory.md), and if it needs more than a few lines, give it
  a section in [apps.md](apps.md) or its own doc.
- **New chart source:** add it to the HelmRepositories table in [patterns.md](patterns.md).
- **New gotcha:** put it in the doc for the app or topic it belongs to. Only rules that apply to
  the whole repo go in "Things that apply everywhere" above.
- **Version bump:** update [inventory.md](inventory.md) and the app doc if the upgrade had notes.
- **New procedure or architecture change:** update the topic doc, and this page if the map
  changed.

Link to sections by heading, not by number, so references keep working when lists are
reordered.
