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
| Multi-Scrobbler | `foxxmd/multi-scrobbler:0.19.2` | `multi-scrobbler` | `http://scrobbler.local:30080` (LAN) |

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
between releases. MS releases frequently; read the changelog before moving 0.19.2.

## Gotchas

1. **MS needs default capabilities.** Its s6 init chowns `/config` and drops to
   `PUID`/`PGID`; `capabilities: drop: [ALL]` breaks it
   (`setgroups: Operation not permitted`). Koito keeps full drop-ALL.
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
