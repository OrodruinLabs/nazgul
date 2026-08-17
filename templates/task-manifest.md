---
status: PLANNED
---
# TASK-000: [Task Title]

## Metadata
<!-- All metadata fields are required. Agents update these on every state transition.
     The stop hook reads these fields to build checkpoint JSON.
     The session-context hook reads these to produce recovery instructions. -->
- **ID**: TASK-000
- **Group**: 0
- **Status**: (see `status:` in the frontmatter block at the top — that is canonical, read by scripts/lib/structured-state.sh; not duplicated here to avoid drift)
<!-- Valid states: PLANNED | READY | IN_PROGRESS | IMPLEMENTED | IN_REVIEW | APPROVED | CHANGES_REQUESTED | DONE | BLOCKED | CANCELLED
     State machine rules — NO skipping states:
       PLANNED -> READY (when all depends_on tasks are DONE, or APPROVED in YOLO)
       READY -> IN_PROGRESS (when implementer claims the task)
       IN_PROGRESS -> IMPLEMENTED (when code complete + tests pass + lint clean)
       IMPLEMENTED -> IN_REVIEW (when review gate picks up the task)
       IN_REVIEW -> DONE (when ALL reviewers APPROVED, non-YOLO)
       IN_REVIEW -> APPROVED (when ALL reviewers APPROVED, YOLO + task-pr only)
       IN_REVIEW -> CHANGES_REQUESTED (when ANY reviewer rejects)
       APPROVED -> DONE (when the Task-PR merges, YOLO + task-pr only)
       CHANGES_REQUESTED -> IN_PROGRESS (when implementer addresses feedback)
       IN_PROGRESS/CHANGES_REQUESTED -> BLOCKED (when max retries hit or unresolvable)
       IMPLEMENTED -> DONE (ONLY with verified `## Merge Evidence` below — never unconditional)
       <any non-terminal state> -> CANCELLED (operator declares the task will never ship, via
         /nazgul:task skip; refused out of a `Blocked kind: reconciliation` quarantine)
     DONE and CANCELLED are both terminal — neither has an out-edge. -->
- **Depends on**: none
<!-- Comma-separated task IDs, e.g. TASK-001, TASK-002
     Task cannot move to READY until every dependency SATISFIES the gate, which is not the same as
     being DONE (`ttg_dependency_satisfied`, scripts/lib/task-transition-guard.sh):
       review_gate.granularity = task     -> DONE (or APPROVED in YOLO)
       review_gate.granularity = group|feature -> IMPLEMENTED, IN_REVIEW, APPROVED, or DONE, because
         every task parks at IMPLEMENTED until ONE aggregate board and DONE is unsatisfiable there
       any granularity                    -> CANCELLED also satisfies: a task that will never ship is
         a dependency that will never be met, so the id STAYS on this line rather than being deleted
     The stop hook auto-promotes PLANNED -> READY when deps are met. -->
- **Delegates to**: none
<!-- Specialist agents this task delegates to, e.g. designer, frontend-dev
     The implementer writes delegation briefs to nazgul/tasks/TASK-000-delegation.md -->
- **Files modified**: []
<!-- List of all files this task will create or modify (populated by planner from File Scope).
     Used by wave analysis to detect file overlap between tasks. -->
- **Wave**: 0
<!-- Wave number assigned by the planner's wave analysis.
     Tasks in the same wave can execute in parallel safely. -->
- **Traces to**: none
<!-- Traceability back to project documents. See Traceability section below. -->
- **Created at**: <!-- ISO 8601 timestamp, e.g. 2026-02-27T10:00:00Z -->
- **Claimed at**: <!-- Set when implementer claims the task (READY -> IN_PROGRESS) -->
- **Implemented at**: <!-- Set when implementation complete (IN_PROGRESS -> IMPLEMENTED) -->
- **Completed at**: <!-- Set when all reviewers approve (IN_REVIEW -> DONE) -->
- **Blocked at**: <!-- Set if task becomes BLOCKED -->
- **Retry count**: 0/3
<!-- Incremented each time task goes through CHANGES_REQUESTED -> IN_PROGRESS cycle.
     When retry_count >= max_retries_per_task (from config.json), task becomes BLOCKED. -->
