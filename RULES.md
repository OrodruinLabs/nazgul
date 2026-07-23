# Nazgul Rules

Enforceable operating rules for the Nazgul Framework. Each rule carries a tier label indicating its real enforcement mechanism — see the legend below. Not every rule has a mechanical guard; the tier makes that explicit.

## Enforcement Tier Legend

| Tier | Label | Meaning |
|------|-------|---------|
| 1 | `[enforced]` | A PreToolUse guard, stop-hook gate, evidence check, tool-allowlist restriction, or real git hook (`core.hooksPath`, §15) blocks violations mechanically — independent of who drives the loop. A git hook is strictly stronger than the others in this tier (it runs outside the Claude Code session entirely, after the shell has fully resolved the command), but *installing* one is itself only `[hook-driven only]` — see §15. |
| 2 | `[hook-driven only]` | Enforced when `stop-hook.sh` drives the loop (AFK/YOLO). A human or orchestrator that dispatches agents directly can route around it. |
| 3 | `[advisory]` | Depends on agent and reviewer discipline. No mechanical block exists. |

---

## 1. The 10 Rules

1. **Always read plan.md first.** `[enforced]` The Recovery Pointer tells you exactly where you are. Source edits require an IN_PROGRESS task in the manifest (`task-state-guard.sh`), and state advances require evidence on disk (`review-evidence.sh`) — the guards enforce the principle that files must be read before work proceeds.
2. **Files are truth, context is ephemeral.** `[enforced]` Write state to files immediately. Never rely on conversational memory. Evidence gates block state transitions that would rely on unwritten state (IMPLEMENTED requires a commit SHA in the manifest that resolves to a real, reachable commit via `git cat-file -e` — MF-026; a hex-looking-but-nonexistent SHA, or a manifest written when `git` is unavailable, now BLOCKS instead of passing a bare pattern match).
3. **Follow existing patterns exactly.** `[advisory]` Read the pattern reference before implementing. Match the style.
4. **Tests are mandatory.** `[enforced]` Every task includes tests. Run them after every change. Don't proceed if failing. `stop-hook.sh` tracks consecutive failures and blocks the loop after `safety.max_consecutive_failures` (default 5) consecutive failures.
5. **Never skip the review gate.** `[enforced]` ALL reviewers must approve. No exceptions. `review-evidence.sh` blocks DONE until a review directory with `verdict: APPROVE` exists for every reviewer.
6. **Address ALL blocking feedback.** `[advisory]` When CHANGES_REQUESTED, fix every REJECT item.
7. **One task at a time.** `[hook-driven only]` Don't work on multiple tasks simultaneously (unless `execution.parallel` batch dispatch is enabled — the stop-hook dispatches a bounded, file-scope-disjoint batch of READY tasks together). Sequencing is enforced by stop-hook dispatch; bypassable by direct orchestrator dispatch.
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

### Bash-Write Reconciliation (MF-022, second layer)

