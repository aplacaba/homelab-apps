## proposal Round 1 — 2026-07-04
### 🔴 Fixed
 - Why section accurately states Flux services expose 80→9790 while controllers' metrics live on 8080 http-prom, and that nothing scrapes Flux today (matches brief + confirmed `podMonitorSelectorNilUsesHelmValues: false` is set at `monitoring/helmrelease.yaml:48`).
 - Scrape method (PodMonitor), all 4 controllers enumerated (`source`, `kustomize`, `helm`, `notification`), `app: <controller>` label selection, `http-prom`/8080 port, `/metrics` path, 30s interval — all transcribed from the brief.
 - "No monitoring HelmRelease change" explicitly stated and grounded.
 - Root `clusters/pk3s/kustomization.yaml` modification listed (verified `flux-monitoring` not yet present; alphabetical slot is between `flux-dashboard` and `forgejo`).
 - Dashboard panel summary names all 8 panels across 3 rows (stat / time-series / per-resource); Prometheus datasource pinned by uid `prometheus`; Homelab folder; title "Flux GitOps", uid `flux`. Full PromQL correctly deferred to design.md.
 - Impact section complete and accurate: verified `terraform/grafana/dashboards.tf` uses a `toset([...])` local so adding `"flux"` is the right pattern; `overwrite = true` + Homelab folder already wired.
 - Out-of-band one-time `terraform apply` with `GRAFANA_AUTH` captured per existing SOP; "no secrets enter git or chat" preserved.
 - "No impact" list is comprehensive and covers all unrelated subsystems.
 - Format matches the archived reference proposal exactly (Why / What Changes / Capabilities [New + Modified] / Impact), including the `<!-- None -->` HTML comment placeholder for empty Modified Capabilities.
 - `.openspec.yaml` schema/created fields present and valid.

### 🟡 Addressed
 - Added a **Non-goals** bullet to "What Changes" enumerating the 7 rejected alternatives from the brief (ServiceMonitor+Service pattern; patching flux-system Services; inline `additionalPodMonitors` in monitoring HelmRelease; scoping to only kustomize/helm; scraping flux-operator; recording rules/Alertmanager alerts; importing the community dashboard). This was a clarifying gap — the decisions were already made in the brief, so the addition is declarative, not decision-level.
 - Note: `schemaVersion: 40` and the explicit "two reconcilers, no coupling" framing from the brief were intentionally not added — they are JSON/architecture implementation details that belong in design.md or the dashboard JSON, not the proposal. The proposal's separate listing of Flux-reconciled PodMonitors and Terraform-reconciled dashboard already conveys the decoupling.

### 🔴 Outstanding
 - none

## design Round 1 — 2026-07-04
### 🔴 Fixed
 - Context section accurately transcribes the frozen proposal: Flux Operator v2.8.8, four controllers in `flux-system`, `http-prom`/8080 verified, operator-owned Services with `prune: Disabled`/`ssa: Ignore`, and both `podMonitorSelectorNilUsesHelmValues: false` + `serviceMonitorSelectorNilUsesHelmValues: false` confirmed at `clusters/pk3s/monitoring/helmrelease.yaml:47-48` (no monitoring HelmRelease change).
 - Both frozen capabilities implemented with no scope creep: `flux-metrics` (Decisions 1–4) and `flux-dashboard` (Decisions 5–7). No recording rules, no alerts, no flux-operator scrape, no ServiceMonitor+Service pattern.
 - Every brief commitment transcribed: 4 PodMonitors one-per-controller in `flux-system` (Decision 2); `app: <controller>` selector + named port `http-prom`/8080 + `/metrics` + 30s (Decision 1); `podMonitorSelectorNilUsesHelmValues: false` relied upon (Decision 4); dashboard title "Flux GitOps", uid `flux`, schemaVersion 40, Homelab folder, refresh 30s, now-6h→now, timezone browser (Decision 6); `"flux"` added to dashboards local (Decision 7); all panels pin datasource uid `prometheus`; 8 panels across 3 rows match the brief's full list verbatim (stat: rate/errors/workers/ratio; time-series: by result, errors by controller; per-resource: top-8 by 1h count, p95 duration); AGENTS.md update (Migration Plan step 6); one-time `terraform apply` with `GRAFANA_AUTH` (step 4 + Risks).
 - All 7 Decisions well-formed: each has explicit Choice / Why / Alternative-considered. Non-Goals aligned with the brief's 7 rejected alternatives (flux-operator, recording rules/alerts, reconfiguring Flux/Services/RBAC, UI edits) — the remaining rejected alternatives (ServiceMonitor+Service, inline additionalPodMonitors, deploy-only scope, community dashboard) are captured in the Decisions' "Alternative considered" sections.
 - Risk [Pod label assumption] correctly flagged: only `flux-system` Service labels were confirmed at explore, pod labels were not; real fallback provided (`app.kubernetes.io/component: <controller>`, noted as also present).
 - Other queries validated correct: `histogram_quantile(0.95, sum(rate(..._bucket[5m])) by (le, controller))` has `le` in the `by` clause ✓; `topk(8, sum(increase(..._count[1h])) by (kind, name, namespace))` is valid ✓; `result` label cardinality matches the verified `{success, requeue, requeue_after, error}` ✓; `by (controller)` on errors total is valid ✓.
 - Migration Plan is ordered and every step is verifiable: step 2 requires `kubectl get podmonitor -n flux-system` + Prometheus targets `UP` at `:8080/metrics` + `controller_runtime_*`/`gotk_*` series present; step 4 gates on `terraform plan` showing exactly one new `grafana_dashboard.flux` before `apply`; step 5 confirms panels render in Grafana; step 7 runs `openspec validate`.
 - Root kustomization insertion point verified correct: alphabetical slot between `flux-dashboard` and `forgejo` (confirmed against `clusters/pk3s/kustomization.yaml`: `flux-dashboard` < `flux-monitoring` < `forgejo`).
 - Format matches the expected repo design style: Context table, Goals/Non-Goals, numbered Decisions (each with Choice/Why/Alternative), Risks/Trade-offs, Migration Plan.
 - No placeholders, TODOs, or contradictions found.

