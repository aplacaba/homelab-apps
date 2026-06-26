## Context

Forgejo runs in the `forgejo` namespace from the upstream Helm chart (`17.1.x`),
`image.rootless: true`. The chart defines two services:

- `forgejo-http` — `ClusterIP:3000`, exposed publicly via Traefik IngressRoute
  (`fgit.watchtoken.org` → `websecure`, `forgejo.local` → `web`) and through the
  Cloudflare Tunnel (`fgit.watchtoken.org` → `https://traefik.traefik.svc:443`).
- `forgejo-ssh` (the chart's `service.ssh`) — currently `ClusterIP:22`. With the
  rootless image the container listens on **2222**; the chart maps
  `service.ssh.port: 22` → targetPort 2222. The SSH server is enabled by chart
  default.

The cluster is a **single-node k3s** at `192.168.254.50`. The node itself runs
`sshd` on `:22`, so host port 22 is taken. Public ingress is **Cloudflare Tunnel
only** — there is no public IP and no router ports are opened. The tunnel
(`k3s-tunnel`) and its **ingress routing + DNS are managed by Terraform** in this
repo: `terraform/tunnel.tf` (`cloudflare_zero_trust_tunnel_cloudflared_config`
with an `ingress` list where every hostname → `local.tunnel_service` =
`https://traefik.traefik.svc:443`, `no_tls_verify: true`, plus an
`http_status:404` catch-all) and `terraform/dns.tf` (proxied CNAMEs to
`${tunnel.id}.cfargotunnel.com`). Only the tunnel **token** stays out-of-band (a
SealedSecret, like `tunnel-credentials`). State is in an S3 backend; the workflow
is `make lint` / `terraform fmt` (pre-commit hook) + `terraform apply` locally.

Traefik is a `LoadBalancer` (VIPs `192.168.254.50-52`) with only `web`
(NodePort 30080) and `websecure` (NodePort 30443) entryPoints. There is **no TCP
entryPoint** for SSH.

`server.SSH_DOMAIN` and `server.SSH_PORT` are unset in `gitea.config.server`, so
the SSH clone URL Forgejo renders in the UI is currently wrong.

## Goals / Non-Goals

**Goals:**
- `git clone`/`push` over SSH to Forgejo works.
- Reachable on the **LAN directly** (no client-side tooling beyond `ssh`).
- Reachable **publicly** from anywhere, tunnel-only (no opened router ports).
- The SSH clone URL shown in the Forgejo UI is correct for the public path.

**Non-Goals:**
- Exposing SSH on standard port 22 (host port is taken by the node `sshd`).
- Opening a port on the router/firewall (would break the tunnel-only model).
- Routing SSH through Traefik (`IngressRouteTCP`) — a single SSH backend does not
  justify a new Traefik TCP entryPoint; revisit if multiple TCP services appear.
- Changing HTTPS access, TLS certs, or any other app.
- Per-route TLS for the SSH hostname (raw TCP, no cert needed).

## Decisions

### Decision 1: LAN via NodePort 30022 on `service.ssh`
**Choice:** Switch `service.ssh.type` to `NodePort` with `nodePort: 30022`
(`port: 22` unchanged as the tunnel target). LAN clones use
`ssh://git@192.168.254.50:30022/...`.
**Why:** Simplest possible exposure for the direct LAN path — a one-line values
change, no new components, no new Traefik config. 30022 is in the k3s NodePort
range (30000–32767) and avoids the node's own `:22`.
**Alternative considered:** Traefik TCP entryPoint + `IngressRouteTCP` — rejected
as extra machinery for a single backend with no middlewares needed (see
Non-Goals).

### Decision 2: Public via Cloudflare Tunnel + client `cloudflared`, managed in Terraform
**Choice:** Add a tunnel ingress entry `ssh.fgit.watchtoken.org` →
`ssh://forgejo-ssh.forgejo.svc:22` in `terraform/tunnel.tf`, and a proxied `ssh`
CNAME in `terraform/dns.tf`; clients use an SSH `ProxyCommand` invoking
`cloudflared access ssh`.
**Why:** The cluster has no public IP and all ingress is tunnel-only. The tunnel
ingress + DNS are already Terraform-managed, so the public SSH route is just two
more resources alongside `fgit`/`vault`/`cv`. Cloudflare only proxies HTTP(S) on
its own; raw TCP/SSH requires the client-side `cloudflared` — the standard
homelab pattern, no opened router ports. SSH traffic goes **straight to
`forgejo-ssh`** (not via Traefik), so no Traefik TCP entryPoint is needed.
**No Cloudflare Access policy** is added — consistent with the cluster's
"Auth: None" model; Forgejo authenticates via SSH keys.
**Alternative considered:** open a router port to the node for plain SSH —
rejected; it breaks the tunnel-only model the cluster was built around.

### Decision 3: Dedicated subdomain `ssh.fgit.watchtoken.org`
**Choice:** Use a new, dedicated hostname for SSH rather than reusing
`fgit.watchtoken.org`.
**Why:** A tunnel Public Hostname maps one hostname → one origin
protocol/service. `fgit.watchtoken.org` already routes to
`https://traefik.traefik.svc:443` for HTTPS; pointing it at the SSH service would
break web access. A dedicated hostname keeps web and SSH ingress independent.
**Alternative considered:** share `fgit.watchtoken.org` — rejected due to the
single-origin-per-hostname constraint above.

### Decision 4: Forgejo advertises `SSH_DOMAIN=ssh.fgit.watchtoken.org`, `SSH_PORT=22`
**Choice:** Set these so the UI clone URL is
`git@ssh.fgit.watchtoken.org:user/repo.git` (port 22 omitted = default).
**Why:** Forgejo renders exactly one SSH clone URL; pointing it at the public
hostname makes remote clones correct out-of-the-box. With `cloudflared`'s
`ProxyCommand`, the advertised port is virtual (the proxy replaces the TCP
connection), so the default 22 is correct.
**Trade-off:** LAN users who prefer direct access use the NodePort address
(`ssh://git@192.168.254.50:30022/...`) rather than the advertised URL. This is
inherent to wanting two paths and is documented.

### Decision 5: No cert / Traefik / secret changes
**Choice:** Touch only the Forgejo HelmRelease values, the Terraform tunnel/DNS
resources, and `AGENTS.md` docs.
**Why:** SSH is raw TCP — the `*.watchtoken.org` wildcard TLS cert (terminated on
Traefik) is irrelevant to it. The tunnel routes straight to `forgejo-ssh`, so no
Traefik change. No new Secret, no SealedSecret.

## Risks / Trade-offs

- **[Two connection shapes]** LAN-direct vs public-proxied, and a single
  advertised URL → **accepted** (Decision 4); documented in AGENTS.md.
- **[Client setup friction]** every public-SSH client needs `cloudflared` + an
  SSH config block → **accepted** (inherent to tunnel-only); mitigated by a
  documented SOP and an `Include`-able snippet.
- **[NodePort 30022 reachability]** must be open on the node firewall for LAN use
  → verify with `ssh -p 30022 git@192.168.254.50`; if blocked, open locally.
- **[Terraform state/backend]** the tunnel ingress + CNAME are applied via
  `terraform apply` against the S3 backend → run `terraform plan` first to
  confirm only the two intended resources change; `make lint`/`terraform fmt`
  before commit (pre-commit hook).
- **[Tunnel ingress order]** the `ssh` entry must precede the `http_status:404`
  catch-all or it is unreachable → the config places hostnames before the
  catch-all; verify in `terraform plan`.
- **[Node port conflict on reinstall]** if 30022 is ever taken by another app,
  the NodePort fails to allocate → k3s allocates only on demand today; revisit if
  collisions appear.

## Migration Plan

1. Edit `clusters/pk3s/forgejo/helmrelease.yaml`: `service.ssh.type: NodePort` +
   `nodeport: 30022`; add `server.SSH_DOMAIN` / `SSH_PORT`.
2. Validate the rendered chart (`helm template`) to confirm the ssh Service
   becomes a NodePort at 30022 and the config keys land in `app.ini`.
3. Edit Terraform: add the `ssh.fgit.watchtoken.org` →
   `ssh://forgejo-ssh.forgejo.svc:22` ingress entry in `terraform/tunnel.tf`
   (before the catch-all) and the `ssh` CNAME in `terraform/dns.tf`. Run
   `terraform fmt`, `make lint`, then `terraform plan` (expect only these two
   resources added) and `terraform apply`.
4. Commit (Forgejo HelmRelease + Terraform); push. Flux reconciles the HelmRelease.
5. **(Out-of-band, per client)** install `cloudflared`; add the SSH
   `ProxyCommand` block for `ssh.fgit.watchtoken.org`.
6. Verify: LAN (`ssh -p 30022`) and public (`ssh git@ssh.fgit.watchtoken.org`)
   both show the Forgejo greeting; a real clone/push round-trips.
7. Update `AGENTS.md` with the new SOP.

**Rollback:** revert the commit (Flux returns `service.ssh` to `ClusterIP`;
`terraform apply` removes the ingress entry + CNAME). No persistent state was
added in-cluster.

## Open Questions

- Whether `START_SSH` must be set explicitly. It defaults to enabled (the ssh
  Service is rendered), so it should not — confirmed during apply by checking the
  pod is listening on 2222.
