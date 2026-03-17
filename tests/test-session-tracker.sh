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

report_results
