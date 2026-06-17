# Design: Promtail DaemonSet for Cluster-Wide Logging

**Date:** 2025-06-17  
**Status:** Approved

## Problem

Loki is deployed in `monitoring` namespace (SingleBinary, 10Gi PVC, 7d retention)
but no log collector is running. Container logs from all pods — including
`cv-datastar` — exist only ephemerally on the node. They cannot be queried in
Grafana via the existing Loki datasource.

## Solution

Deploy Promtail as a standalone HelmRelease in `monitoring` namespace, using the
`grafana/promtail` chart from the existing `grafana` HelmRepository.

### What changes

| File | Action |
|---|---|
| `clusters/pk3s/monitoring/helmrelease-promtail.yaml` | New — Promtail HelmRelease |
| `clusters/pk3s/monitoring/kustomization.yaml` | Edit — add the new resource |

### What does NOT change

- Loki — no changes to `helmrelease-loki.yaml` (volume, retention, schema all fine)
- cv-datastar — no changes needed; Promtail DaemonSet collects stdout logs automatically
- Root `kustomization.yaml` — monitoring directory already listed
- Any existing HelmRepository — the `grafana` repo is already defined and used by Loki

## Configuration

### `helmrelease-promtail.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: promtail
  namespace: monitoring
spec:
  interval: 1h
  chart:
    spec:
      chart: promtail
      version: "6.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    config:
      clients:
        - url: http://loki.monitoring:3100/loki/api/v1/push
    tolerations:
      - operator: Exists
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

### Design decisions

- **Standalone HelmRelease** — matches the repo pattern (one per component), independent
  lifecycle from Loki chart
- **`grafana` HelmRepository** already exists in `flux-system`, used by Loki — no new repo needed
- **Chart version `6.x`** — same major line as the Loki chart, tested together
- **Tolerate all taints** — the single k3s node may have node-level taints; Promtail must run
  regardless, so `operator: Exists` ensures the DaemonSet pod lands
- **Resource quotas** — 50m/128Mi requests, 200m/256Mi limits (lightweight, appropriate for
  homelab scale)
- **Default scrape configs** — the chart ships with built-in scrape configs for pod logs,
  container logs, and journal; all defaults are kept
- **No extra labels** — the existing ServiceMonitor label convention
  (`release: prometheus`) doesn't apply to Promtail (it pushes to Loki, Prometheus
  doesn't scrape it)

### `kustomization.yaml` change

Add `- helmrelease-promtail.yaml` to the resources list, after
`helmrelease-loki.yaml`:

```yaml
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrepository-loki.yaml
  - helmrelease.yaml
  - helmrelease-loki.yaml
  - helmrelease-promtail.yaml    # new
  - ingressroute.yaml
```

## Verification

After Flux reconciles:

1. Confirm DaemonSet is running:
   ```bash
   kubectl get daemonset -n monitoring promtail
   ```

2. Confirm Promtail connects to Loki:
   ```bash
   kubectl logs -n monitoring daemonset/promtail --tail=20
   ```
   Look for "Ready" status and no connection errors to Loki.

3. Query cv-datastar logs in Grafana:
   ```
   {namespace="cv-datastar"}
   ```
   Should return recent nginx access/error log lines.

4. Confirm all namespaces are being collected:
   ```
   {namespace=~".+"} | line_format "{{.namespace}}"
   ```
