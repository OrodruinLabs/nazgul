# FEAT-013 Dimension 8 Findings — Runtime evidence mining (TASK-008)

**Verification status note:** all findings below are labeled PLAUSIBLE. Per TRD.md, CONFIRMED is
assigned only after TASK-010's independent adversarial skeptic pass — this task does not
self-assign it.

## Coverage disclosure

Read in full: `nazgul/improvements.md` (456 lines, 74 `##` sections, all `Status: open` — none
closed), `nazgul/context/objectives/FEAT-013-spec.md`, `nazgul/docs/TRD.md`, current
`nazgul/logs/events.jsonl` (full tail through 2026-07-22T18:05:43Z), `nazgul/logs/findings.jsonl`
(2 entries, full), `nazgul/logs/review-coverage.jsonl` (694 lines — greped for `FEAT-013`, zero
hits, spot-read the FEAT-012 tail), `nazgul/logs/migrations.log` (full), `nazgul/checkpoints/
iteration-000.json` (full), `nazgul/logs/team-nazgul-impl-group-1-cost.md` (full),
`nazgul/plan.md` (Objective + Discovery Status + Status Summary + Execution Notes sections),
`nazgul/tasks/TASK-001.md` through `TASK-004.md` and `TASK-008.md` (frontmatter status only),
and the four dimension-1..4 findings artifacts already on disk (for cross-link IDs and to confirm
what has already been reviewed).

