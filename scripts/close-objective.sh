#!/usr/bin/env bash
set -euo pipefail

# scripts/close-objective.sh — FEAT-031 (ADR-023): the honest replacement for the
# frontmatter surgery operators resort to when an objective's PR merges outside the
# loop. Given that PR it reads merge state through scripts/lib/merge-provider.sh,
# writes `## Merge Evidence` into each stranded manifest FROM THE HOST'S OWN ANSWER,
# and walks each task to DONE through scripts/task-transition.sh.
#
# A CALLER OF THE SOLE SANCTIONED WRITER, NEVER A WRITER (ADR-020, RULES.md §2). No
# frontmatter is touched here, no review directory or verdict is fabricated, and no
# status is written by this file — every status change goes through
# scripts/task-transition.sh, which compare-and-swaps under a lock and records the
# completed edge. That is what makes this closure legitimate rather than a second
# forgery route: a status written any other way is quarantined by the stop-hook's
# bash-write reconciliation pass at the next iteration.
#
# API FIRST, ANCESTRY NEVER (ADR-023 decision 1). This script never runs
# `git merge-base --is-ancestor` and must not be "simplified" into doing so: after a
# server-side SQUASH merge no SHA in any manifest's `## Commits` section is an ancestor
# of the base branch, so ancestry reports "not shipped" for work that demonstrably
# shipped — on a squash host the check is inverted, not merely weak. Corroboration is
# computed in exactly one place, `_ttg_merge_ancestry`, which is non-blocking by
# construction; this script only REPORTS the outcome that announces, and
# `ancestry=squash_signature` is the EXPECTED reading on a squash host — it closes the
# task like any other.
#
# COVERAGE RECORD (RULES.md §15, registry member ten). The terminal stdout line is
#   close-objective: N scanned, M skipped (<reason>=<count>...), K closed, F refused
# with `N == M + K` asserted by the emitter and the skip reasons a CLOSED set. The two
# tail nouns are this entry point's domain reading of the §15 slots (checked = closed,
# findings = refused): it closes tasks, it does not check files.
#
# SKIP REASONS (closed set — always all seven, always in this order):
#   already-terminal       DONE/CANCELLED — nothing left to close
#   not-closable-status    a real status, but not IMPLEMENTED or IN_REVIEW
#   unreadable             no resolvable regular non-symlink manifest for that id
#   not-merged             the host ANSWERED and says this PR is not merged
#   merge-unverifiable     the host could not be asked, or answered unusably
#   evidence-write-failed  the `## Merge Evidence` section could not be recorded
#   transition-refused     task-transition.sh refused or failed the walk to DONE
# The last two are REFUSALS, counted in F as well as in M — a refusal is a reported
# outcome, never a crash. `not-merged` and `merge-unverifiable` are separate reasons on
# purpose: "could not look" is not "not merged", which is the whole thesis of the seam.
#
# EXIT POLICY (blocking; stated because §15 requires whichever policy ships to be):
#   0  at least one task closed and no refusal
#   1  at least one refusal
#   2  NOTHING CHECKED — K == 0 while candidates were scanned, or none were discovered
#   3  usage/precondition error, or an internal coverage-accounting defect
#
# Usage: scripts/close-objective.sh --pr <number|url> [--project-root <path>]

ENTRY="close-objective"

usage() {
  echo "Usage: scripts/close-objective.sh --pr <number|url> [--project-root <path>]" >&2
}

PR_INPUT=""
PROJECT_ROOT_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr=*)           PR_INPUT="${1#--pr=}"; shift ;;
    --pr)             [ "$#" -ge 2 ] || { usage; exit 3; }; PR_INPUT="$2"; shift 2 ;;
    --project-root=*) PROJECT_ROOT_ARG="${1#--project-root=}"; shift ;;
    --project-root)   [ "$#" -ge 2 ] || { usage; exit 3; }; PROJECT_ROOT_ARG="$2"; shift 2 ;;
    -h|--help)        usage; exit 3 ;;
    *)                echo "$ENTRY: unknown argument: $1" >&2; usage; exit 3 ;;
  esac
done
[ -n "$PR_INPUT" ] || { echo "$ENTRY: --pr is required — there is no PR to ask the host about" >&2; usage; exit 3; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=./lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"
# shellcheck source=./lib/merge-provider.sh
source "$SCRIPT_DIR/lib/merge-provider.sh"

if [ -n "$PROJECT_ROOT_ARG" ]; then
  PROJECT_ROOT="$PROJECT_ROOT_ARG"
else
  PROJECT_ROOT="$(resolve_project_root)"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
  echo "$ENTRY: project root does not exist: ${PROJECT_ROOT_ARG:-<resolved>}" >&2
  exit 3
}
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
if [ ! -f "$NAZGUL_DIR/config.json" ] || [ -L "$NAZGUL_DIR/config.json" ] \
  || ! jq -e 'type == "object"' "$NAZGUL_DIR/config.json" >/dev/null 2>&1; then
  echo "$ENTRY: no valid regular non-symlink Nazgul config at $NAZGUL_DIR/config.json" >&2
  exit 3
