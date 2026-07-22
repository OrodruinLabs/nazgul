# FEAT-013 Dimension 2 — Review Board Integrity: Findings

**Scope:** `agents/review-gate.md`, `agents/feedback-aggregator.md`, `scripts/lib/reviewer-selection.sh`,
`scripts/lib/review-provenance.sh`, `scripts/lib/review-evidence.sh`, `scripts/stop-hook.sh` (review-gate
sections), `scripts/task-state-guard.sh` (review-evidence sections), `scripts/subagent-stop.sh`,
`scripts/lib/emit-event.sh`, `scripts/emit-event-cli.sh`, `agents/templates/reviewer-base.md`,
`skills/review/SKILL.md`, `RULES.md` §3 review sections, `nazgul/improvements.md` (incident corpus).

**Coverage disclosure:** Read in full. Not read line-by-line: `agents/templates/reviewer-domains.json`
(scanned, not exhaustively diffed against every generated reviewer), the full text of
`references/fix-first-heuristic.md` (spot-checked), `.claude/agents/generated/*.md` (existence-checked
only, not content-reviewed — those are Discovery-rendered output of `reviewer-base.md`, not hand-authored
source). No plugin source file was modified — this artifact and my own task manifest are the only writes.
`tests/run-tests.sh` was not run for this dimension (static/read analysis was sufficient to reach direct
evidence for every claim below; nothing here depends on runtime behavior tests would exercise differently).

---

## Anchor Resolution Summary

