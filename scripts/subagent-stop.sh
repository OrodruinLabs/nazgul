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
# review-evidence.sh: source of resolve_review_unit(), the single shared
# fallback resolver for pre-fix events (MF-015; ADR-004 Decision 1).
source "$SCRIPT_DIR/lib/review-evidence.sh"

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

  local feat_id cur_iter
  feat_id=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
  cur_iter=$(jq -r '.current_iteration // "null"' "$CONFIG" 2>/dev/null || echo "null")

  # Collect THIS review run's reviewer_verdict events (not just task_ids) —
  # ground truth for review_unit lives on the event itself (MF-015). Scope to
  # the current iteration when known — this isolates the current review from
  # prior runs whose verdicts may still sit in the log tail (the cause of
  # cross-run granularity misclassification). Fall back to the recent tail when
  # the iteration is unknown, so the detector never silently stops recording.
  local verdict_events
  if [ "$cur_iter" != "null" ] && [ -n "$cur_iter" ]; then
    verdict_events=$(tail -400 "$events_file" \
      | jq -c --argjson it "$cur_iter" 'select(.event == "reviewer_verdict" and .iteration == $it)' 2>/dev/null || true)
  fi
  if [ -z "${verdict_events:-}" ]; then
    verdict_events=$(tail -200 "$events_file" \
      | jq -c 'select(.event == "reviewer_verdict")' 2>/dev/null || true)
  fi

  [ -n "${verdict_events:-}" ] || return 0

  local task_ids
  task_ids=$(printf '%s\n' "$verdict_events" \
    | jq -r '.task_id' 2>/dev/null | sort -u | grep -v '^$' | grep -v '^null$' || true)
  [ -n "$task_ids" ] || return 0

  mkdir -p "${coverage_file%/*}"

  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue
    case "$task_id" in
      TASK-[0-9]*) ;;
      *) continue ;;
    esac

    # Ground truth first: read review_unit directly off this task's
    # reviewer_verdict event(s) when the emitting review-gate contract
    # provides it. Only pre-fix events (no review_unit field) fall back to
    # the shared resolver — no independent group/feature re-derivation here
    # (ADR-004 Decision 1: resolve_review_unit is the single source).
    local review_unit granularity_used
    review_unit=$(printf '%s\n' "$verdict_events" \
      | jq -r --arg tid "$task_id" 'select(.task_id == $tid) | .review_unit // empty' 2>/dev/null \
      | grep -v '^$' | tail -1 || true)
    if [ -z "$review_unit" ]; then
      review_unit=$(resolve_review_unit "$NAZGUL_DIR" "$task_id")
    fi
    case "$review_unit" in
      GROUP-*) granularity_used="group" ;;
      FEATURE-*) granularity_used="feature" ;;
      *) granularity_used="task" ;;
    esac

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
