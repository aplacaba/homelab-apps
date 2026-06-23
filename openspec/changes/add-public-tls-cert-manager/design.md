## Context

The `pk3s` cluster fronts public traffic through Cloudflare: edge TLS terminates
at Cloudflare, a token-based `cloudflared` tunnel connects back to Traefik, and
Traefik currently serves public hosts on its `web` (HTTP) entrypoint only.
Traefik's `websecure` entrypoint exists (NodePort 30443) and live `--entryPoints.
websecure.http.tls=true` is set, but the repo's `traefik/helmrelease.yaml` does
not reflect this (drift), and there is no real certificate — only Traefik's
default self-signed one.

Constraints:
- Token-based tunnel → public hostname→origin mapping lives in the **Cloudflare
  Zero Trust dashboard**, not in this repo.
- HTTP-01 challenges cannot reach the cluster behind the tunnel, so **DNS-01** is
  required. The `watchtoken.org` zone is on Cloudflare, so the Cloudflare DNS-01
  provider is the natural solver.
- Secrets are managed by SealedSecrets (`kubeseal`); plaintext never enters git.
- Traefik has `providers.kubernetesCRD.allowCrossNamespace: true`.

## Goals / Non-Goals

**Goals:**
- Browser-trusted, Let's Encrypt-backed HTTPS on Traefik for public
  `*.watchtoken.org` services.
- Automated issuance + renewal with cert-manager.
- Global HTTP→HTTPS redirect for public hosts.
- Convert cv-datastar, forgejo, vaultwarden to public HTTPS.

**Non-Goals:**
- Trusted HTTPS for internal `*.local` (stays HTTP; out of scope).
- Converting floci / flux-dashboard / monitoring (trivial follow-up later).
- Changing the Cloudflare tunnel from token-based to file/config-based.
- Client-mTLS or internal service-mesh TLS.

## Decisions

### Decision 1: cert-manager over Traefik's built-in ACME
**Choice:** Install cert-manager + `ClusterIssuer` (DNS-01) rather than use
Traefik's native `certificatesResolvers`.
**Why:** cert-manager is the standard k8s cert lifecycle controller. It
decouples certificate state from the ingress controller into CRD objects
(`Certificate`, `ClusterIssuer`) and is reusable for future non-Traefik TLS
needs. The cost is one extra controller + per-cert YAML, accepted for a
long-lived homelab.
**Alternative considered:** Traefik built-in ACME — fewer moving parts and a
one-line `certResolver` per route, but cert state is owned by Traefik rather
than a portable CRD.

### Decision 2: DNS-01 via Cloudflare (not HTTP-01)
**Choice:** Let's Encrypt DNS-01, solved with a Cloudflare API token.
**Why:** The cluster is behind the Cloudflare Tunnel, so HTTP-01 inbound
challenges can't reach it. DNS-01 requires only outbound API access to
Cloudflare and supports wildcard certs. Works identically for all public hosts.

### Decision 3: Single wildcard certificate + Traefik default TLSStore
**Choice:** One wildcard `Certificate` for `*.watchtoken.org` writing Secret
`wildcard-watchtoken-org-tls` into the `traefik` namespace, referenced by a
Traefik **default TLSStore** so every `websecure` route serves it automatically
(`tls: {}`, no per-route `secretName`).
**Why:** One cert, one renewal, scales to all apps, and avoids duplicate-cert
rate-limit pressure. `allowCrossNamespace` is already enabled.
**Alternatives considered:**
- Per-app-namespace `Certificate` (self-contained, but 3+ identical wildcard
  certs; hits the Let's Encrypt 5-duplicate/week ceiling as apps grow).
- Per-app distinct-hostname certs (no duplicates, but more objects; no wildcard
  flexibility).

### Decision 4: Staging issuer before production
**Choice:** Create both `letsencrypt-staging` and `letsencrypt-prod`
`ClusterIssuer`s; validate the flow against staging first, then point the
`Certificate` at production.
**Why:** Protects against Let's Encrypt production rate limits while wiring is
being verified.

### Decision 5: Split each IngressRoute into public + local
**Choice:** Replace each app's single `web` IngressRoute with two: a public
`websecure`+`tls: {}` route and a `web` (HTTP) `*.local` route.
**Why:** Traefik `entryPoints` is spec-level (applies to all routes in one
IngressRoute), so a single object cannot mix HTTP and HTTPS. Splitting keeps
`*.local` on HTTP while public moves to HTTPS.

### Decision 6: Add HTTP→HTTPS redirect in this change (TLS already default)
**Choice:** Add `ports.web.redirections.entryPoint.{to: websecure, scheme: https,
permanent: true}` to `traefik/helmrelease.yaml`.
**Why:** Investigation during apply confirmed the traefik chart **already
defaults `ports.websecure.http.tls.enabled: true`** — so the live-vs-repo "drift"
is illusory (no value to pin). The only Traefik change needed is the redirect.
Enabling the redirect **forces** the Cloudflare tunnel to move to `:443` (Decision 7).

## Risks / Trade-offs

- **[Cross-namespace default TLSStore may behave unexpectedly]** → Verify after
  apply that a public route actually serves the wildcard cert; if not, fall back
  to per-route `secretName` cross-namespace reference, then to one `Certificate`
  per app namespace.
- **[Global redirect breaks the tunnel if origin stays on :80]** → The Cloudflare
  dashboard change (origin → `https://traefik:443`, Full strict) is a **required**
  operational step and is sequenced in tasks before/with the redirect.
- **[Cloudflare API token scope wrong → challenges fail]** → Token needs
  `Zone:DNS:Edit` for `watchtoken.org`; sealed via `kubeseal`, verified by a
  staging `Certificate` reaching `Ready=True`.
- **[Let's Encrypt rate limits]** → Staging-first; single wildcard keeps us well
  under duplicate/weekly limits.
- **[Renewal silently fails]** → cert-manager + the wildcard `Certificate` object
  surface failures; optionally add a Prometheus/Event-based check later (not in
  scope).

## Migration Plan

1. Deploy cert-manager (CRDs first), then `ClusterIssuer`s + sealed Cloudflare
   token.
2. Create the wildcard `Certificate` against the **staging** issuer; confirm
   `Ready=True` and Secret populated.
3. Pin Traefik TLS + default TLSStore; verify staging cert is served on a test
   route.
4. Switch the `Certificate` to **production**; confirm real cert served.
5. Split the three apps' IngressRoutes (public→websecure, local→web).
6. In the Cloudflare dashboard, switch tunnel origins to `https://traefik:443`
   (Full strict).
7. Enable the HTTP→HTTPS redirect on `web`; verify no redirect loops and that
   public HTTPS + local HTTP both work.

**Rollback:** revert the commits; cert-manager and the cert can remain
harmlessly, or be removed. Restore Cloudflare tunnel origins to `http://traefik:80`
if the redirect is reverted.

## Open Questions

- Confirm the exact Cloudflare tunnel origin value currently configured in the
  Zero Trust dashboard (service name vs LB IP) so the Full-strict step targets
  the right host. To be checked during apply.
