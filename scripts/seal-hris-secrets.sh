#!/usr/bin/env bash
#
# seal-hris-secrets.sh — seal the HRIS credentials into SealedSecrets.
#
# All values come from ONE file (default ~/.secrets/hris.env, mode 600):
#
#   R2_ACCESS_KEY_ID=...
#   R2_SECRET_ACCESS_KEY=...
#   HRIS_ATS_DATABASE_PASSWORD=...
#   SMTP_USERNAME=alacaba@fastmail.com
#   SMTP_PASSWORD=...
#   RAILS_MASTER_KEY=...
#   GHCR_TOKEN=...
#
# Write them bare — no quotes, no spaces around '='. Only the keys present in the
# file are sealed; the rest are reported as skipped. Nothing is ever echoed, and
# no value is passed on a command line: each value reaches kubectl through a
# mode-600 temp file that is removed on exit.
#
#   ./scripts/seal-hris-secrets.sh --init            # create the values file (chmod 600)
#   ./scripts/seal-hris-secrets.sh --dry-run         # show what would be sealed
#   ./scripts/seal-hris-secrets.sh                   # write sealedsecret-*.yaml
#   ./scripts/seal-hris-secrets.sh --bump --verify   # also roll the pod, then check
#
# Re-sealing alone changes nothing in the cluster: the pod rolls when
# `secretsChecksum` in clusters/pk3s/hris/helmrelease.yaml changes, which is what
# --bump does. Committing and pushing is always left to you.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VALUES_FILE="${HRIS_SECRETS_FILE:-$HOME/.secrets/hris.env}"
OUTDIR="clusters/pk3s/hris"
APP_NAMESPACE="hris"
REGISTRY_NAMESPACE="flux-system"
REGISTRY_HOST="ghcr.io"
REGISTRY_USER="aplacaba"
DEFAULT_SMTP_USER="alacaba@fastmail.com"
ALL_STEPS="r2,db,smtp,ghcr,rails"
ONLY="$ALL_STEPS"
DO_BUMP=0
DO_VERIFY=0
DRY_RUN=0
DO_INIT=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

usage() { sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --values) VALUES_FILE="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --only)   ONLY="$2"; shift 2 ;;
    --bump)   DO_BUMP=1; shift ;;
    --verify) DO_VERIFY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --init)   DO_INIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── tools (not needed for --init, which only writes a template) ──────────────
if [ "$DO_INIT" != 1 ]; then
  if command -v kubeseal >/dev/null 2>&1; then
    KUBESEAL="$(command -v kubeseal)"
  elif [ -x "$HOME/.local/bin/kubeseal" ]; then
    KUBESEAL="$HOME/.local/bin/kubeseal"
  else
    die "kubeseal not found (expected on PATH or at ~/.local/bin/kubeseal)"
  fi
  command -v kubectl >/dev/null || die "kubectl not found"
  command -v python3 >/dev/null || die "python3 not found"
  [ -f "$OUTDIR/helmrelease.yaml" ] || die "$OUTDIR/helmrelease.yaml not found — run from the repo"
fi

# ── values file ──────────────────────────────────────────────────────────────
if [ "$DO_INIT" = 1 ]; then
  [ -e "$VALUES_FILE" ] && die "$VALUES_FILE already exists — edit it instead (or use --values)"
  mkdir -p "$(dirname "$VALUES_FILE")"
  umask 077
  cat > "$VALUES_FILE" <<'TEMPLATE'
# HRIS secret values. Bare KEY=value, no quotes, no spaces around '='.
# Only keys you fill in get sealed. Nothing here is ever echoed by the script.
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
HRIS_ATS_DATABASE_PASSWORD=
SMTP_USERNAME=alacaba@fastmail.com
SMTP_PASSWORD=
RAILS_MASTER_KEY=
GHCR_TOKEN=
TEMPLATE
  chmod 600 "$VALUES_FILE"
  printf 'created %s (mode 600) — fill it in, then run with no arguments\n' "$VALUES_FILE"
  exit 0
fi

[ -f "$VALUES_FILE" ] || die "values file not found: $VALUES_FILE — run --init first"
PERMS="$(stat -c '%a' "$VALUES_FILE")"
case "$PERMS" in
  *[0-9][0-9]|*[1-7][0-9]|*[0-9][1-7]|*[1-7][1-7]) [ "$PERMS" = "600" ] || printf 'warning: %s is mode %s — chmod 600 it\n' "$VALUES_FILE" "$PERMS" >&2 ;;
