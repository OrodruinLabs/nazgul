# Architecture

## Pipeline

```
Objective → Discovery (+Classification) → Doc Generator → Planner → Implementer → Review Board → Loop → Post-Loop → HYDRA_COMPLETE
```

1. **Discovery Agent** scans the codebase, classifies the project, generates tailored reviewer agents
2. **Doc Generator** produces PRDs, TRDs, ADRs based on project type
3. **Planner Agent** decomposes the objective into dependency-ordered tasks
4. **Implementer Agent** builds one task at a time, delegates to specialists as needed
5. **Review Board** (Architect, Code, Security + project-specific reviewers) reviews each task
6. **Feedback Aggregator** classifies findings as AUTO-FIX or ASK (per `references/fix-first-heuristic.md`), then consolidates into actionable fixes
7. Loop continues until ALL tasks pass ALL reviewers
8. **Post-Loop** agents update docs, manage releases, verify observability

## Agent Roster (17 core + project-specific reviewers)

| Category | Agents |
|----------|--------|
| Pipeline (always) | Discovery, Doc Generator, Planner, Implementer, Feedback Aggregator, Team Orchestrator |
| Reviewers (conditional) | Architect, Code, Security, QA, Performance, A11y, DB, API, Type, Infra, Dependency, Mobile, Data |
| Specialists (conditional) | Designer, Frontend Dev, Mobile Dev, DevOps, CI/CD, DB Migration |
| Post-Loop (conditional) | Documentation, Release Manager, Observability |

## Recovery

Hydra survives compaction, crashes, and session restarts:

1. **Pre-compact hook** writes a checkpoint before compaction
2. **Post-compact hook** re-injects loop state immediately after compaction completes
3. **Session-context hook** re-injects state on startup/compaction
4. **Recovery Pointer** in plan.md tells the agent exactly where to resume
5. **Checkpoint files** in `hydra/checkpoints/` have full JSON state snapshots
6. **Webhook forwarding** optionally notifies external systems on stop/compact events
7. **TaskCompleted hook** fires immediately when spawned agents finish for faster transitions
8. **Prompt guard hook** validates user prompts on submission
9. **Task-state guard hook** prevents edits outside claimed task scope

After any interruption:
```bash
/hydra:start --continue    # Resume from last checkpoint
/hydra:status              # See where things stand
```

## Additions Since v1.2

### Fix-First Review (Step 3.75)
When the review board returns CHANGES_REQUESTED, the feedback aggregator classifies each finding:
- **AUTO-FIX**: Mechanical issues (dead code, style, stale comments) — applied automatically
- **ASK**: Risky changes (security, architecture, API contracts) — presented for judgment

The review gate's Step 3.75 applies auto-fixes, re-runs tests, and only surfaces ASK items. This reduces review round-trips significantly.

### E2E Skill Testing
`tests/e2e/run-e2e.sh` spawns `claude -p` subprocesses to validate skills end-to-end. Gracefully skips when the `claude` CLI is unavailable. CI workflow (`e2e-tests.yml`) is manual-trigger only since tests cost money.

### Skill Template System
`scripts/gen-skill-docs.sh` resolves `{{PARTIAL:name}}` placeholders in `SKILL.md.tmpl` files using shared partials from `templates/skill-partials/`. CI workflow (`skill-docs.yml`) checks for stale SKILL.md files on PRs.

### Self-Improvement Mode
Agents optionally self-rate their experience (0-10) and file structured JSON reports to `hydra/improvement-reports/` via `scripts/file-improvement-report.sh`. Enabled per-project in config. `/hydra:metrics` aggregates reports.

### Concurrent Session Tracking
`scripts/lib/session-tracker.sh` manages filesystem locks in `hydra/sessions/`. Sessions register on startup, unregister on exit, and stale locks (>2h) are cleaned automatically. Concurrent sessions trigger a warning to prevent state corruption.

### Shared Task Utilities
`scripts/lib/task-utils.sh` provides `get_task_status`, `set_task_status`, `count_tasks_by_status`, and `get_active_task`. Supports 4 status formats: list-item, ATX inline, ATX block, and YAML frontmatter.

### CI Pipelines
- `test.yml` — runs unit/integration tests on push and PR
- `e2e-tests.yml` — E2E skill tests via `claude -p` (manual trigger)
- `skill-docs.yml` — checks SKILL.md freshness on PRs touching skills/partials

## Directory Structure

```
hydra/                          # Plugin root
├── RULES.md                    # Enforceable operating rules (consolidated)
├── .claude-plugin/plugin.json  # Plugin manifest
├── agents/                     # Agent definitions
│   ├── discovery.md            # Codebase scanner + classifier
│   ├── doc-generator.md        # PRD/TRD/ADR generator
│   ├── planner.md              # Task decomposition
│   ├── implementer.md          # Code builder + specialist delegator
│   ├── review-gate.md          # Review orchestrator
│   ├── feedback-aggregator.md  # Review consolidation
│   ├── team-orchestrator.md    # Parallel execution manager
│   ├── designer.md             # UI/UX design system
│   ├── frontend-dev.md         # Frontend implementation
│   ├── mobile-dev.md           # Mobile implementation
│   ├── devops.md               # Infrastructure configs
│   ├── cicd.md                 # CI/CD pipelines
│   ├── db-migration.md         # Safe schema changes
│   ├── documentation.md        # Post-loop docs
│   ├── release-manager.md      # Versioning + releases
│   ├── observability.md        # Logging + metrics
│   └── templates/              # Reviewer base template + domain config
├── skills/                     # Slash commands (20)
├── hooks/hooks.json            # Hook definitions (9 hook types: Stop, PreCompact, PostCompact, PreToolUse, PostToolUse, SessionStart, SessionEnd, TaskCompleted, UserPromptSubmit)
├── scripts/                    # Hook + sync scripts (17 + 2 libs)
│   └── lib/                    # Shared libraries (task-utils.sh, session-tracker.sh)
└── templates/                  # Objective + doc templates
    └── skill-partials/         # Shared SKILL.md template partials

# At repo root (not inside hydra/):
.github/workflows/              # CI pipelines (test, e2e, skill-docs freshness)
```
