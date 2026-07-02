# Design — Grafana Terraform Dashboards

## 1. Approach (summary)

Two independent reconcilers, no coupling:

- **Flux** reconciles the K8s-side changes from this repo: enabling Forgejo
  metrics, and adding the cloudflared `Service` + the two `ServiceMonitor`s.
- **Terraform** reconciles Grafana: a new root module at `terraform/grafana/`
  (own S3 state key) provisions a service account, a "Homelab" folder, and seven
  dashboards (JSON files in the repo) via the `grafana/grafana` provider.

Grafana datasources (Prometheus, Loki) stay defined in the monitoring
HelmRelease — not Terraform-managed.

**Path:** Terraform (run on a LAN host) → Traefik NodePort `:30080`
(`grafana.local`) → `kube-prometheus-stack-grafana.monitoring.svc:3000` (Grafana
HTTP API). Dashboards, once in Grafana, query the Prometheus datasource, which
scrapes node-exporter / kube-state-metrics / kubelet / Traefik / Forgejo /
cloudflared.

## 2. Terraform module (`terraform/grafana/`)

Separate root module + separate state. The existing `terraform/` is
Cloudflare-only with backend key `cloudflare/terraform.tfstate`; mixing in
Grafana would couple two unrelated state domains and widen blast radius.

### 2.1 `providers.tf`
```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket = "homelab-tfstate"
    key    = "grafana/terraform.tfstate"     # DIFFERENT key from cloudflare
    # ...same non-AWS S3 skip flags as terraform/providers.tf...
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
```

### 2.2 `variables.tf`
```hcl
variable "grafana_url" {
  type      = string                 # http://grafana.local:30080
}
variable "grafana_auth" {
  type      = string
  sensitive = true                   # basic auth OR token
}
```
Both supplied via env vars (`GRAFANA_URL`, `GRAFANA_AUTH` — TF_VAR_*). Nothing
secret is committed; the Grafana admin password already lives in the
`grafana-admin-secret` SealedSecret and is read by the operator from their
password manager at bootstrap.

### 2.3 `bootstrap.tf` — self-bootstrapped service account
```hcl
resource "grafana_service_account" "terraform" {
  name        = "terraform"
  role        = "Admin"
  is_disabled = false
}

resource "grafana_service_account_token" "terraform" {
  name                = "terraform-token"
  service_account_id  = grafana_service_account.terraform.id
  # seconds_to_expiration intentionally OMITTED → token never expires.
  # Rotation is manual: terraform apply -replace=grafana_service_account_token.terraform
}
```

Decision: **no `grafana_organization` resource.** Dashboards go into the default
"Main org." (org id 1) which already exists; creating an org resource would make
a *new* org, which is not desired. The provider targets the default org when no
`org_id` is set.

Decision: token **never expires** (`seconds_to_expiration` omitted) for homelab
simplicity. Rotation is an explicit operator action
(`terraform apply -replace=grafana_service_account_token.terraform`) using admin
basic auth once.

### 2.4 Auth flow (the bootstrap)
The `grafana` provider's `auth` field accepts **either** `admin:<password>`
(basic auth) **or** a raw service-account token in the same field, so the
provider config never changes:

| Step | `GRAFANA_AUTH` | What happens |
|---|---|---|
| 1st apply | `admin:<admin-password>` | Provider authenticates as admin; creates the SA + token resources; writes them to state. |
| After | `terraform output -raw grafana_token` → set `GRAFANA_AUTH` to it | Provider authenticates as the scoped `terraform` SA. |
| Rotate | `admin:<admin-password>` once, `terraform apply -replace=grafana_service_account_token.terraform`, re-export token | New token in state/output. |

`outputs.tf`: `output "grafana_token" { value = grafana_service_account_token.terraform.key, sensitive = true }`.

### 2.5 `folders.tf`
```hcl
resource "grafana_folder" "homelab" {
  title = "Homelab"
  uid   = "homelab"
}
```

