#!/usr/bin/env bash
# cluster-digest worker — inventories chart + image versions across the cluster.
#
# Sources:
#   1. HelmReleases: running chart version from status.lastAttemptedRevision,
#      latest resolved from the chart's HelmRepository (HTTP index or OCI tags).
#   2. Curated raw-manifest images (RAW_IMAGES config): running tag from the
#      Deployment, latest from the container registry. Apps tracking :latest
#      are flagged (bump "tracks-latest"), pinned apps are shown as "pinned".
#
# Output: status.json on the shared PVC for the nginx dashboard.
# Optional: reads the forgejo-registry-auth dockerconfigjson secret in
# flux-system (via RBAC resourceNames) to resolve the private fgit OCI registry.
set -uo pipefail

# Biweekly gate: the CronJob fires weekly, but only even ISO weeks run the
# scan — Kubernetes CronJobs have no "every 2 weeks" schedule.
if (( $(date +%V) % 2 != 0 )); then
  echo "[digest] odd ISO week (W$(date +%V)) — biweekly cadence, skipping"
  exit 0
fi

OUT_DIR="${OUT_DIR:-/data}"
RAW_CONFIG="${RAW_CONFIG:-/config/raw-images.yaml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "[digest] $*"; }
fail() { echo "[digest] FATAL: $*" >&2; exit 1; }

for c in kubectl jq curl awk sort grep; do
  command -v "$c" >/dev/null || fail "$c not found"
done

# ---------- semver ----------------------------------------------------------

# version_key VERSION -> "maj min patch build"
# Normalizes a version tag to comparable numeric fields:
#   v1.2.3 -> 1 2 3 0          4.0.20.3014-ls5 -> 4 0 20 3014
#   2026.11.2 -> 2026 11 2 0   5.3.0_v2.1.2-ls487 -> 5 3 0 487 (ls suffix)
#   version-12.4ubu2604 -> (empty; not numeric-led)
version_key() {
  local v="${1#v}"
  v="${v#version-}"          # LSIO jellyfin style
  v="${v%%+*}"               # build metadata
  # pre-release/build suffix: -ls<NNN> is a real increment, keep the number
  local build=0
  if [[ "$v" == *_* ]]; then
    # compound tag e.g. 5.3.0_v2.1.2-ls487 — version is before the underscore,
    # the ls build number after it
    build="${v##*_}"
    v="${v%%_*}"
    [[ "$build" == *-ls* ]] && build="${build##*-ls}"
    [[ "$build" =~ ^[0-9]+$ ]] || build=0
  elif [[ "$v" == *-ls* ]]; then
    build="${v##*-ls}"
    [[ "$build" =~ ^[0-9]+$ ]] || build=0
    v="${v%%-ls*}"
  elif [[ "$v" == *-* ]]; then
    v="${v%%-*}"             # other pre-releases are ignored for ordering
  fi
  # numeric fields only; 4th field (e.g. 3014) folds into build
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "$v" | awk -F. -v b="$build" '{
      m = ($1 ? $1 : 0); n = ($2 ? $2 : 0); p = ($3 ? $3 : 0)
      extra = 0; for (i = 4; i <= NF; i++) extra = extra * 1000 + $i
      print m, n, p, b + extra
    }'
  fi
}

# semver_cmp A B -> -1 | 0 | 1 | x (not comparable)
semver_cmp() {
  local a b
  a="$(version_key "$1")"; b="$(version_key "$2")"
  [[ -z "$a" || -z "$b" ]] && { echo "x"; return; }
  local maj1 min1 p1 b1 maj2 min2 p2 b2
  read -r maj1 min1 p1 b1 <<<"$a"
  read -r maj2 min2 p2 b2 <<<"$b"
  if (( maj1 != maj2 )); then echo $(( maj1 < maj2 ? -1 : 1 ))
  elif (( min1 != min2 )); then echo $(( min1 < min2 ? -1 : 1 ))
  elif (( p1 != p2 )); then echo $(( p1 < p2 ? -1 : 1 ))
  elif (( b1 != b2 )); then echo $(( b1 < b2 ? -1 : 1 ))
  else echo 0; fi
}

