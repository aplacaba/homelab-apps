#!/usr/bin/env bash
# Seal Terraform sensitive outputs into SealedSecret YAMLs and stage in git.
# Usage:
#   ./scripts/seal-and-commit.sh                    # fetch cert from cluster
#   ./scripts/seal-and-commit.sh --cert /path/to/cert.pem
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

CERT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$CERT" ]; then
  KUBESEAL_ARGS="--controller-name sealed-secrets --controller-namespace sealed-secrets"
else
  KUBESEAL_ARGS="--cert $CERT"
fi

seal() {
  local name="$1" namespace="$2" key="$3" value="$4" output="$5"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n  %s: %s\n' "$name" "$namespace" "$key" "$value" \
    | kubeseal $KUBESEAL_ARGS --format yaml --namespace "$namespace" \
    > "$REPO_ROOT/$output"
  echo "  sealed $output"
}

cd "$REPO_ROOT/terraform"

echo "Sealing secrets..."
seal "tunnel-credentials" "cloudflared" "token" \
  "$(terraform output -raw tunnel_token)" \
  "clusters/pk3s/cloudflared/sealedsecret.yaml"

seal "cloudflare-api-token" "cert-manager" "api-token" \
  "$(terraform output -raw watchtoken_api_token)" \
  "clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml"

seal "cloudflare-alacaba-api-token" "cert-manager" "api-token" \
  "$(terraform output -raw alacaba_api_token)" \
  "clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml"

cd "$REPO_ROOT"
git add clusters/pk3s/cloudflared/sealedsecret.yaml \
       clusters/pk3s/cert-manager/sealedsecret-cloudflare-api-token.yaml \
       clusters/pk3s/cert-manager/sealedsecret-cloudflare-alacaba-api-token.yaml

if ! git diff --cached --quiet; then
  echo "Sealed secrets staged. Run 'git commit && git push' to deploy."
else
  echo "No changes to seal."
fi
