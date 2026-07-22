#!/usr/bin/env bash
# Nazgul shared task utilities — sourced by scripts that read/write task manifests.
# Eliminates duplication of get_task_status(), set_task_status(), and task counting.

_TU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TU_DIR/structured-state.sh"

# Extract status from a task manifest file.
# Supports four formats:
#   1. List-item:    - **Status**: X
#   2. ATX inline:   ## Status: X
#   3. ATX block:    ## Status\n X  (value on next line)
#   4. YAML front:   status: X     (inside --- fenced YAML frontmatter)
# Usage: get_task_status <file> [default]
get_task_status() {
  local result
  # Canonical frontmatter status takes precedence; INVALID surfaces loudly.
  local fm_status fm_rc
  fm_status=$(read_task_status "$1") && fm_rc=0 || fm_rc=$?
  if [ "$fm_rc" -eq 0 ]; then echo "$fm_status"; return; fi
  if [ "$fm_rc" -eq 2 ]; then echo "INVALID"; return; fi
  # fm_rc==1 (no status frontmatter): fall through to legacy parsing below.
  # Try inline formats first (colon on same line)
  result=$(grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$1" 2>/dev/null | sed 's/.*:[[:space:]]*//')
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  # Try block format: ## Status (no colon), value on next line
  result=$(awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (/^[A-Z_]+$/) print; exit}' "$1" 2>/dev/null)
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  # Try YAML frontmatter: status: VALUE (between --- fences)
  result=$(awk '/^---$/{fm++; next} fm==1 && /^status:/{gsub(/^status:[[:space:]]*/, ""); print; exit}' "$1" 2>/dev/null)
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  echo "${2:-}"
}

# Update status in a task manifest file.
# Handles all four formats (list-item, ATX inline, ATX block, YAML frontmatter).
# Usage: set_task_status <file> <old_status> <new_status>
set_task_status() {
  local file="$1" old_status="$2" new_status="$3"
  if has_status_frontmatter "$file"; then
    # Canonical frontmatter: rewrite the status: line inside the leading --- fence,
    # honoring the compare-and-swap contract — only transition when the current
    # value equals old_status (matches the list-item branch; a mismatch is a no-op).
    # CRLF-tolerant: strips a trailing \r from the current value before comparing,
    # and /^---[[:space:]]*$/ matches a trailing \r on the fence.
    awk -v old="$old_status" -v new="$new_status" '
      NR==1 {print; infm=1; next}
      infm && /^status[[:space:]]*:/ {
        cur=$0; sub(/^status[[:space:]]*:[[:space:]]*/, "", cur); sub(/\r$/, "", cur)
        if (cur == old) { print "status: " new } else { print }
        next
      }
      infm && /^---[[:space:]]*$/ {infm=0; print; next}
      {print}
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  elif grep -q '^## Status:' "$file" 2>/dev/null; then
    # ATX inline: ## Status: X
    sed -i.bak "s/^## Status:[[:space:]]*${old_status}/## Status: ${new_status}/" "$file" && rm -f "${file}.bak"
  elif grep -q '^\- \*\*Status\*\*:' "$file" 2>/dev/null; then
    # List-item: - **Status**: X
    sed -i.bak "s/^\(- \*\*Status\*\*:\)[[:space:]]*${old_status}/\1 ${new_status}/" "$file" && rm -f "${file}.bak"
  elif grep -q '^## Status' "$file" 2>/dev/null; then
    # ATX block: ## Status\nX — convert to inline format
    awk -v old="$old_status" -v new="$new_status" '
      /^## Status[[:space:]]*$/ { print "## Status: " new; getline; next }
      { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  elif awk '/^---$/{fm++; next} fm==1 && /^status:/{found=1; exit} END{exit !found}' "$file" 2>/dev/null; then
    # Legacy fallback: YAML frontmatter where line 1 is not a bare `---` (e.g. no
    # leading fence, so has_status_frontmatter above declined). Retained for old manifests.
    sed -i.bak "s/^status:[[:space:]]*${old_status}/status: ${new_status}/" "$file" && rm -f "${file}.bak"
  fi
}

# Extract a metadata list-item field from a task manifest.
# Reads list-item form:  - **<Field>**: <value>
# Returns the trimmed value, or the supplied default (or empty) when absent.
# Used by the loop to read a task's Group/Wave for group/feature review granularity.
# Usage: get_task_field <file> <field-label> [default]
get_task_field() {
  local file="$1" field="$2" default="${3:-}" result
  result=$(grep -m1 -E "^\- \*\*${field}\*\*:" "$file" 2>/dev/null | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//')
  if [ -n "$result" ]; then echo "$result"; else echo "$default"; fi
}

# Count tasks with a given status in a tasks directory.
# Usage: count_tasks_by_status <tasks_dir> <status>
count_tasks_by_status() {
  local tasks_dir="$1" status="$2" count=0
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "$status" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Count every task's status into named buckets AND find the single active task,
# in one pass each — the shared replacement for the near-identical inline blocks
# duplicated across scripts/stop-hook.sh, pre-compact.sh, post-compact.sh, and
# session-context.sh (MF-009). Faithful refactor of the canonical reference —
# stop-hook.sh's counting block (bucket set, TOTAL_COUNT-increments-before-case
# order) and its active-task-scan block (iteration order, first-match-wins tie-
# break) — with exactly one new behavior: a loud INVALID/off-vocabulary arm
# (MF-002, MF-011).
#
# Output contract (consumed directly by callers after invocation — TASK-004
# repoints the four call sites at this instead of returning via stdout, so the
# existing `DONE_COUNT`/`ACTIVE_TASK`/etc. variable names already used inline at
# every call site keep working unchanged):
#   Sets these globals (not `local` — intentionally visible to the caller):
#     DONE_COUNT READY_COUNT IN_PROGRESS_COUNT IN_REVIEW_COUNT APPROVED_COUNT
#     CHANGES_COUNT BLOCKED_COUNT PLANNED_COUNT INVALID_COUNT TOTAL_COUNT
#       - one bucket per canonical status (IMPLEMENTED and IN_REVIEW both land
#         in IN_REVIEW_COUNT, matching the existing case blocks); TOTAL_COUNT is
#         incremented for every manifest found, INCLUDING invalid ones (faithful
#         to the original unconditional increment) — INVALID_COUNT makes that
#         inflation visible/trackable instead of an untracked black hole.
#     ACTIVE_TASK ACTIVE_STATUS ACTIVE_RETRY
#       - the single active task (first file, in iteration order, whose status
#         is IN_PROGRESS/CHANGES_REQUESTED/IN_REVIEW/IMPLEMENTED); empty string
#         when none exists. ACTIVE_RETRY is read from the manifest's
#         `- **Retry count**:` field, defaulting to 0.
#     INVALID_TASKS
#       - newline-separated `<task_id>:<raw_status>` entries, one per task whose
#         status resolved to INVALID; empty string when none. Callers that want
#         more than the stderr diagnostic (e.g. a summary report) read this.
#   Diagnostic: for every INVALID task, prints one line to stderr naming the
#   task id, its raw off-vocabulary status, and the source file — this is the
#   loud MF-002 arm; nothing is silently dropped.
# Usage: count_tasks_and_find_active <tasks_dir>
count_tasks_and_find_active() {
  local tasks_dir="$1"
  local task_file status task_id raw_status

  DONE_COUNT=0; READY_COUNT=0; IN_PROGRESS_COUNT=0; IN_REVIEW_COUNT=0
  APPROVED_COUNT=0; CHANGES_COUNT=0; BLOCKED_COUNT=0; PLANNED_COUNT=0
  INVALID_COUNT=0; TOTAL_COUNT=0
  ACTIVE_TASK=""; ACTIVE_STATUS=""; ACTIVE_RETRY=0
  INVALID_TASKS=""

  if [ -d "$tasks_dir" ]; then
    for task_file in "$tasks_dir"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      TOTAL_COUNT=$((TOTAL_COUNT + 1))
      status=$(get_task_status "$task_file" "PLANNED")
      case "$status" in
        DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
        READY) READY_COUNT=$((READY_COUNT + 1)) ;;
        IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
        IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
        IN_REVIEW) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
        APPROVED) APPROVED_COUNT=$((APPROVED_COUNT + 1)) ;;
        CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
        BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
        PLANNED) PLANNED_COUNT=$((PLANNED_COUNT + 1)) ;;
        *)
          task_id=$(basename "$task_file" .md)
          # get_task_status() normalizes any off-vocabulary frontmatter value to
          # the literal "INVALID" (structured-state.sh:read_task_status). Recover
          # the actual offending string directly from the frontmatter so the
          # diagnostic names the real raw status, not the normalized placeholder.
          raw_status="$status"
          if [ "$status" = "INVALID" ]; then
            raw_status=$(read_frontmatter_field "$task_file" status 2>/dev/null) || raw_status="INVALID"
          fi
          INVALID_COUNT=$((INVALID_COUNT + 1))
          if [ -n "$INVALID_TASKS" ]; then
            INVALID_TASKS="${INVALID_TASKS}
