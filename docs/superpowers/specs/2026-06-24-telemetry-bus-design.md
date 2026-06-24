# Loop Telemetry Bus — Design Specification

> Status: APPROVED (architect-reviewer, confidence 88). Slice 1 of the
> "enhance post-loop / hooks" initiative. Migration approach (revised
> 2026-06-24, simpler than the original dual-write): producers switch to a
> single new `events.jsonl` write; **consumers dual-READ** (`events.jsonl`,
> falling back to the frozen legacy files for pre-upgrade history). No parallel
> legacy write is retained, and there is no v15 cutover step — the old files
> simply freeze in place and age out. Rationale: appending one JSON line is the
> lowest-risk write there is; the real risk is consumer parsing, which dual-read
> covers. A redundant legacy writer (dual-write) was dropped as YAGNI; the emit
> library is proven instead by TASK-001's mandated unit + concurrency tests.

## Problem Statement

Telemetry is currently scattered across four independent stores with heterogeneous schemas:

- `nazgul/logs/iterations.jsonl` — written by three independent writers: `stop-hook.sh:668-677` (iteration-boundary lines with no `event` field), `task-completed.sh:18` (`{"event":"task_completed","timestamp":"..."}`), and `stop-failure.sh:25` (`{"event":"stop_failure","timestamp":"..."}`). `skills/log/SKILL.md:29` already acknowledges the mixed shape: "some lines from other writers carry an `event` field … instead."
- `nazgul/logs/subagents.jsonl` — written only by `subagent-stop.sh:31` with its own `{event,agent,timestamp}` shape, siloed from iterations.
- `nazgul/config.json → budget.spent_usd` — a running accumulator mutated in-place at `stop-hook.sh:104-125`; not an event, resets on every `/nazgul:start`, labeled "ESTIMATED" throughout.
- `nazgul/.compaction_count` — a dotfile updated by `post-compact.sh:62-68`; not part of any event stream.
- Reviewer verdicts — reconstructable only by scanning `nazgul/reviews/TASK-*/`; no first-class event exists anywhere in the hook layer.

Consumers (`skills/metrics/SKILL.md:39-84`, `skills/log/SKILL.md:26-34`) must stitch all five sources together with defensive parsing.

---

## Section 1 — Canonical Event Schema and Full Event Taxonomy

### Common Envelope

Every line in `nazgul/logs/events.jsonl` is a self-contained JSON object. No multi-line records, no blank lines.

```
{
  "sv":        <int>      // schema_version integer, starts at 1
  "ts":        <string>   // UTC ISO 8601, e.g. "2026-06-24T14:30:01Z"
  "event":     <string>   // event type enum (see taxonomy)
  "iteration": <int|null> // config.current_iteration at emit time; null for out-of-loop events
  // ...event-specific payload fields
}
```

Rationale: `sv` keeps lines compact; `ts` is always library-stamped (callers never pass it); `iteration` is read from `config.json → current_iteration` at emit time (null for events firing outside loop context). String values are `jq --arg` escaped; numerics use `--argjson`.

### Full Event Taxonomy Enum

| Event | Replaces / Adds | Justification |
|---|---|---|
| `iteration_boundary` | Replaces unlabeled iteration lines from `stop-hook.sh:668-677` | Central timeline spine |
| `task_completed` | Replaces `task-completed.sh:18` line | TaskCompleted hook; distinct from a state transition |
| `reviewer_verdict` | New first-class event | Verdicts only reconstructable from `reviews/` scans today |
| `retry` | New first-class event | Retry counts buried in task manifest grep |
| `blocked` | New first-class event | High-signal for AFK operators |
| `compaction` | Replaces `.compaction_count` dotfile | Already tracked by `post-compact.sh`; folds into the stream |
| `subagent_stop` | Replaces `subagents.jsonl` lines (`subagent-stop.sh:31`) | Direct lift, canonical envelope |
| `stop_failure` | Replaces `stop-failure.sh:25` line | Same payload, no longer mixed into iteration lines |
| `budget_threshold` | New event | Proactive warning before the ceiling stop at `stop-hook.sh:759-765` |
| `objective_complete` | New event | Clean session-summary anchor for loop completion (`stop-hook.sh:697-746`) |

