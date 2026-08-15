#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — the code under test returns non-zero to block.

# Test: ttg_verify_red_run_evidence (scripts/lib/task-transition-guard.sh) and
# its two call sites — task-state-guard.sh's IMPLEMENTED gate and stop-hook.sh's
# bash-write reconciliation pass. Real scratch git repos with real commits
# throughout: every cat-file / merge-base assertion here is answered by git, not
# by a stub (tests/test-task-transition-guard.sh convention).
TEST_NAME="test-red-run-evidence"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

# A leaked NAZGUL_DIR from the caller's environment would redirect this file's
# telemetry assertions at a real project's events.jsonl.
NAZGUL_DIR=""

source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

GUARD="$REPO_ROOT/scripts/task-state-guard.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
RR_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-rr-stderr-XXXXXX")
trap 'rm -f "$RR_ERR_FILE"' EXIT

# Call the gate IN THIS SHELL (stderr to a file, not a command substitution) so
# TTG_RED_RUN_REASON survives the call. Sets RR_EC / RR_STDERR / RR_REASON.
rr_call() {
  local manifest="$1" root="$2" task_id="${3:-TASK-001}"
  if ttg_verify_red_run_evidence "$manifest" "$root" "$task_id" 2>"$RR_ERR_FILE" >/dev/null; then
    RR_EC=0
  else
    RR_EC=$?
  fi
  RR_STDERR=$(cat "$RR_ERR_FILE")
  # Defaulted, not asserted-into-existence: against a tree where the gate does
  # not exist yet, each case must report its own FAIL rather than the whole
  # file aborting on `set -u` at the first call.
  RR_REASON="${TTG_RED_RUN_REASON:-<unset>}"
}

# Scratch repo: BASE_SHA (with tests/test-foo.sh present) then HEAD_SHA, which
# adds scripts/foo.sh — so the Base SHA..HEAD diff really does put the tree in
# `scripts/**` scope. ORPHAN_SHA is a real parentless commit built with
# commit-tree (never checked out, so the worktree is untouched): git resolves
# it, and it is an ancestor of nothing here.
setup_rr_repo() {
  setup_temp_dir
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/tests" "$TEST_DIR/scripts"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/tests/test-foo.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "base"
  BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  printf 'echo work\n' >> "$TEST_DIR/scripts/foo.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "the task's work"
  HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  ORPHAN_SHA=$(git -C "$TEST_DIR" commit-tree "$(git -C "$TEST_DIR" mktree </dev/null)" \
    -m "unrelated root" </dev/null)
}

# A manifest carrying the given ## Red-Run Evidence body (may be empty).
rr_manifest() {
  local scope="$1" red_run_body="$2"
  printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: %s\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n\n## Red-Run Evidence\n%s\n\n## Description\nx\n' \
    "$scope" "$BASE_SHA" "$HEAD_SHA" "$red_run_body"
}

VALID_ENTRY='- red-run: tests/test-foo.sh :: case "gate blocks an absent section"
  - pre-change-ref: PRE_CHANGE_REF
  - result: FAILED (exit 1) — "FAIL: gate blocks an absent section"
  - captured-by: scripts/red-run.sh at 2026-08-04T11:02:31Z'

valid_entry() { printf '%s' "${VALID_ENTRY//PRE_CHANGE_REF/$BASE_SHA}"; }

# ---------------------------------------------------------------------------
# STATE 1 — section absent, task in scope: BLOCK
# ---------------------------------------------------------------------------
setup_rr_repo
NO_SECTION=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$BASE_SHA" "$HEAD_SHA")
rr_call "$NO_SECTION" "$TEST_DIR"
assert_exit_code "absent + in scope: blocks" "$RR_EC" 1
assert_eq "absent + in scope: reason is 'absent'" "$RR_REASON" "absent"
assert_contains "absent + in scope: distinct diagnostic" "$RR_STDERR" "no ## Red-Run Evidence section, but this task's scope touches"
STDERR_ABSENT="$RR_STDERR"
assert_file_exists "absent: red_run_missing event emitted" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_eq "absent: event carries task_id and reason" \
  "$(jq -r 'select(.event == "red_run_missing") | "\(.task_id) \(.reason)"' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)" \
  "TASK-001 absent"

# ---------------------------------------------------------------------------
# STATE 2 — section absent, task NOT in scope: ALLOW, announce the skipped
# check. Base SHA is HEAD here, so BOTH arms of the union genuinely say
# out-of-scope rather than the diff arm being unavailable.
# ---------------------------------------------------------------------------
OUT_OF_SCOPE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$HEAD_SHA" "$HEAD_SHA")
rr_call "$OUT_OF_SCOPE" "$TEST_DIR"
assert_exit_code "absent + out of scope: allows" "$RR_EC" 0
assert_eq "absent + out of scope: reason is 'not_applicable'" "$RR_REASON" "not_applicable"
assert_contains "absent + out of scope: skipped check is announced, not silent" \
  "$RR_STDERR" "red-run check not applicable, skipped"
STDERR_NOT_APPLICABLE="$RR_STDERR"
teardown_temp_dir

# STATE 2b — the payload is present but lives ONLY inside an HTML comment, which
# the strip removes before parsing. Still a refusal; no longer named as absent.
setup_rr_repo
COMMENTED_ENTRY=$(printf '<!--\n%s\n-->' "$(valid_entry)")
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$COMMENTED_ENTRY")" "$TEST_DIR"
assert_exit_code "commented entry + in scope: still refuses — a comment is not a record" "$RR_EC" 1
assert_eq "commented entry: reason is 'commented_out', not 'absent'" "$RR_REASON" "commented_out"
assert_contains "commented entry: the diagnostic says where the payload actually is" \
  "$RR_STDERR" "carries content only inside an HTML comment"
assert_not_contains "commented entry: it is not reported as an empty section" \
  "$RR_STDERR" "section is present but empty"
STDERR_COMMENTED="$RR_STDERR"
assert_eq "commented entry: red_run_missing carries the distinguishing token" \
  "$(jq -r 'select(.event == "red_run_missing") | .reason' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)" \
  "commented_out"

