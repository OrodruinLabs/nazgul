#!/usr/bin/env bash
set -euo pipefail

# Nazgul SubagentStop — fires when any subagent finishes. Lightweight
# observability: appends one event to the telemetry bus so /nazgul:metrics
# can report how many subagents ran per loop. Never blocks the subagent.
#
# Input: hook JSON on stdin (may include subagent name / type — recorded if
# present, but never required).

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul is not initialized here, do nothing.
[ -f "$CONFIG" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"

# Best-effort extraction of an agent identifier; default to "unknown".
AGENT="unknown"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.subagent_type // .agent_type // .name // "unknown"' 2>/dev/null || echo "unknown")
  [ -n "$AGENT" ] || AGENT="unknown"
fi

# Emit subagent_stop to the telemetry bus (replaces legacy subagents.jsonl write).
# CURRENT_ITERATION intentionally omitted — emit_event treats unset as null.
emit_event "subagent_stop" agent "$AGENT"

# Review-coverage detector: derive which task(s) a review-gate covered and record
# in review-coverage.jsonl (derived index of reviewer_verdict events — not a
# parallel state store). Runs only for review-gate subagents; non-fatal.
_record_review_coverage() {
  command -v jq >/dev/null 2>&1 || return 0

  local events_file="$NAZGUL_DIR/logs/events.jsonl"
  [ -f "$events_file" ] || return 0

  local coverage_file="$NAZGUL_DIR/logs/review-coverage.jsonl"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local iteration="${CURRENT_ITERATION:-null}"

  local granularity feat_id cur_iter
  granularity=$(jq -r '.review_gate.granularity // "task"' "$CONFIG" 2>/dev/null || echo "task")
  case "$granularity" in task|group|feature) ;; *) granularity="task" ;; esac
  feat_id=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
  cur_iter=$(jq -r '.current_iteration // "null"' "$CONFIG" 2>/dev/null || echo "null")

  # Collect distinct task_ids for THIS review run's reviewer_verdict events.
  # Scope to the current iteration when known — this isolates the current review
  # from prior runs whose verdicts may still sit in the log tail (the cause of
  # cross-run granularity misclassification). Fall back to the recent tail when
  # the iteration is unknown, so the detector never silently stops recording.
  local task_ids
  if [ "$cur_iter" != "null" ] && [ -n "$cur_iter" ]; then
    task_ids=$(tail -400 "$events_file" \
      | jq -r --argjson it "$cur_iter" 'select(.event == "reviewer_verdict" and .iteration == $it) | .task_id' 2>/dev/null \
      | sort -u | grep -v '^$' | grep -v '^null$' || true)
  fi
  if [ -z "${task_ids:-}" ]; then
    task_ids=$(tail -200 "$events_file" \
      | jq -r 'select(.event == "reviewer_verdict") | .task_id' 2>/dev/null \
      | sort -u | grep -v '^$' | grep -v '^null$' || true)
  fi

  [ -n "$task_ids" ] || return 0

  local task_count
  task_count=$(printf '%s\n' "$task_ids" | wc -l | tr -d ' ')

  mkdir -p "${coverage_file%/*}"

  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue
    case "$task_id" in
      TASK-[0-9]*) ;;
      *) continue ;;
    esac

    local review_unit granularity_used
    if [ "$task_count" -eq 1 ]; then
      review_unit="$task_id"
      granularity_used="task"
    elif [ "$granularity" = "feature" ]; then
      local feat_id
      feat_id=$(jq -r '.feat_id // "FEATURE"' "$CONFIG" 2>/dev/null || echo "FEATURE")
      review_unit="FEATURE-${feat_id}"
      granularity_used="feature"
    else
      local group
      group=$(grep "^\*\*Group\*\*:\|^- \*\*Group\*\*:" "$NAZGUL_DIR/tasks/${task_id}.md" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1 || echo "1")
      review_unit="GROUP-${group}"
      granularity_used="group"
    fi

    local iter_json
    if [ "$iteration" = "null" ] || [ -z "$iteration" ]; then
      iter_json="null"
    else
      iter_json="$iteration"
    fi

    jq -cn \
      --arg task_id "$task_id" \
      --arg review_unit "$review_unit" \
      --arg granularity_used "$granularity_used" \
      --arg feat_id "$feat_id" \
      --arg ts "$ts" \
      --argjson iteration "$iter_json" \
      '{sv:1,ts:$ts,feat_id:$feat_id,task_id:$task_id,review_unit:$review_unit,granularity_used:$granularity_used,iteration:$iteration}' \
      >> "$coverage_file" 2>/dev/null || true
  done <<< "$task_ids"
}

case "$AGENT" in
  *review-gate*)
    _record_review_coverage || true
    ;;
esac

exit 0
