#!/usr/bin/env bash
set -euo pipefail

# Hydra Stop Hook — Loop engine and state management
# Exit 0 = allow stop (loop ends)
# Exit 2 = block stop (loop continues) with stderr message

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"
PLAN="$HYDRA_DIR/plan.md"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If Hydra not initialized, allow stop
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Read current state
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")
MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
CONSEC_FAILURES=$(jq -r '.safety.consecutive_failures // 0' "$CONFIG")
MAX_CONSEC=$(jq -r '.safety.max_consecutive_failures // 5' "$CONFIG")
# completion_promise is checked by the prompt-layer Stop hook, not this script

# --- Pause flag check (for /hydra-pause skill) ---
PAUSED=$(jq -r '.paused // false' "$CONFIG")
if [ "$PAUSED" = "true" ]; then
  jq '.paused = false' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  exit 0
fi

# --- AFK timeout enforcement (3.5) ---
AFK_ENABLED=$(jq -r '.afk.enabled // false' "$CONFIG")
AFK_TIMEOUT=$(jq -r '.afk.timeout_minutes // 90' "$CONFIG")
if [ "$AFK_ENABLED" = "true" ] && [ "$AFK_TIMEOUT" != "null" ]; then
  # Find the earliest checkpoint timestamp or fall back to config's objective_set_at
  SESSION_START=""
  FIRST_CHECKPOINT=$(ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | tail -1 || true)
  if [ -n "$FIRST_CHECKPOINT" ]; then
    SESSION_START=$(jq -r '.timestamp // ""' "$FIRST_CHECKPOINT")
  fi
  if [ -z "$SESSION_START" ]; then
    SESSION_START=$(jq -r '.objective_set_at // ""' "$CONFIG")
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
          echo "Hydra: AFK timeout reached (${ELAPSED_MINUTES}m >= ${AFK_TIMEOUT}m). Stopping." >&2
          exit 0
        fi
      fi
    fi
  fi
fi

# Increment iteration
NEW_ITER=$((ITERATION + 1))
jq --argjson iter "$NEW_ITER" '.current_iteration = $iter' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

# Count tasks by status
DONE_COUNT=0
READY_COUNT=0
IN_PROGRESS_COUNT=0
IN_REVIEW_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
PLANNED_COUNT=0
TOTAL_COUNT=0

if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "PLANNED")
    case "$STATUS" in
      DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
      READY) READY_COUNT=$((READY_COUNT + 1)) ;;
      IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
      IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      IN_REVIEW) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
      BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
      PLANNED) PLANNED_COUNT=$((PLANNED_COUNT + 1)) ;;
    esac
  done
fi