fi
TASKS_DIR="$NAZGUL_DIR/tasks"

SCANNED=0
CLOSED=0
REFUSED=0
SKIP_ALREADY_TERMINAL=0
SKIP_NOT_CLOSABLE=0
SKIP_UNREADABLE=0
SKIP_NOT_MERGED=0
SKIP_UNVERIFIABLE=0
SKIP_EVIDENCE_WRITE=0
SKIP_TRANSITION=0
ANC_CORROBORATED=0
ANC_SQUASH=0
ANC_OTHER=0

# _refuse <task_id> <reason> <detail> — one TYPED record per refusal, on stderr and on
# the bus, so "3 tasks stayed open" can never read as a clean close-out.
_refuse() {
  REFUSED=$((REFUSED + 1))
  printf '%s: REFUSED %s [reason: %s] — %s\n' "$ENTRY" "$1" "$2" "$3" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_refused" \
    task_id "$1" reason "$2" detail "$3" pr "$PR_INPUT"
}

MP_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-close-objective.XXXXXX")
trap 'rm -f "$MP_ERR_FILE" 2>/dev/null || true' EXIT
MP_JSON=$(merge_provider_pr_state "$PROJECT_ROOT" "$PR_INPUT" 2>"$MP_ERR_FILE") || true
cat "$MP_ERR_FILE" >&2 || true
MP_RESULT=$(printf '%s' "$MP_JSON" | jq -r '.result // "api_failure"' 2>/dev/null || echo "api_failure")
MP_MERGED=$(printf '%s' "$MP_JSON" | jq -r 'if .merged == true then "true" elif .merged == false then "false" else "unknown" end' 2>/dev/null || echo "unknown")
EV_HOST=$(printf '%s' "$MP_JSON" | jq -r '.host // ""' 2>/dev/null || echo "")
EV_PR=$(printf '%s' "$MP_JSON" | jq -r '.pr // ""' 2>/dev/null || echo "")
EV_MERGED_AT=$(printf '%s' "$MP_JSON" | jq -r '.merged_at // ""' 2>/dev/null || echo "")
EV_MERGE_COMMIT=$(printf '%s' "$MP_JSON" | jq -r '.merge_commit // ""' 2>/dev/null || echo "")

# The writer reuses the VERIFIER's own shape predicate rather than restating its
# regexes, so the two can never drift into writing evidence the gate then rejects.
_co_evidence_usable() {
  local key value
  if [ "$_TTG_MERGE_REQUIRED_FIELDS" != "host pr merged-at merge-commit" ]; then
    printf 'the transition guard now requires "%s"; this writer only knows how to record host/pr/merged-at/merge-commit' \
      "$_TTG_MERGE_REQUIRED_FIELDS"
    return 1
  fi
  for key in host pr merged-at merge-commit; do
    case "$key" in
      host)         value="$EV_HOST" ;;
      pr)           value="$EV_PR" ;;
      merged-at)    value="$EV_MERGED_AT" ;;
      merge-commit) value="$EV_MERGE_COMMIT" ;;
    esac
    if [ -z "$value" ] || ! _ttg_merge_shape_ok "$key" "$value"; then
      printf "the host reported MERGED but its answer is not usable as evidence: %s='%s'" "$key" "$value"
      return 1
    fi
  done
  return 0
}

GLOBAL_SKIP=""
GLOBAL_WHY=""
if [ "$MP_RESULT" != "ok" ]; then
  GLOBAL_SKIP="merge-unverifiable"
  GLOBAL_WHY="the host was not usefully asked about PR ${PR_INPUT} [result: ${MP_RESULT}] — this is NOT 'not merged', and no closure may be inferred from it"
elif [ "$MP_MERGED" != "true" ]; then
  GLOBAL_SKIP="not-merged"
  GLOBAL_WHY="the host ANSWERED and reports PR ${PR_INPUT} is not merged [state: $(printf '%s' "$MP_JSON" | jq -r '.state // "unknown"')] — nothing shipped, so nothing closes"
elif ! GLOBAL_WHY=$(_co_evidence_usable); then
  GLOBAL_SKIP="merge-unverifiable"
