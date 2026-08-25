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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RHP_LIB="$SCRIPT_DIR/lib/read-hook-payload.sh"
# A load that returns 0 having defined nothing is still no payload, so it takes
# this hook's own posture rather than exiting 127 into whatever that means here.
rhp_unavailable() {
  printf 'in-flight-marker: stdin reader unavailable: %s — fail-open, skipping the marker write\n' "$1" >&2
  exit 0
}
[ -r "$RHP_LIB" ] || rhp_unavailable "$RHP_LIB is missing or unreadable"
rhp_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_rc=$?
declare -F read_hook_payload >/dev/null && declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "$RHP_LIB defines no reader API after sourcing (source returned $rhp_rc)"

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  read_hook_payload
  if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
    hook_payload_timeout_report "in-flight-marker" "fail-open" "skipping the marker write"
    exit 0
  fi
  INPUT="$HOOK_PAYLOAD"
fi
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# Not an initialized Nazgul project, or config unreadable — fail open (skip
# the write, never block the dispatch either way).
[ -f "$CONFIG" ] || exit 0
jq -e . "$CONFIG" >/dev/null 2>&1 || exit 0

# Gated on the SAME switch as every consumer (PR #223 re-review). This used to write
# unconditionally, which was harmless while the stop-hook quarantined what it could not
# classify. It is not harmless now: the unobservable class is left in place (review #11)
# and the SessionStart sweep that retires it is itself gated on this flag (review #2), so
# with the guard OFF a marker would be written with NO retirement path at all. A guard
# that disables a subsystem must disable its producer too, not just its readers.
IFM_HOLD_ENABLED=$(jq -r 'if .guards.in_flight_hold == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
[ "$IFM_HOLD_ENABLED" = "true" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

# Dispatch class captured at write time (spec 0-C.1) — tri-state extraction, the exact
# pattern of parallel-dispatch-guard.sh:58-70; absent-field and false differ (#104, #205).
BACKGROUND=$(printf '%s' "$INPUT" | jq -r '
  (.tool_input // {}) as $i
  | if ($i | has("run_in_background")) then ($i.run_in_background | tostring) else "missing" end' \
  2>/dev/null || echo "missing")
case "$BACKGROUND" in true|false) : ;; *) BACKGROUND="missing" ;; esac
NAMED=$(printf '%s' "$INPUT" | jq -r 'if ((.tool_input.name // "") != "") then "true" else "false" end' 2>/dev/null || echo "false")

# Same grep-as-data extraction as parallel-dispatch-guard.sh:70 — never eval'd.
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
[ -n "$UNIT" ] || UNIT="nounit"

# Sanitize filename components to a safe basename: [A-Za-z0-9._-], no `/`, no
# `..` — same character allowlist as scrub-stale-review-artifacts.sh:33
# (that script rejects on a bad char; this one transforms to safe instead).
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
  --arg bg "$BACKGROUND" --arg named "$NAMED" \
  '{agent:$agent, unit:$unit, dispatched_at:$ts, dispatched_at_epoch:$epoch, prompt_head:$head, background:$bg, named:$named}' \
  > "$MARKER_FILE" 2>/dev/null || true

exit 0
