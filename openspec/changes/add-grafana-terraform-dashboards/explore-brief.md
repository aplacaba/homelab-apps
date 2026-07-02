# Explore Brief — Grafana Terraform Dashboards

## Goal
Manage custom homelab Grafana dashboards as Terraform resources (GitOps), so
dashboard changes are reviewed/versioned in this repo rather than hand-edited in
the Grafana UI. Datasources stay in Helm; only dashboards (plus the small metric
sources two of them need) are in scope.

## Alternatives considered & rejected
1. **Manage full Grafana config (datasources + folders + alerts + contact points)**
   via the `grafana` provider. Rejected: user scoped this to dashboards only;
   datasources already work fine from `clusters/pk3s/monitoring/helmrelease.yaml`.
2. **Manual service-account token** created in the UI. Rejected: requires a
   manual UI step and manual rotation; user chose self-bootstrap.
3. **Admin basic-auth every run.** Rejected: uses the over-powered admin account
   whose password is already in a SealedSecret; chosen approach scopes a
   dedicated SA.
4. **Grafonnet/Jsonnet** dashboard generation. Rejected: adds a jsonnet toolchain
   + build step; user chose plain JSON files in repo (reviewable diffs).
5. **Import community dashboards by ID.** Rejected: inherits others' panel choices
   and label assumptions; user wants homelab-tailored dashboards.
6. **Single flat terraform/ root** adding grafana next to cloudflare. Rejected:
   mixes two unrelated state domains in one state file; bad blast radius. A
   separate root module at `terraform/grafana/` with its own S3 state key is
   cleaner.
7. **Defer Forgejo/Cloudflare metric sources** (ship empty dashboards). Rejected:
   user chose to add both metric sources now so all 7 dashboards have data.

## Final approach — commitments to transcribe

### Terraform module layout (`terraform/grafana/`, separate root, separate state)
- `providers.tf` — `terraform` block (required_version, grafana provider, s3
  backend `key = "grafana/terraform.tfstate"`); `provider "grafana"` block using
  `url` + `auth` from variables.
- `variables.tf` — `grafana_url` (string), `grafana_auth` (string, sensitive).
- `bootstrap.tf` — `grafana_organization` (default `Main org.` if needed),
  `grafana_service_account.terraform` (name "terraform", role Admin, managed via
  `is_disabled=false`), `grafana_service_account_token.terraform` (name
  "terraform-token", secondsToExpiration=0 = no expiry or a long explicit value).
- `folders.tf` — `grafana_folder.homelab` (title "Homelab", optional uid
  "homelab").
- `dashboards.tf` — one `grafana_dashboard` per dashboard:
  `folder = grafana_folder.homelab.id`, `config_json = file("${path.module}/dashboards/<name>.json")`,
  `overwrite = true` (so re-apply reconciles UI drift back to git).
- `dashboards/*.json` — the 7 dashboard JSONs (see table).
- `outputs.tf` — `grafana_token` (sensitive) = the token, so the user can switch
  `GRAFANA_AUTH` to it after the first apply.

### Auth / bootstrap flow
- Env-driven only; nothing secret in git:
  - `GRAFANA_URL=http://grafana.local:30080` (Terraform runs on a LAN host).
  - `GRAFANA_AUTH` — first apply: `admin:<admin-password>` (basic auth, password
    from password manager). Subsequent applies: the token output by
    `terraform output -raw grafana_token`.
- The `grafana` provider `auth` accepts either basic auth (`admin:pass`) or a
  raw service-account token in the same field, so the switch is just an env-var
  change. No provider reconfig mid-run.
- Rotate: set `GRAFANA_AUTH=admin:<pass>` once, `terraform taint`/recreate the
  token resource (or `terraform apply -replace=...`), grab the new output.

### Dashboards (folder "Homelab") — full table
| File | Dashboard | Datasource | Metric source (status) |
|---|---|---|---|
| cluster-overview.json | Cluster overview: node/pod count, cluster CPU/mem/net, API server req/s, PVC usage | Prometheus | kube-state-metrics + node-exporter (already scraped) |
| nodes.json | Per-node CPU/mem/disk/diskIO/net/load/uptime | Prometheus | node-exporter (already scraped) |
| pods-workloads.json | Per-ns + per-pod CPU/mem vs requests/limits, restarts, OOMKills | Prometheus | kubelet/cAdvisor (already scraped) |
| traefik.json | RPS, p50/p95/p99 latency, status codes, backend health | Prometheus | traefik ServiceMonitor (configured at monitoring/helmrelease.yaml:51-63) |
| forgejo.json | HTTP/git ops, DB conns, Actions queue depth | Prometheus | **NEW**: enable Forgejo metrics + add ServiceMonitor |
| storage-pvc.json | PVC capacity/used, local-path growth over time | Prometheus | kube-state-metrics (already scraped) |
| cloudflare-tunnel.json | Tunnel connections, requests, reconnects | Prometheus | **NEW**: add Service+ServiceMonitor for cloudflared :2000 |