`[hook-driven only]` The table above is enforced at the tool level by `task-state-guard.sh` — but only for a status write that goes through Write/Edit/MultiEdit. A write that reaches a manifest by another path (`mv`/`cp` over the file, a raw shell redirect that evades the PreToolUse matcher) bypasses that tool-level gate entirely. `scripts/stop-hook.sh` closes this as a second, detection-only layer: at the top of every iteration it diffs each task manifest's live status against the status recorded in the previous checkpoint's `task_statuses` snapshot, and any change since then that is not traceable to a guarded transition — logged only by `task-state-guard.sh`'s PreToolUse path via `ttg_log_transition` (`scripts/lib/task-transition-guard.sh`) — is untrusted and flagged `BLOCKED` with a named diagnostic (task id, old→new status, "written outside the guarded Write/Edit/MultiEdit path"). It never rewrites a "corrected" status, only blocks. Both call sites share one library (`scripts/lib/task-transition-guard.sh`: `ttg_valid_transition`, `ttg_verify_commit_evidence`, `ttg_verify_review_evidence`, `ttg_log_transition`), so the transition rules can't drift out of sync between the two enforcement points. Runs only when `stop-hook.sh` drives the loop — a human or orchestrator that never invokes it is not caught by this layer, only by the tool-level block (when the write happens to go through a guarded tool). Kill-switch: `guards.bash_write_reconciliation` (default `true`, config schema v28).

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
9. **Review granularity is enforced at the completion gate.** `[enforced]` `review_gate.granularity` (`task`/`group`/`feature`) controls the review unit. The stop-hook drives dispatch at the configured granularity in AFK/YOLO, so it holds up front there. But a human or orchestrator dispatching `nazgul:review-gate` directly (e.g. `/nazgul:review`) bypasses that **sequencing** — so a `SubagentStop` detector records the unit each review actually covered (`nazgul/logs/review-coverage.jsonl`, derived from `reviewer_verdict` events) and the stop-hook's granularity reconciliation gate blocks (or warns, per `review_gate.enforce_granularity`) `NAZGUL_COMPLETE` when a DONE task was reviewed at the wrong granularity. The gate is post-hoc defense-in-depth (the review already ran at the wrong scope) with a bounded backstop so it can never deadlock an unattended loop. Subagent dispatch CAN now be pre-gated — a PreToolUse matcher on the Agent tool exists and is in production use by parallel-dispatch-guard.sh (§12) — but granularity enforcement deliberately remains at the completion gate: the wrong-scope review is only knowable after the review ran.
10. **Review attestation is diff-bound.** `[hook-driven only]` Before spawning reviewers, review-gate writes a diff-bound dispatch manifest (`nazgul/reviews/<unit>/.dispatch.json`, co-located with the reviewer evidence the DONE gate reads) via `write_dispatch_manifest` (`scripts/lib/review-provenance.sh`): a nonce, a diff-hash, and a derived `token`. The orchestrator — never the reviewer — stamps the matching `review_token:` into each reviewer's frontmatter when it persists the returned review (see §3.3). `validate_review_provenance`, gated by `review_gate.require_provenance` (default `true`), re-scans every DONE task on each stop-hook Stop event and detects a missing manifest or a diff that moved since review (`DIFF_HASH_STALE`), routing violations through its own bounded reset→IMPLEMENTED→BLOCKED escalation (`_provenance_reset_counts`, tracked independently of the pre-existing evidence ladder `_review_reset_counts` so a first-time provenance violation right after an evidence violation still gets its own grace reset). **Honest limit: this is tamper-evidence and diff-staleness detection, not authentication** — the stop-hook verifier and the review-gate orchestrator share the same filesystem and the token derivation is public, so a determined actor with shell access could forge one; its real value is catching the common accidental cases (board skipped, code changed after approval). Degrades to allow for legacy reviews where no reviewer file carries a `review_token:`. Because this check runs only inside the stop-hook's post-hoc scan, a human or orchestrator that hand-writes `status: DONE` without ever invoking stop-hook is not provenance-checked (only evidence-checked, per §3.1). `[enforced]` separately: `task-state-guard.sh` blocks (PreToolUse, independent of driver) any Write/Edit to `.dispatch.json` while the owning task is IN_PROGRESS, closing the window where an implementer could plant a favorable manifest before review starts.
11. **Reviewer dispatch is diff-aware and cost-tiered.** `[enforced]` When `review_gate.conditional_dispatch` is `true` (default `false`), `scripts/lib/reviewer-selection.sh select` deterministically — no LLM judgment — picks which configured reviewers run for the changed-file set: `security-reviewer` always runs; `architect-reviewer` only when scope touches `skills/`, `agents/`, `scripts/`, `hooks/`, or a config-schema file; `qa-reviewer` only when `tests/` changed; `code-reviewer` is skipped only when every changed file is doc/markdown/text; any classification ambiguity defaults to the full board. The orchestrator writes an authorized `verdict: SKIPPED` stub (with a matching `review_token:`) for each skipped reviewer, and `validate_review_evidence` treats a manifest-authorized SKIPPED as gate-satisfying — but only by **recompute-and-compare**: `_re_manifest_authentic` (`scripts/lib/review-evidence.sh`) re-derives the legitimate skip set from the unit's CURRENT `diff.patch` and the live selection policy (`reviewer-selection.sh verify`), so a `skipped[]` entry that is not reproducible from the current diff is rejected; `security-reviewer` is never honored as skipped even if a manifest claims it (defense in depth). This check runs inside `validate_review_evidence`, called from `task-state-guard.sh`'s PreToolUse guard on the DONE-status write — independent of who drives the loop, mirroring §3.1/§3.6. **Honest limit (accepted):** recompute-and-compare binds a skip to the diff and selection policy *on disk*, not to who wrote the manifest — `diff.patch` itself is an unauthenticated trust root, so a determined actor with shell access could pre-plant a diff that legitimizes a forged skip. This closes the cheap forge (naming a reviewer as skipped with nothing backing it), not authenticating the writer, consistent with the plugin's shared-filesystem threat model. Model selection is cost-tiered but not hook-enforced: `models.review` defaults mechanical reviewers to `haiku`; `models.review_by_reviewer` is a review-gate agent instruction (Step 2), not a hook check, that pins both `security-reviewer` and `architect-reviewer` to `sonnet` regardless of the default. `review_gate.require_all_approve` is **informational only — no script reads it**; the effective policy is the hard-coded "every non-skipped reviewer must APPROVE" loop inside `validate_review_evidence` itself (see §3.1).
12. **The `UNVERIFIED` verdict separates "could not assess" from "rejected."** `[enforced]` at the DONE gate; the retry loop + role-aware finalize are review-gate orchestrator steps, not a hook. A fourth verdict `UNVERIFIED` (`VALID_VERDICTS`, `scripts/lib/structured-state.sh`) is emitted either by a reviewer that self-reports it genuinely could not assess the change (`agents/templates/reviewer-base.md`) OR by the review-gate orchestrator as a token-stamped stub when a dispatched reviewer errors, times out, or returns unparseable text (`agents/review-gate.md` Step 2.5). It is distinct from `CHANGES_REQUESTED` (a real rejection) and carries its **own bounded counter**: a terminal `UNVERIFIED` re-dispatches that one reviewer up to `review_gate.unverified_retries` (default 2) times and **never increments** the CHANGES_REQUESTED `retry_count` — the change isn't wrong, the review didn't happen (Step 2.6). Role-aware finalize once retries are exhausted: a **critical reviewer** (`review_gate.critical_reviewers`, default `["security-reviewer","architect-reviewer"]`) still `UNVERIFIED` escalates to **BLOCKED** (fail-closed); a **non-critical reviewer** (code, qa, generated domain reviewers) becomes a **non-blocking warning** that satisfies the DONE gate only when `review_gate.allow_unverified_nonblocking` is `true` (default) — set it `false` for a conservative posture where `UNVERIFIED` blocks for everyone. The DONE-gate half is enforced: `_has_approved_verdict` treats `UNVERIFIED` as not-approved and `_re_is_authorized_unverified` (`scripts/lib/review-evidence.sh`) admits a non-critical `UNVERIFIED` only under the toggle, falls back to the default critical list on a malformed/ambiguous config (fail closed, not open), and never admits `security-reviewer` (hard-coded, pre-config-read). Each finalized `UNVERIFIED` emits a `reviewer_unverified` event; the parallel-mode security hard-stop `_pb_security_rejections` (`scripts/lib/parallel-batch.sh`, §11) emits a distinct `SECURITY_UNVERIFIED` line (same halt) so logs separate "could not assess" from "rejected."
13. **Borderline blocking findings get one bounded adversarial cross-check.** `[advisory]` — review-gate orchestrator behavior (`agents/review-gate.md` Step 3), not a hook check. When `review_gate.adversarial_crosscheck` is `true` (default), a blocking finding (confidence ≥ `confidence_threshold`) whose confidence lands within `review_gate.adversarial_margin` (default 10) of the threshold **and** is HIGH severity or on a security-relevant file gets **exactly one** fresh confirm-or-refute reviewer dispatched for that single finding. If it refutes at ≥ threshold confidence the finding downgrades to a non-blocking CONCERN; if it confirms (or by default) it stays blocking. Bounded by `review_gate.adversarial_max` (default 3) cross-checks per review unit — eligible findings past the cap are logged as not-cross-checked and stay blocking. Per FEAT-006 cost discipline this deliberately does NOT re-review anything else and NEVER runs a second board; worst-case added cost is `adversarial_max` single-finding dispatches, and it is a one-line opt-out.

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

