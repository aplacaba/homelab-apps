# Small apps

Apps that need only a few notes. Bigger apps have their own doc (see the
[guide](AGENT_INSTRUCTIONS.md#where-to-look-next)). Versions are in [inventory.md](inventory.md).

## actual-budget

Actual Budget, a personal finance app. Raw manifests, LAN `budget.local`, public
`budget.watchtoken.org`. The SQLite DB and user files are on one 2Gi `local-path` PVC
(`actual-budget-data`, mounted at `/data`) with reclaim `Delete`, so removing the app from the root
kustomization deletes the budget. Actual's own **Settings → Export data** is the way to get a copy
off the cluster. Run it before any destructive change.

## cv-datastar

The CV site, from the chart built in `~/Projects/cv-datastar` and pushed to the Forgejo OCI
registry ([patterns.md](patterns.md#charts-from-the-forgejo-oci-registry)).

- `alacaba.org` serves the landing page at `/` and the CV at `/cv/`. `cv.alacaba.org` and
  `cv.watchtoken.org` return a 301 to `alacaba.org/cv`. LAN `cv.local`.
- The `alacaba.org` routes pin `tls.secretName: cv-alacaba-org-tls` (Certificate `cv-alacaba-org` in
  this namespace). The `cv-datastar-apex` IngressRoute also serves public HTTP, because the tunnel
  origin skips TLS verification, so the cert only has to be valid for browsers.
- The CI runner builds the image. Its workflow does a `docker login` inside a `run:` step
  ([forgejo.md](forgejo.md#ci-runner)).
- Release and monitoring commands: [cv-datastar-commands.md](cv-datastar-commands.md).

## floci

The FLOCI tool, raw manifests, image `floci/floci` pinned to an exact tag (it was `:latest` until
2026-11-26), with a 5Gi PVC. LAN `floci.local`.

## watcharr

A media watch list and tracker. Raw manifests, SQLite on a 5Gi PVC (`watcharr-data`). LAN
`watcharr.local`.

## pve (Proxmox VE UI proxy)

A Traefik route from `https://pve.local` to Proxmox at `192.168.254.165:8006`. Raw manifests, no
workload.

- **Connection to Proxmox:** Traefik checks Proxmox's certificate against the Proxmox cluster CA,
  stored in the `pve/sealedsecret-pve-ca.yaml` SealedSecret. It sets `serverName: homelab.pve`,
  because the node certificate's SAN doesn't include the IP. If the Proxmox CA or node certificate
  is regenerated, re-seal `/etc/pve/pve-root-ca.pem` straight from the Proxmox host and let Flux
  reconcile. Never commit the plaintext CA.
- **Connection from your browser:** cert-manager issues a self-signed `pve-local-tls` for
  `pve.local`, and the HTTP route redirects to HTTPS. Clients have to trust that certificate or
  accept the browser warning. It's separate from the Proxmox CA.

## flux-dashboard

The Flux Operator web UI (`flux-operator:9080`), raw manifests, LAN `fluxops.local`.
