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
source "$SCRIPT_DIR/lib/task-utils.sh"

# If Hydra not initialized, allow stop
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

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

# --- Pause flag check (for /hydra:pause skill) ---
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
APPROVED_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
PLANNED_COUNT=0
TOTAL_COUNT=0

if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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
# Validate that no tasks are DONE without review evidence
# In YOLO mode, APPROVED tasks have been locally reviewed; DONE only happens via PR merge
if { [ "$YOLO_MODE" != "true" ] || [ "$TASK_PR_MODE" != "true" ]; } && [ -d "$HYDRA_DIR/tasks" ]; then
  CONFIGURED_REVIEWERS=$(jq -r '.agents.reviewers // [] | .[]' "$CONFIG" 2>/dev/null || echo "")
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    if [ "$STATUS" = "DONE" ]; then
      TASK_ID=$(basename "$task_file" .md)
      REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"
      REVIEW_VALID=true

      # Check 1: Review directory exists
      if [ ! -d "$REVIEW_DIR" ]; then
        REVIEW_VALID=false
      fi

      # Check 2: At least one reviewer file exists
      if [ "$REVIEW_VALID" = true ]; then
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

      # Check 3: ALL review files must contain APPROVED
      if [ "$REVIEW_VALID" = true ]; then
        for rf in "$REVIEW_DIR"/*.md; do
          [ -f "$rf" ] || continue
          case "$(basename "$rf")" in
            test-failures.md|consolidated-feedback.md) continue ;;
          esac
          if ! grep -qi 'APPROVED' "$rf" 2>/dev/null; then
            REVIEW_VALID=false
            break
          fi
        done
      fi

      # Check 4: ALL configured reviewers must have approved files
      if [ "$REVIEW_VALID" = true ]; then
        if [ -z "$CONFIGURED_REVIEWERS" ]; then
          REVIEW_VALID=false  # No roster = can't verify
        else
          while IFS= read -r reviewer; do
            [ -z "$reviewer" ] && continue
            if [ ! -f "$REVIEW_DIR/${reviewer}.md" ]; then
              REVIEW_VALID=false
              break
            fi
            if ! grep -qi 'APPROVED' "$REVIEW_DIR/${reviewer}.md" 2>/dev/null; then
              REVIEW_VALID=false
              break
            fi
          done <<< "$CONFIGURED_REVIEWERS"
        fi
      fi

      if [ "$REVIEW_VALID" = false ]; then
        # VIOLATION: Reset to IMPLEMENTED
        set_task_status "$task_file" "DONE" "IMPLEMENTED"
        DONE_COUNT=$((DONE_COUNT - 1))
        IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1))
        echo "HYDRA REVIEW GATE VIOLATION: ${TASK_ID} was DONE without full review — reset to IMPLEMENTED" >&2
      fi
    fi
  done
fi

# Track progress for consecutive failure detection
# In YOLO mode, APPROVED counts as progress alongside DONE
PREV_DONE=$(jq -r '.safety._prev_done_count // 0' "$CONFIG")
if [ "$YOLO_MODE" = "true" ] && [ "$TASK_PR_MODE" = "true" ]; then
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
for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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
LAST_CHECKPOINT_FILE=$(ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || true)
LAST_CHECKPOINT_SHA=""
if [ -n "$LAST_CHECKPOINT_FILE" ]; then
  LAST_CHECKPOINT_SHA=$(jq -r '.git.last_commit_sha // ""' "$LAST_CHECKPOINT_FILE" 2>/dev/null || echo "")
fi

FILES_MODIFIED_JSON="[]"
if git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  if [ -n "$LAST_CHECKPOINT_SHA" ] && git -C "$PROJECT_ROOT" cat-file -t "$LAST_CHECKPOINT_SHA" >/dev/null 2>&1; then
    FILES_MODIFIED_JSON=$(git -C "$PROJECT_ROOT" diff --name-only "$LAST_CHECKPOINT_SHA" HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
  else
    FILES_MODIFIED_JSON=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
  fi
fi

# --- Context rot detection (3.4) ---
COMPACTION_COUNT_FILE="$HYDRA_DIR/.compaction_count"
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
  RECOVERY_INSTR="Read hydra/plan.md Recovery Pointer. No active task — find first READY task in plan."
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
      planned: $planned
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
    NEXT_ACTION_TEXT="Read hydra/tasks/${ACTIVE_TASK}.md and continue based on status ${ACTIVE_STATUS}"
  fi

  # Update Recovery Pointer fields using awk (safe with arbitrary text in GIT_MSG)
  CHECKPOINT_NAME="hydra/checkpoints/iteration-$(printf '%03d' "$NEW_ITER").json"
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
    if [ -d "$HYDRA_DIR/tasks" ]; then
      # Read all cached statuses in one jq call
      CACHED_STATUSES=$(jq -r '.board._last_synced_status // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG" 2>/dev/null || echo "")
      declare -A CACHED_MAP=()
      while IFS=$'\t' read -r _tid _st; do
        [ -n "$_tid" ] && CACHED_MAP["$_tid"]="$_st"
      done <<< "$CACHED_STATUSES"
      # Collect status changes to batch-write after the loop
      BOARD_UPDATES=""
      for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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

# Checkpoint rotation — keep last 10
if [ -d "$HYDRA_DIR/checkpoints" ]; then
  ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
fi

# --- Auto-promote PLANNED -> READY when dependencies are met ---
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
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
        dep_file="$HYDRA_DIR/tasks/${dep}.md"
        if [ -f "$dep_file" ]; then
          DEP_STATUS=$(get_task_status "$dep_file")
          if [ "$YOLO_MODE" = "true" ] && [ "$TASK_PR_MODE" = "true" ]; then
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
  if [ -n "$ACTIVE_TASK" ] && [ -f "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" ]; then
    set_task_status "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" ".*" "BLOCKED"
    # Add or update blocked reason
    if grep -q '^\- \*\*Blocked reason\*\*:' "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" 2>/dev/null; then
      sed -i.bak 's/^\(- \*\*Blocked reason\*\*:\) .*/\1 git conflict — unmerged files detected/' "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md" && rm -f "$HYDRA_DIR/tasks/${ACTIVE_TASK}.md.bak"
    fi
    ACTIVE_BLOCKED_REASON="git conflict"
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
  --arg blocked_reason "${ACTIVE_BLOCKED_REASON:-}" \
  '{iteration: $iteration, timestamp: $timestamp, active_task: $active_task, status: $status, done: $done_count, total: $total, git_sha: $git_sha, blocked_reason: $blocked_reason}' >> "$HYDRA_DIR/logs/iterations.jsonl"

