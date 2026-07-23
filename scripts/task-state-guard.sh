#!/usr/bin/env bash
set -euo pipefail

# Nazgul Task State Guard — enforces Constitution Article III state machine
# Intercepts Write/Edit on task manifests, validates status transitions
# Exit 0 = allow, Exit 2 = block with reason

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/review-evidence.sh"
source "$SCRIPT_DIR/lib/task-transition-guard.sh"

# Single source of truth (ADR-002 Decision 1): derive the accepted-status regex
# alternation from structured-state.sh's VALID_STATUSES (sourced transitively via
# task-utils.sh above) instead of hand-maintaining a second enumeration here — the
# two DID drift apart once (MF-001: this file already had APPROVED, the library
# didn't).
STATUS_REGEX_ALT="(${VALID_STATUSES// /|})"

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

# Helper: check if path is a review-unit dispatch manifest
is_dispatch_manifest() {
  local p="$1"
  [[ "$p" =~ (^|/)nazgul/reviews/[^/]+/\.dispatch\.json$ ]]
}

# Helper: check if path is a review-unit diff (the authenticity trust root)
is_review_diff() {
  local p="$1"
  [[ "$p" =~ (^|/)nazgul/reviews/[^/]+/diff\.patch$ ]]
}

# If this is NOT a task manifest, check if it needs the active-task guard
if ! is_task_manifest "$FILE_PATH"; then
  # Defense-in-depth (recompute-and-compare in review-evidence.sh is the real
  # fix): .dispatch.json and diff.patch are written by the review-gate
  # orchestrator only, which never runs while a task is IN_PROGRESS — the
  # implementer's active turn. Block writes/edits to either while the covering
  # task(s) are IN_PROGRESS — unit-scoped for TASK-*/PATCH-* (that task) and
  # GROUP-* (that group's tasks), falling back to any-task-IN_PROGRESS only for
  # unrecognized unit ids — narrowing the trivial forge path (implementer has Bash+Write
  # under nazgul/).
  if { is_dispatch_manifest "$FILE_PATH" || is_review_diff "$FILE_PATH"; } && [ -d "$PROJECT_ROOT/nazgul/tasks" ]; then
    # Narrow to the review unit's own task(s) so a parallel Agent-Teams wave
    # with another unit's task IN_PROGRESS doesn't false-block this unit's
    # already-finished review bookkeeping. GROUP-<n>/FEATURE-* unit IDs (and
    # any unrecognized shape) fall back to the conservative any-task check.
    _dm_unit_id=$(basename "$(dirname "$FILE_PATH")")
    _dm_blocking=false
    case "$_dm_unit_id" in
      TASK-*|PATCH-*)
        _dm_unit_task="$PROJECT_ROOT/nazgul/tasks/${_dm_unit_id}.md"
        [ -f "$_dm_unit_task" ] || _dm_unit_task="$PROJECT_ROOT/nazgul/tasks/patches/${_dm_unit_id}.md"
        if [ -f "$_dm_unit_task" ] && [ "$(get_task_status "$_dm_unit_task" "")" = "IN_PROGRESS" ]; then
          _dm_blocking=true
        fi
        ;;
      GROUP-*)
        _dm_group_num="${_dm_unit_id#GROUP-}"
        for _dm_task_file in "$PROJECT_ROOT/nazgul/tasks"/TASK-*.md; do
          [ -f "$_dm_task_file" ] || continue
          if [ "$(get_task_field "$_dm_task_file" "Group" "")" = "$_dm_group_num" ] \
            && [ "$(get_task_status "$_dm_task_file" "")" = "IN_PROGRESS" ]; then
            _dm_blocking=true
            break
          fi
        done
        ;;
      *)
        for _dm_task_file in "$PROJECT_ROOT/nazgul/tasks"/TASK-*.md "$PROJECT_ROOT/nazgul/tasks"/patches/PATCH-*.md; do
          [ -f "$_dm_task_file" ] || continue
          if [ "$(get_task_status "$_dm_task_file" "")" = "IN_PROGRESS" ]; then
            _dm_blocking=true
            break
          fi
        done
        ;;
    esac
    if [ "$_dm_blocking" = true ]; then
      echo "NAZGUL STATE GUARD: BLOCKED — $(basename "$FILE_PATH") may not be written while a task is IN_PROGRESS" >&2
      echo "This file is written by the review-gate orchestrator only, after a task reaches IMPLEMENTED." >&2
      exit 2
    fi
  fi

  # Files inside nazgul/ are always allowed (config, plan, reviews, etc.)
  if is_nazgul_path "$FILE_PATH"; then
    exit 0
  fi

  # Documentation and plan files are always allowed (design docs, ADRs, plans, etc.)
  case "$FILE_PATH" in
    */docs/*|*/plans/*|*/doc/*|*/.claude/*|\
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
  ACTIVE_TASK_FILE=""
  TASK_COUNT=0
  for task_file in "$NAZGUL_TASKS_DIR"/TASK-*.md "$NAZGUL_TASKS_DIR"/patches/PATCH-*.md; do
    [ -f "$task_file" ] || continue
    TASK_COUNT=$((TASK_COUNT + 1))
    STATUS=$(get_task_status "$task_file" "")
    if [ "$STATUS" = "IN_PROGRESS" ]; then
      HAS_ACTIVE=true
      ACTIVE_TASK_FILE="$task_file"
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

  # --- FILE SCOPE GUARD ---
  # If the active task declares files in scope, block edits to paths outside
  # it. Exemptions: nazgul/ paths (already returned exit 0 above) and docs/
  # paths. Degrade: if the field is absent/empty/malformed, allow (no
  # restriction declared) — MF-024: fed by the shared `Files modified`
  # JSON-array accessor, not the nonexistent "File Scope" field.
  ACTIVE_TASK_ID=""
  FILE_SCOPE=""
  if [ -n "$ACTIVE_TASK_FILE" ]; then
    ACTIVE_TASK_ID=$(basename "$ACTIVE_TASK_FILE" .md)
    FILE_SCOPE=$(get_task_files_modified "$ACTIVE_TASK_FILE" 2>/dev/null | tr '\n' ' ')
    FILE_SCOPE="${FILE_SCOPE% }"
  fi

  if [ -n "$FILE_SCOPE" ]; then
    # Parse comma/whitespace-separated list of path tokens
    # Normalise commas to spaces, then iterate tokens
    SCOPE_TOKENS=$(printf '%s' "$FILE_SCOPE" | tr ',' ' ')
    SCOPE_MATCH=false
    for token in $SCOPE_TOKENS; do
      [ -z "$token" ] && continue
      # Reject path-traversal tokens
      case "$token" in
        *".."*) continue ;;
      esac
      # Anchored path-suffix matching (exact, suffix, or directory-prefix)
      FILE_BASENAME=$(basename "$FILE_PATH")
      TOKEN_BASENAME=$(basename "$token")
      case "$FILE_PATH" in
        "$token"|*/"$token"|"$token"/*) SCOPE_MATCH=true; break ;;
      esac
      case "$FILE_BASENAME" in
        "$TOKEN_BASENAME") SCOPE_MATCH=true; break ;;
      esac
    done

    if [ "$SCOPE_MATCH" = false ]; then
      echo "NAZGUL FILE SCOPE GUARD: BLOCKED — ${ACTIVE_TASK_ID} file scope does not include: $FILE_PATH" >&2
      echo "Active task scope: $FILE_SCOPE" >&2
      echo "To edit this file, update '- **Files modified**:' in nazgul/tasks/${ACTIVE_TASK_ID}.md first." >&2
      exit 2
    fi
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

# Check if this changes the Status field (supports list-item, ATX inline, ATX block, and YAML frontmatter)
NEW_STATUS=$(echo "$NEW_CONTENT" | sed -n 's/.*\*\*Status\*\*:[[:space:]]*\([A-Z_]*\).*/\1/p' | head -1)
if [ -z "$NEW_STATUS" ]; then
  NEW_STATUS=$(echo "$NEW_CONTENT" | sed -n 's/^## Status:[[:space:]]*\([A-Z_]*\).*/\1/p' | head -1)