esac
if grep -qE $'\r' "$VALUES_FILE"; then die "$VALUES_FILE has CRLF line endings"; fi

TMP_FILES=()
cleanup() { local f; for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$f"; done; }
trap cleanup EXIT
new_tmp() { local f; f="$(mktemp)"; chmod 600 "$f"; TMP_FILES+=("$f"); printf '%s' "$f"; }

value_of() { grep -E "^$1=" "$VALUES_FILE" | head -n1 | cut -d= -f2- || true; }
have() { [ -n "$(value_of "$1")" ]; }

# refuses quoted values: --from-env-file would keep the quotes as data
check_bare() {
  local k v
  for k in "$@"; do
    v="$(value_of "$k")"
    [ -n "$v" ] || continue
    case "$v" in
      \"*|\'*) die "$k is quoted — write it bare: $k=value" ;;
      *[[:space:]]) die "$k ends with whitespace" ;;
    esac
  done
}

# writes a temp env file holding just the given keys (in the order asked for)
env_subset() {
  local out k; out="$(new_tmp)"
  for k in "$@"; do have "$k" && grep -E "^$k=" "$VALUES_FILE" | head -n1 >> "$out"; done
  printf '%s' "$out"
}

seal_env_file() { # secret-name namespace outfile envfile
  local name="$1" ns="$2" out="$3" envfile="$4" target
  target="$OUTDIR/$out"
  if [ "$DRY_RUN" = 1 ]; then note "would seal $ns/$name -> $target"; return 0; fi
  kubectl create secret generic "$name" -n "$ns" --from-env-file="$envfile" \
      --dry-run=client -o yaml \
    | "$KUBESEAL" --controller-name sealed-secrets --controller-namespace sealed-secrets \
        --format yaml --namespace "$ns" > "$target"
  note "sealed $ns/$name -> $target"
}

