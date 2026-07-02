## ADDED Requirements

### Requirement: Custom homelab dashboards managed as code
Grafana dashboards for this homelab MUST be provisioned and reconciled by
  Terraform from JSON files committed in this repo, so the repo — not the Grafana
  UI — is the source of truth.

#### Scenario: Dashboards present after apply
- **WHEN** `terraform apply` succeeds in `terraform/grafana/`
- **THEN** Grafana contains a folder named **Homelab** holding seven dashboards:
  cluster-overview, nodes, pods-workloads, traefik, forgejo, storage-pvc,
  cloudflare-tunnel.

#### Scenario: UI drift is reverted
- **WHEN** someone edits a managed dashboard in the Grafana UI and a subsequent
  `terraform apply` runs
- **THEN** the dashboard is reset back to the JSON in the repo
  (`overwrite = true`); manual UI edits do not persist.

#### Scenario: Datasource pinned by UID
- **WHEN** any managed dashboard queries a datasource
- **THEN** it references the Prometheus datasource by **uid** (`prometheus`),
  not by name, so dashboards keep working if the datasource is renamed.

### Requirement: Self-bootstrapped Grafana service account
Terraform MUST create a dedicated `terraform` service account + token in Grafana
  on its first run (authenticated via the admin password supplied out-of-band),
  and subsequent runs MUST be able to authenticate using the token Terraform
  created. No Grafana secret is committed to git.

#### Scenario: First apply bootstraps the SA
- **WHEN** the operator runs the first `terraform apply` with
  `GRAFANA_AUTH=admin:<admin-password>` (password from the operator's password
  manager / the existing `grafana-admin-secret` SealedSecret)
- **THEN** a `terraform` service account (role Admin) and a non-expiring token
  are created in Grafana and recorded in Terraform state.

#### Scenario: Subsequent applies use the token
- **WHEN** the operator sets `GRAFANA_AUTH` to the value of
  `terraform output -raw grafana_token`
- **THEN** further `terraform apply` runs authenticate as the `terraform`
  service account without needing the admin password.

#### Scenario: Token rotation
- **WHEN** the operator sets `GRAFANA_AUTH=admin:<password>` once and runs
  `terraform apply -replace=grafana_service_account_token.terraform`
- **THEN** a fresh token is issued and exposed via `terraform output`; the old
  token stops working.

#### Scenario: No Grafana secret in git
- **WHEN** the repo is inspected after any apply
- **THEN** no plaintext Grafana admin password or service-account token is
  committed; all Grafana auth is supplied at runtime via `GRAFANA_AUTH`
  (sensitive) and the token lives only in Terraform state.

### Requirement: Isolated Terraform state for Grafana
The Grafana Terraform module MUST keep its state separate from the Cloudflare
  state, so an error in one cannot corrupt the other.

#### Scenario: Separate backend key
- **WHEN** the Grafana module is initialized
- **THEN** it uses the S3 backend key `grafana/terraform.tfstate` (distinct from
  the Cloudflare module's `cloudflare/terraform.tfstate`), and the Cloudflare
  state is untouched by any Grafana run.
