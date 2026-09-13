#!/usr/bin/env bash
#
# hris-chart-update.sh — find a newer HRIS Helm chart release that is still
# below 1.0.0, and optionally move the HelmRelease pin onto it.
#
#   GHCR_TOKEN=<pat> ./.github/scripts/hris-chart-update.sh           # report only
#   GHCR_TOKEN=<pat> ./.github/scripts/hris-chart-update.sh --apply    # rewrite the pin
#
# Why a ceiling: the cluster runs pre-1.0 HRIS releases without review, because
# the app is still moving fast and every chart version is a small delta. 1.0.0 is
# the point where that stops — a major release gets a deliberate human bump, never
# an automatic one. So candidates are exact semver tags with
# `current < version < 1.0.0`, pre-releases (0.2.0-rc1) are ignored, and the
# script refuses to run at all if the pin stops being an exact X.Y.Z.
#
# Two gates before a candidate is reported, both because HRIS holds applicant PII:
#
#   1. the chart must actually be pullable (manifest + Chart.yaml come back), and
#   2. the image tag named by the chart's `appVersion` must already exist in
#      ghcr.io/aplacaba/tala-hris — otherwise the pod would hit ImagePullBackOff
#      (see the HRIS gotcha in AGENTS.md).
#
# Outputs (also appended to $GITHUB_OUTPUT when set):
#   current, candidate, app_version, image_tag, latest_below_ceiling, latest_any
#
# Exit codes: 0 report/apply ok, 2 usage or registry failure, 3 chart published
# but its image is missing (nothing to do yet; the next run retries).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

HELMRELEASE="clusters/pk3s/hris/helmrelease.yaml"
REGISTRY="ghcr.io"
CHART_REPO="aplacaba/charts/hris"
CHART_NAME="hris"
IMAGE_REPO="aplacaba/tala-hris"
CEILING="1.0.0"

APPLY=0

usage() {
  cat <<'EOF'
Usage: GHCR_TOKEN=<pat> .github/scripts/hris-chart-update.sh [--apply]

  --apply   rewrite the chart `version:` pin in clusters/pk3s/hris/helmrelease.yaml
            (without it the script only reports what it found)

GHCR_TOKEN must be a token that can read the private GHCR packages
`aplacaba/charts` and `aplacaba/tala-hris`: a classic PAT with `read:packages`,
or a fine-grained PAT with Packages: Read.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

emit() { # key value — for the GitHub Actions step, and for humans reading stderr
  printf '  %-20s %s\n' "$1" "$2" >&2
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $arg"
      ;;
  esac
done

[[ -f "$HELMRELEASE" ]] || die "$HELMRELEASE not found (run this from the repository)"
[[ -n "${GHCR_TOKEN:-}" ]] || die "GHCR_TOKEN is not set (see --help)"

# --- the current pin -------------------------------------------------------

CURRENT="$(python3 - "$HELMRELEASE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r'^\s*version:\s*"([^"]+)"\s*$', text, re.M)
print(match.group(1) if match else "")
PY
)"
[[ -n "$CURRENT" ]] || die "no quoted chart version pin found in $HELMRELEASE"

python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]) else 1)' "$CURRENT" ||
  die "chart version '$CURRENT' is not an exact X.Y.Z pin — refusing to auto-update"

# --- registry helpers ------------------------------------------------------

exchange_token() { # repo path -> bearer token on stdout
  local repo="$1" body
  body="$(curl -fsS -u "x-access-token:${GHCR_TOKEN}" \
    "https://${REGISTRY}/token?service=${REGISTRY}&scope=repository:${repo}:pull" 2>/dev/null || true)"
  BODY="$body" python3 -c '
import json, os, sys
raw = os.environ.get("BODY", "")
try:
    token = json.loads(raw).get("token")
except ValueError:
    token = None
if not token:
    sys.exit(1)
print(token)
' || die "GHCR refused a pull token for ${repo}. The token needs the read:packages scope (classic PAT) or Packages: Read (fine-grained PAT)."
}

registry_get() { # url, accept header (optional) -> body on stdout, dies with context
  local url="$1" accept="${2:-}" response status body
  response="$(curl -sSL -H "Authorization: Bearer ${BEARER:-}" \
    ${accept:+-H "Accept: ${accept}"} \
    -w $'\n%{http_code}' "$url")" || die "could not reach ${REGISTRY} (${url})"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  case "$status" in
    200) printf '%s' "$body" ;;
    401 | 403)
      die "${REGISTRY} denied access to ${url#https://${REGISTRY}/v2/} (HTTP ${status}). The token needs the read:packages scope (classic PAT) or Packages: Read (fine-grained PAT)."
      ;;
    404) die "not found: ${url}" ;;
    *) die "unexpected HTTP ${status} from ${url}" ;;
  esac
}

fetch_tags() { # repo path -> tag list JSON on stdout
  BEARER="$(exchange_token "$1")"
  registry_get "https://${REGISTRY}/v2/$1/tags/list"
}

