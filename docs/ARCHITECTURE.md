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
6. **Feedback Aggregator** consolidates rejections into actionable fixes
7. Loop continues until ALL tasks pass ALL reviewers
8. **Post-Loop** agents update docs, manage releases, verify observability

## Agent Roster (29 potential, 12-18 typical)

| Category | Agents |
|----------|--------|
| Pipeline (always) | Discovery, Doc Generator, Planner, Implementer, Feedback Aggregator, Team Orchestrator |
| Reviewers (conditional) | Architect, Code, Security, QA, Performance, A11y, DB, API, Type, Infra, Dependency, Mobile, Data |
| Specialists (conditional) | Designer, Frontend Dev, Mobile Dev, DevOps, CI/CD, DB Migration |
| Post-Loop (conditional) | Documentation, Release Manager, Observability |

## Recovery

Hydra survives compaction, crashes, and session restarts:

1. **Pre-compact hook** writes a checkpoint before compaction
2. **Session-context hook** re-injects state on startup/compaction
3. **Recovery Pointer** in plan.md tells the agent exactly where to resume
4. **Checkpoint files** in `hydra/checkpoints/` have full JSON state snapshots

After any interruption:
```bash
/hydra:start --continue    # Resume from last checkpoint
/hydra:status              # See where things stand
```

## Directory Structure

```
hydra/                          # Plugin root
├── CONSTITUTION.md             # Non-negotiable operating principles (the supreme law)
├── GOVERNANCE.md               # Decision authority, conflict resolution, escalation
├── TEAM_CHARTER.md             # Agent roles, communication, coordination model
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
│   └── templates/              # Reviewer templates (10)
├── skills/                     # Slash commands (16)
├── hooks/hooks.json            # Hook definitions
├── scripts/                    # Hook + sync scripts (8)
└── templates/                  # Objective + doc templates
```
