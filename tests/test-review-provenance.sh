#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: review-provenance.sh — UNIFIED dispatch manifest lib
TEST_NAME="test-review-provenance"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/review-provenance.sh"

# Helper: write a reviewer file with frontmatter verdict + optional token
# Usage: write_reviewer TASK-001 code-reviewer APPROVE [token]
write_reviewer() {
  local unit="$1" name="$2" verdict="$3" token="${4:-}"
  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  if [ -n "$token" ]; then
    printf -- '---\nverdict: %s\nreview_token: %s\n---\nbody\n' "$verdict" "$token" \
      > "$TEST_DIR/nazgul/reviews/$unit/$name.md"
  else
    printf -- '---\nverdict: %s\n---\nbody\n' "$verdict" > "$TEST_DIR/nazgul/reviews/$unit/$name.md"
  fi
}

run_validate() {
  VAL_OUTPUT=$(validate_review_provenance "$TEST_DIR/nazgul" "$1") && VAL_EC=0 || VAL_EC=$?
}

# --- Test 1: write_dispatch_manifest — schema round-trip, defaults ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/diff.patch"
printf 'diff --git a b\n+hi\n' > "$DIFF"
TOKEN_OUT=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-006" "3" -- code-reviewer qa-reviewer)
WRITE_EC=$?
assert_exit_code "write manifest: exit 0" "$WRITE_EC" 0
MANIFEST="$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json"
assert_file_exists "manifest file written" "$MANIFEST"
assert_json_field "unit field" "$MANIFEST" ".unit" "TASK-001"
assert_json_field "feat_id field" "$MANIFEST" ".feat_id" "FEAT-006"
assert_json_field "iteration field is numeric" "$MANIFEST" ".iteration" "3"
assert_json_field "printed token matches manifest token" "$MANIFEST" ".token" "$TOKEN_OUT"
assert_json_field "reviewers[0].name" "$MANIFEST" ".reviewers[0].name" "code-reviewer"
assert_json_field "reviewers[1].name" "$MANIFEST" ".reviewers[1].name" "qa-reviewer"
assert_json_field "reviewers[0].resolved defaults false" "$MANIFEST" ".reviewers[0].resolved" "false"
assert_json_field "reviewers length" "$MANIFEST" ".reviewers | length" "2"
assert_json_field "selected defaults to full roster (0)" "$MANIFEST" ".selected[0]" "code-reviewer"
assert_json_field "selected defaults to full roster (1)" "$MANIFEST" ".selected[1]" "qa-reviewer"
assert_json_field "skipped defaults to empty array" "$MANIFEST" ".skipped | length" "0"
assert_file_contains "nonce field present" "$MANIFEST" '"nonce"'
teardown_temp_dir

# --- Test 2: reviewers[].resolved reflects .claude/agents/generated presence ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/.claude/agents/generated"
touch "$TEST_DIR/.claude/agents/generated/code-reviewer.md"
DIFF="$TEST_DIR/diff.patch"; printf 'x\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-002" "$DIFF" "FEAT-006" "1" -- code-reviewer qa-reviewer >/dev/null
MANIFEST="$TEST_DIR/nazgul/reviews/TASK-002/.dispatch.json"
assert_json_field "resolved true for generated agent" "$MANIFEST" ".reviewers[0].resolved" "true"
assert_json_field "resolved false for missing generated agent" "$MANIFEST" ".reviewers[1].resolved" "false"
teardown_temp_dir

# --- Test 3: --selected/--skipped round-trip; full roster kept in reviewers[] ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/diff.patch"; printf 'x\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-003" "$DIFF" "FEAT-006" "2" \
  --selected "code-reviewer" \
  --skipped "qa-reviewer:no tests changed;architect-reviewer:no config touched" \
  -- code-reviewer qa-reviewer architect-reviewer security-reviewer >/dev/null
MANIFEST="$TEST_DIR/nazgul/reviews/TASK-003/.dispatch.json"
assert_json_field "reviewers length is full roster" "$MANIFEST" ".reviewers | length" "4"
assert_json_field "selected length 1" "$MANIFEST" ".selected | length" "1"
assert_json_field "selected[0]" "$MANIFEST" ".selected[0]" "code-reviewer"
assert_json_field "skipped length 2" "$MANIFEST" ".skipped | length" "2"
assert_json_field "skipped[0].name" "$MANIFEST" ".skipped[0].name" "qa-reviewer"
assert_json_field "skipped[0].reason" "$MANIFEST" ".skipped[0].reason" "no tests changed"
assert_json_field "skipped[1].name" "$MANIFEST" ".skipped[1].name" "architect-reviewer"
teardown_temp_dir