fi
if [ -z "$NEW_STATUS" ]; then
  # Try ATX block format: ## Status\n<VALUE>
  NEW_STATUS=$(echo "$NEW_CONTENT" | awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (/^[A-Z_]+$/) print; exit}')
fi
if [ -z "$NEW_STATUS" ]; then
  # YAML frontmatter `status: TOKEN`. When the content has a leading --- ... ---
  # block, scope the search to it so a `status:` line in the manifest BODY (e.g.
  # inside a code block) can't be misread as a transition. For a partial edit
  # that replaces only the status line (no --- delimiters), there is no body to
  # confuse, so search the whole content. printf (not echo) keeps arbitrary
  # multiline content POSIX-safe.
  _fm_src="$NEW_CONTENT"
  if printf '%s\n' "$NEW_CONTENT" | head -1 | grep -q '^---[[:space:]]*$'; then
    _fm_src=$(printf '%s\n' "$NEW_CONTENT" | awk 'NR==1 && /^---[[:space:]]*$/{infm=1; next} infm && /^---[[:space:]]*$/{exit} infm')
  fi
  _fm_line=$(printf '%s\n' "$_fm_src" | \
    grep -m1 -E "^status:[[:space:]]*${STATUS_REGEX_ALT}[[:space:]]*\$" 2>/dev/null || true)
  NEW_STATUS=$(printf '%s' "$_fm_line" | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')
fi
if [ -z "$NEW_STATUS" ]; then
  # Ordered last so frontmatter and structured headings take precedence; bare token
  # is a catch-all for any remaining inline formats that slip past earlier extractors.
  NEW_STATUS=$(printf '%s\n' "$NEW_CONTENT" | \
    grep -m1 -E "^${STATUS_REGEX_ALT}[[:space:]]*\$" 2>/dev/null \
    | tr -d '[:space:]' || true)
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
# ttg_valid_transition (scripts/lib/task-transition-guard.sh) is the single
# source of truth, shared with stop-hook.sh's reconciliation pass (MF-022).
if ! ttg_valid_transition "$OLD_STATUS" "$NEW_STATUS"; then
  echo "NAZGUL STATE GUARD: BLOCKED — Invalid state transition: ${OLD_STATUS} → ${NEW_STATUS}" >&2
  case "$OLD_STATUS" in
    PLANNED)           echo "  PLANNED allowed next: READY, BLOCKED" >&2 ;;
    READY)             echo "  READY allowed next: IN_PROGRESS, BLOCKED" >&2 ;;
    IN_PROGRESS)       echo "  IN_PROGRESS allowed next: IMPLEMENTED, BLOCKED" >&2 ;;
    IMPLEMENTED)       echo "  IMPLEMENTED allowed next: IN_REVIEW, BLOCKED" >&2 ;;
    IN_REVIEW)         echo "  IN_REVIEW allowed next: DONE, APPROVED (YOLO), CHANGES_REQUESTED, BLOCKED" >&2 ;;
    APPROVED)          echo "  APPROVED allowed next: DONE" >&2 ;;
    CHANGES_REQUESTED) echo "  CHANGES_REQUESTED allowed next: IN_PROGRESS, BLOCKED" >&2 ;;
    BLOCKED)           echo "  BLOCKED allowed next: READY (unblock), IN_REVIEW (materialize)" >&2 ;;
    DONE)              echo "  DONE is a terminal state — no further transitions allowed" >&2 ;;
    *)                 echo "  See RULES.md §2 for the permitted transition table" >&2 ;;
  esac
  exit 2
