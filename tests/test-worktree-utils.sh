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

# ---------------------------------------------------------------------------
# Fix 3a — slugify_objective() must collapse ALL whitespace (including
# newlines) before slugifying, so a multi-paragraph objective yields one
# clean line, not a slug with embedded newlines (TASK-003 / AC7).
# ---------------------------------------------------------------------------
MULTI_PARA_OBJECTIVE="$(printf 'Line one here\n\nSecond paragraph goes on for a good while so truncation also gets exercised')"
SLUG=$(slugify_objective "$MULTI_PARA_OBJECTIVE")
SLUG_NO_NEWLINES=$(printf '%s' "$SLUG" | tr -d '\n')
assert_eq "slugify_objective: multi-paragraph input produces a single-line slug" "$SLUG" "$SLUG_NO_NEWLINES"
if [ "${#SLUG}" -le 50 ]; then
  _pass "slugify_objective: result is <= 50 chars"
else
  _fail "slugify_objective: result is <= 50 chars" "length: ${#SLUG}"
fi
git check-ref-format --branch "feat/FEAT-999-${SLUG}" >/dev/null 2>&1
assert_exit_code "slugify_objective: feat/<id>-<slug> passes git check-ref-format --branch" "$?" 0

EMPTY_SLUG=$(slugify_objective "***---***")
if [ -n "$EMPTY_SLUG" ]; then
  _pass "slugify_objective: degenerate all-punctuation input falls back to a non-empty slug"
else
  _fail "slugify_objective: degenerate all-punctuation input falls back to a non-empty slug" "got empty string"
fi

# ---------------------------------------------------------------------------
# Fix 3a — create_feature_branch() end to end with a multi-paragraph
# objective: the branch it reports must actually exist, and config must
# only be written after the branch is verified (TASK-003 / AC7, AC8).
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
CFG2="$TEST_DIR/nazgul/config.json"

OUT_BRANCH="$TEST_DIR/branch-out.txt"
create_feature_branch "$MULTI_PARA_OBJECTIVE" "$TEST_DIR" "$CFG2" > "$OUT_BRANCH" 2>"$TEST_DIR/branch-err.txt"
RC=$?
BRANCH_NAME=$(tail -n1 "$OUT_BRANCH")
assert_exit_code "create_feature_branch: multi-paragraph objective returns 0" "$RC" 0
git check-ref-format --branch "$BRANCH_NAME" >/dev/null 2>&1
assert_exit_code "create_feature_branch: returned branch name is a valid ref" "$?" 0
git -C "$TEST_DIR" rev-parse --verify --quiet "$BRANCH_NAME" >/dev/null 2>&1
assert_exit_code "create_feature_branch: returned branch actually exists" "$?" 0
CONFIG_FEATURE=$(jq -r '.branch.feature' "$CFG2")
assert_eq "create_feature_branch: .branch.feature equals the returned branch name" "$CONFIG_FEATURE" "$BRANCH_NAME"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Fix 3a — checkout failure must return non-zero AND leave
# .branch.feature untouched (config records OBSERVED state, not intended
# state) (TASK-003 / AC8).
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
CFG3="$TEST_DIR/nazgul/config.json"
DEFAULT_BRANCH3=$(git -C "$TEST_DIR" branch --show-current)

COLLIDE_OBJECTIVE="Collision objective"
COLLIDE_SLUG=$(slugify_objective "$COLLIDE_OBJECTIVE")
COLLIDE_BRANCH="feat/FEAT-001-${COLLIDE_SLUG}"
git -C "$TEST_DIR" branch "$COLLIDE_BRANCH"
jq --arg fb "sentinel-unchanged" '.branch.feature = $fb' "$CFG3" > "$CFG3.tmp" && mv "$CFG3.tmp" "$CFG3"

create_feature_branch "$COLLIDE_OBJECTIVE" "$TEST_DIR" "$CFG3" > "$TEST_DIR/collide-out.txt" 2>"$TEST_DIR/collide-err.txt"
RC_COLLIDE=$?
assert_exit_code "create_feature_branch: checkout failure (branch already exists) returns non-zero" "$RC_COLLIDE" 1
CONFIG_FEATURE_AFTER=$(jq -r '.branch.feature' "$CFG3")
assert_eq "create_feature_branch: checkout failure leaves .branch.feature unchanged" "$CONFIG_FEATURE_AFTER" "sentinel-unchanged"
CURRENT_BRANCH_AFTER=$(git -C "$TEST_DIR" branch --show-current)
assert_eq "create_feature_branch: checkout failure leaves the session on the base branch" "$CURRENT_BRANCH_AFTER" "$DEFAULT_BRANCH3"
teardown_temp_dir

report_results
exit $?
