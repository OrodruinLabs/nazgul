#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/session-runner.sh"

echo "=== E2E: /nazgul:init ==="

# Setup: create a fresh project with no nazgul state
TEMP_PROJECT=$(mktemp -d)
trap 'rm -rf "$TEMP_PROJECT"' EXIT

cd "$TEMP_PROJECT"
git init -q
git config user.email "test@nazgul.dev"
git config user.name "Nazgul Test"
echo "# Test Project" > README.md
git add . && git commit -q -m "init"

# Run the skill
OUTPUT=$(run_skill_session "/nazgul:init" 90)

# Validate
PASSED=0
FAILED=0

assert_output_contains "$OUTPUT" "nazgul" "Mentions nazgul in output" && ((PASSED++)) || ((FAILED++))

echo ""
echo "E2E /nazgul:init: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
