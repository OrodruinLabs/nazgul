#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — the script under test exits non-zero on its hard failures.

# Test: scripts/red-run.sh (FEAT-028/TASK-003, PRD AC3, TRD §2). Every case runs
# against a REAL scratch git repo with real commits, a real detached worktree and
# a real copy of this repo's own tests/run-tests.sh — so the exit codes asserted
# here are the harness's own, not a stub's. This repo's tree is never touched.
TEST_NAME="test-red-run-script"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

RED_RUN="$REPO_ROOT/scripts/red-run.sh"

# Scratch project: BASE has tests/run-tests.sh only; HEAD adds scripts/feature.sh
# plus three test files — test-alpha (red at BASE, green at HEAD), test-beta
# (green at BASE: the vacuity case) and test-gamma (a second red file, for the
# multi-entry entry-per-failed-file assertion).
setup_project() {
  setup_temp_dir
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/tests" "$TEST_DIR/scripts" "$TEST_DIR/nazgul/tasks"
  cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/tests/run-tests.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "base"
  BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

  printf '#!/usr/bin/env bash\necho feature\n' > "$TEST_DIR/scripts/feature.sh"
  cat > "$TEST_DIR/tests/test-alpha.sh" <<'ALPHA'
#!/usr/bin/env bash
set -uo pipefail
echo "=== test-alpha ==="
if [ -f "$(cd "$(dirname "$0")/.." && pwd)/scripts/feature.sh" ]; then
  echo "  PASS: feature.sh is wired in"
  exit 0
fi
echo "  FAIL: feature.sh is wired in"
exit 1
ALPHA
  cat > "$TEST_DIR/tests/test-beta.sh" <<'BETA'
#!/usr/bin/env bash
set -uo pipefail
echo "=== test-beta ==="
echo "  PASS: two plus two is four"
exit 0
BETA
  cat > "$TEST_DIR/tests/test-gamma.sh" <<'GAMMA'
#!/usr/bin/env bash
set -uo pipefail
echo "=== test-gamma ==="
if [ -f "$(cd "$(dirname "$0")/.." && pwd)/scripts/feature.sh" ]; then
  echo "  PASS: feature.sh is readable"
  exit 0
fi
echo "  FAIL: feature.sh is readable"
exit 1
GAMMA
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "the task's work"
  HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
}

# Manifest carrying a Base SHA, a Commits SHA, and the given ## Red-Run Evidence
# body — empty $3 means the section is omitted entirely (the append case).
write_manifest() {
  local id="$1" base="$2" evidence="${3:-}"
  {
    printf -- '---\nstatus: IN_PROGRESS\n---\n# %s: scratch task\n\n' "$id"
    printf -- '## Metadata\n- **ID**: %s\n- **Files modified**: ["scripts/feature.sh", "tests/test-alpha.sh"]\n- **Base SHA**: %s\n\n' "$id" "$base"
    printf -- '## Commits\n%s\n\n' "$HEAD_SHA"
    if [ -n "$evidence" ]; then
      printf -- '## Red-Run Evidence\n%s\n\n' "$evidence"
    fi
    printf -- '## Test Obligation\n- **Scoped filter**: `tests/run-tests.sh --filter=gamma`\n\n'
    printf -- '## Implementation Log\n- nothing yet\n'
  } > "$TEST_DIR/nazgul/tasks/${id}.md"
}

run_capture() {
  RR_OUT=$(bash "$RED_RUN" "$@" --project-root="$TEST_DIR" 2>&1)
  RR_EC=$?
}

worktree_count() {
  git -C "$TEST_DIR" worktree list 2>/dev/null | wc -l | tr -d ' '
}

# --- happy path: end-to-end capture over a real scratch repo -----------------
setup_project
write_manifest TASK-001 "$BASE_SHA"
MANIFEST="$TEST_DIR/nazgul/tasks/TASK-001.md"
run_capture TASK-001 --filter=alpha

