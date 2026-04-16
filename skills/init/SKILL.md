---
name: nazgul:init
description: Initialize Nazgul for a project — check prerequisites, run discovery, create runtime directories, generate reviewer agents. Use when setting up Nazgul for the first time, user says "initialize nazgul", "set up nazgul", or before running any other Nazgul commands.
context: fork
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, ToolSearch
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Init

## Examples
- `/nazgul:init` — Initialize Nazgul with default settings
- `/nazgul:init --force` — Reinitialize, archiving current state first
- `/nazgul:init --local` — Initialize in local mode (files not tracked in git)
- `/nazgul:init --local --force` — Reinitialize in local mode

## Prerequisites Check
- jq installed: !`which jq 2>/dev/null && echo "YES" || echo "NO — install jq first: brew install jq (macOS) or apt install jq (Linux)"`
- Git repo: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "YES" || echo "NO — initialize a git repo first"`

## Companion Plugins Check
- security-guidance: !`ls ~/.claude/plugins/security-guidance 2>/dev/null && echo "INSTALLED" || echo "NOT INSTALLED — recommended: claude plugin install security-guidance"`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

Initialize the Nazgul Framework for this project:

### Step 0: Idempotency Check
1. Check if `nazgul/config.json` already exists
2. If it exists, warn the user: "Nazgul is already initialized for this project. Use `--force` to reinitialize (current state will be archived)."
3. If `--force` was passed (check $ARGUMENTS), archive current state to `nazgul/archive/` first, then proceed
4. If neither --force nor fresh: STOP here

### Step 0.5: Parse Arguments
1. Check `$ARGUMENTS` for `--local` flag
2. If `--local` is present, set a variable `LOCAL_MODE=true`
3. Both `--local` and `--force` can be combined

### Step 1: Check Prerequisites
1. Verify `jq` is installed (required for hook scripts). If jq is NOT installed, output: "REQUIRED: jq is not installed. Install it first: `brew install jq` (macOS) or `apt install jq` (Linux). Nazgul cannot function without jq." — STOP, do not proceed with initialization.
2. Verify this is a git repository
3. Check for companion plugins and suggest if missing:
   - security-guidance (ESSENTIAL — real-time code vulnerability detection)
   - frontend-design (recommended if frontend project)

### Step 2: Create Runtime Directory Structure
Create the following directories and files:
```
nazgul/
├── config.json          # Copy from plugin templates/config.json
├── plan.md              # Copy from plugin templates/plan.md
├── tasks/               # Empty, for task manifests
├── checkpoints/         # Empty, for iteration checkpoints
├── reviews/             # Empty, for review artifacts
├── context/             # Will be filled by Discovery
├── docs/                # Will be filled by Doc Generator
└── logs/                # Empty, for iteration logs
```

### Step 2.5: Configure Git Ignore (Local Mode Only)
If `LOCAL_MODE=true`:

1. Read or create `.gitignore` at the project root
2. Check if `# Nazgul Framework (local mode)` marker already exists
3. If marker is NOT present, append:
   ```
   # Nazgul Framework (local mode)
   nazgul/
   .claude/agents/generated/
   .mcp.json
   ```
4. Set `install_mode` to `"local"` in the config:
   ```bash
   jq '.install_mode = "local"' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```

### Step 3: Run Discovery
Delegate to the Discovery agent to scan the codebase:
1. Generate project context files in `nazgul/context/`
2. Generate tailored reviewer agents in `.claude/agents/generated/`
3. Update `nazgul/config.json` with discovered project settings

### Step 4: Display Summary
Show the user:
- Project profile summary (language, framework, key dependencies)
- Number of files scanned
- Reviewer board generated (list all reviewer agents)
- Companion plugin status
- Install mode: local (files not tracked in git) / shared (files tracked in git)
- Next step: `/nazgul:start "your objective"`

### Step 5: Inject CLAUDE.md (Shared Mode Only)
If `LOCAL_MODE=true`:
- Skip this step entirely. The plugin's own CLAUDE.md provides instructions via the plugin system.
- Output: "Skipping CLAUDE.md injection (local mode)."

