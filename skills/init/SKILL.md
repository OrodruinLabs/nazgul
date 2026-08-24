---
name: nazgul:init
description: Initialize Nazgul for a project — check prerequisites, run discovery, create runtime directories, generate reviewer agents. Use when setting up Nazgul for the first time, user says "initialize nazgul", "set up nazgul", or before running any other Nazgul commands.
disable-model-invocation: true
argument-hint: "[--local] [--force]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, ToolSearch
metadata:
  author: Jose Mejia
---

# Nazgul Init

## Examples
- `/nazgul:init` — Initialize Nazgul with default settings
- `/nazgul:init --force` — Reinitialize, archiving current state first
- `/nazgul:init --local` — Initialize in local mode (files not tracked in git)
- `/nazgul:init --local --force` — Reinitialize in local mode

## Arguments
$ARGUMENTS

## Prerequisites Check
- jq installed: !`which jq 2>/dev/null && echo "YES" || echo "NO — install jq first: brew install jq (macOS) or apt install jq (Linux)"`
- Git repo: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "YES" || echo "NO — initialize a git repo first"`

## Companion Plugins Check
- security-guidance: !`ls ~/.claude/plugins/security-guidance 2>/dev/null && echo "INSTALLED" || echo "NOT INSTALLED — recommended: claude plugin install security-guidance"`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

Initialize the Nazgul Framework for this project:

### Step 0: Parse Arguments
This runs FIRST, before any branching, so every later step shares one parsed decision.
1. Read the `## Arguments` block above — that is the literal argument string the user typed (it may be empty).
2. Determine two flags from that string:
   - `LOCAL_MODE` = true if and only if the arguments contain the token `--local`, otherwise false.
   - `FORCE` = true if and only if the arguments contain the token `--force`, otherwise false.
   - Both flags are independent and can be combined.
3. **Emit this exact line to the user before doing anything else** (substitute the real values):
   `Parsed arguments: "<contents of the Arguments block, or (none) if empty>". LOCAL_MODE = <true|false>. FORCE = <true|false>.`
4. Backstop: if the `## Arguments` block above contains the literal text `$ARGUMENTS` (i.e. the placeholder was not substituted), argument substitution is broken — STOP and report: "Skill argument substitution failed — this is a plugin bug, do not proceed." Otherwise continue.
5. Carry `LOCAL_MODE` and `FORCE` forward as decided here; every later step that branches on them MUST use these values, not re-derive them.

### Step 0.5: Idempotency Check
1. Check if `nazgul/config.json` already exists
2. If it exists, warn the user: "Nazgul is already initialized for this project. Use `--force` to reinitialize (current state will be archived)."
3. If `FORCE` is true (from Step 0), archive current state to `nazgul/archive/` first, then proceed
4. If `FORCE` is false and Nazgul is already initialized: STOP here

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
├── logs/                # Empty, for iteration logs
└── learning/            # Empty, for autolearning registry and working files
```

### Step 2.5: Configure Git Ignore
This step ALWAYS runs, with two branches based on `LOCAL_MODE` (from Step 0). Read or create `.gitignore` at the project root.

There are exactly two Nazgul `.gitignore` blocks, each identified by its **exact first-line marker** (match this line exactly when detecting/removing/idempotency-checking — do not match on the descriptive comment lines):
- local mode → marker `# Nazgul Framework (local mode)`
- shared mode → marker `# Nazgul Framework — ephemeral runtime`

**Mode-switch safety (do this in BOTH branches first):** remove the *opposite* mode's block if present, before appending this mode's. Otherwise a stale block conflicts — e.g. a leftover local-mode block ignores the whole `nazgul/` tree and would prevent shared mode from tracking the decision record. Removing a block means deleting its marker line and the lines under it up to the next blank line / comment.

**If `LOCAL_MODE=true` (local mode — nothing tracked in git):**
1. Remove the shared-mode block (marker `# Nazgul Framework — ephemeral runtime`) if present.
2. If the `# Nazgul Framework (local mode)` marker is NOT already present, append:
   ```gitignore
   # Nazgul Framework (local mode)
   nazgul/
   .claude/agents/generated/
   .mcp.json
   ```
3. Set `install_mode` to `"local"`:
   ```bash
   jq '.install_mode = "local"' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```

