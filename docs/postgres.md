# Central PostgreSQL (192.168.254.104)

A dedicated PostgreSQL 18.3 box (LXC 102 `postgresql.hl` on Proxmox), **not** managed by this
repo. These apps use it:

| Database | Role | App |
|---|---|---|
| `forgejo` | `forgejo` | [forgejo.md](forgejo.md) |
| `immich` | `immich` | [media.md](media.md) (vector 0.8.6, vchord 1.1.1, cube, earthdistance) |
| `windshift` | `windshift` | [windshift.md](windshift.md) |
| `hris_ats_production{,_cache,_queue,_cable}` | `hris_ats` | HRIS app removed 2026-11-26, databases still there (real PII) |
| `atuin` | — | app removed 2026-11-09, database still there |

## Nightly backups

At 02:30, `/usr/local/bin/pg-backup.sh` runs from the `postgres` user's crontab (local peer auth)
and backs up `forgejo`, `immich` and `windshift`. `atuin` is backed up until it's dropped. The HRIS
databases were never added.

- It dumps with `pg_dump -Fc --snapshot` and records primary-table row counts in the **same**
  repeatable-read snapshot, so each `backup.log` line describes exactly what is in that dump. For
  `forgejo` the tables are `user`, `repository`, `issue` and `action`; for `immich`, `users` and
  `assets`.
- On failure it prints `pg_backup FAILED: <db>` to stdout (cron mails the admin), logs a `FAILED`
  line and timestamps `/backups/postgres/last-failure`.
- Dumps are kept for 14 days (`find -mtime +14 -delete`). `/backups/postgres` is owned by
  `postgres:postgres`.

## Monthly restore test (manual)

For each database:

1. Restore the newest dump into a scratch DB with `pg_restore --exit-on-error`.
2. Compare the restored row counts with the `backup.log` entry for that exact dump file.
3. Drop the scratch DB.

Any failure (a non-zero `pg_restore` exit, a count query that fails, or counts that don't match)
writes a FAILED line and the `last-failure` sentinel, so it alerts the same way as the nightly run.
A successful test also ends the retention hold on Forgejo's migration snapshot
([forgejo.md](forgejo.md#postgresql-migration-2026-08-11-and-rollback)).

## The `.104` address is a DHCP reservation

The container runs `ip=dhcp`. `.104` comes from a reservation on the Globe router (MAC
`BC:24:11:11:A0:89`). If the router loses that reservation, the container gets a different lease,
and every app that hardcodes `.104` (windshift, forgejo, immich) fails with
`dial tcp 192.168.254.104:5432: connect: connection refused`, while the database and its local
backups stay healthy.

To fix it:

1. Re-add the reservation on the router.
2. Renew the lease inside the LXC: `dhclient -r eth0 && dhclient eth0`. Check with
   `ip -4 addr show eth0`.
3. If the apps keep flapping, a device that held `.104` before may still answer ARP for it until
   its own lease renews. Kick it off (toggle its Wi-Fi) or flush the k3s nodes' neighbour entry.
