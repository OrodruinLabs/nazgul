# CLAUDE.md — Hydra Framework Plugin

## What This Project Is

Hydra is a Claude Code plugin that provides multi-agent autonomous development. This repo IS the installable plugin.

**Install:** `claude --plugin-dir /path/to/ai-hydra-framework` or clone to `~/.claude/plugins/hydra-framework`.

## Directory Structure

```
.claude-plugin/plugin.json           # Plugin manifest (must be at repo root)
CONSTITUTION.md                      # Non-negotiable operating principles
GOVERNANCE.md                        # Decision authority, conflict resolution, escalation
TEAM_CHARTER.md                      # Agent roles, communication protocols, coordination
skills/                              # User-facing commands (/hydra-*)
│   ├── hydra-init/SKILL.md
│   ├── hydra-start/SKILL.md
│   ├── hydra-status/SKILL.md
│   ├── hydra-review/SKILL.md
│   ├── hydra-discover/SKILL.md
│   ├── hydra-context/SKILL.md
│   ├── hydra-simplify/SKILL.md
│   └── hydra-docs/SKILL.md
agents/                              # Subagent definitions
│   ├── discovery.md                 # Pipeline: scans codebase, classifies project
│   ├── doc-generator.md             # Pipeline: generates PRD, TRD, ADRs
│   ├── planner.md                   # Pipeline: decomposes objective into tasks
│   ├── implementer.md               # Pipeline: builds tasks, delegates to specialists
│   ├── review-gate.md               # Pipeline: orchestrates review board
│   ├── feedback-aggregator.md       # Pipeline: consolidates review feedback
│   ├── team-orchestrator.md         # Pipeline: manages Agent Teams
│   ├── designer.md                  # Specialist: design system, visual direction
│   ├── frontend-dev.md              # Specialist: UI component implementation
│   ├── mobile-dev.md                # Specialist: mobile platform implementation
│   ├── devops.md                    # Specialist: Docker, K8s, cloud configs
│   ├── cicd.md                      # Specialist: CI/CD pipeline generation
│   ├── db-migration.md              # Specialist: safe schema changes
│   ├── documentation.md             # Post-loop: README, API docs, changelog
│   ├── release-manager.md           # Post-loop: versioning, release notes
│   ├── observability.md             # Post-loop: logging, metrics, error tracking
│   └── templates/                   # Reviewer templates (Discovery customizes per-project)
hooks/hooks.json                     # Hook configuration
scripts/                             # Shell scripts for hooks
│   ├── stop-hook.sh
│   ├── pre-compact.sh
│   ├── pre-tool-guard.sh
│   └── session-context.sh
templates/                           # Objective + document templates
│   ├── CLAUDE.md.template           # Injected into target projects by /hydra-init
│   ├── feature.md / tdd.md / bugfix.md / refactor.md / greenfield.md / migration.md
│   └── docs/                        # Document templates for doc-generator
tests/                               # Plugin validation tests
```

## Build Rules

1. **Skills use YAML frontmatter.** Every skill in `skills/` is a SKILL.md with frontmatter: `name`, `description`, `allowed-tools`, and optionally `context: fork`, `disable-model-invocation: true`, `agent:`, `memory:`.

2. **Agents use markdown with frontmatter.** Each agent in `agents/` has YAML frontmatter with `name`, `description`, `allowed-tools`, `maxTurns`, and a prompt body.

3. **Shell scripts must be POSIX-safe.** All scripts in `scripts/` should pass `bash -n` and `shellcheck`. They use `jq` for JSON manipulation.

4. **Runtime files are NOT part of the plugin.** The `hydra/` directory (config.json, plan.md, tasks/, checkpoints/, etc.) is created per-project by `/hydra-init`. This repo contains only the plugin code.

## Code Style

- Shell scripts: Use `set -euo pipefail`. Quote all variables. Use `jq` for JSON, not sed/grep.
- Markdown: Use ATX headers (`#`). Fenced code blocks with language tags.
- YAML frontmatter: Consistent indentation (2 spaces). Quote string values with special characters.
- File naming: kebab-case for all files. UPPERCASE for docs (CLAUDE.md, README.md).

## Key Concepts

**Files are memory, context is working memory.** Every piece of state lives on disk. The context window is ephemeral.

**Classify first, always.** Discovery classifies the project (greenfield/brownfield/refactor/bugfix/migration) to determine which agents spawn and which documents generate.

**Documents before code.** After classification, the Doc Generator creates PRDs, TRDs, ADRs before any planning happens.

**Conditional agent roster.** Discovery generates only the agents this project needs. All 29 agents exist as specs, but only relevant ones are instantiated per-project.

**State machine is sacred.** Tasks follow: PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE (or CHANGES_REQUESTED -> retry, or BLOCKED). No skipping states.

**Review board is non-negotiable.** ALL reviewers must approve before a task can be DONE. Confidence scores below 80 become non-blocking warnings instead of rejections.

**Recovery must be automatic.** After any interruption, reading the Recovery Pointer + latest checkpoint + active task manifest must give enough information to resume.

## Dependencies

- `jq` — Required for all JSON manipulation in shell scripts
- `git` — Required for commit tracking and state persistence
- Claude Code with Agent Teams support (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)

## Testing

```bash
tests/run-tests.sh
```
