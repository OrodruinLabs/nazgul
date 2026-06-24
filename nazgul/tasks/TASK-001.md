---
status: DONE
---
# TASK-001: Emit library + CLI wrapper + unit tests

## Metadata
- **ID**: TASK-001
- **Group**: 1
- **Status**: (see `status:` in the frontmatter block at the top — that is canonical, read by scripts/lib/structured-state.sh; not duplicated here to avoid drift)
- **Depends on**: none
- **Delegates to**: none
- **Files modified**: [scripts/lib/emit-event.sh, scripts/emit-event-cli.sh, tests/test-emit-event.sh, tests/test-shellcheck.sh]
- **Wave**: 1
- **Traces to**: PRD AC ("bus_enabled:false no-op", "Uninitialised NAZGUL_DIR no-op", "3 concurrent emitters → 3 valid non-interleaved lines"); TRD Component "emit library (scripts/lib/emit-event.sh)" + "CLI wrapper (scripts/emit-event-cli.sh)"; Design Section 2; ADR-006
- **Created at**: 2026-06-24T12:40:00Z
- **Claimed at**: 2026-06-24T13:00:00Z
- **Base SHA**: 9fb745800ee5fb04218bba5874e13e110c1f5df9
- **Implemented at**: 2026-06-24T13:15:00Z
- **Completed at**: 2026-06-24T14:00:00Z
- **Blocked at**:
- **Retry count**: 0/3
- **Test failures**: 0
- **Completion SHA**: 6b0c7f7

## Description
Create the canonical emit library and its CLI wrapper — pure new code, no edits to
existing files. `scripts/lib/emit-event.sh` is sourced by hooks; it defines
`emit_event "<event_type>" key val key val …` which builds one canonical JSON
envelope `{sv, ts, event, iteration, …payload}` and atomically appends it to
`nazgul/logs/events.jsonl`. `scripts/emit-event-cli.sh` is a thin executable
wrapper that sources the lib and forwards `"$@"` so agents (which cannot source
shell libraries) can emit via a Bash tool call.

Implement EXACTLY the interface and body in design Section 2 (lines 123-215):
- `EMIT_SCHEMA_VERSION=1`; `EVENTS_FILE="${EVENTS_FILE:-${NAZGUL_DIR:-}/logs/events.jsonl}"` (overridable for tests).
- Silent no-op (`return 0`) when `NAZGUL_DIR` or `EVENTS_FILE` is unset/empty — uninitialised guard.
- Honor `telemetry.bus_enabled`: when it resolves to `false` the emit is a no-op (nothing written). Read it from `${NAZGUL_DIR}/config.json` via `jq`; treat unset/missing as enabled (template ships `true`).
- `iter` from `CURRENT_ITERATION` (else the literal `null`); `ts` always library-stamped via `date -u +"%Y-%m-%dT%H:%M:%SZ"` (callers never pass `ts`).
- Key→value pairs: a `:n` suffix on the key marks a numeric value (`--argjson`); plain keys are strings (`--arg`). Build the jq expression incrementally as shown.
- `mkdir -p "$(dirname "$EVENTS_FILE")"` to create `nazgul/logs/` on demand.
- Concurrency: `flock -x` on a `${EVENTS_FILE}.lock` sidecar when `flock` is present; O_APPEND single-`jq`-`write()` fallback when absent (macOS base lacks `flock`).

`emit-event.sh` is never executed directly (no `set -euo pipefail` shebang-exec
needed — it is sourced); `emit-event-cli.sh` IS executed and MUST carry
`#!/usr/bin/env bash` + `set -euo pipefail`. Both must pass `bash -n` + shellcheck.

## Acceptance Criteria
- [x] `scripts/lib/emit-event.sh` defines `emit_event` per Design Section 2: builds the `{sv,ts,event,iteration,…}` envelope (`:n`→`--argjson` numeric, plain→`--arg` string, `ts` library-stamped ISO-8601, `iteration` int when `CURRENT_ITERATION` set else JSON `null`), `mkdir -p`s the logs dir, and no-ops silently when `NAZGUL_DIR` is unset/empty or `telemetry.bus_enabled` is `false`.
- [x] `scripts/emit-event-cli.sh` (executable, `set -euo pipefail`) sources the lib via the `SCRIPT_DIR` pattern and forwards `"$@"`; header carries the verbatim worked `reviewer_verdict` example from Design lines 199-207 (CONCERN 1 mitigation).
- [x] `tests/test-emit-event.sh` passes under `tests/run-tests.sh` covering: valid one-line JSON (parses with `jq .`); `:n` numeric vs string; ISO-8601 `ts`; int vs `null` iteration; `mkdir -p` create; unset-`NAZGUL_DIR` no-op; `bus_enabled:false` no-op; **3 concurrent emitters → exactly 3 valid non-interleaved lines** (flock-absent fallback path). `bash -n` + shellcheck clean on both new scripts.

