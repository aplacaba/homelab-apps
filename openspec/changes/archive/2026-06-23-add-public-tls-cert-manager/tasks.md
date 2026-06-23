# Implementation Tasks

## 1. cert-manager infrastructure

- [x] 1.1 Create `clusters/pk3s/cert-manager/` dir with `namespace.yaml` (`cert-manager`)
- [x] 1.2 Add `helmrepository.yaml` (jetstack, `https://charts.jetstack.io`, in `flux-system`)
- [x] 1.3 Add `helmrelease.yaml` (cert-manager chart `v1.20.2`, `crds.enabled: true`)
- [x] 1.4 Add `kustomization.yaml` listing the resources
- [x] 1.5 Add `cert-manager` to root `clusters/pk3s/kustomization.yaml` (alphabetical)
- [x] 1.6 Verify cert-manager pods `Ready` in `cert-manager` ns after Flux reconcile

## 2. Cloudflare API token + ClusterIssuers

- [x] 2.1 Create a Cloudflare API token with `Zone:DNS:Edit` for `watchtoken.org` (out-of-band)
- [x] 2.2 Seal it as `cloudflare-api-token` SealedSecret in `cert-manager` ns via `kubeseal`
- [x] 2.3 Add `clusterissuer-staging.yaml` (Let's Encrypt staging, DNS-01, Cloudflare provider, `secretRef`)
- [x] 2.4 Add `clusterissuer-prod.yaml` (Let's Encrypt production, same solver)
- [x] 2.5 Add both to `cert-manager/kustomization.yaml`

## 3. Wildcard certificate (Certificate lives in `traefik` ns so its Secret lands there)

- [x] 3.1 Add `traefik/certificate.yaml` — wildcard `*.watchtoken.org`, **staging** ClusterIssuer, Secret `wildcard-watchtoken-org-tls` in `traefik` ns; add to `traefik/kustomization.yaml`
- [x] 3.2 Confirm `Certificate` reaches `Ready=True` and Secret is populated in `traefik`
- [x] 3.3 Switch `certificate.yaml` `issuerRef` to **production**; confirm renewed real cert

## 4. Traefik TLS + redirect

- [x] 4.1 `websecure.http.tls.enabled` — already `true` by chart default; nothing to pin (verified during apply)
- [x] 4.2 Add a Traefik `default` TLSStore in `traefik` ns referencing `wildcard-watchtoken-org-tls`
- [x] 4.3 Add HTTP→HTTPS redirect — **host-scoped** `redirect-to-https` middleware (global entrypoint redirect would break `*.local`); applied to the public `*.watchtoken.org` web routes only
- [x] 4.4 Verified `websecure` serves the wildcard cert before app cutover (openssl on :443 for all hosts)

## 5. App IngressRoute split (cv-datastar, forgejo, vaultwarden)

- [x] 5.1 cv-datastar: added `ingressroute-https.yaml` (`websecure`, `cv.watchtoken.org`, `tls: {}`); `:80` route now redirects public host, keeps `cv.local` HTTP
- [x] 5.2 forgejo: added `ingressroute-https.yaml` (`websecure`, `fgit.watchtoken.org`); `:80` public route redirects to https (no `.local` host exists)
- [x] 5.3 vaultwarden: added `ingressroute-https.yaml` (`websecure`, `vault.watchtoken.org`); `:80` redirects public host, keeps `vault.local` HTTP
- [x] 5.4 Updated each app `kustomization.yaml` to list the new IngressRoute files

## 6. Cloudflare tunnel — HTTPS origin (operational, outside GitOps)

- [x] 6.1 Confirmed tunnel origin (from cloudflared logs): all hosts → `http://traefik.traefik.svc:80`
- [x] 6.2 Switched all 3 public hostname origins to `https://traefik.traefik.svc:443` with **No TLS Verify = ON** (dashboard Origin Server Name did not apply, and the cert is `*.watchtoken.org` vs origin host `traefik.traefik.svc` → strict verify fails). End-to-end is encrypted (Full); verification skipped — acceptable since the tunnel is already encrypted and the cloudflared→Traefik hop is intra-cluster.
- [x] 6.3 Confirmed: `cloudflared` picked up config (version 12, `noTLSVerify:true`); no TLS errors; public 200s.

## 7. Verification

- [x] 7.1 `https://cv.watchtoken.org` → 200 (and fgit, vault)
- [x] 7.2 `http://cv.watchtoken.org` (direct :80) → 301 → https (and fgit, vault)
- [x] 7.3 `https://vault.watchtoken.org` → 200, trusted (LE prod cert on :443)
- [x] 7.4 `https://fgit.watchtoken.org` → 200
- [x] 7.5 LAN `http://cv.local` and `http://vault.local` → 200 over HTTP (unchanged)
- [x] 7.6 `openspec validate add-public-tls-cert-manager` passes
- [x] 7.7 Update `AGENTS.md` (new cert-manager infra dir + TLS gotchas)
