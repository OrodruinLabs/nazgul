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
NZ_DIGEST_PROBE=$(digest_string probe || true)
assert_eq "expected hashes: the shared digest helper returns a 64-hex digest, so no hash comparison here is vacuous" \
  "${#NZ_DIGEST_PROBE}" "64"
EMPTY_HASH=$(digest_string '')
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
T4=$(compute_review_token "nonceA" "hashB" "TASK-001")
if [ "$T1" = "$T4" ]; then
  _fail "token differs when diff_hash differs" "tokens matched unexpectedly: $T1"
else
  _pass "token differs when diff_hash differs"
fi
T5=$(compute_review_token "nonceA" "hashA" "TASK-002")
if [ "$T1" = "$T5" ]; then
  _fail "token differs when unit_id differs" "tokens matched unexpectedly: $T1"
else
  _pass "token differs when unit_id differs"
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
# A bare PATH="" would fail mkdir (the FIRST external call) before the hash step is
# ever reached, proving nothing about hash-tool degradation specifically. Build a
# minimal PATH with every OTHER external tool the function needs (mkdir, dirname,
# mktemp, mv, date, jq, and head/od/tr for the /dev/urandom nonce fallback) but
# WITHOUT sha256sum/shasum/openssl, so the failure is isolated to the hash step.
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/diff.patch"; printf 'x\n' > "$DIFF"
FAKEBIN="$TEST_DIR/fakebin"
mkdir -p "$FAKEBIN"
for tool in mkdir dirname mktemp mv rm date jq head od tr; do
  toolpath=$(command -v "$tool" 2>/dev/null) && ln -s "$toolpath" "$FAKEBIN/$tool"
done
WD_EC=0
PATH="$FAKEBIN" "$BASH_BIN" -c "source '$REPO_ROOT/scripts/lib/review-provenance.sh'; write_dispatch_manifest '$TEST_DIR/nazgul' TASK-005 '$DIFF' FEAT-006 1 -- code-reviewer" \
  >/dev/null 2>&1 || WD_EC=$?
assert_exit_code "write_dispatch_manifest degrades to allow (hash tool missing, scaffolding present)" "$WD_EC" 1
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

# --- FEAT-031/TASK-035: the same authored allowlist existed twice. Everything below pins the
# single shared classifier, both directions of the widening, and the §15 coverage line. ---

source "$REPO_ROOT/scripts/lib/review-evidence.sh"

setup_provenance_env() {
  setup_temp_dir
  setup_nazgul_dir
  local reviewers_json
  # shellcheck disable=SC2086 # intentional word-splitting on the space-separated seat list
  reviewers_json=$(printf '%s\n' $1 | jq -R . | jq -s .)
  create_config ".agents.reviewers = $reviewers_json"
}

run_validate_stderr() {
  VAL_STDERR=$(validate_review_provenance "$TEST_DIR/nazgul" "$1" 2>&1 >/dev/null) || true
}

# Replica of the live FEATURE-FEAT-031 dir at board 9 (47 .md): 4 seats on the current dispatch
# token, 24 archives on STALE ones — the archives produced 20 of the old classifier's 43 refusals.
build_provenance_census() {
  local unit="$1" dir="$TEST_DIR/nazgul/reviews/$1" b s
  mkdir -p "$dir"
  printf 'diff --git a b\n+live\n' > "$dir/diff.patch"
  CENSUS_TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "$unit" "$dir/diff.patch" "FEAT-031" "9" -- \
    architect-reviewer code-reviewer security-reviewer qa-reviewer)
  for s in architect-reviewer code-reviewer security-reviewer qa-reviewer; do
    printf -- '---\nverdict: APPROVE\nreview_token: %s\n---\nbody\n' "$CENSUS_TOKEN" > "$dir/$s.md"
  done
  for b in 3 4 5 6 7 8; do
    for s in architect code qa security; do
      printf -- '---\nverdict: CHANGES_REQUESTED\nreview_token: %s\n---\nboard %s archive\n' \
        "stale${b}0000000000" "$b" > "$dir/board${b}-${s}-reviewer.md"
    done
  done
  for b in 2-BRIEF 2-OUTCOME 3-BRIEF 3-OUTCOME 4-EVIDENCE 4-OUTCOME 5-EVIDENCE 5-OUTCOME \
           6-NAVIGATION 6-OUTCOME 7-NAVIGATION 7-OUTCOME 8-NAVIGATION 8-OUTCOME \
           9-NAVIGATION 9-OUTCOME; do
    printf '# BOARD-%s\n\nOrchestrator board document, no verdict.\n' "$b" > "$dir/BOARD-${b}.md"
  done
  for s in ARCH-G QA-1 SEC-1; do
    printf '# Adversarial cross-check — %s\n\nCONFIRM\n' "$s" > "$dir/adversarial-${s}.md"
  done
}

