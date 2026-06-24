#!/usr/bin/env bash
# scripts/lib/emit-event.sh — append one canonical event line to events.jsonl
# Sourced by hook scripts; also invoked via scripts/emit-event-cli.sh by agents.
# Never executed directly.

EMIT_SCHEMA_VERSION=1
EVENTS_FILE="${EVENTS_FILE:-${NAZGUL_DIR:+${NAZGUL_DIR}/logs/events.jsonl}}"

# Module-level caches — resolved once at source time, not on every call.
# bus_enabled: lazy (NAZGUL_DIR may not be set yet when sourced globally).
_EMIT_BUS_ENABLED=""
# flock availability is fixed for the lifetime of the process.
if command -v flock >/dev/null 2>&1; then _EMIT_HAS_FLOCK=1; else _EMIT_HAS_FLOCK=0; fi
# Log directory guard: tracks last EVENTS_FILE path for which mkdir -p was run.
_EMIT_DIR_READY=""

emit_event() {
  local event_type="$1"; shift

  # Uninitialised Nazgul -> silent no-op.
  [ -z "${NAZGUL_DIR:-}" ] && return 0
  [ -z "$EVENTS_FILE" ]    && return 0

  # Honor telemetry.bus_enabled: false -> silent no-op.
  # Resolved lazily on first call so NAZGUL_DIR is guaranteed to be set.
  # Note: cannot use jq `//` (alternative) here — it treats `false` as falsy
  # and returns the fallback. Use an explicit null check instead.
  if [ -z "$_EMIT_BUS_ENABLED" ]; then
    _EMIT_BUS_ENABLED=$(jq -r 'if .telemetry.bus_enabled == null then "true" else (.telemetry.bus_enabled | tostring) end' "${NAZGUL_DIR}/config.json" 2>/dev/null || echo "true")
  fi
  [ "$_EMIT_BUS_ENABLED" = "false" ] && return 0

  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local jq_args=()
  # shellcheck disable=SC2016
  local jq_expr='{sv:($sv|tonumber),ts:$ts,event:$event,iteration:$iter'
  jq_args+=(--arg sv "$EMIT_SCHEMA_VERSION")
  jq_args+=(--arg ts "$ts")
  jq_args+=(--arg event "$event_type")
  if [ -n "${CURRENT_ITERATION:-}" ]; then
    jq_args+=(--argjson iter "$CURRENT_ITERATION")
  else
    jq_args+=(--argjson iter "null")
  fi

  # Keys must be [a-zA-Z_][a-zA-Z0-9_]* — all callers are internal; no sanitization guard needed.
  while [ $# -ge 2 ]; do
    local raw_key="$1" val="$2"; shift 2
    local key="$raw_key"
    case "$raw_key" in
      *:n) key="${raw_key%:n}"; jq_args+=(--argjson "$key" "$val") ;;
      *)   jq_args+=(--arg "$key" "$val") ;;
    esac
    jq_expr="${jq_expr},${key}:\$${key}"
  done
  jq_expr="${jq_expr}}"

  # Create log dir on first emit only; ${var%/*} avoids a $(dirname) subshell.
  if [ "$_EMIT_DIR_READY" != "$EVENTS_FILE" ]; then
    mkdir -p "${EVENTS_FILE%/*}"
    _EMIT_DIR_READY="$EVENTS_FILE"
  fi

  # flock serialises concurrent SubagentStop fires (Agent Teams). Fallback:
  # O_APPEND + a single jq write() is atomic on POSIX for writes < PIPE_BUF;
  # JSONL lines are short.
  local lockfile="${EVENTS_FILE}.lock"
  if [ "$_EMIT_HAS_FLOCK" = "1" ]; then
    ( flock -x 200; jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE" ) 200>"$lockfile"
  else
    jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE" || true
  fi

}