**Cut (YAGNI):** `session_start` (redundant with iteration_boundary), `post_loop_phase` (visible as subagent_stop with agent name), `pre_check_failed` (needs new review-gate wiring — defer to v2), full per-`set_task_status` `task_transition` coverage (not achievable purely in shell — partial hook-visible coverage only).

### Per-Event Payloads

**`iteration_boundary`** (stop-hook, after the `>> iterations.jsonl` write at line 677):
```json
{"sv":1,"ts":"...","event":"iteration_boundary","iteration":5,
 "active_task":"TASK-003","active_status":"IMPLEMENTED",
 "done":3,"total":7,"git_sha":"abc1234","blocked_reason":""}
```

**`task_completed`** (task-completed.sh, alongside line 18):
```json
{"sv":1,"ts":"...","event":"task_completed","iteration":5,"task_id":"unknown"}
```
Note: TaskCompleted hook payload does not expose reliable task identity; `task_id` defaults to `"unknown"` (CONCERN 2).

**`reviewer_verdict`** (review-gate agent, after each reviewer file collected in Step 2):
```json
{"sv":1,"ts":"...","event":"reviewer_verdict","iteration":5,
 "task_id":"TASK-003","reviewer":"architect-reviewer","decision":"APPROVE",
 "confidence":92,"blocking_findings":0,"concerns":1}
```

**`retry`** (review-gate, after retry_count increment in CHANGES_REQUESTED path):
```json
{"sv":1,"ts":"...","event":"retry","iteration":6,
 "task_id":"TASK-003","retry_count":1,"reason":"CHANGES_REQUESTED"}
```

**`blocked`** (stop-hook git-conflict path; review-gate security/max-retry paths):
```json
{"sv":1,"ts":"...","event":"blocked","iteration":6,"task_id":"TASK-003","reason":"git conflict"}
```

**`compaction`** (post-compact.sh, after `.compaction_count` update at line 68):
```json
{"sv":1,"ts":"...","event":"compaction","iteration":8,"compaction_index":2,"iteration_at_compact":8}
```

**`subagent_stop`** (subagent-stop.sh, alongside line 31; `iteration` is null — script does not read config):
```json
{"sv":1,"ts":"...","event":"subagent_stop","iteration":null,"agent":"nazgul:implementer"}
```

**`stop_failure`** (stop-failure.sh, alongside line 25):
```json
{"sv":1,"ts":"...","event":"stop_failure","iteration":null}
```

**`budget_threshold`** (stop-hook, after BUDGET_SPENT update at line 123, on first crossing of 50% / 90%):
```json
{"sv":1,"ts":"...","event":"budget_threshold","iteration":12,"spent_usd":5.40,"max_usd":6.00,"pct":90}
```

**`objective_complete`** (stop-hook, before `exit 0` on IS_COMPLETE path after learning gate, ~line 745):
```json
{"sv":1,"ts":"...","event":"objective_complete","iteration":14,"total_tasks":7,"done_count":7,"iterations_used":14}
```

---

## Section 2 — Emit Library: `scripts/lib/emit-event.sh`

### Interface

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"

# emit_event "event_type" key1 val1 key2 val2 ...
# Numeric values: append :n to the key   ->  count:n 42
# EVENTS_FILE derived from NAZGUL_DIR (overridable for tests).
# CURRENT_ITERATION set by caller, else null.
```

### Implementation

```bash
#!/usr/bin/env bash
# scripts/lib/emit-event.sh — append one canonical event line to events.jsonl
# Sourced by hook scripts; also invoked via scripts/emit-event-cli.sh by agents.
# Never executed directly.

EMIT_SCHEMA_VERSION=1
EVENTS_FILE="${EVENTS_FILE:-${NAZGUL_DIR:-}/logs/events.jsonl}"

