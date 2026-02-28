# Hydra Framework

Multi-agent autonomous development loop for Claude Code. Hydra runs a complete SDLC pipeline: Discovery, Classification, Document Generation, Planning, Implementation, Review Board, and Post-Loop finalization — all autonomously.

## Architecture

```
Objective → Discovery (+Classification) → Doc Generator → Planner → Implementer → Review Board → Loop → Post-Loop → HYDRA_COMPLETE
```

### Pipeline

1. **Discovery Agent** scans the codebase, classifies the project, generates tailored reviewer agents
2. **Doc Generator** produces PRDs, TRDs, ADRs based on project type
3. **Planner Agent** decomposes the objective into dependency-ordered tasks
4. **Implementer Agent** builds one task at a time, delegates to specialists as needed
5. **Review Board** (Architect, Code, Security + project-specific reviewers) reviews each task
6. **Feedback Aggregator** consolidates rejections into actionable fixes
7. Loop continues until ALL tasks pass ALL reviewers
8. **Post-Loop** agents update docs, manage releases, verify observability

### Agent Roster (29 potential, 12-18 typical)

| Category | Agents |
|----------|--------|
| Pipeline (always) | Discovery, Doc Generator, Planner, Implementer, Feedback Aggregator, Team Orchestrator |
| Reviewers (conditional) | Architect, Code, Security, QA, Performance, A11y, DB, API, Type, Infra, Dependency, Mobile, Data |
| Specialists (conditional) | Designer, Frontend Dev, Mobile Dev, DevOps, CI/CD, DB Migration |
| Post-Loop (conditional) | Documentation, Release Manager, Observability |

## Installation

```bash
# Clone the repo
git clone https://github.com/Strumtry/ai-hydra-framework.git

# Launch Claude Code with the plugin loaded
claude --plugin-dir /path/to/ai-hydra-framework
```

To load Hydra automatically, add an alias to your shell profile (`~/.zshrc` or `~/.bashrc`):
```bash
alias claude='claude --plugin-dir /path/to/ai-hydra-framework'
```

## Quick Start

```bash
# 1. Initialize Hydra for your project
/hydra-init

# 2. Just start — Hydra figures out what to do
/hydra-start

# 2b. Or go full berserk (no permission prompts, no pauses)
claude --dangerously-skip-permissions
/hydra-start --yolo --max 30

# 3. Check progress
/hydra-status
```

Hydra auto-detects project state: if there's active work it resumes, if docs exist it plans, if the project is fresh it scans for TODOs/issues/failing tests and derives an objective. You can always override with `/hydra-start "specific objective"`.

## Commands

| Command | Description | Mode |
|---------|-------------|------|
| `/hydra-init` | First-time setup: discovery, reviewer generation, runtime dirs | User-only |
| `/hydra-start` | Smart start/resume — auto-detects state, derives objective from project context | User-only |
| `/hydra-start "objective"` | Override: start a specific new objective | User-only |
| `/hydra-status` | Check loop progress, task counts, reviewer board | Read-only fork |
| `/hydra-task` | Task lifecycle: skip, unblock, add, prioritize, info, list | Fork |
| `/hydra-pause` | Gracefully pause the loop at next iteration boundary | Fork |
| `/hydra-log` | View run history — iterations, commits, reviews, blockers | Read-only fork |
| `/hydra-reset` | Archive current state and reset to clean slate | Fork |
| `/hydra-review` | Manually trigger review for a task | Read-only fork |
| `/hydra-discover` | Re-run codebase discovery | Fork |
| `/hydra-context` | Collect targeted context for an objective type | Fork |
| `/hydra-simplify` | Post-loop cleanup pass on modified files | Fork |
| `/hydra-docs` | View or regenerate project documents | Fork |

### Flags for `/hydra-start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
- `--continue` — Explicit resume (backward compat — bare `/hydra-start` auto-detects this)

## Companion Plugins

```
ESSENTIAL:
  security-guidance    Real-time vulnerability detection in written code

RECOMMENDED:
  frontend-design      Better frontend code quality (if UI project)

OPTIONAL:
  hookify              Custom safety rules via markdown
  code-simplifier      Post-loop cleanup for code clarity

DO NOT INSTALL ALONGSIDE:
  ralph-wiggum         Conflicts with Hydra's Stop hook
  feature-dev          Conflicts with Hydra's planning phase
```

### Plugin Compatibility Matrix

