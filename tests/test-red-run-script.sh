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
  git -C "$TEST_DIR" init -q -b main
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/tests" "$TEST_DIR/scripts" "$TEST_DIR/nazgul/tasks"
  cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/tests/run-tests.sh"
  cat > "$TEST_DIR/tests/test-mask-unrelated.sh" <<'UNRELATED'
#!/usr/bin/env bash
echo "=== test-mask-unrelated ==="
echo "  FAIL: pre-existing failure outside the copied test set"
exit 1
UNRELATED
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
  cat > "$TEST_DIR/tests/test-mask-vacuous.sh" <<'VACUOUS_MASK'
#!/usr/bin/env bash
echo "=== test-mask-vacuous ==="
echo "  PASS: copied test is vacuous"
exit 0
VACUOUS_MASK
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
assert_file_not_contains "multi: a pre-existing failure outside the copy set is not claimed" \
  "$MANIFEST5" 'red-run: tests/test-mask-unrelated.sh'

write_manifest TASK-013 "$BASE_SHA"
MANIFEST13="$TEST_DIR/nazgul/tasks/TASK-013.md"
run_capture TASK-013 --filter=mask
assert_exit_code "unrelated failure: refuses evidence when no copied test failed" "$RR_EC" 1
assert_contains "unrelated failure: explains why the runner's failure is insufficient" "$RR_OUT" \
  "none of its reported failing test files belongs to the copied test set"
assert_file_not_contains "unrelated failure: writes NO evidence block" "$MANIFEST13" \
  '## Red-Run Evidence'

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
mkdir -p "$TEST_DIR/tests/lib"
printf '# changed assertion helper\n' > "$TEST_DIR/tests/lib/assertions.sh"
printf '# changed setup helper\n' > "$TEST_DIR/tests/lib/setup.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "this task also changes the harness"
HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
write_manifest TASK-011 "$BASE_SHA"
MANIFEST11="$TEST_DIR/nazgul/tasks/TASK-011.md"
run_capture TASK-011 --filter=alpha
assert_exit_code "harness exclusion: the run is still red" "$RR_EC" 0
assert_contains "harness exclusion: says what it refused to copy, and why" "$RR_OUT" \
  "NOT copying tests/run-tests.sh into the pre-change tree"
assert_contains "harness exclusion: assertions helper is never derived into the old tree" "$RR_OUT" \
  "NOT copying tests/lib/assertions.sh into the pre-change tree"
assert_contains "harness exclusion: setup helper is never derived into the old tree" "$RR_OUT" \
  "NOT copying tests/lib/setup.sh into the pre-change tree"
assert_file_contains "harness exclusion: the evidence block records the exclusion" \
  "$MANIFEST11" 'NOT copied (harness, not test input):.*tests/run-tests.sh'

run_capture TASK-011 --filter=alpha --copy=tests/test-alpha.sh
assert_exit_code "--copy: a pinned copy set still red-runs" "$RR_EC" 0
assert_contains "--copy: announces that derivation was suppressed" "$RR_OUT" "copy set pinned by --copy"
assert_file_contains "--copy: the pinning is recorded in the evidence block" "$MANIFEST11" 'copy set pinned by --copy'
assert_file_contains "--copy: exactly the one pinned file was copied" "$MANIFEST11" '1 changed test file(s) copied in'

run_capture TASK-011 --filter=alpha --copy=tests/does-not-exist.sh
assert_exit_code "--copy: a path that does not exist is an error, not a silent skip" "$RR_EC" 1
assert_contains "--copy: names the missing path" "$RR_OUT" "tests/does-not-exist.sh does not exist"

run_capture TASK-011 --filter=alpha --copy=tests/lib
assert_exit_code "--copy: a directory is rejected as a non-regular file" "$RR_EC" 1
assert_contains "--copy: a directory diagnostic names the existing path" "$RR_OUT" \
  "copy=tests/lib exists under"
assert_contains "--copy: a directory is reported accurately" "$RR_OUT" \
  "but is not a regular file"
assert_not_contains "--copy: an existing directory is never reported missing" "$RR_OUT" \
  "tests/lib does not exist"

run_capture TASK-011 --filter=alpha --copy=tests/../scripts/feature.sh
assert_exit_code "--copy: traversal out of tests/ is rejected before any worktree write" "$RR_EC" 1
assert_contains "--copy: traversal rejection names the unsafe path" "$RR_OUT" \
  "copy path must not contain '.' or '..' segments: tests/../scripts/feature.sh"

