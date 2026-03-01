# Review Gate Enforcement — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enforce the Hydra state machine with automated hooks so no task can be marked DONE without passing the review gate — making the Constitution's Article III and Rule 5 mechanically impossible to violate.

**Architecture:** Three-layer defense-in-depth: (1) PreToolUse hook blocks invalid state transitions at write-time, (2) stop-hook validates DONE tasks have review evidence each iteration, (3) Bash guard prevents agents from bypassing hooks via sed/echo. Each layer is independent — any single layer prevents the violation.

**Tech Stack:** Bash (POSIX-safe), jq for JSON parsing, Claude Code hooks API

---

### Task 1: Create task-state-guard.sh (Layer 1 — PreToolUse enforcement)

**Files:**
- Create: `scripts/task-state-guard.sh`
- Test: manual validation (Task 5)

**Step 1: Write the script skeleton with input parsing**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Hydra Task State Guard — enforces Constitution Article III state machine
# Intercepts Write/Edit on task manifests, validates status transitions
# Exit 0 = allow, Exit 2 = block with reason

# Read tool input from stdin (Claude Code passes JSON for PreToolUse hooks)
INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse JSON input with jq
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# Only guard task manifest files (hydra/tasks/TASK-NNN.md)
if ! echo "$FILE_PATH" | grep -qE 'hydra/tasks/TASK-[0-9]+\.md$'; then
  exit 0
fi
```

**Step 2: Add status extraction logic**

Extract the new status from the tool input (Edit's `new_string` or Write's `content`) and the old status from the file on disk.

```bash
# Extract new content being written
if [ "$TOOL_NAME" = "Edit" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
elif [ "$TOOL_NAME" = "Write" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
else
  exit 0
fi

# Check if this changes the Status field
NEW_STATUS=$(echo "$NEW_CONTENT" | sed -n 's/.*\*\*Status\*\*:[[:space:]]*\([A-Z_]*\).*/\1/p' | head -1)
if [ -z "$NEW_STATUS" ]; then
  # Not a status change — allow
  exit 0
fi

# Read current status from file on disk
OLD_STATUS=""
if [ -f "$FILE_PATH" ]; then
  OLD_STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$FILE_PATH" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
fi

# If file is new (first write), allow PLANNED or READY as initial status
if [ -z "$OLD_STATUS" ]; then
  if [ "$NEW_STATUS" = "PLANNED" ] || [ "$NEW_STATUS" = "READY" ]; then
    exit 0
  fi
  echo "HYDRA STATE GUARD: BLOCKED — New task must start as PLANNED or READY, not ${NEW_STATUS}" >&2
  exit 2
fi

# If status isn't actually changing, allow
if [ "$OLD_STATUS" = "$NEW_STATUS" ]; then
  exit 0
fi
```

**Step 3: Add state machine validation**

```bash
# --- ENFORCE STATE MACHINE (Constitution Article III) ---
valid_transition() {
  local from="$1"
  local to="$2"
  case "${from}_${to}" in
    PLANNED_READY)               return 0 ;;
    READY_IN_PROGRESS)           return 0 ;;
    IN_PROGRESS_IMPLEMENTED)     return 0 ;;
    IN_PROGRESS_BLOCKED)         return 0 ;;
    IMPLEMENTED_IN_REVIEW)       return 0 ;;
    IN_REVIEW_DONE)              return 0 ;;
    IN_REVIEW_CHANGES_REQUESTED) return 0 ;;
    IN_REVIEW_BLOCKED)           return 0 ;;
    CHANGES_REQUESTED_IN_PROGRESS) return 0 ;;
    CHANGES_REQUESTED_BLOCKED)   return 0 ;;
    *) return 1 ;;
  esac
}