# bump_type RUNNING LATEST -> major|minor|patch|current|unknown|downgrade
bump_type() {
  local r="$1" l="$2"
  [[ -z "$l" || "$l" == "null" ]] && { echo "unknown"; return; }
  local cmp; cmp="$(semver_cmp "$r" "$l")"
  [[ "$cmp" == "x" ]] && { echo "unknown"; return; }
  (( cmp > 0 )) && { echo "downgrade"; return; }
  (( cmp == 0 )) && { echo "current"; return; }
  read -r rmaj rmin _ <<<"$(version_key "$r")"
  read -r lmaj lmin _ <<<"$(version_key "$l")"
  (( rmaj < lmaj )) && { echo "major"; return; }
  (( rmin < lmin )) && { echo "minor"; return; }
  echo "patch"
}

# ---------- registry / repo lookups -----------------------------------------

# registry_latest_tag REPO_PATH HOST [AUTH_JSON] -> newest strict-semver tag or "null"
registry_latest_tag() {
  local repo="$1" host="$2" authjson="${3:-}"
  local curl_args=(--silent --max-time 20 --show-error)
  # dockerconfig Basic credential for this host (keys carry the scheme)
  local basic=""
  if [[ -n "$authjson" && "$authjson" != "{}" ]]; then
    basic="$(jq -r --arg h "$host" --arg hs "https://$host" \
      '.[$h].auth // .[$hs].auth // empty' <<<"$authjson")"
  fi
  local tok=""
  case "$host" in
    ghcr.io)
      # anonymous first (public repos); with credentials if that is denied
      # (ghcr rejects Basic auth on /v2 — the token endpoint takes it instead)
      tok="$(curl "${curl_args[@]}" "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      if [[ -z "$tok" && -n "$basic" ]]; then
        tok="$(curl "${curl_args[@]}" -u "$(echo "$basic" | base64 -d)" \
          "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      fi
      ;;
    registry-1.docker.io)
      tok="$(curl "${curl_args[@]}" "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      ;;
    codeberg.org)
      tok="$(curl "${curl_args[@]}" "https://codeberg.org/v2/token?service=container_registry&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      ;;
  esac
  if [[ -n "$tok" ]]; then
    curl_args+=(-H "Authorization: Bearer $tok")
  elif [[ -n "$basic" ]]; then
    # self-hosted registries (fgit) accept Basic directly on /v2
    curl_args+=(-H "Authorization: Basic $basic")
  fi
  # strict semver only (no pre-releases); sorted numerically per field.
  # Registries list lexicographically and cap pages, so paginate to exhaustion.
  # Accumulate in a temp file — big tag lists overflow ARG_MAX if inlined.
  local page last ftags="$TMP/tags.$$" last_tags attempt
  : > "$ftags"
  for _ in 1 2 3 4 5 6 7 8; do
    page=""
    for attempt in 1 2; do
      page="$(curl "${curl_args[@]}" "https://${host}/v2/${repo}/tags/list?n=1000${last:+&last=$last}" 2>/dev/null)" || break
      # registries occasionally 429 mid-listing (ghcr burst limit): retry once
      if jq -e 'has("errors") and (.tags | not)' <<<"$page" >/dev/null 2>&1 && (( attempt == 1 )); then
        sleep 2; continue
      fi
      break
    done
    [[ -z "$page" ]] && break
    last_tags="$(jq -r '.tags | last // empty' <<<"$page")"
    jq -r '.tags // [] | .[]' <<<"$page" >> "$ftags"   # plain tag lines
    [[ -z "$last_tags" ]] && break
    last="$last_tags"
    sleep 0.3   # stay polite with anonymous registry budgets
  done
  # plain-text tag lines -> versionish filter + numeric sort
  pick_newest < "$ftags"
  rm -f "$ftags"
}

