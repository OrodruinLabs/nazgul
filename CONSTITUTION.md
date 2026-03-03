# Hydra Constitution

The supreme operating law of the Hydra Framework. These principles are non-negotiable and cannot be overridden by any agent, skill, hook, or configuration.

---

## Article I — Fundamental Principle

**Files are memory. Context is working memory.**

Every piece of state lives on disk, committed to git. The context window is ephemeral and disposable. No agent may rely on conversational memory for state. If it matters, it must be written to a file. If it's only in context, it doesn't exist.

This principle drives every architectural decision in Hydra: task manifests, recovery pointers, checkpoints, notifications, and review artifacts all exist as files.

---

## Article II — The 10 Rules

These rules govern all agent behavior during a Hydra loop. Violation of any rule is a framework failure.

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately. Never rely on conversational memory.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing. Match the style.
4. **Tests are mandatory.** Every task includes tests. Run them after every change. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** When CHANGES_REQUESTED, fix every REJECT item.
7. **One task at a time.** Don't work on multiple tasks simultaneously (unless parallel mode with Agent Teams).
8. **Update Recovery Pointer on every state change.** This is how you survive compaction.
9. **Commit in AFK mode.** Every state transition gets a commit with the `hydra:` prefix.
10. **HYDRA_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

---

## Article III — The State Machine

No task may skip a state. The state machine is the backbone of correctness.

```
Non-YOLO: PLANNED → READY → IN_PROGRESS → IMPLEMENTED → IN_REVIEW → DONE
YOLO:     PLANNED → READY → IN_PROGRESS → IMPLEMENTED → IN_REVIEW → APPROVED → DONE
```

### Permitted Transitions

| From | To | Condition | Written By |
|------|----|-----------|------------|
| PLANNED | READY | All dependencies are DONE (or APPROVED in YOLO mode) | Stop hook (automatic) |
| READY | IN_PROGRESS | Agent claims the task | Implementer |
| IN_PROGRESS | IMPLEMENTED | Code complete + tests pass + lint clean | Implementer |
| IMPLEMENTED | IN_REVIEW | Review gate picks up the task | Review Gate |
| IN_REVIEW | DONE | ALL reviewers APPROVED (non-YOLO mode) | Review Gate |
| IN_REVIEW | APPROVED | ALL reviewers APPROVED (YOLO mode) | Review Gate |
| IN_REVIEW | CHANGES_REQUESTED | ANY reviewer rejects | Review Gate |
| APPROVED | DONE | PR merged (external event, YOLO mode only) | Notification handler or user |
| CHANGES_REQUESTED | IN_PROGRESS | Implementer addresses feedback | Implementer |
| Any active state | BLOCKED | Max retries hit, unresolvable issue, or 3 consecutive test failures | Implementer or Review Gate |
| BLOCKED | READY | Human intervention resolves the blocker | User (manual or /hydra-task unblock) |

### Forbidden Transitions

- PLANNED directly to IN_PROGRESS (must go through READY)
- READY directly to IMPLEMENTED (must go through IN_PROGRESS)
- IN_PROGRESS directly to IN_REVIEW (must go through IMPLEMENTED)
- IN_REVIEW directly to IN_PROGRESS (must go through CHANGES_REQUESTED)
- DONE to any other state (DONE is terminal)
- APPROVED to any state other than DONE (APPROVED is near-terminal, only PR merge advances it)

---

## Article IV — The Review Board

### Non-Negotiable Rules

1. **All reviewers must approve.** A task cannot be DONE until every active reviewer returns APPROVED. There is no majority vote. There is no "good enough."

2. **Confidence threshold governs severity.** Findings with confidence below 80/100 are non-blocking concerns (warning). Findings at or above 80 with HIGH or MEDIUM severity are blocking rejections (REJECT).

3. **Reviewers are read-only.** Reviewer agents must NEVER modify project files. They read source code, run verification commands, and write their review to `hydra/reviews/`. Nothing else.

4. **Pre-checks before reviews.** Tests and lint must pass BEFORE any reviewer runs. Failed pre-checks send the task back to IN_PROGRESS. Three consecutive test failures block the task.

5. **Security rejections are absolute in AFK mode.** If any reviewer raises a security concern in autonomous mode, the task is BLOCKED and requires human review. This notification fires regardless of the `notifications.enabled` setting.

6. **Every finding must be structured.** Each reviewer finding MUST include: severity (HIGH/MEDIUM/LOW), confidence score (0-100), file path, category, verdict (APPROVE/REJECT/CONCERN), issue description, and fix suggestion. Unstructured findings are invalid.

7. **Test failure escalation is per-task.** The 3-consecutive-test-failure threshold tracks across retries for the same task. If a task fails tests 3 times (even across different retry cycles), it is BLOCKED with detailed test output written to `hydra/reviews/[TASK-ID]/test-failures.md`.

8. **Feedback priority is fixed.** When the Feedback Aggregator consolidates reviewer feedback, priority is: security findings first, correctness issues second, style concerns last. Security findings are always blocking regardless of confidence score.

