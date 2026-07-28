#!/usr/bin/env bash
# Nazgul worktree-aware root resolver (FEAT-021 / ADR-008 Option 1 + two
# amendments, 2026-07-28). Single shared answer to "which nazgul/ does this
# process belong to?", sourced by every guard/hook that used to compute
# NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul" directly.
#
# Resolution:
#   1. $CLAUDE_PROJECT_DIR, if set and non-empty — returned UNCONDITIONALLY.
#      No marker check, no fallthrough: an explicit designation is never
#      second-guessed. This restores baseline "${CLAUDE_PROJECT_DIR:-...}"
#      semantics exactly in the explicit-env case (see ADR-008's second
#      amendment).
#   2. Otherwise, marker-validated arbitration between the IMPLICIT
#      candidates (no stated intent to respect, so a marker check is used to
#      pick the real Nazgul root among them): git-toplevel, then $(pwd).
#      A candidate "validates" via _nr_has_marker():
#      <candidate>/nazgul/config.json exists and is readable — an
#      EXISTENCE/readability check only, not an identity/content check.
#
# If no implicit candidate validates (project not yet /nazgul:init'd, or a
# non-git host), resolve_project_root() falls back to the first candidate —
# identical to today's "${CLAUDE_PROJECT_DIR:-$(pwd)}" behavior. It never
# exits, never hard-fails, and never prints anything but the resolved path;
# $(pwd) is always non-empty so the function always succeeds. Distinguishing
# "no Nazgul project here" from anything else is the CALLER's job, exactly as
# it is today: check for the resolved nazgul/config.json yourself and no-op
# if absent.
#
# Never sources or clobbers NAZGUL_DIR — callers with their own override
# precedence (e.g. scripts/lib/raise-finding.sh) keep it in front of this.

[ -n "${_NAZGUL_ROOT_SOURCED:-}" ] && return 0
_NAZGUL_ROOT_SOURCED=1

_nr_has_marker() {
  [ -f "$1/nazgul/config.json" ] && [ -r "$1/nazgul/config.json" ]
}

resolve_project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi

  local git_root
  local -a candidates=()
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  [ -n "$git_root" ] && candidates+=("$git_root")
  candidates+=("$(pwd)")

  local c
  for c in "${candidates[@]}"; do
    if _nr_has_marker "$c"; then
      printf '%s\n' "$c"
      return 0
    fi
  done

  printf '%s\n' "${candidates[0]}"
  return 0
}

resolve_nazgul_dir() {
  printf '%s\n' "$(resolve_project_root)/nazgul"
}
