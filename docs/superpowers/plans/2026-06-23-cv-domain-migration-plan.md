# CV Domain Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate cv-datastar from `cv.watchtoken.org` to `cv.alacaba.org` with 301 redirect from old domain.

**Architecture:** Add new IngressRoutes + cert-manager Certificate for the new domain. Modify existing HTTPS IngressRoute to redirect via Traefik redirectRegex middleware. All changes live in `clusters/pk3s/cv-datastar/`. Cloudflare DNS + public hostname configured out-of-band.

**Tech Stack:** Flux (kustomize), Traefik CRD (IngressRoute, Middleware), cert-manager (Certificate, ClusterIssuer)

---

### Task 1: Create ingressroute-alacaba.yaml

**Files:**
- Create: `clusters/pk3s/cv-datastar/ingressroute-alacaba.yaml`

- [ ] **Write the new file**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: cv-datastar-alacaba
  namespace: cv-datastar
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`cv.alacaba.org`)
      middlewares:
        - name: redirect-to-https
          namespace: traefik
      services:
        - name: cv-datastar
          port: 8080
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: cv-datastar-alacaba-https
  namespace: cv-datastar
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`cv.alacaba.org`)
      services:
        - name: cv-datastar
          port: 8080
  tls: {}
```

- [ ] **Commit**

```bash
git add clusters/pk3s/cv-datastar/ingressroute-alacaba.yaml
git commit -m "feat: add IngressRoutes for cv.alacaba.org"
```

---

### Task 2: Create certificate-alacaba.yaml

**Files:**
- Create: `clusters/pk3s/cv-datastar/certificate-alacaba.yaml`

- [ ] **Write the new file**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cv-alacaba-org
  namespace: traefik
spec:
  secretName: cv-alacaba-org-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "cv.alacaba.org"
```

- [ ] **Commit**

```bash
git add clusters/pk3s/cv-datastar/certificate-alacaba.yaml
git commit -m "feat: add cert-manager Certificate for cv.alacaba.org"
```

---

### Task 3: Create redirect middleware

**Files:**
- Create: `clusters/pk3s/cv-datastar/middlewares/`
- Create: `clusters/pk3s/cv-datastar/middlewares/kustomization.yaml`
- Create: `clusters/pk3s/cv-datastar/middlewares/redirect-to-alacaba.yaml`

- [ ] **Create directory + kustomization**

```yaml
# clusters/pk3s/cv-datastar/middlewares/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - redirect-to-alacaba.yaml
```

- [ ] **Create redirect middleware**

```yaml
# clusters/pk3s/cv-datastar/middlewares/redirect-to-alacaba.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-alacaba
  namespace: cv-datastar
spec:
  redirectRegex:
    regex: ^https://cv\.watchtoken\.org(.*)$
    replacement: https://cv.alacaba.org$1
    permanent: true
```

- [ ] **Commit**

```bash
git add clusters/pk3s/cv-datastar/middlewares/
git commit -m "feat: add 301 redirect middleware cv.watchtoken.org -> cv.alacaba.org"
```

---

### Task 4: Modify ingressroute-https.yaml for redirect

**Files:**
- Modify: `clusters/pk3s/cv-datastar/ingressroute-https.yaml`

- [ ] **Replace content with redirect version**

The old HTTPS IngressRoute should stop serving the app and instead redirect
to the new domain via the `redirect-to-alacaba` middleware:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: cv-datastar-https
  namespace: cv-datastar
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`cv.watchtoken.org`)
      middlewares:
        - name: redirect-to-alacaba
          namespace: cv-datastar
      services:
        - name: cv-datastar
          port: 8080
  tls: {}
```

The `tls: {}` is retained so Traefik terminates TLS on `websecure` and applies
the wildcard cert. The service is retained (required by Traefik schema even
when middleware redirects).

- [ ] **Commit**

```bash
git add clusters/pk3s/cv-datastar/ingressroute-https.yaml
git commit -m "refactor: change cv.watchtoken.org HTTPS route to redirect"
```

---

### Task 5: Update kustomization.yaml

**Files:**
- Modify: `clusters/pk3s/cv-datastar/kustomization.yaml`

- [ ] **Add new resources to the list**

```yaml
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - serviceaccount.yaml
  - ingressroute.yaml
  - ingressroute-https.yaml
  - ingressroute-alacaba.yaml       # new
  - certificate-alacaba.yaml        # new
  - middlewares                     # new
```

- [ ] **Commit**

```bash
git add clusters/pk3s/cv-datastar/kustomization.yaml
git commit -m "chore: add new resources to cv-datastar kustomization"
```

---

### Task 6: Flux dry-run / verification

- [ ] **Run a client-side dry-run to validate manifests**

```bash
kubectl kustomize clusters/pk3s/cv-datastar/ > /dev/null
```

Expected: exits 0 with no output (or valid YAML on stdout, no errors).

- [ ] **Force Flux reconciliation**

```bash
kubectl -n flux-system reconcile kustomization pk3s
```

Wait 30s, then verify:

```bash
kubectl get ingressroute -n cv-datastar
kubectl get certificate -n traefik cv-alacaba-org
kubectl get secret -n traefik cv-alacaba-org-tls  # once cert-manager issues it
```

---

### Task 7: Out-of-band — Cloudflare Zero Trust

- [ ] **Add `cv.alacaba.org` DNS record** in Cloudflare dashboard (CNAME or A record pointing to tunnel)
- [ ] **Add public hostname** `cv.alacaba.org` → `https://traefik.traefik.svc:443` with No TLS Verify ON
- [ ] **Verify** by visiting `https://cv.alacaba.org` in browser — should serve the app
- [ ] **Test redirect** by visiting `http://cv.watchtoken.org` — should 301 → `https://cv.alacaba.org`

---

### Task 8: Update AGENTS.md

- [ ] **Document the new domain in AGENTS.md**

Edit relevant sections to reflect `cv.alacaba.org` alongside `cv.watchtoken.org` for the cv-datastar app.