Otherwise (shared mode):
If the project doesn't already have Nazgul instructions in CLAUDE.md:
- Append the Nazgul section from `templates/CLAUDE.md.template`
- Or create CLAUDE.md if it doesn't exist

### Step 6: Enable Agent Teams & Permissions
Ensure Agent Teams is configured for this project.

Read `.claude/settings.json` (or start with `{}`), then merge:

1. **`enableAgentTeams`**: set to `true` if missing

Write the merged result back. If already present, skip (no-op).

### Step 7: Optional Features Prompt

Use `AskUserQuestion` to ask about optional features. Store preferences in `nazgul/config.json`.

Call `AskUserQuestion` with all three questions at once (up to 4 questions supported):

**Question 1 — Auto-Formatter:**
- header: "Formatter"
- question: "Auto-format files after edits?"
- options:
  - "Yes" — "Run prettier/ruff/gofmt/etc. automatically based on file type"
  - "No (Recommended)" — "Skip auto-formatting, handle it manually"
- If Yes: set `formatter.enabled: true` in config.json
- If No: set `formatter.enabled: false`

**Question 2 — Completion Notifications:**
- header: "Notify"
- question: "Notify when the loop completes?"
- options:
  - "Voice alert (Recommended)" — platform default: `say 'Nazgul loop complete'` (macOS) or `notify-send 'Nazgul' 'Loop complete'` (Linux)
  - "Silent" — "No notification when the loop finishes"
- If Voice alert: set `notifications.on_complete` to the platform-appropriate command
- If Silent: leave `notifications` section empty
- If Other (custom command): set `notifications.on_complete` to the user's command

**Question 3 — Model Assignments:**
- header: "Models"
- question: "Customize model assignments per pipeline stage?"
- options:
  - "Use defaults (Recommended)" — "Opus for planning, Sonnet for implementation/review, Haiku for post-loop"
  - "Customize" — "Choose a model for each pipeline stage"
- If Use defaults: write the balanced preset to `nazgul/config.json → models`
- If Customize: run the model assignment sub-flow:

**Model assignment sub-flow (only if Customize selected):**

1. `AskUserQuestion`:
   - header: "Models"
   - question: "Use a preset or pick per stage?"
   - options:
     - "Balanced" — "Opus planning, Sonnet implementation/review, Haiku post-loop"
     - "Quality" — "Opus for everything"
     - "Fast/cheap" — "Haiku for docs/review/post-loop, Sonnet for planning/implementation"
     - "Per stage" — "Pick individually"

2. If "Per stage": call `AskUserQuestion` twice (4 questions max per call):
   - **Batch 1** (header per question: stage name):
     - "Planning?" → Opus (Recommended) / Sonnet / Haiku
     - "Discovery?" → Opus / Sonnet (Recommended) / Haiku
     - "Docs?" → Opus / Sonnet (Recommended) / Haiku
     - "Review?" → Opus / Sonnet (Recommended) / Haiku
   - **Batch 2:**
     - "Implementation?" → Opus / Sonnet (Recommended) / Haiku
     - "Specialists?" → Opus / Sonnet (Recommended) / Haiku
     - "Post-loop?" → Opus / Sonnet / Haiku (Recommended)

3. Write selected models to `nazgul/config.json → models`

**Presets map:**
- Balanced: `{ planning: "opus", discovery: "sonnet", docs: "sonnet", review: "sonnet", implementation: "sonnet", specialists: "sonnet", post_loop: "haiku", default: "sonnet" }`
- Quality: `{ planning: "opus", discovery: "opus", docs: "opus", review: "opus", implementation: "opus", specialists: "opus", post_loop: "opus", default: "opus" }`
- Fast/cheap: `{ planning: "sonnet", discovery: "haiku", docs: "haiku", review: "haiku", implementation: "sonnet", specialists: "sonnet", post_loop: "haiku", default: "haiku" }`