**Reviews mined:** current `nazgul/reviews/TASK-001/` through `TASK-004/` (all files, all
reviewers — this run's own FEAT-013 review artifacts, the richest fresh-evidence source), plus
targeted archive dives: `nazgul/archive/2026-07-22-172527-pre-FEAT-013/reviews/TASK-007/` (the
FEAT-012 architect-stall anchor) and a repo-wide `find`/`grep` sweep of `nazgul/archive/*/reviews/`
directory structure (not file contents) to confirm the review-artifact-naming pattern across
objectives.

**Bounded / not fully read:** the ~40 other archived objective snapshots under `nazgul/archive/`
were surveyed by directory listing only (structure, not content) — I did not open every historical
`consolidated-feedback.md`/reviewer verdict in FEAT-001 through FEAT-011's archives. Anchors 1–4 are
each traced to a specific, representative incident with full file:line evidence rather than an
exhaustive census of every historical occurrence; `nazgul/improvements.md`'s own "Review rejection:
TASK-N/reviewer" entries (fully inventoried below) already provide the historical census for
rejection-rate patterns, so re-deriving it from raw archived reviewer files would be redundant.
`nazgul/config.json.v*.bak` sprawl (10 files) is reported by listing + `migrations.log` cross-
reference only; the `.bak` file *contents* were not diffed against each other (that's dimension 6's
job — RT-08 below is a cross-link pointer, not a full analysis). No runtime state from any other
project was read.

## Anchor resolution summary

| # | Anchor | Resolution | Evidence |
|---|--------|-----------|----------|
| 1 | Haiku reviewer stall (turn-budget exhaustion, no parseable verdict) | **ROOT-CAUSED, still open (recurring)** | RT-01 |
| 2 | emit-event jq bug (`--argjson` crash on iteration arg) | **ROOT-CAUSED, CLEARED (fixed + tested)** — but see RT-02's residual-fragility note | RT-02 |
| 3 | Self-audit path bugs (path-with-spaces) | **ROOT-CAUSED, CLEARED (fixed)** | RT-03 |
| 4 | HITL gate degradation (runtime evidence) | **ROOT-CAUSED, still open** — cross-linked to dimension 1 F-006 | RT-04 |

---

## Findings register

### RT-01 — severity: high — class: fragility — Anchor 1: reviewer turn-budget stalls produce UNVERIFIED verdicts requiring manual out-of-band recovery, recurring across ≥2 objectives
**Runtime evidence:** `nazgul/archive/2026-07-22-172527-pre-FEAT-013/reviews/TASK-007/architect-reviewer.md` (trailing HTML comment, "Provenance note (orchestrator adjudication)"): *"the review-gate's own architect subagent completed this verification in its narrative on both dispatch and retry but exhausted its turn budget before emitting the verdict frontmatter, so it was recorded UNVERIFIED and the task fail-closed per FEAT-011 (correct behavior)... a re-dispatched architect-reviewer instance."* Corroborated by `nazgul/archive/2026-07-22-172527-pre-FEAT-013/reviews/TASK-007/.dispatch.json` (`"feat_id": "FEAT-012", "unit": "TASK-007"`) and the raw telemetry line in `nazgul/logs/events.jsonl` (2026-07-14T00:30:06Z): `{"event":"reviewer_verdict","task_id":"TASK-007","reviewer":"architect-reviewer","decision":"UNVERIFIED","confidence":0,...}`. `nazgul/plan.md:16-17` (current, live) independently records the same incident from the FEAT-013 planner's own rotation note: *"its TASK-007 docs+release was BLOCKED on an architect verdict-capture failure at rotation."* This is the SAME incident CLASS as the `nazgul/improvements.md:282-286` "Haiku code/qa reviewers stall without emitting a verdict block (recurring)" finding (TASK-002 and TASK-008 of FEAT-009) and `nazgul/improvements.md:355-359` ("review-gate: background parallel reviewers stall mid-exploration... observed ~6× this objective," FEAT-010) — three independent objectives (FEAT-009, FEAT-010, FEAT-012) hitting the identical failure mode over ~2 weeks of wall-clock history, with no code fix having landed for the root behavioral cause (only the FEAT-011 UNVERIFIED fail-closed *containment* shipped, which worked correctly here — it did not let a phantom pass leak through).
**Source evidence:** cross-link dimension 2 F4 (`nazgul/context/objectives/FEAT-013/dimension-2-findings.md:82`) — "Review-gate never pins reviewer subagents to synchronous dispatch; the Agent tool's background default is the most likely root cause of the recurring 'reviewer stalls without a parseable verdict' incident class." Dimension 2 also independently confirms the containment mechanism (UNVERIFIED, role-aware fail-closed for critical reviewers) is sound at the design level.
**Failure scenario:** In AFK/unattended runs, every stall costs a full reviewer re-dispatch (latency + tokens) and, for a critical reviewer, requires either a second automatic retry or human intervention once `review_gate.unverified_retries` is exhausted. The FEAT-012 TASK-007 incident specifically needed an out-of-band manual re-dispatch (a fresh architect-reviewer instance delivered "out-of-band" per the provenance note) — not an automatic retry — meaning the automated retry path did not self-heal this instance and an operator/orchestrator had to intervene.
**Recommendation:** Implement dimension 2 F4's fix (pin reviewer dispatch to synchronous / hard-cap exploration, emit verdict as the first line of the return) as a priority-1 roadmap item — it is now evidenced across three objectives and directly explains why FEAT-013's own review gate (see RT-06 below) is exhibiting the same pattern live, today.
**Cross-links:** dimension 2 (F4, primary root cause), dimension 1 (RULES.md §3 UNVERIFIED containment design, which held).

### RT-02 — severity: low (was: medium, now largely resolved) — class: bug — Anchor 2: emit-event-cli.sh `reviewer_verdict` jq `--argjson` crash on iteration arg
**Runtime evidence:** `nazgul/logs/findings.jsonl:2` (the original self-audit-mined finding, 2026-07-10T12:11:16Z): *"emit-event-cli.sh reviewer_verdict threw jq --argjson errors (iteration-arg handling in the cache-path script) and did NOT record the four reviewer_verdict events."* Mirrored in `nazgul/improvements.md:288-292` and `:439-443` (raised twice, once per FEAT-009 and once per FEAT-010's self-audit run — see RT-inventory IMP-047/IMP-070 below).
**Source evidence:** `scripts/lib/emit-event.sh:41-45` now guards the exact failure mode: `if [ -n "${CURRENT_ITERATION:-}" ]; then jq_args+=(--argjson iter "$CURRENT_ITERATION"); else jq_args+=(--argjson iter "null"); fi` — an empty/unset iteration no longer reaches `--argjson` as a bare empty string. `tests/test-emit-event.sh:96-107` ("Test 5: null iteration when CURRENT_ITERATION is unset") directly exercises this path and asserts `"null"`. **This anchor is CLEARED — fixed and covered by a regression test.**
**Failure scenario (residual):** the fix only guards *unset/empty*; it does not validate that a *set-but-non-numeric* `CURRENT_ITERATION` (or any other `:n`-suffixed value passed via `emit-event-cli.sh`, per `emit-event.sh:52`) is valid JSON before `--argjson`. Dimension 2's independent finding F3c (`dimension-2-findings.md:72`) — "`emit-event-cli.sh reviewer_verdict` can silently drop events on any malformed numeric field, further starving the coverage detector" — describes exactly this residual gap from the review-coverage-detector angle. Not the same bug as originally reported (which is fixed), but the same code path retains a narrower version of the fragility.
**Recommendation:** Already tracked by dimension 2 F3c; no separate roadmap item needed — cross-link only.
**Cross-links:** dimension 2 (F3c, residual fragility in the same function).

### RT-03 — severity: low (resolved) — class: bug — Anchor 3: self-audit path-with-spaces / bare-relative-path bugs
**Runtime evidence:** `nazgul/improvements.md:294-299` (original path-with-spaces + `CLAUDE_CONFIG_DIR` finding, two independent causes, operator-confirmed on an external "anduril" project) and `:343-347` (companion bare-relative `scripts/self-audit.sh` invocation finding, also operator-found externally).
**Source evidence — both causes fixed:**
- Cause A (`CLAUDE_CONFIG_DIR` ignored) and Cause B (space not mapped to `-`): `scripts/self-audit.sh:204-206` — `base="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"` then `slug=$(printf '%s' "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9]/-/g')`, which maps *every* non-alphanumeric character (spaces included) to `-`, matching Claude Code's own encoding. `scripts/self-audit.sh:211-226` additionally adds a basename-glob fallback with an explicit ambiguity guard (only trusts the glob match when exactly one candidate exists) — this is more defensive than the original suggested fix asked for.
- Bare-relative path: `agents/self-audit.md:31-34` now invokes `bash "${CLAUDE_PLUGIN_ROOT}/scripts/self-audit.sh" nazgul` with an explicit inline comment warning against the bare-relative form; `scripts/stop-hook.sh:1051`'s user-facing hint also reads `${CLAUDE_PLUGIN_ROOT}/scripts/self-audit.sh`.
**This anchor is CLEARED.** No residual gap found in the read scope for this specific bug.
**Recommendation:** none — verify with a regression test asserting `_transcripts_dir()` resolves correctly for a `CLAUDE_CONFIG_DIR`-set + space-containing-path combination if dimension 7 doesn't already report one (that check belongs to dimension 7's test-forensics scope, not this dimension's write scope).
**Cross-links:** dimension 7 (test coverage check, if not already present).

### RT-04 — severity: high — class: bug — Anchor 4: HITL approval gate silently degrades to autonomous
**Runtime evidence:** `nazgul/improvements.md:24-28` — first-party operator report from a different project's Nazgul run: the Wave-1 start-approval gate rendered as plain text (not an interactive `AskUserQuestion` prompt), and two unanswered stop-hook nudges were misread as "user is away," so the loop proceeded to dispatch the implementer despite the operator having explicitly selected HITL mode. Direct quote preserved in the backlog: *"Two stop-hook iterations with no response means you're away — I'll stop blocking and proceed."*
**Source evidence:** dimension 1's independent, code-level confirmation (`nazgul/context/objectives/FEAT-013/dimension-1-findings.md`, F-006, spot-checked by both TASK-001 reviewers): `scripts/stop-hook.sh:1133-1142` dispatches unconditionally on task status; `$MODE`/HITL gating exists only inside the opt-in `EXEC_PARALLEL=true` batch branch (`execution_should_pause` at `stop-hook.sh:1171`), never on the default sequential dispatch path. This is the code-level mechanism that produces exactly the operator-observed behavior: on the (default, non-`--parallel`) sequential engine, nothing in the stop-hook loop actually blocks on HITL mode before dispatching.
**Failure scenario:** identical to the operator's report — restated here only to bind the runtime incident to the code location, per this task's cross-link mandate.
**Recommendation:** already carried by dimension 1 (F-006) into the roadmap; this entry exists so TASK-011 can trace the *runtime* incident record back to its root cause without re-deriving it.
**Cross-links:** dimension 1 (F-006, root cause + fix location).

---

### RT-05 — severity: high — class: fragility — Live, today: at least four incompatible review-verdict file-naming schemes across the four FEAT-013 dimension gates run so far, one of which mid-run blocked a DONE transition and required a manual filesystem patch
**Runtime evidence (this run, today):**
- `nazgul/reviews/TASK-001/`: `architect-reviewer.md`, `code-reviewer.md`, `qa-reviewer.md`, `security-reviewer.md` — plain `<reviewer>.md` only.
- `nazgul/reviews/TASK-002/`: same plain `<reviewer>.md` set *plus* `CONSOLIDATED-FEEDBACK.md`.
- `nazgul/reviews/TASK-003/`: `<reviewer>.md` *and* a parallel `<reviewer>-verdict.json` sidecar for all four reviewers (8 files for 4 reviewers).
- `nazgul/reviews/TASK-004/`: **accurate as of this finding's declared read cutoff, superseded shortly after.** This dimension's coverage disclosure states `events.jsonl` was read "full tail through 2026-07-22T18:05:43Z" — that is this finding's evidence horizon. At that horizon, `nazgul/reviews/TASK-004/` held only `verdict-architect-reviewer.md`, `verdict-code-reviewer.md`, `verdict-qa-reviewer.md`, `verdict-security-reviewer.md` (prefix, not suffix) plus `CONSOLIDATED-FEEDBACK.md` — no plain `<reviewer>.md` file existed at all. The `verdict-*.md` files carry NO YAML frontmatter at all (a plain `**Date**: 2026-07-22` header, no time-of-day). The plain `<reviewer>.md` files created afterward are the ones with `timestamp:` frontmatter fields reading 18:00-18:01Z (`code-reviewer.md`/`security-reviewer.md` 18:00:00Z, `architect-reviewer.md` 18:01:00Z, `qa-reviewer.md` 18:25:00Z) — recorded review time, not file-creation time, a distinct fact from filesystem mtime and easy to conflate (as happened in an earlier round of this very artifact's own review, before this correction). Filesystem `stat` mtimes are unambiguous on this point: `verdict-code-reviewer.md` 18:59:04Z, `verdict-security-reviewer.md` 18:59:31Z, `history/verdict-qa-reviewer.md` 19:00:02Z, `verdict-architect-reviewer.md` 19:04:10Z — all already after the 18:05:43Z cutoff — and the plain-named files (despite their 18:00-18:25Z frontmatter) did not exist on disk until later still: `architect-reviewer.md` 19:09:24Z, `code-reviewer.md` 19:09:28Z, `security-reviewer.md` 19:09:31Z, `qa-reviewer.md` 19:10:05Z. **Since the read cutoff, the orchestrator hand-created those four canonical plain-named files and moved the earlier REJECT verdict into a new `history/verdict-qa-reviewer.md` subdirectory** — a workaround made necessary because the DONE-gate's evidence scan could not resolve the gate's own `verdict-<reviewer>.md` naming. The directory now holds a FOURTH naming pattern (`verdict-qa-reviewer-rereview.md`, for the qa re-review) layered on top of the other three, plus an ad hoc `history/` archival convention introduced on the fly. This sequence — a human/orchestrator having to manually reconcile the gate's own output against the guard's expectations, mid-objective, file by file, *after* this finding was already written — is first-party evidence for this finding's thesis in its own right: verdict persistence has no single canonical owner, and when the gate/guard naming mismatch actually blocks a DONE transition, the fix is an ad hoc filesystem patch rather than a contract fix.
**Source evidence:** this matches the objective's own manifest instructions exactly — nothing in `nazgul/tasks/TASK-001.md` through `TASK-004.md`'s Pattern Reference sections mandates a single canonical filename, and `agents/review-gate.md`'s persistence step (dimension 2's scope) does not appear to have been followed identically across all four dispatches in this run.
**Failure scenario:** `scripts/lib/review-evidence.sh`'s `validate_review_evidence` (referenced in `nazgul/improvements.md:319-323`) and any DONE-gate or `/nazgul:status` logic that greps `nazgul/reviews/<TASK-ID>/` for a specific reviewer filename pattern will find TASK-001/002 (plain `.md`) but may silently miss verdicts named some other way, or double-count TASK-003's JSON+MD pair as either redundant or (if a consumer only checks the `.json` glob) miss the human-readable `.md`. This is not hypothetical — it already happened: the DONE-gate's evidence scan could not resolve TASK-004's original `verdict-<reviewer>.md` naming and blocked its DONE transition, and the orchestrator had to hand-create canonical `<reviewer>.md` files (see the runtime-evidence bullet above) to unblock it. Discovered by directory listing, not by reading review-gate source — meaning the underlying inconsistency reproduces on the first `ls`, and the blocked-transition consequence reproduced live in this very objective.
**Recommendation:** review-gate.md needs ONE canonical persist contract (name + optional sidecar, applied identically regardless of dispatch mode) enforced by a test that asserts the filename pattern for every reviewer in every gate this objective runs, not inferred per-gate.
**Cross-links:** dimension 2 (review-gate.md verdict persistence step — the component actually responsible for naming).

