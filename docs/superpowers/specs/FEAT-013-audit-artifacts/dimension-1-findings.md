# FEAT-013 Dimension 1 Findings — Loop Engine & State Machine

**Task:** TASK-001 · **Scope:** `scripts/stop-hook.sh`, `scripts/pre-compact.sh`,
`scripts/post-compact.sh`, `scripts/session-context.sh`, `scripts/session-staging.sh`,
`scripts/lib/task-utils.sh`, `scripts/lib/structured-state.sh`, checkpoint JSON format,
recovery-pointer contract (`nazgul/plan.md` + `templates/task-manifest.md`), plus secondary reads
of `scripts/lib/review-evidence.sh`, `scripts/apply-start-flags.sh`, `scripts/lib/parallel-batch.sh`,
`RULES.md` §1/§2/§4, `templates/plan.md`, `skills/pause/SKILL.md`, `hooks/hooks.json`.

**Coverage disclosure:** Read-only static analysis + targeted empirical shell reproduction (ran
the actual `get_task_status`/awk logic against synthetic and live files to confirm behavior, not
just inspection). `scripts/task-state-guard.sh` (PreToolUse transition enforcement) was read only
opportunistically for cross-reference where it interacts with this dimension's findings — its full
audit is dimension 3's responsibility, not duplicated here. Finding F-011 (compaction-counter
double-increment) could NOT be verified against Claude Code's actual hook-firing semantics
(whether `PostCompact` and `SessionStart[matcher=compact]` ever fire for the same physical
compaction event) — flagged explicitly as needing adversarial/runtime verification, not claimed as
confirmed. No `tests/run-tests.sh` run was performed for this dimension (not required; static +
targeted repro was sufficient to confirm every anchor with direct evidence).

Verification status (CONFIRMED/PLAUSIBLE) is intentionally NOT assigned below — that is TASK-010's
job. Every finding here has been empirically reproduced or has direct, quoted file:line evidence.

---

## Known Anchors — Root Cause Summary

| # | Anchor | Verdict |
|---|--------|---------|
| 1 | `APPROVED` status wedges the state guard | **ROOT-CAUSED** — see F-001, F-002, F-003, F-004 |
| 2 | HITL gate silently degrades to autonomous | **ROOT-CAUSED** — see F-006 |
| 3 | Evidence-gate integrity | **CLEARED** (gate itself sound) with one noted interaction — see F-012 |
| 4 | Resume-after-compaction sufficiency | **ROOT-CAUSED** — see F-007, F-008, F-009 |

---

## Findings Register

### F-001 — `APPROVED` is missing from `VALID_STATUSES`; canonical frontmatter status reads as `INVALID`

- **Severity:** critical
- **Class:** bug
- **Evidence:** `scripts/lib/structured-state.sh:12` —
  `VALID_STATUSES="PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED"`
  (no `APPROVED`). `scripts/lib/structured-state.sh:66-75` (`read_task_status`) returns the
  string `"INVALID"` (rc=2) for any frontmatter `status:` value not in that list.
  `scripts/lib/task-utils.sh:16-23` (`get_task_status`) propagates that verbatim: `if
  [ "$fm_rc" -eq 2 ]; then echo "INVALID"; return; fi`.
  **Empirically reproduced:** a task manifest with canonical frontmatter `status: APPROVED`
  returns `get_task_status` = `INVALID`, not `APPROVED` (verified by sourcing
  `scripts/lib/task-utils.sh` directly against a synthetic file).
  Cross-reference: `APPROVED` is a real, intentional state — `RULES.md:34` documents the
  Task-PR flow `... IN_REVIEW -> APPROVED -> DONE`, and `agents/review-gate.md:513`
  ("Set task status to APPROVED (not DONE)") is the write path that produces it.
- **Failure scenario:** In YOLO + `afk.task_pr` mode, when review-gate sets a task's canonical
  frontmatter status to `APPROVED` (per `agents/review-gate.md:513`), every downstream reader
  that calls `get_task_status`/`read_task_status` on that manifest sees `INVALID`, never
  `APPROVED`. This is the direct root cause of F-002, F-003, F-004 below.
