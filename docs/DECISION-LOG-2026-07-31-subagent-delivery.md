# Decision Log — Subagent Non-Delivery (2026-07-31)

Objective: `nazgul/config.json → .objective` (FEAT-024). PRD: `nazgul/docs/PRD.md`. TRD: `nazgul/docs/TRD.md`.

## TASK-001 — Reviewer `maxTurns` ceiling: repo-wide audit, before and after

Fresh `grep -rn "maxTurns" agents/ .claude/agents/generated/` run at implementation time (not the PRD's
doc-generation-time table, re-verified per AC1). Base commit: `9b0542d` (`main` @ v2.25.0).

### `agents/` (committed specs) — before vs. after

| Agent spec | Before | After | Changed? |
|---|---|---|---|
| `agents/templates/reviewer-base.md` | 12 | **30** | YES — this task |
| `agents/self-audit.md` | 15 | 15 | no |
| `agents/comment-verifier.md` | 20 | 20 | no |
| `agents/feedback-aggregator.md` | 20 | 20 | no |
| `agents/release-manager.md` | 20 | 20 | no |
| `agents/doc-verifier.md` | 20 | 20 | no |
| `agents/debugger.md` | 30 | 30 | no |
| `agents/db-migration.md` | 30 | 30 | no |
| `agents/observability.md` | 30 | 30 | no |
| `agents/learner.md` | 30 | 30 | no |
| `agents/documentation.md` | 40 | 40 | no |
| `agents/cicd.md` | 40 | 40 | no |
| `agents/devops.md` | 40 | 40 | no |
| `agents/review-gate.md` | 40 | 40 | no |
| `agents/team-orchestrator.md` | 40 | 40 | no |
| `agents/designer.md` | 40 | 40 | no |
| `agents/discovery.md` (own frontmatter, line 11) | 50 | 50 | no |
| `agents/discovery.md` (embedded example, line 478) | 30 | 30 | no — see out-of-scope drift below |
| `agents/discovery.md` (embedded example, line 793) | 40 | 40 | no |
| `agents/discovery.md` (embedded example, line 885) | 30 | 30 | no |
| `agents/planner.md` | 50 | 50 | no |
| `agents/doc-generator.md` | 50 | 50 | no |
| `agents/frontend-dev.md` | 50 | 50 | no |
| `agents/mobile-dev.md` | 50 | 50 | no |
| `agents/simplifier.md` | 50 | 50 | no |
| `agents/implementer.md` | 100 | 100 | no |

### `.claude/agents/generated/` (local, gitignored runtime artifacts) — before vs. after

Regenerated on disk in the main worktree as an operational step (never committed — `.gitignore:16`):

| Generated agent | Before | After | Changed? |
|---|---|---|---|
| `.claude/agents/generated/architect-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/code-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/security-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/qa-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/documentation.md` | 30 | 30 | no — out-of-scope drift, see below |
| `.claude/agents/generated/cicd.md` | 40 | 40 | no |
| `.claude/agents/generated/release-manager.md` | 20 | 20 | no |

### Value chosen: 30, not 24

30 was chosen over the PRD/TRD's 24-30 range floor because this repo's own bootstrap test fixtures already
use `maxTurns: 30` for reviewers — matching it avoids introducing a second reviewer-turn-budget convention.
24 would be a new number appearing nowhere else in the repo.

### Out-of-scope drifts confirmed unchanged (per TRD Scope Item 1 required verification)

1. **`agents/discovery.md`'s embedded "Reviewer Agent Template" fragment (~lines 460-500).** Still shows
   `tools: Read, Glob, Grep, Bash`, an `allowed-tools:` Bash-test-command allowlist, `maxTurns: 30`, a
   per-agent `hooks: SubagentStop: type: prompt` block, and `nazgul/reviews/[TASK-ID]/` paths — none of
   which match the live template (`agents/templates/reviewer-base.md`: Read/Glob/Grep only, no
   `allowed-tools`/`hooks` block, `[UNIT-ID]` paths). Predates FEAT-006's reviewer-persistence redesign.
   Filed by TASK-009, not fixed here.
2. **`.claude/agents/generated/documentation.md` at `maxTurns: 30` vs. its source template
   `agents/documentation.md` at `maxTurns: 40`.** A live generated-vs-template drift, confirmed still
   present above. Filed by TASK-009, not fixed here.

Neither drift was touched by this task; no other agent spec was accidentally modified (full audit table
above covers every file the grep matched).
