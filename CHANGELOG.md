# Changelog

All notable changes to this project will be documented in this file.

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
