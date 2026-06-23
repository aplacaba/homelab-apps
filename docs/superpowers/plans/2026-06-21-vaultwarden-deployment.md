# Vaultwarden Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Vaultwarden (self-hosted Bitwarden-compatible password manager) to the k3s cluster.

**Architecture:** Community Helm chart (`guerzon/vaultwarden`) with SQLite storage, Traefik IngressRoute for public + internal access, SealedSecret for admin token.

**Tech Stack:** Vaultwarden, Kubernetes, Helm, Flux, Traefik, SealedSecrets

**References:**
- Design spec: `docs/superpowers/specs/2026-06-21-vaultwarden-design.md`
- Existing patterns: `clusters/pk3s/forgejo/` (Helm + IngressRoute), `clusters/pk3s/cloudflared/` (SealedSecret)

---

### Task 1: Create directory and namespace

**Files:**
- Create: `clusters/pk3s/vaultwarden/namespace.yaml`

- [ ] **Step 1: Create directory**

```bash
mkdir -p clusters/pk3s/vaultwarden
```

- [ ] **Step 2: Write namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vaultwarden
```

### Task 2: Create HelmRepository

**Files:**
- Create: `clusters/pk3s/vaultwarden/helmrepository.yaml`

- [ ] **Step 1: Write helmrepository.yaml**

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

### Task 3: Create SealedSecret for admin token

**Files:**
- Create: `clusters/pk3s/vaultwarden/sealedsecret.yaml`

- [ ] **Step 1: Generate the SealedSecret interactively**

This step requires the cluster's sealed-secrets controller to be running. Run:

```bash
cd /home/tovarisch/Projects/homelab-apps
printf 'Vaultwarden admin token: '; IFS= read -rs ADMIN_TOKEN; echo
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: vaultwarden-admin-token\n  namespace: vaultwarden\ntype: Opaque\nstringData:\n  ADMIN_TOKEN: %s\n' "$ADMIN_TOKEN" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace vaultwarden \
  > clusters/pk3s/vaultwarden/sealedsecret.yaml
unset ADMIN_TOKEN
```

Verify the file exists and contains a valid SealedSecret:

```bash
head -5 clusters/pk3s/vaultwarden/sealedsecret.yaml
# Should show: apiVersion: bitnami.com/v1alpha1
```

### Task 4: Create HelmRelease

**Files:**
- Create: `clusters/pk3s/vaultwarden/helmrelease.yaml`

- [ ] **Step 1: Write helmrelease.yaml**

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
    ingress:
      enabled: false
    fullnameOverride: "vaultwarden"
    domain: https://vault.watchtoken.org
    signupsAllowed: false
    adminToken:
      existingSecret: vaultwarden-admin-token
      existingSecretKey: ADMIN_TOKEN
    storage:
      data:
        name: vaultwarden-data
        size: 1Gi
        class: local-path
        keepPvc: true
        accessMode: ReadWriteOnce
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

### Task 5: Create IngressRoute

**Files:**
- Create: `clusters/pk3s/vaultwarden/ingressroute.yaml`

- [ ] **Step 1: Write ingressroute.yaml**

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

### Task 6: Create vaultwarden kustomization

**Files:**
- Create: `clusters/pk3s/vaultwarden/kustomization.yaml`

- [ ] **Step 1: Write kustomization.yaml**

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

### Task 7: Update root kustomization

**Files:**
- Modify: `clusters/pk3s/kustomization.yaml`

- [ ] **Step 1: Add vaultwarden to resources**

Add after `traefik` entry (alphabetical order):

```yaml
  - traefik
  - vaultwarden
```

### Task 8: Verify before committing

- [ ] **Step 1: Check working tree**

```bash
git status
git diff
```

Expected: all new files in `clusters/pk3s/vaultwarden/` staged or unstaged, plus the edit to `clusters/pk3s/kustomization.yaml`.

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('clusters/pk3s/vaultwarden/kustomization.yaml')); yaml.safe_load(open('clusters/pk3s/kustomization.yaml')); print('YAML OK')"
```

### Task 9: Commit and trigger reconciliation

- [ ] **Step 1: Commit**

```bash
git add clusters/pk3s/vaultwarden/ clusters/pk3s/kustomization.yaml
git commit -m "feat: add vaultwarden deployment"
```

- [ ] **Step 2: Push and reconcile Flux**

```bash
git push
kubectl -n flux-system reconcile kustomization pk3s
```

### Task 10: Verify deployment

- [ ] **Step 1: Check pod status**

```bash
kubectl get pods -n vaultwarden -w
```

Wait for `Running` state.

- [ ] **Step 2: Check logs**

```bash
kubectl logs -n vaultwarden deploy/vaultwarden --tail=20
```

Look for: `Starting server on 0.0.0.0:8080`

- [ ] **Step 3: Check IngressRoute**

```bash
kubectl get ingressroute -n vaultwarden
```

Expected: one IngressRoute with two host rules.
