# Local Install Mode & Help Command — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `--local` flag to `/hydra:init` that gitignores all Hydra artifacts, and create a `/hydra:help` quick-reference skill.

**Architecture:** Two independent changes. (1) Modify `hydra-init` to accept `--local`, add gitignore entries, skip CLAUDE.md injection, and store the mode in config. (2) Create a new `hydra-help` skill with `disable-model-invocation: true` that prints a formatted reference card.

**Tech Stack:** Bash shell scripts, YAML frontmatter, jq for JSON, existing test framework (`tests/lib/assertions.sh`).

---

### Task 1: Add `install_mode` field to config template

**Files:**
- Modify: `templates/config.json` — add `install_mode` field
- Modify: `tests/test-config-schema.sh` — add assertion for new field

**Step 1: Write the failing test**

Add this assertion to `tests/test-config-schema.sh`, after the existing top-level field checks (after line 21):

```bash
assert_json_field "has .install_mode" "$CONFIG" ".install_mode" "shared"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-config-schema.sh`
Expected: FAIL on "has .install_mode"

**Step 3: Add the field to config template**

In `templates/config.json`, add `"install_mode": "shared"` as a top-level field after `"schema_version": 2`:

```json
{
  "schema_version": 2,
  "install_mode": "shared",
  "mode": "hitl",
  ...
}
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-config-schema.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add templates/config.json tests/test-config-schema.sh
git commit -m "feat(config): add install_mode field to config template"
```

---

### Task 2: Add `--local` flag handling to `/hydra:init`

**Files:**
- Modify: `skills/hydra:init/SKILL.md` — add `--local` argument parsing and gitignore step

**Step 1: Add `--local` to examples section**

In `skills/hydra:init/SKILL.md`, update the Examples section:

```markdown
## Examples
- `/hydra:init` — Initialize Hydra with default settings
- `/hydra:init --force` — Reinitialize, archiving current state first
- `/hydra:init --local` — Initialize in local mode (files not tracked in git)
- `/hydra:init --local --force` — Reinitialize in local mode
```

**Step 2: Add argument parsing after Step 0**

Insert a new section between Step 0 and Step 1:

```markdown
### Step 0.5: Parse Arguments
1. Check `$ARGUMENTS` for `--local` flag
2. If `--local` is present, set a variable `LOCAL_MODE=true`
3. Both `--local` and `--force` can be combined
```

**Step 3: Add gitignore step after Step 2 (directory creation)**

Insert a new step after Step 2 (Create Runtime Directory Structure):

```markdown
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
```

**Step 4: Make Step 5 (CLAUDE.md injection) conditional**

Update Step 5 to wrap in a conditional:

```markdown
### Step 5: Inject CLAUDE.md (Shared Mode Only)
If `LOCAL_MODE=true`:
- Skip this step entirely. The plugin's own CLAUDE.md provides instructions via the plugin system.
- Output: "Skipping CLAUDE.md injection (local mode)."

Otherwise (shared mode):
- [existing Step 5 content unchanged]
```

**Step 5: Update Step 4 summary to show install mode**

Add to the Step 4 display output:

```markdown
- Install mode: local (files not tracked in git) / shared (files tracked in git)
```

**Step 6: Run frontmatter test to verify skill still valid**

Run: `bash tests/test-frontmatter.sh`
Expected: PASS (skill still has valid frontmatter)

**Step 7: Commit**

```bash
git add skills/hydra:init/SKILL.md
git commit -m "feat(init): add --local flag for gitignored Hydra installation"
```

---

### Task 3: Create `/hydra:help` skill

**Files:**
- Create: `skills/hydra:help/SKILL.md` — the help quick-reference card

**Step 1: Write the failing test (frontmatter validation)**

The existing `tests/test-frontmatter.sh` automatically checks all skills in `skills/*/SKILL.md`. Creating the file with valid frontmatter will be validated by the existing test. First verify the test currently passes:

Run: `bash tests/test-frontmatter.sh`
Expected: PASS (baseline — no hydra-help yet)

**Step 2: Create the skill directory**

```bash
mkdir -p skills/hydra:help
```

**Step 3: Write the skill file**

Create `skills/hydra:help/SKILL.md`:

