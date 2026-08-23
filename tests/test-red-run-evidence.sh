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
VOCAB_EXPECTED='absent absent_in_tree bad_na_token commented_out corrupt discoverable_test_file exit_zero not_ancestor ref_unresolvable roots_undeterminable roots_unresolved unbound_file_scoped_na uncovered_test_file undiscoverable_unverifiable'
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

# The EXEMPTION vocabulary, read out of the shipped constant rather than restated here, so
# a sixth token cannot be added without this file and every surface below noticing.
NA_TOKENS="${_TTG_RED_RUN_NA_TOKENS:-}"
NA_FILE_SCOPED="${_TTG_RED_RUN_FILE_SCOPED_NA:-}"
NA_TASK_WIDE=$(printf '%s\n' "$NA_TOKENS" | tr ' ' '\n' | grep -vxF "$NA_FILE_SCOPED" | tr '\n' ' ')
NA_TOKEN_N=$(printf '%s\n' "$NA_TOKENS" | tr ' ' '\n' | grep -c '[^[:space:]]')
if [ "$NA_TOKEN_N" -ge 2 ] && [ -n "$NA_FILE_SCOPED" ]; then
  _pass "na-token-vocabulary: derived $NA_TOKEN_N members from the shipped constant (file-scoped: $NA_FILE_SCOPED)"
else
  _fail "na-token-vocabulary: derived from the shipped constant" \
    "_TTG_RED_RUN_NA_TOKENS='$NA_TOKENS' file-scoped='$NA_FILE_SCOPED' — a vocabulary that cannot be read is 'never looked', and every case below would run on an empty set"
fi

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
  "$RR_STDERR" "red-run-evidence/tests-root: 2 scanned, 1 skipped (unsafe=0, unresolvable=1), 1 checked, 1 findings"
assert_contains "skipped root: the scan names where the set came from" "$RR_STDERR" "source=config"

# "Could not determine the roots" is a DIFFERENT state from "determined them and
# nothing matched", and it fails closed rather than quietly excusing the task.
create_config '.project.test_roots = []'
rr_call "$MONO_OUT_OF_SCOPE" "$TEST_DIR"
assert_exit_code "undeterminable roots: fails closed on an out-of-scope task" "$RR_EC" 1
assert_contains "undeterminable roots: distinct, loud diagnostic" \
  "$RR_STDERR" "could not determine the tests roots (project.test_roots is an empty array)"
assert_not_contains "undeterminable roots: never printed as a completed scan" \
  "$RR_STDERR" "red-run-evidence/tests-root:"
assert_not_contains "undeterminable roots: never printed as the degrade path" \
  "$RR_STDERR" "degraded to manifest-only"

rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_exit_code "undeterminable roots: an entry cannot be judged either" "$RR_EC" 1
assert_eq "undeterminable roots: reason is 'roots_undeterminable'" "$RR_REASON" "roots_undeterminable"

# A well-formed array whose every entry is REJECTED has the same semantics as [] —
# nothing left to trigger on — so it must take the same disposition, not the opposite.
create_config '.project.test_roots = ["/tests"]'
rr_call "$MONO_OUT_OF_SCOPE" "$TEST_DIR"
assert_exit_code "all-unsafe roots: fails closed exactly as the empty array does" "$RR_EC" 1
assert_contains "all-unsafe roots: names why the set is undeterminable" \
  "$RR_STDERR" "every entry (1 of 1) was rejected as an unsafe path"
assert_not_contains "all-unsafe roots: never printed as a completed scan" \
  "$RR_STDERR" "red-run-evidence/tests-root:"
