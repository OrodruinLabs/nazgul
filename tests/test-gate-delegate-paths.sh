#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly
# ADR-021 Decision 1: each post-loop gate must hand the agent its resolved absolute
# marker plus <main_worktree_path>, never a bare relative nazgul/... write target.

TEST_NAME="test-gate-delegate-paths"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# Slice one gate's message out of the combined output, banner through opt-out line,
# so an assertion can never be satisfied by text another gate emitted.
gate_message() {
  printf '%s\n' "$HOOK_OUTPUT" | awk -v banner="$1" '
    index($0, banner) { inblk = 1 }
    inblk { print }
    inblk && index($0, "Opt out for future objectives") { exit }
  '
}

# A message never emitted trivially satisfies every "must not contain" assertion
# below, so prove the gate actually fired before asserting on its text.
assert_gate_driven() {
  local name="$1" msg="$2"
  if [ -z "$msg" ]; then
    _fail "$name" "gate emitted no message — the fixture did not drive this gate" \
      "  hook output: '${HOOK_OUTPUT:0:300}'"
  elif ! grep -qF -e "DELEGATE:" <<<"$msg"; then
    _fail "$name" "message found but carries no DELEGATE instruction" "  message: '${msg:0:300}'"
  else
    _pass "$name"
  fi
}

_ere_escape() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\\/]/\\&/g'
}

# Fails when the relative form appears anywhere it is NOT the tail of an absolute
# path (not preceded by "/") — which is exactly the bare relative instruction.
assert_no_relative_path() {
  local name="$1" msg="$2" rel="$3" rc=0
  local pattern="(^|[^/])$(_ere_escape "$rel")"
  grep -Eq -e "$pattern" <<<"$msg" || rc=$?
  case "$rc" in
    0) _fail "$name" "bare relative path still instructed: '$rel'" "  message: '${msg:0:300}'" ;;
    1) _pass "$name" ;;
    *) _assert_unevaluable "$name" "$rc" "$pattern" ;;
  esac
}

# One DONE task with review evidence makes the loop complete — the only state in
# which the post-loop gates run at all.
complete_objective_fixture() {
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  create_config "$@"
  create_plan
  create_task_file "TASK-001" "DONE"
  create_review_dir "TASK-001"
}

# --- GDP-1: learner gate instructs with absolute marker + proposed-rules path ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP1"'
run_hook
LEARN_MSG=$(gate_message "POST-LOOP LEARNING GATE")
assert_exit_code "GDP-1: learner gate blocks" "$HOOK_EC" 2
assert_gate_driven "GDP-1: learner gate emitted a DELEGATE message" "$LEARN_MSG"
assert_contains "GDP-1: names <main_worktree_path>" "$LEARN_MSG" "<main_worktree_path> = $TEST_DIR"
assert_contains "GDP-1: absolute .distilled marker" "$LEARN_MSG" "$TEST_DIR/nazgul/learning/.distilled"
assert_contains "GDP-1: absolute proposed-rules.md" "$LEARN_MSG" "$TEST_DIR/nazgul/learning/proposed-rules.md"
assert_no_relative_path "GDP-1: no bare relative marker" "$LEARN_MSG" "nazgul/learning/.distilled"
assert_no_relative_path "GDP-1: no bare relative proposed-rules.md" "$LEARN_MSG" "nazgul/learning/proposed-rules.md"
teardown_temp_dir

# --- GDP-2: doc-verifier gate instructs with absolute marker ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP2"' \
  '.learning.auto_distill_post_loop = false'
printf '# Doc\n' > "$TEST_DIR/nazgul/docs/TRD.md"
run_hook
DV_MSG=$(gate_message "POST-LOOP DOC-VERIFIER GATE")
assert_exit_code "GDP-2: doc-verifier gate blocks" "$HOOK_EC" 2
assert_gate_driven "GDP-2: doc-verifier gate emitted a DELEGATE message" "$DV_MSG"
assert_contains "GDP-2: names <main_worktree_path>" "$DV_MSG" "<main_worktree_path> = $TEST_DIR"
assert_contains "GDP-2: absolute .docs-verified marker" "$DV_MSG" "$TEST_DIR/nazgul/logs/.docs-verified"
assert_no_relative_path "GDP-2: no bare relative marker" "$DV_MSG" "nazgul/logs/.docs-verified"
teardown_temp_dir

# --- GDP-3: comment-verifier gate instructs with absolute marker ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP3"' \
  '.learning.auto_distill_post_loop = false'
