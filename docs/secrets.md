# Secret management (SealedSecrets)

Secrets are never committed in plaintext. They are encrypted with the `sealed-secrets`
controller's public key and committed as `SealedSecret` objects. The controller decrypts them
in the cluster into normal `Secret`s that apps use. Flux applies a `SealedSecret` like any other
manifest, so nothing in the Flux setup is specific to secrets.

| Component | Detail |
|---|---|
| Controller | `sealed-secrets` namespace, chart `2.22.x` from the `bitnami` OCI repo (controller 0.41.2, image `docker.io/bitnami/sealed-secrets-controller`) |
| CLI | `kubeseal` at `~/.local/bin/kubeseal` |
| Example | `clusters/pk3s/cloudflared/sealedsecret.yaml` becomes `Secret cloudflared/tunnel-credentials` |
| Helpers | `scripts/seal-koito-secrets.sh`, `terraform/scripts/seal-and-commit.sh`. `scripts/` is untracked and lives only on the workstation |

## Seal a new secret

The plaintext never touches git, chat or shell history:

```bash
cd ~/Projects/homelab-apps
printf 'Secret value: '; IFS= read -rs VAL; echo
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: <name>\n  namespace: <ns>\ntype: Opaque\nstringData:\n  key: %s\n' "$VAL" \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
             --format yaml --namespace <ns> \
  > clusters/pk3s/<ns>/sealedsecret.yaml
unset VAL
```

Add `sealedsecret.yaml` to the app's `kustomization.yaml` and commit only the encrypted file.

To replace one key and keep the others, pipe a one-key Secret into
`kubeseal --format yaml --merge-into <existing sealedsecret.yaml>` (example in
[koito.md](koito.md#secrets--rotation)).

## Rolling pods after a re-seal

Env vars are read when a container starts, so re-sealing on its own changes nothing in a running
pod. In the same commit:

- **Chart apps:** bump `secretsChecksum` (or the chart's equivalent) in the HelmRelease values,
  where the chart has one.
- **Raw manifests:** bump the `secrets-revision` annotation on the pod template (multi-scrobbler,
  koito). The helpers' `--bump` flag does this for you.
- **Exceptions:** Alertmanager reloads its config secret by itself in about a minute
  ([monitoring.md](monitoring.md)). Koito's first-boot password is only read once ([koito.md](koito.md)).

Always change the sealed source. Controller 0.41 and later reverts hand edits to a decrypted
`Secret` back to what the `SealedSecret` says.

## Back up the master key (out of band)

The controller's private keys are **not** in git. Without them, a rebuilt cluster can't decrypt
any committed `SealedSecret`. Export every key to an offline location (password manager or
encrypted drive), never to this repo:

```bash
kubectl get secret -n sealed-secrets -o custom-columns=NAME:.metadata.name --no-headers \
  | grep '^sealed-secrets-key' \
  | while read k; do kubectl get secret "$k" -n sealed-secrets -o yaml; echo '---'; done \
  > ~/sealed-secrets-key-backup.yaml
chmod 600 ~/sealed-secrets-key-backup.yaml
```

- The current backup is `~/sealed-secrets-key-backup.yaml`, re-exported 2026-11-26 with all six
  keys (`sealed-secrets-key6bj8z` … `sealed-secrets-keydkwx7`). The June single-key export is kept
  as `~/sealed-secrets-key-backup.2026-06-16.yaml`.
- The controller adds a key about every 30 days and keeps the old ones. Re-export after each
  rotation, because a `SealedSecret` sealed with a key that isn't in the backup can't be recovered
  after a rebuild.
- Keep the `echo '---'`. Without it, an export with several keys isn't valid multi-document YAML.
- Re-export before touching the controller or upgrading k3s.

## Controller chart lineage

The `bitnamicharts/sealed-secrets` OCI chart changed lineage at 2.18. 2.5.x was the
Bitnami-catalog build (image `…:0.31.0-debian-12-r0`, chart-imposed resources, a PDB). 2.18 and
later, at the same OCI path, is the upstream `bitnami/sealed-secrets` chart: image `…:0.41.2`, no
default resources, ClusterRole renamed `secrets-unsealer`, container named `controller`, and an
extra `sealed-secrets-metrics` Service.

These did not change: the release name, the `sealed-secrets:8080` Service, the Deployment selector
and `--key-prefix sealed-secrets-key`. So kubeseal flags and existing keys still work. Resources
are set explicitly in the HelmRelease, and `install/upgrade.crds: CreateReplace` keeps the CRD up
to date.
