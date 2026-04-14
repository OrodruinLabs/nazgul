#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/session-runner.sh"

echo "=== E2E: /nazgul:status ==="

# Setup: create a minimal nazgul runtime dir in a temp project
TEMP_PROJECT=$(mktemp -d)
trap 'rm -rf "$TEMP_PROJECT"' EXIT

cd "$TEMP_PROJECT"
git init -q
git config user.email "test@nazgul.dev"
git config user.name "Nazgul Test"
touch .gitkeep && git add . && git commit -q -m "init"
mkdir -p nazgul/tasks nazgul/checkpoints

cat > nazgul/config.json << 'CONF'
{
  "schema_version": 5,
  "mode": "hitl",
  "objective": "E2E test objective",
  "max_iterations": 10,
  "current_iteration": 3,
  "agents": { "reviewers": ["code-reviewer"] }
}
CONF

cat > nazgul/plan.md << 'PLAN'
# Plan
## Recovery Pointer
- **Current Task:** TASK-001
- **Last Action:** Testing
## Tasks
- TASK-001: Test task [IN_PROGRESS]
PLAN

# Run the skill
OUTPUT=$(run_skill_session "/nazgul:status" 60)

# Validate
PASSED=0
FAILED=0

assert_output_contains "$OUTPUT" "NAZGUL" "Shows Nazgul branding" && ((PASSED++)) || ((FAILED++))

echo ""
echo "E2E /nazgul:status: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
