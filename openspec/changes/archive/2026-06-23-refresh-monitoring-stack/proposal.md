## Why

The monitoring stack is two generations behind: **kube-prometheus-stack is on
`69.8.2`** (operator `v0.80.1`) while the chart is at **`87.0.1`** (operator
`v0.92.0`) — 18 majors behind, carrying multiple Grafana/Prometheus/Alertmanager
and operator-CRD changes. Loki is a major behind (`6.55.0` → `7.0.0`). In-place
upgrading kps across this gap is error-prone (immutable label-selector changes on
the managed DaemonSets/StatefulSets). For a single-replica, `local-path`
homelab, a **clean reinstall** is lower-risk than a fragile in-place upgrade.
Additionally, Grafana admin credentials are currently `admin/admin` in **plaintext
in git**; the reinstall is a natural moment to seal them.

## What Changes

- **Reinstall kube-prometheus-stack `69.8.2 → 87.0.1`** via a Flux-suspended clean
  reinstall: uninstall → delete the 10 `monitoring.coreos.com` CRDs (cascades the
  Prometheus/Alertmanager CRs + managed workloads) + the 3 kps PVCs → install
  fresh. **Accepts loss of ~7d Prometheus history and chart-provisioned
  dashboards** (dashboards regenerate; user-saved dashboards on the Grafana PV
  are lost).
- **Bump Loki `6.55.0 → 7.0.0`** in-place via Flux (preserves the 10Gi PV /
  logs); fall back to StatefulSet recreate if a selector is immutable.
- **Promtail** — already on latest (`6.17.1`); no change.
- **Migrate `monitoring/helmrelease.yaml` values** to 87.x: validate with
  `helm template`, fix removed/renamed keys, switch Grafana admin to a
  `SealedSecret`.
- **Add Grafana admin `SealedSecret`** (`grafana-admin-secret` in `monitoring`);
  reference from Grafana values; remove plaintext `admin/admin`.
- **BREAKING (data):** Prometheus history, Alertmanager state, and Grafana
  user-saved state are deleted in the reinstall (ephemeral homelab data,
  acceptable).
- **BREAKING (operational, brief):** monitoring is unavailable during the
  reinstall window (~minutes). No impact on other apps — monitoring is
  read-only/observability.

## Capabilities

### New Capabilities
- `monitoring-stack`: a current, securely-configured kube-prometheus-stack +
  Loki monitoring stack on the cluster.

### Modified Capabilities
<!-- None — no existing spec in openspec/specs/ for monitoring. -->

## Impact

- **Modified:** `clusters/pk3s/monitoring/helmrelease.yaml` (kps → 87.0.1 + value
  migration + Grafana `existingSecret`); `clusters/pk3s/monitoring/helmrelease-loki.yaml`
  (Loki → 7.0.0).
- **New:** `clusters/pk3s/monitoring/sealedsecret-grafana-admin.yaml`; added to
  `monitoring/kustomization.yaml`.
- **Out-of-band (destructive, cluster):** `helm uninstall` kps, delete 10
  monitoring CRDs, delete 3 kps PVCs. Flux `suspend`/`resume` of the kps
  HelmRelease.
- **External dependency:** a new Grafana admin password (generated out-of-band,
  sealed via `kubeseal`).
- **No impact** on cert-manager, traefik, cloudflared, forgejo, cv-datastar,
  vaultwarden.
