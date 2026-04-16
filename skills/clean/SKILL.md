---
name: nazgul:clean
description: Fully remove Nazgul from a project — deletes all runtime state, generated agents, MCP config, permissions, CLAUDE.md injections, and gitignore entries. Use when user says "remove nazgul", "uninstall nazgul", "clean nazgul", or wants to completely undo /nazgul:init.
context: fork
allowed-tools: Read, Edit, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Clean

## Examples
- `/nazgul:clean` — Fully remove Nazgul from this project (with confirmation)
- `/nazgul:clean --force` — Remove without confirmation prompt

## Arguments
$ARGUMENTS

## Current State
- Nazgul initialized: !`test -f nazgul/config.json && echo "YES" || echo "NO"`
- Install mode: !`test -f nazgul/config.json && jq -r '.install_mode // "shared"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Tasks count: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Generated agents: !`ls .claude/agents/generated/*.md 2>/dev/null | wc -l | tr -d ' '`
- CLAUDE.md has nazgul section: !`grep -q "Nazgul Framework" CLAUDE.md 2>/dev/null && echo "YES" || echo "NO"`
- Gitignore has nazgul entries: !`grep -q "# Nazgul Framework (local mode)" .gitignore 2>/dev/null && echo "YES" || echo "NO"`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

Fully remove Nazgul from this project. No archiving — permanent deletion.

### Step 1: Check if Nazgul is Present

If none of the current state indicators show Nazgul presence (no config, no agents, no MCP entry, no CLAUDE.md section):
- Output: "Nazgul is not installed in this project. Nothing to clean."
- Stop here.

### Step 2: Parse Arguments

Check `$ARGUMENTS` for `--force` flag. If present, skip confirmation.

### Step 3: Confirm with User

Unless `--force` is present, show what will be removed, then use `AskUserQuestion` to confirm:

First, display a summary of what exists:
```
Nazgul Clean — Full Removal
═══════════════════════════════════════════════════════

The following will be PERMANENTLY DELETED:

  nazgul/                        [EXISTS | not found]
  .claude/agents/generated/     [N file(s) | not found]
  .claude/settings.json entries [EXISTS | not found]
  CLAUDE.md nazgul section       [EXISTS | not found]
  .gitignore nazgul entries      [EXISTS | not found]
```

Then use `AskUserQuestion`:
- header: "Confirm"
- question: "This cannot be undone. Remove all Nazgul files from this project?"
- options:
  - "Remove everything" — "Permanently delete all Nazgul runtime state, agents, and config"
  - "Abort" — "Cancel and keep everything as-is"

If Abort: stop immediately.

### Step 4: Remove Runtime State

Delete the entire `nazgul/` directory:

```bash
rm -rf nazgul/
```

### Step 5: Remove Generated Agents

Delete the `.claude/agents/generated/` directory (these are Nazgul-generated reviewer agents):

```bash
rm -rf .claude/agents/generated/
```

If `.claude/agents/` is now empty, remove it too. Do NOT remove `.claude/` itself as it may contain other settings.

### Step 6: Clean .claude/settings.json

If `.claude/settings.json` exists:

1. Read the file
2. Remove `enableAgentTeams` key if set to `true`
3. Use jq:
   ```bash
   jq 'del(.enableAgentTeams)' .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
   ```
4. If the file is now effectively empty (`{}` or only has empty arrays), delete it
5. If `.claude/` directory is now empty, remove it too. But be careful — check first.

### Step 7: Clean CLAUDE.md

If the project's `CLAUDE.md` contains a Nazgul-injected section:

1. Read `CLAUDE.md`
2. Look for the Nazgul section — it starts with `# Nazgul Framework — Project Instructions` (the content from `templates/CLAUDE.md.template`)
3. Remove everything from that header to the end of the Nazgul section. The Nazgul section runs from `# Nazgul Framework — Project Instructions` to the end of the file (it is always appended at the bottom by `/nazgul:init`).
4. Trim any trailing blank lines left behind
5. If CLAUDE.md is now empty (only whitespace), delete the file entirely
6. If CLAUDE.md still has non-Nazgul content, write it back with the Nazgul section removed

### Step 8: Clean .gitignore

If `.gitignore` contains the Nazgul local mode block:

1. Read `.gitignore`
2. Remove the block starting with `# Nazgul Framework (local mode)` and the lines that follow it (`nazgul/`, `.claude/agents/generated/`, `.mcp.json`)
3. Trim any extra blank lines left behind
4. If `.gitignore` is now empty, delete it
5. Otherwise write it back

### Step 9: Output Summary

```
Nazgul Clean Complete
═══════════════════════════════════════════════════════

Removed:
  nazgul/                        [DELETED | was not present]
  .claude/agents/generated/     [DELETED (N files) | was not present]
  .claude/settings.json entries [CLEANED | was not present]
  CLAUDE.md nazgul section       [REMOVED | was not present]
  .gitignore nazgul entries      [REMOVED | was not present]

Nazgul has been fully removed from this project.
To reinstall: /nazgul:init
```