| # | Anchor | Resolution |
|---|--------|-----------|
| 1 | `resolved:true` without persisted verdict file | **CLEARED** as a live evidence-bypass (DONE-gate never reads the manifest's `resolved` field) — but a real low-severity naming/docs finding remains (F1) |
| 2 | GROUP-N review-evidence keying gap | **ROOT-CAUSED, CONFIRMED, CRITICAL** — worse than described: both the preventive guard and the reactive net are affected (F2) |
| 3 | Group-vs-task granularity drift / is `enforce_granularity` airtight? | **ROOT-CAUSED, NOT airtight** — F3 (two related sub-issues: inference-based labeling and the task_id filter drop), compounded by a fragile telemetry path (F3c) |
| 4 | Reviewer stalls (haiku exhausting turn budget / no parseable verdict) | **ROOT-CAUSED, CONFIRMED, CRITICAL, currently unfixed** — traced to a missing `run_in_background: false` directive (F4) |

---

## Findings Register

### F1 — `resolved` field in `.dispatch.json` is misleadingly named; already caused one false security-integrity escalation

- **Severity**: low
- **Class**: docs-drift / fragility
- **Evidence**: `scripts/lib/review-provenance.sh:9` (schema comment: `reviewers: [{name, resolved}], # full roster considered for dispatch`) and `scripts/lib/review-provenance.sh:113-118` — `resolved` is computed ONCE, at Step 1.6 manifest-write time, purely from whether `.claude/agents/generated/<name>.md` exists on disk (`[ -f "$project_root/.claude/agents/generated/${name}.md" ] && resolved="true"`). It has never meant "this reviewer's verdict was recorded" — confirmed by `git log -p` on this file back to its introduction in FEAT-006 (`b5f37ba`, 2026-07-07). The DONE-gate (`validate_review_evidence`, `scripts/lib/review-evidence.sh:186-241`) never reads `.dispatch.json`'s `resolved` field at all — it only requires a physical `nazgul/reviews/<unit>/<reviewer>.md` with an `APPROVE` verdict (or an independently-recomputed authorized-SKIPPED/UNVERIFIED exemption). So the anchor's originally-feared failure mode ("DONE-gate trusts `resolved` instead of the file") does not exist in the current code path — it is cleared as a live bypass, and the FEAT-009 backlog entry (`nazgul/improvements.md:30-33`) itself says the integrity floor "likely holds"; I can now confirm it holds by direct code reading, not just likelihood.
- **Failure scenario**: The field name reads exactly like "this reviewer's review is done/resolved." A reviewer subagent (which has unrestricted `Read`/`Glob`/`Grep` per `agents/templates/reviewer-base.md:1-10` and can therefore stumble onto `.dispatch.json` even though review-gate never hands it that file) already misread `resolved: true` + a missing verdict file as evidence of a security-review bypass once (`nazgul/improvements.md:30-33`, FEAT-009, 2026-07-09 — AFTER the current schema was already in place), costing a wasted escalation and investigation cycle. Nothing prevents the same false alarm recurring for any future reviewer or human operator who inspects the manifest without reading `review-provenance.sh`'s source comment.
- **Recommendation**: Rename `resolved` to something unambiguous (e.g. `agent_definition_present`), or at minimum add an inline comment at the point of use disambiguating it from verdict completion, and note in `agents/review-gate.md`/`RULES.md` that `.dispatch.json` is dispatch bookkeeping, never authoritative for completion — only per-reviewer `.md` files are.

---

### F2 — Group/feature review granularity cannot reach DONE: both the DONE-gate and the reactive safety net key review evidence by TASK-ID only

- **Severity**: critical
- **Class**: bug
- **Evidence**:
  - `scripts/lib/review-evidence.sh:186-188` — `validate_review_evidence(nazgul_dir, task_id)` unconditionally builds `review_dir="$nazgul_dir/reviews/$task_id"`; no granularity parameter, no unit resolution.
  - `scripts/task-state-guard.sh:429-431` — the **preventive** PreToolUse guard that fires on every Edit to a task manifest attempting `status: DONE` (or `APPROVED` in YOLO) calls `validate_review_evidence "$NAZGUL_DIR" "$TASK_ID"` directly — no read of `review_gate.granularity` anywhere in this file's evidence-check block (confirmed by `grep -n "granularity" scripts/task-state-guard.sh` — zero hits outside an unrelated GROUP-* block at lines 95-133 that guards `.dispatch.json`/`diff.patch` writes during IN_PROGRESS, not the DONE-status evidence check).
  - `scripts/stop-hook.sh:210-296` — the **reactive** safety net loops every task, and for any `STATUS = DONE` calls `validate_review_evidence "$NAZGUL_DIR" "$TASK_ID"` at line 211, again with no granularity awareness, even though `GRANULARITY` is already read into scope at line 50 and IS used later in the file (the separate aggregate-review-gating block at lines 358-456) — the two blocks are not wired together.
  - `agents/review-gate.md:42` (granularity section) — explicitly documents that in group/feature mode, "reviewers write one file each" to `nazgul/reviews/[UNIT-ID]/` where `UNIT-ID` is `GROUP-<n>` (group) or `FEATURE-<feat_id>` (feature) — **never** `TASK-<n>`.
  - No bridging/resolver exists: `grep -rn "reviews/\$TASK_ID\|reviews/\${TASK_ID}\|reviews/\$UNIT_ID" scripts/ agents/` finds only the two call sites above, and `grep -rn "cp.*reviews\|symlink.*reviews"` finds nothing that copies or links group evidence into a per-task location.
- **Failure scenario**: A project sets `review_gate.granularity: "group"`. A 2-task wave (TASK-003, TASK-004) both reach IMPLEMENTED; review-gate correctly runs one aggregate review over the combined diff, writes `nazgul/reviews/GROUP-1/{security-reviewer,code-reviewer,...}.md` all `APPROVE`, and per its own Step 4 instructions attempts to Edit `nazgul/tasks/TASK-003.md` to `status: DONE`. `task-state-guard.sh`'s PreToolUse hook computes `REVIEW_DIR="nazgul/reviews/TASK-003"` — which does not exist — returns `NO_REVIEW_DIR`, and hard-blocks the edit with exit 2 ("Cannot mark TASK-003 as DONE... No review directory at: nazgul/reviews/TASK-003"). The task can never legally reach DONE via the documented group-review path. Even in a scenario where the guard is somehow bypassed (e.g. a differently-timed write, or a future change that lets the edit through), the stop-hook's reactive net independently re-derives the same `NO_REVIEW_DIR` on the very next Stop event and resets a genuinely-approved DONE task back to IMPLEMENTED (1st violation) or escalates it to BLOCKED (2nd consecutive violation) — corrupting state that a full, passing review board legitimately produced. Net effect: `review_gate.granularity: "group"` and `"feature"` are non-functional for completing any task — the loop can advance work to IMPLEMENTED and even run a passing aggregate review, but never legally finish it.
- **Recommendation**: Both `validate_review_evidence` call sites must resolve the task's actual review **unit ID** before checking evidence: in `task` mode that's the task's own ID (current behavior, unchanged); in `group` mode it's `GROUP-<n>` from the task manifest's `Group`/`Wave` field (`get_task_field ... "Group" ... "Wave"`, the exact helper `stop-hook.sh:385,401` already uses for its separate aggregate-review-gating block); in `feature` mode it's `FEATURE-<feat_id>`. The resolution logic to do this already exists and is proven correct in `scripts/stop-hook.sh:358-456` (the `AGGREGATE_REVIEW_*` computation) — it simply needs to be factored out (e.g. into `scripts/lib/task-utils.sh` or `review-evidence.sh` itself) and called from both the DONE-gate evidence check and the PreToolUse guard instead of assuming `task_id == unit_id`.

---

### F3 — `enforce_granularity` drift detection has an independent gap: coverage recording infers granularity rather than verifying it, and can silently record zero coverage for group/feature reviews

- **Severity**: high
- **Class**: bug / fragility
- **Evidence**:
  - `scripts/subagent-stop.sh:39-120` (`_record_review_coverage`) derives `granularity_used` NOT from which review directory actually received the verdict files, but from (a) how many distinct `task_id`s appear in `reviewer_verdict` events for the current iteration (`task_count`, lines 60-75), and (b) the **currently configured** `review_gate.granularity` value read fresh from `config.json` (line 50). Concretely: `task_count -eq 1` forces `granularity_used="task"` unconditionally (line 87-89); otherwise it trusts the config's current setting (lines 90-101) — it never opens `nazgul/reviews/<unit>/` to check which directory the verdicts actually landed in.
  - `agents/review-gate.md:246-281` (the `reviewer_verdict` emission block) is written for the single-task case only — `task_id "$TASK_ID"` — and never specifies what value to emit for a multi-task GROUP/FEATURE unit, despite `[UNIT-ID]` being the ambient variable used everywhere else in the same document for group/feature scope.
  - `scripts/subagent-stop.sh:79-84` filters strictly: `case "$task_id" in TASK-[0-9]*) ;; *) continue ;; esac` — any `reviewer_verdict` event whose `task_id` is not a literal `TASK-<digits>` string (e.g. `GROUP-1`, a very natural reading of the undefined instruction above) is silently dropped from consideration.
  - `scripts/subagent-stop.sh:72` (`[ -n "$task_ids" ] || return 0`) — if every event for the iteration was filtered out, the function returns with **zero** lines appended to `nazgul/logs/review-coverage.jsonl` for that review pass.
  - `scripts/stop-hook.sh:865-873` — the post-loop granularity gate only evaluates records present in `review-coverage.jsonl`; an absent record for a given review pass produces no violation line, not a "coverage missing" warning — it degrades to allow silently.
- **Failure scenario**: If review-gate emits `reviewer_verdict` events using the unit ID (`GROUP-1`) for a genuine group review — the most natural reading of the underspecified instruction — the coverage detector drops every one of those events, records nothing, and the post-loop `enforce_granularity` gate (whose entire job is to catch exactly this class of drift) has no data to act on for that review and silently passes. Separately, even when `task_id` values ARE real `TASK-NNN` ids, the detector's `granularity_used` label is inferred from population count + current config rather than verified against the actual review directory used — a coincidental match (e.g. two per-task reviews for two different tasks landing in the same iteration's event tail) could be mislabeled as a genuine "group" review, masking real drift. This is a second, independent gap from F2, in the same subsystem — though its real-world exposure today is likely near zero, since F2 already prevents any task from completing a group/feature review cycle in the first place, so the post-loop gate rarely if ever gets exercised for those modes in practice.
- **Recommendation**: (1) `agents/review-gate.md` should explicitly define what `task_id` to emit for `reviewer_verdict` in group/feature mode — most consistent fix: emit ONE event per (reviewer × covered task) pair with the real `TASK-NNN` id and an additional `review_unit` field carrying the actual `UNIT-ID`, so the coverage detector can verify ground truth instead of inferring it. (2) `_record_review_coverage` should read `review_unit` directly from the event instead of inferring `granularity_used` from population count. (3) Add a "coverage record missing for a review that just ran" warning distinct from "coverage violated," so the gate's silent-degrade-to-allow path is at least visible in logs. This finding should be resolved together with F2 (they share the group/feature evidence-location root cause) and F3c below (the telemetry that feeds it).

