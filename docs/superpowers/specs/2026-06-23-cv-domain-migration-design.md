# CV Domain Migration: cv.watchtoken.org → cv.alacaba.org

## Summary

Migrate the cv-datastar app from `cv.watchtoken.org` to `cv.alacaba.org`.
Old domain issues a 301 redirect to the new one. All changes are declarative
in git (Flux-managed), except for Cloudflare DNS + tunnel config (out-of-band).

## Current State

- `cv.watchtoken.org` served via Traefik IngressRoute (HTTP→HTTPS redirect + HTTPS)
  in `clusters/pk3s/cv-datastar/ingressroute.yaml` + `ingressroute-https.yaml`
- TLS via wildcard `*.watchtoken.org` cert in `traefik/` namespace (default TLSStore)
- `cv.local` served on HTTP for LAN access (unchanged by this work)
- Cloudflare tunnel routes `cv.watchtoken.org` → Traefik `:443` (No TLS Verify)

## Desired State

- `cv.alacaba.org` serves the app (HTTP→HTTPS redirect + HTTPS IngressRoutes)
- `cv.watchtoken.org` issues 301 redirect (preserving path) to `cv.alacaba.org`
- `cv.local` unchanged
- Specific `cv.alacaba.org` cert from cert-manager + Let's Encrypt
- No wildcard cert needed for alacaba.org

## Files to Create

### `clusters/pk3s/cv-datastar/ingressroute-alacaba.yaml`

Two IngressRoutes for the new domain:

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

### `clusters/pk3s/cv-datastar/certificate-alacaba.yaml`

Specific cert for the new domain:

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

Traefik SNI will serve this cert automatically when the secret exists in the
`traefik` namespace. No TLSStore change needed.

### `clusters/pk3s/cv-datastar/middlewares/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - redirect-to-alacaba.yaml
```

### `clusters/pk3s/cv-datastar/middlewares/redirect-to-alacaba.yaml`

301 redirect preserving the request path:

```yaml
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

## Files to Modify

### `clusters/pk3s/cv-datastar/ingressroute-https.yaml`

Change from serving content to using the redirect middleware. The HTTP
`ingressroute.yaml` already redirects to HTTPS via `redirect-to-https` middleware,
so that stays unchanged. The HTTPS route needs to stop serving and start
redirecting:

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

The `tls: {}` is kept so the HTTPS entrypoint and wildcard cert still apply.
The service reference is also kept (required by Traefik, even though the
middleware will redirect before reaching it).

### `clusters/pk3s/cv-datastar/kustomization.yaml`

Add new resources:

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

## Out-of-Band Steps (Cloudflare Zero Trust Dashboard)

1. Add DNS record `cv.alacaba.org` (CNAME or A/AAAA pointing to tunnel)
2. Add public hostname `cv.alacaba.org` → `https://traefik.traefik.svc:443`
   with No TLS Verify ON
3. Optionally remove `cv.watchtoken.org` public hostname (the redirect will
   still work if the tunnel continues routing traffic to Traefik)

## Out-of-Band Steps (Optional)

1. Add `cv.alacaba.org` to `~/.ssh/config` or cert-manager email if needed
2. Update `AGENTS.md` with the new domain

## No Changes

- `ingressroute.yaml` (HTTP) — `cv.watchtoken.org` already redirects to HTTPS;
  the HTTPS IngressRoute now handles the actual redirect
- `cv.local` — unchanged
- HelmRelease — no config changes
- Cloudflare tunnel deployment — no k8s changes
- TLSStore — SNI matching handles the new cert automatically
