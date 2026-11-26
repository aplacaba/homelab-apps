# App deployment patterns

How to add or change an app under `clusters/pk3s/<app>/`. Every app gets its own directory, its
own namespace and an entry in the root `clusters/pk3s/kustomization.yaml`. Deployment means commit
and push. Flux applies it (see the [guide](AGENT_INSTRUCTIONS.md#how-a-change-reaches-the-cluster)).

## Pattern 1 — Helm chart

```
clusters/pk3s/<app>/
├── namespace.yaml
├── helmrepository.yaml   # only if the chart source isn't in the table below
├── helmrelease.yaml
├── ingressroute.yaml     # if it has a web UI
├── sealedsecret.yaml     # if it needs credentials (secrets.md)
└── kustomization.yaml    # lists the files above
```

```yaml
# helmrepository.yaml: lives in flux-system
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <repo-name>
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.example.com       # or oci://… plus `type: oci`
---
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app>
  namespace: <app>
spec:
  interval: 1h
  chart:
    spec:
      chart: <chart-name>
      version: "X.Y.Z"                  # exact pin, or a range like "0.7.x" if the app doc says so
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  values:
    ingress:
      enabled: false                    # we write our own IngressRoute
    # only the values that differ from the chart defaults
```

- **Override, don't copy.** Put only the values that differ from the defaults in `values:`. Good
  examples: `forgejo/helmrelease.yaml` (a full app on external PostgreSQL) and
  `cv-datastar/helmrelease.yaml` (a static site from an OCI chart with `imagePullSecrets`).
- **Charts that ship CRDs** need `install.crds: CreateReplace` and `upgrade.crds: CreateReplace`,
  because helm-controller skips CRD updates on upgrade by default.
- **When a range picks up new releases** depends on `spec.chart.spec.interval` in the HelmRelease
  (it sets the interval of the generated `HelmChart`), not on the HelmRepository's interval. With
  the 1h default, a newly published chart can go unnoticed for up to an hour, which looks just like
  a broken range. To force a re-list now:
  `kubectl annotate helmchart.source.toolkit.fluxcd.io <ns>-<release> -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.
- **A range means git doesn't record the deployed version.** Ask the cluster:
  `kubectl -n <ns> get helmrelease <release> -o jsonpath='{.status.lastAttemptedRevision}'`.

## Pattern 2 — raw manifests

For apps with no usable chart, or simple infrastructure.

```
clusters/pk3s/<app>/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── pvc.yaml              # local-path; reclaim Delete (see the guide)
├── ingressroute.yaml
├── sealedsecret.yaml
└── kustomization.yaml
```

- Pin the image to an exact tag.
- Single-replica apps with SQLite on a RWO volume must never run two pods at once. Use
  `strategy: Recreate`, or `maxSurge: 0` / `maxUnavailable: 1` if a short overlap during shutdown
  is acceptable. Only `Recreate` waits for the old pod to be gone.
- If env vars come from a secret, add a `secrets-revision` annotation on the pod template and bump
  it whenever you re-seal, so the pod restarts (see [secrets.md](secrets.md#rolling-pods-after-a-re-seal)).
- Config files belong in a kustomize `configMapGenerator`, not a hand-written ConfigMap. The
  content-hash suffix changes with the content, so the pods restart on their own (cluster-digest
  works this way).

## Root kustomization

Add the directory to `clusters/pk3s/kustomization.yaml`, keeping the list alphabetical:

```yaml
resources:
  - <existing-apps>
  - <new-app>
```

Removing an entry deletes everything in that directory, PVCs included.

## Ingress

Always use the Traefik CRD, always match on host, and turn off the chart's own ingress
(`ingress.enabled: false` or `ingressRoute.create: false`).

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: <app>
spec:
  entryPoints: [web]
  routes:
    - kind: Rule
      match: Host(`<app>.local`)
      services:
        - name: <service-name>
          port: <port>
```

- **LAN only:** `<app>.local` on `web`, as above. Clients add `192.168.254.50 <app>.local` to
  `/etc/hosts` and browse to `http://<app>.local:30080`.
- **Public `*.watchtoken.org`:** add a `websecure` route with `tls: {}` (the default TLSStore
  serves the wildcard), attach the shared `redirect-to-https` middleware to the `web` route, and add
  the hostname to `terraform/tunnel.tf` plus a DNS record. Other domains (`alacaba.org`) need their
  own `Certificate` and `tls.secretName`. See [networking.md](networking.md).
- IngressRoutes can reference Services and Middlewares in other namespaces
  (`allowCrossNamespace: true`).

## Charts from the Forgejo OCI registry

For charts built locally, for example from `~/Projects/cv-datastar`:

1. Package and push:
   ```bash
   helm package charts/<chart>
   helm push <chart>-<version>.tgz oci://fgit.watchtoken.org/forgejo-admin
   ```
2. Create a HelmRepository with `type: oci` pointing at `oci://fgit.watchtoken.org/forgejo-admin`.
3. Create a sealed `docker-registry` secret `forgejo-registry-auth` in `flux-system` (server
   `https://fgit.watchtoken.org`).
4. Reference it from the HelmRepository (`secretRef`) and from the HelmRelease
   (`imagePullSecrets`).

## Existing HelmRepositories

All live in `flux-system`. Reference them by name in `sourceRef`.

| Name | Type | URL | Used by |
|---|---|---|---|
| `traefik` | default | `https://traefik.github.io/charts` | traefik |
| `forgejo` | OCI | `oci://codeberg.org/forgejo-contrib` | forgejo |
| `forgejo-runner` | OCI | `oci://codeberg.org/wrenix/helm-charts` | forgejo-runner |
| `prometheus-community` | default | `https://prometheus-community.github.io/helm-charts` | monitoring |
| `grafana` | default | `https://grafana.github.io/helm-charts` | monitoring (loki, alloy) |
| `jetstack` | default | `https://charts.jetstack.io` | cert-manager |
| `cv-datastar` | OCI | `oci://fgit.watchtoken.org/forgejo-admin` | cv-datastar (needs `secretRef`) |
| `bitnami` | OCI | `oci://registry-1.docker.io/bitnamicharts` | sealed-secrets |
| `nextcloud` | default | `https://nextcloud.github.io/helm` | nextcloud |
| `fossorial` | default | `https://charts.fossorial.io` | pangolin (newt) |
| `immich` | OCI | `oci://ghcr.io/immich-app/immich-charts` | media (immich) |

Bitnami charts moved to OCI. An HTTP-type HelmRepository for them fails with
`unsupported protocol scheme "oci"`, so declare it `type: oci`.

## Notes

- Prefer SQLite on a PVC for small apps. Use the central PostgreSQL ([postgres.md](postgres.md))
  only for apps that need it, and add the database to its nightly backup.
- If the chart creates PVCs, you don't need to name a storage class. `local-path` is the default.
- Pods on `k3s-media` need the `media` nodeSelector and toleration (the `component-media-pin`
  kustomize component). Nothing else should run there.
