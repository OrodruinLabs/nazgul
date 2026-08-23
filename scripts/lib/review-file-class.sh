#!/usr/bin/env bash
# Nazgul review-unit file classifier — the SINGLE authority for "what is this .md in
# nazgul/reviews/<unit>/?". Extracted by FEAT-031/TASK-035 because the answer existed
# twice: review-evidence.sh (which decides whether a file's verdict can approve a task)
# and review-provenance.sh (which decides whether a file's review_token must match).
# TASK-034 corrected only the first copy, so the DONE gate's two validators disagreed
# about the same directory and the second refused every orchestrator artifact.
#
# The invariant that extraction BUYS, and that a second hand-written copy could not:
# the provenance-subject set IS the verdict set. A file review-evidence will not read
# as a verdict cannot approve anything, so demanding a token from it blocks honest work;
# a file review-evidence WILL read as a verdict must carry a valid token, or a planted
# file approves a task. One classifier makes those two sets the same set by construction
# rather than by two authors agreeing.
#
# Idempotent source guard; no top-level side effects; sources nothing (both callers
# source THIS, and review-evidence.sh already sources review-provenance.sh). NOT
# `set -euo pipefail` — sourced into hook shells that must keep their own options.

[ -n "${_NAZGUL_REVIEW_FILE_CLASS_SOURCED:-}" ] && return 0
_NAZGUL_REVIEW_FILE_CLASS_SOURCED=1

# Meta-files in a review dir that are NOT reviewer verdicts.
# Usage: _is_review_meta_file <basename>
_is_review_meta_file() {
  case "$1" in
    test-failures.md|consolidated-feedback.md|simplify-report.md|summary.md) return 0 ;;
    *) return 1 ;;
  esac
}

