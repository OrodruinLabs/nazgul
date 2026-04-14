# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-04-14

### Added
- Interactive selectable prompts via `AskUserQuestion` across 6 skills (init, bootstrap-project, clean, reset, gen-spec, board)
- `marketplace.json` for Orodruin Labs plugin marketplace distribution
- `keywords` field in plugin manifest for discoverability
- GitHub repo description and topics

### Changed
- Renamed project from Hydra to Nazgul
- New logo assets (dark/light theme, transparent backgrounds)
- Modernized README install instructions (marketplace, direct install, manual clone)
- Improved bootstrap-project README section readability
- Simplified plugin.json — removed explicit paths, uses auto-discovery

### Removed
- Old Hydra branding and logo assets
- Stale `docs/plans/` from prior development iterations
- Mermaid flowchart from README

## [1.0.0] - 2026-04-13

### Added
- Initial public release as Nazgul
- 17 core agents (discovery, planner, implementer, review-gate, and more)
- 20 skills (`/nazgul:init`, `/nazgul:start`, `/nazgul:status`, etc.)
- Review board with unanimous approval requirement
- Fix-first review (auto-fix mechanical issues, ask about risky changes)
- Recovery system (checkpoints, recovery pointers, session tracking)
- Agent Teams support for parallel task execution
- Bootstrap-project for portable Nazgul-free bundles
- 24 unit/integration tests + E2E test suite
- CI pipelines (test, E2E, skill-docs freshness)
