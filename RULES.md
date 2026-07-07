# Nazgul Rules

Enforceable operating rules for the Nazgul Framework. Each rule carries a tier label indicating its real enforcement mechanism — see the legend below. Not every rule has a mechanical guard; the tier makes that explicit.

## Enforcement Tier Legend

| Tier | Label | Meaning |
|------|-------|---------|
| 1 | `[enforced]` | A PreToolUse guard, stop-hook gate, evidence check, or tool-allowlist restriction blocks violations mechanically — independent of who drives the loop. |
| 2 | `[hook-driven only]` | Enforced when `stop-hook.sh` drives the loop (AFK/YOLO). A human or orchestrator that dispatches agents directly can route around it. |
| 3 | `[advisory]` | Depends on agent and reviewer discipline. No mechanical block exists. |

---

## 1. The 10 Rules

1. **Always read plan.md first.** `[enforced]` The Recovery Pointer tells you exactly where you are. Source edits require an IN_PROGRESS task in the manifest (`task-state-guard.sh`), and state advances require evidence on disk (`review-evidence.sh`) — the guards enforce the principle that files must be read before work proceeds.
2. **Files are truth, context is ephemeral.** `[enforced]` Write state to files immediately. Never rely on conversational memory. Evidence gates block state transitions that would rely on unwritten state (IMPLEMENTED requires a commit SHA in the manifest).
3. **Follow existing patterns exactly.** `[advisory]` Read the pattern reference before implementing. Match the style.
4. **Tests are mandatory.** `[enforced]` Every task includes tests. Run them after every change. Don't proceed if failing. `stop-hook.sh` tracks consecutive failures and blocks the loop after `safety.max_consecutive_failures` (default 5) consecutive failures.
5. **Never skip the review gate.** `[enforced]` ALL reviewers must approve. No exceptions. `review-evidence.sh` blocks DONE until a review directory with `verdict: APPROVE` exists for every reviewer.
6. **Address ALL blocking feedback.** `[advisory]` When CHANGES_REQUESTED, fix every REJECT item.
7. **One task at a time.** `[hook-driven only]` Don't work on multiple tasks simultaneously (unless parallel mode with Agent Teams). Sequencing is enforced by stop-hook dispatch; bypassable by direct orchestrator dispatch.
8. **Update Recovery Pointer on every state change.** `[enforced]` This is how you survive compaction. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA in the manifest, IN_REVIEW requires a review directory, source edits require an IN_PROGRESS task.
9. **Commit in AFK mode.** `[hook-driven only]` Every state transition gets a commit with the dynamic prefix from config. Enforced in AFK/YOLO via stop-hook; not enforced in HITL or manual dispatch.
10. **NAZGUL_COMPLETE means ALL tasks DONE and post-loop finished.** `[enforced]` Not before. Verified by re-reading task manifests from disk immediately beforehand — never by recalling prior transitions (guards can silently block status writes).

---

## 2. State Machine

```
Default:     PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE
Task-PR:     PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> APPROVED -> DONE
```

### Permitted Transitions