# A legacy/pre-change harness may exit nonzero without printing a "Failed test
# files" section. The fallback must treat a dash-leading filter as literal data.
cat > "$TEST_DIR/tests/run-tests.sh" <<'LEGACY_RUNNER'
#!/usr/bin/env bash
echo "=== test--dash ==="
echo "  FAIL: legacy harness reports no failed-file summary"
exit 1
LEGACY_RUNNER
git -C "$TEST_DIR" add tests/run-tests.sh
git -C "$TEST_DIR" commit -q -m "legacy runner without failed-file summary"
FALLBACK_BASE=$(git -C "$TEST_DIR" rev-parse HEAD)
cat > "$TEST_DIR/tests/test--dash.sh" <<'DASH_TEST'
#!/usr/bin/env bash
echo "  FAIL: dash-filter regression"
exit 1
DASH_TEST
git -C "$TEST_DIR" add tests/test--dash.sh
git -C "$TEST_DIR" commit -q -m "add dash-filter regression test"
HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
write_manifest TASK-012 "$FALLBACK_BASE"
MANIFEST12="$TEST_DIR/nazgul/tasks/TASK-012.md"
run_capture TASK-012 --filter=-dash
assert_exit_code "fallback: dash-leading filter still identifies the copied failing file" "$RR_EC" 0
assert_contains "fallback: announces failed-file discovery fallback" "$RR_OUT" \
  "falling back to the copied files matching '-dash'"
assert_file_contains "fallback: records the literal dash-filter match" "$MANIFEST12" \
  'red-run: tests/test--dash.sh'

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

UNRELATED_SHA=$(git -C "$TEST_DIR" commit-tree "$(git -C "$TEST_DIR" mktree </dev/null)" \
  -m "unrelated base" </dev/null)
write_manifest TASK-014 "$UNRELATED_SHA"
run_capture TASK-014 --filter=alpha
assert_exit_code "unrelated Base SHA: exits 1 before creating a worktree" "$RR_EC" 1
assert_contains "unrelated Base SHA: says it is not an ancestor of HEAD" "$RR_OUT" \
  "is not an ancestor of HEAD"
assert_file_not_contains "unrelated Base SHA: writes NO evidence block" \
  "$TEST_DIR/nazgul/tasks/TASK-014.md" '## Red-Run Evidence'

write_manifest TASK-009 "$BASE_SHA"
sed -i.bak '/Scoped filter/d' "$TEST_DIR/nazgul/tasks/TASK-009.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-009.md.bak"
run_capture TASK-009
assert_exit_code "no filter anywhere: exits 1 rather than running the full suite" "$RR_EC" 1
assert_contains "no filter anywhere: says a full-suite red run is out of budget" "$RR_OUT" \
  "a full-suite red run is out of the per-task time budget"

run_capture NOT-A-TASK --filter=alpha
assert_exit_code "bad task id: exits 1" "$RR_EC" 1
assert_contains "bad task id: says what shape it wanted" "$RR_OUT" "is not a TASK-NNN"

run_capture TASK-foo --filter=alpha
assert_exit_code "non-numeric task id: exits 1" "$RR_EC" 1
assert_contains "non-numeric task id: says what shape it wanted" "$RR_OUT" "is not a TASK-NNN"

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

# The project's own runner, not this repo's harness. Ordered FIRST among the
# runner-resolution cases: each dies at the pre-change base on the old hardcode.
RRS_SCANNED=0
RRS_CHECKED=0
RRS_SKIPPED=0
RRS_NOJQ=0
RRS_FINDINGS=0
RRS_MARK=0

# A scenario red-run cannot be driven through here (it needs jq to read a project
# config at all) is SKIPPED and counted, never silently passed.
rrs_begin() {
  RRS_SCANNED=$((RRS_SCANNED + 1))
  if [ "${2:-}" = "jq" ] && ! command -v jq >/dev/null 2>&1; then
    RRS_SKIPPED=$((RRS_SKIPPED + 1))
    RRS_NOJQ=$((RRS_NOJQ + 1))
    _skip "runner-resolution: $1 (jq unavailable — red-run cannot read a project config)"
    return 1
  fi
  RRS_CHECKED=$((RRS_CHECKED + 1))
  RRS_MARK="$TESTS_FAILED"
  return 0
}

rrs_end() {
  [ "$TESTS_FAILED" -eq "$RRS_MARK" ] || RRS_FINDINGS=$((RRS_FINDINGS + 1))
}

write_project_config() {
  cat > "$TEST_DIR/nazgul/config.json"
}