- **Recommendation:** Add `APPROVED` to `VALID_STATUSES` in `scripts/lib/structured-state.sh:12`.
  One-line fix; audit for any code that currently treats `INVALID` as a proxy signal for "some
  YOLO task-pr state" before landing it (none found in this dimension's scope, but dimension 3
  owns `task-state-guard.sh`'s independent regex-based status list at
  `scripts/task-state-guard.sh:277,284`, which DOES already include `APPROVED` — the two lists
  have drifted apart and should be reconciled to a single source of truth).

### F-002 — `INVALID` status is an invisible black hole in the loop's task-counting/dispatch logic

- **Severity:** critical
- **Class:** bug
- **Evidence:** `scripts/stop-hook.sh:158-186` — the status-counting `case` statement enumerates
  `DONE|READY|IN_PROGRESS|IMPLEMENTED|IN_REVIEW|APPROVED|CHANGES_REQUESTED|BLOCKED|PLANNED`; there
  is no `INVALID)` arm, so a task whose `get_task_status` returns `INVALID` (F-001, or any future
  malformed/off-enum status value) increments `TOTAL_COUNT` (line 172, unconditional) but is not
  added to ANY of the 8 status buckets. Same gap in the active-task scan (`stop-hook.sh:322-331`,
  checks only `IN_PROGRESS|CHANGES_REQUESTED|IN_REVIEW|IMPLEMENTED`), the READY scan
  (`stop-hook.sh:346-356`), and the identical duplicated loops in `scripts/pre-compact.sh:54-71`,
  `scripts/post-compact.sh:38-59`, `scripts/session-context.sh:59-80`. Confirmed by grep: no
  script in this dimension's scope contains the string `INVALID` at all (`grep -n "INVALID"
  scripts/stop-hook.sh scripts/session-context.sh scripts/pre-compact.sh scripts/post-compact.sh
  scripts/task-state-guard.sh` returns zero matches).
- **Failure scenario:** A task stuck at `INVALID` status permanently inflates `TOTAL_COUNT` above
  the sum of every tracked bucket, so `DONE_COUNT == TOTAL_COUNT` (non-YOLO) or
  `APPROVED_COUNT + DONE_COUNT == TOTAL_COUNT` (YOLO, `stop-hook.sh:800-801`) can never be true —
  the loop cannot detect completion and runs to `max_iterations` or the consecutive-failure
  backstop instead, with no diagnostic anywhere identifying which task or why. It is also never
  selected as the active task, never auto-promoted, never gated by the Layer-2 review-evidence
  safety net (which only fires on `STATUS == "DONE"`, `stop-hook.sh:210` — see F-012).
- **Recommendation:** Add an explicit `INVALID` (and default/unknown) arm to every one of the four
  duplicated counting loops that emits a loud diagnostic (e.g. `emit_event "invalid_status"
  task_id ...` plus a line in `CONTINUE_MSG`) rather than silently dropping the task from every
  bucket. This is also the strongest argument for the consolidation in F-010 — a single shared
  counting function would only need this fix once.

### F-003 — YOLO-mode dependency promotion permanently wedges on an `APPROVED` dependency

- **Severity:** high
- **Class:** bug
- **Evidence:** `scripts/stop-hook.sh:734-748` (auto-promote `PLANNED -> READY`): in YOLO mode,
  `if [ "$DEP_STATUS" != "DONE" ] && [ "$DEP_STATUS" != "APPROVED" ]; then ALL_DONE=false`. Because
  `get_task_status` never returns the literal string `APPROVED` for a canonical manifest (F-001),
  `DEP_STATUS` is `INVALID`, the check `!= "APPROVED"` is true, and `ALL_DONE` is forced `false`
  every iteration.
- **Failure scenario:** In YOLO mode, any `PLANNED` task that depends on a task now sitting at
  frontmatter `status: APPROVED` never promotes to `READY` — it is stuck in `PLANNED` for the rest
  of the run, indistinguishable from a task still waiting on real work.
- **Recommendation:** Fixed by F-001's one-line change (once `get_task_status` correctly returns
  `APPROVED`, this comparison starts working as designed). No independent code change needed here.

### F-004 — YOLO-mode loop completion is unreachable while any task holds `APPROVED`

- **Severity:** high
- **Class:** bug
- **Evidence:** `scripts/stop-hook.sh:180` (`APPROVED) APPROVED_COUNT=$((APPROVED_COUNT + 1))`)
  never matches because `STATUS` is `INVALID` (F-001), so `APPROVED_COUNT` stays 0 for every
  canonical-format task that has genuinely reached `APPROVED`. `stop-hook.sh:800-801` gates YOLO
  completion on `$((APPROVED_COUNT + DONE_COUNT)) -eq $TOTAL_COUNT`. Same undercount feeds
  `PROGRESS_COUNT` at `stop-hook.sh:299-305`, which drives consecutive-failure detection — a task
  that just legitimately reached `APPROVED` (real progress) is not counted as progress, so
  `CONSEC_FAILURES` keeps incrementing instead of resetting.
- **Failure scenario:** A YOLO + task-pr run where every task reaches `APPROVED` (fully
  self-approved, awaiting external PR merge) never satisfies the completion condition and never
  registers the state transition as progress — it degrades into either running out
  `max_iterations` or false-tripping the consecutive-failure stop (`safety.max_consecutive_failures`,
  default 5), both of which look to an operator like the loop is broken/stuck rather than "done
  except for PR merge."
- **Recommendation:** Same root fix as F-001; verify with a regression test that seeds a task
  manifest at canonical `status: APPROVED` and asserts `APPROVED_COUNT` increments and YOLO
  completion fires correctly (this dimension found no such test in the read scope — a test-gap
  worth flagging to dimension 7).

### F-005 — `templates/task-manifest.md`'s own state-machine comment omits `APPROVED` (docs drift, same shape as F-001)

- **Severity:** low
- **Class:** docs-drift
- **Evidence:** `templates/task-manifest.md:13` — `<!-- Valid states: PLANNED | READY |
  IN_PROGRESS | IMPLEMENTED | IN_REVIEW | CHANGES_REQUESTED | DONE | BLOCKED` — omits `APPROVED`,
  unlike `RULES.md:4-6,15-27` (§2 State Machine), which documents the Task-PR flow and the
  `IN_REVIEW -> APPROVED -> DONE` transition correctly and completely.
- **Failure scenario:** An agent (planner, implementer) consulting the task-manifest template's
  inline comment for "what states exist" — rather than the more authoritative but separately
  located `RULES.md` — gets an incomplete picture; low direct impact since the actual write path
  (`agents/review-gate.md:513`) hard-codes `APPROVED` regardless of this comment, but it is the
  same category of omission as the code bug in F-001 and likely shares an origin (APPROVED/Task-PR
  mode added without a full sweep of every place the 8-state enum is duplicated).
- **Recommendation:** Add `APPROVED` to the comment at `templates/task-manifest.md:13`, matching
  `RULES.md`'s Task-PR row.

### F-006 — HITL mode has no mechanical stop-hook enforcement outside the opt-in parallel-batch path

- **Severity:** high
- **Class:** architecture
- **Evidence:** `scripts/stop-hook.sh:1125-1142` builds `DISPATCH_INSTR` for the default
  sequential/task-granularity path unconditionally on task status (`READY`/`IN_PROGRESS` ->
  "DELEGATE: Spawn implementer agent" at line 1138) — `$MODE` is read (`stop-hook.sh:42`) and
  threaded only into display strings (`--arg mode`, `stop-hook.sh:531,1189`), never into a
  conditional gate on this path. The ONLY place `$MODE` participates in an actual pass/fail
  decision is `execution_should_pause "$CONFIG" approve_batch "$MODE"` at `stop-hook.sh:1171`,
  which is reached only when `EXEC_PARALLEL=true` (opt-in, default `false` per
  `scripts/lib/parallel-batch.sh:105-110`, `execution_parallel_enabled`) AND
  `GRANULARITY == "task"` AND a fresh batch fires (`stop-hook.sh:1152-1153`).
  `scripts/lib/parallel-batch.sh:129-136` (`execution_gate_effective`) is where `mode == "hitl"`
  actually forces a gate (`approve_plan`) — but this mechanism exists only for the parallel
  execution feature, not the default sequential loop every non-`--parallel` run uses.
  This matches `nazgul/improvements.md`'s FEAT-009 2026-07-09 entry verbatim: the original
  incident was on the default sequential path (single-task "Wave-1 start-approval gate"), where a
  plain-text approval question plus two Stop-hook nudges caused the agent to interpret silence as
  "away" and proceed — precisely because nothing at the stop-hook layer blocks a
  READY/IN_PROGRESS dispatch instruction from being emitted regardless of whether an interactive
  HITL approval was ever granted.
- **Failure scenario:** Unchanged from the original incident for any run NOT using
  `execution.parallel: true`: an operator selects HITL, the orchestrating agent is expected to
  gate on an `AskUserQuestion` prompt at the prompt/skill layer only (`skills/start/SKILL.md:96-118`
  describes the intended interactive flow), but the stop-hook itself will emit
  `DELEGATE: Spawn implementer agent` for any READY/IN_PROGRESS task on every iteration with no
  awareness of whether a pending approval was ever answered. The fix suggested in
  `improvements.md` item (c) — "the stop-hook, when `mode == hitl` and an approval gate is
  pending, must not allow the loop to advance" — has been implemented ONLY for the `approve_batch`/
  `approve_plan` gates inside the opt-in parallel-dispatch feature (FEAT-012), not for the default
  path the original incident occurred on.
- **Recommendation:** Extend `execution_gate_effective`-style mechanical gating (or an equivalent)
  to the default sequential `DISPATCH_INSTR` construction at `stop-hook.sh:1133-1142`: track
  whether a HITL approval question is outstanding (e.g. a `.pending_approval` marker file written
  when the question is asked and cleared only by an explicit answer) and have the stop-hook refuse
  to emit an implementer-dispatch instruction while `mode == "hitl"` and that marker is set —
  making the "two stop-hook nudges != consent" rule enforced in code, not just in prompt text.

### F-007 — Recovery Pointer awk update in `stop-hook.sh` is a silent no-op against the live `nazgul/plan.md` format

- **Severity:** critical
- **Class:** bug
- **Evidence:** `scripts/stop-hook.sh:636-650` rewrites `nazgul/plan.md`'s Recovery Pointer by
  matching exact bold-label prefixes: `^- \*\*Current Task:\*\*`, `^- \*\*Last Action:\*\*`,
  `^- \*\*Next Action:\*\*`, `^- \*\*Last Checkpoint:\*\*`, `^- \*\*Last Commit:\*\*` — these match
  `templates/plan.md`'s pristine scaffold exactly (`templates/plan.md`, Recovery Pointer section:
  `**Current Task:**`, `**Last Action:**`, `**Next Action:**`, `**Last Checkpoint:**`,
  `**Last Commit:**`). The live `nazgul/plan.md` for the CURRENTLY RUNNING FEAT-013 objective uses
  different prose labels instead: `**Last completed**`, `**Active task**`, `**Current state**`,
  `**Next action**`, `**Files**`, `**Docs**` (none of which match the awk patterns' case,
  colon-inside-bold placement, or field names).
  **Empirically reproduced:** ran the exact awk expression from `stop-hook.sh:636-650` (with
  synthetic `-v` values) against the live `nazgul/plan.md` and diffed input vs. output — zero
  bytes changed. The awk command exits 0 and the file write (`mv "${PLAN}.tmp" "$PLAN"`) succeeds,
  so nothing surfaces an error; the loop has no way to detect that its own Recovery Pointer
  maintenance did nothing.
- **Failure scenario:** For any objective whose `plan.md` Recovery Pointer section was
  hand-authored or generated with different field labels/prose than the exact template (as
  FEAT-013's own, currently-active `nazgul/plan.md` is), every stop-hook iteration silently fails
  to refresh Current Task / Last Action / Next Action / Last Checkpoint / Last Commit. The
  Recovery Pointer — explicitly documented as "THE MOST IMPORTANT SECTION IN THIS FILE" for
  surviving compaction (`templates/plan.md` comment) — goes stale from the first iteration after
  plan creation and stays frozen at whatever the Planner/orchestrator last hand-wrote, exactly when
  compaction-driven recovery most needs it to be current.
- **Recommendation:** Either (a) enforce the canonical five-field format at plan.md-generation time
  (planner/orchestrator must never deviate from the exact template labels — add a
  doc-verifier/self-check that greps for all five exact patterns and fails loudly if any are
  absent), or (b) make the awk update format-tolerant (match on field intent via a small
  allow-list of label synonyms) and, either way, add a post-write verification step that diffs
  before/after and warns/errors if the Recovery Pointer section did not actually change on an
  iteration where it should have (active task/status changed).

### F-008 — `pre-compact.sh` and `stop-hook.sh` write conflicting schemas to the same checkpoint filename, causing silent regression

- **Severity:** high
- **Class:** bug
- **Evidence:** Both scripts derive the checkpoint filename from `current_iteration` without ever
  observing each other's writes: `scripts/stop-hook.sh:509`
  (`CHECKPOINT_FILE="$NAZGUL_DIR/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json"`, where
  `NEW_ITER` was just persisted to `config.current_iteration` at line 107) and
  `scripts/pre-compact.sh:19,24` (`ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")` then
  `CHECKPOINT="$NAZGUL_DIR/checkpoints/iteration-$(printf '%03d' "$ITERATION").json"`) — any
  PreCompact event firing after a Stop-hook boundary reads the SAME `current_iteration` value
  stop-hook just wrote and targets the IDENTICAL filename. The two schemas diverge sharply:
  `stop-hook.sh`'s checkpoint (`stop-hook.sh:565-619`) includes `review_unit` (aggregate-review
  granularity state), `branch` (feature/base/worktree count), `context_health`
  (compactions/consecutive-failures), and `plan_snapshot.est_iteration_usd`/`budget_spent_usd`;
  `pre-compact.sh`'s checkpoint (`pre-compact.sh:124-157`) has none of these fields at all.
  **Verified in production**: `nazgul/checkpoints/iteration-000.json` on disk right now has
  `"last_action": "Pre-compaction checkpoint"` (the literal string hard-coded at
  `pre-compact.sh:132`) and is missing `review_unit`/`branch`/`context_health` entirely — direct
  evidence this overwrite path is exercised in practice, not merely theoretical.
