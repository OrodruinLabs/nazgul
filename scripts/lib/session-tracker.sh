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
  # NO $PPID fallback (PR #223 review #5): $PPID is whatever spawned this hook —
  # hooks.json commands are quoted strings, so that is a wrapper shell that exits
  # seconds later, and the sweep would then rm a LIVE session's lock. An ABSENT pid
  # is state 2 ("never dead") and merely un-sweepable by liveness; a WRONG pid is
  # actively destructive. Prefer the honest gap.
  case "$session_pid" in ''|*[!0-9]*) session_pid="" ;; esac

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

# One shared tri-state liveness predicate — 0 live, 1 PROVABLY gone, 2 no numeric
# pid recorded, which is never "dead". rc=1 is consumed as PROOF (cleanup_stale_sessions
# deletes the lock on it), so `kill -0`'s ESRCH/EPERM conflation is resolved HERE, at
# the one predicate, never at the three consumers (PR #223 review; ADR-009).
_session_lock_is_live() {
  local lock_file="$1" lock_pid
  [ -f "$lock_file" ] || return 1
  lock_pid=$(jq -r '.pid // ""' "$lock_file" 2>/dev/null || echo "")
  if [ -z "$lock_pid" ] || ! [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  kill -0 "$lock_pid" 2>/dev/null && return 0
  # EPERM is not ESRCH: a pid we may not SIGNAL is still RUNNING, and `ps` reads it
  # without that permission. Where `ps` is absent this falls back to today's answer.
  ps -p "$lock_pid" >/dev/null 2>&1
}

# Elapsed seconds for a pid, or "" when unobtainable. `ps -o etime=` is the portable
# spelling ([[DD-]HH:]MM:SS); Linux's `etimes` is not on macOS. Used to catch a
# RECYCLED pid: a process that started AFTER the lock was written is not our session.
_pid_elapsed_seconds() {
  local pid="$1" e d hms h m sec
  e=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || return 1
  [ -n "$e" ] || return 1
  case "$e" in
    *-*) d="${e%%-*}"; hms="${e#*-}" ;;
    *)   d=0;          hms="$e" ;;
  esac
  case "$hms" in
    *:*:*) h="${hms%%:*}"; m="$(printf '%s' "$hms" | cut -d: -f2)"; sec="${hms##*:}" ;;
    *:*)   h=0;            m="${hms%%:*}";                          sec="${hms##*:}" ;;
    *)     return 1 ;;
  esac
  case "$d$h$m$sec" in *[!0-9]*) return 1 ;; esac
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$sec ))
}

# Liveness is the COUNTING path, not just the sweep's (FEAT-032 board R3): only
# a provably-dead lock is dropped, so a pid-less legacy lock still counts.
count_active_sessions() {
  local sessions_dir="${1:-nazgul/sessions}" f n=0 live
  [ -d "$sessions_dir" ] || { echo "0"; return 0; }
  for f in "$sessions_dir"/*.lock; do
    [ -f "$f" ] || continue
    live=0
    _session_lock_is_live "$f" || live=$?   # bare call would abort a `set -e` caller
    if [ "$live" -ne 1 ]; then
      n=$((n + 1))
    fi
  done
  echo "$n"
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
    local live=0
    _session_lock_is_live "$lock_file" || live=$?
    if [ "$live" -eq 0 ]; then
      # A live pid is exempt from the age rule — but ONLY if it is still OUR pid.
      # Without this, a RECYCLED pid makes the lock immortal and blocks heartbeat
      # auto-start unboundedly, which is exactly what the pre-count sweep in
      # heartbeat.sh exists to prevent (PR #223 review #1). The 2h ceiling used to
      # bound that; liveness removed the bound, so restore it by PROOF: a process
      # that has been running for LESS time than the lock has existed started after
      # the lock was written, so the pid was reused. Unobtainable elapsed time falls
      # through to the age rule rather than granting immortality.
      local lk_pid lk_elapsed lk_file_age lk_now
      lk_pid=$(jq -r '.pid // ""' "$lock_file" 2>/dev/null || echo "")
      lk_elapsed=$(_pid_elapsed_seconds "$lk_pid" 2>/dev/null || echo "")
      lk_file_age=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "0")
      case "$lk_file_age" in ''|*[!0-9]*) lk_file_age=0 ;; esac
      lk_now=$now
      if [ -n "$lk_elapsed" ] && [ "$lk_file_age" -gt 0 ] \
         && [ "$lk_elapsed" -lt $(( lk_now - lk_file_age - 5 )) ]; then
        rm -f "$lock_file"          # recycled pid — provably not the session that wrote this
        continue
      fi
      if [ -n "$lk_elapsed" ]; then
        continue                    # live AND same process: genuinely exempt
      fi
      : # elapsed unobtainable — fall through to the age rule below, never immortal
    elif [ "$live" -eq 1 ]; then
      rm -f "$lock_file"
      continue
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
  local sessions_dir="${1:-nazgul/sessions}" f live
  [ -d "$sessions_dir" ] || return 0
  # No duplicate is an ANSWER, not an error: without the guard the empty pipeline
  # exits 1 and aborts any caller running under `set -e` (FEAT-032 board R1).
  for f in "$sessions_dir"/*.lock; do
    [ -f "$f" ] || continue
    live=0
    _session_lock_is_live "$f" || live=$?
    # PROVEN live only (PR #223 review #4). The caller states "multiple LIVE sessions
    # shared one working tree" as fact and tells the operator their state is at risk;
    # a pid-less lock (state 2) is UNKNOWN liveness — the ordinary post-upgrade shape —
    # and an unknown must not be asserted as proof. Counting still treats state 2 as
    # not-dead; only this proven-collision claim demands state 0.
    if [ "$live" -ne 0 ]; then continue; fi
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
