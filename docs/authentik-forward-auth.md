# Authentik Forward Auth — Gating Apps Behind Authentik

How to put any homelab app behind Authentik SSO using Traefik's **forward-auth**
middleware. Paperless-ngx is the worked example; the pattern applies to any app.

> **TL;DR of the two things everyone forgets:** (1) the app's IngressRoute needs
> **two** routes — one for `/outpost.goauthentik.io/` going straight to Authentik,
> and (2) after creating the Provider + Application in the Authentik UI you must
> **assign the provider to the embedded outpost**. Skip either and you get a 404.

---

## How it works

```
Browser: http://<app>.local:30080
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ TRAEFIK (LoadBalancer 192.168.254.50:80→30080)               │
│ IngressRoute "<app>" (ns: <app>)                             │
│                                                              │
│  Route match decides where the request goes:                 │
│   • path /outpost.goauthentik.io/ → authentik-server:80      │
│       (NO middleware — direct to Authentik)                  │
│   • everything else             → middleware, then <app>:port│
└──────────────────────────────────────────────────────────────┘
   │ (for normal requests, the middleware runs first)
   ▼
┌──────────────────────────────────────────────────────────────┐
│ MIDDLEWARE "authentik-forwardauth" (ns: traefik)             │
│  Before reaching <app>, Traefik calls:                       │
│   http://authentik-server.authentik.svc.cluster.local:80     │
│       /outpost.goauthentik.io/auth/traefik                   │
│   • 200 → ok, inject X-authentik-* headers, let it through   │
│   • 401 → not logged in → 302 redirect to the login page     │
│   • 404 → no Application/Provider for this host  ← a misconf │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
AUTHENTIK EMBEDDED OUTPOST (runs inside authentik-server pod,
  served by svc ak-outpost-authentik-embedded-outpost :9000)
  Looks up: "is there a Provider, assigned to me, whose
            external_host == the request host (incl. port)?"
   │
   ▼
<APP> (your service) — only reached AFTER auth succeeds
```

The `X-authentik-*` headers (`username`, `email`, `name`, `groups`, `uid`) are
injected into the forwarded request; some apps can be configured to trust them
for auto-login (optional, app-specific).

---

## Prerequisites (already in place on this cluster)

These are **one-time** cluster setup steps. Done once, reused for every app.

1. **Traefik under Flux + cross-namespace refs enabled.**
   The middleware lives in `traefik` ns and the outpost in `authentik` ns, but
   each gated app's IngressRoute is in its own ns — so Traefik must be allowed
   to follow cross-namespace references:
   `providers.kubernetesCRD.allowCrossNamespace: true` (set in
   `clusters/pk3s/traefik/helmrelease.yaml`). Verify:
   ```bash
   kubectl get deploy traefik -n traefik -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i cross
   ```

2. **The shared forward-auth middleware** —
   `clusters/pk3s/traefik/middlewares/authentik-forwardauth.yaml`. Every gated
   app references this same middleware by name; do not create per-app copies.

---

## Gating a new app — step by step

### Step 1 — Authentik UI: create a Proxy Provider

**Admin → Applications → Providers → Create → Proxy Provider**

| Field | Value |
|-------|-------|
| Name | `<App>` (e.g. `Paperless`) |
| Authorization flow | `default-authentication-flow` (or your SSO flow) |
| **External host** | **exactly the URL you open in the browser, including port** — e.g. `http://paperless.local:30080` |
| Mode | **Forward auth (single application)** |