# --- EXIT CONDITIONS ---

# 0. No tasks exist — nothing to loop on
if [ "$TOTAL_COUNT" -eq 0 ]; then
  exit 0
fi

# 1. All tasks complete
# YOLO mode: loop completes when all tasks are APPROVED or DONE
# Non-YOLO: loop completes when all tasks are DONE
if [ "$TOTAL_COUNT" -gt 0 ]; then
  if [ "$YOLO_MODE" = "true" ] && [ "$TASK_PR_MODE" = "true" ]; then
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
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked, ${PLANNED_COUNT} planned
$([ -n "$FEATURE_BRANCH" ] && echo "Branch: ${FEATURE_BRANCH} → ${BASE_BRANCH} | Worktrees: ${WORKTREE_COUNT}" || true)

Read hydra/plan.md → Recovery Pointer section for current state.
$([ -n "$ACTIVE_TASK" ] && echo "Active task: hydra/tasks/${ACTIVE_TASK}.md (${ACTIVE_STATUS})" || echo "No active task — find first READY task in hydra/plan.md")
$([ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (hydra:review-gate) for ${ACTIVE_TASK}. Do NOT skip the review gate." || true)
$([ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (hydra:review-gate) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "READY" ] || [ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (hydra:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (hydra:implementer) for ${ACTIVE_TASK}. Read consolidated feedback first." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "IMPORTANT: Read hydra/reviews/${ACTIVE_TASK}/consolidated-feedback.md before re-implementing." || true)
$([ "$GIT_CONFLICT_DETECTED" = true ] && echo "WARNING: Git conflicts detected. Resolve unmerged files before continuing.")
$([ -n "$CONTEXT_ROT_WARNING" ] && echo "$CONTEXT_ROT_WARNING")

Continue the Hydra pipeline: read plan.md, delegate to the appropriate agent based on task status.
CONTINUE_MSG

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 2
