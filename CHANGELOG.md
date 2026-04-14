# Changelog

All notable changes to this project will be documented in this file.

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