# --- REVIEW GATE ENFORCEMENT (Layer 2 — reactive safety net) ---
# Validate that no tasks are DONE without review evidence
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
    if [ "$STATUS" = "DONE" ]; then
      TASK_ID=$(basename "$task_file" .md)
      REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"
      REVIEW_VALID=true

      # Check review directory exists with reviewer files
      if [ ! -d "$REVIEW_DIR" ]; then
        REVIEW_VALID=false
      else
        HAS_REVIEWS=false
        for rf in "$REVIEW_DIR"/*.md; do
          [ -f "$rf" ] || continue
          case "$(basename "$rf")" in
            test-failures.md|consolidated-feedback.md) continue ;;
          esac
          HAS_REVIEWS=true
          break
        done
        if [ "$HAS_REVIEWS" = false ]; then
          REVIEW_VALID=false
        fi
      fi

      if [ "$REVIEW_VALID" = false ]; then
        # VIOLATION: Reset to IMPLEMENTED
        sed -i.bak 's/^\(- \*\*Status\*\*:\) DONE/\1 IMPLEMENTED/' "$task_file" && rm -f "${task_file}.bak"
        DONE_COUNT=$((DONE_COUNT - 1))
        IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1))
        echo "HYDRA REVIEW GATE VIOLATION: ${TASK_ID} was DONE without reviews — reset to IMPLEMENTED" >&2

        # Log violation to notifications
        NOTIFY_FILE="$HYDRA_DIR/notifications.jsonl"
        jq -n \
          --arg event "review_gate_violation" \
          --arg task "$TASK_ID" \
          --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          --arg summary "${TASK_ID} was marked DONE without review evidence. Reset to IMPLEMENTED." \
          '{event: $event, task: $task, timestamp: $timestamp, summary: $summary, requires_human: false}' >> "$NOTIFY_FILE"
      fi
    fi
  done
fi

# Track progress for consecutive failure detection
PREV_DONE=$(jq -r '.safety._prev_done_count // 0' "$CONFIG")
if [ "$DONE_COUNT" -gt "$PREV_DONE" ]; then
  # Progress made — reset consecutive failures
  CONSEC_FAILURES=0
else
  # No progress
  CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
fi
jq --argjson cf "$CONSEC_FAILURES" --argjson pd "$DONE_COUNT" \
  '.safety.consecutive_failures = $cf | .safety._prev_done_count = $pd' \
  "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

# Find active task
ACTIVE_TASK=""
ACTIVE_STATUS=""
ACTIVE_RETRY=0
ACTIVE_BLOCKED_REASON=""
for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
  [ -f "$task_file" ] || continue
  STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
  if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "IN_REVIEW" ] || [ "$STATUS" = "IMPLEMENTED" ]; then
    ACTIVE_TASK=$(basename "$task_file" .md)
    ACTIVE_STATUS="$STATUS"
    ACTIVE_RETRY=$(grep -m1 '^\- \*\*Retry count\*\*:' "$task_file" 2>/dev/null | sed 's|.*: \([0-9]*\)/.*|\1|' || echo "0")
    break
  fi
done

# Check for BLOCKED tasks and capture blocked reason
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
    if [ "$STATUS" = "BLOCKED" ]; then
      ACTIVE_BLOCKED_REASON=$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
      break
    fi
  done
fi

# If no active task, find first READY
if [ -z "$ACTIVE_TASK" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
    if [ "$STATUS" = "READY" ]; then
      ACTIVE_TASK=$(basename "$task_file" .md)
      ACTIVE_STATUS="READY"
      break
    fi
  done
fi

# Get git state
GIT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_MSG=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null | cut -c9- || echo "unknown")
GIT_DIRTY=$(git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null && echo "false" || echo "true")

# --- Capture files modified this iteration (GAP-012) ---
# Get the last checkpoint's commit SHA to diff against, fall back to HEAD~1
LAST_CHECKPOINT_FILE=$(ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || true)
LAST_CHECKPOINT_SHA=""
if [ -n "$LAST_CHECKPOINT_FILE" ]; then
  LAST_CHECKPOINT_SHA=$(jq -r '.git.last_commit_sha // ""' "$LAST_CHECKPOINT_FILE" 2>/dev/null || echo "")
fi

FILES_MODIFIED_JSON="[]"
if [ -n "$LAST_CHECKPOINT_SHA" ] && git -C "$PROJECT_ROOT" cat-file -t "$LAST_CHECKPOINT_SHA" >/dev/null 2>&1; then
  FILES_MODIFIED_JSON=$(git -C "$PROJECT_ROOT" diff --name-only "$LAST_CHECKPOINT_SHA" HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
else
  FILES_MODIFIED_JSON=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
fi

# --- Context rot detection (3.4) ---
COMPACTION_COUNT_FILE="$HYDRA_DIR/.compaction_count"
COMPACTION_COUNT=0
LAST_COMPACTION_ITER=0
if [ -f "$COMPACTION_COUNT_FILE" ]; then
  COMPACTION_COUNT=$(jq -r '.count // 0' "$COMPACTION_COUNT_FILE" 2>/dev/null || echo "0")
  LAST_COMPACTION_ITER=$(jq -r '.last_compaction_iter // 0' "$COMPACTION_COUNT_FILE" 2>/dev/null || echo "0")
fi
ITERS_SINCE_COMPACTION=$((NEW_ITER - LAST_COMPACTION_ITER))
CONTEXT_ROT_WARNING=""
if [ "$ITERS_SINCE_COMPACTION" -ge 8 ]; then
  CONTEXT_ROT_WARNING="Context may be degraded after ${ITERS_SINCE_COMPACTION} iterations without compaction. Recommended: run /compact preserving ${ACTIVE_TASK:-current} state and all blocking issues."
fi

# --- Write checkpoint with jq (GAP — safe JSON construction) ---
mkdir -p "$HYDRA_DIR/checkpoints"
CHECKPOINT_FILE="$HYDRA_DIR/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json"

ACTIVE_REVIEWERS=$(jq -c '.agents.reviewers // []' "$CONFIG" 2>/dev/null || echo "[]")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

ACTIVE_TASK_ID="null"
ACTIVE_TASK_STATUS="null"
ACTIVE_TASK_NEXT="null"
RECOVERY_INSTR=""

if [ -n "$ACTIVE_TASK" ]; then
  ACTIVE_TASK_ID="$ACTIVE_TASK"
  ACTIVE_TASK_STATUS="$ACTIVE_STATUS"
  ACTIVE_TASK_NEXT="Read hydra/tasks/${ACTIVE_TASK}.md and continue work"
  RECOVERY_INSTR="Read hydra/plan.md Recovery Pointer, then hydra/tasks/${ACTIVE_TASK}.md for current state."
else
  RECOVERY_INSTR="Read hydra/plan.md Recovery Pointer, then hydra/tasks/none.md for current state."
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
  --arg recovery "$RECOVERY_INSTR" \
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
      ready: $ready,
      in_progress: $in_progress,
      in_review: $in_review,
      changes_requested: $changes_requested,
      blocked: $blocked,
      planned: $planned
    },
    git: {
      branch: $git_branch,
      last_commit_sha: $git_sha,
      last_commit_message: $git_msg,
      uncommitted_changes: $git_dirty
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
    NEXT_ACTION_TEXT="Read hydra/tasks/${ACTIVE_TASK}.md and continue based on status ${ACTIVE_STATUS}"
  fi

  # Update each Recovery Pointer field using sed (if the section exists)
  sed -i.bak "s|^\- \*\*Current Task:\*\* .*|- **Current Task:** ${ACTIVE_TASK:-none}|" "$PLAN" 2>/dev/null || true
  sed -i.bak "s|^\- \*\*Last Action:\*\* .*|- **Last Action:** Iteration ${NEW_ITER} completed|" "$PLAN" 2>/dev/null || true
  sed -i.bak "s|^\- \*\*Next Action:\*\* .*|- **Next Action:** ${NEXT_ACTION_TEXT}|" "$PLAN" 2>/dev/null || true
  sed -i.bak "s|^\- \*\*Last Checkpoint:\*\* .*|- **Last Checkpoint:** hydra/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json|" "$PLAN" 2>/dev/null || true
  sed -i.bak "s|^\- \*\*Last Commit:\*\* .*|- **Last Commit:** ${GIT_SHA} ${GIT_MSG}|" "$PLAN" 2>/dev/null || true
  rm -f "${PLAN}.bak"
fi

# --- BOARD SYNC — push status changes to external board ---
BOARD_ENABLED=$(jq -r '.board.enabled // false' "$CONFIG")
if [ "$BOARD_ENABLED" = "true" ]; then
  BOARD_PROVIDER=$(jq -r '.board.provider // ""' "$CONFIG")
  BOARD_SCRIPT="$SCRIPT_DIR/board-sync-${BOARD_PROVIDER}.sh"
  if [ -f "$BOARD_SCRIPT" ]; then
    if [ -d "$HYDRA_DIR/tasks" ]; then
      for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
        [ -f "$task_file" ] || continue
        # Only sync tasks whose status changed since last sync
        task_id=$(grep -m1 '^\- \*\*ID\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
        current_status=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
        cached_status=$(jq -r --arg tid "$task_id" '.board._last_synced_status[$tid] // ""' "$CONFIG" 2>/dev/null || echo "")
        if [ -z "$task_id" ] || [ "$current_status" = "$cached_status" ]; then
          continue
        fi
        bash "$BOARD_SCRIPT" sync-task "$task_file" 2>/dev/null || true
        # Cache the synced status to avoid re-syncing unchanged tasks
        jq --arg tid "$task_id" --arg st "$current_status" \
          '.board._last_synced_status[$tid] = $st' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
      done
    fi
  fi
fi

# Checkpoint rotation — keep last 10
if [ -d "$HYDRA_DIR/checkpoints" ]; then
  ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
fi

# --- Auto-promote PLANNED -> READY when dependencies are met ---
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "")
    if [ "$STATUS" = "PLANNED" ]; then
      DEPS=$(grep -m1 '^\- \*\*Depends on\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "none")
      if [ "$DEPS" = "none" ] || [ -z "$DEPS" ]; then
        sed -i.bak 's/^\(- \*\*Status\*\*:\) PLANNED/\1 READY/' "$task_file" && rm -f "${task_file}.bak"
        continue
      fi
      # Check if all dependencies are DONE
      ALL_DONE=true
      while IFS= read -r dep; do
        dep_file="$HYDRA_DIR/tasks/${dep}.md"
        if [ -f "$dep_file" ]; then
          DEP_STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$dep_file" 2>/dev/null | sed 's/.*: //' || echo "")
          if [ "$DEP_STATUS" != "DONE" ]; then
            ALL_DONE=false
            break
          fi
        fi
      done <<< "$(echo "$DEPS" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
      if [ "$ALL_DONE" = true ]; then
        sed -i.bak 's/^\(- \*\*Status\*\*:\) PLANNED/\1 READY/' "$task_file" && rm -f "${task_file}.bak"
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
  if [ -n "$ACTIVE_TASK" ] && [ -f "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" ]; then
    sed -i.bak 's/^\(- \*\*Status\*\*:\) .*/\1 BLOCKED/' "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" && rm -f "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md.bak"
    # Add or update blocked reason
    if grep -q '^\- \*\*Blocked reason\*\*:' "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" 2>/dev/null; then
      sed -i.bak 's/^\(- \*\*Blocked reason\*\*:\) .*/\1 git conflict — unmerged files detected/' "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" && rm -f "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md.bak"
    fi
    ACTIVE_BLOCKED_REASON="git conflict"
  fi
  # Write git conflict notification
  NOTIFY_FILE="$HYDRA_DIR/notifications.jsonl"
  jq -n \
    --arg event "git_conflict" \
    --arg task "${ACTIVE_TASK:-unknown}" \
    --arg timestamp "$TIMESTAMP" \
    --arg summary "Git conflict detected. Unmerged files found. Task blocked." \
    '{event: $event, task: $task, timestamp: $timestamp, summary: $summary, requires_human: true}' >> "$NOTIFY_FILE"
