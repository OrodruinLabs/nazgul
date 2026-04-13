#!/usr/bin/env bash
# bootstrap-preflight.sh — Pre-flight gate checks for /hydra:bootstrap-project.
# Pure functions; each returns a distinct non-zero exit code so the skill can
# branch cleanly. All operate relative to the current working directory.
#
# Exit codes:
#   10 — ./hydra/ exists (hard abort)
#   11 — ./docs/ or ./.claude/agents/ is non-empty (prompt or abort)
#   12 — ./.bootstrap-scratch/ exists from prior run (prompt)
#   0  — check passed

BOOTSTRAP_GIT_WARNING=""

check_no_hydra_dir() {
  if [ -d "./hydra" ]; then
    echo "error: ./hydra/ exists. This project is already Hydra-initialized." >&2
    echo "       /hydra:bootstrap-project generates a portable, Hydra-free bundle." >&2
    echo "       Use /hydra:start instead, or remove ./hydra/ first." >&2
    return 10
  fi
  return 0
}

check_docs_agents_empty() {
  local blocker=""
  if [ -d "./docs" ] && [ -n "$(ls -A ./docs 2>/dev/null)" ]; then
    blocker="./docs"
  elif [ -d "./.claude/agents" ] && [ -n "$(ls -A ./.claude/agents 2>/dev/null)" ]; then
    blocker="./.claude/agents"
  fi

  if [ -n "$blocker" ]; then
    echo "error: $blocker is not empty." >&2
    echo "       Re-run with --overwrite to replace existing contents." >&2
    return 11
  fi
  return 0
}

check_scratch_state() {
  if [ -d "./.bootstrap-scratch" ]; then
    echo "error: ./.bootstrap-scratch/ exists from a prior run." >&2
    echo "       Remove it or pass --wipe-scratch to start fresh." >&2
    return 12
  fi
  return 0
}

check_git_clean() {
  # shellcheck disable=SC2034
  BOOTSTRAP_GIT_WARNING=""
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  local changes
  changes=$(git status --porcelain 2>/dev/null)
  if [ -n "$changes" ]; then
    # shellcheck disable=SC2034
    BOOTSTRAP_GIT_WARNING="warning: git working tree has uncommitted changes; continuing"
  fi
  return 0
}