> ⚠️ **The External host must match the browser URL byte-for-byte, port included.**
> Browsing `:80` while the host is set to `:30080` (or vice-versa) → 404.
> See [Port consistency](#port-consistency-the-main-cause-of-404s) below.

### Step 2 — Authentik UI: create an Application

**Admin → Applications → Applications → Create**

| Field | Value |
|-------|-------|
| Name | `<App>` |
| Slug | `<app>` (e.g. `paperless`) |
| Provider | the Proxy Provider from Step 1 |

### Step 3 — Authentik UI: assign the provider to the embedded outpost  ⚠️

**This is the step most people miss and it causes 404 for every host.**

The embedded outpost does **not** auto-discover providers — it only serves
providers explicitly assigned to it.

**Admin → Outposts → `authentik Embedded Outpost` → Edit → Applications**
→ add your new Application → Update.

Verify (returns the count of providers the outpost is serving):
```bash
kubectl exec -n authentik authentik-postgresql-0 -- env PGPASSWORD=authentik-db-pass \
  psql -U authentik -d authentik -t -c \
  "SELECT count(*) FROM authentik_outposts_outpost_providers;"
# must be >= 1 once assigned
```

### Step 4 — Kubernetes: the two-route IngressRoute

If your chart has built-in IngressRoute support, **disable it** (the chart's
single-route shape can't express the two routes auth requires):
```yaml
# in the chart values (helmrelease.yaml)
ingressRoute:
  create: false
```

Then create a manual IngressRoute with **both** routes. See the
[reusable template](#reusable-ingressroute-template) below. Add it to the app's
`kustomization.yaml`, commit, and push.

### Step 5 — Verify

```bash
# The outpost should now return 401/302 (needs login), NOT 404:
kubectl exec -n <app> deploy/<app> -- /bin/sh -c '
  curl -sS -o /dev/null -w "%{http_code}\n" \
    -H "X-Forwarded-Host: <app>.local:30080" -H "X-Forwarded-Proto: http" \
    http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik'
# 401/302 = gate working   |   404 = not assigned / host mismatch (see below)

# Full path through Traefik:
curl -sS -o /dev/null -w "%{http_code}\n" \
  --resolve <app>.local:30080:192.168.254.50 http://<app>.local:30080
# 302 = working (redirects to Authentik login)
```

Then open the URL in a browser → Authentik login → redirected back authenticated.

---

## Reusable IngressRoute template

`clusters/pk3s/<app>/ingressroute.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: <app>
spec:
  entryPoints:
    - web
  routes:
    # 1) Authentik outpost endpoints hit by the browser during/after login.
    #    These MUST reach Authentik directly, WITHOUT the forward-auth
    #    middleware, otherwise the post-login redirect loops or 404s.
    - kind: Rule
      match: Host(`<app>.local`) && PathPrefix(`/outpost.goauthentik.io/`)
      services:
        - name: authentik-server
          namespace: authentik
          port: 80
    # 2) The application itself, gated by Authentik forward-auth.
    - kind: Rule
      match: Host(`<app>.local`)
      middlewares:
        - name: authentik-forwardauth
          namespace: traefik
      services:
        - name: <app>
          namespace: <app>
          port: <port>
```

> Both `authentik-server` (authentik ns) and `authentik-forwardauth` (traefik ns)
> are cross-namespace references — this is why Traefik needs
> `allowCrossNamespace: true`.

---

## Port consistency: the main cause of 404s

The outpost matches the request's `X-Forwarded-Host` **including the port**.
On this cluster Traefik is reachable on **`:30080`** (NodePort), and Authentik's
own `authentik_host` is `http://authentik.local:30080`. **Keep everything on the
same port.**

| Browse URL | `external_host` | Result |
|------------|-----------------|--------|
| `http://<app>.local:30080` | `http://<app>.local:30080` | ✅ 302 (works) |
| `http://<app>.local` (:80) | `http://<app>.local:30080` | ❌ 404 (port mismatch) |
| `http://<app>.local` (:80) | `http://<app>.local` (:80) | ✅ 302 (works, *if* authentik_host also changed to :80) |

Rule of thumb: the **Provider's external_host**, the **browser URL**, and
**Authentik's `authentik_host`** should all use the same port.

---

## Troubleshooting: "still showing not found" (404)

A 404 from the forward-auth flow has exactly **two** causes. Diagnose in order:

### Check 1 — Is the provider assigned to the outpost? (most common)

The provider-list the outpost fetches should contain your app. If it returns
**0 providers**, the provider isn't assigned (Step 3 was skipped):

```bash
# What the embedded outpost sees (must include your app's external_host):
kubectl exec -n authentik authentik-postgresql-0 -- env PGPASSWORD=authentik-db-pass \
  psql -U authentik -d authentik -t -c \
  "SELECT pp.external_host FROM authentik_providers_proxy_proxyprovider pp
   JOIN authentik_outposts_outpost_providers op ON op.provider_id = pp.oauth2provider_ptr_id;"
```
If empty → go to **Admin → Outposts → embedded outpost → Edit → Applications**
and add your app.

### Check 2 — Does the host match, including port?

Probe with the host that exactly matches `external_host`. If it returns 401/302
but a different host returns 404, you have a port or hostname mismatch — see
[Port consistency](#port-consistency-the-main-cause-of-404s) above.

### Quick decision table

| Outpost response | Meaning | Fix |
|------------------|---------|-----|
| **200** | already authenticated (valid session) | — (working) |
| **302** | needs login → redirect (returned on direct probe) | — (working) |
| **401** | needs login | — (working) |
| **404** | no matching Provider for this host | provider not assigned **or** host/port mismatch |

> A 404 from `logger: authentik.asgi` (not from Traefik) confirms the request
> *reached* Authentik and the plumbing is fine — the problem is purely Authentik
> config (assignment or host match), not Kubernetes.

---

## Reference: the live paperless example

The complete working configuration, verified end-to-end:

| Component | Value | Location |
|-----------|-------|----------|
| Forward-auth middleware | `authentik-forwardauth` (ns `traefik`) | `clusters/pk3s/traefik/middlewares/authentik-forwardauth.yaml` |
| Traefik cross-namespace | `allowCrossNamespace: true` | `clusters/pk3s/traefik/helmrelease.yaml` |
| Paperless IngressRoute | 2 routes (outpost + gated app) | `clusters/pk3s/paperless/ingressroute.yaml` |
| Provider `external_host` | `http://paperless.local:30080` | Authentik DB (Proxy Provider) |
| Outpost assignment | provider id 3 → embedded outpost | Authentik DB |
| Access URL | `http://paperless.local:30080` | — |

Behavior: `http://paperless.local:30080` → 302 → Authentik login → authenticated
session → Paperless.
