# homelab-apps — agent entry point

GitOps repository for the **k3s v1.36 homelab cluster** (`pk3s`), synced by Flux Operator from
`./clusters/pk3s` on `main`.

## Read this first

**[docs/AGENT_INSTRUCTIONS.md](docs/AGENT_INSTRUCTIONS.md) is the full guide** — cluster layout,
app deployment pattern, conventions, per-app runbooks (papra, hris, spec-frontend, neo4j, media
stack, pangolin…), secret handling, backup/rollback procedures and the gotcha list. Open it before
changing anything. This file only carries the rules that must hold even if you read nothing else.

## Non-negotiables

1. **Git first — never `kubectl apply/edit/scale`.** Flux applies this repo with server-side apply
   and reverts out-of-band changes on the next sync, so manual cluster surgery is wasted work. Edit
   `clusters/pk3s/<app>/`, commit, push. `flux suspend/resume` is the only sanctioned manual action
   (migrations only).
2. **Never commit plaintext secrets.** Everything is a `SealedSecret` sealed with `kubeseal`;
   plaintext never enters git, chat, or a command line. Re-sealing changes nothing on its own —
   where a chart renders one, bump `secretsChecksum` in the same commit so the pod rolls.
3. **`flux reconcile` is the exception, not the routine.** Flux syncs hourly; force a reconcile only
   to land a change now (verifying a fix, un-sticking a failed sync) — the root Kustomization is
   named `flux-system`, not `pk3s`.
4. **Ingress is the Traefik CRD** (`traefik.io/v1alpha1` IngressRoute), never a
   `networking.k8s.io/v1` Ingress, and always host-based (`Host(...)`, never `PathPrefix`). Disable
   the chart's built-in ingress when you write one by hand.
5. **Most PVCs are `local-path` with reclaim `Delete`.** Removing an app from the root kustomization
   prunes its volumes and data. Back up out of band before anything destructive.
6. **Keep the guide accurate.** After an implementation change, update
   [docs/AGENT_INSTRUCTIONS.md](docs/AGENT_INSTRUCTIONS.md) — new app, new chart source, new gotcha,
   architecture or procedure change.

## Quick map

| Need | Where |
|---|---|
| How a change reaches the cluster | guide → GitOps Workflow, Architecture Notes |
| Adding/changing an app | guide → App Deployment Pattern, Conventions |
| Secrets and rotation | guide → Secret Management (SealedSecrets) |
| Something is broken | guide → Common Gotchas, then the app's section |
| Per-app runbook | guide section, or `docs/papra.md` |

Local operator tooling (`scripts/`, e.g. `seal-hris-secrets.sh`) is untracked on purpose — see the
guide's HRIS and Terraform sections.