chart_app_version() { # chart version -> appVersion on stdout
  local version="$1" manifest blob
  BEARER="$(exchange_token "$CHART_REPO")"
  manifest="$(registry_get "https://${REGISTRY}/v2/${CHART_REPO}/manifests/${version}" \
    "application/vnd.oci.image.manifest.v1+json")"
  blob="$(printf '%s' "$manifest" | python3 -c '
import json, sys
layers = json.load(sys.stdin).get("layers") or []
print(layers[0]["digest"] if layers else "")
')"
  [[ -n "$blob" ]] || die "chart ${CHART_NAME} ${version} has no layers — not a Helm chart?"
  # The chart layer is a gzipped tarball: stream it straight into tar, never
  # through a shell variable (command substitution would mangle the bytes).
  curl -fsSL -H "Authorization: Bearer ${BEARER}" \
    "https://${REGISTRY}/v2/${CHART_REPO}/blobs/${blob}" |
    tar -xzOf - --wildcards "*/Chart.yaml" |
    python3 -c '
import re, sys
match = re.search(r"^appVersion:[ \t]*(.+)$", sys.stdin.read(), re.M)
print(match.group(1).strip().strip(chr(34) + chr(39)) if match else "")
' || die "could not read Chart.yaml for ${CHART_NAME} ${version} from ${CHART_REPO}"
}

# --- candidate selection ---------------------------------------------------

log "HRIS chart auto-update (ceiling ${CEILING}, ${CHART_REPO})"

TAGS_JSON="$(fetch_tags "$CHART_REPO")"
SELECTION="$(printf '%s' "$TAGS_JSON" | python3 -c '
import json, re, sys

def parse(text):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text)
    return tuple(int(part) for part in match.groups()) if match else None

tags = json.load(sys.stdin).get("tags") or []
stable = {tag: parse(tag) for tag in tags}
stable = {tag: version for tag, version in stable.items() if version}
current = parse(sys.argv[1])
ceiling = parse(sys.argv[2])
ordered = sorted(stable, key=lambda tag: stable[tag])

newer = [tag for tag in ordered if current < stable[tag] < ceiling]
below = [tag for tag in ordered if stable[tag] < ceiling]
at_or_above = [tag for tag in ordered if stable[tag] >= ceiling]

print(json.dumps({
    "candidate": newer[-1] if newer else "",
    "latest_below_ceiling": below[-1] if below else "",
    "latest_any": ordered[-1] if ordered else "",
    "ceiling_hit": at_or_above[-1] if at_or_above else "",
}))
' "$CURRENT" "$CEILING")"

json_field() { printf '%s' "$SELECTION" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

CANDIDATE="$(json_field candidate)"
LATEST_BELOW="$(json_field latest_below_ceiling)"
LATEST_ANY="$(json_field latest_any)"
CEILING_HIT="$(json_field ceiling_hit)"

emit current "$CURRENT"
emit latest_below_ceiling "$LATEST_BELOW"
emit latest_any "$LATEST_ANY"
emit candidate "$CANDIDATE"
emit app_version ""
emit image_tag ""

if [[ -n "$CEILING_HIT" ]]; then
  log "note: ${CEILING_HIT} is published — the pre-1.0 auto-update window is over; bump past the ceiling by hand."
fi

if [[ -z "$CANDIDATE" ]]; then
  log "up to date: ${CURRENT} is the newest stable chart below ${CEILING}."
  exit 0
fi

log "candidate: ${CANDIDATE} (pinned: ${CURRENT})"

# --- gates -----------------------------------------------------------------

APP_VERSION="$(chart_app_version "$CANDIDATE")"
[[ -n "$APP_VERSION" ]] || die "chart ${CANDIDATE} has no appVersion — cannot resolve its image tag"

IMAGE_TAGS="$(fetch_tags "$IMAGE_REPO")"
IMAGE_EXISTS="$(printf '%s' "$IMAGE_TAGS" | python3 -c '
import json, sys
sys.exit(0 if sys.argv[1] in (json.load(sys.stdin).get("tags") or []) else 1)
' "$APP_VERSION" && echo yes || echo no)"

emit app_version "$APP_VERSION"
emit image_tag "$APP_VERSION"

if [[ "$IMAGE_EXISTS" != "yes" ]]; then
  log "skip: chart ${CANDIDATE} wants image ${IMAGE_REPO}:${APP_VERSION}, which is not published yet."
  log "      the next run picks it up once the image lands."
  exit 3
fi

log "image ok: ${IMAGE_REPO}:${APP_VERSION} exists"

# --- apply -----------------------------------------------------------------

if ((APPLY)); then
  python3 - "$HELMRELEASE" "$CANDIDATE" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
text = open(path).read()
new, count = re.subn(r'(^\s*version:\s*)"[^"]+"', lambda m: f'{m.group(1)}"{version}"', text, count=1, flags=re.M)
if count != 1:
    sys.exit(f"expected exactly one version pin in {path}, patched {count}")
open(path, "w").write(new)
PY
  log "patched ${HELMRELEASE}: ${CURRENT} -> ${CANDIDATE}"
  git --no-pager diff -- "$HELMRELEASE" >&2 || true
fi

exit 0
