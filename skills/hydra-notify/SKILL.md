---
name: hydra-notify
description: Process pending notification events — route to Hydra agents and execute actions
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - Task
  - TaskCreate
  - TaskUpdate
  - TaskList
  - ToolSearch
context: fork
---

# Hydra Notify — Process Pending Events

## Pre-flight

1. Check if `hydra/config.json` exists. If not: "Hydra not initialized. Run `/hydra-init` first." STOP.
2. Check if notifications are enabled in config (`notifications.enabled`). If not: "Notifications are disabled. Enable in hydra/config.json." STOP.
3. Verify the MCP server `hydra-notifications` is available by calling `get_pending_events`. If it fails: "MCP server not running. Start it with `npm start` in mcp-server/." STOP.

## Process

1. Call `get_pending_events` MCP tool to fetch all pending events.
2. If no events: "No pending events." STOP.
3. For each event:
   a. Read `hydra/notification-routes.json` to determine target agents.
   b. Call `acknowledge_event` to claim the event.
   c. Display the event summary to the user.
   d. Spawn the matched agent(s) with event context.
   e. After agent completes, call `complete_event` with result.
4. Display summary of all processed events.

## Arguments

- `--source <source>` — Only process events from this source (github, ci, slack, etc.)
- `--dry-run` — Show what would be processed without actually routing to agents

## Output

Show a summary after processing:
- Event type and source
- Which agents were routed to
- Status (done/failed)