# image_latest_via_label REPO HOST [AUTH_JSON] -> version from the "latest"
# tag's image-config label (org.opencontainers.image.version). Handles OCI
# indexes (fetch child manifest first). Echoes "" when labels are absent.
image_latest_via_label() {
  local repo="$1" host="$2" authjson="${3:-}"
  local curl_args=(--silent --max-time 20 --show-error)
  local basic tok
  if [[ -n "$authjson" && "$authjson" != "{}" ]]; then
    basic="$(jq -r --arg h "$host" --arg hs "https://$host" '.[$h].auth // .[$hs].auth // empty' <<<"$authjson")"
  fi
  local acc="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  local tok_args=()
  case "$host" in
    ghcr.io)
      tok="$(curl "${curl_args[@]}" "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      if [[ -z "$tok" && -n "$basic" ]]; then
        tok="$(curl "${curl_args[@]}" -u "$(echo "$basic" | base64 -d)" "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      fi
      [[ -n "$tok" ]] && tok_args+=(-H "Authorization: Bearer $tok")
      ;;
    registry-1.docker.io)
      tok="$(curl "${curl_args[@]}" "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty')"
      [[ -n "$tok" ]] && tok_args+=(-H "Authorization: Bearer $tok")
      ;;
    *)
      [[ -n "$basic" ]] && tok_args+=(-H "Authorization: Basic $basic")
      ;;
  esac
  local mfst cfg child blob labels
  mfst="$(curl "${curl_args[@]}" "${tok_args[@]}" -H "Accept: $acc" "https://${host}/v2/${repo}/manifests/latest" 2>/dev/null)" || return 0
  cfg="$(jq -r 'if .manifests
      then ([.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux")][0].digest // "")
      else .config.digest // "" end' <<<"$mfst")"
  [[ -z "$cfg" ]] && return 0
  if jq -e '.manifests' <<<"$mfst" >/dev/null 2>&1; then
    child="$(curl "${curl_args[@]}" "${tok_args[@]}" -H "Accept: $acc" "https://${host}/v2/${repo}/manifests/$cfg" 2>/dev/null)"
    blob="$(jq -r '.config.digest // empty' <<<"$child")"
  else
    blob="$cfg"
  fi
  [[ -z "$blob" ]] && return 0
  # blob endpoints redirect (ghcr → CDN); -L follows
  labels="$(curl -L --silent --max-time 20 "${tok_args[@]}" "https://${host}/v2/${repo}/blobs/$blob" 2>/dev/null)"
  ver="$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' <<<"$labels")"
  # some images label the moving tag literally "latest" — useless, ignore
  [[ "$ver" == "latest" ]] && ver=""
  echo "$ver"
}

# pick_newest < lines-of-versions -> newest version or "null"
# Versionish filter + numeric ordering (handles "1.2.3", "v1.2.3",
# "4.0.20.3014-ls5", "5.3.0_v2.1.2-ls487", "2026.11.2").
pick_newest() {
  local newest
  newest="$(sort -u | grep -E '^[v]?[0-9]+(\.[0-9]+){2,}(-ls[0-9]+|_[A-Za-z0-9._-]+)?$' \
    | awk '{ v=$0; sub(/^v/,"",v); split(v, a, /[-_.]/);
        k=sprintf("%010d.%010d.%010d.%010d.%010d", a[1],a[2],a[3],a[4],a[5]);
        print k "\t" v }' | sort | cut -f2 | tail -1)"
  [[ -z "$newest" ]] && newest="null"
  echo "$newest"
}

# http_chart_latest INDEX_URL CHART_NAME -> newest stable version or "null"
# Parses the repo index with awk (no yq/python): finds the `entries.<chart>`
# block and collects its 4-space-indented `version:` lines. Pre-releases are
# excluded — the index's first entry is not always the newest stable
# (e.g. cert-manager publishes alphas at the top).
http_chart_latest() {
  local versions
  versions="$(curl --silent --max-time 30 --show-error "$1" 2>/dev/null | awk -v chart="$2" '
    /^entries:/ { in_e = 1; next }
    in_e && /^[A-Za-z]/ { in_e = 0; cur = 0 }
    in_e && /^  [A-Za-z0-9_-]+:$/ {
      key = $0; sub(/^  /, "", key); sub(/:$/, "", key)
      cur = (key == chart); next
    }
    cur && /^    version: / { v = $0; sub(/^    version: /, "", v); print v }
  ')"
  printf '%s\n' "$versions" \
    | grep -vE '[-+]' \
    | pick_newest
}