**Self-audit runs at the post-loop completion gate.** `[enforced]` (FEAT-009, ADR-001) After the doc/comment verifiers, `agents/self-audit.md` mines this objective's own signals — review rejections, retries, blocks, best-effort transcript token cost, and any first-party findings in `nazgul/logs/findings.jsonl` (§14) — and appends one structured entry per finding to the durable, append-only backlog at `nazgul/improvements.md` (path from `self_audit.backlog_path`). Its testable core `scripts/self-audit.sh` never fails the run: every source degrades to a no-op when absent. The agent records completion by writing `nazgul/logs/.self-audited` containing the current `feat_id`; the stop-hook blocks `NAZGUL_COMPLETE` until that marker matches, with a bounded ≤3-attempt backstop so it can never deadlock an unattended loop. When `self_audit.enabled` is `false` in `nazgul/config.json` (default `true`), the gate is a complete no-op.

**Model tiers are config-read, not hook-enforced.** `[advisory]` (FEAT-009) The single review tier is now two keys: `models.review_orchestrator` (the review-gate orchestrator) and `models.review_default` (default per-reviewer tier for the mechanical code/qa reviewers). Both resolve with the exact fallback chain **new key → legacy `models.review` → hardcoded** (`sonnet` for the orchestrator, `haiku` for the default reviewer), so a config still carrying only `models.review` is honored unchanged; `models.review_by_reviewer` pins `security-reviewer`/`architect-reviewer` to `sonnet` on top of this (§3 Rule 11). These are agent/skill config reads, not hook checks — advisory, like the rest of the model routing.

---

## 8. File Scope Restrictions

- **Implementer**: `[enforced]` Only files listed in the task manifest's `Files modified` JSON array, read via the shared `get_task_files_modified` accessor (`scripts/lib/task-utils.sh`). `task-state-guard.sh` (PreToolUse on Write/Edit) blocks edits outside declared scope — a live restriction again (MF-024): the block previously queried a nonexistent `File Scope` field and never actually restricted anything. Must update the manifest before expanding scope.
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

- **Never commit to the base branch during a loop.** `[enforced]` Blocked by the `pre-commit` git hook (`scripts/git-hooks/pre-commit`, §15, installed via `core.hooksPath`): a commit targeting `branch.base` while `branch.feature` is set exits nonzero with an actionable error. The old command-string `base-branch-commit-guard.sh` (PreToolUse on Bash) is deleted — it proved non-convergent against shell-expansion bypasses (ADR-001) and is fully replaced by this git-level hook.
- **Never stage `nazgul/` paths in local mode.** `[enforced]` Blocked by `local-mode-tracking-guard.sh` (PreToolUse on Bash): when `install_mode == "local"`, any `git add`/`git commit` touching a `nazgul/` path exits 2.
- **Feature branch:** `[hook-driven only]` `feat/<id>-<slug>` -- integration point. Written to `branch.feature` in config; the git-level `pre-commit` hook (§15) reads this field to validate commits.
- **Task worktrees:** `[hook-driven only]` `feat/<id>/TASK-NNN` -- merge back to feature. Created by stop-hook worktree utilities; naming enforced by convention in AFK mode.
- **Worktrees live in** `../<project>-worktrees/TASK-NNN/` -- `[hook-driven only]` Path written to `branch.worktree_dir` in config; used by stop-hook worktree utilities.
- **On conflict:** `[hook-driven only]` `git merge --abort`, task BLOCKED. Applied by stop-hook on merge failure detection.

