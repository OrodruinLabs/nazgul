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

# lean-comments: allow-run — an unexplained reach-signal arm is the defect this widening closes.
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

# lean-comments: allow-run — what makes an absent entry a finding rather than a silence.
# Enumerated exemptions, each individually justified: a discovered consumer that
# is neither CANCELLED-aware nor listed here is a FINDING, not an absent entry.
# An entry whose defect was fixed, or whose file is no longer discovered, is a
# finding too — see scs_exemption_paths and SCS_RETIRED/SCS_ORPHANED below.
scs_exemption() { # <rel-path> -> prints justification, exit 0 if exempt
  case "$1" in
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
    scripts/lib/review-provenance.sh)
      echo "gates on review PROVENANCE evidence (token match, diff hash, subject-file classification) rather than the status vocabulary; its read_frontmatter_field reach reads a REVIEW file's review_token, and every DONE occurrence is prose naming the gate that consumes its output — no predicate here reads a task status, so a cancelled unit's provenance validates identically" ;;
    *) return 1 ;;
  esac
  return 0
}

# lean-comments: allow-run — why "undecidable" is a third answer, not a quiet non-consumer.
# Board-3 QA Finding A's second half: a file carrying a status token but NO reach
# signal is UNDECIDABLE by this predicate, not "not a consumer". Each is triaged
# by hand here with what its token actually is; an untriaged one is a FINDING, so
# a new arrival is a fail-closed queue entry rather than a silent omission.
scs_ambiguous() { # <rel-path> -> prints triage, exit 0 if triaged
  case "$1" in
    scripts/heartbeat.sh)
      echo "BLOCKED_TASK at :210 is a halt SIGNAL relayed from _pb_blocked_tasks in scripts/lib/parallel-batch.sh (a scanned consumer, CANCELLED-aware); heartbeat.sh does no status arithmetic of its own" ;;
    scripts/lib/emit-event.sh)
      echo "READY occurs only inside the identifier _EMIT_DIR_READY (:15,:70,:72) — a directory-cache flag, not the status vocabulary" ;;
    scripts/lib/stack-utils.sh)
      echo "CHANGES_REQUESTED at :904,:909 is a GitHub PR reviewDecision read from the gh API, a different vocabulary that happens to share a token" ;;
    scripts/migrate-config.sh)
      echo "DONE appears only inside log_migration message literals (:653,:744); no predicate reads a task status" ;;
    scripts/subagent-stop.sh)
      echo "its APPROVE|CHANGES_REQUESTED|UNVERIFIED matches (:272,:387) are the reviewer VERDICT vocabulary, correctly out of the task-status domain" ;;
    *) return 1 ;;
  esac
  return 0
}

# The oracles are indirect so the dogfood arms can substitute scratch lists; the
# shipped functions are the defaults.
SCS_EXEMPTION_FN="${SCS_EXEMPTION_FN:-scs_exemption}"
SCS_AMBIGUOUS_FN="${SCS_AMBIGUOUS_FN:-scs_ambiguous}"

# Derived from the live functions' own case arms rather than a second authored
# copy, so the staleness checks cannot read a list an oracle has moved past.
_scs_case_paths() { # <function-name>
  declare -f "$1" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(?scripts/[A-Za-z0-9._/-]+\)' | tr -d '() \t'
}
scs_exemption_paths() { _scs_case_paths "$SCS_EXEMPTION_FN"; }
scs_ambiguous_paths() { _scs_case_paths "$SCS_AMBIGUOUS_FN"; }

scs_code() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }

# lean-comments: allow-run — the race removed here, recorded at the shape that carried it.
# `producer | grep -q` is NON-DETERMINISTIC under `set -o pipefail` (issue #230):
# grep exits at the first match, the producer dies of SIGPIPE (141), and pipefail
# reports 141 as the pipeline's verdict. It only bites once the body outruns the
# 64 KiB pipe buffer, so it strikes the largest consumer and reads as a clean
# "not a consumer" — a false pass in the other direction. A here-string has no
# producer whose exit status can reach the answer.
scs_grep_code() { # <file> <ere>
  local code
  code=$(scs_code "$1")
  [ -n "$code" ] || return 1
  grep -qE "$2" <<< "$code"
}

