#!/usr/bin/env bash
# Nazgul In-Flight Marker Writer — PreToolUse on the Agent tool.
# Records that a dispatch went out, so stop-hook.sh can allow an uncounted
# hold while it is still running instead of burning an iteration on a no-op
# block (nazgul/inbox/stop-hook-blind-in-flight-iteration-burn.md, ADR-015).
#
# This hook OBSERVES, it never blocks: every exit is 0, and a failed write is
# a silent no-op, never a denied dispatch. No `set -e` on purpose — any
# command here failing must fall through to the unconditional `exit 0` at the
# bottom, not abort the script on a nonzero status.
set -uo pipefail

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# Not an initialized Nazgul project, or config unreadable — fail open (skip
# the write, never block the dispatch either way).
[ -f "$CONFIG" ] || exit 0
jq -e . "$CONFIG" >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

# Same grep-as-data extraction as parallel-dispatch-guard.sh:70 — never eval'd.
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
[ -n "$UNIT" ] || UNIT="nounit"

# Sanitize filename components to a safe basename: [A-Za-z0-9._-], no `/`, no
# `..` — same convention as scrub-stale-review-artifacts.sh:33.
_sanitize() {
  local s; s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  s="${s//../_}"
  [ -n "$s" ] && printf '%s' "$s" || printf 'unknown'
}
SAFE_AGENT=$(_sanitize "${SUBAGENT:-unknown}")
SAFE_UNIT=$(_sanitize "$UNIT")

EPOCH=$(date +%s 2>/dev/null || echo 0)
NONCE="$$-${RANDOM:-0}"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

MARKER_DIR="$NAZGUL_DIR/in-flight"
mkdir -p "$MARKER_DIR" 2>/dev/null || exit 0

MARKER_FILE="$MARKER_DIR/${SAFE_AGENT}__${SAFE_UNIT}__${EPOCH}-${NONCE}.json"
# prompt_head is stored as inert data (first ~200 chars), never eval'd.
PROMPT_HEAD=$(printf '%s' "$PROMPT" | cut -c1-200)

jq -cn --arg agent "$SUBAGENT" --arg unit "$UNIT" --arg ts "$TS" \
  --argjson epoch "$EPOCH" --arg head "$PROMPT_HEAD" \
  '{agent:$agent, unit:$unit, dispatched_at:$ts, dispatched_at_epoch:$epoch, prompt_head:$head}' \
  > "$MARKER_FILE" 2>/dev/null || true

exit 0
