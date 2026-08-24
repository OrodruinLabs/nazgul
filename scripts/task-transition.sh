#!/usr/bin/env bash
set -euo pipefail

# Transactional task-state writer (ADR-020). Under a per-task lock, a successful
# invocation validates one staged snapshot, rechecks the source immediately
# before an atomic rename, verifies the target on disk, and only then records
# transition authority. The lock serializes authoritative transition writers;
# it is not claimed to make an unrelated raw filesystem write transactional.
#
# `repair` is the ONLY exit from a typed reconciliation quarantine. It is closed
# to every other blocker class and revalidates canonical evidence from local
# files and Git history before walking the mode-derived REPAIR_EDGES list. It
# never uses READY and never dispatches an implementer.

usage() {
  echo "Usage: scripts/task-transition.sh transition TASK-NNN FROM TO [--reason TEXT|--reason=TEXT]" >&2
  echo "       scripts/task-transition.sh repair TASK-NNN" >&2
}

[ "$#" -ge 2 ] || { usage; exit 1; }
SUBCOMMAND="$1"
case "$SUBCOMMAND" in
  transition) [ "$#" -ge 4 ] || { usage; exit 1; } ;;
  repair)     [ "$#" -eq 2 ] || { usage; exit 1; } ;;
  *)          usage; exit 1 ;;
esac

TASK_ID="$2"
FROM_STATUS=""
TO_STATUS=""
REASON=""
if [ "$SUBCOMMAND" = "transition" ]; then
  FROM_STATUS="$3"
  TO_STATUS="$4"
  shift 4
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason=*) REASON="${1#--reason=}"; shift ;;
      --reason)
        [ "$#" -ge 2 ] || { usage; echo "task-transition: --reason requires a value" >&2; exit 1; }
        REASON="$2"
        shift 2
        ;;
      *) usage; echo "task-transition: unknown argument: $1" >&2; exit 1 ;;
    esac
  done
  case "$REASON" in
    *$'\n'*|*$'\r'*)
      echo "task-transition: --reason must be one line" >&2
      exit 1
      ;;
  esac
  if [ -n "$REASON" ] && [ "$TO_STATUS" != "BLOCKED" ]; then
    echo "task-transition: --reason is only valid when TO is BLOCKED" >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"

PROJECT_ROOT="$(resolve_project_root)"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
  echo "task-transition: project root does not exist" >&2
  exit 1
}
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
[ -f "$NAZGUL_DIR/config.json" ] && [ ! -L "$NAZGUL_DIR/config.json" ] \
  && jq -e 'type == "object"' "$NAZGUL_DIR/config.json" >/dev/null 2>&1 || {
  echo "task-transition: no valid regular non-symlink Nazgul config at $NAZGUL_DIR/config.json" >&2
  exit 1
}

if [ "$SUBCOMMAND" = "transition" ]; then
  if ! ttg_apply_transition "$NAZGUL_DIR" "$PROJECT_ROOT" \
    "$TASK_ID" "$FROM_STATUS" "$TO_STATUS" "$REASON"; then
    echo "task-transition: ${TASK_ID} did not complete ${FROM_STATUS} -> ${TO_STATUS}" >&2
    exit 1
  fi
  echo "task-transition: ${TASK_ID} ${FROM_STATUS} -> ${TO_STATUS} completed and recorded"
  exit 0
fi

# The shared anchor, so this reader cannot disagree with the gate that refuses the same record.
repair_field() {
  ttg_manifest_field "$MANIFEST_TEXT" "$1" || true
}

repair_deny() {
  echo "task-transition: repair refused for ${TASK_ID} — $1" >&2
  _ttg_emit_event "$NAZGUL_DIR" "reconciliation_repair" \
    task_id "$TASK_ID" action "denied" reason "$2"
  exit 1
}

MANIFEST_FILE=$(ttg_task_manifest_path "$NAZGUL_DIR" "$TASK_ID") || {
  echo "task-transition: no regular task manifest for ${TASK_ID} under ${NAZGUL_DIR}/tasks" >&2
  exit 1
}
MANIFEST_TEXT=$(cat "$MANIFEST_FILE")
LIVE_STATUS=$(get_task_status "$MANIFEST_FILE" "")