---

### F3c — `emit-event-cli.sh reviewer_verdict` can silently drop events on any malformed numeric field, further starving the coverage detector

- **Severity**: medium
- **Class**: fragility
- **Evidence**: `scripts/lib/emit-event.sh:48-56` builds `jq_args` for every `key:n` pair via `--argjson "$key" "$val"` with **no validation** that `$val` is well-formed JSON (a bare integer). `jq -cn` with an invalid `--argjson` value exits non-zero; both dispatch paths swallow that failure unconditionally (`scripts/lib/emit-event.sh:75`: `... || true` and line 77: `... || true`), so the entire event — not just the malformed field — is dropped with no error surfaced to the caller. `agents/review-gate.md`'s emission instructions (lines 265-281) tell the orchestrator to "extract" `CONFIDENCE`/`BLOCKING`/`CONCERNS` as integers from freeform reviewer narrative text but include no validation/sanitization step before passing them to `emit-event-cli.sh`. `nazgul/improvements.md:288-292` and `:439-443` (FEAT-009 and FEAT-010, both **status: open**) document this exact failure occurring twice in production ("emit-event-cli.sh reviewer_verdict threw jq --argjson errors... did NOT record the four reviewer_verdict events").
- **Failure scenario**: If the review-gate orchestrator extracts a non-numeric or empty value for `confidence`/`blocking_findings`/`concerns` (e.g. a reviewer's frontmatter was slightly malformed, or the orchestrator mis-parses it), the corresponding `reviewer_verdict` event is silently never written to `events.jsonl`. This degrades `/nazgul:metrics` accuracy (the originally-diagnosed impact) AND starves `scripts/subagent-stop.sh`'s coverage detector (F3), since it reads exactly this event stream — a dropped event for a group/feature review compounds F3's silent-degrade-to-allow behavior.
- **Recommendation**: In `emit-event.sh`, coerce/validate every `:n`-suffixed value before adding it to `jq_args` (e.g. `case "$val" in ''|*[!0-9-]*) val=null_or_skip ;; esac`), and on a genuinely malformed value either substitute `null` (never silently drop the whole event) or emit a one-line stderr warning distinguishable from a normal non-fatal degrade. Add a test feeding an empty/non-numeric `:n` value through `emit-event-cli.sh reviewer_verdict` and asserting a line IS still written (this exact regression is what the two open improvements.md entries ask for and it has not been done).

---

### F4 — Review-gate never pins reviewer subagents to synchronous dispatch; the Agent tool's background default is the most likely root cause of the recurring "reviewer stalls without a parseable verdict" incident class

- **Severity**: critical
- **Class**: bug
- **Evidence**:
  - `nazgul/improvements.md:355-359` (FEAT-010, **status: open**) diagnoses, with first-party evidence across ~6 recurrences: "With `parallelism.parallel_reviews: true`, reviewers dispatched as BACKGROUND agents frequently 'crawled the codebase and were cut off' — 3 of 4 for TASK-007 stopped mid-exploration without ever emitting a verdict block; the background completion notification surfaces only a truncated final snippet, not the full review text the orchestrator needs to persist verdict files." Its own suggested fix #2: "prefer SYNCHRONOUS reviewer dispatch (`run_in_background: false`)."
  - I confirmed this fix was never applied: `grep -n "run_in_background\|background" agents/review-gate.md agents/templates/reviewer-base.md` returns **zero matches**. Neither the Parallel Review Mode instructions (`agents/review-gate.md:142-163`) nor the Sequential Fallback, nor Step 0's simplifier dispatch, nor Step 3.6's adversarial cross-check dispatch, nor Step 3.75's implementer delegate, nor Step 5.0's post-loop simplify dispatch, ever specify a dispatch mode.
  - Per the Agent tool's own contract (its parameter description in the current environment): "Agents run in the background by default; you will be notified when one completes. Set to false to run this agent synchronously when you need its result before continuing." Without an explicit `run_in_background: false`, every reviewer subagent review-gate spawns defaults to background execution.
  - This directly contradicts review-gate.md's own assumed semantics at line 148: "The single message returns once ALL SELECTED reviewers have completed; you now hold each reviewer's returned review text in the tool results" — true only under synchronous dispatch. Under the actual default, the dispatching message returns immediately with a background-task handle, and the reviewer's real completion (and full returned text) arrives later as an asynchronous notification — exactly the truncation symptom the backlog entry describes.
- **Failure scenario**: Every review cycle that uses Parallel Review Mode (the documented, recommended path) risks one or more SELECTED reviewers stalling mid-exploration with no captured verdict, forcing the Step 2.5 MISSING/MALFORMED retry-once path, then (if still unresolved) an UNVERIFIED stub, then — for a critical reviewer (security/architect, the default `critical_reviewers`) — a fail-closed BLOCKED task requiring human intervention. The downstream UNVERIFIED→fail-closed path does correctly contain the *safety* blast radius (a stalled critical reviewer never silently passes), so review integrity itself is not compromised — but the *reliability/cost* blast radius is large and repeated: every stall burns a wasted subagent turn budget, at least one retry dispatch, and for critical reviewers a full human-escalation cycle. `nazgul/improvements.md` independently theorizes a haiku-model-capability cause (`:282-286`, also open) and evidence of real mitigation attempts exists (reviewer `maxTurns: 12` cap in `agents/templates/reviewer-base.md:14`; security/architect pinned to `sonnet` in `agents/review-gate.md:128`) — but neither mitigation addresses a dispatch-mode default, and the background-dispatch root cause was explicitly diagnosed and never fixed.
- **Recommendation**: Add an explicit `run_in_background: false` requirement to every Agent-tool dispatch instruction in `agents/review-gate.md` (Step 0, Step 2 parallel AND sequential, Step 3.6, Step 3.75, Step 5.0), and state the reason inline (reviewer verdicts must be captured as direct tool-call return values, not asynchronous notifications) so a future edit doesn't silently drop it again. Consider a lightweight regression check (a test or lint) asserting the phrase appears once per Agent-dispatch instruction block in the agent spec text.

---

## Structural Critique

### S1 — Confidence/severity classification policy is duplicated across two agent specs, risking silent drift

- **Severity**: medium
- **Class**: architecture
- **Evidence**: `agents/review-gate.md:378-379` ("Apply confidence threshold: findings with confidence < 80 → non-blocking CONCERN... Findings with confidence >= 80 AND severity HIGH/MEDIUM → blocking REJECT") and `agents/feedback-aggregator.md:60-73` (a full markdown table encoding the identical policy) independently restate the same classification rule in prose, as does the "security is always blocking" carve-out (`review-gate.md:427` vs `feedback-aggregator.md:73`). Two independently-maintained prose copies of one policy is a drift risk: a future change to `confidence_threshold` semantics, the severity tiers, or the security carve-out edited in one file with no matching edit in the other would silently split what the two agents believe "blocking" means, with no mechanical check to catch the divergence (both are prose read by an LLM, not code).
- **Failure scenario**: An operator or future contributor tightens the confidence-threshold rule in `review-gate.md` (e.g. adds a new MEDIUM-severity carve-out) without updating the matching table in `feedback-aggregator.md`. feedback-aggregator then classifies a finding as non-blocking that review-gate's own Step 3 would have called blocking, or vice versa — a review-integrity inconsistency that would be hard to detect because both agents "look" correct in isolation.
- **Recommendation**: Extract the classification table into one canonical reference doc (the codebase already has the pattern — `references/fix-first-heuristic.md` is shared this way) and have both `review-gate.md` and `feedback-aggregator.md` cite it by pointer instead of re-stating it.

### S2 — `review_gate.require_all_approve` is a documented-but-dead config key

- **Severity**: low
- **Class**: docs-drift
- **Evidence**: `RULES.md` §11 states outright: "`review_gate.require_all_approve` is **informational only — no script reads it**; the effective policy is the hard-coded 'every non-skipped reviewer must APPROVE' loop inside `validate_review_evidence` itself." Confirmed: `grep -rn "require_all_approve" scripts/` finds no reads in any script — only its own name appearing in `RULES.md`'s admission and presumably the config schema/template.
- **Failure scenario**: An operator reads the config schema, sees `review_gate.require_all_approve`, sets it to `false` expecting to relax the "every reviewer must approve" requirement, and gets no behavior change at all — a silent no-op config key is worse than a missing one because it actively misleads.
- **Recommendation**: Either wire it (gate `validate_review_evidence`'s all-must-approve loop behind it, defaulting `true` for backward compatibility) or remove it from the config schema/template entirely and document the removal in the schema changelog. Given `RULES.md` already flags this explicitly, this is a low-effort cleanup candidate for the roadmap.

### S3 — `review-gate.md`'s pipeline has grown to 12 top-level steps (~620 lines); some are pure housekeeping siblings that could merge

- **Severity**: low
- **Class**: architecture
- **Evidence**: Steps 0, 1, 1.5, 1.6, 2, 2.5 (plus its embedded "Token self-check" and "Emit reviewer_verdict events" sub-blocks), 2.6, 3, 3.5, 3.6, 3.75, 4, 5 (with 5.-1/5.0/5.1 sub-steps) — an orchestrating LLM must correctly execute this entire sequence, in order, every single review cycle, with several steps (2.5's evidence check, its token self-check, and its citation/bump-hits pass) being purely sequential post-persistence bookkeeping with no branching interaction with the steps around them.
- **Failure scenario**: Not a bug — a maintainability/cognitive-load observation. A long, deeply-numbered prose pipeline is more likely to have a future edit inserted in the wrong place (as already happened once: Step 3.6 is explicitly noted in its own text as living out of numeric order — "this sub-step runs immediately AFTER Step 3... and BEFORE Step 3.75... numbered 3.6 only because 'Step 3.5' is already taken") — a symptom that the step-numbering scheme itself is already strained.
- **Recommendation**: Consolidation candidate, not urgent: merge Step 2.5's three sub-blocks (evidence check, token self-check, citation bump) into one "Step 2.5: Post-Persistence Verification" pass, and consider renumbering the pipeline sequentially (1-13) instead of decimal-inserting, to remove the self-acknowledged numbering strain around Step 3.6.

### S4 — `reviewer-selection.sh`'s architecture-surface classifier is narrower than the plugin's actual architecture surface (latent, since `conditional_dispatch` defaults `false`)

- **Severity**: low
- **Class**: fragility
- **Evidence**: `scripts/lib/reviewer-selection.sh:43-52` (`_nrs_is_architecture_surface`) selects `architect-reviewer` only for files under `skills/*`, `agents/*`, `scripts/*`, `hooks/*`, or a config-schema file. It does not cover `templates/*`, `references/*`, `.github/workflows/*`, or `RULES.md`/`CLAUDE.md` — all of which the TRD (`nazgul/docs/TRD.md:43-44`) explicitly lists as in-scope architecture surface for this very audit ("Also in overall scope... `templates/`, `references/`, `.github/workflows/`, `RULES.md`, CLAUDE.md/README docs surface").
- **Failure scenario**: Only reachable when `review_gate.conditional_dispatch: true` (default `false`, per `agents/review-gate.md:110` — this selector is a no-op in the default configuration). If a project opts in, a change confined to `RULES.md` or a `skill-partials` template — both structurally load-bearing — would not trigger `architect-reviewer`, unlike an equivalent change under `skills/` or `agents/`.
- **Recommendation**: Low urgency given the opt-in default. If `conditional_dispatch` is promoted to default-on in a future release, extend `_nrs_is_architecture_surface` to include `templates/*`, `references/*`, `RULES.md`, `.github/workflows/*` before that promotion.

---

## Honesty / Coverage Notes

- All four known anchors were root-caused with direct `file:line` evidence — none required "explicit clearing" without evidence; anchor 1 is cleared for its originally-feared severity but repurposed into a real (lower-severity) finding (F1) rather than dropped outright.
- No re-dispatch was needed for this dimension — coverage completed in one pass.
- Verification status (CONFIRMED/PLAUSIBLE) is intentionally NOT assigned in this artifact per task instructions — that is TASK-010's job (Phase 3 adversarial verification). Every finding above is presented with the underlying evidence a skeptic would need to attempt refutation.
- Findings F2, F3, F3c are causally linked (same group/feature review-evidence-location root cause, cascading into the telemetry that would otherwise have caught it) — recommend the roadmap treat them as one dependency-ordered fix, with F2 first (it blocks group/feature mode from being exercised at all, which is also why F3's real-world exposure is currently low).
