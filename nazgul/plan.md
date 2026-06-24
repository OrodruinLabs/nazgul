# Plan: FEAT-001 — Loop Telemetry Bus

## Objective
Add a Loop Telemetry Bus: a single canonical, schema-versioned append-only event
stream at `nazgul/logs/events.jsonl`, emitted by the existing hook scripts and the
review-gate agent. Consolidates the four scattered telemetry stores (iteration
journal, subagent log, in-place budget estimate, compaction dotfile) and makes
reviewer verdicts / retries / blocks first-class events. Migration is
**single-write + dual-read** (re-planned 2026-06-24, simpler than the original
dual-write→cutover): producers REPLACE their legacy `iterations.jsonl` /
`subagents.jsonl` writes with `emit_event` (write the new stream only; old files
freeze in place, not deleted); consumers DUAL-READ (prefer `events.jsonl`, fall
back to frozen legacy files for pre-upgrade history). ONE migration
`migrate_13_to_14` adds a `telemetry` block (`bus_enabled`, `record_metered_cost`).
No `legacy_write` field, no `migrate_14_to_15`, no v15 cutover.

**Authoritative design**: `docs/superpowers/specs/2026-06-24-telemetry-bus-design.md`
(architect-reviewer APPROVE @ confidence 88). Task decomposition follows design
Section 8 (A → B/D → E, with C parallel to A), plus a version-bump hygiene task (F)
per project convention.

## Status Summary
| Task | Title | Depends on | Wave | Status |
|------|-------|-----------|------|--------|
| TASK-001 | Emit library + CLI wrapper + unit tests | none | 1 | DONE |
| TASK-002 | Config schema v13→v14 migration + telemetry block + gitignore | none | 1 | READY |
| TASK-003 | Shell hook wiring — replace legacy writes with emit_event (5 hooks) | TASK-001 | 2 | READY |
| TASK-004 | Review-gate agent emit wiring (reviewer_verdict / retry / blocked) | TASK-001 | 2 | READY |
| TASK-005 | Consumer migration — metrics + log skills dual-read | TASK-003, TASK-004 | 3 | PLANNED |
| TASK-006 | Version-bump hygiene (plugin.json 2.3.0→2.4.0 + README + CHANGELOG) | TASK-002, TASK-003, TASK-004, TASK-005 | 4 | PLANNED |

## Parallel Groups

### Group 1 (no dependencies — start in parallel)
- **TASK-001** — `scripts/lib/emit-event.sh`, `scripts/emit-event-cli.sh`, `tests/test-emit-event.sh` (pure new code)
- **TASK-002** — `scripts/migrate-config.sh`, `templates/config.json`, `tests/test-migrate-config.sh`, `tests/test-config-schema.sh`, `.gitignore`

No file overlap between TASK-001 and TASK-002.

### Group 2 (after TASK-001 — both depend on it, no file overlap with each other)
- **TASK-003** — `scripts/stop-hook.sh`, `scripts/task-completed.sh`, `scripts/subagent-stop.sh`, `scripts/stop-failure.sh`, `scripts/post-compact.sh`, `tests/test-observability-hooks.sh`
- **TASK-004** — `agents/review-gate.md`

### Group 3 (after Group 2 — needs the stream populated by hooks + agent)
- **TASK-005** — `skills/metrics/SKILL.md`, `skills/log/SKILL.md`

### Group 4 (after everything — release hygiene)
- **TASK-006** — `.claude-plugin/plugin.json`, `README.md`, `CHANGELOG.md`

## Wave Groups

### Wave 1
- TASK-001, TASK-002 (independent, no file overlap — pure new code + config schema/migration)

### Wave 2
- TASK-003 (depends on TASK-001; modifies 5 hook scripts + observability test)
- TASK-004 (depends on TASK-001; modifies agents/review-gate.md — no file overlap with TASK-003)

### Wave 3
- TASK-005 (depends on TASK-003 and TASK-004; modifies the two consumer skills)

### Wave 4
- TASK-006 (depends on all prior; version-bump hygiene — docs/manifest only)

## PRD Traceability Coverage
Every PRD acceptance criterion maps to at least one task:
- Emit lib (source-only) + CLI wrapper → TASK-001
- Unset `NAZGUL_DIR` → no-op → TASK-001
- `:n` numeric / `--arg` string / `ts` ISO-8601 / `iteration` int|null → TASK-001
- 3 concurrent emitters atomic, no interleave (macOS flock fallback) → TASK-001
- `bus_enabled:false` suppresses emits → TASK-001 (guard) + TASK-003 (hook no-op test)
- `migrate_13_to_14` additive, no `legacy_write` + template v14 → TASK-002
- `nazgul/logs/` gitignored → TASK-002
- iteration_boundary emitted; legacy `iterations.jsonl` no longer appended → TASK-003
- 5 hooks each emit exactly their event; legacy writes removed → TASK-003
- review-gate emits reviewer_verdict / retry / blocked (CONCERN 1) → TASK-004
- metrics/log prefer events.jsonl with permanent legacy dual-read fallback → TASK-005
- `tests/run-tests.sh` green + shellcheck/bash -n clean → all tasks (tests mandatory per task)
- release hygiene (version bump + CHANGELOG) → TASK-006

## Completed
- TASK-001 ✦ DONE @ 6b0c7f7 (2026-06-24) — emit library + CLI wrapper + 20 tests; 4 reviewer board APPROVE

## Recovery Pointer
- **Active task**: none (TASK-001 DONE @ 6b0c7f7)
- **Next action**: TASK-002 (READY, independent) and TASK-003+TASK-004 (both now READY — TASK-001 done). Wave 1 parallel: run TASK-002 alongside TASK-003/TASK-004 (Wave 2 released).
- **Plan written**: 2026-06-24 (re-plan — replaces the prior dual-write→cutover plan)
- **Last updated**: 2026-06-24T14:00:00Z
