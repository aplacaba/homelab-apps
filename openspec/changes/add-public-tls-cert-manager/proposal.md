## Why

All public services (`*.watchtoken.org`) are served over plain HTTP between
Cloudflare's edge and Traefik, and Traefik's `websecure` entrypoint uses only its
default self-signed certificate. There is no browser-trusted certificate on the
cluster and no automated certificate lifecycle. Vaultwarden in particular needs a
trusted HTTPS context for its web vault, and the broader goal is real,
Let's Encrypt-backed HTTPS for every public app — not just edge termination.

## What Changes

- Add **cert-manager** as a new infrastructure component (new GitOps dir), with
  CRDs enabled, deployed via Flux HelmRelease from the jetstack chart.
- Add a Let's Encrypt **DNS-01** `ClusterIssuer` pair (staging + production) that
  uses a Cloudflare API token (SealedSecret) to solve challenges — works behind
  the Cloudflare Tunnel where HTTP-01 cannot reach the cluster.
- Issue a single **wildcard certificate** `*.watchtoken.org`, exposed as Traefik's
  **default TLSStore** so every public route serves it without per-route wiring.
- **Pin existing Traefik drift** into GitOps: `websecure.http.tls=true` (live but
  not in the repo) and add a global **HTTP→HTTPS redirect** on the `web` entrypoint.
- **Split** each app's IngressRoute: public host → `websecure` + `tls: {}`;
  internal `*.local` host → stays on `web` (HTTP).
- Convert the three named apps (**cv-datastar, forgejo, vaultwarden**) to public
  HTTPS. Other public apps (floci, flux-dashboard, monitoring) get HTTPS by a
  trivial one-line IngressRoute switch later — out of scope here.
- **BREAKING (operational):** the token-based Cloudflare Tunnel's origin must move
  from `http://traefik:80` to `https://traefik:443` (Cloudflare "Full strict") in
  the Zero Trust dashboard, otherwise the new HTTP→HTTPS redirect causes a loop.
  This is a manual dashboard change, tracked as a task.

## Capabilities

### New Capabilities
- `public-tls`: Automated, browser-trusted TLS termination for public
  `*.watchtoken.org` services on Traefik, with HTTP→HTTPS redirection.

### Modified Capabilities
<!-- None — no existing specs in openspec/specs/. -->

## Impact

- **New infra dir:** `clusters/pk3s/cert-manager/` (namespace, HelmRepository,
  HelmRelease, SealedSecret, ClusterIssuers, Certificate).
- **Modified:** `clusters/pk3s/traefik/helmrelease.yaml` (pin TLS, add redirect);
  `clusters/pk3s/cv-datastar/ingressroute.yaml`,
  `clusters/pk3s/forgejo/ingressroute-public.yaml`,
  `clusters/pk3s/vaultwarden/ingressroute.yaml` (split into public + local).
- **Root kustomization:** add `cert-manager` resource.
- **External dependency:** Cloudflare API token (DNS edit on `watchtoken.org`),
  sealed out-of-band via `kubeseal`.
- **Out-of-band operational step:** Cloudflare Zero Trust dashboard — switch
  tunnel origins to HTTPS:443 (Full strict).
- **No data migration;** no plaintext secrets in git.
