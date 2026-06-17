#!/usr/bin/env bash
set -euo pipefail
# Parse /nazgul:start flags from an args string and persist them to config.json.
# Single source of truth so every start path applies flags identically.
# Usage: apply-start-flags.sh <config.json> "<args-string>"   (prints resolved mode)
CONFIG="${1:?usage: apply-start-flags.sh <config.json> <args>}"
ARGS="${2:-}"
[ -f "$CONFIG" ] || { echo "hitl"; exit 0; }

yolo=false; afk=false; hitl=false; task_pr=false
# Strip quoted spans first so a flag token INSIDE the objective string is not
# misread as a flag (e.g. /nazgul:start "fix the --yolo bug" must NOT enable yolo).
SCAN=$(printf '%s' "$ARGS" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')
# shellcheck disable=SC2086
# Intentional word-splitting: SCAN is a single flag string and each
# whitespace-separated token is a discrete flag to classify.
for tok in $SCAN; do
  case "$tok" in
    --yolo) yolo=true ;;
    --afk) afk=true ;;
    --hitl) hitl=true ;;
    --task-pr) task_pr=true ;;
  esac
done
maxn=$(printf '%s\n' "$SCAN" | grep -oE -- '--max[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
# Only a POSITIVE integer is valid; --max 0 (or absent) is ignored so it can't
# brick the loop (downstream `.max_iterations // 40` only defaults on null).
if [ -n "$maxn" ] && [ "$maxn" -le 0 ] 2>/dev/null; then maxn=""; fi

set_mode=""
if [ "$hitl" = true ]; then set_mode="hitl"
elif [ "$yolo" = true ] || [ "$afk" = true ]; then set_mode="afk"; fi

jqp='.'
if [ -n "$set_mode" ]; then
  # An explicit mode flag (re)sets mode AND the autonomous sub-flags to exactly
  # what was requested — so switching from a prior --yolo to --afk/--hitl CLEARS
  # the stale afk.yolo/afk.task_pr (the runtime gates on those directly).
  # Sub-flags derive from the RESOLVED mode, not the raw tokens: HITL forces all
  # autonomous sub-flags off (so `--hitl --yolo` → mode hitl with yolo cleared,
  # honoring --hitl precedence); AFK takes them from the parsed --yolo/--task-pr.
  jqp="$jqp | .mode=\"$set_mode\""
  if [ "$set_mode" = "afk" ]; then
    jqp="$jqp | .afk.enabled=true | .afk.yolo=$yolo | .afk.task_pr=$task_pr"
  else
    jqp="$jqp | .afk.enabled=false | .afk.yolo=false | .afk.task_pr=false"
  fi
else
  # No mode flag = resume: leave mode/afk.* as-is. Honor an explicit --task-pr only.
  [ "$task_pr" = true ] && jqp="$jqp | .afk.task_pr=true"
fi
[ -n "$maxn" ] && jqp="$jqp | .max_iterations=($maxn)"

tmp=$(mktemp)
if jq "$jqp" "$CONFIG" > "$tmp" 2>/dev/null; then mv "$tmp" "$CONFIG"; else rm -f "$tmp"; fi
jq -r '.mode // "hitl"' "$CONFIG" 2>/dev/null || echo "hitl"