# helmrepo_latest NAME CHART -> version or "null" (uses HR_URL/HR_TYPE maps)
helmrepo_latest() {
  local name="$1" chart="$2" url type base repo_path
  url="${HR_URL[$name]:-}"; type="${HR_TYPE[$name]:-default}"
  if [[ -z "$url" ]]; then echo "null"; return; fi
  if [[ "$type" == "oci" && "$url" == oci://* ]]; then
    base="${url#oci://}"
    local host="${base%%/*}" path="${base#*/}"
    # chart artifact lives at <url>/<chart> unless the URL already ends with it
    case "$path" in
      */"$chart") repo_path="$path" ;;
      *) repo_path="${path}/${chart}" ;;
    esac
    registry_latest_tag "$repo_path" "$host" "$AUTH_JSON"
  else
    http_chart_latest "${url%/}/index.yaml" "$chart"
  fi
}

# ---------- optional private-registry credentials ---------------------------
# The dockerconfigjson secret Flux already uses for the private cv-datastar
# chart (forgejo-registry-auth → fgit). Read by name —
# the worker's Role in flux-system is restricted with resourceNames.
AUTH_JSON="{}"
for s in forgejo-registry-auth; do
  merged="$(kubectl -n flux-system get "secret/$s" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d \
    | jq -c --argjson acc "$AUTH_JSON" '$acc * .auths' 2>/dev/null)"
  [[ -n "$merged" ]] && { AUTH_JSON="$merged"; log "loaded registry credentials from $s"; }
done

declare -A HR_URL HR_TYPE
while IFS=$'\t' read -r name type url; do
  HR_URL["$name"]="$url"; HR_TYPE["$name"]="${type:-default}"
done < <(kubectl -n flux-system get helmrepository -o json \
  | jq -r '.items[] | [.metadata.name, (.spec.type // "default"), .spec.url] | @tsv')

# Deployment index built once: image-ref (no tag) -> "ns name tag"
DEP_JSON="$(kubectl get deploy -A -o json)"

# ---------- part 1: HelmReleases --------------------------------------------

log "scanning HelmReleases"
ENTRIES="$TMP/entries.jsonl"; : > "$ENTRIES"

while IFS=$'\t' read -r ns name repo_kind repo_name chart_name want running; do
  latest="null"
  [[ "$repo_kind" == "HelmRepository" ]] && latest="$(helmrepo_latest "$repo_name" "$chart_name")"
  bump="$(bump_type "$running" "$latest")"
  range="none"
  case "$want" in
    *x|'*') range="auto-follow ($want)" ;;
  esac
  jq -cn --arg name "$name" --arg ns "$ns" --arg kind helmrelease \
    --arg running "$running" --arg latest "$latest" --arg bump "$bump" \
    --arg range "$range" \
    '{name:$name, ns:$ns, kind:$kind, running:$running, latest:$latest,
      bump:$bump, range:$range}' >> "$ENTRIES"