# The capture line's command, between the backticks — the provenance string a
# reviewer reads as "this is what ran".
capture_cmd() {
  grep -o '^- capture: `[^`]*`' "$1" | head -1 | sed -e 's/^- capture: `//' -e 's/`$//'
}

# Scratch project whose ONLY runner is ./run-my-tests.sh, scoped with --only=.
# tests/run-tests.sh is never created here, so a surviving hardcode cannot pass.
setup_custom_runner_project() {
  setup_temp_dir
  git -C "$TEST_DIR" init -q -b main
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/tests" "$TEST_DIR/scripts" "$TEST_DIR/nazgul/tasks"
  cat > "$TEST_DIR/run-my-tests.sh" <<'CUSTOM_RUNNER'
#!/usr/bin/env bash
set -uo pipefail
only=""
for a in "$@"; do
  case "$a" in --only=*) only="${a#--only=}" ;; esac
done
if [ -z "$only" ]; then
  echo "run-my-tests: no --only= scope given"
  exit 9
fi
root="$(cd "$(dirname "$0")" && pwd)"
matched=0
failed=""
for f in "$root"/tests/test-*.sh; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  case "$base" in *"$only"*) ;; *) continue ;; esac
  matched=1
  bash "$f" || failed="${failed}  - ${base}
"
done
if [ "$matched" -eq 0 ]; then
  echo "run-my-tests: nothing matched --only=$only"
  exit 2
fi
if [ -n "$failed" ]; then
  printf 'Failed test files:\n%s\n' "$failed"
  exit 1
fi
exit 0
CUSTOM_RUNNER
  chmod +x "$TEST_DIR/run-my-tests.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "base: the project's own runner, no nazgul harness"
  CUSTOM_BASE=$(git -C "$TEST_DIR" rev-parse HEAD)

  printf '#!/usr/bin/env bash\necho feature\n' > "$TEST_DIR/scripts/feature.sh"
  cat > "$TEST_DIR/tests/test-delta.sh" <<'DELTA'
#!/usr/bin/env bash
set -uo pipefail
echo "=== test-delta ==="
if [ -f "$(cd "$(dirname "$0")/.." && pwd)/scripts/feature.sh" ]; then
  echo "  PASS: delta needs the feature"
  exit 0
fi
echo "  FAIL: delta needs the feature"
exit 1
DELTA
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "the task's work"
  CUSTOM_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
}

write_custom_manifest() {
  local id="$1"
  {
    printf -- '---\nstatus: IN_PROGRESS\n---\n# %s: scratch task\n\n' "$id"
    printf -- '## Metadata\n- **ID**: %s\n- **Base SHA**: %s\n\n' "$id" "$CUSTOM_BASE"
    printf -- '## Commits\n%s\n\n' "$CUSTOM_HEAD"
    printf -- '## Test Obligation\n- **Scoped filter**: `./run-my-tests.sh --only=delta`\n\n'
    printf -- '## Implementation Log\n- nothing yet\n'
  } > "$TEST_DIR/nazgul/tasks/${id}.md"
}

setup_custom_runner_project
if rrs_begin "project.test_command composes and runs, and the record names it" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "./run-my-tests.sh",
    "test_filter_template": "--only={filter}",
    "test_roots": ["tests"]
  }
}
CFG
  write_custom_manifest TASK-101
  MANIFEST101="$TEST_DIR/nazgul/tasks/TASK-101.md"
  run_capture TASK-101 --filter=delta
  assert_exit_code "custom runner: a project without tests/run-tests.sh still captures" "$RR_EC" 0
  assert_contains "custom runner: reports RED confirmed" "$RR_OUT" "RED confirmed for TASK-101"
  assert_eq "custom runner: the record names the composed project command" \
    "$(capture_cmd "$MANIFEST101")" "./run-my-tests.sh --only=delta"
  assert_file_not_contains "custom runner: the record never names a harness that did not run" \
    "$MANIFEST101" 'run-tests.sh'
  assert_file_contains "custom runner: the entry names the failing test file" \
    "$MANIFEST101" 'red-run: tests/test-delta.sh'
  assert_file_contains "custom runner: the case name comes from the project runner's own output" \
    "$MANIFEST101" 'case "delta needs the feature"'
  assert_file_contains "custom runner: provenance is still the capturer" \
    "$MANIFEST101" 'captured-by: scripts/red-run.sh at 20'
  assert_eq "custom runner: the scratch worktree is removed" "$(worktree_count)" "1"
  rrs_end
fi

