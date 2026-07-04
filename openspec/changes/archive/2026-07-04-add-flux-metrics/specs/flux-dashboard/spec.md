## ADDED Requirements

### Requirement: Flux GitOps dashboard managed as code
A Grafana dashboard for the Flux GitOps pipeline MUST be provisioned and
  reconciled by Terraform into the existing Homelab folder (title **Flux
  GitOps**, uid `flux`, sourced from `terraform/grafana/dashboards/flux.json`),
  so the repo is the source of truth and UI edits are reverted.

#### Scenario: Dashboard present after apply
- **WHEN** `terraform apply` succeeds in `terraform/grafana/` after `"flux"` is
  added to the `dashboards` local in `terraform/grafana/dashboards.tf`
- **THEN** Grafana's **Homelab** folder contains a dashboard titled **Flux
  GitOps** (uid `flux`) sourced from
  `terraform/grafana/dashboards/flux.json`.

#### Scenario: UI drift is reverted
- **WHEN** someone edits the Flux dashboard in the Grafana UI and a subsequent
  `terraform apply` runs
- **THEN** the dashboard is reset to the JSON in the repo (`overwrite = true`);
  manual UI edits do not persist.

#### Scenario: Datasource pinned by UID
- **WHEN** any panel in the Flux dashboard queries a datasource
- **THEN** it references the Prometheus datasource by **uid** (`prometheus`),
  not by name, consistent with the other homelab dashboards.

### Requirement: Dashboard renders the full GitOps pipeline
The Flux dashboard MUST render reconcile health across all four Flux controllers
  (source, kustomize, helm, notification) — rate, errors, duration, and
  per-resource churn — so an upstream source-controller failure is visible
  alongside deploy (helm/kustomize) activity.

#### Scenario: Overview stat row
- **WHEN** the dashboard is opened
- **THEN** a stat row shows: total reconciliations/s, reconcile errors/s, active
  workers, and reconcile health (the non-error reconcile ratio, `1 -
  error/total`, reading ~1.0 when healthy), all computed from
  `controller_runtime_*` series.

#### Scenario: Time-series row
- **WHEN** the dashboard is opened
- **THEN** two time-series panels show reconcile rate broken down by `result`
  (`success`/`requeue`/`requeue_after`/`error`) and reconcile errors over time by
  `controller`.

#### Scenario: Per-resource row
- **WHEN** the dashboard is opened
- **THEN** two panels show the top resources by 1h reconcile count (grouped by
  `kind`, `name`, `namespace`) and the reconcile duration p95 by controller,
  both computed from `gotk_reconcile_duration_seconds_*`.

#### Scenario: Dashboard has real data once scraped
- **WHEN** Prometheus is scraping the Flux controllers (capability
  `flux-metrics`) and the dashboard is opened
- **THEN** the panels render real data rather than "no data".
