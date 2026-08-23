#!/usr/bin/env bash
set -euo pipefail

# Nazgul Task State Guard — enforces Constitution Article III state machine
# Intercepts Write/Edit on task manifests, validates status transitions
# Exit 0 = allow, Exit 2 = block with reason

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/review-evidence.sh"
source "$SCRIPT_DIR/lib/task-transition-guard.sh"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/destructive-patterns.sh
source "$SCRIPT_DIR/lib/destructive-patterns.sh"
RHP_LIB="$SCRIPT_DIR/lib/read-hook-payload.sh"
# A load that returns 0 having defined nothing is still no payload, and it is
# scoped like the timeout branch below rather than denying every repo.
rhp_unavailable() {
  if [ -f "$(resolve_project_root)/nazgul/config.json" ]; then
    printf 'task-state-guard: stdin reader unavailable: %s — fail-closed, blocking the edit\n' "$1" >&2
    exit 2
  fi
  printf 'task-state-guard: stdin reader unavailable: %s — fail-open, not a Nazgul project\n' "$1" >&2
  exit 0
}
[ -r "$RHP_LIB" ] || rhp_unavailable "$RHP_LIB is missing or unreadable"
rhp_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_rc=$?
declare -F read_hook_payload >/dev/null && declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "$RHP_LIB defines no reader API after sourcing (source returned $rhp_rc)"

# Read tool input from stdin (Claude Code passes JSON for PreToolUse hooks)
read_hook_payload
if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
  # lean-comments: allow-run — why one of the three reader bounds decides differently here.
  # `oversize` is asked SEPARATELY rather than inheriting the stall answer by proximity. A
  # stall or a deadline is transient, so failing closed costs a retry; the cap is
  # DETERMINISTIC, so failing closed refuses every large Write in the project forever, with
  # no path around it. This guard is preflight and cannot create authority (ADR-020): the one
  # write it might miss is a padded status edit, which the stop-hook's reconciliation pass
  # quarantines at the next iteration. pre-tool-guard has no such backstop and denies both.
  if [ "${HOOK_PAYLOAD_REASON:-}" = "oversize" ]; then
    hook_payload_timeout_report "task-state-guard" "fail-open" \
      "allowing the edit unscreened — a cap-sized payload is not a state change this guard can read, and reconciliation is the backstop for one that is"
    exit 0
  fi
  # With no payload there is no file path to bound, so the deny is decided here
  # — but an unrelated repo's edits were never this guard's to refuse.
  if [ -f "$(resolve_project_root)/nazgul/config.json" ]; then
    hook_payload_timeout_report "task-state-guard" "fail-closed" "blocking the edit"
    exit 2
  fi
  hook_payload_timeout_report "task-state-guard" "fail-open" "not a Nazgul project"
  exit 0