### 🟡 Addressed
 - Fixed an unambiguous PromQL bug in the Success ratio query (Decision 6): the denominator used `clamp_min(sum(rate(controller_runtime_reconcile_total[5m])), 1)`. Since `rate()` returns per-second values (typically 0.01–0.5/s for homelab Flux controllers), the clamp at `1` activates on essentially every scrape, collapsing the ratio into a raw per-second rate (e.g. success 0.1/s ÷ total 0.11/s should be ≈0.91 but the formula returned 0.1÷1 = 0.1). Changed the clamp to `1e-9` so div-by-zero on idle clusters is still guarded without distorting the ratio. Added a one-line rationale noting rates are per-second and usually ≪ 1. No decision-level change (same query intent: success / total, guarded against zero).

### 🔴 Outstanding
 - none

## tasks Round 1 — 2026-07-04
### 🔴 Fixed
 - Frozen coverage complete: all 4 PodMonitors use the exact controller names (`source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`), each `namespace: flux-system`, `spec.selector.matchLabels.app: <controller>`, endpoint `port: http-prom`/`path: /metrics`/`interval: 30s` — matches frozen proposal/design/specs verbatim.
 - Design Risk [Pod label assumption] transcribed as task 1.7: confirm `app:` label at implement time with explicit fallback to `app.kubernetes.io/component: <controller>` — matches design.md Risk mitigation exactly.
 - Root kustomization insert (task 1.6) correctly placed alphabetically between `flux-dashboard` and `forgejo` — verified against actual `clusters/pk3s/kustomization.yaml`.
 - Flux reconcile + Prometheus `UP` verification present (tasks 2.1–2.4): force reconcile, `kubectl get podmonitor -n flux-system`, targets `UP` check.
 - All 8 dashboard panels use PromQL that matches frozen design.md **exactly** (no drift): Reconciliations/s `sum(rate(controller_runtime_reconcile_total[5m]))` ✓; Errors/s `sum(rate(controller_runtime_reconcile_errors_total[5m]))` ✓; Active workers `sum(controller_runtime_active_workers)` ✓; Success ratio uses `clamp_min(sum(rate(...)), 1e-9)` (the Round 1 design fix, NOT the explore-brief prose "success/(success+error+requeue)") ✓; Rate by result `sum(rate(...)) by (result)` ✓; Errors by controller `sum(rate(...)) by (controller)` ✓; Top resources `topk(8, sum(increase(gotk_reconcile_duration_seconds_count[1h])) by (kind, name, namespace))` ✓; Duration p95 `histogram_quantile(0.95, sum(rate(gotk_reconcile_duration_seconds_bucket[5m])) by (le, controller))` — `le` correctly in the `by` clause ✓.
 - Datasource uid `prometheus` pinned in every panel (task 3.1) — matches frozen design Decision 6 and existing dashboard JSON pattern (verified in `terraform/grafana/dashboards/forgejo.json`).
 - Dashboard metadata (task 3.1): title "Flux GitOps", uid `flux`, schemaVersion 40, timezone browser, refresh 30s, time now-6h→now, tags [homelab, flux] — matches frozen design + forgejo.json style exactly.
 - `dashboards.tf` edit (task 4.1): add `"flux"` to the `dashboards` local — verified the `toset([...])` + `for_each` + `overwrite = true` pattern; current set has 7 entries so "existing seven dashboards unchanged" in task 4.3 is correct.
 - `terraform plan` gate (task 4.3) before `apply` (task 4.4): expects exactly one addition — correct dependency ordering.
 - Dashboard verification (tasks 5.1–5.4): 8 panels render real data; topk panel lists real resources (`Kustomization/flux-system`, cluster `HelmRelease`s like forgejo/kube-prometheus-stack); UI-drift revert via re-`apply` (tests `overwrite = true`).
 - AGENTS.md updates (tasks 6.1–6.3): directory structure entry, Terraform dashboard list, Common Gotchas note on PodMonitor-vs-ServiceMonitor rationale — matches frozen proposal Impact + design Migration Plan step 6.
 - Close-out present: `openspec validate add-flux-metrics` (task 7.1), `make lint`/`terraform fmt -check` (task 7.2), mark tasks complete (7.3), archive (7.4).
 - No extra scope: no alerts, no flux-operator scraping, no recording rules, no ServiceMonitors, no Flux RBAC/Service patches — matches frozen Non-Goals exactly.
 - Ordering respects dependencies: PodMonitors applied + targets `UP` (section 2) before dashboard JSON authoring (section 3) before terraform plan→apply (section 4) before dashboard verification (section 5).
 - Granularity: every task is concrete, actionable, verifiable, and well under 2h. Format matches reference (`add-forgejo-ssh-access/tasks.md`): numbered sections, `- [ ]` checkboxes, inline verification commands.
 - `legendFormat` specified for all multi-series panels (by result, by controller, topk, p95) — matches forgejo.json convention.