fi

# --- Write notification events ---
NOTIFY_ENABLED=$(jq -r '.notifications.enabled // false' "$CONFIG")
NOTIFY_FILE="$HYDRA_DIR/notifications.jsonl"
if [ "$NOTIFY_ENABLED" = "true" ]; then
  # Check for task completions
  if [ "$DONE_COUNT" -gt "$PREV_DONE" ]; then
    jq -n \
      --arg event "task_complete" \
      --arg task "${ACTIVE_TASK:-unknown}" \
      --arg timestamp "$TIMESTAMP" \
      --arg summary "Task completed. ${DONE_COUNT}/${TOTAL_COUNT} done." \
      '{event: $event, task: $task, timestamp: $timestamp, summary: $summary}' >> "$NOTIFY_FILE"
  fi
  if [ "$BLOCKED_COUNT" -gt 0 ]; then
    jq -n \
      --arg event "blocked" \
      --arg task "${ACTIVE_TASK:-unknown}" \
      --arg timestamp "$TIMESTAMP" \
      --arg reason "Task blocked. Check task manifest for details." \
      '{event: $event, task: $task, timestamp: $timestamp, reason: $reason, requires_human: true}' >> "$NOTIFY_FILE"
  fi
fi

# --- Security rejections always notify (3.6) ---
# Check if any BLOCKED task has a security-related blocked reason
if [ -n "$ACTIVE_BLOCKED_REASON" ]; then
  if echo "$ACTIVE_BLOCKED_REASON" | grep -qi "security"; then
    # ALWAYS write security rejection notification regardless of notifications.enabled
    jq -n \
      --arg event "security_rejection" \
      --arg task "${ACTIVE_TASK:-unknown}" \
      --arg timestamp "$TIMESTAMP" \
      --arg reason "Security rejection: ${ACTIVE_BLOCKED_REASON}" \
      '{event: $event, task: $task, timestamp: $timestamp, reason: $reason, requires_human: true}' >> "$NOTIFY_FILE"
  fi
