## Why

The monitoring stack already collects a rich set of metrics (node-exporter,
kube-state-metrics, kubelet/cAdvisor, Traefik) and Grafana is running, but the
only dashboards are the ones kube-prometheus-stack ships by default. The cluster
has **no custom dashboards tailored to this homelab** — nothing for Traefik
request health, PVC/storage growth, Forgejo, or the Cloudflare Tunnel. Worse,
any dashboard someone does build lives only inside Grafana's database: there is
no reviewable, version-controlled source of truth, so a pod/PVC reset silently
loses them and there is no "what changed and why" history.

The same gap exists on the **metric-source** side for two of the apps this homelab
depends on: Forgejo does not expose Prometheus metrics, and cloudflared exposes
them on `:2000` but nothing scrapes that port. Dashboards for those two would be
empty.

## What Changes

- **New Terraform root module at `terraform/grafana/`** (separate S3 state key
  `grafana/terraform.tfstate`, isolated from the existing Cloudflare state) that
  manages Grafana dashboards as code via the `grafana/grafana` provider:
  - **Self-bootstrapped service account**: Terraform creates a dedicated
    `terraform` service account + token. First `apply` authenticates with the
    Grafana admin password (supplied via a local env var, never committed);
    subsequent applies can use the token Terraform created.
  - **"Homelab" folder** containing seven custom dashboards authored as JSON
    files in the repo (`terraform/grafana/dashboards/*.json`). Managed
    dashboards reconcile back to the repo on every apply (`overwrite = true`) —
    manual UI edits are reverted on the next apply, so the repo is the single
    source of truth. Each dashboard pins the Prometheus datasource **by UID**
    (the UID kube-prometheus-stack assigns) so dashboards survive name changes.
- **Two new Prometheus metric sources** so all seven dashboards have data:
  - **Forgejo**: enable metrics in `gitea.config.metrics` and add a
    `ServiceMonitor` (`clusters/pk3s/forgejo/`).
  - **cloudflared**: add a metrics `Service` (port 2000) and a `ServiceMonitor`
    (`clusters/pk3s/cloudflared/`). cloudflared already serves metrics on `:2000`
    via `--metrics 0.0.0.0:2000`; it just isn't scraped today.
- Prometheus auto-discovers the new ServiceMonitors because the stack already
  sets `serviceMonitorSelectorNilUsesHelmValues: false`
  (`clusters/pk3s/monitoring/helmrelease.yaml:47`). **No change to the
  monitoring HelmRelease.**
- The seven dashboards (folder: Homelab): **cluster-overview**, **nodes**
  (hardware), **pods-workloads**, **traefik**, **forgejo**, **storage-pvc**,
  **cloudflare-tunnel**.
- **Repo wiring**: `terraform/Makefile` `validate` runs in both terraform roots;
  `AGENTS.md` documents the new module, its auth/bootstrap and token-rotation
  SOP, and the two new metric sources.

## Capabilities

### New Capabilities
- `grafana-dashboards`: a version-controlled set of custom homelab Grafana
  dashboards (cluster, nodes, pods/workloads, Traefik, Forgejo, storage/PVC,
  Cloudflare tunnel), provisioned and reconciled by Terraform into a "Homelab"
  folder, with UI editing disabled so the repo is the single source of truth.
- `forgejo-metrics`: Forgejo exposes Prometheus metrics on its HTTP port and
  Prometheus scrapes them.
- `cloudflared-metrics`: Prometheus scrapes cloudflared's existing `:2000`
  metrics endpoint via a new Service.

### Modified Capabilities
<!-- None — no existing spec covers grafana/forgejo/cloudflared metrics. -->

## Impact

- **New:** `terraform/grafana/` (`providers.tf`, `variables.tf`, `bootstrap.tf`,
  `folders.tf`, `dashboards.tf`, `outputs.tf`, `dashboards/*.json` ×7).
- **New:** `clusters/pk3s/forgejo/servicemonitor.yaml`.
- **New:** `clusters/pk3s/cloudflared/service-metrics.yaml`,
  `clusters/pk3s/cloudflared/servicemonitor.yaml`.
- **Modified:** `clusters/pk3s/forgejo/helmrelease.yaml` — add
  `gitea.config.metrics.ENABLED`.
- **Modified:** `clusters/pk3s/forgejo/kustomization.yaml`,
  `clusters/pk3s/cloudflared/kustomization.yaml` — reference new resources.
- **Modified:** `terraform/Makefile` — `validate` iterates both terraform roots.
- **Modified:** `AGENTS.md` — document the grafana module, auth/bootstrap SOP,
  the two new metric sources, and the directory structure.
- **Out-of-band (operator, one-time):** supply Grafana admin password via
  `GRAFANA_AUTH=admin:<password>` for the first `terraform apply` in
  `terraform/grafana/`; then switch `GRAFANA_AUTH` to the emitted token. No
  secrets enter git or chat.
- **No impact** on the Cloudflare Terraform state, the wildcard cert, Traefik,
  cert-manager, vaultwarden, cv-datastar, the forgejo-runner, sealed-secrets, or
  the existing Cloudflare tunnel routing. Grafana datasources (Prometheus, Loki)
  remain defined in the monitoring HelmRelease.