# The other half of the split: nothing was stripped, so nothing was ever there.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '')" "$TEST_DIR"
assert_exit_code "empty section + in scope: still refuses" "$RR_EC" 1
assert_eq "empty section: reason stays 'absent'" "$RR_REASON" "absent"
assert_contains "empty section: named as empty, not as commented" \
  "$RR_STDERR" "section is present but empty"
assert_not_contains "empty section: never reported as content hidden in a comment" \
  "$RR_STDERR" "only inside an HTML comment"

# Payload-state matrix, so a state that stopped being reachable cannot read as a
# state that never existed (RULES.md §15). Columns: body | scope | base | reason | exit.
payload_body() {
  case "$1" in
    empty) printf '' ;;
    blank) printf '   \n\n' ;;
    commented) printf '<!--\n%s\n-->' "$(valid_entry)" ;;
    commented-prose) printf '<!-- not filled in yet -->' ;;
    prose) printf 'not a red-run entry' ;;
    entry) valid_entry ;;
    *) return 1 ;;
  esac
}

payload_manifest() {
  printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: %s\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n\n## Red-Run Evidence\n%s\n\n## Description\nx\n' \
    "$2" "$3" "$HEAD_SHA" "$1"
}

PAYLOAD_CASES='empty|["scripts/foo.sh"]|base|absent|1
blank|["scripts/foo.sh"]|base|absent|1
commented|["scripts/foo.sh"]|base|commented_out|1
commented-prose|["scripts/foo.sh"]|base|commented_out|1
empty|["docs/PRD.md"]|head|not_applicable|0
commented|["docs/PRD.md"]|head|not_applicable|0
prose|["scripts/foo.sh"]|base|corrupt|1
entry|["scripts/foo.sh"]|base|verified|0'
PM_SCANNED=0; PM_CHECKED=0; PM_UNRENDERABLE=0; PM_FINDINGS=0
while IFS='|' read -r pm_body pm_scope pm_base pm_reason pm_ec; do
  [ -n "$pm_body" ] || continue
  PM_SCANNED=$((PM_SCANNED + 1))
  if ! pm_rendered=$(payload_body "$pm_body"); then
    PM_UNRENDERABLE=$((PM_UNRENDERABLE + 1))
    _skip "payload-matrix: body '${pm_body}' could not be rendered — not checked"
    continue
  fi
  PM_CHECKED=$((PM_CHECKED + 1))
  case "$pm_base" in head) pm_sha="$HEAD_SHA" ;; *) pm_sha="$BASE_SHA" ;; esac
  rr_call "$(payload_manifest "$pm_rendered" "$pm_scope" "$pm_sha")" "$TEST_DIR"
  if [ "$RR_REASON" = "$pm_reason" ] && [ "$RR_EC" -eq "$pm_ec" ]; then
    _pass "payload-matrix: body=${pm_body} scope=${pm_scope} → ${pm_reason} (exit ${pm_ec})"
  else
    PM_FINDINGS=$((PM_FINDINGS + 1))
    _fail "payload-matrix: body=${pm_body} scope=${pm_scope} → ${pm_reason} (exit ${pm_ec})" \
      "expected: ${pm_reason} / exit ${pm_ec}" "  actual: ${RR_REASON} / exit ${RR_EC}"
  fi
done <<< "$PAYLOAD_CASES"
PM_SKIPPED=$((PM_SCANNED - PM_CHECKED))
echo "  payload-matrix: ${PM_SCANNED} scanned, ${PM_SKIPPED} skipped (unrenderable=${PM_UNRENDERABLE}), ${PM_CHECKED} checked, ${PM_FINDINGS} findings"
assert_eq "payload-matrix: scanned == skipped + checked" "$PM_SCANNED" "$((PM_SKIPPED + PM_CHECKED))"
assert_eq "payload-matrix: every row was actually checked" "$PM_CHECKED" "8"
teardown_temp_dir

