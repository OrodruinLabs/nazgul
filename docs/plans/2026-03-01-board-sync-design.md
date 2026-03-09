# External Board Sync — Design Document

**Date**: 2026-03-01
**Status**: Approved
**Author**: Jose Mejia + Claude

## Problem

Hydra tracks tasks locally in `hydra/tasks/TASK-NNN.md` files. Teams using GitHub (or other platforms) have no visibility into Hydra's progress from their existing project management tools. We need to sync Hydra's task state to external project boards without changing Hydra's source-of-truth model.

## Decisions

- **GitHub Projects V2** as the first supported provider (GraphQL API via `gh` CLI)
- **One-way sync**: Hydra → GitHub. Hydra is always the source of truth. Changes on GitHub are ignored.
- **Sync on state transitions only** — minimal API calls, no polling
- **Real GitHub Issues** linked to the Project board (not draft items)
- **Archive existing items** when taking over an existing project (non-destructive)
- **Provider-pluggable architecture** — generic skill and config, provider-specific sync scripts

## Command: `/hydra:board <provider> [--clean]`

### Usage

```
/hydra:board github            # Connect to GitHub Projects (create new or pick existing)
/hydra:board github --clean    # Take over existing project (archive all items first)
/hydra:board disconnect        # Remove board sync
/hydra:board status            # Show current board connection + sync health
```

### Standalone vs Integrated

- **Standalone**: `/hydra:board github` can be run at any time after `/hydra:init`
- **Integrated**: During `/hydra:start`, if discovery detected a GitHub repo, the user is prompted:
  - "GitHub repo detected (owner/repo). Track tasks on GitHub Projects?"
  - Options: Create new project / Use existing project / Skip for now

### Flow: `/hydra:board github`

1. Verify Hydra is initialized (`hydra/config.json` exists)
2. Detect GitHub repo: `gh repo view --json owner,name`
3. Check `project` scope: `gh auth status` — prompt to add if missing
4. List existing projects → user picks one or creates new
5. Create custom fields (Hydra Status, Task ID, Group)
6. Create `hydra:*` labels on the repo
7. If tasks already exist locally, run full sync
8. Store board config in `hydra/config.json`

## Board Structure

### Custom Fields on GitHub Projects V2

| Field | Type | Values |
|-------|------|--------|
| Hydra Status | SINGLE_SELECT | PLANNED, READY, IN_PROGRESS, IMPLEMENTED, IN_REVIEW, CHANGES_REQUESTED, DONE, BLOCKED |
| Task ID | TEXT | e.g., TASK-001 |
| Group | NUMBER | Parallel execution group |

### GitHub Issues

Each Hydra task becomes a GitHub Issue:
- **Title**: `TASK-001: [Task Title]`
- **Body**: Description + Acceptance Criteria from task manifest
- **Labels**: `hydra`, `hydra:{status}` (e.g., `hydra:in-progress`)
- **Added to project** with Hydra Status field set

The built-in `Status` field on Projects V2 is left alone to avoid conflicts with existing workflows. No views are auto-created — the user creates their own.

## Sync Script: `scripts/board-sync-github.sh`

Provider script implementing the generic interface:

```bash
board-sync-github.sh setup <project-number>    # Connect, create fields, store IDs
board-sync-github.sh create-issue <task-file>   # Create GitHub Issue + add to project
board-sync-github.sh sync-task <task-file>      # Update issue status/labels from task manifest
board-sync-github.sh sync-all                   # Full sync of all hydra/tasks/TASK-*.md
board-sync-github.sh archive-all <project-num>  # Archive all existing items (--clean)
board-sync-github.sh disconnect                 # Remove board config from config.json
board-sync-github.sh status                     # Show connection info + last sync
```

### `sync-task` (hot path)

1. Read task manifest → extract Status, Task ID, title, description
2. Look up GitHub Issue number from `board.task_map` in config
3. If no issue exists → `create-issue` first
4. Update the issue:
   - `gh project item-edit` → set Hydra Status field
   - `gh issue edit` → update labels
