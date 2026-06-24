# Cloudflare IaC with Terraform

## Summary

Move all Cloudflare-managed infrastructure (DNS zones, tunnel, tunnel config,
API tokens) from manual Zero Trust dashboard config into Terraform. Terraform
runs locally or in CI and bridges into the existing Flux GitOps workflow by
committing SealedSecret YAMLs for sensitive outputs (tunnel token, API tokens).

## Architecture

```
┌────────────────────────────────────────┐
│ Terraform (local/CI)                   │
│  cloudflare_zone                       │
│  cloudflare_record                     │
│  cloudflare_tunnel                     │
│  cloudflare_tunnel_config              │
│  cloudflare_api_token                  │
│                                        │
│  Outputs (sensitive):                  │
│   → tunnel_token                       │
│   → watchtoken_api_token               │
│   → alacaba_api_token                  │
└────────────┬───────────────────────────┘
             │ seal-and-commit.sh:
             │ terraform output -raw | kubeseal → SealedSecret YAML
             │ writes to clusters/pk3s/<app>/sealedsecret-*.yaml
             │ git add + git push
             ▼
┌────────────────────────────────────────┐
│ GitHub (homelab-apps repo)             │
│  terraform/                            │
│  clusters/pk3s/cloudflared/            │
│    └── sealedsecret-tunnel-token.yaml  │ ← from TF
│  clusters/pk3s/cert-manager/           │
│    └── sealedsecret-*-api-token.yaml   │ ← from TF
└────────────┬───────────────────────────┘
             │ Flux syncs
             ▼
┌────────────────────────────────────────┐
│ k3s cluster                            │
│  cloudflared → tunnel-credentials      │
│  cert-manager → cloudflare-api-tokens  │
│  Traefik IngressRoutes                 │
└────────────────────────────────────────┘
```

### Key principles

- **Terraform owns Cloudflare**: DNS, tunnel, tunnel ingress rules, API tokens.
  All changes go through `terraform apply` — never the Zero Trust dashboard.
- **Flux owns k8s**: The cloudflared deployment, cert-manager, SealedSecrets.
  All changes go through git commits — never `kubectl` directly.
- **Bridge is committed YAML**: Terraform writes SealedSecret YAMLs to the repo.
  No secrets in plaintext; no kubeseal CLI calls needed in CI after initial setup.

## Terraform Structure

New root-level `terraform/` directory:

```
terraform/
├── providers.tf           # cloudflare provider, R2 backend
├── backend.tf             # Remote state in R2 (S3-compatible)
├── main.tf                # Variables, locals, random_password for tunnel
├── dns.tf                 # Zone + DNS records for both domains
├── tunnel.tf              # Tunnel resource + tunnel_config (ingress rules)
├── tokens.tf              # cloudflare_api_token resources
├── outputs.tf             # Sensitive outputs
├── scripts/
│   └── seal-and-commit.sh # TF outputs → kubeseal → YAML → git commit
└── .terraform-version     # Pinned Terraform version
```

### providers.tf

```hcl
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.21"
    }
  }
  backend "s3" {
    bucket                      = "homelab-tfstate"
    key                         = "cloudflare/terraform.tfstate"
    region                      = "auto"
    endpoint                    = "https://<account-id>.r2.cloudflarestorage.com"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

### dns.tf

Import existing zones, then declare records:

```hcl
data "cloudflare_zones" "watchtoken_org" {
  filter { name = "watchtoken.org" }
}

data "cloudflare_zones" "alacaba_org" {
  filter { name = "alacaba.org" }
}

resource "cloudflare_record" "cv_watchtoken" {
  zone_id = data.cloudflare_zones.watchtoken_org.zones[0].id
  name    = "cv"
  value   = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "fgit_watchtoken" {
  zone_id = data.cloudflare_zones.watchtoken_org.zones[0].id
  name    = "fgit"
  value   = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "vault_watchtoken" {
  zone_id = data.cloudflare_zones.watchtoken_org.zones[0].id
  name    = "vault"
  value   = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "cv_alacaba" {
  zone_id = data.cloudflare_zones.alacaba_org.zones[0].id
  name    = "cv"
  value   = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}
```

All public hostnames CNAME to the tunnel's internal hostname.

### tunnel.tf

```hcl
resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

# NOTE: We create a NEW tunnel rather than importing the existing one,
# because cloudflare_tunnel.secret is write-only — importing would lose
# the secret value and force recreation anyway. The old tunnel is deleted
# after the cutover (Phase 3).
resource "cloudflare_tunnel" "main" {
  account_id = var.cloudflare_account_id
  name       = "k3s-tunnel"
  secret     = random_password.tunnel_secret.result
}

resource "cloudflare_tunnel_config" "main" {
  tunnel_id  = cloudflare_tunnel.main.id
  account_id = var.cloudflare_account_id
  config {
    ingress_rule {
      hostname = "cv.alacaba.org"
      service  = "https://traefik.traefik.svc:443"
      origin_request { no_tls_verify = true }
    }
    ingress_rule {
      hostname = "cv.watchtoken.org"
      service  = "https://traefik.traefik.svc:443"
      origin_request { no_tls_verify = true }
    }
    ingress_rule {
      hostname = "fgit.watchtoken.org"
      service  = "https://traefik.traefik.svc:443"
      origin_request { no_tls_verify = true }
    }
    ingress_rule {
      hostname = "vault.watchtoken.org"
      service  = "https://traefik.traefik.svc:443"
      origin_request { no_tls_verify = true }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}
```

### tokens.tf

```hcl
resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.*watchtoken.org" = "*"
    }
  }
}

resource "cloudflare_api_token" "cert_manager_alacaba" {
  name = "cert-manager-alacaba-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.*alacaba.org" = "*"
    }
  }
}
```

### outputs.tf

```hcl
output "tunnel_token" {
  value     = cloudflare_tunnel.main.tunnel_token
  sensitive = true
}

