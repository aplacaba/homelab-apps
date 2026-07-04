# flux-metrics

## Purpose

Prometheus scrapes the four Flux GitOps controllers
(`source-controller`, `kustomize-controller`, `helm-controller`,
`notification-controller`) running in the `flux-system` namespace, so the
cluster's deploy pipeline is observable. Implemented as `PodMonitor` resources
under `clusters/pk3s/flux-monitoring/` — Flux itself is only observed, never
reconfigured.

## Requirements

### Requirement: Prometheus scrapes the Flux GitOps controllers
Prometheus MUST scrape the four Flux reconcile controllers
  (`source-controller`, `kustomize-controller`, `helm-controller`,
  `notification-controller`) in the `flux-system` namespace via `PodMonitor`
  resources, with no change to the monitoring HelmRelease.

#### Scenario: Four PodMonitors reconcile
- **WHEN** Flux reconciles `clusters/pk3s/flux-monitoring/`
- **THEN** four `PodMonitor` resources exist in `flux-system`
  (`source-controller`, `kustomize-controller`, `helm-controller`,
  `notification-controller`), each selecting pods of its controller and scraping
  the `http-prom` port (8080) at `/metrics` every 30s.

#### Scenario: Prometheus discovers the targets with no values change
- **WHEN** the PodMonitors are applied
- **THEN** Prometheus (whose
  `podMonitorSelectorNilUsesHelmValues: false` is already set in
  `clusters/pk3s/monitoring/helmrelease.yaml`) discovers all four scrape targets
  and they report `UP`; the monitoring HelmRelease values are unchanged.

#### Scenario: Flux series appear in Prometheus
- **WHEN** the targets are `UP`
- **THEN** Prometheus stores `controller_runtime_reconcile_total`,
  `controller_runtime_reconcile_errors_total`, `controller_runtime_active_workers`,
  and `gotk_reconcile_duration_seconds_bucket` series for the Flux controllers.

### Requirement: Flux left unmodified
The change MUST NOT modify Flux itself, its `flux-system` Services, RBAC, or the
  Flux Operator configuration — it only observes Flux.

#### Scenario: No Flux resource is patched
- **WHEN** the change is applied
- **THEN** the `flux-system` Services, Deployments, and the Flux Operator
  manifest are byte-identical to before; only new `PodMonitor` resources are
  added (in `flux-system`) and a new manifest directory under `clusters/pk3s/`.