scs_has_status_token() { # <file>
  scs_grep_code "$1" "$SCS_STATUS_TOKENS"
}

scs_is_consumer() { # <file>
  local code
  code=$(scs_code "$1")
  [ -n "$code" ] || return 1
  grep -qE "$SCS_STATUS_TOKENS" <<< "$code" || return 1
  grep -qE "$SCS_STATE_SIGNAL" <<< "$code" || return 1
  return 0
}

scs_is_cancelled_aware() { # <file>
  scs_grep_code "$1" 'CANCELLED'
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
  SCS_M_NOTOKEN=0; SCS_M_AMBIGUOUS=0; SCS_M_UNTRIAGED=0; SCS_M_UNREADABLE=0
  SCS_CONSUMERS=""; SCS_AWARE=""; SCS_EXEMPT=""; SCS_UNCLASSIFIED=""
  SCS_RETIRED=""; SCS_ORPHANED=""
  SCS_AMBIGUOUS=""; SCS_UNTRIAGED=""; SCS_AMBIG_STALE=""

  [ -d "$root/scripts" ] || return 1

  while IFS= read -r -u 9 f; do
    rel="${f#"$root"/}"
    SCS_N=$((SCS_N + 1))
    if [ ! -r "$f" ]; then
      SCS_M=$((SCS_M + 1)); SCS_M_UNREADABLE=$((SCS_M_UNREADABLE + 1)); continue
    fi
    if ! scs_is_consumer "$f"; then
      SCS_M=$((SCS_M + 1))
      if ! scs_has_status_token "$f"; then
        SCS_M_NOTOKEN=$((SCS_M_NOTOKEN + 1))
      elif "$SCS_AMBIGUOUS_FN" "$rel" >/dev/null; then
        SCS_M_AMBIGUOUS=$((SCS_M_AMBIGUOUS + 1))
        SCS_AMBIGUOUS="${SCS_AMBIGUOUS}${rel}"$'\n'
      else
        SCS_M_UNTRIAGED=$((SCS_M_UNTRIAGED + 1)); SCS_F=$((SCS_F + 1))
        SCS_UNTRIAGED="${SCS_UNTRIAGED}${rel}"$'\n'
      fi
      continue
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
  done 9< <(find "$root/scripts" \( -type f -o -type l \) | LC_ALL=C sort)

  # The other staleness mode: an exemption naming a path this walk never reached.
  while IFS= read -r -u 9 p; do
    [ -n "$p" ] || continue
    _scs_listed "$p" "$SCS_CONSUMERS" && continue
    SCS_ORPHANED="${SCS_ORPHANED}${p}"$'\n'; SCS_F=$((SCS_F + 1))
  done 9< <(scs_exemption_paths)

  # Same discipline for the triage list: an arm naming a path that is no longer
  # ambiguous (it became a consumer, or left the tree) states a fact that expired.
  while IFS= read -r -u 9 p; do
    [ -n "$p" ] || continue
    _scs_listed "$p" "$SCS_AMBIGUOUS" && continue
    SCS_AMBIG_STALE="${SCS_AMBIG_STALE}${p}"$'\n'; SCS_F=$((SCS_F + 1))
  done 9< <(scs_ambiguous_paths)
  return 0
}

scs_coverage_line() { # <label>
  printf '  %s: %d scanned, %d skipped (no-status-token=%d, triaged-ambiguous=%d, untriaged-ambiguous=%d, unreadable=%d), %d checked, %d findings\n' \
    "$1" "$SCS_N" "$SCS_M" "$SCS_M_NOTOKEN" "$SCS_M_AMBIGUOUS" "$SCS_M_UNTRIAGED" \
    "$SCS_M_UNREADABLE" "$SCS_K" "$SCS_F"
}

