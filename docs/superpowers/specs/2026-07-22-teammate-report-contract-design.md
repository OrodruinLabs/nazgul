# Teammate Report Contract + TeammateIdle Guard — Design

**Date:** 2026-07-22
**Status:** Approved design, pre-implementation
**Release:** MINOR — v2.16.0 → v2.17.0, config schema v26 → v27

## Problem

In Agent Teams / teammate mode, a teammate's final plain-text output is never
delivered to the team lead — `SendMessage` is the only channel (verified against
current Claude Code docs). Nazgul's dispatch prompts say "return a report",
which some agents interpret as "message it back" and others as "emit final
text" — the latter goes nowhere. The lead receives only a content-free idle
notification and must manually nudge each teammate, costing one round-trip per
agent. Observed live during FEAT-012 post-loop (docs, release-manager,
doc-verifier all idled without reporting) and reproduced twice during this
design's own research phase.

Root cause: **no mechanical contract for how a dispatched teammate's report
reaches its parent.** `agents/team-orchestrator.md` says only "signal
completion to the caller"; nothing detects a teammate that stopped without
delivering.

## Verified platform facts (2026-07)

- Teammate final text is NOT auto-delivered; subagents via the Agent tool DO
  auto-deliver final text as the tool result. Only team mode has this gap.
- A `TeammateIdle` hook event exists: fires when a teammate is about to go
  idle and CAN block (exit 2) with feedback to keep the teammate working.
  Not currently wired in `hooks/hooks.json`. Payload schema is NOT fully
  documented — observed live fields: `type`, `from`, `timestamp`,
  `idleReason`, and (after a send) `summary` echoing the last message.
- A Stop hook inside the teammate cannot reliably detect "no SendMessage was
  made" — hook payloads carry no tool-call log.
- Nazgul's loop is entirely file-state-driven: the only "report delivered"
  primitive its gates can check is a file write observed by a later hook tick.
  Proven template: post-loop marker gates (feat_id sentinel + ≤3-attempt
  backstop, deadlock-safe).

## Design

Three layers, each backstopping the one above. Completion signal inverts:
**idle notification + report file on disk = done.** The lead reads the file
when the idle ping arrives. `SendMessage` becomes an optional courtesy, never
load-bearing.

### Layer 1 — Prompt contract (first line of defense)

New partial `templates/skill-partials/report-contract.md`, appended to every
Nazgul teammate dispatch prompt:

> Your final plain text is NOT delivered to anyone. Your LAST action MUST be
> writing your complete report to `<REPORT_PATH>`. Do not idle before that
> file exists.

The dispatcher substitutes `<REPORT_PATH>`.

### Layer 2 — Dispatch manifest (evidence registry)

Before each spawn, the dispatcher (team-orchestrator, or main when the
stop-hook's parallel-batch `DISPATCH_INSTR` fires) writes
`nazgul/dispatch/<teammate-name>.json`:

```json
{
  "teammate": "nazgul-security-reviewer-TASK-003",
  "report_path": "nazgul/reviews/TASK-003/security-reviewer.md",
  "feat_id": "FEAT-013",
  "spawned_at": "<iso8601>",
  "blocks": 0
}
```

Where a deliverable already has a canonical home (review file, task manifest),
`report_path` points there — no duplicate report files.

### Layer 3 — TeammateIdle guard (mechanical enforcement)

New `scripts/teammate-idle-guard.sh`, wired in `hooks/hooks.json` under
`TeammateIdle`:

1. Append full payload to `nazgul/logs/teammate-idle.jsonl` (telemetry +
   ongoing schema discovery).
2. Resolve teammate name from payload. No name, or no
   `nazgul/dispatch/<name>.json` → **allow** (not a Nazgul-dispatched
   teammate).
3. Manifest `feat_id` ≠ current objective → **allow** (stale manifest).
4. Report file exists, non-empty, mtime ≥ `spawned_at` → **allow**; mark
   manifest `"delivered": true`.
5. Missing and `blocks < 3` → increment `blocks`, **block** (exit 2) with
   reason: "Your report at `<path>` was not written — your final text is
   invisible to the parent. Write the full report to `<path>` now, then idle."
6. `blocks >= 3` → **allow** + escalation line in the log (deadlock-safe
   backstop; same ≤3 pattern as the post-loop marker gates).

Kill-switch: `execution.enforce.teammate_report_guard` (default `true`),
no-op when absent — same shape as `dispatch_guard` / `rework_guard`.
Config schema v26 → v27 via `scripts/migrate-config.sh`.

### Spec/doc changes

- **`agents/team-orchestrator.md` rewrite:** replace "signal completion to the
  caller" / "monitor the shared task list" with the explicit lifecycle: write
  dispatch manifests → spawn with report-contract partial → treat idle + file
  as completion → read reports from disk → clean up `nazgul/dispatch/*` at
  team teardown.
- **`scripts/stop-hook.sh` parallel-batch `DISPATCH_INSTR`:** add the same
  contract lines for the implementer/review-gate agents it instructs main to
  spawn (harmless for foreground subagents, load-bearing when run as
  teammates).
- **RULES.md:** new section "Teammate Report Contract" documenting the three
  layers; fix stale §3.9 claim ("no PreToolUse matcher for the Task tool" —
  disproven: the `Agent` matcher exists and is in production use by
  `parallel-dispatch-guard.sh`).

## Data flow

```
dispatcher writes nazgul/dispatch/<name>.json
  → spawns teammate (prompt includes report contract + path)
    → teammate works, writes report file as LAST action
      → teammate idles → TeammateIdle hook fires
        → guard: file present? ──yes→ allow; manifest marked delivered
        │                       └─no→ block ≤3× with fix instruction
        → lead receives idle ping → reads report file → cleanup
```

## Error handling

| Condition | Behavior | Rationale |
|---|---|---|
| Unparseable / unexpected payload | allow + log | Payload schema unverified; blocking on garbage strands teammates. Fails OPEN (deliberate inversion of the PreToolUse guards' fail-closed rule). Prompt contract + manual-nudge fallback remain. |
| Guard disabled / `TeammateIdle` unsupported on older CLI | today's behavior + better prompts | Pure degradation, no regression. |
| Teammate crashes (API-error death) | no idle event; lead's existing "failed" notification path untouched | Out of scope. |
| Stale manifests from a crashed run | teardown deletes `nazgul/dispatch/*`; guard ignores mismatched `feat_id` | Prevents false blocks in later objectives. |

## Testing

`tests/test-teammate-idle-guard.sh` (new), following the existing guard-test
harness pattern:

- report present → allow, manifest marked delivered
- report missing → block, `blocks` incremented, reason names the path
- third consecutive block → allow + escalation logged
- malformed payload → allow
- kill-switch off → no-op
- foreign teammate (no manifest) → allow
- stale `feat_id` → allow
- fixture payloads matching the observed live idle-notification shape
  (including the `summary` field)

Plus: `hooks.json` wiring validated by the existing hook-config test;
`migrate-config.sh` v26 migration test.

## Out of scope

- Changing reviewer persistence (RULES.md §3.3 parent-persists model stays).
- The foreground Agent-tool subagent path (already auto-delivers final text).
- Linear/Slack connector notification surfaces.
