# HRIS — chart auto-update (pre-1.0)

Runbook for the HRIS chart update automation. The app itself (access, database,
documents, secrets) is documented in the HRIS section of [AGENTS.md](../AGENTS.md).

## Why this exists

HRIS is deployed from its own Helm chart (`aplacaba/charts/hris`, published by
the private app repo `aplacaba/tala-hris` on a `vX.Y.Z` tag), and the
HelmRelease pins that chart exactly — `image.tag: ""` means the chart's
`appVersion` picks the image, so **a chart bump is the whole release**.

Pinning exactly is deliberate (the app holds applicant PII), but during the
pre-1.0 churn it means someone has to notice every release. This automation does
the noticing without giving up the exact pin: it moves the pin, it never widens
it to a semver range.

## How it runs

`.github/workflows/hris-chart-update.yml` — cron every 6 hours
(`17 */6 * * *`) plus `workflow_dispatch` — runs `.github/scripts/hris-chart-update.sh`:

1. read the `version:` pin out of `clusters/pk3s/hris/helmrelease.yaml`;
2. list the published tags of `ghcr.io/aplacaba/charts/hris`;
3. pick the newest **exact stable semver** with `pin < version < 1.0.0`;
4. gate the candidate (below);
5. if there is one, rewrite the pin, push the branch
   `automation/hris-chart-bump` and open — or refresh — a PR titled
   `chore(hris): bump chart <old> → <new>`.

Merging that PR is the deploy: Flux syncs the new pin on its next pass and the
pod rolls onto the new image (migrations run at container start, single replica,
`strategy: Recreate`).

### Gates before a candidate is proposed

Both exist because a bad bump lands on an app holding real PII:

- **The chart must be pullable** — the manifest and the `Chart.yaml` inside the
  chart layer have to come back from GHCR, so a half-published chart is skipped.
- **The image must exist** — the image tag named by the candidate's `appVersion`
  must already be present in `ghcr.io/aplacaba/tala-hris`. Without this check an
  auto-bump could land a chart whose image is not published and the pod would hit
  `ImagePullBackOff` (HRIS gotcha 3 in AGENTS.md). When the chart is out but the
  image is not, the script exits 3 and the next run picks it up.

Pre-releases (`0.2.0-rc1`) and non-semver tags (`latest`) are ignored, and the
script refuses to run at all if the pin stops being an exact `X.Y.Z`.

## 1.0.0 is the freeze line

Candidates must be below `1.0.0`. Once a 1.0.0+ chart is published the workflow
proposes nothing and says so in the job summary — a major release gets a
deliberate human bump, exactly like every other pinned app in this repo.

Closing a bump PR without merging suppresses **that exact version** on later
runs (the workflow matches the PR title). A newer version still gets its own PR,
so "not this one" and "not ever" stay distinguishable.

## Secrets

The workflow runs off `GH_PAT` alone:

| Capability | On | Why |
|---|---|---|
| `contents: write` | `GH_PAT`, this repo | pushing the bump branch (a `GITHUB_TOKEN` push would not trigger Flux's webhook) |
| `pull requests: write` | `GH_PAT`, this repo | opening/refreshing the bump PR |
| `read:packages` | `GH_PAT`, the private `aplacaba/charts` package | listing chart tags and reading the chart layer |

`read:packages` is a **classic** PAT scope, and a `repo`-scoped token alone is
not enough — GHCR answers the tag list with `permission_denied`. A fine-grained
PAT instead needs *Contents: Read and write*, *Pull requests: Read and write*
and *Packages: Read*. Editing the scopes of an existing PAT does not change its
value, so the repo secret stays valid.

The registry read also accepts a dedicated `GHCR_READ_TOKEN` (used when set,
`GH_PAT` otherwise) if you would rather keep package access off the main token.

If `GH_PAT` cannot open PRs, the workflow retries the `gh pr create`/`gh pr edit`
with the workflow token — that path needs the repository setting *Allow GitHub
Actions to create and approve pull requests* (currently **off** in this repo, so
as things stand `GH_PAT` must be able to open the PR itself).

## Running it by hand

```bash
# report only — prints the pin, the newest chart below 1.0.0, and the gates
GHCR_TOKEN=<pat with read:packages> ./.github/scripts/hris-chart-update.sh

# rewrite the pin in place (the script only edits the file; committing is yours)
GHCR_TOKEN=<pat with read:packages> ./.github/scripts/hris-chart-update.sh --apply
```

The same token the cluster uses to pull the chart (`GHCR_TOKEN` in
`~/.secrets/hris.env`, sealed into `ghcr-registry-auth` and `hris-ghcr`) works
for a local run.
