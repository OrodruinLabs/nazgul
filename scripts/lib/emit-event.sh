#!/usr/bin/env bash
# scripts/lib/emit-event.sh — append one canonical event line to events.jsonl
# Sourced by hook scripts; also invoked via scripts/emit-event-cli.sh by agents.
# Never executed directly.

EMIT_SCHEMA_VERSION=1
EVENTS_FILE="${EVENTS_FILE:-${NAZGUL_DIR:-}/logs/events.jsonl}"

emit_event() {
  local event_type="$1"; shift

  # Uninitialised Nazgul -> silent no-op.
  [ -z "${NAZGUL_DIR:-}" ] && return 0
  [ -z "$EVENTS_FILE" ]    && return 0

  # Honor telemetry.bus_enabled: false -> silent no-op.
  # Note: cannot use jq `//` (alternative) here — it treats `false` as falsy
  # and returns the fallback. Use an explicit null check instead.
  local bus_enabled
  bus_enabled=$(jq -r 'if .telemetry.bus_enabled == null then "true" else (.telemetry.bus_enabled | tostring) end' "${NAZGUL_DIR}/config.json" 2>/dev/null || echo "true")
  [ "$bus_enabled" = "false" ] && return 0

  local iter="${CURRENT_ITERATION:-null}"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local jq_args=()
  # shellcheck disable=SC2016
  local jq_expr='{sv:($sv|tonumber),ts:$ts,event:$event,iteration:($iter|if .=="null" then null else tonumber end)'
  jq_args+=(--arg sv "$EMIT_SCHEMA_VERSION")
  jq_args+=(--arg ts "$ts")
  jq_args+=(--arg event "$event_type")
  jq_args+=(--arg iter "$iter")

  while [ $# -ge 2 ]; do
    local raw_key="$1" val="$2"; shift 2
    local key="$raw_key" numeric=false
    case "$raw_key" in *:n) key="${raw_key%:n}"; numeric=true ;; esac
    if [ "$numeric" = true ]; then jq_args+=(--argjson "$key" "$val")
    else jq_args+=(--arg "$key" "$val"); fi
    jq_expr="${jq_expr},${key}:\$${key}"
  done
  jq_expr="${jq_expr}}"

  mkdir -p "$(dirname "$EVENTS_FILE")"

  # flock serialises concurrent SubagentStop fires (Agent Teams). Fallback:
  # O_APPEND + a single jq write() is atomic on POSIX for writes < PIPE_BUF;
  # JSONL lines are short. CONCERN 3: macOS base ships without flock -> the
  # fallback path must be exercised by macOS CI.
  local lockfile="${EVENTS_FILE}.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200; jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE" ) 200>"$lockfile"
  else
    jq -cn "${jq_args[@]}" "$jq_expr" >> "$EVENTS_FILE"
  fi

  # TODO(telemetry.max_event_lines): future rotation hook point — when
  # config.json gains max_event_lines, truncate events.jsonl to that limit here.
}