assert_exit_code "happy path: exits 0 when the pre-change run is red" "$RR_EC" 0
assert_contains "happy path: reports RED confirmed" "$RR_OUT" "RED confirmed for TASK-001"
assert_file_contains "happy path: writes a ## Red-Run Evidence section" "$MANIFEST" '^## Red-Run Evidence'
assert_file_contains "happy path: entry names the failing test file" "$MANIFEST" 'red-run: tests/test-alpha.sh'
assert_file_contains "happy path: entry carries the failing case name" "$MANIFEST" 'case "feature.sh is wired in"'
assert_file_contains "happy path: pre-change-ref is the manifest Base SHA" "$MANIFEST" "pre-change-ref: $BASE_SHA"
assert_file_contains "happy path: result records a non-zero exit" "$MANIFEST" 'result: FAILED (exit 1)'
assert_file_contains "happy path: provenance is the capturer, not a human" "$MANIFEST" 'captured-by: scripts/red-run.sh at 20'
assert_file_contains "happy path: records the scoped filter it ran" "$MANIFEST" 'run-tests.sh --filter=alpha'
assert_file_not_contains "happy path: never claims manual provenance" "$MANIFEST" 'manual-bootstrap'

CAPTURED_AT=$(grep -o 'captured-by: scripts/red-run.sh at [0-9TZ:-]*' "$MANIFEST" | head -1)
assert_contains "happy path: captured-at is ISO-8601 UTC" "$CAPTURED_AT" "Z"

# --- the live tree is never touched -----------------------------------------
assert_eq "worktree: the scratch worktree is removed (only the main tree remains)" "$(worktree_count)" "1"
assert_eq "live tree: HEAD is unchanged" "$(git -C "$TEST_DIR" rev-parse HEAD)" "$HEAD_SHA"
assert_eq "live tree: nothing was stashed" \
  "$(git -C "$TEST_DIR" stash list | wc -l | tr -d ' ')" "0"
assert_eq "live tree: no tracked file was modified" \
  "$(git -C "$TEST_DIR" status --porcelain -- tests scripts | wc -l | tr -d ' ')" "0"
assert_file_exists "live tree: the post-change source is still present" "$TEST_DIR/scripts/feature.sh"

# --- the emitted block satisfies the shipped gate ----------------------------
# The seam this task exists to close: red-run.sh is the producer,
# ttg_verify_red_run_evidence is the consumer. Asserted against the real gate.
NAZGUL_DIR="$TEST_DIR/nazgul"
# shellcheck source=../scripts/lib/task-transition-guard.sh
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
GATE_ERR=$(mktemp "${TMPDIR:-/tmp}/nazgul-rr-gate-XXXXXX")
if ttg_verify_red_run_evidence "$(cat "$MANIFEST")" "$TEST_DIR" TASK-001 2>"$GATE_ERR" >/dev/null; then
  GATE_EC=0
else
  GATE_EC=$?
fi
GATE_REASON="${TTG_RED_RUN_REASON:-<unset>}"
assert_exit_code "seam: the shipped gate ACCEPTS a red-run.sh-written block" "$GATE_EC" 0
assert_eq "seam: the gate's disposition is 'verified', not a degraded allow" "$GATE_REASON" "verified"
rm -f "$GATE_ERR"

# --- refresh in place: a second capture does not duplicate the entry ---------
run_capture TASK-001 --filter=alpha
assert_exit_code "refresh: a second capture still exits 0" "$RR_EC" 0
assert_eq "refresh: exactly one red-run entry after re-capture" \
  "$(grep -c '^- red-run:' "$MANIFEST")" "1"
assert_eq "refresh: exactly one generated block after re-capture" \
  "$(grep -c 'red-run.sh:begin' "$MANIFEST")" "1"
assert_eq "refresh: exactly one ## Red-Run Evidence heading" \
  "$(grep -c '^## Red-Run Evidence' "$MANIFEST")" "1"
assert_file_contains "refresh: the rest of the manifest survives" "$MANIFEST" '^## Implementation Log'

# --- pre-existing section body is preserved, generated block goes first ------
write_manifest TASK-002 "$BASE_SHA" \
  '<!-- keep me: the hand-written history of an earlier capture -->
