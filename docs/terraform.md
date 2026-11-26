# Terraform

Terraform covers what is outside the cluster: Cloudflare and Grafana dashboards.

```
terraform/
├── providers.tf        # Cloudflare provider + S3 (R2) backend
├── main.tf             # tunnel and variables
├── tunnel.tf           # tunnel ingress (public hostnames → Traefik / forgejo-ssh)
├── dns.tf              # DNS records (media records stay proxied = false)
├── zone-settings.tf    # zone security settings (always_use_https, …)
├── tokens.tf           # cert-manager API tokens
├── outputs.tf
├── Makefile            # lint, fmt-check, validate (both roots)
├── scripts/            # import.sh, seal-and-commit.sh
└── grafana/            # Grafana dashboards (separate root, local state)
```

## Cloudflare: applied in CI

**Applies run in CI, not locally.** `.github/workflows/terraform-cloudflare.yml` runs init,
validate and plan on pull requests, and `terraform apply -auto-approve` on every push to `main`
that touches `terraform/**`. The Cloudflare token, account ID and R2 state-backend credentials are GitHub
secrets. Once a `.tf` change is merged, it is applied. Locally you only need to lint:

```bash
cd terraform && make lint        # or: terraform fmt -check -diff
make install-hooks               # one-time; .githooks/pre-commit checks fmt on staged .tf files
```

Notes:

- To publish an app, add its tunnel hostname in `tunnel.tf` and its CNAME in `dns.tf`. The tunnel
  sends anything it doesn't know to `http_status:404`. See [networking.md](networking.md).
- The `watchtoken.org` apex and the `seerr` and `pangolin` records must stay `proxied = false`
  ([pangolin.md](pangolin.md)).

## Grafana dashboards

Dashboards are managed with Terraform from `terraform/grafana/`. State is local
(`terraform/grafana/terraform.tfstate`, not in S3), and this root is applied **by hand**, not by
CI. Dashboards are JSON files in `terraform/grafana/dashboards/`. Edit them in the repo, because
UI edits are overwritten on the next apply (`overwrite = true`).

Auth comes from env vars, and nothing is committed:

- `GRAFANA_URL=http://grafana.local:30080`
- `GRAFANA_AUTH`: for the first apply, `admin:<admin-password>` (the password from the
  `grafana-admin-secret` SealedSecret, kept in the password manager). That apply creates a
  `terraform` service account and token and records them in state. After that, use
  `terraform output -raw grafana_token`.

Rotating the token (if it's lost or needs changing):

```bash
cd terraform/grafana
GRAFANA_AUTH=admin:<admin-password> terraform apply -replace=grafana_service_account_token.terraform
terraform output -raw grafana_token   # new token
```

Where the dashboards get their metrics: [monitoring.md](monitoring.md#metric-sources-for-the-custom-dashboards).
