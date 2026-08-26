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
# THE PR MUST BIND TO THIS OBJECTIVE, TWICE, OR NOTHING CLOSES. "Is PR N merged?" is
# not the question this script needs answered; "did THIS objective ship as PR N?" is.
# Asking only the first turns any merged PR in the repository into genuine, host-verified,
# ledger-recorded authority to walk every closable manifest on disk to DONE — no forgery
# required, and every downstream gate correctly satisfied. So two bindings are checked
# before a single manifest is touched, and each fails CLOSED:
#     PR -> objective        its head branch must be `branch.feature`, or the branch of
#                            the `stack.layers[]` entry registered for `feat_id`
#     manifest -> objective  it must be listed in this objective's own `nazgul/plan.md`
#                            roster, whose frontmatter feat_id must agree with config's
# Neither is a formality. A merged PR whose head is another objective's branch is real
# evidence about a different objective, and a manifest absent from the roster belongs to
# a different one; both are refused BY NAME rather than closed.
#
# NEITHER BINDING IS ENFORCED HERE. Both live in scripts/lib/task-transition-guard.sh —
# `ttg_pr_bound` and `ttg_objective_roster`/`ttg_task_in_objective` — and this script is
# one of their two callers; the merge-evidence gate is the other, and it is independently
# reachable through `scripts/task-transition.sh transition <id> IMPLEMENTED DONE`. A
# binding enforced only in this caller would leave that gate admitting what this script
# refuses, which is exactly the defect the shared functions exist to prevent.
#
# A REFUSED CLOSE LEAVES NO EVIDENCE BEHIND. `## Merge Evidence` is gate-satisfying on
# its own, so a section written for a close that then refused would sit in the manifest
# indistinguishable from a successful one and admit a later `transition <id> IMPLEMENTED
# DONE` by any agent, on residue. The write, its read-back and the restore therefore share
# ONE scripts/lib/manifest-write.sh critical section (ADR-031), and the pre-close bytes come
# from that primitive's own snapshot rather than a second hand-rolled copy of the live file;
# a rollback that itself fails says so, loudly, in the refusal record and the final report.
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
# SKIP REASONS (closed set — always all nine, always in this order):
#   already-terminal       DONE/CANCELLED — nothing left to close
#   not-closable-status    a real status, but not IMPLEMENTED or IN_REVIEW
#   unreadable             no resolvable regular non-symlink manifest for that id
#   not-this-objective     the manifest is not in this objective's roster, or no roster
#                          could be read at all — both refuse, and each says which
#   pr-not-this-objective  the PR merged, but from a branch that is not this objective's
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=./lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"
# The libraries are sourced BEFORE the arguments are parsed so that the untrusted --pr
# value can be redacted through the seam's own `_mp_oneline` the first time it is echoed.
# shellcheck source=./lib/merge-provider.sh
source "$SCRIPT_DIR/lib/merge-provider.sh"

# One PR, one host question. Without it this pass asked per manifest, at the net tier's 60s
# bound, on the path merge-provider's own header calls the worst place for an unbounded wait.
ttg_install_merge_host_state_memo || true

PR_INPUT=""
PROJECT_ROOT_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr=*)           PR_INPUT="${1#--pr=}"; shift ;;
    --pr)             [ "$#" -ge 2 ] || { usage; exit 3; }; PR_INPUT="$2"; shift 2 ;;
    --project-root=*) PROJECT_ROOT_ARG="${1#--project-root=}"; shift ;;
    --project-root)   [ "$#" -ge 2 ] || { usage; exit 3; }; PROJECT_ROOT_ARG="$2"; shift 2 ;;
    -h|--help)        usage; exit 3 ;;
    *)                echo "$ENTRY: unknown argument: $(_mp_oneline "$1")" >&2; usage; exit 3 ;;
  esac
