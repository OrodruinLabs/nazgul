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

# create_feature_branch's stacking-off hazard assertion (TASK-006) expects
# the checked-out branch to equal config's branch.base, which defaults to
# "main" when unset (matching this repo's own convention — CLAUDE.md: "the
# default branch is always main, never master"). setup_git_repo()'s plain
# `git init` inherits whatever init.defaultBranch this HOST happens to have
# configured (often "master") — normalize every fixture repo to "main" right
# after init so the regression tests below exercise ordinary success, not
# the host's local git config.
_norm_main() {
  git -C "$TEST_DIR" branch -M main 2>/dev/null || true
}

setup_temp_dir
setup_git_repo
_norm_main
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
_norm_main
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
_norm_main
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
_norm_main
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
  _norm_main
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

# ---------------------------------------------------------------------------
# TASK-006 (FEAT-027, ADR-018) — accidental-stacking hazard fix, stacking
# OFF: the checked-out branch must equal config's branch.base (default
# "main"). On mismatch, refuse loudly naming the stray branch and the
# expected base; nonzero; NO branch created; config untouched.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
_norm_main
setup_nazgul_dir
create_config
CFG_STRAY="$TEST_DIR/nazgul/config.json"
CFG_STRAY_BEFORE=$(cat "$CFG_STRAY")

STRAY_BRANCH="some-other-feature"
git -C "$TEST_DIR" checkout -q -b "$STRAY_BRANCH"

STRAY_OBJECTIVE="Stray checkout objective"
STRAY_SLUG=$(slugify_objective "$STRAY_OBJECTIVE")
STRAY_TARGET_BRANCH="feat/FEAT-001-${STRAY_SLUG}"

create_feature_branch "$STRAY_OBJECTIVE" "$TEST_DIR" "$CFG_STRAY" \
  > "$TEST_DIR/stray-out.txt" 2>"$TEST_DIR/stray-err.txt"
RC_STRAY=$?
STRAY_ERR=$(cat "$TEST_DIR/stray-err.txt")

assert_exit_code "create_feature_branch: stacking off + stray checkout returns non-zero" "$RC_STRAY" 1
assert_contains "create_feature_branch: stray-checkout refusal names the stray branch" "$STRAY_ERR" "$STRAY_BRANCH"
assert_contains "create_feature_branch: stray-checkout refusal names the expected base" "$STRAY_ERR" "main"
assert_eq "create_feature_branch: stray-checkout refusal leaves no target branch created" \
  "$(git -C "$TEST_DIR" branch --list "$STRAY_TARGET_BRANCH" | tr -d ' *')" ""
assert_eq "create_feature_branch: stray-checkout refusal leaves config untouched" \
  "$(cat "$CFG_STRAY")" "$CFG_STRAY_BEFORE"
