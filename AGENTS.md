# homelab-apps — agent entry point

GitOps repository for the **k3s v1.37 homelab cluster** (`pk3s`), synced by Flux Operator from
`./clusters/pk3s` on `main`.

## Read this first

**[docs/AGENT_INSTRUCTIONS.md](docs/AGENT_INSTRUCTIONS.md) is the guide.** It explains what the
repo is, how a change reaches the cluster, the repo layout, what runs where, and which topic doc
in `docs/` to open next (patterns, networking, secrets, platform, per-app runbooks). Open it before
changing anything. This file only holds the rules that must hold even if you read nothing else.

## Non-negotiables

1. **Git first — never `kubectl apply/edit/scale`.** Flux applies this repo with server-side apply
   and reverts out-of-band changes on the next sync, so manual cluster surgery is wasted work. Edit
   `clusters/pk3s/<app>/`, commit, push. `flux suspend/resume` is the only sanctioned manual action
   (migrations only).
2. **Never commit plaintext secrets.** Everything is a `SealedSecret` sealed with `kubeseal`;
   plaintext never enters git, chat, or a command line. Re-sealing changes nothing on its own, so
   in the same commit bump `secretsChecksum` (charts) or the `secrets-revision` annotation (raw
   manifests) to restart the pod.
3. **`flux reconcile` is the exception, not the routine.** A push usually lands within a minute or
   two (source polls every 1m, root Kustomization applies every 10m). Force a reconcile only to land
   a change now (verifying a fix, un-sticking a failed sync). The root Kustomization is named
   `flux-system`, not `pk3s`.
4. **Ingress is the Traefik CRD** (`traefik.io/v1alpha1` IngressRoute), never a
   `networking.k8s.io/v1` Ingress, and always host-based (`Host(...)`, never `PathPrefix`). Disable
   the chart's built-in ingress when you write one by hand.
5. **Most PVCs are `local-path` with reclaim `Delete`.** Removing an app from the root kustomization
   prunes its volumes and data. Back up out of band before anything destructive.
6. **Keep the docs accurate.** After an implementation change, update the topic doc it touches
   (and the guide's map if the layout changed). The guide's last section says where each kind of
   change goes.

## Quick map

| Need | Where |
|---|---|
| How a change reaches the cluster, repo layout, what runs where | [docs/AGENT_INSTRUCTIONS.md](docs/AGENT_INSTRUCTIONS.md) |
| Adding or changing an app | [docs/patterns.md](docs/patterns.md) |
| Ingress, TLS, tunnel, DNS | [docs/networking.md](docs/networking.md) |
| Secrets and rotation | [docs/secrets.md](docs/secrets.md) |
| k3s, nodes, Flux Operator upgrades | [docs/platform.md](docs/platform.md) |
| Versions and PVCs | [docs/inventory.md](docs/inventory.md) |
| Something is broken | the app's doc, then "Things that apply everywhere" in the guide |

Local operator tooling (`scripts/`, e.g. `seal-koito-secrets.sh`) is untracked on purpose. See
[docs/secrets.md](docs/secrets.md).
