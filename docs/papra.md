# Papra (document archiving / OCR)

Document archiving / OCR (replaced paperless-ngx on 2026-08-31). Papra
(papra-hq/papra) runs as a single Node container with SQLite — no Redis, no
Celery. Pinned image `ghcr.io/papra-hq/papra:26.6.1-rootless` (tags are
CalVer), port 1221, `strategy: Recreate` (SQLite tolerates one writer),
uid/gid/fsGroup 1000. Raw manifests in `clusters/pk3s/papra/`.

### Access

| Path | Address | How |
|---|---|---|
| **Public** | `https://papra.watchtoken.org` | Cloudflare tunnel → Traefik websecure (wildcard cert). **The only route** — no `papra.local` exists (Better Auth Secure cookies break plain-HTTP LAN login; see gotcha #18) |

Auth: Better Auth email/password; signup permanently blocked at Traefik
(`papra-block-signup` ipAllowList → 403; gotcha #19). First user is admin.
`AUTH_SECRET` lives in the `papra-secret` SealedSecret (`OWLRELAY_API_KEY` /
`INTAKE_EMAILS_WEBHOOK_SECRET` keys remain but are unused since the relay
retirement).

### Document ingestion (folder)

OwlRelay email intake was retired on 2026-09-01 — emails now reach Papra via
drop-folder ingestion. The Deployment enables
`INGESTION_FOLDER_IS_ENABLED=true` and mounts hostPath
`/home/admin/papra-ingest` (k3s-master) at `/app/ingestion`. Layout is
per-org: files must land in `<root>/<org_id>/` (org id = `org_...` in the
Papra URL, currently `org_hqr8cc1ym66zuo4kj6vgk8lu`). The watcher is
recursive (native inotify; fallback
`INGESTION_FOLDER_WATCHER_USE_POLLING=true` if drops are missed). After a
successful import the source file is **deleted** (default strategy); failures
move to `<org_id>/ingestion-error/`, and duplicate content is skipped but
still post-processed.

**Input pipeline (outside this repo):** on k3s-master, an IMAP downloader
(admin/systemd) pulls mailbox attachments and runs the PDF unlocker, dropping
the unlocked files into
`/home/admin/papra-ingest/org_hqr8cc1ym66zuo4kj6vgk8lu/`. admin runs as uid
1000 — same uid as the rootless Papra pod, so both sides write the folder
with no permission dances; the downloader must not write outside the org
subdir (other files are ignored). The hostPath lives on the node, not on the
`papra-data` PVC — a Papra rebuild never touches the drop folder.

### Backup

Everything (SQLite db + document originals) lives on one PVC (`papra-data`,
`/app/app-data`, local-path, **reclaim `Delete`** — gotcha #20): commit
`replicas: 0` → wait for pod termination → mount the PVC read-only in a
helper pod and copy `/app/app-data` out → commit `replicas: 1`. No Papra CLI
export exists (import only).

### Gotchas

- **Locked PDFs are stored but not searchable:** Papra's pdf extractor
  (pdf.js, no password callback) throws on encrypted PDFs — the original
  uploads untouched but gets no OCR text. The drop-folder pipeline runs the
  PDF unlocker on every attachment *before* dropping it into the org folder,
  so locked PDFs should never reach Papra; if one lands directly (manual
  drop), it stays unsearchable.
- **Papra supports SQLite/LibSQL only** — no Postgres driver; the central
  PostgreSQL box cannot host it.
- **Probes:** readiness `GET /api/health` (db-aware), liveness
  `GET /api/ping`.