seal_dockerconfig() { # secret-name namespace outfile token
  local name="$1" ns="$2" out="$3" token="$4" json target
  target="$OUTDIR/$out"
  json="$(new_tmp)"
  HOST="$REGISTRY_HOST" USER_="$REGISTRY_USER" PASS_="$token" python3 - "$json" <<'PY'
import base64, json, os, sys
host, user, pw = os.environ["HOST"], os.environ["USER_"], os.environ["PASS_"]
cfg = {"auths": {host: {"username": user, "password": pw,
                        "auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}}}
with open(sys.argv[1], "w") as fh:
    json.dump(cfg, fh)
PY
  if [ "$DRY_RUN" = 1 ]; then note "would seal $ns/$name -> $target"; return 0; fi
  kubectl create secret generic "$name" -n "$ns" --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$json" --dry-run=client -o yaml \
    | "$KUBESEAL" --controller-name sealed-secrets --controller-namespace sealed-secrets \
        --format yaml --namespace "$ns" > "$target"
  note "sealed $ns/$name -> $target"
}

wanted() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

printf '\nHRIS seal — values: %s%s\n' "$VALUES_FILE" "$([ "$DRY_RUN" = 1 ] && printf ' (dry run)')"
SEALED=(); SKIPPED=()

# ── r2 ───────────────────────────────────────────────────────────────────────
if wanted r2; then
  check_bare R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
  if have R2_ACCESS_KEY_ID && have R2_SECRET_ACCESS_KEY; then
    seal_env_file hris-r2 "$APP_NAMESPACE" sealedsecret-r2.yaml "$(env_subset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY)"
    SEALED+=("hris-r2 (upload credentials)")
  else
    SKIPPED+=("hris-r2 — need R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY")
  fi
fi

# ── database ─────────────────────────────────────────────────────────────────
if wanted db; then
  check_bare HRIS_ATS_DATABASE_PASSWORD
  if have HRIS_ATS_DATABASE_PASSWORD; then
    seal_env_file hris-db "$APP_NAMESPACE" sealedsecret-db.yaml "$(env_subset HRIS_ATS_DATABASE_PASSWORD)"
    SEALED+=("hris-db — rotate the role FIRST: ALTER ROLE hris_ats PASSWORD '...'")
  else
    SKIPPED+=("hris-db — need HRIS_ATS_DATABASE_PASSWORD")
  fi
fi

# ── smtp ─────────────────────────────────────────────────────────────────────
if wanted smtp; then
  check_bare SMTP_USERNAME SMTP_PASSWORD
  if have SMTP_PASSWORD; then
    if have SMTP_USERNAME; then
      smtp_env="$(env_subset SMTP_USERNAME SMTP_PASSWORD)"
    else
      smtp_env="$(new_tmp)"; printf 'SMTP_USERNAME=%s\n' "$DEFAULT_SMTP_USER" >> "$smtp_env"
      grep -E '^SMTP_PASSWORD=' "$VALUES_FILE" | head -n1 >> "$smtp_env"
      note "SMTP_USERNAME not set — defaulting to $DEFAULT_SMTP_USER"
    fi
    seal_env_file hris-smtp "$APP_NAMESPACE" sealedsecret-smtp.yaml "$smtp_env"
    SEALED+=("hris-smtp (mail)")
  else
    SKIPPED+=("hris-smtp — need SMTP_PASSWORD")
  fi
fi

# ── ghcr: one token, two namespaces ──────────────────────────────────────────
if wanted ghcr; then
  check_bare GHCR_TOKEN
  if have GHCR_TOKEN; then
    TOKEN="$(value_of GHCR_TOKEN)"
    seal_dockerconfig hris-ghcr "$APP_NAMESPACE" sealedsecret-ghcr.yaml "$TOKEN"
    seal_dockerconfig ghcr-registry-auth "$REGISTRY_NAMESPACE" sealedsecret-registry-auth.yaml "$TOKEN"
    SEALED+=("hris-ghcr + ghcr-registry-auth (image and chart pulls)")
    unset TOKEN
  else
    SKIPPED+=("ghcr pair — need GHCR_TOKEN")
  fi
fi

# ── rails master key ─────────────────────────────────────────────────────────
if wanted rails; then
  check_bare RAILS_MASTER_KEY
  if have RAILS_MASTER_KEY; then
    seal_env_file hris-rails-secrets "$APP_NAMESPACE" sealedsecret-rails-secrets.yaml "$(env_subset RAILS_MASTER_KEY)"
    SEALED+=("hris-rails-secrets — must match the app repo's current master key")
  else
    SKIPPED+=("hris-rails-secrets — need RAILS_MASTER_KEY")
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
printf '\nsealed:\n'; [ ${#SEALED[@]} -eq 0 ] && note "(nothing)" || for s in "${SEALED[@]}"; do note "$s"; done
printf 'skipped:\n'; [ ${#SKIPPED[@]} -eq 0 ] && note "(nothing)" || for s in "${SKIPPED[@]}"; do note "$s"; done

if [ "$DO_BUMP" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    note "would bump secretsChecksum in $OUTDIR/helmrelease.yaml"
  else
    python3 - "$OUTDIR/helmrelease.yaml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
m = re.search(r'secretsChecksum:\s*"(\d+)"', s)
if not m: sys.exit("secretsChecksum not found in the HelmRelease")
new = str(int(m.group(1)) + 1)
p.write_text(s[:m.start(1)] + new + s[m.end(1):])
print(f"  bumped secretsChecksum: {m.group(1)} -> {new} (this is what rolls the pod)")
PY
  fi
fi

if [ "$DO_VERIFY" = 1 ] && [ "$DRY_RUN" != 1 ]; then
  printf '\ndecrypted keys (values are never printed):\n'
  for s in hris-db hris-r2 hris-smtp hris-rails-secrets hris-ghcr; do
    printf '  %-22s ' "$s"
    kubectl get secret "$s" -n "$APP_NAMESPACE" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}' 2>/dev/null || echo "(not created)"
  done
  printf '  %-22s ' ghcr-registry-auth
  kubectl get secret ghcr-registry-auth -n "$REGISTRY_NAMESPACE" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}' 2>/dev/null || echo "(not created)"
fi

cat <<'NEXT'

next:
  git -C "$(pwd)" add clusters/pk3s/hris && git commit -m "hris: reseal secrets" && git push
  # reconcile now instead of waiting for the hourly sync:
  kubectl annotate kustomization flux-system -n flux-system \
    reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
  kubectl get pods -n hris    # expect one new pod, then 1/1 Running
NEXT
