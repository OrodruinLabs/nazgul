#!/usr/bin/env bash
set -euo pipefail

# Hydra Task State Guard — enforces Constitution Article III state machine
# Intercepts Write/Edit on task manifests, validates status transitions
# Exit 0 = allow, Exit 2 = block with reason

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"

# Read tool input from stdin (Claude Code passes JSON for PreToolUse hooks)
INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse JSON input with jq
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# If this is NOT a task manifest, check if it needs the active-task guard
if ! echo "$FILE_PATH" | grep -qE 'hydra/tasks/TASK-[0-9]+\.md$'; then
  # Files inside hydra/ are always allowed (config, plan, reviews, etc.)
  # Match both absolute (/path/hydra/) and relative (hydra/) paths
  if echo "$FILE_PATH" | grep -qE '(^|/)hydra(/|$)'; then
    exit 0
  fi

  # Check if active task guard is enabled
  HYDRA_TASKS_DIR=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR/hydra/tasks" ]; then
    HYDRA_TASKS_DIR="$CLAUDE_PROJECT_DIR/hydra/tasks"
    HYDRA_CONFIG="$CLAUDE_PROJECT_DIR/hydra/config.json"
  fi

  # No hydra/tasks dir = not a Hydra project, allow everything
  if [ -z "$HYDRA_TASKS_DIR" ]; then
    exit 0
  fi

  # Check config flag — default to true if not set
  REQUIRE_ACTIVE="true"
  if [ -f "${HYDRA_CONFIG:-}" ]; then
    REQUIRE_ACTIVE=$(jq -r 'if .guards.requireActiveTask == false then "false" else "true" end' "$HYDRA_CONFIG" 2>/dev/null || echo "true")
  fi
  if [ "$REQUIRE_ACTIVE" != "true" ]; then
    exit 0
  fi

  # Check if any task is IN_PROGRESS
  HAS_ACTIVE=false
  TASK_COUNT=0
  for task_file in "$HYDRA_TASKS_DIR"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TASK_COUNT=$((TASK_COUNT + 1))
    STATUS=$(get_task_status "$task_file" "")
    if [ "$STATUS" = "IN_PROGRESS" ]; then
      HAS_ACTIVE=true
      break
    fi
  done

  # No task files at all = not an active loop, allow everything
  if [ "$TASK_COUNT" -eq 0 ]; then
    exit 0
  fi

  if [ "$HAS_ACTIVE" = false ]; then
    echo "HYDRA STATE GUARD: BLOCKED — No task is IN_PROGRESS" >&2
    echo "Cannot edit source files without an active task." >&2
    echo "Transition a task to IN_PROGRESS before editing: $FILE_PATH" >&2
    exit 2
  fi

  # Has active task — allow the source file edit
  exit 0
fi

# Extract new content being written
if [ "$TOOL_NAME" = "Edit" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
elif [ "$TOOL_NAME" = "Write" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
else
  exit 0
fi

# Check if this changes the Status field (supports list-item, ATX inline, and ATX block formats)
NEW_STATUS=$(echo "$NEW_CONTENT" | sed -n 's/.*\*\*Status\*\*:[[:space:]]*\([A-Z_]*\).*/\1/p' | head -1)
if [ -z "$NEW_STATUS" ]; then
  NEW_STATUS=$(echo "$NEW_CONTENT" | sed -n 's/^## Status:[[:space:]]*\([A-Z_]*\).*/\1/p' | head -1)
fi
if [ -z "$NEW_STATUS" ]; then
  # Try ATX block format: ## Status\n<VALUE>
  NEW_STATUS=$(echo "$NEW_CONTENT" | awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (/^[A-Z_]+$/) print; exit}')
fi
if [ -z "$NEW_STATUS" ]; then
  # Not a status change — allow
  exit 0
fi

# Read current status from file on disk (supports both formats)
OLD_STATUS=""
if [ -f "$FILE_PATH" ]; then
  OLD_STATUS=$(get_task_status "$FILE_PATH" "")
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
    IN_REVIEW_APPROVED)          return 0 ;;
    IN_REVIEW_CHANGES_REQUESTED) return 0 ;;
    IN_REVIEW_BLOCKED)           return 0 ;;
    APPROVED_DONE)               return 0 ;;
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
  echo "  IN_REVIEW→APPROVED (YOLO), APPROVED→DONE (PR merged)," >&2
  echo "  IN_REVIEW→CHANGES_REQUESTED, *→BLOCKED" >&2
  exit 2
fi

