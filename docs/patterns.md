# Homelab GitOps Patterns

This document captures the conventions and patterns for deploying applications on the `pk3s` cluster via Flux Operator.

## Cluster Architecture

```
pk3s (k3s v1.34)
├── flux-system          # Flux Operator + controllers
├── traefik              # Traefik v3 ingress (NodePort 30080/30443)
├── paperless            # Paperless-ngx (example app)
└── <your-app>           # Future apps follow same pattern
```

## Directory Structure

```
clusters/pk3s/
├── kustomization.yaml       # Root: references all app directories
└── <app-name>/
    ├── kustomization.yaml   # Lists all resources for this app
    ├── namespace.yaml       # Namespace (if app gets its own)
    ├── helmrepository.yaml  # Helm repo (or reuse existing one)
    └── helmrelease.yaml     # Flux HelmRelease definition
```

## Pattern 1: Deploy an App via HelmRelease

### Step 1: Create the directory

```bash
mkdir -p clusters/pk3s/<app-name>
```

### Step 2: Namespace (one per app)

**`clusters/pk3s/<app-name>/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
```

### Step 3: HelmRepository (if new chart source)

**`clusters/pk3s/<app-name>/helmrepository.yaml`**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <repo-name>
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.example.com
```

> **Note:** If the HelmRepository already exists (e.g., `pascaliske`), skip this step and reference the existing one in the HelmRelease.

### Step 4: HelmRelease

**`clusters/pk3s/<app-name>/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  interval: 1h
  chart:
    spec:
      chart: <chart-name>
      version: "X.Y.x"          # Semver range for auto-updates
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  values:
    # Chart-specific values
    # ...
```

### Step 5: Wire into kustomization

**`clusters/pk3s/<app-name>/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - helmrelease.yaml
  # - helmrepository.yaml   # only if adding a new repo
```

Add the directory to the root kustomization:

**`clusters/pk3s/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - flux-dashboard.yaml
  - paperless
  - <app-name>   # <-- add here
```

### Step 6: Deploy

```bash
# Apply namespace first (if needed)
kubectl apply -f clusters/pk3s/<app-name>/namespace.yaml

# Apply HelmRepository (if needed)
kubectl apply -f clusters/pk3s/<app-name>/helmrepository.yaml

# Apply HelmRelease
kubectl apply -f clusters/pk3s/<app-name>/helmrelease.yaml

# Commit and push
git add -A && git commit -m "Add <app-name>" && git push
```

## Pattern 2: Expose via IngressRoute (Host-based)

**Use host-based routing** (`Host(...)`), never path-prefix. Path prefix breaks single-page apps and absolute URL generation.

### Option A: Chart has built-in IngressRoute support

Add to the HelmRelease `values:`
```yaml
values:
  ingressRoute:
    create: true
    entryPoints:
      - web
    rule: Host(`<app>.local`)
```

### Option B: Manual IngressRoute resource

Create **`clusters/pk3s/<app-name>/ingressroute.yaml`**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`<app>.local`)
      services:
        - name: <service-name>
          port: <port>
```

Add to the app's `kustomization.yaml` resources.

## Pattern 3: Trigger HelmRelease Reconciliation

When you update a HelmRelease but Flux doesn't pick it up immediately:

```bash
# Suspend then resume to force reconcile
kubectl -n <namespace> patch helmrelease <name> --type merge -p '{"spec":{"suspend":true}}'
sleep 2
kubectl -n <namespace> patch helmrelease <name> --type merge -p '{"spec":{"suspend":false}}'
```

## Accessing Apps

All apps route through **Traefik** on `http://<node-ip>:30080`.

Add to `/etc/hosts`:
```
192.168.254.50 fluxops.local paperless.local <your-app>.local
```

| App | URL |
|-----|-----|
| Flux Operator | `http://fluxops.local:30080/` |
| Paperless | `http://paperless.local:30080/` |

## Existing HelmRepositories

| Name | URL | Used by |
|------|-----|---------|
| `pascaliske` (flux-system) | `https://charts.pascaliske.dev` | paperless |

## Notes

- **SQLite** is preferred over PostgreSQL for homelab apps (simpler, fewer dependencies).
- **Redis** can be enabled as a chart subchart when needed (see paperless example).
- **Storage:** use `local-path` storage class (k3s built-in); no need to specify when chart auto-creates PVCs.
- **Never use `PathPrefix`** for web UIs — always host-based routing.
- **kubectl apply** directly works for initial deployment; Flux will reconcile and maintain state afterward.
