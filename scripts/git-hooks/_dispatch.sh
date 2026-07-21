#!/usr/bin/env bash
# Nazgul chain-dispatcher — sourced (or exec'd) by the managed pre-commit /
# pre-merge-commit hooks as their final step, after their own guard logic
# passes/no-ops. Forwards a hook invocation to the user's pre-existing hook
# of the same name (if any), preserving argv, stdin, and exit code, so
# installing Nazgul's `core.hooksPath` never silently disables a hook the
# user already had (husky, lefthook, a hand-written pre-push, etc.).
#
# Idempotent source guard, NOT `set -euo pipefail` when sourced — mirrors
# scripts/lib/git-utils.sh / parallel-batch.sh, which are sourced into
# hook shells that own their own strict-mode setting. Enables strict mode
# only when this file is executed directly.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  set -euo pipefail
fi

[ -n "${_NAZGUL_DISPATCH_SOURCED:-}" ] && return 0
_NAZGUL_DISPATCH_SOURCED=1

_NAZGUL_DISPATCH_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_NAZGUL_DISPATCH_CONFIG="$_NAZGUL_DISPATCH_ROOT/nazgul/config.json"

# Prints the resolved prior-hooks directory (absolute, no trailing slash), or
# nothing if it can't be resolved. Resolution order: `branch.prior_hooks_path`
# from config.json (repo-relative if not absolute); else the repo's common
# `.git/hooks` (worktree-safe — hooks are shared via the common git dir, not
# per-worktree).
_dispatch_prior_hooks_dir() {
  local dir=""
  if [ -f "$_NAZGUL_DISPATCH_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    dir=$(jq -r '.branch.prior_hooks_path // ""' "$_NAZGUL_DISPATCH_CONFIG" 2>/dev/null || echo "")
  fi
  if [ -z "$dir" ]; then
    local common_dir
    common_dir=$(git -C "$_NAZGUL_DISPATCH_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
    [ -n "$common_dir" ] || return 0
    case "$common_dir" in
      /*) : ;;
      *) common_dir="$_NAZGUL_DISPATCH_ROOT/$common_dir" ;;
    esac
    dir="$common_dir/hooks"
  fi
  case "$dir" in
    /*) : ;;
    *) dir="$_NAZGUL_DISPATCH_ROOT/$dir" ;;
  esac
  [ -d "$dir" ] || return 0
  (cd "$dir" && pwd)
}

# dispatch_prior_hook <hook_name> [argv...]
# Forwards argv + inherited stdin to the resolved prior hook of the same
# name and returns its exit code. No prior hook (or a resolved path that
# fails the trust-boundary check below) -> no-op, returns 0.
dispatch_prior_hook() {
  local hook_name="${1:-}"
  [ -n "$hook_name" ] || return 0
  shift || true

  local prior_dir
  prior_dir="$(_dispatch_prior_hooks_dir)" || return 0
  [ -n "$prior_dir" ] || return 0

  # Strip any directory components via parameter expansion (no external
  # `basename`, no `--` portability concern) so the name can't traverse out
  # of the prior-hooks dir.
  local hook_base="${hook_name##*/}"
  local prior_hook="$prior_dir/$hook_base"

  # Trust boundary: only exec an existing, executable, non-symlink regular
  # file that resolves under the recorded prior-hooks dir. config.json is
  # Nazgul-written, not user-arbitrary input at hook-run time, but a
  # corrupted/hand-edited value must degrade to no-op, never arbitrary exec.
  [ -e "$prior_hook" ] || return 0
  [ ! -L "$prior_hook" ] || return 0
  [ -f "$prior_hook" ] || return 0
  [ -x "$prior_hook" ] || return 0

  local rc=0
  "$prior_hook" "$@" || rc=$?
  return "$rc"
}
