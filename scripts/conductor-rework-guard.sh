#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Re-work Guard — PreToolUse on Write|Edit|MultiEdit.
# Enforces agents/conductor.md Step 5: a unit whose work is already committed
# is never re-implemented ("completed = cached, never re-executed"). No-op
# unless a conductor run is active. Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
GRAPH="$NAZGUL_DIR/conductor/graph.json"
SESSION_MARKER="$NAZGUL_DIR/conductor/.session"

# Scope: only during an active conductor run.
[ -f "$CONFIG" ] || exit 0
[ -f "$SESSION_MARKER" ] || exit 0
[ -f "$GRAPH" ] || exit 0
ENGINE=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
[ "$ENGINE" = "conductor" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .conductor.enforce.rework_guard == null then "true" else (.conductor.enforce.rework_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0
# Normalise to a repo-relative path (strip project dir prefix if present).
REL="$FILE_PATH"
case "$FILE_PATH" in
  "$NAZGUL_DIR"/*) ;;
  /*) REL="${FILE_PATH#"${CLAUDE_PROJECT_DIR:-$(pwd)}"/}" ;;
esac

# Find a committed unit that owns this file (exact match or suffix match on
# the absolute path, to tolerate either relative or absolute tool_input paths).
OWNER=$(jq -r --arg f "$FILE_PATH" --arg r "$REL" '
  .tasks | to_entries[]
  | select((.value.status=="DONE" or .value.status=="IMPLEMENTED") and (.value.commit_sha // "") != "")
  | select((.value.file_scope // []) | any(. == $f or . == $r or ($f | endswith("/" + .))))
  | .key' "$GRAPH" 2>/dev/null | head -1 || true)

if [ -n "$OWNER" ]; then
  SHA=$(jq -r --arg id "$OWNER" '.tasks[$id].commit_sha // "?"' "$GRAPH" 2>/dev/null || echo "?")
  echo "NAZGUL CONDUCTOR: Blocked — $FILE_PATH belongs to $OWNER, already implemented at $SHA; re-work blocked (agents/conductor.md Step 5)." >&2
  exit 2
fi
exit 0