```markdown
---
name: hydra-help
description: Show Hydra quick reference — all commands, modes, and getting started guide. Use when user says "hydra help", "what commands", or needs orientation.
disable-model-invocation: true
allowed-tools: []
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Framework — Quick Reference

## Getting Started

| Command | Description |
|---------|-------------|
| `/hydra:init` | Set up Hydra for this project |
| `/hydra:init --local` | Set up without tracking files in git |
| `/hydra:init --force` | Reinitialize (archives current state) |

## Running

| Command | Description |
|---------|-------------|
| `/hydra:start` | Auto-detect state and continue work |
| `/hydra:start "objective"` | Start a specific objective |

**Flags for `/hydra:start`:** `--afk` (autonomous), `--yolo` (no reviews), `--hitl` (human-in-the-loop, default), `--max N` (iteration limit)

## Monitoring

| Command | Description |
|---------|-------------|
| `/hydra:status` | Loop progress, task counts, review board |
| `/hydra:log` | Iteration history, commits, reviews |
| `/hydra:task list` | List all tasks with status |

## Task Management

| Command | Description |
|---------|-------------|
| `/hydra:task add "desc"` | Add a new task |
| `/hydra:task skip <id>` | Skip a blocked task |
| `/hydra:task unblock <id>` | Unblock a task |
| `/hydra:task info <id>` | Show task details |
| `/hydra:task prioritize <id>` | Move task to top of queue |

## Control

| Command | Description |
|---------|-------------|
| `/hydra:pause` | Pause loop at next iteration boundary |
| `/hydra:reset` | Archive state and start fresh |
| `/hydra:review` | Manually trigger review for a task |

## Advanced

| Command | Description |
|---------|-------------|
| `/hydra:discover` | Re-run codebase discovery |
| `/hydra:context` | Collect context for an objective type |
| `/hydra:simplify` | Post-loop cleanup pass |
| `/hydra:docs` | View or regenerate project documents |
| `/hydra:board` | Connect to GitHub Projects / Azure DevOps |
| `/hydra:gen-spec` | Interactively build a project specification |

## Modes

| Mode | Description |
|------|-------------|
| `hitl` | **Human-in-the-loop** (default) — confirms before major actions |
| `afk` | **Autonomous** — runs unattended, commits per iteration |
| `yolo` | **Full auto** — no reviews, no confirmations, maximum speed |

## The 10 Rules

1. Always read `plan.md` first — the Recovery Pointer tells you where you are
2. Files are truth, context is ephemeral — write state to disk immediately
3. Follow existing patterns exactly — read before implementing
4. Tests are mandatory — run after every change
5. Never skip the review gate — ALL reviewers must approve
6. Address ALL blocking feedback — fix every REJECT item
7. One task at a time — unless using parallel Agent Teams
8. Update Recovery Pointer on every state change
9. Commit in AFK mode — every state transition gets a `hydra:` commit
10. HYDRA_COMPLETE means ALL tasks DONE and post-loop finished
```

**Step 4: Run frontmatter test to verify**

Run: `bash tests/test-frontmatter.sh`
Expected: PASS — new skill has valid frontmatter (name, description)

**Step 5: Commit**

```bash
git add skills/hydra:help/SKILL.md
git commit -m "feat(help): add /hydra:help quick reference command"
```

---

### Task 4: Update CLAUDE.md.template with help reference

**Files:**
- Modify: `templates/CLAUDE.md.template` — add `/hydra:help` to the commands list

**Step 1: Add help command to template**

In `templates/CLAUDE.md.template`, add to the Commands section (after the existing list):

```markdown
- `/hydra:help` — Quick reference for all commands and modes
```

**Step 2: Commit**

```bash
git add templates/CLAUDE.md.template
git commit -m "docs: add /hydra:help to CLAUDE.md template commands list"
```

---

### Task 5: Run full test suite

**Step 1: Run all tests**

Run: `bash tests/run-tests.sh`
Expected: All tests pass

**Step 2: If any failures, fix and re-run**

If failures occur, fix the specific issue and re-run the failing test with:
```bash
bash tests/run-tests.sh --filter=<test-name>
```

Then re-run the full suite to confirm no regressions.