# --- ENFORCE EVIDENCE GATES ---
# IN_PROGRESS -> IMPLEMENTED requires a commit SHA in the manifest content
# For Edit tool, NEW_CONTENT is only the replacement string — also check existing file
if [ "$OLD_STATUS" = "IN_PROGRESS" ] && [ "$NEW_STATUS" = "IMPLEMENTED" ]; then
  MANIFEST_TEXT="$NEW_CONTENT"
  if [ -f "$FILE_PATH" ]; then
    MANIFEST_TEXT="${MANIFEST_TEXT}
$(cat "$FILE_PATH" 2>/dev/null || true)"
  fi
  if ! echo "$MANIFEST_TEXT" | grep -qE '[0-9a-f]{7,40}'; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark IMPLEMENTED without a commit SHA" >&2
    echo "Add a ## Commits section with at least one commit hash to the task manifest." >&2
    echo "If you implemented the work, you should have committed it." >&2
    exit 2
  fi
fi

# IMPLEMENTED -> IN_REVIEW requires review directory to exist
if [ "$OLD_STATUS" = "IMPLEMENTED" ] && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  TASK_ID_CHECK=$(basename "$FILE_PATH" .md)
  HYDRA_DIR_CHECK=$(dirname "$(dirname "$FILE_PATH")")
  REVIEW_DIR_CHECK="$HYDRA_DIR_CHECK/reviews/$TASK_ID_CHECK"
  if [ ! -d "$REVIEW_DIR_CHECK" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot move to IN_REVIEW without a review directory" >&2
    echo "Expected: ${REVIEW_DIR_CHECK}/" >&2
    echo "The review-gate agent creates this directory when it starts reviewing." >&2
    exit 2
  fi
fi

# --- ENFORCE REVIEW GATE (Constitution Article IV) ---
# In YOLO mode, gate APPROVED; in non-YOLO, gate DONE
# APPROVED → DONE in YOLO needs no review checks (PR merge is external validation)
TASK_ID=$(basename "$FILE_PATH" .md)
HYDRA_DIR=$(dirname "$(dirname "$FILE_PATH")")
CONFIG="$HYDRA_DIR/config.json"
YOLO_MODE="false"
if [ -f "$CONFIG" ]; then
  YOLO_MODE=$(jq -r '.afk.yolo // false' "$CONFIG" 2>/dev/null || echo "false")
fi

NEEDS_REVIEW_CHECK=false
if [ "$YOLO_MODE" = "true" ] && [ "$NEW_STATUS" = "APPROVED" ]; then
  NEEDS_REVIEW_CHECK=true
elif [ "$YOLO_MODE" != "true" ] && [ "$NEW_STATUS" = "DONE" ]; then
  NEEDS_REVIEW_CHECK=true
fi

if [ "$NEEDS_REVIEW_CHECK" = true ]; then
  REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"

  # Check 1: Review directory must exist
  if [ ! -d "$REVIEW_DIR" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "No review directory at: ${REVIEW_DIR}" >&2
    echo "ALL reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
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
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "Review directory exists but contains no reviewer files." >&2
    echo "ALL reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
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
      echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
      echo "Review ${BASENAME} does not contain APPROVED verdict." >&2
      echo "ALL reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
      exit 2
    fi
  done

  # Check 4: ALL configured reviewers must have a review file
  CONFIGURED_REVIEWERS=""
  if [ -f "$CONFIG" ]; then
    CONFIGURED_REVIEWERS=$(jq -r '.agents.reviewers // [] | .[]' "$CONFIG" 2>/dev/null || echo "")
  fi

  if [ -z "$CONFIGURED_REVIEWERS" ]; then
    # No reviewers configured = cannot verify review gate
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "No reviewers configured in hydra/config.json (agents.reviewers is empty)." >&2
    echo "Run Discovery to generate the reviewer roster." >&2
    exit 2
  fi

  MISSING_REVIEWERS=""
  while IFS= read -r reviewer; do
    [ -z "$reviewer" ] && continue
    if [ ! -f "$REVIEW_DIR/${reviewer}.md" ]; then
      MISSING_REVIEWERS="${MISSING_REVIEWERS} ${reviewer}"
    fi
  done <<< "$CONFIGURED_REVIEWERS"
  if [ -n "$MISSING_REVIEWERS" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "Missing reviews from configured reviewers:${MISSING_REVIEWERS}" >&2
    echo "ALL configured reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
    exit 2
  fi
fi

# Valid transition — allow
exit 0
