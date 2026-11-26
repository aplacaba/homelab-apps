# Forgejo (Git, Actions, registry) and the CI runner

Forgejo is the self-hosted Git server, Actions CI and container/OCI registry at
`https://fgit.watchtoken.org`. It's a HelmRelease in `clusters/pk3s/forgejo/` on the central
PostgreSQL (`192.168.254.104`, database and role `forgejo`, not a superuser). The
`gitea-shared-storage` PVC is 10Gi. Services: `forgejo-http:3000` and `forgejo-ssh:22`. Versions
are in [inventory.md](inventory.md).

## Registry: pull from the public hostname

App CI pushes images to `10.43.55.141:3000`, the `forgejo-http` ClusterIP over plain HTTP. The
kubelet **can't** pull from there, because the nodes have no containerd mirror for the ClusterIP.
Only `k3s-master` has `/etc/rancher/k3s/registries.yaml`, and it mirrors `192.168.254.50:30080`;
`k3s-media` has none (checked 2026-11-26). Pull from `fgit.watchtoken.org`, which is the same
registry over HTTPS (tunnel → Traefik → `forgejo-http:3000`), with an imagePullSecret in the
workload's namespace. Never put the ClusterIP in an image reference.

Flux pulls the `cv-datastar` chart from this registry using `forgejo-registry-auth` in
`flux-system` ([patterns.md](patterns.md#charts-from-the-forgejo-oci-registry)).

## SSH

| Path | Address | How |
|---|---|---|
| **LAN** | `ssh://git@192.168.254.50:30022` | NodePort 30022 on the `forgejo-ssh` Service (in `helmrelease.yaml`) |
| **Public** | `git@ssh.watchtoken.org` | Cloudflare Tunnel straight to `forgejo-ssh` (no Traefik), set in Terraform (`tunnel.tf` + `dns.tf`) |

The clone URL shown in the UI is `git@ssh.watchtoken.org`. Client setup (once per machine):

```bash
# 1. Install cloudflared
# 2. In ~/.ssh/config:
#      Host ssh.watchtoken.org
#        ProxyCommand cloudflared access ssh --hostname %h
# 3. Authenticate (opens a browser)
cloudflared access login ssh.watchtoken.org
```

To check: `ssh -T -p 30022 git@192.168.254.50` (LAN) and `ssh -T git@ssh.watchtoken.org`. Both
should print the Forgejo greeting.

## Version policy (LTS)

Forgejo stays on the **15.0 LTS** line (supported until 2027-07-15). Chart 17.3.3 ships 15.x, so
there's no image override. This was decided 2026-11-26 instead of moving to 17.0, a short-lived
stable release (EOL 2027-01-28) that would force 18 and then 19 within months. The next major hop
is planned as **15 → 19 LTS** (19.0 is due 2027-04-15).

Findings from the 15 → 17 research, to re-check for 19:

- Jumping straight across majors is supported, so no intermediate stop is needed. Migrations only
  go forward, so rollback means restoring the `forgejo` DB dump and the PVC backup taken just
  before.
- It needs PostgreSQL 14 or later. The central PG 18.3 is fine.
- The chart's init containers (`configure-gitea` etc.) call `gitea migrate`, `gitea admin user
  list|create|change-password` and `environment-to-ini`. The 17.0.2-rootless image still ships the
  `gitea` wrapper and those flags (uid 1000), so a plain `image.tag` override works on chart 17.3.3.
- 16.0: git hooks are centralised (the old per-repo hooks are optional cleanup). The container no
  longer defaults `REVERSE_PROXY_TRUSTED_PROXIES = *` (we don't use reverse-proxy auth). Mirrors
  that follow HTTP redirects now fail. Skipped checks report as `skipped`.
- 17.0: durations in `app.ini` are parsed strictly, the default log file is `forgejo.log`,
  absolute links in repo markdown resolve from the repo root, and action-run webhook events are
  deprecated (existing webhooks have to be re-created by hand on the workflow run/job events).
  Avoid 17.0.0.
- Before any major: `pg_dump -Fc` of `forgejo` on 192.168.254.104, plus `forgejo dump` or a PVC
  copy. Afterwards run `forgejo doctor check --all`, then check the web UI, SSH (LAN 30022 and
  `ssh.watchtoken.org`), the OCI registry and an Actions run.

## PostgreSQL migration (2026-08-11) and rollback

The SQLite-era data was moved to PostgreSQL on 2026-08-11. A snapshot taken at shutdown is still
on the PVC at `/data/backup/forgejo-2026-08-11/` (checked 2026-09-13: checkpointed `forgejo.db`,
`forgejo-data.sql`, `counts-sqlite.txt`, `forgejo-dump.zip` ≈ 256 MB). It stays until the first
successful monthly restore test ([postgres.md](postgres.md)), and for at least 7 days.

Rollback, only if a check fails. File operations run from a pod that mounts the PVC (image
`nouchka/sqlite3`, `gitea-shared-storage` at `/data`), because forgejo is scaled to 0 in both
cases.

- **Phase A failure (nothing lost, forgejo never started on PG):**
  1. `rm -f /data/gitea/forgejo.db-wal /data/gitea/forgejo.db-shm`
  2. `cp -a /data/backup/forgejo-2026-08-11/forgejo.db* /data/`. The live DB path is
     `/data/forgejo.db`, **not** `/data/gitea/forgejo.db`.
  3. Revert `gitea.config.database` to `sqlite3` in git, push and merge.
  4. `flux reconcile kustomization flux-system -n flux-system --with-source`
  5. Check that the release is still suspended and the staged spec shows `DB_TYPE: sqlite3`.
  6. `flux resume`, then check that it starts on SQLite.
- **Phase B hard failure (writes after the cutover are lost):** run
  `flux suspend helmrelease forgejo -n forgejo` **first**, scale to 0, then do the same file
  restore, git revert and checks as above, then `flux resume`. The PostgreSQL database is kept as
  the copy of record for writes made after the cutover.

Rolling back to SQLite loses nothing only if forgejo hasn't accepted any writes on PostgreSQL yet.
Once it has, a rollback discards them.

## CI runner

In `forgejo-runner/`: runner 13.2.2 with a Docker-in-Docker sidecar (docker 29.10-dind). It
connects to `forgejo-http.forgejo.svc:3000`. Labels `ubuntu-latest` and `ubuntu-22.04` both map to
`docker://node:22-bookworm`.

- **The wrenix chart 0.7.6 is its final release.** It won't render unless `knownLastVersion: true`
  is set, and it still defaults to runner 12.7.3, so the runner version is pinned with `image.tag`.
  Bumping that tag reuses the registration stored in the `forgejo-runner-config` Secret.
- **Labels are set at `runner.config.file.runner.labels`** (not `runner.file.runner.labels`). If
  they don't match the workflow's `runs-on`, jobs wait in the queue forever.
- **Resources** are sized for JVM builds (Clojure/ClojureScript). Job containers get `--cpus=2
  --memory=4g` through `runner.config.file.container.options`. Limits are 2000m/2Gi for the runner
  and 4000m/4Gi for dind. Requests stay small (100m, 128Mi/256Mi) to leave room on `k3s-master`.

Workflow rules since runner v13 (upgraded from 12.7.3 on 2026-11-26):

- `::set-output`, `::set-env` and `::add-path` are gone (they warn and do nothing). Write to
  `$GITHUB_OUTPUT`/`$FORGEJO_OUTPUT`, `$GITHUB_ENV`/`$FORGEJO_ENV` and `$FORGEJO_PATH` instead.
- Expression errors (for example a `format()` with too few arguments) and matrix `exclude`s that
  match nothing now fail the job or workflow instead of warning.
- The `DOCKER_USERNAME`/`DOCKER_PASSWORD` secrets no longer log in to job-image registries. Use
  `jobs.<id>.container.credentials` instead. A `docker login` inside a `run:` step, as cv-datastar
  does, still works.
- Config `container.network_mode` and the `GITEA_RUNNER_*` env vars are ignored. Docker 25 or later
  is required.

### Runner operations

```bash
kubectl get pods -n forgejo-runner
kubectl logs -n forgejo-runner deploy/forgejo-runner -c runner --tail=10   # "declared successfully", "poller launched"
kubectl exec -n forgejo-runner deploy/forgejo-runner -c runner -- wget -q -O- \
  http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1/repos/forgejo-admin/cv/actions/runs?limit=3
kubectl exec -it -n forgejo-runner deploy/forgejo-runner -c runner -- /bin/sh   # or -c dind
```

The Forgejo UI also lists runners under Settings → Actions → Runners.

- **The runner can stop picking up jobs after a cancellation.** The poller process stays alive but
  stops fetching. You'll see `status=waiting` in Forgejo with no recent runner logs. Fix it with
  `kubectl rollout restart deploy/forgejo-runner -n forgejo-runner`. The new pod registers in about
  10s and picks up queued jobs.
- **To change labels, the runner must register again.** Delete the old registration and restart:
  `kubectl delete secret forgejo-runner-config -n forgejo-runner`, then the rollout restart above.