# The refusal vocabulary is CLOSED, and read out of the source rather than narrated
# here: a state folded into an existing bucket would leave this set unchanged.
VOCAB_EXPECTED='absent bad_na_token commented_out corrupt exit_zero not_ancestor ref_unresolvable roots_undeterminable roots_unresolved'
VOCAB_ARGS=$(grep -oE '_ttg_red_run_(deny|empty_payload) "[^"]*" "[^"]*" "[^"]*"' \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" | sed -E 's/.*"([^"]*)"$/\1/')
VOCAB_SCANNED=$(printf '%s\n' "$VOCAB_ARGS" | grep -c '[^[:space:]]')
VOCAB_CHECKED=$(printf '%s\n' "$VOCAB_ARGS" | grep -cE '^[a-z_]+$')
VOCAB_PASSTHROUGH=$((VOCAB_SCANNED - VOCAB_CHECKED))
VOCAB_SET=$(printf '%s\n' "$VOCAB_ARGS" | grep -E '^[a-z_]+$' | sort -u)
VOCAB_FINDINGS=$(comm -3 <(printf '%s\n' "$VOCAB_SET") \
  <(printf '%s\n' "$VOCAB_EXPECTED" | tr ' ' '\n' | sort) | grep -c '[^[:space:]]')
echo "  reason-vocabulary: ${VOCAB_SCANNED} scanned, ${VOCAB_PASSTHROUGH} skipped (variable-passthrough=${VOCAB_PASSTHROUGH}), ${VOCAB_CHECKED} checked, ${VOCAB_FINDINGS} findings"
assert_eq "reason-vocabulary: scanned == skipped + checked" "$VOCAB_SCANNED" "$((VOCAB_PASSTHROUGH + VOCAB_CHECKED))"
assert_eq "reason-vocabulary: the closed set is exactly the enumerated reasons" \
  "$(printf '%s\n' "$VOCAB_SET" | tr '\n' ' ')" \
  "$(printf '%s\n' "$VOCAB_EXPECTED" | tr ' ' '\n' | sort | tr '\n' ' ')"
assert_eq "reason-vocabulary: the new state is a named member, not a bucket" "$VOCAB_FINDINGS" "0"

# ADR-024 decision 4: both halves read project.test_roots. No repo-root tests/
# here ON PURPOSE — the defect is invisible where the hardcode is right.
setup_monorepo_repo() {
  setup_temp_dir
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/src/App/tests" "$TEST_DIR/src/Worker/tests" "$TEST_DIR/scripts"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/src/App/tests/test-app.sh"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/src/Worker/tests/test-worker.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "base"
  BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  printf 'echo work\n' >> "$TEST_DIR/scripts/foo.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "the task's work"
  HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  setup_nazgul_dir
}

mono_entry() {
  printf -- '- red-run: %s :: case "monorepo acceptance"\n  - pre-change-ref: %s\n  - result: FAILED (exit 1) — "FAIL: monorepo acceptance"\n  - captured-by: scripts/red-run.sh at 2026-08-15T00:00:00Z' \
    "$1" "$BASE_SHA"
}

setup_monorepo_repo
create_config '.project.test_roots = ["src/App/tests"]'

# THE case this task exists for: red at the base SHA, where the satisfier still
# demands a literal repo-root tests/ path this project does not have.
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_exit_code "monorepo: evidence under the configured non-tests/ root is accepted" "$RR_EC" 0
assert_eq "monorepo: reason is 'verified'" "$RR_REASON" "verified"

# ...and the requirement that demanded it is the SAME one the trigger raises, so
# a repo-root scripts/** touch in a monorepo now produces a SATISFIABLE demand.
MONO_NO_EVIDENCE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$BASE_SHA" "$HEAD_SHA")
rr_call "$MONO_NO_EVIDENCE" "$TEST_DIR"
assert_exit_code "monorepo: a repo-root scripts/** touch still raises the requirement" "$RR_EC" 1
assert_eq "monorepo: unmet requirement still reasons 'absent'" "$RR_REASON" "absent"

# The trigger reads the configured roots too, not a hardcoded tests/.
MONO_ROOT_SCOPE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["src/App/tests/test-app.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$HEAD_SHA" "$HEAD_SHA")
rr_call "$MONO_ROOT_SCOPE" "$TEST_DIR"
assert_exit_code "monorepo: a configured-root path in the manifest triggers the requirement" "$RR_EC" 1
assert_eq "monorepo: configured-root trigger reasons 'absent'" "$RR_REASON" "absent"

# A repo-root tests/ path is NOT a configured root here: still denied, and the
# diagnostic names the set it was judged against rather than a hardcoded tree.
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry tests/test-app.sh)")" "$TEST_DIR"
assert_exit_code "monorepo: a path outside every configured root is still denied" "$RR_EC" 1
assert_eq "monorepo: outside-every-root reason is 'corrupt'" "$RR_REASON" "corrupt"
assert_contains "monorepo: the denial names the configured root set" \
  "$RR_STDERR" "under a configured tests root (src/App/tests)"

# Every safety check is kept and evaluated PER ROOT — widening the traversal
# rules to reach a monorepo would trade a deadlock for a path escape.
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/../../../etc/hosts)")" "$TEST_DIR"
assert_eq "monorepo: '..' segments are still rejected under a configured root" "$RR_REASON" "corrupt"
assert_contains "monorepo: dot-segment rejection is unchanged" \
  "$RR_STDERR" "must not contain '.' or '..' segments"

ln -s "$TEST_DIR/scripts/foo.sh" "$TEST_DIR/src/App/tests/test-linked.sh"
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-linked.sh)")" "$TEST_DIR"
assert_eq "monorepo: symlinked evidence path is still rejected" "$RR_REASON" "corrupt"
assert_contains "monorepo: regular non-symlink requirement is unchanged" \
  "$RR_STDERR" "regular non-symlink file"

mkdir -p "$TEST_DIR/outside/tests"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/outside/tests/test-escape.sh"
ln -s "$TEST_DIR/outside/tests" "$TEST_DIR/src/App/tests/escape"
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/escape/test-escape.sh)")" "$TEST_DIR"
assert_eq "monorepo: a symlinked directory cannot escape the configured root" "$RR_REASON" "corrupt"
assert_contains "monorepo: containment is still resolved-parent based" \
  "$RR_STDERR" "resolves outside every configured tests root"
rm -f "$TEST_DIR/src/App/tests/escape" "$TEST_DIR/src/App/tests/test-linked.sh"

# An unresolvable configured root is SKIPPED AND COUNTED, never silently dropped:
# a root set that quietly shrinks to empty re-creates the same unsatisfiable gate.
create_config '.project.test_roots = ["src/Ghost/tests", "src/App/tests"]'
MONO_OUT_OF_SCOPE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$HEAD_SHA" "$HEAD_SHA")
rr_call "$MONO_OUT_OF_SCOPE" "$TEST_DIR"
assert_exit_code "skipped root: an out-of-scope task is still allowed" "$RR_EC" 0
assert_contains "skipped root: the scan reports what it examined, with the reason named" \
  "$RR_STDERR" "tests-root scan: 2 scanned, 1 skipped (unsafe=0, unresolvable=1), 1 checked, 1 findings"
assert_contains "skipped root: the scan names where the set came from" "$RR_STDERR" "source=config"

# "Could not determine the roots" is a DIFFERENT state from "determined them and
# nothing matched", and it fails closed rather than quietly excusing the task.
create_config '.project.test_roots = []'
rr_call "$MONO_OUT_OF_SCOPE" "$TEST_DIR"
assert_exit_code "undeterminable roots: fails closed on an out-of-scope task" "$RR_EC" 1
assert_contains "undeterminable roots: distinct, loud diagnostic" \
  "$RR_STDERR" "could not determine the tests roots (project.test_roots is an empty array)"
assert_not_contains "undeterminable roots: never printed as a completed scan" \
  "$RR_STDERR" "tests-root scan:"
assert_not_contains "undeterminable roots: never printed as the degrade path" \
  "$RR_STDERR" "degraded to manifest-only"

rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_exit_code "undeterminable roots: an entry cannot be judged either" "$RR_EC" 1
assert_eq "undeterminable roots: reason is 'roots_undeterminable'" "$RR_REASON" "roots_undeterminable"

create_config '.project.test_roots = "src/App/tests"'
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_eq "a non-array test_roots is undeterminable, not one root" "$RR_REASON" "roots_undeterminable"
assert_contains "a non-array test_roots says what is wrong with it" \
  "$RR_STDERR" "not an array of non-empty repository-relative paths"

