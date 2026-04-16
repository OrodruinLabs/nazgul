---
name: nazgul:reset
description: Reset Nazgul state to a clean slate. Archives current state and recreates from templates. Use when Nazgul gets into a corrupted or confusing state.
context: fork
allowed-tools: Read, Write, Bash, Glob, ToolSearch
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Reset

## Examples
- `/nazgul:reset` — Archive current state and reset to clean slate (with confirmation)
- `/nazgul:reset --hard` — Reset immediately without confirmation prompt
- `/nazgul:reset --preserve-context` — Reset but keep the context/ directory intact

## Arguments
$ARGUMENTS

## Current State
- Config exists: !`test -f nazgul/config.json && echo "YES" || echo "NO"`
- Tasks count: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Checkpoints count: !`ls nazgul/checkpoints/iteration-*.json 2>/dev/null | wc -l | tr -d ' '`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

Reset Nazgul state to a clean slate by archiving existing state and recreating from templates.

### Step 1: Check Initialization

If config does not exist (shows "NO"):
- Output: "Nothing to reset — Nazgul not initialized. Run `/nazgul:init` to set up."
- Stop here.

### Step 2: Parse Arguments

Check `$ARGUMENTS` for flags:
- `--hard` — Skip confirmation, proceed immediately
- `--preserve-context` — Keep the `nazgul/context/` directory intact (architecture map, style conventions, test strategy, etc.)

### Step 3: Confirm with User

Unless `--hard` flag is present, show the summary, then use `AskUserQuestion` to confirm:

First, display what will be archived:
```
Nazgul Reset
═══════════════════════════════════════

This will archive and reset the following:
  - Plan:         nazgul/plan.md
  - Tasks:        [N] task file(s)
  - Checkpoints:  [N] checkpoint file(s)
  - Reviews:      nazgul/reviews/
  - Docs:         nazgul/docs/
  - Logs:         nazgul/logs/

Context directory: [WILL BE RESET | WILL BE PRESERVED (--preserve-context)]

Everything will be archived to nazgul/archive/[timestamp]/ before deletion.
```

Then use `AskUserQuestion`:
- header: "Confirm"
- question: "Archive current state and reset Nazgul to a clean slate?"
- options:
  - "Reset" — "Archive everything and start fresh"
  - "Abort" — "Cancel and keep current state"

If Abort: stop immediately.

### Step 4: Create Archive Directory

Generate a timestamp-based archive directory:

```bash
ARCHIVE_DIR="nazgul/archive/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
```

### Step 5: Archive Existing State

Move the following into the archive directory (if they exist):

1. `nazgul/plan.md` → `$ARCHIVE_DIR/plan.md`
2. `nazgul/tasks/` → `$ARCHIVE_DIR/tasks/`
3. `nazgul/checkpoints/` → `$ARCHIVE_DIR/checkpoints/`
4. `nazgul/reviews/` → `$ARCHIVE_DIR/reviews/`
5. `nazgul/docs/` → `$ARCHIVE_DIR/docs/`
6. `nazgul/logs/` → `$ARCHIVE_DIR/logs/`

If `--preserve-context` is NOT set:
8. `nazgul/context/` → `$ARCHIVE_DIR/context/`

Use `mv` for each item. Skip items that do not exist.

### Step 6: Reset Config

1. Read current `nazgul/config.json` and extract `project.*` fields (project name, language, framework, test command, etc.)
2. Read the config template from the plugin: look for the template config in the plugin's templates directory
3. Write a fresh `nazgul/config.json` with:
   - All default values from the template
   - The preserved `project.*` fields restored
   - `paused: false`
   - `current_iteration: 0`
   - `objective: null`
   - Empty `objectives_history` array (the old history is in the archive)

Use `jq` for all JSON manipulation:

```bash
# Extract project fields from current config
PROJECT=$(jq '.project' nazgul/config.json)

# After writing fresh config, restore project fields
jq --argjson project "$PROJECT" '.project = $project' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
```

### Step 7: Recreate Empty Directories

Ensure the following empty directories exist for the next run:

```bash
mkdir -p nazgul/tasks
mkdir -p nazgul/checkpoints
mkdir -p nazgul/reviews
mkdir -p nazgul/docs
mkdir -p nazgul/logs
```

If `--preserve-context` was NOT set:
```bash
mkdir -p nazgul/context
```

### Step 8: Output Summary

```
Nazgul Reset Complete
═══════════════════════════════════════

Archived to: nazgul/archive/[timestamp]/
  - Plan:         [archived | not found]
  - Tasks:        [N] file(s) archived
  - Checkpoints:  [N] file(s) archived
  - Reviews:      [archived | not found]
  - Docs:         [archived | not found]
  - Logs:         [archived | not found]
  - Context:      [archived | PRESERVED]

Config reset with project settings preserved.

Next steps:
  - /nazgul:start            Start a fresh run
  - /nazgul:start "objective" Start with a specific objective
  - /nazgul:status           Verify clean state
```
