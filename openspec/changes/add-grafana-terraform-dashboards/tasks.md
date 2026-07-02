# Implementation Tasks

## 1. Terraform grafana module scaffolding

- [x] 1.1 Create `terraform/grafana/providers.tf`: `terraform` block (required_version `>= 1.9`, grafana provider `grafana/grafana` `~> 3.0`, S3 backend with `key = "grafana/terraform.tfstate"` mirroring the skip-flags in `terraform/providers.tf`); `provider "grafana"` using `url = var.grafana_url`, `auth = var.grafana_auth`.
- [x] 1.2 Create `terraform/grafana/variables.tf` with `grafana_url` (string) and `grafana_auth` (string, sensitive), each multi-line valid HCL.
- [x] 1.3 Create `terraform/grafana/bootstrap.tf`: `grafana_service_account.terraform` (name "terraform", role "Admin", is_disabled false) and `grafana_service_account_token.terraform` (name "terraform-token", `seconds_to_expiration` omitted). No `grafana_organization` resource.
- [x] 1.4 Create `terraform/grafana/folders.tf`: `grafana_folder.homelab` (title "Homelab", uid "homelab").
- [x] 1.5 Create `terraform/grafana/outputs.tf`: `output "grafana_token"` (sensitive) = `grafana_service_account_token.terraform.key`.
- [x] 1.6 Create `terraform/grafana/dashboards.tf`: `locals.dashboards = toset([...7 names...])` and `grafana_dashboard.this` `for_each`, `folder = grafana_folder.homelab.uid`, `config_json = file(...)`, `overwrite = true`.
- [x] 1.7 `cd terraform/grafana && terraform fmt` then `terraform init -backend=false && terraform validate` — must pass.

## 2. Verify Prometheus datasource UID + target data

- [x] 2.1 Confirm the Prometheus datasource **uid** is `prometheus` (query the Grafana API or read the sidecar-generated datasource). If it differs, make a **single declarative edit** to `clusters/pk3s/monitoring/helmrelease.yaml` (set the sidecar default uid to `prometheus`) — do **not** edit every dashboard JSON (the dashboards are committed to uid `prometheus` per design §4.1).
- [x] 2.2 Note the bundled Grafana version (`kubectl exec ... grafana -- grafana-cli -v` or image tag) — confirm ≥ 9 (service accounts supported).

## 3. Author the seven dashboards

- [x] 3.1 Create `terraform/grafana/dashboards/cluster-overview.json` (node/pod counts, cluster CPU/mem/net, API server req/s, PVC usage; datasource uid `prometheus`).
- [x] 3.2 Create `nodes.json` (per-node CPU/mem/disk/diskIO/net/load/uptime from node-exporter).
- [x] 3.3 Create `pods-workloads.json` (per-ns + per-pod CPU/mem vs requests/limits, restarts, OOMKills).
- [x] 3.4 Create `traefik.json` (RPS, p50/p95/p99 latency, status codes, backend health from `traefik_*` series).
- [x] 3.5 Create `forgejo.json` (HTTP rate, git ops, DB conns, Actions queue depth from `forgejo_*` series; will show data only after §4 lands).
- [x] 3.6 Create `storage-pvc.json` (per-PVC used/capacity, volume growth from `kubelet_volume_stats_*` / kube-state-metrics).
- [x] 3.7 Create `cloudflare-tunnel.json` (tunnel connections, request counters, reconnect events from `cloudflared_*` series; will show data only after §5 lands).
- [x] 3.8 Validate each JSON parses (`jq . <file>` ok) and has a stable top-level `uid`.

## 4. Forgejo metrics source

