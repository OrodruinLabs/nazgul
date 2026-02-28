#!/usr/bin/env bash
set -euo pipefail

# Test: All JSON files parse correctly
TEST_NAME="test-json-validation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

JSON_FILES=(
  ".claude-plugin/plugin.json"
  "hooks/hooks.json"
  "templates/config.json"
  "templates/checkpoint.json"
  "templates/docs/design-tokens.json"
)

for json_file in "${JSON_FILES[@]}"; do
  full_path="$REPO_ROOT/$json_file"
  basename_file=$(basename "$json_file")
  if [ ! -f "$full_path" ]; then
    _fail "$basename_file exists" "file not found: $full_path"
    continue
  fi
  if jq empty "$full_path" 2>/dev/null; then
    _pass "$basename_file is valid JSON"
  else
    _fail "$basename_file is valid JSON" "jq parse error"
  fi
done

report_results
