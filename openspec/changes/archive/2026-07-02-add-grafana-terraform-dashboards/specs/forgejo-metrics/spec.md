## ADDED Requirements

### Requirement: Forgejo exposes Prometheus metrics
Forgejo MUST expose its built-in Prometheus metrics on its HTTP endpoint so
  Prometheus can scrape application-level signals (HTTP/git ops, DB conns,
  Actions queue depth).

#### Scenario: Metrics endpoint enabled
- **WHEN** the Forgejo HelmRelease reconciles with `gitea.config.metrics.ENABLED: "true"`
- **THEN** `GET http://forgejo-http.forgejo.svc:3000/metrics` returns Prometheus
  exposition-format metrics (HTTP 200).

### Requirement: Prometheus scrapes Forgejo metrics
A `ServiceMonitor` in the `forgejo` namespace MUST cause the existing Prometheus
  instance to scrape Forgejo `/metrics`, with no change to the monitoring
  HelmRelease.

#### Scenario: ServiceMonitor discovered
- **WHEN** the `forgejo` ServiceMonitor is applied
- **THEN** Prometheus (whose `serviceMonitorNamespaceSelector` is `{}` = all
  namespaces) discovers it and begins scraping the `http` port at `/metrics`
  every 30s; `forgejo_*` series appear in Prometheus.

#### Scenario: Forgejo dashboard has data
- **WHEN** the Forgejo dashboard (in the Homelab folder) is opened
- **THEN** panels for HTTP rate, git ops, DB connections, and Actions queue depth
  render real data rather than "no data".
