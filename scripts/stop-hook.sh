#!/usr/bin/env bash
set -euo pipefail

# Nazgul Stop Hook — Loop engine and state management
# Exit 0 = allow stop (loop ends)
# Exit 2 = block stop (loop continues) with stderr message

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
PLAN="$NAZGUL_DIR/plan.md"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/session-tracker.sh"
source "$SCRIPT_DIR/lib/review-evidence.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/emit-event.sh"

# If Nazgul not initialized, allow stop
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Clean up session lock on exit — read persisted ID to match session-context.sh
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -f "$NAZGUL_DIR/.session_id" ]; then
  SESSION_ID=$(cat "$NAZGUL_DIR/.session_id")
fi
[ -n "$SESSION_ID" ] && unregister_session "$SESSION_ID" "$NAZGUL_DIR/sessions"

# Read current state (batched into single jq call)
CONFIG_STATE=$(jq -r '[
  (.current_iteration // 0),
  (.max_iterations // 40),
  (.mode // "hitl"),
  (.safety.consecutive_failures // 0),
  (.safety.max_consecutive_failures // 5),
  (.afk.yolo // false),
  (.afk.task_pr // false)
] | join("\t")' "$CONFIG" 2>/dev/null || echo "0\t40\thitl\t0\t5\tfalse\tfalse")
IFS=$'\t' read -r ITERATION MAX_ITER MODE CONSEC_FAILURES MAX_CONSEC YOLO_MODE TASK_PR_MODE <<< "$CONFIG_STATE"
# completion_promise is checked by the prompt-layer Stop hook, not this script

# Review granularity (review_gate.granularity): "task" (default — review board
# fires per task at IMPLEMENTED), "group" (one review per parallel wave/group),
# or "feature" (one review over base..HEAD once ALL tasks are IMPLEMENTED).
# Any unrecognized/legacy/absent value falls back to "task" so existing projects
# and hand-edited configs are unchanged.
GRANULARITY=$(jq -r '.review_gate.granularity // "task"' "$CONFIG" 2>/dev/null || echo "task")
case "$GRANULARITY" in task|group|feature) ;; *) GRANULARITY="task" ;; esac

# --- Pause flag check (for /nazgul:pause skill) ---
# Pause is STICKY: once paused, every Stop allows the stop (exit 0) and the flag
# stays true so the loop never silently self-resumes. The flag is cleared only by
# /nazgul:start on an explicit resume (see skills/start "Reset Loop Counters").
# An earlier version cleared paused here on the first Stop, so a pause never held
# past one iteration.
PAUSED=$(jq -r '.paused // false' "$CONFIG")
if [ "$PAUSED" = "true" ]; then
  exit 0
fi

# --- AFK timeout enforcement (3.5) ---
AFK_ENABLED=$(jq -r '.afk.enabled // false' "$CONFIG")
AFK_TIMEOUT=$(jq -r '.afk.timeout_minutes // 90' "$CONFIG")
if [ "$AFK_ENABLED" = "true" ] && [ "$AFK_TIMEOUT" != "null" ]; then
  # Session start = objective_set_at (primary). Fallbacks, both retention-safe-ish:
  # the durable never-pruned iteration log's first line, then (last resort) the
  # oldest surviving checkpoint.
  SESSION_START=$(jq -r '.objective_set_at // ""' "$CONFIG")
  if [ -z "$SESSION_START" ] || [ "$SESSION_START" = "null" ]; then
    if [ -f "$NAZGUL_DIR/logs/iterations.jsonl" ]; then
      SESSION_START=$(head -1 "$NAZGUL_DIR/logs/iterations.jsonl" 2>/dev/null | jq -r '.timestamp // ""' 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$SESSION_START" ] || [ "$SESSION_START" = "null" ]; then
    FIRST_CHECKPOINT=$(ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | tail -1 || true)
    [ -n "$FIRST_CHECKPOINT" ] && SESSION_START=$(jq -r '.timestamp // ""' "$FIRST_CHECKPOINT")
  fi
  if [ -n "$SESSION_START" ] && [ "$SESSION_START" != "null" ]; then
    # Convert timestamps to epoch seconds for comparison
    if command -v date >/dev/null 2>&1; then
      # macOS date vs GNU date
      if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$SESSION_START" "+%s" >/dev/null 2>&1; then
        START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$SESSION_START" "+%s" 2>/dev/null || echo "0")
      else
        START_EPOCH=$(date -d "$SESSION_START" "+%s" 2>/dev/null || echo "0")
      fi
      NOW_EPOCH=$(date "+%s")
      if [ "$START_EPOCH" -gt 0 ]; then
        ELAPSED_MINUTES=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
        if [ "$ELAPSED_MINUTES" -ge "$AFK_TIMEOUT" ]; then
          echo "Nazgul: AFK timeout reached (${ELAPSED_MINUTES}m >= ${AFK_TIMEOUT}m). Stopping." >&2
          exit 0
        fi
      fi
    fi
  fi
fi

# Increment iteration
NEW_ITER=$((ITERATION + 1))
jq --argjson iter "$NEW_ITER" '.current_iteration = $iter' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
# CURRENT_ITERATION is read by emit_event() (sourced from lib/emit-event.sh).
# shellcheck disable=SC2034
CURRENT_ITERATION="$NEW_ITER"

# --- Budget accumulation (cost governor; estimate, not metered spend) ---
BUDGET_ENABLED=$(jq -r '.budget.enabled // false' "$CONFIG")
BUDGET_EST=0
# Coerce at read time: spent_usd is written into the checkpoint via --argjson on
# EVERY run (even when budget is disabled), so a non-numeric hand-edited value
# would otherwise abort the hook mid-iteration.
BUDGET_SPENT=$(jq -r '(.budget.spent_usd // 0) | tonumber? // 0' "$CONFIG")
if [ "$BUDGET_ENABLED" = "true" ]; then
  # Coerce to a number and default on any non-numeric/hand-edited value, so a
  # malformed budget can never make a downstream jq --argjson abort the hook
  # mid-iteration (after current_iteration was already incremented).
  BUDGET_EST=$(jq -r '
    (.budget.per_iteration_usd) as $explicit
    | (if $explicit != null then $explicit
       else ((.budget.model_iteration_cost // {})[(.models.implementation // "sonnet")]
             // (.budget.model_iteration_cost // {}).sonnet // 0.30)
       end)
    | tonumber? // 0.30
  ' "$CONFIG")
  BUDGET_SPENT=$(jq -r --argjson est "$BUDGET_EST" '((.budget.spent_usd // 0) | tonumber? // 0) + $est' "$CONFIG")
  jq --argjson s "$BUDGET_SPENT" '.budget.spent_usd = $s' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

  # Emit budget_threshold on first crossing of 50% / 90%; deduped via config flags.
  BUDGET_MAX_THRESHOLD=$(jq -r '(.budget.max_usd | tonumber?) // empty' "$CONFIG" 2>/dev/null || true)
  if [ -n "$BUDGET_MAX_THRESHOLD" ] && \
     awk -v m="$BUDGET_MAX_THRESHOLD" 'BEGIN{exit !(m > 0)}'; then
    if awk -v s="$BUDGET_SPENT" -v m="$BUDGET_MAX_THRESHOLD" \
         'BEGIN{exit !(s/m >= 0.90)}'; then
      EMITTED90=$(jq -r '._budget_threshold_90_emitted // false' "$CONFIG" 2>/dev/null || echo "false")
      if [ "$EMITTED90" = "false" ]; then
        emit_event "budget_threshold" \
          spent_usd:n "$BUDGET_SPENT" max_usd:n "$BUDGET_MAX_THRESHOLD" pct:n "90"
        jq '._budget_threshold_90_emitted = true' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      fi
    elif awk -v s="$BUDGET_SPENT" -v m="$BUDGET_MAX_THRESHOLD" \
           'BEGIN{exit !(s/m >= 0.50)}'; then
      EMITTED50=$(jq -r '._budget_threshold_50_emitted // false' "$CONFIG" 2>/dev/null || echo "false")
      if [ "$EMITTED50" = "false" ]; then
        emit_event "budget_threshold" \
          spent_usd:n "$BUDGET_SPENT" max_usd:n "$BUDGET_MAX_THRESHOLD" pct:n "50"
        jq '._budget_threshold_50_emitted = true' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      fi
    fi
  fi
fi

# Count tasks by status
DONE_COUNT=0
READY_COUNT=0
IN_PROGRESS_COUNT=0
IN_REVIEW_COUNT=0
APPROVED_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
PLANNED_COUNT=0
TOTAL_COUNT=0

if [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(get_task_status "$task_file" "PLANNED")
    case "$STATUS" in
      DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
      READY) READY_COUNT=$((READY_COUNT + 1)) ;;
      IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
      IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      IN_REVIEW) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      APPROVED) APPROVED_COUNT=$((APPROVED_COUNT + 1)) ;;
      CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
      BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
      PLANNED) PLANNED_COUNT=$((PLANNED_COUNT + 1)) ;;
    esac
  done
fi

# --- REVIEW GATE ENFORCEMENT (Layer 2 — reactive safety net) ---
# Validate that no tasks are DONE without review evidence (shared lib: review-evidence.sh)
# First violation: reset DONE → IMPLEMENTED with diagnostics. Second consecutive
# violation for the same task: escalate to BLOCKED with remediation (no livelock).
# In YOLO mode, APPROVED tasks have been locally reviewed; DONE only happens via PR merge
REQUIRE_PROVENANCE=$(jq -r 'if .review_gate.require_provenance == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
REVIEW_VIOLATIONS=""
if { [ "$YOLO_MODE" != "true" ] || [ "$TASK_PR_MODE" != "true" ]; } && [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    TASK_ID=$(basename "$task_file" .md)
    # Independent 2-strike ladders: evidence violations (_review_reset_counts)
    # and provenance violations (_provenance_reset_counts) no longer share a
    # counter, so a genuinely-first provenance violation right after an
    # evidence violation gets its own grace reset instead of escalating
    # straight to BLOCKED.
    EVID_RESET_COUNT=$(jq -r --arg t "$TASK_ID" '.safety._review_reset_counts[$t] // 0' "$CONFIG" 2>/dev/null || echo "0")
    case "$EVID_RESET_COUNT" in (*[!0-9]*|'') EVID_RESET_COUNT=0 ;; esac
    PROV_RESET_COUNT=$(jq -r --arg t "$TASK_ID" '.safety._provenance_reset_counts[$t] // 0' "$CONFIG" 2>/dev/null || echo "0")
    case "$PROV_RESET_COUNT" in (*[!0-9]*|'') PROV_RESET_COUNT=0 ;; esac

    if [ "$STATUS" = "DONE" ]; then
      EVIDENCE_PROBLEMS=$(validate_review_evidence "$NAZGUL_DIR" "$TASK_ID") || true
      if [ -n "$EVIDENCE_PROBLEMS" ]; then
        MISSING_LIST=$(echo "$EVIDENCE_PROBLEMS" | awk 'NF>1 {out = out sep $2; sep = ", "} NF==1 {out = out sep $1; sep = ", "} END {print out}')
        if [ "$EVID_RESET_COUNT" -ge 1 ]; then
          # Second consecutive violation — escalate to BLOCKED with remediation
          set_task_status "$task_file" "DONE" "BLOCKED"
          BLOCKED_REASON_TEXT="review evidence missing (${MISSING_LIST}) — run /nazgul:review --materialize ${TASK_ID}"
          if grep -q '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null; then
            awk -v reason="- **Blocked reason**: ${BLOCKED_REASON_TEXT}" \
              '/^\- \*\*Blocked reason\*\*:/ { print reason; next } { print }' \
              "$task_file" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"
          else
            echo "- **Blocked reason**: ${BLOCKED_REASON_TEXT}" >> "$task_file"
          fi
          jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
          DONE_COUNT=$((DONE_COUNT - 1))
          BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
          REVIEW_VIOLATIONS="${REVIEW_VIOLATIONS}NAZGUL REVIEW GATE VIOLATION: ${TASK_ID} escalated to BLOCKED — review evidence missing: ${MISSING_LIST}. Run /nazgul:review --materialize ${TASK_ID}
"
        else
          # First violation — reset to IMPLEMENTED with diagnostics
          set_task_status "$task_file" "DONE" "IMPLEMENTED"
          jq --arg t "$TASK_ID" '.safety._review_reset_counts[$t] = 1' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
          DONE_COUNT=$((DONE_COUNT - 1))
          IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1))
          REVIEW_VIOLATIONS="${REVIEW_VIOLATIONS}NAZGUL REVIEW GATE VIOLATION: ${TASK_ID} reset DONE → IMPLEMENTED — missing/unapproved reviews: ${MISSING_LIST}. Fix: spawn review-gate for ${TASK_ID}, or run /nazgul:review --materialize ${TASK_ID}
"
        fi
      else
        # Evidence passed — gate on tamper/staleness provenance next (own bounded
        # reset→IMPLEMENTED→BLOCKED counter; require_provenance=false or a valid/legacy
        # manifest is a no-op).
        PROVENANCE_PROBLEMS=""
        if [ "$REQUIRE_PROVENANCE" = "true" ]; then
          PROVENANCE_PROBLEMS=$(validate_review_provenance "$NAZGUL_DIR" "$TASK_ID") || true
        fi
        if [ -n "$PROVENANCE_PROBLEMS" ]; then
          PROVENANCE_LIST=$(echo "$PROVENANCE_PROBLEMS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
          if [ "$PROV_RESET_COUNT" -ge 1 ]; then
            # Second consecutive violation — escalate to BLOCKED with remediation
            set_task_status "$task_file" "DONE" "BLOCKED"
            BLOCKED_REASON_TEXT="review provenance invalid (${PROVENANCE_LIST}) — re-run review-gate so a fresh diff-bound dispatch manifest is written"
            if grep -q '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null; then
              awk -v reason="- **Blocked reason**: ${BLOCKED_REASON_TEXT}" \
                '/^\- \*\*Blocked reason\*\*:/ { print reason; next } { print }' \
                "$task_file" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"
            else
              echo "- **Blocked reason**: ${BLOCKED_REASON_TEXT}" >> "$task_file"
            fi
            # Evidence passed to reach this branch — clear its (now-stale) counter too,
            # so a later fresh evidence issue doesn't over-escalate as a 2nd strike.
            jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t]) | del(.safety._provenance_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
            DONE_COUNT=$((DONE_COUNT - 1))
            BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
            REVIEW_VIOLATIONS="${REVIEW_VIOLATIONS}NAZGUL REVIEW GATE VIOLATION: ${TASK_ID} escalated to BLOCKED — review provenance invalid: ${PROVENANCE_LIST}. Re-run review-gate so a fresh diff-bound dispatch manifest is written for ${TASK_ID}
"
          else
            # First violation — reset to IMPLEMENTED with diagnostics.
            # Evidence passed to reach this branch — clear its (now-stale) counter so
            # the two gates' ladders stay independent (evidence is currently valid).
            set_task_status "$task_file" "DONE" "IMPLEMENTED"
            jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t]) | .safety._provenance_reset_counts[$t] = 1' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
            DONE_COUNT=$((DONE_COUNT - 1))
            IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1))
            REVIEW_VIOLATIONS="${REVIEW_VIOLATIONS}NAZGUL REVIEW GATE VIOLATION: ${TASK_ID} reset DONE → IMPLEMENTED — review provenance invalid: ${PROVENANCE_LIST}. Fix: re-run review-gate so a fresh diff-bound dispatch manifest is written for ${TASK_ID}
"
          fi
        elif [ "$EVID_RESET_COUNT" != "0" ] || [ "$PROV_RESET_COUNT" != "0" ]; then
          # Evidence and provenance are both now valid — clear both stale counters
          jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t]) | del(.safety._provenance_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
        fi
      fi
    elif { [ "$EVID_RESET_COUNT" != "0" ] || [ "$PROV_RESET_COUNT" != "0" ]; } && [ "$STATUS" != "IMPLEMENTED" ] && [ "$STATUS" != "IN_REVIEW" ]; then
      # Task left DONE for a non-repair state — clear both stale counters.
      # IMPLEMENTED/IN_REVIEW are the repair path the reset itself creates: the
      # counter must survive them, or a later bad DONE restarts at zero and
      # never escalates. Valid evidence (branch above) still clears it.
      jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t]) | del(.safety._provenance_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
    fi
  done
  # Emitted here (in addition to CONTINUE_MSG) so violations are visible even on
  # exit-0 paths (max iterations, consecutive failures) where CONTINUE_MSG never prints.
  if [ -n "$REVIEW_VIOLATIONS" ]; then
    printf '%s' "$REVIEW_VIOLATIONS" >&2
  fi
fi

# Track progress for consecutive failure detection
# In YOLO mode, APPROVED counts as progress alongside DONE
PREV_DONE=$(jq -r '.safety._prev_done_count // 0' "$CONFIG")
if [ "$YOLO_MODE" = "true" ]; then
  PROGRESS_COUNT=$((DONE_COUNT + APPROVED_COUNT))
else
  PROGRESS_COUNT=$DONE_COUNT
fi
if [ "$PROGRESS_COUNT" -gt "$PREV_DONE" ]; then
  # Progress made — reset consecutive failures
  CONSEC_FAILURES=0
else
  # No progress
  CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
fi
jq --argjson cf "$CONSEC_FAILURES" --argjson pd "$PROGRESS_COUNT" \
  '.safety.consecutive_failures = $cf | .safety._prev_done_count = $pd' \
  "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

# Find active task
ACTIVE_TASK=""
ACTIVE_STATUS=""
ACTIVE_RETRY=0
ACTIVE_BLOCKED_REASON=""
for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
  [ -f "$task_file" ] || continue
  STATUS=$(get_task_status "$task_file")
  if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "IN_REVIEW" ] || [ "$STATUS" = "IMPLEMENTED" ]; then
    ACTIVE_TASK=$(basename "$task_file" .md)
    ACTIVE_STATUS="$STATUS"
    ACTIVE_RETRY=$(grep -m1 '^\- \*\*Retry count\*\*:' "$task_file" 2>/dev/null | sed 's|.*: \([0-9]*\).*|\1|' || echo "0")
    break
  fi