**Otherwise (shared mode — track the decision record, ignore the ephemeral journal):**
The decision record (`config.json`, `plan.md`, `tasks/`, `reviews/`, `docs/`, `context/`, generated agents) stays tracked so teammates can resume the loop from a clone. Only regenerable, machine-local journal files are ignored.
1. Remove the local-mode block (marker `# Nazgul Framework (local mode)`) if present.
2. If the `# Nazgul Framework — ephemeral runtime` marker is NOT already present, append (the marker is the FIRST line exactly; the second line is a descriptive comment):
   ```gitignore
   # Nazgul Framework — ephemeral runtime
   # (regenerable, machine-local — safe to delete; not shared across teammates)
   nazgul/checkpoints/
   nazgul/logs/
   nazgul/sessions/
   nazgul/.session_id
   nazgul/.compaction_count
   nazgul/archive/
   # Per-dispatch markers, written at PreToolUse(Agent) and cleared at SubagentStop; the trailing slash also covers in-flight/quarantine/
   nazgul/in-flight/
   # Transient mkdir mutual-exclusion dirs; meaningless off their own machine
   nazgul/locks/
   # The heartbeat tick lock (scripts/heartbeat.sh:40,63); likewise meaningless off its own machine
   nazgul/.heartbeat.lock
   # Generated from scripts/git-hooks/ at install (scripts/lib/git-hooks.sh:16,128); committing it commits a stale copy of shipped code
   nazgul/.githooks/
   # Per-dispatch report manifests; per-session
   nazgul/dispatch/
   # Per-run self-rating JSON (scripts/file-improvement-report.sh:11)
   nazgul/improvement-reports/
   # A per-machine log-offset cursor (scripts/self-audit.sh:169)
   nazgul/self-audit-window.json
   # A transient approval marker (scripts/stop-hook.sh:1823)
   nazgul/.hitl-pending
   # Exists only between a jq ... > rewrite of config.json and its mv
   nazgul/config.json.tmp
   # Local-only work queue; the GitHub board is the durable, shareable copy (CLAUDE.md Backlog Rule, whose --check enforcement is what makes that safe)
   nazgul/inbox/
   # Per-session pause note, written only by skills/pause/SKILL.md; machine-local
   nazgul/HANDOFF.md
   # Operator-ruled ephemeral: ~420 KB, append-only across objectives, and NOT regenerable
   # The recorded consequence, not an oversight: in shared mode the self-audit backlog does not reach teammates
   nazgul/improvements.md
   nazgul/reviews/*/test-failures.md
   nazgul/reviews/*/simplify-report.md
   nazgul/reviews/*/diff.patch
   nazgul/reviews/post-loop-simplify-report.md
   # Transient autolearning working files (registry + declines stay tracked)
   nazgul/learning/proposed-rules.md
   nazgul/learning/.last-run
   ```
3. Set `install_mode` to `"shared"`:
   ```bash
   jq '.install_mode = "shared"' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```
4. If this is a reinitialization (`--force`) of a project that already committed the ephemeral paths, tell the user they can stop tracking them with the one-shot in Step 4's summary.

### Step 3: Run Discovery
Dispatch via the `Agent` tool with `subagent_type: "nazgul:discovery"` — **do not pass a `name`/`-n` parameter.** Naming an `Agent`-tool dispatch folds it into team/roster infrastructure even without an explicit team spawn (ADR-017); discovery is one-shot work (scan, write, return), so it stays on the unnamed one-shot subagent primitive.

**The brief MUST open with the runtime-state root.** `agents/discovery.md`'s input contract (RULES.md §21) says: no `<main_worktree_path>` in the brief, fall back to `branch.main_worktree_path`, otherwise STOP. At init time that config key is still `null` — it is written later by `create_feature_branch` under `/nazgul:start` — so a brief without the root leaves discovery no legal way to proceed. Resolve `ROOT` here instead, from this project's own checkout (`git rev-parse --show-toplevel` — the directory holding `nazgul/config.json`, not necessarily the cwd you were invoked from), and prepend these two lines to the brief, `$ROOT` expanded to the absolute path:

```text
Dispatch brief: <main_worktree_path> = /abs/path/to/project. Nazgul config: /abs/path/to/project/nazgul/config.json.
Address every runtime-state path under that root, absolute and verbatim — your cwd is not it.
```

The dispatch:
1. Generates project context files in `$ROOT/nazgul/context/`
2. Generates tailored reviewer agents in `$ROOT/.claude/agents/generated/`
3. Updates `$ROOT/nazgul/config.json` with discovered project settings

The dispatch is a single exchange — its return value is the summary Step 4 displays below. No `nazgul/dispatch/<name>.json` manifest is written for this call (it is not a teammate, so the Report Contract's Layer 2 does not apply); instead it inherits `SubagentStop`'s empty-return detection + bounded resume (RULES.md §19) automatically, with no extra instrumentation needed here.

### Step 4: Display Summary
Show the user:
- Project profile summary (language, framework, key dependencies)
- Number of files scanned
- Reviewer board generated (list all reviewer agents)
- Companion plugin status
- Install mode: local (whole `nazgul/` untracked) / shared (decision record tracked; ephemeral journal — checkpoints, logs, sessions, archive — gitignored)
- **Shared-mode reinitialization only:** if `git ls-files nazgul/checkpoints nazgul/logs nazgul/sessions nazgul/archive nazgul/.session_id nazgul/.compaction_count 'nazgul/reviews/*/test-failures.md' 'nazgul/reviews/*/simplify-report.md' 'nazgul/reviews/*/diff.patch' nazgul/reviews/post-loop-simplify-report.md 2>/dev/null` shows any already-tracked ephemeral paths, tell the user to stop tracking them (files stay on disk; `--ignore-unmatch` keeps the command safe when some paths aren't tracked). **`diff.patch` matters most here** — a committed, stale captured diff makes reviewers analyze old code and emit phantom findings:
  ```bash
  git rm -r --cached --ignore-unmatch nazgul/checkpoints nazgul/logs nazgul/sessions nazgul/archive \
    nazgul/.session_id nazgul/.compaction_count
  git rm --cached --ignore-unmatch -- 'nazgul/reviews/*/test-failures.md' 'nazgul/reviews/*/simplify-report.md' \
    'nazgul/reviews/*/diff.patch' nazgul/reviews/post-loop-simplify-report.md
  git commit -m "chore(nazgul): stop tracking ephemeral runtime state"
  ```
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

### Step 8: Advisory Suggestion

Print, unconditionally, after everything above: "Run /nazgul:doctor to verify your environment before starting the loop." This is a printed suggestion only — do not run doctor, do not read or branch on its result, and do not gate any part of initialization on it.