| Plugin | Status | Notes |
|--------|--------|-------|
| security-guidance | ESSENTIAL | Catches code-level vulnerabilities; Hydra catches architectural issues |
| code-review | COMPATIBLE | Use for PR review AFTER Hydra loop completes |
| feature-dev | OVERLAP | Both do planning. Don't use during a Hydra loop |
| pr-review-toolkit | COMPATIBLE | Detailed PR review after Hydra creates a PR |
| code-simplifier | COMPATIBLE | Optional post-loop cleanup via `/hydra-simplify` |
| frontend-design | COMPATIBLE | Auto-invoked during frontend work |
| hookify | COMPATIBLE | Add custom guardrails on top of Hydra |
| ralph-wiggum | CONFLICTS | Both use Stop hooks. Remove before installing Hydra |
| OpenClaw | SYNERGISTIC | Voice-commanded autonomous loops via `notifications.jsonl` |

## OpenClaw Integration

Hydra is designed to work with OpenClaw for voice-commanded autonomous development:

```
You (WhatsApp voice): "Build the payment integration overnight"
OpenClaw → spawns Hydra loop → monitors progress → messages you when done
```

Hydra writes events to `hydra/notifications.jsonl` that OpenClaw (or any external tool) can `tail -f`:

```jsonl
{"event":"task_complete","task":"TASK-003","timestamp":"...","summary":"User service done"}
{"event":"blocked","task":"TASK-005","timestamp":"...","reason":"API key needed","requires_human":true}
{"event":"loop_complete","timestamp":"...","summary":"6/6 tasks done, 18 commits"}
```

## The 10 Rules for the Hydra Loop

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing.
4. **Tests are mandatory.** Every task includes tests. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** Fix every REJECT item when CHANGES_REQUESTED.
7. **One task at a time.** Unless parallel mode with Agent Teams.
8. **Update Recovery Pointer on every state change.** Survives compaction.
9. **Commit in AFK mode.** Every state transition gets a `hydra:` prefixed commit.
10. **HYDRA_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

## Recovery

Hydra survives compaction, crashes, and session restarts:

1. **Pre-compact hook** writes a checkpoint before compaction
2. **Session-context hook** re-injects state on startup/compaction
3. **Recovery Pointer** in plan.md tells the agent exactly where to resume
4. **Checkpoint files** in `hydra/checkpoints/` have full JSON state snapshots

After any interruption:
```bash
/hydra-start --continue    # Resume from last checkpoint
/hydra-status              # See where things stand
```

## Config Upgrades

When the Hydra plugin template evolves (new fields, new sections), existing projects upgrade automatically:

1. On every session start, Hydra compares your project's `hydra/config.json` schema version against the plugin template
2. If your config is outdated, it creates a backup (`config.json.v1.bak`), applies incremental migrations, and logs to `hydra/logs/migrations.log`
3. Existing settings are preserved — only missing fields are added

No manual action required. You'll see a one-time notice: `"Hydra config migrated from v1 to v2."`

## Safety

- **Pre-tool guard** blocks: `rm -rf /`, `DROP TABLE`, `git push --force main`, fork bombs, `curl | sh`
- **Security rejections** in AFK mode → BLOCKED (requires human review)
- **Max retries per task**: 3 (configurable)
- **Max consecutive failures**: 5 (auto-stops if no progress)
- **Confidence threshold**: Findings below 80/100 are non-blocking concerns

## Troubleshooting

**"No Hydra config found"** — Run `/hydra-init` first.

**"Discovery not run"** — Run `/hydra-init` or `/hydra-discover`.

**Loop stops unexpectedly** — Check `hydra/config.json` for `max_iterations` or `consecutive_failures`. Run `/hydra-start --continue` to resume.

**Task stuck as BLOCKED** — Check `hydra/tasks/TASK-NNN.md` for the `blocked_reason`. Fix the issue manually, then run `/hydra-task unblock TASK-NNN` or set status to READY and `/hydra-start --continue`.

**Want to see what happened overnight?** — Run `/hydra-log` for a full timeline of iterations, commits, reviews, and blockers.

**Need to pause the loop?** — Run `/hydra-pause` to stop cleanly at the next iteration boundary.

**Hydra state is corrupted** — Run `/hydra-reset` to archive current state and start fresh. Use `--preserve-context` to keep discovery data.

**Context degradation** — If the agent seems confused after many iterations, run `/compact` with Hydra-specific instructions, then the session-context hook will re-inject state.

## Requirements

- `jq` — Required for JSON manipulation in hook scripts
- `git` — Required for commit tracking and state persistence
- Claude Code — Agent Teams is enabled automatically by `/hydra-init`

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
├── skills/                     # Slash commands (12)
├── hooks/hooks.json            # Hook definitions
├── scripts/                    # Hook scripts (4)
└── templates/                  # Objective + doc templates
```

## License

MIT