done < <(kubectl get helmrelease -A -o json | jq -r '.items[]
  | [ .metadata.namespace
    , .metadata.name
    , (.spec.chart.spec.sourceRef.kind // "-")
    , (.spec.chart.spec.sourceRef.name // "-")
    , (.spec.chart.spec.chart // "-")
    , (.spec.chart.spec.version // "*")
    , (.status.lastAttemptedRevision // "?") ] | @tsv')

# ---------- part 2: raw images ----------------------------------------------

log "scanning raw-manifest images"
if [[ -f "$RAW_CONFIG" ]]; then
  # config lines: {name, image, ns, note} — one app per YAML mapping
  while IFS=$'\t' read -r rname rimage rns rnote; do
    [[ -z "$rname" ]] && continue
    rtag=""
    [[ "$rimage" == *:* ]] && rtag="${rimage##*:}"
    image_base="${rimage%%:*}"

    # running tag: exact image match from the deployment index
    running_tag="$(jq -r --arg img "$image_base" '
      [ .items[].spec.template.spec
        | ((.containers // []) + (.initContainers // []))[]?
        | select((.image == $img) or (.image | startswith($img + ":")))
        | .image ] | first
      | if . == null then "?" else (. | split(":") | last // "latest") end' <<<"$DEP_JSON")"

    bump=""; latest="null"
    if [[ "$rnote" == "pinned" ]]; then
      bump="pinned"
    elif [[ "$rtag" == "latest" || "$running_tag" == "latest" ]]; then
      bump="tracks-latest"
    else
      host="${image_base%%/*}"
      repo_path="${image_base#*/}"
      case "$host" in
        lscr.io) host="ghcr.io"; repo_path="linuxserver/${repo_path#linuxserver/}" ;;
        *.*) ;;                      # dotted first element = real registry host
        *) repo_path="$image_base"; host="registry-1.docker.io" ;;  # owner/repo = docker hub
      esac
      latest="$(image_latest_via_label "$repo_path" "$host" "$AUTH_JSON")"
      if [[ -z "$latest" ]]; then
        latest="$(registry_latest_tag "$repo_path" "$host" "$AUTH_JSON")"
      fi
      bump="$(bump_type "$running_tag" "$latest")"
    fi
    jq -cn --arg name "$rname" --arg ns "$rns" --arg kind image \
      --arg running "$running_tag" --arg latest "$latest" --arg bump "$bump" \
      --arg range "${rnote:-none}" \
      '{name:$name, ns:$ns, kind:$kind, running:$running, latest:$latest,
        bump:$bump, range:$range}' >> "$ENTRIES"
  done < <(awk '
    /^- name:/ {
      if (name != "") print name "\t" image "\t" ns "\t" note
      name = $3; image = ""; ns = ""; note = ""; next
    }
    /^  image:/ { image = $2; next }
    /^  ns:/    { ns = $2; next }
    /^  note:/  { note = $2; next }
    END { if (name != "") print name "\t" image "\t" ns "\t" note }
  ' "$RAW_CONFIG")
else
  log "no raw-images config at $RAW_CONFIG — skipping part 2"
fi

# ---------- history ---------------------------------------------------------

WEEK="$(date +%G-W%V)"
summary="$(jq -s '{
  outdated: [.[] | select(.bump=="major" or .bump=="minor" or .bump=="patch")] | length,
  major: [.[] | select(.bump=="major")] | length,
  minor: [.[] | select(.bump=="minor")] | length,
  patch: [.[] | select(.bump=="patch")] | length}' "$ENTRIES")"
jq -n --arg w "$WEEK" --argjson s "$summary" '$s + {week: $w}' > "$TMP/today.json"

HIST_FILE="$OUT_DIR/history.jsonl"
touch "$HIST_FILE"
# keep max one entry per week, last 52 weeks
jq -s --slurpfile today "$TMP/today.json" \
  'map(select(.week != $today[0].week)) + $today | .[-52:]' \
  "$HIST_FILE" > "$TMP/hist.new" && mv "$TMP/hist.new" "$HIST_FILE"

# ---------- output ----------------------------------------------------------

HISTORY_JSON="$(jq -s '.' "$HIST_FILE")"
jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson hist "$HISTORY_JSON" \
  '{generated: $gen, entries: ., history: $hist}' "$ENTRIES" > "$OUT_DIR/status.json.tmp"
mv "$OUT_DIR/status.json.tmp" "$OUT_DIR/status.json"
log "wrote $OUT_DIR/status.json ($(wc -l < "$ENTRIES") entries)"
