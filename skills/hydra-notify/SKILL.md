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
2. If `--setup` was passed: set `notifications.enabled` to `true` in `hydra/config.json` and continue.
   Otherwise: check if notifications are enabled (`notifications.enabled`). If not: "Notifications are disabled. Enable in hydra/config.json." STOP.
3. Ensure the MCP server is built and configured:
   a. Resolve plugin root from `$CLAUDE_PLUGIN_ROOT` env var
   b. Check if `<plugin-root>/mcp-server/dist/index.js` exists
   c. If it does NOT exist, run `cd <plugin-root>/mcp-server && npm install && npm run build`
   d. If the build fails, tell the user: "MCP server build failed. Check the output above and fix any issues in `mcp-server/`." STOP.
   e. **MCP server config → `.mcp.json` (project root):**
      Read `.mcp.json` at the project root (or start with `{}`). If `mcpServers.hydra-notifications` is missing, add it:
      - `{"command": "node", "args": ["<plugin-root>/mcp-server/dist/index.js"]}`
      Write the merged result back.
   f. **Permissions → `.claude/settings.json`:**
      Read `.claude/settings.json` (or start with `{}`). If `permissions.allow` doesn't contain `"mcp__hydra-notifications__*"`, add it.
      Write back the merged settings.
   g. If changes were made in either file, tell the user: "MCP server configured. Restart Claude Code to activate, then run `/hydra-notify` again." STOP.
4. Verify the MCP server is available by calling `get_pending_events`. If it fails: "MCP server is configured but not running. Restart Claude Code to activate it." STOP.

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

## Polling

Polling is **on by default** (every 300 seconds). The server automatically:
- Polls GitHub workflow runs for the current repo
- Discovers the open PR for the current branch and polls its comments

Tune with `HYDRA_POLL_INTERVAL` (seconds). Set to `0` to disable polling entirely.

## Arguments

- `--setup` — Only configure the MCP server in project settings (skip event processing). Use this to enable notifications on an existing project.
- `--source <source>` — Only process events from this source (github, ci, slack, etc.)
- `--dry-run` — Show what would be processed without actually routing to agents

## Output

Show a summary after processing:
- Event type and source
- Which agents were routed to
- Status (done/failed)
