#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-run-tests-harness"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

RUNNER="$REPO_ROOT/tests/run-tests.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-tests-harness-XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
cleanup() { chmod -R u+rwX "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# A sandbox is a private tests/ dir holding a copy of the runner under test plus
# trivial fake test files, so the harness never re-enters the real suite.
_mk_sandbox() {
  local dir="$TMP_ROOT/$1"; shift
  mkdir -p "$dir/tests"
  cp "$RUNNER" "$dir/tests/run-tests.sh"
  chmod +x "$dir/tests/run-tests.sh"
  local spec
  for spec in "$@"; do
    local fname="${spec%%:*}" code="${spec##*:}"
    printf '#!/usr/bin/env bash\necho "fake %s"\nexit %s\n' "$fname" "$code" > "$dir/tests/$fname"
    chmod +x "$dir/tests/$fname"
  done
  printf '%s' "$dir"
}

OUT=""; ERR=""; RC=0; LAST=""
_run() {
  local dir="$1"; shift
  OUT="$(bash "$dir/tests/run-tests.sh" "$@" 2>"$dir/stderr.txt" </dev/null)"
  RC=$?
  ERR="$(cat "$dir/stderr.txt")"
  LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
}

GRAMMAR='^run-tests: ([0-9]+) scanned, ([0-9]+) skipped \(filtered-out=([0-9]+), unreadable=([0-9]+)\), ([0-9]+) checked, ([0-9]+) findings$'

# Asserts the line parses AND that it accounts for itself: N == M + K, M == filtered-out + unreadable.
_assert_grammar() {
  local label="$1" line="$2"
  if [[ "$line" =~ $GRAMMAR ]]; then
    _pass "$label: coverage line conforms to the fixed grammar"
    local n="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" f="${BASH_REMATCH[3]}"
    local u="${BASH_REMATCH[4]}" k="${BASH_REMATCH[5]}"
    assert_eq "$label: N == M + K" "$n" "$((m + k))"
    assert_eq "$label: M == filtered-out + unreadable" "$m" "$((f + u))"
  else
    _fail "$label: coverage line conforms to the fixed grammar" "got: '$line'"
  fi
}

# --- Zero-match filter: the vacuous green this task exists to abolish ---
SB_ZERO="$(_mk_sandbox zero test-alpha.sh:0 test-beta.sh:0 test-gamma.sh:0)"
_run "$SB_ZERO" --filter=no-such-test-anywhere
RC_ZERO="$RC"
assert_eq "zero-match: exits 2 (not 0)" "$RC_ZERO" "2"
assert_contains "zero-match: NOTHING CHECKED on stderr" "$ERR" "run-tests: NOTHING CHECKED"
assert_contains "zero-match: names the filter that matched nothing" "$ERR" "no-such-test-anywhere"
assert_not_contains "zero-match: does NOT claim all tests passed" "$OUT" "All tests passed."
assert_eq "zero-match: coverage line accounts every candidate as filtered-out" "$LAST" \
  "run-tests: 3 scanned, 3 skipped (filtered-out=3, unreadable=0), 0 checked, 0 findings"
_assert_grammar "zero-match" "$LAST"

# --- All match, all pass ---
SB_ALL="$(_mk_sandbox allpass test-alpha.sh:0 test-beta.sh:0)"
_run "$SB_ALL"
assert_eq "all-match: exits 0" "$RC" "0"
assert_contains "all-match: reports success" "$OUT" "All tests passed."
assert_eq "all-match: coverage line" "$LAST" \
  "run-tests: 2 scanned, 0 skipped (filtered-out=0, unreadable=0), 2 checked, 0 findings"
_assert_grammar "all-match" "$LAST"

# --- All match, one real failure: exit 1, distinct from the zero-match code ---
SB_FAIL="$(_mk_sandbox withfail test-alpha.sh:0 test-beta.sh:0 test-gamma.sh:1)"
_run "$SB_FAIL"
RC_FAIL="$RC"
assert_eq "real-failure: exits 1" "$RC_FAIL" "1"
assert_not_contains "real-failure: does NOT claim all tests passed" "$OUT" "All tests passed."
assert_eq "real-failure: coverage line counts the finding" "$LAST" \
  "run-tests: 3 scanned, 0 skipped (filtered-out=0, unreadable=0), 3 checked, 1 findings"
if [ "$RC_ZERO" -ne "$RC_FAIL" ]; then
  _pass "zero-match exit code is distinct from the real-failure exit code"
else
  _fail "zero-match exit code is distinct from the real-failure exit code" "both were $RC_ZERO"
fi

# --- Partial filter ---
SB_PART="$(_mk_sandbox partial test-alpha.sh:0 test-beta.sh:0 test-gamma.sh:0)"
_run "$SB_PART" --filter=alpha
assert_eq "partial-filter: exits 0" "$RC" "0"
assert_eq "partial-filter: coverage line splits scanned into skipped + checked" "$LAST" \
  "run-tests: 3 scanned, 2 skipped (filtered-out=2, unreadable=0), 1 checked, 0 findings"
_assert_grammar "partial-filter" "$LAST"

# --- A leading dash is data, never a grep option ---
SB_DASH="$(_mk_sandbox dash-filter test-alpha.sh:0 test--n-case.sh:0)"
_run "$SB_DASH" --filter=-n
assert_eq "dash-filter: exits 0 rather than aborting grep" "$RC" "0"
assert_eq "dash-filter: treats the filter literally" "$LAST" \
  "run-tests: 2 scanned, 1 skipped (filtered-out=1, unreadable=0), 1 checked, 0 findings"
_assert_grammar "dash-filter" "$LAST"

# --- No test files discovered at all: a broken enumerator, not a clean repo ---
SB_EMPTY="$(_mk_sandbox empty)"
_run "$SB_EMPTY"
assert_eq "no-candidates: exits 2" "$RC" "2"
assert_contains "no-candidates: NOTHING CHECKED on stderr" "$ERR" "run-tests: NOTHING CHECKED"
assert_not_contains "no-candidates: does NOT claim all tests passed" "$OUT" "All tests passed."
assert_eq "no-candidates: coverage line is all zeros" "$LAST" \
  "run-tests: 0 scanned, 0 skipped (filtered-out=0, unreadable=0), 0 checked, 0 findings"

# --- Unreadable candidate is skipped under its own reason, never silently dropped ---
SB_UNREAD="$(_mk_sandbox unreadable test-alpha.sh:0 test-beta.sh:0 test-gamma.sh:0)"
rm -f "$SB_UNREAD/tests/test-beta.sh"
ln -s missing-test-target "$SB_UNREAD/tests/test-beta.sh"
_run "$SB_UNREAD"
assert_eq "unreadable: still exits 0 (nothing checked failed)" "$RC" "0"
assert_eq "unreadable: coverage line books it under the unreadable reason" "$LAST" \
  "run-tests: 3 scanned, 1 skipped (filtered-out=0, unreadable=1), 2 checked, 0 findings"
assert_contains "unreadable: names the skipped file" "$OUT" "test-beta.sh"
_assert_grammar "unreadable" "$LAST"

_run "$SB_UNREAD" --filter=beta
assert_eq "filtered unreadable: exits 2 because no matching candidate was checked" "$RC" "2"
assert_contains "filtered unreadable: diagnoses the matching non-regular candidate" "$ERR" \
  "matching candidates for filter 'beta' were unreadable or non-regular"
assert_not_contains "filtered unreadable: does not claim the filter matched nothing" "$ERR" \
  "no test files matched filter"
assert_eq "filtered unreadable: coverage line distinguishes filtering from unreadability" "$LAST" \
  "run-tests: 3 scanned, 3 skipped (filtered-out=2, unreadable=1), 0 checked, 0 findings"
_assert_grammar "filtered unreadable" "$LAST"

# --- The N == M + K self-assertion actually fires (mutated runner) ---
SB_MUT="$(_mk_sandbox mutant test-alpha.sh:0 test-beta.sh:0 test-gamma.sh:0)"
sed 's/CHECKED + 1/CHECKED + 2/' "$RUNNER" > "$SB_MUT/tests/run-tests.sh"
chmod +x "$SB_MUT/tests/run-tests.sh"
if grep -q "CHECKED + 2" "$SB_MUT/tests/run-tests.sh"; then
  _pass "self-assertion: mutation applied to the runner copy"
  _run "$SB_MUT"
  assert_eq "self-assertion: accounting mismatch exits 3" "$RC" "3"
  assert_contains "self-assertion: mismatch announced on stderr" "$ERR" "coverage accounting mismatch"
  assert_not_contains "self-assertion: does NOT claim all tests passed" "$OUT" "All tests passed."
  if [[ "$LAST" =~ $GRAMMAR ]]; then
    _pass "self-assertion: coverage line is still emitted with the honest numbers"
  else
    _fail "self-assertion: coverage line is still emitted with the honest numbers" "got: '$LAST'"
  fi
else
  _fail "self-assertion: mutation applied to the runner copy" "sed matched nothing — the test would be vacuous"
fi

# FEAT-031/TASK-046: a test file that drains stdin must not inherit the harness's
# own — measured by elapsed drain against a pipe deliberately held open.
STDIN_HOLD_SECONDS=3
SB_STDIN="$TMP_ROOT/stdin"
mkdir -p "$SB_STDIN/tests"
cp "$RUNNER" "$SB_STDIN/tests/run-tests.sh"
chmod +x "$SB_STDIN/tests/run-tests.sh"
cat > "$SB_STDIN/tests/test-stdin-drain.sh" <<'DRAIN'
#!/usr/bin/env bash
echo "=== test-stdin-drain ==="
_started=$(date +%s)
cat >/dev/null 2>&1 || true
echo "  drain-seconds=$(( $(date +%s) - _started ))"
echo "  PASS: stdin drained"
exit 0
DRAIN
chmod +x "$SB_STDIN/tests/test-stdin-drain.sh"

_drain_seconds() { printf '%s\n' "$1" | sed -n 's/.*drain-seconds=//p' | head -1; }

# Control first: the probe can turn red. Handed the same open pipe with no
# redirect in front of it, the very same file blocks for the whole hold.
CTL_OUT=$( { sleep "$STDIN_HOLD_SECONDS"; } | bash "$SB_STDIN/tests/test-stdin-drain.sh" 2>&1 )
CTL_DRAIN=$(_drain_seconds "$CTL_OUT")
if [ -n "$CTL_DRAIN" ] && [ "$CTL_DRAIN" -ge 2 ]; then
  _pass "stdin: the probe detects an inherited open pipe (control drained ${CTL_DRAIN}s)"
else
  _fail "stdin: the probe detects an inherited open pipe" "control drain-seconds='${CTL_DRAIN}' — the probe cannot turn red, so the assertion below is vacuous"
fi

RUN_OUT=$( { sleep "$STDIN_HOLD_SECONDS"; } | bash "$SB_STDIN/tests/run-tests.sh" --filter=stdin-drain 2>&1 )
RUN_DRAIN=$(_drain_seconds "$RUN_OUT")
if [ -n "$RUN_DRAIN" ] && [ "$RUN_DRAIN" -le 1 ]; then
  _pass "stdin: the runner hands each test file a stdin already at EOF (drained ${RUN_DRAIN}s)"
else
  _fail "stdin: the runner hands each test file a stdin already at EOF" "drain-seconds='${RUN_DRAIN}' — the test file inherited the harness's open stdin"
fi
assert_contains "stdin: the drain probe still ran" "$RUN_OUT" "PASS: stdin drained"

report_results
exit $?