### 2.6 `dashboards.tf` — one resource per dashboard
```hcl
locals {
  dashboards = toset([
    "cluster-overview", "nodes", "pods-workloads", "traefik",
    "forgejo", "storage-pvc", "cloudflare-tunnel",
  ])
}

resource "grafana_dashboard" "this" {
  for_each    = local.dashboards
  folder      = grafana_folder.homelab.uid
  config_json = file("${path.module}/dashboards/${each.key}.json")
  overwrite   = true     # revert UI drift on next apply
}
```
Each dashboard JSON's top-level `uid` is set so Grafana identity is stable across
renames; `title` matches the filename. All `datasource` objects in each JSON pin
the Prometheus datasource by **uid** (see §4).

## 3. Dashboards (folder: Homelab)

Seven JSON files in `terraform/grafana/dashboards/`. All reference the Prometheus
datasource by uid `prometheus` (see §4). Panels (illustrative, final layout at
implement time):

| File | Title | Key panels |
|---|---|---|
| `cluster-overview.json` | Cluster Overview | node count, pod count, cluster CPU%, mem%, net rx/tx, API server req/s, PVC used % |
| `nodes.json` | Nodes (Hardware) | per-node CPU%, mem%, disk used%, disk IOPS, net, load1/15, uptime |
| `pods-workloads.json` | Pods & Workloads | per-ns CPU/mem requests vs usage, per-pod CPU/mem vs limits, restarts, OOMKills |
| `traefik.json` | Traefik | RPS by entrypoint, p50/p95/p99 latency, status codes (2xx/4xx/5xx), backend errors |
| `forgejo.json` | Forgejo | http request rate, git clone/fetch ops, DB conns, Actions queue depth |
| `storage-pvc.json` | Storage / PVC | per-PVC used/capacity, local-path volume growth, kubelet volume stats |
| `cloudflare-tunnel.json` | Cloudflare Tunnel | tunnel active connections, counter requests, register/reconnect events, HA |

Dashboards are authored as **raw Grafana JSON** (schema version matching the
bundled Grafana). No Grafonnet build step.

## 4. Resolved open questions (from explore-brief)

1. **Prometheus datasource UID.** kube-prometheus-stack's bundled
   `sidecar.datasources` default publishes the Prometheus datasource with
   **uid `prometheus`**. → All dashboards pin `datasource: { type: "prometheus", uid: "prometheus" }`.
   Verified at implement time; if the actual UID differs, set
   `grafana.datasources.defaultUid`/sidecar in the monitoring HelmRelease to
   `prometheus` (single declarative edit) rather than editing every JSON.
2. **serviceMonitorNamespaceSelector.** Verified against the live cluster:
   ```
   $ kubectl get prometheus -n monitoring -o jsonpath='{.items[*].spec.serviceMonitorNamespaceSelector}'
   {}        # all namespaces
   ```
   `{}` means Prometheus discovers ServiceMonitors in **all** namespaces, so the
   new Forgejo and cloudflared ServiceMonitors are auto-discovered. **No
   monitoring HelmRelease change.** (The `serviceMonitorSelectorNilUsesHelmValues: false`
   value at `clusters/pk3s/monitoring/helmrelease.yaml:47` governs the *label*
   selector, not the namespace selector — both are independently satisfied.)
3. **Forgejo metrics port.** Forgejo serves `/metrics` on the existing HTTP port
   (3000). The chart's Service already names it `http`. → ServiceMonitor endpoint
   uses `port: http`, `path: /metrics`. No new port on the Service.
4. **Grafana version.** kube-prometheus-stack 87.0.1 bundles Grafana 11.x →
   service accounts supported. (Requirement ≥ Grafana 9.)
5. **Token expiry semantics.** Omitting `seconds_to_expiration` yields a
   never-expiring token in the pinned provider; rotation is explicit (§2.3).

## 5. K8s-side metric sources

### 5.1 Forgejo (`clusters/pk3s/forgejo/`)
- `helmrelease.yaml`: under `gitea.config`, add:
  ```yaml
  metrics:
    ENABLED: "true"
  ```
