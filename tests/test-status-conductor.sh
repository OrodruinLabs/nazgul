#!/usr/bin/env bash
set -euo pipefail

# Test: /nazgul:status conductor-mode wave/unit view (skills/status/SKILL.md)
TEST_NAME="test-status-conductor"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STATUS_SKILL="$REPO_ROOT/skills/status/SKILL.md"

# Extract the shipped "Conductor graph digest" command so the test exercises
# the exact snippet the skill runs, not a reimplementation of it.
DIGEST_CMD=$(grep "Conductor graph digest:" "$STATUS_SKILL" | sed -n 's/.*!`\(.*\)`$/\1/p')
assert_eq "digest command was extracted from SKILL.md" "$([ -n "$DIGEST_CMD" ] && echo yes || echo no)" "yes"

run_digest() {
  (cd "$TEST_DIR" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$DIGEST_CMD")
}

# --- Test 1: conductor engine + graph.json -> wave/unit digest ---
setup_temp_dir
setup_nazgul_dir
create_config '.execution.engine = "conductor"'
source "$REPO_ROOT/scripts/lib/conductor-graph.sh"
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-TEST" "conductor" 2
graph_upsert_task "$GRAPH" "TASK-001" '[]' 1 "DONE" '["skills/status/SKILL.md"]'
graph_set_verdict "$GRAPH" "TASK-001" "approved" "abc1234"
graph_upsert_task "$GRAPH" "TASK-002" '["TASK-001"]' 2 "IN_PROGRESS" '["tests/test-status-conductor.sh"]'

DIGEST_OUT=$(run_digest)
printf '%s' "$DIGEST_OUT" > "$TEST_DIR/digest.json"
if [ "$DIGEST_OUT" != "{}" ]; then _pass "conductor+graph: digest is non-empty"; else _fail "conductor+graph: digest is non-empty" "got: $DIGEST_OUT"; fi
assert_json_field "conductor+graph: TASK-001 status" "$TEST_DIR/digest.json" ".units[\"TASK-001\"].status" "DONE"
assert_json_field "conductor+graph: TASK-001 sha" "$TEST_DIR/digest.json" ".units[\"TASK-001\"].sha" "abc1234"
assert_json_field "conductor+graph: TASK-001 wave" "$TEST_DIR/digest.json" ".units[\"TASK-001\"].wave" "1"
assert_json_field "conductor+graph: TASK-002 status" "$TEST_DIR/digest.json" ".units[\"TASK-002\"].status" "IN_PROGRESS"
assert_json_field "conductor+graph: next_unit is the first non-terminal unit" "$TEST_DIR/digest.json" ".next_unit" "TASK-002"
teardown_temp_dir

# --- Test 2: sequential engine -> digest degrades to "{}" (regression: sequential view untouched) ---
setup_temp_dir
setup_nazgul_dir
create_config '.execution.engine = "sequential"'
DIGEST_OUT=$(run_digest)
assert_eq "sequential: digest is empty object" "$DIGEST_OUT" "{}"
teardown_temp_dir

# --- Test 3: conductor engine, no graph.json yet -> degrades gracefully, no crash ---
setup_temp_dir
setup_nazgul_dir
create_config '.execution.engine = "conductor"'
DIGEST_EC=0
DIGEST_OUT=$(run_digest) || DIGEST_EC=$?
assert_exit_code "conductor+no-graph: exits 0" "$DIGEST_EC" 0
assert_eq "conductor+no-graph: digest is empty object" "$DIGEST_OUT" "{}"
teardown_temp_dir

# --- Static wiring: SKILL.md documents the conductor branch and the sequential fallback ---
assert_file_contains "SKILL.md gates the conductor branch on execution.engine + graph digest" \
  "$STATUS_SKILL" "Conductor-mode branch"
assert_file_contains "SKILL.md reuses graph_wave_digest (never reimplements wave computation)" \
  "$STATUS_SKILL" "graph_wave_digest"
assert_file_contains "SKILL.md documents graceful no-graph-yet fallback" \
  "$STATUS_SKILL" "no graph yet"
assert_file_contains "SKILL.md keeps the sequential Status Report Format" \
  "$STATUS_SKILL" "Task Progress"
assert_file_contains "SKILL.md adds the Conductor Wave Progress format" \
  "$STATUS_SKILL" "Conductor Wave Progress"

report_results
