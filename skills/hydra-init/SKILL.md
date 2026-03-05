---
name: hydra-init
description: Initialize Hydra for a project — check prerequisites, run discovery, create runtime directories, generate reviewer agents. Use when setting up Hydra for the first time, user says "initialize hydra", "set up hydra", or before running any other Hydra commands.
context: fork
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Init

## Examples
- `/hydra-init` — Initialize Hydra with default settings
- `/hydra-init --force` — Reinitialize, archiving current state first
- `/hydra-init --local` — Initialize in local mode (files not tracked in git)
- `/hydra-init --local --force` — Reinitialize in local mode

## Prerequisites Check
- jq installed: !`which jq 2>/dev/null && echo "YES" || echo "NO — install jq first: brew install jq (macOS) or apt install jq (Linux)"`
- Git repo: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "YES" || echo "NO — initialize a git repo first"`

## Companion Plugins Check
- security-guidance: !`ls ~/.claude/plugins/security-guidance 2>/dev/null && echo "INSTALLED" || echo "NOT INSTALLED — recommended: claude plugin install security-guidance"`

## Instructions

Initialize the Hydra Framework for this project:

### Step 0: Idempotency Check
1. Check if `hydra/config.json` already exists
2. If it exists, warn the user: "Hydra is already initialized for this project. Use `--force` to reinitialize (current state will be archived)."
3. If `--force` was passed (check $ARGUMENTS), archive current state to `hydra/archive/` first, then proceed
4. If neither --force nor fresh: STOP here

### Step 0.5: Parse Arguments
1. Check `$ARGUMENTS` for `--local` flag
2. If `--local` is present, set a variable `LOCAL_MODE=true`
3. Both `--local` and `--force` can be combined

### Step 1: Check Prerequisites
1. Verify `jq` is installed (required for hook scripts). If jq is NOT installed, output: "REQUIRED: jq is not installed. Install it first: `brew install jq` (macOS) or `apt install jq` (Linux). Hydra cannot function without jq." — STOP, do not proceed with initialization.
2. Verify this is a git repository
3. Check for companion plugins and suggest if missing:
   - security-guidance (ESSENTIAL — real-time code vulnerability detection)
   - frontend-design (recommended if frontend project)

### Step 2: Create Runtime Directory Structure
Create the following directories and files:
```
hydra/
├── config.json          # Copy from plugin templates/config.json
├── plan.md              # Copy from plugin templates/plan.md
├── tasks/               # Empty, for task manifests
├── checkpoints/         # Empty, for iteration checkpoints
├── reviews/             # Empty, for review artifacts
├── context/             # Will be filled by Discovery
├── docs/                # Will be filled by Doc Generator
├── logs/                # Empty, for iteration logs
└── notifications.jsonl  # Empty, for OpenClaw bridge
```

### Step 2.5: Configure Git Ignore (Local Mode Only)
If `LOCAL_MODE=true`:

1. Read or create `.gitignore` at the project root
2. Check if `# Hydra Framework (local mode)` marker already exists
3. If marker is NOT present, append:
   ```
   # Hydra Framework (local mode)
   hydra/
   .claude/agents/generated/
   .mcp.json
   ```
4. Set `install_mode` to `"local"` in the config:
   ```bash
   jq '.install_mode = "local"' hydra/config.json > hydra/config.json.tmp && mv hydra/config.json.tmp hydra/config.json
   ```

### Step 3: Run Discovery
Delegate to the Discovery agent to scan the codebase:
1. Generate project context files in `hydra/context/`
2. Generate tailored reviewer agents in `.claude/agents/generated/`
3. Update `hydra/config.json` with discovered project settings

### Step 4: Display Summary
Show the user:
- Project profile summary (language, framework, key dependencies)
- Number of files scanned
- Reviewer board generated (list all reviewer agents)
- Companion plugin status
- Install mode: local (files not tracked in git) / shared (files tracked in git)
- Next step: `/hydra-start "your objective"`

### Step 5: Inject CLAUDE.md (Shared Mode Only)
If `LOCAL_MODE=true`:
- Skip this step entirely. The plugin's own CLAUDE.md provides instructions via the plugin system.
- Output: "Skipping CLAUDE.md injection (local mode)."

Otherwise (shared mode):
If the project doesn't already have Hydra instructions in CLAUDE.md:
- Append the Hydra section from `templates/CLAUDE.md.template`
- Or create CLAUDE.md if it doesn't exist

### Step 6: Enable Agent Teams, MCP Server & Permissions
Ensure Agent Teams, the notification MCP server, and permissions are all configured for this project.

Resolve the plugin root: use `$CLAUDE_PLUGIN_ROOT` env var. If not set, fall back to the plugin's known install path.

**Build MCP server if needed:** Check if `<plugin-root>/mcp-server/dist/index.js` exists. If it does NOT exist, run `cd <plugin-root>/mcp-server && npm install && npm run build`. If the build fails, tell the user: "MCP server build failed. Check the output above and fix any issues in `mcp-server/`." STOP.

**A. MCP server config → `.mcp.json` (project root)**

Read `.mcp.json` at the project root (or start with `{}`), then merge:

1. **`mcpServers.hydra-notifications`**: if missing, add:
   ```json
   {
     "command": "node",
     "args": ["${PLUGIN_ROOT}/mcp-server/dist/index.js"]
   }
   ```
   where `${PLUGIN_ROOT}` is the resolved absolute path of the plugin directory (no env var references in the final JSON).

Write the merged result back. If already present, skip (no-op).

**B. Agent Teams & permissions → `.claude/settings.json`**

Read `.claude/settings.json` (or start with `{}`), then merge:

1. **`enableAgentTeams`**: set to `true` if missing
2. **`permissions.allow`**: if array doesn't contain `"mcp__hydra-notifications__*"`, add it

Write the merged result back. If everything is already present, skip (no-op).
