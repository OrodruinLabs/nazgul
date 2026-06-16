# Changelog

All notable changes to this project will be documented in this file.

## [1.3.4] - 2026-06-16

### Fixed
- Subagent definitions `agents/discovery.md` and `agents/templates/reviewer-base.md` carried an `allowed-tools:` frontmatter line, which is a **skills** field and is silently ignored on subagents (the honored field is `tools:`, which both files also have). Net effect was a false sense of restriction — notably the reviewer's intended `Bash(npm test *)`-style scoping was never enforced. Removed the dead lines; reviewers keep `Bash` (needed for tests) and remain covered by the PreToolUse destructive-command guard. Verified against the official subagents frontmatter reference
- `CLAUDE.md` build rules listed `memory:` as a valid optional skill frontmatter field; it is **not** supported for skills (silently ignored) and no skill actually used it. Corrected the rule and enumerated the real optional fields (`argument-hint`, `arguments`, `disallowed-tools`, `model`, `paths`)

### Added
- `StopFailure` hook (`scripts/stop-failure.sh`): a turn ending on an API error previously left an AFK/autonomous loop silently stalled. Now records the failure to the iteration log, writes a `.stop_failure` recovery breadcrumb, runs the configured `notifications.on_failure`/`on_complete` command, and forwards a webhook event
- `SubagentStop` hook (`scripts/subagent-stop.sh`): lightweight observability — appends one line per finished subagent (with agent type when present) to `nazgul/logs/subagents.jsonl`
- `effort: high` on the `planner` and `debugger` agents (newly-supported subagent frontmatter field) to route the deepest-reasoning stages to higher reasoning effort
- `argument-hint` autocomplete hints on `init` (`[--local] [--force]`), `config` (`[models]`), and `start` — surfaces accepted flags as the user types, directly improving the discoverability gap behind the original `--local` bug
- `tests/test-observability-hooks.sh` — behavioral tests for the two new hook scripts (no-op without config, correct logging + breadcrumb with config, agent-name extraction)

### Notes
- Reviewed the plugin against current (June 2026) Claude Code docs. Confirmed already-correct and intentionally left unchanged: `PreCompact`/`PostCompact` + `SessionStart` source matching for compaction recovery, bare model aliases (`opus`/`sonnet`/`haiku` — they auto-track the latest snapshot; pinning full versioned IDs would freeze stale models), the hooks.json format, and the hand-rolled checkpoint/Recovery-Pointer system. `isolation: worktree` is a real new subagent field but was intentionally NOT adopted because Nazgul already manages worktrees manually (EnterWorktree/ExitWorktree); adding it would double-create worktrees

## [1.3.3] - 2026-06-16

### Fixed
- `/nazgul:init --local` silently behaved as shared mode: the `--local`/`--force` flags were buried inline in numbered-step prose, so the model unreliably acted on them — `.gitignore` got no `nazgul/` block, `install_mode` was never set to `local`, and the shared-mode CLAUDE.md section was appended anyway. `skills/init/SKILL.md` now carries an explicit `## Arguments` block (the convention 16 other skills already follow) and Step 0.5 forces the parsed decision to be **emitted to the user** (`Parsed arguments: ... LOCAL_MODE = ... FORCE = ...`) before any branch, with a backstop that halts if the `$ARGUMENTS` placeholder ever fails to substitute
- `/nazgul:config models` had the same latent defect: the `models` shortcut token was read from an inline `$ARGUMENTS` reference with no `## Arguments` block. Added the block and pointed the shortcut check at it
- Note: contrary to the original design spec's root-cause theory, Claude Code substitutes `$ARGUMENTS` wherever it appears in a skill body (and appends `ARGUMENTS:` when absent), so arguments always reached the model — the real defect was instruction reliability, not missing substitution. The `## Arguments` block is a clarity/consistency convention, and the forced echo in Step 0.5 is the actual robustness fix

### Added
- `tests/test-skill-arguments.sh` — regression test enforcing that every skill referencing `$ARGUMENTS` also surfaces it via a bare-line substitution block. Fails on pre-fix `main` (listing `init` and `config`), passes after the fix. Auto-discovered by `tests/run-tests.sh`

## [1.3.2] - 2026-06-04

### Fixed
- YOLO review-gate livelock from a verdict verb-form mismatch: reviewer agents write `## Verdict: APPROVE`, but `_has_approved_verdict` in `scripts/lib/review-evidence.sh` only matched the past participle `approved`, so every fully-reviewed file read as `UNAPPROVED` and the stop hook reset all tasks `DONE → IMPLEMENTED` every iteration (burning the full `--max` budget after a false `NAZGUL_COMPLETE`). The matcher now accepts `APPROVE`/`APPROVES`/`APPROVED` while keeping anchoring and a word boundary so `approval denied` and the `approved` substring in `UNAPPROVED` don't false-match
- Reviewer template (`agents/templates/reviewer-base.md`) now requires exactly one verbatim verdict line with the canonical token and explicitly forbids the imperative `APPROVE`, preventing recurrence

## [1.3.1] - 2026-06-04