# Every configured root unresolvable is its own named state — not "your evidence
# file is missing", which is what the operator would otherwise go looking for.
create_config '.project.test_roots = ["src/Ghost/tests"]'
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/Ghost/tests/test-x.sh)")" "$TEST_DIR"
assert_exit_code "no root resolves: blocks" "$RR_EC" 1
assert_eq "no root resolves: reason is 'roots_unresolved'" "$RR_REASON" "roots_unresolved"
assert_contains "no root resolves: names the set that resolved to nothing" \
  "$RR_STDERR" "every configured tests root (src/Ghost/tests) was skipped"

# The default reproduces today's single-root behaviour exactly, both when the key
# is configured to it and when the key is absent altogether.
create_config '.project.test_roots = ["tests"]'
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_eq "default root: a monorepo path is rejected exactly as before" "$RR_REASON" "corrupt"
assert_contains "default root: the message names the single legacy root" \
  "$RR_STDERR" "under a configured tests root (tests)"
create_config 'del(.project.test_roots)'
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_eq "absent key: falls back to the single legacy root" "$RR_REASON" "corrupt"
assert_contains "absent key: the fallback names itself rather than passing as config" \
  "$RR_STDERR" "source=default:absent"

# Root-set matrix, so "checked nothing" cannot read as "found nothing"
# (RULES.md §15). Columns: roots json | entry path | expected reason | exit.
ROOT_CASES='["src/App/tests"]|src/App/tests/test-app.sh|verified|0
["src/App/tests"]|src/Worker/tests/test-worker.sh|corrupt|1
["src/App/tests","src/Worker/tests"]|src/App/tests/test-app.sh|verified|0
["src/App/tests","src/Worker/tests"]|src/Worker/tests/test-worker.sh|verified|0
["src/Ghost/tests","src/App/tests"]|src/App/tests/test-app.sh|verified|0
["src/Ghost/tests"]|src/Ghost/tests/test-x.sh|roots_unresolved|1
[]|src/App/tests/test-app.sh|roots_undeterminable|1
["tests"]|src/App/tests/test-app.sh|corrupt|1
["../outside/tests"]|src/App/tests/test-app.sh|corrupt|1'
RC_SCANNED=0; RC_CHECKED=0; RC_UNCONFIGURABLE=0; RC_FINDINGS=0
while IFS='|' read -r rc_roots rc_path rc_reason rc_ec; do
  [ -n "$rc_roots" ] || continue
  RC_SCANNED=$((RC_SCANNED + 1))
  if ! create_config ".project.test_roots = ${rc_roots}" 2>/dev/null; then
    RC_UNCONFIGURABLE=$((RC_UNCONFIGURABLE + 1))
    _skip "root-matrix: ${rc_roots} could not be written to the config — not checked"
    continue
  fi
  RC_CHECKED=$((RC_CHECKED + 1))
  rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry "$rc_path")")" "$TEST_DIR"
  if [ "$RR_REASON" = "$rc_reason" ] && [ "$RR_EC" -eq "$rc_ec" ]; then
    _pass "root-matrix: roots=${rc_roots} path=${rc_path} → ${rc_reason} (exit ${rc_ec})"
  else
    RC_FINDINGS=$((RC_FINDINGS + 1))
    _fail "root-matrix: roots=${rc_roots} path=${rc_path} → ${rc_reason} (exit ${rc_ec})" \
      "expected: ${rc_reason} / exit ${rc_ec}" "  actual: ${RR_REASON} / exit ${RR_EC}"
  fi
done <<< "$ROOT_CASES"
RC_SKIPPED=$((RC_SCANNED - RC_CHECKED))
echo "  root-matrix: ${RC_SCANNED} scanned, ${RC_SKIPPED} skipped (unconfigurable=${RC_UNCONFIGURABLE}), ${RC_CHECKED} checked, ${RC_FINDINGS} findings"
assert_eq "root-matrix: scanned == skipped + checked" "$RC_SCANNED" "$((RC_SKIPPED + RC_CHECKED))"
assert_eq "root-matrix: every configured row was actually checked" "$RC_CHECKED" "9"
teardown_temp_dir

# ADR-024 Planner decision 3: declaring a path OUT of scope used to put it IN
# scope, raising a demand the task could never meet. Keys on declared CHANGES.
setup_rr_repo
setup_nazgul_dir
create_config

# Base SHA is HEAD, so the diff arm genuinely says docs-only and the verdict
# rests on the declared-scope arm alone.
prohibition_manifest() {
  printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## File Scope\n%s\n\n## Description\nx\n' \
    "$HEAD_SHA" "$HEAD_SHA" "$1"
}

rr_call "$(prohibition_manifest '**Modifies**:
- docs/PRD.md

**Must NOT touch**: `scripts/red-run.sh` (TASK-006), the commit-evidence verifier')" "$TEST_DIR"
assert_exit_code "prohibition: a Must NOT touch line does not put the task in scope" "$RR_EC" 0
assert_eq "prohibition: the docs-only task stays 'not_applicable'" "$RR_REASON" "not_applicable"

rr_call "$(prohibition_manifest '**Modifies**:
- docs/PRD.md

**Must NOT touch**:
- `scripts/red-run.sh`
- `tests/run-tests.sh`')" "$TEST_DIR"
assert_exit_code "prohibition: continuation lines under the label are excluded too" "$RR_EC" 0
assert_eq "prohibition: multi-line prohibition stays 'not_applicable'" "$RR_REASON" "not_applicable"

# The exclusion is bounded by the next label — it must not swallow a real
# declaration that happens to follow the prohibition.
rr_call "$(prohibition_manifest '**Must NOT touch**: docs/

**Modifies**:
- tests/test-foo.sh')" "$TEST_DIR"
assert_exit_code "prohibition: a declaration AFTER the prohibition still triggers" "$RR_EC" 1
assert_eq "prohibition: post-prohibition declaration reasons 'absent'" "$RR_REASON" "absent"

rr_call "$(prohibition_manifest '**Modifies**:
- scripts/foo.sh

**Must NOT touch**: docs/')" "$TEST_DIR"
assert_exit_code "prohibition: a genuine declaration on any other line still triggers" "$RR_EC" 1
assert_eq "prohibition: genuine declaration reasons 'absent'" "$RR_REASON" "absent"