fi
if [ -n "$GLOBAL_SKIP" ]; then
  printf '%s: no closure for PR %s [%s] — %s\n' "$ENTRY" "$PR_INPUT" "$GLOBAL_SKIP" "$GLOBAL_WHY" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_blocked" \
    pr "$PR_INPUT" reason "$GLOBAL_SKIP" result "$MP_RESULT" detail "$GLOBAL_WHY"
else
  GLOBAL_WHY=""
fi

# Section body written into every closed manifest. `recorded-by` is provenance in the
# `captured-by:` tradition: evidence with no named producer is unverifiable evidence.
_co_evidence_block() {
  printf '## Merge Evidence\n'
  printf -- '- **host**: %s\n' "$EV_HOST"
  printf -- '- **pr**: %s\n' "$EV_PR"
  printf -- '- **merged-at**: %s\n' "$EV_MERGED_AT"
  printf -- '- **merge-commit**: %s\n' "$EV_MERGE_COMMIT"
  printf -- '- **recorded-by**: scripts/close-objective.sh (host API, %s)\n' "$MP_RESULT"
  printf '\n'
}

# Replace an existing `## Merge Evidence` section in place, or append one — a manifest
# written before FEAT-031 has no such section, and that is the ordinary AC20 case.
_CO_AWK_PROG='
BEGIN { emitted = 0; skip = 0; n = split(ENVIRON["NAZGUL_CO_EVIDENCE"], ev, "\n"); lastblank = 1 }
skip == 1 { if ($0 ~ /^## /) { skip = 0; print "" } else { next } }
/^## Merge Evidence[ \t]*$/ {
  if (!emitted) { for (i = 1; i <= n; i++) print ev[i]; emitted = 1 }
  skip = 1
  next
}
{ print; lastblank = ($0 ~ /^[ \t]*$/) }
END {
  if (!emitted) {
    if (!lastblank) print ""
    for (i = 1; i <= n; i++) print ev[i]
  }
}'

_co_write_evidence() {
  local file="$1" rc=0
  NAZGUL_CO_EVIDENCE="$(_co_evidence_block)"
  export NAZGUL_CO_EVIDENCE
  nz_rewrite_file "$file" awk "$_CO_AWK_PROG" "$file" || rc=$?
  unset NAZGUL_CO_EVIDENCE
  return "$rc"
}

# Corroboration is REPORTED, never computed here: the tally reads the outcome
# ttg_verify_merge_evidence announced, which is non-blocking by construction.
_co_tally_ancestry() {
  case "$(printf '%s' "$1" | grep -oE 'ancestry=[a-z_]+' | tail -1)" in
    ancestry=corroborated)     ANC_CORROBORATED=$((ANC_CORROBORATED + 1)) ;;
    ancestry=squash_signature) ANC_SQUASH=$((ANC_SQUASH + 1)) ;;
    *)                         ANC_OTHER=$((ANC_OTHER + 1)) ;;
  esac
}

_co_close_one() {
  local task_id="$1" manifest="$2" from="$3" err rc=0

  if ! err=$(_co_write_evidence "$manifest" 2>&1); then
    SKIP_EVIDENCE_WRITE=$((SKIP_EVIDENCE_WRITE + 1))
    _refuse "$task_id" "evidence-write-failed" "could not record ## Merge Evidence in ${manifest}: $(printf '%s' "$err" | tr '\n' ' ')"
    return 0
  fi
  if ! err=$(ttg_verify_merge_evidence "$(cat "$manifest")" "$PROJECT_ROOT" "$task_id" 2>&1); then
    SKIP_EVIDENCE_WRITE=$((SKIP_EVIDENCE_WRITE + 1))
    _refuse "$task_id" "evidence-write-failed" "the recorded ## Merge Evidence did not read back as verifiable [${TTG_MERGE_REASON}] — nothing was closed on it"
    return 0
  fi

  err=$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$SCRIPT_DIR/task-transition.sh" \
    transition "$task_id" "$from" DONE 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    SKIP_TRANSITION=$((SKIP_TRANSITION + 1))
    _refuse "$task_id" "transition-refused" "${from} -> DONE was refused by the sole sanctioned writer: $(printf '%s' "$err" | tr '\n' ' ')"
    return 0
  fi

  CLOSED=$((CLOSED + 1))
  _co_tally_ancestry "$err"
  printf '%s: closed %s (%s -> DONE) on merge evidence pr=%s merge-commit=%s\n' \
    "$ENTRY" "$task_id" "$from" "$EV_PR" "$EV_MERGE_COMMIT"
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_closed" \
    task_id "$task_id" from "$from" pr "$EV_PR" host "$EV_HOST" merge_commit "$EV_MERGE_COMMIT"
}

