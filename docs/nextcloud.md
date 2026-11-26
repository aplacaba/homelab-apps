# Nextcloud

File sync and sharing. A HelmRelease in `clusters/pk3s/nextcloud/` with the MariaDB and Redis
subcharts. LAN `sync.local`, public `sync.watchtoken.org`. Versions are in
[inventory.md](inventory.md).

## Reverse-proxy settings

Behind Traefik, Nextcloud must trust the proxy's forwarded headers. The chart's
`reverse-proxy.config.php` reads env vars (`OVERWRITEHOST`, `OVERWRITECLIURL`, `TRUSTED_PROXIES`,
`OVERWRITEPROTOCOL`) and writes them to `$CONFIG`. `nextcloud.host` only feeds
`NEXTCLOUD_TRUSTED_DOMAINS`. It does **not** set `overwritehost` or `trusted_proxies`.

So set these explicitly under `nextcloud.extraEnv`:

- `OVERWRITEHOST=sync.watchtoken.org`
- `OVERWRITECLIURL=https://sync.watchtoken.org`
- `TRUSTED_PROXIES=10.42.0.0/16` (the k3s pod CIDR)

Without them, sync clients get DAV hrefs pointing at `localhost` or `http` and fail with "Files not
accessible on server". When this happens, `config.php` shows
`overwrite.cli.url => 'https://localhost'` and no `overwritehost`/`trusted_proxies` entries.

To fix a running instance before Flux reconciles, run these as www-data inside the pod:

```bash
php occ config:system:set overwritehost --value=sync.watchtoken.org
php occ config:system:set trusted_proxies 0 --value=10.42.0.0/16
php occ config:system:set overwrite.cli.url --value=https://sync.watchtoken.org
```

`overwritehost` takes only one value. Because it's set to `sync.watchtoken.org`, share links and
WebDAV endpoints use the public host even when you're on `.local`. That's expected, because the
public hostname is the canonical one, so don't work around it.

## Uploads

The Cloudflare free tier limits request bodies through the tunnel to about 100 MB. Large uploads
(videos, big archives) fail on `sync.watchtoken.org` but work on `sync.local`. Photos and documents
aren't affected.

## Backup

Nextcloud uses **three** volumes, all `local-path` with reclaim `Delete`:

| PVC | Size | Contents |
|---|---|---|
| `nextcloud-nextcloud` | 100Gi | `/var/www/html` and the data |
| `data-nextcloud-mariadb-0` | 8Gi | the database |
| `redis-data-nextcloud-redis-master-0` | 5Gi | cache, can be rebuilt |

Back up the data and the database together, in maintenance mode: `occ maintenance:mode --on`, dump
the DB, copy the data, then `--off`. Backing up the data without the database means data loss when
you restore.

The chart's `helm.sh/resource-policy: keep` annotation stops `helm uninstall` from deleting the
PVCs, but Flux pruning still deletes them if nextcloud is removed from the root kustomization. Back
up out of band before that.
