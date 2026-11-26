# Pangolin media relay

Friends (about 10 users) reach the media stack through a self-hosted Pangolin CE instance on a
Hetzner VPS (Falkenstein, Debian 13, 2 vCPU/4GB, `root@178.105.27.201`), **not** through the
Cloudflare Tunnel. That keeps video streaming within Cloudflare's ToS and avoids the roughly
100 MB upload limit. TLS ends at the VPS (wildcard `*.watchtoken.org` plus the apex, Let's Encrypt
DNS-01 with a scoped Cloudflare token). Transcoding still happens at home (B580 QSV).

| Hostname | App | Auth | Backend |
|---|---|---|---|
| `watchtoken.org` (apex) | Jellyfin | Jellyfin users (no Pangolin auth) | `http://jellyfin.media.svc:8096` |
| `seerr.watchtoken.org` | seerr | Pangolin SSO → Jellyfin SSO | `http://seerr.media.svc:5055` |
| `pangolin.watchtoken.org` | Pangolin dashboard | admin + MFA | — |

## Cluster side: the newt agent

The `pangolin` namespace runs the `fossorial/newt` chart (versions in
[inventory.md](inventory.md)), pinned to `k3s-master` because the media node's memory budget is
tight. Credentials are a SealedSecret (`newt-auth`). It connects **out** over WireGuard, so no
ports are open at home.

- `disableSSH: true`, because newt 1.13 and later start a built-in SSH server by default and only
  HTTP resources are tunnelled.
- Chart 1.6.0 and later ship no default resources, so requests and limits are set per instance.
  There's **no CPU limit**, because throttling quietly slows the WireGuard path.
- Upgraded from 1.12.3 on 2026-11-26 (the VPS runs Pangolin server 1.21.1). Rollback means
  reverting the commit (chart 1.4.0 / newt 1.12.3). The tunnel holds no state.
- Next: newt 1.20.1 moves the main tunnel to netstack2 with gVisor RACK off, which fixes download
  stalls after packet loss. Adopt it with a chart bump or `image.tag` once the chart catches up.

## VPS side (not managed by GitOps)

- **Config and the SQLite DB** are in `/opt/pangolin`. The `pangolin-backup` systemd timer on the
  master pulls them weekly with rsync to `/home/backups/pangolin` (Sun 02:30). To rebuild:
  reinstall with the installer and restore the dir. newt reconnects by itself, and nothing changes
  on the cluster side because its credentials stay the same.
- **Wildcard cert is set up in the config files, not the dashboard** (the installer manages the
  domain in files):
  - In `config/traefik/traefik_config.yml`, a DNS-01 resolver (`cloudflare` provider) replaces
    HTTP-01.
  - The traefik container has the `CLOUDFLARE_DNS_API_TOKEN` env var.
  - `config/config.yml` sets `prefer_wildcard_cert: true` on `domains.domain1`.
  - The dashboard router's `tls.domains` SAN (`watchtoken.org` + `*.watchtoken.org`) is what
    triggers issuance.
- **CrowdSec** runs on the VPS (installed with `--crowdsec`). Residential IPs sometimes have a bad
  reputation and get friends blocked. Unblock and whitelist from `/opt/pangolin`:
  ```bash
  docker compose exec crowdsec cscli decisions delete --ip <ip>
  docker compose exec crowdsec cscli decisions add --ip <ip> --duration 999999h --type whitelist
  ```
- **Region:** the VPS is in Falkenstein, not Singapore as first planned. That's fine for friends in
  Europe and North America, while friends in Southeast Asia get more latency. This was accepted and
  recorded 2026-08-22.

## DNS must stay gray-clouded

The `watchtoken.org` apex and the `seerr` and `pangolin` A records are `proxied = false` in
`terraform/dns.tf`. Never switch them to proxied, and never add a wildcard A record. Either one
would send video through Cloudflare, which breaks ToS §2.8 at 4–6 concurrent streams.

## Emergency stopgap

If the VPS dies:

1. Point the apex record at `cfargotunnel.com` (Cloudflare flattens apex CNAMEs).
2. Add a tunnel ingress for jellyfin. This is a temporary ToS gray area.
3. Keep seerr offline until the VPS is rebuilt from the backup.