- New `servicemonitor.yaml`:
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata: { name: forgejo, namespace: forgejo }
  spec:
    selector:
      matchLabels: { app.kubernetes.io/instance: forgejo }   # verify label at implement time
    endpoints:
      - port: http
        path: /metrics
        interval: 30s
  ```
  The selector matches every Service of the `forgejo` release; only the HTTP
  Service exposes a port named `http`, so the endpoint resolves to it. Verify
  with `kubectl get svc -n forgejo --show-labels` at implement time.
- **kustomization wiring:** add `servicemonitor.yaml` to
  `clusters/pk3s/forgejo/kustomization.yaml` `resources:`.

### 5.2 cloudflared (`clusters/pk3s/cloudflared/`)
cloudflared already runs `--metrics 0.0.0.0:2000`
(`clusters/pk3s/cloudflared/deployment.yaml:24-25`).
- New `service-metrics.yaml`:
  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: cloudflared-metrics
    namespace: cloudflared
    labels:
      app.kubernetes.io/name: cloudflared-metrics   # MUST match the ServiceMonitor selector
  spec:
    selector: { app: cloudflared }
    ports:
      - { name: metrics, port: 2000, targetPort: 2000 }
  ```
- New `servicemonitor.yaml`:
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata: { name: cloudflared, namespace: cloudflared }
  spec:
    selector:
      matchLabels: { app.kubernetes.io/name: cloudflared-metrics }  # matches the Service above
    endpoints:
      - port: metrics
        path: /metrics
        interval: 30s
  ```
  The ServiceMonitor `selector` matches **Service** labels, so the label set in
  `cloudflared-metrics` `metadata.labels` (above) and the ServiceMonitor
  `selector.matchLabels` must agree.
- **kustomization wiring:** add `service-metrics.yaml` and `servicemonitor.yaml`
  to `clusters/pk3s/cloudflared/kustomization.yaml` `resources:`.

## 6. Repo wiring & docs

- `terraform/Makefile`: `validate` runs `terraform init -backend=false &&
  terraform validate` in **both** `terraform/` and `terraform/grafana/`.
  `fmt-check` is already recursive.
- `AGENTS.md`:
  - Directory Structure: add `terraform/grafana/` (new terraform root).
  - New subsection "Grafana dashboards (Terraform)": module location, separate
    state key, env-var auth (`GRAFANA_URL`/`GRAFANA_AUTH`), first-apply bootstrap
    SOP, token-rotation SOP, and the rule "dashboards are TF-managed — edit via
    repo, not the UI".
  - Note the two new metric sources (Forgejo metrics enabled; cloudflared :2000
    scraped) under the relevant app / monitoring notes.

## 7. Edge cases & risks

- **Wrong datasource UID.** If the Prometheus UID isn't `prometheus`,
  dashboards show "datasource not found." Mitigation: verify before authoring;
  fallback is a single HelmRelease edit (§4.1).
- **ServiceMonitor label mismatch.** Forgejo's Service label for `instance`
  must match the ServiceMonitor selector; verify at implement time via
  `kubectl get svc -n forgejo --show-labels`.
- **Token loss.** Token lives only in Terraform state (S3). If state is lost,
  re-bootstrap with admin password. State is in the same S3 bucket as cloudflare.
- **Provider auth after token created but env still basic-auth.** Harmless —
  both work; the provider field is the same.
- **`overwrite` reverts UI edits.** Desired behavior, but document it so users
  don't think the UI is broken.
- **Forgejo admin password in plaintext** at `clusters/pk3s/forgejo/helmrelease.yaml:23`
  is a pre-existing smell, **out of scope** for this change.

## 8. Alternatives (why not)

- Full Grafana config via Terraform — rejected (scope: dashboards only).
- Manual SA token — rejected (manual UI step + manual rotation).
- Admin basic-auth every run — rejected (over-powered account).
- Grafonnet/Jsonnet — rejected (toolchain + build step).
- Import community dashboards — rejected (inherits others' choices).
- Flat terraform/ root shared with Cloudflare — rejected (state coupling).
- Defer metric sources — rejected (two dashboards would be empty).
