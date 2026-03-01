#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-event-router"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

ROUTER="$REPO_ROOT/scripts/event-router.sh"

# Test: match_route function — exact source + glob event_type
result=$(bash "$ROUTER" --test-match '{"source":"github","event_type":"pr.opened"}' '{"source":"github","event_type":"pr.*"}')
assert_eq "github pr.* matches pr.opened" "$result" "match"

result=$(bash "$ROUTER" --test-match '{"source":"ci","event_type":"build.failed"}' '{"source":"github","event_type":"pr.*"}')
assert_eq "github pr.* does not match ci build.failed" "$result" "no_match"

result=$(bash "$ROUTER" --test-match '{"source":"ci","event_type":"deployment.completed"}' '{"source":"*","event_type":"deployment.*"}')
assert_eq "wildcard source matches any" "$result" "match"

# Test: route config validation
assert_file_exists "notification-routes template exists" "$REPO_ROOT/templates/notification-routes.json"

# Validate JSON
if jq empty "$REPO_ROOT/templates/notification-routes.json" 2>/dev/null; then
  _pass "notification-routes.json is valid JSON"
else
  _fail "notification-routes.json is valid JSON"
fi

# Check required fields
assert_json_field "routes array exists" "$REPO_ROOT/templates/notification-routes.json" '.routes | type' "array"
assert_json_field "fallback_agent defined" "$REPO_ROOT/templates/notification-routes.json" '.fallback_agent' "discovery"

report_results