# --- Test 4: diff absent -> empty-string sha256 ---
setup_temp_dir
setup_nazgul_dir
EMPTY_HASH=$(printf '' | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-004" "$TEST_DIR/nope.patch" "FEAT-006" "1" -- code-reviewer >/dev/null
MANIFEST="$TEST_DIR/nazgul/reviews/TASK-004/.dispatch.json"
assert_json_field "diff absent -> empty-string sha256" "$MANIFEST" ".diff_hash" "$EMPTY_HASH"
teardown_temp_dir

# --- Test 5: compute_review_token — deterministic, input-sensitive, 16 lowercase-hex chars ---
T1=$(compute_review_token "nonceA" "hashA" "TASK-001")
T2=$(compute_review_token "nonceA" "hashA" "TASK-001")
assert_eq "token deterministic for identical inputs" "$T1" "$T2"
T3=$(compute_review_token "nonceB" "hashA" "TASK-001")
if [ "$T1" = "$T3" ]; then
  _fail "token differs when nonce differs" "tokens matched unexpectedly: $T1"
else
  _pass "token differs when nonce differs"
fi
if [ "${#T1}" -eq 16 ]; then
  _pass "token is 16 chars"
else
  _fail "token is 16 chars" "got len ${#T1}: '$T1'"
fi
case "$T1" in
  *[!0-9a-f]*) _fail "token is lowercase hex" "got: '$T1'" ;;
  *) _pass "token is lowercase hex" ;;
esac

# --- Test 6: compute_review_token degrades to allow when no sha256 tool exists ---
# Absolute bash path: `PATH="" bash ...` would fail command-lookup on "bash" itself.
BASH_BIN=$(command -v bash)
DEGRADE_EC=0
DEGRADE_OUT=$(PATH="" "$BASH_BIN" -c "source '$REPO_ROOT/scripts/lib/review-provenance.sh'; compute_review_token n h TASK-001" 2>/dev/null) || DEGRADE_EC=$?
assert_exit_code "compute_review_token degrades to allow (no hash tool)" "$DEGRADE_EC" 1
assert_eq "compute_review_token degrades to allow: no output" "$DEGRADE_OUT" ""

# --- Test 7: write_dispatch_manifest degrades to allow when no sha256 tool exists ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/diff.patch"; printf 'x\n' > "$DIFF"
WD_EC=0
PATH="" "$BASH_BIN" -c "source '$REPO_ROOT/scripts/lib/review-provenance.sh'; write_dispatch_manifest '$TEST_DIR/nazgul' TASK-005 '$DIFF' FEAT-006 1 -- code-reviewer" \
  >/dev/null 2>&1 || WD_EC=$?
assert_exit_code "write_dispatch_manifest degrades to allow (no hash tool)" "$WD_EC" 1
assert_file_not_exists "no manifest written when hash tool missing" "$TEST_DIR/nazgul/reviews/TASK-005/.dispatch.json"
teardown_temp_dir

# --- validate_review_provenance ---

# --- Test 8: no reviewer files yet (empty dir) -> degrade to allow ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-010"
run_validate "TASK-010"
assert_exit_code "no reviewer files: exit 0" "$VAL_EC" 0
assert_eq "no reviewer files: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 9: review dir does not exist at all -> degrade to allow ---
setup_temp_dir
setup_nazgul_dir
run_validate "TASK-011"
assert_exit_code "no review dir at all: exit 0 (degrade)" "$VAL_EC" 0
teardown_temp_dir

# --- Test 10: meta-file-only dir (e.g. summary.md) -> degrade to allow ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-012"
printf 'summary text\n' > "$TEST_DIR/nazgul/reviews/TASK-012/summary.md"
run_validate "TASK-012"
assert_exit_code "meta-only dir: exit 0 (degrade)" "$VAL_EC" 0
teardown_temp_dir

# --- Test 11: legacy review — no manifest, no reviewer carries a token -> degrade to allow ---
setup_temp_dir
setup_nazgul_dir
write_reviewer "TASK-020" "code-reviewer" "APPROVE"
run_validate "TASK-020"
assert_exit_code "legacy no-token review: exit 0 (degrade)" "$VAL_EC" 0
teardown_temp_dir

