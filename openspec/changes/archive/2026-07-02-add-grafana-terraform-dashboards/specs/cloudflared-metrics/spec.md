## ADDED Requirements

### Requirement: A Service exposes cloudflared's metrics endpoint
A dedicated `Service` MUST expose cloudflared's already-running metrics listener
  (`--metrics 0.0.0.0:2000`) so Prometheus can select and scrape it.

#### Scenario: Metrics Service exists
- **WHEN** the cloudflared manifests reconcile
- **THEN** a `cloudflared-metrics` Service in the `cloudflared` namespace routes
  port `metrics` (2000) to the cloudflared pod(s), and carries the label
  `app.kubernetes.io/name: cloudflared-metrics`.

### Requirement: Prometheus scrapes cloudflared metrics
A `ServiceMonitor` in the `cloudflared` namespace MUST cause the existing
  Prometheus instance to scrape `cloudflared-metrics:2000/metrics`, with no change
  to the monitoring HelmRelease.

#### Scenario: ServiceMonitor selects the metrics Service
- **WHEN** the `cloudflared` ServiceMonitor is applied
- **THEN** its `selector` matches the `cloudflared-metrics` Service's labels
  (`app.kubernetes.io/name: cloudflared-metrics`), and Prometheus (namespace
  selector `{}`) scrapes it every 30s; `cloudflared_*` / tunnel series appear.

#### Scenario: Cloudflare tunnel dashboard has data
- **WHEN** the cloudflare-tunnel dashboard (in the Homelab folder) is opened
- **THEN** panels for tunnel connections, request counters, and reconnect events
  render real data rather than "no data".
