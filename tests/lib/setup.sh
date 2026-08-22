#!/usr/bin/env bash
# Nazgul Test Setup Library
# Sourced by script integration tests. Provides temp dir, git repo, and nazgul state helpers.

# Resolve the repo root (where nazgul/ lives) relative to this script
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_temp_dir() {
  # The template carries NO colon. PATH is colon-separated, so a ":" anywhere in TEST_DIR
  # silently splits every `PATH="$TEST_DIR/fakebin:$PATH"` prepend into two nonexistent
  # entries — the stub is never found and the test exercises the REAL binary while
  # reporting a stub-driven pass. Two tests had already worked around this locally
  # (test-git-hooks-premerge.sh, test-heartbeat-start-injection.sh); this fixes the source.
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-test-XXXXXX")
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
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  touch "$TEST_DIR/.gitkeep"
  git -C "$TEST_DIR" add .gitkeep
  git -C "$TEST_DIR" commit -q -m "initial commit"
  # Second commit so HEAD~1 works (needed by pre-compact.sh and stop-hook.sh)
  echo "# test" > "$TEST_DIR/README.md"
  git -C "$TEST_DIR" add README.md
  git -C "$TEST_DIR" commit -q -m "add readme"
}

setup_nazgul_dir() {
  mkdir -p "$TEST_DIR/nazgul/tasks"
  mkdir -p "$TEST_DIR/nazgul/checkpoints"
  mkdir -p "$TEST_DIR/nazgul/logs"
  mkdir -p "$TEST_DIR/nazgul/reviews"
  mkdir -p "$TEST_DIR/nazgul/context"
  mkdir -p "$TEST_DIR/nazgul/docs"
}

create_config() {
  # Creates a config.json from the template, then applies optional jq overrides
  # Usage: create_config '.mode = "yolo"' '.current_iteration = 5'
  #
  # Pins review_gate.granularity to "task" BEFORE any caller override is
  # applied (MF-013/TASK-001). templates/config.json's shipped default has
  # been "group" since v17, but almost every fixture across this suite plants
  # review evidence at the task-id-keyed path (reviews/<task_id>/...) with no
  # explicit granularity opinion — that was harmless only because the
  # evidence gates used to ignore granularity entirely (the MF-013 bug).
  # Now that resolve_review_unit() makes them honor it for real, an implicit
  # "group" default would silently break every such fixture. Defaulting here
  # (not by editing the template) restores the suite's long-standing implicit
  # behavior; any test that explicitly wants group/feature semantics still
  # gets it, since its own override runs after this one and wins.
  cp "$REPO_ROOT/templates/config.json" "$TEST_DIR/nazgul/config.json"
  jq '.review_gate.granularity = "task"' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
    && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
  for override in "$@"; do
    jq "$override" "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
      && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
  done
}

create_task_file() {
  # Usage: create_task_file TASK-001 READY [depends] [blocked_reason]
  # Emits canonical YAML frontmatter (---\nstatus: X\n---) as the manifest's status
  # source of truth, matching agents/planner.md:86 and every real nazgul/tasks/*.md
  # in this repo. get_task_status() (scripts/lib/task-utils.sh) prefers frontmatter
  # transparently, so callers get realistic coverage with no per-site changes.
  local id="$1"
  local status="$2"
  local deps="${3:-none}"
  local blocked_reason="${4:-}"

  cat > "$TEST_DIR/nazgul/tasks/${id}.md" << TASK_EOF
---
status: ${status}
---
# ${id}: Test task

- **Depends on**: ${deps}
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer
TASK_EOF

  if [ -n "$blocked_reason" ]; then
    echo "- **Blocked reason**: ${blocked_reason}" >> "$TEST_DIR/nazgul/tasks/${id}.md"
  fi
}

create_task_file_legacy() {
  # Usage: create_task_file_legacy TASK-001 READY [depends] [blocked_reason]
  # Preserves the pre-MF-052 legacy list-item body (`- **Status**: X`, no
  # frontmatter) verbatim, for the specific tests that exist to prove
  # get_task_status()'s list-item fallback parsing still works.
  local id="$1"
  local status="$2"
  local deps="${3:-none}"
  local blocked_reason="${4:-}"

  cat > "$TEST_DIR/nazgul/tasks/${id}.md" << TASK_EOF
# ${id}: Test task

- **Status**: ${status}
- **Depends on**: ${deps}
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer
TASK_EOF

  if [ -n "$blocked_reason" ]; then
    echo "- **Blocked reason**: ${blocked_reason}" >> "$TEST_DIR/nazgul/tasks/${id}.md"
  fi
}