- (superseded) manual note from the bootstrap capture'
MANIFEST2="$TEST_DIR/nazgul/tasks/TASK-002.md"
run_capture TASK-002 --filter=alpha
assert_exit_code "preserve: capture into an existing section exits 0" "$RR_EC" 0
assert_file_contains "preserve: the pre-existing body is still there" "$MANIFEST2" 'keep me: the hand-written history'
assert_file_contains "preserve: the pre-existing note is still there" "$MANIFEST2" '(superseded) manual note'
FIRST_BODY_LINE=$(awk '/^## Red-Run Evidence/{getline; print; exit}' "$MANIFEST2")
assert_contains "preserve: the generated block is inserted first, above the history" \
  "$FIRST_BODY_LINE" "red-run.sh:begin"

# --- VACUOUS: a test that passes against the pre-change tree -----------------
write_manifest TASK-003 "$BASE_SHA"
MANIFEST3="$TEST_DIR/nazgul/tasks/TASK-003.md"
run_capture TASK-003 --filter=beta
assert_exit_code "vacuous: exits 2 when the pre-change run PASSES" "$RR_EC" 2
assert_contains "vacuous: says the test is vacuous, loudly" "$RR_OUT" "VACUOUS TEST"
assert_contains "vacuous: names the passing pre-change run" "$RR_OUT" "exited 0 against the tree at $BASE_SHA"
assert_contains "vacuous: says no evidence was written" "$RR_OUT" "No evidence block was written."
assert_file_not_contains "vacuous: writes NO evidence block" "$MANIFEST3" '## Red-Run Evidence'
assert_eq "vacuous: the scratch worktree is still removed" "$(worktree_count)" "1"

# --- NOTHING MATCHED: a filter that matches no test file --------------------
write_manifest TASK-004 "$BASE_SHA"
MANIFEST4="$TEST_DIR/nazgul/tasks/TASK-004.md"
run_capture TASK-004 --filter=no-such-test
assert_exit_code "zero-match: exits 3, distinct from the vacuous exit 2" "$RR_EC" 3
assert_contains "zero-match: says nothing was checked" "$RR_OUT" "NOTHING CHECKED"
assert_contains "zero-match: names the filter that matched nothing" "$RR_OUT" \
  "the scoped filter matched no test files in the pre-change tree"
assert_not_contains "zero-match: is NOT reported as a vacuous test" "$RR_OUT" "VACUOUS TEST"
assert_file_not_contains "zero-match: writes NO evidence block" "$MANIFEST4" '## Red-Run Evidence'
assert_eq "zero-match: the scratch worktree is still removed" "$(worktree_count)" "1"

# --- one entry per failing test file ----------------------------------------
write_manifest TASK-005 "$BASE_SHA"
MANIFEST5="$TEST_DIR/nazgul/tasks/TASK-005.md"
run_capture TASK-005 --filter=test-
assert_exit_code "multi: a filter spanning three files still red-runs" "$RR_EC" 0
assert_eq "multi: one entry per FAILED file, not per file run" \
  "$(grep -c '^- red-run:' "$MANIFEST5")" "2"
assert_file_contains "multi: alpha is recorded" "$MANIFEST5" 'red-run: tests/test-alpha.sh'
assert_file_contains "multi: gamma is recorded" "$MANIFEST5" 'red-run: tests/test-gamma.sh'
assert_file_not_contains "multi: the file that PASSED red is not claimed as evidence" \
  "$MANIFEST5" 'red-run: tests/test-beta.sh'

# --- filter derived from the manifest's Test Obligation ---------------------
write_manifest TASK-006 "$BASE_SHA"
MANIFEST6="$TEST_DIR/nazgul/tasks/TASK-006.md"
run_capture TASK-006
assert_exit_code "derived filter: falls back to ## Test Obligation" "$RR_EC" 0
assert_file_contains "derived filter: ran the filter the manifest named" "$MANIFEST6" 'run-tests.sh --filter=gamma'
assert_file_contains "derived filter: entry names gamma" "$MANIFEST6" 'red-run: tests/test-gamma.sh'