# --- Test 12: reviewer carries a token but no manifest exists -> NO_DISPATCH_MANIFEST ---
setup_temp_dir
setup_nazgul_dir
write_reviewer "TASK-021" "code-reviewer" "APPROVE" "deadbeefdeadbeef"
run_validate "TASK-021"
assert_exit_code "token present, no manifest: exit 1" "$VAL_EC" 1
assert_contains "NO_DISPATCH_MANIFEST marker" "$VAL_OUTPUT" "NO_DISPATCH_MANIFEST"
teardown_temp_dir

# --- Test 13: valid manifest + matching stamped tokens -> exit 0 ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-030/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-030" "$DIFF" "FEAT-006" "1" -- code-reviewer qa-reviewer)
write_reviewer "TASK-030" "code-reviewer" "APPROVE" "$TOKEN"
write_reviewer "TASK-030" "qa-reviewer" "APPROVE" "$TOKEN"
run_validate "TASK-030"
assert_exit_code "valid provenance: exit 0" "$VAL_EC" 0
assert_eq "valid provenance: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 14: TOKEN_MISMATCH ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-031/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-031" "$DIFF" "FEAT-006" "1" -- code-reviewer >/dev/null
write_reviewer "TASK-031" "code-reviewer" "APPROVE" "0000000000000000"
run_validate "TASK-031"
assert_exit_code "token mismatch: exit 1" "$VAL_EC" 1
assert_contains "TOKEN_MISMATCH marker" "$VAL_OUTPUT" "TOKEN_MISMATCH code-reviewer"
teardown_temp_dir

# --- Test 15: TOKEN_MISSING ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-032/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-032" "$DIFF" "FEAT-006" "1" -- code-reviewer >/dev/null
write_reviewer "TASK-032" "code-reviewer" "APPROVE"
run_validate "TASK-032"
assert_exit_code "token missing: exit 1" "$VAL_EC" 1
assert_contains "TOKEN_MISSING marker" "$VAL_OUTPUT" "TOKEN_MISSING code-reviewer"
teardown_temp_dir

# --- Test 16: DIFF_HASH_STALE (diff mutated after dispatch) ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-033/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'original diff\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-033" "$DIFF" "FEAT-006" "1" -- code-reviewer)
write_reviewer "TASK-033" "code-reviewer" "APPROVE" "$TOKEN"
printf 'changed diff after review\n' > "$DIFF"
run_validate "TASK-033"
assert_exit_code "diff hash stale: exit 1" "$VAL_EC" 1
assert_contains "DIFF_HASH_STALE marker" "$VAL_OUTPUT" "DIFF_HASH_STALE"
teardown_temp_dir

# --- Test 17: skipped-stub exemption — SKIPPED reviewer stub with no token is not flagged ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-034/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-034" "$DIFF" "FEAT-006" "1" \
  --selected "code-reviewer" --skipped "qa-reviewer:no tests changed" \
  -- code-reviewer qa-reviewer)
write_reviewer "TASK-034" "code-reviewer" "APPROVE" "$TOKEN"
printf -- '---\nverdict: SKIPPED\n---\nskipped: no tests changed\n' > "$TEST_DIR/nazgul/reviews/TASK-034/qa-reviewer.md"
run_validate "TASK-034"
assert_exit_code "skipped stub exempt: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 18: opaque unit id — GROUP-N works identically to TASK-NNN ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/GROUP-1/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "GROUP-1" "$DIFF" "FEAT-006" "1" -- code-reviewer)
write_reviewer "GROUP-1" "code-reviewer" "APPROVE" "$TOKEN"
run_validate "GROUP-1"
assert_exit_code "opaque unit id GROUP-1: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 19: multiple problems reported together ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-041/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'orig\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-041" "$DIFF" "FEAT-006" "1" -- code-reviewer qa-reviewer >/dev/null
write_reviewer "TASK-041" "code-reviewer" "APPROVE"
printf 'mutated\n' > "$DIFF"
run_validate "TASK-041"
assert_exit_code "multi-problem: exit 1" "$VAL_EC" 1
assert_contains "multi: token missing" "$VAL_OUTPUT" "TOKEN_MISSING code-reviewer"
assert_contains "multi: diff stale" "$VAL_OUTPUT" "DIFF_HASH_STALE"
teardown_temp_dir

report_results
