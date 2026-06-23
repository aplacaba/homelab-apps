# Implementation Tasks

## 1. Pre-flight & artifacts

- [ ] 1.1 Generate a strong Grafana admin password (out-of-band)
- [ ] 1.2 Seal it as `grafana-admin-secret` (`admin-password` key) in `monitoring` ns via `kubeseal` → `monitoring/sealedsecret-grafana-admin.yaml`
- [ ] 1.3 Add `sealedsecret-grafana-admin.yaml` to `monitoring/kustomization.yaml`
- [ ] 1.4 Confirm the 3 kps PVCs (prometheus/alertmanager/grafana) are expendable (record current state)

## 2. Migrate kps values to 87.x

- [ ] 2.1 Copy current `monitoring/helmrelease.yaml` values to a scratch file
- [ ] 2.2 Render with `helm template prometheus-community/kube-prometheus-stack --version 87.0.1 -f <values>`; capture warnings/errors
- [ ] 2.3 Fix removed/renamed value keys; switch Grafana admin to `existingSecret: grafana-admin-secret` + `existingSecretPasswordKey: admin-password`; remove plaintext `admin/admin`
- [ ] 2.4 Re-render until clean; bump `version: "87.0.1"` in `helmrelease.yaml`

## 3. kps clean reinstall (destructive, Flux-safe)

- [ ] 3.1 `flux suspend hr kube-prometheus-stack -n monitoring`
- [ ] 3.2 `helm uninstall kube-prometheus-stack -n monitoring`
- [ ] 3.3 Delete the 10 `*.monitoring.coreos.com` CRDs (`kubectl delete crd ...`); strip finalizers / `--force` any stuck CRs
- [ ] 3.4 Delete the 3 leftover kps PVCs (prometheus / alertmanager / grafana)
- [ ] 3.5 Confirm namespace clean: no monitoring.coreos.com CRs, no kps PVCs/workloads (Loki/Promtail untouched)

## 4. Commit & fresh install

- [ ] 4.1 Commit (kps→87 values + Grafana SealedSecret ref + Loki→7.0 bump), push
- [ ] 4.2 `flux resume hr kube-prometheus-stack -n monitoring`; force reconcile
- [ ] 4.3 Wait for fresh 87 install: all kps pods `Running`, no `field is immutable` errors

## 5. Loki 6.55 → 7.0 in-place

- [ ] 5.1 Flux reconciles Loki HelmRelease → 7.0
- [ ] 5.2 If `loki` StatefulSet hits immutable selector: `kubectl delete sts loki -n monitoring --cascade=orphan`, let Flux recreate (PV retained)
- [ ] 5.3 Confirm Loki pod `Running`, 10Gi PV retained

## 6. Verification

- [ ] 6.1 `helm list -n monitoring` shows kps `87.x`, Loki `7.x`, Promtail `6.17.1`
- [ ] 6.2 All monitoring pods `Running`
- [ ] 6.3 Grafana loads on `http://grafana.local` (LAN), login works with the sealed admin password, default dashboards present, Loki datasource healthy
- [ ] 6.4 Prometheus targets Up (node-exporter, kube-state-metrics, kubelet, coreDNS, traefik)
- [ ] 6.5 Non-monitoring apps unaffected: `https://cv.watchtoken.org`/`fgit`/`vault` → 200; `.local` → 200; cert-manager/traefik/cloudflared pods unchanged
- [ ] 6.6 `openspec validate refresh-monitoring-stack` passes
- [ ] 6.7 Update `AGENTS.md` if monitoring conventions changed (e.g., Grafana admin SealedSecret)
