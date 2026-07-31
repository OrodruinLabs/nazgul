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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul is not initialized here, do nothing.
[ -f "$CONFIG" ] || exit 0

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

# Best-effort review-unit resolution for AGENT (TASK-002 / LR-001): finds the
# dispatch manifest whose `selected` roster lists AGENT and returns its unit.
# Pure enrichment — callers must treat "" as "unresolved", never as failure.
# Tie-break on more than one match: prefer the most-recently-created manifest
# (mirrors this codebase's other "most-recent wins" tie-breaks, e.g.
# self-audit.sh's newest-session-dir pick).
_resolve_review_unit_for_agent() {
  local reviews_dir="$NAZGUL_DIR/reviews"
  [ -d "$reviews_dir" ] || return 0

  local unit="" best_created="" manifest
  for manifest in "$reviews_dir"/*/.dispatch.json; do
    [ -f "$manifest" ] || continue
    local is_selected
    is_selected=$(jq -r --arg a "$AGENT" '(.selected // []) | any(. == $a)' "$manifest" 2>/dev/null)
    [ "$is_selected" = "true" ] || continue
    local this_unit this_created
    this_unit=$(jq -r '.unit // empty' "$manifest" 2>/dev/null)
    this_created=$(jq -r '.created_at // empty' "$manifest" 2>/dev/null)
    [ -n "$this_unit" ] || continue
    if [ -z "$unit" ] || [[ "$this_created" > "$best_created" ]]; then
      unit="$this_unit"
      best_created="$this_created"
    fi
  done
  printf '%s' "$unit"
}

# Resolves AGENT's configured maxTurns ceiling from its own spec file: the
# generated copy first (what actually ran), falling back to the committed
# template for agents dispatched standalone (e.g. `architect`) with no
# generated copy. Prints nothing (not even a trailing newline) when neither
# file exists or carries a `maxTurns:` line — the caller's numeric-suffix
# convention already turns an empty string into an explicit JSON null.
_resolve_agent_max_turns() {
  local project_root="${NAZGUL_DIR%/nazgul}"
  local spec="$project_root/.claude/agents/generated/${AGENT}.md"
  [ -f "$spec" ] || spec="$project_root/agents/${AGENT}.md"
  [ -f "$spec" ] || return 0

  grep -m1 -E '^maxTurns:[[:space:]]*[0-9]+' "$spec" 2>/dev/null | grep -oE '[0-9]+' || true
}

# Appends one review-receipt line (LR-001 / TASK-002): hashes a dispatched
# REVIEWER's own final returned text so a later re-check can bind a verdict
# to the exact text the reviewer returned. Scope is unchanged by TASK-004 —
# still reviewer-dispatch-scoped, still gated on both a resolved unit and
# non-empty final_text; only empty-return detection became universal.
_append_review_receipt() {
  local unit="$1" final_text="$2"

  local hash
  hash=$(printf '%s' "$final_text" | _rp_sha256) || return 0
  [ -n "$hash" ] || return 0

  local receipts_file="$NAZGUL_DIR/logs/review-receipts.jsonl"
  mkdir -p "${receipts_file%/*}" 2>/dev/null || return 0
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn \
    --arg unit "$unit" \
    --arg reviewer "$AGENT" \
    --arg hash "$hash" \
    --arg ts "$ts" \
    '{unit: $unit, reviewer: $reviewer, hash: $hash, ts: $ts}' \
    >> "$receipts_file" 2>/dev/null || true
}

# Universal empty-return detection (TASK-004 / TRD Scope Item 2): every
# completing subagent with a readable transcript gets this check, regardless
# of whether it maps to a review-gate dispatch — the two standalone stalls
# in the objective's own evidence (`commits_verify`, `create_feature_branch`)
# are NOT board dispatches and must still be caught. Unit resolution below is
# best-effort enrichment; it can never gate whether detection runs.
# `.transcript_path` in the hook payload is the PARENT/team session's shared
# transcript, not this subagent's own; `.agent_transcript_path` IS this exact
# completing subagent's isolated transcript file — empirically confirmed
# (TASK-002 manifest Implementation Log).
_inspect_subagent_completion() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "subagent-stop: skipping empty-return detection (jq unavailable)" >&2
    return 0
  fi
  if [ -z "$INPUT" ]; then
    echo "subagent-stop: skipping empty-return detection (no hook input)" >&2
    return 0
  fi

  local agent_transcript
  agent_transcript=$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // empty' 2>/dev/null) || true
  if [ -z "$agent_transcript" ] || [ ! -f "$agent_transcript" ]; then
    echo "subagent-stop: skipping empty-return detection (no readable agent_transcript_path)" >&2
    return 0
  fi

  # "unknown" is an explicit sentinel: "looked and found no unit" must stay
  # distinguishable from "never looked" (RULES.md §15 / LR-006, applied here
  # to this hook's own control flow rather than to a guard's pass/fail).
  local unit
  unit=$(_resolve_review_unit_for_agent)
  [ -n "$unit" ] || unit="unknown"

  # Extract the subagent's own final assistant-role message text: one JSON
  # record per line, the last record with type "assistant" is its final
  # turn, and its returned text lives in the "text"-typed blocks of
  # message.content.
  local final_text
  if ! final_text=$(jq -rs '
      [ .[] | select(.type == "assistant") ]
      | last
      | (.message.content // [])
      | map(select(.type == "text") | .text)
      | join("")
    ' "$agent_transcript" 2>/dev/null); then
    echo "subagent-stop: skipping empty-return detection (transcript parse failed: $agent_transcript)" >&2
    return 0
  fi

  if [ -z "$final_text" ]; then
    local turns_used max_turns
    turns_used=$(jq -rs '[ .[] | select(.type == "assistant") ] | length' "$agent_transcript" 2>/dev/null) || true
    max_turns=$(_resolve_agent_max_turns) || true
    emit_event "subagent_empty_return" \
      agent "$AGENT" \
      unit "$unit" \
      turns_used:n "$turns_used" \
      max_turns:n "$max_turns"
  fi

  # Receipt-hashing stays reviewer-dispatch-scoped: only when a review unit
  # resolved (not the "unknown" sentinel) AND final_text is non-empty.
  if [ "$unit" != "unknown" ] && [ -n "$final_text" ]; then
    _append_review_receipt "$unit" "$final_text"
  fi
}

_inspect_subagent_completion || true

exit 0
