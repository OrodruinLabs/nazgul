#!/usr/bin/env bash
set -euo pipefail

# Nazgul Task State Guard — enforces Constitution Article III state machine
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

# Handle MultiEdit: fan out into per-edit Edit invocations
# Aggregate new_string content per file so evidence gates (e.g., commit SHA)
# can see text from sibling edits to the same file.
if [ "$TOOL_NAME" = "MultiEdit" ]; then
  EDITS_JSON=$(echo "$INPUT" | jq -c '.tool_input.edits // [] | .[]' 2>/dev/null || echo "")
  if [ -z "$EDITS_JSON" ]; then
    exit 0
  fi
  while IFS= read -r EDIT; do
    [ -z "$EDIT" ] && continue
    # Aggregate all new_string values from edits targeting the SAME file
    EDIT_FILE=$(echo "$EDIT" | jq -r '.file_path // ""')
    SAME_FILE_STRINGS=$(echo "$INPUT" | jq -r --arg fp "$EDIT_FILE" '
      .tool_input.edits // [] | .[] | select(.file_path == $fp) | .new_string // ""
    ' 2>/dev/null || echo "")
    SINGLE_INPUT=$(echo "$INPUT" | jq --argjson edit "$EDIT" --arg agg "$SAME_FILE_STRINGS" '
      .tool_name = "Edit"
      | .tool_input = $edit
      | .tool_input.new_string = $agg
    ')
    EC=0
    echo "$SINGLE_INPUT" | "$0" || EC=$?
    if [ "$EC" -ne 0 ]; then
      exit "$EC"
    fi
  done <<< "$EDITS_JSON"
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# Derive project root — prefer CLAUDE_PROJECT_DIR, fall back to pwd
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Helper: check if a path is inside the project's nazgul/ control directory
is_nazgul_path() {
  local p="$1"
  # Relative path starting with nazgul/
  case "$p" in
    nazgul|nazgul/*) return 0 ;;
  esac
  # Absolute path under PROJECT_ROOT/nazgul/
  case "$p" in
    "${PROJECT_ROOT}"/nazgul|"${PROJECT_ROOT}"/nazgul/*) return 0 ;;
  esac
  return 1
}

# Helper: check if path is a task manifest in the project's nazgul/ dir
is_task_manifest() {
  local p="$1"
  # Must match nazgul/tasks/TASK-<digits>.md (strict: digits only before .md)
  [[ "$p" =~ (^|/)nazgul/tasks/TASK-[0-9]+\.md$ ]]
}

# If this is NOT a task manifest, check if it needs the active-task guard
if ! is_task_manifest "$FILE_PATH"; then
  # Files inside nazgul/ are always allowed (config, plan, reviews, etc.)
  if is_nazgul_path "$FILE_PATH"; then
    exit 0
  fi

  # Documentation and plan files are always allowed (design docs, ADRs, plans, etc.)
  case "$FILE_PATH" in
    */docs/*|*/plans/*|*/doc/*|*/.claude/*) exit 0 ;;
  esac
  # Also check relative paths
  case "$FILE_PATH" in
    docs/*|plans/*|doc/*|.claude/*) exit 0 ;;
  esac

  # Check if active task guard is enabled
  NAZGUL_TASKS_DIR=""
  if [ -d "$PROJECT_ROOT/nazgul/tasks" ]; then
    NAZGUL_TASKS_DIR="$PROJECT_ROOT/nazgul/tasks"
    NAZGUL_CONFIG="$PROJECT_ROOT/nazgul/config.json"
  fi

  # No nazgul/tasks dir = not a Nazgul project, allow everything
  if [ -z "$NAZGUL_TASKS_DIR" ]; then
    exit 0
  fi

  # Check config flag — default to true if not set
  REQUIRE_ACTIVE="true"
  if [ -f "${NAZGUL_CONFIG:-}" ]; then
    REQUIRE_ACTIVE=$(jq -r 'if .guards.requireActiveTask == false then "false" else "true" end' "$NAZGUL_CONFIG" 2>/dev/null || echo "true")
  fi
  if [ "$REQUIRE_ACTIVE" != "true" ]; then
    exit 0
  fi

  # Check if any task or patch is IN_PROGRESS
  HAS_ACTIVE=false
  TASK_COUNT=0
  for task_file in "$NAZGUL_TASKS_DIR"/TASK-*.md "$NAZGUL_TASKS_DIR"/patches/PATCH-*.md; do
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
    echo "NAZGUL STATE GUARD: BLOCKED — No task is IN_PROGRESS" >&2
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
  OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null || echo "")
elif [ "$TOOL_NAME" = "Write" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
  OLD_STRING=""
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
  echo "NAZGUL STATE GUARD: BLOCKED — New task must start as PLANNED or READY, not ${NEW_STATUS}" >&2
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
  echo "NAZGUL STATE GUARD: BLOCKED — Invalid state transition: ${OLD_STATUS} → ${NEW_STATUS}" >&2
  echo "Constitution Article III permitted transitions:" >&2
  echo "  PLANNED→READY, READY→IN_PROGRESS, IN_PROGRESS→IMPLEMENTED," >&2
  echo "  IMPLEMENTED→IN_REVIEW, IN_REVIEW→DONE (with reviews)," >&2
  echo "  IN_REVIEW→APPROVED (YOLO), APPROVED→DONE (PR merged)," >&2
  echo "  IN_REVIEW→CHANGES_REQUESTED, *→BLOCKED" >&2
  exit 2
fi

# --- ENFORCE EVIDENCE GATES ---
# IN_PROGRESS -> IMPLEMENTED requires a commit SHA in the manifest content
# For Write, NEW_CONTENT is the full post-edit file.
# For Edit, reconstruct post-edit content by applying old_string→new_string on the file.
if [ "$OLD_STATUS" = "IN_PROGRESS" ] && [ "$NEW_STATUS" = "IMPLEMENTED" ]; then
  if [ "$TOOL_NAME" = "Write" ]; then
    MANIFEST_TEXT="$NEW_CONTENT"
  elif [ -f "$FILE_PATH" ] && [ -n "$OLD_STRING" ]; then
    # Reconstruct post-edit file: replace old_string with new_string in on-disk content
    MANIFEST_TEXT=$(awk -v old="$OLD_STRING" -v new="$NEW_CONTENT" '
      BEGIN { buf="" }
      { buf = buf (NR>1 ? "\n" : "") $0 }
      END { idx = index(buf, old); if (idx) print substr(buf, 1, idx-1) new substr(buf, idx+length(old)); else print buf }
    ' "$FILE_PATH")
  else
    MANIFEST_TEXT="$NEW_CONTENT"
  fi
  if ! printf '%s' "$MANIFEST_TEXT" | grep -qE '[0-9a-f]{7,40}'; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark IMPLEMENTED without a commit SHA" >&2
    echo "Add a ## Commits section with at least one commit hash to the task manifest." >&2
    echo "If you implemented the work, you should have committed it." >&2
    exit 2
  fi
fi

# IMPLEMENTED -> IN_REVIEW requires review directory to exist
if [ "$OLD_STATUS" = "IMPLEMENTED" ] && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  TASK_ID_CHECK=$(basename "$FILE_PATH" .md)
  NAZGUL_DIR_CHECK=$(dirname "$(dirname "$FILE_PATH")")
  REVIEW_DIR_CHECK="$NAZGUL_DIR_CHECK/reviews/$TASK_ID_CHECK"
  if [ ! -d "$REVIEW_DIR_CHECK" ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot move to IN_REVIEW without a review directory" >&2
    echo "Expected: ${REVIEW_DIR_CHECK}/" >&2
    echo "The review-gate agent creates this directory when it starts reviewing." >&2
    exit 2
  fi
fi

# --- ENFORCE REVIEW GATE (Constitution Article IV) ---
# In YOLO mode, gate APPROVED; in non-YOLO, gate DONE
# APPROVED → DONE in YOLO needs no review checks (PR merge is external validation)
TASK_ID=$(basename "$FILE_PATH" .md)
NAZGUL_DIR=$(dirname "$(dirname "$FILE_PATH")")
CONFIG="$NAZGUL_DIR/config.json"
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
  REVIEW_DIR="$NAZGUL_DIR/reviews/$TASK_ID"

  # Check 1: Review directory must exist
  if [ ! -d "$REVIEW_DIR" ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
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
      test-failures.md|consolidated-feedback.md|simplify-report.md) continue ;;
    esac
    REVIEW_COUNT=$((REVIEW_COUNT + 1))
  done

  if [ "$REVIEW_COUNT" -eq 0 ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "Review directory exists but contains no reviewer files." >&2
    echo "ALL reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
    exit 2
  fi

  # Check 3: Every reviewer must have APPROVED
  for review_file in "$REVIEW_DIR"/*.md; do
    [ -f "$review_file" ] || continue
    BASENAME=$(basename "$review_file")
    case "$BASENAME" in
      test-failures.md|consolidated-feedback.md|simplify-report.md) continue ;;
    esac
    if ! grep -qi 'APPROVED' "$review_file" 2>/dev/null; then
      echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
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
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "No reviewers configured in nazgul/config.json (agents.reviewers is empty)." >&2
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
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    echo "Missing reviews from configured reviewers:${MISSING_REVIEWERS}" >&2
    echo "ALL configured reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
    exit 2
  fi
fi

# Valid transition — allow
exit 0
