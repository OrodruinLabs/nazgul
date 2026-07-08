#!/usr/bin/env bash
set -euo pipefail

# Test: scrub-stale-review-artifacts.sh archives+clears stale reviews/learning,
# is idempotent, no-ops on empty state, and protects an active objective.
TEST_NAME="test-scrub-stale-review-artifacts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCRUB="$REPO_ROOT/scripts/scrub-stale-review-artifacts.sh"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_nazgul_dir() {
  local test_name="$1"
  local dir="$TMPDIR_BASE/$test_name/nazgul"
  mkdir -p "$dir/reviews" "$dir/learning" "$dir/logs" "$dir/tasks"
  echo "$dir"
}

# --- Test 1: stale reviews + learning artifacts → archived and cleared ---
NAZGUL_DIR=$(setup_nazgul_dir "stale")
mkdir -p "$NAZGUL_DIR/reviews/TASK-001"
echo "verdict: CHANGES_REQUESTED" > "$NAZGUL_DIR/reviews/TASK-001/consolidated-feedback.md"
echo "# Proposed Learned Rules" > "$NAZGUL_DIR/learning/proposed-rules.md"
echo "FEAT-001" > "$NAZGUL_DIR/learning/.distilled"
echo "marker" > "$NAZGUL_DIR/logs/.docs-verified"

OUTPUT=$("$SCRUB" --for-new-objective FEAT-002 "$NAZGUL_DIR")
assert_contains "stale run reports archive" "$OUTPUT" "archived stale artifacts"
assert_file_not_exists "reviews content cleared" "$NAZGUL_DIR/reviews/TASK-001/consolidated-feedback.md"
assert_file_not_exists "proposed-rules.md cleared" "$NAZGUL_DIR/learning/proposed-rules.md"
assert_file_not_exists ".distilled cleared" "$NAZGUL_DIR/learning/.distilled"
assert_file_not_exists ".docs-verified cleared" "$NAZGUL_DIR/logs/.docs-verified"

ARCHIVE_DIR=$(find "$NAZGUL_DIR/archive" -maxdepth 1 -mindepth 1 -type d | head -1)
assert_file_exists "reviews archived" "$ARCHIVE_DIR/reviews/TASK-001/consolidated-feedback.md"
assert_file_exists "proposed-rules.md archived" "$ARCHIVE_DIR/learning/proposed-rules.md"
assert_file_exists ".distilled archived" "$ARCHIVE_DIR/learning/.distilled"
assert_file_exists ".docs-verified archived" "$ARCHIVE_DIR/logs/.docs-verified"

if [ -d "$NAZGUL_DIR/reviews" ]; then
  _pass "reviews dir recreated empty"
else
  _fail "reviews dir recreated empty" "directory missing: $NAZGUL_DIR/reviews"
fi

# --- Test 2: idempotent — second run on same dir is a clean no-op ---
OUTPUT2=$("$SCRUB" --for-new-objective FEAT-002 "$NAZGUL_DIR")
assert_contains "second run no-ops" "$OUTPUT2" "nothing stale to scrub"
ARCHIVE_COUNT=$(find "$NAZGUL_DIR/archive" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
assert_eq "idempotent — no duplicate archive dir" "$ARCHIVE_COUNT" "1"

# --- Test 3: empty state → clean no-op, nothing archived ---
NAZGUL_DIR=$(setup_nazgul_dir "empty")
OUTPUT3=$("$SCRUB" --for-new-objective FEAT-003 "$NAZGUL_DIR")
assert_contains "empty state no-ops" "$OUTPUT3" "nothing stale to scrub"
assert_dir_not_exists "no archive dir created" "$NAZGUL_DIR/archive"

# --- Test 4: active objective with an open task → refuses to scrub, for each open status ---
for open_status in READY IN_PROGRESS IN_REVIEW IMPLEMENTED CHANGES_REQUESTED; do
  NAZGUL_DIR=$(setup_nazgul_dir "active-$open_status")
  mkdir -p "$NAZGUL_DIR/reviews/TASK-001"
  echo "junk" > "$NAZGUL_DIR/reviews/TASK-001/consolidated-feedback.md"
  cat > "$NAZGUL_DIR/tasks/TASK-001.md" << EOF
---
status: $open_status
---
# TASK-001
EOF
  OUTPUT4=$("$SCRUB" --for-new-objective FEAT-004 "$NAZGUL_DIR" 2>&1)
  assert_contains "active objective ($open_status) refuses scrub" "$OUTPUT4" "refusing"
  assert_file_exists "active reviews left untouched ($open_status)" "$NAZGUL_DIR/reviews/TASK-001/consolidated-feedback.md"
  assert_dir_not_exists "no archive dir created ($open_status)" "$NAZGUL_DIR/archive"
done

# --- Test 4b: nonexistent nazgul_dir → clean exit 0, no archive ---
NONEXISTENT_DIR="$TMPDIR_BASE/does-not-exist/nazgul"
set +e
OUTPUT4B=$("$SCRUB" --for-new-objective FEAT-004B "$NONEXISTENT_DIR" 2>&1)
EXIT_CODE_4B=$?
set -e
assert_exit_code "nonexistent nazgul_dir exits 0" "$EXIT_CODE_4B" "0"
assert_eq "nonexistent nazgul_dir: no output" "$OUTPUT4B" ""
assert_dir_not_exists "nonexistent nazgul_dir: no archive created" "$NONEXISTENT_DIR/archive"

# --- Test 4c: FOR_FEAT_ID with path traversal → rejected ---
NAZGUL_DIR=$(setup_nazgul_dir "traversal")
set +e
OUTPUT4C=$("$SCRUB" --for-new-objective "../evil" "$NAZGUL_DIR" 2>&1)
EXIT_CODE_4C=$?
set -e
assert_exit_code "path-traversal feat_id rejected" "$EXIT_CODE_4C" "1"
assert_contains "path-traversal feat_id error message" "$OUTPUT4C" "invalid"

# --- Test 5: missing --for-new-objective → usage error ---
NAZGUL_DIR=$(setup_nazgul_dir "no-flag")
USAGE_OUT="$TMPDIR_BASE/scrub-usage-out.txt"
set +e
"$SCRUB" "$NAZGUL_DIR" >"$USAGE_OUT" 2>&1
EXIT_CODE=$?
set -e
assert_exit_code "missing flag exits non-zero" "$EXIT_CODE" "1"
assert_contains "missing flag prints usage" "$(cat "$USAGE_OUT")" "Usage:"

report_results
