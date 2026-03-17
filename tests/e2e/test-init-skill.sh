#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/session-runner.sh"

echo "=== E2E: /hydra:init ==="

# Setup: create a fresh project with no hydra state
TEMP_PROJECT=$(mktemp -d)
trap 'rm -rf "$TEMP_PROJECT"' EXIT

cd "$TEMP_PROJECT"
git init -q
git config user.email "test@hydra.dev"
git config user.name "Hydra Test"
echo "# Test Project" > README.md
git add . && git commit -q -m "init"

# Run the skill
OUTPUT=$(run_skill_session "/hydra:init" 90)

# Validate
PASSED=0
FAILED=0

assert_output_contains "$OUTPUT" "hydra" "Mentions hydra in output" && ((PASSED++)) || ((FAILED++))

echo ""
echo "E2E /hydra:init: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
