# Hydra Rules

Enforceable operating rules for the Hydra Framework. Every rule here is checked by a hook, agent, or script.

---

## 1. The 10 Rules

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately. Never rely on conversational memory.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing. Match the style.
4. **Tests are mandatory.** Every task includes tests. Run them after every change. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** When CHANGES_REQUESTED, fix every REJECT item.
7. **One task at a time.** Don't work on multiple tasks simultaneously (unless parallel mode with Agent Teams).
8. **Update Recovery Pointer on every state change.** This is how you survive compaction.
9. **Commit in AFK mode.** Every state transition gets a commit with the dynamic prefix from config.
10. **HYDRA_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

---

## 2. State Machine

```
Default:     PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE
Task-PR:     PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> APPROVED -> DONE
```

### Permitted Transitions

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

### Forbidden Transitions

- PLANNED -> IN_PROGRESS (must go through READY)
- READY -> IMPLEMENTED (must go through IN_PROGRESS)
- IN_PROGRESS -> IN_REVIEW (must go through IMPLEMENTED)
- IN_REVIEW -> IN_PROGRESS (must go through CHANGES_REQUESTED)
- DONE -> any state (terminal)

---

## 3. Review Board

1. **All reviewers must approve.** Unanimous -- no majority vote.
2. **Confidence threshold governs severity.** Below 80 = non-blocking CONCERN. At or above 80 with HIGH/MEDIUM severity = blocking REJECT.
3. **Reviewers are read-only.** Never modify project files. Read, verify, write review to `hydra/reviews/`.
4. **Pre-checks before reviews.** Tests and lint must pass BEFORE reviewers run. Three consecutive test failures block the task.
5. **Security rejections are absolute in AFK mode.** Task is BLOCKED, requires human review.
6. **Every finding must be structured.** Required fields: severity, confidence, file path, category, verdict, issue, fix.
7. **Feedback priority:** Security first, correctness second, style last.
8. **Contradiction handling:** HITL = flag for human. AFK = majority wins, ties broken by higher confidence.

---

## 4. Recovery Protocol

The Recovery Pointer is read first by every agent on every start.

```markdown
## Recovery Pointer
- **Current Task:** TASK-NNN
- **Last Action:** [what just happened]
- **Next Action:** [what should happen next]
- **Last Checkpoint:** hydra/checkpoints/iteration-NNN.json
- **Last Commit:** abc1234
```

### Recovery Read Order

1. `hydra/config.json` -- Mode, iteration, reviewer list
2. `hydra/plan.md` -- Recovery Pointer
3. `hydra/checkpoints/iteration-NNN.json` -- Latest checkpoint
4. `hydra/tasks/TASK-XXX.md` -- Active task manifest
5. `hydra/reviews/TASK-XXX/` -- If CHANGES_REQUESTED: consolidated feedback
6. `hydra/context/project-profile.md` -- If needed: project conventions

**No agent may begin work without reading files 1-4. Files are truth -- never rely on conversational memory.**

---

## 5. Safety Boundaries

### Hard Blocks (unconditional)
- `rm -rf /`, `rm -rf ~` -- filesystem destruction
- `DROP TABLE`, `TRUNCATE` -- data destruction
- `git push --force main/master` -- shared branch destruction
- Fork bombs, `curl | sh` -- unsafe execution
- `chmod -R 777` -- permission degradation

### Soft Limits

| Limit | Default | Config |
|-------|---------|--------|
| Max iterations | 40 | `max_iterations` |
| Max retries/task | 3 | `review_gate.max_retries_per_task` |
| Max consecutive failures | 5 | `safety.max_consecutive_failures` |
| AFK timeout | 90 min | `afk.timeout_minutes` |
| Confidence threshold | 80 | `review_gate.confidence_threshold` |

---

## 6. Classification

| Type | Detection |
|------|-----------|
| GREENFIELD | <10 source files, no meaningful logic |
| BROWNFIELD | Existing codebase, adding features (DEFAULT) |
| REFACTOR | Restructuring without changing behavior |
| BUGFIX | Fixing specific issues, narrow scope |
| MIGRATION | Moving between technologies/platforms |

---

## 7. Document Generation Matrix

| Document | Greenfield | Brownfield | Refactor | Bugfix | Migration |
|----------|-----------|------------|----------|--------|-----------|
| PRD | Full | Feature-scoped | -- | -- | Feature parity |
| TRD | Full | Feature-scoped | Target arch | -- | Target stack |
| ADR | Key decisions | New decisions | Why refactor | -- | Why migrate |
| Test Plan | Full | Feature tests | Regression | Regression | Validation |

---

## 8. File Scope Restrictions

- **Implementer**: Only files in the task's `file_scope`. Must update manifest before expanding.
- **Reviewers**: Read-only. Write only to `hydra/reviews/`.
- **Parallel tasks**: Zero file overlap. Team Orchestrator validates before assigning.
- **Specialists**: Only files in the delegation brief's scope.

---

## 9. Mode Governance

- **HITL** (default): Human approves classification, docs, plan. Consulted on blockers.
- **AFK**: Auto-approve classification/docs/plan. Auto-commit. Security rejections auto-block.
- **YOLO**: AFK + zero permission prompts. Requires `--dangerously-skip-permissions`. Pre-tool guard still blocks destructive commands.

---

## 10. Branch Isolation

- Never commit to the base branch during a loop
- Feature branch: `feat/<id>-<slug>` -- integration point
- Task worktrees: `feat/<id>/TASK-NNN` -- merge back to feature
- Worktrees live in `../<project>-worktrees/TASK-NNN/`
- On conflict: `git merge --abort`, task BLOCKED
