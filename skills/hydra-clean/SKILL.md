---
name: hydra-clean
description: Fully remove Hydra from a project — deletes all runtime state, generated agents, MCP config, permissions, CLAUDE.md injections, and gitignore entries. Use when user says "remove hydra", "uninstall hydra", "clean hydra", or wants to completely undo /hydra-init.
context: fork
allowed-tools: Read, Edit, Bash, Glob, Grep, AskUserQuestion
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Clean

## Examples
- `/hydra-clean` — Fully remove Hydra from this project (with confirmation)
- `/hydra-clean --force` — Remove without confirmation prompt

## Arguments
$ARGUMENTS

## Current State
- Hydra initialized: !`test -f hydra/config.json && echo "YES" || echo "NO"`
- Install mode: !`test -f hydra/config.json && jq -r '.install_mode // "shared"' hydra/config.json 2>/dev/null || echo "unknown"`
- Tasks count: !`ls hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Generated agents: !`ls .claude/agents/generated/*.md 2>/dev/null | wc -l | tr -d ' '`
- MCP config has hydra: !`test -f .mcp.json && jq -e '.mcpServers["hydra-notifications"]' .mcp.json >/dev/null 2>&1 && echo "YES" || echo "NO"`
- CLAUDE.md has hydra section: !`grep -q "Hydra Framework" CLAUDE.md 2>/dev/null && echo "YES" || echo "NO"`
- Gitignore has hydra entries: !`grep -q "# Hydra Framework (local mode)" .gitignore 2>/dev/null && echo "YES" || echo "NO"`

## Instructions

Fully remove Hydra from this project. No archiving — permanent deletion.

### Step 1: Check if Hydra is Present

If none of the current state indicators show Hydra presence (no config, no agents, no MCP entry, no CLAUDE.md section):
- Output: "Hydra is not installed in this project. Nothing to clean."
- Stop here.

### Step 2: Parse Arguments

Check `$ARGUMENTS` for `--force` flag. If present, skip confirmation.

### Step 3: Confirm with User

Unless `--force` is present, show what will be removed and ask for confirmation:

```
Hydra Clean — Full Removal
═══════════════════════════════════════════════════════

The following will be PERMANENTLY DELETED:

  hydra/                        [EXISTS | not found]
  .claude/agents/generated/     [N file(s) | not found]
  .mcp.json hydra entry         [EXISTS | not found]
  .claude/settings.json entries [EXISTS | not found]
  CLAUDE.md hydra section       [EXISTS | not found]
  .gitignore hydra entries      [EXISTS | not found]

This cannot be undone. Proceed? (yes/no)
```

Wait for user confirmation. If the user says no, abort.

### Step 4: Remove Runtime State

Delete the entire `hydra/` directory:

```bash
rm -rf hydra/
```

### Step 5: Remove Generated Agents

Delete the `.claude/agents/generated/` directory (these are Hydra-generated reviewer agents):

```bash
rm -rf .claude/agents/generated/
```

If `.claude/agents/` is now empty, remove it too. Do NOT remove `.claude/` itself as it may contain other settings.

### Step 6: Clean .mcp.json

If `.mcp.json` exists and contains a `hydra-notifications` entry:

1. Read `.mcp.json`
2. Remove the `mcpServers.hydra-notifications` key using jq:
   ```bash
   jq 'del(.mcpServers["hydra-notifications"])' .mcp.json > .mcp.json.tmp && mv .mcp.json.tmp .mcp.json
   ```
3. If `.mcpServers` is now empty (`{}`), and there are no other top-level keys besides `mcpServers`, delete `.mcp.json` entirely
4. Otherwise keep the file with remaining entries

### Step 7: Clean .claude/settings.json

If `.claude/settings.json` exists:

1. Read the file
2. Remove `enableAgentTeams` key if set to `true`
3. Remove `"mcp__hydra-notifications__*"` from `permissions.allow` array
4. Use jq:
   ```bash
   jq 'del(.enableAgentTeams) | if .permissions.allow then .permissions.allow -= ["mcp__hydra-notifications__*"] else . end' .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
   ```
5. If the file is now effectively empty (`{}` or only has empty arrays), delete it
6. If `.claude/` directory is now empty, remove it too. But be careful — check first.

### Step 8: Clean CLAUDE.md

If the project's `CLAUDE.md` contains a Hydra-injected section:

1. Read `CLAUDE.md`
2. Look for the Hydra section — it starts with `# Hydra Framework — Project Instructions` (the content from `templates/CLAUDE.md.template`)
3. Remove everything from that header to the end of the Hydra section. The Hydra section runs from `# Hydra Framework — Project Instructions` to the end of the file (it is always appended at the bottom by `/hydra-init`).
4. Trim any trailing blank lines left behind
5. If CLAUDE.md is now empty (only whitespace), delete the file entirely
6. If CLAUDE.md still has non-Hydra content, write it back with the Hydra section removed

### Step 9: Clean .gitignore

If `.gitignore` contains the Hydra local mode block:

1. Read `.gitignore`
2. Remove the block starting with `# Hydra Framework (local mode)` and the lines that follow it (`hydra/`, `.claude/agents/generated/`, `.mcp.json`)
3. Trim any extra blank lines left behind
4. If `.gitignore` is now empty, delete it
5. Otherwise write it back

### Step 10: Output Summary

```
Hydra Clean Complete
═══════════════════════════════════════════════════════

Removed:
  hydra/                        [DELETED | was not present]
  .claude/agents/generated/     [DELETED (N files) | was not present]
  .mcp.json hydra entry         [REMOVED | was not present]
  .claude/settings.json entries [CLEANED | was not present]
  CLAUDE.md hydra section       [REMOVED | was not present]
  .gitignore hydra entries      [REMOVED | was not present]

Hydra has been fully removed from this project.
To reinstall: /hydra-init
```
