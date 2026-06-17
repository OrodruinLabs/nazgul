#!/usr/bin/env bash
set -euo pipefail
# Parse /nazgul:start flags from an args string and persist them to config.json.
# Single source of truth so every start path applies flags identically.
# Usage: apply-start-flags.sh <config.json> "<args-string>"   (prints resolved mode)
CONFIG="${1:?usage: apply-start-flags.sh <config.json> <args>}"
ARGS="${2:-}"
[ -f "$CONFIG" ] || { echo "hitl"; exit 0; }

yolo=false; afk=false; hitl=false; task_pr=false
# shellcheck disable=SC2086
# Intentional word-splitting: ARGS is a single flag string and each
# whitespace-separated token is a discrete flag to classify.
for tok in $ARGS; do
  case "$tok" in
    --yolo) yolo=true ;;
    --afk) afk=true ;;
    --hitl) hitl=true ;;
    --task-pr) task_pr=true ;;
  esac
done
maxn=$(printf '%s\n' "$ARGS" | grep -oE -- '--max[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)

set_mode=""
if [ "$hitl" = true ]; then set_mode="hitl"
elif [ "$yolo" = true ] || [ "$afk" = true ]; then set_mode="afk"; fi

jqp='.'
if [ -n "$set_mode" ]; then
  jqp="$jqp | .mode=\"$set_mode\""
  if [ "$set_mode" = "afk" ]; then jqp="$jqp | .afk.enabled=true"; else jqp="$jqp | .afk.enabled=false"; fi
fi
[ "$yolo" = true ] && jqp="$jqp | .afk.yolo=true"
[ "$task_pr" = true ] && jqp="$jqp | .afk.task_pr=true"
[ -n "$maxn" ] && jqp="$jqp | .max_iterations=($maxn)"

tmp=$(mktemp)
if jq "$jqp" "$CONFIG" > "$tmp" 2>/dev/null; then mv "$tmp" "$CONFIG"; else rm -f "$tmp"; fi
jq -r '.mode // "hitl"' "$CONFIG" 2>/dev/null || echo "hitl"
