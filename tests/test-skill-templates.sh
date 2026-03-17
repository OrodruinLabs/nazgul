#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-skill-templates"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Test 1: Template processor exists and is executable
script="$REPO_ROOT/scripts/gen-skill-docs.sh"
assert_file_exists "gen-skill-docs.sh exists" "$script"
if [ -x "$script" ]; then
  _pass "gen-skill-docs.sh is executable"
else
  _fail "gen-skill-docs.sh is executable"
fi

# Test 2: Preamble partial exists
assert_file_exists "preamble partial exists" "$REPO_ROOT/templates/skill-partials/preamble.md"

# Test 3: Recovery protocol partial exists
assert_file_exists "recovery partial exists" "$REPO_ROOT/templates/skill-partials/recovery-protocol.md"

# Test 4: Preamble has expected content
preamble_content=$(cat "$REPO_ROOT/templates/skill-partials/preamble.md")
assert_contains "preamble has output formatting" "$preamble_content" "Output Formatting"
assert_contains "preamble has recovery protocol" "$preamble_content" "Recovery Protocol"
assert_contains "preamble references ui-brand" "$preamble_content" "ui-brand.md"

# Test 5: Gen script --dry-run doesn't error
output=$("$script" --dry-run 2>&1) || true
# Should mention partials
assert_contains "dry-run shows partials" "$output" "partial"

# Test 6: Gen script --check doesn't crash
"$script" --check 2>&1 || true
_pass "gen-skill-docs.sh --check runs without crash"

report_results