[ "$LIVE_STATUS" = "BLOCKED" ] \
  || repair_deny "live status is ${LIVE_STATUS:-missing}, not BLOCKED; repair only exits a quarantine" "not_blocked"

BLOCKED_KIND=$(repair_field "Blocked kind")
if [ -z "$BLOCKED_KIND" ]; then
  repair_deny "the manifest records no 'Blocked kind' — an untyped blocker is not a reconciliation quarantine; use /nazgul:task unblock" "untyped_blocker"
fi
# The SHARED predicate, never a second reading: a manifest the gate holds and repair refuses is one
# the Write/Edit checker will not let an operator edit either — frozen, with no exit at all.
if ! ttg_is_reconciliation_quarantine "$MANIFEST_TEXT"; then
  repair_deny "blocker kind is '${BLOCKED_KIND}', not 'reconciliation'; repair is closed to other blocker classes — use /nazgul:task unblock" "wrong_blocker_kind"
fi

QUARANTINE_FROM=$(repair_field "Blocked from")
QUARANTINE_OBSERVED=$(repair_field "Blocked observed")
for _field_pair in "Blocked from:$QUARANTINE_FROM" "Blocked observed:$QUARANTINE_OBSERVED"; do
  case "${_field_pair##*:}" in
    PLANNED|READY|IN_PROGRESS|IMPLEMENTED|IN_REVIEW|APPROVED|CHANGES_REQUESTED|DONE|BLOCKED|CANCELLED) ;;
    *) repair_deny "quarantine metadata is incomplete: '${_field_pair%%:*}' is '${_field_pair##*:}', not a canonical status" "corrupt_quarantine_metadata" ;;
  esac
done

case "$QUARANTINE_OBSERVED" in
  IN_REVIEW|DONE) ;;
  *) repair_deny "the quarantined status was ${QUARANTINE_OBSERVED}, which is not reviewed work; repair restores review-completed tasks only" "unreviewed_observed_status" ;;
esac

REPAIR_CHECKS=0
REPAIR_FINDINGS=""
repair_check() {
  local name="$1"; shift
  REPAIR_CHECKS=$((REPAIR_CHECKS + 1))
  "$@" >/dev/null 2>&1 || REPAIR_FINDINGS="${REPAIR_FINDINGS}${REPAIR_FINDINGS:+, }${name}"
}

repair_review_evidence_complete() {
  local problems
  problems=$(ttg_verify_review_evidence "$NAZGUL_DIR" "$TASK_ID") || true
  [ -z "$problems" ]
}
repair_provenance_valid() {
  local problems
  [ "$REQUIRE_PROVENANCE" = "true" ] || return 0
  problems=$(validate_review_provenance "$NAZGUL_DIR" "$REVIEW_UNIT") || true
  [ -z "$problems" ]
}
repair_review_dir_safe() {
  local dir
  dir=$(ttg_review_dir_path "$NAZGUL_DIR" "$REVIEW_UNIT") || return 1
  ttg_review_evidence_paths_safe "$NAZGUL_DIR" "$dir"
}

REQUIRE_PROVENANCE=$(jq -r 'if .review_gate.require_provenance == false then "false" else "true" end' \
  "$NAZGUL_DIR/config.json" 2>/dev/null || echo "true")
REVIEW_UNIT=$(resolve_review_unit "$NAZGUL_DIR" "$TASK_ID")

repair_check "commit-evidence" ttg_verify_commit_evidence "$MANIFEST_TEXT" "$PROJECT_ROOT"
repair_check "red-run-evidence" ttg_verify_red_run_evidence "$MANIFEST_TEXT" "$PROJECT_ROOT" "$TASK_ID" "$NAZGUL_DIR"
repair_check "review-directory" repair_review_dir_safe
repair_check "review-verdicts" repair_review_evidence_complete
repair_check "review-provenance" repair_provenance_valid

if [ -n "$REPAIR_FINDINGS" ]; then
  echo "task-transition: repair ${TASK_ID} — ${REPAIR_CHECKS} evidence checks run, incomplete: ${REPAIR_FINDINGS}" >&2
  repair_deny "incomplete evidence for review unit ${REVIEW_UNIT}: ${REPAIR_FINDINGS}" "incomplete_evidence"
fi

YOLO_MODE=$(jq -r 'if .afk.yolo == true then "true" else "false" end' \
  "$NAZGUL_DIR/config.json" 2>/dev/null || echo "false")
