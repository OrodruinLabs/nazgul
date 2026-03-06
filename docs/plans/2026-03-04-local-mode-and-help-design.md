# Design: Local Install Mode & Help Command

**Date:** 2026-03-04
**Status:** Approved

## Feature 1: Local Mode (`--local` flag on `/hydra-init`)

### Problem
When Hydra initializes in a project, it creates files (`hydra/`, `.claude/agents/generated/`, `.mcp.json`, CLAUDE.md modifications) that get tracked by git and pushed to the project repository. Users want the option to keep all Hydra artifacts local-only.

### Solution
Add a `--local` flag to `/hydra-init`. When passed:

1. **`.gitignore` management** — Append to the project's `.gitignore` (create if needed):
   ```
   # Hydra Framework (local mode)
   hydra/
   .claude/agents/generated/
   .mcp.json
   ```

2. **Skip CLAUDE.md injection** — Step 5 of hydra-init is skipped entirely. The plugin's own CLAUDE.md provides instructions via the plugin system.

3. **Config flag** — Store `"install_mode": "local"` in `hydra/config.json`.

4. **Init summary** — Display `Mode: local (files not tracked in git)` in the Step 4 summary.

### What stays the same
All other init steps: prerequisites, directory creation, discovery, agent generation, MCP server setup, `.claude/settings.json`. Files still get created — they're just gitignored.

### Files Modified
- `skills/hydra-init/SKILL.md` — Add `--local` flag handling, gitignore step, conditional CLAUDE.md skip
- `templates/config.json` — Add `install_mode` field (default: `"shared"`)

## Feature 2: `/hydra-help` Quick Reference Card

### Problem
New users have no quick way to see available commands and what they do.

### Solution
New skill at `skills/hydra-help/SKILL.md` with `disable-model-invocation: true` that displays a formatted quick-reference card covering:

- Getting started commands
- Running/monitoring commands
- Task management
- Control commands
- Advanced commands
- Mode descriptions (hitl, afk, yolo)

### Files Created
- `skills/hydra-help/SKILL.md` — The help skill
