#!/usr/bin/env bash
# Nazgul heartbeat-triage — the source-agnostic selection policy for the
# automation heartbeat (FEAT-008). Kept OUT of inbox-provider.sh so any future
# provider reuses this ordering unchanged: it consumes only the provider
# contract (inbox_list / inbox_get). Candidate title/body are DATA — carried
# through jq via --argjson, never `eval`'d and never shell-expanded.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# (heartbeat hook / start skill) that own their own shell options.

# NO SENTINEL: the scalar `_NAZGUL_HEARTBEAT_TRIAGE_SOURCED` that sat here made one exported variable
# enough to leave the triage policy undefined — the 127-exit hazard nazgul-root.sh:40-49 measured.

_HB_TRIAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_HB_TRIAGE_DIR/inbox-provider.sh"
# shellcheck source=./emit-event.sh
source "$_HB_TRIAGE_DIR/emit-event.sh"

# _heartbeat_mtime <file> -> file modification time in epoch seconds (0 when
# unavailable). Tries BSD `stat -f` (macOS) then GNU `stat -c` (Linux).
_heartbeat_mtime() {
  local f="$1" m
  m=$(stat -f %m "$f" 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || m=0
  printf '%s' "${m:-0}"
}

# _heartbeat_coverage_line <scanned> <checked> <findings> <unsafe-id> <unreadable>
# <malformed> [dir] — TRD §6 line, on STDERR: stdout here is the value channel.
_heartbeat_coverage_line() {
  local scanned="$1" checked="$2" findings="$3"
  local unsafe="$4" unreadable="$5" malformed="$6" inbox_dir="${7:-}"
  local skipped=$((unsafe + unreadable + malformed))
  if [ "$scanned" -ne $((skipped + checked)) ]; then
    printf 'heartbeat-triage: INTERNAL — coverage accounting mismatch: %d scanned != %d skipped + %d checked\n' \
      "$scanned" "$skipped" "$checked" >&2
  fi
  if [ "$checked" -eq 0 ] && [ "$scanned" -gt 0 ]; then
    printf 'heartbeat-triage: NOTHING CHECKED — all %d candidates skipped\n' "$scanned" >&2
    emit_event coverage_vacuous entry_point "heartbeat-triage" \
      scanned:n "$scanned" skipped:n "$skipped" inbox_dir "$inbox_dir" || true
  fi
  printf 'heartbeat-triage: %d scanned, %d skipped (unsafe-id=%d, unreadable=%d, malformed=%d), %d checked, %d findings\n' \
    "$scanned" "$skipped" "$unsafe" "$unreadable" "$malformed" "$checked" "$findings" >&2
}

# heartbeat_pick <inbox_dir> prints the priority/age/name winner; unreadable priorities sort last.
# Stated-but-unreadable priority is announced before demotion, never collapsed into an absent value.
heartbeat_pick() {
  local inbox_dir="$1" list id get_json mtime cand raw_priority parsed_priority
  local candidates=()
  local scanned=0 checked=0 findings=0
  local skip_unsafe_id=0 skip_unreadable=0 skip_malformed=0
  list=$(inbox_list "$inbox_dir")
  if [ -z "$list" ]; then
    _heartbeat_coverage_line 0 0 0 0 0 0
    return 1
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    scanned=$((scanned + 1))
    # Untrusted id: reject anything with a path separator before touching disk.
    case "$id" in
      */* | *'\'*) skip_unsafe_id=$((skip_unsafe_id + 1)); continue ;;
    esac
    get_json=$(inbox_get "$inbox_dir" "$id") || { skip_unreadable=$((skip_unreadable + 1)); continue; }
    raw_priority=$(printf '%s' "$get_json" | jq -r 'if .priority == null then "" else (.priority | tostring) end' 2>/dev/null) || raw_priority=""
    parsed_priority=$(printf '%s' "$raw_priority" | jq -Rr 'tonumber? // ""' 2>/dev/null) || parsed_priority=""
    if [ -n "$raw_priority" ] && [ -z "$parsed_priority" ]; then
      findings=$((findings + 1))
      printf 'heartbeat-triage: candidate %s states priority "%s", which this parser cannot read — demoted to last place\n' "$id" "$raw_priority" >&2
      emit_event heartbeat_triage_unparseable candidate "$id" priority "$raw_priority" inbox_dir "$inbox_dir" || true
    fi
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
      }') || { skip_malformed=$((skip_malformed + 1)); continue; }
    checked=$((checked + 1))
    candidates+=("$cand")
  done <<EOF
$list
EOF
  _heartbeat_coverage_line "$scanned" "$checked" "$findings" \
    "$skip_unsafe_id" "$skip_unreadable" "$skip_malformed" "$inbox_dir"
  [ "${#candidates[@]}" -gt 0 ] || return 1
  printf '%s\n' "${candidates[@]}" \
    | jq -sr 'sort_by([(.priority // infinite), .mtime, .id]) | .[0].id'
}
