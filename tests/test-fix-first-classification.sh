#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-fix-first-classification"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Test 1: Classification reference exists and has required sections
ref_file="$REPO_ROOT/references/fix-first-heuristic.md"
assert_file_exists "reference file exists" "$ref_file"

content=$(cat "$ref_file")
assert_contains "has AUTO-FIX section" "$content" "AUTO-FIX"
assert_contains "has ASK section" "$content" "ASK"
assert_contains "has Classification Rules section" "$content" "Classification Rules"
assert_contains "security always ASK" "$content" "Security findings are ALWAYS ASK"

# Test 2: Review gate references fix-first heuristic
gate_file="$REPO_ROOT/agents/review-gate.md"
gate_content=$(cat "$gate_file")
assert_contains "review-gate references fix-first" "$gate_content" "fix-first"

# Test 3: Feedback aggregator references fix-first categories
agg_file="$REPO_ROOT/agents/feedback-aggregator.md"
agg_content=$(cat "$agg_file")
assert_contains "aggregator has AUTO-FIX" "$agg_content" "AUTO-FIX"
assert_contains "aggregator has ASK" "$agg_content" "ASK"

report_results