rr_call "$(rr_manifest '["scripts/foo.sh"]' "$(mono_entry src/App/tests/test-app.sh)")" "$TEST_DIR"
assert_eq "all-unsafe roots: an entry cannot be judged either" "$RR_REASON" "roots_undeterminable"

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
["../outside/tests"]|src/App/tests/test-app.sh|roots_undeterminable|1
["/tests","./../x"]|src/App/tests/test-app.sh|roots_undeterminable|1'
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
assert_eq "root-matrix: every configured row was actually checked" "$RC_CHECKED" "10"
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
assert_eq "valid entry: stderr is the per-file coverage record and nothing else" \
  "$(printf '%s\n' "$RR_STDERR" | grep -cv 'red-run-evidence/files:')" "0"
assert_contains "valid entry: the per-file scan reports what it enumerated" \
  "$RR_STDERR" "red-run-evidence/files: 0 scanned, 0 skipped (support=0, enumerated-na=0), 0 checked, 0 findings"

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
for tok in $NA_TASK_WIDE; do
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


# PER-FILE DENOMINATOR (TASK-017 / board-4 item 5a) — the obligation is one entry
# per changed test file, derived from Base SHA..the task's own recorded commits.
setup_rr_multi_repo() {
  setup_temp_dir
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "test@nazgul.dev"
  git -C "$TEST_DIR" config user.name "Nazgul Test"
  mkdir -p "$TEST_DIR/tests/lib" "$TEST_DIR/scripts"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/tests/test-a.sh"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/tests/run-tests.sh"
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/tests/lib/helper.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "base"
  BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  printf 'echo a\n' >> "$TEST_DIR/tests/test-a.sh"
  printf '#!/usr/bin/env bash\necho b\n' > "$TEST_DIR/tests/test-b.sh"
  printf 'echo helper\n' >> "$TEST_DIR/tests/lib/helper.sh"
  printf 'echo harness\n' >> "$TEST_DIR/tests/run-tests.sh"
  git -C "$TEST_DIR" add -A
  git -C "$TEST_DIR" commit -q -m "the task's work: two test files, a helper, the harness"
  HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
}

rr_entry_for() { # <rel-path>
  printf -- '- red-run: %s :: case "x"\n  - pre-change-ref: %s\n  - result: FAILED (exit 1)\n' \
    "$1" "$BASE_SHA"
}

setup_rr_multi_repo

rr_call "$(rr_manifest '["tests/test-a.sh","tests/test-b.sh"]' "$(rr_entry_for tests/test-a.sh)")" "$TEST_DIR"
assert_exit_code "per-file: two changed test files with evidence for one BLOCKS" "$RR_EC" 1
assert_eq "per-file: the refusal is named, not folded into corrupt" "$RR_REASON" "uncovered_test_file"
assert_contains "per-file: the refusal names the uncovered file" "$RR_STDERR" "tests/test-b.sh"
assert_not_contains "per-file: the covered file is not blamed" \
  "$(printf '%s\n' "$RR_STDERR" | grep 'no red-run entry naming them')" "tests/test-a.sh"

RR_COV_LINE=$(printf '%s\n' "$RR_STDERR" | grep -o 'red-run-evidence/files: [0-9].*findings' | head -1)
assert_eq "per-file: the coverage line reports the derived population" "$RR_COV_LINE" \
  "red-run-evidence/files: 4 scanned, 2 skipped (support=2, enumerated-na=0), 2 checked, 1 findings"
