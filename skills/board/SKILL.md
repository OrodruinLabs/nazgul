---
name: nazgul:board
description: Connect Nazgul task tracking to an external project board (GitHub Projects, Azure DevOps, etc). Use when user says "connect to github projects", "set up board", "track on github", or "nazgul board".
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
  version: 2.7.1
---

# Nazgul Board

## Examples
- `/nazgul:board github` — Connect to GitHub Projects
- `/nazgul:board github --clean` — Take over existing project (archive items first)
- `/nazgul:board disconnect` — Remove board sync
- `/nazgul:board status` — Show current board connection

## Arguments
$ARGUMENTS

## Current State
- Nazgul initialized: !`[ -f nazgul/config.json ] && echo "YES" || echo "NO"`
- Board enabled: !`jq -r '.board.enabled // false' nazgul/config.json 2>/dev/null || echo "false"`
- Board provider: !`jq -r '.board.provider // "none"' nazgul/config.json 2>/dev/null || echo "none"`
- Last sync: !`jq -r '.board.last_sync // "never"' nazgul/config.json 2>/dev/null || echo "never"`
- Sync failures: !`jq -r '.board.sync_failures // 0' nazgul/config.json 2>/dev/null || echo "0"`
- GitHub repo: !`gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "NOT_DETECTED"`
- GitHub auth scopes: !`gh auth status 2>&1 | grep -oE 'project' || echo "NO_PROJECT_SCOPE"`
- Existing projects: !`gh project list --format json --jq '.projects[] | "\(.number): \(.title)"' 2>/dev/null | head -5 || echo "NONE"`
- Mapped tasks: !`jq -r '.board.task_map | length' nazgul/config.json 2>/dev/null || echo "0"`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

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

1. Check Nazgul initialized (use preprocessor data above)
2. If NOT initialized: "Run `/nazgul:init` first." — STOP
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
   ```

   Then use `AskUserQuestion`:
   - header: "Project"
   - question: "Which GitHub Project should Nazgul use?"
   - options: list existing projects (up to 3) + "Create a new project" as the last option
   - If "Create new": run `gh project create --owner [owner] --title "Nazgul: [repo-name]" --format json` and extract project number

2. If no projects exist, use `AskUserQuestion`:
   - header: "Project"
   - question: "No existing GitHub Projects found. Create one?"
   - options:
     - "Create project" — "Create 'Nazgul: [repo-name]' on GitHub Projects"
     - "Abort" — "Cancel board setup"

3. If user picks existing + `--clean` flag, use `AskUserQuestion`:
   - header: "Confirm"
   - question: "This will archive [N] items on project '[title]'. Continue?"
   - options:
     - "Archive and continue" — "Clear existing items and set up fresh"
     - "Keep items" — "Connect without archiving existing items"
   - If "Archive": run `bash scripts/board-sync-github.sh archive-all [project-number]`

### Step 4: Run Setup

Run: `bash scripts/board-sync-github.sh setup [project-number]`

### Step 5: Initial Sync

If tasks already exist in `nazgul/tasks/`:
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
Run `/nazgul:board status` to check sync health.
Run `/nazgul:board disconnect` to remove sync.
```

## GitHub Connector (two-way issue sync)

Board sync above is **one-way**: Nazgul pushes task status to a GitHub *Projects V2 board*. The separate, opt-in **GitHub connector** (`scripts/lib/connector-github.sh`) adds **two-way sync with GitHub *Issues*** and is **default-OFF**. GitHub is the only shipped connector — Linear/Slack are planned behind the same contract but are NOT shipped.

- **Pull**: OPEN issues carrying the opt-in label (`connectors.github.pull.label`, default `nazgul`) surface through the objective-inbox seam as work candidates. With `automation.heartbeat.inbox.provider="github"` the heartbeat tick engine triages and auto-starts them like local inbox items. On claim, Nazgul adds the claimed label (`connectors.github.pull.claimed_label`, default `nazgul-claimed`) — its "I took this" marker, which a push never removes.
- **Push**: on each loop iteration the stop-hook pushes any changed task status back onto the mapped issue (a single `nazgul-status:*` label, plus a `<!-- nazgul-pr -->`-marked PR-link comment when the task manifest carries a `- **PR**:` URL). Unchanged statuses are not re-pushed, and a push failure never blocks the loop.

**Enable it:**
1. `gh auth login` — credentials live in `gh auth`/env only; no token is stored in `nazgul/config.json`.
2. Set `connectors.github.enabled` to `true`.
3. Set `automation.heartbeat.inbox.provider` to `"github"` — this existing key is the provider selector; there is no new key.
4. Apply the `nazgul` label to the issues you want Nazgul to pick up.

Pull failures never block work: after 5 consecutive failures (`connectors.github.pull_failures`) the connector auto-disables. Full key reference: the **Connectors** section in `docs/CONFIGURATION.md`.
