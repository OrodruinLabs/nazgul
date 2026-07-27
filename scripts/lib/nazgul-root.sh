#!/usr/bin/env bash
# Nazgul worktree-aware root resolver (FEAT-021 / ADR-008 Option 1, with the
# planner's marker-validation amendment — see nazgul/plan.md "Planner
# correction"). Single shared answer to "which nazgul/ does this process
# belong to?", sourced by every guard/hook that used to compute
# NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul" directly.
#
# Precedence (ordered candidates, marker-validated, first match wins):
#   1. git rev-parse --show-toplevel   (this process's actual git worktree)
#   2. $CLAUDE_PROJECT_DIR             (session-level override)
#   3. $(pwd)                          (legacy fallback)
# A candidate "validates" when <candidate>/nazgul/config.json exists and is
# readable. The first validating candidate wins — git-toplevel beats a stale
# CLAUDE_PROJECT_DIR whenever both are real Nazgul roots, which is the live
# worktree-vs-main-checkout incident shape this resolver exists to fix.
#
# If NO candidate validates (project not yet /nazgul:init'd, or a non-git
# host), resolve_project_root() falls back to the first non-empty candidate —
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
  local git_root
  local -a candidates=()
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  [ -n "$git_root" ] && candidates+=("$git_root")
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && candidates+=("$CLAUDE_PROJECT_DIR")
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