- **Failure scenario:** A PreCompact event (compaction can be triggered at essentially any point
  in a session, not only at iteration boundaries) firing shortly after a Stop-hook iteration
  silently replaces the just-written, richer checkpoint with a strictly inferior one — losing
  aggregate-review-unit state, branch/worktree counts, and budget/context-health tracking at
  exactly the moment (immediately pre-compaction) that state is most needed for a clean resume.
  Nothing detects or reports the schema downgrade; the next read of "latest checkpoint" silently
  gets the poorer of the two.
- **Recommendation:** `pre-compact.sh` should either (a) skip writing a checkpoint at all when one
  already exists for the current `current_iteration` (defer entirely to `stop-hook.sh`'s richer
  write, and instead just re-emit the existing checkpoint's recovery summary to stdout — which is
  the part PreCompact actually needs), or (b) share the exact checkpoint-construction logic with
  `stop-hook.sh` (a single function) so the two callers can never disagree on schema.

### F-009 — `post-compact.sh` and `session-context.sh` have zero review-granularity awareness, unlike `stop-hook.sh`

- **Severity:** medium
- **Class:** architecture
- **Evidence:** `grep -n "granularity\|GRANULARITY\|review_unit\|aggregate" scripts/pre-compact.sh
  scripts/post-compact.sh scripts/session-context.sh` returns zero matches in all three files.
  `stop-hook.sh` has a dedicated ~100-line block (`stop-hook.sh:358-456`) computing
  `AGGREGATE_REVIEW_READY`/`AWAITING_AGGREGATE_REVIEW` and re-selecting the active task away from
  a "parked" IMPLEMENTED task when `review_gate.granularity != "task"`. `post-compact.sh:102`
  (`[ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent ... for
  ${ACTIVE_TASK}."`) and the byte-identical `session-context.sh:152` will unconditionally suggest
  a single-task review-gate dispatch for the first IMPLEMENTED task found, with no check for
  whether the configured granularity is `"group"`/`"feature"` and the review unit is actually
  complete.