fi

# Derive task identity once — used by both evidence gates and the review gate below
TASK_ID=$(basename "$FILE_PATH" .md)
NAZGUL_DIR=$(dirname "$(dirname "$FILE_PATH")")

# --- ENFORCE EVIDENCE GATES ---
# IN_PROGRESS -> IMPLEMENTED requires a commit SHA in the manifest content
# For Write, NEW_CONTENT is the full post-edit file.
# For Edit, reconstruct post-edit content by applying old_string→new_string on the file.
if [ "$OLD_STATUS" = "IN_PROGRESS" ] && [ "$NEW_STATUS" = "IMPLEMENTED" ]; then
  if [ "$TOOL_NAME" = "Write" ]; then
    MANIFEST_TEXT="$NEW_CONTENT"
  elif [ -f "$FILE_PATH" ] && [ -n "$OLD_STRING" ]; then
    # Reconstruct post-edit file: replace old_string with new_string in on-disk content.
    # old/new travel via ENVIRON, not -v: BSD awk rejects literal newlines in -v assignments,
    # which silently no-ops the guard on multi-line old_string (e.g. the frontmatter fence).
    MANIFEST_TEXT=$(OLD_STRING="$OLD_STRING" NEW_CONTENT="$NEW_CONTENT" awk '
      BEGIN { buf=""; old=ENVIRON["OLD_STRING"]; new=ENVIRON["NEW_CONTENT"] }
      { buf = buf (NR>1 ? "\n" : "") $0 }
      END { idx = index(buf, old); if (idx) print substr(buf, 1, idx-1) new substr(buf, idx+length(old)); else print buf }
    ' "$FILE_PATH")
  else
    MANIFEST_TEXT="$NEW_CONTENT"
  fi
  if ! ttg_verify_commit_evidence "$MANIFEST_TEXT" "$PROJECT_ROOT"; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark IMPLEMENTED without a verified commit SHA" >&2
    echo "Add a ## Commits section with a real, reachable commit hash (verified via git cat-file) to the task manifest." >&2
    echo "If you implemented the work, you should have committed it. If git is unavailable, this blocks by design (fail closed)." >&2
    exit 2
  fi
fi

# IMPLEMENTED/BLOCKED -> IN_REVIEW requires review directory to exist
# (BLOCKED -> IN_REVIEW is the /nazgul:review --materialize repair path)
if { [ "$OLD_STATUS" = "IMPLEMENTED" ] || [ "$OLD_STATUS" = "BLOCKED" ]; } && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  # resolve_review_unit (MF-013): in group/feature granularity the review
  # directory is GROUP-<n>/FEATURE-<feat_id>, not reviews/<task_id>.
  REVIEW_DIR_CHECK="$NAZGUL_DIR/reviews/$(resolve_review_unit "$NAZGUL_DIR" "$TASK_ID")"
  if [ ! -d "$REVIEW_DIR_CHECK" ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot move to IN_REVIEW without a review directory" >&2
    echo "Expected: ${REVIEW_DIR_CHECK}/" >&2
    echo "The review-gate agent creates this directory when it starts reviewing." >&2
    exit 2
  fi
fi

# BLOCKED -> IN_REVIEW is reserved for review-evidence blockers. Tasks blocked
# for other reasons (git conflicts, test failures, max retries) must not bypass
# their blocker via the repair path — use /nazgul:task unblock instead.
if [ "$OLD_STATUS" = "BLOCKED" ] && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  if ! grep -qi '^\- \*\*Blocked reason\*\*:.*review evidence' "$FILE_PATH" 2>/dev/null; then
    echo "NAZGUL STATE GUARD: BLOCKED — BLOCKED → IN_REVIEW is reserved for review-evidence repair" >&2
    echo "This task's Blocked reason is not a review-evidence blocker." >&2
    echo "Use /nazgul:task unblock to return it to READY instead." >&2
    exit 2
  fi
fi

# --- ENFORCE REVIEW GATE (Constitution Article IV) ---
# In YOLO mode, gate APPROVED; in non-YOLO, gate DONE
# APPROVED → DONE in YOLO needs no review checks (PR merge is external validation)
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
  # Diagnostic-only path — the actual gate is ttg_verify_review_evidence below,
  # which resolves the same reviews/<unit> the resolver computes; kept in sync
  # here so the NO_REVIEW_DIR message names the directory that was really checked.
  REVIEW_DIR="$NAZGUL_DIR/reviews/$(resolve_review_unit "$NAZGUL_DIR" "$TASK_ID")"
  EVIDENCE_PROBLEMS=$(ttg_verify_review_evidence "$NAZGUL_DIR" "$TASK_ID") || true
  if [ -n "$EVIDENCE_PROBLEMS" ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — Cannot mark ${TASK_ID} as ${NEW_STATUS}" >&2
    # NO_REVIEW_DIR and NO_REVIEWERS_CONFIGURED are single-token outputs (the lib
    # early-returns on them) — bare-token case patterns are safe. Any other
    # output is MISSING/UNAPPROVED lines handled by the * branch.
    case "$EVIDENCE_PROBLEMS" in
      NO_REVIEW_DIR)
        echo "No review directory at: ${REVIEW_DIR}" >&2
        ;;
      NO_REVIEWERS_CONFIGURED)
        echo "No reviewers configured in nazgul/config.json (agents.reviewers is empty)." >&2
        echo "Run Discovery to generate the reviewer roster." >&2
        ;;
      *)
        MISSING_LIST=$(echo "$EVIDENCE_PROBLEMS" | awk '$1=="MISSING"{printf " %s", $2}')
        UNAPPROVED_LIST=$(echo "$EVIDENCE_PROBLEMS" | awk '$1=="UNAPPROVED"{printf " %s", $2}')
        if [ -n "$MISSING_LIST" ]; then
          echo "Missing reviews from configured reviewers:${MISSING_LIST}" >&2
        fi
        if [ -n "$UNAPPROVED_LIST" ]; then
          echo "Review does not contain APPROVED verdict:${UNAPPROVED_LIST}" >&2
        fi
        if [ -z "$MISSING_LIST" ] && [ -z "$UNAPPROVED_LIST" ]; then
          echo "Unexpected review evidence problem: ${EVIDENCE_PROBLEMS}" >&2
        fi
        ;;
    esac
    echo "ALL reviewers must approve before ${NEW_STATUS} (Constitution Rule 5)." >&2
    exit 2
  fi
fi

# Valid transition — allow. Record it in the guarded-transition ledger so
# stop-hook.sh's reconciliation pass can tell this legitimate
# Write/Edit/MultiEdit-mediated change apart from a Bash-write bypass (MF-022).
ttg_log_transition "$NAZGUL_DIR" "$TASK_ID" "$OLD_STATUS" "$NEW_STATUS"
exit 0
