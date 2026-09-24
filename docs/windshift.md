# Windshift (work management / Jira alternative)

Deployed 2026-09-24, replacing Papra (backup of the Papra PVC in
`~/backups/papra-2026-09-24/` on the admin workstation). Single Go container —
`ghcr.io/windshiftapp/windshift:v0.8.8`, scratch image, UID 65534, port 8080 —
with the database on the central PostgreSQL box (`192.168.254.104`, db + role
`windshift`) and attachments/plugins on a 5Gi `local-path` PVC. Raw manifests
in `clusters/pk3s/windshift/`.

### Access

| Path | Address | How |
|---|---|---|
| **Public** | `https://windshift.watchtoken.org` | Cloudflare tunnel → Traefik websecure (wildcard cert). **The only route** — no `windshift.local` (Windshift rejects plain-HTTP non-localhost origins; guide gotcha #18) |

Auth: the admin account was claimed on 2026-09-24 (one-shot first-run setup;
further users are created admin-side). During the claim, `/api/setup` was
temporarily blocked at Traefik (ipAllowList `127.0.0.1/32` → 403) and the
account was created over a port-forward; that block has been removed
(guide gotcha #19). Passkeys bind to `WEBAUTHN_RP_ID=windshift.watchtoken.org`
(set explicitly — the container hostname is the container ID).

If the database is ever rebuilt from scratch, re-add the block before the
public URL finds the fresh instance, then claim it with:

```bash
kubectl port-forward -n windshift deploy/windshift 8080:8080
# open http://localhost:8080, create the admin account, then remove the block
```

### Database

- `DB_TYPE=postgres` → `POSTGRES_HOST=192.168.254.104`, `POSTGRES_USER`/
  `POSTGRES_DB=windshift`, `POSTGRES_SSLMODE=disable`, password in the
  `windshift-secret` SealedSecret (keys `POSTGRES_PASSWORD`, `SSO_SECRET`;
  plaintext source of truth `~/.secrets/windshift.env`, mode 600).
- `windshift` is in the nightly `pg-backup.sh` run (02:30, 14-day retention);
  restore per the guide's monthly restore-test procedure.

### Attachments

- `ATTACHMENT_PATH=/data/attachments` on the `windshift-data` PVC (5Gi,
  reclaim `Delete`). Quiesced backup: commit `replicas: 0` → wait for pod
  termination → copy `/data` out with a read-only helper pod → `replicas: 1`.
- Public-tunnel uploads are capped at ~100 MB (guide gotcha #22).

### Gotchas

- **Scratch image needs the tmpfs:** `/tmp` is a 64Mi memory `emptyDir`;
  large multipart uploads spill there and the coding-agent runner executes a
  git askpass helper from it (`exec` is required — k8s memory emptyDir is
  exec by default, unlike Docker). Startup fails without it.
- **Setup block (removed):** the temporary `windshift-block-setup` route is
  gone and the public setup wizard now completes/opens normally. Re-add it
  (ipAllowList `127.0.0.1/32`) only for a from-scratch rebuild, since setup
  mode disables authentication until the first admin exists.
- **Memory:** `WINDSHIFT_MEMORY_LIMIT_MB` defaults to 2048 (min 512); the
  container limit must be ≥ the budget (2Gi set). Process budget is a soft
  target, not a hard RSS ceiling.
