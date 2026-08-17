#!/usr/bin/env bash
set -euo pipefail

# Nazgul Session Context — injects state on startup and after compaction
# Stdout is shown to the agent

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
PROJECT_ROOT="$(resolve_project_root)"
NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# The ONE dispatch-brief preamble every DELEGATE line below reuses verbatim —
# every contract-bearing agent spec STOPs without <main_worktree_path>.
DISPATCH_BRIEF="Dispatch brief: <main_worktree_path> = ${PROJECT_ROOT}. Nazgul config: ${CONFIG}. Address every runtime-state path under that root, absolute and verbatim — your cwd is not it."
PLAN="$NAZGUL_DIR/plan.md"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/session-tracker.sh"
# Grouped with its siblings rather than sourced mid-script (PR #223 review #15).
source "$SCRIPT_DIR/lib/emit-event.sh"

# If Nazgul not initialized, nothing to inject
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Session identity resolution (TASK-006/FEAT-026). CLAUDE_SESSION_ID is not
# set in the SessionStart hook env, so the fallback chain reads the real id
# out of the hook's own JSON payload on stdin first: payload .session_id ->
# CLAUDE_SESSION_ID -> persisted nazgul/.session_id -> synthetic epoch-pid
# (last resort, matched by the digits-hyphen-digits shape below). Read
# guarded by a TTY check + tolerant cat, mirroring
# teammate-idle-guard.sh/subagent-stop.sh so this never hangs the hook.
STDIN_PAYLOAD=""
if [ ! -t 0 ]; then
  STDIN_PAYLOAD=$(cat 2>/dev/null || echo "")
fi
PAYLOAD_SESSION_ID=""
if [ -n "$STDIN_PAYLOAD" ]; then
  PAYLOAD_SESSION_ID=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi
if [ -n "$PAYLOAD_SESSION_ID" ]; then
  SESSION_ID="$PAYLOAD_SESSION_ID"
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_SESSION_ID"
elif [ -s "$NAZGUL_DIR/.session_id" ]; then
  SESSION_ID=$(cat "$NAZGUL_DIR/.session_id")
else
  SESSION_ID="$(date +%s)-$$"
fi

# Session tracking — register this session and warn on concurrent
SESSIONS_DIR="$NAZGUL_DIR/sessions"
# Persist resolved session ID so the SessionEnd hook can unregister it
printf '%s' "$SESSION_ID" > "$NAZGUL_DIR/.session_id"
register_session "$SESSION_ID" "$SESSIONS_DIR"
cleanup_stale_sessions "$SESSIONS_DIR"
CONCURRENT_WARNING=""
if warning_msg=$(is_concurrent_session_warning "$SESSIONS_DIR"); then
  CONCURRENT_WARNING="$warning_msg"
fi