${task_id}:${raw_status}"
          else
            INVALID_TASKS="${task_id}:${raw_status}"
          fi
          echo "task-utils: ${task_id} has an invalid/off-vocabulary status '${raw_status}' — not counted into any tracked bucket (file: ${task_file})" >&2
          ;;
      esac
    done
  fi

  if [ -d "$tasks_dir" ]; then
    for task_file in "$tasks_dir"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      status=$(get_task_status "$task_file")
      if [ "$status" = "IN_PROGRESS" ] || [ "$status" = "CHANGES_REQUESTED" ] || [ "$status" = "IN_REVIEW" ] || [ "$status" = "IMPLEMENTED" ]; then
        # ACTIVE_TASK/ACTIVE_STATUS/ACTIVE_RETRY are part of the output contract
        # (see header comment) — read by callers after this function returns.
        # shellcheck disable=SC2034
        ACTIVE_TASK=$(basename "$task_file" .md)
        # shellcheck disable=SC2034
        ACTIVE_STATUS="$status"
        # shellcheck disable=SC2034
        ACTIVE_RETRY=$(grep -m1 '^\- \*\*Retry count\*\*:' "$task_file" 2>/dev/null | sed 's|.*: \([0-9]*\).*|\1|' || echo "0")
        break
      fi
    done
  fi
}

# Find the first task with IN_PROGRESS status. Returns task ID or empty string.
# Usage: get_active_task <tasks_dir>
get_active_task() {
  local tasks_dir="$1"
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "IN_PROGRESS" ]; then
      basename "$f" .md
      return
    fi
  done
  echo ""
}