done
[ -n "$PR_INPUT" ] || { echo "$ENTRY: --pr is required — there is no PR to ask the host about" >&2; usage; exit 3; }

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
SKIP_NOT_THIS_OBJECTIVE=0
SKIP_PR_NOT_THIS_OBJECTIVE=0
SKIP_NOT_MERGED=0
SKIP_UNVERIFIABLE=0
SKIP_EVIDENCE_WRITE=0
SKIP_TRANSITION=0
ANC_CORROBORATED=0
ANC_SQUASH=0
ANC_OTHER=0
ROLLBACK_FAILED=0
CO_ROLLBACK_NOTE=""
CFG_FEAT_ID=$(jq -r '.feat_id // ""' "$NAZGUL_DIR/config.json" 2>/dev/null || echo "")

# _refuse <task_id> <reason> <detail> — one TYPED record per refusal, on stderr and on
# the bus, so "3 tasks stayed open" can never read as a clean close-out.
_refuse() {
  REFUSED=$((REFUSED + 1))
  printf '%s: REFUSED %s [reason: %s] — %s\n' "$ENTRY" "$1" "$2" "$3" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_refused" \
    task_id "$1" reason "$2" detail "$3" pr "$PR_SAFE"
}

MP_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-close-objective.XXXXXX")
VERIFY_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-close-objective-verify.XXXXXX")
# The primitive deletes its own snapshot on install, so the bytes a later rollback restores
# are carried out of the producer HERE — still the primitive's snapshot, never a second read.
CO_PRECLOSE_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-close-objective-preclose.XXXXXX")
CO_HELD_LOCK=""
trap 'rm -f "$MP_ERR_FILE" "$VERIFY_ERR_FILE" "$CO_PRECLOSE_FILE" 2>/dev/null || true
      [ -z "${CO_HELD_LOCK:-}" ] || _nz_release_lock "$CO_HELD_LOCK" "${NZ_LOCK_TOKEN:-}" 2>/dev/null || true' EXIT
# Bash runs no EXIT trap on an untrapped INT/TERM, and the lock is a directory: without these
# an operator's Ctrl-C mid-close wedges every later transition for that task until a human rmdirs.
trap 'exit 130' INT
trap 'exit 143' TERM
MP_JSON=$(merge_provider_pr_state "$PROJECT_ROOT" "$PR_INPUT" 2>"$MP_ERR_FILE") || true
cat "$MP_ERR_FILE" >&2 || true
MP_RESULT=$(printf '%s' "$MP_JSON" | jq -r '.result // "api_failure"' 2>/dev/null || echo "api_failure")
MP_MERGED=$(printf '%s' "$MP_JSON" | jq -r 'if .merged == true then "true" elif .merged == false then "false" else "unknown" end' 2>/dev/null || echo "unknown")
EV_HOST=$(printf '%s' "$MP_JSON" | jq -r '.host // ""' 2>/dev/null || echo "")
EV_PR=$(printf '%s' "$MP_JSON" | jq -r '.pr // ""' 2>/dev/null || echo "")
EV_MERGED_AT=$(printf '%s' "$MP_JSON" | jq -r '.merged_at // ""' 2>/dev/null || echo "")
EV_MERGE_COMMIT=$(printf '%s' "$MP_JSON" | jq -r '.merge_commit // ""' 2>/dev/null || echo "")
EV_HEAD_REF=$(printf '%s' "$MP_JSON" | jq -r '.head_ref // ""' 2>/dev/null || echo "")
EV_BASE_REF=$(printf '%s' "$MP_JSON" | jq -r '.base_ref // ""' 2>/dev/null || echo "")

# --pr can carry credentials in its userinfo, so the normalised number is what every
# record carries; an unnormalisable value goes through the seam's own redaction.
PR_SAFE="$EV_PR"
[ -n "$PR_SAFE" ] || PR_SAFE=$(_mp_oneline "$PR_INPUT")

# The provenance line the gate validates against its own closed producer set. Defined
# once, so what is WRITTEN and what is pre-validated cannot be two different strings.
_co_recorded_by() {
  printf 'scripts/close-objective.sh (host API, %s)' "$MP_RESULT"
}

