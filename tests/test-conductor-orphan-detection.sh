#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-orphan-detection"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
HOOK="$REPO_ROOT/scripts/subagent-stop.sh"

setup() { # <graph_json>
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor" "$WORK/nazgul/logs"
  jq -n '{schema_version:20,execution:{engine:"conductor"},telemetry:{bus_enabled:true}}' > "$WORK/nazgul/config.json"
  echo "$1" > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }
fire() { jq -n '{subagent_type:"nazgul:conductor"}' | bash "$HOOK" >/dev/null 2>&1 || true; }
count_event() { # <file> <pattern>
  local n
  n=$(grep -c "$2" "$1" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# incomplete wave: a unit dispatched but not terminal -> .resume-needed written
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"IN_PROGRESS","wave":1,"dispatched":true},"TASK-002":{"status":"DONE","wave":1}}}'
fire
assert_file_exists "orphan marker written on incomplete wave" "$WORK/nazgul/conductor/.resume-needed"
assert_json_field "resume marker records wave" "$WORK/nazgul/conductor/.resume-needed" '.wave' "1"
assert_json_field "resume marker records orphaned unit" "$WORK/nazgul/conductor/.resume-needed" '.units[0]' "TASK-001"
assert_eq "conductor_orphan_detected event emitted" "$(count_event "$WORK/nazgul/logs/events.jsonl" '"conductor_orphan_detected"')" "1"
teardown

# complete wave -> no marker, no event
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"DONE","wave":1},"TASK-002":{"status":"DONE","wave":1}}}'
fire
assert_file_not_exists "no marker when wave complete" "$WORK/nazgul/conductor/.resume-needed"
assert_eq "no conductor_orphan_detected event when wave complete" "$(count_event "$WORK/nazgul/logs/events.jsonl" '"conductor_orphan_detected"')" "0"
teardown

# dispatched unit already BLOCKED (terminal) -> no marker
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"BLOCKED","wave":1,"dispatched":true},"TASK-002":{"status":"DONE","wave":1}}}'
fire
assert_file_not_exists "no marker when dispatched unit is BLOCKED (terminal)" "$WORK/nazgul/conductor/.resume-needed"
teardown

# non-conductor agent -> detector never runs even with an incomplete graph
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"IN_PROGRESS","wave":1,"dispatched":true}}}'
jq -n '{subagent_type:"nazgul:implementer"}' | bash "$HOOK" >/dev/null 2>&1 || true
assert_file_not_exists "non-conductor agent does not trigger detector" "$WORK/nazgul/conductor/.resume-needed"
teardown

report_results