### YOLO Mode — Deferred Merge

In YOLO mode (`afk.yolo: true`), the in-loop review gate still runs fully — all
configured reviewers must approve before a task advances. However, instead of DONE,
the task is set to APPROVED and a stacked PR is created. The loop proceeds to the
next task immediately.

DONE is set only when the PR is merged. This defers external code review to the PR
while preserving all local quality checks (tests, lint, all 6 reviewers).

---

## Article V — Recovery

### The Recovery Pointer Contract

The Recovery Pointer is the SINGLE MOST IMPORTANT piece of recovery state. It is the first thing read by the stop hook, the first thing read by session-context.sh, and the first thing read by any agent starting work. It is small enough to survive aggressive compaction summaries and human-readable for manual inspection.

The Recovery Pointer in `plan.md` must be updated on every state transition by every agent that changes task state.

```markdown
## Recovery Pointer
- **Current Task:** TASK-NNN
- **Last Action:** [what just happened]
- **Next Action:** [what should happen next]
- **Last Checkpoint:** hydra/checkpoints/iteration-NNN.json
- **Last Commit:** abc1234
```

### The Recovery Read Order

When any agent starts work — after compaction, crash, or fresh start — it reads files in this exact order:

1. `hydra/config.json` — Mode, iteration count, reviewer list
2. `hydra/plan.md` — Recovery Pointer (resume from section)
3. `hydra/checkpoints/iteration-NNN.json` — Latest checkpoint (full detail)
4. `hydra/tasks/TASK-XXX.md` — Active task manifest (full state)
5. `hydra/reviews/TASK-XXX/` — If CHANGES_REQUESTED: consolidated feedback
6. `hydra/context/project-profile.md` — If needed: project conventions

No agent may begin work without reading at minimum files 1-4.

**NEVER start work without reading these files first. NEVER rely on conversational memory — files are the truth.**

### Automatic Recovery

After any interruption (compaction, crash, timeout), reading the Recovery Pointer + latest checkpoint + active task manifest must provide enough information to resume without human intervention.

---

## Article VI — Classification First

Classification is Discovery's FIRST action — before scanning, before agent spawning, before anything else. Until the project is classified, no other pipeline stage may proceed.

### The 5 Project Types

| Type | Detection Signals |
|------|-------------------|
| GREENFIELD | <10 source files, no meaningful logic, empty or scaffolded-only project |
| BROWNFIELD | Existing codebase, adding new features. **DEFAULT for ambiguous cases.** |
| REFACTOR | Restructuring without changing behavior, same inputs/outputs expected |
| BUGFIX | Fixing specific issues, narrow scope, usually references an issue or error |
| MIGRATION | Moving between technologies or platforms, source and target stacks identified |

### What Classification Determines

Classification governs everything downstream:
- **Which agents spawn** — a BUGFIX needs far fewer agents than a GREENFIELD project
- **Which documents are generated** — see Article VII for the Document Generation Matrix
- **Which templates apply** — objective templates, review templates, and planning templates are all classification-specific
- **How the Planner decomposes work** — GREENFIELD gets full decomposition; BUGFIX gets narrow, targeted tasks

### AFK vs. HITL Behavior

- **AFK mode:** Ambiguous classification defaults to BROWNFIELD. This is the safest default — it produces the most context without over-generating documents. Discovery logs the ambiguity to `hydra/notifications.jsonl`.
- **HITL mode:** Classification is confirmed with the user before proceeding. Discovery presents its evidence and recommended classification, and the user approves or overrides.

### Hard Requirement

No downstream agent may operate without classification being complete. Any agent that starts work before classification is a framework violation.

---

## Article VII — Documents Before Code

After classification, the Doc Generator produces documents BEFORE any planning begins. No Planner may run until documents are generated and approved.

### Document Generation Matrix

| Classification | Documents Generated |
|---------------|---------------------|
| GREENFIELD | Full PRD + TRD + ADRs (complete specification) |
| BROWNFIELD | Feature-scoped TRD + ADR (scoped to the new feature) |
| REFACTOR | Target architecture TRD (describing the desired end-state) |
| BUGFIX | Root cause analysis only (minimal documentation) |
| MIGRATION | Full PRD + TRD + ADRs + rollback plan (maximum documentation) |

### Traceability Requirement

Every task MUST have a `traces_to` field linking back to PRD acceptance criteria. This is not optional — tasks without traceability are invalid.

Traceability is bidirectional:
- **Forward:** Every task traces to at least one PRD acceptance criterion
- **Backward:** Every PRD acceptance criterion maps to at least one task

If an acceptance criterion has no corresponding task, the Planner has missed work. If a task has no corresponding criterion, the task is out of scope.

### AFK vs. HITL Behavior

- **HITL mode:** Documents require human review and approval before the Planner runs. The Doc Generator presents documents for review, and the user approves, requests changes, or overrides.
- **AFK mode:** Documents are auto-generated and auto-approved. The Doc Generator writes documents and proceeds immediately to the Planner.

