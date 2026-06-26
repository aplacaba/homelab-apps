## ADDED Requirements

### Requirement: Forgejo SSH reachable on the LAN
Forgejo git-over-SSH MUST be reachable directly from the LAN via the node's
  NodePort, without any client-side proxy tooling.

#### Scenario: LAN SSH clone
- **WHEN** a user on the LAN runs `ssh -T -p 30022 git@192.168.254.50`
- **THEN** Forgejo responds with its SSH greeting, and
  `git clone ssh://git@192.168.254.50:30022/<owner>/<repo>.git` succeeds.

### Requirement: Forgejo SSH reachable publicly via Cloudflare Tunnel
Forgejo git-over-SSH MUST be reachable from the public internet through the
  Cloudflare Tunnel, tunnel-only (no opened router ports), using a dedicated
  subdomain and client-side `cloudflared`. The tunnel route and DNS MUST be
  managed in Terraform (`terraform/tunnel.tf` ingress + `terraform/dns.tf`
  CNAME), routing the tunnel straight to `forgejo-ssh` (not via Traefik).

#### Scenario: Public SSH clone
- **WHEN** a client with `cloudflared` configured runs
  `ssh -T git@ssh.fgit.watchtoken.org`
- **THEN** the connection is proxied through the tunnel to the Forgejo SSH
  service, Forgejo responds with its greeting, and a clone/push round-trips.

#### Scenario: Terraform-managed route
- **WHEN** the public route is provisioned
- **THEN** `terraform/tunnel.tf` contains an ingress entry
  `ssh.fgit.watchtoken.org` → `ssh://forgejo-ssh.forgejo.svc:22` (before the
  catch-all) and `terraform/dns.tf` contains a proxied `ssh` CNAME to the
  tunnel, with no Cloudflare dashboard changes required.

### Requirement: Dedicated public SSH hostname
Public SSH MUST use a dedicated hostname (`ssh.fgit.watchtoken.org`) routed to
  `ssh://forgejo-ssh.forgejo.svc:22`, leaving the HTTPS hostname
  (`fgit.watchtoken.org` → Traefik) untouched.

#### Scenario: Independent web and SSH ingress
- **WHEN** `fgit.watchtoken.org` is accessed over HTTPS
- **THEN** it still routes to Traefik as before, and SSH is served only via
  `ssh.fgit.watchtoken.org` through the tunnel.

### Requirement: Correct SSH clone URL in the Forgejo UI
Forgejo MUST advertise `ssh.fgit.watchtoken.org` as the SSH domain (default
  port 22) so the clone-URL widget renders a working public SSH URL.

#### Scenario: UI clone URL
- **WHEN** viewing a repository in the Forgejo UI
- **THEN** the SSH clone URL shown is
  `git@ssh.fgit.watchtoken.org:<owner>/<repo>.git`.

### Requirement: No impact on HTTPS or other apps
The SSH change MUST NOT alter HTTPS access (public or `.local`), the wildcard
  TLS certificate, Traefik, the cloudflared pod, or any non-Forgejo app.

#### Scenario: Unaffected services
- **WHEN** the SSH change is applied
- **THEN** `https://fgit.watchtoken.org` and `forgejo.local` still return 200,
  the `*.watchtoken.org` cert is unchanged, and cert-manager/traefik/cloudflared
  pods are unchanged.