---

## 11. Parallel Dispatch (opt-in)

`execution.parallel` (default `false`) is an opt-in batch-dispatch option inside the single sequential
stop-hook loop — there is no separate driver agent or engine choice. `scripts/stop-hook.sh` reads the
flag on every Stop-hook invocation and, when set, layers concurrent task dispatch on top of the same
state machine, Review Board (§3), and worktree/branch rules (§10) the sequential loop already uses. This
replaces the former opt-in Conductor engine (FEAT-007 through FEAT-009), deleted along with its dedicated
driver agent, `nazgul/conductor/graph.json` state, and engine-specific guards in favor of one engine with
an optional parallel-batch mode (the Parallel Execution Collapse).

- **Batch selection: Planner-marked and zero-overlap only, capped at `execution.max_parallel`.** `[enforced]` `compute_dispatch_batch` (`scripts/lib/parallel-batch.sh`) runs as a plain, unconditional bash conditional inside `stop-hook.sh`'s own continuation-message construction whenever `execution.parallel` is `true` and the active task is a fresh `READY` dispatch in `task` granularity — the interpreter always evaluates it, no agent judgment gates whether the check runs (the same "script-level gate" class §13 already credits `[enforced]` for `scripts/heartbeat.sh`, not the agent-protocol-invoked `[advisory]` tier the deleted Conductor's equivalent wave rule carried). A batch requires `>=2` `READY` candidates (all deps `DONE`) named TOGETHER on one `nazgul/plan.md` `## Wave Groups` line with pairwise-disjoint `Files modified` scopes; any doubt — missing scope, overlap, no Wave Groups section, different wave lines — falls back to a batch of one, the proven sequential behavior. Batches never exceed `execution.max_parallel` (default `3`).
- **The two hard stops are unconditional — never gated, never yolo-bypassable by config.** `[enforced]` Any `BLOCKED` task or any non-`APPROVE` `security-reviewer.md` verdict halts the loop for a human. `execution_should_halt` (`scripts/lib/parallel-batch.sh`) fails CLOSED on ambiguity (`BLOCKED_TASKS_AMBIGUOUS`, `SECURITY_REJECTION_AMBIGUOUS`, `*_UNREADABLE`) and ignores every `execution.gates` value and mode, including `yolo`. `stop-hook.sh` calls it as a plain, unconditional bash `if` whenever `execution.parallel` is `true`, before any dispatch instruction is built — this extends §3.5's AFK security-rejection stop and §5's hard-block list into parallel mode, and (unlike the deleted Conductor's own agent-protocol-invoked use of the equivalent check) no LLM judgment intervenes at this call site.
- **`execution.gates.{approve_plan,approve_batch,approve_final_pr}`** (all default `false`, autonomous-first) let a human pause before the plan is accepted, before a parallel batch dispatches, or before the final PR. `[hook-driven only]` `execution_gate_effective`/`execution_should_pause` (`scripts/lib/parallel-batch.sh`) compute the EFFECTIVE value — `mode == "hitl"` flips `approve_plan` on without mutating the stored config — and `stop-hook.sh` prepends a `GATE approve_batch: ... WAIT for explicit approval` instruction ahead of the batch `DISPATCH_INSTR` when the gate is active. This is a continuation-message instruction, not a PreToolUse block: a human or orchestrator that dispatches implementers directly, bypassing the stop-hook's suggested batch, is not stopped from proceeding without approval.

---

## 12. Parallel Dispatch Enforcement

Two PreToolUse guards back the same headline invariant the deleted Conductor's dispatch/rework guards
gave the old engine — **"completed = cached, never re-executed," and a merged task's file scope stays
closed** — now keyed directly off task manifests (`nazgul/tasks/TASK-NNN.md`) instead of a separate stored
graph, since parallel dispatch has no `graph.json` mirror to go stale. Both guards no-op unless
`execution.parallel` is `true`, so a sequential-mode run is never touched.

- **Dispatch guard.** `[enforced]` `scripts/parallel-dispatch-guard.sh` — a PreToolUse guard on the `Agent` tool — denies (exit 2) re-dispatching a work unit (`implementer`, `review-gate`, `team-orchestrator`) whose task manifest status makes that dispatch wasted work, matched via the `NAZGUL_UNIT: TASK-NNN` marker every dispatch prompt carries (grepped as data, never `eval`'d). The "already done" threshold differs by subagent kind: `implementer`/`team-orchestrator` are denied once status reaches `IMPLEMENTED`/`DONE`, but `review-gate` is denied only at `DONE` — dispatching `review-gate` for an `IMPLEMENTED` unit is the required next step, not a re-dispatch. Kill-switch: `execution.enforce.dispatch_guard` (default `true`).
- **Re-work guard.** `[enforced]` `scripts/parallel-rework-guard.sh` — a PreToolUse guard on `Write|Edit|MultiEdit` — denies (exit 2) a write to a file inside the `file_scope` of a *different* task already `DONE`/`IMPLEMENTED` with a merged commit recorded in its own manifest; the actively-dispatched task is never blocked from writing inside its own scope. Its scope check reads the `Files modified` JSON array via the shared `get_task_files_modified` accessor (MF-025), replacing a comma-split parser that could never match a real bracket/quote-laden manifest value. Kill-switch: `execution.enforce.rework_guard` (default `true`).

**Both guards fail CLOSED on a genuinely unparseable config (MF-053, ADR-003 Decision 3).** `[enforced]` A *missing* `config.json` still safely no-ops as `parallel=false` (the existing `[ -f "$CONFIG" ] || exit 0` stays first). But a config that is *present* and fails `jq -e . "$CONFIG"` — a torn or corrupt write, not an absent file — now exits 2 with a named diagnostic in both `parallel-dispatch-guard.sh` and `parallel-rework-guard.sh`, instead of the prior `jq ... || echo "false"` fallback that silently disarmed the guard on exactly that ambiguity. This mirrors `scripts/lib/git-hooks.sh`'s `_gh_config_readable()` fail-closed precedent (§15).

These two guards sit underneath, not instead of, the two unconditional hard stops in §11: even with both
kill-switches set `false`, `execution_should_halt` (`scripts/lib/parallel-batch.sh`) still fails closed on
any `BLOCKED` task or non-`APPROVE` `security-reviewer.md` verdict.

---

## 13. Automation Heartbeat

`scripts/heartbeat.sh` (FEAT-008) is a trigger-agnostic tick engine: a single `bash` script (`#!/usr/bin/env bash`,
not portable POSIX `sh` — it uses bash-only parameter expansion) that reuses
the same `scripts/lib/parallel-batch.sh` hard-stop and `scripts/lib/session-tracker.sh` session libraries
§11 documents rather than reimplementing them, fired either by hand (`/nazgul:heartbeat`,
`skills/heartbeat/SKILL.md`) or by an opt-in Claude Code native
scheduled agent (routine) configured entirely outside this plugin. `hooks/hooks.json` does not wire it to
any Claude Code hook event, so whether a tick ever runs at all is a trigger the operator chooses, not
something Nazgul schedules itself.

- **Opt-in and default-off.** `[advisory]` `automation.heartbeat.enabled` defaults to `false` (`jq -r
  '.automation.heartbeat.enabled // false'`). No PreToolUse guard or stop-hook forces or blocks the
  routine that fires `scripts/heartbeat.sh` in the first place — the same "config-read, not hook-blocked"
  posture §11 already gives `execution.parallel`/gate selection. Once a tick DOES run, the
  `enabled` check is a plain, unconditional bash `if` near the top of the script: false means a
  `decision: disabled` record and `exit 0` before any inbox read, triage, or side effect.
- **The concurrency guard: never a second loop.** `[enforced]` `scripts/heartbeat.sh` calls
  `count_active_sessions` (`scripts/lib/session-tracker.sh`) — the identical session-lock mechanism
  `stop-hook.sh` uses — before archiving or starting anything; any active session forces `decision:
  skipped, reason: active_session` and `exit 0`. This is a single top-of-flow bash conditional the
  interpreter always evaluates on every invocation, not a step an agent's own protocol could choose to
  skip — the same class of internal script gate `[enforced]` already credits `stop-hook.sh` with
  elsewhere in this document (§1 Rule 4). Covered by `tests/test-heartbeat-session-guard.sh`.
- **The two hard stops are unconditional — independent of `enabled` and of `mode`, including `yolo`.** `[enforced]`
  `scripts/heartbeat.sh` calls `execution_should_halt` (`scripts/lib/parallel-batch.sh`, the
  identical fail-closed function §11/§12 document for parallel dispatch) as the very first thing it does
  on every invocation — before even reading `automation.heartbeat.enabled` — so a `BLOCKED` task or a
  non-`APPROVE` security-reviewer verdict halts the tick (`decision: hard_stop`) regardless of whether
  heartbeat is enabled or what `mode` is set to. Same reasoning as §11's parallel-dispatch usage of this
  function: this call site is a single bash line the interpreter executes unconditionally every time the
  script runs — no agent judgment intervenes, mirroring the distinction this document already draws
  between agent-protocol-invoked checks and plain script-level gates. Covered by
  `tests/test-heartbeat-hard-stops.sh` across `enabled: true`, `enabled: false`, and `mode: yolo`.
- **Idempotent atomic claim-then-archive.** `[enforced]` The picked candidate is moved into
  `<inbox>/archive/` via a single `mv -f` (`inbox_archive`, `scripts/lib/inbox-provider.sh`) BEFORE
  `/nazgul:start` is invoked — archive-then-start, so the move itself is the atomic claim: a crash
  between the two leaves the item archived (not lost, not re-pickable), and a re-run can never
  double-start it. This is a fixed, single-outcome filesystem operation in the script's own flow, not
  agent discretion. Covered by `tests/test-heartbeat-idempotency.sh` (archive-not-delete, single start
  invocation, crash-between-claim-and-start consistency).
- **No `eval` on inbox/objective text.** `[advisory]` During triage, candidate title/body only ever reach
  `jq` via `--arg`/`--argjson`/`--rawfile`, never `eval`'d or shell-interpolated
  (`scripts/lib/inbox-provider.sh`, `scripts/lib/heartbeat-triage.sh`), and
  `tests/test-heartbeat-triage.sh` proves a metacharacter-laden title/body produces no side effect. The
  one place objective text is spliced into a command string — `_hb_start`'s
  `claude -p "/nazgul:start \"$objective\" $mode_flag $par_flag"` (`scripts/heartbeat.sh`, where
  `$mode_flag`/`$par_flag` derive from `automation.heartbeat.auto_start.{mode,parallel}` — `--yolo
  --parallel` by default, but e.g. `mode: afk`/`parallel: false` resolve to `--afk` with no `--parallel`
  flag at all) — is hardened against that splice being broken out of (FEAT-008 TASK-011): `_hb_objective`
  truncates the objective to its first line at the source (`.title`/`.body` both `split("\n")[0]`), and
  `_hb_start` additionally neutralizes every embedded `"`, `\n`, and `\r` before interpolation, so a
  crafted title can no longer close the quoted span early and smuggle flags (e.g. `--max`, `--afk`) past
  `scripts/apply-start-flags.sh`'s line-bounded quoted-span strip into an unattended auto-start;
  the `NAZGUL_HEARTBEAT_START_CMD` override passes the objective as a single argv element and is
  injection-safe by construction. `tests/test-heartbeat-start-injection.sh` exercises the real
  `_hb_start` path against both the quote- and newline-breakout vectors. All of this proves today's code
  is safe; it is not a mechanical guard against a future edit reintroducing `eval` or an unescaped
  interpolation — `shellcheck` (registered for every heartbeat script in `tests/test-shellcheck.sh`)
  catches quoting and expansion hazards but does not forbid the `eval` builtin itself, so this stays a
  discipline the tests currently confirm rather than a hook that blocks regression.

Branch isolation (§10) applies unchanged: `scripts/heartbeat.sh` never commits or touches a git branch —
it only reads the inbox, moves files within it, and shells out to `/nazgul:start`, which is subject to
the same §10 tiers (the `pre-commit` git hook, §15; `local-mode-tracking-guard.sh`) as every other
objective start. No new guard and no new tier is introduced here.

## 14. Raising Findings

`scripts/lib/raise-finding.sh` (FEAT-009 TASK-009) is the PRODUCER side of a first-party
finding-raise channel: any sub-session that sources it can call `raise_finding <severity>
<category> <title> <detail> [suggested_fix] [evidence]` to surface an in-the-moment
improvement candidate that survives it exiting, rather than silently working around an
out-of-scope problem or inventing unplanned scope creep to fix it mid-task.

- **Use it instead of working around out-of-scope findings.** `[advisory]` Depends on
  agent discipline — no mechanical guard forces a sub-session to call `raise_finding`
  rather than silently ignoring or ad-hoc-fixing something outside its task's file scope.
  Implementer, team-orchestrator, and debugger sub-sessions all have Bash and
  can source the helper directly; reviewer sub-sessions cannot — `agents/templates/reviewer-base.md`
  restricts them to `Read`/`Glob`/`Grep` (§3.3) — so a reviewer instead notes the candidate
  as its own line in the returned review for a Bash-capable sub-session to raise on its behalf.
- **Data-only, no `eval`.** `[advisory]` Every field is built via `jq --arg` — no `eval`,
  no shell interpolation of caller-supplied text into a command — and embedded `\n`/`\r`
  in every value are neutralized to a space before storage (the same neutralize-before-splice
  discipline as `scripts/heartbeat.sh`'s `_hb_start`, §13), so a metacharacter- or
  newline-laden title can never execute or break the markdown-backlog `##`-section
  structure `self-audit.sh` later renders it into. `tests/test-raise-finding.sh` proves
  today's code is safe; like §13's equivalent note, this is not a mechanical guard against
  a future edit reintroducing `eval`.
- **Append-only sink.** `[advisory]` One JSONL line — `ts`, `agent` (`$NAZGUL_AGENT`, empty
  when unset), `unit` (`$NAZGUL_UNIT`, empty when unset), `severity`, `category`, `title`,
  `detail`, `suggested_fix`, `evidence` — is appended per call to
  `nazgul/logs/findings.jsonl` (created if absent), guarded by `flock` when available
  (mirrors `scripts/lib/emit-event.sh`). Consumed by `scripts/self-audit.sh` (TASK-001),
  which ingests the file into the improvements backlog; this task is producer-only and
  never edits that consumer.

## 15. Git-Level Guards

FEAT-010 (ADR-001) replaces the two guards that tried to infer git intent by parsing an arbitrary Bash
command string — the old `base-branch-commit-guard.sh` and the deferred H2 pre-merge verdict guard —
with real git hooks. Both proved non-convergent across three review rounds each: shell parameter
expansion, line continuation, and wrapper forms (`eval`, `bash -c`, path-qualified `git`) kept
reopening bypasses no finite tokenizer closed. Moving enforcement inside git itself removes the command
string from the equation entirely — a hook only runs once the shell has fully resolved what git was
actually asked to do.

- **`pre-commit` — base-branch guard.** `[enforced]` `scripts/git-hooks/pre-commit` blocks a commit
  on `branch.base` while `branch.feature` is set, reading `nazgul/config.json` from the repo the hook
  itself runs in (`git rev-parse --show-toplevel`) — this is the fix for the old guard's cwd
  false-positive (it always resolved `$CLAUDE_PROJECT_DIR`'s branch, blocking commits to an unrelated
  repo) and its `git -C` false-negative (which routed around a Bash-string check entirely). A git hook
  has no such ambiguity: "current branch" is whatever repo git itself is invoked in.
- **`pre-merge-commit` — H2 parallel-unit verdict guard.** `[enforced]` `scripts/git-hooks/pre-merge-commit`
  blocks `git merge --no-ff` of a parallel-dispatched task unit whose manifest under `nazgul/tasks/`
  records the merged commit in its `## Commits` section but is not yet `Status: DONE`. Only active when
  `execution.parallel == true` and `execution.enforce.premerge_guard` (default `true`) is not explicitly
  `false`. Identity is resolved from git's `GITHEAD_<sha>` environment variables (keyed by the actual
  merged commit's content hash, so a decoy value can't relabel an unapproved unit as an approved one)
  rather than `GIT_REFLOG_ACTION`, which a caller can pre-set to spoof the same claim.
- **Generic chain-dispatcher preserves user hooks.** `[enforced]` Pointing `core.hooksPath` at a
  managed directory would otherwise silently disable any hook a user already had installed under every
  *other* standard githooks(5) name. `scripts/git-hooks/_dispatch.sh` forwards argv/stdin/exit code to
  whatever hook previously occupied that name (recorded prior `core.hooksPath`/`.git/hooks` location),
  and every standard hook name Nazgul does not itself define ships as a thin shim that does nothing but
  call the dispatcher — so a pre-existing `commit-msg` or `pre-push` hook keeps running unmodified.
- **Activation: `core.hooksPath` → `nazgul/.githooks/`.** `[hook-driven only]` `scripts/lib/git-hooks.sh`
  installs the two guards, the dispatcher, and the pass-through shims into the per-project managed
  directory `nazgul/.githooks/`, then points `git config core.hooksPath` at it — never editing a file
  the user owns. Gated on `guards.git_hooks` (default `true`); an explicit `false` makes install and
  self-heal no-ops. `uninstall_git_hooks` is not gated on the toggle — it always restores whatever
  prior `core.hooksPath` was recorded, so flipping the toggle mid-loop can't strand a recorded value.
- **Install/uninstall/self-heal lifecycle, tied to the loop's own boundaries.** `[hook-driven only]`
  `install_git_hooks` runs inside `create_feature_branch`/`setup_worktree_dir`
  (`scripts/worktree-utils.sh`) at the moment `branch.feature` is assigned, first durably recording the
  live `core.hooksPath` (or its absence) into `branch.prior_hooks_path` so uninstall can restore it
  exactly. `uninstall_git_hooks` runs inside `cleanup_all_worktrees` at objective completion, restoring
  that recorded value verbatim. All five of `skills/start/SKILL.md`'s branch-setup sites call
  `create_feature_branch` (MF-034: previously inline prose, so the lifecycle above was never actually
  invoked in production despite the library functions being correct), and `agents/review-gate.md` /
  `agents/team-orchestrator.md` merge tasks back via `merge_task_to_feature()` (`git -C`-safe, closing
  the worktree-cwd escape MF-035 depended on) instead of a `cd <main_worktree_path>` convention.
  `self_heal_git_hooks` runs from `scripts/session-context.sh`'s `SessionStart` self-heal block and is
  now two layers: when `guards.git_hooks` is true, `branch.feature` is set, and `branch.prior_hooks_path`
  is still `null` (an active objective whose branch-setup call site never installed), it performs a
  first-time `install_git_hooks` — narrow defense-in-depth for the residual MF-034 gap; otherwise it
  re-asserts the managed path only on detected drift, never a blind overwrite of an intentional
  mid-session change. All call sites are agent-protocol/skill-driven (worktree setup, objective
  completion, session start), not a PreToolUse guard, so a manually-dispatched agent that never calls
  `create_feature_branch()` (or reaches `SessionStart` with `branch.feature` still unset) gets no guard
  installed at all — the honest gap this tier label exists to state.

**Enforcement tier, stated honestly (ADR-001 Consequences).** Once installed, the two guards above are
tagged `[enforced]` — but they are stronger than every other `[enforced]` entry in this document: they
run outside the Claude Code session entirely, after the shell has fully resolved the command, so they
hold even against a human typing `git commit`/`git merge` directly or a hypothetical bypass of every
PreToolUse guard here (the Legend's tier-1 row now notes this). *Installation* is the honest gap: it is
not itself mechanically forced onto every code path that could start a loop or invoke git; it depends on
the loop's own protocol calling `create_feature_branch()`/`setup_worktree_dir()`, same limit this
document already applies to other protocol-invoked checks (e.g. §14's `raise_finding` call sites). A
repo where install never ran, and no `SessionStart` has fired since `branch.feature` was assigned, has no
guard at all yet — self-heal's first-time-install layer (above) closes the common case (a loop whose
branch-setup call site never ran `create_feature_branch`) at the next `SessionStart`, but a repo that
never reaches either call site stays unguarded indefinitely.

## 16. GitHub Connector

`scripts/lib/connector-github.sh` (FEAT-012, ADR-001) is the first real remote provider behind the
generalized provider seam FEAT-008 introduced (`scripts/lib/inbox-provider.sh`). It is a two-way GitHub
connector: PULL (`connector_github_pull_list`/`pull_get`/`pull_archive`) turns opt-in-labeled issues into
inbox candidates, and PUSH (`connector_github_push_status`/`push_pr`) reflects local task status and PR
links back onto the mapped issue. `scripts/lib/inbox-provider.sh` routes the `inbox_*` calls to the
connector only when `automation.heartbeat.inbox.provider == "github"`; the `file` provider path stays
byte-identical. Both directions are wired into the running loop (FEAT-012 TASK-008): `scripts/heartbeat.sh`
consumes the `github` provider on the pull side, and `scripts/stop-hook.sh` pushes on a task transition.
Linear/Slack are follow-on providers behind the same seam; they are not shipped.

- **Opt-in and default-off.** `[advisory]` `connectors.github.enabled` defaults to `false` (and push is
  separately gated by `connectors.github.push.enabled`, default `true` but only active under the
  top-level `enabled`). No PreToolUse guard forces or blocks the connector; the gate is a plain `jq`
  read near the top of each entry point (`heartbeat.sh`'s provider dispatch, `stop-hook.sh`'s push
  block) — disabled means the loop behaves exactly as it did before, with the `file` inbox and no push.
- **Credentials via `gh auth` only — never stored or logged.** `[advisory]` Every GitHub call shells out
  to the `gh` CLI, which reads its own auth; no token is ever written to `config.json`, printed to a log,
  or `eval`'d. `migrate_24_to_25` adds no credential key. This is a code-and-review discipline confirmed
  by `tests/test-connector-github.sh`, not a mechanical secret-scanner.
- **Remote content is DATA.** `[advisory]` Issue title/body reach `jq` only via `--arg`/`--rawfile` and
  are only ever passed as `gh` argv elements — never shell-interpolated or `eval`'d. A hostile body is
  bounded by `connectors.github.pull.max_body_bytes` (default 65536), and malformed/absent JSON skips the
  candidate rather than crashing. Same honest tier as §13's inbox data-only rule: `shellcheck` catches
  quoting hazards but does not forbid a future `eval`, so the tests confirm today's code, not a regression
  block.
- **Sync-storm guard: a push never un-claims an issue.** `[enforced]` (in-script) On claim,
  `connector_github_pull_archive` adds `connectors.github.pull.claimed_label` (default `nazgul-claimed`)
  and records a remote-issue ↔ local-id entry in `connectors.github.map`; `pull_list` excludes both the
  claimed set and mapped issues. `push_status` only ever touches the `nazgul-status:*` label namespace
  (removing stale ones, upserting one) and `push_pr` only upserts a single `<!-- nazgul-pr -->`-marked
  comment — neither removes the opt-in or claimed label, so a pushed update can never make an issue
  re-enter `pull_list`. This is a fixed property of the script's own label/namespace separation, not a
  hook.
- **Degrade-safe failure counter.** `[enforced]` (in-script) A failed pull after retry bumps
  `connectors.github.pull_failures`; at 5 consecutive failures the connector auto-disables
  (`enabled=false`) with a `stderr` warning, and a good pull resets the counter to 0. Auth/network/
  rate-limit faults degrade to a no-op — the heartbeat tick and the stop-hook push are wrapped so a
  connector error never blocks or crashes the loop. Covered by `tests/test-connector-github.sh`.

## 17. Teammate Report Contract

In Agent Teams mode a teammate's final plain text is delivered to NO ONE —
SendMessage is the only live channel, and nothing platform-side forces a
teammate to use it. Nazgul therefore defines a teammate's deliverable as a
FILE, enforced in three layers:

1. **Prompt contract** `[advisory]` — every teammate dispatch ends with the
   Report Contract block (`templates/skill-partials/report-contract.md`)
   naming an explicit `report_path`.
2. **Dispatch manifest** `[advisory]` — before spawning, the dispatcher writes
   `nazgul/dispatch/<session-name>.json` (`teammate`, `report_path`, `feat_id`,
   `spawned_at`, `spawned_at_epoch`, `blocks`). Deleted at team teardown.
   Note: the §3.3 read-only guarantee applies to subagent-dispatched
   reviewers persisted by the review-gate orchestrator; reviewer teammates in
   Agent Teams mode must be spawned with Write access scoped to their single
   report file, or the dispatcher must point `report_path` at lead-persisted
   output.
3. **TeammateIdle guard** `[enforced]` — `scripts/teammate-idle-guard.sh`
   blocks a manifest-registered teammate from idling while its `report_path`
   is missing/empty (exit 2 with the fix instruction), at most 3 times per
   teammate, then fails open with an escalation line in
   `nazgul/logs/teammate-idle.jsonl` (which also records every raw payload as
   schema telemetry). Fails OPEN on unparseable payloads, unknown teammates,
   and stale `feat_id` — a deliberate inversion of the PreToolUse guards'
   fail-closed rule, because blocking on garbage strands live teammates.
   Kill-switch: `execution.enforce.teammate_report_guard` (default `true`).
   Known limitation: the guard resolves `nazgul/` via
   `CLAUDE_PROJECT_DIR`/cwd, so a teammate whose session resolves to a git
   worktree without the shared `nazgul/` runtime exits untracked (no
   enforcement, no telemetry) — worktree-aware resolution
   (`git rev-parse --git-common-dir` / `branch.main_worktree_path`) is a
   known follow-up.

Completion signal = idle notification + report file on disk. SendMessage is
coordination-only courtesy, never the report channel.
