# Implementation Tasks

## 1. cert-manager infrastructure

- [x] 1.1 Create `clusters/pk3s/cert-manager/` dir with `namespace.yaml` (`cert-manager`)
- [x] 1.2 Add `helmrepository.yaml` (jetstack, `https://charts.jetstack.io`, in `flux-system`)
- [x] 1.3 Add `helmrelease.yaml` (cert-manager chart `v1.20.2`, `crds.enabled: true`)
- [x] 1.4 Add `kustomization.yaml` listing the resources
- [x] 1.5 Add `cert-manager` to root `clusters/pk3s/kustomization.yaml` (alphabetical)
- [ ] 1.6 Verify cert-manager pods `Ready` in `cert-manager` ns after Flux reconcile

## 2. Cloudflare API token + ClusterIssuers

- [x] 2.1 Create a Cloudflare API token with `Zone:DNS:Edit` for `watchtoken.org` (out-of-band)
- [x] 2.2 Seal it as `cloudflare-api-token` SealedSecret in `cert-manager` ns via `kubeseal`
- [x] 2.3 Add `clusterissuer-staging.yaml` (Let's Encrypt staging, DNS-01, Cloudflare provider, `secretRef`)
- [x] 2.4 Add `clusterissuer-prod.yaml` (Let's Encrypt production, same solver)
- [x] 2.5 Add both to `cert-manager/kustomization.yaml`

## 3. Wildcard certificate (Certificate lives in `traefik` ns so its Secret lands there)

- [x] 3.1 Add `traefik/certificate.yaml` — wildcard `*.watchtoken.org`, **staging** ClusterIssuer, Secret `wildcard-watchtoken-org-tls` in `traefik` ns; add to `traefik/kustomization.yaml`
- [ ] 3.2 Confirm `Certificate` reaches `Ready=True` and Secret is populated in `traefik`
- [ ] 3.3 Switch `certificate.yaml` `issuerRef` to **production**; confirm renewed real cert

## 4. Traefik TLS + redirect

- [x] 4.1 `websecure.http.tls.enabled` — already `true` by chart default; nothing to pin (verified during apply)
- [x] 4.2 Add a Traefik `default` TLSStore in `traefik` ns referencing `wildcard-watchtoken-org-tls`
- [ ] 4.3 Add HTTP→HTTPS redirect on `web`: `ports.web.redirections.entryPoint.to=websecure` (permanent) — **BREAKING; do at cutover with Phase 5/6**
- [ ] 4.4 Verify a test `websecure` route serves the wildcard cert before app cutover

## 5. App IngressRoute split (cv-datastar, forgejo, vaultwarden)

- [ ] 5.1 Split `cv-datastar/ingressroute.yaml` → public (`websecure`, `tls: {}`, `cv.watchtoken.org`) + local (`web`, `cv.local`)
- [ ] 5.2 Split `forgejo/ingressroute-public.yaml` → public (`websecure`, `fgit.watchtoken.org`) + local (`web`) if a local host exists; else just move public to `websecure`
- [ ] 5.3 Split `vaultwarden/ingressroute.yaml` → public (`websecure`, `vault.watchtoken.org`) + local (`web`, `vault.local`)
- [ ] 5.4 Update each app `kustomization.yaml` to list the new IngressRoute files

## 6. Cloudflare tunnel — Full strict (operational, outside GitOps)

- [ ] 6.1 Confirm current tunnel origin host (service name vs LB IP) in the Zero Trust dashboard
- [ ] 6.2 Switch public hostname origins to `https://<traefik>:443`, set SSL mode to Full (strict)
- [ ] 6.3 Confirm tunnel health is green after the switch

## 7. Verification

- [ ] 7.1 `curl -vI https://cv.watchtoken.org` → valid LE prod cert, 200
- [ ] 7.2 `curl -vI http://cv.watchtoken.org` → 301 redirect to https
- [ ] 7.3 Browser → `https://vault.watchtoken.org` → trusted, web vault loads
- [ ] 7.4 Browser → `https://fgit.watchtoken.org` → trusted, Forgejo loads
- [ ] 7.5 LAN `curl http://cv.local` and `http://vault.local` → still 200 over HTTP
- [ ] 7.6 `openspec validate add-public-tls-cert-manager` passes
- [ ] 7.7 Update `AGENTS.md` (new cert-manager infra dir + TLS gotchas) if conventions changed
