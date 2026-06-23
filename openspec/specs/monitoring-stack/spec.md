# monitoring-stack

## Purpose

Prometheus + Loki + Grafana monitoring stack on the homelab k3s cluster,
provisioned via Flux HelmReleases from the prometheus-community and grafana Helm
repositories. Provides metrics collection, log aggregation, and dashboards for
cluster observability.

## Requirements

### Requirement: Monitoring stack on current chart versions
kube-prometheus-stack and Loki MUST run on current chart versions (kps `87.x`,
Loki `7.x`) so the stack receives upstream fixes and stays maintainable.

#### Scenario: After the refresh
- **WHEN** the refresh is complete
- **THEN** `helm list` shows kps `87.x` and Loki `7.x` deployed, and all
  monitoring pods are `Running`.

### Requirement: Clean reinstall without stale state
The kps upgrade MUST be performed as a clean reinstall (uninstall + CRD + PVC
  removal) to avoid the immutable-label-selector failures inherent to in-place
  kps major upgrades.

#### Scenario: Reinstall sequence
- **WHEN** kps is reinstalled
- **THEN** the 10 `monitoring.coreos.com` CRDs and the 3 kps PVCs are deleted
  first, and the 87.x install reconciles cleanly with no `field is immutable`
  errors.

### Requirement: Grafana admin credentials sealed
Grafana admin credentials MUST NOT be stored in plaintext in git; they MUST come
  from a `SealedSecret`.

#### Scenario: Grafana auth source
- **WHEN** the refreshed Grafana starts
- **THEN** its admin password is read from the `grafana-admin-secret` Secret
  (decrypted by SealedSecrets), and no plaintext admin password exists in the
  repo.

### Requirement: Non-monitoring apps unaffected
The refresh MUST NOT affect any non-monitoring component (cert-manager, traefik,
  cloudflared, forgejo, cv-datastar, vaultwarden).

#### Scenario: During and after the reinstall
- **WHEN** kps is uninstalled/reinstalled
- **THEN** public HTTPS (cv/fgit/vault) and `.local` access continue to return
  200, and cert-manager/traefik/cloudflared pods remain unchanged.

### Requirement: Loki logs preserved where possible
Loki MUST be upgraded in place (preserving its 10Gi PV / log history); a
  StatefulSet recreate is acceptable only if an immutable selector blocks the
  in-place upgrade.

#### Scenario: Loki upgrade
- **WHEN** Loki is bumped 6.55 → 7.0
- **THEN** the upgrade is attempted in place first, preserving the existing PV.