RR_COV_N=$(printf '%s' "$RR_COV_LINE" | sed -E 's/^.*files: ([0-9]+) scanned.*/\1/')
RR_COV_M=$(printf '%s' "$RR_COV_LINE" | sed -E 's/^.* ([0-9]+) skipped.*/\1/')
RR_COV_K=$(printf '%s' "$RR_COV_LINE" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
assert_eq "per-file: N == M + K on the gate's own line" "$RR_COV_N" "$((RR_COV_M + RR_COV_K))"
assert_contains "per-file: the two skips are named, never silent" "$RR_STDERR" \
  "harness or non-test input, so it carries no entry of its own:"

rr_call "$(rr_manifest '["tests/test-a.sh","tests/test-b.sh"]' "$(rr_entry_for tests/test-a.sh)
$(rr_entry_for tests/test-b.sh)")" "$TEST_DIR"
assert_exit_code "per-file: an entry for each changed test file ALLOWS" "$RR_EC" 0
assert_eq "per-file: covered both, so the reason is 'verified'" "$RR_REASON" "verified"
assert_contains "per-file: both files counted as checked, none as a finding" "$RR_STDERR" \
  "red-run-evidence/files: 4 scanned, 2 skipped (support=2, enumerated-na=0), 2 checked, 0 findings"

# The harness exclusion is READ from the producer, so the two cannot drift apart.
assert_eq "per-file: the never-copy set is the producer's own RR_NEVER_COPY" \
  "$(_ttg_rr_never_copy | tr '\n' ' ')" \
  "$(sed -n '/^RR_NEVER_COPY="/,/"$/p' "$REPO_ROOT/scripts/red-run.sh" | sed 's/^RR_NEVER_COPY="//; s/"$//' | tr '\n' ' ')"

# An enumerated N/A is a whole-task discharge the producer cannot emit per file:
# still allowed, but every discharged file lands in its own reported bucket.
rr_call "$(rr_manifest '["tests/test-a.sh","tests/test-b.sh"]' '- red-run: N/A — revert')" "$TEST_DIR"
assert_exit_code "per-file: an enumerated N/A still allows" "$RR_EC" 0
assert_contains "per-file: the N/A discharge is counted in its own bucket, not as checked" \
  "$RR_STDERR" "red-run-evidence/files: 4 scanned, 4 skipped (support=0, enumerated-na=4), 0 checked, 0 findings"

# Attribution is each recorded commit's OWN diff: a manifest's planning-time Base SHA is
# routinely merges behind the branch point, so a range charges this task with others' work.
git -C "$TEST_DIR" checkout -q -b stale-base-probe
printf 'echo unrelated\n' >> "$TEST_DIR/tests/test-a.sh"
printf '#!/usr/bin/env bash\necho other\n' > "$TEST_DIR/tests/test-someone-elses.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "another task's work, merged in before this task branched"
printf '#!/usr/bin/env bash\necho mine\n' > "$TEST_DIR/tests/test-mine.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "this task's only commit"
MINE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
STALE_BASE=$(printf '## Metadata\n- **ID**: TASK-001\n- **Files modified**: ["tests/test-mine.sh"]\n- **Base SHA**: %s\n\n## Commits\n- %s\n\n## Red-Run Evidence\n%s\n\n## Description\nx\n' \
  "$BASE_SHA" "$MINE_SHA" "$(rr_entry_for tests/test-mine.sh)")
rr_call "$STALE_BASE" "$TEST_DIR"
assert_exit_code "attribution: a stale Base SHA does not charge this task with another's files" "$RR_EC" 0
assert_contains "attribution: only the recorded commit's own diff is the population" \
  "$RR_STDERR" "red-run-evidence/files: 1 scanned, 0 skipped (support=0, enumerated-na=0), 1 checked, 0 findings"
assert_not_contains "attribution: the interloper commit's file is not in the denominator" \
  "$RR_STDERR" "tests/test-someone-elses.sh"
assert_contains "attribution: the source names what it enumerated" \
  "$RR_STDERR" "source=the own-diff of 1 recorded commit(s)"
git -C "$TEST_DIR" checkout -q -

# A denominator that cannot be enumerated says so; it never reports an empty population.
NOT_A_REPO=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-rr-norepo-XXXXXX")
mkdir -p "$NOT_A_REPO/tests"
rr_call "$(rr_manifest '["tests/test-a.sh"]' '- red-run: N/A — revert')" "$NOT_A_REPO"
assert_exit_code "per-file: an underivable denominator does not invent a block" "$RR_EC" 0
assert_contains "per-file: an underivable denominator is announced, not counted as zero" \
  "$RR_STDERR" "DENOMINATOR NOT ENUMERATED (git is unavailable, or ${NOT_A_REPO} is not a git repository"
assert_not_contains "per-file: no coverage line is emitted over a population that was never enumerated" \
  "$RR_STDERR" "0 scanned, 0 skipped (support=0"
rm -rf "$NOT_A_REPO"

# #198's neighbour: a well-formed entry whose file this tree does not hold is a
# DIFFERENT refusal from a malformed one, and it names the tree it looked in.
git -C "$TEST_DIR" rm -q --cached tests/test-b.sh >/dev/null
rm -f "$TEST_DIR/tests/test-b.sh"
rr_call "$(rr_manifest '["tests/test-a.sh","tests/test-b.sh"]' "$(rr_entry_for tests/test-b.sh)")" "$TEST_DIR"
assert_exit_code "absent-in-tree: still blocks" "$RR_EC" 1
assert_eq "absent-in-tree: the reason is not 'corrupt'" "$RR_REASON" "absent_in_tree"
assert_contains "absent-in-tree: names the tree the gate actually read" "$RR_STDERR" \
  "absent from the tree this gate reads ($TEST_DIR)"
assert_contains "absent-in-tree: says the entry itself is well-formed" "$RR_STDERR" \
  "the entry is not malformed"
rr_call "$(rr_manifest '["tests/test-a.sh"]' "$(rr_entry_for tests/test-never-committed.sh)")" "$TEST_DIR"
assert_eq "absent-in-tree: a path in no commit at all is still 'corrupt'" "$RR_REASON" "corrupt"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MANIFEST CONTRACT — templates/task-manifest.md
# ---------------------------------------------------------------------------
MANIFEST_TEMPLATE="$REPO_ROOT/templates/task-manifest.md"
assert_file_contains "template declares a ## Red-Run Evidence section" \
  "$MANIFEST_TEMPLATE" '^## Red-Run Evidence'
assert_file_contains "template states the heading IS the enforcement boundary" \
  "$MANIFEST_TEMPLATE" 'heading IS the enforcement boundary'
for tok in $NA_TOKENS; do
  assert_file_contains "template names closed-exemption member '${tok}'" "$MANIFEST_TEMPLATE" "$tok"
done

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

# THE FIFTH TOKEN — file-scoped, CHECKED rather than declared (TASK-048). Both
# directions below: a token that only ADMITS is a general-purpose red-run bypass.
setup_rr_repo
mkdir -p "$TEST_DIR/tests/e2e"
# The REAL runner, so the glob under test is the shipped producer's own and not a
# fixture restating it — a restated glob agrees with itself and proves nothing.
cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/tests/run-tests.sh"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/tests/e2e/test-bar.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "the runner and a test it cannot discover"
HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

GLOB_LINE=$(grep -cE '^[[:space:]]*for [A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+"\$[A-Za-z_]+"/' "$TEST_DIR/tests/run-tests.sh")
assert_eq "the fixture runner really carries a parseable discovery line (else every case below is vacuous)" \
  "$GLOB_LINE" "1"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/e2e/test-bar.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "undiscoverable file + the file-scoped token: ALLOWED" "$RR_EC" 0
assert_eq "undiscoverable file: reason is 'enumerated_na'" "$RR_REASON" "enumerated_na"
assert_contains "the admit says it CHECKED, and against which glob — not that it was told" \
  "$RR_STDERR" "CHECKED against tests/run-tests.sh's own glob 'tests/test-*.sh'"

# The half without which the token proves nothing.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/test-foo.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "a DISCOVERABLE file declaring the same token: REFUSED" "$RR_EC" 1
assert_eq "discoverable file: reason is 'discoverable_test_file'" "$RR_REASON" "discoverable_test_file"
assert_contains "discoverable file: the refusal names the glob that reaches it" \
  "$RR_STDERR" "IS discovered by tests/run-tests.sh's own glob"

# A subdirectory is not globbed, but a matching NAME alone must not admit either:
# tests/e2e/test-bar.sh and tests/test-foo.sh differ only in directory.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/test-foo.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_eq "discoverability is directory AND pattern, not pattern alone" "$RR_REASON" "discoverable_test_file"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "the file-scoped token used task-wide: REFUSED (it would exempt every file)" "$RR_EC" 1
assert_eq "bare file-scoped token: reason is 'unbound_file_scoped_na', not 'bad_na_token'" \
  "$RR_REASON" "unbound_file_scoped_na"
assert_contains "bare file-scoped token: says a claim naming no file can be checked against nothing" \
  "$RR_STDERR" "names no file"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/e2e/test-bar.sh :: N/A — docs-only')" "$TEST_DIR"
assert_exit_code "a task-wide token in the file-scoped slot: REFUSED" "$RR_EC" 1
assert_eq "task-wide token given a path: reason is 'bad_na_token'" "$RR_REASON" "bad_na_token"

# A path the token names must still be a real file under a tests root: the fifth
# token cannot launder a path the other checks would refuse.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/e2e/test-nonexistent.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_eq "the token does not bypass the path checks it sits behind" "$RR_REASON" "corrupt"

# "Could not ask" is its own answer, and it is a REFUSAL — admitting an unverifiable
# claim turns the checked token straight back into the declaration it replaced.
rm -f "$TEST_DIR/tests/run-tests.sh"
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/e2e/test-bar.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "no runner to read the glob from: REFUSED, not admitted" "$RR_EC" 1
assert_eq "unreadable runner: reason is 'undiscoverable_unverifiable'" "$RR_REASON" "undiscoverable_unverifiable"
assert_contains "unverifiable: says the claim is refused rather than believed" \
  "$RR_STDERR" "refused, not believed"

# A runner present but carrying no parseable discovery line is the same refusal for
# a different reason, and the reason is named.
printf '#!/usr/bin/env bash\necho no discovery loop here\n' > "$TEST_DIR/tests/run-tests.sh"
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/e2e/test-bar.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_eq "unparseable runner: also 'undiscoverable_unverifiable'" "$RR_REASON" "undiscoverable_unverifiable"
assert_contains "unparseable runner: the diagnostic distinguishes it from an absent one" \
  "$RR_STDERR" "no 'for <var> in"

# The glob is READ from the runner, never restated in the guard: change the runner's
# glob and the verdict must follow it. A hard-coded copy would ignore this.
cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/tests/run-tests.sh"
sed -i.bak 's|"\$SCRIPT_DIR"/test-\*\.sh|"$SCRIPT_DIR"/check-*.sh|' "$TEST_DIR/tests/run-tests.sh"
rm -f "$TEST_DIR/tests/run-tests.sh.bak"
# Under 'check-*.sh' both files are undiscoverable, yet one entry discharges exactly
# ONE — the per-file coverage pass still runs after a file-scoped N/A.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/test-foo.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "one file-scoped N/A does NOT discharge the task's other changed test file" "$RR_EC" 1
assert_eq "the still-uncovered file is named 'uncovered_test_file'" "$RR_REASON" "uncovered_test_file"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: tests/test-foo.sh :: N/A — harness-undiscoverable
- red-run: tests/e2e/test-bar.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "the verdict follows the runner's glob: under 'check-*.sh' both files are undiscoverable" "$RR_EC" 0
assert_eq "changed glob: reason is 'enumerated_na'" "$RR_REASON" "enumerated_na"
assert_contains "and the diagnostic quotes the CHANGED glob, proving it was read not assumed" \
  "$RR_STDERR" "'tests/check-*.sh'"

# The task-wide tokens are untouched by the file-scoped one's arrival.
for tok in $NA_TASK_WIDE; do
  rr_call "$(rr_manifest '["scripts/foo.sh"]' "- red-run: N/A — ${tok}")" "$TEST_DIR"
  assert_eq "task-wide '${tok}' still exempts the whole task" "$RR_REASON" "enumerated_na"
done
teardown_temp_dir

# lean-comments: allow-run — names the false ADMIT this fixture exists to close.
# TWO ROOTS, TWO RUNNERS, TWO DIFFERENT GLOBS. Asking only the FIRST root reported a file
# the SECOND root's own runner discovers as undiscoverable, and ADMITTED it — a false
# exemption produced by the checker, not the operator. The globs differ on purpose, so a
# pass cannot come from the two roots happening to agree.
setup_monorepo_repo
create_config '.project.test_roots = ["src/App/tests", "src/Worker/tests"]'
cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/src/App/tests/run-tests.sh"
cp "$REPO_ROOT/tests/run-tests.sh" "$TEST_DIR/src/Worker/tests/run-tests.sh"
sed -i.bak 's|"\$SCRIPT_DIR"/test-\*\.sh|"$SCRIPT_DIR"/check-*.sh|' "$TEST_DIR/src/Worker/tests/run-tests.sh"
rm -f "$TEST_DIR/src/Worker/tests/run-tests.sh.bak"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/src/Worker/tests/check-worker.sh"
git -C "$TEST_DIR" add -A
git -C "$TEST_DIR" commit -q -m "a runner per root, with different globs"
assert_eq "[fixture] the second root's runner really carries the OTHER glob" \
  "$(grep -c 'check-\*\.sh' "$TEST_DIR/src/Worker/tests/run-tests.sh")" "1"

rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: src/Worker/tests/check-worker.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "two roots: a file the SECOND root's own runner discovers is REFUSED, not admitted" "$RR_EC" 1
assert_eq "two roots: reason is 'discoverable_test_file'" "$RR_REASON" "discoverable_test_file"
assert_contains "two roots: the refusal names the runner that contradicts the claim, not the first one" \
  "$RR_STDERR" "IS discovered by src/Worker/tests/run-tests.sh's own glob 'src/Worker/tests/check-*.sh'"

# Same directory, same file-name shape the FIRST root globs — and still undiscoverable,
# because discoverability is each root's OWN glob over its OWN directory.
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: src/Worker/tests/test-worker.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "two roots: a file NO root's runner reaches is still ALLOWED" "$RR_EC" 0
assert_eq "two roots: reason is 'enumerated_na'" "$RR_REASON" "enumerated_na"
assert_contains "two roots: the admit names EVERY root it was checked against, not just one" \
  "$RR_STDERR" "CHECKED against src/App/tests/run-tests.sh's own glob 'src/App/tests/test-*.sh', src/Worker/tests/run-tests.sh's own glob 'src/Worker/tests/check-*.sh'"

# "One root could not be read" is not "no root reaches this file": an unparseable runner
# under ANY configured root refuses the whole claim rather than being skipped past.
printf '#!/usr/bin/env bash\necho no discovery loop here\n' > "$TEST_DIR/src/Worker/tests/run-tests.sh"
rr_call "$(rr_manifest '["scripts/foo.sh"]' '- red-run: src/Worker/tests/test-worker.sh :: N/A — harness-undiscoverable')" "$TEST_DIR"
assert_exit_code "two roots: an unparseable runner under the SECOND root refuses the claim" "$RR_EC" 1
assert_eq "two roots: an unreadable root is 'undiscoverable_unverifiable', never a skip" \
  "$RR_REASON" "undiscoverable_unverifiable"
assert_contains "two roots: the refusal names WHICH root could not be read" \
  "$RR_STDERR" "src/Worker/tests/run-tests.sh is readable but no 'for <var> in"
teardown_temp_dir

# lean-comments: allow-run — the trigger rule and its scope are the whole argument here.
# THE VOCABULARY'S CONSUMERS. Members from the constant above; the surfaces that owe them
# from the TREE. The trigger is the claim itself, never punctuation: a paragraph that says
# the list is closed AND names two or more members is teaching the set and owes every one.
# Paragraph-scoped ON PURPOSE — naming the fifth token elsewhere in the same file is how
# docs/CONFIGURATION.md carried a four-member "closed list" row and a five-member event
# line at once, each true on its own line and contradictory as a file.
NA_CLOSURE_RE='closed list|list is closed|closed set'
NA_TRIGGER_MIN=2

_na_names() { grep -qE "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)" <<< "$2"; }

# lean-comments: allow-run — the population's boundaries, and why -mindepth 1 is load-bearing.
# -mindepth 1 keeps the prune list from matching the STARTING POINT: CI checks this repo out
# at /home/runner/work/nazgul/nazgul, whose basename is `nazgul`, so without it find prunes
# the whole tree and the scan reports 0 scanned / 0 findings — clean-looking and vacuous.
# Invisible locally, where the working copy is named ai-hydra-framework (cf. #89).
# _na_surfaces <root> <tokens> -> one `<rel>|<claiming-paragraphs>|<missing members>` record
# per candidate. docs/superpowers/** is DATED record, so binding it would rewrite history;
# the generated reviewer seats are per-project gitignored artifacts, checked where they
# exist and named as a skip where they do not.
_na_surfaces() {
  local root="$1" tokens="$2" f rel body rec hits miss tok claims
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root"/}"
    if [ ! -r "$f" ]; then printf '%s|unreadable|\n' "$rel"; continue; fi
    claims=0; miss=""
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      body="${rec#*|}"; body="${body//$'\002'/$'\n'}"
      grep -qiE "$NA_CLOSURE_RE" <<< "$body" || continue
      hits=0
      for tok in $tokens; do _na_names "$tok" "$body" && hits=$((hits + 1)); done
      [ "$hits" -ge "$NA_TRIGGER_MIN" ] || continue
      claims=$((claims + 1))
      for tok in $tokens; do _na_names "$tok" "$body" || miss="$miss $tok"; done
    done <<< "$(awk 'BEGIN{RS=""} {gsub(/\n/,"\002"); print NR "|" $0}' "$f")"
    printf '%s|%d|%s\n' "$rel" "$claims" \
      "$(printf '%s\n' "$miss" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  done <<< "$( { find "$root" -mindepth 1 \( -name .git -o -name nazgul -o -name node_modules \
                      -o -path "$root/docs/superpowers" -o -name .claude \) -prune \
                    -o -type f -name '*.md' -print
                  find "$root/.claude/agents/generated" -type f -name '*.md' -print; } 2>/dev/null )"
}

# _na_tally <root> <tokens> — sets NA_SCANNED/NA_SKIP_*/NA_CHECKED/NA_FINDINGS/NA_BAD.
_na_tally() {
  local rel claims miss
  NA_SCANNED=0; NA_SKIP_NOCLAIM=0; NA_SKIP_UNREADABLE=0; NA_CHECKED=0; NA_FINDINGS=0; NA_BAD=""
  while IFS='|' read -r rel claims miss; do
    [ -n "$rel" ] || continue
    NA_SCANNED=$((NA_SCANNED + 1))
    if [ "$claims" = "unreadable" ]; then
      NA_SKIP_UNREADABLE=$((NA_SKIP_UNREADABLE + 1))
    elif [ "$claims" -eq 0 ]; then
      NA_SKIP_NOCLAIM=$((NA_SKIP_NOCLAIM + 1))
    else
      NA_CHECKED=$((NA_CHECKED + 1))
      [ -n "$miss" ] && { NA_FINDINGS=$((NA_FINDINGS + 1)); NA_BAD="$NA_BAD$rel(${miss// /,}) "; }
    fi
  done <<< "$(_na_surfaces "$1" "$2")"
}

_na_tally "$REPO_ROOT" "$NA_TOKENS"
NA_SEATS_DIR="$REPO_ROOT/.claude/agents/generated"
if [ -d "$NA_SEATS_DIR" ]; then
  _pass "na-token-surfaces: the live generated reviewer seats are in the population ($(find "$NA_SEATS_DIR" -type f -name '*.md' | grep -c . ) seat file(s))"
else
  _skip "na-token-surfaces: no .claude/agents/generated here, so the live reviewer seats were NOT examined — present in an initialised project, absent in a fresh clone"
fi
assert_eq "na-token-surfaces: every surface that calls this list CLOSED names all $NA_TOKEN_N members" \
  "${NA_BAD% }" ""
NA_SURFACE_FLOOR=2
if [ "$NA_CHECKED" -ge "$NA_SURFACE_FLOOR" ]; then
  _pass "na-token-surfaces: the enumerator actually looked ($NA_CHECKED claiming surfaces >= $NA_SURFACE_FLOOR)"
else
  _fail "na-token-surfaces: the enumerator actually looked" \
    "only $NA_CHECKED claiming surface(s) under $REPO_ROOT — a trigger that stopped matching reports a clean tree with nothing checked"
fi
echo "  na-token-surfaces: ${NA_SCANNED} scanned, $((NA_SKIP_NOCLAIM + NA_SKIP_UNREADABLE)) skipped (no-closure-claim=${NA_SKIP_NOCLAIM}, unreadable=${NA_SKIP_UNREADABLE}), ${NA_CHECKED} checked, ${NA_FINDINGS} findings"
assert_eq "na-token-surfaces: scanned == skipped + checked" \
  "$NA_SCANNED" "$((NA_SKIP_NOCLAIM + NA_SKIP_UNREADABLE + NA_CHECKED))"

# The pass is worth only its ability to fail. Same tree, same trigger, one planted
# member: every surface that teaches the set must now owe the token none of them names.
NA_SHIPPED_CHECKED="$NA_CHECKED"
NA_PLANT="na-planted-sixth"
_na_tally "$REPO_ROOT" "$NA_TOKENS $NA_PLANT"
if [ "$NA_CHECKED" -eq "$NA_SHIPPED_CHECKED" ] && [ "$NA_FINDINGS" -eq "$NA_SHIPPED_CHECKED" ]; then
  _pass "[mutation] a sixth member with no surface update turns every one of the $NA_CHECKED claiming surfaces red"
else
  _fail "[mutation] a sixth member with no surface update turns every claiming surface red" \
    "checked=$NA_CHECKED (want $NA_SHIPPED_CHECKED), findings=$NA_FINDINGS (want $NA_SHIPPED_CHECKED) — the pass cannot fail, so its zero above proves nothing"
fi
case "$NA_BAD" in
  *"$NA_PLANT"*) _pass "[mutation] and the finding names the member the vocabulary added" ;;
  *) _fail "[mutation] and the finding names the member the vocabulary added" \
       "detail was '${NA_BAD% }', which does not name '$NA_PLANT'" ;;
