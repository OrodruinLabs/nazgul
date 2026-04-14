# Per-Stage Model Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users configure which AI model (Opus, Sonnet, Haiku) runs each pipeline stage, with balanced defaults and interactive configuration.

**Architecture:** Config-driven model routing. `nazgul/config.json` `models` section is the single source of truth. The start skill and orchestrator agents read it at runtime and pass the `model` parameter on every `Agent()` call. A new `/nazgul:config` skill provides interactive post-init configuration. Generated reviewer agents get `model:` in their frontmatter as a secondary layer.

**Tech Stack:** Markdown (SKILL.md, agent .md), JSON (config.json), Shell (tests), AskUserQuestion tool

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `skills/config/SKILL.md` | New `/nazgul:config` skill — view/change settings |
| Modify | `templates/config.json` | Update `models` defaults to balanced preset |
| Modify | `skills/init/SKILL.md` | Add model config question to Step 7 |
| Modify | `skills/start/SKILL.md` | Update defaults in model selection table |
| Modify | `agents/review-gate.md` | Update default model for reviewers |
| Modify | `agents/team-orchestrator.md` | Update default model for teams |
| Modify | `agents/discovery.md` | Add `model:` to generated reviewer frontmatter |
| Modify | `skills/help/SKILL.md` | Add `/nazgul:config` to command reference |
| Create | `tests/test-model-routing.sh` | Unit tests for config defaults and frontmatter |

---

### Task 1: Update config template with balanced defaults

**Files:**
- Modify: `templates/config.json:126-135`

- [ ] **Step 1: Update the models section defaults**

Change the `models` section in `templates/config.json` from the current defaults to the balanced preset:

```json
"models": {
  "planning": "opus",
  "discovery": "sonnet",
  "docs": "sonnet",
  "review": "sonnet",
  "implementation": "sonnet",
  "specialists": "sonnet",
  "post_loop": "haiku",
  "default": "sonnet"
}
```

The changes from current: `discovery` opus→sonnet, `docs` opus→sonnet, `review` opus→sonnet, `post_loop` sonnet→haiku.

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('templates/config.json'))"`
Expected: no output (success)

- [ ] **Step 3: Commit**

```bash
git add templates/config.json
git commit -m "update model defaults to balanced preset"
```

---

### Task 2: Update start skill model selection table

**Files:**
- Modify: `skills/start/SKILL.md:66-76`

- [ ] **Step 1: Update the model selection table defaults**

Change the defaults column in the Model Selection table to match the balanced preset:

```markdown
### Model Selection

Read `nazgul/config.json → models` to determine which model to assign each pipeline agent. When spawning agents via the Agent tool, pass the `model` parameter:

| Pipeline Agent    | Config Key              | Default  |
|-------------------|-------------------------|----------|
| Discovery         | `models.discovery`      | sonnet   |
| Doc Generator     | `models.docs`           | sonnet   |
| Planner           | `models.planning`       | opus     |
| Implementer       | `models.implementation` | sonnet   |
| Review Gate       | `models.review`         | sonnet   |

If the `models` section is missing from config.json, use `"sonnet"` as the fallback for all agents.
```

Also replace "Task tool" with "Agent tool" in the surrounding text if still present.

- [ ] **Step 2: Commit**

```bash
git add skills/start/SKILL.md
git commit -m "update start skill model defaults to balanced preset"
```

---

### Task 3: Update review-gate default model

**Files:**
- Modify: `agents/review-gate.md:75`

- [ ] **Step 1: Change the default model for reviewers**

On line 75, change the default from `"opus"` to `"sonnet"`:

```markdown
Read `nazgul/config.json → models.review` for the model to assign reviewers (default: `"sonnet"`). Pass this as the `model` parameter when spawning each reviewer via the Agent tool.
```

- [ ] **Step 2: Also update the post-loop agent default on line 222**

Change from `"sonnet"` to `"haiku"`:

```markdown
1. Run post-loop agents (documentation, release-manager, observability) if configured — use `models.post_loop` from `nazgul/config.json` as the `model` parameter (default: `"haiku"`)
```

- [ ] **Step 3: Commit**

```bash
git add agents/review-gate.md
git commit -m "update review-gate defaults to balanced preset"
```

---

### Task 4: Update team-orchestrator default models

**Files:**
- Modify: `agents/team-orchestrator.md:34,52`

- [ ] **Step 1: Change review team default from opus to sonnet**

On line 34, change:

```markdown
3. Read `nazgul/config.json → models.review` for the model to assign each reviewer teammate (default: `"sonnet"`). Pass this as the `model` parameter when spawning each teammate via the Agent tool.
```

