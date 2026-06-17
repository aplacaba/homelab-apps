# Promtail Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Promtail as a DaemonSet to ship all cluster container logs (including cv-datastar) to the existing Loki instance.

**Architecture:** Add a standalone Promtail HelmRelease in `monitoring/` namespace using the existing `grafana` HelmRepository. The DaemonSet tails pod logs from every node and pushes them to `loki.monitoring:3100`. No changes to Loki, cv-datastar, or root kustomization.

**Tech Stack:** Flux HelmRelease, Promtail Helm chart (grafana repo), Loki (already deployed)

---

### Task 1: Create Promtail HelmRelease

**Files:**
- Create: `clusters/pk3s/monitoring/helmrelease-promtail.yaml`

- [ ] **Step 1: Write the HelmRelease manifest**

Create `clusters/pk3s/monitoring/helmrelease-promtail.yaml`:

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

### Task 2: Register Promtail in monitoring kustomization

**Files:**
- Modify: `clusters/pk3s/monitoring/kustomization.yaml`

- [ ] **Step 1: Add promtail HelmRelease to resources list**

Edit `clusters/pk3s/monitoring/kustomization.yaml` — add `- helmrelease-promtail.yaml` after `- helmrelease-loki.yaml`:

Original:
```yaml
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrepository-loki.yaml
  - helmrelease.yaml
  - helmrelease-loki.yaml
  - ingressroute.yaml
```

Replace with:
```yaml
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrepository-loki.yaml
  - helmrelease.yaml
  - helmrelease-loki.yaml
  - helmrelease-promtail.yaml
  - ingressroute.yaml
```

### Task 3: Commit

**Files:** All changed files from Tasks 1-2

- [ ] **Step 1: Verify git status shows only intended changes**

```bash
git status
```
Expected: `helmrelease-promtail.yaml` (new) and `kustomization.yaml` (modified).

- [ ] **Step 2: Commit**

```bash
git add clusters/pk3s/monitoring/helmrelease-promtail.yaml clusters/pk3s/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add Promtail DaemonSet for cluster-wide logging"
```

### Post-Deploy Verification (Manual)

After Flux reconciles (wait ~1-2 min or force with `kubectl -n flux-system reconcile kustomization pk3s`):

```bash
# 1. DaemonSet is running
kubectl get daemonset -n monitoring promtail

# 2. Promtail connected to Loki (look for "Ready")
kubectl logs -n monitoring daemonset/promtail --tail=20

# 3. Query cv-datastar logs in Grafana (http://grafana.local:30080 → Explore)
# LogQL: {namespace="cv-datastar"}
```
