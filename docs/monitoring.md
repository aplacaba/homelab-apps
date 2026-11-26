# Monitoring: metrics, logs, alerts

Everything is in `clusters/pk3s/monitoring/` (plus `flux-monitoring/`). Grafana is at
`http://grafana.local:30080` (LAN). Versions are in [inventory.md](inventory.md).

| Piece | Detail |
|---|---|
| kube-prometheus-stack | Prometheus (7d retention), Alertmanager, Grafana, node-exporter |
| Loki | single-tenant (`loki.auth_enabled: false`) |
| Alloy | log-collector DaemonSet (`helmrelease-alloy.yaml`), runs on both nodes |
| Alerts | Alertmanager → Telegram; Flux failure rules in `prometheusrule-flux.yaml` |
| Dashboards | managed with Terraform from `terraform/grafana/` ([terraform.md](terraform.md#grafana-dashboards)) |

## Notes

- **Grafana admin credentials are a SealedSecret** (`sealedsecret-grafana-admin.yaml`, keys
  `admin-user` and `admin-password`), used through `grafana.admin.existingSecret:
  grafana-admin-secret`. To rotate, re-seal that secret. Don't put a password in the HelmRelease.
- **Loki needs `auth_enabled: false`.** The chart defaults to `true`, which requires an
  `X-Scope-OrgID` tenant header, and Alloy pushes without one get a 401.
- **Logs are collected by Alloy, not Promtail** (Promtail is EOL and was removed 2026-11-26).
  Alloy copies the old promtail `kubernetes-pods` job rule for rule, so Loki streams keep the same
  labels: `namespace, pod, container, app, instance, component, job=namespace/app, node_name,
  filename, stream`, plus the Loki-derived `service_name`. Keep queries and dashboards on those
  names, and change labels in the HelmRelease's `configMap.content` relabel rules, not ad hoc.
  Positions are stored on the hostPath `/var/lib/alloy` (the chart default `/tmp/alloy` is lost on
  restart). `tail_from_end = true` only affects files with no saved position. The old
  `/run/promtail` hostPath on each node is a leftover and safe to delete.
- **node-exporter and alloy run on `k3s-media`** (they tolerate everything with `operator: Exists`),
  so metrics and logs from the media node are collected.
- **The kube-prometheus-stack CRDs follow the chart** through `install/upgrade.crds: CreateReplace`.
  Don't use the `kubectl apply --server-side` CRD commands from upstream's UPGRADE.md. 87.0.1 →
  93.11.0 (2026-11-26) needed no stops at intermediate majors:
  - CRD versions didn't change, only their schemas.
  - 89.x moved Grafana to chart 13/14 (distroless, values schema).
  - 90.x creates a `prometheus-prometheus-token` Secret for control-plane ServiceMonitor auth.
  - 92.x adds `nodeSelector: kubernetes.io/os: linux`, which restarts the pods once.
  - Grafana DB copy taken before the upgrade: `~/backups/grafana/pre-kps-93.11.0/grafana-data-pre-13.3.tgz`.
    Rollback means reverting the version and, if Grafana refuses the newer schema, restoring that
    DB.

## Metric sources for the custom dashboards

- **Forgejo:** `gitea.config.metrics.ENABLED: "true"` plus a `ServiceMonitor` on the http port at
  `/metrics`.
- **cloudflared:** a `cloudflared-metrics` Service (port 2000) plus a `ServiceMonitor`. cloudflared
  runs with `--metrics 0.0.0.0:2000`.
- **Flux controllers** (`flux-monitoring/`): one `PodMonitor` per controller on port `http-prom`
  (8080) at `/metrics`. They are PodMonitors because the flux-system Services are owned by the
  operator (`ssa: Ignore`) and only expose 80→9090. Prometheus finds them through
  `podMonitorSelectorNilUsesHelmValues: false`. They feed the **Flux GitOps** dashboard.

## Telegram alerts

```
Flux controllers  →  PrometheusRule (flux-alerts)  →  Alertmanager  →  Telegram
    (metrics)          (eval every 30s, 5m for)       (config from SealedSecret)
```

| Rule | Metric | For |
|---|---|---|
| `KustomizationFailed` | `gotk_reconcile_condition{status="False", kind="Kustomization"}` | 5m |
| `HelmReleaseFailed` | `gotk_reconcile_condition{status="False", kind="HelmRelease"}` | 5m |
| `SourceFailed` | `gotk_reconcile_condition{status="False", kind=~"GitRepository\|HelmRepository\|OCIRepository\|Bucket"}` | 5m |

**What goes to Telegram:** outage and availability alerts. That means pod, deployment,
statefulset and daemonset health (`KubePodNotReady`, `KubePodCrashLooping`,
`KubeDeploymentReplicasMismatch`, …), nodes down or unreachable, kubelet, API or target down,
certificate expiry, persistent-volume errors and Flux reconcile failures.

**What goes to the `null` receiver (no message):** resource and capacity alerts. That means CPU
throttling, CPU and memory overcommit and quota, HPA maxed out, node CPU, memory and disk
saturation, file-descriptor and conntrack limits, filesystem and PV space or inodes filling, node
pressure and eviction, plus `Watchdog` and `InfoInhibitor`. `KubeProxyDown` is masked too, because
k3s doesn't expose kube-proxy metrics, so it would always fire.

**Routing:** alerts are grouped by `alertname` and `namespace`. The first message goes out after
10s (`group_wait`), later alerts in the same group wait 5m, and unresolved alerts repeat every 4h.
The null matcher is the `^(...)` regex in `route.routes` of the sealed `alertmanager-config`.

**Config reloads by itself.** The Prometheus Operator watches the `alertmanager-config` Secret,
and the config-reloader picks up a change in about a minute (in
`/etc/alertmanager/config_out/`). No pod restart is needed.

### Rotating the Telegram credentials or changing routes

Re-seal the whole Alertmanager config:

```bash
cd ~/Projects/homelab-apps
printf 'bot_token: '; IFS= read -rs BOT; echo
printf 'chat_id: '; IFS= read -rs CID; echo
cat <<SEOF | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml --namespace monitoring > clusters/pk3s/monitoring/sealedsecret-alertmanager-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'telegram'
      routes:
        - receiver: 'null'
          matchers:
            - 'alertname=~"^(CPUThrottlingHigh|Kube(CPU|Memory)(Overcommit|QuotaOvercommit)|KubeQuota.*|KubeletTooManyPods|KubeHpa.*|KubeNode(Pressure|Eviction)|KubePersistentVolume(FillingUp|InodesFillingUp)|Node(CPUHighUsage|MemoryHighUtilization|DiskIOSaturation|SystemSaturation|HighNumberConntrackEntriesUsed|FileDescriptorLimit|Filesystem.*)|KubeProxyDown|Watchdog|InfoInhibitor)"'
    receivers:
      - name: 'telegram'
        telegram_configs:
          - bot_token: '$BOT'
            chat_id: $CID
            parse_mode: 'HTML'
      - name: 'null'
SEOF
unset BOT CID
```

Then commit and push. To add another receiver (email, Slack, …), add it under `receivers:`, add a
route with specific matchers (the default route sends everything to `telegram`), and re-seal.

| File | Purpose |
|---|---|
| `monitoring/prometheusrule-flux.yaml` | the 3 Flux alert rules |
| `monitoring/sealedsecret-alertmanager-config.yaml` | Alertmanager config, including the sealed Telegram credentials |
| `monitoring/helmrelease.yaml` | references `configSecret: alertmanager-config` |

### Verification

```bash
kubectl get prometheusrule -n monitoring flux-alerts -o yaml
kubectl get secret -n monitoring alertmanager-config -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -15
kubectl exec -n monitoring alertmanager-prometheus-alertmanager-0 -c config-reloader \
  -- cat /etc/alertmanager/config_out/alertmanager.env.yaml
# rules loaded? (port-forward prometheus-prometheus-prometheus-0:9090)
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[] | select(.name=="flux")'
```