# The writer reuses the VERIFIER's own shape predicate rather than restating its
# regexes, so the two can never drift into writing evidence the gate then rejects.
_co_evidence_usable() {
  local key value
  if [ "$_TTG_MERGE_REQUIRED_FIELDS" != "host pr merged-at merge-commit head-ref recorded-by" ]; then
    printf 'the transition guard now requires "%s"; this writer only knows how to record host/pr/merged-at/merge-commit/head-ref/recorded-by' \
      "$_TTG_MERGE_REQUIRED_FIELDS"
    return 1
  fi
  for key in host pr merged-at merge-commit head-ref recorded-by; do
    case "$key" in
      host)         value="$EV_HOST" ;;
      pr)           value="$EV_PR" ;;
      merged-at)    value="$EV_MERGED_AT" ;;
      merge-commit) value="$EV_MERGE_COMMIT" ;;
      head-ref)     value="$EV_HEAD_REF" ;;
      recorded-by)  value="$(_co_recorded_by)" ;;
    esac
    if [ -z "$value" ] || ! _ttg_merge_shape_ok "$key" "$value"; then
      printf "the host reported MERGED but its answer is not usable as evidence: %s='%s'" "$key" "$value"
      return 1
    fi
  done
  return 0
}

# lean-comments: allow-run — why each binding has exactly one home, not one per caller.
# Both bindings are asked in ONE place each — ttg_pr_bound for the PR, ttg_objective_roster
# for the manifest: the merge-evidence gate enforces the same two questions independently
# through the sanctioned writer, so a copy here is a copy that can drift away from the
# boundary that actually blocks.

ROSTER=""
ROSTER_SKIP_WHY=""
if ROSTER=$(ttg_objective_roster "$NAZGUL_DIR"); then
  ROSTER_SKIP_WHY="it is not listed in ${CFG_FEAT_ID}'s roster in ${NAZGUL_DIR}/plan.md — another objective's manifest is not closed by this objective's merge"
else
  ROSTER_SKIP_WHY="the objective roster could not be read, so membership was never established"
  printf '%s: the objective roster could not be read [%s] — every candidate is skipped as not-this-objective rather than closed on an unscoped scan\n' \
    "$ENTRY" "$ROSTER" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_roster_unreadable" \
    feat_id "$CFG_FEAT_ID" reason "$ROSTER" pr "$PR_SAFE"
  ROSTER=""
fi

GLOBAL_SKIP=""
GLOBAL_WHY=""
if [ "$MP_RESULT" != "ok" ]; then
  GLOBAL_SKIP="merge-unverifiable"
  GLOBAL_WHY="the host was not usefully asked about PR ${PR_SAFE} [result: ${MP_RESULT}] — this is NOT 'not merged', and no closure may be inferred from it"
elif ! GLOBAL_WHY=$(ttg_pr_bound "$NAZGUL_DIR" "$CFG_FEAT_ID" "$EV_HEAD_REF" "$PR_SAFE" "$EV_BASE_REF"); then
  GLOBAL_SKIP="pr-not-this-objective"
elif [ "$MP_MERGED" != "true" ]; then
  GLOBAL_SKIP="not-merged"
  GLOBAL_WHY="the host ANSWERED and reports PR ${PR_SAFE} is not merged [state: $(printf '%s' "$MP_JSON" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")] — nothing shipped, so nothing closes"
elif ! GLOBAL_WHY=$(_co_evidence_usable); then
  GLOBAL_SKIP="merge-unverifiable"
fi
if [ -n "$GLOBAL_SKIP" ]; then
  printf '%s: no closure for PR %s [%s] — %s\n' "$ENTRY" "$PR_SAFE" "$GLOBAL_SKIP" "$GLOBAL_WHY" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_blocked" \
    pr "$PR_SAFE" reason "$GLOBAL_SKIP" result "$MP_RESULT" detail "$GLOBAL_WHY"
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
  printf -- '- **head-ref**: %s\n' "$EV_HEAD_REF"
  printf -- '- **recorded-by**: %s\n' "$(_co_recorded_by)"
  printf '\n'
}

