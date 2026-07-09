#!/usr/bin/env bash
# Nazgul heartbeat-triage — the source-agnostic selection policy for the
# automation heartbeat (FEAT-008). Kept OUT of inbox-provider.sh so any future
# provider reuses this ordering unchanged: it consumes only the provider
# contract (inbox_list / inbox_get). Candidate title/body are DATA — carried
# through jq via --argjson, never `eval`'d and never shell-expanded.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# (heartbeat hook / start skill) that own their own shell options.

[ -n "${_NAZGUL_HEARTBEAT_TRIAGE_SOURCED:-}" ] && return 0
_NAZGUL_HEARTBEAT_TRIAGE_SOURCED=1

_HB_TRIAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_HB_TRIAGE_DIR/inbox-provider.sh"

# _heartbeat_mtime <file> -> file modification time in epoch seconds (0 when
# unavailable). Tries BSD `stat -f` (macOS) then GNU `stat -c` (Linux).
_heartbeat_mtime() {
  local f="$1" m
  m=$(stat -f %m "$f" 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || m=0
  printf '%s' "${m:-0}"
}

# heartbeat_pick <inbox_dir> -> print the single winning candidate id, ordered
# deterministically by explicit priority ascending (lower = higher priority;
# missing/non-numeric priority sorts last), then age (oldest mtime first), then
# filename. Prints nothing and returns non-zero when the inbox is empty
# ("nothing actionable").
heartbeat_pick() {
  local inbox_dir="$1" list id get_json mtime cand
  local candidates=()
  list=$(inbox_list "$inbox_dir")
  [ -n "$list" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # Untrusted id: reject anything with a path separator before touching disk.
    case "$id" in
      */* | *'\'*) continue ;;
    esac
    get_json=$(inbox_get "$inbox_dir" "$id") || continue
    mtime=$(_heartbeat_mtime "$inbox_dir/$id")
    cand=$(jq -cn \
      --argjson get "$get_json" \
      --arg id "$id" \
      --argjson mtime "$mtime" \
      '{
        id: $id,
        priority: ($get.priority | if . == null then null else (tostring | tonumber? // null) end),
        mtime: $mtime,
        title: $get.title,
        body: $get.body
      }') || continue
    candidates+=("$cand")
  done <<EOF
$list
EOF
  [ "${#candidates[@]}" -gt 0 ] || return 1
  printf '%s\n' "${candidates[@]}" \
    | jq -sr 'sort_by([(.priority // infinite), .mtime, .id]) | .[0].id'
}