# --- the harness is never copied into the pre-change tree -------------------
# Found by this script's own first real use: TASK-001 changed tests/run-tests.sh,
# the derived copy set carried it into the pre-change worktree, and the red run
# went green because the change under test had been copied in with the tests.
teardown_temp_dir
setup_project
printf '\n# touched by this task\n' >> "$TEST_DIR/tests/run-tests.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "this task also changes the harness"
HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
write_manifest TASK-011 "$BASE_SHA"
MANIFEST11="$TEST_DIR/nazgul/tasks/TASK-011.md"
run_capture TASK-011 --filter=alpha
assert_exit_code "harness exclusion: the run is still red" "$RR_EC" 0
assert_contains "harness exclusion: says what it refused to copy, and why" "$RR_OUT" \
  "NOT copying tests/run-tests.sh into the pre-change tree"
assert_file_contains "harness exclusion: the evidence block records the exclusion" \
  "$MANIFEST11" 'NOT copied (harness, not test input): tests/run-tests.sh'

run_capture TASK-011 --filter=alpha --copy=tests/test-alpha.sh
assert_exit_code "--copy: a pinned copy set still red-runs" "$RR_EC" 0
assert_contains "--copy: announces that derivation was suppressed" "$RR_OUT" "copy set pinned by --copy"
assert_file_contains "--copy: the pinning is recorded in the evidence block" "$MANIFEST11" 'copy set pinned by --copy'
assert_file_contains "--copy: exactly the one pinned file was copied" "$MANIFEST11" '1 changed test file(s) copied in'

run_capture TASK-011 --filter=alpha --copy=tests/does-not-exist.sh
assert_exit_code "--copy: a path that does not exist is an error, not a silent skip" "$RR_EC" 1
assert_contains "--copy: names the missing path" "$RR_OUT" "tests/does-not-exist.sh does not exist"

# --- environment errors: nothing written, distinct messages -----------------
run_capture TASK-999 --filter=alpha
assert_exit_code "missing manifest: exits 1" "$RR_EC" 1
assert_contains "missing manifest: names the path it looked for" "$RR_OUT" "no manifest at"

write_manifest TASK-007 ""
sed -i.bak '/Base SHA/d' "$TEST_DIR/nazgul/tasks/TASK-007.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-007.md.bak"
run_capture TASK-007 --filter=alpha
assert_exit_code "no Base SHA: exits 1" "$RR_EC" 1
assert_contains "no Base SHA: says there is no pre-change tree to run against" "$RR_OUT" \
  "There is no pre-change tree to run against"
assert_file_not_contains "no Base SHA: writes NO evidence block" \
  "$TEST_DIR/nazgul/tasks/TASK-007.md" '## Red-Run Evidence'

write_manifest TASK-008 "0000000000000000000000000000000000000000"
run_capture TASK-008 --filter=alpha
assert_exit_code "unresolvable Base SHA: exits 1" "$RR_EC" 1
assert_contains "unresolvable Base SHA: says so" "$RR_OUT" "does not resolve to a commit"

write_manifest TASK-009 "$BASE_SHA"
sed -i.bak '/Scoped filter/d' "$TEST_DIR/nazgul/tasks/TASK-009.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-009.md.bak"
run_capture TASK-009
assert_exit_code "no filter anywhere: exits 1 rather than running the full suite" "$RR_EC" 1
assert_contains "no filter anywhere: says a full-suite red run is out of budget" "$RR_OUT" \
  "a full-suite red run is out of the per-task time budget"

run_capture NOT-A-TASK --filter=alpha
assert_exit_code "bad task id: exits 1" "$RR_EC" 1
assert_contains "bad task id: says what shape it wanted" "$RR_OUT" "is not a TASK-NNN"

# --- no test files changed: refuses rather than capturing nothing ------------
teardown_temp_dir
setup_project
NO_TESTS_BASE=$(git -C "$TEST_DIR" rev-parse HEAD)
write_manifest TASK-010 "$NO_TESTS_BASE"
run_capture TASK-010 --filter=alpha
assert_exit_code "no changed tests: exits 1" "$RR_EC" 1
assert_contains "no changed tests: says it looked, and where" "$RR_OUT" "the working tree, and untracked files"
assert_contains "no changed tests: points at the enumerated N/A escape" "$RR_OUT" "enumerated N/A token"
assert_eq "no changed tests: no scratch worktree is left behind" "$(worktree_count)" "1"

teardown_temp_dir
report_results