## Pattern Reference
Study before coding:
- **Verbatim implementation** — `docs/superpowers/specs/2026-06-24-telemetry-bus-design.md` Section 2 (lines 123-215): full `emit_event` body, CLI wrapper, arg convention.
- **`scripts/lib/` sourced-helper convention** — `scripts/lib/task-utils.sh`, `scripts/lib/learned-rules.sh` (sourced libs; `learned-rules.sh` also shows the agent-callable arg convention this mirrors).
- **`SCRIPT_DIR` source pattern** — `nazgul/context/style-conventions.md` (`SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; source "$SCRIPT_DIR/lib/…"`).
- **Test harness conventions** — `tests/lib/assertions.sh` (`_pass`/`_fail`), and any existing `tests/test-*.sh` (e.g. `tests/test-task-utils.sh`) for temp-dir fixture + `EVENTS_FILE`/`NAZGUL_DIR` override style.

## File Scope

**Creates**:
- scripts/lib/emit-event.sh
- scripts/emit-event-cli.sh
- tests/test-emit-event.sh

**Modifies**:
- tests/test-shellcheck.sh (added to SCRIPTS array — review fix)

## Traceability
- **PRD Acceptance Criteria**: "bus_enabled:false → emit is a no-op"; "Uninitialised NAZGUL_DIR → emit silently no-ops"; "3 concurrent emitters → exactly 3 valid, non-interleaved JSONL lines (macOS, flock-absent fallback)"
- **TRD Component**: emit library (`scripts/lib/emit-event.sh`) + CLI wrapper (`scripts/emit-event-cli.sh`)
- **ADR Reference**: ADR-006 (events.jsonl stream; single-write + dual-read)

## Implementation Log

### Attempt 1

Created all three files per design Section 2:

**`scripts/lib/emit-event.sh`**
- Source-only library (no shebang-exec guard needed)
- `EMIT_SCHEMA_VERSION=1`; `EVENTS_FILE` derived from `NAZGUL_DIR` (overridable for tests)
- Uninitialised guard: `[ -z "${NAZGUL_DIR:-}" ] && return 0`
- `bus_enabled` check via explicit jq null-check (avoided jq `//` operator which treats `false` as falsy)
- `iter`/`ts` library-stamped; `:n` suffix → `--argjson`; plain key → `--arg`
- `mkdir -p "$(dirname "$EVENTS_FILE")"` before write
- flock path for Linux; O_APPEND fallback for macOS (flock absent)
- `# shellcheck disable=SC2016` on jq_expr (intentional single-quoted jq body)

**`scripts/emit-event-cli.sh`**
- Executable with `#!/usr/bin/env bash` + `set -euo pipefail`
- Verbatim `reviewer_verdict` usage example in header (CONCERN 1 mitigation)
- `SCRIPT_DIR` pattern; `# shellcheck disable=SC1091` on dynamic source

**`tests/test-emit-event.sh`**
- 20 tests covering all acceptance criteria
- Fixed jq `//` false-as-falsy bug during implementation
- All 20/20 PASS; `bash -n` + `shellcheck -S warning` clean on both scripts

**Key fix during implementation**: jq's `//` (alternative) operator returns the fallback for BOTH null AND false values. The `bus_enabled` check was changed to use an explicit null comparison: `if .telemetry.bus_enabled == null then "true" else (.telemetry.bus_enabled | tostring) end`

## Commits
- c83a183 feat(FEAT-001): add emit library, CLI wrapper, and unit tests (TASK-001)
- c2b9fc0 feat(FEAT-001): simplify TASK-001 (4 simplifier fixes, all tests green)
- 6b0c7f7 feat(FEAT-001): review fixes for TASK-001 — shellcheck registration, comment hygiene, dir-guard path-key

## Review Results

### Attempt 1

| Reviewer | Verdict | Confidence | Blocking | Concerns |
|---|---|---|---|---|
| architect-reviewer | ✦ APPROVE | 82 | 0 | 2 |
| code-reviewer | CHANGES_REQUESTED | 85 | 3 | 3 |
| security-reviewer | ✦ APPROVE | 88 | 0 | 4 |
| qa-reviewer | CHANGES_REQUESTED | 90 | 1* | 2 |

*QA finding 2 (config migration) excluded as out of scope (TASK-002).

**AUTO-FIX applied (3)**: shellcheck registration in test-shellcheck.sh; removed speculative CONCERN 3 CI-action comment; removed TODO(telemetry.max_event_lines) stub.

**ASK applied (YOLO mode, 2)**: _EMIT_DIR_READY guard keyed on EVENTS_FILE path (option b); key trust-boundary comment added.

**Final outcome**: ✦ DONE — all fixes applied, 20/20 tests green, shellcheck clean, completion SHA 6b0c7f7.
