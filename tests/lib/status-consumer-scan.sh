#!/usr/bin/env bash
# Mechanical discovery of the task-status CONSUMER population, shared by
# tests/test-cancelled-status.sh (the gate: every consumer is CANCELLED-aware or
# enumerated-exempt) and tests/test-cancelled-status-consumers.sh (the
# denominator check: every consumer is pinned by some test file).
#
# The population is DERIVED from the shipped tree, never authored. An authored
# list is what let an eighth veto site (scripts/webhook-forward.sh) and a ninth
# (scripts/notify.sh, issue #203) ship while the suite stayed green.
#
# Boundary, stated rather than implied: the walk covers scripts/** only —
# executable code, where a CANCELLED-blind branch is a live defect. The prose
# surfaces (skills/**, templates/**, RULES.md) are pinned by the behavioural rows
# in tests/test-cancelled-status-consumers.sh, not by this scan.

SCS_STATUS_TOKENS='(PLANNED|READY|IN_PROGRESS|IMPLEMENTED|IN_REVIEW|APPROVED|CHANGES_REQUESTED|BLOCKED|DONE|CANCELLED)'
SCS_STATE_SIGNAL='(nazgul/tasks|/tasks"|/tasks/|TASK-\*|get_task_status|count_tasks_by_status|count_tasks_and_find_active|task_status|TASKS_DIR|tasks_dir)'

# Enumerated exemptions, each individually justified: a discovered consumer that
# is neither CANCELLED-aware nor listed here is a FINDING, not an absent entry.
scs_exemption() { # <rel-path> -> prints justification, exit 0 if exempt
  case "$1" in
    scripts/notify.sh)
      echo "issue #203, deliberately unfixed this objective: the loop-completion check counts DONE only, so an objective carrying a CANCELLED task never notifies" ;;
    scripts/webhook-forward.sh)
      echo "second-board finding, fix owned by rework unit RW-B: tasks_done counts DONE only while tasks_total includes CANCELLED, so the payload never reaches parity" ;;
    scripts/lib/review-evidence.sh)
      echo "its status-shaped tokens are review VERDICTS (CHANGES_REQUESTED/SKIPPED/UNVERIFIED); its nazgul/tasks/ read is resolve_review_unit's feat_id lookup, which never branches on task status" ;;
    scripts/self-audit.sh)
      echo "its status-shaped tokens are review verdicts and its tasks/ read is a retry-count scan; it never branches on task status" ;;
    scripts/task-state-guard.sh)
      echo "preflight only: its one status predicate is IN_PROGRESS, and transition legality is delegated wholly to scripts/lib/task-transition-guard.sh, which is CANCELLED-aware" ;;
    scripts/scrub-stale-review-artifacts.sh)
      echo "enumerates the OPEN statuses; CANCELLED is terminal and correctly absent (driven as row 18 of tests/test-cancelled-status-consumers.sh)" ;;
    scripts/parallel-rework-guard.sh)
      echo "scope ownership requires DONE|IMPLEMENTED plus a recorded commit, so a cancelled task owns nothing (driven as row 15 of tests/test-cancelled-status-consumers.sh)" ;;
    scripts/git-hooks/pre-merge-commit)
      echo "gates on review APPROVAL evidence rather than the status vocabulary; a cancelled unit carries no approval and is correctly blocked (driven as row 17 of tests/test-cancelled-status-consumers.sh)" ;;
    *) return 1 ;;
  esac
  return 0
}

scs_code() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }

scs_is_consumer() { # <file>
  local code
  code=$(scs_code "$1")
  [ -n "$code" ] || return 1
  printf '%s\n' "$code" | grep -qE "$SCS_STATUS_TOKENS" || return 1
  printf '%s\n' "$code" | grep -qE "$SCS_STATE_SIGNAL" || return 1
  return 0
}

scs_is_cancelled_aware() { # <file>
  scs_code "$1" | grep -q 'CANCELLED'
}

# scs_run <tree-root> — the SINGLE driver: the shipped-tree arm and the dogfood
# arm both go through it. Sets SCS_N/M/K/F plus the classified path lists.
scs_run() {
  local root="$1" f rel
  SCS_N=0; SCS_M=0; SCS_K=0; SCS_F=0
  SCS_M_NONCONSUMER=0; SCS_M_UNREADABLE=0
  SCS_CONSUMERS=""; SCS_AWARE=""; SCS_EXEMPT=""; SCS_UNCLASSIFIED=""; SCS_RETIRED=""

  [ -d "$root/scripts" ] || return 1

  while IFS= read -r f; do
    rel="${f#"$root"/}"
    SCS_N=$((SCS_N + 1))
    if [ ! -r "$f" ]; then
      SCS_M=$((SCS_M + 1)); SCS_M_UNREADABLE=$((SCS_M_UNREADABLE + 1)); continue
    fi
    if ! scs_is_consumer "$f"; then
      SCS_M=$((SCS_M + 1)); SCS_M_NONCONSUMER=$((SCS_M_NONCONSUMER + 1)); continue
    fi
    SCS_K=$((SCS_K + 1))
    SCS_CONSUMERS="${SCS_CONSUMERS}${rel}"$'\n'
    if scs_is_cancelled_aware "$f"; then
      SCS_AWARE="${SCS_AWARE}${rel}"$'\n'
      scs_exemption "$rel" >/dev/null && SCS_RETIRED="${SCS_RETIRED}${rel}"$'\n'
    elif scs_exemption "$rel" >/dev/null; then
      SCS_EXEMPT="${SCS_EXEMPT}${rel}"$'\n'
    else
      SCS_F=$((SCS_F + 1))
      SCS_UNCLASSIFIED="${SCS_UNCLASSIFIED}${rel}"$'\n'
    fi
  done < <(find "$root/scripts" \( -type f -o -type l \) | sort)
  return 0
}

scs_coverage_line() { # <label>
  printf '  %s: %d scanned, %d skipped (non-consumer=%d, unreadable=%d), %d checked, %d findings\n' \
    "$1" "$SCS_N" "$SCS_M" "$SCS_M_NONCONSUMER" "$SCS_M_UNREADABLE" "$SCS_K" "$SCS_F"
}
