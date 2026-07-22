---
name: nazgul:heartbeat
description: Run one Nazgul automation-heartbeat tick — triages the work inbox and auto-starts the next objective if idle. Opt-in and default-off; fired by an optional Claude Code native scheduled agent (routine) or run by hand. Use when asked to "run a heartbeat tick", "check the inbox", or to test/debug the heartbeat.
context: fork
allowed-tools: Read, Bash
metadata:
  author: Jose Mejia
---

# Nazgul Heartbeat

## Examples
- `/nazgul:heartbeat` — Run one heartbeat tick by hand (identical to a scheduled routine firing)

## Current State
- Heartbeat enabled: !`jq -r '.automation.heartbeat.enabled // false' nazgul/config.json 2>/dev/null || echo "false"`
- Inbox dir: !`jq -r '.automation.heartbeat.inbox.dir // "nazgul/inbox"' nazgul/config.json 2>/dev/null || echo "nazgul/inbox"`
- Inbox candidates: !`ls -1 nazgul/inbox/*.md nazgul/inbox/*.json 2>/dev/null | wc -l | tr -d ' '`
- Latest heartbeat log: !`ls -1t nazgul/logs/heartbeat-*.jsonl 2>/dev/null | head -1 || echo "none yet"`

## Instructions

Run exactly one heartbeat tick and report the outcome. This skill is trigger-agnostic: run it by
hand for testing, or configure a Claude Code native scheduled agent (routine) to fire it on an
interval (see below).

### Step 1: Check Initialization

If `nazgul/config.json` does not exist:
- Output: "Nazgul not initialized. Run `/nazgul:init` first."
- Stop here.

### Step 2: Run One Tick

Invoke the tick engine directly — it is the entire implementation; this skill only wraps it:

```bash
bash scripts/heartbeat.sh
```

`scripts/heartbeat.sh` is self-contained and trigger-agnostic: it gates on
`automation.heartbeat.enabled`, enforces the two unconditional hard stops (BLOCKED task, security
rejection) regardless of that flag, triages the inbox, and — only when idle and clear — archives the
picked candidate and auto-starts it. It always exits 0 and appends one decision record to
`nazgul/logs/heartbeat-<date>.jsonl`.

### Step 3: Report the Tick

Read the last line of the latest `nazgul/logs/heartbeat-<date>.jsonl` (`tail -1`) and report the
`decision` field with its context:

| `decision` | Report |
|---|---|
| `disabled` | Heartbeat is disabled (`automation.heartbeat.enabled: false`) — tick was a no-op |
| `hard_stop` | Halted — `reason` (`blocked_task` and/or `security_rejection`) |
| `nothing_actionable` | Saw N inbox candidates, none actionable |
| `skipped` | Saw N, picked `<picked>`, skipped (`reason`) |
| `started` | Saw N, picked `<picked>` → started `<objective>` (archived to `<archived_to>`) |

Use `/nazgul:log` for the full historical heartbeat timeline across ticks.

## Enabling the Interval Trigger (opt-in, default off)

`automation.heartbeat.enabled` defaults to `false` — an unconfigured project never ticks on its own.
To enable unattended, periodic ticking:

1. Set `automation.heartbeat.enabled: true` in `nazgul/config.json` (review
   `automation.heartbeat.inbox.dir` and `automation.heartbeat.auto_start` for your setup).
2. Configure a Claude Code **native scheduled agent (routine)** to fire `/nazgul:heartbeat` on your
   chosen interval (`automation.heartbeat.interval`, e.g. `30m`). Routines are a Claude Code platform
   primitive independent of this plugin — set one up per the Claude Code scheduled-agent
   documentation, pointing it at this skill.
3. Each fired tick is identical to running `/nazgul:heartbeat` by hand: same gates, same hard stops,
   same decision record.

The core (`scripts/heartbeat.sh`) does not know or care what fired it — a routine, a human, or a test
harness all invoke the same tick. This skill wires no OS-level cron/launchd job and no `claude -p`
invocation; that remains deferred (FEAT-009).