output "watchtoken_api_token" {
  value     = cloudflare_api_token.cert_manager_watchtoken.value
  sensitive = true
}

output "alacaba_api_token" {
  value     = cloudflare_api_token.cert_manager_alacaba.value
  sensitive = true
}
```

### seal-and-commit.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Tunnel token → cloudflared/tunnel-credentials
TOKEN=$(terraform output -raw tunnel_token)
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tunnel-credentials\n  namespace: cloudflared\ntype: Opaque\nstringData:\n  token: %%s\n' "$TOKEN" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace cloudflared \
  > "$REPO_ROOT/clusters/pk3s/cloudflared/sealedsecret-tunnel-token.yaml"

# watchtoken API token → cert-manager
WATCHTOKEN_TOKEN=$(terraform output -raw watchtoken_api_token)
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: %%s\n' "$WATCHTOKEN_TOKEN" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace cert-manager \
  > "$REPO_ROOT/clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml"

# alacaba API token → cert-manager
ALACABA_TOKEN=$(terraform output -raw alacaba_api_token)
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-alacaba-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: %%s\n' "$ALACABA_TOKEN" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace cert-manager \
  > "$REPO_ROOT/clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml"

# Stage changes (GH Actions pushes via the workflow)
(cd "$REPO_ROOT" && git add clusters/pk3s/)
```

## GitHub Actions Workflow

### `.github/workflows/terraform-cloudflare.yml`

```yaml
name: Cloudflare Terraform

on:
  push:
    branches: [main]
    paths: ["terraform/**"]
  pull_request:
    branches: [main]
    paths: ["terraform/**"]
  workflow_dispatch:

jobs:
  terraform:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GH_PAT }}  # PAT so the commit triggers Flux sync

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.15.6

      - name: Install kubeseal
        run: |
          wget -q https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.1/kubeseal-linux-amd64
          install -m 755 kubeseal-linux-amd64 /usr/local/bin/kubeseal

      - name: Terraform init
        working-directory: terraform
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
        run: terraform init

      - name: Terraform plan
        working-directory: terraform
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          TF_VAR_cloudflare_account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
        run: terraform plan

      - name: Terraform apply
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        working-directory: terraform
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          TF_VAR_cloudflare_account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
        run: terraform apply -auto-approve

      - name: Seal and commit secrets
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        env:
          KUBESEAL_CERT: ${{ secrets.KUBESEAL_CERT }}
        run: |
          # Write the cert (stored as GH secret) to a temp file
          echo "$KUBESEAL_CERT" > /tmp/sealed-secrets-cert.pem

          # Tunnel token
          TOKEN=$(terraform -chdir=terraform output -raw tunnel_token)
          printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tunnel-credentials\n  namespace: cloudflared\ntype: Opaque\nstringData:\n  token: %s\n' "$TOKEN" \
            | kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
            > clusters/pk3s/cloudflared/sealedsecret-tunnel-token.yaml

          # watchtoken API token
          WATCHTOKEN_TOKEN=$(terraform -chdir=terraform output -raw watchtoken_api_token)
          printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: %s\n' "$WATCHTOKEN_TOKEN" \
            | kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
            > clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml

          # alacaba API token
          ALACABA_TOKEN=$(terraform -chdir=terraform output -raw alacaba_api_token)
          printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-alacaba-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: %s\n' "$ALACABA_TOKEN" \
            | kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
            > clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml

      - name: Commit and push
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        run: |
          git config user.name "terraform-cloudflare-bot"
          git config user.email "bot@alacaba.org"
          git add clusters/pk3s/
          if ! git diff --cached --quiet; then
            git commit -m "chore: update Cloudflare secrets from Terraform"
            git push
          else
            echo "No changes to commit"
          fi
```

### Required GitHub Secrets

| Secret | Source | Used by |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | Your Cloudflare dashboard — needs Zone:Read, DNS:Edit, Tunnel:Edit, API Tokens:Write for both zones | Terraform provider |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard → API Tokens → Account ID | Terraform `cloudflare_tunnel` + `cloudflare_api_token` |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 → Manage R2 API Tokens → Create | Terraform state backend (S3-compatible) |
| `R2_SECRET_ACCESS_KEY` | Same R2 token creation | Terraform state backend |
| `KUBESEAL_CERT` | Export from cluster: `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --fetch-cert \| base64` | Offline sealing (no cluster access needed in CI) |
| `GH_PAT` | GitHub → Settings → Developer settings → Personal access tokens — needs `contents: write` on this repo | Workflow pushes back sealed secrets. A PAT is needed instead of the default `GITHUB_TOKEN` because the commit must trigger Flux's webhook. |

