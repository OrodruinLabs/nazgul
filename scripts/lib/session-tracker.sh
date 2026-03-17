#!/usr/bin/env bash
# session-tracker.sh — filesystem-based concurrent session detection
# Adapted from gstack's session tracking pattern

_sanitize_session_id() {
  # Replace any non-alphanumeric/hyphen/underscore chars with underscore
  echo "$1" | tr -c 'A-Za-z0-9_-' '_'
}

register_session() {
  local session_id
  session_id=$(_sanitize_session_id "$1")
  local sessions_dir="${2:-hydra/sessions}"
  mkdir -p "$sessions_dir"

  jq -n \
    --arg pid "$$" \
    --arg session "$session_id" \
    --arg started "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{pid: $pid, session: $session, started: $started}' \
    > "$sessions_dir/${session_id}.lock"
}

unregister_session() {
  local session_id
  session_id=$(_sanitize_session_id "$1")
  local sessions_dir="${2:-hydra/sessions}"
  rm -f "$sessions_dir/${session_id}.lock"
}

count_active_sessions() {
  local sessions_dir="${1:-hydra/sessions}"
  if [ -d "$sessions_dir" ] && ls "$sessions_dir"/*.lock >/dev/null 2>&1; then
    ls "$sessions_dir"/*.lock 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

cleanup_stale_sessions() {
  local sessions_dir="${1:-hydra/sessions}"
  local max_age_seconds="${2:-7200}"  # 2 hours default

  [ -d "$sessions_dir" ] || return 0

  local now
  now=$(date +%s)

  for lock_file in "$sessions_dir"/*.lock; do
    [ -f "$lock_file" ] || continue
    local file_age
    # macOS uses -f %m, Linux uses -c %Y
    file_age=$(stat -f %m "$lock_file" 2>/dev/null || stat -c %Y "$lock_file" 2>/dev/null || echo 0)
    local age=$((now - file_age))
    if [ "$age" -gt "$max_age_seconds" ]; then
      rm -f "$lock_file"
    fi
  done
}

is_concurrent_session_warning() {
  local sessions_dir="${1:-hydra/sessions}"
  local count
  count=$(count_active_sessions "$sessions_dir")
  if [ "$count" -gt 1 ]; then
    echo "WARNING: $count concurrent Hydra sessions detected. State corruption risk."
    return 0
  fi
  return 1
}