# lean-comments: allow-run — this IS the derivation boundary the task was opened to state.
# agents/review-gate.md is the source of truth for what the orchestrator writes into a unit
# dir, and two of its classes are .md yet are NOT reviewer verdicts: the four names above,
# and adversarial-<finding-ref>.md (required at :602, already skipped as a non-verdict by
# the spec's own self-check at :355). adversarial-*.md is NOT folded into
# _is_review_meta_file because review-gate.md documents that function's contract as exactly
# those four names and calls it by name; the two copies are bound by test instead —
# tests/test-review-evidence.sh re-extracts every reviews/[UNIT-ID]/*.md write target and
# every self-check case arm out of review-gate.md and fails if this predicate does not
# recognise one. Non-.md artifacts (diff.patch, .dispatch.json) never reach here: both
# callers glob *.md.
# Usage: _re_is_orchestrator_artifact <basename>
_re_is_orchestrator_artifact() {
  _is_review_meta_file "$1" && return 0
  case "$1" in
    adversarial-*.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Trailing '-'-delimited segment of each configured reviewer name, lowercased: the roster's
# own statement of what a seat name looks like. Usage: _re_seat_suffixes <reviewers>
_re_seat_suffixes() {
  printf '%s\n' "$1" | sed -e 's/.*-//' -e '/^$/d' | tr '[:upper:]' '[:lower:]' | sort -u
}

# 0 iff <stem> ends in a segment some configured seat also ends in — BOARD-2-OUTCOME does not,
# extra-reviewer does. Usage: _re_is_seat_shaped <stem> <seat-suffixes>
_re_is_seat_shaped() {
  local last
  last=$(printf '%s' "$1" | sed 's/.*-//' | tr '[:upper:]' '[:lower:]')
  [ -n "$last" ] || return 1
  grep -qxF "$last" <<< "$2"
}

# 0 iff <stem> is a qualifier-prefixed archive (board7-code-reviewer) of a seat this run
# already reads. Usage: _re_is_superseded_copy <stem> <reviewers> <review_dir>
_re_is_superseded_copy() {
  local rest="$1"
  while [ "${rest#*-}" != "$rest" ]; do
    rest="${rest#*-}"
    grep -qxF "$rest" <<< "$2" && return 0
    [ -f "$3/$rest.md" ] && return 0
  done
  return 1
}

# lean-comments: allow-run — the composition ORDER is the rule, so it is stated once, here,
# where it is applied. Both DONE-gate validators call this and nothing else; a caller that
# re-implements the order re-opens the divergence TASK-035 closed.
#
# Prints exactly one class for <basename>, and every caller must handle all six:
#   seat        — a configured roster member's own file
#   extra-seat  — seat-shaped, not on the roster, not an archive of a seat already read
#                 (the backstop for a seat dropped from the roster mid-review)
#   unnarrowed  — no roster could be read, so no seat vocabulary exists to narrow BY;
#                 treated as a subject rather than skipped, because failing to derive the
#                 rule must widen what is checked, never what is ignored
#   artifact    — the orchestrator's own paperwork (above)
#   non-seat    — names no seat the roster names (BOARD-9-OUTCOME)
#   superseded  — a qualifier-prefixed archive of a seat this run already reads
# `seat`/`extra-seat`/`unnarrowed` are CHECKED; the rest are skipped, each under its own
# counted reason. Passing <seat-suffixes> is an optimisation only: omitted, it is derived.
# Usage: review_classify_unit_file <basename> <reviewers> <review_dir> [<seat-suffixes>]
review_classify_unit_file() {
  local base="$1" reviewers="$2" review_dir="$3" seat_suffixes="${4:-}"
  local name="${base%.md}"

  if [ -n "$reviewers" ] && grep -qxF "$name" <<< "$reviewers"; then
    printf 'seat\n'; return 0
  fi
  if _re_is_orchestrator_artifact "$base"; then
    printf 'artifact\n'; return 0
  fi
  if [ -z "$reviewers" ]; then
    printf 'unnarrowed\n'; return 0
  fi
  [ -n "$seat_suffixes" ] || seat_suffixes=$(_re_seat_suffixes "$reviewers")
  if ! _re_is_seat_shaped "$name" "$seat_suffixes"; then
    printf 'non-seat\n'; return 0
  fi
  if _re_is_superseded_copy "$name" "$reviewers" "$review_dir"; then
    printf 'superseded\n'; return 0
  fi
  printf 'extra-seat\n'
}

# lean-comments: allow-run — the §15 grammar for a review-unit scan, written ONCE. Both
# DONE-gate passes classify the same directory with the same predicates and report the same
# closed skip vocabulary, so two printf literals would be one more copy of one rule — the
# defect this file exists to close, in the very line that reports it. RULES.md §15 follows the
# EMITTER: this file is the registered entry point, and it is counted covered only when BOTH
# tokens conform, mirroring the two-scan precedent already set by the red-run evidence gate.
# The optional floor note is the caller's, because "nothing was read" means something
# different to each pass and each must be free to say which.
# Usage: review_emit_class_coverage <token> <scanned> <artifact> <non-seat> <superseded>
#                                   <checked> <findings> <unit> <seat-suffixes> [<floor-note>]
review_emit_class_coverage() {
  local token="$1" scanned="$2" a="$3" ns="$4" sc="$5" checked="$6" findings="$7"
  local unit="$8" suffixes="$9" floor="${10:-}"
  printf '%s: %d scanned, %d skipped (artifact=%d, non-seat=%d, superseded=%d), %d checked, %d findings\n' \
    "$token" "$scanned" "$((a + ns + sc))" "$a" "$ns" "$sc" "$checked" "$findings" >&2
  [ -z "$floor" ] || printf '%s: %s\n' "$token" "$floor" >&2
  printf '%s: unit=%s; seat-suffixes=[%s]\n' \
    "$token" "$unit" "$(printf '%s' "$suffixes" | tr '\n' ' ' | sed 's/[[:space:]]*$//')" >&2
}

# Prefix on a validator's own health diagnostic (NOTHING_CHECKED /
# COVERAGE_ACCOUNTING_DEFECT) — distinguishes "checker broken" from "review incomplete".
NAZGUL_VALIDATOR_DEFECT_PREFIX="VALIDATOR_DEFECT"

# 0 iff <line> is a validator self-diagnostic, not a per-reviewer problem.
# Usage: _re_is_validator_defect_line <line>
_re_is_validator_defect_line() {
  case "$1" in
    "${NAZGUL_VALIDATOR_DEFECT_PREFIX} "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Genuine (non-defect) lines of <problems>, one per line; the mirror
# _re_defect_problems keeps only the defect lines. Usage: _re_genuine_problems <problems>
_re_genuine_problems() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _re_is_validator_defect_line "$line" || printf '%s\n' "$line"
  done <<< "$1"
  return 0
}

# Usage: _re_defect_problems <problems>
_re_defect_problems() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _re_is_validator_defect_line "$line" && printf '%s\n' "$line"
  done <<< "$1"
  return 0
}
