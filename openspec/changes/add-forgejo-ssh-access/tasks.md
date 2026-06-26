# Implementation Tasks

## 1. Forgejo HelmRelease values

- [x] 1.1 In `clusters/pk3s/forgejo/helmrelease.yaml`, set `service.ssh.type: NodePort` and `service.ssh.nodePort: 30022` (keep `service.ssh.port: 22`)
- [x] 1.2 Add `gitea.config.server.SSH_DOMAIN: ssh.fgit.watchtoken.org` and `gitea.config.server.SSH_PORT: 22`
- [x] 1.3 Render the chart locally (`helm template forgejo forgejo/forgejo --version 17.1.x -f <values>`) and confirm the ssh Service is `NodePort:30022` and `app.ini` contains the SSH_DOMAIN/SSH_PORT keys

## 2. Commit & Flux reconcile

- [x] 2.1 Commit the HelmRelease change, push
- [x] 2.2 Force reconcile: `kubectl -n flux-system reconcile helmrelease forgejo` (or wait for the 1h interval)
- [x] 2.3 Confirm `kubectl get svc -n forgejo` shows the ssh service as `NodePort` exposing 30022

## 3. Cloudflare Tunnel ingress + DNS (Terraform-managed)

- [x] 3.1 In `terraform/tunnel.tf`, add an ingress entry `{ hostname = "ssh.fgit.watchtoken.org", service = "ssh://forgejo-ssh.forgejo.svc:22" }` **before** the `http_status:404` catch-all (no `origin_request`/`no_tls_verify` — raw TCP, not via Traefik)
- [x] 3.2 In `terraform/dns.tf`, add a proxied CNAME `ssh.fgit` → `${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com` in the `watchtoken.org` zone (creates `ssh.fgit.watchtoken.org`, matching the ingress hostname)
- [x] 3.3 Run `terraform fmt` and `make lint` (pre-commit hook enforces `terraform fmt`)
- [x] 3.4 `terraform plan` — confirm only the tunnel-config update + the new DNS record change; then `terraform apply`
- [x] 3.5 Confirm the cloudflared pod reconciles the new config and `ssh.fgit.watchtoken.org` resolves to the tunnel CNAME (`dig`/`nslookup`)

## 4. Client setup (out-of-band, per client)

- [ ] 4.1 Install `cloudflared` on the client machine
- [ ] 4.2 Add to `~/.ssh/config`: `Host ssh.fgit.watchtoken.org` / `ProxyCommand cloudflared access ssh --hostname %h`
- [ ] 4.3 `cloudflared access login ssh.fgit.watchtoken.org` (one-time browser auth) if prompted

## 5. Verification

- [x] 5.1 LAN: `ssh -T -p 30022 git@192.168.254.50` prints the Forgejo greeting (no shell)
- [ ] 5.2 LAN round-trip: `git clone ssh://git@192.168.254.50:30022/<owner>/<repo>.git`, make a commit, `git push` succeeds — **needs SSH key added to Forgejo**
- [ ] 5.3 Public: `ssh -T git@ssh.fgit.watchtoken.org` (with ProxyCommand) prints the Forgejo greeting — **needs client cloudflared**
- [ ] 5.4 Public round-trip: clone + commit + push over `git@ssh.fgit.watchtoken.org:<owner>/<repo>.git` — **needs client cloudflared + SSH key**
- [x] 5.5 Forgejo UI: the SSH clone widget shows `git@ssh.fgit.watchtoken.org:<owner>/<repo>.git`
- [x] 5.6 `terraform` state shows the `ssh` ingress entry + CNAME; HTTPS hostnames (`fgit`/`vault`/`cv`) unchanged
- [x] 5.7 HTTPS unaffected: `https://fgit.watchtoken.org` and `forgejo.local` still load; `*.watchtoken.org` cert + traefik/cloudflared pods unchanged
- [x] 5.8 `openspec validate add-forgejo-ssh-access` passes

## 6. Documentation

- [x] 6.1 Update `AGENTS.md`: add a Forgejo SSH section — NodePort 30022 LAN address; `ssh.fgit.watchtoken.org` public via cloudflared, with the route Terraform-managed (`tunnel.tf` ingress + `dns.tf` CNAME, straight to `forgejo-ssh`, no Traefik); the per-client `cloudflared` ProxyCommand SOP. Add the Terraform files to "Modified" conventions if a Terraform section exists.