# In-flight marker hygiene (#104 direction c): markers past the staleness bound are
# quarantined (never deleted — stop-hook.sh doctrine) so an orphan backlog never regrows.
#
# Three constraints, all from PR #223 review #2:
#  - Gated on `guards.in_flight_hold`. An operator who disabled the hold subsystem
#    disabled this too; the stop-hook's own quarantine is gated, so this must be.
#  - NEVER on `source: compact`. Compaction is not a new session. SessionStart fires
#    on it, so an unguarded sweep silently destroyed a long AFK run's crashed-subagent
#    evidence mid-run, and the recurring in_flight_stale diagnostic stopped with it.
#  - Emits `in_flight_swept`, NOT `in_flight_orphan`. `orphan` now asserts a PROVEN
#    class (background:"false" or a named dispatch) and `skills/status/SKILL.md` tells
#    operators exactly that; an aged background:"true" marker is merely OLD. Reusing the
#    name here would rebuild, one file over, the same conflation F-E just removed.
IN_FLIGHT_DIR="$NAZGUL_DIR/in-flight"
IFM_HOLD_ENABLED=$(jq -r 'if .guards.in_flight_hold == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
IFM_SOURCE=$(printf '%s' "$STDIN_PAYLOAD" | jq -r '.source // empty' 2>/dev/null || echo "")
if [ -d "$IN_FLIGHT_DIR" ] && [ "$IFM_HOLD_ENABLED" = "true" ] && [ "$IFM_SOURCE" != "compact" ]; then
  STALE_MIN=$(jq -r '[.guards.in_flight_stale_minutes // 30, 1] | max' "$CONFIG" 2>/dev/null || echo 30)
  case "$STALE_MIN" in ''|*[!0-9]*) STALE_MIN=30 ;; esac
  IFM_NOW=$(date +%s)
  IFM_CUTOFF=$((IFM_NOW - STALE_MIN * 60))
  for ifm in "$IN_FLIGHT_DIR"/*.json; do
    [ -f "$ifm" ] || continue
    ifm_epoch=$(jq -r '.dispatched_at_epoch // 0' "$ifm" 2>/dev/null || echo 0)
    case "$ifm_epoch" in ''|*[!0-9]*) ifm_epoch=0 ;; esac
    if [ "$ifm_epoch" -lt "$IFM_CUTOFF" ]; then
      ifm_unit=$(jq -r '.unit // "unknown"' "$ifm" 2>/dev/null || echo "unknown")
      mkdir -p "$IN_FLIGHT_DIR/quarantine" 2>/dev/null || true
      mv "$ifm" "$IN_FLIGHT_DIR/quarantine/" 2>/dev/null || true
      emit_event "in_flight_swept" source "session_start_sweep" unit "$ifm_unit" age_minutes:n "$(( (IFM_NOW - ifm_epoch) / 60 ))" || true
    fi
  done
fi

# Orphaned-team sweep (spec 2026-07-24) — dead-session Agent-Teams state
# attributable to THIS project. Kill-switch: guards.team_sweep. A sweep that
# cannot identify the current session must not sweep (RULES.md §15/ADR-009):
# if resolution above fell all the way through to the synthetic epoch-pid
# fallback, that id can never match a team's leadSessionId, so skip instead
# of sweeping under a wrong identity and log why.
TT_SWEEP_NOTICE=""
TT_SWEEP_ENABLED=$(jq -r 'if .guards.team_sweep == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
if [ "$TT_SWEEP_ENABLED" = "true" ]; then
  if [[ "$SESSION_ID" =~ ^[0-9]+-[0-9]+$ ]]; then
    TT_SWEEP_NOTICE="Skipped orphaned-team sweep: current session id could not be resolved (unresolved_session_id) — see nazgul/logs/team-sweep.jsonl."
    mkdir -p "$NAZGUL_DIR/logs" 2>/dev/null || true
    jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{ts:$ts, action:"skipped", reason:"unresolved_session_id"}' \
      >> "$NAZGUL_DIR/logs/team-sweep.jsonl" 2>/dev/null || true
  else
    source "$SCRIPT_DIR/lib/team-teardown.sh"
    TT_MIN_AGE=$(jq -r '[.guards.team_sweep_min_age_hours // 24, 1] | max' "$CONFIG" 2>/dev/null || echo 24)
    TT_SWEPT=$(tt_sweep_orphaned_teams "$NAZGUL_DIR" "$PROJECT_ROOT" "$SESSION_ID" "$TT_MIN_AGE" 2>/dev/null || true)
    [ -n "$TT_SWEPT" ] && TT_SWEEP_NOTICE="Swept orphaned team state (dead sessions): $(printf '%s' "$TT_SWEPT" | tr '\n' ' ')"
  fi
fi

# Auto-migrate config to latest schema version
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MIGRATE_SCRIPT="$PLUGIN_ROOT/scripts/migrate-config.sh"
MIGRATION_NOTICE=""
if [ -f "$MIGRATE_SCRIPT" ]; then
  MIGRATE_OUTPUT=$("$MIGRATE_SCRIPT" "$NAZGUL_DIR" 2>/dev/null) || true
  if [ -n "$MIGRATE_OUTPUT" ]; then
    MIGRATION_NOTICE="$MIGRATE_OUTPUT"
  fi
fi

MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
OBJECTIVE=$(jq -r '.objective // "none"' "$CONFIG")
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")

# MF-008: review granularity awareness, mirroring stop-hook.sh's read (its
# GRANULARITY var, ~line 51) — needed below to defer the single-task review
# dispatch suggestion to the aggregate review path in group/feature mode.
GRANULARITY=$(jq -r '.review_gate.granularity // "task"' "$CONFIG" 2>/dev/null || echo "task")
case "$GRANULARITY" in task|group|feature) ;; *) GRANULARITY="task" ;; esac

# Count tasks and find active task (shared helper; see task-utils.sh:145)
count_tasks_and_find_active "$NAZGUL_DIR/tasks"

# --- Telemetry-dark / stale plan.md detection (MF-060) ---
# Compares plan.md's declared "## Status Summary" counts against the counts
# just recomputed above. Catches an objective running outside the stop-hook
# loop (e.g. Agent-Team SendMessage fan-out), where plan.md's Status Summary
# and loop telemetry go stale/silent while the task manifests keep advancing
# underneath it — the exact condition this repo's own FEAT-013 audit run
# reproduced live. Detection-only and non-blocking: never rewrites plan.md
# (the orchestrator owns it) and never fails session start.
check_plan_staleness() {
  local plan_file="$1"
  local summary declared_total declared_planned declared_active actual_active
  local total_diff active_diff

  summary=$(awk '/^## Status Summary/{flag=1; next} /^## /{flag=0} flag' "$plan_file" 2>/dev/null) || true
  if [ -z "$summary" ]; then
    echo "WARNING: nazgul/plan.md has no parseable '## Status Summary' section — plan.md may be stale or the objective may be running outside the tracked loop (see MF-060)." >&2
    return 0
  fi

  declared_total=$(printf '%s\n' "$summary" | grep -m1 -oE 'Total tasks:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || true
  if [ -z "$declared_total" ]; then
    echo "WARNING: nazgul/plan.md's Status Summary has no parseable 'Total tasks: N' line — cannot verify against the ${TOTAL_COUNT} actual task manifest(s). Objective may be running outside the tracked loop (see MF-060)." >&2
    return 0
  fi

  declared_planned=$(printf '%s\n' "$summary" | grep -m1 -oE 'PLANNED:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || true
  declared_planned="${declared_planned:-0}"
  declared_active=$((declared_total - declared_planned))
  actual_active=$((TOTAL_COUNT - PLANNED_COUNT))

  if [ "$declared_total" -ge "$TOTAL_COUNT" ]; then
    total_diff=$((declared_total - TOTAL_COUNT))
  else
    total_diff=$((TOTAL_COUNT - declared_total))
  fi
  if [ "$declared_active" -ge "$actual_active" ]; then
    active_diff=$((declared_active - actual_active))
  else
    active_diff=$((actual_active - declared_active))
  fi

  # A drift of at most 1 (total count, or count of tasks that have left
  # PLANNED) is normal single-iteration lag between the last plan.md write and
  # this SessionStart. Beyond that — especially declared_active far below
  # actual_active, the exact all-PLANNED-but-really-in-progress symptom
  # MF-060 documents — is telemetry-dark and gets a loud, non-blocking flag.
  if [ "$total_diff" -gt 1 ] || [ "$active_diff" -gt 1 ]; then
    echo "WARNING: nazgul/plan.md's Status Summary is stale (declared: total=${declared_total} non-PLANNED=${declared_active} | actual: total=${TOTAL_COUNT} non-PLANNED=${actual_active}) — objective may be running outside the tracked loop (e.g. Agent-Team dispatch bypassing stop-hook.sh's recompute/emit). See MF-060." >&2
  fi
}

if [ -f "$PLAN" ]; then
  check_plan_staleness "$PLAN" || true
fi

# Git-hooks self-heal — first-time installs for an active loop that never
# went through its SKILL.md install call site, else re-asserts on drift;
# self_heal_git_hooks itself no-ops when guards.git_hooks is off or no
# objective is active (MF-034 defense-in-depth, see git-hooks.sh).
GIT_HOOKS_LIB="$PLUGIN_ROOT/scripts/lib/git-hooks.sh"
if [ -f "$GIT_HOOKS_LIB" ]; then
  # shellcheck source=./lib/git-hooks.sh
  source "$GIT_HOOKS_LIB"
  if declare -F self_heal_git_hooks >/dev/null 2>&1; then
    self_heal_git_hooks "$NAZGUL_DIR/.." "$CONFIG" || true
  fi
fi

# Compaction counter (GAP-008 context rot detection)
COMPACTION_FILE="$NAZGUL_DIR/.compaction_count"
HOOK_EVENT="${CLAUDE_HOOK_EVENT:-}"

# --- MF-012: idempotent compaction counter increment. This SessionStart
# (matcher=compact) fires AFTER post-compact.sh for the SAME physical
# compaction event (PreCompact -> compaction -> PostCompact -> SessionStart
# [compact], confirmed against the Claude Code hooks reference — see
# pre-compact.sh's reset comment and post-compact.sh's matching guard). A
# plain read-increment-write here as well as in post-compact.sh double-counts
# every compaction. The `mkdir` lock post-compact.sh claims first (it always
# runs first in the lifecycle) means this branch normally just skips its own
# increment; it still claims the lock itself as a defensive fallback in case
# PostCompact ever fails to run for a given compaction.
if [ "$HOOK_EVENT" = "compact" ]; then
  COMPACTION_LOCK="$NAZGUL_DIR/.compaction_count.lock"
  # Read current state or initialize
  if [ -f "$COMPACTION_FILE" ]; then
    PREV_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
  else
    PREV_COUNT=0
  fi
  if mkdir "$COMPACTION_LOCK" 2>/dev/null; then
    NEW_COUNT=$((PREV_COUNT + 1))
    # Write updated compaction state with current iteration
    printf '{"count": %d, "last_compaction_iteration": %s}\n' "$NEW_COUNT" "$ITERATION" > "$COMPACTION_FILE"
  fi
  # else: post-compact.sh already claimed and incremented for this compaction.
fi

# Read compaction count for output
if [ -f "$COMPACTION_FILE" ]; then
  COMPACTION_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
else
  COMPACTION_COUNT=0
fi

# Get latest checkpoint
LATEST_CHECKPOINT=$(ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || echo "none")

# Get reviewers
REVIEWERS=$(jq -r '.agents.reviewers // [] | join(", ")' "$CONFIG" 2>/dev/null || echo "none configured")

# Git state
GIT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
GIT_LAST=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || echo "unknown")

# Branch isolation state
FEATURE_BRANCH=$(jq -r '.branch.feature // ""' "$CONFIG" 2>/dev/null || echo "")
BASE_BRANCH=$(jq -r '.branch.base // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_DIR=$(jq -r '.branch.worktree_dir // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_COUNT=0
if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
  WORKTREE_COUNT=$(find "$WORKTREE_DIR" -maxdepth 1 -name 'TASK-*' -type d 2>/dev/null | wc -l | tr -d ' ')
fi

# Stack map (FEAT-027, schema v35+): empty unless stacking is enabled or a
# layer exists; a malformed `.stack` (non-object) falls through the same
# jq-error-then-fallback path old-schema configs already use, never a crash.
STACK_LINE=""
STACK_ENABLED=$(jq -r 'if (.execution.stacking.enabled == true) then "true" else "false" end' "$CONFIG" 2>/dev/null || echo "false")
STACK_LAYER_COUNT=$(jq -r '[.stack.layers[]?] | length' "$CONFIG" 2>/dev/null || echo "0")
if [ "$STACK_ENABLED" = "true" ] || [ "$STACK_LAYER_COUNT" -gt 0 ]; then
  STACK_MAX=$(jq -r '.execution.stacking.max_unmerged // 3' "$CONFIG" 2>/dev/null || echo "3")
  STACK_OPEN=$(jq -r '[.stack.layers[]? | select(.state == "open")] | length' "$CONFIG" 2>/dev/null || echo "0")
  STACK_TIP_BRANCH=$(jq -r '([.stack.layers[]? | select(.state == "open")] | sort_by(.opened_at) | last // {}) | (.branch // "")' "$CONFIG" 2>/dev/null || echo "")
  STACK_TIP_PR=$(jq -r '([.stack.layers[]? | select(.state == "open")] | sort_by(.opened_at) | last // {}) | (.pr // "")' "$CONFIG" 2>/dev/null || echo "")
  STACK_HALTED=$(jq -r 'if (.execution.stacking.halted == true) then "true" else "false" end' "$CONFIG" 2>/dev/null || echo "false")
  STACK_HALT_REASON=$(jq -r '.execution.stacking.halt_reason // ""' "$CONFIG" 2>/dev/null || echo "")
  STACK_LINE="Stack: ${STACK_OPEN} open / cap ${STACK_MAX}"
  if [ -n "$STACK_TIP_BRANCH" ]; then
    STACK_TIP_PR_NUM=""
    if [[ "$STACK_TIP_PR" =~ ([0-9]+)$ ]]; then
      STACK_TIP_PR_NUM="${BASH_REMATCH[1]}"
    fi
    if [ -n "$STACK_TIP_PR_NUM" ]; then
      STACK_LINE="${STACK_LINE} | tip: ${STACK_TIP_BRANCH} (PR #${STACK_TIP_PR_NUM} open)"
    else
      STACK_LINE="${STACK_LINE} | tip: ${STACK_TIP_BRANCH} (no PR yet)"
    fi
  fi
  if [ "$STACK_HALTED" = "true" ]; then
    STACK_LINE="${STACK_LINE} | HALTED${STACK_HALT_REASON:+: $STACK_HALT_REASON}"
  fi
fi

# Output context
cat << CONTEXT_EOF
Nazgul loop state — iteration ${ITERATION}/${MAX_ITER} | Mode: ${MODE} | Objective: ${OBJECTIVE}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked, ${CANCELLED_COUNT} cancelled | Total: ${TOTAL_COUNT}
Compactions: ${COMPACTION_COUNT}
CONTEXT_EOF

# Output Recovery Pointer if plan exists
if [ -f "$PLAN" ]; then
  echo ""
  sed -n '/^## Recovery Pointer/,/^## /p' "$PLAN" | head -7
fi

cat << CONTEXT_EOF2
$([ -n "$MIGRATION_NOTICE" ] && echo "NOTICE: $MIGRATION_NOTICE" || true)
Active task: ${ACTIVE_TASK:-none} (${ACTIVE_STATUS:-none})
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Do NOT skip the review gate." || true)
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF}" || true)
$([ "$GRANULARITY" != "task" ] && { [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] || [ "$ACTIVE_STATUS" = "IN_REVIEW" ]; } && echo "NOTE: review granularity is ${GRANULARITY} — do NOT spawn a single-task review-gate for ${ACTIVE_TASK}; it is parked pending the aggregate review unit (MF-008). Read nazgul/plan.md for aggregate-review readiness before dispatching." || true)
$([ "$ACTIVE_STATUS" = "READY" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Create-or-recover its worktree and pass the printed path as <task_worktree>: bash -c 'source \"${SCRIPT_DIR}/worktree-utils.sh\" && create_task_worktree ${ACTIVE_TASK} \"${PROJECT_ROOT}\" \"${CONFIG}\"'" || true)
$([ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Create-or-recover its worktree and pass the printed path as <task_worktree>: bash -c 'source \"${SCRIPT_DIR}/worktree-utils.sh\" && create_task_worktree ${ACTIVE_TASK} \"${PROJECT_ROOT}\" \"${CONFIG}\"'" || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Read consolidated feedback first, and pass the retained <task_worktree> for this task." || true)
Reviewers: ${REVIEWERS}
$([ -n "$FEATURE_BRANCH" ] && echo "Branch: ${FEATURE_BRANCH} → ${BASE_BRANCH} | Worktrees: ${WORKTREE_COUNT}" || true)
$([ -n "$STACK_LINE" ] && echo "$STACK_LINE" || true)
Git: ${GIT_BRANCH} — ${GIT_LAST}
Latest checkpoint: ${LATEST_CHECKPOINT}
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "WARNING: Read nazgul/reviews/${ACTIVE_TASK}/consolidated-feedback.md for reviewer feedback." || true)
$([ -n "$CONCURRENT_WARNING" ] && echo "$CONCURRENT_WARNING" || true)
$([ -n "$TT_SWEEP_NOTICE" ] && echo "$TT_SWEEP_NOTICE" || true)

Read nazgul/plan.md for full state. Continue the Nazgul pipeline.
CONTEXT_EOF2