done

# Check for BLOCKED tasks and capture blocked reason
if [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    if [ "$STATUS" = "BLOCKED" ]; then
      ACTIVE_BLOCKED_REASON=$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
      break
    fi
  done
fi

# If no active task, find first READY
if [ -z "$ACTIVE_TASK" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    if [ "$STATUS" = "READY" ]; then
      ACTIVE_TASK=$(basename "$task_file" .md)
      ACTIVE_STATUS="READY"
      break
    fi
  done
fi

# --- REVIEW GRANULARITY: aggregate-review gating (group / feature) ---------------
# In "task" mode this whole block is a no-op: review-gate dispatches per task at
# IMPLEMENTED (the existing CONTINUE_MSG dispatch below).
#
# In "group"/"feature" mode, tasks are advanced to IMPLEMENTED and *parked* until
# the whole review unit is built, then ONE review board pass covers the combined
# diff. We compute:
#   AGGREGATE_REVIEW_READY  — the unit is fully IMPLEMENTED and is the next thing
#                             to review (no earlier unit still pending work).
#   AGGREGATE_REVIEW_SCOPE  — "group <N>" or "feature" (for messaging / scope).
#   AGGREGATE_REVIEW_TASKS  — space-separated task IDs in the unit awaiting review.
# When the active task is a *parked* IMPLEMENTED task but its unit is NOT yet
# complete, we re-select the next READY task so the loop keeps implementing
# instead of prematurely dispatching a single-task review.
AGGREGATE_REVIEW_READY="false"
AGGREGATE_REVIEW_SCOPE=""
AGGREGATE_REVIEW_TASKS=""
AWAITING_AGGREGATE_REVIEW="false"
if [ "$GRANULARITY" != "task" ] && [ -d "$NAZGUL_DIR/tasks" ]; then
  # The "active group" is the group of the lowest-numbered task that is not yet
  # DONE (group mode reviews one wave/group at a time, in order). In feature mode
  # the unit is ALL non-DONE tasks regardless of group.
  ACTIVE_GROUP=""
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    [ "$STATUS" = "DONE" ] && continue
    ACTIVE_GROUP=$(get_task_field "$task_file" "Group" "$(get_task_field "$task_file" "Wave" "1")")
    break
  done

  # Walk the review unit: in group mode, only tasks whose Group matches ACTIVE_GROUP;
  # in feature mode, every non-DONE task. The unit is "review-ready" when it has at
  # least one task and every task in it is IMPLEMENTED (none still READY/IN_PROGRESS/
  # CHANGES_REQUESTED/BLOCKED). A BLOCKED task holds the whole unit back.
  UNIT_TOTAL=0
  UNIT_IMPLEMENTED=0
  UNIT_BLOCKED=0
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    [ "$STATUS" = "DONE" ] && continue
    if [ "$GRANULARITY" = "group" ]; then
      TGROUP=$(get_task_field "$task_file" "Group" "$(get_task_field "$task_file" "Wave" "1")")
      [ "$TGROUP" = "$ACTIVE_GROUP" ] || continue
    fi
    UNIT_TOTAL=$((UNIT_TOTAL + 1))
    case "$STATUS" in
      IMPLEMENTED|IN_REVIEW)
        UNIT_IMPLEMENTED=$((UNIT_IMPLEMENTED + 1))
        AGGREGATE_REVIEW_TASKS="${AGGREGATE_REVIEW_TASKS}$(basename "$task_file" .md) "
        ;;
      BLOCKED) UNIT_BLOCKED=$((UNIT_BLOCKED + 1)) ;;
    esac
  done
  AGGREGATE_REVIEW_TASKS=$(printf '%s' "$AGGREGATE_REVIEW_TASKS" | sed 's/[[:space:]]*$//')

  if [ "$UNIT_TOTAL" -gt 0 ] && [ "$UNIT_IMPLEMENTED" -eq "$UNIT_TOTAL" ]; then
    AGGREGATE_REVIEW_READY="true"
    if [ "$GRANULARITY" = "group" ]; then
      AGGREGATE_REVIEW_SCOPE="group ${ACTIVE_GROUP}"
    else
      AGGREGATE_REVIEW_SCOPE="feature"
    fi
  elif [ "$UNIT_IMPLEMENTED" -gt 0 ]; then
    # Some tasks in the unit are IMPLEMENTED-but-parked, but the unit is not yet
    # complete — record the "awaiting aggregate review" condition for recovery.
    AWAITING_AGGREGATE_REVIEW="true"
  fi

  # If the active task is IMPLEMENTED (or a stale IN_REVIEW left over from a
  # per-task run whose granularity was switched to group/feature mid-run) but the
  # unit is NOT review-ready, it is a *parked* task — do not dispatch review for it.
  # Re-select the next READY task so the implementer keeps building the rest of the
  # unit. The genuine aggregate-review-in-progress case (every unit task IN_REVIEW)
  # is already excluded here: it sets AGGREGATE_REVIEW_READY=true above.
  if { [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] || [ "$ACTIVE_STATUS" = "IN_REVIEW" ]; } \
     && [ "$AGGREGATE_REVIEW_READY" != "true" ]; then
    ACTIVE_TASK=""
    ACTIVE_STATUS=""
    for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      STATUS=$(get_task_status "$task_file")
      if [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "READY" ] || [ "$STATUS" = "IN_PROGRESS" ]; then
        ACTIVE_TASK=$(basename "$task_file" .md)
        ACTIVE_STATUS="$STATUS"
        ACTIVE_RETRY=$(grep -m1 '^\- \*\*Retry count\*\*:' "$task_file" 2>/dev/null | sed 's|.*: \([0-9]*\).*|\1|' || echo "0")
        break
      fi
    done
    # No more implementable tasks but unit still not complete (e.g. everything left
    # is BLOCKED) — surface the first parked IMPLEMENTED task so recovery shows the
    # awaiting-review state rather than a phantom "no active task".
    if [ -z "$ACTIVE_TASK" ] && [ -n "$AGGREGATE_REVIEW_TASKS" ]; then
      ACTIVE_TASK=$(printf '%s' "$AGGREGATE_REVIEW_TASKS" | awk '{print $1}')
      ACTIVE_STATUS="IMPLEMENTED"
    fi
  fi
