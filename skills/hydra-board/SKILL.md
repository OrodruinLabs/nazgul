---
name: hydra-board
description: Connect Hydra task tracking to an external project board (GitHub Projects, Azure DevOps, etc). Use when user says "connect to github projects", "set up board", "track on github", or "hydra board".
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Board

## Examples
- `/hydra-board github` — Connect to GitHub Projects
- `/hydra-board github --clean` — Take over existing project (archive items first)
- `/hydra-board disconnect` — Remove board sync
- `/hydra-board status` — Show current board connection

## Arguments
$ARGUMENTS

## Current State
- Hydra initialized: !`[ -f hydra/config.json ] && echo "YES" || echo "NO"`
- Board enabled: !`jq -r '.board.enabled // false' hydra/config.json 2>/dev/null || echo "false"`
- Board provider: !`jq -r '.board.provider // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Last sync: !`jq -r '.board.last_sync // "never"' hydra/config.json 2>/dev/null || echo "never"`
- Sync failures: !`jq -r '.board.sync_failures // 0' hydra/config.json 2>/dev/null || echo "0"`
- GitHub repo: !`gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "NOT_DETECTED"`
- GitHub auth scopes: !`gh auth status 2>&1 | grep -oE 'project' || echo "NO_PROJECT_SCOPE"`
- Existing projects: !`gh project list --format json --jq '.projects[] | "\(.number): \(.title)"' 2>/dev/null | head -5 || echo "NONE"`
- Mapped tasks: !`jq -r '.board.task_map | length' hydra/config.json 2>/dev/null || echo "0"`

## Instructions

### Step 0: Parse Arguments

Parse `$ARGUMENTS` for:
- Provider name: `github`, `ado`, `trello` (first positional arg)
- Subcommand: `disconnect`, `status` (if no provider)
- Flags: `--clean` (archive existing items before setup)

### Step 1: Route by Command

#### If `disconnect`:
1. Run: `bash scripts/board-sync-github.sh disconnect`
2. Show: "Board sync disconnected."
3. STOP.

#### If `status`:
1. Run: `bash scripts/board-sync-github.sh status`
2. STOP.

#### If provider is `github`:
Continue to Step 2.

#### If provider is unsupported:
Show: "Provider '[name]' not yet supported. Available: github"
STOP.

#### If no arguments:
Show usage examples and current board state.
STOP.

### Step 2: Prerequisites Check

1. Check Hydra initialized (use preprocessor data above)
2. If NOT initialized: "Run `/hydra-init` first." — STOP
3. Check GitHub repo detected (use preprocessor data above)
4. If NOT detected: "Not a GitHub repository or `gh` not authenticated." — STOP
5. Check project scope (use preprocessor data above)
6. If NO_PROJECT_SCOPE: "Missing `project` scope. Run: `gh auth refresh -s project`" — STOP

### Step 3: Project Selection

Using the preprocessor "Existing projects" data:

1. If projects exist, present options:
   ```
   Existing GitHub Projects found:
   1. #[num]: [title]
   2. #[num]: [title]
   3. Create a new project

   Which project should Hydra use?
   ```

2. If no projects exist, ask:
   ```
   No existing GitHub Projects found. Create one?
   Project name (default: "Hydra: [repo-name]"):
   ```

3. If user picks "Create new":
   - Run: `gh project create --owner [owner] --title "[name]" --format json`
   - Extract project number

4. If user picks existing + `--clean` flag:
   - Show: "This will archive [N] items on project '[title]'. Continue?"
   - If confirmed: run `bash scripts/board-sync-github.sh archive-all [project-number]`

### Step 4: Run Setup

Run: `bash scripts/board-sync-github.sh setup [project-number]`

### Step 5: Initial Sync

If tasks already exist in `hydra/tasks/`:
1. Show: "Found [N] existing tasks. Syncing to board..."
2. Run: `bash scripts/board-sync-github.sh sync-all`
3. Show: "Synced [N] tasks to GitHub Projects."

### Step 6: Summary

Show:
```
Board sync enabled!
═══════════════════════════════
Provider:   GitHub Projects V2
Repo:       [owner]/[repo]
Project:    #[number] — [title]
Tasks:      [N] synced
URL:        https://github.com/orgs/[owner]/projects/[number]

Tasks will auto-sync to the board on every state transition.
Run `/hydra-board status` to check sync health.
Run `/hydra-board disconnect` to remove sync.
```
