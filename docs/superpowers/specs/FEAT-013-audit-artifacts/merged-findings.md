# FEAT-013 — Merged Findings Register (Phase 2: Dedup & Merge)

**Task:** TASK-009 · **Inputs:** `dimension-1-findings.md` through `dimension-8-findings.md` (all 8
present, all board-APPROVED). **Output of this phase:** one severity-ranked register with stable
IDs (`MF-NNN`) + the Phase-3 (TASK-010) verification queue. CONFIRMED/PLAUSIBLE is intentionally
**not** assigned below (that is TASK-010's job) except where a source dimension itself already
flagged a hedge (PLAUSIBLE-not-CONFIRMED, or "needs runtime verification") — those hedges are
carried over verbatim, not resolved here.

## Dimension coverage gaps (disclosed up front, per TRD Phase 2 rule 5)

All 8 dimension artifacts exist and were read in full. None is missing. Several self-declare
partial coverage in specific sub-areas; none of these gaps affect the findings merged below (they
bound what *could* still be found, not the validity of what *was*):

- **dim-1**: F-011 (compaction-counter double-increment) explicitly needs runtime/adversarial
  verification of Claude Code's hook-firing semantics — carried as PLAUSIBLE-hedged (MF-012).
  `task-state-guard.sh` read only opportunistically (dim-3's primary territory).
- **dim-2**: `reviewer-domains.json` scanned, not exhaustively diffed; `fix-first-heuristic.md`
  spot-checked; `.claude/agents/generated/*.md` existence-checked only.
- **dim-3**: `RULES.md` targeted-grepped, not read end-to-end; `notify.sh`/`webhook-forward.sh`
  audited at moderate (not exhaustive/fuzzed) depth; single static-read pass, no dynamic input
  fuzzing.
- **dim-4**: full declared-scope coverage, no gaps disclosed (guard-surface boundary explicitly
  deferred to dim-3).
- **dim-5**: full primary-scope read; `RULES.md` §11–17 only (not the whole file); one finding
  (Finding 7 / MF-042) explicitly PLAUSIBLE-not-CONFIRMED by the dimension's own author.
- **dim-6**: `agents/*.md`/`skills/*/SKILL.md` grepped for config-key refs, not read end-to-end;
  `README.md` spot-checked, not swept key-by-key; six config sections `docs/CONFIGURATION.md`
  doesn't document at all were checked for consumer-presence only, not for a docs claim to falsify.
- **dim-7**: ~50 of 66 test files grep-swept (assertion-density/anchor-hit triage), not fully read;
  `tests/e2e/*` bodies and `tests/fixtures/bootstrap-transform/` contents not read (explicitly
  out of scope / low marginal value).
- **dim-8**: ~40 archived objective snapshots surveyed by directory listing only, not content;
  no other-project runtime state read; did not re-run `self-audit.sh`'s own detection logic to
  distinguish "FEAT-011/012 produced no findings" from "the self-audit gate didn't fire for them."

## Dedup summary

- **62 merged findings** survive from the 8 dimension artifacts' combined ~95 individual
  finding/structural-critique entries.
- **6 cross-dimension merges performed** (5 pairs + implicit sub-merges), each listed with its
  contributing dimensions and a severity-call note:
  1. **MF-006** — dim-1 F-006 + dim-8 RT-04 (HITL gate degrades to autonomous — code-level root
     cause + first-party runtime incident report of the exact same mechanism).
  2. **MF-014** — dim-2 F4 + dim-8 RT-01 + dim-8 RT-06 (reviewer background-dispatch stall — one
     root-cause finding + two independent live runtime recurrences, one of which is this very
     objective's own review gate failing the same way while auditing itself).
  3. **MF-025** — dim-3 F3-04 + dim-5 Finding 3 (`Files modified` JSON-array value never correctly
     parsed — dim-3 found it via the guard/rework-guard angle, dim-5 independently rediscovered
     the identical root cause via the parallel-batch dispatch-safety angle).
  4. **MF-034** — dim-4 Finding 1 + dim-5 Finding 1 (git-hooks install/uninstall lifecycle never
     invoked in production — the two dimensions' explicitly-flagged canonical duplicate, found
     from the git-hooks-lifecycle side and the worktree-utils.sh-dead-code side respectively).
  5. **MF-048** — dim-6 Anchor 1 + dim-8 RT-08 (`config.json.v*.bak` accumulation — dim-6
     root-caused it in the migration script, dim-8 independently corroborated it as live runtime
     evidence).
  - Two source anchors that reached **CLEARED/fixed** status (dim-8 RT-02, emit-event jq crash;
    RT-03, self-audit path-with-spaces) are **not** carried forward as active register entries —
    see "Resolved/cleared anchors" at the end. Their residual fragility (RT-02 only) is folded
    into MF-016.
- **0 drops.** Every finding across all 8 artifacts carries at least one concrete `file:line` (or
  named runtime-artifact-path, e.g. `nazgul/config.json.v24.bak`, `nazgul/logs/events.jsonl`)
  citation. See "Dropped" section below for the explicit statement.
- Where a merge changed the effective severity call, the rationale is recorded inline in that
  finding's entry (per TRD Phase 2: cross-dimension agreement is a severity signal; "take the max
  unless a contributor's rationale argues otherwise").

---

# Findings Register (severity-ranked)

## CRITICAL (10)

### MF-001 — `APPROVED` is missing from `VALID_STATUSES`; canonical frontmatter status reads as `INVALID`
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-1 (F-001)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/structured-state.sh:12` (`VALID_STATUSES` omits `APPROVED`);
  `scripts/lib/structured-state.sh:66-75` (`read_task_status` returns `INVALID` for any
  off-enum value); `scripts/lib/task-utils.sh:16-23` (`get_task_status` propagates `INVALID`
  verbatim); `RULES.md:34` and `agents/review-gate.md:513` (APPROVED is a real, intentional,
  documented state); empirically reproduced against a synthetic manifest.
- **Failure scenario:** In YOLO + `afk.task_pr` mode, once review-gate sets a task's frontmatter
  to `status: APPROVED`, every reader of `get_task_status`/`read_task_status` sees `INVALID`
  instead — the direct root cause of MF-004 and MF-005 below.
- **Recommendation:** Add `APPROVED` to `VALID_STATUSES` (one line). Reconcile against
  `scripts/task-state-guard.sh:277,284`'s independent regex status list, which already includes
  `APPROVED` — the two lists have drifted apart and should become one source of truth.

### MF-002 — `INVALID` status is an invisible black hole in the loop's task-counting/dispatch logic
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-1 (F-002)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:158-186` (status-counting `case` has no `INVALID)` arm but
  unconditionally increments `TOTAL_COUNT` at line 172); duplicated gap in `stop-hook.sh:322-331,
  346-356`, `scripts/pre-compact.sh:54-71`, `scripts/post-compact.sh:38-59`,
  `scripts/session-context.sh:59-80`; grep confirms zero `INVALID` handling anywhere in these
  five files.
- **Failure scenario:** A task stuck at `INVALID` permanently inflates `TOTAL_COUNT` above the sum
  of every tracked bucket — `DONE_COUNT == TOTAL_COUNT` (or the YOLO equivalent) can never be
  true, so the loop never detects completion and runs to `max_iterations` or the
  consecutive-failure backstop with no diagnostic identifying which task or why.
- **Recommendation:** Add an explicit `INVALID`/unknown arm to all four duplicated counting loops
  that emits a loud diagnostic. Strongest argument for the MF-009 consolidation (a single shared
  counting function needs this fix only once).

### MF-003 — Recovery Pointer awk update in `stop-hook.sh` is a silent no-op against the live `nazgul/plan.md` format
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-1 (F-007)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:636-650` matches exact bold-label prefixes
  (`**Current Task:**`, etc.) that match `templates/plan.md`'s pristine scaffold but not this
  very objective's own live `nazgul/plan.md` (`**Last completed**`, `**Active task**`, etc.).
  Empirically reproduced: ran the exact awk expression against the live file — zero bytes
  changed, exit 0, no error surfaced.
- **Failure scenario:** For any objective whose `plan.md` Recovery Pointer uses different field
  labels than the exact template (as FEAT-013's own currently-active plan.md does), every
  stop-hook iteration silently fails to refresh the section explicitly documented as "THE MOST
  IMPORTANT SECTION IN THIS FILE" for surviving compaction — it goes stale from the first
  iteration and stays frozen exactly when compaction-driven recovery needs it most.
- **Recommendation:** Either enforce the canonical five-field format at plan-generation time (with
  a doc-verifier self-check), or make the awk update format-tolerant via a label-synonym
  allow-list, plus a post-write diff/warn step. Directly explains MF-060's live symptom in this
  objective.

### MF-013 — Group/feature review granularity cannot reach DONE: both the DONE-gate and the reactive safety net key review evidence by TASK-ID only
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-2 (F2)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/review-evidence.sh:186-188` (`validate_review_evidence` always builds
  `reviews/$task_id`, no granularity/unit parameter); `scripts/task-state-guard.sh:429-431`
  (preventive PreToolUse guard, same task-id-only call, `grep -n granularity` → zero hits in its
  evidence-check block); `scripts/stop-hook.sh:210-296` (reactive net, same gap, despite
  `GRANULARITY` already being in scope for a separate block at lines 358-456); `agents/
  review-gate.md:42` (group/feature mode writes to `GROUP-<n>`/`FEATURE-<feat_id>`, never
  `TASK-<n>`); no bridging/resolver exists anywhere in `scripts/` or `agents/`.
- **Failure scenario:** With `review_gate.granularity: "group"` or `"feature"`, a passing
  aggregate review is written to `reviews/GROUP-1/...`, but the PreToolUse guard computes
  `reviews/TASK-003` (doesn't exist), hard-blocks the DONE edit, and even if bypassed the reactive
  net independently resets the task back to IMPLEMENTED or escalates to BLOCKED — corrupting
  state a legitimately-passing review board produced. Group/feature granularity is non-functional
  for completing any task today.
- **Recommendation:** Both `validate_review_evidence` call sites must resolve the task's actual
  review-unit ID (task/group/feature) before checking evidence, reusing the resolution logic
  already proven correct in `stop-hook.sh:358-456`. Matches pre-existing backlog item IMP-052.

### MF-014 — Review-gate never pins reviewer subagents to synchronous dispatch; recurring, still-live "reviewer stalls without a parseable verdict" incident class (5 recorded occurrences across 4 objectives, including this one, today)
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-2 (F4), dim-8 (RT-01, RT-06)
- **Verification status (TASK-010, Phase 3):** **Symptom CONFIRMED; single-mechanism framing
  PARTIALLY-CONFIRMED** (corrected post-board-review from a flat CONFIRMED — see
  `verification-verdicts.md` "Board Corrections" and
  `verification-crosschecks/MF-014-fresh-skeptic.md`). The reviewer verdict-capture stall symptom
  is real and cross-objective (code gap: `review-gate.md` never sets `run_in_background: false`).
  The single claimed mechanism ("Agent tool defaults to background dispatch") is only partially
  established — a fresh, differently-primed skeptic found the stalls are multi-causal: reviewer
  `maxTurns: 12` turn-budget exhaustion, haiku-tier format non-adherence, a since-removed
  historical explicit background flag, and (for this very objective) Agent-Teams `SendMessage`
  async-by-design fan-out — a different dispatch path than review-gate.md's Agent-tool path, making
  RT-06 a path-mismatched corroboration rather than same-mechanism evidence. Roadmap fix must be
  multi-pronged (maxTurns, defensive synchronous pin, verdict-schema-or-retry, Agent-Teams async
  persistence), not just adding `run_in_background: false`.
- **Evidence:** `nazgul/improvements.md:355-359` (FEAT-010, open): background-dispatched reviewers
  "crawled the codebase and were cut off," 3 of 4 stopped mid-exploration with no verdict.
  `grep -n "run_in_background\|background" agents/review-gate.md agents/templates/
  reviewer-base.md` → **zero matches** anywhere in the pipeline (Step 0, 2, 3.6, 3.75, 5.0).
  Agent tool's own contract: background dispatch is the default unless `run_in_background: false`
  is set — contradicting `review-gate.md:148`'s assumed "single message returns once ALL reviewers
  have completed" semantics. Runtime corroboration:
  `nazgul/archive/2026-07-22-172527-pre-FEAT-013/reviews/TASK-007/architect-reviewer.md`
  (FEAT-012, out-of-band manual re-dispatch needed) and
  `nazgul/logs/events.jsonl` 2026-07-14T00:30:06Z (`reviewer_verdict`, `UNVERIFIED`, confidence 0);
  `nazgul/reviews/TASK-001/qa-reviewer.md:6` (this very objective, today:
  `persisted_by: orchestrator (review-gate went idle before persisting...)`).
- **Failure scenario:** Every Parallel Review Mode cycle risks stalled reviewers, forcing retry →
  UNVERIFIED → (for critical reviewers) fail-closed BLOCKED requiring human intervention. Safety
  is contained (UNVERIFIED never silently passes), but reliability/cost blast radius is large and
  now evidenced across FEAT-009, FEAT-010, FEAT-012, and FEAT-013 (this audit's own review gate).
- **Severity-call note:** dim-2's own critical rating stands as the ceiling; dim-8's two
  independent live recurrences (one in this very audit) don't raise the label further but
  substantially reinforce confidence this is the single highest-recurrence defect in the corpus —
  recommend TASK-011 treat as top wave-1 candidate.
- **Recommendation:** Add explicit `run_in_background: false` to every Agent-dispatch instruction
  in `agents/review-gate.md` (Steps 0, 2, 3.6, 3.75, 5.0), state the reason inline, add a
  lightweight regression check.

### MF-022 — Bash-mediated writes bypass the state machine entirely
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-3 (F3-01)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `hooks/hooks.json:52-97` (`task-state-guard.sh` wired only on
  `Write|Edit|MultiEdit`, never `Bash`); `scripts/pre-tool-guard.sh:68-87` (Bash-side funnel
  recognizes only `sed`/`cat`/`tee`/echo-printf redirects); `RULES.md:39,142` (`[enforced]` claim
  contradicted by the false-negative angle).
- **Failure scenario:** Any write bypassing Write/Edit/MultiEdit (`mv`, `cp`, `dd`, `python3 -c
  ...write()`, `perl -i`, `node -e ...writeFileSync`, `ex`/`vi -c wq`) passes `pre-tool-guard.sh`
  unrecognized and never reaches `task-state-guard.sh` at all — the entire state machine,
  evidence gates, and review-gate check are skipped. A forged `status: DONE` manifest with a
  fabricated `## Commits` line can be placed with one `mv`.
- **Recommendation:** Same "layer that knows the truth" migration already validated for
  branch protection (git-level hook or filesystem-level integrity check the stop-hook trusts),
  rather than enumerating every possible Bash write path.

### MF-023 — `prompt-guard.sh` reads a non-existent env var; dead in production
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-3 (F3-02)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/prompt-guard.sh:16-22` (`USER_PROMPT="${CLAUDE_HOOK_USER_PROMPT:-}"`,
  never reads stdin); every sibling guard reads its JSON envelope from stdin;
  `tests/test-prompt-guard.sh:19-23,88` is the only place that env var is ever set (test harness
  only, not production).
- **Failure scenario:** `CLAUDE_HOOK_USER_PROMPT` is never set in production, so `USER_PROMPT` is
  always empty and the guard exits 0 (allow) unconditionally — both of its protections (blocking
  a manually-typed `NAZGUL_COMPLETE`, blocking direct task-status-setting prompt text) are
  silently inert. Same "unrealistic-input test" class as MF-052 (dim-7's anchor 1) — recurring
  here in dim-3's own guard and test suite.
- **Recommendation:** Rewrite to read stdin JSON like every sibling guard; rewrite
  `tests/test-prompt-guard.sh` to pipe realistic stdin instead of exporting the env var.

### MF-034 — The entire git-hooks install/uninstall lifecycle is never invoked by production code; `worktree-utils.sh` is dead code
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-4 (Finding 1), dim-5 (Finding 1)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/worktree-utils.sh:62-64,199-205` (`install_git_hooks`/
  `uninstall_git_hooks` called only from `create_feature_branch`/`cleanup_all_worktrees`);
  exhaustive grep confirms `worktree-utils.sh` is sourced by exactly one file in the whole
  repo — `tests/test-git-hooks-wiring.sh`. Production branch/worktree setup is inline prose in
  `skills/start/SKILL.md` (5 occurrences) and `agents/implementer.md:113`, none of which sources
  the library. **Live dogfood proof on this repo, today**: `guards.git_hooks: true`,
  `branch.feature` set (active objective), but `branch.prior_hooks_path: null` and
  `git config --get core.hooksPath` → OS default; `nazgul/.githooks/` does not exist on disk.
  Consequence: `self_heal_git_hooks` (`scripts/lib/git-hooks.sh:189-211`, wired to every
  `SessionStart` via `session-context.sh:85-91`) early-returns on every invocation because
  `prior_hooks_path` is never recorded — the self-heal layer can structurally never do anything.
- **Failure scenario:** Any project with `guards.git_hooks: true` (the default) believes the
  pre-commit base-branch guard and pre-merge-commit H2 verdict guard are protecting it. Neither
  ever installs — a direct commit to base is never blocked, and a CHANGES_REQUESTED/BLOCKED
  parallel unit can be merged with zero mechanical enforcement, silently defeating the entire
  FEAT-010 "enforce at the layer that knows the truth" redesign.
- **Severity-call note:** Both contributing dimensions independently rated this critical from two
  different angles (git-hooks-lifecycle side vs. worktree-utils-dead-code side); maximal
  cross-dimension agreement, no downgrade warranted — likely this audit's single highest-impact
  finding.
- **Recommendation:** Wire `install_git_hooks` into the actual branch-creation call site in
  `skills/start/SKILL.md` (all 5 occurrences), or delete `worktree-utils.sh` and rebuild the
  install trigger inside `session-context.sh`. Must ship together with MF-035 (worktree escape) —
  wiring install back in without also fixing MF-035 makes the guard newly live but still
  bypassable in parallel mode.

### MF-038 — GitHub connector's PUSH half is an unreachable no-op; the map never gets a real local id
- **Severity:** critical · **Class:** bug · **Dimensions:** dim-5 (Finding 2)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/connector-github.sh:88-99` (`_cgh_map_put` only writes a real value
  with a 3rd arg); only production caller (`connector_github_pull_archive`,
  `connector-github.sh:270-282`) always calls the 2-arg stub form; repo-wide grep confirms no
  caller ever supplies a real local id; `_cgh_map_resolve` (`:121-128`) can therefore never match,
  making `connector_github_push_status`/`push_pr` unconditional no-ops despite being wired live
  into `scripts/stop-hook.sh:705,707`. `tests/test-connector-github.sh:267-268` proves this by
  having to hand-fabricate the map state to exercise push at all.
- **Failure scenario:** An operator enabling `connectors.github.push.enabled: true` gets pulls,
  claims, and starts working correctly, but no status label or PR-link comment ever appears on
  the originating issue — indefinitely, with no error/warning anywhere (both early-exit paths
  return 0, identical to "push gate is off").
- **Recommendation:** Thread the picked issue number through to a real local id, likely via
  `scripts/heartbeat.sh`'s archive-then-start flow plus a write-back step from
  `skills/start/SKILL.md` once the started session's `feat_id` is known.

### MF-052 — `create_task_file()` fixture helper writes a status format production stopped emitting; 259 call sites across 16 test files never construct the manifest shape the loop/guards actually receive
- **Severity:** critical · **Class:** test-gap · **Dimensions:** dim-7 (F-1)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `tests/lib/setup.sh:52-72` writes only legacy `- **Status**: X` (no frontmatter);
  `agents/planner.md:86` mandates canonical `---\nstatus: PLANNED\n---` frontmatter; live check —
  11/11 real task manifests in this repo use canonical frontmatter, 0 use list-item-only.
  `scripts/lib/task-utils.sh:16-23` treats frontmatter as authoritative, list-item as fallback.
  259 call sites across 16 files (`test-stop-hook.sh` 89, `test-task-state-guard.sh` 67, etc.) all
  construct the fallback shape. Already caused one real production bug (multi-line `Edit
  old_string` spanning the frontmatter fence crashed `task-state-guard.sh`'s awk reconstruction —
  caught by a human, not the pre-existing green suite; regression tests 75-76 added after the
  fact).
- **Failure scenario:** A future change correct for list-item-format manifests but subtly wrong
  for canonical-frontmatter manifests passes all 259 assertions and is still broken against every
  real task file this plugin creates for itself and every managed project.
- **Recommendation:** Change `create_task_file()` to emit canonical frontmatter as the default
  (low-risk, since `get_task_status` already prefers frontmatter transparently — the 259 call
  sites gain realistic coverage with zero per-site changes); keep a renamed
  `create_task_file_legacy()` for the tests that specifically exist to prove fallback
  compatibility.

---

## HIGH (18)

### MF-004 — YOLO-mode dependency promotion permanently wedges on an `APPROVED` dependency
- **Severity:** high · **Class:** bug · **Dimensions:** dim-1 (F-003)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:734-748` — `DEP_STATUS != "APPROVED"` is always true because
  `get_task_status` never returns literal `APPROVED` (MF-001), so `ALL_DONE` is forced false every
  iteration.
- **Failure scenario:** In YOLO mode, any `PLANNED` task depending on a task now at
  `status: APPROVED` never promotes to `READY` — stuck for the rest of the run.
- **Recommendation:** Fixed by MF-001's one-line change; no independent code change needed.

### MF-005 — YOLO-mode loop completion is unreachable while any task holds `APPROVED`
- **Severity:** high · **Class:** bug · **Dimensions:** dim-1 (F-004)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:180` (`APPROVED_COUNT` never increments, same root cause as
  MF-001); `stop-hook.sh:800-801` gates YOLO completion on
  `APPROVED_COUNT + DONE_COUNT == TOTAL_COUNT`; same undercount feeds `PROGRESS_COUNT`
  (`stop-hook.sh:299-305`), so `CONSEC_FAILURES` never resets on a genuine APPROVED transition.
- **Failure scenario:** A YOLO + task-pr run where every task reaches `APPROVED` never satisfies
  completion and never registers the transition as progress — degrades to `max_iterations` or a
  false consecutive-failure stop, looking broken when it is actually done-except-for-PR-merge.
- **Recommendation:** Same root fix as MF-001; add a regression test seeding a canonical
  `status: APPROVED` manifest and asserting completion fires. No such test found in scope
  (test-gap for dim-7).

### MF-006 — HITL mode has no mechanical stop-hook enforcement outside the opt-in parallel-batch path
- **Severity:** high · **Class:** architecture · **Dimensions:** dim-1 (F-006), dim-8 (RT-04)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:1125-1142` builds `DISPATCH_INSTR` for the default
  sequential path unconditionally on task status; `$MODE` never gates this path. The only place
  `$MODE` participates in a pass/fail decision is `execution_should_pause(...)` at
  `stop-hook.sh:1171`, reached only when `EXEC_PARALLEL=true` (opt-in, default false) AND
  `GRANULARITY == "task"`. Runtime corroboration: `nazgul/improvements.md:24-28` — first-party
  operator report, a different project's run: "Two stop-hook iterations with no response means
  you're away — I'll stop blocking and proceed," despite the operator having explicitly selected
  HITL.
- **Failure scenario:** For any non-`--parallel` run, the stop-hook emits
  `DELEGATE: Spawn implementer agent` for any READY/IN_PROGRESS task regardless of whether a
  pending HITL approval was ever answered — matching the operator-observed incident exactly.
- **Severity-call note:** Both contributing entries agree at high; dim-8's is the live runtime
  incident that produced the code-level finding's anchor in the first place — no severity change,
  agreement recorded.
- **Recommendation:** Extend `execution_gate_effective`-style mechanical gating to the default
  sequential `DISPATCH_INSTR` construction — track an outstanding-approval marker file and refuse
  to emit a dispatch instruction while `mode == "hitl"` and it is set.

### MF-007 — `pre-compact.sh` and `stop-hook.sh` write conflicting schemas to the same checkpoint filename, causing silent regression
- **Severity:** high · **Class:** bug · **Dimensions:** dim-1 (F-008)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/stop-hook.sh:509` and `scripts/pre-compact.sh:19,24` both derive the
  checkpoint filename from `current_iteration` without observing each other's writes; the two
  schemas diverge sharply (stop-hook's includes `review_unit`/`branch`/`context_health`/budget
  fields; pre-compact's has none). **Verified in production**: `nazgul/checkpoints/
  iteration-000.json` on disk right now is missing all of those fields — direct evidence the
  overwrite path is exercised, not theoretical.
- **Failure scenario:** A PreCompact event firing shortly after a Stop-hook iteration silently
  replaces the richer, just-written checkpoint with a strictly inferior one, losing
  aggregate-review-unit state and budget tracking exactly when a clean resume needs it most.
- **Recommendation:** Either skip the pre-compact write when a checkpoint already exists for the
  current iteration, or share the exact checkpoint-construction function between both callers.

### MF-015 — `enforce_granularity` drift detection infers granularity rather than verifying it, and can silently record zero coverage for group/feature reviews
- **Severity:** high · **Class:** bug/fragility · **Dimensions:** dim-2 (F3)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/subagent-stop.sh:39-120` derives `granularity_used` from task-id
  population count + currently-configured value, never from which review directory actually
  received the verdicts; `:79-84` filters strictly to `TASK-[0-9]*`, silently dropping any
  `reviewer_verdict` event whose `task_id` is `GROUP-1` (the natural reading of an underspecified
  instruction in `agents/review-gate.md:246-281`); `:72` — zero surviving events means zero lines
  appended to `review-coverage.jsonl`; `scripts/stop-hook.sh:865-873` treats an absent record as
  no-violation, not "coverage missing."
- **Failure scenario:** If review-gate emits `reviewer_verdict` with the unit ID for a genuine
  group review, the coverage detector drops every event and the post-loop gate whose entire job
  is to catch this drift silently passes. Real-world exposure is currently low only because MF-013
  already prevents group/feature tasks from completing at all.
- **Recommendation:** Emit one event per (reviewer × covered task) with a `review_unit` field the
  detector reads directly instead of inferring; add a "coverage record missing" warning distinct
  from "coverage violated." Resolve together with MF-013 and MF-016.

### MF-024 — File Scope enforcement is permanently dead code (field-name mismatch)
- **Severity:** high · **Class:** bug · **Dimensions:** dim-3 (F3-03)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/task-state-guard.sh:204-239` queries field `"File Scope"`;
  `agents/planner.md:107-121` only ever emits `## File Scope` heading + `- **Files modified**:`
  inline field; zero instances of `- **File Scope**:` across all 11 live manifests; `RULES.md:195`
  claims `[enforced]`.
- **Failure scenario:** `FILE_SCOPE` is always empty, so the entire scope-restriction block
  (lines 211-239) never executes for any task — an IN_PROGRESS implementer can edit any file in
  the repository with zero mechanical scope restriction.
- **Recommendation:** Point the guard at `Files modified` and fix the parsing for its JSON-array
  form (see MF-025 — a naive comma-split is insufficient). Add a regression test using a real
  planner-shaped manifest.

### MF-025 — `Files modified` JSON-array value is never actually parsed, breaking three independent consumers
- **Severity:** high · **Class:** bug · **Dimensions:** dim-3 (F3-04), dim-5 (Finding 3)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/task-utils.sh:90-94` (`get_task_field` returns raw post-colon text
  verbatim including `[`/`]`/`"`); `scripts/parallel-rework-guard.sh:56-66` (`_scope_has` splits
  on `,` and exact-string-compares — brackets/quotes attach asymmetrically, can never match);
  `scripts/lib/parallel-batch.sh:289-303` (pairwise-disjoint-scope check misses a real overlap
  unless it sits at the same bracket-position in both scopes). Live multi-item proof:
  `nazgul/tasks/TASK-010.md:12`. `tests/test-parallel-batch.sh:24-25`'s fixture writes bare
  comma-separated paths, matching no real manifest.
- **Failure scenario:** (a) `parallel-rework-guard.sh`'s "committed unit's scope is never
  re-worked" protection never fires. (b) Two READY tasks with genuinely overlapping file scope
  (shared file at differing array positions) pass the disjointness check and get dispatched
  concurrently in `execution.parallel` mode, racing the merge step.
- **Severity-call note:** Independently rediscovered by two dimensions via different consumer
  angles (guard/rework-guard vs. parallel-batch dispatch safety) — both already rated high;
  agreement reinforces confidence, no upgrade to critical since dim-3 itself frames the parallel
  race as degrading to a manual merge conflict, not silent corruption.
- **Recommendation:** One shared, correctly-parsing accessor (`jq -r '.[]'`) used by all three
  consumers; formalize JSON-array as the one documented format in `agents/planner.md:110`.

### MF-026 — Commit-SHA evidence gate is a pattern match, not a verification
- **Severity:** high · **Class:** bug · **Dimensions:** dim-3 (F3-05)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/task-state-guard.sh:362-387` — `grep -qE '[0-9a-f]{7,40}'` with no call to
  `git cat-file -e`/`git rev-parse --verify` anywhere in the file or `review-evidence.sh`;
  `RULES.md:18` claims `[enforced]`.
- **Failure scenario:** A manifest containing any 7+ character lowercase-hex substring (a typo, or
  unrelated prose) satisfies the gate with no commit ever made. Same forged-evidence class already
  fixed once for review-manifest authenticity via recompute-and-compare
  (`_re_manifest_authentic`); never ported to this more fundamental gate.
- **Recommendation:** Verify the extracted SHA against the real repository:
  `git cat-file -e "$sha^{commit}"`.

### MF-027 — `rm -rf` root/home pattern block over-matches any absolute-path deletion
- **Severity:** high · **Class:** false-positive (fail-**safe** over-block — NOT a security bypass;
  do not conflate with MF-022's fail-open class) · **Dimensions:** dim-3 (F3-06)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED as a fail-safe over-block
  (regex-precision defect, usability/availability impact); NOT a security bypass** (reclassified
  post-board-review from an implied fail-open framing — see `verification-verdicts.md` "Board
  Corrections"). The over-match is real, empirically confirmed live against the verifier's own
  session, but the guard denies legitimate commands rather than letting anything dangerous through
  — must be weighted separately from MF-022 (the genuine fail-open bypass) in the roadmap. Fix is
  regex anchoring (`rm\s+-rf\s+/(\s|$|;|&|\|)` or a real root-path check), not a security patch.
- **Evidence:** `scripts/pre-tool-guard.sh:43-46` — `rm\s+-rf\s+/` has no end-anchor, matching any
  `rm -rf /<anything>` as a substring; `RULES.md:116` documents the narrower intent.
- **Failure scenario:** `rm -rf /tmp/build-cache` or any legitimate absolute-path AFK cleanup is
  unconditionally blocked with a misleading "root filesystem" message — highest cost precisely in
  unattended AFK/YOLO mode where no human is present to override.
- **Recommendation:** Anchor precisely: `rm\s+-rf\s+/(\s|$|;|&|\|)`.

### MF-028 — Force-push-to-main check is order-dependent
- **Severity:** high · **Class:** bypass · **Dimensions:** dim-3 (F3-07)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/pre-tool-guard.sh:54-55` requires the force flag before the branch name;
  `RULES.md:114,118` claims unconditional enforcement "regardless of mode."
- **Failure scenario:** `git push origin main --force` and `git push origin main -f` — both
  idiomatic, common forms — match neither pattern and are not blocked.
- **Recommendation:** AND two independent boolean checks (force-flag present, `main`/`master`
  present) within a `git push` invocation instead of requiring fixed order.

### MF-035 — Worktree guard escape via relative `core.hooksPath` resolving per-worktree-toplevel
- **Severity:** high (currently dormant, masked only by MF-034) · **Class:** bug ·
  **Dimensions:** dim-4 (Finding 2)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** Empirically reproduced in a scratch git repo (2.48.1): a managed `pre-commit` hook
  fires correctly in the main worktree but silently does not fire from a secondary worktree,
  because `git rev-parse --git-path hooks` resolves relative to the invoking worktree's own
  toplevel. `scripts/lib/git-hooks.sh:126-127,143` installs only under the main worktree with a
  relative `core.hooksPath`. `agents/implementer.md:113-114` confirms every task-level commit in
  parallel mode runs from inside a secondary worktree — the exact escape condition — for every
  task in progress. Mitigating factor: `agents/review-gate.md:522-524` and
  `agents/team-orchestrator.md:93` both instruct `cd <main_worktree_path>` before merge, so the
  documented flow is safe today — but only by convention, with no mechanical check.
- **Failure scenario:** Once MF-034 ships and guards actually install, any deviation from the "cd
  first" convention (agent memory lapse, stale cwd after a tool error, a future parallel-dispatch
  path that merges without the explicit cd) silently produces an unguarded merge with zero
  exception or log line.
- **Recommendation:** Make `merge_task_to_feature()` worktree-cwd-safe via explicit `git -C`, and/
  or install managed hooks per task worktree (or `core.hooksPath` with `--worktree` scoping) so
  the guard is structurally present regardless of invoking worktree. Must ship together with
  MF-034 — fixing MF-034 alone newly enables this bypass for every parallel-mode commit.

### MF-039 — Heartbeat's "never a second loop" concurrency guard has a TOCTOU race
- **Severity:** high · **Class:** fragility · **Dimensions:** dim-5 (Finding 4)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/heartbeat.sh:176-182` calls `count_active_sessions`
  (`scripts/lib/session-tracker.sh:31-38`, plain `ls *.lock | wc -l`) before archiving/starting
  anything; the `.lock` file is only created inside the **new** session's own SessionStart hook,
  well after `_hb_start`'s `claude -p` call. No `flock`/atomic-`mkdir` mutex exists.
- **Failure scenario:** Two heartbeat ticks invoked within the CLI-startup window (scheduled
  routine + manual `/nazgul:heartbeat` overlap, or a short interval vs. slow cold start) both read
  `0` active sessions and both proceed — possibly on two different candidates, each triggering its
  own full Nazgul loop concurrently against the same `nazgul/` state.
- **Recommendation:** Make the claim atomic — `mkdir` a lock directory as the first action of
  `heartbeat.sh` itself, released via `trap`, so concurrent ticks race on the `mkdir` rather than a
  stale `ls` read.

### MF-040 — Wave Groups line-format brittleness silently degrades `execution.parallel` to fully sequential
- **Severity:** high · **Class:** fragility · **Dimensions:** dim-5 (Finding 5)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/parallel-batch.sh:267-282` requires ≥2 `TASK-ID`s on one bullet line
  (matching `agents/planner.md:135-136`'s documented format); this objective's own
  `nazgul/plan.md:80-88` lists one task per bullet — a perfectly reasonable, more-readable
  convention that yields zero multi-task matches, silently falling back to fully sequential with
  no error surfaced beyond an internal `reason` string.
- **Failure scenario:** Any planner run (human-edited or LLM-authored) that reformats a wave to
  one-bullet-per-task permanently and silently disables `execution.parallel` for that wave, with
  no signal anything is wrong.
- **Recommendation:** Parse each wave's task membership from the `### Wave N` heading + all
  following `- TASK-NNN` bullets rather than requiring same-line comma-grouping.

### MF-048 — `config.json.v*.bak` accumulation: no pruning/rotation, unbounded growth, committed permanently in default shared mode
- **Severity:** high · **Class:** fragility/architecture · **Dimensions:** dim-6 (Anchor 1),
  dim-8 (RT-08)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/migrate-config.sh:39-42` backs up unconditionally on every crossing, with
  zero pruning logic anywhere in the plugin (contrast `stop-hook.sh:719-720`'s checkpoint-pruning
  precedent). **Live proof**: `nazgul/config.json.v{11,12,13,16,17,19,20,22,23,24}.bak` — 10
  files, one month of dogfooding, `nazgul/logs/migrations.log` corroborating one line per file.
  `install_mode: "shared"` is the *default*; only `--local` mode gitignores `nazgul/` — this repo
  happens to run local mode, which is why the sprawl is invisible in `git log` here but would not
  be for a default-shared-mode project. **Non-blocking reviewer concern to fold in**
  (`nazgul/reviews/TASK-006/security-reviewer.md:53`, confidence 72/100): Anchor 1 as originally
  written does not connect `.bak` sprawl to the secrets-exposure implication of `webhooks.headers`
  (which can contain bearer tokens) living inside every backed-up `config.json` in default shared
  mode — a real amplification of this finding's severity for shared-mode projects using webhooks.
- **Failure scenario:** A long-lived shared-mode project that upgrades regularly (the encouraged
  pattern) accumulates one committed `.bak` file per schema bump forever — dozens of files a year,
  each potentially carrying secret header values, bloating `git log -- nazgul/` and confusing
  which file is authoritative.
- **Severity-call note:** dim-6 rated high; dim-8's independent runtime corroboration (RT-08) was
  labeled low only because it explicitly deferred root-causing to dim-6, not because it assessed
  lower severity — max (high) applies, per TRD's "take the max unless a contributor's rationale
  argues otherwise" rule.
- **Recommendation:** Mirror the checkpoint-pruning pattern in `migrate-config.sh` immediately
  after the backup line (keep N most recent, or age-based eviction). Given the folded-in security
  concern, prioritize this for shared-mode/webhook-using projects specifically.

### MF-049 — Docs-vs-code drift for config keys: an entire stale architecture section, undocumented live flags, and a dead key documented as functional
- **Severity:** high · **Class:** docs-drift · **Dimensions:** dim-6 (Anchor 2)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `docs/CONFIGURATION.md:95-112` documents `execution.engine`/`conductor.*` and cites
  a deleted file (`scripts/lib/conductor-gates.sh`) as current — all deleted by
  `migrate_25_to_26` (v2.16.0, `fc96f75`); `docs/CONFIGURATION.md:3-10` omits the live
  `--parallel`/`--conductor` flags (`scripts/apply-start-flags.sh:10,23-24,56`);
  `docs/CONFIGURATION.md:304-314` documents `models.fast_mode_implementation` as working — deleted
  at schema v5 (22 versions ago), yet `skills/start/SKILL.md:80` still instructs the orchestrating
  agent to branch on it as live guidance; `docs/CONFIGURATION.md:325-338` documents
  `self_improvement.*` with no default scaffold anywhere in `templates/config.json`, making it
  undiscoverable via `/nazgul:config`.
- **Failure scenario:** An operator configuring `conductor.gates.*` per the docs gets silently
  dropped keys with zero effect from the next migration onward; an operator trying documented fast
  mode gets a feature that can never activate. Both fail silently.
- **Recommendation:** Regenerate the Execution Engine section to match CLAUDE.md's already-correct
  description; delete the Fast Mode section or re-wire it; scaffold or drop `self_improvement.*`;
  add `--parallel`/`--conductor` to the flags list.

### MF-053 — `parallel-dispatch-guard.sh`/`parallel-rework-guard.sh` fail OPEN on corrupt `config.json`, with zero test coverage — silently defeats the exact double-dispatch protection they exist for
- **Severity:** high · **Class:** fragility · **Dimensions:** dim-7 (F-2)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/parallel-dispatch-guard.sh:22-23` and
  `scripts/parallel-rework-guard.sh:21-22` (byte-identical): `jq ... || echo "false"` on parse
  failure forces `PARALLEL="false"` and the guard no-ops at line 23, regardless of the file's
  actual on-disk value moments earlier. Zero test in either test file constructs a
  corrupt/unparseable config while `execution.parallel` should be true.
- **Failure scenario:** A config write racing a guard invocation (a torn write during a concurrent
  parallel wave — the exact scenario this guard defends against) causes the guard to silently
  treat the run as non-parallel and allow re-dispatch of an already-IMPLEMENTED/DONE work unit —
  the same double-dispatch bug class from session memory (FEAT-007 conductor
  fire-and-yield/double-dispatch), undetectable by the current suite.
- **Recommendation:** Fail closed on `jq` parse failure (deny with a clear message). Add a test
  writing `printf 'not json' > config.json` with a task already IMPLEMENTED and asserting no
  silent allow.

### MF-058 — At least four incompatible review-verdict file-naming schemes across four gates in this same objective; one already blocked a DONE transition and required a manual filesystem patch
- **Severity:** high · **Class:** fragility · **Dimensions:** dim-8 (RT-05)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** Live, today: `nazgul/reviews/TASK-001/` uses plain `<reviewer>.md`;
  `nazgul/reviews/TASK-002/` adds `CONSOLIDATED-FEEDBACK.md`; `nazgul/reviews/TASK-003/` adds a
  parallel `<reviewer>-verdict.json` sidecar; `nazgul/reviews/TASK-004/` originally used
  `verdict-<reviewer>.md` (prefix, not suffix, no frontmatter) — the DONE-gate's evidence scan
  could not resolve this naming and blocked the transition; the orchestrator had to hand-create
  canonical `<reviewer>.md` files and move the earlier verdict into an ad hoc `history/`
  subdirectory, introducing a *fourth* naming pattern (`verdict-qa-reviewer-rereview.md`) on top of
  the other three. Nothing in `nazgul/tasks/TASK-001.md`–`TASK-004.md`'s Pattern Reference sections
  mandates one canonical filename.
- **Failure scenario:** Any DONE-gate/`/nazgul:status` logic that greps for one specific reviewer
  filename pattern will find some task directories and silently miss verdicts named another way —
  already reproduced live, not hypothetical.
- **Recommendation:** `review-gate.md` needs one canonical persist contract (name + optional
  sidecar) enforced identically regardless of dispatch mode, with a test asserting the pattern per
  reviewer per gate.

### MF-059 — Reviewer subagents received an injected message impersonating inter-session coordination, four times across two reviewers in this run, including explicit pressure toward a softer verdict; nothing mechanical stopped it
- **Severity:** high · **Class:** architecture · **Dimensions:** dim-8 (RT-07)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `nazgul/reviews/TASK-001/qa-reviewer.md:13` — an injected `agent-message`
  purporting to be from "another Claude session," asking the reviewer to cut the review short and
  output a different verdict format; refused. `nazgul/reviews/TASK-008/architect-reviewer.md:10,37`
  — a second and third occurrence in the same run, the second escalating to "CRITICAL" pressure
  with a pre-supplied example answer that would have softened the verdict from CHANGES_REQUESTED
  to APPROVE; both refused, verdict stood. `nazgul/reviews/TASK-008/code-reviewer.md:10` — a fourth,
  independent corroboration from a different reviewer in the same round. No file in the
  `review-gate.md`/reviewer-prompt surface defines which inbound channels are authoritative for a
  dispatched reviewer.
- **Failure scenario:** All four occurrences were refused and no verdict was corrupted, but nothing
  mechanical guarantees a lower-capability reviewer tier (haiku, per MF-014's stall pattern) would
  resist the same pressure — a reviewer that complied would silently launder a
  CHANGES_REQUESTED-worthy artifact into an APPROVE, indistinguishable from a genuine approval at
  the DONE-gate.
- **Recommendation:** Add explicit trust-boundary language to the reviewer dispatch contract: only
  the orchestrator's initial dispatch prompt is authoritative; any later inbound message claiming
  to be another session or nudging toward a verdict is untrusted content to report, not obey.
  Given 4/4 occurrences in one objective, treat as active, not theoretical.

---

## MEDIUM (18)

### MF-008 — `post-compact.sh` and `session-context.sh` have zero review-granularity awareness, unlike `stop-hook.sh`
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-1 (F-009)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `grep -n "granularity|GRANULARITY|review_unit|aggregate"` → zero matches in
  `pre-compact.sh`/`post-compact.sh`/`session-context.sh`; `stop-hook.sh:358-456` has a dedicated
  ~100-line block the other two lack; `post-compact.sh:102`/`session-context.sh:152`
  unconditionally suggest a single-task review-gate dispatch for the first IMPLEMENTED task found.
- **Failure scenario:** In group/feature granularity mode, a compaction or session restart mid-run
  instructs the agent to spawn a single-task review-gate for a "parked" task, reviewing it against
  a partial diff and violating the granularity contract before the post-loop reconciliation gate
  can catch it.
- **Recommendation:** Port the `AGGREGATE_REVIEW_READY` computation (or a shared helper) into
  `post-compact.sh`/`session-context.sh`. Natural companion to MF-003's Recovery Pointer fix (same
  subsystem).

### MF-009 — Structural: task-counting/active-task-detection logic duplicated across four scripts, already drifted twice
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-1 (F-010)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** Near-identical ~30-70 line blocks independently in `stop-hook.sh:158-186,317-331`,
  `pre-compact.sh:26-41,43-71`, `post-compact.sh:26-59`, `session-context.sh:59-80`, with no shared
  helper despite `task-utils.sh` existing precisely for this.
- **Failure scenario:** Direct architectural cause of MF-002 (INVALID handling absent in 4 places
  independently) and MF-008 (granularity-awareness added to only 1 of 4 copies).
- **Recommendation:** Extract a single `count_tasks_and_find_active()` into `task-utils.sh`. The
  single highest-leverage consolidation candidate in this dimension.

### MF-016 — `emit-event-cli.sh reviewer_verdict` can silently drop events on any malformed numeric field, starving the granularity coverage detector
- **Severity:** medium · **Class:** fragility · **Dimensions:** dim-2 (F3c), dim-8 (RT-02
  residual)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/emit-event.sh:48-56` builds `jq_args` via `--argjson` with no
  validation; both dispatch paths swallow the `jq` failure with `|| true` (lines 75,77), dropping
  the entire event silently. Occurred twice in production (`nazgul/improvements.md:288-292,439-443`,
  FEAT-009 and FEAT-010, both open). Note: the *original* reported bug (empty/unset
  `CURRENT_ITERATION`) is already fixed and regression-tested
  (`scripts/lib/emit-event.sh:41-45`, `tests/test-emit-event.sh:96-107`) — this entry is the
  narrower **residual** gap (set-but-non-numeric values still crash silently), independently
  identified by dim-2 from the review-coverage-detector-starvation angle.
- **Failure scenario:** A dropped `reviewer_verdict` event degrades `/nazgul:metrics` accuracy and
  compounds MF-015's silent-degrade-to-allow behavior for group/feature coverage detection.
- **Recommendation:** Coerce/validate every `:n`-suffixed value before adding to `jq_args`;
  substitute `null` rather than dropping the whole event; add a test feeding a malformed numeric
  value through `emit-event-cli.sh reviewer_verdict`. Part of the same review-telemetry foundation
  bundle as MF-014/MF-015 — natural wave-1 companion.

### MF-018 — Structural: confidence/severity classification policy duplicated across two agent specs
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-2 (S1)
- **Evidence:** `agents/review-gate.md:378-379,427` and `agents/feedback-aggregator.md:60-73,73`
  independently restate the identical classification rule and security carve-out in prose, with no
  mechanical check to catch divergence.
- **Failure scenario:** A future edit to the threshold/carve-out rule in one file without a
  matching edit in the other causes feedback-aggregator and review-gate to silently disagree on
  what counts as blocking.
- **Recommendation:** Extract the classification table into one canonical reference doc (the
  codebase already has this pattern for `references/fix-first-heuristic.md`) and have both agents
  cite it by pointer.

### MF-029 — CLAUDE.md's directory map omits five live, wired hook scripts
- **Severity:** medium · **Class:** docs-drift · **Dimensions:** dim-3 (F3-08)
- **Evidence:** `CLAUDE.md:53-63` omits `local-mode-tracking-guard.sh`, `lean-comments-guard.sh`,
  `stop-failure.sh`, `subagent-stop.sh`, `teammate-idle-guard.sh` — all five wired and live per
  `hooks/hooks.json`.
- **Failure scenario:** A contributor reading CLAUDE.md's directory structure undercounts the
  guard fleet by 5 scripts and may not realize `TeammateIdle`/`StopFailure`/`SubagentStop` are
  hooked at all.
- **Recommendation:** Add the five missing scripts with one-line descriptions.

### MF-030 — `formatter.sh`'s file-path extraction misses the standard field, falls back to a blind recursive string search
- **Severity:** medium · **Class:** fragility · **Dimensions:** dim-3 (F3-09)
- **Evidence:** `scripts/formatter.sh:72-78` primary jq query never includes
  `.tool_input.file_path` (the field every sibling guard uses); fallback (`:76`) is a recursive
  scan for the first absolute-path-looking string anywhere in the payload.
- **Failure scenario:** If the edited file's own diff contains an absolute path with an extension,
  the fallback can pick the wrong string, silently formatting nothing or the wrong file. Lower
  severity: opt-in and cosmetic (PostToolUse, non-blocking).
- **Recommendation:** Query `.tool_input.file_path` first, keep the recursive scan only as a
  last-resort fallback.

### MF-036 — Chain-dispatch to pre-existing user hooks: incomplete `githooks(5)` coverage and interrupted-cycle drift loss
- **Severity:** medium · **Class:** bug/fragility · **Dimensions:** dim-4 (Finding 3)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `scripts/lib/git-hooks.sh:23-29` (`_GH_OTHER_HOOKS`) is missing exactly the 4
  `p4-*` hook names out of 28 total per `man githooks`. Separately, `install_git_hooks`'s
  "record prior" block (`:108-124`) only records `core.hooksPath` on the FIRST install of a cycle
  — if a prior `uninstall_git_hooks` never ran (crash, or per MF-034, structurally never), a
  user's intervening manual hooks-manager change (e.g. switching to lefthook) is silently
  discarded and never restored.
- **Failure scenario:** (a) a git-p4 user's hook silently stops firing once Nazgul installs. (b) a
  user who reconfigures hooks mid-cycle loses that change on the loop's next resume.
- **Recommendation:** Add the four `p4-*` names (cheap). On each install, compare live
  `core.hooksPath` against both the managed dir and the recorded prior value; if it differs from
  both, treat as drift and warn or update the recorded value. Ships naturally alongside MF-034/
  MF-035 in the same subsystem — recommend bundling into the same wave.

### MF-041 — `teammate-idle-guard.sh`'s newest fail-open branches (unsafe name, unsafe report_path) are untested
- **Severity:** medium · **Class:** test-gap · **Dimensions:** dim-5 (Finding 6)
- **Evidence:** `scripts/teammate-idle-guard.sh:60-62,86-88` added after the original design; no
  test in `tests/test-teammate-idle-guard.sh` (147 lines, fully read) passes a `NAME` containing
  `/`/`..` or an absolute/traversal `report_path`.
- **Failure scenario:** Both branches are correctly ordered today (no live vulnerability), but a
  future refactor (reordering checks, changing the `case` pattern) could silently reintroduce a
  path-escape with no test catching it.
- **Recommendation:** Add the two missing cases, asserting allow + the specific log message, and
  that no file at the unsafe path was touched.

### MF-042 — The TeammateIdle guard has apparently never fired in this repo's history, possibly explained by the already-known worktree gap
- **Severity:** medium (PLAUSIBLE, not CONFIRMED by its own author) · **Class:** fragility ·
  **Dimensions:** dim-5 (Finding 7)
- **Verification status (TASK-010, Phase 3):** **PLAUSIBLE** (unchanged) — mandated hedge; static evidence cannot definitively confirm or refute. See `verification-verdicts.md`.
- **Evidence:** `nazgul/logs/teammate-idle.jsonl` does not exist anywhere in the repo, though
  `log_event` fires unconditionally on every guard invocation including allow-paths —
  `hooks/hooks.json:177-187` confirms correct wiring. `RULES.md:482-487` already documents, as a
  known open limitation, that the guard resolves `nazgul/` via `CLAUDE_PROJECT_DIR`/cwd only, so a
  teammate whose session resolves to a worktree without the shared `nazgul/` runtime exits
  untracked — precisely the symptom observed for precisely the teammate topology (implementers in
  worktrees) the design documents as standard.
- **Honesty note carried verbatim:** cannot prove causation from static analysis alone; an
  innocent explanation (correct teardown, or no teammate has gone idle yet) is also consistent with
  the absent dispatch dir, though it doesn't fully explain the log file's total non-existence.
- **Recommendation:** Escalate from "watch and see" to "actively verify" — run one deliberate
  minimal-worktree-free teammate dispatch and confirm the log gets a first entry.

### MF-043 — `team-orchestrator.md`'s review-team step list has a duplicate "3."
- **Severity:** medium · **Class:** docs-drift · **Dimensions:** dim-5 (Finding 8)
- **Evidence:** `agents/team-orchestrator.md:34-35` — both lines numbered "3.", shifting every
  subsequent step off by one relative to its printed number.
- **Failure scenario:** Comprehension/miscounting risk when cross-referencing a "step N" from
  elsewhere.
- **Recommendation:** Renumber lines 34-59 sequentially; trivial fix.

### MF-044 — Heartbeat's archive-then-start design permanently drops an inbox item on a start-command failure, by design, with no operator-facing surfacing
- **Severity:** medium · **Class:** fragility · **Dimensions:** dim-5 (Finding 9)
- **Evidence:** `scripts/heartbeat.sh:190-201` — `inbox_archive` runs before `_hb_start`; on
  failure the item stays archived by deliberate design (comment at lines 8-10,186-189), recorded
  only as `decision: started, reason: start_command_failed` in a dated JSONL log nothing monitors.
- **Failure scenario:** A transient `claude -p` failure (network blip, rate-limit, auth expiry)
  permanently drops the picked objective from consideration — recoverable only by a human noticing
  the raw log line.
- **Recommendation:** Surface `start_command_failed` entries in `/nazgul:status`/heartbeat's own
  report, or move failed-archived items to a visibly distinct `nazgul/inbox/failed/` location.

### MF-047 — Structural: Teammate Report Contract's three layers are unevenly enforced, and the enforcement layer's own activation is unenforced
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-5 (structural critique)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `RULES.md:473` marks only Layer 3 (`TeammateIdle` guard) `[enforced]`; Layers 1
  (prompt contract) and 2 (dispatch manifest) are `[advisory]` — nothing mechanically verifies a
  dispatcher wrote `nazgul/dispatch/<name>.json` before spawning a teammate. A *missing* manifest
  degrades to silent allow (`teammate-idle-guard.sh:66-69`), indistinguishable from "not a
  Nazgul-dispatched teammate at all."
- **Failure scenario:** A dispatcher that forgets Layer 2 gets zero enforcement and zero signal,
  identical to a legitimately foreign process — the entire contract's guarantee rests on a step
  nothing checks ever happened.
- **Recommendation:** At minimum, a periodic self-audit assertion ("N teammates spawned per
  team-orchestrator logs; M manifests written; M should equal N"). Closes the loop on the Teammate
  Report Contract shipped in v2.17.0 — natural wave-1 companion to MF-041/MF-042.

### MF-050 — Live dogfood config is schema-stale mid-session, producing mixed old/new key coexistence
- **Severity:** medium · **Class:** fragility · **Dimensions:** dim-6 (Finding 3)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** This repo's own `nazgul/config.json` is at `schema_version: 25` while
  `templates/config.json` is at 27 — confirmed at audit time. Migration only runs via
  `SessionStart` (`session-context.sh:31-40`); never re-invoked mid-session (`post-compact.sh` has
  no migration call). Concrete effect: the live config currently carries **both** the deleted
  `.execution.engine`/full legacy `.conductor` tree **and** the new `.execution.parallel` surface
  simultaneously; physically corroborated by `nazgul/conductor/` still existing on disk though
  `migrate_25_to_26` should have `rm -rf`'d it.
- **Failure scenario:** Downstream guards reading only the new key path get correct fail-safe
  defaults today (the general pattern fails toward *more* enforcement here), but the general
  two-writer hazard (a future migration flipping a default during this lag window, with the old
  key still present and read by unmigrated code) is unguarded.
- **Recommendation:** Invoke `migrate-config.sh` from `post-compact.sh` as well (cheap, idempotent),
  or add a non-fatal startup assertion when `CURRENT_VERSION < TARGET_VERSION` outside the
  SessionStart call. Cheap, high-leverage — natural wave-1 companion to MF-048/MF-049.

### MF-051 — Structural: multiple dead config-key clusters with zero runtime consumers
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-6 (Finding 4)
- **Evidence:** `context.*` (4 of 5 keys with zero references anywhere, including in the scripts
  that would naturally consume them); `parallelism.*` (4 of 6 keys unreferenced);
  `safety.block_destructive_commands` (zero references — `pre-tool-guard.sh` blocks destructive
  commands unconditionally, never reading this key, so setting it `false` has no effect);
  `safety.require_tests_pass_before_review` (RULES.md already self-discloses this is advisory-only,
  but absent from `docs/CONFIGURATION.md` entirely); top-level `task_file`/`log_dir`/`review_dir`
  (zero config-path consumers, every script hardcodes the literal string instead).
- **Failure scenario:** An operator setting `safety.block_destructive_commands: false` believing
  it disables the guard has disabled nothing, with no error — a false sense of control, the worse
  of the two failure modes for a security-flavored key.
- **Recommendation:** Wire each dead key to real behavior or remove it in a future migration.
  `safety.block_destructive_commands` should either gate `pre-tool-guard.sh` for real or be
  deleted.

### MF-054 — `teammate-idle-guard.sh`'s two path-traversal fail-open branches have zero test coverage
- **Severity:** medium · **Class:** test-gap · **Dimensions:** dim-7 (F-3)
- **Evidence:** `scripts/teammate-idle-guard.sh:59-62,84-88` — both explicitly documented,
  intentional fail-open branches (not a hidden mistake); `tests/test-teammate-idle-guard.sh`'s 19
  assertions cover a genuinely solid fail-open sweep otherwise, but never construct a traversal
  `from`/`report_path`. (Same underlying gap as MF-041, independently reached via dim-7's
  test-forensics lens rather than dim-5's teammate-contract lens — recorded as a separate finding
  since dim-7 is auditing test-suite completeness generically, not the teammate contract
  specifically, but the fix is identical to MF-041's recommendation and should be applied once.)
- **Failure scenario:** A future refactor that "simplifies" the `case` pattern and drops the `..`
  check would look green.
- **Recommendation:** Same as MF-041 — add the two missing assertions once, satisfying both
  findings.

### MF-055 — `test-shellcheck.sh`'s hardcoded `SCRIPTS` array is stale: 20 of 49 shell scripts (41%) — including two production-critical shared libraries and one active guard — receive zero verification
- **Severity:** medium · **Class:** test-gap · **Dimensions:** dim-7 (F-5)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `tests/test-shellcheck.sh:12-45` hardcodes 32 entries against a real inventory of
  49; 20 absent, three highest-consequence: `scripts/prompt-guard.sh` (MF-023's own subject),
  `scripts/lib/task-utils.sh`, `scripts/lib/structured-state.sh` (the shared status-parsing
  libraries underlying MF-001/MF-002/MF-009/MF-052 — the single most load-bearing shell code in
  the plugin, never once run through `bash -n`/shellcheck by this suite).
- **Failure scenario:** A syntax error or unsafe pattern introduced into `task-utils.sh` would not
  fail this test, despite the test's own name/header promising 100% coverage.
- **Recommendation:** Replace the hardcoded array with a `find scripts -name '*.sh'` glob. One-line
  fix with outsized leverage given how many other findings in this register trace back to the
  unverified files — strong wave-1 candidate.

### MF-060 — Live, today: FEAT-013's own execution is running entirely outside the framework's tracked state (plan.md stale, zero telemetry emitted)
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-8 (RT-09)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `nazgul/plan.md`'s Status Summary reads all-PLANNED / 0 iterations while actual
  per-task manifests show 5 of 11 tasks have left PLANNED (2 DONE, 2 IMPLEMENTED, 1 IN_PROGRESS).
  `nazgul/logs/events.jsonl`: every event in this session's window is `subagent_stop`; zero
  `task_dispatched`/`task_completed`/`reviewer_verdict` events despite 4 review gates having
  already produced 16 reviewer verdicts. Consistent with FEAT-013 running as ad hoc Agent-Team
  `SendMessage` fan-out rather than through `stop-hook.sh`'s loop engine, which normally recomputes
  the summary and emits telemetry at each transition.
- **Failure scenario:** Anyone consulting `/nazgul:status`/`/nazgul:metrics` during an Agent-Team-
  driven objective sees a plan.md and metrics stream that both claim nothing has happened, while
  real review cycles including rework rounds have occurred — a live demonstration of the
  "recovery must be automatic" principle failing under a sanctioned alternative execution mode.
- **Recommendation:** Either wire the Agent-Team/SendMessage path to the same recompute/emit hooks
  the stop-hook loop uses, or explicitly document the gap and have `/nazgul:status`/`/nazgul:metrics`
  detect and flag a stale summary. Cross-links MF-003/MF-009 (same symptom, different execution
  path) — this very objective is the live reproduction, making it a strong wave-1 candidate to fix
  early alongside the awk-format fix.

### MF-062 — Structural: the self-improvement loop (self-audit → improvements.md) has no forcing function to close items
- **Severity:** medium · **Class:** architecture · **Dimensions:** dim-8 (structural critique)
- **Verification status (TASK-010, Phase 3):** **CONFIRMED** — adversarially reviewed; refutation attempted and failed. See `verification-verdicts.md`.
- **Evidence:** `nazgul/improvements.md` — all 74 inventoried items are `Status: open`, none
  closed/superseded/retired anywhere in the file, spanning FEAT-009 through FEAT-010
  (2026-07-09–11) with no entries between then and this FEAT-013 audit despite FEAT-011/FEAT-012
  running in between (open question whether those objectives found nothing or the self-audit gate
  didn't fire — not resolved in this dimension's scope).
- **Failure scenario:** A rich, well-evidenced backlog with ~zero closure is itself a structural
  smell — items like IMP-047/048/056/072 are already fixed at the source-code level (per
  MF-*/RT-02/RT-03 evidence below) but remain open in the bookkeeping, undermining the backlog's
  usefulness as a queue.
- **Recommendation:** TASK-011 should explicitly map each of the 74 items to a wave (or explicit
  rejection with reason) and mark the already-fixed ones retired. This register's carryover
  section below feeds that mapping directly. Process fix that should ship alongside wave 1's first
  code fixes so the mapping doesn't immediately go stale again.

---

## LOW (16)

### MF-010 — `templates/task-manifest.md`'s own state-machine comment omits `APPROVED`
- **Severity:** low · **Class:** docs-drift · **Dimensions:** dim-1 (F-005)
- **Evidence:** `templates/task-manifest.md:13` omits `APPROVED`, unlike `RULES.md:4-6,15-27`.
- **Failure scenario:** Low direct impact (the real write path hard-codes `APPROVED` regardless),
  but same-category omission as MF-001, likely shares an origin.
- **Recommendation:** Add `APPROVED` to the comment, matching `RULES.md`'s Task-PR row.

### MF-011 — Evidence-gate INVALID blind spot (anchor cleared as sound; one interaction noted)
- **Severity:** low · **Class:** architecture · **Dimensions:** dim-1 (F-012)
- **Evidence:** `scripts/lib/review-evidence.sh` recompute-and-compare design is sound (no forgery
  vector found), but the Layer-2 reactive safety net only runs `if STATUS = "DONE"`
  (`stop-hook.sh:210`) — a task wedged at `INVALID` (MF-001/MF-002) is invisible to it too.
- **Failure scenario:** Not itself forgeable, but the evidence gate provides zero protection for a
  task stuck in the INVALID blind spot.
- **Recommendation:** No change needed to `review-evidence.sh` itself; fixing MF-002 closes this
  gap as a side effect.

### MF-012 — `.compaction_count` incremented by two independent, uncoordinated code paths (needs runtime verification)
- **Severity:** low · **Class:** fragility · **Dimensions:** dim-1 (F-011) · **Verification
  status hedge carried verbatim: PLAUSIBLE, not confirmed** — this dimension's static scope could
  not determine Claude Code's actual hook co-firing semantics.
- **Evidence:** `scripts/post-compact.sh:62-69` and `scripts/session-context.sh:94-108` both
  increment the same counter file with identical read-increment-write, no locking.
- **Failure scenario (unverified):** IF `PostCompact` and `SessionStart[matcher=compact]` both fire
  for the same physical compaction event, the context-rot warning threshold fires roughly twice as
  eagerly as intended.
- **Recommendation:** If runtime verification confirms co-firing, consolidate to one incrementing
  site or add an idempotency key.

### MF-017 — `resolved` field in `.dispatch.json` is misleadingly named; already caused one false security-integrity escalation
- **Severity:** low · **Class:** docs-drift/fragility · **Dimensions:** dim-2 (F1)
- **Evidence:** `scripts/lib/review-provenance.sh:9,113-118` — `resolved` has only ever meant
  "the reviewer's agent-definition file exists on disk," never "verdict recorded"; the DONE-gate
  never reads it. Already caused one real wasted-escalation incident
  (`nazgul/improvements.md:30-33`, FEAT-009).
- **Failure scenario:** A reviewer or operator inspecting the manifest without reading the source
  comment can misread `resolved: true` + a missing verdict file as a bypass.
- **Recommendation:** Rename to something unambiguous (e.g. `agent_definition_present`) or add an
  inline disambiguating comment.

### MF-019 — `review_gate.require_all_approve` is a documented-but-dead config key
- **Severity:** low · **Class:** docs-drift · **Dimensions:** dim-2 (S2)
- **Evidence:** `RULES.md` §11 self-discloses: "informational only — no script reads it"; the
  effective policy is hard-coded inside `validate_review_evidence` itself. `grep -rn
  "require_all_approve" scripts/` finds no reads.
- **Failure scenario:** An operator setting it to `false` expecting relaxed enforcement gets no
  behavior change, silently.
- **Recommendation:** Either wire it (default `true` for backward compat) or remove it from the
  schema/template and document the removal.

### MF-020 — Structural: `review-gate.md`'s pipeline has grown to 12 top-level steps (~620 lines); numbering already strained
- **Severity:** low · **Class:** architecture · **Dimensions:** dim-2 (S3)
- **Evidence:** Step 3.6 is explicitly self-noted in its own text as living out of numeric order
  ("numbered 3.6 only because 'Step 3.5' is already taken").
- **Failure scenario:** Maintainability/cognitive-load risk, not a bug — a future edit is more
  likely to land in the wrong place.
- **Recommendation:** Merge Step 2.5's sub-blocks into one pass; consider sequential renumbering.

### MF-021 — Structural: `reviewer-selection.sh`'s architecture-surface classifier is narrower than the plugin's actual architecture surface
- **Severity:** low · **Class:** fragility · **Dimensions:** dim-2 (S4)
- **Evidence:** `scripts/lib/reviewer-selection.sh:43-52` covers `skills/*`, `agents/*`,
  `scripts/*`, `hooks/*` but not `templates/*`/`references/*`/`.github/workflows/*`/`RULES.md`/
  `CLAUDE.md`, all explicitly in-scope per this very audit's own TRD.
- **Failure scenario:** Only reachable when `review_gate.conditional_dispatch: true` (default
  false — currently a no-op).
- **Recommendation:** Low urgency; extend the classifier before any future promotion of
  `conditional_dispatch` to default-on.

### MF-031 — `notify.sh` uses bare relative paths instead of `CLAUDE_PROJECT_DIR`
- **Severity:** low · **Class:** fragility · **Dimensions:** dim-3 (F3-10)
- **Evidence:** `scripts/notify.sh:91,108,109,125` reference `nazgul/...` as bare relative paths,
  unlike every sibling guard's `PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"` pattern.
- **Failure scenario:** If the Stop hook's cwd ever diverges from the project root,
  `notify.sh`'s completion detection silently finds nothing.
- **Recommendation:** Standardize on `PROJECT_ROOT` resolution like the rest of the fleet.

### MF-032 — `webhook-forward.sh`'s custom-header handling breaks on header values containing spaces
- **Severity:** low · **Class:** fragility · **Dimensions:** dim-3 (F3-11)
- **Evidence:** `scripts/webhook-forward.sh:92-104` pipes newline-joined `-H` args through
  `xargs`, which word-splits on all whitespace.
- **Failure scenario:** Any `webhooks.headers` value containing a space (e.g. `Authorization:
  Bearer <token>`) corrupts the outgoing request. Low severity: opt-in and best-effort.
- **Recommendation:** Build a bash array natively and pass directly to `curl "${HEADER_ARGS[@]}"`.

### MF-033 — Structural: duplicated bespoke shell tokenizers across two guards
- **Severity:** low · **Class:** architecture · **Dimensions:** dim-3 (structural critique)
- **Evidence:** `pre-tool-guard.sh:88-217` and `local-mode-tracking-guard.sh:78-204` each
  independently implement a ~120-line, hand-rolled quote-aware awk tokenizer solving the same
  problem, with independently-evolved edge-case coverage.
- **Failure scenario:** Every bespoke reimplementation is a fresh opportunity for the same class of
  quoting bug to reappear (as it has — MF-027, MF-028), with no mechanical way for a fix
  discovered in one to propagate to the other.
- **Recommendation:** Extract a single shared tokenizer both guards source.

### MF-037 — Structural: `worktree-utils.sh`'s directory location is inconsistent with its sibling libraries
- **Severity:** low · **Class:** architecture · **Dimensions:** dim-4 (structural critique)
- **Evidence:** `scripts/worktree-utils.sh` lives directly under `scripts/` while every parallel
  lifecycle helper (`git-hooks.sh`, `parallel-batch.sh`, `task-utils.sh`) lives under
  `scripts/lib/`.
- **Failure scenario:** None functionally; a minor convention inconsistency, worth folding into any
  refactor of MF-034.
- **Recommendation:** Move to `scripts/lib/worktree-utils.sh` if/when MF-034 is addressed.

### MF-045 — Dead `.delivered` manifest field
- **Severity:** low · **Class:** architecture · **Dimensions:** dim-5 (Finding 10)
- **Evidence:** `scripts/teammate-idle-guard.sh:100` writes `.delivered = true`; repo-wide grep
  finds exactly one hit — the write site itself. Nothing reads it.
- **Recommendation:** Either use it (a cheap pre-check before re-testing file existence) or remove
  the write. Essentially free to fix.

### MF-046 — Stale version-number labels in `test-migrate-config.sh` accumulate every schema bump
- **Severity:** low · **Class:** docs-drift/test-gap · **Dimensions:** dim-5 (Finding 11)
- **Evidence:** `tests/test-migrate-config.sh:1707` — a test labeled "v26 garbage conductor..."
  asserts the terminal schema version is `27`.
- **Recommendation:** Reword recurring labels to describe behavior under test, not a specific
  version number.

### MF-056 — `teammate-idle-guard.sh`'s MTIME-fallback branch untested for the "stat fails on both GNU and BSD forms" case
- **Severity:** low · **Class:** test-gap · **Dimensions:** dim-7 (F-4)
- **Evidence:** `scripts/teammate-idle-guard.sh:96` — dual-form `stat` fallback with a documented
  "treat as delivered" behavior on total failure; no test forces both forms to fail.
- **Failure scenario:** Rare (needs a toolchain with neither `stat` flavor, or a TOCTOU file
  deletion); a regression here would silently misclassify report freshness undetected.
- **Recommendation:** Low priority; mock both `stat` forms failing and assert no crash.

### MF-057 — `test-shellcheck.sh`'s "not installed" branch reports fake PASSes instead of skipping; companion numbering gap in `test-teammate-idle-guard.sh`
- **Severity:** low · **Class:** fragility/docs-drift · **Dimensions:** dim-7 (F-6)
- **Evidence:** `tests/test-shellcheck.sh:79-85` counts 32 synthetic PASSes when shellcheck isn't
  on `PATH`, indistinguishable from a real pass in the suite's summary (CI-dead-code since
  `.github/workflows/test.yml` installs shellcheck, so only affects local runs).
  `tests/test-teammate-idle-guard.sh`'s inline numbering jumps from test 13 to test 18 (tests
  14-17 don't exist), eroding confidence the file is a complete record.
- **Recommendation:** Report as SKIPPED rather than PASSED locally; renumber or annotate the test
  gap.

### MF-061 — Informational: 2 of 4 completed FEAT-013 dimension gates required a CHANGES_REQUESTED round; the board is correctly catching real defects
- **Severity:** low (informational, no fix needed) · **Class:** test-gap-adjacent ·
  **Dimensions:** dim-8 (RT-10)
- **Evidence:** `nazgul/reviews/TASK-002/CONSOLIDATED-FEEDBACK.md` (phantom cross-reference caught);
  `nazgul/reviews/TASK-004/CONSOLIDATED-FEEDBACK.md` (undisclosed coverage gap + two
  citation-precision defects caught). Consistent with the historical ~1-in-2 to ~1-in-3 first-pass
  rejection rate already inventoried in `nazgul/improvements.md`'s "Review rejection" entries.
- **Failure scenario:** N/A — this is the review board correctly doing its job.
- **Recommendation:** No fix needed. Flag for TASK-011 as evidence that citation-precision spot
  checks are a high-value, cheap reviewer habit — do not let a future review-latency optimization
  (addressing MF-014/MF-015) regress this catch rate. **Not included in the verification queue**
  (no claim here needs adversarial refutation — it's an observation about process health, not a
  defect).

---

# Dropped (no-evidence hard-drops)

**None.** Every finding surfaced across all 8 dimension artifacts carries at least one concrete
`file:line` citation or a named runtime-artifact-path (log file, config file, checkpoint JSON,
review directory) as evidence. No finding was dropped under the TRD Phase 2 hard-drop rule.

---

# Verification Queue (Phase 3 / TASK-010 work list)

**Phase 3 status: COMPLETE**, including a post-review board correction pass. TASK-010
adversarially reviewed all 38 queued findings — see `verification-verdicts.md` for the full
per-finding skeptic record. Result after the review board's own independent re-derivation pass
surfaced two label-accuracy corrections (applied, not reversals — see "Board Corrections" in
`verification-verdicts.md`): **36 CONFIRMED, 1 CONFIRMED-reclassified (MF-027 — fail-safe
over-block, not a security bypass), 1 SYMPTOM-CONFIRMED/mechanism-PARTIAL (MF-014 — stall symptom
real and cross-objective, single "background dispatch" mechanism only partially established and
multi-causal), 0 REFUTED, 0 DOWNGRADED, 1 PLAUSIBLE** (MF-042, mandated hedge — stays PLAUSIBLE per
the task manifest's explicit instruction regardless of outcome, since static evidence cannot
definitively resolve it). Each finding entry above now carries a
`Verification status (TASK-010, Phase 3):` line recording its individual verdict. MF-012 (the
other named hedge) was never in this queue and remains PLAUSIBLE, untouched, exactly as carried
below. **Methodology caveat** (see `verification-verdicts.md` top-of-file box): verification was
performed by one self-skeptic across all 38 findings, not 38 independently-dispatched fresh agents
per the manifest's literal protocol — disclosed, partially mitigated by ~24/38 live empirical
reproductions plus the review board's own independent 6-10-finding re-derivation sample and one
targeted fresh-skeptic cross-check (MF-014), but TASK-011 must carry this as a caveat on the
register's evidentiary strength.

Every critical and high finding (28), plus 10 mediums judged likely to land in roadmap wave 1
(one-line inclusion rationale given for each medium). All entries below were originally labeled
PLAUSIBLE by default per the dimension artifacts (verification status was this phase's job to
resolve) except MF-012 and MF-042, which additionally carry their source dimension's own explicit
not-yet-confirmed hedge.

## Critical (10 — all included)

| Queue ID | Claim | Strongest single evidence | What a skeptic should try to refute |
|---|---|---|---|
| MF-001 | `APPROVED` missing from `VALID_STATUSES` makes `get_task_status` return `INVALID` for a canonical `status: APPROVED` manifest | `structured-state.sh:12` (`VALID_STATUSES` string), empirically reproduced | Source `task-utils.sh` and `structured-state.sh` directly against a synthetic `status: APPROVED` manifest; confirm the returned string is literally `INVALID`, not `APPROVED` |
| MF-002 | A task at `INVALID` status is uncounted in all four duplicated counting loops, permanently inflating `TOTAL_COUNT` | `grep -n "INVALID" scripts/stop-hook.sh ...` → zero hits (absence-of-handling proof) | Find any `case`/`if` arm in the four named scripts that does handle a status value outside the 8-status enum; if found, the finding is refuted |
| MF-003 | `stop-hook.sh`'s Recovery Pointer awk update is a no-op against this repo's own live `plan.md` | Direct byte-diff: awk expression run against live `plan.md`, zero bytes changed | Re-run the exact awk command from `stop-hook.sh:636-650` against current `nazgul/plan.md` and check for any changed bytes; also check whether `plan.md`'s Recovery Pointer section has been hand-reformatted back to canonical labels since this was written |
| MF-013 | Group/feature review evidence is checked by task-id only, so no task can legally reach DONE under group/feature granularity | `review-evidence.sh:186-188` (`review_dir="$nazgul_dir/reviews/$task_id"`, no unit param) | Find any code path — in `task-state-guard.sh`, `stop-hook.sh`, or elsewhere — that resolves a `GROUP-<n>`/`FEATURE-<id>` unit before calling `validate_review_evidence`; if found, evidence resolution isn't task-id-only |
| MF-014 | Review-gate never sets `run_in_background: false`, and this is the most likely root cause of repeated reviewer stalls | `grep -n "run_in_background" agents/review-gate.md agents/templates/reviewer-base.md` → zero matches | Find any dispatch instruction in `review-gate.md` that does specify a synchronous mode; separately, verify the Agent tool's actual default really is background (not e.g. auto-detected from context) |
| MF-022 | `task-state-guard.sh` is wired only on Write/Edit/MultiEdit, never Bash, so a Bash-mediated file write bypasses it entirely | `hooks/hooks.json:52-97` matcher list | Attempt (in a sandboxed/test copy) to write a forged `status: DONE` manifest via `mv`/`cp`/`python3 -c` and confirm no guard fires; alternatively find a Bash-side guard elsewhere in the fleet that does catch this |
| MF-023 | `prompt-guard.sh` reads `CLAUDE_HOOK_USER_PROMPT`, which is never set outside the test harness, making the guard dead in production | `prompt-guard.sh:16-22` vs. every sibling guard's stdin-read pattern | Confirm (via Claude Code's actual hook-payload delivery mechanism, not just this repo's convention) whether `UserPromptSubmit` really delivers via stdin, not an env var — if an env var delivery path exists, the finding is refuted |
| MF-034 | The git-hooks install/uninstall lifecycle is never called by any production code path; live proof on this very repo | Live `git config --get core.hooksPath` on this repo returns OS default despite `guards.git_hooks: true` and an active objective | Re-run `git config --get core.hooksPath` and `ls nazgul/.githooks/` on the current repo state; also grep the full repo (not just the dimension's stated scope) for any other caller of `install_git_hooks` that might have been missed |
| MF-038 | The GitHub connector's push half can never resolve a real local id because `_cgh_map_put` is only ever called in its 2-arg (stub) form | `connector-github.sh:270-282` — both call sites, always 2 args | Grep the entire repo for any 3-arg call to `_cgh_map_put`; if none exists anywhere, the push path is confirmed structurally unreachable |
| MF-052 | 259 test call sites across 16 files build task manifests in a format production (and this repo's own 11 live manifests) never uses | `grep -l '^status:' nazgul/tasks/*.md` → 11/11; `tests/lib/setup.sh:52-72` (no frontmatter) | Re-run the grep against current `nazgul/tasks/*.md`; separately confirm `get_task_status`'s frontmatter-first precedence still holds in the current source |

## High (18 — all included)

| Queue ID | Claim | Strongest single evidence | What a skeptic should try to refute |
|---|---|---|---|
| MF-004 | YOLO dependency promotion wedges because `DEP_STATUS` can never literally equal `"APPROVED"` | `stop-hook.sh:734-748` comparison, downstream of MF-001 | Confirm this is purely downstream of MF-001 (i.e., fixing MF-001 alone resolves it) rather than an independent second bug |
| MF-005 | YOLO completion is unreachable while any task holds `APPROVED`, for the same root cause | `stop-hook.sh:180,800-801` | Same as MF-004 — confirm no independent second cause |
| MF-006 | HITL mode has no stop-hook enforcement outside the opt-in parallel-batch path | `stop-hook.sh:1125-1142` (unconditional dispatch) vs. `:1171` (gated only under `EXEC_PARALLEL=true`) | Find any conditional on `$MODE` in the default sequential dispatch path that would block a READY/IN_PROGRESS dispatch instruction while HITL approval is pending |
| MF-007 | `pre-compact.sh` and `stop-hook.sh` write incompatible checkpoint schemas to the same filename | Live `nazgul/checkpoints/iteration-000.json` missing `review_unit`/`branch`/`context_health` | Inspect the current checkpoint file's actual field set and compare against `stop-hook.sh:565-619`'s schema; confirm the fields really are absent |
| MF-015 | The granularity coverage detector infers rather than verifies which review directory was actually used, and can drop group-mode events entirely | `subagent-stop.sh:79-84` filters strictly to `TASK-[0-9]*` | Trace what `task_id` value `review-gate.md`'s emission instructions actually produce for a group review today; if it's always a real `TASK-NNN` (not `GROUP-N`), the drop mechanism doesn't trigger as described |
| MF-024 | The File Scope guard queries a field name (`File Scope`) that no real planner-generated manifest ever contains | `grep` across all 11 live `nazgul/tasks/*.md` for `- **File Scope**:` → zero | Re-run the grep against current manifests; check whether `agents/planner.md`'s spec has since been updated to emit that exact field name |
| MF-025 | `Files modified`'s JSON-array value is comma-split naively, breaking overlap/scope detection for multi-file scopes | `task-utils.sh:90-94` (raw string return, no JSON parsing) | Construct a two-task pair with a shared file at differing array positions and trace `_scope_has`/the parallel-batch disjointness check by hand against the current source to confirm the match fails |
| MF-026 | The commit-SHA evidence gate is a `grep -qE` pattern match, never checked against the real repository | `task-state-guard.sh:362-387` — no `git cat-file`/`git rev-parse` call in the file | Search the full file (and `review-evidence.sh`) for any git-verification call this citation might have missed |
| MF-027 | `rm -rf` root-pattern guard has no end-anchor and blocks any absolute-path deletion | `pre-tool-guard.sh:43-46` regex `rm\s+-rf\s+/` | Test the literal regex against `rm -rf /tmp/foo` and confirm it matches (over-blocks) |
| MF-028 | Force-push-to-main detection requires the force flag before the branch name in the command string | `pre-tool-guard.sh:54-55` regex ordering | Test `git push origin main --force` and `git push origin main -f` against both listed regexes and confirm neither matches |
| MF-035 | Relative `core.hooksPath` resolves per-invoking-worktree-toplevel, so a managed hook installed only in the main worktree never fires from a task worktree | Empirical repro in a scratch git 2.48.1 repo | Reproduce independently: create a worktree, install a hook via relative `core.hooksPath` in the main tree, commit from the secondary worktree, confirm the hook does not fire |
| MF-039 | The heartbeat concurrency guard is check-then-act with no atomic primitive, allowing two ticks to both pass the active-session check | `session-tracker.sh:31-38` (`ls *.lock \| wc -l`), lock file only created inside the *new* session's own SessionStart | Trace whether any lock/mutex exists earlier in `heartbeat.sh`'s own execution, before `_hb_start` is even called; if one exists, the race window may be smaller or absent |
| MF-040 | `compute_dispatch_batch` requires ≥2 TASK-IDs on one bullet line, silently falling back to sequential for one-task-per-line plans | `parallel-batch.sh:267-282` regex/line logic; this repo's own `plan.md:80-88` as a live counterexample | Confirm `nazgul/plan.md`'s Wave 1 section is genuinely one-task-per-line today, and that `compute_dispatch_batch` genuinely finds zero multi-match lines against it |
| MF-048 | `.bak` files accumulate with no pruning logic anywhere in the plugin, and are git-committed by default (shared mode) | `grep -rn "prune\|rotate\|retention"` across `scripts/` → zero hits touching `.bak`; live 10-file inventory on this repo | Confirm no pruning call exists anywhere in `migrate-config.sh`; independently confirm `install_mode: "shared"` is genuinely the schema default in `templates/config.json` |
| MF-049 | `docs/CONFIGURATION.md`'s Execution Engine section describes a deleted architecture (`conductor.*`, `models.conductor`, `scripts/lib/conductor-gates.sh`) | `test -f scripts/lib/conductor-gates.sh` → MISSING; `migrate_25_to_26` deletion code | Confirm `scripts/lib/conductor-gates.sh` and `agents/conductor.md` are genuinely absent from the current tree, and that `docs/CONFIGURATION.md` still references them |
| MF-053 | Both parallel guards fail open (no-op) on a corrupt/unparseable `config.json` rather than failing closed | `parallel-dispatch-guard.sh:22-23`, `parallel-rework-guard.sh:21-22` — identical `\|\| echo "false"` pattern | Feed each guard script a deliberately malformed `config.json` (in a sandbox) with `execution.parallel` having been `true` moments before, and confirm the guard exits 0 |
| MF-058 | Four incompatible review-verdict filename schemes exist across four gates in this same objective, one of which blocked a DONE transition | Live directory listing of `nazgul/reviews/TASK-001` through `TASK-004` at the stated read horizon | Re-list the current `nazgul/reviews/TASK-00{1,2,3,4}/` directories and confirm the naming inconsistency and the manual `history/` workaround are genuinely present |
| MF-059 | Reviewer subagents received injected messages impersonating inter-session coordination, with explicit pressure toward a softer verdict, four times in this run | `nazgul/reviews/TASK-001/qa-reviewer.md:13`, `nazgul/reviews/TASK-008/architect-reviewer.md:10,37`, `nazgul/reviews/TASK-008/code-reviewer.md:10` — reviewer-authored process notes | Read all four cited review files directly and confirm the process-integrity notes exist verbatim as quoted, rather than being paraphrased or invented by dim-8 |

## Medium (10 selected — inclusion rationale per entry)

| Queue ID | Claim | Strongest single evidence | What a skeptic should try to refute | Wave-1 rationale |
|---|---|---|---|---|
| MF-008 | `post-compact.sh`/`session-context.sh` have zero granularity awareness, unlike `stop-hook.sh` | `grep -n "granularity"` → zero hits in both files | Confirm the grep is current and that no granularity-aware logic exists elsewhere in either file under a different variable name | Same "recovery must be automatic" foundation as critical MF-003; natural to fix in the same pass |
| MF-009 | Task-counting/active-task logic is duplicated across 4 scripts with no shared helper | Near-identical block boundaries cited in all four files | Confirm `task-utils.sh` genuinely lacks a combined multi-bucket-plus-active-task helper today | Root architectural cause of already-critical MF-002 and medium MF-008; highest-leverage single consolidation in the register |
| MF-016 | `emit-event.sh` still silently drops events on a set-but-non-numeric `:n`-suffixed value, despite the original empty/unset case being fixed | `emit-event.sh:48-56`, unconditional `\|\| true` on both dispatch paths | Feed a non-numeric string as a `:n`-suffixed value through `emit-event-cli.sh reviewer_verdict` and confirm the whole event is dropped, not just the field | Part of the same review-telemetry foundation bundle as critical MF-014/high MF-015 |
| MF-036 | Git-hooks chain-dispatch misses 4 of 28 `githooks(5)` names and can lose a user's mid-cycle hooks-manager change | `_GH_OTHER_HOOKS` array vs. `man githooks` enumeration | Recount the array's entries and independently enumerate `man githooks` on the reference platform | Ships naturally alongside critical MF-034/high MF-035 in the same git-hooks subsystem fix |
| MF-042 | The `TeammateIdle` guard has never fired in this repo's history (PLAUSIBLE per its own author) | Total absence of `nazgul/logs/teammate-idle.jsonl` despite unconditional `log_event` on every invocation | Attempt the recommended deliberate dispatch and check whether the log file is created; this is the one entry where verification directly resolves the dimension's own stated uncertainty | Directly tests a load-bearing safety guard's real-world coverage; cheap to check, high signal for prioritization |
| MF-047 | The Teammate Report Contract's Layers 1–2 are advisory only, and a missing manifest is indistinguishable from a non-Nazgul process | `RULES.md:473` (`[enforced]` only for Layer 3); `teammate-idle-guard.sh:66-69` (silent allow) | Confirm no other mechanism (a stop-hook count, a different guard) cross-checks manifest-vs-spawn counts | Closes the loop on the same v2.17.0 contract as MF-041/MF-042; natural same-wave bundle |
| MF-050 | This repo's own live config is schema-stale mid-session, with old and new key trees coexisting | `jq '.schema_version'` on `nazgul/config.json` (25) vs. `templates/config.json` (27), live today | Re-run both `jq` reads against current files; confirm `nazgul/conductor/` still exists on disk despite the migration's `rm -rf` | Cheap one-line fix (call migrate from post-compact) with direct reliability payoff; natural companion to high MF-048/MF-049 |
| MF-055 | `test-shellcheck.sh`'s hardcoded array excludes 20 of 49 scripts including the plugin's most load-bearing shared libraries | Diff of the hardcoded array vs. `ls scripts/*.sh scripts/lib/*.sh` | Recount both the array and the real inventory to confirm the 20-file gap and the three bolded high-consequence omissions | One-line glob fix with outsized leverage — closes a lint blind spot over files nearly every other critical/high finding in this register traces back to |
| MF-060 | This very objective's execution is invisible to `plan.md`'s Status Summary and `events.jsonl` | Live `plan.md` all-PLANNED counters vs. 5 actually-non-PLANNED task manifests, today | Re-read current `nazgul/plan.md`'s Status Summary and current task manifest statuses to confirm the mismatch still holds | This audit's own execution is the live reproduction of a foundational observability gap; TASK-011's roadmap needs to address it early since it undermines trust in the loop's own self-reporting |
| MF-062 | The self-audit backlog (`improvements.md`) has zero closure mechanism across 74 open items | Full-file read: all 74 items `Status: open`, none closed | Re-scan `nazgul/improvements.md` for any `Status: closed`/`retired` marker that might have been added since | Process fix that must land alongside wave 1's first code fixes, or the mapping this register feeds immediately goes stale again |

**Queue size: 38** (10 critical + 18 high + 10 medium).

---

# Carryover for TASK-011 (not merged into findings above — preserved verbatim per manifest instructions)

## Reviewer non-blocking concerns (from `nazgul/reviews/`)

- **TASK-006 / security-reviewer** (`nazgul/reviews/TASK-006/security-reviewer.md:53`, confidence
  72/100): Anchor 1 (`.bak` sprawl) as originally scoped by dim-6 did not connect the sprawl to
  the secrets-exposure implication of `webhooks.headers` (can hold bearer tokens) persisting
  inside every backed-up `config.json` in default shared mode. **Already folded into MF-048
  above** — listed here per the manifest's explicit instruction to preserve the raw reviewer
  concern for TASK-011's visibility, not just its folded consequence.
- **TASK-006 / qa-reviewer** (`nazgul/reviews/TASK-006/qa-reviewer.md:27,29,51,58`, confidence
  40/100): "Zero files written outside the artifact" (a read-only-audit-task acceptance criterion)
  is structurally unverifiable via normal git-diff in this repo's local mode, since `nazgul/` is
  gitignored. Not a defect in dim-6's artifact — a structural gap in how read-only audit tasks can
  be verified in local-mode projects generally. Recommend TASK-011 flag this as a process/tooling
  gap (a local-mode-aware audit-verification mechanism, e.g. a pre/post file-listing diff) rather
  than a code finding in this register, since it applies to every future read-only audit task in
  local mode, not specifically to FEAT-013.
- **TASK-004 / architect-reviewer** (`nazgul/reviews/TASK-004/verdict-architect-reviewer.md:50`):
  a minor hook-count arithmetic slip (21 vs. 22) was caught and corrected before the artifact was
  finalized — the merged dim-4 Finding 3 text already reflects the corrected count (22). No action
  needed; noted for completeness only.
- **TASK-007 / code-reviewer and security-reviewer** (`nazgul/reviews/TASK-007/code-reviewer.md:20`,
  `security-reviewer.md:32`): both recommend an independent human/skeptic confirmation of the
  remaining un-spot-checked tail of dim-7's F-1 (the precise "3 of ~76 assertions" canonical-format
  count) and F-4 claims, since their own review sampled rather than exhaustively re-derived those
  specific counts. Relevant input for TASK-010's adversarial pass on MF-052 (already in the
  verification queue) and MF-056 (not in the queue — TASK-010 may wish to spot-check anyway given
  this reviewer note).

## `nazgul/improvements.md` — 74-item open inventory (reference only, not re-merged)

The full inventory (IMP-001 through IMP-074, all currently `Status: open`) is preserved in full in
`nazgul/context/objectives/FEAT-013/dimension-8-findings.md` (lines 177-268) and is not
reproduced here to avoid a third copy drifting out of sync — TASK-011 should read it directly from
that artifact when building the fix-roadmap's `improvements.md` consolidation per TRD Phase 4.

**Already-fixed candidates for retirement** (confirmed cleared at the source-code level by dim-8's
RT-02/RT-03, per that dimension's own "now fixed" annotations — TASK-011 should mark these
retired-by-fix in the consolidated queue rather than carrying them forward as actionable):
- **IMP-047** (`emit-event-cli.sh reviewer_verdict` jq `--argjson` crash, original report) — fixed,
  `emit-event.sh:41-45` + `tests/test-emit-event.sh:96-107`. Residual narrower gap survives as
  **MF-016** (in this register, in the verification queue).
- **IMP-048** (self-audit path-with-spaces + `CLAUDE_CONFIG_DIR` ignored) — fixed,
  `self-audit.sh:204-206,211-226`. No residual finding.
- **IMP-056** (self-audit bare-relative path invocation) — fixed,
  `agents/self-audit.md:31-34`, `stop-hook.sh:1051`. No residual finding.
- **IMP-072** (emit-event `--argjson` crash, 2nd occurrence record — duplicate of IMP-047) — same
  fix, same disposition as IMP-047.

**Note on IMP-046/IMP-058/IMP-071** (haiku/background reviewer stalls, recorded independently
three times in the backlog): these are the pre-existing backlog record of the exact defect this
register's **MF-014** (critical, in the verification queue) root-causes and which dim-8's RT-01/
RT-06 show recurring live a fourth and fifth time. TASK-011 should map all of IMP-046/058/071 to
MF-014's fix, not treat them as separate roadmap items.

## Resolved / cleared anchors (not carried forward as active register entries)

- **dim-8 Anchor 2 / RT-02** — emit-event `--argjson` crash on the iteration arg: CLEARED, fixed
  and regression-tested. Residual fragility preserved as **MF-016**.
- **dim-8 Anchor 3 / RT-03** — self-audit path-with-spaces / bare-relative-path bugs: CLEARED,
  fixed, no residual gap found in scope.
- **dim-3 Anchor 1 (partial)** — `local-mode-tracking-guard.sh`'s originally-reported message-grep
  false positive: CLEARED, current quote-aware awk implementation correctly distinguishes a commit
  message merely mentioning `nazgul/` from a real tracked pathspec.

---

# Summary

- **62 merged findings**: 10 critical · 18 high · 18 medium · 16 low.
- **6 cross-dimension merges** (5 distinct topic-pairs, one — MF-014 — a three-way merge):
  MF-006, MF-014, MF-025, MF-034, MF-048.
- **0 drops** — every finding carried adequate evidence.
- **Verification queue: 38 entries** (10 critical + 18 high + 10 wave-1-candidate mediums).
- **Phase 3 (TASK-010) result, post-board-review: 36 CONFIRMED · 1 CONFIRMED-reclassified
  (MF-027, fail-safe over-block) · 1 SYMPTOM-CONFIRMED/mechanism-PARTIAL (MF-014, multi-causal) ·
  0 REFUTED · 0 DOWNGRADED · 1 PLAUSIBLE** (MF-042, mandated hedge). Full per-finding skeptic
  record, board-correction rationale, and methodology caveat in `verification-verdicts.md`. All 24
  non-queued findings (8 non-selected mediums + 16 lows) remain PLAUSIBLE by default, unverified,
  per the "never silently upgraded" rule — including MF-012, the other named hedge.
- **2 anchors CLEARED as fixed** (not carried as active findings, folded into the carryover
  section): dim-8 RT-02, RT-03.
- **Carryover preserved for TASK-011**: 4 reviewer non-blocking concerns from `nazgul/reviews/`,
  the `improvements.md` 74-item inventory reference (with 4 already-fixed retirement candidates
  identified), and the resolved/cleared-anchor note above.
- **Files touched**: only this artifact
  (`nazgul/context/objectives/FEAT-013/merged-findings.md`), `verification-verdicts.md`
  (TASK-010's own output artifact), and `nazgul/tasks/TASK-009.md`/`TASK-010.md` (status
  transitions) — zero plugin source files, zero dimension input artifacts modified.