fi

# Get git state (handle repos with no commits)
GIT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
if git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_MSG=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null | cut -c9- || echo "unknown")
  GIT_DIRTY=$(git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null && echo "false" || echo "true")
else
  GIT_SHA="unknown"
  GIT_MSG="no commits yet"
  GIT_DIRTY="true"
fi

# Get branch isolation state
FEATURE_BRANCH=$(jq -r '.branch.feature // ""' "$CONFIG" 2>/dev/null || echo "")
BASE_BRANCH=$(jq -r '.branch.base // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_DIR=$(jq -r '.branch.worktree_dir // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_COUNT=0
if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
  WORKTREE_COUNT=$(find "$WORKTREE_DIR" -maxdepth 1 -name 'TASK-*' -type d 2>/dev/null | wc -l | tr -d ' ')
fi

# --- Capture files modified this iteration (GAP-012) ---
# Get the last checkpoint's commit SHA to diff against, fall back to HEAD~1
LAST_CHECKPOINT_FILE=$(ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || true)
LAST_CHECKPOINT_SHA=""
if [ -n "$LAST_CHECKPOINT_FILE" ]; then
  LAST_CHECKPOINT_SHA=$(jq -r '.git.last_commit_sha // ""' "$LAST_CHECKPOINT_FILE" 2>/dev/null || echo "")
fi

# Robust against a single-commit repo (no HEAD~1) and a missing/invalid base —
# always yields exactly one JSON array (see scripts/lib/git-utils.sh). A bare
# `git diff … | jq … || echo "[]"` here used to emit "[]\n[]" under pipefail and
# abort the hook on a fresh greenfield repo.
FILES_MODIFIED_JSON=$(files_modified_json "$PROJECT_ROOT" "$LAST_CHECKPOINT_SHA")

# --- Context rot detection (3.4) ---
COMPACTION_COUNT_FILE="$NAZGUL_DIR/.compaction_count"
COMPACTION_COUNT=0
LAST_COMPACTION_ITER=0
if [ -f "$COMPACTION_COUNT_FILE" ]; then
  COMPACTION_COUNT=$(jq -r '.count // 0' "$COMPACTION_COUNT_FILE" 2>/dev/null || echo "0")
  LAST_COMPACTION_ITER=$(jq -r '.last_compaction_iteration // 0' "$COMPACTION_COUNT_FILE" 2>/dev/null || echo "0")
fi
ITERS_SINCE_COMPACTION=$((NEW_ITER - LAST_COMPACTION_ITER))
CONTEXT_ROT_WARNING=""
if [ "$ITERS_SINCE_COMPACTION" -ge 8 ]; then
  CONTEXT_ROT_WARNING="Context may be degraded after ${ITERS_SINCE_COMPACTION} iterations without compaction. Recommended: run /compact preserving ${ACTIVE_TASK:-current} state and all blocking issues."
fi

# --- Write checkpoint with jq (GAP — safe JSON construction) ---
mkdir -p "$NAZGUL_DIR/checkpoints"
CHECKPOINT_FILE="$NAZGUL_DIR/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json"

ACTIVE_REVIEWERS=$(jq -c '.agents.reviewers // []' "$CONFIG" 2>/dev/null || echo "[]")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

ACTIVE_TASK_ID="null"
ACTIVE_TASK_STATUS="null"
ACTIVE_TASK_NEXT="null"
RECOVERY_INSTR=""

if [ -n "$ACTIVE_TASK" ]; then
  ACTIVE_TASK_ID="$ACTIVE_TASK"
  ACTIVE_TASK_STATUS="$ACTIVE_STATUS"
  ACTIVE_TASK_NEXT="Read nazgul/tasks/${ACTIVE_TASK}.md and continue work"
  RECOVERY_INSTR="Read nazgul/plan.md Recovery Pointer, then nazgul/tasks/${ACTIVE_TASK}.md for current state."
else
  RECOVERY_INSTR="Read nazgul/plan.md Recovery Pointer. No active task — find first READY task in plan."
fi

jq -n \
  --argjson iteration "$NEW_ITER" \
  --arg timestamp "$TIMESTAMP" \
  --arg mode "$MODE" \
  --arg active_task_id "$ACTIVE_TASK_ID" \
  --arg active_task_status "$ACTIVE_TASK_STATUS" \
  --argjson active_retry "$ACTIVE_RETRY" \
  --arg active_next "$ACTIVE_TASK_NEXT" \
  --argjson files_modified "$FILES_MODIFIED_JSON" \
  --argjson total "$TOTAL_COUNT" \
  --argjson done_count "$DONE_COUNT" \
  --argjson approved "$APPROVED_COUNT" \
  --argjson ready "$READY_COUNT" \
  --argjson in_progress "$IN_PROGRESS_COUNT" \
  --argjson in_review "$IN_REVIEW_COUNT" \
  --argjson changes_requested "$CHANGES_COUNT" \
  --argjson blocked "$BLOCKED_COUNT" \
  --argjson planned "$PLANNED_COUNT" \
  --arg git_branch "$GIT_BRANCH" \
  --arg git_sha "$GIT_SHA" \
  --arg git_msg "$GIT_MSG" \
  --argjson git_dirty "$GIT_DIRTY" \
  --argjson active_reviewers "$ACTIVE_REVIEWERS" \
  --argjson compactions "$COMPACTION_COUNT" \
  --argjson iters_since_compact "$ITERS_SINCE_COMPACTION" \
  --argjson consec_failures "$CONSEC_FAILURES" \
  --arg feature_branch "$FEATURE_BRANCH" \
  --arg base_branch "$BASE_BRANCH" \
  --argjson worktree_count "$WORKTREE_COUNT" \
  --arg recovery "$RECOVERY_INSTR" \
  --argjson est_iteration_usd "$BUDGET_EST" \
  --argjson budget_spent_usd "$BUDGET_SPENT" \
  --arg granularity "$GRANULARITY" \
  --arg agg_scope "$AGGREGATE_REVIEW_SCOPE" \
  --arg agg_tasks "$AGGREGATE_REVIEW_TASKS" \
  --argjson agg_ready "$AGGREGATE_REVIEW_READY" \
  --argjson agg_awaiting "$AWAITING_AGGREGATE_REVIEW" \
  '{
    iteration: $iteration,
    timestamp: $timestamp,
    mode: $mode,
    active_task: {
      id: (if $active_task_id == "null" then null else $active_task_id end),
      status: (if $active_task_status == "null" then null else $active_task_status end),
      retry_count: $active_retry,
      last_action: null,
      next_action: (if $active_next == "null" then null else $active_next end),
      files_modified_this_iteration: $files_modified
    },
    plan_snapshot: {
      total_tasks: $total,
      done: $done_count,
      approved: $approved,
      ready: $ready,
      in_progress: $in_progress,
      in_review: $in_review,
      changes_requested: $changes_requested,
      blocked: $blocked,
      planned: $planned,
      est_iteration_usd: $est_iteration_usd,
      budget_spent_usd: $budget_spent_usd
    },
    git: {
      branch: $git_branch,
      last_commit_sha: $git_sha,
      last_commit_message: $git_msg,
      uncommitted_changes: $git_dirty
    },
    branch: {
      feature: (if $feature_branch == "" then null else $feature_branch end),
      base: (if $base_branch == "" then null else $base_branch end),
      active_worktrees: $worktree_count
    },
    reviewers: {
      active: $active_reviewers,
      last_review_task: null,
      last_review_verdict: null
    },
    review_unit: {
      granularity: $granularity,
      scope: (if $agg_scope == "" then null else $agg_scope end),
      tasks_awaiting_review: (if $agg_tasks == "" then [] else ($agg_tasks | split(" ")) end),
      aggregate_review_ready: $agg_ready,
      awaiting_aggregate_review: $agg_awaiting
    },
    context_health: {
      compactions_this_session: $compactions,
      iterations_since_last_compaction: $iters_since_compact,
      consecutive_failures: $consec_failures
    },
    recovery_instructions: $recovery
  }' > "$CHECKPOINT_FILE"

