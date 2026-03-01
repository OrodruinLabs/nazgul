#!/usr/bin/env bash
# Hydra Test Setup Library
# Sourced by script integration tests. Provides temp dir, git repo, and hydra state helpers.

# Resolve the repo root (where hydra/ lives) relative to this script
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_temp_dir() {
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hydra-test-XXXXXX")
  export TEST_DIR
  export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown_temp_dir() {
  if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
    rm -rf "$TEST_DIR"
  fi
}

setup_git_repo() {
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "test@hydra.dev"
  git -C "$TEST_DIR" config user.name "Hydra Test"
  touch "$TEST_DIR/.gitkeep"
  git -C "$TEST_DIR" add .gitkeep
  git -C "$TEST_DIR" commit -q -m "initial commit"
  # Second commit so HEAD~1 works (needed by pre-compact.sh and stop-hook.sh)
  echo "# test" > "$TEST_DIR/README.md"
  git -C "$TEST_DIR" add README.md
  git -C "$TEST_DIR" commit -q -m "add readme"
}

setup_hydra_dir() {
  mkdir -p "$TEST_DIR/hydra/tasks"
  mkdir -p "$TEST_DIR/hydra/checkpoints"
  mkdir -p "$TEST_DIR/hydra/logs"
  mkdir -p "$TEST_DIR/hydra/reviews"
  mkdir -p "$TEST_DIR/hydra/context"
  mkdir -p "$TEST_DIR/hydra/docs"
}

create_config() {
  # Creates a config.json from the template, then applies optional jq overrides
  # Usage: create_config '.mode = "yolo"' '.current_iteration = 5'
  cp "$REPO_ROOT/templates/config.json" "$TEST_DIR/hydra/config.json"
  for override in "$@"; do
    jq "$override" "$TEST_DIR/hydra/config.json" > "$TEST_DIR/hydra/config.json.tmp" \
      && mv "$TEST_DIR/hydra/config.json.tmp" "$TEST_DIR/hydra/config.json"
  done
}

create_task_file() {
  # Usage: create_task_file TASK-001 READY [depends] [blocked_reason]
  local id="$1"
  local status="$2"
  local deps="${3:-none}"
  local blocked_reason="${4:-}"

  cat > "$TEST_DIR/hydra/tasks/${id}.md" << TASK_EOF
# ${id}: Test task

- **Status**: ${status}
- **Depends on**: ${deps}
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer
TASK_EOF

  if [ -n "$blocked_reason" ]; then
    echo "- **Blocked reason**: ${blocked_reason}" >> "$TEST_DIR/hydra/tasks/${id}.md"
  fi
}

create_review_dir() {
  # Creates a mock review directory with an APPROVED reviewer file
  # Usage: create_review_dir TASK-001
  local id="$1"
  mkdir -p "$TEST_DIR/hydra/reviews/${id}"
  cat > "$TEST_DIR/hydra/reviews/${id}/code-reviewer.md" << REVIEW_EOF
# Code Review: ${id}

## Verdict: APPROVED

No blocking issues found.
REVIEW_EOF
}

create_plan() {
  # Creates a plan.md with Recovery Pointer in the format stop-hook.sh expects
  cat > "$TEST_DIR/hydra/plan.md" << 'PLAN_EOF'
# Hydra Plan

## Objective
Test objective

## Status Summary
- Total tasks: 0
- DONE: 0 | READY: 0 | IN_PROGRESS: 0

## Recovery Pointer
- **Current Task:** none
- **Last Action:** Plan created, no tasks started
- **Next Action:** Run discovery, then begin task execution
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
}
