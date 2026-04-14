#!/usr/bin/env bash
# bootstrap-preflight.sh — Pre-flight gate checks for /hydra:bootstrap-project.
# Pure functions; each returns a distinct non-zero exit code so the skill can
# branch cleanly. All operate relative to the current working directory.
#
# Exit codes:
#   10 — ./hydra/ exists (hard abort)
#   11 — ./docs/ or ./.claude/agents/ non-empty, or a design file already
#         exists at ./.claude/design-tokens.json or ./.claude/design-system.md
#         (prompt or abort)
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

# _dir_blocker <path>
#   Classifies a directory for preflight purposes. Prints the appropriate
#   blocker label to stdout (empty string if no blocker). Exits 0.
#
#   Cases:
#     - doesn't exist          → no blocker (prints "")
#     - exists, unreadable     → blocker (prints "<path> (unreadable)")
#     - exists, readable, empty→ no blocker (prints "")
#     - exists, readable, non-empty → blocker (prints "<path>")
#
#   Fails CLOSED: an unreadable or un-inspectable dir is treated as a blocker
#   so the skill won't silently overwrite into a path it can't introspect.
_dir_blocker() {
  local d="$1"
  [ -d "$d" ] || { printf ''; return; }
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then
    printf '%s (unreadable)' "$d"
    return
  fi
  # `find -mindepth 1 -print -quit` emits one line iff the dir has at least
  # one entry. Redirect stderr so a late-stage permission issue on a child
  # doesn't leak noise; stdout gives us the signal we need either way.
  if find "$d" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    printf '%s' "$d"
  fi
}

check_docs_agents_empty() {
  # Accumulate ALL blocker paths so the user sees them at once instead of
  # hitting a confusing sequence of single-blocker failures on successive runs.
  local -a blockers=()
  local b
  b=$(_dir_blocker "./docs");             [ -n "$b" ] && blockers+=("$b")
  b=$(_dir_blocker "./.claude/agents");   [ -n "$b" ] && blockers+=("$b")
  # Design files are individual files (not directories) this skill may write
  # to. Guard against clobbering pre-existing user config.
  if [ -f "./.claude/design-tokens.json" ]; then
    blockers+=("./.claude/design-tokens.json")
  fi
  if [ -f "./.claude/design-system.md" ]; then
    blockers+=("./.claude/design-system.md")
  fi

  if [ "${#blockers[@]}" -gt 0 ]; then
    echo "error: the following skill-managed targets already exist or cannot be inspected:" >&2
    for b in "${blockers[@]}"; do
      echo "  - $b" >&2
    done
    echo "       Re-run with --overwrite to replace them, or fix permissions on unreadable paths." >&2
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
