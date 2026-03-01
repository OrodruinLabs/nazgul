#!/usr/bin/env bash
set -euo pipefail

# Hydra Event Router — matches events to agents using glob patterns
# Usage:
#   event-router.sh --test-match '<event_json>' '<match_json>'
#   event-router.sh --route '<event_json>' '<routes_file>'

glob_match() {
  local value="$1"
  local pattern="$2"
  local regex
  regex=$(printf '%s' "$pattern" | sed 's/\./\\./g; s/\*/[^.]*/g')
  regex="^${regex}$"
  printf '%s' "$value" | grep -qE "$regex" && return 0 || return 1
}

match_route() {
  local event_source="$1"
  local event_type="$2"
  local match_source="$3"
  local match_type="$4"

  if [ "$match_source" != "*" ] && [ "$match_source" != "$event_source" ]; then
    echo "no_match"
    return
  fi

  if glob_match "$event_type" "$match_type"; then
    echo "match"
  else
    echo "no_match"
  fi
}

if [ "${1:-}" = "--test-match" ]; then
  event_json="$2"
  match_json="$3"
  event_source=$(printf '%s' "$event_json" | jq -r '.source')
  event_type=$(printf '%s' "$event_json" | jq -r '.event_type')
  match_source=$(printf '%s' "$match_json" | jq -r '.source')
  match_type=$(printf '%s' "$match_json" | jq -r '.event_type')
  match_route "$event_source" "$event_type" "$match_source" "$match_type"
  exit 0
fi

if [ "${1:-}" = "--route" ]; then
  event_json="$2"
  routes_file="$3"
  event_source=$(printf '%s' "$event_json" | jq -r '.source')
  event_type=$(printf '%s' "$event_json" | jq -r '.event_type')

  route_count=$(jq '.routes | length' "$routes_file")
  matched_agents="[]"

  for ((i = 0; i < route_count; i++)); do
    match_source=$(jq -r ".routes[$i].match.source" "$routes_file")
    match_type=$(jq -r ".routes[$i].match.event_type" "$routes_file")

    result=$(match_route "$event_source" "$event_type" "$match_source" "$match_type")
    if [ "$result" = "match" ]; then
      agents=$(jq -c ".routes[$i].agents" "$routes_file")
      matched_agents=$(printf '%s\n%s' "$matched_agents" "$agents" | jq -s 'add | unique')
    fi
  done

  if [ "$(printf '%s' "$matched_agents" | jq 'length')" -eq 0 ]; then
    fallback=$(jq -r '.fallback_agent' "$routes_file")
    matched_agents=$(jq -nc --arg a "$fallback" '[$a]')
  fi

  printf '%s' "$matched_agents"
  exit 0
fi

echo "Usage: event-router.sh --test-match '<event>' '<match>' | --route '<event>' '<routes_file>'" >&2
exit 1
