# CLAUDE.md — Nazgul Framework Plugin

## What This Project Is

Nazgul is a Claude Code plugin that provides multi-agent autonomous development. This repo IS the installable plugin.

**Install:** `claude --plugin-dir /path/to/ai-nazgul-framework` or clone to `~/.claude/plugins/nazgul`.

## Directory Structure

```
.claude-plugin/plugin.json           # Plugin manifest (must be at repo root)
RULES.md                             # Enforceable operating rules (consolidated)
skills/                              # User-facing commands (/nazgul:*)
│   ├── init/SKILL.md
│   ├── start/SKILL.md
│   ├── status/SKILL.md
│   ├── review/SKILL.md
│   ├── discover/SKILL.md
│   ├── context/SKILL.md
│   ├── simplify/SKILL.md
│   ├── docs/SKILL.md
│   ├── patch/SKILL.md
│   ├── verify/SKILL.md
│   ├── metrics/SKILL.md
│   └── bootstrap-project/SKILL.md   # Emit portable Nazgul-free bundle (one-shot)
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
│   ├── debugger.md                  # Specialist: investigation on repeated failures
│   ├── documentation.md             # Post-loop: README, API docs, changelog
│   ├── release-manager.md           # Post-loop: versioning, release notes
│   ├── observability.md             # Post-loop: logging, metrics, error tracking
│   └── templates/                   # Reviewer base template + domain config
hooks/hooks.json                     # Hook configuration
scripts/                             # Shell scripts for hooks
│   ├── stop-hook.sh                 # Stop: loop engine, state machine, checkpoints
│   ├── pre-compact.sh               # PreCompact: checkpoint before compaction
│   ├── post-compact.sh              # PostCompact: re-inject state after compaction
│   ├── pre-tool-guard.sh            # PreToolUse: block destructive commands
│   ├── task-state-guard.sh          # PreToolUse: verify task state before edits
│   ├── prompt-guard.sh              # UserPromptSubmit: validate user prompts
│   ├── session-context.sh           # SessionStart: inject loop state + session tracking
│   ├── session-staging.sh           # SessionEnd: stage files for AFK safety
│   ├── formatter.sh                 # PostToolUse: auto-format after edits (opt-in)
│   ├── notify.sh                    # Stop: completion notifications
│   ├── webhook-forward.sh           # Stop/Compact: forward events to HTTP endpoints
│   ├── task-completed.sh            # TaskCompleted: update board, record metrics
│   ├── board-sync-github.sh         # GitHub Projects board sync
│   ├── migrate-config.sh            # Config schema migration (v1→v5)
│   ├── worktree-utils.sh            # Git worktree helper functions
│   ├── file-improvement-report.sh   # Self-improvement: write JSON reports
│   ├── gen-skill-docs.sh            # Skill template: resolve {{PARTIAL:name}}
│   ├── bootstrap-transform.sh       # bootstrap-project: Nazgul-token scrub pass
│   └── lib/                         # Shared libraries
│       ├── task-utils.sh            # Task status parsing (4 formats) + counting
│       ├── session-tracker.sh       # Concurrent session lock management
│       ├── bootstrap-scrub-map.sh   # bootstrap-project: scrub rules data
│       ├── bootstrap-render.sh      # bootstrap-project: prompt rendering + domain helpers
│       ├── bootstrap-preflight.sh   # bootstrap-project: pre-flight gate checks
│       └── bootstrap-relocate.sh    # bootstrap-project: atomic staged relocation
templates/                           # Objective + document templates
│   ├── CLAUDE.md.template           # Injected into target projects by /nazgul:init
│   ├── feature.md / tdd.md / bugfix.md / refactor.md / greenfield.md / migration.md
│   ├── docs/                        # Document templates for doc-generator
│   └── skill-partials/              # Shared partials for SKILL.md templates
│       ├── preamble.md              # Standard output formatting + recovery
│       └── recovery-protocol.md     # 4-step file-first recovery
references/                          # Shared reference docs for agents
│   ├── ui-brand.md                  # Visual identity and output formatting
│   ├── verification-patterns.md     # Stub detection and wiring verification
│   ├── fix-first-heuristic.md       # AUTO-FIX vs ASK classification rules
│   └── self-improvement.md          # Agent self-rating protocol
tests/                               # Plugin validation tests
│   ├── run-tests.sh                 # Test runner (24 unit/integration files)
│   ├── test-*.sh                    # Unit/integration tests
│   ├── fixtures/                    # Test fixtures (bootstrap-transform scrub cases)
│   ├── lib/                         # Test assertions + setup helpers
│   └── e2e/                         # E2E skill tests via claude -p
.github/workflows/                   # CI pipelines
│   ├── test.yml                     # Unit/integration tests on push/PR
│   ├── e2e-tests.yml                # E2E skill tests (manual trigger)
│   └── skill-docs.yml               # Skill template freshness check on PR
```

