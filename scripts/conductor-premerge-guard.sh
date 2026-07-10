#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Pre-Merge Guard — PreToolUse on Bash `git merge`.
# Enforces FEAT-009 H2: a unit branch is never merged into the feature branch
# without a recorded DONE + APPROVE verdict in graph.json — exactly how
# TASK-004 got merged unreviewed this session (the review-gate bypass).
# No-op unless a conductor run is active. Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$CMD" ] && CMD="$INPUT"
[ -z "$CMD" ] && exit 0
printf '%s' "$CMD" | grep -qE 'git[[:space:]]+merge' || exit 0

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
ENFORCE=$(jq -r 'if .conductor.enforce.premerge_guard == null then "true" else (.conductor.enforce.premerge_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

# Identify the unit from the merged branch name (feat/<display_id>/TASK-NNN),
# matched as DATA (grep), never eval'd against the command string.
UNIT=$(printf '%s' "$CMD" | grep -oE 'feat/[A-Za-z0-9_.-]+/TASK-[0-9]+' | head -1 | grep -oE 'TASK-[0-9]+' || true)
[ -n "$UNIT" ] || exit 0

STATUS=$(jq -r --arg id "$UNIT" '.tasks[$id].status // ""' "$GRAPH" 2>/dev/null || echo "")
VERDICT=$(jq -r --arg id "$UNIT" '.tasks[$id].verdict // ""' "$GRAPH" 2>/dev/null || echo "")

if [ "$STATUS" = "DONE" ] && printf '%s' "$VERDICT" | grep -qiE '^APPROVE'; then
  exit 0
fi

echo "NAZGUL CONDUCTOR: Blocked — merge of $UNIT into the feature branch has no recorded DONE+APPROVE verdict (status='${STATUS:-none}', verdict='${VERDICT:-none}'); this is the review-gate-bypass class of defect (FEAT-009 H2, agents/conductor.md Step 6)." >&2
exit 2
