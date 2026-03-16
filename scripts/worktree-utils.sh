#!/usr/bin/env bash
set -euo pipefail

# Hydra Worktree Utilities — shared helpers for branch/worktree management
# Source this file: source "$(dirname "$0")/worktree-utils.sh"

# Requires: HYDRA_DIR and CONFIG to be set by the caller

slugify_objective() {
  local input="$1"
  echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50
}

create_feature_branch() {
  local objective="$1"
  local project_root="${2:-$(pwd)}"
  local config="${3:-$CONFIG}"
  local slug
  slug=$(slugify_objective "$objective")
  # Compute feat_id from objectives_history length
  local feat_num
  feat_num=$(jq '(.objectives_history // [] | length) + 1' "$config")
  local feat_id="FEAT-$(printf '%03d' "$feat_num")"

  # Check for board issue number
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local display_id
  if [ -n "$board_issue" ] && [ "$board_issue" != "null" ]; then
    display_id="#${board_issue}"
  else
    display_id="$feat_id"
  fi

  local branch_name="feat/${board_issue:-$feat_id}-${slug}"
  local base_branch
  base_branch=$(git -C "$project_root" branch --show-current 2>/dev/null || echo "main")
  local main_worktree_path
  main_worktree_path=$(cd "$project_root" && pwd)

  git -C "$project_root" checkout -b "$branch_name" 2>/dev/null

  local tmp
  tmp=$(mktemp)
  jq \
    --arg feat "$branch_name" \
    --arg base "$base_branch" \
    --arg mwp "$main_worktree_path" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg fid "$feat_id" \
    --arg did "$display_id" \
    --arg prefix "feat(${display_id}):" \
    '.branch.feature = $feat | .branch.base = $base | .branch.main_worktree_path = $mwp | .branch.created_at = $ts | .feat_id = $fid | .feat_display_id = $did | .afk.commit_prefix = $prefix' \
    "$config" > "$tmp" && mv "$tmp" "$config"

  echo "$branch_name"
}

setup_worktree_dir() {
  local project_root="${1:-$(pwd)}"
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
  local project_root="${2:-$(pwd)}"
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
  local project_root="${2:-$(pwd)}"
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
  local project_root="${2:-$(pwd)}"
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
  local project_root="${1:-$(pwd)}"
  local config="${2:-$CONFIG}"

  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")

  if [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; then
    return 0
  fi

  # Remove all task worktrees
  for task_dir in "$worktree_dir"/TASK-*; do
    [ -d "$task_dir" ] || continue
    local task_id
    task_id=$(basename "$task_dir")
    cleanup_task_worktree "$task_id" "$project_root" "$config"
  done

  # Remove the parent worktree directory if empty
  rmdir "$worktree_dir" 2>/dev/null || true
}