# NOT VACUOUS — this gate judges the very task that changed it, so the shape of
# that task's own manifest is the one shape that must never stop demanding.
SELF_SHAPED=$(printf '## Metadata\n- **ID**: TASK-007\n- **Files modified**: ["scripts/lib/task-transition-guard.sh","tests/test-red-run-evidence.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## File Scope\n**Modifies**:\n- `scripts/lib/task-transition-guard.sh`\n- `tests/test-red-run-evidence.sh`\n\n**Must NOT touch**: `scripts/red-run.sh` (TASK-006)\n\n## Description\nx\n' \
  "$HEAD_SHA" "$HEAD_SHA")
rr_call "$SELF_SHAPED" "$TEST_DIR" TASK-007
assert_exit_code "not vacuous: a scripts/** + tests/** task still REQUIRES evidence" "$RR_EC" 1
assert_eq "not vacuous: the unmet requirement still reasons 'absent'" "$RR_REASON" "absent"
teardown_temp_dir

# ---------------------------------------------------------------------------
# STATE 3 — non-comment section content with no parseable entry: BLOCK as corrupt.
# ---------------------------------------------------------------------------
setup_rr_repo
rr_call "$(rr_manifest '["docs/PRD.md"]' 'not a red-run entry')" "$TEST_DIR"
assert_exit_code "present + no entry: blocks even out of scope" "$RR_EC" 1
assert_eq "present + no entry: reason is 'corrupt'" "$RR_REASON" "corrupt"
assert_contains "present + no entry: distinct diagnostic" \
  "$RR_STDERR" "present but carries no parseable 'red-run:' entry"
STDERR_CORRUPT="$RR_STDERR"

COMMENT_ONLY_OUT=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s — docs: work\n\n## Red-Run Evidence\n<!-- not filled in yet -->\n\n## Description\nx\n' \
  "$HEAD_SHA" "$HEAD_SHA")
rr_call "$COMMENT_ONLY_OUT" "$TEST_DIR"
assert_exit_code "comment-only + out of scope: allows" "$RR_EC" 0
assert_eq "comment-only + out of scope: reason is not_applicable" "$RR_REASON" "not_applicable"

TEMPLATE_SCOPE_OUT=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## File Scope\n<!--\n**Creates:**\n- `tests/models/user.test.ts`\n-->\n\n## Commits\n- %s — docs: work\n\n## Red-Run Evidence\n<!-- not filled in yet -->\n\n## Description\nx\n' \
  "$HEAD_SHA" "$HEAD_SHA")
rr_call "$TEMPLATE_SCOPE_OUT" "$TEST_DIR"
assert_exit_code "template scope comments: example test paths do not put a docs task in scope" "$RR_EC" 0
assert_eq "template scope comments: reason is not_applicable" "$RR_REASON" "not_applicable"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '<!-- not filled in yet -->')" "$TEST_DIR"
assert_exit_code "comment-only + in scope: blocks — a comment is not a record" "$RR_EC" 1
assert_eq "comment-only + in scope: reason is commented_out" "$RR_REASON" "commented_out"

# ---------------------------------------------------------------------------
# STATE 4 — a real, referentially intact entry: ALLOW
# ---------------------------------------------------------------------------
rr_call "$(rr_manifest '["scripts/foo.sh","tests/test-foo.sh"]' "$(valid_entry)")" "$TEST_DIR"
assert_exit_code "valid entry: allows" "$RR_EC" 0
assert_eq "valid entry: reason is 'verified'" "$RR_REASON" "verified"
assert_eq "valid entry: no diagnostic noise" "$RR_STDERR" ""

# --- ref unresolvable ---
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/test-foo.sh :: case "x"
  - pre-change-ref: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  - result: FAILED (exit 1)')" "$TEST_DIR"
assert_exit_code "ref unresolvable: blocks" "$RR_EC" 1
assert_eq "ref unresolvable: reason is 'ref_unresolvable'" "$RR_REASON" "ref_unresolvable"
assert_contains "ref unresolvable: distinct diagnostic" "$RR_STDERR" "does not resolve to a real commit"
STDERR_REF="$RR_STDERR"

# --- ref resolves but is an ancestor of nothing under ## Commits ---
rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/test-foo.sh :: case \"x\"
  - pre-change-ref: ${ORPHAN_SHA}
  - result: FAILED (exit 1)")" "$TEST_DIR"
assert_exit_code "ref not an ancestor: blocks" "$RR_EC" 1
assert_eq "ref not an ancestor: reason is 'not_ancestor'" "$RR_REASON" "not_ancestor"
assert_contains "ref not an ancestor: distinct diagnostic" "$RR_STDERR" "is not an ancestor of any SHA recorded under ## Commits"
STDERR_ANCESTOR="$RR_STDERR"

# --- result records exit 0: the whole point of the gate ---
rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/test-foo.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}
  - result: PASSED (exit 0) — all green")" "$TEST_DIR"
assert_exit_code "recorded exit 0: blocks" "$RR_EC" 1
assert_eq "recorded exit 0: reason is 'exit_zero'" "$RR_REASON" "exit_zero"
assert_contains "recorded exit 0: distinct diagnostic" "$RR_STDERR" "is not a red run"
STDERR_EXIT_ZERO="$RR_STDERR"

# --- named test path does not exist in the worktree ---
rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/test-never-written.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}
  - result: FAILED (exit 1)")" "$TEST_DIR"
assert_exit_code "nonexistent test path: blocks" "$RR_EC" 1
assert_eq "nonexistent test path: reason is 'corrupt'" "$RR_REASON" "corrupt"
assert_contains "nonexistent test path: names the path" "$RR_STDERR" "tests/test-never-written.sh"

rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: ${TEST_DIR}/tests/test-foo.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}
  - result: FAILED (exit 1)")" "$TEST_DIR"
assert_eq "absolute test path: reason is corrupt" "$RR_REASON" "corrupt"
assert_contains "absolute test path: repository-relative tests path required" "$RR_STDERR" "must be repository-relative and under a configured tests root (tests)"

rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/../scripts/foo.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}
  - result: FAILED (exit 1)")" "$TEST_DIR"
assert_eq "traversal test path: reason is corrupt" "$RR_REASON" "corrupt"
assert_contains "traversal test path: dot segments rejected" "$RR_STDERR" "must not contain '.' or '..' segments"