### 🟡 Addressed
 - Fixed task 2.4 exec command: referenced `deploy/prometheus` but kube-prometheus-stack runs Prometheus as a StatefulSet managed by prometheus-operator (no Deployment named `prometheus` exists — verified the monitoring HelmRelease uses kps 87.x with `fullnameOverride: prometheus`, which creates a Prometheus CR + operator-managed StatefulSet, not a Deployment). Changed to `<prometheus-pod>` placeholder with instruction to find the pod name via `kubectl get pods -n monitoring`, and clarified the Prometheus UI path as "Status → Targets". Declarative fix of a broken verification command — no approach change.

### 🔴 Outstanding
 - none

## specs Round 1 — 2026-07-04
### 🔴 Fixed
 - Capability coverage is exact: the `specs/` directory contains precisely the two new capabilities named in the frozen proposal (`flux-metrics`, `flux-dashboard`) — no missing, no extra, no modified-capability deltas (correct, since no prior spec covered Flux).
 - `flux-metrics/spec.md` is fully consistent with the frozen proposal + design: all four controllers enumerated by exact name (`source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`); `PodMonitor` method (not ServiceMonitor); `http-prom`/8080 + `/metrics` + 30s carried in the scenario; nil-selector referenced by exact field name `podMonitorSelectorNilUsesHelmValues: false` with the correct file path `clusters/pk3s/monitoring/helmrelease.yaml` (verified at line 48); "no change to the monitoring HelmRelease" stated in both the requirement body and a dedicated scenario.
 - `flux-metrics` "No Flux resource is patched" scenario correctly distinguishes the manifest location (`clusters/pk3s/`) from the applied namespace (`flux-system`) and asserts Flux Services/Deployments/Operator stay untouched — matches frozen Non-Goals (no Flux/RBAC/Service reconfiguration). Valuable, testable, non-tautological.
 - `flux-dashboard/spec.md` is fully consistent with the frozen proposal + design: title "Flux GitOps", uid `flux`, Homelab folder, datasource pinned by uid `prometheus`, sourced from `terraform/grafana/dashboards/flux.json`, `"flux"` added to the `dashboards` local in `terraform/grafana/dashboards.tf` (verified the `toset([...])` + `for_each` + `overwrite = true` pattern at `dashboards.tf:1-18`).
 - Panel count and structure match Decision 6 exactly: stat row lists 4 panels (reconciliations/s, errors/s, active workers, success ratio); time-series row lists 2 (rate by `result`, errors by `controller`); per-resource row lists 2 (top resources by 1h count grouped by `kind,name,namespace`, p95 duration by controller) — 8 panels across 3 rows. The `result` label values (`success`/`requeue`/`requeue_after`/`error`) match the verified set from the brief.
 - Metric-family references in scenarios are accurate: stat row → `controller_runtime_*`; per-resource row → `gotk_reconcile_duration_seconds_*` (wildcard correctly covers `_count` for top-resources and `_bucket` for p95).
 - "UI drift is reverted" scenario (references `overwrite = true`) and "Datasource pinned by UID" scenario are both valuable and testable, mirroring the archived `grafana-dashboards/spec.md` reference pattern.
 - "Dashboard has real data once scraped" is a legitimate cross-capability integration scenario (references `flux-metrics`), not a tautology — it tests the dashboard renders given scraping, distinct from "series exist in Prometheus."
 - Modal verbs present in every requirement body: `flux-metrics` Req1 "MUST scrape", Req2 "MUST NOT modify"; `flux-dashboard` Req1 "MUST be provisioned", Req2 "MUST render". Validator-compliant.
 - No decision creep: no alerts, no flux-operator scraping, no recording rules, no ServiceMonitors, no RBAC changes — scope matches frozen Non-Goals exactly.
 - Format matches the archived reference specs (`forgejo-metrics`, `grafana-dashboards`): `## ADDED Requirements`, `### Requirement:`, `#### Scenario:`, bold `- **WHEN**` / `- **THEN**`. No placeholders, TODOs, or ambiguity.

