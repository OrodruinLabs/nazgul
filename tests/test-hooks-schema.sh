#!/usr/bin/env bash
set -euo pipefail

# Test: hooks.json structure and wiring
TEST_NAME="test-hooks-schema"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

HOOKS="$REPO_ROOT/hooks/hooks.json"

assert_file_exists "hooks.json exists" "$HOOKS"

# Has all hook events
val=$(jq -r '.hooks.Stop | type' "$HOOKS")
assert_eq "has Stop hook" "$val" "array"

val=$(jq -r '.hooks.PreCompact | type' "$HOOKS")
assert_eq "has PreCompact hook" "$val" "array"

val=$(jq -r '.hooks.PostCompact | type' "$HOOKS")
assert_eq "has PostCompact hook" "$val" "array"

val=$(jq -r '.hooks.PreToolUse | type' "$HOOKS")
assert_eq "has PreToolUse hook" "$val" "array"

val=$(jq -r '.hooks.PostToolUse | type' "$HOOKS")
assert_eq "has PostToolUse hook" "$val" "array"

val=$(jq -r '.hooks.SessionStart | type' "$HOOKS")
assert_eq "has SessionStart hook" "$val" "array"

val=$(jq -r '.hooks.SessionEnd | type' "$HOOKS")
assert_eq "has SessionEnd hook" "$val" "array"

val=$(jq -r '.hooks.TaskCompleted | type' "$HOOKS")
assert_eq "has TaskCompleted hook" "$val" "array"

val=$(jq -r '.hooks.UserPromptSubmit | type' "$HOOKS")
assert_eq "has UserPromptSubmit hook" "$val" "array"

# Stop has command hooks
stop_types=$(jq -r '[.hooks.Stop[0].hooks[].type] | unique | join(",")' "$HOOKS")
assert_eq "Stop has command hooks" "$stop_types" "command"

# PreToolUse has Bash matcher
matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$HOOKS")
assert_eq "PreToolUse has Bash matcher" "$matcher" "Bash"

# SessionStart has both startup and compact matchers
matchers=$(jq -r '[.hooks.SessionStart[].matcher] | sort | join(",")' "$HOOKS")
assert_eq "SessionStart has startup and compact matchers" "$matchers" "compact,startup"

# All command hooks reference scripts/ or are inline bash
all_commands=$(jq -r '.. | objects | select(.type == "command") | .command' "$HOOKS" 2>/dev/null)
all_valid=true
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if ! echo "$cmd" | grep -qE '(scripts/|bash -c)'; then
    all_valid=false
    break
  fi
done <<< "$all_commands"
if [ "$all_valid" = true ]; then
  _pass "All command hooks reference scripts/ or inline bash"
else
  _fail "All command hooks reference scripts/ or inline bash" "Found command not referencing scripts/ or bash"
fi

report_results