fi

# --- Iteration logs (4.1) ---
mkdir -p "$HYDRA_DIR/logs"
jq -n \
  --argjson iteration "$NEW_ITER" \
  --arg timestamp "$TIMESTAMP" \
  --arg active_task "${ACTIVE_TASK:-none}" \
  --arg status "${ACTIVE_STATUS:-none}" \
  --argjson done_count "$DONE_COUNT" \
  --argjson total "$TOTAL_COUNT" \
  --arg git_sha "$GIT_SHA" \
  '{iteration: $iteration, timestamp: $timestamp, active_task: $active_task, status: $status, done: $done_count, total: $total, git_sha: $git_sha}' >> "$HYDRA_DIR/logs/iterations.jsonl"

# --- EXIT CONDITIONS ---

# 1. All tasks DONE
if [ "$TOTAL_COUNT" -gt 0 ] && [ "$DONE_COUNT" -eq "$TOTAL_COUNT" ]; then
  if [ "$NOTIFY_ENABLED" = "true" ]; then
    jq -n \
      --arg event "loop_complete" \
      --arg timestamp "$TIMESTAMP" \
      --arg summary "All ${TOTAL_COUNT} tasks done. Branch: ${GIT_BRANCH}." \
      '{event: $event, timestamp: $timestamp, summary: $summary}' >> "$NOTIFY_FILE"
  fi
  exit 0
