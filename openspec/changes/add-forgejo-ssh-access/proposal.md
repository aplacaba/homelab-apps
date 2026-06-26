## Why

Forgejo's HTTPS clone already works (public via `fgit.watchtoken.org`, internal via
`forgejo.local`), but **git-over-SSH is not reachable**. The Forgejo pod runs an
SSH server (rootless image, container port 2222) behind a `Service` that is
`ClusterIP:22` — it exists but is **never exposed**: no NodePort, no Traefik TCP
entryPoint, and the Cloudflare Tunnel only routes HTTP/HTTPS hostnames. So
`git clone git@...:repo.git` fails today, and the clone-URL SSH widget in the
Forgejo UI is misleading (`server.SSH_DOMAIN` / `SSH_PORT` are unset).

SSH access is wanted both on the **LAN** (direct) and **publicly** (from
anywhere), matching how HTTPS already works.

## What Changes

- **Expose the Forgejo SSH `Service` as a `NodePort` (30022)** for direct LAN
  access. The node's own `sshd` owns `:22`, so SSH must use an alternate port.
- **Advertise the SSH clone URL** via `gitea.config.server.SSH_DOMAIN` +
  `SSH_PORT` so the UI shows a working SSH URL.
- **Public SSH over the Cloudflare Tunnel** using a **dedicated subdomain**
  (`ssh.fgit.watchtoken.org`): clients run `cloudflared` as an SSH `ProxyCommand`.
  This stays tunnel-only (no opened router ports), consistent with the cluster's
  existing ingress model. Unlike HTTPS hostnames (which route to Traefik), the SSH
  ingress routes the tunnel **directly to `forgejo-ssh`** — no Traefik TCP
  entryPoint involved.
- **The public path is Terraform-managed** (in this repo): the tunnel ingress
  entry lives in `terraform/tunnel.tf` and the `ssh` CNAME in `terraform/dns.tf`,
  alongside the existing `cv`/`fgit`/`vault` hostnames. No Cloudflare Access
  policy is added — consistent with the cluster's "Auth: None" model (Forgejo
  authenticates via SSH keys).
- **Forgejo rootless image**: container SSH listen port stays 2222; the chart
  already wires `service.ssh.port: 22` → targetPort 2222. No change to that
  mapping.
- **Non-breaking:** HTTPS access (`fgit.watchtoken.org`, `forgejo.local`) is
  untouched. The `*.watchtoken.org` wildcard cert is untouched (SSH is raw TCP,
  no TLS). No other app is affected.

## Capabilities

### New Capabilities
- `forgejo-ssh`: git-over-SSH access to Forgejo, reachable on the LAN (NodePort)
  and publicly (Cloudflare Tunnel + client `cloudflared`).

### Modified Capabilities
<!-- None — no existing spec covers forgejo. -->

## Impact

- **Modified:** `clusters/pk3s/forgejo/helmrelease.yaml` —
  `service.ssh.type: NodePort` + `nodePort: 30022`, and add
  `gitea.config.server.SSH_DOMAIN` / `SSH_PORT`.
- **Modified:** `terraform/tunnel.tf` — add an ingress entry
  `ssh.fgit.watchtoken.org` → `ssh://forgejo-ssh.forgejo.svc:22` (before the
  `http_status:404` catch-all). Unlike the other hostnames it does **not** route
  to `local.tunnel_service` (Traefik) and needs no `no_tls_verify` (raw TCP).
- **Modified:** `terraform/dns.tf` — add a proxied CNAME `ssh` →
  `${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com` in the
  `watchtoken.org` zone, mirroring the existing `fgit`/`vault` records.
- **Modified:** `AGENTS.md` — document the new NodePort, the Terraform-managed
  tunnel/DNS for `ssh.fgit.watchtoken.org`, and the client `cloudflared` SSH
  setup (operational SOP).
- **Out-of-band (each client):** install `cloudflared`; add an SSH `ProxyCommand`
  block for `ssh.fgit.watchtoken.org` to `~/.ssh/config`. (The tunnel itself is
  already Terraform-managed; only client setup remains manual.)
- **No impact** on cert-manager, traefik, cloudflared (pod), cv-datastar,
  monitoring, sealed-secrets, vaultwarden, forgejo-runner.
