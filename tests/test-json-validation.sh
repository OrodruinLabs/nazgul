#!/usr/bin/env bash
set -euo pipefail

# Test: every tracked JSON file in the plugin parses.
# Discovered by glob, not by a hand-maintained array: the previous list named 5
# paths and gave zero coverage to the 3 added after it was written (FEAT-028
# TASK-017, docs/test-audit-2026-08.md finding F7).
TEST_NAME="test-json-validation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCAN_ROOT="${NAZGUL_JSON_SCAN_ROOT:-$REPO_ROOT}"

# git ls-files, so only tracked plugin JSON is in scope — never a contributor's
# untracked scratch file, and never a fixture that is deliberately malformed.
mapfile -t JSON_FILES < <(cd "$SCAN_ROOT" && git ls-files '*.json' 2>/dev/null \
  | grep -v '^tests/' | sort -u)

JV_SCANNED=${#JSON_FILES[@]}
JV_CHECKED=0
JV_SKIP_NOT_A_FILE=0
JV_SKIP_UNREADABLE=0
JV_FINDINGS=0

for json_file in ${JSON_FILES[@]+"${JSON_FILES[@]}"}; do
  full_path="$SCAN_ROOT/$json_file"
  if [ ! -f "$full_path" ]; then
    JV_SKIP_NOT_A_FILE=$((JV_SKIP_NOT_A_FILE + 1))
    echo "  SKIP: $json_file (tracked but not a regular file — not checked)"
    continue
  fi
  if [ ! -r "$full_path" ]; then
    JV_SKIP_UNREADABLE=$((JV_SKIP_UNREADABLE + 1))
    echo "  SKIP: $json_file (unreadable — not checked)"
    continue
  fi
  JV_CHECKED=$((JV_CHECKED + 1))
  if jq empty "$full_path" 2>/dev/null; then
    _pass "$json_file is valid JSON"
  else
    JV_FINDINGS=$((JV_FINDINGS + 1))
    _fail "$json_file is valid JSON" "jq parse error"
  fi
done

# The paths the plugin cannot load without: named explicitly, so a discovery
# regression is a failure here rather than a quietly smaller scanned count.
for required in ".claude-plugin/plugin.json" "hooks/hooks.json" "templates/config.json" \
                "agents/templates/reviewer-domains.json"; do
  if printf '%s\n' ${JSON_FILES[@]+"${JSON_FILES[@]}"} | grep -qxF -- "$required"; then
    _pass "discovery includes the load-bearing $required"
  else
    JV_FINDINGS=$((JV_FINDINGS + 1))
    _fail "discovery includes the load-bearing $required" "not in the discovered set"
  fi
done

JV_SKIPPED=$((JV_SKIP_NOT_A_FILE + JV_SKIP_UNREADABLE))
if [ "$JV_SCANNED" -ne $((JV_SKIPPED + JV_CHECKED)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $JV_SCANNED scanned != $JV_SKIPPED skipped + $JV_CHECKED checked" >&2
  _fail "coverage accounting adds up (N == M + K)" "$JV_SCANNED != $JV_SKIPPED + $JV_CHECKED"
fi
if [ "$JV_CHECKED" -eq 0 ]; then
  echo "$TEST_NAME: NOTHING CHECKED — no tracked JSON discovered under $SCAN_ROOT" >&2
  _fail "the enumerator found at least one tracked JSON file" \
    "zero candidates — a broken enumerator, not a repo without JSON"
fi

RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (not-a-file=%d, unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$JV_SCANNED" "$JV_SKIPPED" "$JV_SKIP_NOT_A_FILE" "$JV_SKIP_UNREADABLE" \
  "$JV_CHECKED" "$JV_FINDINGS"
exit "$RC"