run_hook
CV_MSG=$(gate_message "POST-LOOP COMMENT-VERIFIER GATE")
assert_exit_code "GDP-3: comment-verifier gate blocks" "$HOOK_EC" 2
assert_gate_driven "GDP-3: comment-verifier gate emitted a DELEGATE message" "$CV_MSG"
assert_contains "GDP-3: names <main_worktree_path>" "$CV_MSG" "<main_worktree_path> = $TEST_DIR"
assert_contains "GDP-3: absolute .comments-verified marker" "$CV_MSG" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_no_relative_path "GDP-3: no bare relative marker" "$CV_MSG" "nazgul/logs/.comments-verified"
teardown_temp_dir

# --- GDP-4: self-audit gate — absolute marker and absolute default backlog ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP4"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs = {"verify_post_loop": false, "verify_comments": false}'
run_hook
SA_MSG=$(gate_message "POST-LOOP SELF-AUDIT GATE")
assert_exit_code "GDP-4: self-audit gate blocks" "$HOOK_EC" 2
assert_gate_driven "GDP-4: self-audit gate emitted a DELEGATE message" "$SA_MSG"
assert_contains "GDP-4: names <main_worktree_path>" "$SA_MSG" "<main_worktree_path> = $TEST_DIR"
assert_contains "GDP-4: absolute .self-audited marker" "$SA_MSG" "$TEST_DIR/nazgul/logs/.self-audited"
assert_contains "GDP-4: absolute default backlog" "$SA_MSG" "$TEST_DIR/nazgul/improvements.md"
assert_no_relative_path "GDP-4: no bare relative marker" "$SA_MSG" "nazgul/logs/.self-audited"
assert_no_relative_path "GDP-4: no bare relative backlog" "$SA_MSG" "nazgul/improvements.md"
teardown_temp_dir

# --- GDP-5: a configured relative backlog is honoured, rooted at PROJECT_ROOT ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP5"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs = {"verify_post_loop": false, "verify_comments": false}' \
  '.self_audit.backlog_path = "blk/improvements.md"'
run_hook
SA5_MSG=$(gate_message "POST-LOOP SELF-AUDIT GATE")
assert_gate_driven "GDP-5: self-audit gate emitted a DELEGATE message" "$SA5_MSG"
assert_contains "GDP-5: configured backlog rendered absolute" "$SA5_MSG" "$TEST_DIR/blk/improvements.md"
assert_not_contains "GDP-5: default backlog not substituted" "$SA5_MSG" "nazgul/improvements.md"
assert_no_relative_path "GDP-5: no bare relative configured backlog" "$SA5_MSG" "blk/improvements.md"
assert_json_field "GDP-5: configured backlog_path untouched in config" \
  "$TEST_DIR/nazgul/config.json" ".self_audit.backlog_path" "blk/improvements.md"
teardown_temp_dir

# --- GDP-6: an already-absolute configured backlog is not re-rooted ---
complete_objective_fixture \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-GDP6"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs = {"verify_post_loop": false, "verify_comments": false}' \
  '.self_audit.backlog_path = "/srv/nazgul-backlog.md"'
run_hook
SA6_MSG=$(gate_message "POST-LOOP SELF-AUDIT GATE")
assert_exit_code "GDP-6: self-audit gate blocks" "$HOOK_EC" 2
assert_gate_driven "GDP-6: self-audit gate emitted a DELEGATE message" "$SA6_MSG"
# Quote-anchored: an unanchored search for the configured path is a substring of every
# re-rooted spelling of it, so it would pass on exactly the regression this case exists for.
assert_contains "GDP-6: absolute backlog passed through verbatim" \
  "$SA6_MSG" '"/srv/nazgul-backlog.md"'
assert_not_contains "GDP-6: not re-rooted at PROJECT_ROOT" "$SA6_MSG" "$TEST_DIR/srv/nazgul-backlog.md"
# The likeliest regression is unconditional "$PROJECT_ROOT/$SA_BACKLOG", whose DOUBLE slash
# the single-slash control cannot see; collapse slash runs so every spelling lands on one test.
SA6_NORM=$(printf '%s' "$SA6_MSG" | sed 's|//*|/|g')
SA6_ROOT_NORM=$(printf '%s' "$TEST_DIR" | sed 's|//*|/|g')
assert_not_contains "GDP-6: not re-rooted by naive concatenation either (any slash run)" \
  "$SA6_NORM" "$SA6_ROOT_NORM/srv/nazgul-backlog.md"
teardown_temp_dir

report_results