if ! valid_transition "$OLD_STATUS" "$NEW_STATUS"; then
  echo "HYDRA STATE GUARD: BLOCKED — Invalid state transition: ${OLD_STATUS} → ${NEW_STATUS}" >&2
  echo "Constitution Article III permitted transitions:" >&2
  echo "  PLANNED→READY, READY→IN_PROGRESS, IN_PROGRESS→IMPLEMENTED," >&2
  echo "  IMPLEMENTED→IN_REVIEW, IN_REVIEW→DONE (with reviews)," >&2
  echo "  IN_REVIEW→CHANGES_REQUESTED, *→BLOCKED" >&2
  exit 2
fi
```

**Step 4: Add DONE-specific review evidence check**

```bash
# --- ENFORCE REVIEW GATE FOR DONE (Constitution Article IV) ---
if [ "$NEW_STATUS" = "DONE" ]; then
  TASK_ID=$(basename "$FILE_PATH" .md)
  HYDRA_DIR=$(dirname "$(dirname "$FILE_PATH")")
  REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"

  # Check 1: Review directory must exist
  if [ ! -d "$REVIEW_DIR" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as DONE" >&2
    echo "No review directory at: ${REVIEW_DIR}" >&2
    echo "ALL reviewers must approve before DONE (Constitution Rule 5)." >&2
    exit 2
  fi

  # Check 2: Must contain reviewer files (exclude meta-files)
  REVIEW_COUNT=0
  for review_file in "$REVIEW_DIR"/*.md; do
    [ -f "$review_file" ] || continue
    BASENAME=$(basename "$review_file")
    case "$BASENAME" in
      test-failures.md|consolidated-feedback.md) continue ;;
    esac
    REVIEW_COUNT=$((REVIEW_COUNT + 1))
  done

  if [ "$REVIEW_COUNT" -eq 0 ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as DONE" >&2
    echo "Review directory exists but contains no reviewer files." >&2
    echo "ALL reviewers must approve before DONE (Constitution Rule 5)." >&2
    exit 2
  fi

  # Check 3: Every reviewer must have APPROVED
  for review_file in "$REVIEW_DIR"/*.md; do
    [ -f "$review_file" ] || continue
    BASENAME=$(basename "$review_file")
    case "$BASENAME" in
      test-failures.md|consolidated-feedback.md) continue ;;
    esac
    if ! grep -qi 'APPROVED' "$review_file" 2>/dev/null; then
      echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as DONE" >&2
      echo "Review ${BASENAME} does not contain APPROVED verdict." >&2
      echo "ALL reviewers must approve before DONE (Constitution Rule 5)." >&2
      exit 2
    fi
  done
fi

# Valid transition — allow
exit 0
```

**Step 5: Make executable and commit**

```bash
chmod +x scripts/task-state-guard.sh
git add scripts/task-state-guard.sh
git commit -m "feat: add task-state-guard.sh — enforces state machine transitions via PreToolUse hook"
```

---

### Task 2: Register hook in hooks.json

**Files:**
- Modify: `hooks/hooks.json`

**Step 1: Add Write|Edit PreToolUse matcher**

Add a new entry to the `PreToolUse` array alongside the existing Bash matcher:

```json
{
  "matcher": "Write|Edit",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/task-state-guard.sh",
      "timeout": 10
    }
  ]
}
```

The PreToolUse section should now have two entries: one for Bash (existing) and one for Write|Edit (new).

**Step 2: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: register task-state-guard hook for Write|Edit on task manifests"
```

---

### Task 3: Enhance stop-hook.sh (Layer 2 — reactive validation)

**Files:**
- Modify: `scripts/stop-hook.sh` (after the task counting loop, around line 97)

**Step 1: Add DONE-without-review validation after task counting**

Insert after line 97 (after the task counting `done` / `fi` block), before the consecutive failure tracking:

```bash
# --- REVIEW GATE ENFORCEMENT (Layer 2 — reactive safety net) ---
# Validate that no tasks are DONE without review evidence
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
    if [ "$STATUS" = "DONE" ]; then
      TASK_ID=$(basename "$task_file" .md)
      REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"
      REVIEW_VALID=true

      # Check review directory exists with reviewer files
      if [ ! -d "$REVIEW_DIR" ]; then
        REVIEW_VALID=false
      else
        HAS_REVIEWS=false
        for rf in "$REVIEW_DIR"/*.md; do
          [ -f "$rf" ] || continue
          case "$(basename "$rf")" in
            test-failures.md|consolidated-feedback.md) continue ;;
          esac
          HAS_REVIEWS=true
          break
        done
        if [ "$HAS_REVIEWS" = false ]; then
          REVIEW_VALID=false
        fi
      fi

      if [ "$REVIEW_VALID" = false ]; then
        # VIOLATION: Reset to IMPLEMENTED
        sed -i.bak 's/^\(- \*\*Status\*\*:\) DONE/\1 IMPLEMENTED/' "$task_file" && rm -f "${task_file}.bak"
        DONE_COUNT=$((DONE_COUNT - 1))
        IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1))
        echo "HYDRA REVIEW GATE VIOLATION: ${TASK_ID} was DONE without reviews — reset to IMPLEMENTED" >&2

        # Log violation to notifications
        NOTIFY_FILE="$HYDRA_DIR/notifications.jsonl"
        jq -n \
          --arg event "review_gate_violation" \
          --arg task "$TASK_ID" \
          --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          --arg summary "${TASK_ID} was marked DONE without review evidence. Reset to IMPLEMENTED." \
          '{event: $event, task: $task, timestamp: $timestamp, summary: $summary, requires_human: false}' >> "$NOTIFY_FILE"
      fi
    fi
  done
fi
```

**Step 2: Commit**

```bash
git add scripts/stop-hook.sh
git commit -m "feat: stop-hook validates DONE tasks have review evidence, auto-resets violations"
```

---

### Task 4: Enhance pre-tool-guard.sh (Layer 3 — escape prevention)

**Files:**
- Modify: `scripts/pre-tool-guard.sh` (add before the `exit 0` at the end)

**Step 1: Add patterns to block Bash-based task manifest manipulation**

Add before the final `exit 0`:

```bash
# Task manifest status protection — prevent bypassing Write/Edit hooks
check_pattern 'sed.*hydra/tasks/TASK-.*Status' "Direct sed on task manifest status (use Write/Edit tools)"
check_pattern 'echo.*Status.*hydra/tasks/TASK-' "Direct echo to task manifest (use Write/Edit tools)"
check_pattern 'printf.*Status.*hydra/tasks/TASK-' "Direct printf to task manifest (use Write/Edit tools)"
check_pattern 'cat.*>.*hydra/tasks/TASK-' "Direct cat redirect to task manifest (use Write/Edit tools)"
check_pattern 'tee.*hydra/tasks/TASK-' "Direct tee to task manifest (use Write/Edit tools)"
```

**Step 2: Commit**

```bash
git add scripts/pre-tool-guard.sh
git commit -m "feat: block Bash-based task manifest status manipulation"
```

---

### Task 5: Validation testing

**Step 1: Run shellcheck on all modified scripts**

```bash
shellcheck scripts/task-state-guard.sh
shellcheck scripts/stop-hook.sh
shellcheck scripts/pre-tool-guard.sh
```

Expected: no errors.

**Step 2: Run bash syntax check**

```bash
bash -n scripts/task-state-guard.sh
bash -n scripts/stop-hook.sh
bash -n scripts/pre-tool-guard.sh
```

Expected: no output (clean parse).

**Step 3: Run existing tests**

```bash
tests/run-tests.sh
```

Expected: all existing tests pass.

**Step 4: Final commit with all changes**

```bash
git add -A
git commit -m "feat: enforce review gate with 3-layer defense-in-depth

Layer 1: task-state-guard.sh PreToolUse hook blocks invalid state transitions
Layer 2: stop-hook.sh validates DONE tasks have review evidence each iteration
Layer 3: pre-tool-guard.sh blocks Bash-based task manifest manipulation

No task can be marked DONE without review evidence on disk."
```