ln -s "$TEST_DIR/scripts/foo.sh" "$TEST_DIR/tests/test-linked.sh"
rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/test-linked.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}
  - result: FAILED (exit 1)")" "$TEST_DIR"
assert_eq "symlink test path: reason is corrupt" "$RR_REASON" "corrupt"
assert_contains "symlink test path: regular non-symlink file required" "$RR_STDERR" "regular non-symlink file"

# --- entry with no result: line at all ---
rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: tests/test-foo.sh :: case \"x\"
  - pre-change-ref: ${BASE_SHA}")" "$TEST_DIR"
assert_exit_code "entry with no result line: blocks" "$RR_EC" 1
assert_eq "entry with no result line: reason is 'corrupt'" "$RR_REASON" "corrupt"

# ---------------------------------------------------------------------------
# STATE 5/6 — the CLOSED N/A list, and free text rejected
# ---------------------------------------------------------------------------
for tok in docs-only comment-only revert fixture-capture-only; do
  rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: N/A — ${tok}")" "$TEST_DIR"
  assert_exit_code "N/A — ${tok}: allowed (enumerated)" "$RR_EC" 0
  assert_eq "N/A — ${tok}: reason is 'enumerated_na'" "$RR_REASON" "enumerated_na"
done
assert_contains "enumerated N/A is recorded on stderr, not silent" "$RR_STDERR" "enumerated exemption, recorded"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: N/A — no time, will add later')" "$TEST_DIR"
assert_exit_code "N/A free text: blocks" "$RR_EC" 1
assert_eq "N/A free text: reason is 'bad_na_token'" "$RR_REASON" "bad_na_token"
assert_contains "N/A free text: distinct diagnostic naming the closed list" \
  "$RR_STDERR" "is not in the closed exemption list"
STDERR_BAD_NA="$RR_STDERR"

# A token that merely CONTAINS an enumerated one is not that token.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: N/A — docs-only-ish')" "$TEST_DIR"
assert_eq "N/A list is exact-match, not substring" "$RR_REASON" "bad_na_token"

# ---------------------------------------------------------------------------
# SEVEN DISTINCT DIAGNOSTICS — a reason the operator cannot tell apart from
# another reason is one collapsed state wearing seven names.
# ---------------------------------------------------------------------------
# Compared as whole diagnostics, not as lines: every blocking reason shares one
# trailing remediation line, so a line-wise sort -u would count that shared line
# as a seventh "diagnostic" and stop measuring distinguishability at all.
distinct_diagnostics() {
  local blob
  for blob in "$@"; do
    printf '%s' "$blob" | tr '\n' '\037'
    printf '\n'
  done | sort -u | wc -l | tr -d ' '
}
DISTINCT_COUNT=$(distinct_diagnostics \
  "$STDERR_ABSENT" "$STDERR_CORRUPT" "$STDERR_REF" "$STDERR_ANCESTOR" \
  "$STDERR_EXIT_ZERO" "$STDERR_BAD_NA" "$STDERR_COMMENTED")
assert_eq "seven block reasons emit seven distinct stderr diagnostics" "$DISTINCT_COUNT" "7"
assert_not_contains "the allow-with-announce diagnostic is distinct from the absent block" \
  "$STDERR_NOT_APPLICABLE" "no ## Red-Run Evidence section, but this task's scope touches"

# ---------------------------------------------------------------------------
# SECTION SCOPING — the `## Red-Run Evidence` heading IS the boundary. A
# `red-run:` token anywhere else is invisible, exactly as a hex token outside
# `## Commits` is invisible to the commit gate.
# ---------------------------------------------------------------------------
DECOY=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\n- red-run: tests/test-foo.sh :: case "decoy in Description"\n  - pre-change-ref: %s\n  - result: FAILED (exit 1)\n' \
  "$BASE_SHA" "$HEAD_SHA" "$BASE_SHA")
rr_call "$DECOY" "$TEST_DIR"
assert_exit_code "red-run: token outside the section is invisible to the gate" "$RR_EC" 1
assert_eq "decoy entry does not satisfy the gate" "$RR_REASON" "absent"

# A following `## ` heading closes the section, so an entry after it is outside.
AFTER_BOUNDARY=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Red-Run Evidence\n<!-- empty -->\n\n## Description\n- red-run: N/A — docs-only\n' \
  "$BASE_SHA" "$HEAD_SHA")
rr_call "$AFTER_BOUNDARY" "$TEST_DIR"
assert_eq "entry after the next ## heading does not count as an entry" "$RR_REASON" "commented_out"

# ---------------------------------------------------------------------------
# KILL SWITCH — guards.red_run_evidence: false suppresses the BLOCK ONLY.
# ---------------------------------------------------------------------------
setup_nazgul_dir
create_config '.guards.red_run_evidence = false'
rm -f "$TEST_DIR/nazgul/logs/events.jsonl"
rr_call "$NO_SECTION" "$TEST_DIR"
assert_exit_code "kill switch off: block suppressed" "$RR_EC" 0
assert_eq "kill switch off: reason still recorded" "$RR_REASON" "absent"
assert_contains "kill switch off: diagnostic still fires" "$RR_STDERR" "[reason: absent]"
assert_contains "kill switch off: suppression itself is announced" \
  "$RR_STDERR" "block suppressed by guards.red_run_evidence: false"
assert_eq "kill switch off: red_run_missing event still fires" \
  "$(jq -r 'select(.event == "red_run_missing") | .reason' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)" \
  "absent"

create_config '.guards.red_run_evidence = true'
rr_call "$NO_SECTION" "$TEST_DIR"
assert_exit_code "kill switch on (explicit true): blocks" "$RR_EC" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# D-3 SCOPE PREDICATE — UNION of the manifest field and the Base SHA..HEAD diff
# ---------------------------------------------------------------------------
setup_rr_repo
# The manifest UNDERSTATES its scope (docs only) but the diff touches scripts/.
# Understating the field is exactly how a task would evade this gate, so the
# field alone cannot decide it.
UNDERSTATED=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$BASE_SHA" "$HEAD_SHA")
rr_call "$UNDERSTATED" "$TEST_DIR"
assert_exit_code "union: git diff puts an understating manifest in scope" "$RR_EC" 1
assert_eq "union: understated manifest still reasons 'absent'" "$RR_REASON" "absent"
assert_not_contains "union: predicate was NOT degraded — the diff was computable" \
  "$RR_STDERR" "degraded to manifest-only"