assert_eq "create_feature_branch: stray-checkout refusal leaves the session where it was (nothing moved)" \
  "$(git -C "$TEST_DIR" branch --show-current)" "$STRAY_BRANCH"
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-006 — stacking-aware tests share one minimal `gh` PATH-shim mock
# (extension list + auth status only — create_feature_branch never calls
# `gh stack`/`gh pr` itself, only stack_available/stack_tip/
# stack_register_layer). No network. Mirrors tests/test-stack-utils.sh.
# ---------------------------------------------------------------------------
WU_BASE_PATH="$PATH"
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-wu-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'GH_EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    action="${1:-}"; shift || true
    case "$action" in
      list)
        if [ "${NAZGUL_TEST_GH_STACK_EXT:-1}" != "0" ]; then
          printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'
        fi
        exit 0 ;;
      *) exit 1 ;;
    esac ;;
  auth)
    action="${1:-}"; shift || true
    case "$action" in
      status) [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
GH_EOF
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  export PATH="$WU_BASE_PATH"; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

# ---------------------------------------------------------------------------
# TASK-006 — stacking ON and ready: base := stack_tip (explicit ref, never
# whatever is checked out), stack_register_layer entry appended at creation.
# The tip carries a commit main doesn't have and we deliberately check out
# main (not the tip) before calling create_feature_branch, so "created from
# the tip" is provable rather than incidental.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
_norm_main
setup_nazgul_dir
create_config
CFG_READY="$TEST_DIR/nazgul/config.json"
jq '.execution.stacking.enabled = true' "$CFG_READY" > "$CFG_READY.tmp" && mv "$CFG_READY.tmp" "$CFG_READY"

TIP_BRANCH="feat/FEAT-100-tip-layer"
git -C "$TEST_DIR" checkout -q -b "$TIP_BRANCH"
echo "tip work" > "$TEST_DIR/tip.txt"
git -C "$TEST_DIR" add tip.txt
git -C "$TEST_DIR" commit -q -m "tip commit"
TIP_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
git -C "$TEST_DIR" checkout -q main

jq --arg br "$TIP_BRANCH" \
  '.stack.layers = [{feat_id:"FEAT-100", branch:$br, pr:null, base:"main", state:"open", opened_at:"2026-08-01T00:00:00Z", merged_at:null}]' \
  "$CFG_READY" > "$CFG_READY.tmp" && mv "$CFG_READY.tmp" "$CFG_READY"

create_feature_branch "Second layer objective" "$TEST_DIR" "$CFG_READY" \
  > "$TEST_DIR/ready-out.txt" 2>"$TEST_DIR/ready-err.txt"
RC_READY=$?
READY_BRANCH=$(tail -n1 "$TEST_DIR/ready-out.txt")

assert_exit_code "create_feature_branch: stacking on + ready returns 0" "$RC_READY" 0
assert_eq "create_feature_branch: new branch HEAD equals the tip's HEAD (created from the explicit tip ref)" \
  "$(git -C "$TEST_DIR" rev-parse "$READY_BRANCH" 2>/dev/null)" "$TIP_SHA"
assert_eq "create_feature_branch: config .branch.base records the tip" \
  "$(jq -r '.branch.base' "$CFG_READY")" "$TIP_BRANCH"
assert_eq "create_feature_branch: registry now has 2 layers (tip + new)" \
  "$(jq '.stack.layers | length' "$CFG_READY")" "2"
NEW_FEAT_ID=$(jq -r '.feat_id' "$CFG_READY")
assert_eq "create_feature_branch: new registry entry's branch is the returned branch" \
  "$(jq -r --arg f "$NEW_FEAT_ID" '.stack.layers[] | select(.feat_id == $f) | .branch' "$CFG_READY")" "$READY_BRANCH"
assert_eq "create_feature_branch: new registry entry's base is the tip branch" \
  "$(jq -r --arg f "$NEW_FEAT_ID" '.stack.layers[] | select(.feat_id == $f) | .base' "$CFG_READY")" "$TIP_BRANCH"
assert_eq "create_feature_branch: new registry entry's state is open" \
  "$(jq -r --arg f "$NEW_FEAT_ID" '.stack.layers[] | select(.feat_id == $f) | .state' "$CFG_READY")" "open"
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-006 — stacking ON but tooling missing: stack_available reports
# "missing" and create_feature_branch falls back to the SAME non-stacking
# assertion as stacking-off (ADR-018 locked decision 4: fail closed to
# today's single-branch contract), plus a loud stop_gate degradation event —
# never a silent downgrade. Realistic trigger: mid-continuation, the current
# checkout is the PRIOR (unmerged) layer, not branch.base, so the fallback
# assertion legitimately refuses.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
_norm_main
setup_nazgul_dir
create_config
CFG_MISSING="$TEST_DIR/nazgul/config.json"
jq '.execution.stacking.enabled = true' "$CFG_MISSING" > "$CFG_MISSING.tmp" && mv "$CFG_MISSING.tmp" "$CFG_MISSING"

MISSING_STRAY_BRANCH="leftover-layer-branch"
git -C "$TEST_DIR" checkout -q -b "$MISSING_STRAY_BRANCH"

# worktree-utils.sh (and the emit-event.sh it transitively sources) was
# already sourced once at the top of this file, before any NAZGUL_DIR
# existed — emit_event's EVENTS_FILE default is a module-level var computed
# only at that first source, so it stays frozen. Point it at THIS fixture's
# events log directly rather than relying on NAZGUL_DIR being re-read.
NAZGUL_DIR="$TEST_DIR/nazgul"
EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"

export NAZGUL_TEST_GH_STACK_EXT=0
create_feature_branch "Missing tooling objective" "$TEST_DIR" "$CFG_MISSING" \
  > "$TEST_DIR/missing-out.txt" 2>"$TEST_DIR/missing-err.txt"
RC_MISSING=$?
unset NAZGUL_TEST_GH_STACK_EXT

assert_exit_code "create_feature_branch: stacking on + tooling missing returns non-zero" "$RC_MISSING" 1
assert_contains "create_feature_branch: missing-tooling refusal names the stray branch" \
  "$(cat "$TEST_DIR/missing-err.txt")" "$MISSING_STRAY_BRANCH"
if [ -f "$EVENTS_FILE" ]; then
  assert_contains "create_feature_branch: missing tooling emits a loud stacking_unavailable degradation event" \
    "$(cat "$EVENTS_FILE")" "stacking_unavailable"
else
  _fail "create_feature_branch: missing tooling emits a loud stacking_unavailable degradation event" "events.jsonl was never created"
fi
unset NAZGUL_DIR EVENTS_FILE
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-006 — rollback-unwind contract: if stack_register_layer fails AFTER
# the branch/base config write already committed, create_feature_branch
# must roll back BOTH the branch and the config write, not leave config
# pointing at a branch (and a base/registry) that no longer agree. Forces
# the failure with a test-double `stack_register_layer` that shadows the
# real one, defined in a throwaway subshell so the override never leaks
# into the rest of this file.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
_norm_main
setup_nazgul_dir
create_config
CFG_ROLLBACK="$TEST_DIR/nazgul/config.json"
jq '.execution.stacking.enabled = true' "$CFG_ROLLBACK" > "$CFG_ROLLBACK.tmp" && mv "$CFG_ROLLBACK.tmp" "$CFG_ROLLBACK"

RB_TIP_BRANCH="feat/FEAT-200-rb-tip"
git -C "$TEST_DIR" checkout -q -b "$RB_TIP_BRANCH"

jq --arg br "$RB_TIP_BRANCH" \
  '.stack.layers = [{feat_id:"FEAT-200", branch:$br, pr:null, base:"main", state:"open", opened_at:"2026-08-01T00:00:00Z", merged_at:null}]' \
  "$CFG_ROLLBACK" > "$CFG_ROLLBACK.tmp" && mv "$CFG_ROLLBACK.tmp" "$CFG_ROLLBACK"
CFG_ROLLBACK_BEFORE=$(cat "$CFG_ROLLBACK")

ROLLBACK_OBJECTIVE="Rollback unwind objective"
ROLLBACK_SLUG=$(slugify_objective "$ROLLBACK_OBJECTIVE")
ROLLBACK_TARGET_BRANCH="feat/FEAT-001-${ROLLBACK_SLUG}"

bash -c "
  source '$REPO_ROOT/scripts/worktree-utils.sh'
  stack_register_layer() { echo 'FAKE stack_register_layer: forced failure for rollback test' >&2; return 1; }
  create_feature_branch '$ROLLBACK_OBJECTIVE' '$TEST_DIR' '$CFG_ROLLBACK'
" > "$TEST_DIR/rollback-out.txt" 2>"$TEST_DIR/rollback-err.txt"
RC_ROLLBACK=$?

assert_exit_code "create_feature_branch: stack_register_layer failure after config commit returns non-zero" "$RC_ROLLBACK" 1
assert_contains "create_feature_branch: rollback-unwind diagnostic names the rollback" \
  "$(cat "$TEST_DIR/rollback-err.txt")" "rolling back"
assert_eq "create_feature_branch: rollback-unwind leaves NO orphan branch" \
  "$(git -C "$TEST_DIR" branch --list "$ROLLBACK_TARGET_BRANCH" | tr -d ' *')" ""
assert_eq "create_feature_branch: rollback-unwind returns the session to the tip base" \
  "$(git -C "$TEST_DIR" branch --show-current)" "$RB_TIP_BRANCH"
assert_eq "create_feature_branch: rollback-unwind restores config byte-identical (branch/base fields AND registry both reverted)" \
  "$(cat "$CFG_ROLLBACK")" "$CFG_ROLLBACK_BEFORE"

teardown_temp_dir
export PATH="$WU_BASE_PATH"
rm -rf "$FAKEBIN"

report_results
exit $?