`[enforced]` All permitted and forbidden transitions are mechanically enforced by `task-state-guard.sh` (PreToolUse on Write/Edit). Any status write that is not an adjacent permitted transition — including a non-adjacent jump like `IN_PROGRESS → DONE` or `PLANNED → DONE`, and including a full-manifest Write whose `status:` lives in YAML frontmatter (caught by the guard's status-extraction fallback) — is rejected (exit 2) with a message naming the current status and the allowed next state(s). Illegal status writes are blocked at the tool call level regardless of who drives the loop.

| From | To | Condition |
|------|----|-----------|
| PLANNED | READY | All dependencies DONE (or APPROVED in YOLO) |
| READY | IN_PROGRESS | Agent claims the task |
| IN_PROGRESS | IMPLEMENTED | Code complete + tests pass + lint clean |
| IMPLEMENTED | IN_REVIEW | Review gate picks up the task |
| IN_REVIEW | DONE | ALL reviewers APPROVED (non-YOLO) |
| IN_REVIEW | APPROVED | ALL reviewers APPROVED (YOLO + task-pr only) |
| IN_REVIEW | CHANGES_REQUESTED | ANY reviewer rejects |
| APPROVED | DONE | PR merged (YOLO + task-pr only) |
| CHANGES_REQUESTED | IN_PROGRESS | Implementer addresses feedback |
| Any active state | BLOCKED | Max retries, unresolvable issue, or 3 consecutive test failures |
| BLOCKED | READY | Human intervention resolves the blocker |
| BLOCKED | IN_REVIEW | Review evidence materialized via `/nazgul:review --materialize` (review directory required) |

### Forbidden Transitions

- PLANNED -> IN_PROGRESS (must go through READY)
- READY -> IMPLEMENTED (must go through IN_PROGRESS)
- IN_PROGRESS -> IN_REVIEW (must go through IMPLEMENTED)
- IN_REVIEW -> IN_PROGRESS (must go through CHANGES_REQUESTED)
- DONE -> any state (terminal)

---

## 3. Review Board

1. **All reviewers must approve.** `[enforced]` Unanimous -- no majority vote. `review-evidence.sh` blocks DONE until all reviewers have `verdict: APPROVE`.
2. **Confidence threshold governs severity.** `[enforced]` Below 80 = non-blocking CONCERN. At or above 80 with HIGH/MEDIUM severity = blocking REJECT. Applied by `review-evidence.sh`.
3. **Reviewers are read-only.** `[enforced]` Reviewers are spawned with only `Read`/`Glob`/`Grep` — no `Write` and no `Bash` — so they genuinely cannot modify any file or run any command (tool-allowlist enforced, not merely convention). They analyze the diff and RETURN their review as their final message; the review-gate orchestrator persists each returned review to `nazgul/reviews/[UNIT-ID]/`. (This single point of persistence is why reviewers no longer silently fail to write their files.)
4. **Pre-checks before reviews.** `[advisory]` Tests and lint must pass BEFORE reviewers run. Three consecutive test failures block the task. The config flag `require_tests_pass_before_review` is not mechanically gated at the pre-review boundary.
5. **Security rejections are absolute in AFK mode.** `[hook-driven only]` Task is BLOCKED, requires human review. Applied by stop-hook in AFK mode; not active in HITL or manual dispatch.
6. **Every finding must be structured.** `[enforced]` Required fields: severity, confidence, file path, category, verdict, issue, fix. `review-evidence.sh` reads the structured format to determine APPROVE/REJECT — a malformed review without a valid `verdict` field is treated as a non-approval.
7. **Feedback priority:** `[hook-driven only]` Security first, correctness second, style last. Contradiction resolution in AFK mode is handled by stop-hook (majority wins, ties by confidence); advisory in HITL.
8. **Contradiction handling:** `[hook-driven only]` HITL = flag for human. AFK = majority wins, ties broken by higher confidence. Applied by stop-hook in AFK mode.
9. **Review granularity is enforced at the completion gate.** `[enforced]` `review_gate.granularity` (`task`/`group`/`feature`) controls the review unit. The stop-hook drives dispatch at the configured granularity in AFK/YOLO, so it holds up front there. But a human or orchestrator dispatching `nazgul:review-gate` directly (e.g. `/nazgul:review`) bypasses that **sequencing** — so a `SubagentStop` detector records the unit each review actually covered (`nazgul/logs/review-coverage.jsonl`, derived from `reviewer_verdict` events) and the stop-hook's granularity reconciliation gate blocks (or warns, per `review_gate.enforce_granularity`) `NAZGUL_COMPLETE` when a DONE task was reviewed at the wrong granularity. The gate is post-hoc defense-in-depth (the review already ran at the wrong scope) with a bounded backstop so it can never deadlock an unattended loop. Subagent **dispatch** itself cannot be pre-gated (no PreToolUse matcher for the Task tool), so completion-gate enforcement is the available mechanism.
10. **Review attestation is diff-bound.** `[hook-driven only]` Before spawning reviewers, review-gate writes a diff-bound dispatch manifest (`nazgul/reviews/<unit>/.dispatch.json`, co-located with the reviewer evidence the DONE gate reads) via `write_dispatch_manifest` (`scripts/lib/review-provenance.sh`): a nonce, a diff-hash, and a derived `token`. The orchestrator — never the reviewer — stamps the matching `review_token:` into each reviewer's frontmatter when it persists the returned review (see §3.3). `validate_review_provenance`, gated by `review_gate.require_provenance` (default `true`), re-scans every DONE task on each stop-hook Stop event and detects a missing manifest or a diff that moved since review (`DIFF_HASH_STALE`), routing violations through its own bounded reset→IMPLEMENTED→BLOCKED escalation (`_provenance_reset_counts`, tracked independently of the pre-existing evidence ladder `_review_reset_counts` so a first-time provenance violation right after an evidence violation still gets its own grace reset). **Honest limit: this is tamper-evidence and diff-staleness detection, not authentication** — the stop-hook verifier and the review-gate orchestrator share the same filesystem and the token derivation is public, so a determined actor with shell access could forge one; its real value is catching the common accidental cases (board skipped, code changed after approval). Degrades to allow for legacy reviews where no reviewer file carries a `review_token:`. Because this check runs only inside the stop-hook's post-hoc scan, a human or orchestrator that hand-writes `status: DONE` without ever invoking stop-hook is not provenance-checked (only evidence-checked, per §3.1). `[enforced]` separately: `task-state-guard.sh` blocks (PreToolUse, independent of driver) any Write/Edit to `.dispatch.json` while the owning task is IN_PROGRESS, closing the window where an implementer could plant a favorable manifest before review starts.
11. **Reviewer dispatch is diff-aware and cost-tiered.** `[enforced]` When `review_gate.conditional_dispatch` is `true` (default `false`), `scripts/lib/reviewer-selection.sh select` deterministically — no LLM judgment — picks which configured reviewers run for the changed-file set: `security-reviewer` always runs; `architect-reviewer` only when scope touches `skills/`, `agents/`, `scripts/`, `hooks/`, or a config-schema file; `qa-reviewer` only when `tests/` changed; `code-reviewer` is skipped only when every changed file is doc/markdown/text; any classification ambiguity defaults to the full board. The orchestrator writes an authorized `verdict: SKIPPED` stub (with a matching `review_token:`) for each skipped reviewer, and `validate_review_evidence` treats a manifest-authorized SKIPPED as gate-satisfying — but only by **recompute-and-compare**: `_re_manifest_authentic` (`scripts/lib/review-evidence.sh`) re-derives the legitimate skip set from the unit's CURRENT `diff.patch` and the live selection policy (`reviewer-selection.sh verify`), so a `skipped[]` entry that is not reproducible from the current diff is rejected; `security-reviewer` is never honored as skipped even if a manifest claims it (defense in depth). This check runs inside `validate_review_evidence`, called from `task-state-guard.sh`'s PreToolUse guard on the DONE-status write — independent of who drives the loop, mirroring §3.1/§3.6. **Honest limit (accepted):** recompute-and-compare binds a skip to the diff and selection policy *on disk*, not to who wrote the manifest — `diff.patch` itself is an unauthenticated trust root, so a determined actor with shell access could pre-plant a diff that legitimizes a forged skip. This closes the cheap forge (naming a reviewer as skipped with nothing backing it), not authenticating the writer, consistent with the plugin's shared-filesystem threat model. Model selection is cost-tiered but not hook-enforced: `models.review` defaults mechanical reviewers to `haiku`; `models.review_by_reviewer` is a review-gate agent instruction (Step 2), not a hook check, that pins both `security-reviewer` and `architect-reviewer` to `sonnet` regardless of the default. `review_gate.require_all_approve` is **informational only — no script reads it**; the effective policy is the hard-coded "every non-skipped reviewer must APPROVE" loop inside `validate_review_evidence` itself (see §3.1).

---

## 4. Recovery Protocol

The Recovery Pointer is read first by every agent on every start. `[enforced]` Evidence gates enforce the underlying principle — source edits require an IN_PROGRESS task (`task-state-guard.sh`) and state advances require on-disk evidence (`review-evidence.sh`). Agents cannot make progress without reading and writing the correct state files.

```markdown
## Recovery Pointer
- **Current Task:** TASK-NNN
- **Last Action:** [what just happened]
- **Next Action:** [what should happen next]
- **Last Checkpoint:** nazgul/checkpoints/iteration-NNN.json
- **Last Commit:** abc1234
```

### Recovery Read Order

1. `nazgul/config.json` -- Mode, iteration, reviewer list
2. `nazgul/plan.md` -- Recovery Pointer
3. `nazgul/checkpoints/iteration-NNN.json` -- Latest checkpoint
4. `nazgul/tasks/TASK-XXX.md` -- Active task manifest
5. `nazgul/reviews/TASK-XXX/` -- If CHANGES_REQUESTED: consolidated feedback
6. `nazgul/context/project-profile.md` -- If needed: project conventions

**No agent may begin work without reading files 1-4. Files are truth -- never rely on conversational memory.**

---

## 5. Safety Boundaries

### Hard Blocks (unconditional)

`[enforced]` All hard blocks below are caught by `pre-tool-guard.sh` (PreToolUse on Bash) and blocked before execution, regardless of mode or who drives the loop.

- `rm -rf /`, `rm -rf ~` -- filesystem destruction
- `DROP TABLE`, `TRUNCATE` -- data destruction
- `git push --force main/master` -- shared branch destruction
- Fork bombs, `curl | sh` -- unsafe execution
- `chmod -R 777` -- permission degradation
- Comment bloat in source writes -- blocked by `lean-comments-guard.sh` (PreToolUse on Write/Edit/MultiEdit), opt-out via `guards.lean_comments`

### Lean Comments (enforced)

`[enforced]` Comments must be LEAN. Full XML/JSDoc/docstring belongs on **PUBLIC interface members only**; implementations use `<inheritdoc/>`. A single short comment explaining a non-obvious domain/venue quirk is allowed. Everything else is bloat and is blocked at write time and rejected by the code reviewer (always-blocking, never an auto-approved CONCERN):

- A run of 3+ consecutive `//`/`#` line comments that is not a license header.
- A `<remarks>`/multi-paragraph doc block on a private/internal/protected or test member.
- A banner/separator comment (`// ── Helpers ──────`, `// =======`).
- A comment that restates or narrates the next line of code.

Tunable via `guards.lean_comments` (default `true`) and `guards.max_consecutive_comment_lines` (default `2`).

This guard governs comment QUANTITY at write time. See §7 for the complementary post-loop comment-QUALITY gate (templated/restatement/contradiction defects) — the two are independent, non-overlapping checks.

### FEAT-005 Guard Audit (Bash-matched vs. Write/Edit-matched guards)

`[enforced]` FEAT-005 audited all four PreToolUse guards for whole-command-substring brittleness — matching on text that appears in a Bash command string rather than on the real action being taken.

**Bash-matched guards (fixed in FEAT-005):** `local-mode-tracking-guard.sh` and `pre-tool-guard.sh` receive `tool_input.command` (the Bash string, extracted from the PreToolUse JSON envelope) and previously used substring presence to infer intent (e.g., `nazgul/` anywhere in the command string, or `echo.*Status.*nazgul/tasks/` regardless of redirect). Both guards were updated to inspect the real action with a no-`eval` tokenizer: `local-mode-tracking-guard.sh` now parses actual git positional pathspecs (skipping flag values like `-m` messages and git global options); `pre-tool-guard.sh`'s manifest-write rule now requires a genuine redirect (`>`, `>>`, the noclobber-override `>|`/`>>|`, or the combined `&>`/`&>>`) targeting a `nazgul/tasks/TASK-*.md` path. Both tokenizers split compound commands (`;`, `&&`, `||`, `|`, unquoted newlines), reconstruct redirect targets from adjacent quoted fragments, skip leading `VAR=value` env assignments, and handle fd-numbered/combined redirects (`1>`, `2>`, `2>&1`, `&>`) so they cannot hide a target or steal the command word. Genuinely exotic shell forms (process substitution, `eval`, command substitution, nested subshells) are out of scope by design and degrade to allow — the primary protection is `.gitignore` + the session-staging chokepoint.

**Write/Edit-matched guards (structurally immune — no fix required):** `task-state-guard.sh` and `lean-comments-guard.sh` operate on Write/Edit/MultiEdit tool JSON (`tool_input.file_path`, `tool_input.content`, `tool_input.new_string`). They never inspect a Bash command string. The whole-command-substring class of false-positive is structurally absent; the FEAT-005 precision fixes do not apply to them and no change was made.

### Soft Limits

`[enforced]` Iteration, retry, and failure ceilings are enforced by `stop-hook.sh`; the loop cannot advance past them regardless of mode.

| Limit | Default | Config |
|-------|---------|--------|
| Max iterations | 40 | `max_iterations` |
| Max retries/task | 3 | `review_gate.max_retries_per_task` |
| Max consecutive failures | 5 | `safety.max_consecutive_failures` |
| AFK timeout | 90 min | `afk.timeout_minutes` |
| Confidence threshold | 80 | `review_gate.confidence_threshold` |

---

## 6. Classification

`[enforced]` Classification is performed by the Discovery agent and written to `nazgul/config.json`; downstream agents read the config-file classification and adapt accordingly. The written result persists and drives conditional agent roster generation.

| Type | Detection |
|------|-----------|
| GREENFIELD | <10 source files, no meaningful logic |
| BROWNFIELD | Existing codebase, adding features (DEFAULT) |
| REFACTOR | Restructuring without changing behavior |
| BUGFIX | Fixing specific issues, narrow scope |
| MIGRATION | Moving between technologies/platforms |

---

## 7. Document Generation Matrix

`[hook-driven only]` Document generation follows this matrix; the stop-hook drives the doc-generator agent per the configured roster. In manual dispatch the matrix is advisory.

| Document | Greenfield | Brownfield | Refactor | Bugfix | Migration |
|----------|-----------|------------|----------|--------|-----------|
| PRD | Full | Feature-scoped | -- | -- | Feature parity |
| TRD | Full | Feature-scoped | Target arch | -- | Target stack |
| ADR | Key decisions | New decisions | Why refactor | -- | Why migrate |
| Test Plan | Full | Feature tests | Regression | Regression | Validation |

**Doc-accuracy is enforced at the post-loop completion gate.** `[enforced]` Generated docs and CHANGELOG must reference only artifacts that exist in source — event types, config keys, commands, scripts, and schema versions named in a doc must be findable in the codebase. After the post-loop documentation and release-manager agents run, a separate `agents/doc-verifier.md` agent cross-checks every named artifact against source and writes an objective-scoped marker (`nazgul/logs/.docs-verified`, containing the current `feat_id`) when all references are clean. The stop-hook blocks `NAZGUL_COMPLETE` until this marker is present and matches the active `feat_id`. The gate has a bounded backstop (≤3 attempts) after which it emits a loud warning and allows completion — it never deadlocks an unattended loop. When `docs.verify_post_loop` is `false` in `nazgul/config.json` (default `true`), the gate is a complete no-op: no marker is required and no block is issued. When `nazgul/docs/` is absent or empty the verifier exits allow without blocking (degrade-to-allow).

**Inline doc-comment quality is enforced at the post-loop completion gate.** `[enforced]` `agents/comment-verifier.md` — a language-generic agent — grades inline source doc-comments (XML `<summary>`, JSDoc, docstrings) changed by the objective for templated, restatement, and contradiction defects; this is distinct from the Lean Comments quantity guard in §5 (write-time bloat vs. post-loop quality — see the cross-reference there). It records completion by writing `nazgul/logs/.comments-verified` containing the current `feat_id`. The stop-hook blocks `NAZGUL_COMPLETE` until this marker is present and matches the active `feat_id`, with its own bounded backstop (≤3 attempts) after which it warns and allows completion. When `docs.verify_comments` is `false` in `nazgul/config.json` (default `true`), or no non-doc/config source file changed on the feature branch, the gate degrades to allow without requiring the marker.

---

## 8. File Scope Restrictions

- **Implementer**: `[enforced]` Only files in the task's `file_scope`. `task-state-guard.sh` (PreToolUse on Write/Edit) blocks edits outside declared scope. Must update manifest before expanding.
- **Reviewers**: `[enforced]` Read-only — `Read`/`Glob`/`Grep` only, no `Write` and no `Bash` (tool-allowlist enforced). Reviewers do not write any file; they RETURN their review and the review-gate orchestrator persists it to `nazgul/reviews/` (see §3.3).
- **Parallel tasks**: `[hook-driven only]` Zero file overlap. Team Orchestrator validates before assigning; bypassable by manual task dispatch.
- **Specialists**: `[hook-driven only]` Only files in the delegation brief's scope. Validated by the Team Orchestrator when stop-hook drives dispatch.

---

## 9. Mode Governance

`[enforced]` Mode is read from `nazgul/config.json` by every agent on start. Pre-tool guard blocks destructive commands in all modes. Stop-hook enforces mode-specific behavior (AFK auto-commit, AFK security BLOCK, YOLO permission skip).

- **HITL** (default): Human approves classification, docs, plan. Consulted on blockers.
- **AFK**: Auto-approve classification/docs/plan. Auto-commit. Security rejections auto-block.
- **YOLO**: AFK + zero permission prompts. Requires `--dangerously-skip-permissions`. Pre-tool guard still blocks destructive commands.

---

## 10. Branch Isolation

- **Never commit to the base branch during a loop.** `[hook-driven only]` Blocked by `base-branch-commit-guard.sh` (PreToolUse on Bash): a commit targeting `branch.base` while `branch.feature` is set exits 2 with an actionable error. PreToolUse guard pending TASK-002 (`base-branch-commit-guard.sh`)
- **Never stage `nazgul/` paths in local mode.** `[enforced]` Blocked by `local-mode-tracking-guard.sh` (PreToolUse on Bash): when `install_mode == "local"`, any `git add`/`git commit` touching a `nazgul/` path exits 2.
- **Feature branch:** `[hook-driven only]` `feat/<id>-<slug>` -- integration point. Written to `branch.feature` in config; guards read this field to validate commits. PreToolUse guard pending TASK-002
- **Task worktrees:** `[hook-driven only]` `feat/<id>/TASK-NNN` -- merge back to feature. Created by stop-hook worktree utilities; naming enforced by convention in AFK mode.
- **Worktrees live in** `../<project>-worktrees/TASK-NNN/` -- `[hook-driven only]` Path written to `branch.worktree_dir` in config; used by stop-hook worktree utilities.
- **On conflict:** `[hook-driven only]` `git merge --abort`, task BLOCKED. Applied by stop-hook on merge failure detection.

---

## 11. Conductor Execution Engine (opt-in)

`agents/conductor.md` is a graph-only alternative driver: one long-lived session that computes waves
from the Planner's task graph and dispatches each unit's implementation and Review Board itself, holding
only `nazgul/conductor/graph.json` (ids, deps, wave, status, a one-line verdict, a bare commit SHA — never
a diff or file body). It reuses Review Board (§3) unmodified — every unit still goes through
`agents/review-gate.md` exactly as the sequential loop does — and any `worktree`-backend unit follows the
same `EnterWorktree`/`ExitWorktree` + feature-branch-only merge rules as every other Nazgul worktree
(§10); it never merges to `main`. The sequential stop-hook loop is untouched either way.

- **Opt-in engine selection and pause gates are config-read, not hook-blocked.** `[advisory]` `execution.engine` defaults to `"sequential"`; `/nazgul:start --conductor` (`skills/start/SKILL.md` Engine Selection) is what dispatches `agents/conductor.md` instead of the Implementer, only when `execution.engine == "conductor"`. `conductor.gates.approve_graph`/`approve_each_wave`/`approve_final_pr` default `false` (autonomous-first); `conductor_gate_effective` (`scripts/lib/conductor-gates.sh`) computes the EFFECTIVE value at read time — `mode == "hitl"` flips `approve_graph` on without mutating the stored config — and `conductor_should_pause` is checked at Steps 1.5/3.2/3.3 of `agents/conductor.md`. Both the engine choice and every gate pause are protocol steps inside the Conductor's own prompt: no PreToolUse guard stops a human or orchestrator from dispatching `agents/conductor.md` directly regardless of the stored `execution.engine` value, or from skipping a gate pause.
- **The two hard stops are unconditional within the Conductor's own protocol — never gated, never yolo-bypassable by config.** `[advisory]` Any `BLOCKED` task or any non-`APPROVE` `security-reviewer.md` verdict halts the Conductor for a human. `conductor_should_halt` (`scripts/lib/conductor-gates.sh`) fails CLOSED on ambiguity (`BLOCKED_TASKS_AMBIGUOUS`, `SECURITY_REJECTION_AMBIGUOUS`, `*_UNREADABLE`) and ignores every `conductor.gates` value and mode, including `yolo` — this extends §3.5's AFK security-rejection stop and §5's hard-block list into the Conductor engine. `agents/conductor.md` calls it unconditionally at the top of every wave (Step 3.1) and again at every batch boundary within a wave (Step 5.3), so a BLOCKED or security-rejected unit can never let more work start once called. Per this legend that is `[advisory]`, not `[enforced]`: the lib fails closed whenever invoked, but no PreToolUse guard or `stop-hook.sh` gate forces the invocation — it depends entirely on `agents/conductor.md`'s own protocol, same honest limit as the rest of this section.
- **Wave parallelism: Planner-marked and zero-overlap only, capped at `conductor.max_parallel`.** `[advisory]` A wave runs parallel only when `nazgul/plan.md`'s `## Wave Groups` section marks it explicitly AND `route_wave` (`scripts/lib/conductor-router.sh`) finds zero file-scope overlap across the wave's units; any overlap, or an unmarked wave, aborts the whole wave to sequential — the identical rule §8 already gives Team Orchestrator ("Parallel tasks... Zero file overlap... bypassable by manual task dispatch"), not reimplemented here. Batches never exceed `conductor.max_parallel` (default `3`, read via `conductor_max_parallel`). `route_wave` fails closed to sequential whenever called, but that call happens inside `agents/conductor.md`'s own Step 4 protocol, not behind `stop-hook.sh` — per this legend that makes it `[advisory]`, bypassable by an orchestrator that dispatches units directly without going through the router, same caveat as §8's Team Orchestrator entry.
- **Graph-only invariant: the Conductor never holds file bodies.** `[advisory]` `graph_upsert_task`/`graph_set_verdict` (`scripts/lib/conductor-graph.sh`) refuse to write a multi-line or diff-shaped verdict, or a non-SHA commit (`tests/test-conductor-recovery.sh` covers the rejection cases). This is a backstop on those two setters, not a hard guard on the Conductor itself: the agent holds `Write`/`Edit` directly and could bypass `conductor-graph.sh` to hand-write `graph.json`. The real invariant — never `Read` a diff, a changed source file, or reviewer prose into its own context — is agent discipline, spelled out in `agents/conductor.md`'s "GRAPH-ONLY INVARIANT" section and test-backed, not mechanically blocked.
