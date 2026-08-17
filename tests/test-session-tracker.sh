#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-session-tracker"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Source the tracker
source "$REPO_ROOT/scripts/lib/session-tracker.sh"

# Test 1: Register creates a lock file
setup_temp_dir
sessions_dir="$TEST_DIR/sessions"
register_session "test-session-1" "$sessions_dir"
count=$(count_active_sessions "$sessions_dir")
assert_eq "register creates lock" "$count" "1"
teardown_temp_dir

# Test 2: Detect concurrent sessions
setup_temp_dir
sessions_dir="$TEST_DIR/sessions"
register_session "session-a" "$sessions_dir"
register_session "session-b" "$sessions_dir"
count=$(count_active_sessions "$sessions_dir")
assert_eq "detect concurrent" "$count" "2"
teardown_temp_dir

# Test 3: Unregister removes lock file
setup_temp_dir
sessions_dir="$TEST_DIR/sessions"
register_session "session-x" "$sessions_dir"
unregister_session "session-x" "$sessions_dir"
count=$(count_active_sessions "$sessions_dir")
assert_eq "unregister removes lock" "$count" "0"
teardown_temp_dir

# Test 4: Stale sessions are cleaned up
setup_temp_dir
sessions_dir="$TEST_DIR/sessions"
mkdir -p "$sessions_dir"
echo '{"pid": 99999, "started": "old"}' > "$sessions_dir/stale.lock"
# Backdate mtime to 3 hours ago (relative to now, cross-platform)
three_hours_ago=$(date -v-3H +"%Y%m%d%H%M" 2>/dev/null || date -d "3 hours ago" +"%Y%m%d%H%M" 2>/dev/null || echo "")
if [ -n "$three_hours_ago" ]; then
  touch -t "$three_hours_ago" "$sessions_dir/stale.lock"
fi
cleanup_stale_sessions "$sessions_dir" 7200
count=$(count_active_sessions "$sessions_dir")
assert_eq "stale cleanup" "$count" "0"
teardown_temp_dir

# Test 5: Concurrent warning fires when 2+ sessions
setup_temp_dir
sessions_dir="$TEST_DIR/sessions"
register_session "s1" "$sessions_dir"
register_session "s2" "$sessions_dir"
warning=$(is_concurrent_session_warning "$sessions_dir" 2>&1) || true
assert_contains "concurrent warning message" "$warning" "concurrent"
teardown_temp_dir

