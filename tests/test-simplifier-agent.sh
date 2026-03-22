#!/usr/bin/env bash
set -euo pipefail

# Test: Simplifier agent definition has valid structure
TEST_NAME="test-simplifier-agent"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

AGENT_FILE="$REPO_ROOT/agents/simplifier.md"

# --- Test 1: Agent file exists ---
assert_file_exists "simplifier.md exists" "$AGENT_FILE"

# --- Test 2: Has valid frontmatter with name ---
assert_file_contains "has name field" "$AGENT_FILE" "name: simplifier"

# --- Test 3: Has required tools ---
assert_file_contains "has Read tool" "$AGENT_FILE" "Read"
assert_file_contains "has Write tool" "$AGENT_FILE" "Write"
assert_file_contains "has Edit tool" "$AGENT_FILE" "Edit"
assert_file_contains "has Bash tool" "$AGENT_FILE" "Bash"
assert_file_contains "has Agent tool" "$AGENT_FILE" "Agent"

# --- Test 4: Has maxTurns ---
assert_file_contains "has maxTurns" "$AGENT_FILE" "maxTurns:"

# --- Test 5: References all 3 review types ---
assert_file_contains "references reuse review" "$AGENT_FILE" "Reuse"
assert_file_contains "references quality review" "$AGENT_FILE" "Quality"
assert_file_contains "references efficiency review" "$AGENT_FILE" "Efficiency"

# --- Test 6: Has safety rules ---
assert_file_contains "has safety rules" "$AGENT_FILE" "Safety Rules"
assert_file_contains "mentions test after fix" "$AGENT_FILE" "Test after every single fix"
assert_file_contains "mentions non-blocking" "$AGENT_FILE" "Non-blocking"

report_results