# --- Recovery Pointer update in plan.md (GAP-007) ---
if [ -f "$PLAN" ]; then
  NEXT_ACTION_TEXT="Continue work on ${ACTIVE_TASK:-next READY task}"
  if [ -n "$ACTIVE_TASK" ]; then
    NEXT_ACTION_TEXT="Read nazgul/tasks/${ACTIVE_TASK}.md and continue based on status ${ACTIVE_STATUS}"
  fi
  # Granularity-aware recovery hints (survive compaction via plan.md Next Action).
  if [ "$GRANULARITY" != "task" ] && [ "$AGGREGATE_REVIEW_READY" = "true" ]; then
    NEXT_ACTION_TEXT="AGGREGATE REVIEW (${GRANULARITY}) ready for [${AGGREGATE_REVIEW_SCOPE}] — spawn review-gate over the combined diff for tasks: ${AGGREGATE_REVIEW_TASKS}"
  elif [ "$GRANULARITY" != "task" ] && [ "$AWAITING_AGGREGATE_REVIEW" = "true" ]; then
    NEXT_ACTION_TEXT="AWAITING AGGREGATE REVIEW (${GRANULARITY}) — parked IMPLEMENTED tasks (${AGGREGATE_REVIEW_TASKS}); keep implementing the rest of the review unit, do NOT review/re-implement parked tasks"
  fi

  # Update Recovery Pointer fields using awk (safe with arbitrary text in GIT_MSG)
  CHECKPOINT_NAME="nazgul/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json"
  awk \
    -v task="${ACTIVE_TASK:-none}" \
    -v action="Iteration ${NEW_ITER} completed" \
    -v next_action="$NEXT_ACTION_TEXT" \
    -v ckpt="$CHECKPOINT_NAME" \
    -v sha="$GIT_SHA" \
    -v msg="$GIT_MSG" \
    '{
      if ($0 ~ /^- \*\*Current Task:\*\*/) { print "- **Current Task:** " task }
      else if ($0 ~ /^- \*\*Last Action:\*\*/) { print "- **Last Action:** " action }
      else if ($0 ~ /^- \*\*Next Action:\*\*/) { print "- **Next Action:** " next_action }
      else if ($0 ~ /^- \*\*Last Checkpoint:\*\*/) { print "- **Last Checkpoint:** " ckpt }
      else if ($0 ~ /^- \*\*Last Commit:\*\*/) { print "- **Last Commit:** " sha " " msg }
      else { print }
    }' "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN"
