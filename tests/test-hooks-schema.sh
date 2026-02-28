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

# Has all 4 hook events
val=$(jq -r '.hooks.Stop | type' "$HOOKS")
assert_eq "has Stop hook" "$val" "array"

val=$(jq -r '.hooks.PreCompact | type' "$HOOKS")
assert_eq "has PreCompact hook" "$val" "array"

val=$(jq -r '.hooks.PreToolUse | type' "$HOOKS")
assert_eq "has PreToolUse hook" "$val" "array"

val=$(jq -r '.hooks.SessionStart | type' "$HOOKS")
assert_eq "has SessionStart hook" "$val" "array"

# Stop has both prompt and command hooks
stop_types=$(jq -r '[.hooks.Stop[0].hooks[].type] | sort | join(",")' "$HOOKS")
assert_eq "Stop has prompt and command" "$stop_types" "command,prompt"

# PreToolUse has Bash matcher
matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$HOOKS")
assert_eq "PreToolUse has Bash matcher" "$matcher" "Bash"

# SessionStart has both startup and compact matchers
matchers=$(jq -r '[.hooks.SessionStart[].matcher] | sort | join(",")' "$HOOKS")
assert_eq "SessionStart has startup and compact matchers" "$matchers" "compact,startup"

# All command hooks reference scripts/
all_commands=$(jq -r '.. | objects | select(.type == "command") | .command' "$HOOKS" 2>/dev/null)
all_valid=true
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if ! echo "$cmd" | grep -q 'scripts/'; then
    all_valid=false
    break
  fi
done <<< "$all_commands"
if [ "$all_valid" = true ]; then
  _pass "All command hooks reference scripts/"
else
  _fail "All command hooks reference scripts/" "Found command not referencing scripts/"
fi

report_results