TASK_PR_MODE=$(jq -r 'if .afk.task_pr == true then "true" else "false" end' \
  "$NAZGUL_DIR/config.json" 2>/dev/null || echo "false")
# YOLO task-PR review reaches DONE only through APPROVED; hard-coding
# IN_REVIEW -> DONE made every repair in that mode refuse at the second edge.
if [ "$YOLO_MODE" = "true" ] && [ "$TASK_PR_MODE" = "true" ]; then
  REPAIR_EDGES=("BLOCKED:IN_REVIEW" "IN_REVIEW:APPROVED" "APPROVED:DONE")
else
  REPAIR_EDGES=("BLOCKED:IN_REVIEW" "IN_REVIEW:DONE")
fi

# A halt after the first edge has already left the quarantine, so re-enter it
# rather than report a preservation that did not happen.
repair_halt() {
  local edge="$1" live disposition detail
  live=$(get_task_status "$MANIFEST_FILE" "")
  if [ "$live" = "BLOCKED" ]; then
    disposition="preserved"
    detail="the quarantine is intact at BLOCKED"
  else
    # ttg_apply_transition can report failure after its rename lands, so the
    # disposition is read back off disk instead of taken from the return code.
    ttg_apply_transition "$NAZGUL_DIR" "$PROJECT_ROOT" "$TASK_ID" "$live" BLOCKED "" || true
    live=$(get_task_status "$MANIFEST_FILE" "")
    if [ "$live" = "BLOCKED" ]; then
      disposition="restored"
      detail="the walk had already left the quarantine at ${edge%%:*}; it was re-entered and repair may be retried"
    else
      disposition="stranded"
      detail="the walk left the quarantine and could not re-enter it; the manifest is on disk at ${live:-missing} and needs human repair"
    fi
  fi
  echo "task-transition: repair ${TASK_ID} halted at ${edge%%:*} -> ${edge##*:}; ${detail}" >&2
  _ttg_emit_event "$NAZGUL_DIR" "reconciliation_repair" \
    task_id "$TASK_ID" action "halted" reason "edge_refused" edge "$edge" \
    quarantine "$disposition" live_status "${live:-missing}"
  exit 1
}

for _repair_edge in ${REPAIR_EDGES[@]+"${REPAIR_EDGES[@]}"}; do
  if ! ttg_apply_transition "$NAZGUL_DIR" "$PROJECT_ROOT" \
    "$TASK_ID" "${_repair_edge%%:*}" "${_repair_edge##*:}" ""; then
    repair_halt "$_repair_edge"
  fi
done

REPAIRED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Staged through nz_rewrite_file: it picks an unpredictable colocated name and
# carries the manifest mode over, so no pre-created `.repair.tmp` can be aimed.
export NAZGUL_REPAIR_LINE="- **Blocked kind**: reconciliation (repaired ${REPAIRED_AT})"
if ! nz_rewrite_file "$MANIFEST_FILE" awk \
  '$0 ~ /^-[[:space:]]*[*][*]Blocked kind[*][*]:/ { print ENVIRON["NAZGUL_REPAIR_LINE"]; next } { print }' \
  "$MANIFEST_FILE"; then
  unset NAZGUL_REPAIR_LINE
  echo "task-transition: repair ${TASK_ID} completed its walk but could not mark the quarantine repaired; rerun repair after fixing the manifest" >&2
  exit 1
fi
unset NAZGUL_REPAIR_LINE

_ttg_emit_event "$NAZGUL_DIR" "reconciliation_repair" \
  task_id "$TASK_ID" action "repaired" review_unit "$REVIEW_UNIT" \
  checkpoint_status "$QUARANTINE_FROM" observed_status "$QUARANTINE_OBSERVED" \
  checks:n "$REPAIR_CHECKS"

REPAIR_WALK=""
for _re in ${REPAIR_EDGES[@]+"${REPAIR_EDGES[@]}"}; do
  [ -n "$REPAIR_WALK" ] || REPAIR_WALK="${_re%%:*}"
  REPAIR_WALK="${REPAIR_WALK} -> ${_re#*:}"
done
echo "task-transition: repair ${TASK_ID} — ${REPAIR_CHECKS} evidence checks run, 0 findings; ${REPAIR_WALK} recorded"