if rrs_begin "a configured runner absent from the pre-change tree is named as such" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "./run-my-tests-v2.sh",
    "test_filter_template": "--only={filter}"
  }
}
CFG
  write_custom_manifest TASK-102
  run_capture TASK-102 --filter=delta
  assert_exit_code "absent runner: exits 1 — an environment error, not a red run" "$RR_EC" 1
  assert_contains "absent runner: names the runner and the tree it is missing from" "$RR_OUT" \
    "is absent from the pre-change tree: $CUSTOM_BASE has no run-my-tests-v2.sh"
  assert_contains "absent runner: says nothing ran, so this is not a failed run" "$RR_OUT" \
    "nothing was run at all"
  assert_not_contains "absent runner: is NOT the undeterminable-runner state" "$RR_OUT" \
    "no test runner could be determined"
  assert_not_contains "absent runner: is never reported as a vacuous test" "$RR_OUT" "VACUOUS TEST"
  assert_file_not_contains "absent runner: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-102.md" '## Red-Run Evidence'
  rrs_end
fi

if rrs_begin "a runner path that escapes the pre-change tree is refused" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "./tests/../run-my-tests.sh",
    "test_filter_template": "--only={filter}"
  }
}
CFG
  write_custom_manifest TASK-111
  run_capture TASK-111 --filter=delta
  assert_exit_code "traversal runner: exits 1 rather than running a file from another tree" "$RR_EC" 1
  assert_contains "traversal runner: names the segment it refused" "$RR_OUT" \
    "carries a '.' or '..' segment"
  assert_contains "traversal runner: says which tree it would have run from" "$RR_OUT" \
    "possibly the changed one"
  assert_file_not_contains "traversal runner: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-111.md" '## Red-Run Evidence'
  rrs_end
fi

if rrs_begin "a configured runner that is not on PATH is named as such" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "nazgul-no-such-runner-xyz test",
    "test_filter_template": "--only={filter}"
  }
}
CFG
  write_custom_manifest TASK-103
  run_capture TASK-103 --filter=delta
  assert_exit_code "unreachable runner: exits 1" "$RR_EC" 1
  assert_contains "unreachable runner: names the command it could not execute" "$RR_OUT" \
    "is not on PATH: 'nazgul-no-such-runner-xyz' cannot be executed here"
  assert_contains "unreachable runner: says nothing ran" "$RR_OUT" "nothing was run at all"
  assert_file_not_contains "unreachable runner: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-103.md" '## Red-Run Evidence'
  rrs_end
fi

if rrs_begin "a custom runner with no filter template is refused, not appended to" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "./run-my-tests.sh"
  }
}
CFG
  write_custom_manifest TASK-104
  run_capture TASK-104 --filter=delta
  assert_exit_code "no template: exits 1 rather than guessing a scoping flag" "$RR_EC" 1
  assert_contains "no template: names the missing configuration key" "$RR_OUT" \
    "project.test_filter_template is not configured"
  assert_contains "no template: names the command it refused to scope" "$RR_OUT" "./run-my-tests.sh"
  assert_contains "no template: says why a blind append is refused" "$RR_OUT" \
    "would exit non-zero and be read as RED confirmed"
  assert_not_contains "no template: is never reported as a vacuous test" "$RR_OUT" "VACUOUS TEST"
  assert_file_not_contains "no template: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-104.md" '## Red-Run Evidence'
  rrs_end
fi

if rrs_begin "a filter template carrying no {filter} is refused distinctly" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "./run-my-tests.sh",
    "test_filter_template": "--only"
  }
}
CFG
  write_custom_manifest TASK-105
  run_capture TASK-105 --filter=delta
  assert_exit_code "placeholderless template: exits 1" "$RR_EC" 1
  assert_contains "placeholderless template: names the placeholder it wanted, and the value it got" \
    "$RR_OUT" "carries no {filter} placeholder: '--only'"
  assert_not_contains "placeholderless template: is NOT the absent-template message" "$RR_OUT" \
    "is not configured"
  assert_file_not_contains "placeholderless template: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-105.md" '## Red-Run Evidence'
  rrs_end
fi

if rrs_begin "an unusable config value is refused as unusable, not as a failed run" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": ["./run-my-tests.sh"],
    "test_filter_template": "--only={filter}"
  }
}
CFG
  write_custom_manifest TASK-106
  run_capture TASK-106 --filter=delta
  assert_exit_code "nonstring test_command: exits 1" "$RR_EC" 1
  assert_contains "nonstring test_command: names the key and what is wrong with it" "$RR_OUT" \
    "project.test_command in"
  assert_contains "nonstring test_command: reports the value's kind" "$RR_OUT" "unusable (nonstring)"
  assert_contains "nonstring test_command: distinguishes itself from a failed runner" "$RR_OUT" \
    "no runner could be determined at all"
  rrs_end
