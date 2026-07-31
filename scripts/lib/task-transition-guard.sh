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

# Real commit-SHA verification (MF-026, tightened FEAT-023/TASK-006 — Defect 5,
# hardened TASK-006 attempt 2 — security B1). Scopes evidence to the
# manifest's `## Commits` section, using the identical awk boundary
# expression as scripts/git-hooks/pre-merge-commit's commits_verify() (that
# hook runs standalone in target repos and cannot source this file, so keep
# the two textually identical rather than sharing code — ADR-013). A
# candidate must both resolve to a real commit AND be a strict descendant of
# the manifest's own `## Metadata` -> Base SHA; the Base SHA itself does not
# count as forward progress.
#
# "Base SHA label absent" and "Base SHA label present but unresolvable" are
# distinct states, not one degrade path (a present-but-corrupt value is a
# stronger trouble signal than an absent field, per CLAUDE.md's guard-must-
# know-why rule): absent degrades to existence-only (plan.md C5, genuine
# pre-convention manifests); present-but-unresolvable is a malformed
# manifest and fails CLOSED. Each state announces itself on stderr with
# distinct text. The fail-CLOSED-on-ambiguity rule (ADR-003 Decision 3) still
# governs everything else: unavailable git, non-repo project_root, and no
# resolvable candidate in `## Commits` all deny.
# Usage: ttg_verify_commit_evidence <manifest_text> <project_root>
ttg_verify_commit_evidence() {
  local manifest_text="$1" project_root="$2" sha base_sha base_sha_line commits_section
  command -v git >/dev/null 2>&1 || return 1
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 1

  base_sha_line=$(printf '%s' "$manifest_text" \
    | awk '/^## Metadata/{f=1;next} /^## /{f=0} f' \
    | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Base SHA\*\*' | head -1 || true)
  base_sha=$(printf '%s' "$base_sha_line" | grep -oE '[0-9a-f]{7,64}' | head -1 || true)
  if [ -n "$base_sha" ] && ! git -C "$project_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    base_sha=""
  fi

  if [ -n "$base_sha_line" ] && [ -z "$base_sha" ]; then
    echo "ttg_verify_commit_evidence: Base SHA label present but its value does not resolve to a real commit — manifest treated as corrupt, rejecting" >&2
    return 1
  fi
  [ -n "$base_sha" ] || echo "ttg_verify_commit_evidence: no Base SHA label in manifest — forward-progress check skipped, degrading to existence-only" >&2

  commits_section=$(printf '%s' "$manifest_text" | awk '/^## Commits/{f=1;next} /^## /{f=0} f')
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$project_root" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    [ -n "$base_sha" ] || return 0
    [ "$(git -C "$project_root" rev-parse "$sha")" = "$(git -C "$project_root" rev-parse "$base_sha")" ] && continue
    git -C "$project_root" merge-base --is-ancestor "$base_sha" "$sha" 2>/dev/null && return 0
  done < <(printf '%s' "$commits_section" | grep -oE '[0-9a-f]{7,64}' || true)
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
