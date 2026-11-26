# Networking: ingress, TLS, tunnel, DNS

## Request paths

| Path | Route | TLS |
|---|---|---|
| **LAN** `*.local` | `/etc/hosts` → `http://192.168.254.50:30080` → Traefik `web` | none (plain HTTP) |
| **Public web** (`*.watchtoken.org`, `*.alacaba.org`) | Cloudflare edge → Tunnel → `https://traefik.traefik.svc:443` (No TLS Verify) → Traefik `websecure` | Cloudflare edge plus Traefik |
| **Public SSH** `ssh.watchtoken.org` | Tunnel → `forgejo-ssh.forgejo.svc:22` (raw TCP, skips Traefik) | — |
| **LAN SSH** | `ssh://git@192.168.254.50:30022` (NodePort) | — |
| **Media for friends** | Pangolin VPS, not Cloudflare ([pangolin.md](pangolin.md)) | at the VPS |

Tunnel hostnames are set in Terraform (`terraform/tunnel.tf`, plus CNAMEs in `terraform/dns.tf`):
`alacaba.org`, `cv.alacaba.org`, `cv.watchtoken.org`, `fgit.watchtoken.org`, `ssh.watchtoken.org`,
`sync.watchtoken.org`, `budget.watchtoken.org` and `windshift.watchtoken.org`.
Any other public request gets a 404 from the tunnel. To publish an app, add its hostname there
(see [terraform.md](terraform.md)) as well as its IngressRoute.

## Traefik

- The chart is in `clusters/pk3s/traefik/` (versions in [inventory.md](inventory.md)), NodePort
  30080 (`web`) and 30443 (`websecure`).
- `providers.kubernetesCRD.allowCrossNamespace: true`, so any IngressRoute can use Services and
  Middlewares in other namespaces.
- The service type is set with `service.spec.type: LoadBalancer`. The old `service.type` key was
  never read (it only seemed to work because `LoadBalancer` is the default), and chart 43 and later
  reject it in the values schema.
- The Traefik and Hub CRDs ship in the chart's `crds/`, so the HelmRelease sets
  `install/upgrade.crds: CreateReplace`. The 41.4.0 → 43.0.0 upgrade (2026-11-26) only added CRD
  fields. Gateway API isn't used (no CRDs, provider off). Rollback means reverting the commit; the
  newer CRDs only add fields, which older versions ignore.
- `svclb-traefik` is the only DaemonSet that skips the media node. That's fine, because LAN
  traffic enters through the master's NodePort.

## TLS

- **`*.watchtoken.org`:** a wildcard `Certificate` in the `traefik` namespace (cert-manager,
  Let's Encrypt DNS-01 through Cloudflare) wired to the `default` TLSStore. An IngressRoute only
  needs `entryPoints: [websecure]` and `tls: {}`, with no per-route `secretName`.
- **The `alacaba.org` domains are not in the default TLSStore.** Their websecure routes must set
  `tls.secretName: cv-alacaba-org-tls` explicitly (Certificate `cv-alacaba-org` in `cv-datastar`,
  covering `alacaba.org` and `cv.alacaba.org`). It's issued with DNS-01 using the alacaba Cloudflare
  token.
- **Tunnel origin is `https://traefik.traefik.svc:443` with No TLS Verify.** The cert is for
  `*.watchtoken.org`, but cloudflared connects to `traefik.traefik.svc`, so strict verification
  fails with a 502. The hop is still encrypted.
- **cert-manager CRD bootstrap takes two passes.** If `ClusterIssuer`/`Certificate` objects are in
  the same Flux pass that installs cert-manager, the dry-run fails (`no matches for kind
  "Certificate"`) before cert-manager installs, and it never recovers. For a fresh install, deploy
  cert-manager without those objects, wait for the CRDs, then add them back (see the
  `cert-manager/` history).

## Redirects

- **Redirect HTTP to HTTPS per host, not globally.** Don't use `ports.web.redirections.entryPoint`:
  it would send `*.local` to HTTPS, where there is no cert or route. Attach the shared
  `redirect-to-https` Middleware (in the `traefik` namespace) only to public routes on `web`.
- **Cloudflare upgrades public HTTP first.** Both zones have `always_use_https = on`
  (`terraform/zone-settings.tf`), so public `http://` gets a 301 at the edge before it reaches
  Traefik. Traefik's redirect only handles LAN or direct connections (port 30080 with a public
  `Host` header). Redirects from public HTTP therefore take two hops.

## Limits and rules

- **Tunnel upload limit is about 100 MB** on Cloudflare's free tier. Large uploads fail on public
  hostnames (for example `sync.watchtoken.org`) but work on the LAN hostname.
- **Never send video through Cloudflare.** The media DNS records (the `watchtoken.org` apex,
  `seerr`, `pangolin`) are `proxied = false` and point at the Pangolin VPS. Proxying them, or
  adding a stray wildcard A record, would put streaming through Cloudflare, which breaks their ToS
  §2.8.
- **Public SSH skips Traefik.** It's set up in `terraform/tunnel.tf`. Don't add a Traefik TCP
  entryPoint for it.
- **Apps that need HTTPS have no LAN route.** Windshift (CORS rejects plain-HTTP origins) is reached
  on LAN through its public HTTPS hostname.
- **Some apps are LAN-only on purpose.** Don't add tunnel or DNS entries for `koito.*` or
  `scrobbler.*` (they have no auth), or for the `*.local` media apps.
