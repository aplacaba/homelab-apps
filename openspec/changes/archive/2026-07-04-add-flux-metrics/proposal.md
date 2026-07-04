## Why

The homelab is a Flux GitOps cluster: every app is reconciled from this repo by
four Flux controllers in `flux-system` (`source`, `kustomize`, `helm`,
`notification`). Prometheus already scrapes node-exporter, kube-state-metrics,
kubelet/cAdvisor, Traefik, Forgejo, and cloudflared — but **it does not scrape
Flux itself**. The Flux services only expose port `80→9090`; the controllers'
Prometheus endpoint lives on port `8080` (`http-prom`) and is reached by no
`ServiceMonitor` or `PodMonitor`.

Consequence: when a `HelmRelease` stalls, a `GitRepository` stops syncing, or a
`Kustomization` starts erroring, there is **no signal in Grafana**. The only way
to notice is to `kubectl`-drill into `flux-system` logs or the Flux CLI. The
existing homelab Grafana folder has dashboards for every other piece of the
stack except the deploy pipeline itself. This change closes that gap so the
cluster's GitOps health is visible alongside everything else, reviewed and
version-controlled in the repo like the other dashboards.

## What Changes

- **New directory `clusters/pk3s/flux-monitoring/`** containing four
  `PodMonitor` resources (one per Flux controller), all `namespace: flux-system`,
  each selecting pods by `app: <controller>` and scraping the `http-prom` port
  (8080) at `/metrics` every 30s.
- Prometheus auto-discovers the PodMonitors because the stack already sets
  `podMonitorSelectorNilUsesHelmValues: false`
  (`clusters/pk3s/monitoring/helmrelease.yaml`). **No change to the monitoring
  HelmRelease.**
- The root `clusters/pk3s/kustomization.yaml` adds `flux-monitoring` to its
  `resources:`.
- **New dashboard `terraform/grafana/dashboards/flux.json`** ("Flux GitOps",
  uid `flux`) added to the Terraform-managed set in
  `terraform/grafana/dashboards.tf`, provisioned into the existing "Homelab"
  folder. Panels cover: reconcile rate, reconcile errors/s, active workers,
  reconcile success ratio (stat row); reconcile rate by result, errors over time
  by controller (time-series row); top resources by reconcile count, reconcile
  duration p95 by controller (per-resource row). All panels pin the Prometheus
  datasource by uid `prometheus`.
- `AGENTS.md` updated: directory structure entry for `flux-monitoring/`, and a
  note that Flux is now scraped.
- **Non-goals** (alternatives considered and rejected at explore time): no
  `ServiceMonitor`s or per-controller metrics `Service`s (Flux services are
  operator-owned, carrying `prune: Disabled`/`ssa: Ignore`); no patching of the
  existing `flux-system` Services (edits may be silently dropped); no
  `additionalPodMonitors` inlined in the monitoring HelmRelease (not co-located
  with anything Flux-related); not scoped down to only `kustomize`/`helm`
  (source-controller failures are the upstream cause of most deploy stalls);
  `flux-operator` itself is not scraped (it is the manager, not the reconcile
  pipeline); no Flux recording rules or Alertmanager alerts; no import of the
  official Flux community dashboard (hand-tailored JSON matches the homelab
  style).

## Capabilities

### New Capabilities
- `flux-metrics`: Prometheus scrapes the four Flux GitOps controllers
  (`source-controller`, `kustomize-controller`, `helm-controller`,
  `notification-controller`) in `flux-system` via `PodMonitor`s, exposing
  reconcile rate, errors, duration, and per-resource churn series.
- `flux-dashboard`: a version-controlled Grafana dashboard ("Flux GitOps") in
  the Homelab folder rendering the Flux GitOps pipeline health, reconciled to
  the repo by Terraform.

### Modified Capabilities
<!-- None — no existing spec covers Flux metrics or a Flux dashboard. -->

## Impact

- **New:** `clusters/pk3s/flux-monitoring/` (`kustomization.yaml`,
  `podmonitor-source.yaml`, `podmonitor-kustomize.yaml`,
  `podmonitor-helm.yaml`, `podmonitor-notification.yaml`).
- **Modified:** `clusters/pk3s/kustomization.yaml` — add `flux-monitoring` to
  `resources:` (alphabetical).
- **New:** `terraform/grafana/dashboards/flux.json`.
- **Modified:** `terraform/grafana/dashboards.tf` — add `"flux"` to the
  `dashboards` local set.
- **Modified:** `AGENTS.md` — directory structure + a one-line note that Flux is
  scraped; add Flux dashboard to the dashboard list.
- **Out-of-band (operator, one-time):** `cd terraform/grafana && terraform apply`
  with `GRAFANA_AUTH` set (per the existing SOP) to provision the new dashboard.
  No secrets enter git or chat.
- **No impact** on the Cloudflare Terraform state, the wildcard cert, Traefik,
  cert-manager, vaultwarden, cv-datastar, forgejo, forgejo-runner, sealed-secrets,
  the monitoring HelmRelease values, or existing dashboards. Flux itself is not
  reconfigured — only observed.
