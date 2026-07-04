# Explore Brief — Flux Metrics for Grafana

## Goal
Scrape the Flux GitOps controllers' Prometheus endpoints and render a Grafana
dashboard ("Flux GitOps") so the homelab's deploy pipeline (source → kustomize →
helm → notification) is observable: reconcile rate, errors, duration, and
per-resource churn. Today Prometheus does not scrape Flux at all — the Flux
services only expose port 80→9090, not the controllers' metrics port 8080.

## Alternatives considered & rejected
1. **ServiceMonitor + new metrics Service per controller** (cloudflared pattern).
   Rejected: 4 controllers × (Service + ServiceMonitor) = 8 manifests for a
   namespace we don't own; Flux services carry `prune: Disabled` / `ssa: Ignore`
   annotations signaling operator ownership. `PodMonitor` selects pods directly
   with zero new services.
2. **Patch the existing flux-system Services** to add a metrics port. Rejected:
   those Services are managed by flux-operator (`ssa: Ignore`); edits may be
   silently dropped on next Flux reconciliation.
3. **`additionalPodMonitors` inline in kube-prometheus-stack HelmRelease values**
   (like the existing inline `traefik` ServiceMonitor). Rejected: buries
   Flux-specific config inside a large unrelated values file; harder to review
   and not co-located with anything Flux-related.
4. **Scope only kustomize-controller / helm-controller** ("deploys"). Rejected:
   user chose full GitOps health; source-controller failures (GitRepo/HelmRepo
   sync) are the upstream cause of most deploy stalls and must be visible.
5. **Also scrape `flux-operator` itself.** Rejected (for now): it is the manager,
   not part of the reconcile pipeline; its metrics are operator-runtime only.
   Can be added later if desired.
6. **Add Flux recording rules / Alertmanager alerts.** Rejected: out of scope;
   user asked for metrics + dashboard. Alerts can be a follow-up change.
7. **Import the official Flux community dashboard** by ID. Rejected: inherits
   others' panel choices and label assumptions; the existing homelab dashboards
   are hand-tailored JSON and this should match that style.

## Final approach — commitments to transcribe

### Scraping (new `clusters/pk3s/flux-monitoring/`)
- Four `PodMonitor` resources, one per controller, all `namespace: flux-system`:
  `source-controller`, `kustomize-controller`, `helm-controller`,
  `notification-controller`.
- Each selects pods by label `app: <controller>` and targets the named port
  `http-prom` (container port 8080), path `/metrics`, interval 30s.
- Prometheus discovers them because
  `podMonitorSelectorNilUsesHelmValues: false` is already set
  (`clusters/pk3s/monitoring/helmrelease.yaml`). **No monitoring HelmRelease
  change.**
- `kustomization.yaml` lists the 4 PodMonitors; root `clusters/pk3s/kustomization.yaml`
  adds `flux-monitoring` to `resources:`.

### Dashboard (`terraform/grafana/dashboards/flux.json`)
- Title **"Flux GitOps"**, uid `flux`, schemaVersion 40, Homelab folder.
- Add `"flux"` to the `dashboards` set in `terraform/grafana/dashboards.tf`.
- All panels pin Prometheus datasource by uid `prometheus` (matches existing
  dashboards).
- Panels (full list, no "e.g."):
  - **Row 1 — stat (4):** Reconciliations/s
    (`sum(rate(controller_runtime_reconcile_total[5m]))`); Reconcile errors/s
    (`sum(rate(controller_runtime_reconcile_errors_total[5m]))`); Active
    workers (`sum(controller_runtime_active_workers)`); Reconcile success ratio
    (success / (success+error+requeue) over 5m).
  - **Row 2 — time series (2):** Reconcile rate by `result`
    (`success|requeue|requeue_after|error`); Reconcile errors over time by
    `controller`.
  - **Row 3 — per-resource (2):** Top 8 resources by reconcile count over 1h
    (`topk(8, sum(increase(gotk_reconcile_duration_seconds_count[1h])) by (kind,
    name, namespace))`); Reconcile duration p95 by controller
    (`histogram_quantile(0.95, sum(rate(gotk_reconcile_duration_seconds_bucket[5m])) by (le, controller))`).

### Cross-module data flow
- Prometheus (monitoring ns) → PodMonitor-discovered flux-system pods `:8080/metrics`.
- Grafana "Flux GitOps" dashboard → Prometheus datasource → those series.
- Flux reconciles the PodMonitors from this repo (kustomize-controller). Terraform
  reconciles the dashboard from `terraform/grafana/`. Two reconcilers, no coupling.

## Open questions / to verify at implement time
1. Prometheus datasource uid in this cluster is `prometheus` (existing dashboards
   already use it) — confirm and pin.
2. Pods carry the `app: <controller>` label (verified at explore: services do;
   pod labels must be confirmed, with fallback to
   `app.kubernetes.io/component` if not).
3. Whether `notification-controller` pods expose the same `http-prom` named port
   (verified yes at explore: port 8080 named `http-prom`).
4. `controller_runtime_reconcile_total{result=...}` label values present:
   `error|requeue|requeue_after|success` (verified at explore).