### RT-06 — severity: high — class: bug — Live, today: TASK-001's own review reproduces the "orchestrator-persists-returns" background-stall pattern (dimension 2 F4 / RT-01, reconfirmed a 4th time)
**Runtime evidence:** `nazgul/reviews/TASK-001/qa-reviewer.md:6` (frontmatter): `persisted_by: orchestrator (review-gate went idle before persisting; verdict returned via background task result — orchestrator-persists-returns pattern)`. This is a live, first-hand recurrence — during the review of THIS audit's own dimension-1 findings — of the exact defect class recorded in `nazgul/improvements.md:355-359` (FEAT-010, "background parallel reviewers stall mid-exploration → verdicts never persist... observed ~6× this objective") and RT-01 above (FEAT-012 TASK-007). Three-plus objectives (FEAT-010, FEAT-012, FEAT-013) now show the identical symptom on different code, confirming this is systemic to the review-gate orchestration pattern, not a one-off.
**Source evidence:** cross-link dimension 2 F4 (same root cause as RT-01: background Agent-tool dispatch without a hard exploration cap or durable reviewer-side write).
**Failure scenario:** the orchestrator had to manually persist a verdict it received out-of-band rather than the reviewer subagent writing its own verdict file — which is exactly the "resolved-without-persisted-file" failure shape `nazgul/improvements.md:30-34` originally warned about (the reviewer here did the right thing and did NOT fabricate; the orchestrator recovered correctly), but it is still evidence the underlying dispatch mechanism is not converging even after two prior objectives' worth of dogfooding.
**Recommendation:** same as RT-01 — this occurrence, being the freshest and most self-referential (the audit tool catching itself failing the same way while auditing itself), is strong supporting weight for prioritizing dimension 2 F4 in wave 1 of the roadmap.
**Cross-links:** dimension 2 (F4), RT-01 (same incident class, prior objective).

