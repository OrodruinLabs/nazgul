---
status: DONE
---
# TASK-006: Version-bump hygiene (plugin.json 2.3.0→2.4.0 + README badge + CHANGELOG)

## Metadata
- **ID**: TASK-006
- **Group**: 4
- **Status**: (see `status:` in the frontmatter block at the top — that is canonical, read by scripts/lib/structured-state.sh; not duplicated here to avoid drift)
- **Depends on**: TASK-002, TASK-003, TASK-004, TASK-005
- **Delegates to**: none
- **Files modified**: [.claude-plugin/plugin.json, README.md, CHANGELOG.md]
- **Wave**: 4
- **Traces to**: PRD AC ("full test suite green; shellcheck + bash -n clean"); project release convention (MEMORY: feedback_version_bump_skills.md); ADR-006
- **Created at**: 2026-06-24T12:40:00Z
- **Claimed at**: 2026-06-24T17:30:00Z
- **Base SHA**: 8bd3f9933e8dbb2a744216b8610f45c4c5eceeff
- **Implemented at**: 2026-06-24T17:45:00Z
- **Completed at**: 2026-06-24T18:30:00Z
- **Blocked at**:
- **Retry count**: 0/3
- **Merge commit**: 0a0c723
- **Test failures**: 0

## Description
Release-hygiene task: bump the plugin version and record the feature, per the
project convention of bumping on every shipped feature (MEMORY:
`feedback_version_bump_skills.md` — sync plugin.json + README badge + CHANGELOG
together). The Loop Telemetry Bus is a backward-compatible, additive feature
(new event stream, additive config migration, dual-read consumers) → a MINOR bump.

1. `.claude-plugin/plugin.json` — bump `version` from `2.3.0` to `2.4.0`.
2. `README.md` — update the version badge to `2.4.0` (keep wording/format consistent
   with the existing badge).
3. `CHANGELOG.md` — add a `2.4.0` section summarizing FEAT-001: canonical
   `nazgul/logs/events.jsonl` event stream emitted by 5 hooks + the review-gate
   agent; 10 event types; `migrate_13_to_14` telemetry block
   (`bus_enabled`, `record_metered_cost`); single-write producers + permanent
   dual-read consumers (`metrics`/`log`); `telemetry.bus_enabled:false` kill switch.
   Match the existing CHANGELOG entry format (e.g. the 2.3.0 entry).

This task runs LAST so the CHANGELOG accurately reflects what shipped. Verify the
full suite is green (`tests/run-tests.sh`) and that `plugin.json` remains valid
JSON. No code/behavior changes here — docs + manifest only.

## Acceptance Criteria
- [x] `.claude-plugin/plugin.json` `version` is `2.4.0` (valid JSON) and the `README.md` version badge reads `2.4.0`, matching the existing badge format.
- [x] `CHANGELOG.md` has a `2.4.0` section describing FEAT-001 (events.jsonl stream, 10 event types, `migrate_13_to_14` telemetry block, single-write + dual-read, `bus_enabled` kill switch) in the existing entry format.
- [x] `tests/run-tests.sh` is green and `tests/test-json-validation.sh` passes on `plugin.json`.

## Pattern Reference
Study before coding:
- **Version-bump convention** — MEMORY `feedback_version_bump_skills.md` (sync plugin.json + README badge + CHANGELOG on every fix/feature PR).
- **Current version + badge** — `.claude-plugin/plugin.json` line 3 (`"version": "2.3.0"`); `README.md` version badge.
- **CHANGELOG entry format** — `CHANGELOG.md` most-recent entry (the `2.3.0` section) for heading style, bullet structure, and date format.

## File Scope

**Creates**:
- (none)

**Modifies**:
- .claude-plugin/plugin.json (version 2.3.0 → 2.4.0)
- README.md (version badge → 2.4.0)
- CHANGELOG.md (add 2.4.0 / FEAT-001 section)

## Traceability
- **PRD Acceptance Criteria**: "tests/run-tests.sh green; shellcheck + bash -n clean on all modified/new scripts" (release gate); project release-hygiene convention
- **TRD Component**: Rollout Plan (single release at schema v14)
- **ADR Reference**: ADR-006 (single release; v14)

## Commits
- `fa70fa9` — feat(FEAT-001): version-bump hygiene — plugin.json 2.3.0→2.4.0, README badge, CHANGELOG 2.4.0 (TASK-006)
- `5f69c9c` — simplify: CHANGELOG bullet format fix (TASK-006)

## Implementation Log

### Attempt 1
- Bumped `.claude-plugin/plugin.json` `version` from `2.3.0` to `2.4.0` (valid JSON confirmed).
- Updated `README.md` shields.io badge from `2.3.0` to `2.4.0` (same `style=flat-square` format).
- Added `## [2.4.0] - 2026-06-24` section to `CHANGELOG.md` before the 2.3.0 entry, following the same `### Added` / `### Changed` structure. Section documents: events.jsonl stream, 10 event types, 5 producer hooks, review-gate emit wiring, dual-read consumers (metrics/log), migrate_13_to_14 telemetry block, bus_enabled kill switch, atomic append with flock fallback.
- `scripts/gen-skill-docs.sh --check` — no stale skill docs (version bump does not touch skills/ or templates/skill-partials/).
- `tests/run-tests.sh` — 34/34 passed.
- `jq` validated plugin.json — valid JSON, version 2.4.0.

## Review Results

### Attempt 1
- **architect-reviewer**: APPROVED (confidence 99) — Version consistency across all 3 files confirmed. MINOR bump classification correct. CHANGELOG completeness verified against all 5 AC elements. No findings.
- **code-reviewer**: APPROVED (confidence 98) — JSON well-formed, badge URL correct, CHANGELOG entry format consistent with prior entries, factual accuracy confirmed vs. FEAT-001 spec. No blocking findings.
- **security-reviewer**: APPROVED (confidence 97) — Pure metadata change, no secrets/credentials disclosed, shields.io is standard trusted service. INFO-only findings (confidence 15-30, all non-blocking).
- **qa-reviewer**: APPROVED (confidence 97) — All 4 acceptance criteria pass. All 3 version strings synchronized. CHANGELOG covers all required FEAT-001 elements. 34/34 tests green.
- **Merge**: `0a0c723` into `feat/FEAT-001-loop-telemetry-bus` (--no-ff)
