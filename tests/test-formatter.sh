#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — formatter.sh always exits 0 (non-blocking), but
# several cases assert on its emitted status field instead.

# Test: scripts/formatter.sh — MF-030 file-path extraction order. Verifies
# `.tool_input.file_path` (the field every sibling guard uses, e.g.
# task-state-guard.sh:58) is queried FIRST, ahead of the historical aliases
# and the blind recursive fallback scan.
TEST_NAME="test-formatter"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

FORMATTER="$REPO_ROOT/scripts/formatter.sh"

# Runs formatter.sh with NAZGUL_FORMATTER_ENABLED=1 (bypass config lookup)
# and NAZGUL_FORMATTER_DEBUG=1, piping the given JSON payload on stdin.
# Captures both the emitted status field AND the debug "File: <path>" line
# (the only place the *resolved* absolute path is surfaced — the "no
# formatter" status message itself only names the extension, not the path).
run_formatter() {
  local payload="$1"
  FMT_OUTPUT=$(printf '%s' "$payload" | NAZGUL_FORMATTER_ENABLED=1 NAZGUL_FORMATTER_DEBUG=1 bash "$FORMATTER" 2>&1) \
    && FMT_EC=0 || FMT_EC=$?
  FMT_STATUS=$(printf '%s' "$FMT_OUTPUT" | tail -1 | jq -r '.hookSpecificOutput.status // empty' 2>/dev/null || true)
  FMT_MESSAGE=$(printf '%s' "$FMT_OUTPUT" | tail -1 | jq -r '.hookSpecificOutput.message // empty' 2>/dev/null || true)
  FMT_RESOLVED_FILE=$(printf '%s' "$FMT_OUTPUT" | grep -oE 'File: [^,]+' | head -1 | sed 's/^File: //')
}

# --- Test 1: MF-030 — .tool_input.file_path takes priority over a decoy
# absolute path found elsewhere in the payload (e.g. inside a diff/content
# field). The real target file exists and has no formatter installed for its
# extension (.xyzzy is not a recognized extension) -> "no_formatter", proving
# formatter.sh resolved to the CORRECT file rather than the decoy. ---
setup_temp_dir
REAL_FILE="$TEST_DIR/real-target.xyzzy"
DECOY_FILE="$TEST_DIR/decoy-should-not-be-picked.xyzzy"
printf 'real content\n' > "$REAL_FILE"
printf 'decoy content\n' > "$DECOY_FILE"
PAYLOAD=$(jq -n --arg real "$REAL_FILE" --arg decoy "$DECOY_FILE" \
  '{tool_input: {file_path: $real}, tool_response: {content: ("see also " + $decoy)}}')
run_formatter "$PAYLOAD"
assert_eq "MF-030: resolves .tool_input.file_path over decoy" "$FMT_STATUS" "no_formatter"
assert_eq "MF-030: resolved file is the real target, not the decoy" "$FMT_RESOLVED_FILE" "$REAL_FILE"
teardown_temp_dir

# --- Test 2: .tool_input.file_path wins even when a legacy alias
# (.tool_result.file_path) is also present and points elsewhere. ---
setup_temp_dir
REAL_FILE="$TEST_DIR/correct.xyzzy"
OTHER_FILE="$TEST_DIR/legacy-alias-target.xyzzy"
printf 'real\n' > "$REAL_FILE"
printf 'other\n' > "$OTHER_FILE"
PAYLOAD=$(jq -n --arg real "$REAL_FILE" --arg other "$OTHER_FILE" \
  '{tool_input: {file_path: $real}, tool_result: {file_path: $other}}')
run_formatter "$PAYLOAD"
assert_eq "MF-030: .tool_input.file_path outranks .tool_result.file_path" "$FMT_RESOLVED_FILE" "$REAL_FILE"
teardown_temp_dir

# --- Test 3: no .tool_input.file_path at all -> legacy alias fallback still
# works (no regression to the pre-existing alias chain). ---
setup_temp_dir
LEGACY_FILE="$TEST_DIR/legacy-only.xyzzy"
printf 'legacy\n' > "$LEGACY_FILE"
PAYLOAD=$(jq -n --arg f "$LEGACY_FILE" '{tool_result: {file_path: $f}}')
run_formatter "$PAYLOAD"
assert_eq "MF-030: falls back to .tool_result.file_path when .tool_input absent" "$FMT_RESOLVED_FILE" "$LEGACY_FILE"
teardown_temp_dir

# --- Test 4: no recognized field anywhere -> blind recursive scan fallback
# still finds an absolute-path-looking string (last resort, unchanged). ---
setup_temp_dir
SCAN_FILE="$TEST_DIR/scan-target.xyzzy"
printf 'x\n' > "$SCAN_FILE"
PAYLOAD=$(jq -n --arg f "$SCAN_FILE" '{some_nested: {blob: $f}}')
run_formatter "$PAYLOAD"
assert_eq "MF-030: recursive-scan fallback still finds a path" "$FMT_RESOLVED_FILE" "$SCAN_FILE"
teardown_temp_dir

# --- Test 5: bash -n / shellcheck sanity (project convention) ---
bash -n "$FORMATTER" 2>/dev/null && _pass "bash -n clean: formatter.sh" || _fail "bash -n clean: formatter.sh" "syntax error in $FORMATTER"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$FORMATTER" 2>/dev/null && _pass "shellcheck clean: formatter.sh" || _fail "shellcheck clean: formatter.sh" "shellcheck found issues in $FORMATTER"
else
  _pass "shellcheck clean: formatter.sh (shellcheck not installed, skipped)"
fi

report_results
