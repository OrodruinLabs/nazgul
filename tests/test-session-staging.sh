#!/usr/bin/env bash
set -uo pipefail

# Test: session-staging.sh — the SessionEnd session-lock release (FEAT-032 board R2).
# The lock's lifetime is the SESSION's, so the release must survive every staging gate.
TEST_NAME="test-session-staging"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Locks come from the real producer: _sanitize_session_id pipes through `echo`, so a
# genuine lock is "<id>_.lock" — a hand-planted "<id>.lock" is a vacuously-green fixture.
plant_session() {
  local root="$1" afk="$2"
  mkdir -p "$root/nazgul"
  jq -cn --arg a "$afk" '{afk: {enabled: ($a == "true")}, install_mode: "plugin"}' \
    > "$root/nazgul/config.json"
  ( source "$REPO_ROOT/scripts/lib/session-tracker.sh"
    register_session "sess-a" "$root/nazgul/sessions" )
}

lock_count() {
  find "$1/nazgul/sessions" -maxdepth 1 -name '*.lock' 2>/dev/null | wc -l | tr -d ' '
}

run_session_end() {
  local root="$1" cwd="${2:-$1}"
  ( cd "$cwd" && printf '{"session_id":"sess-a"}' \
      | CLAUDE_PROJECT_DIR="$root" bash "$REPO_ROOT/scripts/session-staging.sh" >/dev/null 2>&1 )
}

# --- Test 1: AFK + git repo + cwd at root — the one path that always released ---
setup_temp_dir
plant_session "$TEST_DIR" true
setup_git_repo
assert_eq "afk: lock registered before SessionEnd" "$(lock_count "$TEST_DIR")" "1"
run_session_end "$TEST_DIR"
assert_eq "afk: lock released (the path that already worked)" "$(lock_count "$TEST_DIR")" "0"
teardown_temp_dir

# --- Test 2: HITL — afk.enabled=false, the TEMPLATE DEFAULT. This is the case that
# proves the fix: every HITL session used to register a lock and then leak it ---
setup_temp_dir
plant_session "$TEST_DIR" false
setup_git_repo
assert_eq "hitl: lock registered before SessionEnd" "$(lock_count "$TEST_DIR")" "1"
run_session_end "$TEST_DIR"
assert_eq "hitl: lock released despite staging being skipped" "$(lock_count "$TEST_DIR")" "0"
teardown_temp_dir

# --- Test 3: staging disabled by env — an unrelated opt-out must not pin a lock ---
setup_temp_dir
plant_session "$TEST_DIR" true
setup_git_repo
( cd "$TEST_DIR" && printf '{"session_id":"sess-a"}' \
    | NAZGUL_STAGING_DISABLE=1 CLAUDE_PROJECT_DIR="$TEST_DIR" \
      bash "$REPO_ROOT/scripts/session-staging.sh" >/dev/null 2>&1 )
assert_eq "NAZGUL_STAGING_DISABLE=1: lock still released" "$(lock_count "$TEST_DIR")" "0"
teardown_temp_dir

# --- Test 4: cwd is NOT the project root (the task-worktree shape). The release
# resolves its root with resolve_nazgul_dir, so no cwd-relative probe gates it ---
setup_temp_dir
plant_session "$TEST_DIR" true
setup_git_repo
mkdir -p "$TEST_DIR/sub"
run_session_end "$TEST_DIR" "$TEST_DIR/sub"
assert_eq "cwd off-root: lock released via resolve_nazgul_dir, not a cwd probe" \
  "$(lock_count "$TEST_DIR")" "0"
teardown_temp_dir

# --- Test 5: not a git repository at all ---
setup_temp_dir
plant_session "$TEST_DIR" true
run_session_end "$TEST_DIR"
assert_eq "non-git tree: lock still released" "$(lock_count "$TEST_DIR")" "0"
teardown_temp_dir

# --- Test 6: no session_id in the payload -> release NOTHING ---
# INVERTED DELIBERATELY (PR #223 review #9). This asserted the `.session_id` fallback,
# which is last-writer-wins: session-context.sh rewrites that file on every SessionStart,
# so in the shared-working-tree case #195 exists to protect, session A ending here would
# have unregistered session B's LIVE lock while A's own leaked. An unreleased lock is
# retired by the pid-liveness sweep; a wrongly-released one silently disarms the
# collision warning for a session that is still running. Absent beats wrong.
setup_temp_dir
plant_session "$TEST_DIR" false
printf 'sess-a' > "$TEST_DIR/nazgul/.session_id"
( cd "$TEST_DIR" && printf '{}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/session-staging.sh" >/dev/null 2>&1 )
assert_eq "payload without session_id: releases NOTHING — .session_id cannot identify the ending session" \
  "$(lock_count "$TEST_DIR")" "1"
teardown_temp_dir

# --- Test 7: another session's lock is never collateral damage ---
setup_temp_dir
plant_session "$TEST_DIR" false
( source "$REPO_ROOT/scripts/lib/session-tracker.sh"
  register_session "sess-b" "$TEST_DIR/nazgul/sessions" )
run_session_end "$TEST_DIR"
assert_eq "only the ending session's lock is removed" "$(lock_count "$TEST_DIR")" "1"
assert_file_exists "the OTHER session's lock survives" "$TEST_DIR/nazgul/sessions/sess-b_.lock"
teardown_temp_dir

# --- Test 8: the hook stays non-blocking on the HITL path ---
setup_temp_dir
plant_session "$TEST_DIR" false
OUT=$( cd "$TEST_DIR" && printf '{"session_id":"sess-a"}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/session-staging.sh" 2>/dev/null )
EC=$?
assert_eq "hitl: hook exits 0 (non-blocking)" "$EC" "0"
assert_contains "hitl: hook still emits its continue envelope" "$OUT" '"continue": true'
teardown_temp_dir

# --- Test 9: uninitialized project — nothing to release, and no crash ---
setup_temp_dir
OUT=$( cd "$TEST_DIR" && printf '{"session_id":"sess-a"}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/session-staging.sh" 2>/dev/null )
EC=$?
assert_eq "no nazgul/ at all: exits 0" "$EC" "0"
assert_contains "no nazgul/ at all: continue envelope emitted" "$OUT" '"continue": true'
teardown_temp_dir

report_results
