#!/usr/bin/env bash
set -euo pipefail

# Test: the e2e harness cannot report success for a run that checked nothing.
# FEAT-028 TASK-017 (docs/test-audit-2026-08.md finding F8): run-e2e.sh exited 0
# both when the claude CLI was absent and when a --filter matched no file — the
# same vacuous green tests/run-tests.sh fixed for the unit suite (plan D-6) and
# tests/smoke/run-smoke.sh carried from the start.
# Driven through the REAL runner with a PATH that has no claude on it; a real
# e2e is never invoked, because the harness must stop before that point.
TEST_NAME="test-e2e-harness-shape"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

RUNNER="$REPO_ROOT/tests/e2e/run-e2e.sh"
assert_file_exists "run-e2e.sh exists" "$RUNNER"

STUB=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-e2e-shape-XXXXXX")
trap 'rm -rf "$STUB"' EXIT
for tool in bash grep basename mktemp git jq sed awk cat rm cp chmod dirname sort; do
  src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$STUB/$tool"
done
assert_not_contains "the stub PATH dir has no claude in it" "$(ls "$STUB")" "claude"

run_e2e() {
  local out ec=0
  out=$(PATH="$STUB" bash "$RUNNER" "$@" </dev/null 2>&1) || ec=$?
  printf '%s\n__EC__%s\n' "$out" "$ec"
}

# --- Absent CLI: NOTHING CHECKED, exit 2 — never a green run that verified nothing ---
R=$(run_e2e)
assert_contains "absent claude CLI: exit 2, not 0" "$R" "__EC__2"
assert_contains "absent claude CLI: says NOTHING CHECKED" "$R" "NOTHING CHECKED"
assert_contains "absent claude CLI: names the reason" "$R" "claude CLI not on PATH"
assert_not_contains "absent claude CLI: never claims all tests passed" "$R" "All tests passed"

# --- Zero-match filter: NOTHING CHECKED, exit 2 (the plan D-6 class) ---
R=$(run_e2e "--filter=no-such-e2e-test-anywhere")
assert_contains "zero-match filter: exit 2, not 0" "$R" "__EC__2"
assert_contains "zero-match filter: says NOTHING CHECKED" "$R" "NOTHING CHECKED"

# --- Fixed-grammar coverage line on every path, accounting that adds up ---
COV=$(printf '%s' "$R" | grep -e '^run-e2e: ' | tail -1)
assert_contains "coverage line: fixed grammar" "$COV" "scanned,"
assert_contains "coverage line: names both skip reasons" "$COV" "filtered-out="
assert_contains "coverage line: no-claude-cli is a named reason" "$COV" "no-claude-cli="
SCANNED=$(printf '%s' "$COV" | sed -E 's/^run-e2e: ([0-9]+) scanned.*/\1/')
SKIPPED=$(printf '%s' "$COV" | sed -E 's/.*scanned, ([0-9]+) skipped.*/\1/')
CHECKED=$(printf '%s' "$COV" | sed -E 's/.*\), ([0-9]+) checked.*/\1/')
assert_eq "coverage accounting adds up (N == M + K)" "$SCANNED" "$((SKIPPED + CHECKED))"
if [ "$SCANNED" -gt 0 ]; then
  _pass "the runner discovered at least one e2e candidate to account for"
else
  _fail "the runner discovered at least one e2e candidate to account for" "scanned=$SCANNED"
fi

# --- The per-file skip-green: an e2e test file itself must not exit 0 CLI-less ---
BOOTSTRAP="$REPO_ROOT/tests/e2e/test-bootstrap-project.sh"
assert_file_exists "e2e/test-bootstrap-project.sh exists" "$BOOTSTRAP"
BE=0
BOUT=$(PATH="$STUB" bash "$BOOTSTRAP" </dev/null 2>&1) || BE=$?
assert_eq "e2e/test-bootstrap-project.sh: absent CLI exits 2, not 0" "$BE" "2"
assert_contains "e2e/test-bootstrap-project.sh: reports the skip as SKIP" "$BOUT" "SKIP:"
assert_contains "e2e/test-bootstrap-project.sh: says NOTHING CHECKED" "$BOUT" "NOTHING CHECKED"

# --- e2e/lib/session-runner.sh: its two helpers are pure shell and need no CLI ---
RUNNER_LIB="$REPO_ROOT/tests/e2e/lib/session-runner.sh"
assert_file_exists "e2e/lib/session-runner.sh exists" "$RUNNER_LIB"

run_helper() {
  local body="$1" out ec=0
  out=$(bash -c "source '$RUNNER_LIB'
$body" 2>&1) || ec=$?
  printf '%s\n__EC__%s\n' "$out" "$ec"
}

R=$(run_helper 'assert_output_not_contains "flags: --afk here" "--afk" "dash needle"')
assert_contains "session-runner: assert_output_not_contains FAILS on a dash needle that IS present" \
  "$R" "FAIL: dash needle"
assert_not_contains "session-runner: it is never scored as a pass" "$R" "PASS: dash needle"

R=$(run_helper 'assert_output_contains "flags: --afk here" "--afk" "dash needle present"')
assert_contains "session-runner: assert_output_contains evaluates a dash needle that IS present" \
  "$R" "PASS: dash needle present"

# The always-red counter idiom the two skill tests used: `((PASSED++))` returns the
# OLD value, so at 0 it is falsy and `set -e` aborted the file before its summary.
for skill_test in test-init-skill test-status-skill; do
  F="$REPO_ROOT/tests/e2e/$skill_test.sh"
  assert_file_not_contains "e2e/$skill_test.sh: no ((VAR++)) counter under set -e" \
    "$F" '((PASSED++))'
  assert_file_contains "e2e/$skill_test.sh: counts through an if/else instead" \
    "$F" 'PASSED=\$((PASSED + 1))'
done

report_results
