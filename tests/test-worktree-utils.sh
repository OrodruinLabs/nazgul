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

# ---------------------------------------------------------------------------
# Fix 3b — sourcing worktree-utils.sh under zsh must never silently
# half-load: either full bash parity (install_git_hooks defined) or a loud,
# explicit, non-zero FATAL failure — never today's exit 0 with
# install_git_hooks UNDEFINED (TASK-006 / AC9). Mirrors test-shellcheck.sh's
# MF-057 local-SKIP convention: assertions.sh has no SKIPPED status, so an
# unavailable zsh is reported by name, never a silent pass.
_skip() {
  printf "  SKIP: %s\n" "$1"
}
if command -v zsh >/dev/null 2>&1; then
  ZSH_OUT="$TEST_DIR-zsh-out.txt"
  ZSH_ERR="$TEST_DIR-zsh-err.txt"
  mkdir -p "$(dirname "$ZSH_OUT")" 2>/dev/null || true
  # `declare -f` (lowercase, prints the body) not `-F` (names-only): zsh's
  # `declare -F <name>` ignores its argument and always exits 0, so it would
  # report DEFINED even for a genuinely undefined function and mask exactly
  # the regression this probe exists to catch. `declare -f` is accurate in
  # both shells.
  zsh -c "source '$REPO_ROOT/scripts/worktree-utils.sh'; declare -f install_git_hooks >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" \
    >"$ZSH_OUT" 2>"$ZSH_ERR"
  ZSH_RC=$?
  ZSH_STDOUT=$(cat "$ZSH_OUT")
  ZSH_STDERR=$(cat "$ZSH_ERR")
  if [ "$ZSH_RC" -eq 0 ] && [ "$ZSH_STDOUT" = "DEFINED" ]; then
    _pass "zsh sourcing: full bash parity (install_git_hooks defined, exit 0)"
  elif [ "$ZSH_RC" -ne 0 ] && printf '%s' "$ZSH_STDERR" | grep -qF "FATAL: worktree-utils.sh must be sourced from bash"; then
    _pass "zsh sourcing: loud non-zero FATAL failure, not a silent partial load"
  else
    _fail "zsh sourcing: neither full parity nor a loud FATAL failure" \
      "rc=$ZSH_RC stdout=$ZSH_STDOUT stderr=$ZSH_STDERR"
  fi
  rm -f "$ZSH_OUT" "$ZSH_ERR"
else
  _skip "zsh sourcing parity/fatal-failure check (zsh not installed)"
fi

# ---------------------------------------------------------------------------
# Fix 3b — bash parity regression: sourcing under bash must remain fully
# unaffected by the new guard (TASK-006 / AC9).
# ---------------------------------------------------------------------------
BASH_OUT="$TEST_DIR-bash-out.txt"
BASH_ERR="$TEST_DIR-bash-err.txt"
mkdir -p "$(dirname "$BASH_OUT")" 2>/dev/null || true
bash -c "source '$REPO_ROOT/scripts/worktree-utils.sh'; declare -f install_git_hooks >/dev/null 2>&1 && echo IGH_DEFINED || echo IGH_UNDEFINED; declare -f create_feature_branch >/dev/null 2>&1 && echo CFB_DEFINED || echo CFB_UNDEFINED" \
  >"$BASH_OUT" 2>"$BASH_ERR"
BASH_RC=$?
BASH_STDOUT=$(cat "$BASH_OUT")
assert_exit_code "bash sourcing: exits 0" "$BASH_RC" 0
assert_contains "bash sourcing: install_git_hooks defined" "$BASH_STDOUT" "IGH_DEFINED"
assert_contains "bash sourcing: create_feature_branch defined" "$BASH_STDOUT" "CFB_DEFINED"
assert_eq "bash sourcing: no new stderr output" "$(cat "$BASH_ERR")" ""
rm -f "$BASH_OUT" "$BASH_ERR"