- **Base SHA**: <!-- 40-hex SHA of the commit this task branched from. Written by the Planner at
     manifest creation or by the implementer at claim time (agents/implementer.md Task Selection
     step 3). Read by `ttg_verify_commit_evidence` (scripts/lib/task-transition-guard.sh) to prove the
     SHA recorded under `## Commits` is a strict descendant of this one — i.e. real forward progress,
     not just a pre-existing reachable commit. If absent, the gate degrades to existence-only and
     announces it on stderr; it does not fail closed. -->

## Commits
<!-- Populated by the implementer when transitioning IN_PROGRESS -> IMPLEMENTED (agents/implementer.md
     step 11) — required before that transition; the state guard blocks it without at least one entry.
     One bullet per commit: the full 40-hex SHA from `git rev-parse HEAD`, bare (no backticks), an em
     dash, then the commit subject. Set it before any merge — the branch-tip commit for this task, per
     the review-then-merge ordering (RULES.md §11). The `## Commits` heading IS the enforcement
     boundary for the IMPLEMENTED gate — `ttg_verify_commit_evidence` reads only what falls under it,
     and the recorded SHA must resolve AND be a strict descendant of `Base SHA` above. Short and
     backticked forms still resolve, so the full-40-hex-bare form remains a cross-manifest consistency
     rule, not a matching requirement.

     Example:
     - f81e1b25d6b513c5f8c46bb65f25acd970016f8c — feat(FEAT-001): TASK-001 implement user model -->

## Red-Run Evidence
<!-- Populated by scripts/red-run.sh before IN_PROGRESS -> IMPLEMENTED: proof that this task's
     new/changed tests FAILED against the pre-change tree. A test written to confirm its author's
     implementation is not a test (FEAT-028 charter, deliverable 1).

     The `## Red-Run Evidence` heading IS the enforcement boundary for the IMPLEMENTED gate —
     `ttg_verify_red_run_evidence` (scripts/lib/task-transition-guard.sh) reads only what falls under
     it, exactly as `ttg_verify_commit_evidence` reads only what falls under `## Commits`. A
     `red-run:` token anywhere else in this manifest is invisible to the gate.

     One `- red-run:` bullet per entry. The gate verifies referential integrity, never semantics: the
     named test path exists in the worktree, `pre-change-ref` resolves to a real commit and is an
     ancestor of a SHA recorded under `## Commits`, and `result:` records a NON-ZERO exit. Whether the
     failure was meaningful is the qa-reviewer's blocking question.

     When no meaningful pre-change red run exists, record one specifically applicable enumerated
     exemption. The list is CLOSED — docs-only, comment-only, revert, fixture-capture-only — and free
     text is rejected. The gate validates exact list membership; the qa-reviewer judges whether the
     selected exemption is truthful.

     Example:
     - red-run: tests/test-foo.sh :: case "guard blocks a 6-line run in a .sh file"
       - pre-change-ref: 8f2c1ad3c0be1f5e2a9d47bb0c1e6d3a51f7b902
       - result: FAILED (exit 1) — "FAIL: guard blocks a 6-line run in a .sh file"
       - captured-by: scripts/red-run.sh at 2026-08-04T11:02:31Z
     - red-run: N/A — docs-only -->

