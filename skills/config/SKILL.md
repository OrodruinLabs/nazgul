---
name: "nazgul:config"
description: View and change Nazgul settings — model assignments, formatter, notifications. Use when user says "configure nazgul", "change models", "nazgul settings", or wants to adjust config after init.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Nazgul Config

## Examples
- `/nazgul:config` — View current settings and change any of them
- `/nazgul:config models` — Jump directly to model assignment configuration

## Pre-flight

0. Load the `AskUserQuestion` tool (deferred by default): run `ToolSearch` with query `select:AskUserQuestion`. Do this BEFORE any step that uses `AskUserQuestion`.
1. Check if `nazgul/config.json` exists. If not: "Nazgul not initialized. Run `/nazgul:init` first." and STOP.

## Step 1: Display Current Settings

Read `nazgul/config.json` and display:

```text
─── ◈ NAZGUL ▸ CONFIGURATION ───────────────────────────
```

```text
Models:
  Planning:        [models.planning]
  Discovery:       [models.discovery]
  Docs:            [models.docs]
  Review:          [models.review]
  Implementation:  [models.implementation]
  Specialists:     [models.specialists]
  Post-loop:       [models.post_loop]
  Default:         [models.default]

Formatter:         [formatter.enabled ? "enabled" : "disabled"]
Notifications:     [notifications.on_complete || "disabled"]
```

## Step 2: Ask What to Change

If `$ARGUMENTS` contains "models", skip directly to the Model Assignment sub-flow.

Otherwise, use `AskUserQuestion` (multiSelect: true):
- header: "Settings"
- question: "What would you like to change?"
- options:
  - "Model assignments" — "Configure which AI model runs each pipeline stage"
  - "Formatter" — "Enable or disable auto-formatting after edits"
  - "Notifications" — "Configure completion notifications"

## Step 3: Run Selected Sub-flows

### Model Assignment Sub-flow

1. `AskUserQuestion`:
   - header: "Models"
   - question: "How would you like to configure models?"
   - options:
     - "Use a preset" — "Quick setup with predefined model assignments"
     - "Customize per stage" — "Pick a model for each pipeline stage individually"

2. **If preset**, use `AskUserQuestion`:
   - header: "Preset"
   - question: "Which model preset?"
   - options:
     - "Balanced (Recommended)" — "Opus for planning, Sonnet for implementation/review, Haiku for post-loop"
     - "Quality" — "Opus for everything — best results, highest cost"
     - "Fast/cheap" — "Haiku for docs/review/post-loop, Sonnet for planning/implementation"

   Preset values:
   - Balanced: `{ planning: "opus", discovery: "sonnet", docs: "sonnet", review: "sonnet", implementation: "sonnet", specialists: "sonnet", post_loop: "haiku", default: "sonnet" }`
   - Quality: `{ planning: "opus", discovery: "opus", docs: "opus", review: "opus", implementation: "opus", specialists: "opus", post_loop: "opus", default: "opus" }`
   - Fast/cheap: `{ planning: "sonnet", discovery: "haiku", docs: "haiku", review: "haiku", implementation: "sonnet", specialists: "sonnet", post_loop: "haiku", default: "haiku" }`

3. **If per-stage**, use `AskUserQuestion` in two batches:

   **Batch 1:**
   - "Which model for Planning?" (header: "Planning") → Opus (Recommended) / Sonnet / Haiku
   - "Which model for Discovery?" (header: "Discovery") → Opus / Sonnet (Recommended) / Haiku
   - "Which model for Docs?" (header: "Docs") → Opus / Sonnet (Recommended) / Haiku
   - "Which model for Review?" (header: "Review") → Opus / Sonnet (Recommended) / Haiku

   **Batch 2:**
   - "Which model for Implementation?" (header: "Implement") → Opus / Sonnet (Recommended) / Haiku
   - "Which model for Specialists?" (header: "Specialist") → Opus / Sonnet (Recommended) / Haiku
   - "Which model for Post-loop?" (header: "Post-loop") → Opus / Sonnet / Haiku (Recommended)

4. Update `nazgul/config.json → models` with the selected values using `jq`:
   ```bash
   jq '.models.planning = "opus" | .models.discovery = "sonnet" | ...' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```

5. Update `model:` field in generated agents by role:
   - Read `nazgul/config.json → agents.reviewers` and `agents.specialists` arrays
   - For each file in `.claude/agents/generated/*.md`, extract the agent name from frontmatter
   - If name appears in `agents.reviewers` → set `model: [models.review]`
   - If name appears in `agents.specialists` → set `model: [models.specialists]`

6. Display confirmation:
   ```
   ─── ◈ NAZGUL ▸ MODELS UPDATED ──────────────────────────

   Planning:        opus
   Discovery:       sonnet
   ...

   Changes take effect on the next pipeline run.
   ```

### Formatter Sub-flow

Same as init Step 7 Question 1. Use `AskUserQuestion`:
- header: "Formatter"
- question: "Auto-format files after edits?"
- options:
  - "Yes" — "Run prettier/ruff/gofmt/etc. automatically based on file type"
  - "No" — "Skip auto-formatting, handle it manually"
- Update `nazgul/config.json → formatter.enabled`

### Notifications Sub-flow

Use `AskUserQuestion`:
- header: "Notify"
- question: "Notify when the loop completes?"
- options:
  - "Voice alert (Recommended)" — platform default: `say 'Nazgul loop complete'` (macOS) or `notify-send 'Nazgul' 'Loop complete'` (Linux)
  - "Silent" — "No notification when the loop finishes"
- If Voice alert: set `nazgul/config.json → notifications.on_complete` to the platform-appropriate command
- If Silent: remove or empty `nazgul/config.json → notifications.on_complete`
- If Other (user selects the built-in "Other" free-text option): set `nazgul/config.json → notifications.on_complete` to the user's custom command
