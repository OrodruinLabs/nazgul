# Documentation Update Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Update all internal docs (CLAUDE.md, ARCHITECTURE.md, CONFIGURATION.md, SAFETY.md) to reflect features from PRs #1-#5: shared task utilities, CI workflows, fix-first review, E2E testing, skill templates, self-improvement mode, session tracking, and YAML frontmatter task status.

**Architecture:** Pure documentation changes across 4 files. No code changes. Each task updates one file completely, then commits.

**Tech Stack:** Markdown

---

### Task 1: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update install path**

Change line 7 from:
```
**Install:** `claude --plugin-dir /path/to/ai-hydra` or clone to `~/.claude/plugins/hydra`.
```
To:
```
**Install:** `claude --plugin-dir /path/to/ai-hydra-framework` or clone to `~/.claude/plugins/hydra`.
```

**Step 2: Update directory structure — scripts section (lines 46-53)**

Replace the scripts block with the full current list:
```
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
│   └── lib/                         # Shared libraries
│       ├── task-utils.sh            # Task status parsing (4 formats) + counting
│       └── session-tracker.sh       # Concurrent session lock management
```

**Step 3: Update directory structure — references section (lines 58-60)**

Replace with:
```
references/                          # Shared reference docs for agents
│   ├── ui-brand.md                  # Visual identity and output formatting
│   ├── verification-patterns.md     # Stub detection and wiring verification
│   ├── fix-first-heuristic.md       # AUTO-FIX vs ASK classification rules
│   └── self-improvement.md          # Agent self-rating protocol
```

**Step 4: Update directory structure — templates section (lines 54-57)**

Replace with:
```
templates/                           # Objective + document templates
│   ├── CLAUDE.md.template           # Injected into target projects by /hydra:init
│   ├── feature.md / tdd.md / bugfix.md / refactor.md / greenfield.md / migration.md
│   ├── docs/                        # Document templates for doc-generator
│   └── skill-partials/              # Shared partials for SKILL.md templates
│       ├── preamble.md              # Standard output formatting + recovery protocol
│       └── recovery-protocol.md     # 4-step file-first recovery
```

**Step 5: Update directory structure — tests section (line 61)**

Replace with:
```
tests/                               # Plugin validation tests
│   ├── run-tests.sh                 # Test runner (18 test files)
│   ├── test-*.sh                    # Unit/integration tests
│   ├── lib/                         # Test assertions + setup helpers
│   └── e2e/                         # E2E skill tests via claude -p
.github/workflows/                   # CI pipelines
│   ├── test.yml                     # Unit/integration tests on push/PR
│   ├── e2e-tests.yml                # E2E skill tests (manual trigger)
│   └── skill-docs.yml               # Skill template freshness check on PR
```

**Step 6: Add fix-first to Key Concepts (after line 94)**

Add:
```
**Fix-first review.** Feedback aggregator classifies findings as AUTO-FIX (mechanical — applied automatically) or ASK (risky — requires judgment). Review gate Step 3.75 applies auto-fixes before presenting remaining items.
```

**Step 7: Update Testing section (lines 104-108)**

Replace with:
```markdown
## Testing

```bash
tests/run-tests.sh                    # Run all unit/integration tests (18 files)
tests/run-tests.sh --filter=stop-hook # Run specific test file
tests/e2e/run-e2e.sh                  # Run E2E skill tests (requires claude CLI, costs money)
```

CI runs automatically on push (`test.yml`) and checks skill template freshness on PRs (`skill-docs.yml`). E2E tests are manual trigger only (`e2e-tests.yml`).
```

**Step 8: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md — add all scripts, references, templates, CI, fix-first, E2E testing"
```

---

### Task 2: Update docs/ARCHITECTURE.md

**Files:**
- Modify: `docs/ARCHITECTURE.md`

**Step 1: Update pipeline step 6 (line 14)**

Change:
```
6. **Feedback Aggregator** consolidates rejections into actionable fixes
```
To:
```
6. **Feedback Aggregator** classifies findings as AUTO-FIX or ASK (per `references/fix-first-heuristic.md`), then consolidates into actionable fixes
```

**Step 2: Add new section after Recovery (after line 45)**

Add:
```markdown
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
```

**Step 3: Update directory structure — add missing entries (lines 71-74)**

Change:
```
├── scripts/                    # Hook + sync scripts (15)
└── templates/                  # Objective + doc templates
```
To:
```
├── scripts/                    # Hook + sync scripts (17 + 2 libs)
│   └── lib/                    # Shared libraries (task-utils.sh, session-tracker.sh)
├── templates/                  # Objective + doc templates
│   └── skill-partials/         # Shared SKILL.md template partials
└── .github/workflows/          # CI pipelines (test, e2e, skill-docs freshness)
```

**Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: update ARCHITECTURE.md — fix-first review, E2E testing, self-improvement, session tracking, CI"
```

---

### Task 3: Update docs/CONFIGURATION.md

**Files:**
- Modify: `docs/CONFIGURATION.md`

**Step 1: Add --task-pr flag to flags section (after line 9)**

Add:
```
- `--task-pr` — (with `--yolo`) Create stacked per-task PRs targeting the feature branch instead of a single PR at completion
```

**Step 2: Add Self-Improvement section (after line 108)**

Add:
```markdown
## Self-Improvement Mode

Enable agent self-rating and improvement reports:

```json
{
  "self_improvement": {
    "enabled": true,
    "threshold": 7
  }
}
```

Agents rating their experience below the threshold file structured JSON reports to `hydra/improvement-reports/`. Reports include task ID, agent name, rating, summary, and improvement suggestions. View aggregated data with `/hydra:metrics`.

## Concurrent Session Detection

Hydra automatically tracks active sessions via filesystem locks in `hydra/sessions/`. Stale locks (>2 hours) are cleaned automatically. If multiple sessions target the same project, a warning is issued on startup. No configuration needed — always active.
```

**Step 3: Commit**

```bash
git add docs/CONFIGURATION.md
git commit -m "docs: update CONFIGURATION.md — add --task-pr flag, self-improvement, session tracking"
```

---

### Task 4: Update docs/SAFETY.md

**Files:**
- Modify: `docs/SAFETY.md`

**Step 1: Add fix-first and session tracking guardrails (after line 24)**

Add:
```
- **Fix-first auto-remediation**: Mechanical review findings (dead code, style) are applied automatically; only risky changes (security, architecture) require human judgment
- **Concurrent session detection**: Filesystem locks warn when multiple Hydra sessions run on the same project, preventing state corruption
```

**Step 2: Add troubleshooting entry (after line 42)**

Add:
```markdown
**"Multiple concurrent sessions detected"** — Ensure only one Hydra session per project at a time. Stale locks are cleaned after 2 hours, or delete `hydra/sessions/*.lock` manually.
```

**Step 3: Commit**

```bash
git add docs/SAFETY.md
git commit -m "docs: update SAFETY.md — add fix-first and session tracking guardrails"
```

---

### Task 5: Final commit and push

**Step 1: Run tests to verify no breakage**

```bash
tests/run-tests.sh
```
Expected: 18 files, all pass (docs changes don't affect tests)

**Step 2: Push branch and create PR**

```bash
git push -u origin docs/post-merge-updates
gh pr create --base main --title "docs: update internal docs for PRs #1-#5" --body "..."
```