fi

# --- BOARD SYNC — push status changes to external board ---
BOARD_ENABLED=$(jq -r '.board.enabled // false' "$CONFIG")
if [ "$BOARD_ENABLED" = "true" ]; then
  BOARD_PROVIDER=$(jq -r '.board.provider // ""' "$CONFIG")
  BOARD_SCRIPT="$SCRIPT_DIR/board-sync-${BOARD_PROVIDER}.sh"
  if [ -f "$BOARD_SCRIPT" ]; then
    if [ -d "$NAZGUL_DIR/tasks" ]; then
      # Read all cached statuses in one jq call
      CACHED_STATUSES=$(jq -r '.board._last_synced_status // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG" 2>/dev/null || echo "")
      declare -A CACHED_MAP=()
      while IFS=$'\t' read -r _tid _st; do
        [ -n "$_tid" ] && CACHED_MAP["$_tid"]="$_st"
      done <<< "$CACHED_STATUSES"
      # Collect status changes to batch-write after the loop
      BOARD_UPDATES=""
      for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
        [ -f "$task_file" ] || continue
        task_id=$(grep -m1 '^\- \*\*ID\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
        current_status=$(get_task_status "$task_file")
        if [ -z "$task_id" ] || [ "$current_status" = "${CACHED_MAP[$task_id]:-}" ]; then
          continue
        fi
        bash "$BOARD_SCRIPT" sync-task "$task_file" 2>/dev/null || true
        BOARD_UPDATES="${BOARD_UPDATES}${task_id}\t${current_status}\n"
      done
      # Batch-write all status changes in a single jq call
      if [ -n "$BOARD_UPDATES" ]; then
        UPDATES_JSON=$(printf '%b' "$BOARD_UPDATES" | awk -F'\t' 'NF==2{printf "%s\"%s\":\"%s\"", (NR>1?",":""), $1, $2}' | sed 's/^/{/;s/$/}/')
        jq --argjson updates "$UPDATES_JSON" \
          '.board._last_synced_status = (.board._last_synced_status // {} | . + $updates)' \
          "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
      fi
    fi
  fi
fi

# Checkpoint rotation — keep last 2 (recovery reads only the latest; one extra for diff-base)
if [ -d "$NAZGUL_DIR/checkpoints" ]; then
  ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | tail -n +3 | xargs rm -f 2>/dev/null || true
fi

# --- Auto-promote PLANNED -> READY when dependencies are met ---
if [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    if [ "$STATUS" = "PLANNED" ]; then
      DEPS=$(grep -m1 '^\- \*\*Depends on\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "none")
      if [ "$DEPS" = "none" ] || [ -z "$DEPS" ]; then
        set_task_status "$task_file" "PLANNED" "READY"
        continue
      fi
      # Check if all dependencies are DONE (or APPROVED in YOLO mode)
      ALL_DONE=true
      while IFS= read -r dep; do
        dep_file="$NAZGUL_DIR/tasks/${dep}.md"
        if [ -f "$dep_file" ]; then
          DEP_STATUS=$(get_task_status "$dep_file")
          if [ "$YOLO_MODE" = "true" ]; then
            if [ "$DEP_STATUS" != "DONE" ] && [ "$DEP_STATUS" != "APPROVED" ]; then
              ALL_DONE=false; break
            fi
          else
            if [ "$DEP_STATUS" != "DONE" ]; then
              ALL_DONE=false; break
            fi
          fi
        fi
      done <<< "$(echo "$DEPS" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
      if [ "$ALL_DONE" = true ]; then
        set_task_status "$task_file" "PLANNED" "READY"
      fi
    fi
  done
fi

# --- Git conflict detection (3.3) ---
GIT_CONFLICT_DETECTED=false
GIT_PORCELAIN=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null || echo "")
if echo "$GIT_PORCELAIN" | grep -qE '^(U.|.U|AA|DD) '; then
  GIT_CONFLICT_DETECTED=true
  # Set the active task to BLOCKED with reason "git conflict"
  if [ -n "$ACTIVE_TASK" ] && [ -f "$NAZGUL_DIR/tasks/${ACTIVE_TASK}.md" ]; then
    set_task_status "$NAZGUL_DIR/tasks/${ACTIVE_TASK}.md" ".*" "BLOCKED"
    # Add or update blocked reason
    if grep -q '^\- \*\*Blocked reason\*\*:' "$NAZGUL_DIR/tasks/${ACTIVE_TASK}.md" 2>/dev/null; then
      sed -i.bak 's/^\(- \*\*Blocked reason\*\*:\) .*/\1 git conflict — unmerged files detected/' "$NAZGUL_DIR/tasks/${ACTIVE_TASK}.md" && rm -f "$NAZGUL_DIR/tasks/${ACTIVE_TASK}.md.bak"
    fi
    ACTIVE_BLOCKED_REASON="git conflict"
    # Emit blocked event (pure observer; state already set by set_task_status above).
    emit_event "blocked" task_id "${ACTIVE_TASK:-unknown}" reason "git conflict"
  fi
fi

# --- Iteration boundary emit (replaces legacy iterations.jsonl write) ---
# Emit iteration_boundary to the telemetry bus. Pure observer after all state
# writes; does not gate, reorder, or replace any set_task_status call.
emit_event "iteration_boundary" \
  active_task "${ACTIVE_TASK:-none}" \
  active_status "${ACTIVE_STATUS:-none}" \
  done:n "$DONE_COUNT" \
  total:n "$TOTAL_COUNT" \
  git_sha "$GIT_SHA" \
  blocked_reason "${ACTIVE_BLOCKED_REASON:-}" \
  budget_spent_usd:n "$BUDGET_SPENT"

# --- EXIT CONDITIONS ---

# 0. No tasks exist — nothing to loop on
if [ "$TOTAL_COUNT" -eq 0 ]; then
  exit 0
fi

# 1. All tasks complete
# YOLO mode: loop completes when all tasks are APPROVED or DONE
# Non-YOLO: loop completes when all tasks are DONE
if [ "$TOTAL_COUNT" -gt 0 ]; then
  IS_COMPLETE=false
  if [ "$YOLO_MODE" = "true" ]; then
    [ "$((APPROVED_COUNT + DONE_COUNT))" -eq "$TOTAL_COUNT" ] && IS_COMPLETE=true
  elif [ "$DONE_COUNT" -eq "$TOTAL_COUNT" ]; then
    IS_COMPLETE=true
  fi

  if [ "$IS_COMPLETE" = "true" ]; then
    # --- Post-loop learning gate (mandatory; honors opt-out) ------------------
    # Distilling candidate Learned Rules is otherwise advisory — only the start
    # skill's OBJECTIVE_COMPLETE prose asks for it, so it silently gets skipped.
    # Gate loop completion on it: block the stop with a DELEGATE instruction until
    # the learner has run and recorded a marker for this objective. No-op when
    # learning is disabled. A bounded attempt counter keeps an unwritable marker
    # from bricking the loop (this exit path is BEFORE the max-iteration backstop).
    LEARN_ENABLED=$(jq -r 'if .learning.enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
    LEARN_DISTILL=$(jq -r 'if .learning.auto_distill_post_loop == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
    if [ "$LEARN_ENABLED" = "true" ] && [ "$LEARN_DISTILL" = "true" ]; then
      OBJ_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
      LEARN_DIR="$NAZGUL_DIR/learning"
      MARKER="$LEARN_DIR/.distilled"
      ATTEMPTS_FILE="$LEARN_DIR/.distill-attempts"
      DISTILLED_FOR=""
      [ -f "$MARKER" ] && DISTILLED_FOR=$(cat "$MARKER" 2>/dev/null || echo "")
      if [ "$DISTILLED_FOR" != "$OBJ_ID" ]; then
        # Reset the attempt counter when it belongs to a different objective.
        ATTEMPTS=0
        if [ -f "$ATTEMPTS_FILE" ]; then
          read -r A_OBJ A_CNT < "$ATTEMPTS_FILE" 2>/dev/null || true
          if [ "${A_OBJ:-}" = "$OBJ_ID" ]; then
            case "${A_CNT:-0}" in ''|*[!0-9]*) A_CNT=0 ;; esac
            ATTEMPTS="$A_CNT"
          fi
        fi
        if [ "$ATTEMPTS" -lt 3 ]; then
          mkdir -p "$LEARN_DIR"
          printf '%s %s\n' "$OBJ_ID" "$((ATTEMPTS + 1))" > "$ATTEMPTS_FILE"
          cat >&2 << LEARN_MSG
Nazgul: all ${DONE_COUNT}/${TOTAL_COUNT} tasks complete — POST-LOOP LEARNING GATE (mandatory).
Candidate Learned Rules have NOT been distilled for this objective (${OBJ_ID}) yet.
DELEGATE: Spawn the learner agent (Agent tool, subagent_type "nazgul:learner") to mine this
objective's review/diagnosis artifacts and write candidate rules to
nazgul/learning/proposed-rules.md. It PROPOSES only — it never approves or edits the registry.
When it finishes it MUST record completion: echo "${OBJ_ID}" > nazgul/learning/.distilled
Do NOT output NAZGUL_COMPLETE until distillation has run and the marker is written.
Opt out for future objectives with learning.auto_distill_post_loop=false in nazgul/config.json.
LEARN_MSG
          jq -n --arg r "Post-loop learning gate: distill learned rules for ${OBJ_ID}" '{"decision":"block","reason":$r}'
          exit 2
        else
          echo "Nazgul: learning gate gave up after ${ATTEMPTS} attempts for ${OBJ_ID} — completing without distillation. Run /nazgul:learn manually." >&2
        fi
      fi
    fi
    # --- Post-loop granularity reconciliation gate ----------------------------
    # Mirrors the learning gate above: marker, bounded attempt counter (max 3),
    # decision-block JSON + exit 2 on violation, graceful pass on backstop.
    # Degrades to allow when coverage file is absent — never blocks on missing data.
    ENFORCE_GRANULARITY=$(jq -r '.review_gate.enforce_granularity // "block"' "$CONFIG" 2>/dev/null || echo "block")
    COVERAGE_FILE="$NAZGUL_DIR/logs/review-coverage.jsonl"
    GRAN_DIR="$NAZGUL_DIR/logs"
    GRAN_MARKER="$GRAN_DIR/.granularity-checked"
    GRAN_ATTEMPTS_FILE="$GRAN_DIR/.granularity-attempts"
    GRAN_OBJ_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
    GRAN_CHECKED_FOR=""
    [ -f "$GRAN_MARKER" ] && GRAN_CHECKED_FOR=$(cat "$GRAN_MARKER" 2>/dev/null || echo "")
    if [ "$GRAN_CHECKED_FOR" != "$GRAN_OBJ_ID" ] && [ -f "$COVERAGE_FILE" ]; then
      # Scope to THIS objective's coverage records. review-coverage.jsonl is
      # append-only and accumulates records across objectives; a record carrying
      # a different feat_id belongs to a prior objective and must not block this
      # one. A record with no/empty feat_id (legacy, pre-stamping) is treated as
      # belonging to the current objective so older logs still gate.
      GRAN_VIOLATIONS=$(jq -r --arg g "$GRANULARITY" --arg feat "$GRAN_OBJ_ID" \
        'select(((.feat_id // "") == "" or .feat_id == $feat) and .granularity_used != $g) | "\(.task_id) reviewed as \(.granularity_used) (expected \($g))"' \
        "$COVERAGE_FILE" 2>/dev/null | sort -u || true)
      if [ -n "$GRAN_VIOLATIONS" ]; then
        if [ "$ENFORCE_GRANULARITY" = "warn" ]; then
          cat >&2 << GRAN_WARN_MSG
Nazgul: GRANULARITY WARNING — tasks were reviewed at wrong granularity (configured: ${GRANULARITY}).
${GRAN_VIOLATIONS}
enforce_granularity=warn: completing despite violation. Set enforce_granularity=block to enforce.
GRAN_WARN_MSG
          mkdir -p "$GRAN_DIR"
          printf '%s\n' "$GRAN_OBJ_ID" > "$GRAN_MARKER"
        else
          GRAN_ATTEMPTS=0
          if [ -f "$GRAN_ATTEMPTS_FILE" ]; then
            read -r GA_OBJ GA_CNT < "$GRAN_ATTEMPTS_FILE" 2>/dev/null || true
            if [ "${GA_OBJ:-}" = "$GRAN_OBJ_ID" ]; then
              case "${GA_CNT:-0}" in ''|*[!0-9]*) GA_CNT=0 ;; esac
              GRAN_ATTEMPTS="$GA_CNT"
            fi
          fi
          if [ "$GRAN_ATTEMPTS" -lt 3 ]; then
            mkdir -p "$GRAN_DIR"
            printf '%s %s\n' "$GRAN_OBJ_ID" "$((GRAN_ATTEMPTS + 1))" > "$GRAN_ATTEMPTS_FILE"
            cat >&2 << GRAN_BLOCK_MSG
Nazgul: GRANULARITY GATE — tasks completed but review coverage violates configured granularity (${GRANULARITY}).
Offending tasks:
${GRAN_VIOLATIONS}
DELEGATE: Re-run the review-gate agent at granularity="${GRANULARITY}" for the affected tasks/units.
Do NOT output NAZGUL_COMPLETE until coverage at the correct granularity is recorded.
Set enforce_granularity=warn in nazgul/config.json to downgrade this gate to a warning.
GRAN_BLOCK_MSG
            jq -n --arg r "Granularity gate: tasks reviewed at wrong granularity for ${GRAN_OBJ_ID}" '{"decision":"block","reason":$r}'
            exit 2
          else
            echo "Nazgul: granularity gate gave up after ${GRAN_ATTEMPTS} attempts for ${GRAN_OBJ_ID} — completing with violation. Fix review coverage manually." >&2
            mkdir -p "$GRAN_DIR"
            printf '%s\n' "$GRAN_OBJ_ID" > "$GRAN_MARKER"
          fi
        fi
      else
        mkdir -p "$GRAN_DIR"
        printf '%s\n' "$GRAN_OBJ_ID" > "$GRAN_MARKER"
      fi
    fi
    # Post-loop doc-verifier gate: marker + bounded backstop (≤3); degrades-to-allow when no docs.
    DOC_VERIFY_ENABLED=$(jq -r 'if .docs.verify_post_loop == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
    if [ "$DOC_VERIFY_ENABLED" = "true" ]; then
      DV_OBJ_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
      DOCS_DIR="$NAZGUL_DIR/docs"
      DV_MARKER="$NAZGUL_DIR/logs/.docs-verified"
      DV_ATTEMPTS_FILE="$NAZGUL_DIR/logs/.docs-verify-attempts"
      VERIFIED_FOR=""
      [ -f "$DV_MARKER" ] && VERIFIED_FOR=$(cat "$DV_MARKER" 2>/dev/null || echo "")
      if [ "$VERIFIED_FOR" != "$DV_OBJ_ID" ]; then
        if [ ! -d "$DOCS_DIR" ] || ! find "$DOCS_DIR" -maxdepth 1 -name "*.md" -print -quit 2>/dev/null | grep -q .; then
          mkdir -p "$NAZGUL_DIR/logs"
          printf '%s\n' "$DV_OBJ_ID" > "$DV_MARKER"
        else
          DV_ATTEMPTS=0
          if [ -f "$DV_ATTEMPTS_FILE" ]; then
            read -r DV_OBJ DV_CNT < "$DV_ATTEMPTS_FILE" 2>/dev/null || true
            if [ "${DV_OBJ:-}" = "$DV_OBJ_ID" ]; then
              case "${DV_CNT:-0}" in ''|*[!0-9]*) DV_CNT=0 ;; esac
              DV_ATTEMPTS="$DV_CNT"
            fi
          fi
          if [ "$DV_ATTEMPTS" -lt 3 ]; then
            mkdir -p "$NAZGUL_DIR/logs"
            printf '%s %s\n' "$DV_OBJ_ID" "$((DV_ATTEMPTS + 1))" > "$DV_ATTEMPTS_FILE"
            cat >&2 << DV_MSG
Nazgul: all ${DONE_COUNT}/${TOTAL_COUNT} tasks complete — POST-LOOP DOC-VERIFIER GATE (mandatory).
Generated docs have NOT been verified for this objective (${DV_OBJ_ID}) yet.
DELEGATE: Spawn the doc-verifier agent (nazgul:doc-verifier) to cross-check nazgul/docs/*.md
and CHANGELOG.md against source. It checks that every event type, config key, command, and
named script referenced in docs exists in the codebase.
When it finishes it MUST record completion: echo "${DV_OBJ_ID}" > nazgul/logs/.docs-verified
Do NOT output NAZGUL_COMPLETE until verification has run and the marker is written.
Opt out for future objectives with docs.verify_post_loop=false in nazgul/config.json.
DV_MSG
            jq -n --arg r "Post-loop doc-verifier gate: docs not yet verified for ${DV_OBJ_ID}" '{"decision":"block","reason":$r}'
            exit 2
          else
            echo "Nazgul: doc-verifier gate gave up after ${DV_ATTEMPTS} attempts for ${DV_OBJ_ID} — completing without doc verification. Run /nazgul:doc-verifier manually." >&2
            mkdir -p "$NAZGUL_DIR/logs"
            printf '%s\n' "$DV_OBJ_ID" > "$DV_MARKER"
          fi
        fi
      fi
    fi
    # Post-loop comment-verifier gate: marker + bounded backstop (≤3); degrades-to-allow
    # when no source files changed on the feature branch (nothing new to check).
    COMMENT_VERIFY_ENABLED=$(jq -r 'if .docs.verify_comments == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
    if [ "$COMMENT_VERIFY_ENABLED" = "true" ]; then
      CV_OBJ_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
      CV_MARKER="$NAZGUL_DIR/logs/.comments-verified"
      CV_ATTEMPTS_FILE="$NAZGUL_DIR/logs/.comments-verify-attempts"
      CV_VERIFIED_FOR=""
      [ -f "$CV_MARKER" ] && CV_VERIFIED_FOR=$(cat "$CV_MARKER" 2>/dev/null || echo "")
      if [ "$CV_VERIFIED_FOR" != "$CV_OBJ_ID" ]; then
        # Filter out docs/config/lockfiles — mirrors the comment-verifier agent's own
        # scope filter, so this cheap backstop doesn't spawn the agent for doc-only diffs.
        CV_CHANGED_JSON=$(files_modified_json "$PROJECT_ROOT" "$BASE_BRANCH" 2>/dev/null || echo '[]')
        CV_CHANGED_COUNT=$(printf '%s' "$CV_CHANGED_JSON" | jq '[ .[] | select(
            (test("^nazgul/docs/") or test("^docs/") or endswith(".json") or endswith(".lock")) | not
          ) ] | length' 2>/dev/null || echo 0)
        case "$CV_CHANGED_COUNT" in (*[!0-9]*|'') CV_CHANGED_COUNT=0 ;; esac
        if [ "$CV_CHANGED_COUNT" -eq 0 ]; then
          mkdir -p "$NAZGUL_DIR/logs"
          printf '%s\n' "$CV_OBJ_ID" > "$CV_MARKER"
        else
          CV_ATTEMPTS=0
          if [ -f "$CV_ATTEMPTS_FILE" ]; then
            read -r CV_ATT_OBJ CV_ATT_CNT < "$CV_ATTEMPTS_FILE" 2>/dev/null || true
            if [ "${CV_ATT_OBJ:-}" = "$CV_OBJ_ID" ]; then
              case "${CV_ATT_CNT:-0}" in ''|*[!0-9]*) CV_ATT_CNT=0 ;; esac
              CV_ATTEMPTS="$CV_ATT_CNT"
            fi
          fi
          if [ "$CV_ATTEMPTS" -lt 3 ]; then
            mkdir -p "$NAZGUL_DIR/logs"
            printf '%s %s\n' "$CV_OBJ_ID" "$((CV_ATTEMPTS + 1))" > "$CV_ATTEMPTS_FILE"
            cat >&2 << CV_MSG
Nazgul: all ${DONE_COUNT}/${TOTAL_COUNT} tasks complete — POST-LOOP COMMENT-VERIFIER GATE (mandatory).
Inline doc-comments have NOT been verified for this objective (${CV_OBJ_ID}) yet.
DELEGATE: Spawn the comment-verifier agent (nazgul:comment-verifier) to cross-check inline
source doc-comments (XML <summary>, JSDoc, docstrings) changed by this objective for
templated, restatement, or contradiction defects.
When it finishes it MUST record completion: echo "${CV_OBJ_ID}" > nazgul/logs/.comments-verified
Do NOT output NAZGUL_COMPLETE until verification has run and the marker is written.
Opt out for future objectives with docs.verify_comments=false in nazgul/config.json.
CV_MSG
            jq -n --arg r "Post-loop comment-verifier gate: comments not yet verified for ${CV_OBJ_ID}" '{"decision":"block","reason":$r}'
            exit 2
          else
            echo "Nazgul: comment-verifier gate gave up after ${CV_ATTEMPTS} attempts for ${CV_OBJ_ID} — completing without comment verification. Run /nazgul:comment-verifier manually." >&2
            mkdir -p "$NAZGUL_DIR/logs"
            printf '%s\n' "$CV_OBJ_ID" > "$CV_MARKER"
          fi
        fi
      fi
    fi
    # Post-loop self-audit gate (ADR-001): marker + bounded backstop (≤3); never a hard
    # block — proposes-only findings can't be allowed to deadlock an unattended loop.
    SELF_AUDIT_ENABLED=$(jq -r 'if .self_audit.enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
    if [ "$SELF_AUDIT_ENABLED" = "true" ]; then
      SA_OBJ_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
      # Honor a configured backlog path so the DELEGATE message points at the
      # real file (self-audit.sh writes to self_audit.backlog_path); default it.
      SA_BACKLOG=$(jq -r '.self_audit.backlog_path // "nazgul/improvements.md"' "$CONFIG" 2>/dev/null || echo "nazgul/improvements.md")
      [ -n "$SA_BACKLOG" ] || SA_BACKLOG="nazgul/improvements.md"
      SA_MARKER="$NAZGUL_DIR/logs/.self-audited"
      SA_ATTEMPTS_FILE="$NAZGUL_DIR/logs/.self-audit-attempts"
      SA_AUDITED_FOR=""
      [ -f "$SA_MARKER" ] && SA_AUDITED_FOR=$(cat "$SA_MARKER" 2>/dev/null || echo "")
      if [ "$SA_AUDITED_FOR" != "$SA_OBJ_ID" ]; then
        SA_ATTEMPTS=0
        if [ -f "$SA_ATTEMPTS_FILE" ]; then
          read -r SA_ATT_OBJ SA_ATT_CNT < "$SA_ATTEMPTS_FILE" 2>/dev/null || true
          if [ "${SA_ATT_OBJ:-}" = "$SA_OBJ_ID" ]; then
            case "${SA_ATT_CNT:-0}" in ''|*[!0-9]*) SA_ATT_CNT=0 ;; esac
            SA_ATTEMPTS="$SA_ATT_CNT"
          fi
        fi
        if [ "$SA_ATTEMPTS" -lt 3 ]; then
          mkdir -p "$NAZGUL_DIR/logs"
          printf '%s %s\n' "$SA_OBJ_ID" "$((SA_ATTEMPTS + 1))" > "$SA_ATTEMPTS_FILE"
          cat >&2 << SA_MSG
Nazgul: all ${DONE_COUNT}/${TOTAL_COUNT} tasks complete — POST-LOOP SELF-AUDIT GATE (mandatory).
Self-audit findings have NOT been recorded for this objective (${SA_OBJ_ID}) yet.
DELEGATE: Spawn the self-audit agent (nazgul:self-audit) to mine cost/perf/correctness
signals from this objective and append findings to ${SA_BACKLOG}. It proposes
only — it never edits code or approves anything.
When it finishes it MUST record completion: echo "${SA_OBJ_ID}" > nazgul/logs/.self-audited
Do NOT output NAZGUL_COMPLETE until self-audit has run and the marker is written.
Opt out for future objectives with self_audit.enabled=false in nazgul/config.json.
SA_MSG
          jq -n --arg r "Post-loop self-audit gate: findings not yet recorded for ${SA_OBJ_ID}" '{"decision":"block","reason":$r}'
          exit 2
        else
          echo "Nazgul: self-audit gate gave up after ${SA_ATTEMPTS} attempts for ${SA_OBJ_ID} — completing without self-audit. Run \${CLAUDE_PLUGIN_ROOT}/scripts/self-audit.sh manually." >&2
          mkdir -p "$NAZGUL_DIR/logs"
          printf '%s\n' "$SA_OBJ_ID" > "$SA_MARKER"
        fi
      fi
    fi
    # Doc-verifier, comment-verifier, and self-audit gates passed, opted out, or
    # backstop exhausted — allow completion.
    # Emit objective_complete before exit (pure observer; state is already final).
    emit_event "objective_complete" \
      total_tasks:n "$TOTAL_COUNT" \
      done_count:n "$DONE_COUNT" \
      iterations_used:n "$NEW_ITER"
    exit 0
  fi
fi

# 2. Max iterations reached
if [ "$NEW_ITER" -ge "$MAX_ITER" ]; then
  echo "Nazgul: Max iterations ($MAX_ITER) reached. ${DONE_COUNT}/${TOTAL_COUNT} tasks done." >&2
  exit 0
fi

# 2.5 Budget ceiling reached (cost governor — estimate)
# Coerce max_usd to a number; a null/non-numeric/non-positive ceiling is treated
# as "no ceiling" (inert guard) so a fat-fingered config can't fail CLOSED and
# silently brick an unattended loop — matches the rate/accumulator coercion above.
BUDGET_MAX=$(jq -r '(.budget.max_usd | tonumber?) // empty' "$CONFIG")
if [ "$BUDGET_ENABLED" = "true" ] && [ -n "$BUDGET_MAX" ]; then
  if awk -v s="$BUDGET_SPENT" -v m="$BUDGET_MAX" 'BEGIN{exit !(m > 0 && s+0 >= m+0)}'; then
    echo "Nazgul: budget reached (~\$${BUDGET_SPENT} / \$${BUDGET_MAX} after ${NEW_ITER} iterations). Stopping." >&2
    exit 0
  fi
fi

# 3. Consecutive failures exceeded
if [ "$CONSEC_FAILURES" -ge "$MAX_CONSEC" ]; then
  echo "Nazgul: ${CONSEC_FAILURES} consecutive iterations with no progress. Stopping." >&2
  exit 0
fi

# --- CONTINUE LOOP ---
# Exit 2 = block the stop, agent continues

REASON="Iteration ${NEW_ITER}/${MAX_ITER}: ${DONE_COUNT}/${TOTAL_COUNT} tasks done"
if [ -n "$REVIEW_VIOLATIONS" ]; then
  # head -3 is an intentional size cap for the one-line JSON reason; the full
  # violation list is surfaced in CONTINUE_MSG below.
  VIOLATION_SUMMARY=$(printf '%s' "$REVIEW_VIOLATIONS" | head -3 | tr '\n' ';' | sed 's/;$//')
  REASON="${REASON} | ${VIOLATION_SUMMARY}"
fi

# --- Build the DELEGATE instruction (granularity-aware) --------------------------
# In "task" mode an IMPLEMENTED/IN_REVIEW active task dispatches a per-task review.
# In "group"/"feature" mode the review board fires ONCE per review unit over the
# combined diff — only when AGGREGATE_REVIEW_READY is true (the whole unit is
# IMPLEMENTED). The per-task review branches are therefore gated to GRANULARITY
# == "task": in group/feature mode a parked IMPLEMENTED/IN_REVIEW task must NEVER
# trigger a single-task review. That matters for the blocked-unit fallback above
# (lines ~368-371), which surfaces a parked IMPLEMENTED task as the active task
# for recovery even though its unit is incomplete — without this gate it would
# wrongly dispatch a premature per-task review. Such cases fall through to the
# AWAITING AGGREGATE REVIEW marker instead.
DISPATCH_INSTR=""
if [ "$GRANULARITY" != "task" ] && [ "$AGGREGATE_REVIEW_READY" = "true" ]; then
  if [ "$GRANULARITY" = "feature" ]; then
    REVIEW_DIFF_HINT="the cumulative feature diff (base..HEAD: ${BASE_BRANCH:-origin/main}..HEAD)"
  else
    REVIEW_DIFF_HINT="the combined diff for ${AGGREGATE_REVIEW_SCOPE} (its tasks' commits)"
  fi
  DISPATCH_INSTR="DELEGATE: Spawn review-gate agent (nazgul:review-gate) for the AGGREGATE review unit [${AGGREGATE_REVIEW_SCOPE}]. Review SCOPE is ${REVIEW_DIFF_HINT}, covering tasks: ${AGGREGATE_REVIEW_TASKS}. Pass granularity=${GRANULARITY} and the task list so feedback-aggregator can attribute findings back to the owning task by file scope. MANDATORY: review-gate must run Step 0 (simplify pass) before pre-checks — read its agent definition."
elif [ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IMPLEMENTED" ]; then
  DISPATCH_INSTR="DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. MANDATORY: review-gate must run Step 0 (simplify pass) before pre-checks — read its agent definition."
elif [ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IN_REVIEW" ]; then
  DISPATCH_INSTR="DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}."
elif [ "$ACTIVE_STATUS" = "READY" ] || [ "$ACTIVE_STATUS" = "IN_PROGRESS" ]; then
  DISPATCH_INSTR="DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}."
elif [ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ]; then
  DISPATCH_INSTR="DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. Read consolidated feedback first.
IMPORTANT: Read nazgul/reviews/${ACTIVE_TASK}/consolidated-feedback.md before re-implementing."
fi

# "Awaiting aggregate review" recovery marker: tasks are IMPLEMENTED-but-parked,
# unit not yet complete. Survives compaction so recovery knows not to re-review
# or re-implement parked tasks.
AGGREGATE_MARKER=""
if [ "$GRANULARITY" != "task" ] && [ "$AWAITING_AGGREGATE_REVIEW" = "true" ] && [ "$AGGREGATE_REVIEW_READY" != "true" ]; then
  AGGREGATE_MARKER="AWAITING AGGREGATE REVIEW (${GRANULARITY}): tasks already IMPLEMENTED and PARKED — do NOT re-review or re-implement them: ${AGGREGATE_REVIEW_TASKS}. Keep implementing the rest of the review unit; the review board fires once the whole ${GRANULARITY} is IMPLEMENTED."
elif [ "$GRANULARITY" != "task" ] && [ "$AGGREGATE_REVIEW_READY" = "true" ]; then
  AGGREGATE_MARKER="AGGREGATE REVIEW READY (${GRANULARITY}): review unit [${AGGREGATE_REVIEW_SCOPE}] fully IMPLEMENTED — tasks: ${AGGREGATE_REVIEW_TASKS}."
fi

cat >&2 << CONTINUE_MSG
Nazgul loop — iteration ${NEW_ITER}/${MAX_ITER} | Mode: ${MODE} | Review granularity: ${GRANULARITY}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked, ${PLANNED_COUNT} planned
$([ -n "$REVIEW_VIOLATIONS" ] && printf '%s' "$REVIEW_VIOLATIONS" || true)
$([ -n "$FEATURE_BRANCH" ] && echo "Branch: ${FEATURE_BRANCH} → ${BASE_BRANCH} | Worktrees: ${WORKTREE_COUNT}" || true)

Read nazgul/plan.md → Recovery Pointer section for current state.
$([ -n "$ACTIVE_TASK" ] && echo "Active task: nazgul/tasks/${ACTIVE_TASK}.md (${ACTIVE_STATUS})" || echo "No active task — find first READY task in nazgul/plan.md")
$([ -n "$AGGREGATE_MARKER" ] && echo "$AGGREGATE_MARKER" || true)
$([ -n "$DISPATCH_INSTR" ] && echo "$DISPATCH_INSTR" || true)
$([ "$GIT_CONFLICT_DETECTED" = true ] && echo "WARNING: Git conflicts detected. Resolve unmerged files before continuing.")
$([ -n "$CONTEXT_ROT_WARNING" ] && echo "$CONTEXT_ROT_WARNING")

Continue the Nazgul pipeline: read plan.md, delegate to the appropriate agent based on task status.
CONTINUE_MSG

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 2