### Fixed
- `/nazgul:start` now resets loop counters (`current_iteration`, `safety.consecutive_failures`, `safety._prev_done_count`) on every loop-starting path. Previously only the ACTIVE_LOOP/`--continue` resume paths reset `current_iteration` and nothing ever reset `consecutive_failures`, so starting a fresh objective (e.g. `/nazgul:start --yolo`) with stale counters at/over their caps silently bricked the loop — the Stop hook hit its max-iteration or consecutive-failure gate and exited 0 (allowed the stop) instead of re-dispatching, despite READY tasks
- Restored four README-linked docs (`docs/ARCHITECTURE.md`, `CONFIGURATION.md`, `SAFETY.md`, `PLUGINS.md`) deleted in the Hydra→Nazgul rebrand, rebranded and fact-checked against the current codebase — the README "Learn More" links no longer 404

## [1.3.0] - 2026-06-03

### Fixed
- YOLO loop livelock: tasks could never reach DONE when review verdicts were written to a consolidated `summary.md` instead of per-reviewer files — the state guard and stop hook silently fought every transition forever
- Stop hook review-gate resets are now diagnostic: the continue message and JSON reason name the exact missing/unapproved reviewers and the repair command (previously stderr-only, never surfaced)
- Evidence validation logic deduplicated into `scripts/lib/review-evidence.sh` — `task-state-guard.sh` and `stop-hook.sh` had already drifted (`simplify-report.md` exclusion differed)
- Review Gate agent now verifies every configured reviewer wrote its file before aggregating verdicts (Step 2.5), and re-reads task manifests from disk before emitting NAZGUL_COMPLETE
- `/nazgul:start` OBJECTIVE_COMPLETE state and Rule 10 require disk verification before any completion claim
- BLOCKED was a dead-end in the state guard's transition matrix — `BLOCKED → READY` (unblock) and `BLOCKED → IN_REVIEW` (materialize, review directory required) are now legal exits

### Added
- `/nazgul:review --materialize [TASK-ID | --all]` — repair command that re-runs the full reviewer board for tasks stuck without per-reviewer evidence, reconstructing `diff.patch` from manifest commit SHAs when missing
- Livelock breaker: a second consecutive review-gate reset for the same task escalates to BLOCKED with a remediation note instead of looping (reset counts in `config.json` `.safety._review_reset_counts`)
- `tests/test-review-evidence.sh` — unit tests for the shared validation library, including the summary.md-only regression case

## [1.2.2] - 2026-04-16

### Fixed
- `/nazgul:bootstrap-project` no longer asks "what are you building?" on brownfield projects — the codebase IS the spec, Discovery derives everything automatically
- `detect_project_type()` uses `-prune` instead of `! -path` filters, avoiding slow traversals into `node_modules/`, `vendor/`, etc.
- `--yes` flag now correctly aborts on greenfield projects with no objective instead of blocking on interactive prompts
- Skill frontmatter `metadata.version` synced to plugin version across all 21 SKILL.md files (was stuck at 1.0.0/1.1.0)

### Added
- `detect_project_type()` in `bootstrap-preflight.sh` — counts source files to classify brownfield (>= 5) vs greenfield
- Three-tier objective collection in bootstrap Phase 2: explicit argument > brownfield auto-derive > greenfield interactive
- 5 new test cases for `detect_project_type` (empty dir, below threshold, at threshold, excluded dirs pruned, config-only files)

## [1.2.1] - 2026-04-14

### Fixed
- Pre-load `AskUserQuestion` via `ToolSearch` in all interactive skills (was failing when the deferred tool hadn't been loaded yet)

## [1.2.0] - 2026-04-14

### Added
- Per-stage model routing — configure which AI model (Opus, Sonnet, Haiku) runs each pipeline stage
- New `/nazgul:config` skill — view and change settings (models, formatter, notifications) after init
- Model presets: Balanced (default), Quality, Fast/cheap
- Per-stage customization via interactive `AskUserQuestion` prompts
- Model configuration step in `/nazgul:init` Step 7
- Generated reviewer and specialist agents now include `model:` in frontmatter
- Unit tests for model routing config and skill wiring

### Changed
- Default model assignments updated to balanced preset (Opus for planning, Sonnet for implementation/review, Haiku for post-loop)

## [1.1.0] - 2026-04-14

### Added
- Interactive selectable prompts via `AskUserQuestion` across 6 skills (init, bootstrap-project, clean, reset, gen-spec, board)

## [1.0.0] - 2026-04-14

### Added
- Initial public release as Nazgul (renamed from Hydra)
- 17 core agents (discovery, planner, implementer, review-gate, and more)
- 20 skills (`/nazgul:init`, `/nazgul:start`, `/nazgul:status`, etc.)
- Review board with unanimous approval requirement
- Fix-first review (auto-fix mechanical issues, ask about risky changes)
- Recovery system (checkpoints, recovery pointers, session tracking)
- Agent Teams support for parallel task execution
- Bootstrap-project for portable Nazgul-free bundles
- `marketplace.json` for Orodruin Labs plugin marketplace distribution
- New logo assets (dark/light theme, transparent backgrounds)
- Modernized README install instructions (marketplace, direct install, manual clone)
- 24 unit/integration tests + E2E test suite
- CI pipelines (test, E2E, skill-docs freshness)