# ---------------------------------------------------------------------------
# Fix 3b — when scripts/lib/git-hooks.sh is genuinely absent (not a zsh
# artifact) and guards.git_hooks is not explicitly false, create_feature_branch
# must emit a named warning instead of silently skipping the install
# (TASK-006 / "make the install verifiable, not best-effort"). Simulated by
# pointing CLAUDE_PLUGIN_ROOT at a directory with no scripts/lib/git-hooks.sh,
# so install_git_hooks stays undefined for a reason unrelated to the shell.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
CFG4="$TEST_DIR/nazgul/config.json"
FAKE_PLUGIN_ROOT="$TEST_DIR-fake-plugin-root"
mkdir -p "$FAKE_PLUGIN_ROOT/scripts/lib"

WARN_OUT="$TEST_DIR-warn-out.txt"
WARN_ERR="$TEST_DIR-warn-err.txt"
bash -c "CLAUDE_PLUGIN_ROOT='$FAKE_PLUGIN_ROOT' source '$REPO_ROOT/scripts/worktree-utils.sh'; create_feature_branch 'Warn objective' '$TEST_DIR' '$CFG4'" \
  >"$WARN_OUT" 2>"$WARN_ERR"
assert_contains "create_feature_branch: absent git-hooks.sh emits a named warning (not silence)" \
  "$(cat "$WARN_ERR")" "WARNING: create_feature_branch: install_git_hooks is undefined"
rm -rf "$FAKE_PLUGIN_ROOT" "$WARN_OUT" "$WARN_ERR"
teardown_temp_dir

# ---------------------------------------------------------------------------
# PR #74 review (Copilot): the config write was UNCHECKED. A failed
# `jq … && mv` left the branch created and checked out on disk while
# config.json recorded nothing, and the function still returned SUCCESS —
# config inconsistent with observed state (ADR-009), with nothing emitted.
# The state was also unrecoverable: every retry then died at `checkout -b`
# with "invalid ref name or already exists", so one transient write failure
# bricked branch setup for the objective until a human deleted the branch.
#
# Repro: a VALID config (so every read succeeds and the branch IS created)
# inside a read-only parent dir, so only the `mv` fails. Root-skipped — mode
# bits are not enforced for root.
#
# Asserts BOTH halves: the return code pins the check; no-orphan-branch and
# back-on-base pin the ROLLBACK, which is what separates this fix from a bare
# fail-and-leave-the-branch.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  create_config
  CFG_W="$TEST_DIR/nazgul/config.json"
  BASE_BRANCH_W=$(git -C "$TEST_DIR" branch --show-current)
  WRITE_OBJECTIVE="Write failure objective"
  WRITE_SLUG=$(slugify_objective "$WRITE_OBJECTIVE")
  WRITE_BRANCH="feat/FEAT-001-${WRITE_SLUG}"
  CFG_BEFORE_W=$(cat "$CFG_W")

  chmod 555 "$TEST_DIR/nazgul"
  create_feature_branch "$WRITE_OBJECTIVE" "$TEST_DIR" "$CFG_W" \
    > "$TEST_DIR/wfail-out.txt" 2>"$TEST_DIR/wfail-err.txt"
  RC_WRITE=$?
  chmod 755 "$TEST_DIR/nazgul"

  assert_exit_code "create_feature_branch: failed config write returns non-zero" "$RC_WRITE" 1
  assert_contains "create_feature_branch: failed write names the rollback in its diagnostic" \
    "$(cat "$TEST_DIR/wfail-err.txt")" "rolling back"
  assert_eq "create_feature_branch: failed write leaves NO orphan branch (rollback)" \
    "$(git -C "$TEST_DIR" branch --list "$WRITE_BRANCH" | tr -d ' *')" ""
  assert_eq "create_feature_branch: failed write returns the session to the base branch" \
    "$(git -C "$TEST_DIR" branch --show-current)" "$BASE_BRANCH_W"
  assert_eq "create_feature_branch: failed write leaves config.json byte-identical" \
    "$(cat "$CFG_W")" "$CFG_BEFORE_W"

  teardown_temp_dir
fi

report_results
exit $?
