#!/usr/bin/env bash
# Nazgul worktree-aware root resolver (FEAT-021 / ADR-008 Option 1 + Amendment
# 2026-07-28). Single shared answer to "which nazgul/ does this process
# belong to?", sourced by every guard/hook that used to compute
# NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul" directly.
#
# Precedence (ordered candidates, marker-validated, first match wins):
#   1. $CLAUDE_PROJECT_DIR             (explicit signal — wins when valid)
#   2. git rev-parse --show-toplevel   (this process's actual git worktree)
#   3. $(pwd)                          (legacy fallback)
# A candidate "validates" via _nr_has_marker(): <candidate>/nazgul/config.json
# exists and is readable. That is an EXISTENCE/readability check only, not an
# identity or content check — a validated candidate is a real Nazgul root,
# not proof it is the *intended* one for this invocation. Callers must not
# treat marker-validation as a substitute for their own scoping.
#
# An explicit CLAUDE_PROJECT_DIR is trusted over git-toplevel once it
# validates: TASK-012 corrected the original TASK-001 ordering (git-toplevel
# first), which silently overrode a valid explicit override — a regression,
# see ADR-008's Amendment for the full incident and rationale.
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
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && candidates+=("$CLAUDE_PROJECT_DIR")
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
