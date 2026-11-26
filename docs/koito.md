# Koito / Multi-Scrobbler (scrobble stack)

Self-hosted scrobbling for **Apple Music (iPhone)** and **YouTube Music (iPhone +
browser)**, deployed 2026-10-04. **Koito** is the archive + stats UI; **Multi-Scrobbler**
(MS) is the bridge that collects from the cloud services and pushes into Koito over the
LAN. Nothing here is exposed publicly.

## Architecture

```
 Apple Music (iPhone)                    YouTube Music (iPhone + browser)
   FastScrobbler                            (same Google account)
        │ fastscrobbler → listenbrainz.org         │
        ▼                                          ▼
   ListenBrainz.org ──┐              ┌── MS `ytmusic` source (YTM_COOKIE)
                      ▼              ▼
              multi-scrobbler :9078 (scrobbler.local, LAN-only)
                 client: koito → http://koito.koito.svc:4110
                      │
                      ▼
                 Koito :4110 (koito.local, LAN-only; archive + stats)
```

| Component | Version | Namespace | Route |
|---|---|---|---|
| Koito | `gabehf/koito:v0.3.2` | `koito` | `http://koito.local:30080` (LAN) |
| Multi-Scrobbler | `foxxmd/multi-scrobbler:0.21.3` | `multi-scrobbler` | `http://scrobbler.local:30080` (LAN) |

Add `192.168.254.50 koito.local scrobbler.local` to `/etc/hosts` on client machines.

- **Apple Music path:** FastScrobbler (iOS, App Store) submits plays to
  ListenBrainz.org; MS's `listenbrainz` source polls that account and re-scrobbles to
  Koito. FastScrobbler has no custom-server option, so the ListenBrainz hop is
  required for iPhone plays.
- **YouTube Music path:** MS's `ytmusic` source uses a cookie session and covers the
  iPhone app and the browser via the same account history.
- **Never expose either app:** MS has no authentication and upstream explicitly warns
  against public exposure; Koito is LAN-only by design. There are no tunnel/DNS
  entries for either.

## Secrets & rotation

All values live in one operator file, `~/.secrets/koito.env` (mode 600), sealed by
`scripts/seal-koito-secrets.sh` (values are never echoed):

| Key | Purpose |
|---|---|
| `KOITO_DEFAULT_USERNAME` / `KOITO_DEFAULT_PASSWORD` | first-boot Koito admin — **only used on an empty database** |
| `KOITO_USER` / `KOITO_TOKEN` | Koito user + API key used by MS |
| `SOURCE_LZ_USER` / `SOURCE_LZ_TOKEN` | ListenBrainz username + user token (Apple Music path) |
| `YTM_COOKIE` | YouTube Music cookie session |

**Rotating the YouTube cookie (the routine case):**

```bash
# 1. Fresh incognito session at music.youtube.com → DevTools → Network → any request
#    → copy the entire `Cookie:` request header value into a file (mode 600).
# 2. Import it:
./scripts/import-ytm-cookie.sh ~/path/to/capture.txt
# 3. Re-seal AND roll the pod:
./scripts/seal-koito-secrets.sh --bump
#    (--bump increments the `secrets-revision` annotation in the MS Deployment)
# 4. Commit and push:
git add clusters/pk3s/multi-scrobbler clusters/pk3s/koito && \
  git commit -m "multi-scrobbler: rotate YouTube cookie" && git push
```

Env vars are read at container start — **re-sealing alone changes nothing**; the
`secrets-revision` bump is what rolls the pod (raw-manifest equivalent of the chart
`secretsChecksum` pattern). The Koito first-boot password is not affected by re-seals:
rotate it in the UI (Settings → account).

**Cookie-only rotation without `koito.env` or the helper scripts** (used 2026-11-26, when
neither was on the workstation). `kubeseal --merge-into` replaces just the `YTM_COOKIE`
key and leaves the Koito/ListenBrainz values untouched:

```bash
# cookie file = the raw Cookie header value, mode 600, outside the repo
python3 -I -c 'import sys,json;v=open(sys.argv[1]).read().strip();print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"multi-scrobbler-secrets","namespace":"multi-scrobbler"},"type":"Opaque","stringData":{"YTM_COOKIE":v}}))' <cookie-file> \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
      --format yaml --merge-into clusters/pk3s/multi-scrobbler/sealedsecret-multi-scrobbler.yaml
# then bump `secrets-revision` in clusters/pk3s/multi-scrobbler/deployment.yaml, commit, push
```

Capture the cookie **signed in**. A signed-out header has only ~5 visitor cookies (`YSC`,
`VISITOR_INFO1_LIVE`, …); a valid one is ~2 KB and includes `SAPISID`, `__Secure-3PAPISID`,
`SID`, `LOGIN_INFO`. Afterwards, close the incognito window **without signing out**:
signing out or reusing that session makes Google rotate the cookie. The first cookie (Oct 4)
was dead by Oct 28 and went unnoticed for weeks. A failing source logs `Cookie-based
authentication failed` every 20 min, and MS stops retrying until the pod restarts.

