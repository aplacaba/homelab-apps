# Design: Vaultwarden Deployment

**Date:** 2026-06-21  
**Status:** Approved

## Problem

No self-hosted password manager exists in the cluster. Team needs a Bitwarden-compatible
server for shared credentials, accessible both publicly (`vault.watchtoken.org`) and
internally (`vault.local`).

## Solution

Deploy Vaultwarden using the community Helm chart (`guerzon/vaultwarden`) with SQLite
storage, a SealedSecret for the admin token, and a manual Traefik IngressRoute.

### What changes

| File | Action |
|---|---|
| `clusters/pk3s/vaultwarden/namespace.yaml` | New |
| `clusters/pk3s/vaultwarden/helmrepository.yaml` | New — community Helm repo |
| `clusters/pk3s/vaultwarden/helmrelease.yaml` | New — release with values |
| `clusters/pk3s/vaultwarden/ingressroute.yaml` | New — Traefik CRD for public + internal |
| `clusters/pk3s/vaultwarden/sealedsecret.yaml` | New — ADMIN_TOKEN encrypted |
| `clusters/pk3s/vaultwarden/kustomization.yaml` | New — lists all resources above |
| `clusters/pk3s/kustomization.yaml` | Edit — add `vaultwarden` to resources |

### What does NOT change

- Root kustomization structure — same pattern as existing apps
- Cloudflare Tunnel — Traefik already receives public traffic; adding a DNS record
  for `vault.watchtoken.org` is manual (external to this design)
- Any existing HelmRepository — new repo is self-contained in vaultwarden dir
- Traefik config — `allowCrossNamespace: true` is already enabled

## Configuration

### `namespace.yaml`

Standard namespace `vaultwarden`.

### `helmrepository.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: vaultwarden
  namespace: flux-system
spec:
  interval: 1h
  url: https://guerzon.github.io/vaultwarden
```

### `helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: vaultwarden
  namespace: vaultwarden
spec:
  interval: 1h
  chart:
    spec:
      chart: vaultwarden
      version: "*"
      sourceRef:
        kind: HelmRepository
        name: vaultwarden
        namespace: flux-system
  values:
    # Manual IngressRoute via Traefik CRD
    ingress:
      enabled: false

    # Use fullnameOverride so service name is just "vaultwarden"
    fullnameOverride: "vaultwarden"

    # Domain config
    domain: https://vault.watchtoken.org

    # Signups disabled by default — enable via admin panel
    signupsAllowed: false

    # Admin token from SealedSecret
    adminToken:
      existingSecret: vaultwarden-admin-token
      existingSecretKey: ADMIN_TOKEN

    # SQLite persistence
    storage:
      data:
        name: vaultwarden-data
        size: 1Gi
        class: local-path
        keepPvc: true
        accessMode: ReadWriteOnce

    # Resource limits for homelab
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

### `sealedsecret.yaml`

Created via `kubeseal` (not committed in plaintext):

```bash
printf 'ADMIN_TOKEN value: '; IFS= read -rs VAL; echo
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: vaultwarden-admin-token\n  namespace: vaultwarden\ntype: Opaque\nstringData:\n  ADMIN_TOKEN: %s\n' "$VAL" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace vaultwarden \
  > clusters/pk3s/vaultwarden/sealedsecret.yaml
unset VAL
```

### `ingressroute.yaml`

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: vaultwarden
  namespace: vaultwarden
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`vault.watchtoken.org`)
      services:
        - name: vaultwarden
          port: 8080
    - kind: Rule
      match: Host(`vault.local`)
      services:
        - name: vaultwarden
          port: 8080
```

### `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - helmrepository.yaml
  - sealedsecret.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

### Root `kustomization.yaml` change

Add `vaultwarden` after `traefik` (alphabetical order):

```yaml
resources:
  - cloudflared
  - cv-datastar
  - floci
  - flux-dashboard
  - forgejo
  - forgejo-runner
  - monitoring
  - sealed-secrets
  - traefik
  - vaultwarden
```

## Verification

After Flux reconciles (or `kubectl -n flux-system reconcile kustomization pk3s`):

1. Confirm pod is running:
   ```bash
   kubectl get pods -n vaultwarden
   ```

2. Check logs for startup:
   ```bash
   kubectl logs -n vaultwarden deploy/vaultwarden --tail=20
   ```
   Look for "Starting server on 0.0.0.0:8080".

3. Access admin panel:
   ```bash
   curl -s http://vault.local/admin | head -5
   # or via public: https://vault.watchtoken.org/admin
   ```
   Should return the admin login page (prompts for ADMIN_TOKEN).

4. Confirm IngressRoute:
   ```bash
   kubectl get ingressroute -n vaultwarden
   ```