if [ -d "$TASKS_DIR" ]; then
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    SCANNED=$((SCANNED + 1))
    task_id="$(basename "$candidate" .md)"
    if ! manifest=$(ttg_task_manifest_path "$NAZGUL_DIR" "$task_id" 2>/dev/null) || [ ! -r "$manifest" ]; then
      SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1))
      printf '%s: skipped %s [unreadable] — no resolvable regular non-symlink manifest\n' "$ENTRY" "$task_id" >&2
      continue
    fi
    status=$(get_task_status "$manifest" "")
    case "$status" in
      DONE|CANCELLED)
        SKIP_ALREADY_TERMINAL=$((SKIP_ALREADY_TERMINAL + 1))
        continue ;;
      IMPLEMENTED|IN_REVIEW) ;;
      *)
        SKIP_NOT_CLOSABLE=$((SKIP_NOT_CLOSABLE + 1))
        printf '%s: skipped %s [not-closable-status] — %s is not IMPLEMENTED or IN_REVIEW\n' \
          "$ENTRY" "$task_id" "${status:-missing}" >&2
        continue ;;
    esac
    if [ -n "$GLOBAL_SKIP" ]; then
      case "$GLOBAL_SKIP" in
        not-merged)         SKIP_NOT_MERGED=$((SKIP_NOT_MERGED + 1)) ;;
        merge-unverifiable) SKIP_UNVERIFIABLE=$((SKIP_UNVERIFIABLE + 1)) ;;
      esac
      printf '%s: skipped %s [%s] — it is closable but the merge was not confirmed\n' \
        "$ENTRY" "$task_id" "$GLOBAL_SKIP" >&2
      continue
    fi
    _co_close_one "$task_id" "$manifest" "$status"
  done < <(find "$TASKS_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'TASK-*.md' | LC_ALL=C sort)
fi

if [ "$CLOSED" -gt 0 ]; then
  printf '%s: ancestry corroboration (never a predicate): corroborated=%d squash-signature=%d not-checkable=%d\n' \
    "$ENTRY" "$ANC_CORROBORATED" "$ANC_SQUASH" "$ANC_OTHER"
fi

SKIPPED=$((SKIP_ALREADY_TERMINAL + SKIP_NOT_CLOSABLE + SKIP_UNREADABLE + SKIP_NOT_MERGED \
  + SKIP_UNVERIFIABLE + SKIP_EVIDENCE_WRITE + SKIP_TRANSITION))
ACCOUNTING_OK=1
if [ "$SCANNED" -ne $((SKIPPED + CLOSED)) ]; then
  ACCOUNTING_OK=0
  printf '%s: INTERNAL — coverage accounting mismatch: %d scanned != %d skipped + %d closed\n' \
    "$ENTRY" "$SCANNED" "$SKIPPED" "$CLOSED" >&2
fi
if [ "$CLOSED" -eq 0 ]; then
  if [ "$SCANNED" -gt 0 ]; then
    printf '%s: NOTHING CHECKED — all %d candidate(s) skipped, nothing was closed\n' "$ENTRY" "$SCANNED" >&2
  else
    printf '%s: NOTHING CHECKED — no task manifests discovered under %s\n' "$ENTRY" "$TASKS_DIR" >&2
  fi
  _ttg_emit_event "$NAZGUL_DIR" "coverage_vacuous" entry_point "$ENTRY" \
    scanned:n "$SCANNED" skipped:n "$SKIPPED" refused:n "$REFUSED" pr "$PR_INPUT"
fi

_ttg_emit_event "$NAZGUL_DIR" "close_objective_summary" pr "$PR_INPUT" result "$MP_RESULT" \
  scanned:n "$SCANNED" skipped:n "$SKIPPED" closed:n "$CLOSED" refused:n "$REFUSED"

printf '%s: %d scanned, %d skipped (already-terminal=%d, not-closable-status=%d, unreadable=%d, not-merged=%d, merge-unverifiable=%d, evidence-write-failed=%d, transition-refused=%d), %d closed, %d refused\n' \
  "$ENTRY" "$SCANNED" "$SKIPPED" "$SKIP_ALREADY_TERMINAL" "$SKIP_NOT_CLOSABLE" "$SKIP_UNREADABLE" \
  "$SKIP_NOT_MERGED" "$SKIP_UNVERIFIABLE" "$SKIP_EVIDENCE_WRITE" "$SKIP_TRANSITION" "$CLOSED" "$REFUSED"

[ "$ACCOUNTING_OK" -eq 1 ] || exit 3
[ "$REFUSED" -eq 0 ] || exit 1
if [ "$CLOSED" -eq 0 ]; then exit 2; fi
exit 0
