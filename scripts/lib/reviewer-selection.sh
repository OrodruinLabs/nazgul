#!/usr/bin/env bash
# Nazgul reviewer-selection — deterministic (NOT LLM) diff-aware selector for
# Gap C Lever 3. Decides which configured reviewers a changed-file set needs.
#
# Usage:
#   reviewer-selection.sh select --files "<space-list>" --reviewers "<space-list>"
#   reviewer-selection.sh verify --files "<space-list>" --reviewers "<space-list>" \
#     --claimed-skipped "<space-list of reviewer names>"
#
# `select` output (two lines, ordering follows --reviewers input order):
#   SELECTED: <space-list of reviewers to dispatch>
#   SKIPPED: <name:reason>;<name:reason>...
#
# `verify` re-derives the legitimate skipped set from --files/--reviewers and
# exits 0 only if it is EXACTLY the --claimed-skipped set (order-independent).
# This is the recompute-and-compare authenticity check consumed by
# review-evidence.sh: trust a dispatch manifest's skipped[] by reproduction,
# not by origin.
#
# Policy is CONSERVATIVE — any classification ambiguity defaults to inclusion:
#   security-reviewer   — always selected, never skippable.
#   architect-reviewer  — selected iff a file is under skills/, agents/,
#                         scripts/, hooks/, or is a config-schema file.
#   qa-reviewer         — selected iff a file is under tests/.
#   code-reviewer       — skipped only when every file is doc/markdown/text.
#   unknown reviewer    — always selected (never skip what we can't classify).
#   empty/unparseable --files -> full --reviewers set selected, none skipped.
#
# Idempotent source guard: no top-level side effects beyond function/var
# definitions when sourced; safe to `source` from another lib or hook shell.
# NOT `set -euo pipefail` for the same reason as review-provenance.sh.

[ -n "${_NAZGUL_REVIEWER_SELECTION_SOURCED:-}" ] && return 0
_NAZGUL_REVIEWER_SELECTION_SOURCED=1

_nrs_is_doc_file() {
  case "$1" in
    *.md|*.markdown|*.txt|*.rst) return 0 ;;
    *) return 1 ;;
  esac
}

_nrs_is_architecture_surface() {
  case "$1" in
    skills/*|agents/*|scripts/*|hooks/*) return 0 ;;
    templates/config.json|*config*.json) return 0 ;;
    *) return 1 ;;
  esac
}

_nrs_is_tests_file() {
  case "$1" in
    tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _nrs_join <sep> <items...> -> prints items joined by <sep>
_nrs_join() {
  local sep="$1"; shift
  local out="" item first=1
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then out="$item"; first=0; else out="$out$sep$item"; fi
  done
  printf '%s' "$out"
}

# cmd_select <files-space-list> <reviewers-space-list>
cmd_select() {
  local files_raw="$1" reviewers_raw="$2"
  local -a files=() reviewers=()
  [ -n "$files_raw" ] && read -ra files <<< "$files_raw"
  [ -n "$reviewers_raw" ] && read -ra reviewers <<< "$reviewers_raw"

  local -a selected=() skipped=()
  local r

  if [ "${#files[@]}" -eq 0 ]; then
    for r in ${reviewers[@]+"${reviewers[@]}"}; do
      selected+=("$r")
    done
    printf 'SELECTED: %s\n' "$(_nrs_join ' ' ${selected[@]+"${selected[@]}"})"
    printf 'SKIPPED: %s\n' ""
    return 0
  fi

  local has_arch=0 has_tests=0 has_nondoc=0 f
  for f in "${files[@]}"; do
    _nrs_is_architecture_surface "$f" && has_arch=1
    _nrs_is_tests_file "$f" && has_tests=1
    _nrs_is_doc_file "$f" || has_nondoc=1
  done

  for r in ${reviewers[@]+"${reviewers[@]}"}; do
    case "$r" in
      security-reviewer)
        selected+=("$r") ;;
      architect-reviewer)
        if [ "$has_arch" -eq 1 ]; then
          selected+=("$r")
        else
          skipped+=("$r:no architecture-surface change")
        fi ;;
      qa-reviewer)
        if [ "$has_tests" -eq 1 ]; then
          selected+=("$r")
        else
          skipped+=("$r:no tests/ change")
        fi ;;
      code-reviewer)
        if [ "$has_nondoc" -eq 1 ]; then
          selected+=("$r")
        else
          skipped+=("$r:doc-only change")
        fi ;;
      *)
        selected+=("$r") ;;
    esac
  done

  printf 'SELECTED: %s\n' "$(_nrs_join ' ' ${selected[@]+"${selected[@]}"})"
  printf 'SKIPPED: %s\n' "$(_nrs_join ';' ${skipped[@]+"${skipped[@]}"})"
}

# cmd_verify <files-space-list> <reviewers-space-list> <claimed-skipped-names-space-list>
# 0 iff the claimed skipped-name set exactly equals the deterministic recompute.
cmd_verify() {
  local files_raw="$1" reviewers_raw="$2" claimed_raw="$3"
  local select_out skipped_line entries=() entry
  select_out=$(cmd_select "$files_raw" "$reviewers_raw")
  skipped_line=$(printf '%s\n' "$select_out" | sed -n '2p')
  skipped_line="${skipped_line#SKIPPED: }"

  local -a actual_names=() claimed_names=()
  [ -n "$skipped_line" ] && IFS=';' read -ra entries <<< "$skipped_line"
  for entry in ${entries[@]+"${entries[@]}"}; do
    [ -z "$entry" ] && continue
    actual_names+=("${entry%%:*}")
  done
  [ -n "$claimed_raw" ] && read -ra claimed_names <<< "$claimed_raw"

  local sorted_actual sorted_claimed
  sorted_actual=$(printf '%s\n' ${actual_names[@]+"${actual_names[@]}"} | sort -u)
  sorted_claimed=$(printf '%s\n' ${claimed_names[@]+"${claimed_names[@]}"} | sort -u)
  [ "$sorted_actual" = "$sorted_claimed" ]
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    select)
      local sel_files="" sel_reviewers=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --files)     sel_files="$2";     shift 2 ;;
          --reviewers) sel_reviewers="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      cmd_select "$sel_files" "$sel_reviewers" ;;
    verify)
      local ver_files="" ver_reviewers="" ver_claimed=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --files)           ver_files="$2";     shift 2 ;;
          --reviewers)       ver_reviewers="$2";  shift 2 ;;
          --claimed-skipped) ver_claimed="$2";    shift 2 ;;
          *) shift ;;
        esac
      done
      cmd_verify "$ver_files" "$ver_reviewers" "$ver_claimed" ;;
    *)
      echo "usage: reviewer-selection.sh select --files \"<list>\" --reviewers \"<list>\"" >&2
      echo "       reviewer-selection.sh verify --files \"<list>\" --reviewers \"<list>\" --claimed-skipped \"<list>\"" >&2
      exit 2 ;;
  esac
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
