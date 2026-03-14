# Hydra Governance

How decisions are made, conflicts resolved, and rules enforced within the Hydra Framework.

---

## Decision Authority Matrix

Not all agents have equal authority. This matrix defines who can make what decisions.

### Unilateral Decisions (Agent Decides Alone)

| Agent | Can Decide |
|-------|-----------|
| **Discovery** | Project classification, which agents to spawn, which reviewer templates to apply, context file content |
| **Doc Generator** | Document content, which documents to generate (per classification matrix) |
| **Planner** | Task decomposition, dependency ordering, task grouping, priority assignment |
| **Implementer** | Implementation approach within task scope, which files to modify, when to delegate to specialists |
| **Each Reviewer** | Their own verdict (APPROVE / REJECT / CONCERN) and confidence score |
| **Feedback Aggregator** | How to consolidate multiple reviewer feedbacks into actionable items |
| **Stop Hook** | Whether to continue or stop the loop (based on exit conditions) |

### Requires Consensus (Multiple Agents)

| Decision | Who Decides | Rule |
|----------|------------|------|
| Task passes review | ALL active reviewers | Unanimous APPROVE required |
| Task is blocked | Implementer OR Review Gate | Either can block; requires human to unblock |
| Post-loop is complete | All post-loop agents | Each must complete their phase |

### Requires Human Approval (HITL Mode)

| Decision | When Human Approves |
|----------|-------------------|
| Project classification | HITL mode only — AFK auto-classifies |
| Generated documents | HITL mode only — AFK auto-approves |
| Task plan | HITL mode only — AFK auto-approves |
| Unblocking a task | Always (unless user configured auto-unblock) |
| Security rejections | Always in AFK/YOLO mode |
| New objective (when active work exists) | HITL mode — AFK auto-archives |
| Tool installation (greenfield scaffolding) | HITL mode — YOLO auto-installs |

### Cannot Be Decided By Any Agent

| Decision | Who Decides | Why |
|----------|------------|-----|
| Overriding the 10 Rules | Nobody during operation | Constitutional (see CONSTITUTION.md Article X) |
| Skipping the review gate | Nobody | Constitutional (Rule 5) |
| Marking DONE without all approvals | Nobody | Constitutional (Article IV) |
| Executing hard-blocked commands | Nobody | Pre-tool guard enforces unconditionally |

---

## Conflict Resolution

### Reviewer Disagreement

When reviewers disagree (one APPROVES, another REJECTS):

1. The REJECT takes precedence. The task goes to CHANGES_REQUESTED.
2. The Feedback Aggregator consolidates all feedback, noting which reviewers approved and which rejected.
3. The Implementer addresses ONLY the blocking issues (REJECT items). Approved aspects are not re-worked.
4. On re-review, each reviewer evaluates independently again. A previously-approving reviewer may now reject if the fix introduced new issues.

### Confidence Conflicts

When a reviewer reports a finding with borderline confidence:

- Below 80: Non-blocking CONCERN. Logged but does not block the task.
- At or above 80 with HIGH/MEDIUM severity: Blocking REJECT.
- The threshold is configurable (`review_gate.confidence_threshold`) but applies uniformly to all reviewers.

### Reviewer Output Format

Every reviewer finding MUST include these fields:

| Field | Required | Description |
|-------|----------|-------------|
| Severity | Yes | HIGH, MEDIUM, or LOW |
| Confidence | Yes | 0-100 score indicating certainty |
| File | Yes | Path to the file containing the issue |
| Category | Yes | e.g., security, performance, correctness, style |
| Verdict | Yes | APPROVE, REJECT, or CONCERN |
| Issue | Yes | Description of the problem found |
| Fix | Yes | Suggested resolution |
| Pattern Reference | No | Link to existing pattern that should be followed |

Reviews missing required fields are invalid and must be regenerated. The Review Gate validates review format before processing verdicts.

### Implementation Approach Conflicts

When the Implementer's approach conflicts with reviewer feedback:

1. Reviewer feedback takes priority on the first retry.
2. If the same issue recurs after addressing feedback, the Implementer documents the conflict in the task manifest under "Attempted Approaches."
3. After max retries (default: 3), the task is BLOCKED for human resolution.
4. The human can unblock with new guidance, skip the task, or override.

### Specialist Delegation Conflicts

When a specialist agent (e.g., Frontend Dev) produces work that the Implementer disagrees with:

1. The Implementer is the coordinator. It can request revisions via an updated delegation brief.
2. If unresolved, the implementation proceeds to review. Reviewers are the final arbiter.
3. The Implementer must not silently discard specialist work.

---

## Escalation Paths

### Automatic Escalation