# The other half of the union: the diff says docs-only, the manifest says tests/.
git -C "$TEST_DIR" checkout -q -b docs-only-branch "$BASE_SHA"
mkdir -p "$TEST_DIR/docs"
printf 'doc\n' > "$TEST_DIR/docs/PRD.md"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "docs only"
DOCS_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
MANIFEST_ARM=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["tests/test-foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$BASE_SHA" "$DOCS_HEAD")
rr_call "$MANIFEST_ARM" "$TEST_DIR"
assert_exit_code "union: manifest field alone puts a docs-only diff in scope" "$RR_EC" 1

# Neither arm in scope: allowed.
NEITHER=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Description\nx\n' "$BASE_SHA" "$DOCS_HEAD")
rr_call "$NEITHER" "$TEST_DIR"
assert_exit_code "union: neither arm in scope allows" "$RR_EC" 0
assert_eq "union: neither arm in scope reasons 'not_applicable'" "$RR_REASON" "not_applicable"
assert_not_contains "union: a computable diff is never reported as degraded" \
  "$RR_STDERR" "degraded to manifest-only"
teardown_temp_dir

# --- THIRD STATE: the diff cannot be computed at all ---
# "Could not look" is not "looked and found nothing" — the degrade is announced,
# never silent, and falls back to the manifest field alone.
setup_rr_repo
NO_BASE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n\n## Commits\n- %s\n\n## Description\nx\n' "$HEAD_SHA")
rr_call "$NO_BASE" "$TEST_DIR"
assert_exit_code "degraded (no Base SHA): falls back to manifest-only, allows" "$RR_EC" 0
assert_contains "degraded (no Base SHA): announced on stderr" \
  "$RR_STDERR" "red-run scope predicate degraded to manifest-only (no Base SHA in the manifest)"

BAD_BASE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n\n## Commits\n- %s\n\n## Description\nx\n' "$HEAD_SHA")
rr_call "$BAD_BASE" "$TEST_DIR"
assert_contains "degraded (unresolvable Base SHA): names that reason, distinctly" \
  "$RR_STDERR" "Base SHA deadbeefdeadbeefdeadbeefdeadbeefdeadbeef does not resolve"
teardown_temp_dir

setup_temp_dir
mkdir -p "$TEST_DIR/tests"
NO_REPO=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["docs/PRD.md"]\n- **Base SHA**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n\n## Commits\n- deadbeef\n\n## Description\nx\n')
rr_call "$NO_REPO" "$TEST_DIR"
assert_contains "degraded (non-repo project root): names that reason, distinctly" \
  "$RR_STDERR" "degraded to manifest-only (project root is not a git repository)"
teardown_temp_dir