All dashboards reference the Prometheus datasource by UID. kube-prometheus-stack
creates the Prometheus datasource with a fixed UID; must verify the exact UID at
implement time (commonly `prometheus` or the release-derived value) and pin it in
every dashboard JSON's `datasource` objects.

### Metric-source additions (Kubernetes side)
- **Forgejo** (`clusters/pk3s/forgejo/`):
  - `helmrelease.yaml`: add `gitea.config.metrics.ENABLED: "true"` (and
    `DEFAULT_ENABLED: "true"` if needed) under `gitea.config`.
  - new `servicemonitor.yaml`: `ServiceMonitor` selecting
    `app.kubernetes.io/instance: forgejo`, endpoint port `http` (3000),
    path `/metrics`, interval 30s.
- **cloudflared** (`clusters/pk3s/cloudflared/`):
  - new `service-metrics.yaml`: `Service` "cloudflared-metrics" selecting
    `app: cloudflared`, port `metrics` → targetPort 2000.
  - new `servicemonitor.yaml`: `ServiceMonitor` selecting `app: cloudflared`,
    endpoint port `metrics`, path `/metrics`, interval 30s.
- Prometheus auto-discovers ServiceMonitors because `serviceMonitorSelectorNilUsesHelmValues: false`
  is already set (monitoring/helmrelease.yaml:47) — **no monitoring HelmRelease
  change needed**.
- Both ServiceMonitors live in their app namespaces; cross-ns discovery works
  because kube-prometheus-stack's Prometheus uses a namespace selector that
  covers all namespaces by default (verify at implement time; if not, add the ns
  to the prometheus `serviceMonitorNamespaceSelector`).

### Makefile / repo wiring
- `terraform/Makefile` `validate` target iterates both roots (`terraform/` and
  `terraform/grafana/`); `fmt-check` is already recursive. Update target so
  `make validate` runs `terraform init -backend=false` + `validate` in each root.
- Pre-commit hook (`terraform fmt -check`) already recursive; no hook change.

### AGENTS.md updates
- Add a "Grafana dashboards (Terraform)" subsection: module location, separate
  state, env-var auth (`GRAFANA_URL`/`GRAFANA_AUTH`), first-apply bootstrap SOP,
  token rotation SOP, "dashboards are TF-managed — edit via repo, not UI".
- Add the new `terraform/grafana/` dir to the Directory Structure.

## Cross-module data flow
- Terraform (LAN host) → HTTP → `grafana.local:30080` (Traefik NodePort) →
  `kube-prometheus-stack-grafana.monitoring:3000` (Grafana API).
- Grafana dashboards → query Prometheus datasource → Prometheus scrapes
  node-exporter/kube-state-metrics/kubelet/Traefik/Forgejo/cloudflared.
- Flux reconciles the K8s-side changes (Forgejo metrics enablement, cloudflared
  Service/ServiceMonitor, Forgejo ServiceMonitor) from this repo. Terraform
  reconciles the Grafana dashboards. Two reconcilers, no coupling.

## Open questions / things to verify at implement time
1. Exact Prometheus datasource UID created by kube-prometheus-stack (pin in
   every dashboard JSON).
2. Whether kube-prometheus-stack's Prometheus `serviceMonitorNamespaceSelector`
   covers all namespaces by default (so the new forgejo/cloudflared
   ServiceMonitors are auto-scraped). If not, add a value.
3. Whether the forgejo Helm chart exposes a named metrics port or reuses the
   http port (3000) for `/metrics` — determines ServiceMonitor port name.
4. Grafana version bundled in kube-prometheus-stack 87.0.1 — confirm it supports
   service accounts (Grafana 9+, yes).
5. Whether `grafana_service_account_token` with `seconds_to_expiration = 0`
   means "no expiry" in the provider version pinned (verify provider docs at the
   pinned version).