- [x] 4.1 In `clusters/pk3s/forgejo/helmrelease.yaml`, under `gitea.config`, add `metrics: { ENABLED: "true" }`.
- [x] 4.2 Create `clusters/pk3s/forgejo/servicemonitor.yaml` (ServiceMonitor selecting `app.kubernetes.io/instance: forgejo`, endpoint `port: http`, `path: /metrics`, `interval: 30s`).
- [x] 4.3 Add `servicemonitor.yaml` to `clusters/pk3s/forgejo/kustomization.yaml` `resources:`.
- [x] 4.4 Verify the http Service labels with `kubectl get svc -n forgejo --show-labels` (confirm `app.kubernetes.io/instance: forgejo` is present; tighten selector if needed).
- [x] 4.5 Force reconcile: `kubectl -n flux-system reconcile helmrelease forgejo`; confirm `curl http://forgejo-http.forgejo.svc:3000/metrics` returns 200 Prometheus text.

## 5. cloudflared metrics source

- [x] 5.1 Create `clusters/pk3s/cloudflared/service-metrics.yaml`: Service `cloudflared-metrics`, `metadata.labels: { app.kubernetes.io/name: cloudflared-metrics }`, `spec.selector: { app: cloudflared }`, port `metrics`→2000.
- [x] 5.2 Create `clusters/pk3s/cloudflared/servicemonitor.yaml`: ServiceMonitor `cloudflared`, `selector.matchLabels: { app.kubernetes.io/name: cloudflared-metrics }`, endpoint `port: metrics`, `path: /metrics`, `interval: 30s`.
- [x] 5.3 Add both files to `clusters/pk3s/cloudflared/kustomization.yaml` `resources:`.
- [x] 5.4 Force reconcile (kubectl reconcile kustomization or wait), confirm `kubectl get servicemonitor -n cloudflared` and that Prometheus targets show cloudflared up.

## 6. Repo wiring

- [x] 6.1 Update `terraform/Makefile`: make `validate` run `terraform init -backend=false && terraform validate` in both `terraform/` and `terraform/grafana/`. (`fmt-check` is already recursive.)
- [x] 6.2 `cd terraform && make lint` passes.

## 7. First apply (operator, out-of-band)

- [x] 7.1 Set env: `GRAFANA_URL=http://grafana.local:30080` and `GRAFANA_AUTH=admin:<admin-password>` (password from password manager / `grafana-admin-secret` SealedSecret decrypt).
- [x] 7.2 `cd terraform/grafana && terraform init` (real S3 backend) && `terraform plan` — confirm plan creates the SA, token, folder, and 7 dashboards, nothing else.
- [x] 7.3 `terraform apply`; capture `terraform output -raw grafana_token`; set `GRAFANA_AUTH` to it for future runs.
- [x] 7.4 With `GRAFANA_AUTH` now set to the token, run `terraform plan` again — it should report **no changes** (proves subsequent applies authenticate as the `terraform` SA, satisfying the "Subsequent applies use the token" scenario).
- [x] 7.5 In Grafana UI confirm the **Homelab** folder holds the 7 dashboards.

## 8. Verify dashboards have data

- [x] 8.1 Open each dashboard; the 5 with existing sources (cluster-overview, nodes, pods-workloads, traefik, storage-pvc) show data immediately.
- [x] 8.2 After Forgejo metrics settle (~1 min), `forgejo.json` shows `forgejo_*` data.
- [x] 8.3 After cloudflared scrape settles, `cloudflare-tunnel.json` shows `cloudflared_*` data.
- [x] 8.4 Edit one dashboard in the UI, re-run `terraform apply`, confirm it reverts to the repo version.

## 9. Documentation

- [x] 9.1 Update `AGENTS.md` Directory Structure: add `terraform/grafana/`.
- [x] 9.2 Add an `AGENTS.md` subsection "Grafana dashboards (Terraform)": module location, separate state key, env-var auth (`GRAFANA_URL`/`GRAFANA_AUTH`), first-apply bootstrap SOP, token-rotation SOP (`terraform apply -replace=...`), and the rule "dashboards are TF-managed — edit via repo, not UI; UI edits revert on next apply".
- [x] 9.3 Note in `AGENTS.md` the two new metric sources (Forgejo metrics enabled; cloudflared :2000 scraped via `cloudflared-metrics` Service).

## 10. OpenSpec validation

- [x] 10.1 `openspec validate add-grafana-terraform-dashboards` passes.
- [x] 10.2 Final review: all task checkboxes ticked; no files outside the proposal scope modified.