5. On DONE: close the issue
6. On BLOCKED: add `hydra:blocked` label + comment with blocked reason

### Error Handling

- **Sync failures never block local work.** The board is a visibility layer, not source of truth.
- Network failures → log warning, continue local flow
- Rate limits → exponential backoff with 3 retries, then skip and log
- Stale issue (deleted externally) → recreate and update mapping
- Consecutive failure counter → auto-disable sync after 5 failures, log warning

## Integration Points

Only two ongoing sync points:

### 1. Planner Agent

After creating each `hydra/tasks/TASK-NNN.md`:
- Call `board-sync-github.sh create-issue <task-file>`
- Creates the GitHub Issue and adds to project with status PLANNED

### 2. Stop Hook (`scripts/stop-hook.sh`)

After writing the checkpoint:
- For each task whose status changed this iteration → `board-sync-github.sh sync-task <task-file>`
- Catches ALL transitions without modifying individual agents
- Piggybacks on the existing task status loop

Agents themselves never know about the board — they update local task files, the stop hook handles the push.

## Discovery Integration

The discovery agent detects GitHub capability during its scan:
- Runs `gh repo view --json owner,name` to detect GitHub repo
- Runs `gh auth status` to check for `project` scope
- Stores results in `hydra/context/` as part of the project profile
- No user prompt during discovery — just detection

## `/hydra:start` Integration

After discovery completes, before planning:
- Check discovery context for GitHub detection
- If GitHub detected, prompt user:
  - "GitHub repo detected (owner/repo). Track tasks on GitHub Projects?"
  - Create new project / Use existing project / Skip for now
- If yes, run board setup inline (same script as `/hydra:board`)
- Planning continues with sync active

## Config Schema

New `board` section in `hydra/config.json`:

```json
{
  "board": {
    "enabled": false,
    "provider": null,
    "provider_config": {},
    "task_map": {},
    "last_sync": null,
    "sync_failures": 0
  }
}
```

- `provider`: `"github"`, `"ado"`, `"trello"`, etc.
- `provider_config`: Opaque object owned by the provider script. Contents depend on `provider`.
- `task_map`: Maps task IDs to external references: `{"TASK-001": {"issue_number": 42, "item_id": "PVTI_..."}, ...}`
- `last_sync`: ISO 8601 timestamp of last successful sync
- `sync_failures`: Consecutive failure counter

### GitHub `provider_config` (populated by setup)

```json
{
  "owner": "owner-name",
  "repo": "repo-name",
  "project_number": 1,
  "project_id": "PVT_...",
  "field_ids": {
    "hydra_status": "PVTF_...",
    "task_id": "PVTF_...",
    "group": "PVTF_..."
  },
  "status_option_ids": {
    "PLANNED": "...",
    "READY": "...",
    "IN_PROGRESS": "...",
    "IMPLEMENTED": "...",
    "IN_REVIEW": "...",
    "CHANGES_REQUESTED": "...",
    "DONE": "...",
    "BLOCKED": "..."
  },
  "labels_created": true
}
```

Field IDs and option IDs are captured at setup time so every sync doesn't need to query them.

## Takeover Flow (`--clean`)

1. `gh project item-list` → get all existing items
2. For each item: `gh project item-archive`
3. Remove any stale `hydra:*` labels from the repo
4. Recreate labels fresh
5. Proceed with normal setup

Archive instead of delete — items are accessible via "Archived items" view, non-destructive, restorable.

Guard rails:
- Show confirmation: "This will archive N items on project 'X'. Continue?"
- `--clean` flag must be explicit — no accidental archiving

## Future Providers

Adding a new provider requires:
1. `scripts/board-sync-{provider}.sh` implementing the standard interface
2. Provider-specific `provider_config` schema (documented in the script)
3. Add provider name to `/hydra:board` skill's argument handling

No changes needed to config schema, stop hook logic, or agent protocols.