# --- Test 20 (AC1/AC2): the duplication is ELIMINATED, not re-copied. Derived from the tree,
# so a third hand-written copy anywhere under scripts/ turns this red wherever it lands. ---
CLASS_LIB_REL="scripts/lib/review-file-class.sh"
assert_file_exists "shared classifier lib is shipped" "$REPO_ROOT/$CLASS_LIB_REL"
FOUR_NAMES='test-failures.md|consolidated-feedback.md|simplify-report.md|summary.md'
assert_eq "the four-name meta literal survives in exactly one shipped script, the shared lib" \
  "$(grep -rlF "$FOUR_NAMES" "$REPO_ROOT/scripts" 2>/dev/null | sed "s|^$REPO_ROOT/||" | LC_ALL=C sort | tr '\n' ' ')" \
  "$CLASS_LIB_REL "
assert_eq "_rp_is_meta_file — the second copy TASK-034 could not reach — is gone entirely" \
  "$(grep -rl '_rp_is_meta_file' "$REPO_ROOT/scripts" "$REPO_ROOT/agents" 2>/dev/null | grep -c . || true)" "0"
CLASS_DEF_N=0
for fn in _is_review_meta_file _re_is_orchestrator_artifact _re_seat_suffixes _re_is_seat_shaped \
          _re_is_superseded_copy review_classify_unit_file; do
  CLASS_DEF_N=$((CLASS_DEF_N + 1))
  assert_eq "classifier '$fn' is defined exactly once, in the shared lib" \
    "$(grep -rlE "^${fn}\(\) \{" "$REPO_ROOT/scripts" 2>/dev/null | sed "s|^$REPO_ROOT/||" | LC_ALL=C sort | tr '\n' ' ')" \
    "$CLASS_LIB_REL "
done
assert_eq "single-authority scan: K>0 floor — the predicate list was actually walked" "$CLASS_DEF_N" "6"
for lib in review-evidence review-provenance; do
  assert_file_contains "$lib sources the shared classifier rather than carrying one" \
    "$REPO_ROOT/scripts/lib/$lib.sh" "review-file-class.sh"
done

# --- Test 21 (AC2, the invariant extraction BUYS): the provenance-subject set IS the verdict set,
# asserted on both validators' own §15 coverage lines — the finest partition either one states. ---
setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "TASK-001"
run_validate_stderr "TASK-001"
PROV_PARTITION=$(printf '%s\n' "$VAL_STDERR" | sed -n 's/^review-provenance\/subject-files: \([0-9].*\)$/\1/p' | head -1)
EVID_PARTITION=$(validate_review_evidence "$TEST_DIR/nazgul" "TASK-001" 2>&1 >/dev/null \
  | sed -n 's/^review-evidence\/verdict-files: \([0-9].*\)$/\1/p' | head -1)
assert_eq "subject set == verdict set: both validators report the same partition" \
  "$PROV_PARTITION" "$EVID_PARTITION"
assert_contains "and that partition is the real census shape" "$PROV_PARTITION" \
  "47 scanned, 43 skipped (artifact=3, non-seat=16, superseded=24), 4 checked"
# Dogfood the SHARING itself: one override moves BOTH validators. Two hand-written copies
# could not do that, which is what makes the assertion above a binding and not a coincidence.
SHARED_PROV=$(
  _re_is_orchestrator_artifact() { return 1; }
  validate_review_provenance "$TEST_DIR/nazgul" "TASK-001" 2>&1 >/dev/null \
    | sed -n 's/^review-provenance\/subject-files: \([0-9].*\)$/\1/p' | head -1
)
SHARED_EVID=$(
  _re_is_orchestrator_artifact() { return 1; }
  validate_review_evidence "$TEST_DIR/nazgul" "TASK-001" 2>&1 >/dev/null \
    | sed -n 's/^review-evidence\/verdict-files: \([0-9].*\)$/\1/p' | head -1
)
assert_eq "[mutation] one shared predicate moves both validators in lockstep" \
  "$SHARED_PROV" "$SHARED_EVID"
assert_contains "[mutation] and it really moved (artifact=0, the 3 adversarial files now read)" \
  "$SHARED_PROV" "artifact=0"
teardown_temp_dir

# --- Test 22 (AC3 direction A): an orchestrator artifact is NOT a provenance subject. This is
# the refusal board 9 hit — 43 problem lines against a directory with nothing wrong in it. ---
setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
run_validate "FEATURE-FEAT-031"
assert_exit_code "census: exit 0 — the board-9 refusal is gone" "$VAL_EC" 0
assert_eq "census: no output at all" "$VAL_OUTPUT" ""
assert_not_contains "census: adversarial artifact is not a provenance subject" "$VAL_OUTPUT" "adversarial-"
assert_not_contains "census: board document is not a provenance subject" "$VAL_OUTPUT" "BOARD-"
assert_not_contains "census: a stale per-board archive is not a provenance subject" "$VAL_OUTPUT" "board3-"
teardown_temp_dir

# --- Test 23 (AC3 direction B): the widening must not blunt the gate. Every planted/stale shape
# it exists to catch is still caught, by NAME, inside that same 47-file census. ---
setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
printf -- '---\nverdict: APPROVE\n---\nno token at all\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/qa-reviewer.md"
run_validate "FEATURE-FEAT-031"
assert_exit_code "roster seat with no token still fails" "$VAL_EC" 1
assert_eq "roster seat with no token: exactly one problem" "$(printf '%s\n' "$VAL_OUTPUT" | grep -c .)" "1"
assert_contains "roster seat with no token: named" "$VAL_OUTPUT" "TOKEN_MISSING qa-reviewer"
teardown_temp_dir

setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
printf -- '---\nverdict: APPROVE\nreview_token: 0000000000000000\n---\nplanted\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/security-reviewer.md"
run_validate "FEATURE-FEAT-031"
assert_exit_code "roster seat with a stale/planted token still fails" "$VAL_EC" 1
assert_eq "stale token: exactly one problem" "$(printf '%s\n' "$VAL_OUTPUT" | grep -c .)" "1"
assert_contains "stale token: named" "$VAL_OUTPUT" "TOKEN_MISMATCH security-reviewer"
teardown_temp_dir

setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
printf -- '---\nverdict: APPROVE\n---\nplanted seat, never dispatched\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/extra-reviewer.md"
run_validate "FEATURE-FEAT-031"
assert_exit_code "a planted NON-roster seat file is still a subject" "$VAL_EC" 1
assert_contains "planted non-roster seat: named" "$VAL_OUTPUT" "TOKEN_MISSING extra-reviewer"
teardown_temp_dir

setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
printf 'diff --git a b\n+MOVED after the board approved\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/diff.patch"
run_validate "FEATURE-FEAT-031"
assert_exit_code "diff moved under an approved census: still stale" "$VAL_EC" 1
assert_contains "diff moved: DIFF_HASH_STALE" "$VAL_OUTPUT" "DIFF_HASH_STALE"
teardown_temp_dir

# --- Test 24 (dogfood): the direction-B assertions are load-bearing. A swallow-everything
# classifier — the tempting "just widen the allowlist" fix — loses every one of them. ---
setup_provenance_env "architect-reviewer code-reviewer security-reviewer qa-reviewer"
build_provenance_census "FEATURE-FEAT-031"
printf -- '---\nverdict: APPROVE\nreview_token: 0000000000000000\n---\nplanted\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/extra-reviewer.md"
PERMISSIVE_OUT=$(
  _re_is_orchestrator_artifact() { return 0; }
  validate_review_provenance "$TEST_DIR/nazgul" "FEATURE-FEAT-031" 2>/dev/null
) || true
assert_not_contains "[mutation] swallow-everything loses the planted verdict" \
  "$PERMISSIVE_OUT" "TOKEN_MISMATCH extra-reviewer"
NARROW_OUT=$(
  _re_is_seat_shaped() { return 1; }
  validate_review_provenance "$TEST_DIR/nazgul" "FEATURE-FEAT-031" 2>/dev/null
) || true
assert_not_contains "[mutation] a never-seat-shaped classifier loses it too" \
  "$NARROW_OUT" "TOKEN_MISMATCH extra-reviewer"
run_validate "FEATURE-FEAT-031"
assert_contains "the shipped classifier keeps it" "$VAL_OUTPUT" "TOKEN_MISMATCH extra-reviewer"
# A ROSTER seat is answered `seat` before either predicate is consulted, so neither mutant can
# reclassify one — the archive/artifact widening can never reach a configured seat's own file.
printf -- '---\nverdict: APPROVE\nreview_token: 0000000000000000\n---\nplanted\n' \
  > "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-031/security-reviewer.md"
ROSTER_OUT=$(
  _re_is_orchestrator_artifact() { return 0; }
  _re_is_seat_shaped() { return 1; }
  _re_is_superseded_copy() { return 0; }
  validate_review_provenance "$TEST_DIR/nazgul" "FEATURE-FEAT-031" 2>/dev/null
) || true
assert_contains "[mutation] no classifier mutant can hide a configured seat's own file" \
  "$ROSTER_OUT" "TOKEN_MISMATCH security-reviewer"
teardown_temp_dir

# --- Test 25 (fail-closed): a roster that cannot be read gives no seat vocabulary to narrow BY.
# The derivation failing must widen what is CHECKED, never what is ignored. ---
setup_temp_dir
setup_nazgul_dir
DIFF="$TEST_DIR/nazgul/reviews/TASK-060/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff\n' > "$DIFF"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-060" "$DIFF" "FEAT-031" "1" -- code-reviewer >/dev/null
printf -- '---\nverdict: APPROVE\nreview_token: 0000000000000000\n---\nplanted\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-060/BOARD-9-OUTCOME.md"
run_validate "TASK-060"
run_validate_stderr "TASK-060"
assert_exit_code "no config.json: nothing is narrowed away, so the planted file is caught" "$VAL_EC" 1
assert_contains "no config.json: named" "$VAL_OUTPUT" "TOKEN_MISMATCH BOARD-9-OUTCOME"
assert_contains "no config.json: the empty seat vocabulary is reported, not hidden" \
  "$VAL_STDERR" "seat-suffixes=[]"
teardown_temp_dir

# --- Test 26 (AC5): the §15 coverage line, and the K>0 floor whose ambiguous case .dispatch.json
# decides — "no board has run here yet" vs "a board ran and the classifier read nothing". ---
setup_provenance_env "code-reviewer"
build_provenance_census "GROUP-2" >/dev/null
run_validate_stderr "GROUP-2"
FLOOR_LINE=$(printf '%s\n' "$VAL_STDERR" | sed -n 's/^\(review-provenance\/subject-files: [0-9].*findings\)$/\1/p' | head -1)
assert_contains "coverage line conforms to the §15 grammar" "$FLOOR_LINE" \
  "review-provenance/subject-files: 47 scanned, "
COV_N=$(printf '%s' "$FLOOR_LINE" | sed -E 's/^[^:]*: ([0-9]+) scanned.*/\1/')
COV_M=$(printf '%s' "$FLOOR_LINE" | sed -E 's/^.* ([0-9]+) skipped \(.*/\1/')
COV_K=$(printf '%s' "$FLOOR_LINE" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
assert_eq "coverage line: N == M + K" "$COV_N" "$((COV_M + COV_K))"
assert_eq "coverage line: K > 0 on a healthy directory" "$( [ "$COV_K" -gt 0 ] && echo yes || echo no )" "yes"
teardown_temp_dir

setup_provenance_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-070"
printf 'diff\n' > "$TEST_DIR/nazgul/reviews/TASK-070/diff.patch"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-070" "$TEST_DIR/nazgul/reviews/TASK-070/diff.patch" \
  "FEAT-031" "1" -- code-reviewer >/dev/null
printf '# BOARD-2-OUTCOME\n' > "$TEST_DIR/nazgul/reviews/TASK-070/BOARD-2-OUTCOME.md"
printf '# adversarial\n' > "$TEST_DIR/nazgul/reviews/TASK-070/adversarial-SEC-1.md"
run_validate "TASK-070"
run_validate_stderr "TASK-070"
assert_exit_code "floor: a dispatched board that read nothing blocks" "$VAL_EC" 1
assert_contains "floor: NOTHING_CHECKED reaches the caller, not just stderr" "$VAL_OUTPUT" "NOTHING_CHECKED"
assert_contains "floor: stderr says which state it was" "$VAL_STDERR" \
  "NOTHING CHECKED — all 2 candidate(s) skipped after a board was dispatched"
teardown_temp_dir

setup_provenance_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-071"
printf '# BOARD-2-OUTCOME\n' > "$TEST_DIR/nazgul/reviews/TASK-071/BOARD-2-OUTCOME.md"
printf '# adversarial\n' > "$TEST_DIR/nazgul/reviews/TASK-071/adversarial-SEC-1.md"
run_validate "TASK-071"
run_validate_stderr "TASK-071"
assert_exit_code "floor: the SAME directory with no dispatch manifest is pre-review, allowed" "$VAL_EC" 0
assert_eq "floor: and says nothing to the caller" "$VAL_OUTPUT" ""
assert_contains "floor: but names the state on stderr rather than going quiet" "$VAL_STDERR" \
  "nothing to check — all 2 candidate(s) skipped, no dispatch manifest (pre-review)"
teardown_temp_dir

# --- Test 28 (TASK-043, AC1): the shared prefix reaches the provenance validator's own
# output too — "one shape, not two" applies across both files, not just review-evidence.sh. ---
setup_provenance_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-070"
printf 'diff\n' > "$TEST_DIR/nazgul/reviews/TASK-070/diff.patch"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-070" "$TEST_DIR/nazgul/reviews/TASK-070/diff.patch" \
  "FEAT-031" "1" -- code-reviewer >/dev/null
printf '# BOARD-2-OUTCOME\n' > "$TEST_DIR/nazgul/reviews/TASK-070/BOARD-2-OUTCOME.md"
printf '# adversarial\n' > "$TEST_DIR/nazgul/reviews/TASK-070/adversarial-SEC-1.md"
run_validate "TASK-070"
assert_eq "prefix: output is EXACTLY the shared prefixed token" \
  "$VAL_OUTPUT" "VALIDATOR_DEFECT NOTHING_CHECKED"
teardown_temp_dir

# --- Test 29 (TASK-043, AC3): task-transition.sh's repair_provenance_valid (line 150) checks
# `[ -z "$problems" ]` on this exact call — pin that a defect-only unit still refuses it. ---
setup_provenance_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-072"
printf 'diff\n' > "$TEST_DIR/nazgul/reviews/TASK-072/diff.patch"
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-072" "$TEST_DIR/nazgul/reviews/TASK-072/diff.patch" \
  "FEAT-031" "1" -- code-reviewer >/dev/null
printf '# BOARD-2-OUTCOME\n' > "$TEST_DIR/nazgul/reviews/TASK-072/BOARD-2-OUTCOME.md"
run_validate "TASK-072"
assert_eq "AC3: repair_provenance_valid's own guard clause still trips" \
  "$( [ -z "$VAL_OUTPUT" ] && echo allowed || echo refused )" "refused"
teardown_temp_dir

# --- Test 27 (AC4): the real review directory of this checkout, asserted on NAMES and counts and
# on the rot-proof invariant: no orchestrator artifact is ever reported as a subject. ---
LIVE_COMMON=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
LIVE_NAZGUL=""
[ -n "$LIVE_COMMON" ] && LIVE_NAZGUL="$(dirname "$LIVE_COMMON")/nazgul"
if [ -n "$LIVE_NAZGUL" ] && [ -f "$LIVE_NAZGUL/config.json" ] && [ -d "$LIVE_NAZGUL/reviews" ]; then
  LIVE_SCANNED=0; LIVE_SKIPPED=0; LIVE_CHECKED=0; LIVE_FINDINGS=0; LIVE_BADNAMES=""
  for live_dir in "$LIVE_NAZGUL"/reviews/*/; do
    [ -d "$live_dir" ] || continue
    LIVE_SCANNED=$((LIVE_SCANNED + 1))
    if [ ! -f "$live_dir/.dispatch.json" ]; then
      LIVE_SKIPPED=$((LIVE_SKIPPED + 1)); continue
    fi
    LIVE_CHECKED=$((LIVE_CHECKED + 1))
    live_unit=$(basename "$live_dir")
    live_out=$(validate_review_provenance "$LIVE_NAZGUL" "$live_unit" 2>/dev/null) || true
    live_bad=$(printf '%s\n' "$live_out" | sed -n 's/^TOKEN_[A-Z]* //p' \
      | grep -E '^(adversarial-|BOARD-|board[0-9])' || true)
    if [ -n "$live_bad" ]; then
      LIVE_FINDINGS=$((LIVE_FINDINGS + 1))
      LIVE_BADNAMES="$LIVE_BADNAMES$(printf '%s' "$live_bad" | tr '\n' ' ')"
    fi
    echo "  live dir $live_unit: $(printf '%s\n' "$live_out" | grep -c '[^[:space:]]' || true) problem(s): $(printf '%s\n' "$live_out" | tr '\n' ' ')"
  done
  assert_eq "live dirs: no orchestrator artifact is reported as a provenance subject, by name" \
    "${LIVE_BADNAMES% }" ""
  if [ "$LIVE_CHECKED" -gt 0 ]; then
    _pass "live dirs: K>0 floor — $LIVE_CHECKED dispatched unit(s) actually validated"
  else
    _skip "live dirs: no unit carries a .dispatch.json in this checkout"
  fi
  echo "  live-review-dirs: ${LIVE_SCANNED} scanned, ${LIVE_SKIPPED} skipped (no-dispatch-manifest=${LIVE_SKIPPED}), ${LIVE_CHECKED} checked, ${LIVE_FINDINGS} findings"
else
  _skip "live dirs: no initialised nazgul/ in this checkout (task worktree or CI)"
fi

report_results