## Merge Evidence
<!-- Populated by scripts/close-objective.sh (/nazgul:complete), the SOLE writer of this section.
     No agent hand-writes it. The closer asks the host about the PR through the merge-provider seam
     (scripts/lib/merge-provider.sh) and writes these fields only when the host answered `ok` AND
     reported the PR merged; every other seam outcome is a named skip and nothing is written.

     This is what makes IMPLEMENTED -> DONE reachable at all — work that merged outside the loop can
     be closed on the host's answer instead of on a hand-edited `status:` field. For IN_REVIEW -> DONE
     it is an ALTERNATIVE to the review route, never a bypass: the review route is evaluated first and
     the accepted route is always named on stderr.

     The `## Merge Evidence` heading IS the enforcement boundary — `ttg_verify_merge_evidence`
     (scripts/lib/task-transition-guard.sh) reads only what falls under it, exactly as
     `ttg_verify_commit_evidence` reads only what falls under `## Commits`. A `host:` or `pr:` line
     anywhere else in this manifest is invisible to the gate.

     THE SHAPE CHECK IS ONLY THE FIRST HALF. The gate does not stop at counting fields: it calls
     `merge_provider_pr_state` and admits the edge ONLY when the host answered `result: "ok"` AND
     `merged: true`, and when the host's own `merged-at`, `merge-commit` and head branch match what
     is recorded here. A gate that stopped at the shape would certify whoever typed the lines, which
     is the forgery route this section exists to remove.

     AND IT ASKS WHOSE PR IT IS, AND WHOSE TASK. "Is PR N merged?" is not the question — "did THIS
     objective ship as PR N, and is this one of its tasks?" is. `head-ref` must equal the head branch
     the host reports, and that branch must be this objective's `branch.feature` or the branch of the
     `stack.layers[]` entry registered for its `feat_id`; and this manifest must be listed in the
     `## Tasks` roster of the objective's own nazgul/plan.md, whose frontmatter `feat_id` must agree
     with config's. Without the first binding a genuinely merged PR of ANY other objective would be
     real, host-verified evidence for closing any task on disk; without the second, this objective's
     own genuine merge would close every other objective's stranded manifests too.

     Six required fields, each shape-checked — `host`, `pr`, `merged-at`, `merge-commit`, `head-ref`,
     `recorded-by` — and nine closed refusal reasons: `absent` (no section, or one with nothing in
     it), `commented_out` (content present but only inside an HTML comment: a comment is not a record,
     and this template's own block reads as exactly that), `truncated` (a required field is missing),
     `malformed` (a field is present but fails its shape check, including a `recorded-by` naming
     something outside the closed producer set), `not_merged` (the host ANSWERED and says this PR is
     not merged), `unverifiable` (the host could not be asked, or answered unusably, or reported
     merged without returning the fields to compare against), `contradicted` (the host answered and
     its `merged-at`, its `merge-commit`, its head branch, or the merge commit's containment in the
     base disagrees with this section), `not_this_objective` (the host confirms the merge, but of a
     PR that is not this objective's), and `not_this_objectives_task` (it IS this objective's merged
     PR, but this manifest is not in this objective's roster — or no roster could be read at all).
     Each emits `merge_evidence_missing`. `unverifiable` and
     `not_merged` are separate on purpose: "could not look" is not "not merged". There is NO kill
     switch: a switch on the last gate before DONE would be the bypass.

     Git ancestry is corroboration and never a predicate — after a server-side squash no SHA recorded
     under `## Commits` reaches the merge commit, so `squash_signature` is the expected reading there
     and is recorded, not blocked on.

     Example (all six fields — a block missing any one of them is refused as `truncated`). Every
     value below is deliberately unresolvable against any real host: an example that names a real
     merged PR and its real merge commit is a working forgery skeleton shipped inside the artifact
     this gate polices.
     - **host**: example.invalid
     - **pr**: 999999
     - **merged-at**: 2026-01-01T00:00:00Z
     - **merge-commit**: 0000000000000000000000000000000000000000
     - **head-ref**: feat/EXAMPLE-000-example-objective
     - **recorded-by**: scripts/close-objective.sh (host API, ok) -->

## Description
<!-- Clear, specific description of what this task accomplishes.
     Written by the Planner. Should be understandable without reading other tasks.
     Include enough context that the implementer can work without re-reading the full plan.

     Example:
     Create the User model with email, password_hash, created_at, and updated_at fields.
     Use the existing database setup in src/db/. Follow the Product model pattern exactly.
     Include a unique constraint on email and auto-managed timestamps. -->

## Acceptance Criteria
<!-- Specific, testable criteria. Each must be independently verifiable.
     The implementer checks these off during implementation.
     The review board verifies these during review.
     Max 3 criteria per task (if more needed, split the task).

     Example:
     - [ ] User model created at src/models/user.ts with all required fields
     - [ ] Migration created in src/db/migrations/ with unique email constraint
     - [ ] Unit tests pass in tests/models/user.test.ts (minimum 3 test cases) -->
- [ ] <!-- Criterion 1 -->
- [ ] <!-- Criterion 2 -->
- [ ] <!-- Criterion 3 -->

## Pattern Reference
<!-- The specific file(s) and line range(s) the implementer should study before coding.
     These show how similar things are already done in this codebase.
     The Planner sets this based on discovery context files.
     NEVER leave this empty — every task must follow an existing pattern or document why not.

     Example:
     Follow the existing Product model pattern in:
     - Model: src/models/product.ts (lines 1-45)
     - Migration: src/db/migrations/002_create_products.ts
     - Tests: tests/models/product.test.ts (lines 1-60) -->

## File Scope
<!-- Explicit list of files this task will create or modify.
     CRITICAL for parallel execution: tasks in the same parallel group MUST NOT overlap.
     The pre-tool-guard warns if an implementer touches files outside this scope. -->

**Creates**:
<!-- Files that do not exist yet and will be created by this task.
     Example:
     - src/models/user.ts
     - src/db/migrations/003_create_users.ts
     - tests/models/user.test.ts -->

**Modifies**:
<!-- Existing files that will be changed by this task.
     Example:
     - src/models/index.ts (add export for User model) -->

## Traceability
<!-- Links this task back to project documents generated by the doc-generator.
     Every task MUST trace to at least one PRD acceptance criterion (if PRD exists).
     The Planner sets these during planning. Reviewers verify traceability during review. -->
- **PRD Acceptance Criteria**: <!-- e.g. #3 ("Users can complete checkout in under 10 seconds") -->
- **TRD Component**: <!-- e.g. PaymentService (src/services/payment.ts) -->
- **ADR Reference**: <!-- e.g. ADR-001 (Stripe over PayPal — lower fees, better API) -->

## Implementation Log
<!-- Appended by the implementer during each attempt.
     Each attempt records: what was done, test results, lint results, commit SHA.
     This log is the ground truth for what happened — survives compaction via file. -->

### Attempt 1
<!-- Example:
     **Started**: 2026-02-27T10:05:00Z
     **Actions**:
     - Created src/models/user.ts with fields: email (string, unique), password_hash (string), created_at (datetime), updated_at (datetime)
     - Created migration 003_create_users.ts with CREATE TABLE, unique index on email
     - Added User export to src/models/index.ts
     - Created tests/models/user.test.ts with 5 test cases (create, read, update, delete, duplicate email)
     **Test results**: 5/5 passing
     **Lint results**: clean (0 errors, 0 warnings)
     **Commit**: `feat(FEAT-001): TASK-001 implement user model` (sha: f81e1b25d6b513c5f8c46bb65f25acd970016f8c) -->

## Review Results
<!-- Populated by the review-gate agent after each review cycle.
     Each reviewer's verdict is also written to nazgul/reviews/TASK-000/[reviewer-name].md
     This section is a summary for quick reference.
     Confidence scores below the threshold (default 80) are non-blocking CONCERN items. -->

### Attempt 1
<!-- Example:
     - architect-reviewer: APPROVED (confidence: 92) — follows existing model pattern correctly
     - code-reviewer: APPROVED (confidence: 88) — naming consistent, tests thorough
     - security-reviewer: APPROVED (confidence: 95) — password_hash not exposed in model toJSON
     - qa-reviewer: CONCERN (confidence: 72) — could add edge case test for empty email [non-blocking]

     **Verdict**: ALL_APPROVED
     **Completion commit**: `feat(FEAT-001): TASK-001 complete` (sha: ghi9012) -->

<!-- If CHANGES_REQUESTED:
     - architect-reviewer: APPROVED (confidence: 90)
     - code-reviewer: CHANGES_REQUESTED (confidence: 85) — missing input validation on update endpoint
     - security-reviewer: APPROVED (confidence: 88)

     **Verdict**: CHANGES_REQUESTED
     **Blocking issues**: 1
     **Consolidated feedback**: nazgul/reviews/TASK-000/consolidated-feedback.md -->
