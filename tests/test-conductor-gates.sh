#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: conductor-gates.sh — gate evaluation + two unconditional hard stops
TEST_NAME="test-conductor-gates"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/conductor-gates.sh"

# --- Test 1: defaults — all gates false, max_parallel 3, engine sequential ---
setup_temp_dir
setup_nazgul_dir
create_config
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "defaults: approve_graph stored false" "$(conductor_gate_stored "$CONFIG" approve_graph)" "false"
assert_eq "defaults: approve_each_wave stored false" "$(conductor_gate_stored "$CONFIG" approve_each_wave)" "false"
assert_eq "defaults: approve_final_pr stored false" "$(conductor_gate_stored "$CONFIG" approve_final_pr)" "false"
assert_eq "defaults: max_parallel is 3" "$(conductor_max_parallel "$CONFIG")" "3"
assert_eq "defaults: engine is sequential" "$(conductor_execution_engine "$CONFIG")" "sequential"
assert_eq "defaults: no pause in afk" "$(conductor_gate_effective "$CONFIG" approve_graph afk)" "false"
assert_eq "defaults: no pause in yolo" "$(conductor_gate_effective "$CONFIG" approve_graph yolo)" "false"
teardown_temp_dir

# --- Test 2: hitl flips approve_graph effectively true; other two unaffected ---
setup_temp_dir
setup_nazgul_dir
create_config
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "hitl: approve_graph effective true" "$(conductor_gate_effective "$CONFIG" approve_graph hitl)" "true"
assert_eq "hitl: approve_graph stored stays false" "$(conductor_gate_stored "$CONFIG" approve_graph)" "false"
assert_eq "hitl: approve_each_wave stays false" "$(conductor_gate_effective "$CONFIG" approve_each_wave hitl)" "false"
assert_eq "hitl: approve_final_pr stays false" "$(conductor_gate_effective "$CONFIG" approve_final_pr hitl)" "false"
teardown_temp_dir

# --- Test 3: each gate independently togglable via stored config ---
setup_temp_dir
setup_nazgul_dir
create_config '.conductor.gates.approve_each_wave = true'
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "toggle: approve_each_wave true in afk" "$(conductor_gate_effective "$CONFIG" approve_each_wave afk)" "true"
assert_eq "toggle: approve_graph unaffected" "$(conductor_gate_effective "$CONFIG" approve_graph afk)" "false"
assert_eq "toggle: approve_final_pr unaffected" "$(conductor_gate_effective "$CONFIG" approve_final_pr afk)" "false"
if conductor_should_pause "$CONFIG" approve_each_wave afk; then
  _pass "toggle: conductor_should_pause true for approve_each_wave"
else
  _fail "toggle: conductor_should_pause true for approve_each_wave"
fi
if conductor_should_pause "$CONFIG" approve_graph yolo; then
  _fail "toggle: conductor_should_pause false for approve_graph in yolo"
else
  _pass "toggle: conductor_should_pause false for approve_graph in yolo"
fi
teardown_temp_dir

# --- Test 4: BLOCKED hard stop halts even with all gates false AND flipped ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
create_task_file TASK-002 BLOCKED none
create_config
NAZGUL_DIR="$TEST_DIR/nazgul"
HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "blocked/gates-false: halts" "$HALT_EC" 1
assert_contains "blocked/gates-false: names TASK-002" "$HALT_OUT" "BLOCKED_TASK TASK-002"

create_config '.conductor.gates.approve_graph = true' '.conductor.gates.approve_each_wave = true' '.conductor.gates.approve_final_pr = true'
HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "blocked/gates-flipped: still halts" "$HALT_EC" 1
assert_contains "blocked/gates-flipped: names TASK-002" "$HALT_OUT" "BLOCKED_TASK TASK-002"
teardown_temp_dir

# --- Test 5: security-reject hard stop halts even with all gates false AND flipped ---
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
create_config
NAZGUL_DIR="$TEST_DIR/nazgul"
HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "security-reject/gates-false: halts" "$HALT_EC" 1
assert_contains "security-reject/gates-false: names TASK-001" "$HALT_OUT" "SECURITY_REJECTION TASK-001"

create_config '.conductor.gates.approve_graph = true' '.conductor.gates.approve_each_wave = true' '.conductor.gates.approve_final_pr = true'
HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "security-reject/gates-flipped: still halts" "$HALT_EC" 1
assert_contains "security-reject/gates-flipped: names TASK-001" "$HALT_OUT" "SECURITY_REJECTION TASK-001"
teardown_temp_dir

# --- Test 6: malformed security verdict is ambiguous -> fails closed ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 IN_REVIEW none
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'EOF'
---
verdict: NOT_A_REAL_VERDICT
---
# Security Review
EOF
HALT_OUT=$(conductor_should_halt "$TEST_DIR/nazgul") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "malformed security verdict: halts" "$HALT_EC" 1
assert_contains "malformed security verdict: reports ambiguous" "$HALT_OUT" "SECURITY_REJECTION_AMBIGUOUS TASK-001"
teardown_temp_dir

