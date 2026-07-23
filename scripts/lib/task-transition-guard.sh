#!/usr/bin/env bash
# Nazgul shared task-transition/evidence library (MF-022 Bundle 2, ADR-003
# Decision 2). Sourced by BOTH scripts/task-state-guard.sh (PreToolUse gate)
# and scripts/stop-hook.sh (stop-hook-time reconciliation), so a transition
# accepted by one call site is provably accepted by the other — no second
# implementation to drift out of sync.

_TTG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TTG_DIR/task-utils.sh"
# shellcheck source=/dev/null
source "$_TTG_DIR/review-evidence.sh"

# Constitution Article III state machine — single source of truth for both
# call sites (was previously duplicated as a local function in
# task-state-guard.sh only).
# Usage: ttg_valid_transition <from> <to>
ttg_valid_transition() {
  local from="$1" to="$2"
  case "${from}_${to}" in
    PLANNED_READY)                 return 0 ;;
    PLANNED_BLOCKED)               return 0 ;;
    READY_BLOCKED)                 return 0 ;;
    READY_IN_PROGRESS)             return 0 ;;
    IN_PROGRESS_IMPLEMENTED)       return 0 ;;
    IN_PROGRESS_BLOCKED)           return 0 ;;
    IMPLEMENTED_BLOCKED)           return 0 ;;
    IMPLEMENTED_IN_REVIEW)         return 0 ;;
    IN_REVIEW_DONE)                return 0 ;;
    IN_REVIEW_APPROVED)            return 0 ;;
    IN_REVIEW_CHANGES_REQUESTED)   return 0 ;;
    IN_REVIEW_BLOCKED)             return 0 ;;
    APPROVED_DONE)                 return 0 ;;
    APPROVED_BLOCKED)              return 0 ;;
    CHANGES_REQUESTED_IN_PROGRESS) return 0 ;;
    CHANGES_REQUESTED_BLOCKED)     return 0 ;;
    # BLOCKED exits: READY via /nazgul:task unblock; IN_REVIEW via
    # /nazgul:review --materialize (still requires a review directory).
    BLOCKED_READY)                 return 0 ;;
    BLOCKED_IN_REVIEW)             return 0 ;;
    *) return 1 ;;
  esac
}

# Real commit-SHA verification (MF-026). Extracts every 7-40 char lowercase-hex
# candidate substring from manifest_text and accepts iff at least one resolves
# to a real, reachable commit object via `git cat-file -e`. Fails CLOSED (no
# match) when git is unavailable or project_root isn't a repo — an
# evidence-trust gate must deny on ambiguity, never silently degrade back to a
# pattern match (ADR-003 Decision 3).
# Usage: ttg_verify_commit_evidence <manifest_text> <project_root>
ttg_verify_commit_evidence() {
  local manifest_text="$1" project_root="$2" sha
  command -v git >/dev/null 2>&1 || return 1
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$project_root" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  done < <(printf '%s' "$manifest_text" | grep -oE '[0-9a-f]{7,40}')
  return 1
}

# Thin pass-through to review-evidence.sh's validate_review_evidence so both
# call sites exercise the identical review-gate evidence check (Constitution
# Rule 5) through this one library.
# Usage: ttg_verify_review_evidence <nazgul_dir> <task_id>
ttg_verify_review_evidence() {
  validate_review_evidence "$1" "$2"
}

# Append one entry to the guarded-transition ledger. Called only after a
# transition has passed ttg_valid_transition() and all evidence gates on the
# PreToolUse path — the stop-hook reconciliation pass reads this ledger to
# tell a legitimate Write/Edit/MultiEdit-mediated transition apart from a
# Bash-write bypass (MF-022). Trimmed to the newest 500 lines so the ledger
# never grows unbounded across a long-running loop.
# Usage: ttg_log_transition <nazgul_dir> <task_id> <from> <to>
ttg_log_transition() {
  local nazgul_dir="$1" task_id="$2" from="$3" to="$4"
  local ledger="$nazgul_dir/logs/guarded-transitions.jsonl"
  mkdir -p "$nazgul_dir/logs"
  jq -nc --arg t "$task_id" --arg f "$from" --arg to "$to" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id:$t, from:$f, to:$to, timestamp:$ts}' >> "$ledger" 2>/dev/null || true
  tail -n 500 "$ledger" > "${ledger}.tmp" 2>/dev/null && mv "${ledger}.tmp" "$ledger" || true
}

# True iff the ledger records a guarded transition landing on `to` for
# task_id at or after since_ts. Matches on the endpoint only (not the exact
# from->to pair) so a legitimate multi-hop sequence within one agent turn
# (e.g. IN_PROGRESS->IMPLEMENTED->IN_REVIEW, two separate guarded calls) isn't
# mistaken for a bypass — the reconciliation pass's recompute-and-compare
# check (MF-022): a live status is only trusted if some guarded call landed
# on it since the last checkpoint.
# Usage: ttg_transition_is_guarded <nazgul_dir> <task_id> <to> <since_ts>
ttg_transition_is_guarded() {
  local nazgul_dir="$1" task_id="$2" to="$3" since_ts="$4"
  local ledger="$nazgul_dir/logs/guarded-transitions.jsonl"
  [ -f "$ledger" ] || return 1
  jq -e --arg t "$task_id" --arg to "$to" --arg since "$since_ts" \
    'select(.task_id == $t and .to == $to and .timestamp >= $since)' \
    "$ledger" >/dev/null 2>&1
}