### 🟡 Addressed
 - none

### 🔴 Outstanding
 - none

## design UNFREEZE — 2026-07-04 (post-deploy verification)
### 🔴 Reason
 - Verification (Prometheus query of live data) revealed the "Reconcile Success
   Ratio" panel reads ~0 permanently: Flux's `controller_runtime_reconcile_total`
   is dominated by `result="requeue_after"` (38120) with `result="success"`
   near-absent (26). The panel `success/total` is therefore non-informative.
 - Decision-level change (panel semantics + PromQL) → unfreeze design.md and all
   downstream artifacts (flux-dashboard spec, tasks.md). flux-metrics spec and
   proposal.md are unaffected.
### 🟢 Approved fix (user-approved)
 - Rename panel "Reconcile Success Ratio" → "Reconcile Health".
 - Query: `1 - (sum(rate(controller_runtime_reconcile_total{result="error"}[5m])) / clamp_min(sum(rate(controller_runtime_reconcile_total[5m])), 1e-9))`
   — reads ~1.0 healthy, drops toward 0 as errors spike.

## design Round 2 (post-unfreeze) — 2026-07-04
### 🔴 Fixed
 - **Internal consistency (all 3 unfrozen files):** the panel name "Reconcile health" and the non-error-ratio query are identical across design.md (Decision 6 Row 1 line 123 + PromQL bullet lines 133–138), `specs/flux-dashboard/spec.md` (Requirement body line 28 + "Overview stat row" scenario lines 35–38), and `tasks.md` task 3.2 (lines 47–49). Grep across the change dir confirms NO leftover "success ratio" panel name or `result="success"` health query in any of the three files — the sole `result="success"` hit in design.md (line 174) is the *intentional* explanation inside the [Flux `result` label skew] Risk bullet, and the `result ∈ {success,...}` enumeration at line 39 documents label cardinality (unchanged from Round 1, still accurate). The frozen proposal.md's "reconcile success ratio" summary is intentionally left per instructions.
 - **PromQL correctness:** `1 - (sum(rate(controller_runtime_reconcile_total{result="error"}[5m])) / clamp_min(sum(rate(controller_runtime_reconcile_total[5m])), 1e-9))` is mathematically sound — numerator is the per-second error rate summed across controllers, denominator is the per-second total rate (all results) clamped at 1e-9 to guard div-by-zero on an idle cluster without distorting the ratio (rates are ≪ 1/s, so the Round-1 epsilon fix is preserved). Reads exactly 1.0 when error rate is 0 (verified live), monotonically toward 0 as errors dominate. Unchanged panels remain correct: `histogram_quantile(0.95, sum(rate(gotk_reconcile_duration_seconds_bucket[5m])) by (le, controller))` keeps `le` in the `by` clause ✓; `topk(8, sum(increase(gotk_reconcile_duration_seconds_count[1h])) by (kind, name, namespace))` valid ✓.
 - **Risk bullet accuracy:** [Flux `result` label skew] (design.md lines 172–177) correctly attributes the failure mode — interval-driven reconciles dominate `requeue_after` while `success` is near-zero — and quotes live counts (`requeue_after`≈38k, `error`≈0.1k, `success`≈tens) that match the grounding (38120 / 111 / 26) within rounding. The remediation (use `1 - error/total`, not `success/total`) follows directly.
 - **No scope creep:** diff is confined to the one health panel (name + query) and its explanatory Risk bullet. The other 7 panels, all 4 PodMonitors, the terraform/dashboards.tf edit, the AGENTS.md tasks, and the migration plan are byte-identical to Round 1.
 - **Consistency with frozen artifacts:** no contradiction with proposal.md (its "success ratio" phrasing is frozen and explicitly out-of-scope per instructions) or `specs/flux-metrics/spec.md` (which concerns scraping only and names no panels).
 - **No placeholders / TODO / ambiguity** introduced in any of the three files.
### 🟡 Addressed
 - none
### 🔴 Outstanding
 - none
