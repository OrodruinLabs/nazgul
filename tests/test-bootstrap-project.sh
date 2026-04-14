#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-project"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Build a reusable function that simulates the skill's orchestration bash
# (everything except the Agent tool invocations, which we replace with
# pre-populated fake scratch trees).
simulate_bootstrap() {
  local project="$1"
  local scratch="$project/.bootstrap-scratch"

  # Pre-flight (in-process)
  (cd "$project" && source "$REPO_ROOT/scripts/lib/bootstrap-preflight.sh" && \
    check_no_nazgul_dir && check_scratch_state && check_docs_agents_empty && check_git_clean) || return $?

  # Stubbed pipeline — write canonical outputs to scratch
  mkdir -p "$scratch/docs" "$scratch/context" "$scratch/agents" "$scratch/.claude"
  cat > "$scratch/docs/PRD.md" <<'PRD'
# PRD
See nazgul/context/project-profile.md for stack info.
PRD
  cat > "$scratch/docs/TRD.md" <<'TRD'
# TRD
Architecture docs.
TRD
  cat > "$scratch/docs/test-plan.md" <<'TP'
# Test Plan
TP
  cat > "$scratch/docs/manifest.md" <<'MAN'
# Manifest
MAN
  cat > "$scratch/context/project-profile.md" <<'PROF'
# Profile
Stack: Python.
PROF
  cat > "$scratch/agents/code-reviewer.md" <<'AG'
---
name: code-reviewer
description: "Pipeline: reviewer"
tools:
  - Read
allowed-tools: Read
maxTurns: 30
nazgul:
  phase: review
---

# Code Reviewer
Review the code.
AG

  # Transform
  bash "$REPO_ROOT/scripts/bootstrap-transform.sh" "$scratch" || return $?

  # Relocate
  source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"
  (cd "$project" && relocate_bundle "$scratch" "$project") || return $?
  (cd "$project" && append_gitignore "$project")
  (cd "$project" && cleanup_scratch "$scratch")
}

# --- Happy path ---
setup_temp_dir
setup_git_repo

simulate_bootstrap "$TEST_DIR"
happy_ec=$?
assert_exit_code "happy path exit 0" "$happy_ec" 0

assert_file_exists "PRD landed"     "$TEST_DIR/docs/PRD.md"
assert_file_exists "TRD landed"     "$TEST_DIR/docs/TRD.md"
assert_file_exists "test-plan"      "$TEST_DIR/docs/test-plan.md"
assert_file_exists "profile landed" "$TEST_DIR/docs/context/project-profile.md"
assert_file_exists "reviewer"       "$TEST_DIR/.claude/agents/code-reviewer.md"

assert_file_not_exists "manifest dropped"           "$TEST_DIR/docs/manifest.md"
assert_file_not_exists "scratch cleaned up"         "$TEST_DIR/.bootstrap-scratch"
assert_file_not_contains "PRD has no nazgul/ path"   "$TEST_DIR/docs/PRD.md" "nazgul/"
assert_file_not_contains "reviewer has no nazgul fm" "$TEST_DIR/.claude/agents/code-reviewer.md" "nazgul:"
assert_file_contains "gitignore appended"           "$TEST_DIR/.gitignore" ".bootstrap-scratch/"

teardown_temp_dir

# --- Pre-flight: aborts if ./nazgul/ exists ---
setup_temp_dir
setup_git_repo
mkdir -p "$TEST_DIR/nazgul"
set +e
simulate_bootstrap "$TEST_DIR" >/dev/null 2>&1
ec=$?
set -e
assert_exit_code "aborts on ./nazgul/" "$ec" 10
assert_file_not_exists "docs NOT created" "$TEST_DIR/docs/PRD.md"
teardown_temp_dir

# --- Atomicity: simulated mid-relocation failure leaves docs untouched ---
setup_temp_dir
setup_git_repo

# Make ./.claude/agents a regular file so mkdir -p fails during relocate
# (this triggers the dry-run check in relocate_bundle)
mkdir -p "$TEST_DIR/.claude"
touch "$TEST_DIR/.claude/agents"

# Pre-populate scratch (bypass pre-flight since we're testing mid-run)
SCRATCH="$TEST_DIR/.bootstrap-scratch"
mkdir -p "$SCRATCH/docs" "$SCRATCH/agents"
echo "PRD" > "$SCRATCH/docs/PRD.md"
echo "reviewer" > "$SCRATCH/agents/r.md"

source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"
set +e
(cd "$TEST_DIR" && relocate_bundle "$SCRATCH" "$TEST_DIR" >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "relocate aborts pre-first-write" "$ec" 20
assert_file_not_exists "docs/PRD NOT created" "$TEST_DIR/docs/PRD.md"
teardown_temp_dir

report_results
