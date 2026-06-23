#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?must be set}"
: "${TF_VAR_cloudflare_account_id:?must be set}"

WATCHTOKEN_ZONE="8f0cbcc9fc1a0c2cfe0016df00c27914"
ALACABA_ZONE="a9203e0777c754f88020d7508fc1d145"

# Ensure terraform is initialized
if [ ! -f .terraform.lock.hcl ]; then
  echo "Initializing terraform..."
  terraform init
fi

import_record() {
  local zone="$1" name="$2" resource="$3"
  local id
  id=$(curl -fsSL -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=CNAME&name=$name" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)

  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "ERROR: could not find record $name in zone $zone"
    return 1
  fi

  echo "Importing $resource ($name → $zone/$id)..."
  terraform import "$resource" "$zone/$id"
}

import_record "$WATCHTOKEN_ZONE" "cv.watchtoken.org"    cloudflare_dns_record.cv_watchtoken
import_record "$WATCHTOKEN_ZONE" "fgit.watchtoken.org"  cloudflare_dns_record.fgit_watchtoken
import_record "$WATCHTOKEN_ZONE" "vault.watchtoken.org" cloudflare_dns_record.vault_watchtoken
import_record "$ALACABA_ZONE"    "cv.alacaba.org"       cloudflare_dns_record.cv_alacaba

echo ""
echo "Done. Run: terraform plan"
