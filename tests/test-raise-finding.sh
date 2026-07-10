#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — raise-finding.sh is a sourced helper, not a standalone script

# Test: scripts/lib/raise-finding.sh — raise_finding producer helper (FEAT-009 TASK-009)
TEST_NAME="test-raise-finding"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/raise-finding.sh"

line_n() {
  sed -n "${2}p" "$1"
}

# --- Test 1: append produces one well-formed JSON line ---
setup_temp_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
unset NAZGUL_AGENT NAZGUL_UNIT

raise_finding "high" "process" "Test title" "Test detail" "apply the fix" "saw it in the log"

FINDINGS_FILE="$NAZGUL_DIR/logs/findings.jsonl"
assert_file_exists "test 1: findings.jsonl created" "$FINDINGS_FILE"
assert_eq "test 1: exactly one line" "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" "1"
assert_json_field "test 1: severity" "$FINDINGS_FILE" '.severity' "high"
assert_json_field "test 1: category" "$FINDINGS_FILE" '.category' "process"
assert_json_field "test 1: title" "$FINDINGS_FILE" '.title' "Test title"
assert_json_field "test 1: detail" "$FINDINGS_FILE" '.detail' "Test detail"
assert_json_field "test 1: suggested_fix" "$FINDINGS_FILE" '.suggested_fix' "apply the fix"
assert_json_field "test 1: evidence" "$FINDINGS_FILE" '.evidence' "saw it in the log"
assert_eq "test 1: ts is non-empty ISO-8601" \
  "$(jq -r '.ts' "$FINDINGS_FILE" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"

teardown_temp_dir

# --- Test 2: append-only across two calls ---
setup_temp_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
unset NAZGUL_AGENT NAZGUL_UNIT

raise_finding "medium" "qa" "First finding" "first detail"
FINDINGS_FILE="$NAZGUL_DIR/logs/findings.jsonl"
FIRST_LINE_BEFORE=$(line_n "$FINDINGS_FILE" 1)

raise_finding "low" "docs" "Second finding" "second detail"

assert_eq "test 2: two lines after second call" "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" "2"
assert_eq "test 2: first line byte-for-byte unchanged" "$(line_n "$FINDINGS_FILE" 1)" "$FIRST_LINE_BEFORE"
assert_eq "test 2: second line has the new title" "$(line_n "$FINDINGS_FILE" 2 | jq -r '.title')" "Second finding"

teardown_temp_dir

# --- Test 3: metacharacter-laden title — no eval/execution, newlines neutralized ---
setup_temp_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
unset NAZGUL_AGENT NAZGUL_UNIT

MARKER="$TEST_DIR/pwned"
EVIL_TITLE='Title with `touch '"$MARKER"'` and $(touch '"$MARKER"') and "quotes"
and an embedded
newline'

raise_finding "low" "test" "$EVIL_TITLE" "detail"

FINDINGS_FILE="$NAZGUL_DIR/logs/findings.jsonl"
assert_file_not_exists "test 3: metacharacters never executed" "$MARKER"
assert_eq "test 3: still exactly one JSONL line (newline neutralized, not split)" \
  "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" "1"
STORED_TITLE=$(jq -r '.title' "$FINDINGS_FILE")
assert_contains "test 3: literal backtick/subshell text preserved as data" "$STORED_TITLE" 'touch'
assert_eq "test 3: no raw newline in stored title" "$(printf '%s' "$STORED_TITLE" | wc -l | tr -d ' ')" "0"

teardown_temp_dir

# --- Test 4: missing optional args default to empty ---
setup_temp_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
unset NAZGUL_AGENT NAZGUL_UNIT

raise_finding "medium" "cat" "no optional args" "detail only"

FINDINGS_FILE="$NAZGUL_DIR/logs/findings.jsonl"
assert_json_field "test 4: suggested_fix defaults empty" "$FINDINGS_FILE" '.suggested_fix' ""
assert_json_field "test 4: evidence defaults empty" "$FINDINGS_FILE" '.evidence' ""

teardown_temp_dir

# --- Test 5: NAZGUL_AGENT / NAZGUL_UNIT populate when set, empty when unset ---
setup_temp_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
unset NAZGUL_AGENT NAZGUL_UNIT

raise_finding "low" "cat" "unset env" "detail"
FINDINGS_FILE="$NAZGUL_DIR/logs/findings.jsonl"
assert_json_field "test 5: agent empty when unset" "$FINDINGS_FILE" '.agent' ""
assert_json_field "test 5: unit empty when unset" "$FINDINGS_FILE" '.unit' ""

export NAZGUL_AGENT="implementer"
export NAZGUL_UNIT="TASK-009"
raise_finding "low" "cat" "set env" "detail"
assert_eq "test 5: agent populated when set" "$(line_n "$FINDINGS_FILE" 2 | jq -r '.agent')" "implementer"
assert_eq "test 5: unit populated when set" "$(line_n "$FINDINGS_FILE" 2 | jq -r '.unit')" "TASK-009"

unset NAZGUL_AGENT NAZGUL_UNIT
teardown_temp_dir

# --- Test 6: best-effort — an unwritable NAZGUL_DIR must NOT abort a `set -e` caller ---
# raise_finding is sourced into arbitrary sub-session shells; an environmental
# failure (here: logs parent is a regular FILE, so mkdir -p fails for any user)
# must degrade to a logged no-op and return 0, never propagate under set -e.
setup_temp_dir
printf 'i am a file\n' > "$TEST_DIR/blk"   # blocks mkdir -p "$TEST_DIR/blk/nazgul/logs"
T6_OUT=$(NAZGUL_DIR="$TEST_DIR/blk/nazgul" bash -c '
  set -euo pipefail
  source "'"$REPO_ROOT"'/scripts/lib/raise-finding.sh"
  raise_finding high process "T6 title" "T6 detail"
  echo "CALLER-SURVIVED"
' 2>&1)
T6_EC=$?
assert_eq "test 6: unwritable NAZGUL_DIR does not abort a set -e caller" "$T6_EC" "0"
assert_contains "test 6: caller continued past raise_finding" "$T6_OUT" "CALLER-SURVIVED"
assert_contains "test 6: logged the skip" "$T6_OUT" "finding NOT recorded"
assert_file_not_exists "test 6: no findings file at the blocked path" "$TEST_DIR/blk/nazgul/logs/findings.jsonl"
teardown_temp_dir

report_results