- **Failure scenario:** In `"group"`/`"feature"` granularity mode, a compaction event (PostCompact)
  or a session restart mid-run (SessionStart matcher `compact`) that lands while some — but not
  all — of a review unit's tasks are IMPLEMENTED will instruct the agent to spawn a single-task
  review-gate for a "parked" task, prematurely reviewing it against a partial diff and violating
  the granularity contract. This is exactly the class of violation the post-loop granularity
  reconciliation gate (`stop-hook.sh:853-915`) exists to catch after the fact — but that gate only
  fires at objective completion, so the wrong dispatch can still happen and produce wasted/invalid
  review work mid-run.
- **Recommendation:** Port the `AGGREGATE_REVIEW_READY`/`AWAITING_AGGREGATE_REVIEW` computation
  (or a shared helper extracted from `stop-hook.sh:358-456`) into `post-compact.sh` and
  `session-context.sh` so their DELEGATE suggestions respect `review_gate.granularity` the same
  way the main loop does.

### F-010 — Structural critique: task-counting/active-task-detection logic is duplicated across four scripts and has already drifted

- **Severity:** medium
- **Class:** architecture
- **Evidence:** Near-identical ~30-70 line blocks exist independently in `scripts/stop-hook.sh:158-186`
  + `317-331`, `scripts/pre-compact.sh:26-41` + `43-71`, `scripts/post-compact.sh:26-59`, and
  `scripts/session-context.sh:59-80` — all four hand-roll the same
  "for each `TASK-*.md`, call `get_task_status`, tally into 8 buckets, and separately find the
  first task matching `IN_PROGRESS|CHANGES_REQUESTED|IN_REVIEW|IMPLEMENTED`" logic, with no shared
  helper in `scripts/lib/task-utils.sh` despite that file existing precisely to hold shared
  task-manifest utilities (`count_tasks_by_status`/`get_active_task` already exist there,
  `scripts/lib/task-utils.sh:98-125`, but are single-status helpers, not the multi-bucket-plus-
  active-task combined scan actually used everywhere — so the four call sites reimplement it from
  scratch instead of using or extending the library).