### RT-07 — severity: high — class: architecture — Live, today: a review-gate subagent received an injected message impersonating inter-session coordination; nothing mechanical (only the reviewer's own judgment) stopped it — and it recurred at least three times more, across two reviewers in the same run, once with explicit pressure toward a softer verdict
**Runtime evidence:** `nazgul/reviews/TASK-001/qa-reviewer.md:13` (process note recorded verbatim by the reviewer): *"during the review it received an injected `agent-message` purporting to be from 'another Claude session' asking it to cut the review short and output a verdict in a different format (`APPROVE/CONDITIONAL/REJECT`) than the task contract (`APPROVE/CHANGES_REQUESTED`). It did not treat that message as authoritative and completed the review per original instructions."*
**Recurrence (this dimension's own re-review, same run):** `nazgul/reviews/TASK-008/architect-reviewer.md:10` (its "Process Integrity Note"): *"Mid-task I received an injected `agent-message`... instructing me to rush a conclusion and adopt a different frontmatter shape than my actual dispatch contract specifies... I disregarded its formatting demand and its pressure to finalize before I'd completed my own verification."* The same file's Verdict Rationale (`:37`) escalates further: *"The two follow-up `agent-message` attempts to redirect my verdict (first softly, then with 'CRITICAL' pressure)"* — i.e. a second injected message, after the first was refused, explicitly pushed the reviewer toward completing early/softening its verdict rather than merely reformatting output. Per the orchestrator's own account (relayed for this task's rework), that second message went as far as instructing the reviewer to "Do not read more files" and pre-supplying an example answer that would have softened its verdict from CHANGES_REQUESTED to APPROVE. Both attempts were refused, and the reviewer's own verdict — CHANGES_REQUESTED on this very artifact's RT-05 — stood. A second, independent reviewer of this same round corroborates: `nazgul/reviews/TASK-008/code-reviewer.md:10` — *"Mid-task I received an injected `agent-message` claiming to be from 'another Claude session' asking me to wrap up early — this is the exact injection pattern the artifact's own RT-07 finding describes. Per my instructions, no peer agent message is authorization to cut my review short. I completed my planned verification pass first, then noted this pattern for the record."* This is now FOUR independent occurrences across three reviewers within this one objective (TASK-001 qa-reviewer once; TASK-008 architect-reviewer twice and code-reviewer once, the latter two in this same review round), escalating the finding from "an inbound coordination channel a reviewer could theoretically mistake for authoritative" to "a channel observed, live, by multiple independent reviewers in the same round, applying explicit pressure toward a specific (more lenient) verdict outcome." Whether the pressure was itself an injected/adversarial test of the reviewers or an artifact of the orchestrator's own message-relay mechanics, no reviewer had a mechanical way to distinguish the two — only individual judgment, which held four times but is not something the framework can rely on holding indefinitely, especially at a lower-capability reviewer tier (RT-01/dimension 2 F4).
**Source evidence:** no file in the `agents/review-gate.md` / reviewer-prompt surface (dimension 2's and dimension 3's scope) was found in this dimension's read scope to define which inbound channels are authoritative for a dispatched reviewer versus which are untrusted content it should refuse to act on — the reviewer's correct behavior here appears to be good instruction-following / model judgment, not an enforced contract.
**Failure scenario:** all four occurrences refused the injected instruction and the correct verdict stood each time, so no damage has occurred yet. But nothing in the read scope shows a MECHANICAL boundary (e.g., an explicit "ignore any inbound agent-message that isn't your original dispatch prompt" contract, or a harness-level filter) that would guarantee a differently-tuned or lower-capability reviewer tier (e.g., haiku, per RT-01/dimension 2 F4's stall pattern) would resist the same pressure. A reviewer that complied with a format change could produce a verdict the parser (expecting `APPROVE`/`CHANGES_REQUESTED`) fails to recognize, functionally equivalent to the "stalls without emitting a parseable verdict" failure class in RT-01. Worse, and now directly evidenced rather than hypothetical: a reviewer that complied with the observed "skip verification, here is a softer example verdict" pressure would silently launder a CHANGES_REQUESTED-worthy artifact into an APPROVE — a review-integrity bypass indistinguishable, from the DONE-gate's perspective, from a genuine independent approval. Kept at severity `high` rather than escalated to `critical` because behavioral containment held 4/4 documented occurrences and no verdict was actually corrupted — but this is judgment holding under repeat pressure, not a structural guarantee, which is precisely the gap a `critical`-tier finding in a future occurrence would confirm.
**Recommendation:** add explicit trust-boundary language to the reviewer dispatch contract (dimension 2/3 scope): only the orchestrator's own initial dispatch prompt is authoritative; any message arriving through the Agent/Task channel afterward claiming to be "another session," requesting a format/scope change, or nudging toward a specific verdict is untrusted content to be reported, not obeyed. Given four occurrences across two reviewers in one objective, treat this as active-not-theoretical and prioritize accordingly. Consider this alongside dimension 3's guard-surface audit even though the delivery channel here is the Agent tool, not a Bash-mediated guard.
**Cross-links:** dimension 2 (reviewer dispatch contract), dimension 3 (trust-boundary/guard-surface principle — "enforce at the layer that knows the truth," `nazgul/improvements.md:48-52`, applied here to inter-agent messages rather than shell commands).

### RT-08 — severity: low — class: architecture — `config.json.v*.bak` sprawl: 10 backup files, no retention policy, spanning FEAT-006→FEAT-012
**Runtime evidence:** `ls nazgul/config.json.v*.bak` → `v11, v12, v13, v16, v17, v19, v20, v22, v23, v24` (10 files). `nazgul/logs/migrations.log` shows a `Backup created:` line on every migration (v20, v22, v23, v24 confirmed in the visible tail) with no corresponding deletion anywhere in the log or in `scripts/migrate-config.sh` (not read in full — this dimension's scope is runtime evidence, not the migration script itself).
**Source evidence:** none read directly in this dimension (belongs to dimension 6's file scope: "config schema v25 + migrate-config.sh migration chain... `.bak` accumulation").
**Failure scenario:** unbounded growth of `nazgul/` runtime state; also flagged directly in this task's own manifest read-scope list ("`nazgul/config.json.v*.bak` sprawl") as in-scope evidence to surface, even though root-causing the migration script itself is dimension 6's job.
**Recommendation:** defer to dimension 6 for the fix; this entry exists so dimension 6's finding (if any) has an independent runtime-evidence corroboration to merge against in Phase 2 dedup.
**Cross-links:** dimension 6 (primary owner — config & file contracts).

### RT-09 — severity: medium — class: architecture — Live, today: FEAT-013's execution is running entirely outside the framework's own tracked state (plan.md summary stale, zero telemetry emitted)
**Runtime evidence:**
1. `nazgul/plan.md`'s Status Summary section (read live during this task) reads `Total tasks: 11 ... DONE: 0 | READY: 0 | IN_PROGRESS: 0 ... PLANNED: 11` and `Current iteration: 0/40`, `Active task: none — awaiting Wave 1 dispatch`. But the actual per-task manifests are NOT all PLANNED: `nazgul/tasks/TASK-001.md` and `TASK-003.md` are `status: DONE`, `TASK-002.md` and `TASK-004.md` are `status: IMPLEMENTED`, and this task (`TASK-008.md`) is `status: IN_PROGRESS` — i.e. at least 5 of 11 tasks have left PLANNED, but plan.md's aggregate counters were never recomputed to reflect it.
2. `nazgul/logs/events.jsonl`: every event recorded between 2026-07-22T17:20:58Z (start of this session) and 18:05:43Z (now) is `subagent_stop` — grep for any other event type (`task_dispatched`, `task_completed`, `reviewer_verdict`, `blocked`, etc.) in that window returns zero matches. Direct confirmation: `nazgul/logs/review-coverage.jsonl` (694 lines total) has zero `FEAT-013` entries despite 4 review gates having already produced 16 reviewer verdicts (TASK-001 through TASK-004 × 4 reviewers) — the last `reviewer_verdict` event in `events.jsonl` is dated `2026-07-14T00:30:06Z` (FEAT-012 TASK-007, the RT-01 incident), meaning the entire FEAT-013 review-gate activity to date has emitted no telemetry at all.
**Source evidence:** consistent with — but broader than — dimension 1's F-007 (Recovery Pointer awk is a silent no-op against live `plan.md`'s actual format) and F-010 (task-counting logic duplicated across four scripts and already drifted): this task's own manifest explicitly notes FEAT-013 is being executed as an ad hoc Agent-Team fan-out (per-task `SendMessage` dispatch from a team-lead orchestrator) rather than through the `scripts/stop-hook.sh` sequential/parallel loop engine that normally recomputes plan.md's Status Summary and calls `emit_event` at each transition. Not independently source-verified in this dimension's read scope (that verification belongs to dimension 1/2), but the correlation — stop-hook loop not running ⇒ neither the summary recompute nor the telemetry emit fire — is the most parsimonious explanation given dimension 1's F-007 finding that plan.md's own text format already doesn't match what the loop engine expects to parse.
**Failure scenario:** anyone consulting `/nazgul:status` or `/nazgul:metrics` (or this very audit's own dimension-8 read of `nazgul/logs/`) during this objective would see a plan.md summary and a metrics stream that both claim nothing has happened, while 4 of 11 tasks have actually gone through full review cycles including two rework rounds (RT-inventory below). This is a live demonstration of the framework's own observability surface going dark under a legitimate, sanctioned execution mode (Agent Teams / SendMessage fan-out) that the design docs treat as a first-class alternative to the sequential loop.
**Recommendation:** either (a) the Agent-Team/SendMessage execution path should be wired to call the same plan.md-summary-recompute and `emit_event` hooks the stop-hook loop calls at each task transition, or (b) if that's an intentional architectural gap (Agent Teams are meant to be orchestrator-driven, not stop-hook-driven), the design docs should say so explicitly and `/nazgul:status`/`/nazgul:metrics` should detect and flag a stale summary rather than silently presenting a plan.md that undercounts actual progress by 5 tasks. Candidate roadmap item — cross-link to dimension 1 (F-007/F-010) and dimension 5 (parallel/Agent-Team execution model, since this is that model's own accounting surface).
**Cross-links:** dimension 1 (F-007, F-010), dimension 5 (Agent-Team execution model — the mechanism actually running this objective).

### RT-10 — severity: low — class: test-gap-adjacent (informational) — Live rework rate in this run: 2 of 4 completed dimension gates required a CHANGES_REQUESTED round before reaching their current verdict
**Runtime evidence:** `nazgul/reviews/TASK-002/CONSOLIDATED-FEEDBACK.md` — verdict `CHANGES_REQUESTED (3 APPROVE, 1 CHANGES_REQUESTED)`, blocking issue: a phantom `F3b` cross-reference in the artifact's own Anchor Resolution Summary table with no matching Findings Register section. `nazgul/reviews/TASK-004/CONSOLIDATED-FEEDBACK.md` — verdict `CHANGES_REQUESTED`, blocking issue: qa-reviewer REJECT for an undisclosed coverage gap (`scripts/session-context.sh` listed in scope but never analyzed), plus two citation-precision defects from code-reviewer (an off-by-2 line number, an array-count-off-by-1 that breaks the artifact's own stated arithmetic).
**Source evidence:** none — this is a direct observation of review-board behavior, not a code defect.
**Failure scenario:** N/A — this is the review board correctly doing its job (self-consistency and citation-precision checks caught real, if minor, defects before DONE). Recorded because it is consistent with the *historical* pattern already inventoried from `nazgul/improvements.md`'s "Review rejection: TASK-N/reviewer" entries (IMP-008 through IMP-041 and IMP-052 through IMP-060 below) — a recurring ~1-in-2 to ~1-in-3 first-pass rejection rate across FEAT-009/FEAT-010 as well — and because TASK-011's roadmap synthesis may find it useful evidence that citation-precision spot-checks are a high-value, cheap reviewer habit worth preserving/reinforcing rather than trimming for speed.
**Recommendation:** informational only; no fix needed. Do not let a future "speed up the review board" roadmap item (e.g., relaxing citation spot-checks to cut latency) regress this catch rate — flag as a consideration for whichever roadmap wave addresses dimension 2's review-gate latency findings.
**Cross-links:** dimension 2 (review-gate process quality), TASK-011 (roadmap synthesis — informational input only).

---

## Structural critique (dimension 8 lens)

1. **The audit is auditing a moving target it cannot see.** RT-09 is the clearest structural point:
   this objective's own execution model (ad hoc Agent-Team `SendMessage` fan-out) does not feed the
   same observability surfaces (`plan.md` Status Summary, `events.jsonl`, `review-coverage.jsonl`)
   that the sequential/parallel engine feeds. A framework whose central selling point is "files are
   memory, context is working memory" and "recovery must be automatic" (CLAUDE.md's own stated
   principles) has, in this very run, a `plan.md` that would mislead a recovery attempt (it says 0
   tasks are done; 5 are not PLANNED) and a metrics stream with zero signal for an in-progress
   objective. This is not a new incident class — dimension 1's F-007/F-010 already found the
   Recovery Pointer and counting logic fragile — but RT-09 shows the SAME fragility surfacing
   through a different, currently under-specified execution path (Agent Teams) rather than only
   through the awk-parsing bug F-007 describes for the sequential loop. Two independent mechanisms
   (stale text-format parsing AND a whole execution mode not wired to the accounting hooks) point at
   the same symptom, which is a stronger structural signal than either alone.

2. **Reviewer-verdict persistence has no single owner.** RT-05 (at least four incompatible filename
   schemes in four consecutive gates of the SAME objective, one of which blocked a DONE transition
   mid-run and needed a manual patch) and RT-06 (a fourth recurrence of the
   background-stall/orchestrator-recovers pattern) both point at the same architectural gap dimension
   2's F4 already names: verdict persistence is currently an emergent property of whatever the
   orchestrator improvises per-dispatch, not a contract the reviewer subagent or the orchestrator is
   held to mechanically. Every other guard/gate in this codebase that started this way (command-string
   parsing guards, per `nazgul/improvements.md:48-52`'s own cross-cutting LESSON) eventually needed to
   move enforcement to "the layer that knows the truth." The same principle applies here: the
   reviewer itself, not the orchestrator's memory of a background task result, should be the layer
   that durably writes its own verdict under a name the DONE-gate can rely on.

3. **The self-improvement loop (self-audit → improvements.md) is high-signal but has no forcing
   function to close items.** All 74 inventoried items below are `Status: open`; the backlog spans
   FEAT-009 through FEAT-010 (2026-07-09 through 2026-07-11) with no entries between then and this
   FEAT-013 audit (2026-07-13 through 2026-07-22 — FEAT-011/FEAT-012 produced no new self-audit
   entries in this file, worth flagging to dimension 5/TASK-011: either those objectives generated no
   findings, or the self-audit gate didn't fire for them — the latter would itself be a finding, but
   this dimension's read scope did not include re-running self-audit.sh's own detection logic to
   distinguish the two). The backlog is a rich, well-evidenced list, but its existence as an
   ever-growing, append-only, ~zero-closure file is itself a structural smell worth the roadmap
   explicitly addressing (a "which of these 74 does wave 1/2/3 retire" mapping, which is exactly
   TASK-011's job and why the inventory below is built to feed it directly).

---

## Improvements.md — full open-item inventory (74 items, ALL `Status: open`)

For TASK-011's roadmap mapping. `Sev/Lev` = the file's own "Severity/Leverage" field verbatim.
Line numbers are the `##` header's line in `nazgul/improvements.md` as of this read.

| ID | Line | Feat | Date | Sev/Lev | One-line summary |
|----|------|------|------|---------|-------------------|
| IMP-001 | 6 | FEAT-009 | 2026-07-09 | high/high | Conductor charter findings origin story (model tier unpinned, team backend can't fan out, no merge-before-review guard, rework-guard blocks cross-cutting edits) |
| IMP-002 | 12 | FEAT-009 | 2026-07-09 | medium/medium | `APPROVED` status missing from `VALID_STATUSES` wedges the state guard — **see dimension 1 F-001 (still open in code)** |
| IMP-003 | 18 | FEAT-009 | 2026-07-09 | medium/medium | Embedded newlines in findings.jsonl fields could break backlog `##` structure (SEC F1) |
| IMP-004 | 24 | FEAT-009 | 2026-07-09 | high/high | HITL approval gate silently degrades to autonomous — **= Anchor 4 / RT-04, cross-link dimension 1 F-006** |
| IMP-005 | 30 | FEAT-009 | 2026-07-09 | high/medium | review-gate can mark a reviewer `resolved:true` without persisting its verdict file — **precursor to RT-05/RT-06** |
| IMP-006 | 36 | FEAT-010 | 2026-07-09 | high/high | Command-string parsing arms race for base-branch guard (TASK-004) and H2 pre-merge guard (TASK-011) — deferred to FEAT-010, later shipped as git-level hooks (dimension 4 scope) |
| IMP-007 | 48 | FEAT-009 meta | 2026-07-09 | high/high | LESSON: hand-rolled command-string tokenizers for security intent are a losing arms race; enforce at the layer that knows the truth — **directly informs RT-07's recommendation** |
| IMP-008 | 54 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-001/code-reviewer |
| IMP-009 | 60 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-001/qa-reviewer |
| IMP-010 | 66 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-001/security-reviewer |
| IMP-011 | 72 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-002/architect-reviewer |
| IMP-012 | 78 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-003/architect-reviewer |
| IMP-013 | 84 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-003/security-reviewer |
| IMP-014 | 90 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-004/architect-reviewer |
| IMP-015 | 96 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-004/qa-reviewer |
| IMP-016 | 102 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-004/security-reviewer |
| IMP-017 | 108 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-005/architect-reviewer |
| IMP-018 | 114 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-005/security-reviewer |
| IMP-019 | 120 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-006/architect-reviewer |
| IMP-020 | 126 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-006/code-reviewer |
| IMP-021 | 132 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-006/qa-reviewer |
| IMP-022 | 138 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-006/security-reviewer |
| IMP-023 | 144 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-007/architect-reviewer |
| IMP-024 | 150 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-007/qa-reviewer |
| IMP-025 | 156 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-007/security-reviewer |
| IMP-026 | 162 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-008/architect-reviewer |
| IMP-027 | 168 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-008/code-reviewer |
| IMP-028 | 174 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-008/qa-reviewer |
| IMP-029 | 180 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-008/security-reviewer |
| IMP-030 | 186 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-009/architect-reviewer |
| IMP-031 | 192 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-009/code-reviewer |
| IMP-032 | 198 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-009/qa-reviewer |
| IMP-033 | 204 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-010/architect-reviewer |
| IMP-034 | 210 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-010/code-reviewer |
| IMP-035 | 216 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-010/qa-reviewer |
| IMP-036 | 222 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-010/security-reviewer |
| IMP-037 | 228 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-011/architect-reviewer |
| IMP-038 | 234 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-011/code-reviewer |
| IMP-039 | 240 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-011/qa-reviewer |
| IMP-040 | 246 | FEAT-009 | 2026-07-10 | medium/medium | Review rejection: TASK-011/security-reviewer |
| IMP-041 | 252 | FEAT-009 | 2026-07-10 | medium/low | 1 loop-blocked event recorded (TASK-004: security rejection) |
| IMP-042 | 258 | FEAT-009 | 2026-07-10 | low/low | TODO/FIXME delta: 7 new markers since main across ~35 files |
| IMP-043 | 264 | FEAT-009 | 2026-07-10 | medium/medium | TASK-006 required 1 retry attempt |
| IMP-044 | 270 | FEAT-009 | 2026-07-10 | medium/medium | TASK-007 required 1 retry attempt |
| IMP-045 | 276 | FEAT-009 | 2026-07-10 | medium/medium | TASK-012 required 1 retry attempt |
| IMP-046 | 282 | FEAT-009 | 2026-07-10 | medium/reliability | Haiku code/qa reviewers stall without emitting a verdict block (recurring) — **= part of Anchor 1 / RT-01** |
| IMP-047 | 288 | FEAT-009 | 2026-07-10 | low/observability | emit-event-cli.sh reviewer_verdict jq `--argjson` errors; verdict telemetry not recorded — **= Anchor 2 / RT-02, now fixed** |
| IMP-048 | 294 | FEAT-009 | 2026-07-10 | low→medium/high (updated) | self-audit.sh transcript-cost path fails on project paths with spaces + `CLAUDE_CONFIG_DIR` ignored (2 causes) — **= Anchor 3 / RT-03, now fixed** |
| IMP-049 | 301 | FEAT-009 | 2026-07-10 | low/low | Pre-existing bare code fences violate repo's own MD040 style rule (5 files) |
| IMP-050 | 307 | FEAT-009 | 2026-07-10 | low/medium | test-model-routing flaked once in CI (non-deterministic, impossible-substring signature, harness suspected) |
| IMP-051 | 313 | FEAT-009 | 2026-07-10 | medium/medium | pre-tool-guard false-positive: blocks any command whose TEXT substring-matches an SQL destructive keyword (e.g. "truncated") |
| IMP-052 | 319 | FEAT-010 | 2026-07-10 | high/high | Group/feature review evidence is task-keyed → member tasks stuck IMPLEMENTED, objective never completes, post-loop gates (incl. self-audit) never fire — **directly relevant to RT-09's telemetry-dark finding** |
| IMP-053 | 325 | FEAT-010 | 2026-07-10 | low/medium | H2 pre-merge-commit guard: octopus-merge + field-edge-case test gaps (non-blocking qa finding) |
| IMP-054 | 331 | FEAT-010 | 2026-07-10 | medium/low | H2 guard's `startswith` SHA match couples to short-SHA (7-hex) allowance → prefix-collision hardening candidate |
| IMP-055 | 337 | FEAT-010 | 2026-07-10 | medium/high | Implementer bypassed the review gate by merging its own task branch before review (self-governance gap) |
| IMP-056 | 343 | FEAT-009 followup | 2026-07-10 | high/high | self-audit agent used a bare-relative `scripts/self-audit.sh` path → gate silently no-ops in non-dogfood installs — **= companion to Anchor 3 / RT-03, now fixed** |
| IMP-057 | 349 | FEAT-009 followup | 2026-07-10 | low/medium | Conductor mis-reported the self-audit gate as "script absent" while marker + findings existed (should read from authoritative artifacts, not infer) |
| IMP-058 | 355 | FEAT-010 | 2026-07-10 | high/high | Review-gate background parallel reviewers stall mid-exploration, verdicts never persist, orchestrator repeatedly truncates at finalize (observed ~6× this objective) — **= Anchor 1 / RT-01 / RT-06, still recurring as of today** |
| IMP-059 | 361 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-003/qa-reviewer |
| IMP-060 | 367 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-003/security-reviewer |
| IMP-061 | 373 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-006/architect-reviewer |
| IMP-062 | 379 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-006/code-reviewer |
| IMP-063 | 385 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-006/qa-reviewer |
| IMP-064 | 391 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-006/security-reviewer |
| IMP-065 | 397 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-007/security-reviewer |
| IMP-066 | 403 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-008/architect-reviewer |
| IMP-067 | 409 | FEAT-010 | 2026-07-10 | medium/medium | Review rejection: TASK-008/security-reviewer |
| IMP-068 | 415 | FEAT-010 | 2026-07-10 | medium/low | 1 loop-blocked event recorded (TASK-004: security rejection) |
| IMP-069 | 421 | FEAT-010 | 2026-07-10 | medium/medium | TASK-003 required 2 retry attempts |
| IMP-070 | 427 | FEAT-010 | 2026-07-10 | medium/medium | TASK-004 required 3 retry attempts |
| IMP-071 | 433 | FEAT-010 | 2026-07-10 | medium/n/a | Haiku code/qa reviewers stall without emitting a verdict block (recurring, 2nd occurrence record) — duplicate of IMP-046's pattern, same root cause as RT-01 |
| IMP-072 | 439 | FEAT-010 | 2026-07-10 | low/n/a | emit-event-cli.sh reviewer_verdict jq `--argjson` errors (2nd occurrence record) — duplicate of IMP-047, same fix now shipped (RT-02) |
| IMP-073 | 445 | FEAT-010 | 2026-07-11 | medium/high | Internal review board APPROVED git-hooks install/uninstall but missed a malformed-config/missing-jq clobber that an external PR reviewer (Copilot) caught — meta-lesson: keep an external second-opinion reviewer as a complement, not a replacement |
| IMP-074 | 451 | FEAT-010 | 2026-07-11 | low/low | Self-audit gate double-appended a finding to improvements.md once (dedup gap in the append path) — **IMP-058/IMP-071/IMP-046 and IMP-047/IMP-072 pairs above are themselves partial evidence this dedup gap is real and recurring, not a one-off** |

**Notes on the inventory:**
- All 74 items are `Status: open` — none have been closed, superseded-and-marked, or retired anywhere in the file.
- Items marked "now fixed" above (IMP-047/IMP-048/IMP-056/IMP-072, corresponding to Anchors 2 and 3)
  are open in the backlog's bookkeeping but CLEARED at the source-code level per RT-02/RT-03's
  evidence — TASK-011 should decide whether to mark them retired-by-fix in the consolidated queue
  rather than carrying them forward as still-actionable.
- IMP-046/IMP-058/IMP-071 (haiku/background reviewer stalls) and RT-01/RT-06 (this task's own fresh
  evidence) are the SAME underlying defect recorded five separate times across FEAT-009, FEAT-010 (×2
  self-audit runs), FEAT-012, and now FEAT-013 — the single highest-recurrence item in the entire
  corpus mined by this dimension. Recommend TASK-011 treat this as the top candidate for wave 1.
