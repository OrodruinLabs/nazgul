---
name: hydra-reset
description: Reset Hydra state to a clean slate. Archives current state and recreates from templates. Use when Hydra gets into a corrupted or confusing state.
context: fork
allowed-tools: Read, Write, Bash, Glob
metadata:
  author: Hydra Framework
  version: 1.0.0
---

# Hydra Reset

## Examples
- `/hydra-reset` — Archive current state and reset to clean slate (with confirmation)
- `/hydra-reset --hard` — Reset immediately without confirmation prompt
- `/hydra-reset --preserve-context` — Reset but keep the context/ directory intact

## Arguments
$ARGUMENTS

## Current State
- Config exists: !`test -f hydra/config.json && echo "YES" || echo "NO"`
- Tasks count: !`ls hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Checkpoints count: !`ls hydra/checkpoints/iteration-*.json 2>/dev/null | wc -l | tr -d ' '`

## Instructions

Reset Hydra state to a clean slate by archiving existing state and recreating from templates.

### Step 1: Check Initialization

If config does not exist (shows "NO"):
- Output: "Nothing to reset — Hydra not initialized. Run `/hydra-init` to set up."
- Stop here.

### Step 2: Parse Arguments

Check `$ARGUMENTS` for flags:
- `--hard` — Skip confirmation, proceed immediately
- `--preserve-context` — Keep the `hydra/context/` directory intact (architecture map, style conventions, test strategy, etc.)

### Step 3: Confirm with User

Unless `--hard` flag is present, show a confirmation prompt:

```
Hydra Reset
═══════════════════════════════════════

This will archive and reset the following:
  - Plan:         hydra/plan.md
  - Tasks:        [N] task file(s)
  - Checkpoints:  [N] checkpoint file(s)
  - Reviews:      hydra/reviews/
  - Docs:         hydra/docs/
  - Logs:         hydra/logs/
  - Notifications: hydra/notifications.jsonl

Context directory: [WILL BE RESET | WILL BE PRESERVED (--preserve-context)]

Everything will be archived to hydra/archive/[timestamp]/ before deletion.

Proceed? (yes/no)
```

Wait for user confirmation. If the user says no, abort.

### Step 4: Create Archive Directory

Generate a timestamp-based archive directory:

```bash
ARCHIVE_DIR="hydra/archive/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
```

### Step 5: Archive Existing State

Move the following into the archive directory (if they exist):

1. `hydra/plan.md` → `$ARCHIVE_DIR/plan.md`
2. `hydra/tasks/` → `$ARCHIVE_DIR/tasks/`
3. `hydra/checkpoints/` → `$ARCHIVE_DIR/checkpoints/`
4. `hydra/reviews/` → `$ARCHIVE_DIR/reviews/`
5. `hydra/docs/` → `$ARCHIVE_DIR/docs/`
6. `hydra/logs/` → `$ARCHIVE_DIR/logs/`
7. `hydra/notifications.jsonl` → `$ARCHIVE_DIR/notifications.jsonl`

If `--preserve-context` is NOT set:
8. `hydra/context/` → `$ARCHIVE_DIR/context/`

Use `mv` for each item. Skip items that do not exist.

### Step 6: Reset Config

1. Read current `hydra/config.json` and extract `project.*` fields (project name, language, framework, test command, etc.)
2. Read the config template from the plugin: look for the template config in the plugin's templates directory
3. Write a fresh `hydra/config.json` with:
   - All default values from the template
   - The preserved `project.*` fields restored
   - `paused: false`
   - `current_iteration: 0`
   - `objective: null`
   - Empty `objectives_history` array (the old history is in the archive)

Use `jq` for all JSON manipulation:

```bash
# Extract project fields from current config
PROJECT=$(jq '.project' hydra/config.json)

# After writing fresh config, restore project fields
jq --argjson project "$PROJECT" '.project = $project' hydra/config.json > hydra/config.json.tmp && mv hydra/config.json.tmp hydra/config.json
```

### Step 7: Recreate Empty Directories

Ensure the following empty directories exist for the next run:

```bash
mkdir -p hydra/tasks
mkdir -p hydra/checkpoints
mkdir -p hydra/reviews
mkdir -p hydra/docs
mkdir -p hydra/logs
```

If `--preserve-context` was NOT set:
```bash
mkdir -p hydra/context
```

### Step 8: Output Summary

```
Hydra Reset Complete
═══════════════════════════════════════

Archived to: hydra/archive/[timestamp]/
  - Plan:         [archived | not found]
  - Tasks:        [N] file(s) archived
  - Checkpoints:  [N] file(s) archived
  - Reviews:      [archived | not found]
  - Docs:         [archived | not found]
  - Logs:         [archived | not found]
  - Notifications: [archived | not found]
  - Context:      [archived | PRESERVED]

Config reset with project settings preserved.

Next steps:
  - /hydra-start            Start a fresh run
  - /hydra-start "objective" Start with a specific objective
  - /hydra-status           Verify clean state
```
