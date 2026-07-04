## Context

The cluster is a single-node k3s managed by **Flux Operator v2.8.8**. Four
controllers run in `flux-system`, each a separate Deployment exposing a
Prometheus endpoint on container port `8080` named `http-prom` (verified at
explore):

| Controller | CRDs reconciled | `http-prom` port |
|---|---|---|
| `source-controller` | GitRepository, HelmRepository, OCIRepository, Bucket | 8080 |
| `kustomize-controller` | Kustomization | 8080 |
| `helm-controller` | HelmRelease | 8080 |
| `notification-controller` | Provider, Alert, Receiver | 8080 |

The Services in `flux-system` (`source-controller`, `notification-controller`,
etc.) only expose port `80 → targetPort 9090` (the controllers' HTTP API). They
do **not** expose `8080`, and they carry annotations
`kustomize.toolkit.fluxcd.io/prune: Disabled` / `ssa: Ignore` signalling they are
owned by `flux-operator`.

Prometheus (`kube-prometheus-stack` 87.x in `monitoring`) already discovers
scrape targets via `PodMonitor` and `ServiceMonitor` across all namespaces
because the HelmRelease sets both
`serviceMonitorSelectorNilUsesHelmValues: false` and
`podMonitorSelectorNilUsesHelmValues: false`
(`clusters/pk3s/monitoring/helmrelease.yaml:47-48`). Existing app scrapers
(cloudflared, forgejo) use `ServiceMonitor` + a dedicated metrics `Service`.

Grafana dashboards are **Terraform-managed** from `terraform/grafana/` (separate
local state). The Homelab folder is populated from
`terraform/grafana/dashboards/*.json` via a `toset([...])` local in
`dashboards.tf`; each `grafana_dashboard` resource uses `overwrite = true` so
UI edits revert to the repo. Dashboards pin the Prometheus datasource by uid
`prometheus` (confirmed: every existing dashboard JSON uses
`{ "type": "prometheus", "uid": "prometheus" }`).

The Flux controllers emit, among others:
- `controller_runtime_reconcile_total{controller,result}` — counter, `result`
  ∈ `{success, requeue, requeue_after, error}` (verified).
- `controller_runtime_reconcile_errors_total{controller}` — counter.
- `controller_runtime_active_workers{controller}` — gauge.
- `gotk_reconcile_duration_seconds_bucket{kind,name,namespace,le}` — histogram
  per reconciled resource (e.g. `kind="HelmRelease",name="forgejo",namespace="forgejo"`);
  plus matching `_count` / `_sum` (verified).
- `gotk_cache_events_total`, `gotk_token_cached_items` (source-controller).

## Goals / Non-Goals

**Goals:**
- Prometheus scrapes all four Flux reconcile controllers' `/metrics`.
- A reviewed, version-controlled Grafana dashboard renders GitOps pipeline
  health (rate, errors, duration, per-resource churn).
- No change to Flux itself, the monitoring HelmRelease, or any unrelated app.

**Non-Goals:**
- Scraping the `flux-operator` manager pod (runtime-only metrics, not the
  reconcile pipeline).
- Flux recording rules or Alertmanager alerts (follow-up change).
- Reconfiguring Flux, its Services, or its RBAC.
- Editing dashboards in the Grafana UI (Terraform is the source of truth).

## Decisions

### Decision 1: Scrape via `PodMonitor`, not `ServiceMonitor`+`Service`
**Choice:** One `PodMonitor` per controller, selecting pods by `app:
<controller>` and targeting the named port `http-prom` (8080).
**Why:** A `PodMonitor` selects pods directly and needs no `Service`. The Flux
Services don't expose 8080 and are operator-owned (`ssa: Ignore`); creating four
new metrics Services just to feed four `ServiceMonitor`s is 8 manifests in a
namespace we don't own, for no functional gain. `PodMonitor` is the
purpose-built CRD for "scrape these pods directly".
**Alternative considered:** mirror the cloudflared pattern (new metrics `Service`
+ `ServiceMonitor` per controller) — rejected for the extra, unrelated Services
in `flux-system`.

### Decision 2: One PodMonitor per controller (not one combined)
**Choice:** Four `PodMonitor` resources (`podmonitor-source.yaml`,
`podmonitor-kustomize.yaml`, `podmonitor-helm.yaml`,
`podmonitor-notification.yaml`).
**Why:** Each maps 1:1 to a controller/Deployment, so each is independently
readable and disable-able. A single combined `PodMonitor` would need an
`In`-style selector and obscure which controller a scrape failure relates to.
**Alternative considered:** one `PodMonitor` with a broad selector — rejected on
readability and blast-radius.

### Decision 3: Placement in a new `clusters/pk3s/flux-monitoring/` directory
**Choice:** New directory referenced from the root kustomization. PodMonitors
carry `namespace: flux-system` (where the target pods live) but the manifests
live under `flux-monitoring/`.
**Why:** Groups everything Flux-observability-related in one reviewable place;
keeps the monitoring HelmRelease dir focused on the kps release; follows the
"one concern per directory" convention in AGENTS.md. No `namespace.yaml` is
needed — `flux-system` already exists and is not owned by this change.
**Alternative considered:** drop the PodMonitors into `clusters/pk3s/monitoring/`
— rejected because that dir is the kps HelmRelease, not a grab-bag for foreign
scrapers.

### Decision 4: Discovery requires no monitoring HelmRelease change
**Choice:** Rely on the existing
`podMonitorSelectorNilUsesHelmValues: false`.
**Why:** A nil selector = "select PodMonitors in all namespaces with any labels".
The four PodMonitors are picked up automatically once applied. No values edit,
no Flux reconcile of the monitoring release.
**Alternative considered:** inline `additionalPodMonitors` in the kps HelmRelease
(like the inline `traefik` ServiceMonitor) — rejected because it buries
Flux-specific config in a large unrelated values file and is not co-located with
the dashboard it supports.

### Decision 5: Dashboard scope = full GitOps pipeline (4 controllers)
**Choice:** The dashboard shows reconcile rate/errors/duration across all four
controllers, plus per-resource breakdowns.
**Why:** A deploy stall usually originates upstream (source-controller failing to
sync a `GitRepository`/`HelmRepository`), so a helm/kustomize-only view hides the
root cause. Full pipeline = end-to-end signal.
**Alternative considered:** deploy-only (helm + kustomize) — rejected (see brief).

### Decision 6: Panel set and PromQL
**Choice:** Eight panels in three rows, datasource pinned by uid `prometheus`,
matching the existing dashboard style (`schemaVersion: 40`, `refresh: 30s`,
`time: now-6h → now`, `timezone: browser`):

- **Row 1 — stat:** Reconciliations/s, Reconcile errors/s, Active workers,
  Success ratio.
- **Row 2 — time series:** Reconcile rate by `result`, Errors over time by
  `controller`.
- **Row 3 — per-resource:** Top-8 resources by 1h reconcile count, Reconcile
  duration p95 by controller.

Key PromQL (final queries; verified against the metrics present at explore):
- Reconciliations/s: `sum(rate(controller_runtime_reconcile_total[5m]))`
- Errors/s: `sum(rate(controller_runtime_reconcile_errors_total[5m]))`
- Active workers: `sum(controller_runtime_active_workers)`
- Success ratio:
  `sum(rate(controller_runtime_reconcile_total{result="success"}[5m])) / clamp_min(sum(rate(controller_runtime_reconcile_total[5m])), 1e-9)`
  (`clamp_min` with a tiny epsilon avoids div-by-zero on idle clusters without
  distorting the ratio — rates are per-second and usually ≪ 1, so a clamp of `1`
  would always activate and turn the ratio into a raw rate).
- Rate by result:
  `sum(rate(controller_runtime_reconcile_total[5m])) by (result)`
- Errors over time:
  `sum(rate(controller_runtime_reconcile_errors_total[5m])) by (controller)`
- Top resources:
  `topk(8, sum(increase(gotk_reconcile_duration_seconds_count[1h])) by (kind, name, namespace))`
- Duration p95:
  `histogram_quantile(0.95, sum(rate(gotk_reconcile_duration_seconds_bucket[5m])) by (le, controller))`

**Alternative considered:** p99 duration and a "errors by resource" panel —
rejected (YAGNI for a homelab; the by-controller view is enough to localise, and
`gotk_reconcile_duration_seconds` has no error dimension).

### Decision 7: Terraform reconciliation is a one-time `apply`
**Choice:** Add `"flux"` to the `dashboards` local in
`terraform/grafana/dashboards.tf`; the new `flux.json` is picked up by the
existing `for_each`.
**Why:** The module already iterates `local.dashboards`; adding one string is the
whole change. `overwrite = true` means subsequent `apply`s reconcile drift back
to the repo. No provider/auth change.
**Alternative considered:** a separate Terraform root for Flux dashboards —
rejected; the grafana module exists precisely to hold all homelab dashboards.

## Risks / Trade-offs

- **[Pod label assumption]** the PodMonitors select on `app: <controller>`. The
  flux-system **Services** carry that label; pod labels were not exhaustively
  verified at explore → **mitigation**: confirm pod labels at implement time and
  fall back to `app.kubernetes.io/component: <controller>` (also present) if
  `app` is absent on pods.
- **[Series cardinality]** `gotk_reconcile_duration_seconds_bucket` has
  per-resource labels; on a homelab (~10 Flux resources) this is trivial. No
  relabelling needed.
- **[Prometheus datasource uid]** pinned as `prometheus`; if a future kps upgrade
  changes the generated uid, the panel shows "no data" → consistent with every
  existing dashboard (same assumption); not specific to this change.
- **[Two reconcilers]** Flux reconciles the PodMonitors; Terraform reconciles the
  dashboard. A dashboard opened before the PodMonitors land shows "no data"
  transiently → resolves on the next Flux pass (~1h, or force-reconcile).
- **[Terraform apply is out-of-band]** the dashboard does not appear until the
  operator runs `terraform apply` in `terraform/grafana/` with `GRAFANA_AUTH`
  per the existing SOP (AGENTS.md).

## Migration Plan

1. Create `clusters/pk3s/flux-monitoring/` with `kustomization.yaml` and four
   `podmonitor-*.yaml`; add `flux-monitoring` to the root
   `clusters/pk3s/kustomization.yaml` resources (alphabetical slot, between
   `flux-dashboard` and `forgejo`).
2. Commit + push; Flux reconciles the PodMonitors. Verify:
   `kubectl get podmonitor -n flux-system` shows all four, and the Prometheus
   UI/targets show the controllers `UP` at `:8080/metrics`; `controller_runtime_*`
   and `gotk_*` series exist in Prometheus.
3. Author `terraform/grafana/dashboards/flux.json` (Decision 6 panels/PromQL);
   add `"flux"` to the `dashboards` local in `terraform/grafana/dashboards.tf`.
4. `cd terraform/grafana && terraform fmt && terraform plan` — expect one new
   `grafana_dashboard.flux` plus the existing dashboards unchanged; then
   `terraform apply` (with `GRAFANA_AUTH` set per SOP).
5. Open Grafana → Homelab → "Flux GitOps"; confirm all panels render real data.
6. Update `AGENTS.md` (directory structure + dashboard list + "Flux is scraped").
7. `openspec validate add-flux-metrics` passes; mark tasks complete.
