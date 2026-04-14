---
name: nazgul:enhance
description: Research latest Claude Code features and propose Nazgul improvements. Use periodically to keep Nazgul aligned with new platform capabilities. Run with `/loop 2w /nazgul:enhance` for auto-recurring checks.
context: fork
allowed-tools: Read, Bash, Glob, Grep, WebSearch, WebFetch
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Nazgul Enhance

## Examples
- `/nazgul:enhance` — Research latest Claude Code features and propose Nazgul improvements
- `/loop 2w /nazgul:enhance` — Auto-check every 2 weeks for new enhancement opportunities

## Current Nazgul Capabilities

### Plugin Version
- Version: !`jq -r '.version // "unknown"' .claude-plugin/plugin.json 2>/dev/null || echo "unknown"`

### Registered Hooks
- Hook types: !`jq -r '.hooks | keys | join(", ")' hooks/hooks.json 2>/dev/null || echo "unknown"`

### Skills Inventory
- Skills: !`ls -1 skills/ 2>/dev/null | tr '\n' ', ' | sed 's/,$//'`

### Agents Inventory
- Pipeline agents: !`ls -1 agents/*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ', ' | sed 's/,$//'`
- Reviewer templates: !`ls -1 agents/templates/*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ', ' | sed 's/,$//'`

### Config Schema
- Schema version: !`jq -r '.schema_version // "unknown"' templates/config.json 2>/dev/null || echo "unknown"`
- Config sections: !`jq -r 'keys | join(", ")' templates/config.json 2>/dev/null || echo "unknown"`

### Hook Scripts
- Scripts: !`ls -1 scripts/*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' ', ' | sed 's/,$//'`

### Agent Tools Used
- Implementer tools: !`sed -n '/^tools:/,/^[^ -]/p' agents/implementer.md 2>/dev/null | grep '  - ' | sed 's/  - //' | tr '\n' ', ' | sed 's/,$//'`
- Team orchestrator tools: !`sed -n '/^tools:/,/^[^ -]/p' agents/team-orchestrator.md 2>/dev/null | grep '  - ' | sed 's/  - //' | tr '\n' ', ' | sed 's/,$//'`

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, and display patterns defined there.

### Phase 1: Inventory Current Capabilities

Using the preprocessor data above, build an internal capability map:
- Which hook lifecycle events does Nazgul handle? (Stop, PreCompact, PreToolUse, PostToolUse, SessionStart, SessionEnd — anything missing?)
- Which Claude Code tools do agents currently use? (Check allowed-tools in agent frontmatter)
- What config options exist? (Check templates/config.json sections)
- What scripts handle automation? (Check scripts/ directory)

### Phase 2: Research Claude Code Releases

Search for the latest Claude Code features and changes. Use these searches:

1. `WebSearch` for "Claude Code changelog 2026" and "Claude Code new features"
2. `WebSearch` for "Claude Code hooks reference" and "Claude Code agent teams"
3. `WebFetch` the official docs if URLs are found
4. `WebSearch` for "Anthropic Claude Code release notes"

Focus on:
- New hook types (e.g., PostCompact, Elicitation hooks, HTTP hooks)
- New tools available to agents (e.g., ExitWorktree, EnterWorktree)
- New configuration options (e.g., worktree sparse paths, session naming)
- New agent/skill capabilities (e.g., /loop, /plan with description)
- Performance features (e.g., fast mode, server-side compaction)
- New MCP integrations

### Phase 3: Gap Analysis

Compare discovered features against the capability inventory. For each gap, classify impact:

| Impact | Criteria |
|--------|----------|
| HIGH   | Improves core loop reliability OR enables capability Nazgul can't do today |
| MEDIUM | Improves performance/UX without new capability |
| LOW    | Already handled by Nazgul's own implementation OR not applicable |

### Phase 4: Output Enhancement Proposal

Output a structured report:

```
─── ◈ NAZGUL ▸ ENHANCING ─────────────────────────────

Enhancement Proposals
═══════════════════════════════════════

Current State
─────────────────────────────────────
Plugin version:    [version]
Schema version:    [version]
Hook types:        [count] registered
Skills:            [count] active
Agents:            [count] defined

New Features Discovered
─────────────────────────────────────

◆ [HIGH] Feature Name
  Source:    Claude Code vX.Y.Z (YYYY-MM-DD)
  Status:   Not implemented / Partially implemented
  Proposal: [What to do]
  Files:    [Which Nazgul files to modify]
  Effort:   Trivial / Moderate / Significant

◆ [MEDIUM] Feature Name
  ...

◇ [LOW] Feature Name
  ...

─── ◈ NEXT ─────────────────────────────────────────────
  Run `/nazgul:start "integrate [feature]"` to implement
  Or `/loop 2w /nazgul:enhance` for recurring checks
────────────────────────────────────────────────────────
```

### Important Notes

- This skill is READ-ONLY. It does NOT modify Nazgul files.
- It produces proposals for the user to act on.
- When run via `/loop`, it auto-checks periodically without user intervention.
- Focus on actionable, specific proposals — not vague suggestions.
- Always check if a feature is already handled by Nazgul before proposing it.