## Build Rules

1. **Skills use YAML frontmatter.** Every skill in `skills/` is a SKILL.md with frontmatter: `name`, `description`, `allowed-tools`, and optionally `context: fork`, `disable-model-invocation: true`, `agent:`, `memory:`.

2. **Agents use markdown with frontmatter.** Each agent in `agents/` has YAML frontmatter with `name`, `description`, `allowed-tools`, `maxTurns`, and a prompt body.

3. **Shell scripts must be POSIX-safe.** All scripts in `scripts/` should pass `bash -n` and `shellcheck`. They use `jq` for JSON manipulation.

4. **Runtime files are NOT part of the plugin.** The `nazgul/` directory (config.json, plan.md, tasks/, checkpoints/, etc.) is created per-project by `/nazgul:init`. This repo contains only the plugin code.

## Code Style

- Shell scripts: Use `set -euo pipefail`. Quote all variables. Use `jq` for JSON, not sed/grep.
- Markdown: Use ATX headers (`#`). Fenced code blocks with language tags.
- YAML frontmatter: Consistent indentation (2 spaces). Quote string values with special characters.
- File naming: kebab-case for all files. UPPERCASE for docs (CLAUDE.md, README.md).
- Git: The default branch is always `main`, never `master`. All agent and skill references to the default branch must use `main`.

## Key Concepts

**Files are memory, context is working memory.** Every piece of state lives on disk. The context window is ephemeral.

**Classify first, always.** Discovery classifies the project (greenfield/brownfield/refactor/bugfix/migration) to determine which agents spawn and which documents generate.

**Documents before code.** After classification, the Doc Generator creates PRDs, TRDs, ADRs before any planning happens.

**Conditional agent roster.** Discovery generates only the agents this project needs. 17 core agents exist as specs, plus a reviewer template that spawns project-specific reviewers. Only relevant ones are instantiated per-project.

**State machine is sacred.** Tasks follow: PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE (or CHANGES_REQUESTED -> retry, or BLOCKED). No skipping states.

**Review board is non-negotiable.** ALL reviewers must approve before a task can be DONE. Confidence scores below 80 become non-blocking warnings instead of rejections.

**Fix-first review.** Feedback aggregator classifies findings as AUTO-FIX (mechanical — applied automatically) or ASK (risky — requires judgment). Review gate Step 3.75 applies auto-fixes before presenting remaining items.

**Recovery must be automatic.** After any interruption, reading the Recovery Pointer + latest checkpoint + active task manifest must give enough information to resume.

## Dependencies

- `jq` — Required for all JSON manipulation in shell scripts
- `git` — Required for commit tracking and state persistence
- Claude Code with Agent Teams support (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)

## Testing

```bash
tests/run-tests.sh                    # Run all unit/integration tests (24 files)
tests/run-tests.sh --filter=stop-hook # Run specific test file
tests/e2e/run-e2e.sh                  # Run E2E skill tests (requires claude CLI, costs money)
```

CI runs automatically on push (`test.yml`) and checks skill template freshness on PRs (`skill-docs.yml`). E2E tests are manual trigger only (`e2e-tests.yml`).