# --- lock payload: identity + tree fields (#195) ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/sessions"
(cd "$TEST_DIR" && CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/424242.sock" \
  bash -c 'source "'"$REPO_ROOT"'/scripts/lib/session-tracker.sh"; register_session "sess-a" nazgul/sessions')
LOCK=$(ls "$TEST_DIR"/nazgul/sessions/*.lock | head -1)
assert_eq "register: pid derived from messaging-socket basename" "$(jq -r '.pid' "$LOCK")" "424242"
assert_eq "register: cwd recorded" "$(jq -r '.cwd' "$LOCK")" "$(cd "$TEST_DIR" && pwd -P)"
CONTAINS_KEYS=$(jq -r 'has("toplevel") and has("branch")' "$LOCK")
assert_eq "register: toplevel and branch keys present" "$CONTAINS_KEYS" "true"
teardown_temp_dir

# --- liveness outranks age; dead pid removed promptly ---
setup_temp_dir
mkdir -p "$TEST_DIR/sessions"
DEAD_PID=$(bash -c 'echo $$')   # that shell has exited; its pid is dead
jq -cn --arg p "$DEAD_PID" '{pid:$p, session:"dead", started:"2026-01-01T00:00:00Z"}' > "$TEST_DIR/sessions/dead.lock"
jq -cn --arg p "$$" '{pid:$p, session:"live", started:"2026-01-01T00:00:00Z"}' > "$TEST_DIR/sessions/live.lock"
touch -t 202601010000 "$TEST_DIR/sessions/dead.lock" "$TEST_DIR/sessions/live.lock"
(source "$REPO_ROOT/scripts/lib/session-tracker.sh"; cleanup_stale_sessions "$TEST_DIR/sessions" 7200)
assert_file_not_exists "cleanup: dead-pid lock removed regardless of age policy" "$TEST_DIR/sessions/dead.lock"
assert_file_exists "cleanup: live-pid lock SURVIVES despite being over-age" "$TEST_DIR/sessions/live.lock"
teardown_temp_dir

# --- #195: >=2 LIVE locks against one tree is its own, sharper warning ---
setup_temp_dir
mkdir -p "$TEST_DIR/sessions"
jq -cn --arg p "$$" '{pid:$p, session:"a", started:"x", toplevel:"/repo/one"}' > "$TEST_DIR/sessions/a.lock"
jq -cn --arg p "$$" '{pid:$p, session:"b", started:"x", toplevel:"/repo/one"}' > "$TEST_DIR/sessions/b.lock"
MSG=$(source "$REPO_ROOT/scripts/lib/session-tracker.sh"; is_concurrent_session_warning "$TEST_DIR/sessions")
assert_contains "warning: names the shared tree" "$MSG" "/repo/one"
assert_contains "warning: names the #195 hazard class" "$MSG" "shared"
teardown_temp_dir

# Board R1 twin: the predicate is `set -e`-safe on its own, not by the accident
# of session-context.sh calling it as `if warning_msg=$(...)`.
setup_temp_dir
mkdir -p "$TEST_DIR/sessions"
# LIVE pids with no toplevel — board R3 made counting liveness-filtered, so the
# original dead-pid fixture now returns before ever reaching the scan under test.
jq -cn --arg p "$$" '{pid:$p, session:"a"}' > "$TEST_DIR/sessions/a.lock"
jq -cn --arg p "$$" '{pid:$p, session:"b"}' > "$TEST_DIR/sessions/b.lock"
SURVIVED=$(bash -c '
set -euo pipefail
source "$1"
is_concurrent_session_warning "$2/sessions" >/dev/null
echo SURVIVED
' _ "$REPO_ROOT/scripts/lib/session-tracker.sh" "$TEST_DIR" 2>/dev/null)
assert_eq "bare call under set -euo pipefail survives an empty duplicate scan" "$SURVIVED" "SURVIVED"
teardown_temp_dir

# --- Board R3: _session_lock_is_live is the ONE predicate, and liveness is the
# COUNTING path — not just the sweep's ---
setup_temp_dir
mkdir -p "$TEST_DIR/sessions"
jq -cn '{pid:"99999", session:"dead"}' > "$TEST_DIR/sessions/dead.lock"
jq -cn --arg p "$$" '{pid:$p, session:"live"}' > "$TEST_DIR/sessions/live.lock"
jq -cn '{session:"legacy"}' > "$TEST_DIR/sessions/legacy.lock"

RC=0; _session_lock_is_live "$TEST_DIR/sessions/live.lock" || RC=$?
assert_eq "predicate: live pid -> 0" "$RC" "0"
RC=0; _session_lock_is_live "$TEST_DIR/sessions/dead.lock" || RC=$?
assert_eq "predicate: unreachable pid -> 1" "$RC" "1"
RC=0; _session_lock_is_live "$TEST_DIR/sessions/legacy.lock" || RC=$?
assert_eq "predicate: no recorded pid -> 2 (unknown, never 'dead')" "$RC" "2"

COUNT=$(count_active_sessions "$TEST_DIR/sessions")
assert_eq "count: dead lock excluded, live + pid-less legacy still counted" "$COUNT" "2"
assert_file_exists "count: counting NEVER deletes — sweeping is cleanup's job" "$TEST_DIR/sessions/dead.lock"

rm -f "$TEST_DIR/sessions/live.lock" "$TEST_DIR/sessions/legacy.lock"
COUNT=$(count_active_sessions "$TEST_DIR/sessions")
assert_eq "count: a lone dead lock no longer reads as an active session" "$COUNT" "0"
teardown_temp_dir

report_results
