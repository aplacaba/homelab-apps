## Context

The `monitoring` namespace runs kube-prometheus-stack `69.8.2` (prometheus-operator
`v0.80.1`) plus standalone Loki `6.55.0` and Promtail `6.17.1`. kps provisions:
Prometheus (1 replica, 7d/20Gi), Alertmanager (1 replica, 5Gi), Grafana (1
replica, 5Gi persistence, admin/admin plaintext, chart-provisioned dashboards +
Loki datasource), kube-state-metrics, node-exporter (3 nodes), kubelet + coreDNS
scraping (controller-manager/scheduler/etcd disabled). All single-replica on
`local-path` storage.

kps is 18 chart majors behind (`69 → 87`, operator `v0.80.1 → v0.92.0`). kps
major upgrades are notorious for `field is immutable` errors because pod
label/selectors on the managed DaemonSets (node-exporter) / StatefulSets
(Prometheus, Alertmanager) / Deployments (kube-state-metrics, grafana) change
across versions, and Kubernetes forbids mutating selectors.

10 `monitoring.coreos.com` CRDs are installed; 3 kps PVCs exist
(`prometheus-prometheus-prometheus-db-*` 20Gi,
`alertmanager-prometheus-alertmanager-db-*` 5Gi, `kube-prometheus-stack-grafana`
5Gi). Loki is a non-operator chart (StatefulSet `loki` + `storage-loki-0` 10Gi).

Flux manages all three via `HelmRelease` (supports `spec.suspend`).

## Goals / Non-Goals

**Goals:**
- kps on `87.0.1` and Loki on `7.0.0`, via the lowest-risk path.
- Remove plaintext Grafana admin creds from git.
- No impact on non-monitoring apps.

**Non-Goals:**
- Preserving Prometheus/Alertmanager/Grafana history (reinstall intentionally
  discards it).
- HA / multi-replica monitoring (stays single-replica).
- Changing retention, scraping topology, or Loki/Promtail architecture.
- Bumping Promtail (already latest).

## Decisions

### Decision 1: kps via clean reinstall, not in-place
**Choice:** Suspend the kps HelmRelease, `helm uninstall`, delete the 10 operator
CRDs + 3 kps PVCs, then install 87 fresh.
**Why:** An in-place 69→87 upgrade will hit immutable-selector errors on multiple
managed workloads, requiring manual deletion of each anyway. Doing a deliberate,
ordered clean reinstall is faster, deterministic, and avoids a half-upgraded
state. Data loss is acceptable (ephemeral homelab metrics; dashboards are
chart-provisioned and regenerate).
**Alternative considered:** in-place upgrade with per-workload selector cleanup —
rejected as more fragile for a 18-major gap with no data-preservation benefit.

### Decision 2: Loki in-place, preserve logs
**Choice:** Bump Loki 6.55→7.0 via Flux's normal helm upgrade, keeping the 10Gi PV.
**Why:** Loki logs have some operational value (recent events) and a single
chart-major bump usually upgrades cleanly. Only if the StatefulSet selector is
immutable do we recreate it (acceptable — logs are also ephemeral).
**Alternative considered:** reinstall Loki too — rejected unless in-place fails.

### Decision 3: Flux-suspend during the manual kps teardown
**Choice:** `flux suspend hr kube-prometheus-stack` before `helm uninstall`, resume
only after git is at 87 and pushed.
**Why:** otherwise Flux sees the release missing and reinstalls at the still-pinned
`69.x`, racing our teardown. Suspending isolates the manual phase.

### Decision 4: Validate values with `helm template` before applying
**Choice:** Render `kube-prometheus-stack --version 87.0.1` against the migrated
values locally and fix removed/renamed keys before committing.
**Why:** 18 majors remove/rename value keys; surfacing them as template
warnings/errors pre-apply avoids a failed Flux reconcile loop.

### Decision 5: Grafana admin via SealedSecret
**Choice:** New `SealedSecret` `grafana-admin-secret` (`admin-password` key) in
`monitoring`; values set `grafana.admin.existingSecret` +
`existingSecretPasswordKey: admin-password`; remove plaintext `user/password`.
**Why:** removes a plaintext credential from git at zero extra operational cost
(the reinstall resets creds anyway).

## Risks / Trade-offs

- **[Data loss]** Prometheus/Alertmanager/Grafana history deleted → **accepted**
  (Decision 1).
- **[Stuck CRD deletion]** operator finalizers may hang after the operator pod is
  gone → Mitigation: `kubectl patch crd <name> -p '{"metadata":{"finalizers":[]}}'`
  or `--grace-period=0 --force` for stuck CRs.
- **[Value-key drift 69→87]** removed/renamed keys cause Flux reconcile failure →
  Mitigation: Decision 4 (`helm template` validation) before apply.
- **[Loki immutable selector]** → Mitigation: delete STS (`--cascade=orphan`
  keeps PV) and let Flux recreate.
- **[Flux race]** → Mitigation: Decision 3 (suspend).
- **[Grafana can't decode sealed secret]** wrong namespace/key → Mitigation:
  verify the decrypted `Secret` exists before resuming; Grafana fails closed
  (restarts) until correct.

## Migration Plan

1. Pre-flight: snapshot/record current values (already in git); confirm 3 kps
   PVCs are expendable; generate + seal the Grafana admin password.
2. Validate migrated kps values against 87.0.1 with `helm template`.
3. `flux suspend hr kube-prometheus-stack`.
4. `helm uninstall kube-prometheus-stack -n monitoring`.
5. Delete 10 `monitoring.coreos.com` CRDs (force/finalizer-strip stuck ones).
6. Delete 3 leftover kps PVCs.
7. Commit git changes (kps→87 values + grafana SealedSecret ref + Loki→7.0);
   push.
8. `flux resume hr kube-prometheus-stack`; force reconcile → fresh 87 install.
9. `flux reconcile` Loki HelmRelease → in-place 7.0.
10. Verify (pods, targets, Grafana login, dashboards, Loki datasource,
    non-monitoring apps unaffected).

**Rollback:** revert the git commit, `flux suspend`, `helm uninstall` 87, delete
CRDs/PVCs again, reinstall 69.x, `flux resume`. Note PVCs are gone either way, so
history cannot be recovered — consistent with Decision 1.

## Open Questions

- Exact value-key differences between kps 69 and 87 (e.g., Grafana
  `additionalDataSources` vs `datasources`, `grafana.ini` sub-keys) — resolved
  empirically via Decision 4 (`helm template`) during apply.
