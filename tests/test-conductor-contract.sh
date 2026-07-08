#!/usr/bin/env bash
set -euo pipefail

# Test: agents/conductor.md prose contracts that the Layer 1-3 shell guards
# depend on (grepped as data, never eval'd, by conductor-dispatch-guard.sh /
# conductor-rework-guard.sh / subagent-stop.sh's orphan detector).
TEST_NAME="test-conductor-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

CONDUCTOR_MD="$REPO_ROOT/agents/conductor.md"

assert_file_contains "Step 5 emits the NAZGUL_UNIT dispatch-guard contract" "$CONDUCTOR_MD" "NAZGUL_UNIT: TASK"
assert_file_contains "Step 0 writes the session marker guards key off of" "$CONDUCTOR_MD" "conductor/.session"
assert_file_contains "Step 5 wires graph_mark_dispatched before dispatch" "$CONDUCTOR_MD" "graph_mark_dispatched"

report_results
