# Cloudflare IaC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all Cloudflare infrastructure (DNS, tunnel, tunnel config, API tokens) from manual Zero Trust dashboard config into Terraform, running via GitHub Actions.

**Architecture:** Terraform declares Cloudflare resources; sensitive outputs (tunnel token, API tokens) are piped through `kubeseal` and committed as SealedSecret YAMLs to this repo. Flux syncs them into the cluster. A GitHub Actions workflow runs `terraform apply` on pushes to `terraform/**` on main, then commits the sealed secrets back.

**Tech Stack:** Terraform 1.15.x, Cloudflare provider ~> 5.21, kubeseal 0.38.1, GitHub Actions, R2 (state backend)

---

### Task 1: Create Terraform directory structure and provider config

**Files:**
- Create: `terraform/.terraform-version`
- Create: `terraform/providers.tf`
- Create: `terraform/backend.tf`
- Create: `terraform/main.tf`

- [ ] **Create `.terraform-version`**

```text
1.15.6
```

- [ ] **Create `providers.tf`**

```hcl
terraform {
  required_version = ">= 1.9"
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

Replace `<account-id>` with your Cloudflare account ID.

- [ ] **Create `main.tf`**

```hcl
variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:Read, DNS:Edit, Tunnel:Edit, API Tokens:Write"
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (visible in dashboard URL)"
}

locals {
  tunnel_service = "https://traefik.traefik.svc:443"
}
```

- [ ] **Commit**

```bash
git add terraform/
git commit -m "feat: add Terraform directory structure and provider config"
```

---

### Task 2: Write DNS config

**Files:**
- Create: `terraform/dns.tf`

- [ ] **Create `dns.tf`**

```hcl
# ── Zones (resolved at plan time via Cloudflare API) ──────────────────────

data "cloudflare_zone" "watchtoken_org" {
  name = "watchtoken.org"
}

data "cloudflare_zone" "alacaba_org" {
  name = "alacaba.org"
}

# ── DNS Records ────────────────────────────────────────────────────────────

resource "cloudflare_dns_record" "cv_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "cv"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "fgit_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "fgit"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "vault_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "vault"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "cv_alacaba" {
  zone_id = data.cloudflare_zone.alacaba_org.id
  name    = "cv"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}
```

- [ ] **Commit**

```bash
git add terraform/dns.tf
git commit -m "feat: add DNS zone data sources and record resources"
```

---

### Task 3: Write tunnel config

**Files:**
- Create: `terraform/tunnel.tf`

- [ ] **Create `tunnel.tf`**

```hcl
resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

# New tunnel — not importing the existing one because the secret is write-only.
# After apply, update cloudflared to use the new token, then delete the old tunnel.
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
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "cv.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "fgit.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "vault.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}
```

- [ ] **Commit**

```bash
git add terraform/tunnel.tf
git commit -m "feat: add tunnel and tunnel_config resources"
```

---

### Task 4: Write API token config

**Files:**
- Create: `terraform/tokens.tf`

- [ ] **Create `tokens.tf`**

```hcl
# Tokens for cert-manager DNS-01 challenges.
# These replace the manually-created tokens currently managed as SealedSecrets.
resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.watchtoken_org.id}" = "*"
    }
  }
}

resource "cloudflare_api_token" "cert_manager_alacaba" {
  name = "cert-manager-alacaba-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.alacaba_org.id}" = "*"
    }
  }
}
```

- [ ] **Commit**

```bash
git add terraform/tokens.tf
git commit -m "feat: add cert-manager API token resources"
```

---

### Task 5: Write outputs and seal script

**Files:**
- Create: `terraform/outputs.tf`
- Create: `terraform/scripts/seal-and-commit.sh`

- [ ] **Create `outputs.tf`**

```hcl
output "tunnel_token" {
  value     = cloudflare_tunnel.main.tunnel_token
  sensitive = true
  description = "Token for cloudflared deployment"
}

output "watchtoken_api_token" {
  value     = cloudflare_api_token.cert_manager_watchtoken.value
  sensitive = true
  description = "API token for cert-manager DNS-01 on watchtoken.org"
}

output "alacaba_api_token" {
  value     = cloudflare_api_token.cert_manager_alacaba.value
  sensitive = true
  description = "API token for cert-manager DNS-01 on alacaba.org"
}
```

- [ ] **Create `scripts/seal-and-commit.sh`**

```bash
#!/usr/bin/env bash
# Seal Terraform sensitive outputs into SealedSecret YAMLs and commit to git.
# Usage: ./scripts/seal-and-commit.sh [--cert /path/to/cert.pem]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CERT="${1:-}"

if [ -z "$CERT" ]; then
  # Fetch from cluster
  KUBESEAL_ARGS="--controller-name sealed-secrets --controller-namespace sealed-secrets"
else
  KUBESEAL_ARGS="--cert $CERT"
fi

seal() {
  local name="$1" namespace="$2" key="$3" value="$4" output="$5"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n  %s: %%s\n' "$name" "$namespace" "$key" "$value" \
    | kubeseal $KUBESEAL_ARGS --format yaml --namespace "$namespace" \
    > "$REPO_ROOT/$output"
  echo "Sealed $output"
}

cd "$REPO_ROOT/terraform"

seal "tunnel-credentials" "cloudflared" "token" \
  "$(terraform output -raw tunnel_token)" \
  "clusters/pk3s/cloudflared/sealedsecret-tunnel-token.yaml"

seal "cloudflare-api-token" "cert-manager" "api-token" \
  "$(terraform output -raw watchtoken_api_token)" \
  "clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml"

seal "cloudflare-alacaba-api-token" "cert-manager" "api-token" \
  "$(terraform output -raw alacaba_api_token)" \
  "clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml"