emit_event() {
  local event_type="$1"; shift

  # Uninitialised Nazgul -> silent no-op.
  [ -z "${NAZGUL_DIR:-}" ] && return 0
  [ -z "$EVENTS_FILE" ]    && return 0

  local iter="${CURRENT_ITERATION:-null}"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local jq_args=()
  local jq_expr='{sv:($sv|tonumber),ts:$ts,event:$event,iteration:($iter|if .=="null" then null else tonumber end)'
  jq_args+=(--arg sv "$EMIT_SCHEMA_VERSION")
  jq_args+=(--arg ts "$ts")
  jq_args+=(--arg event "$event_type")
  jq_args+=(--arg iter "$iter")

  while [ $# -ge 2 ]; do
    local raw_key="$1" val="$2"; shift 2
    local key="$raw_key" numeric=false
    case "$raw_key" in *:n) key="${raw_key%:n}"; numeric=true ;; esac
    if [ "$numeric" = true ]; then jq_args+=(--argjson "$key" "$val")
    else jq_args+=(--arg "$key" "$val"); fi
    jq_expr="${jq_expr},${key}:\$${key}"
  done
  jq_expr="${jq_expr}}"

  mkdir -p "$(dirname "$EVENTS_FILE")"

  # flock serialises concurrent SubagentStop fires (Agent Teams). Fallback:
  # O_APPEND + a single jq write() is atomic on POSIX for writes < PIPE_BUF;
  # JSONL lines are short. CONCERN 3: macOS base ships without flock -> the
  # fallback path must be exercised by macOS CI.
  local lockfile="${EVENTS_FILE}.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200; jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE" ) 200>"$lockfile"
  else
    jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE"
  fi
}
```

### CLI Wrapper: `scripts/emit-event-cli.sh`

Agents cannot source shell libraries — they invoke scripts via Bash tool calls.

```bash
#!/usr/bin/env bash
set -euo pipefail
# scripts/emit-event-cli.sh — CLI entry point for emit-event.sh used by agents.
# Usage: emit-event-cli.sh <event_type> [key val ...] [key:n numeric_val ...]
#
# Example (review-gate agent Bash tool call):
#   "${CLAUDE_PLUGIN_ROOT}/scripts/emit-event-cli.sh" reviewer_verdict \
#     task_id "$TASK_ID" reviewer "$REVIEWER_NAME" \
#     decision "$DECISION" confidence:n "$CONFIDENCE" \
#     blocking_findings:n "$BLOCKING" concerns:n "$CONCERNS"
#
# NAZGUL_DIR and CURRENT_ITERATION must be set in the environment or the emit
# silently no-ops (uninitialised guard in emit-event.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"
emit_event "$@"
```

Argument convention: positional `event_type` first, then alternating `key val` pairs (`:n` suffix = numeric). Mirrors how `scripts/lib/learned-rules.sh` is called from agents.

**CONCERN 1 (CLI arg convention):** The convention must be documented verbatim in `agents/review-gate.md` Step 2 where the emit calls are added, or the agent will construct the Bash call incorrectly. The header-comment example above is the mitigation.

---

## Section 3 — Per-Hook Wiring Map

### `scripts/stop-hook.sh`
Source the lib after existing `source` lines. Emits:
- **`iteration_boundary`** — **replaces** the `>> iterations.jsonl` write block (lines 666-677) with an `emit_event` call, `CURRENT_ITERATION="$NEW_ITER"` (already computed at line 101). The legacy `iterations.jsonl` is no longer written going forward (the existing file freezes; consumers dual-read it for old history).
- **`task_transition`** (review-gate-bypass reset paths) — DONE→IMPLEMENTED reset (~line 193), DONE→BLOCKED escalation (~line 177).
- **`blocked`** — git-conflict path, after `ACTIVE_BLOCKED_REASON="git conflict"` (lines 651-663).
- **`budget_threshold`** — after BUDGET_SPENT finalized (line 123), guarded by `BUDGET_ENABLED=true` and positive `BUDGET_MAX`; dedup via `_budget_threshold_N_emitted` flag in config (reset by `/nazgul:start`).
- **`objective_complete`** — before `exit 0` on IS_COMPLETE path after learning gate (~line 745).

### `scripts/task-completed.sh`
Add `INPUT=$(cat 2>/dev/null || true)` read (pattern from `subagent-stop.sh:12-13`), source lib, emit **`task_completed`** **replacing** the `>> iterations.jsonl` write at line 18. Best-effort `task_id` from stdin (`.task_id // .taskId // "unknown"`).
**CONCERN 2:** payload lacks reliable task identity (same wall as subagent-stop). `task_id: "unknown"` in the common case; consumers must not depend on it in v1.