# ---------------------------------------------------------------------------
# CALL SITE 1 — scripts/task-state-guard.sh IMPLEMENTED gate
# ---------------------------------------------------------------------------
run_guard() {
  GUARD_STDERR=$(echo "$1" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
}

guard_write_input() {
  jq -n --arg fp "$TEST_DIR/nazgul/tasks/TASK-001.md" --arg content "$1" \
    '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}'
}

# Manifest as the implementer would write it at IMPLEMENTED: real commit SHA,
# scope touching scripts/**, and (in the first case) no red-run evidence.
guard_manifest() {
  printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-001: Test\n\n## Metadata\n- **ID**: TASK-001\n- **Group**: 1\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n%s\n' \
    "$BASE_SHA" "$HEAD_SHA" "$1"
}

setup_rr_repo
setup_nazgul_dir
create_config
printf -- '---\nstatus: IN_PROGRESS\n---\n# TASK-001: Test\n\n- **Group**: 1\n' > "$TEST_DIR/nazgul/tasks/TASK-001.md"

# Under ADR-020 no direct status write is ever allowed, so exit 2 alone proves
# nothing about this gate. What distinguishes the states is WHICH refusal the
# operator gets: a refusal FOR the evidence, or a routing to the transactional
# command that would then have applied the edge.
ROUTED="Direct task-status edits cannot record completed-write authority"
REFUSED="failed the shared transition/evidence validation"

run_guard "$(guard_write_input "$(guard_manifest '')")"
assert_exit_code "call site 1: IN_PROGRESS->IMPLEMENTED with a real SHA but no red-run evidence is BLOCKED" "$GUARD_EC" 2
assert_contains "call site 1: block is the evidence refusal" "$GUARD_STDERR" "$REFUSED"
assert_contains "call site 1: block names red-run evidence" "$GUARD_STDERR" "IMPLEMENTED requires verified red-run evidence"
assert_contains "call site 1: block names the enumerated exemption escape" "$GUARD_STDERR" "red-run: N/A — docs-only"
assert_contains "call site 1: the shared library's own diagnostic reaches the operator" \
  "$GUARD_STDERR" "[reason: absent]"
assert_not_contains "call site 1: refused evidence is not routed to the command" "$GUARD_STDERR" "$ROUTED"

run_guard "$(guard_write_input "$(guard_manifest "
## Red-Run Evidence
$(valid_entry)
")")"
assert_exit_code "call site 1: same transition WITH valid red-run evidence is still denied as a direct write" "$GUARD_EC" 2
assert_contains "call site 1: valid evidence is routed, not refused" "$GUARD_STDERR" "$ROUTED"
assert_contains "call site 1: routing names the exact edge for the command" \
  "$GUARD_STDERR" "scripts/task-transition.sh transition TASK-001 IN_PROGRESS IMPLEMENTED"
assert_not_contains "call site 1: valid evidence is not blamed" "$GUARD_STDERR" "$REFUSED"

run_guard "$(guard_write_input "$(guard_manifest '
## Red-Run Evidence
- red-run: N/A — docs-only
')")"
assert_exit_code "call site 1: enumerated N/A exemption reaches the routing, not the refusal" "$GUARD_EC" 2
assert_contains "call site 1: enumerated N/A is routed to the command" "$GUARD_STDERR" "$ROUTED"

run_guard "$(guard_write_input "$(guard_manifest '
## Red-Run Evidence
- red-run: N/A — I ran them locally
')")"
assert_exit_code "call site 1: free-text N/A is BLOCKED" "$GUARD_EC" 2
assert_contains "call site 1: free-text N/A is refused for evidence" "$GUARD_STDERR" "$REFUSED"

# The commit gate still runs FIRST — a manifest with red-run evidence but no
# commit SHA must still be refused for the commit, not silently reordered.
run_guard "$(guard_write_input "$(printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-001: Test\n\n- **Group**: 1\n\n## Red-Run Evidence\n%s\n' "$(valid_entry)")")"
assert_exit_code "call site 1: commit gate still blocks first when no SHA is recorded" "$GUARD_EC" 2
assert_contains "call site 1: commit gate's own message, not the red-run one" "$GUARD_STDERR" "commit SHA"

create_config '.guards.red_run_evidence = false'
run_guard "$(guard_write_input "$(guard_manifest '')")"
assert_exit_code "call site 1: kill switch off — evidence no longer refuses the edge" "$GUARD_EC" 2
assert_contains "call site 1: kill switch off — the write is routed to the command" "$GUARD_STDERR" "$ROUTED"
assert_not_contains "call site 1: kill switch off — nothing is refused for evidence" "$GUARD_STDERR" "$REFUSED"
assert_contains "call site 1: kill switch off — diagnostic still reaches the operator" \
  "$GUARD_STDERR" "[reason: absent]"

# The gate the guard now only diagnoses is the one the transactional command
# enforces. Prove both verdicts survive in ttg_validate_transition itself, so
# "everything is denied" cannot hide a gate that stopped deciding.
create_config
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" TASK-001 IN_PROGRESS IMPLEMENTED \
  "$(guard_manifest "
## Red-Run Evidence
$(valid_entry)
")" 2>/dev/null; then
  _pass "shared validator still admits the edge when red-run evidence verifies"
else
  _fail "shared validator still admits the edge when red-run evidence verifies" "expected: 0" "  actual: nonzero"
fi
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" TASK-001 IN_PROGRESS IMPLEMENTED \
  "$(guard_manifest '')" 2>/dev/null; then
  _fail "shared validator still refuses the edge when red-run evidence is absent" "expected: nonzero" "  actual: 0"
else
  _pass "shared validator still refuses the edge when red-run evidence is absent"
fi
teardown_temp_dir

# ---------------------------------------------------------------------------
# CALL SITE 2 — scripts/stop-hook.sh bash-write reconciliation re-verification
# ---------------------------------------------------------------------------
run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

recon_manifest() {
  printf -- '---\nstatus: %s\n---\n# TASK-001: Test\n\n## Metadata\n- **ID**: TASK-001\n- **Group**: 1\n- **Depends on**: none\n- **Retry count**: 0/3\n- **Files modified**: ["scripts/foo.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n%s\n' \
    "$1" "$BASE_SHA" "$HEAD_SHA" "${2:-}"
}

setup_rr_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
recon_manifest "IN_PROGRESS" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
# Bash write — never through task-state-guard.sh, so never through the gate.
recon_manifest "IMPLEMENTED" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
assert_eq "call site 2: untraceable IMPLEMENTED with no red-run evidence is flagged BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_contains "call site 2: diagnostic names red-run evidence distinctly" \
  "$HOOK_OUTPUT" "carries no verified red-run evidence (absent)"
assert_contains "call site 2: blocked reason recorded on the manifest names red-run evidence" \
  "$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md")" "unverified red-run evidence (absent)"
teardown_temp_dir

# Valid red-run evidence does NOT excuse the bash-write bypass: the task is
# still BLOCKED, but under the original MF-022 reason, not the red-run one.
setup_rr_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
recon_manifest "IN_PROGRESS" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
recon_manifest "IMPLEMENTED" "
## Red-Run Evidence
$(valid_entry)
" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
assert_eq "call site 2: bypass with valid red-run evidence is still BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_contains "call site 2: reason falls back to the MF-022 bypass, not red-run" \
  "$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md")" "outside the guarded"
assert_not_contains "call site 2: red-run is not blamed when the evidence verifies" \
  "$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md")" "unverified red-run evidence"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MANIFEST CONTRACT — templates/task-manifest.md
# ---------------------------------------------------------------------------
MANIFEST_TEMPLATE="$REPO_ROOT/templates/task-manifest.md"
assert_file_contains "template declares a ## Red-Run Evidence section" \
  "$MANIFEST_TEMPLATE" '^## Red-Run Evidence'
assert_file_contains "template states the heading IS the enforcement boundary" \
  "$MANIFEST_TEMPLATE" 'heading IS the enforcement boundary'
assert_file_contains "template names the closed exemption list" \
  "$MANIFEST_TEMPLATE" 'docs-only, comment-only, revert, fixture-capture-only'

TEMPLATE_HEADINGS=$(grep -n '^## ' "$MANIFEST_TEMPLATE" | grep -E 'Commits|Red-Run Evidence|Description' | awk -F: '{print $2}' | tr '\n' '|')
assert_eq "## Red-Run Evidence sits immediately after ## Commits" \
  "$TEMPLATE_HEADINGS" "## Commits|## Red-Run Evidence|## Description|"

# The template as the planner ships it: a real Base SHA and a real descendant
# commit satisfy the COMMIT gate, but the untouched Red-Run section remains
# logically absent after its HTML commentary is stripped.
setup_rr_repo
TEMPLATE_FILLED=$(sed "s|^- \*\*Base SHA\*\*:.*|- **Base SHA**: ${BASE_SHA}|" "$MANIFEST_TEMPLATE" \
  | sed "/^## Commits$/a\\
- ${HEAD_SHA} — feat: work")
if ttg_verify_commit_evidence "$TEMPLATE_FILLED" "$TEST_DIR"; then
  _pass "template with a real descendant commit passes the commit gate"
else
  _fail "template with a real descendant commit passes the commit gate" "expected: 0" "  actual: nonzero"
fi
rr_call "$TEMPLATE_FILLED" "$TEST_DIR"
assert_exit_code "template's untouched Red-Run section fails this gate" "$RR_EC" 1
assert_eq "template's untouched Red-Run section is named as commented, not as absent" \
  "$RR_REASON" "commented_out"
teardown_temp_dir

report_results