# lean-comments: allow-run — the false-pass this predicate replaces, kept at the predicate.
# scs_pin_class <tests-dir> <rel> -> reached | named-only | unnamed
#
# Board-3 NEW-5: "the path string appears anywhere in any tests/test-*.sh" counts
# a comment, and counts a file's own name inside another test's discovery list —
# a naming check wearing a driving check's costume. A ROOTED reference on a
# non-comment line ("$REPO_ROOT/<rel>" and friends) is a test addressing the real
# file on disk; a bare mention is undecidable from text alone and says so.
scs_pin_class() {
  local tests_dir="$1" rel="$2" esc hits
  esc=$(printf '%s' "$rel" | sed 's/[][\.*^$/]/\\&/g')
  hits=$(grep -rn -F -e "$rel" "$tests_dir"/test-*.sh 2>/dev/null \
           | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#') || hits=""
  if grep -qE '(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\})"?/'"$esc" <<< "$hits"; then
    echo "reached"; return 0
  fi
  if grep -rlF -e "$rel" "$tests_dir"/test-*.sh >/dev/null 2>&1; then
    echo "named-only"; return 0
  fi
  echo "unnamed"
}

# lean-comments: allow-run — why a named-but-unreached site is a finding, not a skip.
# scs_pin_scan <tests-dir> <tree-root> [<consumer-list>] — the DISPOSITION of the
# classes above, kept beside the classifier so every caller drives one copy.
# `named-only` is a FINDING: a site named by a test but never reached through a
# rooted path is pinned by nothing, and skipping it is the "looked and found none"
# collapse the §15 grammar exists to prevent. `vanished` is the one skip left, and
# it states its reason: the file was readable at discovery and is not now.
scs_pin_scan() {
  local tests_dir="$1" root="$2" list="${3:-${SCS_CONSUMERS:-}}" rel
  SCS_PS_SCANNED=0; SCS_PS_SKIPPED=0; SCS_PS_VANISHED=0
  SCS_PS_PINNED=0; SCS_PS_UNDECIDABLE=0; SCS_PS_UNPINNED=0
  SCS_PS_VANISHED_PATHS=""; SCS_PS_UNDECIDABLE_PATHS=""; SCS_PS_UNPINNED_PATHS=""
  while IFS= read -r -u 9 rel; do
    [ -n "$rel" ] || continue
    SCS_PS_SCANNED=$((SCS_PS_SCANNED + 1))
    if [ ! -r "$root/$rel" ]; then
      SCS_PS_SKIPPED=$((SCS_PS_SKIPPED + 1)); SCS_PS_VANISHED=$((SCS_PS_VANISHED + 1))
      SCS_PS_VANISHED_PATHS="${SCS_PS_VANISHED_PATHS}${rel}"$'\n'
      continue
    fi
    case "$(scs_pin_class "$tests_dir" "$rel")" in
      reached)
        SCS_PS_PINNED=$((SCS_PS_PINNED + 1)) ;;
      named-only)
        SCS_PS_UNDECIDABLE=$((SCS_PS_UNDECIDABLE + 1))
        SCS_PS_UNDECIDABLE_PATHS="${SCS_PS_UNDECIDABLE_PATHS}${rel}"$'\n' ;;
      *)
        SCS_PS_UNPINNED=$((SCS_PS_UNPINNED + 1))
        SCS_PS_UNPINNED_PATHS="${SCS_PS_UNPINNED_PATHS}${rel}"$'\n' ;;
    esac
  done 9<<< "$list"
  SCS_PS_CHECKED=$((SCS_PS_PINNED + SCS_PS_UNDECIDABLE + SCS_PS_UNPINNED))
  SCS_PS_FINDINGS=$((SCS_PS_UNDECIDABLE + SCS_PS_UNPINNED))
  return 0
}

scs_pin_scan_line() { # <label>
  printf '  %s: %d scanned, %d skipped (vanished=%d), %d checked, %d findings\n' \
    "$1" "$SCS_PS_SCANNED" "$SCS_PS_SKIPPED" "$SCS_PS_VANISHED" \
    "$SCS_PS_CHECKED" "$SCS_PS_FINDINGS"
}
