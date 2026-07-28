#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — this script owns its own error handling so a nonzero
# status reaches the assertion helpers instead of killing the run.
# scripts/worktree-utils.sh declares `set -euo pipefail` and is sourced directly
# into THIS shell below (required to observe its export side effect), which would
# otherwise switch -e back on for everything after the source. `set +e` is
# re-asserted immediately after that source to keep the posture above true.

# Test: scripts/worktree-utils.sh's create_task_worktree() (TASK-008, qa 70 —
# carried forward to this task). No prior test asserted its documented
# CLAUDE_PROJECT_DIR export at all.
TEST_NAME="test-worktree-utils"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config

DEFAULT_BRANCH=$(git -C "$TEST_DIR" branch --show-current)
CFG="$TEST_DIR/nazgul/config.json"
WORKTREE_DIR="${TEST_DIR}-worktrees"
mkdir -p "$WORKTREE_DIR"
jq --arg fb "$DEFAULT_BRANCH" --arg wd "$WORKTREE_DIR" \
  '.branch.feature = $fb | .branch.worktree_dir = $wd' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/worktree-utils.sh"
# worktree-utils.sh's own `set -euo pipefail` just leaked into this shell. Undo
# the -e half so an unexpected nonzero status is reported by the assertion
# helpers rather than silently aborting the run mid-file.
set +e

# --- Direct call: CLAUDE_PROJECT_DIR must be exported to the MAIN checkout,
# not the task worktree path. Capture stdout to a file (not `$(...)`) so the
# function still runs in THIS shell — a command-substitution caller forks a
# subshell that discards the export (TASK-008's own finding); calling it
# directly is the only way to observe the export at all.
unset CLAUDE_PROJECT_DIR
OUT_DIRECT="$TEST_DIR/direct-out.txt"
create_task_worktree TASK-100 "$TEST_DIR" "$CFG" > "$OUT_DIRECT" 2>/dev/null
# `git worktree add`'s own stdout chatter ("Preparing worktree...") lands in
# the same capture ahead of the function's final `echo "$task_dir"` — take
# the last line, exactly as a real $(...) caller would end up relying on.
TASK_DIR_DIRECT=$(tail -n1 "$OUT_DIRECT")

assert_eq "direct call: CLAUDE_PROJECT_DIR exported to the MAIN checkout" "${CLAUDE_PROJECT_DIR:-}" "$TEST_DIR"
if [ "$TASK_DIR_DIRECT" != "$TEST_DIR" ]; then
  _pass "direct call: returned task_dir is the worktree path, not the main checkout"
else
  _fail "direct call: returned task_dir is the worktree path, not the main checkout" "task_dir equaled the main checkout: $TASK_DIR_DIRECT"
fi
assert_dir_exists "direct call: task worktree directory actually created" "$TASK_DIR_DIRECT"

cleanup_task_worktree TASK-100 "$TEST_DIR" "$CFG"
unset CLAUDE_PROJECT_DIR

# --- Command-substitution call: the SAME function, called via $(...), forks
# a subshell — the export happens in that subshell and is discarded when it
# exits. This is the asymmetry TASK-008 itself documented as the reason
# create_task_worktree() has no live production caller today.
TASK_DIR_SUBSHELL=$(create_task_worktree TASK-101 "$TEST_DIR" "$CFG" 2>/dev/null | tail -n1)
assert_eq "subshell call (\$(...)): CLAUDE_PROJECT_DIR is NOT exported to the caller (discarded with the subshell)" "${CLAUDE_PROJECT_DIR:-}" ""
if [ -d "$TASK_DIR_SUBSHELL" ]; then
  _pass "subshell call: the worktree itself was still created (only the export is lost)"
else
  _fail "subshell call: the worktree itself was still created (only the export is lost)" "missing: $TASK_DIR_SUBSHELL"
fi

cleanup_task_worktree TASK-101 "$TEST_DIR" "$CFG"
rm -rf "$WORKTREE_DIR"
teardown_temp_dir

report_results
exit $?
