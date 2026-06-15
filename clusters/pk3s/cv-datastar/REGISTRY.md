# Setting Up the Chart in the OCI Registry

## Prerequisites

- `helm` CLI installed (v3.8+ for OCI support)
- A Forgejo **access token** with `read:package` and `write:package` scopes
  (Settings → Applications → Generate Token)

## 1. Create the Registry Auth Secret on the Cluster

```bash
# Create a docker-registry secret in flux-system namespace
kubectl create secret docker-registry forgejo-registry-auth \
  --namespace flux-system \
  --docker-server=https://fgit.watchtoken.org \
  --docker-username=<your-forgejo-username> \
  --docker-password=<your-forgejo-token>
```

This secret is referenced by:
- `helmrepository.yaml` — Flux pulls the Helm chart from the OCI registry
- `helmrelease.yaml` (via `imagePullSecrets`) — k3s pulls the Docker image

## 2. Push the Helm Chart to the Registry

From the `~/Projects/cv-datastar` directory:

```bash
# Login (one-time)
helm registry login fgit.watchtoken.org \
  --username <your-forgejo-username> \
  --password <your-forgejo-token>

# Package the chart
helm package charts/cv-datastar

# Push to OCI registry
helm push cv-datastar-0.1.0.tgz oci://fgit.watchtoken.org/forgejo-admin
```

The chart will be available at:
```
oci://fgit.watchtoken.org/forgejo-admin/cv-datastar:0.1.0
```

Flux will pick it up automatically on the next reconciliation cycle (interval: 1h).
To force immediate reconciliation:

```bash
kubectl -n flux-system reconcile helmrepository cv-datastar
```

## 3. Updating the Chart Later

When you bump the chart version:

```bash
helm package charts/cv-datastar
helm push cv-datastar-<new-version>.tgz oci://fgit.watchtoken.org/forgejo-admin
```

Then either:
- Update `version: "0.1.x"` in `helmrelease.yaml` to match the new semver range, or
- Use a wider range like `"0.x.x"` to auto-pick any 0.x version