cd "$REPO_ROOT"
git add clusters/pk3s/cloudflared/sealedsecret-tunnel-token.yaml \
       clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml \
       clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml
if ! git diff --cached --quiet; then
  echo "Sealed secrets staged. Run 'git commit && git push' to deploy."
else
  echo "No changes to seal."
fi
```

- [ ] **Make the script executable and commit**

```bash
chmod +x terraform/scripts/seal-and-commit.sh
git add terraform/outputs.tf terraform/scripts/
git commit -m "feat: add Terraform outputs and seal script"
```

---

### Task 6: Create GitHub Actions workflow

**Files:**
- Create: `.github/workflows/terraform-cloudflare.yml`

- [ ] **Create workflow file**

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
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          token: ${{ secrets.GH_PAT }}

      - uses: hashicorp/setup-terraform@8f3f96ceb4efcc05ba5c713ad60f9b66c6cdf3c7  # v3.1.2
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

      - name: Terraform validate
        working-directory: terraform
        run: terraform validate

      - name: Terraform plan
        working-directory: terraform
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          TF_VAR_cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          TF_VAR_cloudflare_account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
        run: terraform plan

      - name: Terraform apply
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        working-directory: terraform
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          TF_VAR_cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          TF_VAR_cloudflare_account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
        run: terraform apply -auto-approve

      - name: Seal and stage secrets
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        env:
          KUBESEAL_CERT: ${{ secrets.KUBESEAL_CERT }}
        run: |
          echo "$KUBESEAL_CERT" > /tmp/sealed-secrets-cert.pem
          bash terraform/scripts/seal-and-commit.sh --cert /tmp/sealed-secrets-cert.pem

      - name: Commit and push
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        run: |
          git config user.name "terraform-cloudflare-bot"
          git config user.email "bot@alacaba.org"
          if ! git diff --cached --quiet; then
            git commit -m "chore: update Cloudflare secrets from Terraform"
            git push
          else
            echo "No changes to commit"
          fi
```

- [ ] **Commit**

```bash
mkdir -p .github/workflows
git add .github/workflows/terraform-cloudflare.yml
git commit -m "ci: add Terraform Cloudflare workflow"
```

---

### Task 7: Push and verify CI

- [ ] **Push branch and verify workflow runs**

```bash
git push -u origin feat/cloudflare-iac
```

Open the PR or the Actions tab and verify:
- The workflow triggers on the push
- `terraform validate` passes
- `terraform plan` runs successfully (will show all new resources)

- [ ] **If plan shows errors**, fix and re-push

---

### Task 8: Create R2 bucket and set up GitHub secrets

- [ ] **Create R2 bucket**

```bash
aws s3api create-bucket --bucket homelab-tfstate --region auto \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

- [ ] **Generate R2 API token** in Cloudflare Dashboard → R2 → Manage R2 API Tokens → Create
      Save the Access Key ID and Secret Access Key.

- [ ] **Export kubeseal public cert**

```bash
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
  --fetch-cert | base64 > kubeseal-cert.b64
# Copy the contents for the GitHub secret
```

- [ ] **Create GitHub secrets** in repo Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Token with Zone:Read, DNS:Edit, Tunnel:Edit, API Tokens:Write |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | From R2 token creation |
| `R2_SECRET_ACCESS_KEY` | From R2 token creation |
| `KUBESEAL_CERT` | The base64-encoded public cert from step above |
| `GH_PAT` | GitHub PAT with `contents: write` on this repo |

---

### Task 9: Import existing state and initial apply

- [ ] **Run terraform init locally**

```bash
cd terraform
terraform init
```

- [ ] **Import existing DNS records**

The zones are resolved via `data.cloudflare_zone` at plan time (API call).
Only DNS records need importing (they already exist in Cloudflare).

```bash
terraform import cloudflare_dns_record.cv_watchtoken <zone-id>/<record-id>
terraform import cloudflare_dns_record.fgit_watchtoken <zone-id>/<record-id>
terraform import cloudflare_dns_record.vault_watchtoken <zone-id>/<record-id>
terraform import cloudflare_dns_record.cv_alacaba <zone-id>/<record-id>
```

To find record IDs, query the Cloudflare API:
```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone-id>/dns_records?name=cv.watchtoken.org" \
  | jq '.result[].id'
```

- [ ] **Run plan and verify zero unexpected changes**

```bash
terraform plan
```

- [ ] **Apply (creates new tunnel + API tokens)**

```bash
terraform apply
```

- [ ] **Run seal script to generate SealedSecrets**

```bash
./scripts/seal-and-commit.sh
```

- [ ] **Push the committed SealedSecrets**

```bash
git push
```

---

### Task 10: Verify and cut over

- [ ] **Restart cloudflared to pick up new tunnel token**

```bash
kubectl rollout restart deploy/cloudflared -n cloudflared
```

- [ ] **Verify all endpoints work**

```bash
curl -sI --max-time 10 https://cv.alacaba.org/
curl -sI --max-time 10 https://cv.watchtoken.org/
curl -sI --max-time 10 https://fgit.watchtoken.org/
curl -sI --max-time 10 https://vault.watchtoken.org/
```

- [ ] **Delete old tunnel** in Cloudflare Zero Trust dashboard after confirming new tunnel works

- [ ] **Remove old SealedSecrets from git** (they're now TF-managed)

```bash
git rm clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml
git commit -m "chore: remove old SealedSecrets replaced by Terraform"
git push
```

- [ ] **Remove manual Zero Trust public hostname config** (Terraform owns it now)

- [ ] **Update AGENTS.md** to document the Terraform workflow
