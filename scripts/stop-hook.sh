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
REVIEW_VIOLATIONS=""
if { [ "$YOLO_MODE" != "true" ] || [ "$TASK_PR_MODE" != "true" ]; } && [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    TASK_ID=$(basename "$task_file" .md)
    RESET_COUNT=$(jq -r --arg t "$TASK_ID" '.safety._review_reset_counts[$t] // 0' "$CONFIG" 2>/dev/null || echo "0")
    case "$RESET_COUNT" in (*[!0-9]*|'') RESET_COUNT=0 ;; esac

    if [ "$STATUS" = "DONE" ]; then
      EVIDENCE_PROBLEMS=$(validate_review_evidence "$NAZGUL_DIR" "$TASK_ID") || true
      if [ -n "$EVIDENCE_PROBLEMS" ]; then
        MISSING_LIST=$(echo "$EVIDENCE_PROBLEMS" | awk 'NF>1 {out = out sep $2; sep = ", "} NF==1 {out = out sep $1; sep = ", "} END {print out}')
        if [ "$RESET_COUNT" -ge 1 ]; then
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
      elif [ "$RESET_COUNT" != "0" ]; then
        # Evidence is now valid — clear the stale counter
        jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
      fi
    elif [ "$RESET_COUNT" != "0" ] && [ "$STATUS" != "IMPLEMENTED" ] && [ "$STATUS" != "IN_REVIEW" ]; then
      # Task left DONE for a non-repair state — clear the stale counter.
      # IMPLEMENTED/IN_REVIEW are the repair path the reset itself creates: the
      # counter must survive them, or a later bad DONE restarts at zero and
      # never escalates. Valid evidence (branch above) still clears it.
      jq --arg t "$TASK_ID" 'del(.safety._review_reset_counts[$t])' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
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
  fi
fi

# --- Iteration logs (4.1) ---
mkdir -p "$NAZGUL_DIR/logs"
jq -n \
  --argjson iteration "$NEW_ITER" \
  --arg timestamp "$TIMESTAMP" \
  --arg active_task "${ACTIVE_TASK:-none}" \
  --arg status "${ACTIVE_STATUS:-none}" \
  --argjson done_count "$DONE_COUNT" \
  --argjson total "$TOTAL_COUNT" \
  --arg git_sha "$GIT_SHA" \
  --arg blocked_reason "${ACTIVE_BLOCKED_REASON:-}" \
  '{iteration: $iteration, timestamp: $timestamp, active_task: $active_task, status: $status, done: $done_count, total: $total, git_sha: $git_sha, blocked_reason: $blocked_reason}' >> "$NAZGUL_DIR/logs/iterations.jsonl"

# --- EXIT CONDITIONS ---

# 0. No tasks exist — nothing to loop on
if [ "$TOTAL_COUNT" -eq 0 ]; then
  exit 0
fi

# 1. All tasks complete
# YOLO mode: loop completes when all tasks are APPROVED or DONE
# Non-YOLO: loop completes when all tasks are DONE
if [ "$TOTAL_COUNT" -gt 0 ]; then
  if [ "$YOLO_MODE" = "true" ]; then
    LOCALLY_COMPLETE=$((APPROVED_COUNT + DONE_COUNT))
    if [ "$LOCALLY_COMPLETE" -eq "$TOTAL_COUNT" ]; then
      exit 0
    fi
  elif [ "$DONE_COUNT" -eq "$TOTAL_COUNT" ]; then
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

cat >&2 << CONTINUE_MSG
Nazgul loop — iteration ${NEW_ITER}/${MAX_ITER} | Mode: ${MODE}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked, ${PLANNED_COUNT} planned
$([ -n "$REVIEW_VIOLATIONS" ] && printf '%s' "$REVIEW_VIOLATIONS" || true)
$([ -n "$FEATURE_BRANCH" ] && echo "Branch: ${FEATURE_BRANCH} → ${BASE_BRANCH} | Worktrees: ${WORKTREE_COUNT}" || true)

Read nazgul/plan.md → Recovery Pointer section for current state.
$([ -n "$ACTIVE_TASK" ] && echo "Active task: nazgul/tasks/${ACTIVE_TASK}.md (${ACTIVE_STATUS})" || echo "No active task — find first READY task in nazgul/plan.md")
$([ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. MANDATORY: review-gate must run Step 0 (simplify pass) before pre-checks — read its agent definition." || true)
$([ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "READY" ] || [ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. Read consolidated feedback first." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "IMPORTANT: Read nazgul/reviews/${ACTIVE_TASK}/consolidated-feedback.md before re-implementing." || true)
$([ "$GIT_CONFLICT_DETECTED" = true ] && echo "WARNING: Git conflicts detected. Resolve unmerged files before continuing.")
$([ -n "$CONTEXT_ROT_WARNING" ] && echo "$CONTEXT_ROT_WARNING")

Continue the Nazgul pipeline: read plan.md, delegate to the appropriate agent based on task status.
CONTINUE_MSG

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 2
