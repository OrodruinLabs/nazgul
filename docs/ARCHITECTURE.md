# Architecture

## Pipeline

```
Objective → Discovery (+Classification) → Doc Generator → Planner → Implementer → Review Board → Loop → Post-Loop → NAZGUL_COMPLETE
```

1. **Discovery Agent** scans the codebase, classifies the project, generates tailored reviewer agents
2. **Doc Generator** produces PRDs, TRDs, ADRs based on project type
3. **Planner Agent** decomposes the objective into dependency-ordered tasks
4. **Implementer Agent** builds one task at a time, delegates to specialists as needed
5. **Review Board** (Architect, Code, Security + project-specific reviewers) reviews each task
6. **Feedback Aggregator** classifies findings as AUTO-FIX or ASK (per `references/fix-first-heuristic.md`), then consolidates into actionable fixes
7. Loop continues until ALL tasks pass ALL reviewers
8. **Post-Loop** agents update docs, manage releases, verify observability

## Agent Roster (core agents + project-specific reviewers)

| Category | Agents |
|----------|--------|
| Pipeline (always) | Discovery, Doc Generator, Planner, Implementer, Review Gate, Feedback Aggregator, Team Orchestrator |
| Reviewers (conditional) | Architect, Code, Security, QA, Performance, A11y, DB, API, Type, Infra, Dependency, Mobile, Data |
| Specialists (conditional) | Designer, Frontend Dev, Mobile Dev, DevOps, CI/CD, DB Migration, Debugger |
| Post-Loop (conditional) | Documentation, Release Manager, Observability, Simplifier |

Discovery generates only the agents a given project needs. The full set of core agents exists as specs, plus a reviewer template (`agents/templates/reviewer-base.md`) that spawns project-specific reviewers driven by `agents/templates/reviewer-domains.json`.

## Telemetry & Observability

Nazgul maintains a canonical, schema-versioned event stream at `nazgul/logs/events.jsonl` — an append-only JSONL file where hooks and agents emit structured telemetry. This consolidates what was previously scattered across multiple files (`iterations.jsonl`, `subagents.jsonl`, in-place config mutations, and dotfiles).

### Event Stream

The event stream captures the complete lifecycle:

- **Iteration boundaries** — when the loop stops after each iteration
- **Task lifecycle** — task completion events
- **Review verdicts** — approvals/rejections from the review board with confidence scores
- **Retries and blocks** — re-attempts after CHANGES_REQUESTED, and blocking states that require intervention
- **Compaction milestones** — checkpoints during context compression
- **Subagent lifecycle** — when specialized agents (implementer, discovery, etc.) complete
- **Budget/cost warnings** — proactive alerts before spending limits

See `docs/superpowers/specs/2026-06-24-telemetry-bus-design.md` for the full event taxonomy and schema.

### Emit Library

`scripts/lib/emit-event.sh` is the canonical append mechanism — atomically writes one JSON event line per call using `flock` (Linux) or a mv-based swap (macOS). Callers pass event type + key-value pairs; the library handles schema versioning, timestamps (ISO 8601 UTC), and iteration context.

Used by:
- **5 hook scripts** (`stop-hook.sh`, `task-completed.sh`, `subagent-stop.sh`, `stop-failure.sh`, `post-compact.sh`) — write producer events
- **Review-gate agent** (`agents/review-gate.md`) — emits reviewer verdicts, retry dispatch, and blocks
- **Agents via CLI wrapper** (`scripts/emit-event-cli.sh`) — agent-friendly invoke pattern

### Migration: Single-Write + Dual-Read

The migration from scattered telemetry to `events.jsonl` is **single-write + dual-read**:

- **Producers** (hooks and review-gate agent) write ONLY the new `events.jsonl` stream. Legacy `iterations.jsonl` and `subagents.jsonl` are no longer appended; they freeze in place as historical records (not deleted).
- **Consumers** (`/nazgul:metrics`, `/nazgul:log` skills) prefer the new `events.jsonl` but fall back permanently to frozen legacy files for pre-upgrade history. This preserves full event history across upgrades with zero data loss.
- **No parallel writes, no cutover step, no v15.** The emit library is proven by mandatory unit + concurrency tests; one append-only write is the lowest-risk telemetry design. This approach avoids the complexity of dual-write + version cutover while keeping consumers forward/backward compatible.

## Recovery

Nazgul survives compaction, crashes, and session restarts:

1. **Pre-compact hook** writes a checkpoint before compaction
2. **Post-compact hook** re-injects loop state immediately after compaction completes
3. **Session-context hook** re-injects state on startup/compaction
4. **Recovery Pointer** in plan.md tells the agent exactly where to resume
5. **Checkpoint files** in `nazgul/checkpoints/` have full JSON state snapshots
6. **Webhook forwarding** optionally notifies external systems on stop/compact events
7. **TaskCompleted hook** fires immediately when spawned agents finish for faster transitions
8. **Prompt guard hook** validates user prompts on submission
9. **Task-state guard hook** prevents edits outside claimed task scope

After any interruption:
```bash
/nazgul:start              # Auto-detects state and resumes from last checkpoint
/nazgul:status             # See where things stand
```

## Review Gate & Fix-First Review

When the review board returns CHANGES_REQUESTED, the feedback aggregator classifies each finding:
- **AUTO-FIX**: Mechanical issues (dead code, style, stale comments) — applied automatically
- **ASK**: Risky changes (security, architecture, API contracts) — presented for judgment

The review gate's Step 3.75 applies auto-fixes, re-runs tests, and only surfaces ASK items. This reduces review round-trips significantly. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA in the task manifest, IN_REVIEW requires a review directory, and source edits require an IN_PROGRESS task.

## Testing & CI

### E2E Skill Testing
`tests/e2e/run-e2e.sh` spawns `claude -p` subprocesses to validate skills end-to-end. Gracefully skips when the `claude` CLI is unavailable. CI workflow (`e2e-tests.yml`) is manual-trigger only since tests cost money.

### Skill Template System
`scripts/gen-skill-docs.sh` resolves `{{PARTIAL:name}}` placeholders in `SKILL.md.tmpl` files using shared partials from `templates/skill-partials/`. CI workflow (`skill-docs.yml`) checks for stale SKILL.md files on PRs.

### CI Pipelines
- `test.yml` — runs unit/integration tests on push and PR
- `e2e-tests.yml` — E2E skill tests via `claude -p` (manual trigger)
- `skill-docs.yml` — checks SKILL.md freshness on PRs touching skills/partials

## Self-Improvement Mode
Agents optionally self-rate their experience (0-10) and file structured JSON reports via `scripts/file-improvement-report.sh`. Enabled per-project in config. `/nazgul:metrics` aggregates reports.

## Concurrent Session Tracking
`scripts/lib/session-tracker.sh` manages filesystem locks in `nazgul/sessions/`. Sessions register on startup, unregister on exit, and stale locks (>2h) are cleaned automatically. Concurrent sessions trigger a warning to prevent state corruption.

## Shared Task Utilities
`scripts/lib/task-utils.sh` provides `get_task_status`, `set_task_status`, `count_tasks_by_status`, and `get_active_task`. Supports 4 status formats: list-item, ATX inline, ATX block, and YAML frontmatter.

## Directory Structure

The repo IS the installable plugin. Runtime state lives under `nazgul/` in each target project (created by `/nazgul:init`), never in this repo.

```
.claude-plugin/plugin.json   # Plugin manifest (must be at repo root)
RULES.md                     # Enforceable operating rules (consolidated)
agents/                      # Agent definitions (18 specs + reviewer template)
│   └── templates/           # reviewer-base.md + reviewer-domains.json
skills/                      # Slash commands (/nazgul:*) — 22 skills
hooks/hooks.json             # Hook definitions (9 hook types: Stop, PreCompact,
│                            #   PostCompact, PreToolUse, PostToolUse, SessionStart,
│                            #   SessionEnd, TaskCompleted, UserPromptSubmit)
scripts/                     # Hook + sync scripts (18 + 7 libs)
│   └── lib/                 # Shared libraries (task-utils, session-tracker,
│                            #   emit-event, review-evidence, bootstrap-{scrub-map,render,preflight,relocate})
templates/                   # Objective + doc templates
│   └── skill-partials/      # Shared SKILL.md template partials
references/                  # Shared reference docs for agents
tests/                       # Plugin validation tests (unit, integration, E2E)
.github/workflows/           # CI pipelines (test, e2e, skill-docs freshness)

# Created per-project by /nazgul:init (NOT part of the plugin):
nazgul/
├── config.json              # Runtime configuration
├── plan.md                  # Live task tracker with Recovery Pointer
├── tasks/                   # Individual task manifests with full state
├── checkpoints/             # Per-iteration JSON snapshots
├── reviews/                 # Review artifacts per task
├── context/                 # Project context from Discovery
├── docs/                    # Generated project documents (PRD, TRD, ADRs)
└── logs/                    # Runtime telemetry (events.jsonl + frozen legacy history)
```