# --- Test 7: clean state -> no halt (no BLOCKED task, approved security review) ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 IN_REVIEW none
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'EOF'
---
verdict: APPROVE
---
# Security Review

No issues.
EOF
HALT_OUT=$(conductor_should_halt "$TEST_DIR/nazgul") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "clean state: no halt" "$HALT_EC" 0
assert_eq "clean state: no output" "$HALT_OUT" ""
teardown_temp_dir

# --- Test 8: unreadable BLOCKED/security state fails CLOSED (not degrade-to-allow) ---
setup_temp_dir
NAZGUL_DIR="$TEST_DIR/nazgul-does-not-exist"
HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "unreadable nazgul_dir: fails closed" "$HALT_EC" 1
assert_contains "unreadable nazgul_dir: names tasks unreadable" "$HALT_OUT" "BLOCKED_TASKS_UNREADABLE"
assert_contains "unreadable nazgul_dir: names security unreadable" "$HALT_OUT" "SECURITY_REVIEWS_UNREADABLE"
teardown_temp_dir

# --- Test 9b: security-reviewer.md present with no verdict field (rc=1) is ambiguous -> fails closed ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 IN_REVIEW none
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'EOF'
# Security Review

No frontmatter, no verdict field at all.
EOF
HALT_OUT=$(conductor_should_halt "$TEST_DIR/nazgul") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "no-verdict security file: halts" "$HALT_EC" 1
assert_contains "no-verdict security file: reports ambiguous" "$HALT_OUT" "SECURITY_REJECTION_AMBIGUOUS TASK-001"
teardown_temp_dir

# --- Test 9c: INVALID task status is ambiguous -> fails closed ---
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/tasks/TASK-001.md" << 'EOF'
---
status: NOT_A_REAL_STATUS
---
# TASK-001: Test task
EOF
HALT_OUT=$(conductor_should_halt "$TEST_DIR/nazgul") && HALT_EC=0 || HALT_EC=$?
assert_exit_code "INVALID task status: halts" "$HALT_EC" 1
assert_contains "INVALID task status: reports ambiguous" "$HALT_OUT" "BLOCKED_TASKS_AMBIGUOUS TASK-001"
teardown_temp_dir

# --- Test 9d: malformed-JSON config -> execution.engine/max_parallel still degrade to allow ---
setup_temp_dir
setup_nazgul_dir
CONFIG="$TEST_DIR/nazgul/config.json"
echo "not valid json" > "$CONFIG"
assert_eq "malformed config: engine defaults sequential" "$(conductor_execution_engine "$CONFIG")" "sequential"
assert_eq "malformed config: max_parallel defaults 3" "$(conductor_max_parallel "$CONFIG")" "3"
teardown_temp_dir

# --- Test 9e: unreadable tasks_dir (exists but chmod 000) fails closed ---
if [ "$(id -u)" -ne 0 ]; then
  setup_temp_dir
  setup_nazgul_dir
  create_config
  NAZGUL_DIR="$TEST_DIR/nazgul"
  chmod 000 "$NAZGUL_DIR/tasks"
  HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR") && HALT_EC=0 || HALT_EC=$?
  chmod 755 "$NAZGUL_DIR/tasks"
  assert_exit_code "unreadable tasks_dir: halts" "$HALT_EC" 1
  assert_contains "unreadable tasks_dir: reports unreadable" "$HALT_OUT" "BLOCKED_TASKS_UNREADABLE"
  teardown_temp_dir
else
  echo "SKIP: unreadable tasks_dir test (running as root, chmod 000 has no effect)"
fi

# --- Test 9: a non-evaluable ordinary gate degrades to allow ---
setup_temp_dir
setup_nazgul_dir
CONFIG="$TEST_DIR/nazgul/config.json"
echo "not valid json" > "$CONFIG"
assert_eq "degrade-to-allow: malformed config stored false" "$(conductor_gate_stored "$CONFIG" approve_each_wave)" "false"
assert_eq "degrade-to-allow: malformed config effective false in afk" "$(conductor_gate_effective "$CONFIG" approve_each_wave afk)" "false"
MISSING_CONFIG="$TEST_DIR/nazgul/no-such-config.json"
assert_eq "degrade-to-allow: missing config stored false" "$(conductor_gate_stored "$MISSING_CONFIG" approve_graph)" "false"
assert_eq "degrade-to-allow: missing config engine defaults sequential" "$(conductor_execution_engine "$MISSING_CONFIG")" "sequential"
assert_eq "degrade-to-allow: missing config max_parallel defaults 3" "$(conductor_max_parallel "$MISSING_CONFIG")" "3"
# hitl override is a mode rule, not a config read — still applies even when the config is unreadable.
assert_eq "degrade-to-allow: hitl still flips approve_graph with malformed config" "$(conductor_gate_effective "$CONFIG" approve_graph hitl)" "true"
teardown_temp_dir

report_results