- [ ] **Step 2: Verify implementation team default is already sonnet**

Line 52 should already say `"sonnet"` — confirm and leave unchanged.

- [ ] **Step 3: Commit**

```bash
git add agents/team-orchestrator.md
git commit -m "update team-orchestrator review default to sonnet"
```

---

### Task 5: Add model field to generated reviewer frontmatter

**Files:**
- Modify: `agents/discovery.md:762` (reviewer generation section)

- [ ] **Step 1: Add instruction to include model in reviewer frontmatter**

After the line "7. Write the generated reviewer to `.claude/agents/generated/[name].md`", add:

```markdown
8. Read `nazgul/config.json → models.review` (default: `"sonnet"`). Add `model: [value]` to the generated reviewer's YAML frontmatter, after the `name:` field.
```

- [ ] **Step 2: Also add model to the specialist template frontmatter**

In the specialist template section (around line 771), add `model:` to the frontmatter template:

```markdown
---
name: [specialist-name]
model: [read from nazgul/config.json → models.specialists, default: "sonnet"]
description: [one-line description tailored to this project]
tools:
  - Read
  - Write
  - Glob
  - Grep
  - Bash
maxTurns: 40
---
```

- [ ] **Step 3: Commit**

```bash
git add agents/discovery.md
git commit -m "add model field to generated reviewer and specialist frontmatter"
```

---

### Task 6: Add model configuration to init Step 7

**Files:**
- Modify: `skills/init/SKILL.md:114-137`

- [ ] **Step 1: Add model configuration question to Step 7**

After the existing Question 2 (Completion Notifications), add:

```markdown
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
```

- [ ] **Step 2: Update the AskUserQuestion call instruction**

Change "Call `AskUserQuestion` with both questions at once" to "Call `AskUserQuestion` with all three questions at once" (still within the 4-question limit).

- [ ] **Step 3: Commit**

```bash
git add skills/init/SKILL.md
git commit -m "add model configuration to init Step 7"
```

---

### Task 7: Create `/nazgul:config` skill

**Files:**
- Create: `skills/config/SKILL.md`

- [ ] **Step 1: Create the skill file**

