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

---

## 8. File Scope Restrictions

- **Implementer**: `[enforced]` Only files in the task's `file_scope`. `task-state-guard.sh` (PreToolUse on Write/Edit) blocks edits outside declared scope. Must update manifest before expanding.
- **Reviewers**: `[enforced]` Read-only. Write only to `nazgul/reviews/`. Enforced via tool allowlist.
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
