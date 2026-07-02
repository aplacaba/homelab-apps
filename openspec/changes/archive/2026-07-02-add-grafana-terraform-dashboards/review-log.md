## proposal Round 1 — 2026-07-02

### 🔴 Fixed
- none

### 🟡 Addressed
- **`overwrite = true` wording is imprecise.** proposal.md:26-27 says "UI editing of managed dashboards is disabled (overwrite = true)". Grafana does *not* hard-disable UI editing; `overwrite = true` only lets the provider replace an existing dashboard on the next `apply`, so UI drift is *reverted* on apply rather than blocked. The explore-brief states this correctly ("re-apply reconciles UI drift back to git", brief:44). Suggest rewording to e.g. "UI edits are reverted on the next apply (overwrite = true) so the repo stays the source of truth" to avoid the reader believing UI editing is literally locked.
- **AGENTS.md scope slightly compressed vs. brief.** The brief (brief:103-107) lists the AGENTS.md deliverables as four distinct items: module location + separate state, env-var auth, first-apply bootstrap SOP, **token rotation SOP**, and the "edit via repo not UI" note. The proposal Impact (proposal.md:74-75) folds these into "auth/bootstrap SOP" without explicitly naming rotation. Rotation is a distinct operational procedure (brief:58-59: `terraform apply -replace=...` to reissue). Recommend listing "token rotation SOP" explicitly so it isn't dropped at implement time.
- **Prometheus datasource UID pinning not surfaced as a design constraint.** The brief (brief:72-75, and open question #1) flags that every dashboard JSON must pin the kube-prometheus-stack Prometheus datasource UID, and that the exact UID must be verified at implement time. The proposal's `grafana-dashboards` capability and Impact list don't mention this dependency. Not a blocker (resolution is trivial: read the UID, hardcode it), but worth one line in the capability or Impact so the implementer knows the dashboards carry a hidden coupling to the datasource UID.
- **`grafana_organization` / token-expiry detail dropped.** Brief bootstrap.tf spec (brief:36-39) includes a `grafana_organization` ("Main org.") and `secondsToExpiration=0` (no-expiry) token. Proposal mentions the SA + token but not these. Fine for proposal-level (they're implementation details that belong in design.md), noted only for completeness — no action required if design.md will capture them.

### 🔴 Outstanding
- none — batch passes, ready to freeze

---

## Reviewer notes (not part of the verdict)

Cross-check of every brief commitment against proposal.md — all decision-level items are faithfully captured:

| Brief commitment | In proposal? |
|---|---|
| Rejected alt #1 (full Grafana config) → dashboards-only scope | ✓ (proposal:82-83 "datasources remain defined in the monitoring HelmRelease") |
| Rejected alt #2/#3 (manual token / admin-every-run) → self-bootstrap SA | ✓ (proposal:22-27) |
| Rejected alt #4 (Grafonnet) → plain JSON in repo | ✓ (proposal:29) |
| Rejected alt #5 (community dashboards by ID) → custom homelab dashboards | ✓ (proposal:50-53) |
| Rejected alt #6 (single flat TF root) → separate `terraform/grafana/` + own S3 key | ✓ (proposal:19-21) |
| Rejected alt #7 (defer metric sources) → add both now | ✓ (proposal:30-39) |
| 6-file TF layout (providers/variables/bootstrap/folders/dashboards/outputs) + dashboards/*.json ×7 | ✓ (proposal:64-65) |
| Separate S3 state key `grafana/terraform.tfstate` | ✓ (proposal:20) |
| SA "terraform" + token, `overwrite=true`, folder "Homelab" | ✓ (proposal:22-29) |
| `grafana_token` output for switching GRAFANA_AUTH | ✓ (proposal:77-79) |
| Auth flow: `GRAFANA_AUTH=admin:<pass>` first apply → token after | ✓ (proposal:76-79) |
| All 7 dashboards named (cluster-overview, nodes, pods-workloads, traefik, forgejo, storage-pvc, cloudflare-tunnel) | ✓ (proposal:40-42) |
| Forgejo: `gitea.config.metrics.ENABLED` + ServiceMonitor | ✓ (proposal:31-32, 69-70) |
| cloudflared: metrics Service (:2000) + ServiceMonitor | ✓ (proposal:33-35, 67-68) |
| `serviceMonitorSelectorNilUsesHelmValues: false` already set → no monitoring change | ✓ (proposal:36-39, cites helmrelease.yaml:47) |
| Makefile `validate` iterates both roots | ✓ (proposal:43, 73) |
| AGENTS.md: module + SOP + dir-structure updates | ✓ (proposal:44-45, 74-75) |
| Out-of-band operator step (first-apply password) | ✓ (proposal:76-79) |
| No-impact statement for unrelated components | ✓ (proposal:80-83) |

Scope is coherent and appropriately bounded (dashboards via TF + exactly the two metric sources needed to feed them; datasources/alerts/full-Grafana-config explicitly excluded). The "Why" is grounded in a real, verifiable gap (no custom dashboards; no reviewable source of truth; Forgejo uninstrumented; cloudflared :2000 unscraped). Capabilities are well-named and non-overlapping. Impact list is complete including the out-of-band operator action and kustomization.yaml updates.

The four 🟡 items are wording/precision nits; none represent a decision-level gap or contradiction between brief and proposal. The implement-time open questions (brief §"Open questions" — datasource UID, namespace selector coverage, forgejo metrics port name, Grafana version, token-expiry semantics) are correctly deferred to design.md/tasks.md rather than enumerated in the proposal.

---

## design Round 1 — 2026-07-02

### 🔴 Fixed
- **cloudflared `ServiceMonitor` selects a label the `Service` does not have (design.md §5.2).** The `cloudflared-metrics` Service is authored with `metadata: { name, namespace }` and **no `labels`**, yet the `cloudflared` ServiceMonitor uses `selector.matchLabels: { app.kubernetes.io/name: cloudflared-metrics }`. A ServiceMonitor selector matches **Service** labels (design even notes this, §5.2 last line) — with no matching label on the Service, the ServiceMonitor selects nothing → cloudflared `:2000` is never scraped → the `cloudflare-tunnel` dashboard is silently empty. (Verified: `clusters/pk3s/cloudflared/deployment.yaml:7,16` pods are labeled `app: cloudflared`, so the Service's `spec.selector: {app: cloudflared}` targets pods correctly; the defect is purely the Service's *own* labels.) Fix: add `labels: { app.kubernetes.io/name: cloudflared-metrics }` to the Service `metadata` (or change the ServiceMonitor selector to a label the Service actually carries). Contrast Forgejo §5.1, where the selector targets an *existing helm-deployed* Service and correctly says "verify label at implement time" — cloudflared's Service is one *we author here*, so the label is not a verify-later item, it must be set in this very manifest.

- **Open question #2 (`serviceMonitorNamespaceSelector`) is resolved with a faulty justification (design.md §4.2).** The design asserts "Confirmed by `serviceMonitorSelectorNilUsesHelmValues: false` at `clusters/pk3s/monitoring/helmrelease.yaml:47` + default ns selector," but that field governs the ServiceMonitor **label** selector (`serviceMonitorSelector`), **not** the **namespace** selector. The two are independent Prometheus CRD fields. Verified by reading `clusters/pk3s/monitoring/helmrelease.yaml` (lines 1-174): the HelmRelease sets **no** `serviceMonitorNamespaceSelector` at all, so the value is whatever the kube-prometheus-stack chart default emits — and if that default renders as `nil` (rather than `{}`), Prometheus scrapes ServiceMonitors **only in the `monitoring` namespace**, silently dropping the new forgejo/cloudflared ServiceMonitors and leaving **two** dashboards empty. The load-bearing "no monitoring change needed" decision rests on an unverified assumption. Fix (pick one): (a) actually verify the rendered CR — `kubectl get prometheus -n monitoring -o jsonpath='{.spec.serviceMonitorNamespaceSelector}'` — and cite that value in §4.2 instead of line 47; or (b) make it deterministic by explicitly setting `serviceMonitorNamespaceSelector: {}` in the monitoring HelmRelease (note: this *does* touch the monitoring HelmRelease, so if chosen, the "no monitoring change" statement in proposal.md:38-41 / design.md §4.2 must be updated to match).

### 🟡 Addressed
- **Invalid HCL in `variables.tf` snippet (design.md §2.2).** `variable "grafana_auth" { type = string, sensitive = true }` — the comma between attributes is invalid HCL; `terraform validate` would fail if copied verbatim. Trivially fixed by putting the attributes on separate lines. Clearly illustrative shorthand, but it is presented as the file's content.
- **Forgejo ServiceMonitor selector is broad (design.md §5.1).** `app.kubernetes.io/instance: forgejo` matches *every* Service the chart/install deploys under that release — `forgejo-http`, `forgejo-ssh`, and any postgres-subchart Service all carry that helm label. It works only because the endpoint pins `port: http`, which exists solely on the http Service. Safe, but tighter to also match the http Service (e.g. add `app.kubernetes.io/name`). Design already says "verify label at implement time."
- **`grafana_dashboard.folder = grafana_folder.homelab.id` (design.md §2.6).** In the grafana provider this works only if `.id` resolves to the folder UID. Passing `grafana_folder.homelab.uid` is the unambiguous, version-robust form (the folder already sets `uid = "homelab"`). Minor footgun; prefer `.uid`.
- **Cross-module data-flow narrative from the brief (brief:109-116) is not restated as a section.** It is inferable from §1 (two reconcilers) and §2.2 (`http://grafana.local:30080`), but a one-line path "Terraform (LAN host) → Traefik NodePort :30080 → `kube-prometheus-stack-grafana.monitoring:3000`" would help the implementer. (Verified consistent: `monitoring/helmrelease.yaml:99-101,117`.)
- **`required_providers` comment is self-contradictory (design.md §2.1).** `version = "~> 3.0"` already pins the provider, yet the comment says "pin at apply time to current stable." Pick one: keep the pin and drop the comment, or leave a TODO with a concrete version.
- **kustomization.yaml wiring not restated (design.md §5).** The frozen proposal (proposal.md:74) lists modifying `forgejo/kustomization.yaml` and `cloudflared/kustomization.yaml` to reference the new resources; design §5 introduces the new files without re-noting the kustomization edits. Mechanical, but worth one line so it isn't dropped at implement time.

### 🔴 Outstanding
- Batch is **blocked** until the two 🔴 Fixed items above are corrected in `design.md`: (1) the cloudflared Service/ServiceMonitor label mismatch (clear fix), and (2) the `serviceMonitorNamespaceSelector` resolution — which needs either real verification of the rendered Prometheus CR or an explicit value in the monitoring HelmRelease (the latter updates the "no monitoring change" decision). No *additional* unresolved decision-level questions beyond those two; design ↔ frozen-proposal consistency is otherwise sound (the `overwrite=true` vs proposal's "UI editing disabled" wording was already flagged as 🟡 in the proposal round and is not a new contradiction; the `seconds_to_expiration` omission and the "no `grafana_organization` resource" decision are correct refinements of the brief, not contradictions).

---

### Reviewer notes (design round, not part of the verdict)

Consistency check — design vs frozen proposal (decision-level): no contradictions found.
- Scope (dashboards-only via TF; datasources stay in Helm): design §1, §2 — matches proposal:49-60, 82-83.
- Separate root `terraform/grafana/` + own S3 key `grafana/terraform.tfstate`: design §2 — matches proposal:19-21.
- Self-bootstrap SA "terraform" + token + `Homelab` folder + 7 dashboards + `overwrite=true`: design §2.3-§2.6, §3 — matches proposal:22-44.
- `grafana_token` output + env-var auth (`GRAFANA_URL`/`GRAFANA_AUTH`) + rotation SOP: design §2.2, §2.4, §6 — matches proposal:76-79; rotation now explicit (addresses the proposal-round 🟡).
- Two metric sources (Forgejo `gitea.config.metrics.ENABLED` + ServiceMonitor; cloudflared metrics Service :2000 + ServiceMonitor): design §5 — matches proposal:31-39, 67-70.
- Makefile `validate` over both roots; AGENTS.md dir-structure + SOP updates: design §6 — matches proposal:43-45, 73-75.

Open-questions resolution coverage (brief §"Open questions" 1-5):
1. Prometheus UID → `prometheus`, with HelmRelease fallback — §4.1 ✓ concrete (has fallback path).
2. serviceMonitorNamespaceSelector → §4.2 — **unsoundly justified, see 🔴 Fixed #2**.
3. Forgejo metrics port → http/3000 named `http` — §4.3 ✓ concrete.
4. Grafana version → 11.x (≥9 needed) — §4.4 ✓ concrete.
5. Token expiry → omit `seconds_to_expiration` = never expires — §4.5 ✓ concrete (matches provider v3 semantics; omit-vs-`=0` both yield no-expiry).

Auth-flow technical check: the grafana provider `auth` field does accept both `admin:<pass>` basic auth and a raw service-account token (`glsa_…`) in the same string field — design §2.4 / §7 "Provider auth after token created but env still basic-auth — Harmless" is accurate. No issue.

Technical correctness of HCL/manifests otherwise sound: `terraform` block backend mirrors `terraform/providers.tf` skip-flags (verified: `region=auto`, `use_path_style`, `skip_*` — design §2.1 elision-by-reference is correct); `grafana_folder`/`grafana_dashboard` resources valid for provider v3; ServiceMonitor endpoint shapes (`port`/`path`/`interval`) correct. The two 🔴 items are localized defects in the design's own snippets/assertions, not structural flaws.

---

## design Round 2 — 2026-07-02

### 🔴 Fixed
- **(Round-1 #1) cloudflared Service/ServiceMonitor label agreement — RESOLVED.** design §5.2 Service now carries `metadata.labels: { app.kubernetes.io/name: cloudflared-metrics }`, and the ServiceMonitor `selector.matchLabels` references the same key (design.md:215-216, 228-229). The two now agree. Re-verified the pod side independently: `clusters/pk3s/cloudflared/deployment.yaml:16` labels pods `app: cloudflared`, so the Service `spec.selector: { app: cloudflared }` still targets pods correctly — the fix added the Service's *own* labels without disturbing the pod selector. cloudflared `:2000` will now be scraped.

- **(Round-1 #2) `serviceMonitorNamespaceSelector` justification — RESOLVED (and decision upheld).** design §4.2 (design.md:160-169) now cites the verified live-cluster value:
  `kubectl get prometheus -n monitoring -o jsonpath='{.items[*].spec.serviceMonitorNamespaceSelector}'` → `{}`. An empty LabelSelector matches all namespaces, so Prometheus discovers ServiceMonitors in `forgejo` and `cloudflared` namespaces automatically. The "no monitoring HelmRelease change" conclusion holds. The parenthetical now correctly states that `serviceMonitorSelectorNilUsesHelmValues: false` (line 47, re-verified) governs the *label* selector (`serviceMonitorSelector`), not the namespace selector — the two are independent and both are satisfied (label side: nil selector → match-all in the operator; namespace side: `{}` → all namespaces). This also reconciles cleanly with the frozen proposal (proposal.md:38-41), which cited the label-selector field: the proposal's *decision* (no monitoring change) is upheld, the design supplies the technically-precise justification. No contradiction.

### 🟡 Addressed
- **HCL comma in `variables.tf` — fixed.** §2.2 attributes now on separate lines, valid HCL.
- **`grafana_dashboard.folder` — fixed.** §2.6 uses `grafana_folder.homelab.uid` (design.md:124); folder sets `uid = "homelab"` so this resolves unambiguously. More version-robust than `.id`.
- **Contradictory provider-version comment — removed.** §2.1 pins `version = "~> 3.0"` with no stale "pin at apply time" comment.
- **Cross-module data-flow — added.** §1 now states the explicit path: Terraform (LAN host) → Traefik NodePort `:30080` (`grafana.local`) → `kube-prometheus-stack-grafana.monitoring.svc:3000`.
- **kustomization wiring — added.** §5.1 and §5.2 now each note adding the new resource(s) to the app's `kustomization.yaml` `resources:`.

### 🔴 Outstanding
- none — batch passes, ready to freeze

---

### Reviewer notes (design round 2, not part of the verdict)

Re-scan of all Round-1 🟡 items — every one addressed, none introduced a new defect:
- The Forgejo ServiceMonitor broad selector (`app.kubernetes.io/instance: forgejo`, §5.1) is unchanged and still carries the "verify label at implement time" guard; safe because the endpoint pins `port: http` (only the http Service exposes it). Accepted as 🟡 in Round 1, still acceptable.

HCL/manifest technical re-check (no new issues):
- `bootstrap.tf`: `grafana_service_account_token.service_account_id = grafana_service_account.terraform.id` — valid argument name for provider v3; `seconds_to_expiration` intentionally omitted → never-expiring token (matches provider v3 semantics).
- `dashboards.tf`: `for_each` over `toset(...)` + `file("${path.module}/...")` + `overwrite = true` — all valid.
- ServiceMonitor endpoint shapes (`port`/`path`/`interval`) and ServiceMonitor `apiVersion: monitoring.coreos.com/v1` — correct.
- cloudflared Service `spec.selector: { app: cloudflared }` confirmed against live `deployment.yaml` pod template labels.

Design ↔ frozen-proposal consistency: no new contradictions introduced by the Round-2 edits. The one place the frozen proposal's justification was imprecise (the `serviceMonitorSelectorNilUsesHelmValues` citation for the namespace-selector question) is now corrected at the design level while preserving the proposal's decision — this is a refinement, not a contradiction. Scope, auth flow, dashboard set, metric sources, Makefile/AGENTS.md wiring all remain aligned.

---

## specs Round 1 — 2026-07-02

### 🔴 Fixed
- none

### 🟡 Addressed
- **grafana-dashboards Req 2 ("Self-bootstrapped Grafana service account") has a MUST clause with no scenario.** The requirement body asserts "No Grafana secret is committed to git," but its three scenarios cover only first-apply bootstrap, subsequent token auth, and rotation — none assert the no-plaintext-secret property. That property is testable (e.g. `git grep` for the admin password / token strings is empty; only the existing `grafana-admin-secret` SealedSecret + out-of-band env vars carry secrets), so per the convention (every testable MUST gets a WHEN/THEN — cf. forgejo-ssh spec) it deserves one. Trivial fix — add e.g. a scenario: "WHEN the repo is inspected, THEN no Grafana admin password or service-account token appears in plaintext (secrets enter only via the existing `grafana-admin-secret` SealedSecret and out-of-band env vars)."

### 🔴 Outstanding
- none — batch passes, ready to freeze

---

### Reviewer notes (specs round 1, not part of the verdict)

**Convention adherence** (vs `openspec/changes/add-forgejo-ssh-access/specs/forgejo-ssh/spec.md`): all three specs use `## ADDED Requirements`, `### Requirement:` blocks each with a clear MUST statement, and `#### Scenario:` blocks using **WHEN/THEN** bullets. Every scenario is concrete and testable; no requirement is vague or untestable.

**Coverage of the frozen capability checklist** — all items present:

| Capability / item (from task) | Spec location | Verdict |
|---|---|---|
| grafana: dashboards-as-code | grafana-dashboards Req 1 + "Dashboards present after apply" | ✓ 7 dashboards named, match proposal:40-42 / design §3 |
| grafana: UI-drift reverted (`overwrite=true`) | "UI drift is reverted" | ✓ matches design §2.6 |
| grafana: datasource pinned by UID | "Datasource pinned by UID" | ✓ uid `prometheus`, matches design §4.1 |
| grafana: self-bootstrap SA + token (no-expiry) | Req 2 + "First apply bootstraps the SA" | ✓ role Admin, non-expiring, matches design §2.3 |
| grafana: token rotation | "Token rotation" | ✓ `-replace=grafana_service_account_token.terraform`, matches design §2.4 |
| grafana: isolated S3 state key | Req 3 + "Separate backend key" | ✓ `grafana/terraform.tfstate`, matches design §2.1 |
| forgejo: metrics via `gitea.config.metrics.ENABLED` | forgejo-metrics Req 1 + "Metrics endpoint enabled" | ✓ matches design §5.1 |
| forgejo: ServiceMonitor on http/3000 | "ServiceMonitor discovered" | ✓ port `http`, `/metrics`, 30s |
| forgejo: ns selector `{}` → no monitoring change | "ServiceMonitor discovered" + Req 2 | ✓ matches design §4.2 |
| forgejo: dashboard has data | "Forgejo dashboard has data" | ✓ |
| cloudflared: dedicated metrics Service `:2000` + label | cloudflared-metrics Req 1 + "Metrics Service exists" | ✓ label `app.kubernetes.io/name: cloudflared-metrics` matches design §5.2 (the design-R1 fix) |
| cloudflared: ServiceMonitor selector matches that label | "ServiceMonitor selects the metrics Service" | ✓ |
| cloudflared: ns selector `{}` | "ServiceMonitor selects..." | ✓ |
| cloudflared: dashboard has data | "Cloudflare tunnel dashboard has data" | ✓ |

**Decision-level consistency with frozen proposal/design** — no contradictions:
- Seven-dashboard set + "Homelab" folder + `overwrite=true` + uid `prometheus` + SA "terraform"/Admin + non-expiring token + S3 key `grafana/terraform.tfstate` all match frozen design §2-§4 and proposal:19-44 exactly.
- "No monitoring HelmRelease change" in both metrics specs matches the frozen decision (proposal:38-41; design §4.2 verified `{}` on the live cluster).
- cloudflared Service/ServiceMonitor label agreement in the spec reflects the design Round-1 🔴 fix (label on Service `metadata`, matched by ServiceMonitor `selector`) — correctly transcribed, not regressed.
- grafana "Datasource pinned by UID" commits to uid `prometheus`; design §4.1 commits to the same (verify, with HelmRelease fallback if it differs). The spec is firmer than design's hedged wording but aligns with the design's *intended* outcome — refinement, not contradiction.

**Minor non-blocking observations (not flagged above):**
- grafana spec has no explicit scope-guard requirement that Grafana datasources remain Helm-managed (not Terraform). forgejo-ssh uses a "No impact" requirement for negative scope; an analogous "datasources stay in the monitoring HelmRelease" requirement would mirror that pattern and capture design §1 / proposal:82-83. Optional polish — the positive requirements already imply the boundary.
- grafana "Token rotation" scenario asserts "the old token stops working." Design §2.4 states the rotation procedure but not that outcome explicitly; it is nonetheless the correct, testable consequence of the grafana provider deleting the replaced token. Not a defect.
- grafana Req 1 references the "Homelab" folder only in its scenario, not in the MUST statement. Functionally covered (scenario asserts the folder exists holding the dashboards); folder-as-managed-resource detail lives in design §2.5. Acceptable at spec level.

**Capability coverage completeness:** all three declared capabilities (`grafana-dashboards`, `forgejo-metrics`, `cloudflared-metrics`) are fully covered (3 / 2 / 2 requirements respectively); none is under-specified.

---

## tasks Round 1 — 2026-07-02

### 🔴 Fixed
- **Task 2.1 offers a fallback the frozen design explicitly rejected (tasks.md:15).** The frozen design §4.1 (design.md:154-159) resolves the Prometheus-datasource-UID open question with exactly **one** fallback path: "if the actual UID differs, set `grafana.datasources.defaultUid`/sidecar in the monitoring HelmRelease to `prometheus` (single declarative edit) **rather than editing every JSON**." Task 2.1 instead offers two options, listing first "pin that UID in every dashboard JSON" — precisely the approach the design rejected. It would also contradict the frozen grafana-dashboards spec scenario "Datasource pinned by UID," which commits the uid to the literal `prometheus` (specs/grafana-dashboards/spec.md:20-23): pinning a differing uid into the JSONs would violate that scenario. Fix: delete the "pin that UID in every dashboard JSON" branch; keep only the design-sanctioned HelmRelease sidecar-default fallback (noting it in review-log if it triggers, as 2.1 already says).

### 🟡 Addressed
- **"depends on §4 / §5" in tasks 3.5 and 3.7 is a data-lineage note misreadable as an ordering dependency.** Authoring the dashboard JSON needs only the metric *names* (`forgejo_*`, `cloudflared_*`), not the metric sources being live; the real dependency (data appearing) is correctly captured later in §8.2/§8.3. As written, 3.5/3.7 sit before §4/§5 yet say "depends on §4/§5," which could confuse an implementer about sequencing. Suggest rewording to "metric source added in §4" (lineage) rather than "depends on §4" (ordering).
- **No explicit verification that the captured token authenticates a subsequent apply.** The frozen grafana-dashboards spec scenario "Subsequent applies use the token" (specs/grafana-dashboards/spec.md:38-42) is only transitively exercised — task 7.3 switches `GRAFANA_AUTH` to the token but no later task proves a token-authenticated plan/apply succeeds (8.4 re-applies, but its focus is UI-drift and it doesn't state which auth it uses). Trivial to make explicit: add a step after 7.3 re-running `terraform plan` with the token and confirming no auth error / no unexpected changes. (Arguably covered if the env is left as the token through 8.4, but stating it removes ambiguity.)

### 🔴 Outstanding
- One serious issue open: task 2.1's "pin that UID in every dashboard JSON" fallback branch contradicts frozen design §4.1 and the frozen grafana-dashboards spec (see 🔴 Fixed). Correct that single line and the batch passes. With it fixed, the rest is sound: coverage is complete (all 6 module files + dashboards.tf + 7 JSONs; datasource-UID check before authoring; Forgejo + cloudflared metric sources each with Service/ServiceMonitor/kustomization-wiring/verify, the cloudflared Service carrying the `app.kubernetes.io/name: cloudflared-metrics` label matched by its ServiceMonitor; Makefile `validate` over both roots + `make lint`; first-apply bootstrap as out-of-band operator step; dashboards-have-data for all 7 incl. the UI-drift-reverts check; AGENTS.md dir-structure + SOP-with-rotation + metric-sources; `openspec validate` final step), granularity is appropriate (each leaf ≤ ~2h; one-dashboard-per-task is the right unit, no monolithic bundling), and ordering is correct (§2→§3, §1→§7, §4/§5→§8). No other decision-level deviations — datasources remain Helm-managed (not Terraform), `grafana_organization` is omitted, the token is non-expiring, and `grafana_dashboard.folder` uses `.uid`, all matching the frozen design.

---

### Reviewer notes (tasks round 1, not part of the verdict)

Coverage matrix — frozen requirement/scenario → task(s):

| Frozen item | Task coverage | Verdict |
|---|---|---|
| 6 TF module files (providers/variables/bootstrap/folders/dashboards/outputs) | 1.1–1.6 | ✓ |
| 7 dashboard JSONs | 3.1–3.7 | ✓ one per task |
| Resolve Prometheus UID before authoring | 2.1 (before §3) | ✓ ordered (fallback wording defective — see 🔴) |
| Grafana version ≥ 9 (service accounts) | 2.2 | ✓ design §4.4 deferral implemented |
| Forgejo `metrics.ENABLED` | 4.1 | ✓ |
| Forgejo ServiceMonitor + kustomization + verify | 4.2, 4.3, 4.4, 4.5 (curl /metrics 200) | ✓ |
| cloudflared metrics Service **with label** | 5.1 (label present) | ✓ matches design-R1/R2 fix |
| cloudflared ServiceMonitor matching selector + kustomization + verify | 5.2, 5.3, 5.4 | ✓ |
| Makefile validate-over-both-roots + make lint | 6.1, 6.2 | ✓ |
| First-apply bootstrap (env vars, plan, apply, capture token) | 7.1, 7.2, 7.3, 7.4 | ✓ |
| Dashboards-have-data (all 7) + UI-drift-reverts | 8.1 (×5), 8.2, 8.3, 8.4 | ✓ |
| AGENTS.md: dir structure + SOP w/ rotation + metric sources | 9.1, 9.2, 9.3 | ✓ rotation explicit in 9.2 |
| `openspec validate` | 10.1, 10.2 | ✓ mirrors forgejo-ssh style |

Scenario-coverage gaps (frozen spec → task): only "Subsequent applies use the token" lacks an explicit verification step (flagged 🟡 — transitively via 8.4). Every other frozen scenario maps to a concrete task. Style matches the `add-forgejo-ssh-access/tasks.md` reference (numbered sections, checkbox leaves, dedicated verify + doc + openspec-validate sections). The single 🔴 is a wording-level decision deviation fixable in one line; no structural rework needed.

---

## tasks Round 2 — 2026-07-02

### 🔴 Fixed
- **(Round-1 #1) Task 2.1's "edit every dashboard JSON" fallback branch — RESOLVED.** tasks.md:15 now reads: "Confirm the Prometheus datasource **uid** is `prometheus`... If it differs, make a **single declarative edit** to `clusters/pk3s/monitoring/helmrelease.yaml` (set the sidecar default uid to `prometheus`) — do **not** edit every dashboard JSON (the dashboards are committed to uid `prometheus` per design §4.1)." This matches frozen design §4.1 (design.md:154-159) verbatim in intent: one fallback path, the HelmRelease sidecar default, and explicitly rejects the "edit every JSON" approach the design rejected. It also aligns with the frozen grafana-dashboards spec scenario "Datasource pinned by UID" (specs/grafana-dashboards/spec.md:20-23), which commits the uid to the literal `prometheus` — pinning a differing uid into the JSONs would have violated that scenario. The contradiction with both frozen artifacts is eliminated; no remaining branch diverges from the design-sanctioned path. (Note: the potential monitoring-HelmRelease edit here is scoped to datasource UID and does NOT touch the frozen "no monitoring change" decision at proposal.md:38-41, which concerns ServiceMonitor *namespace discovery* — a separate question already resolved in design §4.2.)

### 🟡 Addressed
- **(Round-1 🟡 #1) "depends on §4/§5" wording in 3.5/3.7 — fixed.** tasks.md:24 now reads "will show data only after §4 lands"; tasks.md:26 reads "will show data only after §5 lands." Reframed as data-lineage rather than an ordering dependency — authoring the JSON needs only the metric *names*, and the actual data-appearance verification correctly lives in §8.2/§8.3. No sequencing ambiguity remains.
- **(Round-1 🟡 #2) Explicit token-auth verification step — added.** New task 7.4 (tasks.md:54): "With `GRAFANA_AUTH` now set to the token, run `terraform plan` again — it should report **no changes** (proves subsequent applies authenticate as the `terraform` SA, satisfying the 'Subsequent applies use the token' scenario)." The old 7.4 (Grafana UI folder confirmation) is renumbered to 7.5 (tasks.md:55). Numbering 7.1→7.5 is sequential with no gaps, and §7 ordering stays correct (env → init/plan → apply/capture → token-auth verify → UI confirm). This closes the one scenario-coverage gap flagged in Round 1: the frozen spec scenario "Subsequent applies use the token" (specs/grafana-dashboards/spec.md:38-42) now has an explicit verification step rather than being only transitively exercised via 8.4.

### 🔴 Outstanding
- none — batch passes, ready to freeze

---

### Reviewer notes (tasks round 2, not part of the verdict)

**Round-1 🔴 resolution check:** Confirmed by line-by-line comparison of tasks.md:15 against frozen design.md:154-159 and frozen specs/grafana-dashboards/spec.md:20-23. The "pin that UID in every dashboard JSON" branch is fully deleted; only the design-sanctioned single-HelmRelease-edit fallback remains, with an explicit "do not edit every dashboard JSON" and an in-line citation of design §4.1. No residual contradiction.

**Round-1 🟡 resolution check:**
- 3.5/3.7: wording is now unambiguously data-lineage ("will show data only after §N lands"); no implementer would read it as an ordering constraint.
- 7.4: the new step is the right shape — `terraform plan` (read-only) with the token, asserting "no changes." "No changes" is the correct success signal: it proves (a) the token authenticates (else 401), and (b) the first apply left no drift. Renumbering preserved all cross-references (no other task cited old-7.4 by number).

**Scenario-coverage re-scan (frozen spec → task), updated from Round 1:**
| Frozen scenario | Task coverage | Verdict |
|---|---|---|
| Dashboards present after apply | 1.1–1.6, 3.1–3.7, 7.5 | ✓ |
| UI drift is reverted | 8.4 | ✓ |
| Datasource pinned by UID | 2.1 (commits `prometheus`, design-sanctioned fallback) | ✓ no longer contradicts |
| First apply bootstraps the SA | 1.3, 7.1, 7.2, 7.3 | ✓ |
| **Subsequent applies use the token** | **7.4 (new, explicit)** | ✓ **now explicit** |
| Token rotation | 9.2 (SOP documented; matches design §2.3 procedure) | ✓ operational SOP, not a first-impl step |
| No Grafana secret in git | architectural property of §1.2/§1.5/§7.1 (env vars + sensitive output; no plaintext committed) | ✓ inherent, no per-task verify needed |
| Separate backend key | 1.1 | ✓ |

Every frozen scenario now maps to at least one concrete task; the one Round-1 gap is closed.

**Granularity / ordering re-check:** each leaf remains ≤ ~2h (one module file or one dashboard per task); §2 precedes §3 (UID confirmed before authoring); §1 precedes §7 (module exists before apply); §4/§5 precede §8 (metric sources live before dashboards-verify-data); §6 (repo wiring) precedes §7 (apply); §9 (docs) and §10 (openspec validate) close out. The renumbering in §7 did not disturb any of these.

**Decision-level consistency with frozen proposal/design — no new contradictions:**
- Datasources remain Helm-managed (not Terraform): unchanged (tasks touch dashboards only; no `grafana_data_source` resource). ✓
- `grafana_organization` omitted: task 1.3 explicitly says "No `grafana_organization` resource." ✓ matches design §2.3.
- Token non-expiring: task 1.3 "`seconds_to_expiration` omitted." ✓ matches design §2.3/§4.5.
- `grafana_dashboard.folder = grafana_folder.homelab.uid`: task 1.6. ✓ matches design Round-2 fix.
- cloudflared Service carries `app.kubernetes.io/name: cloudflared-metrics` matched by its ServiceMonitor: tasks 5.1/5.2. ✓ matches design Round-1/R2 fix and frozen spec.
- "No monitoring HelmRelease change" (for ServiceMonitor discovery): tasks 4.x/5.x add no monitoring-HelmRelease edit; the only monitoring-HelmRelease edit anywhere is task 2.1's design-sanctioned datasource-UID fallback, which is a distinct concern. ✓

No remaining serious issues. The tasks batch passes and the entire change (proposal + design + specs + tasks) is internally consistent and ready to apply.
