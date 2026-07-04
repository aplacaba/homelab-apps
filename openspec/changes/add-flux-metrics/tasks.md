# Implementation Tasks

## 1. PodMonitors for the Flux controllers

- [x] 1.1 Create `clusters/pk3s/flux-monitoring/kustomization.yaml` listing the
      four `podmonitor-*.yaml` resources
- [x] 1.2 Create `clusters/pk3s/flux-monitoring/podmonitor-source.yaml`:
      `PodMonitor` named `source-controller`, `namespace: flux-system`,
      `spec.selector.matchLabels.app: source-controller`, endpoint
      `port: http-prom`, `path: /metrics`, `interval: 30s`
- [x] 1.3 Create `clusters/pk3s/flux-monitoring/podmonitor-kustomize.yaml` for
      `kustomize-controller` (same shape, `app: kustomize-controller`)
- [x] 1.4 Create `clusters/pk3s/flux-monitoring/podmonitor-helm.yaml` for
      `helm-controller`
- [x] 1.5 Create `clusters/pk3s/flux-monitoring/podmonitor-notification.yaml` for
      `notification-controller`
- [x] 1.6 In `clusters/pk3s/kustomization.yaml`, add `- flux-monitoring` to
      `resources:` in alphabetical order (between `flux-dashboard` and `forgejo`)
- [x] 1.7 Before committing, confirm the exact pod label: run
      `kubectl get pods -n flux-system --show-labels` and verify each controller's
      pods carry `app: <controller>`; if not, switch all four PodMonitors to
      `app.kubernetes.io/component: <controller>` (also present) and note it in
      the review-log

## 2. Flux reconciles the PodMonitors

- [ ] 2.1 Commit the new directory + root kustomization edit; push
- [ ] 2.2 Force reconcile: `kubectl -n flux-system reconcile kustomization pk3s`
      (or wait for the 1h interval)
- [ ] 2.3 Confirm `kubectl get podmonitor -n flux-system` lists all four with no
      errors
- [ ] 2.4 In the Prometheus UI (Status → Targets), or via
      `kubectl -n monitoring exec <prometheus-pod> -- wget -qO-
      http://localhost:9090/api/v1/targets` (find the pod name with `kubectl get
      pods -n monitoring`; kps runs Prometheus as a StatefulSet, not a
      Deployment), confirm the four `flux-system/*/http-prom` targets are `UP`

## 3. Flux dashboard JSON

- [x] 3.1 Create `terraform/grafana/dashboards/flux.json`: title "Flux GitOps",
      uid `flux`, schemaVersion 40, timezone `browser`, refresh `30s`,
      time `now-6h → now`, tags `["homelab","flux"]`, all panels pinning the
      Prometheus datasource as `{ "type": "prometheus", "uid": "prometheus" }`
- [x] 3.2 Row 1 — four `stat` panels (4×4 grid): Reconciliations/s
      (`sum(rate(controller_runtime_reconcile_total[5m]))`); Reconcile errors/s
      (`sum(rate(controller_runtime_reconcile_errors_total[5m]))`); Active
      workers (`sum(controller_runtime_active_workers)`); Success ratio
      (`sum(rate(controller_runtime_reconcile_total{result="success"}[5m])) /
      clamp_min(sum(rate(controller_runtime_reconcile_total[5m])), 1e-9)`)
- [x] 3.3 Row 2 — two `graph` panels: Reconcile rate by `result`
      (`sum(rate(controller_runtime_reconcile_total[5m])) by (result)` with
      `legendFormat: "{{result}}"`); Errors over time by controller
      (`sum(rate(controller_runtime_reconcile_errors_total[5m])) by (controller)`
      with `legendFormat: "{{controller}}"`)
- [x] 3.4 Row 3 — two `graph` panels: Top 8 resources by 1h reconcile count
      (`topk(8, sum(increase(gotk_reconcile_duration_seconds_count[1h])) by
      (kind, name, namespace))` with
      `legendFormat: "{{kind}}/{{name}} ({{namespace}})"`); Reconcile duration
      p95 by controller
      (`histogram_quantile(0.95, sum(rate(gotk_reconcile_duration_seconds_bucket[5m]))
      by (le, controller))` with `legendFormat: "{{controller}}"`)
- [x] 3.5 Validate the JSON parses (`python -m json.tool
      terraform/grafana/dashboards/flux.json > /dev/null`) and matches the
      panel/gridPos style of `terraform/grafana/dashboards/forgejo.json`

## 4. Terraform reconciliation

- [x] 4.1 Add `"flux"` to the `dashboards` local set in
      `terraform/grafana/dashboards.tf` (keep the list alphabetical)
- [x] 4.2 `cd terraform/grafana && terraform fmt -check -diff` (pre-commit hook
      also enforces this)
- [ ] 4.3 With `GRAFANA_AUTH` set per the existing SOP, `terraform plan` — expect
      exactly one addition (`grafana_dashboard.this["flux"]`) and the existing
      seven dashboards unchanged; resolve any unexpected change before proceeding
- [ ] 4.4 `terraform apply` (confirm the add)
- [ ] 4.5 `terraform output -raw grafana_token` still works (provider auth intact)

## 5. Dashboard verification in Grafana

- [ ] 5.1 Open Grafana → Homelab folder → **Flux GitOps** dashboard
- [ ] 5.2 Confirm all eight panels render real data (not "no data")
- [ ] 5.3 Sanity-check a known value: the Top-resources panel lists
      `Kustomization/flux-system` and the cluster's `HelmRelease`s (forgejo,
      kube-prometheus-stack, etc.)
- [ ] 5.4 Temporarily edit a panel title in the Grafana UI, re-run
      `terraform apply`, confirm it reverts (UI drift reverted = `overwrite = true`
      works for this dashboard)

## 6. AGENTS.md documentation

- [x] 6.1 Add `flux-monitoring/` to the Directory Structure section with a
      one-line description ("PodMonitors for the four Flux controllers")
- [x] 6.2 Add **flux** to the list of Terraform-managed dashboards in the
      "Grafana dashboards (Terraform)" section
- [x] 6.3 Add a Common Gotchas entry (or a note in the monitoring section) that
      Flux is scraped via PodMonitors (not ServiceMonitors) because the
      flux-system Services are operator-owned and don't expose port 8080

## 7. OpenSpec validation & close-out

- [x] 7.1 `openspec validate add-flux-metrics` passes
- [x] 7.2 Run `make lint` (or `terraform fmt -check -diff` in both terraform
      roots) and the k8s YAML is well-formed
- [ ] 7.3 Mark all tasks complete in `tasks.md`
- [ ] 7.4 Archive the change (`/opsx-archive add-flux-metrics`) after final
      review
