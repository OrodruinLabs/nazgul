#!/usr/bin/env bash
set -euo pipefail

# Nazgul SubagentStop — fires when any subagent finishes. Appends a
# telemetry event to the event bus (whenever jq, hook input, and the bus are
# available — unavailable preconditions skip with a stderr notice) so
# /nazgul:metrics can report how many subagents ran per loop. Also inspects the completing subagent's own
# transcript for an empty or verdict-less final return (subagent_empty_return
# event) and, on detection, can now BLOCK the subagent turn to force one
# bounded resume attempt — this hook is no longer "never blocks."
# Exit 0 = allow the subagent to finish (telemetry-only, or resume not taken)
# Exit 2 = block-to-continue: harness re-runs the SAME subagent with the
#          returned "reason" injected as its next turn (decision:block JSON)
#
# The resume path is capped at 2 attempts per dispatch (`_RESUME_CAP`), keyed
# under nazgul/logs/.resume-attempts/, kill-switched by guards.subagent_resume
# (default true), and skipped on the harness's own stop_hook_active re-entry
# signal. It fails open to detection-only (exit 0) on any error, disabled
# kill-switch, or cap exhaustion — never a silent pass, never an unbounded
# block.
#
# Input: hook JSON on stdin (may include subagent name / type, and this
# subagent's own transcript path — recorded/inspected if present, but
# nothing here is required for the telemetry-only path to still run).

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
# $AGENT is untrusted hook input, used directly in a path — reject anything
# but a bare identifier before it ever reaches a filesystem path.
_resolve_agent_max_turns() {
  [[ "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]] || return 0

  local project_root="${NAZGUL_DIR%/nazgul}"
  local spec="$project_root/.claude/agents/generated/${AGENT}.md"
  [ -f "$spec" ] || spec="$project_root/agents/${AGENT}.md"
  [ -f "$spec" ] || return 0

  grep -m1 -E '^maxTurns:[[:space:]]*[0-9]+' "$spec" 2>/dev/null | grep -oE '[0-9]+' || true
}

# Reviewer identification (TASK-005): a positive test only — a non-reviewer
# must never be checked for a verdict line, since only reviewers carry the
# verdict grammar contract (agents/templates/reviewer-base.md:71-98). Every
# generated reviewer name ends in "-reviewer" (agents/templates/reviewer-domains.json
# keys, plus architect-reviewer) — mirrors the *review-gate* name-keyed case
# above. $unit != "unknown" is a second, independent positive signal: AGENT
# was found in some dispatch.json's `selected` roster, which review-gate
# populates with reviewer names only.
_agent_is_reviewer() {
  local unit_arg="$1"
  case "$AGENT" in
    *-reviewer) return 0 ;;
  esac
  [ "$unit_arg" != "unknown" ]
}

# Matches the fenced YAML verdict line reviewer-base.md:71-98 specifies
# (`verdict: APPROVE|CHANGES_REQUESTED|UNVERIFIED`) — no looser than the
# contract's three literal values, no stricter than the plain "key: value"
# form reviewers actually emit.
_final_text_has_verdict_line() {
  printf '%s\n' "$1" | grep -qE '^[[:space:]]*verdict:[[:space:]]*(APPROVE|CHANGES_REQUESTED|UNVERIFIED)[[:space:]]*$'
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

# Bounded auto-resume (TASK-006 / ADR-015 Part 2 Branch A): the SubagentStop
# exit-2 probe (TASK-003) confirmed the harness continues the SAME subagent
# with the block reason injected as a new turn, so a stalled dispatch is
# fixed in-hook — no marker file, no orchestrator involvement. Gated on
# guards.subagent_resume (default true) and hard-capped independently of the
# kill-switch so a pathological repeat cannot loop.
_RESUME_CAP=2

_subagent_resume_enabled() {
  jq -r 'if .guards.subagent_resume == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true"
}

# Stable per-dispatch identifier for the attempt counter: agent_id is the
# harness's own identity for this exact subagent instance (present in the
# TASK-003 probe's stdin), constant across the SAME dispatch's resumed turns
# but distinct across separate dispatches of the same agent type.
_resume_dispatch_key() {
  local key
  key=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null) || true
  if [ -z "$key" ]; then
    local session_id
    session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
    [ -n "$session_id" ] && key="${session_id}:${AGENT}"
  fi
  if [ -z "$key" ]; then
    echo "subagent-stop: resume key fallback to bare agent name (no agent_id/session_id in hook input) for $AGENT" >&2
    key="$AGENT"
  fi
  printf '%s' "$key"
}

# One attempts file per dispatch, named by a short hash of its key (the raw
# key may contain path-unsafe characters). Directory lives under
# nazgul/logs/, mirroring stop-hook.sh's own marker/attempts-file
# convention, generalized here to one file per concurrent dispatch instead
# of a single shared file per objective. Uses the shared `_rp_sha256` helper
# (review-provenance.sh, transitively sourced via review-evidence.sh) rather
# than reimplementing the sha256sum/shasum fallback: a top-level pipeline
# with neither tool installed would abort the whole hook under `set -e`.
_resume_attempts_file() {
  local key="$1" hash
  hash=$(printf '%s' "$key" | _rp_sha256) || hash=""
  hash="${hash:0:16}"
  if [ -z "$hash" ]; then
    echo "subagent-stop: resume attempts-file hash fallback (sha256 unavailable) for $AGENT" >&2
    hash="fallback"
  fi
  printf '%s/.resume-attempts/%s' "$NAZGUL_DIR/logs" "$hash"
}

# Decides and executes the resume outcome for one detected empty-return.
# Always emits exactly one subagent_empty_return event, whose `action` field
# records the outcome: resumed | exhausted | detected_only. Fail-open: any
# unexpected error here degrades to detected_only (exit 0) with a stderr
# notice — never a silent pass, never an unbounded block.
_maybe_resume_subagent() {
  local emit_reason="$1" unit="$2" turns_used="$3" max_turns="$4"
  local action="detected_only" should_block=1 directive=""

  if [ "$(_subagent_resume_enabled)" = "true" ]; then
    local stop_hook_active
    stop_hook_active=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || stop_hook_active="false"
    [ -n "$stop_hook_active" ] || stop_hook_active="false"

    if [ "$stop_hook_active" = "true" ]; then
      # Belt-and-suspenders: the harness's own re-entry signal — never block
      # again on it, even with cap headroom left.
      echo "subagent-stop: stop_hook_active re-entry for agent $AGENT — not blocking again" >&2
    else
      local key attempts_dir attempts_file attempts=0
      key=$(_resume_dispatch_key)
      attempts_dir="$NAZGUL_DIR/logs/.resume-attempts"
      attempts_file=$(_resume_attempts_file "$key")

      if ! mkdir -p "$attempts_dir" 2>/dev/null; then
        echo "subagent-stop: resume path failed (attempts dir unwritable) — degrading to detection-only for $AGENT" >&2
      else
        if [ -f "$attempts_file" ]; then
          local raw
          raw=$(cat "$attempts_file" 2>/dev/null || echo "")
          case "$raw" in ''|*[!0-9]*) attempts=0 ;; *) attempts="$raw" ;; esac
        fi

        if [ "$attempts" -lt "$_RESUME_CAP" ]; then
          if printf '%s\n' "$((attempts + 1))" > "$attempts_file" 2>/dev/null; then
            action="resumed"
            should_block=0
            if _agent_is_reviewer "$unit"; then
              directive="Your previous turn ended without delivering a usable result. Make no further tool calls. Reply now with your final deliverable, beginning with the YAML frontmatter verdict block: a line containing ---, then a line 'verdict: APPROVE' (or CHANGES_REQUESTED or UNVERIFIED), your remaining frontmatter fields, and a closing --- line."
            else
              directive="Your previous turn ended without delivering a usable result. Make no further tool calls. Reply now with your final deliverable."
            fi
          else
            echo "subagent-stop: resume path failed (attempt write) — degrading to detection-only for $AGENT" >&2
          fi
        else
          action="exhausted"
          echo "subagent-stop: resume_exhausted — attempt cap (${_RESUME_CAP}) reached for agent $AGENT, completing without further resume" >&2
        fi
      fi
    fi
  fi

  emit_event "subagent_empty_return" \
    agent "$AGENT" \
    unit "$unit" \
    reason "$emit_reason" \
    turns_used:n "$turns_used" \
    max_turns:n "$max_turns" \
    action "$action"

  if [ "$should_block" -eq 0 ]; then
    # Dual-channel delivery. The TASK-003 probe proved empirically that the
    # stdout decision JSON + exit 2 reaches the subagent on this harness (the
    # probe's injected instruction was obeyed). The documented contract,
    # however, says exit 2 feeds STDERR to the subagent and stdout JSON is
    # only read on exit 0 — so emit the directive on stderr as well, making
    # delivery robust under either interpretation and across harness versions.
    printf '%s\n' "$directive" >&2
    jq -cn --arg r "$directive" '{"decision":"block","reason":$r}' || true
    exit 2
  fi
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
  # distinguishable from "never looked" (RULES.md §15 / ADR-009, applied here
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

  # TASK-005: a reviewer whose final_text is non-empty but carries no verdict
  # line has also delivered nothing usable — same event, distinguished by
  # `reason` so a consumer can separate "never spoke" from "spoke without
  # delivering" (TRD Scope Item 2 step 5, second detection clause).
  local emit_reason=""
  if [ -z "$final_text" ]; then
    emit_reason="empty_final_text"
  elif _agent_is_reviewer "$unit" && ! _final_text_has_verdict_line "$final_text"; then
    emit_reason="no_verdict_line"
  fi

  if [ -n "$emit_reason" ]; then
    local turns_used max_turns
    turns_used=$(jq -rs '[ .[] | select(.type == "assistant") ] | length' "$agent_transcript" 2>/dev/null) || true
    max_turns=$(_resolve_agent_max_turns) || true
    _maybe_resume_subagent "$emit_reason" "$unit" "$turns_used" "$max_turns"
  fi

  # Receipt-hashing stays reviewer-dispatch-scoped: only when a review unit
  # resolved (not the "unknown" sentinel) AND final_text is non-empty.
  if [ "$unit" != "unknown" ] && [ -n "$final_text" ]; then
    _append_review_receipt "$unit" "$final_text"
  fi
}

_inspect_subagent_completion || true

exit 0
