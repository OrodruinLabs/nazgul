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

# Reach signals, OR-composed on purpose. Board-3 QA Finding A: requiring a status
# token AND one hand-written literal set made a miss SILENT, and a PoC consumer
# that reaches its manifest through a caller-supplied path escaped. An added arm
# can only widen the candidate set, so its cost is a noisy manual classification.
SCS_SIGNAL_PATH='(nazgul/tasks|/tasks"|/tasks/|TASK-\*|TASKS_DIR|tasks_dir)'
SCS_SIGNAL_AUTHORITY='(task_status|count_tasks_by_status|count_tasks_and_find_active|get_active_task|has_status_frontmatter|read_frontmatter_field|VALID_STATUSES)'
# The manifest status FIELD in each documented manifest format — the shape a
# consumer takes when the path is a parameter and no tasks-dir literal is spelled.
SCS_SIGNAL_FIELD='([Ss]tatus:|[Ss]tatus\*\*:|##[[:space:]]*Status)'
SCS_STATE_SIGNAL="(${SCS_SIGNAL_PATH}|${SCS_SIGNAL_AUTHORITY}|${SCS_SIGNAL_FIELD})"

# Enumerated exemptions, each individually justified: a discovered consumer that
# is neither CANCELLED-aware nor listed here is a FINDING, not an absent entry.
# An entry whose defect was fixed, or whose file is no longer discovered, is a
# finding too — see scs_exemption_paths and SCS_RETIRED/SCS_ORPHANED below.
scs_exemption() { # <rel-path> -> prints justification, exit 0 if exempt
  case "$1" in
    scripts/notify.sh)
      echo "issue #203, deliberately unfixed this objective: its private DONE regex matches only the legacy '- **Status**: DONE' and '## Status: DONE' forms, so on a canonical-frontmatter manifest set DONE counts 0 and the TOTAL == DONE completion check can never hold at all — CANCELLED-blindness is the narrower case inside that larger defect" ;;
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
    scripts/prompt-guard.sh)
      echo "surfaced by the widened reach signal: it spells no status vocabulary of its own — STATUS_ALT is derived at runtime from structured-state.sh's VALID_STATUSES, the single authority, which already carries CANCELLED; a restated status name here would be the defect (driven by tests/test-prompt-guard.sh)" ;;
    scripts/git-hooks/pre-merge-commit)
      echo "gates on review APPROVAL evidence rather than the status vocabulary; a cancelled unit carries no approval and is correctly blocked (driven as row 17 of tests/test-cancelled-status-consumers.sh)" ;;
    *) return 1 ;;
  esac
  return 0
}

# The oracle is indirect so the dogfood arm can substitute a scratch exemption
# list; the shipped list is the default.
SCS_EXEMPTION_FN="${SCS_EXEMPTION_FN:-scs_exemption}"

# Derived from the live function's own case arms rather than a second authored
# copy, so the staleness checks cannot read a list the oracle has moved past.
scs_exemption_paths() {
  declare -f "$SCS_EXEMPTION_FN" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(?scripts/[A-Za-z0-9._/-]+\)' | tr -d '() \t'
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

_scs_listed() { # <path> <newline-list>
  case $'\n'"$2" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# scs_run <tree-root> — the SINGLE driver: the shipped-tree arm and the dogfood
# arm both go through it. Sets SCS_N/M/K/F plus the classified path lists.
scs_run() {
  local root="$1" f rel p
  SCS_N=0; SCS_M=0; SCS_K=0; SCS_F=0
  SCS_M_NONCONSUMER=0; SCS_M_UNREADABLE=0
  SCS_CONSUMERS=""; SCS_AWARE=""; SCS_EXEMPT=""; SCS_UNCLASSIFIED=""
  SCS_RETIRED=""; SCS_ORPHANED=""

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
      if "$SCS_EXEMPTION_FN" "$rel" >/dev/null; then
        SCS_RETIRED="${SCS_RETIRED}${rel}"$'\n'; SCS_F=$((SCS_F + 1))
      fi
    elif "$SCS_EXEMPTION_FN" "$rel" >/dev/null; then
      SCS_EXEMPT="${SCS_EXEMPT}${rel}"$'\n'
    else
      SCS_F=$((SCS_F + 1))
      SCS_UNCLASSIFIED="${SCS_UNCLASSIFIED}${rel}"$'\n'
    fi
  done < <(find "$root/scripts" \( -type f -o -type l \) | sort)

  # The other staleness mode: an exemption naming a path this walk never reached.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _scs_listed "$p" "$SCS_CONSUMERS" && continue
    SCS_ORPHANED="${SCS_ORPHANED}${p}"$'\n'; SCS_F=$((SCS_F + 1))
  done < <(scs_exemption_paths)
  return 0
}

scs_coverage_line() { # <label>
  printf '  %s: %d scanned, %d skipped (non-consumer=%d, unreadable=%d), %d checked, %d findings\n' \
    "$1" "$SCS_N" "$SCS_M" "$SCS_M_NONCONSUMER" "$SCS_M_UNREADABLE" "$SCS_K" "$SCS_F"
}