### `scripts/subagent-stop.sh`
Add `SCRIPT_DIR`, source lib, emit **`subagent_stop`** **replacing** the `>> subagents.jsonl` write at line 31. `CURRENT_ITERATION="null"` (script intentionally does not read config).

### `scripts/stop-failure.sh`
Add `SCRIPT_DIR`, source lib, emit **`stop_failure`** **replacing** the `>> iterations.jsonl` write at line 25. `CURRENT_ITERATION="null"`.

### `scripts/post-compact.sh`
Source lib (`SCRIPT_DIR` already set at line 12), emit **`compaction`** after the counter write at line 68. `CURRENT_ITERATION="$ITERATION"`.

### `agents/review-gate.md`
Bash-tool calls to `emit-event-cli.sh` — the only events with no natural shell hook point:
- **`reviewer_verdict`** after Step 2 (each reviewer collected).
- **`retry`** after Step 4 CHANGES_REQUESTED increment.
- **`blocked`** on security-rejection / max-retries BLOCKED.
Each call sets `NAZGUL_DIR="${CLAUDE_PROJECT_DIR}/nazgul"` and reads `CURRENT_ITERATION` from config first.

### Events with no emit point in v1
READY→IN_PROGRESS (implementer-set) → defer to v2; IMPLEMENTED→IN_REVIEW and IN_REVIEW→DONE → bounded by `reviewer_verdict` + next `iteration_boundary`.

---

## Section 4 — Real vs Estimated Cost

`stop-hook.sh` reads no stdin (all state from `$CONFIG` + filesystem). `subagent-stop.sh:12-13` reads stdin but extracts only the agent name. `stop-failure.sh:12` drains stdin to `/dev/null`. **No script records actual token usage.**

**Finding:** Whether the Stop/SubagentStop payload exposes token counts is an **open question** unresolvable from the repo — needs live-runtime testing. `budget.spent_usd` is explicitly an estimate (`stop-hook.sh:104`, `skills/metrics/SKILL.md:62`).

**Recommendation:** No metered cost in v1. Add a dormant `telemetry.record_metered_cost: false` flag in the v14 schema. If a later investigation confirms tokens in the payload, add a `budget_actual` event additively (stop-hook would need an `INPUT=$(cat …)` read it currently lacks).

---

## Section 5 — Consumer Migration

### `skills/metrics/SKILL.md`
Sources 2 (iterations.jsonl), 4 (config budget), 5 (subagents.jsonl) collapse into `events.jsonl`:
```
Iteration count:  jq -sc '[.[]|select(.event=="iteration_boundary")]|length'
Compaction count: jq -sc '[.[]|select(.event=="compaction")]|length'
Subagent counts:  jq -sc '[.[]|select(.event=="subagent_stop")]|group_by(.agent)|map({agent:.[0].agent,count:length})'
Reviewer stats:   jq -sc '[.[]|select(.event=="reviewer_verdict")]|group_by(.reviewer)|map({reviewer:.[0].reviewer,approved:(map(select(.decision=="APPROVE"))|length),rejected:(map(select(.decision=="CHANGES_REQUESTED"))|length)})'
```
Budget spend: add `budget_spent_usd` to the `iteration_boundary` payload for a per-iteration history; latest value is the cumulative estimate. Reviewer full-finding breakdowns still read `reviews/` files in v1 (events supplement, not fully replace).

