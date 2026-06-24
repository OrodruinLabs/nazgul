---
name: "nazgul:config"
description: View and change Nazgul settings — model assignments, formatter, notifications. Use when user says "configure nazgul", "change models", "nazgul settings", or wants to adjust config after init.
argument-hint: "[models]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
  version: 2.1.0
---

# Nazgul Config

## Examples
- `/nazgul:config` — View current settings and change any of them
- `/nazgul:config models` — Jump directly to model assignment configuration

## Arguments
$ARGUMENTS

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
Default mode:      [default_mode || "ask each run"]

Review:
  Granularity:     [review_gate.granularity || "task"]
  Require all approve: [review_gate.require_all_approve]
  Confidence threshold: [review_gate.confidence_threshold]
  Max retries/unit:  [review_gate.max_retries_per_task]
  Block on security reject: [review_gate.block_on_security_reject]

Guards:
  Lean comments:     [guards.lean_comments != false ? "on" : "off"] (max run: [guards.max_consecutive_comment_lines || 2])
```

## Step 2: Ask What to Change

If the `## Arguments` block above contains the token `models`, skip directly to the Model Assignment sub-flow.

Otherwise, use `AskUserQuestion` (multiSelect: true):
- header: "Settings"
- question: "What would you like to change?"
- options:
  - "Model assignments" — "Configure which AI model runs each pipeline stage"
  - "Formatter" — "Enable or disable auto-formatting after edits"
  - "Notifications" — "Configure completion notifications"
  - "Default run mode" — "Set the mode /nazgul:start uses when no flag is passed (or clear it to be asked each time)"
  - "Review granularity" — "Choose whether the review board fires per task, per parallel group, or once per feature"
  - "Lean comments guard" — "Toggle the deterministic comment-bloat guard, or tune the max consecutive comment-line run"

## Step 3: Run Selected Sub-flows

### Lean Comments Guard Sub-flow

1. `AskUserQuestion`:
   - header: "Lean comments"
   - question: "Comment-bloat guard (blocks banners, restating comment runs, and `<remarks>`/multi-paragraph docs on non-public members at write time)?"
   - options:
     - "On (default)" — "Block comment bloat in source writes and reject it in review"
     - "Off" — "Opt out — the guard becomes a no-op for this project"
2. Write the choice: `jq '.guards.lean_comments = (<true|false>)' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json` (substitute `true`/`false`; do NOT run the placeholder verbatim).
3. If the user wants to tune the threshold, write the integer to `guards.max_consecutive_comment_lines` the same way (default `2` = runs of 3+ are blocked).

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

### Default Run Mode Sub-flow

1. `AskUserQuestion`:
   - header: "Default mode"
   - question: "What mode should /nazgul:start use when you don't pass a flag?"
   - options:
     - "Ask each run (Recommended)" — "No default; /nazgul:start prompts for mode each time"
     - "HITL" — "Review each step"
     - "AFK" — "Autonomous; pauses on risky decisions"
     - "YOLO" — "Fully autonomous; no permission prompts (start still confirms YOLO each run)"

2. Write the choice to config: `"Ask each run"` → `null`, otherwise the lowercase mode string:
   ```bash
   jq '.default_mode=<value>' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```
   (use `null` unquoted for "Ask each run", e.g. `jq '.default_mode=null' …`).

### Review Granularity Sub-flow

1. `AskUserQuestion`:
   - header: "Review unit"
   - question: "When should the review board run?"
   - options:
     - "Per task (Recommended)" — "Review each task the moment it reaches IMPLEMENTED (current default)"
     - "Per group" — "Review once per planner-defined parallel wave/group, over that group's combined diff"
     - "Per feature" — "Implement ALL tasks to IMPLEMENTED, then ONE review over the whole feature diff (base..HEAD)"

2. Write the **selected** lowercase value to `review_gate.granularity` (`task` | `group` | `feature`) — substitute the user's choice; do NOT run the placeholder verbatim:
   ```bash
   jq --arg g "<task|group|feature>" '.review_gate.granularity = $g' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```

3. Note for the user: `group`/`feature` defer review until the unit is fully implemented. All other review settings — `require_all_approve`, `confidence_threshold`, `block_on_security_reject` — still apply in every mode; `max_retries_per_task` is counted **per review unit** (task/group/feature), and in group/feature mode a CHANGES_REQUESTED re-opens only the tasks whose files own the findings, not the whole unit. Takes effect on the next pipeline run.