- **Failure scenario:** This duplication is the direct architectural cause of F-002 (missing
  `INVALID` handling had to be independently absent in 4 places) and F-009 (granularity-awareness
  was added to only 1 of the 4 copies). Every future loop-engine feature that touches task-status
  accounting risks the same fan-out-and-drift pattern.
- **Recommendation:** Extract a single `count_tasks_and_find_active()` (or similar) into
  `scripts/lib/task-utils.sh` returning all counts + the active task in one pass, used by all four
  call sites. This is the single highest-leverage consolidation candidate in this dimension: it
  would have prevented F-002 and F-009 from being possible to introduce independently.

### F-011 — `.compaction_count` is incremented by two independent, uncoordinated code paths (needs runtime verification)

- **Severity:** low
- **Class:** fragility
- **Evidence:** `scripts/post-compact.sh:62-69` increments `$NAZGUL_DIR/.compaction_count`
  unconditionally on every invocation (`PostCompact` hook, `hooks/hooks.json` PostCompact array).
  `scripts/session-context.sh:94-108` increments the SAME file, gated on
  `[ "$HOOK_EVENT" = "compact" ]` where `HOOK_EVENT="${CLAUDE_HOOK_EVENT:-}"` — this script is
  wired to `SessionStart` with `"matcher": "compact"` (`hooks/hooks.json` SessionStart array,
  second entry). Both writes use the identical read-increment-write pattern
  (`PREV_COUNT`/`NEW_COUNT=$((PREV_COUNT + 1))`) with no locking or shared counter source. This
  count feeds the context-rot warning threshold at `stop-hook.sh:494-505`
  (`ITERS_SINCE_COMPACTION`, warns at `>= 8` iterations without compaction).