```markdown
---
name: nazgul:config
description: View and change Nazgul settings — model assignments, formatter, notifications. Use when user says "configure nazgul", "change models", "nazgul settings", or wants to adjust config after init.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Nazgul Config

## Examples
- `/nazgul:config` — View current settings and change any of them
- `/nazgul:config models` — Jump directly to model assignment configuration

## Pre-flight

1. Check if `nazgul/config.json` exists. If not: "Nazgul not initialized. Run `/nazgul:init` first." and STOP.

## Step 1: Display Current Settings

Read `nazgul/config.json` and display:

```
─── ◈ NAZGUL ▸ CONFIGURATION ───────────────────────────
```

```
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
   jq '.models.planning = "opus" | .models.discovery = "sonnet" | ...' nazgul/config.json > tmp && mv tmp nazgul/config.json
   ```

5. Update `model:` field in generated reviewer agents:
   - Glob for `.claude/agents/generated/*.md`
   - For each file: if `model:` line exists in frontmatter, replace the value; if not, add `model: [models.review]` after the `name:` line

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

Same as init Step 7 Question 2. Use `AskUserQuestion`:
- header: "Notify"
- question: "Notify when the loop completes?"
- options:
  - "Voice alert" — platform default command
  - "Silent" — "No notification"
- Update `nazgul/config.json → notifications.on_complete`
```

- [ ] **Step 2: Commit**

```bash
git add skills/config/SKILL.md
git commit -m "feat: add /nazgul:config skill for post-init settings"
```

---

### Task 8: Add /nazgul:config to help skill

**Files:**
- Modify: `skills/help/SKILL.md`

- [ ] **Step 1: Add config to the command table**

Find the commands table in help skill and add a row for `/nazgul:config`:

```markdown
| `/nazgul:config` | View and change settings (models, formatter, notifications) |
```

Place it near the other utility commands (after `/nazgul:board` or similar).

- [ ] **Step 2: Commit**

```bash
git add skills/help/SKILL.md
git commit -m "add /nazgul:config to help command reference"
```

---

### Task 9: Write unit tests

**Files:**
- Create: `tests/test-model-routing.sh`

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/setup.sh"
source "$(dirname "$0")/lib/assertions.sh"

# ── Test: config template has balanced defaults ──────────
test_config_template_balanced_defaults() {
  local config
  config=$(cat templates/config.json)

  assert_equal "$(echo "$config" | jq -r '.models.planning')" "opus" \
    "planning should default to opus"
  assert_equal "$(echo "$config" | jq -r '.models.discovery')" "sonnet" \
    "discovery should default to sonnet"
  assert_equal "$(echo "$config" | jq -r '.models.docs')" "sonnet" \
    "docs should default to sonnet"
  assert_equal "$(echo "$config" | jq -r '.models.review')" "sonnet" \
    "review should default to sonnet"
  assert_equal "$(echo "$config" | jq -r '.models.implementation')" "sonnet" \
    "implementation should default to sonnet"
  assert_equal "$(echo "$config" | jq -r '.models.specialists')" "sonnet" \
    "specialists should default to sonnet"
  assert_equal "$(echo "$config" | jq -r '.models.post_loop')" "haiku" \
    "post_loop should default to haiku"
  assert_equal "$(echo "$config" | jq -r '.models.default')" "sonnet" \
    "default should be sonnet"
}

# ── Test: all model values are valid ──────────────────────
test_config_model_values_valid() {
  local valid_models=("opus" "sonnet" "haiku" "inherit")
  local config
  config=$(cat templates/config.json)

  for key in planning discovery docs review implementation specialists post_loop default; do
    local value
    value=$(echo "$config" | jq -r ".models.$key")
    local found=false
    for valid in "${valid_models[@]}"; do
      if [[ "$value" == "$valid" ]]; then
        found=true
        break
      fi
    done
    assert_true "$found" "models.$key value '$value' should be one of: ${valid_models[*]}"
  done
}

# ── Test: config template models section has all required keys ──
test_config_models_has_all_keys() {
  local config
  config=$(cat templates/config.json)
  local required_keys=("planning" "discovery" "docs" "review" "implementation" "specialists" "post_loop" "default")

  for key in "${required_keys[@]}"; do
    local value
    value=$(echo "$config" | jq -r ".models.$key")
    assert_not_equal "$value" "null" "models.$key should exist in config template"
  done
}

# ── Test: config skill exists with correct frontmatter ────
test_config_skill_exists() {
  assert_file_exists "skills/config/SKILL.md" "config skill should exist"

  local name
  name=$(head -10 skills/config/SKILL.md | grep "^name:" | sed 's/name: *//')
  assert_equal "$name" "nazgul:config" "skill name should be nazgul:config"

  local tools
  tools=$(head -10 skills/config/SKILL.md | grep "allowed-tools:")
  assert_contains "$tools" "AskUserQuestion" "config skill should have AskUserQuestion in allowed-tools"
}

# ── Test: discovery agent mentions model in reviewer generation ──
test_discovery_generates_model_in_reviewers() {
  local discovery
  discovery=$(cat agents/discovery.md)
  assert_contains "$discovery" "model:" "discovery should mention model: in reviewer generation"
  assert_contains "$discovery" "models.review" "discovery should reference models.review config key"
}

# ── Test: help skill lists config command ─────────────────
test_help_lists_config() {
  local help
  help=$(cat skills/help/SKILL.md)
  assert_contains "$help" "nazgul:config" "help should list /nazgul:config"
}

# ── Run ───────────────────────────────────────────────────
run_tests
```

- [ ] **Step 2: Make test executable**

Run: `chmod +x tests/test-model-routing.sh`

- [ ] **Step 3: Run the tests (expect failures — tests written before implementation)**

Run: `bash tests/test-model-routing.sh`
Expected: Some tests pass (config template may already partially match), others fail (config skill doesn't exist yet). This validates the test harness works.

- [ ] **Step 4: Commit**

```bash
git add tests/test-model-routing.sh
git commit -m "test: add model routing unit tests"
```

---

### Task 10: Run all tests and verify

**Files:**
- None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/run-tests.sh`
Expected: All tests pass, including the new model routing tests.

- [ ] **Step 2: Run the model routing tests specifically**

Run: `bash tests/test-model-routing.sh`
Expected: All 6 tests pass.

- [ ] **Step 3: Verify config.json is valid JSON**

Run: `python3 -c "import json; json.load(open('templates/config.json')); print('OK')"`
Expected: `OK`

- [ ] **Step 4: Final commit with version bump**

Update `plugin.json` version to `1.2.0`, update README badge, update CHANGELOG.md, then commit:

```bash
git add .claude-plugin/plugin.json README.md CHANGELOG.md
git commit -m "v1.2.0: per-stage model routing and /nazgul:config"
```
