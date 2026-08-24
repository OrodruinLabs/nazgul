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
# Supplies _rp_sha256; every use is `declare -F`-guarded so an absent or broken
# library degrades this hook rather than aborting it (fail-open contract above).
# shellcheck source=lib/review-provenance.sh
source "$SCRIPT_DIR/lib/review-provenance.sh" 2>/dev/null || true

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
# Identify the dispatch by digest, never by prompt text (ADR-028). `unavailable`
# is alphabet-disjoint from hex, so "could not compute" never reads as a digest.
PROMPT_HASH="unavailable"
PROMPT_BYTES="null"
if declare -F _rp_sha256 >/dev/null 2>&1; then
  _ifm_full=$(printf '%s' "$PROMPT" | _rp_sha256 2>/dev/null) || _ifm_full=""
  if [ -n "$_ifm_full" ]; then
    PROMPT_HASH="${_ifm_full:0:16}"
  else
    echo "in-flight-marker: sha256 unavailable — prompt_hash recorded as 'unavailable'" >&2
  fi
else
  echo "in-flight-marker: _rp_sha256 not loaded — prompt_hash recorded as 'unavailable'" >&2
fi

# Bytes over the SAME stream that is hashed — `${#PROMPT}` counts characters
# under a UTF-8 locale, so it would disagree with the digest, invisibly.
_ifm_bytes=$(printf '%s' "$PROMPT" | wc -c 2>/dev/null | tr -d ' ') || _ifm_bytes=""
case "$_ifm_bytes" in ''|*[!0-9]*) _ifm_bytes="null" ;; esac
PROMPT_BYTES="$_ifm_bytes"
# --argjson with invalid JSON fails the whole write, and a missing marker is
# worse than a missing field (TRD R2). `null` is the literal, never 0.
case "$PROMPT_BYTES" in
  ''|*[!0-9]*) [ "$PROMPT_BYTES" = "null" ] || PROMPT_BYTES="null" ;;
esac

jq -cn --arg agent "$SUBAGENT" --arg unit "$UNIT" --arg ts "$TS" \
  --argjson epoch "$EPOCH" --arg hash "$PROMPT_HASH" --argjson bytes "$PROMPT_BYTES" \
  --arg bg "$BACKGROUND" --arg named "$NAMED" \
  '{agent:$agent, unit:$unit, dispatched_at:$ts, dispatched_at_epoch:$epoch, prompt_hash:$hash, prompt_bytes:$bytes, background:$bg, named:$named}' \
  > "$MARKER_FILE" 2>/dev/null || true

exit 0