esac

# The prune list names `nazgul`, and `find` applies its expression to the STARTING POINT
# too — so a checkout whose own basename is a prune token prunes the entire tree. CI hits
# this exactly (/home/runner/work/nazgul/nazgul) and a local clone never does.
NA_SELFPRUNE_ROOT="$(mktemp -d)/nazgul"
mkdir -p "$NA_SELFPRUNE_ROOT"
{
  printf 'A paragraph that calls this a closed list and names %s and %s.\n' \
    "${NA_TOKENS%% *}" "$(printf '%s' "$NA_TOKENS" | awk '{print $2}')"
} > "$NA_SELFPRUNE_ROOT/claim.md"
_na_tally "$NA_SELFPRUNE_ROOT" "$NA_TOKENS"
if [ "$NA_SCANNED" -ge 1 ]; then
  _pass "na-token-surfaces: a root whose basename is itself a prune token is still walked ($NA_SCANNED scanned)"
else
  _fail "na-token-surfaces: a root whose basename is itself a prune token is still walked" \
    "0 scanned under $NA_SELFPRUNE_ROOT — the prune list matched the starting point, so the whole tree vanished and the scan would report a clean 0 findings having examined nothing"
fi
rm -rf "$(dirname "$NA_SELFPRUNE_ROOT")"

report_results
