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

  # Check 4: ALL configured reviewers must have a review file
  CONFIG="$HYDRA_DIR/config.json"
  CONFIGURED_REVIEWERS=""
  if [ -f "$CONFIG" ]; then
    CONFIGURED_REVIEWERS=$(jq -r '.agents.reviewers // [] | .[]' "$CONFIG" 2>/dev/null || echo "")
  fi

  if [ -z "$CONFIGURED_REVIEWERS" ]; then
    # No reviewers configured = cannot verify review gate
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as DONE" >&2
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
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as DONE" >&2
    echo "Missing reviews from configured reviewers:${MISSING_REVIEWERS}" >&2
    echo "ALL configured reviewers must approve before DONE (Constitution Rule 5)." >&2
    exit 2
  fi
fi

# Valid transition — allow
exit 0
