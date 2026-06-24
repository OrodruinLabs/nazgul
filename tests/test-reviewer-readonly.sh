#!/usr/bin/env bash
set -uo pipefail

# Reviewers must stay genuinely read-only: no Write and no Bash tool (so they
# cannot modify files or run commands), and no SubagentStop file-write hook.
# They RETURN their review; the review-gate orchestrator persists it. This guards
# against regressing back to the "told to write a file but can't" failure mode.

TEST_NAME="test-reviewer-readonly"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

TEMPLATE="$REPO_ROOT/agents/templates/reviewer-base.md"

# Template invariants
assert_file_not_contains "template: no Bash in tool allowlist" "$TEMPLATE" "  - Bash"
assert_file_not_contains "template: no Write in tool allowlist" "$TEMPLATE" "  - Write"
assert_file_not_contains "template: no SubagentStop file-write hook" "$TEMPLATE" "SubagentStop"
assert_file_contains "template: instructs return-based output" "$TEMPLATE" "Return your review as your final message"

# Generated reviewers (rendered from the template) must hold the same invariants
for f in "$REPO_ROOT"/.claude/agents/generated/*-reviewer.md; do
  [ -e "$f" ] || continue
  rn=$(basename "$f")
  assert_file_not_contains "generated $rn: no Bash in tool allowlist" "$f" "  - Bash"
  assert_file_not_contains "generated $rn: no Write in tool allowlist" "$f" "  - Write"
  assert_file_not_contains "generated $rn: no SubagentStop hook" "$f" "SubagentStop"
  assert_file_contains "generated $rn: return-based output" "$f" "Return your review"
done

report_results