### Why GH_PAT instead of GITHUB_TOKEN?

The default `GITHUB_TOKEN` commits don't trigger subsequent workflow runs or
push events. Flux relies on GitHub webhooks (push events) to detect changes.
A PAT ensures the commit from the workflow triggers a push event, which
Flux picks up.

## Security Considerations

### Secret sensitivity tiers

| Tier | Secrets | Exposure if leaked |
|---|---|---|
| **Public** | `CLOUDFLARE_ACCOUNT_ID`, `KUBESEAL_CERT` | No impact |
| **Scoped** | `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `GH_PAT` | Limited to one R2 bucket / one repo |
| **Powerful** | `CLOUDFLARE_API_TOKEN` (bootstrap) | Full DNS + tunnel + token management |

### Mitigations

**CLOUDFLARE_API_TOKEN** is the highest-value target:
- Scope it to specific zones (`watchtoken.org` + `alacaba.org`) rather than all zones
- Restrict permissions to exactly what Terraform needs: Zone:Read, DNS:Edit, Tunnel:Edit, API Tokens:Write
- It's only used during the `terraform apply` step — once Terraform creates the dedicated `cert_manager_*` tokens via `cloudflare_api_token` resources, you can revoke the bootstrap token and Terraform will manage itself via the tokens it created
- GitHub Actions masks this value in logs automatically

**R2 access keys:**
- Scope to a single bucket (`homelab-tfstate`)
- Enable bucket versioning so a corrupted state file can be rolled back

**SealedSecrets (the outputs):**
- Only the public encryption key is stored in GitHub (`KUBESEAL_CERT`)
- The private decryption key lives exclusively in the k3s cluster's `sealed-secrets` namespace
- Even with full GitHub access, nobody can read the tunnel token or API tokens from the committed SealedSecret YAMLs

**Runner ephemerality:**
- GitHub-hosted runners are single-use VMs destroyed after each job
- No secrets persist between runs
- The runner can only access env vars of secrets you've explicitly configured

### Supply chain risk

The workflow installs `kubeseal` via `wget` from GitHub Releases (TLS, verified URL). Still, pinning action versions to SHA commit hashes adds defense:

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

## Migration Plan

### Prerequisite: Create R2 bucket for state

Terraform remote state lives in an R2 bucket. Create it manually before init:

```bash
# One-time: create the bucket via AWS CLI (S3-compatible)
aws s3api create-bucket --bucket homelab-tfstate --region auto \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

### Phase 1: Import existing state

```bash
cd terraform
terraform init

# Import zones
terraform import cloudflare_zone.watchtoken_org <zone_id>
terraform import cloudflare_zone.alacaba_org <zone_id>

# Import DNS records
terraform import cloudflare_record.cv_watchtoken <zone_id>/<record_id>
terraform import cloudflare_record.fgit_watchtoken <zone_id>/<record_id>
terraform import cloudflare_record.vault_watchtoken <zone_id>/<record_id>
terraform import cloudflare_record.cv_alacaba <zone_id>/<record_id>

# Do NOT import existing tunnel — we create a new one (see tunnel.tf note).
```

After each import, run `terraform plan` to verify zero unexpected changes.

### Phase 2: Initial apply + seed secrets

```bash
terraform apply    # Creates new API tokens, updates tunnel config
./scripts/seal-and-commit.sh
```

This commits new SealedSecrets to the repo. Flux picks them up. The cloudflared
deployment needs a rolling restart to pick up the new tunnel token (the old token
remains valid until explicitly revoked, so no downtime).

### Phase 3: Remove old SealedSecrets

After verifying Terraform-owned tokens work:
- Remove the old `sealedsecret-cloudflare-api-token.yaml` from git
- Remove `sealedsecret-cloudflare-alacaba-api-token.yaml` from git (if manually created before)
- Revoke old tokens in Cloudflare dashboard

### Phase 4: Remove manual config

- Remove public hostname config from Zero Trust dashboard (Terraform now owns
  `cloudflare_tunnel_config`)
- No more manual dashboard edits going forward

## Out of Scope

- **Cloudflare Workers / Pages**: Not in use; add later if needed.
- **WAF rules / Firewall**: Not currently configured; add later if needed.
- **Flux reconciliation changes**: No changes needed — Flux already syncs
  the entire `clusters/pk3s/` directory.
- **AGENTS.md updates**: Document the Terraform workflow after implementation.

## Remaining Manual Steps

- `terraform import` for all existing resources (Phase 1)
- Initial `terraform apply` + `seal-and-commit.sh` run (Phase 2)
- Rolling restart of cloudflared after new tunnel token propagates
- Remove old Zero Trust dashboard config (Phase 4)