- **Failure scenario (unverified):** IF `PostCompact` and `SessionStart[matcher=compact]` both fire
  for the same physical compaction event (plausible if a compaction that ends the current session
  also triggers a fresh session-start with the "resuming from compaction" matcher), `.compaction_count`
  double-increments per real compaction, and the context-rot warning fires roughly twice as
  eagerly as intended.
- **Coverage disclosure:** This dimension's static read scope cannot determine Claude Code's exact
  internal firing semantics for these two hook events relative to one another — flagging this as a
  finding that needs adversarial/runtime verification (TASK-010 or a dedicated runtime probe)
  rather than asserting it as confirmed.
- **Recommendation:** If runtime verification confirms co-firing, consolidate to a single
  incrementing site (have `session-context.sh`'s compact branch read-only, and let
  `post-compact.sh` own the sole write), or add an idempotency key (e.g. stamp the current git SHA
  + iteration into the counter file and skip incrementing if unchanged since the last write).

### F-012 — Anchor 3 (evidence-gate integrity): gate design is sound; one interaction with F-002 noted

- **Severity:** low
- **Class:** architecture
- **Evidence:** `scripts/lib/review-evidence.sh` (read in full for this anchor, though its primary
  owner is dimension 2's territory) — `validate_review_evidence`
  (`review-evidence.sh:186-241`) recomputes evidence from disk (`configured_reviewers` from
  `config.json`, per-reviewer `.md` files, `_has_approved_verdict` reading a canonical
  `verdict:` frontmatter field first with a legacy-regex fallback) rather than trusting any
  manifest-declared "resolved" flag — this is the recompute-and-compare design that already closed
  the FEAT-006 forged-manifest hole (per `project_feat006_review_integrity_cost` prior incident).
  `_re_manifest_authentic` (`review-evidence.sh:85-111`) similarly re-derives whether a claimed
  `skipped[]` entry is reproducible from the current diff + selection policy rather than trusting
  the manifest's say-so, and `security-reviewer` is hard-excluded from both the skip and
  unverified-nonblocking paths (`review-evidence.sh:126,149`) as defense in depth. No forgery
  vector was found in this dimension's read of the gate itself.
- **Interaction with F-002/F-001:** the Layer-2 reactive safety net in `stop-hook.sh` that calls
  `validate_review_evidence` only runs `if [ "$STATUS" = "DONE" ]` (`stop-hook.sh:210`). A task
  wedged at `INVALID` status (F-001/F-002) is therefore invisible to this safety net too — it is
  neither reset to `IMPLEMENTED` with diagnostics nor escalated to `BLOCKED`; it simply never
  enters the `DONE` branch that triggers evidence re-validation. This does not make the evidence
  gate itself forgeable, but it does mean the gate provides zero protection for a task stuck in
  the `INVALID` blind spot.
- **Recommendation:** No change needed to `review-evidence.sh` itself. Fixing F-002 (adding
  loud `INVALID`-status handling to the counting/dispatch loops) closes this gap as a side effect.

---

## Structural Critique Summary (both lenses covered)

- **Overbuilt/redundant:** None found that should be removed outright in this dimension — the
  Layer-1 (`task-state-guard.sh` PreToolUse) + Layer-2 (`stop-hook.sh` reactive DONE-gate
  revalidation) split is intentional, documented defense-in-depth (`stop-hook.sh:188-192`), not
  accidental duplication, and should stay.
- **Consolidation candidates:** F-010 (task-counting/active-task logic, 4x duplicated,
  demonstrably already drifted twice — F-002, F-009) is the clearest, highest-leverage
  simplification opportunity in this dimension.
- **Config/guard sprawl:** Two independent "valid status" lists exist
  (`scripts/lib/structured-state.sh:12` `VALID_STATUSES`, and
  `scripts/task-state-guard.sh:277,284` inline regex) that have already diverged (F-001) — a
  single source of truth would prevent this class of bug by construction.

## Summary

- **Findings:** 12 total — critical 3 (F-001, F-002, F-007) · high 4 (F-003, F-004, F-006, F-008)
  · medium 2 (F-009, F-010) · low 2 (F-005, F-012) · low/fragility 1 (F-011, flagged as needing
  runtime verification rather than confirmed).
- **Anchors:** 4/4 root-caused with direct file:line evidence (2 root-caused as live bugs with
  empirical reproduction: F-001/APPROVED-wedge and F-007/Recovery-Pointer-no-op; 1 root-caused as
  an architecture gap: F-006/HITL; 1 cleared as sound with a noted interaction: F-012/evidence-gate).
- **Files modified:** only this artifact and `nazgul/tasks/TASK-001.md` (status transitions) — zero
  plugin source files touched.
