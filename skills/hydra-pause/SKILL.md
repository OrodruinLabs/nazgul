---
name: hydra-pause
description: Gracefully pause the Hydra autonomous loop at the next iteration boundary. The loop will stop cleanly after the current task action completes.
context: fork
allowed-tools: Read, Write, Edit, Bash
---

# Hydra Pause

## Current State
- Config: !`cat hydra/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Paused: !`jq -r '.paused // false' hydra/config.json 2>/dev/null || echo "unknown"`

## Instructions

Gracefully pause the Hydra autonomous loop so it stops at the next iteration boundary.

### Step 1: Check Initialization

If the config shows "NOT_INITIALIZED":
- Output: "Hydra not initialized. Run `/hydra-init` first."
- Stop here.

### Step 2: Check Current Pause State

Read `hydra/config.json` and check the `paused` field.

If already paused (`"paused": true`):
- Output: "Hydra is already paused. Run `/hydra-start` to resume."
- Stop here.

### Step 3: Set Pause Flag

Use `jq` to set `"paused": true` in `hydra/config.json`:

```bash
jq '.paused = true' hydra/config.json > hydra/config.json.tmp && mv hydra/config.json.tmp hydra/config.json
```

### Step 4: Confirm

Output:
```
Hydra will pause at the next iteration boundary.
The current task action will complete before stopping.

To resume: /hydra-start
To check status: /hydra-status
```