fi

# 2. Max iterations reached
if [ "$NEW_ITER" -ge "$MAX_ITER" ]; then
  echo "Hydra: Max iterations ($MAX_ITER) reached. ${DONE_COUNT}/${TOTAL_COUNT} tasks done." >&2
  exit 0
fi

# 3. Consecutive failures exceeded
if [ "$CONSEC_FAILURES" -ge "$MAX_CONSEC" ]; then
  echo "Hydra: ${CONSEC_FAILURES} consecutive iterations with no progress. Stopping." >&2
  exit 0
fi

# --- CONTINUE LOOP ---
# Exit 2 = block the stop, agent continues

REASON="Iteration ${NEW_ITER}/${MAX_ITER}: ${DONE_COUNT}/${TOTAL_COUNT} tasks done"

cat >&2 << CONTINUE_MSG
Hydra loop — iteration ${NEW_ITER}/${MAX_ITER} | Mode: ${MODE}
Tasks: ${DONE_COUNT} done, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked, ${PLANNED_COUNT} planned

Read hydra/plan.md → Recovery Pointer section for current state.
$([ -n "$ACTIVE_TASK" ] && echo "Active task: hydra/tasks/${ACTIVE_TASK}.md (${ACTIVE_STATUS})" || echo "No active task — find first READY task in hydra/plan.md")
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "IMPORTANT: Read hydra/reviews/${ACTIVE_TASK}/consolidated-feedback.md before re-implementing.")
$([ "$GIT_CONFLICT_DETECTED" = true ] && echo "WARNING: Git conflicts detected. Resolve unmerged files before continuing.")
$([ -n "$CONTEXT_ROT_WARNING" ] && echo "$CONTEXT_ROT_WARNING")

Continue the Hydra pipeline: read plan.md, delegate to the appropriate agent based on task status.
CONTINUE_MSG

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 2