**Telegram alerts tell you when to rotate** (added 2026-11-27). A `ServiceMonitor` scrapes MS's
Prometheus metrics at `/api/metrics` (`/metrics` is the SPA), and `prometheusrule.yaml` in
`clusters/pk3s/multi-scrobbler/` defines:

| Alert | Fires when | Meaning |
|---|---|---|
| `MultiScrobblerSourceUnhealthy` | `multiscrobbler_source_issues > 0` for 30m | A source is unauthenticated or not polling. For `ytmusic` that means the cookie expired, so rotate it as above. It covers `listenbrainz` too. |
| `MultiScrobblerNoYouTubeMusicPlays` | no `ytmusic` plays discovered in 3d (after 3d of data) | It's authed but finding nothing. Rotate if you *have* been listening; otherwise ignore it. |

`source_issues` is +1 for "requires auth but not authed" and +1 for "should poll but isn't", so
`2` is the dead-cookie state. If a dashboard password is ever set at `/setup`, check that
`/api/metrics` still answers without auth; otherwise the scrape fails and `TargetDown` fires
instead.

Quick manual check: `kubectl -n multi-scrobbler port-forward deploy/multi-scrobbler 9078` →
`curl -s localhost:9078/api/metrics | grep source_issues` (all `0` = healthy).

## Operations

```bash
kubectl -n koito get pods,pvc
kubectl -n multi-scrobbler get pods,pvc
kubectl -n multi-scrobbler logs deploy/multi-scrobbler --tail=100     # source status
```

- MS dashboard (`http://scrobbler.local`) shows each source as Monitoring / Fully
  Initialized, recent plays, and the dead-scrobble queue (retried every 5 min and
  persisted across restarts).
- Koito UI (`http://koito.local`) — log in with the credentials from
  `~/.secrets/koito.env`.

## Import / backup / restore

- **Import:** place a ListenBrainz/Maloja/Last.fm/Spotify export inside the `import/`
  folder of the Koito data directory (`/etc/koito/import/`) and restart the pod.
  MusicBrainz lookups are throttled at 1 req/s for large imports; `KOITO_DISABLE_MUSICBRAINZ=true`
  makes it faster but skips alias enrichment.
- **Backup:** Koito exposes the export API (`/apis/web/v1/export`); the SQLite DB +
  image cache live on the `koito-data` PVC (`/etc/koito`). MS state (caches + retry
  queue) is on `multi-scrobbler-data`.
- **Both PVCs are `local-path` with reclaim `Delete`** — removing either app from the
  root kustomization prunes its volume. Copy the data out of band (quiesced SQLite
  copy or export API) before any destructive change.
- ListenBrainz also holds a copy of the Apple Music history and can export it.

## Upgrades

Both images are pinned by tag in Git. Before bumping Koito, back up `/etc/koito` —
v0.3.1+ carried an image-cache migration and upstream warns about data migrations
between releases. MS releases frequently; read the changelog before bumping it.
0.19.2 → 0.21.3 (2026-11-26): 0.20.0 ran an **irreversible** DB migration, and 0.21.0
switched to a distroless non-root image and added dashboard auth (see gotcha 1).
Pre-upgrade backup (online `node:sqlite` backup of `ms.db`, integrity ok, plus
`yti-ytmusic/`): `~/backups/multi-scrobbler/pre-0.21.3/ms-config-pre-0.21.3.tgz`
(+ `.sha256`) on the workstation. Rollback = `replicas: 0`, restore that tarball into
the PVC (helper pod, `chown 1000:1000`), pin 0.19.2 with `PUID`/`PGID` back, and
`replicas: 1`. A bare image revert will not work, because 0.19.2 cannot read the
migrated DB.

## Gotchas

1. **MS ≥ 0.21 runs non-root (distroless).** There's no s6 init or shell, and
   `PUID`/`PGID` are ignored. The pod sets `runAsUser/runAsGroup: 1000` (the owner of
   the existing `/config`) and drops ALL capabilities. Without a password the dashboard
   is "insecure" (full access on `.local`); set one at `/setup`. `/api/health` returns
   500 if any source is unauthenticated, so the probes stay on `/`.
2. **IPv4-only cluster vs Node happy-eyeballs.** MS runs with
   `NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"`.
   Without it, Node's 250 ms attempt timeout races to unreachable AAAA addresses and
   aborts slow connections — symptom: the ListenBrainz source fails at startup with
   `ETIMEDOUT`. Don't drop the flags.
3. **YouTube Music is unofficial.** Google can break it; expect occasional
   missed/duplicate scrobbles and cookie invalidation (renewal above).
4. **FastScrobbler's iOS backgrounding is best-effort.** Its history scans recover
   most missed plays, not all.
5. **ListenBrainz listens are public** (the project has no private-listens mode);
   Koito is the private archive.
6. **The login gate is off**, so Koito's stats endpoints are readable on the LAN;
   mutations and API submissions still require a session or API key. If the gate is
   ever enabled (`KOITO_LOGIN_GATE=true`), API keys continue to work.
