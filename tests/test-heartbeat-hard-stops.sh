#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes/log content explicitly

# Test: heartbeat.sh — the two unconditional hard stops (BLOCKED task,
# security rejection), independent of automation.heartbeat.enabled and of mode
TEST_NAME="test-heartbeat-hard-stops"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

latest_log() {
  ls -1t "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | head -1
}

run_case() {
  local label="$1" expected_reason="$2"; shift 2
  create_config "$@"
  bash "$REPO_ROOT/scripts/heartbeat.sh"
  local log
  log=$(latest_log)
  assert_file_exists "$label: log file written" "$log"
  assert_json_field "$label: decision is hard_stop" "$log" '.decision' "hard_stop"
  assert_json_field "$label: reason names the firing stop" "$log" '.reason' "$expected_reason"
  rm -f "$log"
}

# --- BLOCKED task hard stop: fires under enabled true/false and mode yolo ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
create_task_file TASK-002 BLOCKED none
run_case "blocked/enabled-true" "blocked_task" '.automation.heartbeat.enabled = true'
run_case "blocked/enabled-false" "blocked_task" '.automation.heartbeat.enabled = false'
run_case "blocked/mode-yolo" "blocked_task" '.mode = "yolo"' '.automation.heartbeat.enabled = true'
teardown_temp_dir

# --- Security rejection hard stop: fires under enabled true/false and mode yolo ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 IN_REVIEW none
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'EOF'
---
verdict: CHANGES_REQUESTED
---
# Security Review

Blocking vulnerability found.
EOF
run_case "security/enabled-true" "security_rejection" '.automation.heartbeat.enabled = true'
run_case "security/enabled-false" "security_rejection" '.automation.heartbeat.enabled = false'
run_case "security/mode-yolo" "security_rejection" '.mode = "yolo"' '.automation.heartbeat.enabled = true'
teardown_temp_dir

report_results
