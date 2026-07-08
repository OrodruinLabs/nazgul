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

# Find a committed unit that owns this file. file_scope entries are always
# repo-relative, so only an exact match against the repo-relative form (or
# against the normalized absolute path, in case a scope entry is itself
# absolute) counts. Deliberately no suffix/endswith match: piping $f into
# `any(...)` rebinds jq's `.` to the array element, not the outer $f, so a
# naive `$f | endswith("/" + .)` branch is dead code AND, if written the
# "obvious" correct way instead (`. | endswith("/" + $f)`), it reintroduces
# false positives — e.g. editing other/scripts/heartbeat.sh would match a
# scope of scripts/heartbeat.sh because it ends with "/scripts/heartbeat.sh".
OWNER=$(jq -r --arg f "$FP" --arg r "$REL" '
  .tasks | to_entries[]
  | select((.value.status=="DONE" or .value.status=="IMPLEMENTED") and (.value.commit_sha // "") != "")
  | select((.value.file_scope // []) | any(. == $f or . == $r))
  | .key' "$GRAPH" 2>/dev/null | head -1 || true)

if [ -n "$OWNER" ]; then
  SHA=$(jq -r --arg id "$OWNER" '.tasks[$id].commit_sha // "?"' "$GRAPH" 2>/dev/null || echo "?")
  echo "NAZGUL CONDUCTOR: Blocked — $FILE_PATH belongs to $OWNER, already implemented at $SHA; re-work blocked (agents/conductor.md Step 5)." >&2
  exit 2
fi
exit 0
