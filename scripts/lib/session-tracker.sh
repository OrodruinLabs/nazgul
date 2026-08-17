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
  local sessions_dir="${2:-nazgul/sessions}"
  mkdir -p "$sessions_dir"

  # Identity must be liveness-checkable (kill -0), i.e. the SESSION process —
  # never this hook shell's own $$, which is dead moments later (#195/V7).
  local session_pid=""
  # The messaging socket's basename IS the session pid when exported
  # (read-only parse; RULES §22 forbids ever CONNECTING to it from here).
  case "${CLAUDE_CODE_MESSAGING_SOCKET:-}" in
    *.sock) session_pid="$(basename "${CLAUDE_CODE_MESSAGING_SOCKET%.sock}")" ;;
  esac
  case "$session_pid" in ''|*[!0-9]*) session_pid="$PPID" ;; esac

  # Tree identity for the shared-checkout warning (#195). </dev/null bounds
  # the #201 command-substitution hang class; failures degrade to "".
  local cwd toplevel branch
  cwd="$(pwd -P 2>/dev/null || pwd)"
  toplevel="$(git rev-parse --show-toplevel </dev/null 2>/dev/null || echo "")"
  branch="$(git branch --show-current </dev/null 2>/dev/null || echo "")"

  jq -n \
    --arg pid "$session_pid" \
    --arg session "$session_id" \
    --arg started "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg cwd "$cwd" --arg toplevel "$toplevel" --arg branch "$branch" \
    '{pid: $pid, session: $session, started: $started, cwd: $cwd, toplevel: $toplevel, branch: $branch}' \
    > "$sessions_dir/${session_id}.lock"
}

unregister_session() {
  local session_id
  session_id=$(_sanitize_session_id "$1")
  local sessions_dir="${2:-nazgul/sessions}"
  rm -f "$sessions_dir/${session_id}.lock"
}

count_active_sessions() {
  local sessions_dir="${1:-nazgul/sessions}"
  if [ -d "$sessions_dir" ] && ls "$sessions_dir"/*.lock >/dev/null 2>&1; then
    ls "$sessions_dir"/*.lock 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

cleanup_stale_sessions() {
  local sessions_dir="${1:-nazgul/sessions}"
  local max_age_seconds="${2:-7200}"  # 2 hours default

  [ -d "$sessions_dir" ] || return 0

  local now
  now=$(date +%s)

  local lock_files
  lock_files=$(find "$sessions_dir" -maxdepth 1 -name '*.lock' 2>/dev/null) || true
  [ -n "$lock_files" ] || return 0

  while IFS= read -r lock_file; do
    [ -f "$lock_file" ] || continue
    # Liveness outranks age (#195/V7): a live recorded pid is never swept, a
    # dead one goes immediately; legacy pid-less locks fall to the age rule.
    local lock_pid
    lock_pid=$(jq -r '.pid // ""' "$lock_file" 2>/dev/null || echo "")
    if [ -n "$lock_pid" ] && [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
      if kill -0 "$lock_pid" 2>/dev/null; then
        continue
      else
        rm -f "$lock_file"
        continue
      fi
    fi
    local file_age
    # Linux (GNU stat) uses -c %Y, macOS (BSD stat) uses -f %m
    file_age=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "0")
    # Guard against non-numeric values
    if ! [[ "$file_age" =~ ^[0-9]+$ ]]; then
      file_age=0
    fi
    local age=$((now - file_age))
    if [ "$age" -gt "$max_age_seconds" ]; then
      rm -f "$lock_file"
    fi
  done <<< "$lock_files"
}

# The first working tree recorded by >=2 LIVE locks, or "" when there is none —
# the #195 shared-checkout shape (one session committed another's staged work).
duplicate_live_toplevel() {
  local sessions_dir="${1:-nazgul/sessions}" f lp
  [ -d "$sessions_dir" ] || return 0
  # No duplicate is an ANSWER, not an error: without the guard the empty pipeline
  # exits 1 and aborts any caller running under `set -e` (FEAT-032 board R1).
  for f in "$sessions_dir"/*.lock; do
    [ -f "$f" ] || continue
    lp=$(jq -r '.pid // ""' "$f" 2>/dev/null)
    if [ -n "$lp" ] && [[ "$lp" =~ ^[0-9]+$ ]] && ! kill -0 "$lp" 2>/dev/null; then continue; fi
    jq -r '.toplevel // ""' "$f" 2>/dev/null
  done | grep -v '^$' | sort | uniq -d | head -1 || true
}

is_concurrent_session_warning() {
  local sessions_dir="${1:-nazgul/sessions}"
  local count dup_tree
  count=$(count_active_sessions "$sessions_dir")
  [ "$count" -gt 1 ] || return 1
  dup_tree=$(duplicate_live_toplevel "$sessions_dir")
  if [ -n "$dup_tree" ]; then
    echo "WARNING: multiple live Nazgul sessions shared one working tree ($dup_tree) — the #195 shared-checkout hazard: one session can commit another's staged work. Give each concurrent loop its own worktree. State corruption risk."
    return 0
  fi
  echo "WARNING: $count concurrent Nazgul sessions detected. State corruption risk."
  return 0
}