fi

if rrs_begin "no runner anywhere is a distinct, named refusal" ""; then
  rm -f "$TEST_DIR/nazgul/config.json"
  write_custom_manifest TASK-107
  run_capture TASK-107 --filter=delta
  assert_exit_code "no runner: exits 1" "$RR_EC" 1
  assert_contains "no runner: says no runner could be determined" "$RR_OUT" \
    "no test runner could be determined for this project"
  assert_contains "no runner: names both the key and the fallback it looked for" "$RR_OUT" \
    "project.test_command is not set"
  assert_contains "no runner: names the convention it fell back to" "$RR_OUT" \
    "has no tests/run-tests.sh to fall back to"
  assert_contains "no runner: says nothing ran at all" "$RR_OUT" "nothing was run at all"
  assert_not_contains "no runner: is never reported as a vacuous test" "$RR_OUT" "VACUOUS TEST"
  assert_not_contains "no runner: is never reported as nothing-checked" "$RR_OUT" "NOTHING CHECKED"
  assert_file_not_contains "no runner: writes NO evidence block" \
    "$TEST_DIR/nazgul/tasks/TASK-107.md" '## Red-Run Evidence'
  rrs_end
fi

# The shipped defaults must reproduce the pre-configuration capture exactly.
teardown_temp_dir
setup_project
if rrs_begin "no config at all: the legacy convention captures byte-identically" ""; then
  write_manifest TASK-108 "$BASE_SHA"
  MANIFEST108="$TEST_DIR/nazgul/tasks/TASK-108.md"
  run_capture TASK-108 --filter=alpha
  assert_exit_code "default runner: a project with no config still captures" "$RR_EC" 0
  assert_eq "default runner: the recorded command is the pre-configuration string, unchanged" \
    "$(capture_cmd "$MANIFEST108")" "tests/run-tests.sh --filter=alpha"
  LEGACY_CAPTURE_CMD=$(capture_cmd "$MANIFEST108")
  rrs_end
fi

if rrs_begin "an unmigrated config naming the legacy harness captures identically" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 36,
  "project": {
    "test_command": "tests/run-tests.sh"
  }
}
CFG
  write_manifest TASK-109 "$BASE_SHA"
  MANIFEST109="$TEST_DIR/nazgul/tasks/TASK-109.md"
  run_capture TASK-109 --filter=alpha
  assert_exit_code "legacy test_command: a schema-36 config with no template still captures" "$RR_EC" 0
  assert_eq "legacy test_command: precedence 1 and precedence 2 record the same command" \
    "$(capture_cmd "$MANIFEST109")" "${LEGACY_CAPTURE_CMD:-<unset>}"
  assert_file_contains "legacy test_command: the entry is unchanged too" \
    "$MANIFEST109" 'red-run: tests/test-alpha.sh'
  rrs_end
fi

if rrs_begin "an explicit default template is identical to the shipped default" jq; then
  write_project_config <<'CFG'
{
  "schema_version": 37,
  "project": {
    "test_command": "tests/run-tests.sh",
    "test_filter_template": "--filter={filter}",
    "test_roots": ["tests"]
  }
}
CFG
  write_manifest TASK-110 "$BASE_SHA"
  MANIFEST110="$TEST_DIR/nazgul/tasks/TASK-110.md"
  run_capture TASK-110 --filter=alpha
  assert_exit_code "migrated config: captures" "$RR_EC" 0
  assert_eq "migrated config: the shipped default reproduces the hardcoded command exactly" \
    "$(capture_cmd "$MANIFEST110")" "${LEGACY_CAPTURE_CMD:-<unset>}"
  rrs_end
fi

echo "  runner-resolution: ${RRS_SCANNED} scanned, ${RRS_SKIPPED} skipped (jq-unavailable=${RRS_NOJQ}), ${RRS_CHECKED} checked, ${RRS_FINDINGS} findings"
assert_eq "runner-resolution: scanned == skipped + checked" \
  "$RRS_SCANNED" "$((RRS_SKIPPED + RRS_CHECKED))"
if command -v jq >/dev/null 2>&1; then
  assert_eq "runner-resolution: every scenario was driven where jq is available" \
    "$RRS_CHECKED" "$RRS_SCANNED"
else
  assert_eq "runner-resolution: the jq-free scenarios were still driven" "$RRS_CHECKED" "2"
fi

teardown_temp_dir
report_results