| Trigger | Escalation | Action |
|---------|-----------|--------|
| 3 consecutive test failures | Task BLOCKED | Write test output to `hydra/reviews/[TASK-ID]/test-failures.md`. Requires human investigation. |
| Max retries exceeded | Task BLOCKED | Document all attempted approaches. Requires human decision. |
| Security rejection in AFK mode | Task BLOCKED | Requires human review. |
| Security blocker vs other blockers | Different handling | Security blockers require human unblock (cannot auto-resolve even in YOLO mode). Other blockers may be auto-resolved by `/hydra:task unblock`. |
| Git conflicts detected | Task BLOCKED | Merge conflicts need manual resolution. |
| 5 consecutive iterations with no progress | Loop STOPS | Suggests human review of blocked tasks and plan. |
| AFK timeout exceeded | Loop STOPS | Session time limit reached. Human resumes when ready. |
| Context rot (8+ iterations since compaction) | WARNING | Recommends running `/compact`. Does not block. |

### Manual Escalation

Users can intervene at any time:

| Action | Command |
|--------|---------|
| Pause the loop | `/hydra:pause` |
| Check status | `/hydra:status` |
| View history | `/hydra:log` |
| Unblock a task | `/hydra:task unblock TASK-NNN` |
| Skip a task | `/hydra:task skip TASK-NNN` |
| Add a task | `/hydra:task add "description"` |
| Reset everything | `/hydra:reset` |
| Edit task directly | Edit `hydra/tasks/TASK-NNN.md` manually |

---

## Mode Governance

### HITL (Human-in-the-Loop) — Default

- Human approves classification, documents, and plan before execution
- Human is consulted on blockers
- Human can intervene at any iteration
- No auto-commits (unless configured)

### AFK (Autonomous)

- Classification, documents, and plan proceed automatically
- Auto-commit on every state transition with dynamic prefix from config (e.g., `feat(#42):`)
- Security rejections auto-block (human reviews later)
- Blockers are logged; human reviews asynchronously
- Session time limit enforced (`afk.timeout_minutes`)

### YOLO (Full Berserk)

- Everything in AFK, plus zero permission prompts
- Requires `claude --dangerously-skip-permissions`
- Pre-tool guard still blocks genuinely destructive commands
- Designed for overnight/unattended runs on trusted codebases
- Maximum trust, maximum speed, minimum safety net

The mode is set at loop start and stored in `config.json`. It governs which decisions require human approval (see Decision Authority Matrix above).

---

## Document Generation Authority

The Doc Generator runs after Discovery and before the Planner. Its authority and rules:

### Decision Authority

- **Doc Generator decides document content unilaterally.** No other agent may override document content.
- **Classification determines which documents are generated.** The Document Generation Matrix maps project type to required documents:

| Document | Greenfield | Brownfield | Refactor | Bugfix | Migration |
|----------|-----------|------------|----------|--------|-----------|
| PRD | Full | Feature-scoped | — | — | Feature parity |
| TRD | Full | Feature-scoped | Target architecture | — | Target stack |
| ADR | Key decisions | New decisions | Why refactor | — | Why migrate |
| Test Plan | Full strategy | Feature tests | Regression suite | Regression test | Migration validation |
| Migration Plan | — | — | — | — | Full |
| Root Cause Analysis | — | — | — | Full | — |
| Rollback Plan | — | — | Full | — | Full |

### Approval Gates

- **HITL mode**: Documents require human review before the Planner runs. The user may request revisions.
- **AFK mode**: Documents are auto-generated and auto-approved. The Planner consumes them immediately.
- **All documents** are written to `hydra/docs/` and logged in `hydra/docs/manifest.md`.

---

## Specialist Delegation Protocol

The Implementer delegates to specialist agents for domain-specific work. Delegation is never automatic — the Implementer decides when and to whom.

### Delegation Triggers

| Task Type | Delegation Chain |
|-----------|-----------------|
| UI/frontend tasks | Implementer → Designer (specs) → Frontend Dev (implementation) |
| Mobile tasks | Implementer → Mobile Dev |
| Infrastructure tasks | Implementer → DevOps |
| CI/CD tasks | Implementer → CI/CD (consumes DevOps infrastructure specs) |
| Database schema tasks | Implementer → DB Migration |

### Delegation Brief Format

Every delegation is formalized in a brief at `hydra/tasks/[TASK-ID]-delegation.md`:

- **Task context**: What the broader task is about
- **Specific scope**: Exactly what the specialist should implement
- **Expected output**: Files to create/modify, format requirements
- **Constraints**: Technology choices, pattern references, performance requirements
- **Return protocol**: Specialist completes work and returns control to Implementer

### Rules

1. The Implementer decides WHEN to delegate (unilateral authority)
2. Specialists implement ONLY within the brief's scope
3. Specialists return control to the Implementer when complete
4. The Implementer may request revisions via an updated brief
5. If a specialist and Implementer disagree, the implementation proceeds to review — reviewers are the final arbiter
6. The Implementer must not silently discard specialist work

---

## Feedback Aggregator Priority Rules

When the Feedback Aggregator consolidates feedback from multiple reviewers, it follows a strict priority order:

### Priority Order

1. **Security findings** — Always first. Security findings are always blocking regardless of confidence score.
2. **Correctness issues** — Logic errors, broken functionality, missing edge cases.
3. **Style concerns** — Naming, formatting, code organization.

### Contradiction Handling

When reviewers contradict each other (e.g., one says "use approach A", another says "use approach B"):

- **HITL mode**: Flag the contradiction for human decision. Present both perspectives with reasoning.
- **AFK mode**: The majority opinion wins. If evenly split, the higher-confidence finding takes precedence.

### Output

Consolidated feedback is written to `hydra/reviews/TASK-NNN/consolidated-feedback.md` with:
- All blocking issues (REJECT) listed first, grouped by priority
- Non-blocking concerns (CONCERN) listed separately
- Clear action items for the Implementer
- Which reviewers approved vs. rejected

---

## Post-Loop Completion Rules

Post-loop is the final phase before HYDRA_COMPLETE. It is non-negotiable.

### Trigger

Post-loop runs ONLY when ALL tasks in the plan have status DONE. Not before.

### Execution Order

Post-loop agents run in sequence:
1. **Documentation** — Updates README, API docs, changelog based on all completed tasks
2. **Release Manager** — Handles versioning, release notes, git tags
3. **Observability** — Verifies logging, metrics, and error tracking are in place

### Authority Scope

Post-loop agents have write authority ONLY for:
- Documentation files (README, CHANGELOG, API docs)
- Release artifacts (version bumps, release notes, git tags)
- Observability configuration (logging setup, metrics endpoints)

They must NOT modify application source code or test files.

### Failure Handling

- If a post-loop agent fails, HYDRA_COMPLETE does NOT fire
- The user is notified and must resolve the issue before completion
- The loop can be resumed with `/hydra:start` which will retry the failed post-loop phase

### Completion

Only after ALL post-loop agents succeed does the system output HYDRA_COMPLETE.

---

## Parallel Execution Decision Logic

Parallel execution is governed by configuration and safety constraints.

### Prerequisites

Both must be true:
- `parallelism.enabled: true` in config.json
- `parallelism.use_agent_teams: true` in config.json

### Decision Flow

| Scenario | Parallel? | Condition |
|----------|----------|-----------|
| Reviews | Always (when enabled) | All reviewers run as simultaneous teammates |
| Independent tasks | Yes | Tasks with zero shared file scope AND no dependency relationship |
| Dependent tasks | Never | Tasks with dependencies always run sequentially |
| Overlapping file scope | Never | Tasks touching the same files run sequentially |

### Team Orchestrator Role

The Team Orchestrator manages all parallel coordination:
1. Identifies independent task groups by analyzing dependencies and file scopes
2. Validates zero file overlap between parallel tasks
3. Creates and manages Agent Teams
4. Enforces `max_parallel_teammates` limit (default: 4)
5. Falls back to sequential execution if safety constraints are violated

### Constraints

- Maximum parallel teammates: configurable via `parallelism.max_parallel_teammates`
- File scope validation is mandatory — parallel implementers with overlapping files are a framework violation
- The review gate still requires unanimous approval regardless of parallel execution
- State machine transitions are never skipped, even in parallel mode

---

## State Persistence Governance

### What Must Be Written to Disk

| State | File | Written By |
|-------|------|-----------|
| Current task and status | `hydra/plan.md` Recovery Pointer | Every agent on state change, Stop hook |
| Full task details | `hydra/tasks/TASK-NNN.md` | Planner (create), Implementer (update), Review Gate (update) |
| Iteration snapshot | `hydra/checkpoints/iteration-NNN.json` | Stop hook, Pre-compact hook |
| Review verdicts | `hydra/reviews/TASK-NNN/` | Each reviewer agent |
| Consolidated feedback | `hydra/reviews/TASK-NNN/consolidated-feedback.md` | Feedback Aggregator |
| Project context | `hydra/context/` | Discovery agent |
| Project documents | `hydra/docs/` | Doc Generator |
| Runtime configuration | `hydra/config.json` | Various (mode, iteration, agents) |
| Iteration log | `hydra/logs/iterations.jsonl` | Stop hook |

### Checkpoint Retention

- Keep the last 10 checkpoints. Older ones are deleted by the stop hook.
- Checkpoints use `jq` for JSON construction to prevent escaping issues.
- Every checkpoint includes: iteration, timestamp, active task, plan snapshot, git state, reviewer state, context health, and recovery instructions.

---

## Amendment Process

Changes to governance require:

1. **Proposal**: Describe the change and rationale
2. **Impact assessment**: Which agents, hooks, and skills are affected
3. **Implementation**: Update all affected files
4. **Documentation**: Update CONSTITUTION.md, GOVERNANCE.md, and/or TEAM_CHARTER.md as needed
5. **Review**: Changes pass the project's review board

Governance changes are versioned alongside the plugin (`plugin.json` version bump).
