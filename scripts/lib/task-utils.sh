#!/usr/bin/env bash
# Nazgul shared task utilities — sourced by scripts that read/write task manifests.
# Eliminates duplication of get_task_status(), set_task_status(), and task counting.

_TU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TU_DIR/structured-state.sh"

# Permission bits of a path in the first stat(1) dialect that answers; non-zero
# when none can, so callers fail closed. Usage: nz_file_mode <path>
nz_file_mode() {
  local file="$1" mode=""
  # GNU stat -f means --file-system and SUCCEEDS with unrelated output, so exit
  # status cannot pick the dialect; accept a candidate only if it parses octal.
  for _nz_fm in "-f %Lp" "-c %a"; do
    # shellcheck disable=SC2086
    mode=$(stat $_nz_fm "$file" 2>/dev/null) || mode=""
    case "$mode" in ''|*[!0-7]*) mode="" ;; esac
    [ -n "$mode" ] && break
  done
  unset _nz_fm
  [ -n "$mode" ] || return 1
  printf '%s\n' "$mode"
}

# Replace <dest> with the stdout of <producer…> through a colocated staging file,
# preserving <dest>'s mode. Usage: nz_rewrite_file <dest> <producer> [args…]
nz_rewrite_file() {
  local dest="$1"; shift
  local dir tmp mode
  # A PREDICTABLE sibling can be pre-created as a symlink, and the redirection
  # then truncates, re-modes, and installs over whatever it aims at (PATCH-005).
  if [ -L "$dest" ] || [ ! -f "$dest" ]; then
    echo "nz_rewrite_file: refusing to rewrite ${dest}: not a regular non-symlink file" >&2
    return 1
  fi
  dir=$(dirname "$dest")
  mode=$(nz_file_mode "$dest") || {
    echo "nz_rewrite_file: could not read the mode of ${dest}" >&2
    return 1
  }
  tmp=$(mktemp "${dir}/.nz-rewrite.XXXXXX") || {
    echo "nz_rewrite_file: could not create a colocated staging file beside ${dest}" >&2
    return 1
  }
  if ! "$@" > "$tmp"; then
    rm -f "$tmp"
    echo "nz_rewrite_file: producer failed for ${dest}" >&2
    return 1
  fi
  if ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    echo "nz_rewrite_file: could not preserve the mode of ${dest}" >&2
    return 1
  fi
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "nz_rewrite_file: atomic replace failed for ${dest}" >&2
    return 1
  fi
  return 0
}

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
  local fm_status fm_rc status_pat
  fm_status=$(read_task_status "$1") && fm_rc=0 || fm_rc=$?
  if [ "$fm_rc" -eq 0 ]; then echo "$fm_status"; return; fi
  if [ "$fm_rc" -eq 2 ]; then echo "INVALID"; return; fi
  # lean-comments: allow-run — fm_rc==1 (no status frontmatter): fall through to legacy parsing.
  # The SPLIT moves to the label that matched: a greedy `.*:` took the LAST colon, so a colon-bearing
  # off-vocabulary status read as its final segment and the INVALID diagnostic named a truncation of
  # it (#169). SELECTION stays byte-for-byte the two spellings grep matched — widening this reader
  # past its own writer in set_task_status is the defect one level up. `|| true` so a no-match reaches
  # this function's own documented default instead of aborting an errexit caller.
  status_pat=$(nz_manifest_field_pattern_ere Status)
  result=$(awk -v pat="$status_pat" '
    {
      if ($0 ~ /^- \*\*Status\*\*:/) { if (!match(tolower($0), pat)) next }
      else if ($0 ~ /^## Status:/) { match($0, /^## Status:/) }
      else next
      v = substr($0, RSTART + RLENGTH)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$1" 2>/dev/null || true)
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
    nz_rewrite_file "$file" awk -v old="$old_status" -v new="$new_status" '
      NR==1 {print; infm=1; next}
      infm && /^status[[:space:]]*:/ {
        cur=$0; sub(/^status[[:space:]]*:[[:space:]]*/, "", cur); sub(/\r$/, "", cur)
        if (cur == old) { print "status: " new } else { print }
        next
      }
      infm && /^---[[:space:]]*$/ {infm=0; print; next}
      {print}
    ' "$file" || return 1
  elif grep -q '^## Status:' "$file" 2>/dev/null; then
    # ATX inline: ## Status: X
    nz_rewrite_file "$file" sed \
      "s/^## Status:[[:space:]]*${old_status}/## Status: ${new_status}/" "$file" || return 1
  elif grep -q '^\- \*\*Status\*\*:' "$file" 2>/dev/null; then
    # List-item: - **Status**: X
    nz_rewrite_file "$file" sed \
      "s/^\(- \*\*Status\*\*:\)[[:space:]]*${old_status}/\1 ${new_status}/" "$file" || return 1
  elif grep -q '^## Status' "$file" 2>/dev/null; then
    # ATX block: ## Status\nX — convert to inline format
    nz_rewrite_file "$file" awk -v old="$old_status" -v new="$new_status" '
      /^## Status[[:space:]]*$/ { print "## Status: " new; getline; next }
      { print }
    ' "$file" || return 1
  elif awk '/^---$/{fm++; next} fm==1 && /^status:/{found=1; exit} END{exit !found}' "$file" 2>/dev/null; then
    # Legacy fallback: YAML frontmatter where line 1 is not a bare `---` (e.g. no
    # leading fence, so has_status_frontmatter above declined). Retained for old manifests.
    nz_rewrite_file "$file" sed \
      "s/^status:[[:space:]]*${old_status}/status: ${new_status}/" "$file" || return 1
  fi
}

# lean-comments: allow-run — one anchor, and what each narrowing of it cost.
# NZ_MANIFEST_FIELD_ANCHOR is THE anchor for a `- **Field**: value` manifest line. It existed in
# two spellings — `^-[[:space:]]*\*\*` in the transition library and task-state-guard, `^\- \*\*`
# in the transition gate and the stop-hook — so a manifest written with two spaces after the dash was a LIVE
# quarantine to the Write/Edit checker and invisible to the gate, and `BLOCKED -> CANCELLED`
# laundered an integrity block into a terminal status (#232 residual, PATCH-007 item 9). Both
# spellings then pinned the dash to column 0, so an INDENTED record was seen by neither
# (PATCH-008 item 4). The tolerant form is the one kept, deliberately: a record seen and refused
# costs an operator one retry, a record NOT seen costs the block itself. Its one cost in the other
# direction is priced and accepted: the BLOCKED -> IN_REVIEW review-evidence class in
# task-transition-guard.sh also widens, onto an edge that still has to produce review evidence to
# reach DONE. It lives HERE, in the lowest lib, because get_task_field below needs it and
# task-utils cannot source the library that sources task-utils.
NZ_MANIFEST_FIELD_ANCHOR='^[[:space:]]*-[[:space:]]*\*\*'

# lean-comments: allow-run — this is the WRITER half of the anchor above, and why it must exist.
# A reader anchor that widens while its writers stay pinned is not a smaller defect than having no
# anchor: PATCH-008 item 4 widened the reader alone, and every writer of the same field kept
# matching column 0 only — so `repair`'s awk left an INDENTED record byte-identical while printing
# `recorded`, and `set_manifest_field` APPENDED a second record that the reader's `grep -m1` then
# read past (re-review #4 items 3, 4). Both are the SAME anchor in two dialects, so the ERE form is
# TRANSLITERATED from the reader's own value rather than spelled a second time — `\*` is the only
# ERE escape it uses, and tests/test-quarantine-refusal-corpus.sh asserts no backslash survives, so
# an added escape fails loudly instead of silently narrowing one dialect.
NZ_MANIFEST_FIELD_ANCHOR_ERE="${NZ_MANIFEST_FIELD_ANCHOR//\\\*/[*]}"

# nz_manifest_field_pattern_ere <field> -> that field's line in every spelling the reader accepts;
# the SOLE source of a writer's pattern. Lowercased label: apply it with `grep -iE` / awk `tolower($0)`.
nz_manifest_field_pattern_ere() {
  printf '%s%s[*][*]:' "$NZ_MANIFEST_FIELD_ANCHOR_ERE" \
    "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

# Extract a metadata list-item field from a task manifest.
# Reads list-item form:  - **<Field>**: <value>
# Returns the trimmed value, or the supplied default (or empty) when absent.
# Used by the loop to read a task's Group/Wave for group/feature review granularity.
# Usage: get_task_field <file> <field-label> [default]
get_task_field() {
  local file="$1" field="$2" default="${3:-}" result field_pat
  # lean-comments: allow-run — the shared anchor, not a fifth hand-spelling. Every consumer reads
  # "field absent" as the permissive answer (an unread `Files modified` disables the File Scope
  # guard), so the pin was fail-open — and so was the split: `sed 's/.*:'` took the LAST colon, so
  # a value ENDING in one (`review-evidence:`) trimmed to empty and this returned $default, and one
  # CONTAINING one (`2026-08-26T11:15:00Z`) returned its final segment (#169). Splitting at the same
  # pattern that selected the line is the only form that cannot disagree with the selection.
  field_pat=$(nz_manifest_field_pattern_ere "$field")
  result=$(awk -v pat="$field_pat" '
    {
      if (!match(tolower($0), pat)) next
      v = substr($0, RSTART + RLENGTH)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$file" 2>/dev/null || true)
  if [ -n "$result" ]; then echo "$result"; else echo "$default"; fi
}

# Extract the `Files modified` JSON-array field from a task manifest, one file
# per output line. The single shared accessor for the File Scope guard, the
# parallel rework guard, and the parallel-batch disjointness check (MF-025) —
# replaces three independent ad hoc comma-split parsers that could never match
# a real bracket/quote-laden value.
# On a missing field, returns empty silently. On a present-but-malformed
# (non-JSON, e.g. legacy comma-separated) value, returns empty AND emits a
# loud stderr diagnostic — mirrors the ADR-002 Decision 1 loud-not-silent
# degrade precedent; never a silent black hole.
# Usage: get_task_files_modified <file>
get_task_files_modified() {
  local file="$1" raw
  raw=$(get_task_field "$file" "Files modified")
  [ -n "$raw" ] || return 0
  if ! printf '%s\n' "$raw" | jq -r '.[]' 2>/dev/null; then
    echo "WARN: get_task_files_modified: malformed/non-JSON 'Files modified' value in $file: $raw" >&2
  fi
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
#     CHANGES_COUNT BLOCKED_COUNT PLANNED_COUNT CANCELLED_COUNT INVALID_COUNT
#     TOTAL_COUNT
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
  local task_file status task_id raw_status retry_raw retry_digits

  DONE_COUNT=0; READY_COUNT=0; IN_PROGRESS_COUNT=0; IN_REVIEW_COUNT=0
  APPROVED_COUNT=0; CHANGES_COUNT=0; BLOCKED_COUNT=0; PLANNED_COUNT=0
  CANCELLED_COUNT=0; INVALID_COUNT=0; TOTAL_COUNT=0
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
        CANCELLED) CANCELLED_COUNT=$((CANCELLED_COUNT + 1)) ;;
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
        # lean-comments: allow-run — the floor belongs at the assignment, not in the consumer.
        # TASK-008 dropped the old reader's `|| echo "0"` as dead code because "the pipeline's exit
        # status is sed's, always 0" — true WITHOUT pipefail, false WITH it, and every caller runs
        # `set -euo pipefail`. Four paths reach here as the empty string (field absent, present but
        # empty, present but non-numeric, file unreadable), and stop-hook.sh hands the result straight
        # to `jq --argjson`, which rejects empty and ends the hook before its decision:block payload
        # (#281). ADR-033's "a count that could not be read is not zero" governs a count wired to a
        # DESTRUCTIVE path; this one feeds a checkpoint field this function already initialises to 0.
        retry_raw=$(get_task_field "$task_file" "Retry count" "0")
        retry_digits="${retry_raw%%[!0-9]*}"
        # shellcheck disable=SC2034
        ACTIVE_RETRY="${retry_digits:-0}"
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
