#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-self-improvement"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Test 1: Reference doc exists
assert_file_exists "reference doc exists" "$REPO_ROOT/references/self-improvement.md"

# Test 2: Report script exists and is executable
script="$REPO_ROOT/scripts/file-improvement-report.sh"
assert_file_exists "report script exists" "$script"
if [ ! -x "$script" ]; then
  _fail "report script is executable"
else
  _pass "report script is executable"
fi

# Test 3: Report script produces valid JSON
setup_temp_dir
output_dir="$TEST_DIR/reports"
mkdir -p "$output_dir"

"$script" \
  --task "TASK-001" \
  --agent "implementer" \
  --rating 7 \
  --summary "Test report" \
  --output-dir "$output_dir" >/dev/null 2>&1

report_file=$(ls "$output_dir"/*.json 2>/dev/null | head -1)
if [ -z "$report_file" ]; then
  _fail "report file created"
else
  _pass "report file created"
  # Validate JSON fields
  assert_json_field "has task field" "$report_file" ".task" "TASK-001"
  assert_json_field "has rating field" "$report_file" ".rating" "7"
  assert_json_field "has agent field" "$report_file" ".agent" "implementer"
fi

teardown_temp_dir
report_results