# lean-comments: allow-run — the skip arm's missing blank is deliberate and invisible from awk.
# Replace an existing `## Merge Evidence` section in place, or append one — a manifest
# written before FEAT-031 has no such section, and that is the ordinary AC20 case.
# The skip arm does NOT emit the separating blank: the block carries its own trailing one
# (below), and printing a second here gave the mid-file replace two where append got one.
_CO_AWK_PROG='
BEGIN { emitted = 0; skip = 0; n = split(ENVIRON["NAZGUL_CO_EVIDENCE"], ev, "\n"); lastblank = 1 }
skip == 1 { if ($0 ~ /^## /) { skip = 0 } else { next } }
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

# The producer the shared primitive runs over its OWN snapshot (ADR-031): the pre-close bytes a
# rollback may need come from there, so no second read of the live manifest can drift from them.
_co_evidence_producer() {
  local snapshot="$1"
  cat "$snapshot" > "$CO_PRECLOSE_FILE" || return 1
  awk "$_CO_AWK_PROG" "$snapshot"
}

# INNER form: _co_locked_close already holds this task's lock, and the outer would deadlock on it.
_co_write_evidence() {
  local task_id="$1" rc=0
  # `$(...)` strips the block's trailing newline, so the trailing one is re-added HERE and is
  # the section's ONLY separating blank — every branch then writes the same bytes.
  NAZGUL_CO_EVIDENCE="$(_co_evidence_block)
"
  export NAZGUL_CO_EVIDENCE
  nz_manifest_write_locked "$NAZGUL_DIR" "$task_id" -- _co_evidence_producer || rc=$?
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

# The primitive appends its snapshot path to every producer; a restore must emit the pre-close
# bytes ALONE, so it names its own source and drops that trailing argument.
_co_emit_preclose() {
  cat "$CO_PRECLOSE_FILE"
}

# lean-comments: allow-run — why a refused close must undo its own write, not just report.
# _co_rollback_via <writer> <task_id> <manifest> -> restore the pre-close bytes, leaving the
# outcome in CO_ROLLBACK_NOTE for the refusal record. `## Merge Evidence` satisfies the DONE
# gate on its own and carries no trace of the refusal that followed it, so a section left
# behind by a refused close is a standing token any later `transition <id> IMPLEMENTED DONE`
# would spend. Restoring the snapshot, rather than stripping the section, also undoes the
# replacement of a pre-existing one. <writer> is the primitive form that matches whether the
# lock is already held: it is not reentrant, so that choice belongs to the caller, not here.
_co_rollback_via() {
  local writer="$1" task_id="$2" manifest="$3" out
  CO_ROLLBACK_NOTE=""
  if out=$("$writer" "$NAZGUL_DIR" "$task_id" -- _co_emit_preclose 2>&1); then
    CO_ROLLBACK_NOTE="; the manifest was rolled back to its pre-close bytes, so no ## Merge Evidence residue remains"
    return 0
  fi
  ROLLBACK_FAILED=$((ROLLBACK_FAILED + 1))
  CO_ROLLBACK_NOTE="; ROLLBACK FAILED ($(printf '%s' "$out" | tr '\n' ' ')) — ${manifest} still carries a ## Merge Evidence section that no closure stands behind; remove it by hand before any transition is attempted"
  return 1
}

_co_rollback() {
  _co_rollback_via nz_manifest_write_locked "$@"
}

# lean-comments: allow-run — why the section is opened here rather than by nz_manifest_with_lock.
# _co_with_task_lock <task_id> <command…> — ONE critical section for the evidence write, its
# host-verified read-back and the rollback: two acquisitions let another writer land between a
# refused close and its undo. The lock PATH, the acquire and the release are the primitive's own
# (ADR-031) — one protocol, one lock — but the section is opened in THIS shell rather than
# through nz_manifest_with_lock, which runs its command in a subshell. The read-back's host memo
# and its consecutive-non-answer cap are per-PROCESS state (PATCH-008 item 9); from a subshell
# neither survives, so every manifest re-asks a dead host at the net tier's full 60s and the cap
# never fires. Measured on this suite: 5 host asks where 4 are owed, and 6 where 4 are.
_co_with_task_lock() {
  local task_id="$1" lock rc=0
  shift
  CO_LOCK_ERR=""
  if ! lock=$(nz_manifest_lock_path "$NAZGUL_DIR" "$task_id" 2>&1); then
    CO_LOCK_ERR="$lock"
    return 1
  fi
  NZ_LOCK_TOKEN=""
  if ! _nz_acquire_lock "$lock" 1; then
    CO_LOCK_ERR=$(_nz_mw_fail lock_unavailable "another transition already holds the ${task_id} lock" 2>&1) || true
    return 1
  fi
  CO_HELD_LOCK="$lock"
  "$@" || rc=$?
  _nz_release_lock "$lock" "$NZ_LOCK_TOKEN" 2>/dev/null || true
  CO_HELD_LOCK=""
  return "$rc"
}

# Runs under _co_with_task_lock, in the CURRENT shell. 4 means the read-back refused and the
# rollback ran; any other non-zero means the primitive refused the write and named its cause.
_co_locked_close() {
  local task_id="$1" manifest="$2" vrc=0
  CO_WRITE_ERR=""
  CO_ROLLBACK_NOTE=""
  if ! CO_WRITE_ERR=$(_co_write_evidence "$task_id" 2>&1); then
    return 1
  fi
  # CURRENT SHELL, never `err=$(ttg_verify_merge_evidence …)`: the reason is returned in a
  # global, and a subshell's assignment cannot reach the record that has to name it.
  ttg_verify_merge_evidence "$(cat "$manifest")" "$PROJECT_ROOT" "$task_id" "$NAZGUL_DIR" \
    2>"$VERIFY_ERR_FILE" || vrc=$?
  if [ "$vrc" -eq 0 ]; then
    return 0
  fi
  _co_rollback "$task_id" "$manifest" || true
  return 4
}

_co_close_one() {
  local task_id="$1" manifest="$2" from="$3" err rc=0 lrc=0

  CO_WRITE_ERR=""
  CO_LOCK_ERR=""
  CO_ROLLBACK_NOTE=""
  _co_with_task_lock "$task_id" _co_locked_close "$task_id" "$manifest" || lrc=$?
  if [ "$lrc" -eq 4 ]; then
    SKIP_EVIDENCE_WRITE=$((SKIP_EVIDENCE_WRITE + 1))
    err=$(tr '\n' ' ' < "$VERIFY_ERR_FILE" 2>/dev/null) || err=""
    _refuse "$task_id" "evidence-write-failed" "the recorded ## Merge Evidence did not read back as verifiable [${TTG_MERGE_REASON:-unreported}] — nothing was closed on it${err:+; the verifier said: ${err}}${CO_ROLLBACK_NOTE}"
    return 0
  fi
  if [ "$lrc" -ne 0 ]; then
    # No rollback on this arm: nz_manifest_write_locked installs through an atomic rename, so
    # a failed write left the manifest untouched and a restore here could only add noise.
    SKIP_EVIDENCE_WRITE=$((SKIP_EVIDENCE_WRITE + 1))
    _refuse "$task_id" "evidence-write-failed" "could not record ## Merge Evidence in ${manifest}: $(printf '%s' "${CO_WRITE_ERR}${CO_LOCK_ERR}" | tr '\n' ' ')"
    return 0
  fi

  err=$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" bash "$SCRIPT_DIR/task-transition.sh" \
    transition "$task_id" "$from" DONE 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    SKIP_TRANSITION=$((SKIP_TRANSITION + 1))
    # The walk takes and releases this task's lock itself, so its undo is necessarily a second
    # critical section — the OUTER form, because nothing holds the lock by the time it runs.
    _co_rollback_via nz_manifest_write "$task_id" "$manifest" || true
    _refuse "$task_id" "transition-refused" "${from} -> DONE was refused by the sole sanctioned writer: $(printf '%s' "$err" | tr '\n' ' ')${CO_ROLLBACK_NOTE}"
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
    if ! ttg_id_in_roster "$ROSTER" "$task_id"; then
      SKIP_NOT_THIS_OBJECTIVE=$((SKIP_NOT_THIS_OBJECTIVE + 1))
      printf '%s: skipped %s [not-this-objective] — %s\n' "$ENTRY" "$task_id" "$ROSTER_SKIP_WHY" >&2
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
        pr-not-this-objective) SKIP_PR_NOT_THIS_OBJECTIVE=$((SKIP_PR_NOT_THIS_OBJECTIVE + 1)) ;;
        not-merged)            SKIP_NOT_MERGED=$((SKIP_NOT_MERGED + 1)) ;;
        merge-unverifiable)    SKIP_UNVERIFIABLE=$((SKIP_UNVERIFIABLE + 1)) ;;
      esac
      printf '%s: skipped %s [%s] — it is closable, but PR %s was not confirmed to be this objective'"'"'s merge\n' \
        "$ENTRY" "$task_id" "$GLOBAL_SKIP" "$PR_SAFE" >&2
      continue
    fi
    _co_close_one "$task_id" "$manifest" "$status"
  done < <(find "$TASKS_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'TASK-*.md' | LC_ALL=C sort)
fi

if [ "$CLOSED" -gt 0 ]; then
  printf '%s: ancestry corroboration (never a predicate): corroborated=%d squash-signature=%d not-checkable=%d\n' \
    "$ENTRY" "$ANC_CORROBORATED" "$ANC_SQUASH" "$ANC_OTHER"
fi

if [ "$ROLLBACK_FAILED" -gt 0 ]; then
  printf '%s: %d manifest(s) kept a ## Merge Evidence section a refused close wrote — that section satisfies the DONE gate on its own, so remove it by hand before any transition is attempted\n' \
    "$ENTRY" "$ROLLBACK_FAILED" >&2
  _ttg_emit_event "$NAZGUL_DIR" "close_objective_rollback_failed" \
    count:n "$ROLLBACK_FAILED" pr "$PR_SAFE"
fi

SKIPPED=$((SKIP_ALREADY_TERMINAL + SKIP_NOT_CLOSABLE + SKIP_UNREADABLE + SKIP_NOT_THIS_OBJECTIVE \
  + SKIP_PR_NOT_THIS_OBJECTIVE + SKIP_NOT_MERGED + SKIP_UNVERIFIABLE + SKIP_EVIDENCE_WRITE + SKIP_TRANSITION))
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
    scanned:n "$SCANNED" skipped:n "$SKIPPED" refused:n "$REFUSED" pr "$PR_SAFE"
fi

_ttg_emit_event "$NAZGUL_DIR" "close_objective_summary" pr "$PR_SAFE" result "$MP_RESULT" \
  feat_id "$CFG_FEAT_ID" head_ref "$EV_HEAD_REF" \
  scanned:n "$SCANNED" skipped:n "$SKIPPED" closed:n "$CLOSED" refused:n "$REFUSED"

printf '%s: %d scanned, %d skipped (already-terminal=%d, not-closable-status=%d, unreadable=%d, not-this-objective=%d, pr-not-this-objective=%d, not-merged=%d, merge-unverifiable=%d, evidence-write-failed=%d, transition-refused=%d), %d closed, %d refused\n' \
  "$ENTRY" "$SCANNED" "$SKIPPED" "$SKIP_ALREADY_TERMINAL" "$SKIP_NOT_CLOSABLE" "$SKIP_UNREADABLE" \
  "$SKIP_NOT_THIS_OBJECTIVE" "$SKIP_PR_NOT_THIS_OBJECTIVE" \
  "$SKIP_NOT_MERGED" "$SKIP_UNVERIFIABLE" "$SKIP_EVIDENCE_WRITE" "$SKIP_TRANSITION" "$CLOSED" "$REFUSED"

[ "$ACCOUNTING_OK" -eq 1 ] || exit 3
[ "$REFUSED" -eq 0 ] || exit 1
if [ "$CLOSED" -eq 0 ]; then exit 2; fi
exit 0