**Dual-read:** prefer `events.jsonl` when present and non-empty; else legacy grep/wc fallback.

### `skills/log/SKILL.md`
Replace source 1 with `events.jsonl`. Unified timeline: `jq -sc 'sort_by(.ts)|.[]'`. The defensive multi-shape parsing at line 29 disappears. Dual-read flag `TIMELINE_SOURCE=events|legacy`. Document the v1 gaps: `task_completed` has no reliable `task_id`; most state transitions are not captured as `task_transition` events.

---

## Section 6 — Migration Plan (single-write + dual-read)

**One release (schema v14).** The emit lib + CLI are added; each wired hook **replaces** its legacy `>> iterations.jsonl` / `>> subagents.jsonl` write with an `emit_event` call (producers write only `events.jsonl` from the upgrade forward). Consumers gain **dual-read** (prefer `events.jsonl`, fall back to the frozen legacy files for pre-upgrade history). `migrate_13_to_14` adds:
```json
"telemetry": { "bus_enabled": true, "record_metered_cost": false }
```

There is **no `legacy_write` flag and no v15 cutover** — the design was simplified (2026-06-24) away from the original dual-write plan. Rationale: appending one JSON line is the lowest-risk write there is, so running a redundant legacy writer in parallel (and the two-release cutover dance it required) was YAGNI. The legacy files are not deleted — they freeze in place, remain readable via dual-read, and age out naturally. The emit path's correctness is assured by TASK-001's unit + 3-concurrent-emitter tests, not by a parallel backstop writer.

**Why dual-READ is still needed (but dual-WRITE is not):** dual-read is what preserves history — a project upgraded mid-objective keeps its pre-upgrade `iterations.jsonl`/`subagents.jsonl` data readable. Dual-write would only have added a write-side rollback net for unproven emit code; for a trivial append that net isn't worth a forever-forked write path.

**Opt-out:** `telemetry.bus_enabled: false` makes every emit a no-op. Because legacy writes are removed (not gated), opting out means that telemetry simply isn't recorded for that run — there is no parallel legacy stream to fall back on. This is an explicit, documented trade-off of the simplification (vs. the dropped dual-write design, where opting out left legacy writes intact).

**Init / migration trigger:** the template ships at v14 with the telemetry block, so new `/nazgul:init` projects start on the bus. Existing projects pick up `migrate_13_to_14` via `session-context.sh:36` on next session start. The version bump is the only signal; no manual step.

---

## Section 7 — Backward Compat, Init, Log Rotation

- **`/nazgul:init`:** template at v14 → new projects start on the bus. `nazgul/logs/` created on demand (`mkdir -p` in the emit lib).
- **In-flight projects:** on next session start, `migrate_13_to_14` adds the telemetry block; from the first Stop onward, hooks write `events.jsonl` only; the existing `iterations.jsonl`/`subagents.jsonl` freeze with their accumulated history intact; `events.jsonl` accumulates forward (no backfill); dual-read in the consumers stitches the frozen legacy history together with the new stream.
- **Log rotation:** append-only, unpruned. ~40 KB for a 40-iteration run; single-digit MB over months. `objective_complete` segments runs; consumers computing per-run metrics filter by `ts >= objective_set_at` or events after the most recent `objective_complete`. A `telemetry.max_event_lines` rotation field is future scope — mark the hook point in the lib.

---

## Section 8 — File-Change Inventory