create_task_file_with_files_modified() {
  # Usage: create_task_file_with_files_modified TASK-001 IN_PROGRESS '["scripts/foo.sh","tests/test-foo.sh"]'
  # Canonical frontmatter manifest with a real planner-shaped `Files modified`
  # value (FEAT-014 fixture-realism precedent), for MF-025 accessor consumers.
  local id="$1"
  local status="$2"
  local files_modified="$3"

  cat > "$TEST_DIR/nazgul/tasks/${id}.md" << TASK_EOF
---
status: ${status}
---
# ${id}: Test task

- **Files modified**: ${files_modified}
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer
TASK_EOF
}

create_task_file_with_commits() {
  # Usage: create_task_file_with_commits TASK-001 IN_PROGRESS "abc1234"
  local id="$1"
  local status="$2"
  local commits="${3:-}"

  cat > "$TEST_DIR/nazgul/tasks/${id}.md" << TASK_EOF
# ${id}: Test task

- **Status**: ${status}
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer

## Commits
- ${commits}
TASK_EOF
}

set_task_group() {
  # Override a task manifest's - **Group**: field (for review-granularity tests).
  # Usage: set_task_group TASK-001 2
  local id="$1" group="$2"
  sed -i.bak "s/^- \*\*Group\*\*:.*/- **Group**: ${group}/" "$TEST_DIR/nazgul/tasks/${id}.md" \
    && rm -f "$TEST_DIR/nazgul/tasks/${id}.md.bak"
}

create_review_dir() {
  # Creates a mock review directory with an APPROVED reviewer file
  # Usage: create_review_dir TASK-001
  local id="$1"
  mkdir -p "$TEST_DIR/nazgul/reviews/${id}"
  cat > "$TEST_DIR/nazgul/reviews/${id}/code-reviewer.md" << REVIEW_EOF
# Code Review: ${id}

## Verdict: APPROVED

No blocking issues found.
REVIEW_EOF
}

create_plan() {
  # Creates a plan.md with Recovery Pointer in the format stop-hook.sh expects
  cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

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

setup_two_worktree_repo() {
  # Builds the FEAT-021 live-incident shape with real git: a repo at
  # $TEST_DIR/main with its own nazgul/ (feat_id FEAT-005, TASK-007 DONE —
  # the main checkout's unrelated objective), plus a real `git worktree add`
  # checkout nested at .claude/worktrees/feat-x with its OWN nazgul/ (same
  # feat_id — both trees independently computed objectives_history.length+1
  # — TASK-007 IN_PROGRESS, this worktree's own active task).
  #
  # Reuses setup_git_repo/setup_nazgul_dir/create_config/create_task_file by
  # temporarily repointing the shared $TEST_DIR global to each tree in turn,
  # then restores it — sets TWO_WT_MAIN / TWO_WT_WORKTREE for the caller.
  local outer="$TEST_DIR"
  TWO_WT_MAIN="$outer/main"
  TWO_WT_WORKTREE="$TWO_WT_MAIN/.claude/worktrees/feat-x"

  mkdir -p "$TWO_WT_MAIN"
  TEST_DIR="$TWO_WT_MAIN"
  setup_git_repo
  setup_nazgul_dir
  create_config '.feat_id = "FEAT-005"' '.execution.parallel = true'
  create_task_file TASK-007 DONE

  git -C "$TWO_WT_MAIN" worktree add -q "$TWO_WT_WORKTREE" -b feat-x

  TEST_DIR="$TWO_WT_WORKTREE"
  setup_nazgul_dir
  create_config '.feat_id = "FEAT-005"' '.execution.parallel = true'
  create_task_file TASK-007 IN_PROGRESS

  TEST_DIR="$outer"
}

teardown_two_worktree_repo() {
  # Explicit `git worktree remove` + `prune` BEFORE teardown_temp_dir's
  # `rm -rf` — required so the fixture repo's own .git/worktrees/ metadata
  # never dangles, per this task's test requirements.
  if [ -n "${TWO_WT_MAIN:-}" ] && [ -d "$TWO_WT_MAIN" ]; then
    git -C "$TWO_WT_MAIN" worktree remove --force "$TWO_WT_WORKTREE" 2>/dev/null || true
    git -C "$TWO_WT_MAIN" worktree prune 2>/dev/null || true
  fi
  unset TWO_WT_MAIN TWO_WT_WORKTREE
}