fi
INPUT="$HOOK_PAYLOAD"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse JSON input with jq
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Handle MultiEdit by checking every edit independently. A task-status-bearing
# edit is denied and routed to the transactional command, so there is no reason
# to aggregate sibling strings (aggregation let an earlier same-status string
# shadow a later real status change). A remove-then-add status sequence is
# deliberately denied at the removal and must use the transition command.
if [ "$TOOL_NAME" = "MultiEdit" ]; then
  EDITS_JSON=$(echo "$INPUT" | jq -c '.tool_input.edits // [] | .[]' 2>/dev/null || echo "")
  if [ -z "$EDITS_JSON" ]; then
    exit 0
  fi
  while IFS= read -r EDIT; do
    [ -z "$EDIT" ] && continue
    SINGLE_INPUT=$(echo "$INPUT" | jq --argjson edit "$EDIT" '
      .tool_name = "Edit"
      | .tool_input = $edit
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

# Derive project root via the worktree-aware resolver (FEAT-021 / ADR-008)
PROJECT_ROOT="$(resolve_project_root)"

# Bound FILE_PATH by PROJECT_ROOT (Defect 3): writes outside this project
# aren't this guard's business — including another project's own manifest.
_tsg_canon_path() {
  # No-existence-required realpath (BSD lacks -m): resolve the longest
  # existing prefix via cd+pwd -P, reattach what doesn't exist literally.
  #
  # A TERMINAL symlink must be resolved too (PR #75 review). Resolving only
  # dirname left the leaf literal, which is a real BYPASS in the fail-open
  # direction, not just cosmetic: a path OUTSIDE the project symlinked to an
  # in-project source file canonicalized as outside, so the boundary check
  # below exited 0 and the state gate never ran — while the write landed
  # inside the project. Reproduced: direct write to proj/src/main.ts with no
  # task IN_PROGRESS exits 2, but the same write via outside/link.ts exited 0.
  local p="$1" suffix="" dir base
  dir="$(dirname -- "$p")"
  base="$(basename -- "$p")"
  while [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
    suffix="/$(basename -- "$dir")$suffix"
    dir="$(dirname -- "$dir")"
  done
  dir="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
  # Bounded symlink walk on the leaf, only when it exists and the prefix was
  # fully resolved (no literal suffix). Bounded to 16 hops so a symlink loop
  # cannot hang a PreToolUse hook; a still-symlinked leaf at the bound fails
  # closed in the caller rather than becoming an outside-path allow.
  if [ -z "$suffix" ]; then
    local hops=0 target
    while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
      target="$(readlink -- "$dir/$base")" || break
      case "$target" in
        /*) dir="$(dirname -- "$target")"; base="$(basename -- "$target")" ;;
        *)  dir="$(cd "$dir" 2>/dev/null && cd "$(dirname -- "$target")" 2>/dev/null && pwd -P || printf '%s' "$dir")"
            base="$(basename -- "$target")" ;;
      esac
      dir="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
      hops=$((hops + 1))
    done
    [ ! -L "$dir/$base" ] || return 1
  fi
  printf '%s%s/%s' "$dir" "$suffix" "$base"
}

case "$FILE_PATH" in
  /*) REQUEST_FILE_PATH="$FILE_PATH" ;;
  *)  REQUEST_FILE_PATH="$PROJECT_ROOT/$FILE_PATH" ;;
esac
CANON_FILE_PATH="$REQUEST_FILE_PATH"
if ! CANON_FILE_PATH="$(_tsg_canon_path "$CANON_FILE_PATH")"; then
  echo "NAZGUL STATE GUARD: BLOCKED — file path contains an unresolved or overlong symlink chain" >&2
  exit 2
fi
CANON_PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_ROOT")"

# A request made through the project's lexical task path must resolve to that
# exact canonical leaf. This rejects both a symlinked tasks/ component and a
# symlinked TASK leaf whether the target lands inside or outside the project.
case "$REQUEST_FILE_PATH" in
  "$PROJECT_ROOT"/nazgul/tasks/*|"$CANON_PROJECT_ROOT"/nazgul/tasks/*)
    REQUEST_TASK_BASENAME=$(basename "$REQUEST_FILE_PATH")
    if [[ "$REQUEST_TASK_BASENAME" =~ ^TASK-[0-9]+\.md$ ]]; then
      REQUEST_TASK_ID="${REQUEST_TASK_BASENAME%.md}"
      EXPECTED_TASK_PATH="$CANON_PROJECT_ROOT/nazgul/tasks/$REQUEST_TASK_ID.md"
      if [ "$CANON_FILE_PATH" != "$EXPECTED_TASK_PATH" ] \
        || [ -L "$CANON_PROJECT_ROOT/nazgul/tasks" ] \
        || [ -L "$EXPECTED_TASK_PATH" ]; then
        echo "NAZGUL STATE GUARD: BLOCKED — task manifest does not resolve to its canonical project runtime path" >&2
        exit 2
      fi
    fi
    ;;
esac
# When the project root canonicalizes to "/", "$CANON_PROJECT_ROOT"/* expands
# to "//*", which matches nothing with a single leading slash — so EVERY
# descendant fell through to `exit 0` and the guard silently disarmed itself
# for the whole filesystem (PR #75 review; verified: with root=/, both
# /tmp/file and /a/b took the allow branch). A root-mounted project is
# unlikely, but a guard that no-ops on an unlikely input is still a guard that
# no-ops. With root "/" every absolute path IS a descendant, so skip the
# boundary test rather than let the pattern decide it.
if [ "$CANON_PROJECT_ROOT" != "/" ]; then
  case "$CANON_FILE_PATH" in
    "$CANON_PROJECT_ROOT"|"$CANON_PROJECT_ROOT"/*) ;;
    *) exit 0 ;;
  esac
fi

# Helper: check if a path is inside the project's nazgul/ control directory
is_nazgul_path() {
  local p="$1"
  # Relative path starting with nazgul/
  case "$p" in
    nazgul|nazgul/*) return 0 ;;
  esac
  # Absolute path under PROJECT_ROOT/nazgul/
  case "$p" in
    "${CANON_PROJECT_ROOT}"/nazgul|"${CANON_PROJECT_ROOT}"/nazgul/*) return 0 ;;
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
if ! is_task_manifest "$CANON_FILE_PATH"; then
  # Defense-in-depth (recompute-and-compare in review-evidence.sh is the real
  # fix): .dispatch.json and diff.patch are written by the review-gate
  # orchestrator only, which never runs while a task is IN_PROGRESS — the
  # implementer's active turn. Block writes/edits to either while the covering
  # task(s) are IN_PROGRESS — unit-scoped for TASK-*/PATCH-* (that task) and
  # GROUP-* (that group's tasks), falling back to any-task-IN_PROGRESS only for
  # unrecognized unit ids — narrowing the trivial forge path (implementer has Bash+Write
  # under nazgul/).
  if { is_dispatch_manifest "$CANON_FILE_PATH" || is_review_diff "$CANON_FILE_PATH"; } && [ -d "$PROJECT_ROOT/nazgul/tasks" ]; then
    # Narrow to the review unit's own task(s) so a parallel Agent-Teams wave
    # with another unit's task IN_PROGRESS doesn't false-block this unit's
    # already-finished review bookkeeping. GROUP-<n>/FEATURE-* unit IDs (and
    # any unrecognized shape) fall back to the conservative any-task check.
    _dm_unit_id=$(basename "$(dirname "$CANON_FILE_PATH")")
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
      echo "NAZGUL STATE GUARD: BLOCKED — $(basename "$CANON_FILE_PATH") may not be written while a task is IN_PROGRESS" >&2
      echo "This file is written by the review-gate orchestrator only, after a task reaches IMPLEMENTED." >&2
      exit 2
    fi
  fi

  # Two keys are carved OUT of the nazgul/ allow below: scripts/red-run.sh executes
  # them directly, so this write is the one route past pre-tool-guard.sh entirely.
  _tsg_project_command_values() {
    local payload="$1" out=""
    if command -v jq >/dev/null 2>&1; then
      out=$(printf '%s' "$payload" | jq -r '
        (if (.project | type) == "object" then .project else {} end)
        | (.test_command, .test_filter_template)
        | select(type == "string" and . != "")' 2>/dev/null || true)
    fi
    # An Edit new_string is a FRAGMENT, not parseable JSON: recover the values
    # textually rather than treating an unparseable payload as nothing to check.
    if [ -z "$out" ]; then
      out=$(printf '%s' "$payload" \
        | grep -oE '"(test_command|test_filter_template)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
        | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)
    fi
    printf '%s' "$out"
  }

  _tsg_screen_project_commands() {
    local payload values value ec
    payload=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || echo "")
    [ -n "$payload" ] || return 0
    values=$(_tsg_project_command_values "$payload")
    [ -n "$values" ] || return 0
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      ec=0
      dp_scan_command "$value" || ec=$?
      [ "$ec" -eq 2 ] || continue
      echo "NAZGUL STATE GUARD: BLOCKED — this write would set a project command that is on the destructive-command denylist" >&2
      echo "Denylisted as: $DP_REASON" >&2
      echo "Value contained: $DP_PATTERN" >&2
      echo "Value: $value" >&2
      echo "project.test_command and project.test_filter_template are executed by scripts/red-run.sh, not through the Bash tool, so pre-tool-guard.sh never sees them." >&2
      exit 2
    done <<EOF
$values
EOF
  }

  case "$CANON_FILE_PATH" in
    */nazgul/config.json) _tsg_screen_project_commands ;;
  esac

  # Everything else inside nazgul/ is always allowed (plan, reviews, etc.)
  if is_nazgul_path "$CANON_FILE_PATH"; then
    exit 0
  fi

  # Documentation and plan files are always allowed (design docs, ADRs, plans, etc.)
  case "$FILE_PATH" in
    */docs/*|*/plans/*|*/doc/*|*/.claude/*|\
    docs/*|plans/*|doc/*|.claude/*) exit 0 ;;
  esac

  # Split "not a Nazgul project" from "IS a Nazgul project whose task state is
  # missing" (ADR-009 Option 3): reuse nazgul-root.sh's own marker for the
  # former — nazgul/config.json exists and is readable — instead of inventing
  # a second definition (TASK-002 / PRD AC6).
  NAZGUL_CONFIG="$PROJECT_ROOT/nazgul/config.json"
  if [ ! -f "$NAZGUL_CONFIG" ] || [ ! -r "$NAZGUL_CONFIG" ]; then
    exit 0
  fi

  # config.json exists but nazgul/tasks/ is missing or unreadable: this is a
  # corrupted/partially-initialized Nazgul project, not a non-Nazgul
  # directory. Fail CLOSED (ADR-009): a silent allow here disarms both the
  # active-task and file-scope gates for the rest of the invocation.
  # `-r` alone is not enough for a DIRECTORY: without the search (`-x`) bit the
  # glob below cannot stat TASK-*.md, so every task reads as absent — exactly
  # the "never actually looked" state this branch exists to reject.
  if [ ! -d "$PROJECT_ROOT/nazgul/tasks" ] \
    || [ ! -r "$PROJECT_ROOT/nazgul/tasks" ] \
    || [ ! -x "$PROJECT_ROOT/nazgul/tasks" ]; then
    echo "NAZGUL STATE GUARD: BLOCKED — nazgul/config.json exists but nazgul/tasks/ is missing or unreadable" >&2
    echo "This looks like a corrupted or partially-initialized Nazgul project, not a non-Nazgul directory." >&2
    echo "The active-task and file-scope gates cannot be evaluated without it." >&2
    exit 2
  fi
  NAZGUL_TASKS_DIR="$PROJECT_ROOT/nazgul/tasks"

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

# Deny ordinary Write/Edit while a transition lock is already visible. The
# PreToolUse check cannot hold that lock through a later tool completion, so it
# narrows (but does not pretend to eliminate) the final check-to-rename window.
# task-transition.sh is the sole status authority; TASK-004 separately funnels
# direct shell mutation, and all cooperative metadata writers must avoid a task
# while its transition lock exists.
# Derived from the canonical path so a symlink alias cannot downgrade a task
# manifest into the generic nazgul-file allow branch.
TASK_ID=$(basename "$CANON_FILE_PATH" .md)
if [ -d "$CANON_PROJECT_ROOT/nazgul/locks/task-transition-${TASK_ID}.lock" ]; then
  echo "NAZGUL STATE GUARD: BLOCKED — ${TASK_ID} is locked by an in-flight transactional transition" >&2
  exit 2
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

# Build the exact post-image and parse canonical state once. Regexing only the
# replacement fragment was bypassable when stale body text appeared first,
# canonical status was deleted/quoted, or MultiEdit supplied multiple strings.
POST_IMAGE=$(mktemp "${TMPDIR:-/tmp}/nazgul-task-state.XXXXXX") || exit 2
trap 'rm -f "$POST_IMAGE"' EXIT INT TERM
if [ "$TOOL_NAME" = "Write" ]; then
  printf '%s' "$NEW_CONTENT" > "$POST_IMAGE"
elif [ -f "$CANON_FILE_PATH" ] && [ -n "$OLD_STRING" ]; then
  OLD_STRING="$OLD_STRING" NEW_CONTENT="$NEW_CONTENT" awk '
    BEGIN { buf=""; old=ENVIRON["OLD_STRING"]; new=ENVIRON["NEW_CONTENT"] }
    { buf = buf (NR>1 ? "\n" : "") $0 }
    END { idx = index(buf, old); if (idx) printf "%s", substr(buf, 1, idx-1) new substr(buf, idx+length(old)); else printf "%s", buf }
  ' "$CANON_FILE_PATH" > "$POST_IMAGE"
else
  printf '%s' "$NEW_CONTENT" > "$POST_IMAGE"
fi

OLD_STATUS=""
OLD_CANON_RC=1
if [ -f "$CANON_FILE_PATH" ]; then
  OLD_STATUS=$(get_task_status "$CANON_FILE_PATH" "")
  if read_task_status "$CANON_FILE_PATH" >/dev/null 2>&1; then OLD_CANON_RC=0; else OLD_CANON_RC=$?; fi
fi
NEW_STATUS=$(get_task_status "$POST_IMAGE" "")
if read_task_status "$POST_IMAGE" >/dev/null 2>&1; then POST_CANON_RC=0; else POST_CANON_RC=$?; fi

if [ "$NEW_STATUS" = "INVALID" ] \
  || { [ -n "$OLD_STATUS" ] && [ -z "$NEW_STATUS" ]; } \
  || { [ "$OLD_CANON_RC" -eq 0 ] && [ "$POST_CANON_RC" -ne 0 ]; }; then
  echo "NAZGUL STATE GUARD: BLOCKED — task manifest post-image has missing or invalid canonical status" >&2
  echo "Keep a valid status field and use the transactional command for status changes." >&2
  exit 2
fi

# --- ADR-020 QUARANTINE RECORD INTEGRITY (board-5 S-5) ---
# rc 1 = record absent; rc 0 with an empty value = present but blanked.
_tsg_q_value() {
  local line
  line=$(grep -m1 -iE "^-[[:space:]]*\*\*$2\*\*:" "$1" 2>/dev/null) || return 1
  line="${line#*:}"
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s' "${line%"${line##*[![:space:]]}"}"
}

_tsg_q_refuse() {
  echo "NAZGUL STATE GUARD: BLOCKED — ${TASK_ID}: $1" >&2
  echo "Removing a reconciliation quarantine is a state change, not an edit." >&2
  echo "Its only sanctioned exit is: ${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}/scripts/task-transition.sh repair ${TASK_ID}" >&2
  exit 2
}

# The three fields are ONE record, so deleting the first line silently unlocked
# BLOCKED -> CANCELLED. Narrow by ADR-009: only a write that CHANGES one is denied.
if [ "$OLD_STATUS" = "BLOCKED" ] && [ -f "$CANON_FILE_PATH" ]; then
  for _q_field in "Blocked kind" "Blocked from" "Blocked observed"; do
    _q_old_rc=0
    _q_old=$(_tsg_q_value "$CANON_FILE_PATH" "$_q_field") || _q_old_rc=$?
    [ "$_q_old_rc" -eq 0 ] || continue
    _q_new_rc=0
    _q_new=$(_tsg_q_value "$POST_IMAGE" "$_q_field") || _q_new_rc=$?
    if [ "$_q_new_rc" -ne 0 ]; then
      _tsg_q_refuse "this write deletes the quarantine record '${_q_field}'"
    fi
    if [ "$_q_new" != "$_q_old" ]; then
      _tsg_q_refuse "this write alters the quarantine record '${_q_field}' ('${_q_old}' -> '${_q_new}')"
    fi
  done
fi

# `Blocked from`/`Blocked observed` are written ONLY by the reconciliation
# quarantine, so either without a reconciliation kind is half-erased, not clean.
if [ "$NEW_STATUS" = "BLOCKED" ]; then
  _q_kind_rc=0; _q_kind=$(_tsg_q_value "$POST_IMAGE" "Blocked kind") || _q_kind_rc=$?
  _q_from_rc=0; _q_from=$(_tsg_q_value "$POST_IMAGE" "Blocked from") || _q_from_rc=$?
  _q_obs_rc=0;  _q_obs=$(_tsg_q_value "$POST_IMAGE" "Blocked observed") || _q_obs_rc=$?
  _q_typed=0
  case "$_q_kind" in
    [Rr]econciliation|[Rr]econciliation[[:space:]]*) _q_typed=1 ;;
  esac
  if [ "$_q_typed" -eq 1 ]; then
    if [ "$_q_from_rc" -ne 0 ] || [ -z "$_q_from" ] || [ "$_q_obs_rc" -ne 0 ] || [ -z "$_q_obs" ]; then
      _tsg_q_refuse "a typed reconciliation quarantine is missing 'Blocked from' and/or 'Blocked observed'"
    fi
  elif [ "$_q_from_rc" -eq 0 ] || [ "$_q_obs_rc" -eq 0 ]; then
    _tsg_q_refuse "'Blocked from'/'Blocked observed' are present without a reconciliation 'Blocked kind' — the quarantine record is partially erased"
  fi
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
  # Derived from ttg_valid_transition, never restated: the hand-kept copy that used to live here
  # had gone stale for IMPLEMENTED -> DONE and all eight -> CANCELLED edges.
  if ALLOWED_NEXT=$(ttg_allowed_next "$OLD_STATUS"); then
    if [ -n "$ALLOWED_NEXT" ]; then
      echo "  ${OLD_STATUS} allowed next: ${ALLOWED_NEXT}" >&2
      echo "  Some of those edges carry evidence conditions — see RULES.md §2 for the permitted transition table" >&2
    else
      echo "  ${OLD_STATUS} is a terminal state — no further transitions allowed" >&2
    fi
  else
    echo "  See RULES.md §2 for the permitted transition table" >&2
  fi
  exit 2
fi

NAZGUL_DIR=$(dirname "$(dirname "$CANON_FILE_PATH")")
MANIFEST_TEXT=$(cat "$POST_IMAGE")

if ! ttg_validate_transition "$NAZGUL_DIR" "$PROJECT_ROOT" "$TASK_ID" \
  "$OLD_STATUS" "$NEW_STATUS" "$MANIFEST_TEXT"; then
  echo "NAZGUL STATE GUARD: BLOCKED — ${TASK_ID} failed the shared transition/evidence validation" >&2
  exit 2
fi

echo "NAZGUL STATE GUARD: BLOCKED — Direct task-status edits cannot record completed-write authority" >&2
echo "Run: ${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}/scripts/task-transition.sh transition ${TASK_ID} ${OLD_STATUS} ${NEW_STATUS}" >&2
echo "Edit non-status metadata first, then use the command for the locked status transition." >&2
exit 2
