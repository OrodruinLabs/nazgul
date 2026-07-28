#!/usr/bin/env bash
set -euo pipefail

# Nazgul Worktree Utilities — shared helpers for branch/worktree management
# Source this file: source "$(dirname "$0")/worktree-utils.sh"

# Requires: NAZGUL_DIR and CONFIG to be set by the caller

# ${BASH_SOURCE[0]} is bash-only. Under zsh (the default interactive shell on
# macOS) it is an unset-parameter diagnostic that zsh treats as non-fatal:
# _WU_DIR would silently resolve to the caller's $PWD, _WU_PLUGIN_ROOT and
# _WU_GIT_HOOKS_LIB (git-hooks.sh, install_git_hooks) and _WU_NAZGUL_ROOT_LIB
# (nazgul-root.sh, resolve_project_root) would all point at wrong paths, and
# this file would half-load with no error. Refuse loudly instead.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "FATAL: worktree-utils.sh must be sourced from bash (got: $(basename "${0:-unknown}"))." >&2
  echo "The managed git-hooks install (create_feature_branch -> install_git_hooks) cannot proceed under this shell." >&2
  return 1 2>/dev/null || exit 1
fi

_WU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WU_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_WU_DIR/.." && pwd)}"
_WU_GIT_HOOKS_LIB="$_WU_PLUGIN_ROOT/scripts/lib/git-hooks.sh"
# shellcheck source=./lib/git-hooks.sh
[ -f "$_WU_GIT_HOOKS_LIB" ] && source "$_WU_GIT_HOOKS_LIB"
_WU_NAZGUL_ROOT_LIB="$_WU_PLUGIN_ROOT/scripts/lib/nazgul-root.sh"
# shellcheck source=./lib/nazgul-root.sh
[ -f "$_WU_NAZGUL_ROOT_LIB" ] && source "$_WU_NAZGUL_ROOT_LIB"

slugify_objective() {
  local input="$1"
  local slug
  slug=$(printf '%s' "$input" \
    | tr '\n\r\t' '   ' \
    | tr -s '[:space:]' ' ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' \
    | cut -c1-50)
  printf '%s' "${slug:-objective}"
}

create_feature_branch() {
  local objective="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"
  local slug
  slug=$(slugify_objective "$objective")
  # Identity reuse (Objective Identity rule): a feat_id already in config is
  # authoritative — /nazgul:plan or a prior start path assigned it, and specs
  # (objectives/FEAT-NNN-spec.md) are keyed to it. Derive a fresh id ONLY when
  # config has none; recomputing on reuse would rename the branch and prefix
  # to a wrong, off-by-one id.
  local feat_id display_id commit_prefix branch_component
  feat_id=$(jq -r '.feat_id // ""' "$config")
  if [ -n "$feat_id" ] && [ "$feat_id" != "null" ]; then
    display_id=$(jq -r '.feat_display_id // ""' "$config")
    { [ -n "$display_id" ] && [ "$display_id" != "null" ]; } || display_id="$feat_id"
    commit_prefix=$(jq -r '.afk.commit_prefix // ""' "$config")
    { [ -n "$commit_prefix" ] && [ "$commit_prefix" != "null" ]; } || commit_prefix="feat(${display_id}):"
    branch_component="${display_id#\#}"
  else
    local feat_num
    feat_num=$(jq '(.objectives_history // [] | length) + 1' "$config")
    feat_id="FEAT-$(printf '%03d' "$feat_num")"
    # Check for board issue number
    local board_issue
    board_issue=$(jq -r '.board.current_issue // ""' "$config")
    if [ -n "$board_issue" ] && [ "$board_issue" != "null" ]; then
      display_id="#${board_issue}"
      branch_component="$board_issue"
    else
      display_id="$feat_id"
      branch_component="$feat_id"
    fi
    commit_prefix="feat(${display_id}):"
  fi

  local branch_name="feat/${branch_component}-${slug}"
  local base_branch
  base_branch=$(git -C "$project_root" branch --show-current 2>/dev/null || echo "main")
  local main_worktree_path
  main_worktree_path=$(cd "$project_root" && pwd)

  # Config must record OBSERVED state, not intended state (ADR-009): verify
  # the ref name, the checkout, and the branch's existence before writing
  # anything, and fail loudly (non-zero) on any of the three.
  if ! git -C "$project_root" check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: create_feature_branch: '$branch_name' is not a valid git branch name" >&2
    return 1
  fi
  if ! git -C "$project_root" checkout -b "$branch_name" 2>/dev/null; then
    echo "ERROR: create_feature_branch: 'git checkout -b $branch_name' failed (invalid ref name or already exists)" >&2
    return 1
  fi
  if ! git -C "$project_root" rev-parse --verify --quiet "$branch_name" >/dev/null; then
    echo "ERROR: create_feature_branch: branch '$branch_name' does not exist after checkout" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  jq \
    --arg feat "$branch_name" \
    --arg base "$base_branch" \
    --arg mwp "$main_worktree_path" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg fid "$feat_id" \
    --arg did "$display_id" \
    --arg prefix "$commit_prefix" \
    '.branch.feature = $feat | .branch.base = $base | .branch.main_worktree_path = $mwp | .branch.created_at = $ts | .feat_id = $fid | .feat_display_id = $did | .afk.commit_prefix = $prefix' \
    "$config" > "$tmp" && mv "$tmp" "$config"

  if declare -F install_git_hooks >/dev/null 2>&1; then
    install_git_hooks "$project_root" "$config" || true
  else
    # The header guard above now makes non-bash sourcing fail loudly before
    # this function is even defined, so the only way install_git_hooks can
    # still be undefined here is a deployment that never shipped
    # scripts/lib/git-hooks.sh. guards.git_hooks=false is NOT this branch —
    # that skip lives inside install_git_hooks itself. Warn by name instead
    # of skipping silently, so the install is verifiable, not best-effort.
    local git_hooks_guard
    git_hooks_guard=$(jq -r '(.guards.git_hooks // true)' "$config" 2>/dev/null || echo "true")
    if [ "$git_hooks_guard" != "false" ]; then
      echo "WARNING: create_feature_branch: install_git_hooks is undefined (scripts/lib/git-hooks.sh was not sourced) — the managed core.hooksPath install did NOT run." >&2
    fi
  fi

  echo "$branch_name"
}