### Hard Requirement

No code is written until documents exist. No task is created without traceability to a requirement. No Planner runs without approved documents.

---

## Article VIII — Safety Boundaries

### Hard Blocks (Enforced by Pre-Tool Guard)

These commands are blocked unconditionally:
- `rm -rf /`, `rm -rf ~` — filesystem destruction
- `DROP TABLE`, `TRUNCATE` — data destruction
- `git push --force main`, `git push --force master` — shared branch destruction
- Fork bombs, `curl | sh`, `wget | sh` — unsafe execution
- `chmod -R 777` — permission degradation

### Soft Limits (Configurable)

| Limit | Default | Config Path |
|-------|---------|-------------|
| Max iterations per loop | 40 | `max_iterations` |
| Max retries per task | 3 | `review_gate.max_retries_per_task` |
| Max consecutive failures | 5 | `safety.max_consecutive_failures` |
| AFK timeout | 90 minutes | `afk.timeout_minutes` |
| Confidence threshold | 80 | `review_gate.confidence_threshold` |

### Escalation

When a task is BLOCKED, the system always writes a notification. When the blocked reason involves security, the notification fires regardless of the `notifications.enabled` setting. Git conflicts detected during the loop automatically block the active task.

---

## Article IX — Context Management

### Budget Strategy

Three levels govern how aggressively context is managed:

| Level | Threshold | Behavior |
|-------|-----------|----------|
| `conservative` | 60% | More frequent compaction, less context available per turn |
| `aggressive` | 70% | Default. Balanced compaction timing. |
| `minimal` | 80% | Less compaction, more risk of context exhaustion |

### File Read Limits

Maximum 200 lines per file read to prevent context flooding. When exploration-heavy work is needed, use subagents — they have their own context windows and do not consume the main session's budget.

### Context Fork Mode

Read-only skills (`hydra-status`, `hydra-review`, `hydra-discover`, `hydra-context`, `hydra-simplify`, `hydra-docs`) run with `context: fork` to prevent polluting the main session's context window. These skills read state files and report back without leaving residual context in the working session.

### Context Rot Detection

After 8+ iterations without compaction, the stop hook warns about potential context degradation. Running `/compact` with Hydra-specific instructions resets the iteration counter. The warning is logged to `hydra/notifications.jsonl` and displayed to the user if in HITL mode.

### Compaction Survival

The pre-compact hook writes a checkpoint before compaction occurs. After compaction, the session-context hook re-injects essential state (Recovery Pointer, active task, iteration count). The Recovery Pointer is deliberately small enough to survive aggressive compaction summaries — it contains only the minimum needed to resume work.

---

## Article X — Conditional Agent Roster

Discovery generates only the agents the project needs. A React+Prisma project might get 18 agents. A CLI tool might get 10. All 29 agents exist as specifications, but only relevant ones are instantiated per-project.

The Implementer is not a solo builder. For UI tasks, it delegates to Designer then Frontend Dev. For infrastructure tasks, to DevOps. For schema changes, to DB Migration. Delegation uses briefs written to `hydra/tasks/[TASK-ID]-delegation.md`.

---

## Article XI — File Scope Restrictions

### Implementer Scope

The Implementer must not modify files outside the active task's `file_scope` field. If additional files need modification, the task manifest must be updated first — the Implementer cannot silently expand scope.

### Reviewer Scope

Reviewers must NEVER modify project files. They may only read source code, run verification commands (tests, lint), and write their review to `hydra/reviews/`. Any reviewer that modifies project files is a framework violation.

### Parallel Scope

When multiple implementer agents work in parallel (via Agent Teams), they MUST have zero file overlap. The Team Orchestrator validates this before assigning parallel work. If overlap is detected, the conflicting tasks run sequentially instead of in parallel.

### Discovery Evidence

Discovery must cite specific evidence (file path + line number or content excerpt) for every detection it makes. No guessing. If a signal cannot be confirmed with evidence, it is not reported. This applies to project classification, technology detection, pattern identification, and all other Discovery outputs.

### Specialist Scope

Specialist agents (Designer, Frontend Dev, DevOps, DB Migration, etc.) implement only within the scope of their delegation brief. Files outside the brief's scope are off-limits. If a specialist discovers that out-of-scope files need changes, they report back to the Implementer rather than making the changes themselves.

---

## Article XII — Amendments

This constitution may be amended only by:
1. Updating this file in the Hydra plugin source
2. Documenting the rationale in an ADR
3. Updating all affected agents, hooks, and skills to reflect the change
4. Passing review by the project's review board

No agent may unilaterally override these rules during operation. Configuration can adjust thresholds (Article VIII soft limits) but cannot disable fundamental principles (Articles I-VII).

**HYDRA_COMPLETE fires ONLY after post-loop agents complete.** If a post-loop agent fails, HYDRA_COMPLETE does not fire. The failure is logged to `hydra/notifications.jsonl` and the user is notified. Post-loop agents must all succeed for the loop to be considered truly complete.
