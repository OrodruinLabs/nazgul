#!/usr/bin/env bash
set -euo pipefail
# Nazgul Parallel Re-work Guard — PreToolUse on Write|Edit|MultiEdit.
# Enforces the execution.parallel dispatch contract: a task whose work is
# already committed is never re-implemented ("completed = cached, never
# re-executed"). No-op unless execution.parallel is on.
# Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
TASKS_DIR="$NAZGUL_DIR/tasks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scope: only when the parallel dispatch option is on. A present-but-corrupt
# config can't be trusted to say "parallel is off", so it fails closed instead
# of silently no-opping (MF-053, ADR-003 Decision 3).
[ -f "$CONFIG" ] || exit 0
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "NAZGUL PARALLEL: Blocked — config.json is unreadable; cannot verify parallel-dispatch safety" >&2; exit 2; }
PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG")
[ "$PARALLEL" = "true" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.rework_guard == null then "true" else (.execution.enforce.rework_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Strip a leading /private symmetrically from the incoming path, the project
# dir, and the nazgul dir. macOS symlink-normalizes /var, /tmp, etc. under
# /private, so CLAUDE_PROJECT_DIR (e.g. /var/...) and a tool-reported absolute
# file_path (e.g. /private/var/...) can disagree on the same real file; without
# this the prefix-strip below misses and the file is fail-open ALLOWED even
# though it belongs to a committed unit. No realpath dependency — the file may
# not exist yet for a Write.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FP="${FILE_PATH#/private}"
PD="${PROJECT_DIR#/private}"
ND="${NAZGUL_DIR#/private}"

# Normalise to a repo-relative path (strip project dir prefix if present).
REL="$FP"
case "$FP" in
  "$ND"/*) ;;
  /*) REL="${FP#"$PD"/}" ;;
esac

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/task-utils.sh"

# _scope_has <manifest> <abs> <rel> -> 0 iff Files modified contains the file
# (exact match against repo-relative or absolute form; no suffix matching —
# see the false-positive note in the original conductor-rework-guard). Uses
# the shared JSON-array accessor (MF-025) instead of a comma-split that can
# never match a bracket/quote-laden real manifest value.
_scope_has() {
  local mf="$1" abs="$2" rel="$3" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    { [ "$f" = "$abs" ] || [ "$f" = "$rel" ]; } && return 0
  done < <(get_task_files_modified "$mf")
  return 1
}

_has_commit() { grep -A5 '^## Commits' "$1" 2>/dev/null | grep -qE '\b[0-9a-f]{7,40}\b'; }

OWNER=""
for tf in "$TASKS_DIR"/TASK-*.md; do
  [ -f "$tf" ] || continue
  st=$(get_task_status "$tf" "")
  case "$st" in DONE|IMPLEMENTED) ;; *) continue ;; esac
  _has_commit "$tf" || continue
  if _scope_has "$tf" "$FP" "$REL"; then OWNER=$(basename "$tf" .md); break; fi
done

if [ -n "$OWNER" ]; then
  # Cross-cutting exemption: file ALSO uniquely in a commit-less IN_PROGRESS
  # task's scope -> legitimate cross-cutting edit. Zero or 2+ matches fail
  # closed (no caller-identity binding — same rule as the conductor guard).
  CURRENT_COUNT=0
  for tf in "$TASKS_DIR"/TASK-*.md; do
    [ -f "$tf" ] || continue
    st=$(get_task_status "$tf" "")
    [ "$st" = "IN_PROGRESS" ] || continue
    _has_commit "$tf" && continue
    _scope_has "$tf" "$FP" "$REL" && CURRENT_COUNT=$((CURRENT_COUNT + 1))
  done
  [ "$CURRENT_COUNT" = "1" ] && exit 0
  echo "NAZGUL PARALLEL: Blocked — $FILE_PATH belongs to $OWNER, already implemented and committed; re-work blocked." >&2
  exit 2
fi
exit 0