| File | Action | Purpose |
|---|---|---|
| `scripts/lib/emit-event.sh` | CREATE | Core emit library |
| `scripts/emit-event-cli.sh` | CREATE | CLI wrapper for agent Bash calls |
| `scripts/stop-hook.sh` | MODIFY | Emit iteration_boundary, task_transition, blocked, budget_threshold, objective_complete; replace the legacy iterations.jsonl write |
| `scripts/task-completed.sh` | MODIFY | Add stdin read; emit task_completed (replaces legacy iterations.jsonl write) |
| `scripts/subagent-stop.sh` | MODIFY | Add SCRIPT_DIR; emit subagent_stop (replaces legacy subagents.jsonl write) |
| `scripts/stop-failure.sh` | MODIFY | Add SCRIPT_DIR; emit stop_failure (replaces legacy iterations.jsonl write) |
| `scripts/post-compact.sh` | MODIFY | Emit compaction after counter write |
| `agents/review-gate.md` | MODIFY | Bash calls for reviewer_verdict, retry, blocked |
| `scripts/migrate-config.sh` | MODIFY | Add migrate_13_to_14 (telemetry block: bus_enabled + record_metered_cost) |
| `templates/config.json` | MODIFY | schema_version → 14; add telemetry block |
| `skills/metrics/SKILL.md` | MODIFY | Prefer events.jsonl; dual-read legacy fallback; note task_id gap |
| `skills/log/SKILL.md` | MODIFY | Prefer events.jsonl; dual-read legacy fallback; document timeline gaps |
| `tests/test-emit-event.sh` | CREATE | Unit tests for emit lib |
| `tests/test-observability-hooks.sh` | MODIFY | Assert each hook emits a correct line to events.jsonl (and no longer writes the legacy file) |
| `tests/test-migrate-config.sh` | MODIFY | Test migrate_13_to_14 (additive telemetry block, no legacy_write field) |
| `tests/test-config-schema.sh` | MODIFY | Assert telemetry fields at v14 (bus_enabled, record_metered_cost) |

### Planner Task Decomposition
- **TASK-A** — emit lib + CLI + test-emit-event.sh (pure new code).
- **TASK-B** — shell hook wiring (5 scripts) + test-observability-hooks.sh (depends on A).
- **TASK-C** — config schema + migration (parallel to A).
- **TASK-D** — agent wiring (review-gate.md) (depends on A).
- **TASK-E** — consumer migration (metrics + log skills) (depends on B, D).

Order: A → (B ‖ D) → E, with C parallel to A.

---

## Section 9 — Risks, Edge Cases, Test Strategy

- **Concurrency:** Agent Teams fire SubagentStop concurrently; `flock -x` + `.lock` sidecar serialises. **CONCERN 3:** `flock` absent from macOS base — fallback relies on O_APPEND atomicity (<512 B lines safe). macOS CI must run the concurrency test.
- **Partial writes:** SIGKILL mid-write can leave a partial last line. All consumers use tolerant parsing: `jq -sc '[.[]|select(.event!=null)]' "$EVENTS" 2>/dev/null || true`.
- **Schema evolution:** `sv` per line; v1 rule = additive changes only (new optional fields no bump; remove/rename → bump to 2). Matches `migrate-config.sh` additive philosophy.
- **AFK commit noise:** `nazgul/logs/` must be gitignored (same policy as transient review artifacts). Verify before shipping.
- **Budget dedup:** `_budget_threshold_N_emitted` flags reset in the same `/nazgul:start` jq that zeroes `spent_usd` (`del(._budget_threshold_50_emitted)|del(._budget_threshold_90_emitted)`).

### Tests
- **`tests/test-emit-event.sh` (new):** valid JSON line w/ envelope; `:n` → numeric value; ISO-8601 `ts`; null vs integer iteration; `mkdir -p` create; unset NAZGUL_DIR → no-op; 3 concurrent emitters → 3 valid lines no interleave; line parses with `jq .`.
- **`tests/test-observability-hooks.sh` (extend):** each hook emits exactly one correctly-typed line to `events.jsonl`; the legacy `iterations.jsonl`/`subagents.jsonl` writes are gone (hook no longer appends to them); `bus_enabled:false` makes the emit a no-op (nothing written).
- **`tests/test-migrate-config.sh` (extend):** migrate_13_to_14 adds fields, preserves existing, removes nothing.
- **`tests/test-config-schema.sh` (extend):** template at v14 with telemetry fields.
