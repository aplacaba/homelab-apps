# cv-datastar — kubectl commands reference

## Monitoring

```bash
# Chart version installed by Flux
kubectl get helmrelease -n cv-datastar cv-datastar \
  -o jsonpath='{.status.lastAppliedRevision}'

# HelmRelease health + last upgrade message
kubectl get helmrelease -n cv-datastar cv-datastar \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'

# Pods with node and age
kubectl get pods -n cv-datastar -o wide

# Image tag in deployment spec
kubectl get deployment -n cv-datastar cv-datastar \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Actual image digest running in the pod
kubectl get pod -n cv-datastar <pod-name> \
  -o jsonpath='{.status.containerStatuses[0].imageID}'

# Rollout status
kubectl rollout status deploy/cv-datastar -n cv-datastar

# Full Helm release history
helm history cv-datastar -n cv-datastar
```

## Applying an update

```bash
# 1. Force HelmChart to rescan OCI registry
kubectl annotate --overwrite helmcharts.source.toolkit.fluxcd.io \
  -n flux-system cv-datastar-cv-datastar \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 2. Force HelmRelease to upgrade (after chart is found)
kubectl annotate --overwrite helmrelease \
  -n cv-datastar cv-datastar \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 3. Restart pods to pick up new `:latest` image (tag string unchanged)
kubectl rollout restart deploy/cv-datastar -n cv-datastar
```