setup_worktree_dir() {
  local project_root="${1:-$(resolve_project_root)}"
  local config="${2:-$CONFIG}"
  local project_name
  project_name=$(basename "$project_root")
  local worktree_dir
  worktree_dir="$(dirname "$project_root")/${project_name}-worktrees"

  mkdir -p "$worktree_dir"

  local tmp
  tmp=$(mktemp)
  jq --arg wd "$worktree_dir" '.branch.worktree_dir = $wd' "$config" > "$tmp" && mv "$tmp" "$config"

  echo "$worktree_dir"
}

create_task_worktree() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local feature_branch
  feature_branch=$(jq -r '.branch.feature // ""' "$config")
  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")

  if [ -z "$feature_branch" ] || [ -z "$worktree_dir" ]; then
    echo "ERROR: feature branch or worktree_dir not configured" >&2
    return 1
  fi

  local task_dir="${worktree_dir}/${task_id}"
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  git -C "$project_root" worktree add "$task_dir" -b "$task_branch" "$feature_branch" 2>/dev/null

  # ADR-008 Option 2: export the MAIN checkout, not $task_dir. nazgul/ is
  # gitignored and per-worktree, so a task worktree never carries its own
  # nazgul/config.json — pointing CLAUDE_PROJECT_DIR at $task_dir would fail
  # resolve_project_root()'s marker validation and could clobber an
  # already-correct value.
  #
  # STATUS: no live caller exercises this. create_task_worktree() has no
  # production caller (real path is the EnterWorktree tool or a raw
  # `git worktree add` — agents/implementer.md:113); the only return channel
  # is `echo "$task_dir"`, so every real caller captures via $(...), and that
  # subshell discards the export before it reaches the caller. Correctly
  # targeted and ready if a future direct (non-subshell) caller is wired up —
  # such a caller would then keep this export for the rest of its own
  # process, including any later unrelated resolve_project_root() calls in
  # that same shell.
  export CLAUDE_PROJECT_DIR="$project_root"

  # Apply sparse checkout if configured
  local sparse_paths
  sparse_paths=$(jq -r '.branch.sparse_paths // empty' "$config" 2>/dev/null || true)
  if [ -n "$sparse_paths" ] && [ "$sparse_paths" != "null" ]; then
    git -C "$task_dir" sparse-checkout init --cone 2>/dev/null || true
    # Read sparse_paths array and set cone patterns
    local paths
    paths=$(jq -r '.branch.sparse_paths[]' "$config" 2>/dev/null || true)
    if [ -n "$paths" ]; then
      echo "$paths" | git -C "$task_dir" sparse-checkout set --stdin 2>/dev/null || true
    fi
  fi

  local tmp
  tmp=$(mktemp)
  jq --arg lb "$task_branch" '.branch.last_task_branch = $lb' "$config" > "$tmp" && mv "$tmp" "$config"

  echo "$task_dir"
}

merge_task_to_feature() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local feature_branch
  feature_branch=$(jq -r '.branch.feature // ""' "$config")
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  git -C "$project_root" checkout "$feature_branch"
  local commit_prefix
  commit_prefix=$(jq -r '.afk.commit_prefix // "feat:"' "$config")
  if ! git -C "$project_root" merge --no-ff -m "${commit_prefix} merge ${task_id}" "$task_branch" 2>/dev/null; then
    git -C "$project_root" merge --abort 2>/dev/null || true
    return 1
  fi
  return 0
}

cleanup_task_worktree() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")
  local task_dir="${worktree_dir}/${task_id}"
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  if [ -d "$task_dir" ]; then
    git -C "$project_root" worktree remove "$task_dir" --force 2>/dev/null || true
  fi
  git -C "$project_root" branch -D "$task_branch" 2>/dev/null || true
}

cleanup_all_worktrees() {
  local project_root="${1:-$(resolve_project_root)}"
  local config="${2:-$CONFIG}"

  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    # Remove all task worktrees
    for task_dir in "$worktree_dir"/TASK-*; do
      [ -d "$task_dir" ] || continue
      local task_id
      task_id=$(basename "$task_dir")
      cleanup_task_worktree "$task_id" "$project_root" "$config"
    done

    # Remove the parent worktree directory if empty
    rmdir "$worktree_dir" 2>/dev/null || true
  fi

  # uninstall_git_hooks unconditionally restores core.hooksPath — only call it
  # when this objective actually installed (prior_hooks_path recorded), so a
  # repo/objective that never installed can't have its hooksPath touched.
  if declare -F uninstall_git_hooks >/dev/null 2>&1 && [ -f "$config" ]; then
    local hooks_installed
    hooks_installed=$(jq -r '(.branch // {}).prior_hooks_path != null' "$config" 2>/dev/null || echo "false")
    if [ "$hooks_installed" = "true" ]; then
      uninstall_git_hooks "$project_root" "$config" || true
    fi
  fi
}
