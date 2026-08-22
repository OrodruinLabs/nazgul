#!/usr/bin/env bash
set -uo pipefail

# Test: scripts/lib/task-transition-guard.sh — the shared transition/evidence
# library sourced by BOTH task-state-guard.sh (PreToolUse) and stop-hook.sh
# (reconciliation). Parity between the two call sites is asserted here at the
# function level; tests/test-task-state-guard.sh and tests/test-stop-hook.sh
# exercise the same functions end-to-end through each call site.
TEST_NAME="test-task-transition-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/task-transition-guard.sh"
source "$LIB"

# ---------------------------------------------------------------------------
# ttg_valid_transition — the full Constitution Article III table. Pairs are
# "FROM:TO" (colon-delimited, not underscore-split) so multi-word states like
# IN_PROGRESS/CHANGES_REQUESTED are never ambiguous with the delimiter.
# ---------------------------------------------------------------------------
VALID_PAIRS="PLANNED:READY PLANNED:BLOCKED READY:BLOCKED READY:IN_PROGRESS \
IN_PROGRESS:IMPLEMENTED IN_PROGRESS:BLOCKED IMPLEMENTED:BLOCKED \
IMPLEMENTED:IN_REVIEW IMPLEMENTED:DONE IN_REVIEW:DONE IN_REVIEW:APPROVED \
IN_REVIEW:CHANGES_REQUESTED IN_REVIEW:BLOCKED APPROVED:DONE APPROVED:BLOCKED \
CHANGES_REQUESTED:IN_PROGRESS CHANGES_REQUESTED:BLOCKED BLOCKED:READY \
BLOCKED:IN_REVIEW"
for pair in $VALID_PAIRS; do
  from="${pair%%:*}"
  to="${pair#*:}"
  if ttg_valid_transition "$from" "$to"; then
    _pass "ttg_valid_transition: ${from} -> ${to} allowed"
  else
    _fail "ttg_valid_transition: ${from} -> ${to} allowed" "expected: 0" "  actual: nonzero"
  fi
done

INVALID_PAIRS="PLANNED:IN_PROGRESS READY:IMPLEMENTED DONE:READY IN_PROGRESS:IN_REVIEW"
for pair in $INVALID_PAIRS; do
  from="${pair%%:*}"
  to="${pair#*:}"
  if ttg_valid_transition "$from" "$to"; then
    _fail "ttg_valid_transition: ${from} -> ${to} rejected" "expected: nonzero" "  actual: 0"
  else
    _pass "ttg_valid_transition: ${from} -> ${to} rejected"
  fi
done

# ---------------------------------------------------------------------------
# ttg_verify_commit_evidence — real verification, not a pattern match (MF-026)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
if ttg_verify_commit_evidence "## Commits
- ${REAL_SHA}" "$TEST_DIR"; then
  _pass "ttg_verify_commit_evidence: real reachable SHA verifies"
else
  _fail "ttg_verify_commit_evidence: real reachable SHA verifies" "expected: 0" "  actual: nonzero"
fi

if ttg_verify_commit_evidence "## Commits
- deadbeef1234" "$TEST_DIR"; then
  _fail "ttg_verify_commit_evidence: hex-looking nonexistent SHA rejected" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: hex-looking nonexistent SHA rejected"
fi
teardown_temp_dir

setup_temp_dir
# No setup_git_repo — TEST_DIR is not a git repo at all.
if ttg_verify_commit_evidence "## Commits
- deadbeef1234" "$TEST_DIR"; then
  _fail "ttg_verify_commit_evidence: non-repo project_root fails closed" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: non-repo project_root fails closed"
fi
teardown_temp_dir

setup_temp_dir
setup_git_repo
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
if (PATH="/nonexistent-bin-only" ttg_verify_commit_evidence "## Commits
- ${REAL_SHA}" "$TEST_DIR"); then
  _fail "ttg_verify_commit_evidence: git unavailable fails closed" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: git unavailable fails closed"
fi
teardown_temp_dir

# ---------------------------------------------------------------------------
# ttg_verify_commit_evidence — scoped to `## Commits` + descendant-of-Base
# (FEAT-023/TASK-006, Defect 5). Keystone: a manifest carrying only a Base
# SHA with no `## Commits` section used to pass vacuously (V3(a)); it must
# fail now.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD~1)
DESC_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

if ttg_verify_commit_evidence "## Metadata
- **Base SHA**: ${BASE_SHA}

## Description
work not yet committed under ## Commits" "$TEST_DIR"; then
  _fail "ttg_verify_commit_evidence: keystone — Base SHA with no ## Commits section rejected" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: keystone — Base SHA with no ## Commits section rejected"
fi

if ttg_verify_commit_evidence "## Metadata
- **Base SHA**: ${BASE_SHA}

## Commits
- ${DESC_SHA}" "$TEST_DIR"; then
  _pass "ttg_verify_commit_evidence: descendant of Base SHA in ## Commits verifies"
else
  _fail "ttg_verify_commit_evidence: descendant of Base SHA in ## Commits verifies" "expected: 0" "  actual: nonzero"
fi

if ttg_verify_commit_evidence "## Metadata
- **Base SHA**: ${BASE_SHA}

## Commits
- ${BASE_SHA}" "$TEST_DIR"; then
  _fail "ttg_verify_commit_evidence: Base SHA recorded as its own ## Commits entry rejected (no forward progress)" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: Base SHA recorded as its own ## Commits entry rejected (no forward progress)"
fi

if ttg_verify_commit_evidence "## Metadata
- **Base SHA**: ${BASE_SHA}

## Commits
- deadbeef1234" "$TEST_DIR"; then
  _fail "ttg_verify_commit_evidence: hex-shaped unresolvable ## Commits entry rejected (MF-026, scoped)" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_verify_commit_evidence: hex-shaped unresolvable ## Commits entry rejected (MF-026, scoped)"
fi

STDERR_OUT=$(ttg_verify_commit_evidence "## Commits
- ${DESC_SHA}" "$TEST_DIR" 2>&1 >/dev/null) && DEGRADE_EC=0 || DEGRADE_EC=$?
if [ "$DEGRADE_EC" -eq 0 ]; then
  _pass "ttg_verify_commit_evidence: no Base SHA degrades to existence-only (still passes)"
else
  _fail "ttg_verify_commit_evidence: no Base SHA degrades to existence-only (still passes)" "expected: 0" "  actual: nonzero"
fi
assert_contains "ttg_verify_commit_evidence: no-Base-SHA degradation is announced on stderr" \
  "$STDERR_OUT" "forward-progress check skipped"
DEGRADE_STDERR="$STDERR_OUT"
teardown_temp_dir

# Base SHA present-but-corrupt vs. absent (security B1, TASK-006 attempt 2):
# the two states must not collapse into the same degrade path. A garbled or
# fabricated Base SHA is a stronger trouble signal than a missing field and
# must fail CLOSED, not fall back to existence-only.
setup_temp_dir
setup_git_repo
UNRELATED_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
CORRUPT_STDERR=$(ttg_verify_commit_evidence "## Metadata
- **Base SHA**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

## Commits
- ${UNRELATED_SHA}" "$TEST_DIR" 2>&1 >/dev/null) && CORRUPT_EC=0 || CORRUPT_EC=$?
if [ "$CORRUPT_EC" -ne 0 ]; then
  _pass "ttg_verify_commit_evidence: present-but-unresolvable Base SHA + unrelated commit rejected"
else
  _fail "ttg_verify_commit_evidence: present-but-unresolvable Base SHA + unrelated commit rejected" "expected: nonzero" "  actual: 0"
fi
assert_contains "ttg_verify_commit_evidence: corrupt-Base-SHA rejection is announced on stderr" \
  "$CORRUPT_STDERR" "treated as corrupt"
if [ "$CORRUPT_STDERR" != "$DEGRADE_STDERR" ]; then
  _pass "ttg_verify_commit_evidence: corrupt-Base-SHA and absent-Base-SHA emit distinct diagnostics"
else
  _fail "ttg_verify_commit_evidence: corrupt-Base-SHA and absent-Base-SHA emit distinct diagnostics" \
    "expected: different stderr text" "  actual: byte-identical (\"$CORRUPT_STDERR\")"
fi
teardown_temp_dir

# Archived-manifest sweep (plan.md V3(c)): every FEAT-022 DONE manifest must
# still verify under the scoped + descendant-of-Base logic. Scoped to the
# FEAT-022 archive specifically — nazgul/archive/*/tasks/ also holds
# pre-FEAT-022 snapshots that predate the `## Commits` authoring convention
# (FEAT-022/TASK-004) and correctly have no evidence to find; sweeping those
# too would assert a property the objective never claimed for them. Skipped,
# not failed, when the archive isn't present (untracked runtime state).
shopt -s nullglob
ARCHIVE_FILES=("$REPO_ROOT"/nazgul/archive/*-FEAT-022-complete/tasks/TASK-*.md)
shopt -u nullglob
if [ "${#ARCHIVE_FILES[@]}" -eq 0 ]; then
  echo "  SKIP: archived-manifest sweep — no nazgul/archive/*-FEAT-022-complete/tasks/ present"
else
  assert_eq "archived-manifest sweep: nine FEAT-022 manifests found (plan.md V3(c))" "${#ARCHIVE_FILES[@]}" "9"
  for tf in "${ARCHIVE_FILES[@]}"; do
    manifest_text=$(cat "$tf")
    if ttg_verify_commit_evidence "$manifest_text" "$REPO_ROOT" 2>/dev/null; then
      _pass "ttg_verify_commit_evidence: archived $(basename "$(dirname "$(dirname "$tf")")")/$(basename "$tf") passes"
    else
      _fail "ttg_verify_commit_evidence: archived $(basename "$(dirname "$(dirname "$tf")")")/$(basename "$tf") passes" "expected: 0" "  actual: nonzero"
    fi
  done
fi

# Cross-check agreement with pre-merge-commit's commits_verify() on the
# SCOPING question: a Base-SHA-only manifest (no ## Commits) is evidence for
# neither check. Sources the real function text from the hook file itself
# (never edited or duplicated here) so this can't silently drift from it.
PRE_MERGE_HOOK="$REPO_ROOT/scripts/git-hooks/pre-merge-commit"
COMMITS_VERIFY_SRC=$(sed -n '/^commits_verify() {/,/^}/p' "$PRE_MERGE_HOOK")
if [ -n "$COMMITS_VERIFY_SRC" ]; then
  eval "$COMMITS_VERIFY_SRC"
  setup_temp_dir
  setup_git_repo
  CROSS_BASE=$(git -C "$TEST_DIR" rev-parse HEAD)
  CROSS_MANIFEST="$TEST_DIR/manifest.md"
  printf '## Metadata\n- **Base SHA**: %s\n' "$CROSS_BASE" > "$CROSS_MANIFEST"

  if ttg_verify_commit_evidence "$(cat "$CROSS_MANIFEST")" "$TEST_DIR"; then
    _fail "cross-check: ttg_verify_commit_evidence has no evidence for a Base-SHA-only manifest" "expected: nonzero" "  actual: 0"
  else
    _pass "cross-check: ttg_verify_commit_evidence has no evidence for a Base-SHA-only manifest"
  fi
  if commits_verify "$CROSS_MANIFEST" "$CROSS_BASE"; then
    _fail "cross-check: commits_verify has no evidence for a Base-SHA-only manifest" "expected: nonzero" "  actual: 0"
  else
    _pass "cross-check: commits_verify has no evidence for a Base-SHA-only manifest"
  fi
  teardown_temp_dir
else
  _fail "cross-check: commits_verify() extracted from pre-merge-commit" "expected: non-empty function source" "  actual: empty"
fi

# ---------------------------------------------------------------------------
# TASK-008 — authoring ends: templates/task-manifest.md and
# agents/implementer.md must actually declare what TASK-006's gate enforces.
# ---------------------------------------------------------------------------
MANIFEST_TEMPLATE="$REPO_ROOT/templates/task-manifest.md"
IMPLEMENTER_DOC="$REPO_ROOT/agents/implementer.md"

assert_file_contains "templates/task-manifest.md declares a Base SHA field" \
  "$MANIFEST_TEMPLATE" '\*\*Base SHA\*\*'

METADATA_BLOCK=$(awk '/^## Metadata/{f=1;next} /^## /{f=0} f' "$MANIFEST_TEMPLATE")
if printf '%s\n' "$METADATA_BLOCK" | grep -q '\*\*Base SHA\*\*'; then
  _pass "templates/task-manifest.md: Base SHA field sits inside ## Metadata"
else
  _fail "templates/task-manifest.md: Base SHA field sits inside ## Metadata" \
    "expected: '**Base SHA**' inside the ## Metadata block" "  actual: not found"
fi

assert_file_not_contains "templates/task-manifest.md no longer calls the SHA format 'not the enforcement boundary'" \
  "$MANIFEST_TEMPLATE" "not the enforcement boundary"
assert_file_not_contains "agents/implementer.md no longer calls the SHA format 'not the enforcement boundary'" \
  "$IMPLEMENTER_DOC" "not the enforcement boundary"

# Test Requirement #4 names three separate clauses of FEAT-022/TASK-004's format spec, so assert each
# one rather than only "40-hex SHA". Both the qa and code reviewers independently flagged that a single
# substring check would pass while a future edit clipped "bare (no backticks)" or "before any merge" —
# an assertion whose name promises more than its pattern verifies is the same shape of silent
# under-coverage this objective exists to close.
assert_file_contains "templates/task-manifest.md still specifies the full 40-hex SHA form" \
  "$MANIFEST_TEMPLATE" "40-hex SHA"
assert_file_contains "agents/implementer.md still specifies the full 40-hex SHA form" \
  "$IMPLEMENTER_DOC" "40-hex SHA"
assert_file_contains "templates/task-manifest.md still requires the bare (no backticks) form" \
  "$MANIFEST_TEMPLATE" "bare (no backticks)"
assert_file_contains "agents/implementer.md still requires the bare (no backticks) form" \
  "$IMPLEMENTER_DOC" "bare (no backticks)"
assert_file_contains "templates/task-manifest.md still requires recording before any merge" \
  "$MANIFEST_TEMPLATE" "before any merge"
assert_file_contains "agents/implementer.md still requires recording before any merge" \
  "$IMPLEMENTER_DOC" "before any merge"

# The template, instantiated the way a real implementer would: a real Base
# SHA in ## Metadata satisfies TASK-006's gate only once ## Commits carries a
# real descendant commit — left at its placeholder/example content, it fails.
setup_temp_dir
setup_git_repo
TPL_BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD~1)
TPL_DESC_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

TEMPLATE_UNFILLED=$(sed "s/^- \*\*Base SHA\*\*:.*/- **Base SHA**: ${TPL_BASE_SHA}/" "$MANIFEST_TEMPLATE")

if ttg_verify_commit_evidence "$TEMPLATE_UNFILLED" "$TEST_DIR"; then
  _fail "templates/task-manifest.md: unfilled ## Commits (placeholder/example only) fails the gate" \
    "expected: nonzero" "  actual: 0"
else
  _pass "templates/task-manifest.md: unfilled ## Commits (placeholder/example only) fails the gate"
fi

TEMPLATE_FILLED=$(printf '%s\n' "$TEMPLATE_UNFILLED" | sed "/^## Commits\$/a\\
- ${TPL_DESC_SHA} — feat(FIXTURE): descendant commit")

if ttg_verify_commit_evidence "$TEMPLATE_FILLED" "$TEST_DIR"; then
  _pass "templates/task-manifest.md: real Base SHA + real descendant ## Commits entry passes the gate"
else
  _fail "templates/task-manifest.md: real Base SHA + real descendant ## Commits entry passes the gate" \
    "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir

# ---------------------------------------------------------------------------
# ttg_log_transition / ttg_transition_is_guarded — the reconciliation ledger
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
NAZGUL_DIR="$TEST_DIR/nazgul"

if ttg_transition_is_guarded "$NAZGUL_DIR" "TASK-001" "IMPLEMENTED" "2020-01-01T00:00:00Z"; then
  _fail "ttg_transition_is_guarded: no ledger file returns false" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_transition_is_guarded: no ledger file returns false"
fi

ttg_log_transition "$NAZGUL_DIR" "TASK-001" "IN_PROGRESS" "IMPLEMENTED"
LOGGED_TS=$(jq -r '.timestamp' "$NAZGUL_DIR/logs/guarded-transitions.jsonl")

if ttg_transition_is_guarded "$NAZGUL_DIR" "TASK-001" "IMPLEMENTED" "$LOGGED_TS"; then
  _pass "ttg_transition_is_guarded: logged transition found at/after since_ts"
else
  _fail "ttg_transition_is_guarded: logged transition found at/after since_ts" "expected: 0" "  actual: nonzero"
fi

if ttg_transition_is_guarded "$NAZGUL_DIR" "TASK-001" "IMPLEMENTED" "9999-01-01T00:00:00Z"; then
  _fail "ttg_transition_is_guarded: since_ts in the future is not matched" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_transition_is_guarded: since_ts in the future is not matched"
fi

if ttg_transition_is_guarded "$NAZGUL_DIR" "TASK-001" "DONE" "$LOGGED_TS"; then
  _fail "ttg_transition_is_guarded: wrong target status is not matched" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_transition_is_guarded: wrong target status is not matched"
fi

if ttg_transition_is_guarded "$NAZGUL_DIR" "TASK-002" "IMPLEMENTED" "$LOGGED_TS"; then
  _fail "ttg_transition_is_guarded: wrong task_id is not matched" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_transition_is_guarded: wrong task_id is not matched"
fi

# Ledger trims to the newest 500 lines
for i in $(seq 1 510); do
  ttg_log_transition "$NAZGUL_DIR" "TASK-999" "READY" "IN_PROGRESS"
done
LEDGER_LINES=$(wc -l < "$NAZGUL_DIR/logs/guarded-transitions.jsonl" | tr -d ' ')
assert_eq "ttg_log_transition: ledger trimmed to 500 lines" "$LEDGER_LINES" "500"
teardown_temp_dir

# TASK-010 (ADR-023 decision 3) — ttg_verify_merge_evidence and the conditional merge-closure
# route to DONE. A NEW route to DONE, so the negatives are asserted first and by name.

# lean-comments: allow-run — provenance for the seam stub every merge assertion below rides on.
# SEAM-STUB PROVENANCE — derived-from-captured, and PINNED to the real producer instead of
# authored from the consumer that reads it.
#   tier:          derived-from-captured
#   producer:      merge_provider_pr_state (scripts/lib/merge-provider.sh), driven for real
#                  once below over the gh bytes tests/test-merge-provider.sh captured
#                  verbatim (gh 2.80.0, `gh pr view 88 --json state,mergedAt,mergeCommit,
#                  headRefName,baseRefName,url`, OrodruinLabs/nazgul PR 88, re-captured
#                  2026-08-18 for `url`). MP_CAPTURED_MERGED below is those bytes,
#                  byte-for-byte, and its url names the fixture's own remote — the seam
#                  refuses an answer that names another repository.
#   pinned-by:     MP_STUB_KEYS == MP_REAL_KEYS — the stub emits the producer's OWN key
#                  set, so a producer-side rename fails HERE rather than leaving every
#                  merge assertion in this file green over a shape nothing returns.
#   why:           the previous stub emitted exactly the four keys the parser read, and
#                  that is why no test here could drive the wrong-objective case: the
#                  mock's shape decided the test's reach (FEAT-031 second board, QA-2).
#   synthetic:     only the merged-at/merge-commit VALUES are fixture-controlled, so the
#                  ancestry cases can use this repo fixture's own shas.
MP_CAPTURED_MERGED='{"baseRefName":"main","headRefName":"feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'

# This objective vs. the captured OTHER one: PR 88's real head branch is FEAT-030's, the
# captured instance of the hazard — a genuinely merged PR of a DIFFERENT objective.
MERGE_FEAT_ID="FEAT-031"
MERGE_BRANCH="feat/FEAT-031-objective-closure"
MERGE_OTHER_BRANCH="feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr"
merge_config() {
  create_config ".feat_id = \"$MERGE_FEAT_ID\"" ".branch.feature = \"$MERGE_BRANCH\"" "$@"
}

# This objective's own plan.md: the frontmatter feat_id config must agree with, and the
# `## Tasks` roster that says which manifests on disk are this objective's.
merge_plan() {
  {
    printf -- '---\nfeat_id: %s\n---\n# Plan — %s\n\n## Tasks\n\n' "$MERGE_FEAT_ID" "$MERGE_FEAT_ID"
    printf -- '- TASK-050\n- TASK-051\n- TASK-052\n- TASK-053\n- TASK-054\n'
  } > "$TEST_DIR/nazgul/plan.md"
}

MERGE_VALID_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh (host API, ok)"

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"
MP_FAKEBIN="$TEST_DIR/fakebin"
mkdir -p "$MP_FAKEBIN"
cat > "$MP_FAKEBIN/gh" << 'MP_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  pr) [ "${2:-}" = "view" ] || exit 1; printf '%s\n' "${NAZGUL_TEST_MP_PAYLOAD:-}"; exit 0 ;;
esac
exit 1
MP_GH_EOF
chmod +x "$MP_FAKEBIN/gh"
export NAZGUL_TEST_MP_PAYLOAD="$MP_CAPTURED_MERGED"
MP_PATH_SAVED="$PATH"
export PATH="$MP_FAKEBIN:$PATH"
MP_REAL_JSON=$(merge_provider_pr_state "$TEST_DIR" 88)
export PATH="$MP_PATH_SAVED"
unset NAZGUL_TEST_MP_PAYLOAD
MP_REAL_KEYS=$(printf '%s' "$MP_REAL_JSON" | jq -r 'keys | sort | join(",")')
assert_eq "seam stub: the captured payload really does carry ANOTHER objective's head branch" \
  "$(printf '%s' "$MP_REAL_JSON" | jq -r '.head_ref')" "$MERGE_OTHER_BRANCH"
teardown_temp_dir

# The gate's answer must come from OUTSIDE the manifest, so the seam is stubbed and the
# fixtures drive it: only result=ok + merged=true + matching fields may ever verify.
MP_RESULT="ok"
MP_MERGED="true"
MP_AT="2026-08-15T12:00:00Z"
MP_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
MP_HEAD_REF="$MERGE_BRANCH"
MP_BASE_REF="main"
MP_STATE="MERGED"
MP_DIAG=""
MP_HOST="github.com"
merge_provider_pr_state() {
  jq -cn --arg r "$MP_RESULT" --arg m "$MP_MERGED" --arg a "$MP_AT" --arg c "$MP_COMMIT" \
    --arg h "$MP_HEAD_REF" --arg b "$MP_BASE_REF" --arg s "$MP_STATE" --arg d "$MP_DIAG" \
    --arg p "${2:-}" --arg hh "$MP_HOST" \
    '{result:$r,
      provider:"github",
      host:(if $hh == "" then null else $hh end),
      repo:"orodruinlabs/nazgul",
      pr:$p,
      state:(if $s == "" then null else $s end),
      merged:(if $m == "true" then true elif $m == "false" then false else null end),
      merged_at:(if $a == "" then null else $a end),
      merge_commit:(if $c == "" then null else $c end),
      diagnostic:(if $d == "" then null else $d end),
      head_ref:(if $h == "" then null else $h end),
      base_ref:(if $b == "" then null else $b end)}'
  [ "$MP_RESULT" = "ok" ] || return 5
}
mp_reset() {
  MP_RESULT="ok"; MP_MERGED="true"
  MP_AT="2026-08-15T12:00:00Z"
  MP_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  MP_HEAD_REF="$MERGE_BRANCH"; MP_BASE_REF="main"; MP_STATE="MERGED"; MP_DIAG=""
  MP_HOST="github.com"
}

MP_STUB_KEYS=$(merge_provider_pr_state "" 91 | jq -r 'keys | sort | join(",")')
assert_eq "seam stub: emits the PRODUCER's key set, not the subset its consumer reads" \
  "$MP_STUB_KEYS" "$MP_REAL_KEYS"

merge_manifest() {
  # Usage: merge_manifest <merge-evidence-body> [commits-body]
  printf '%s\n' "---
status: IMPLEMENTED
---
# TASK-050

## Metadata
- **ID**: TASK-050

## Commits
${2:-}

## Merge Evidence
${1}

## Description
closure fixture"
}

MERGE_ERR="${TMPDIR:-/tmp}/nazgul-merge-stderr.$$"

# Captured in THIS shell, never in $( ): a command substitution forks, and the TTG_*
# verdict globals asserted below would die with the subshell that set them.
me_verify() {
  local ec=0
  ttg_verify_merge_evidence "$1" "$2" "${3:-}" 2>"$MERGE_ERR" >/dev/null || ec=$?
  ME_STDERR=$(cat "$MERGE_ERR")
  return "$ec"
}

setup_temp_dir
setup_git_repo
setup_nazgul_dir
merge_config '.agents.reviewers = ["code-reviewer"]'
merge_plan
NAZGUL_DIR="$TEST_DIR/nazgul"

me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && ME_EC=0 || ME_EC=$?
assert_exit_code "ttg_verify_merge_evidence: a well-formed section verifies" "$ME_EC" 0
assert_eq "ttg_verify_merge_evidence: a verified section reasons 'verified'" "$TTG_MERGE_REASON" "verified"
assert_contains "ttg_verify_merge_evidence: the verified diagnostic names host and pr" "$ME_STDERR" "host=github.com"

# The heading IS the enforcement boundary, exactly as `## Commits` is: the same four
# fields recorded outside it are invisible to the gate.
OUTSIDE_HEADING="---
status: IMPLEMENTED
---
## Metadata
- **ID**: TASK-050

## Description
${MERGE_VALID_BODY}"
me_verify "$OUTSIDE_HEADING" "$TEST_DIR" TASK-050 && ABSENT_EC=0 || ABSENT_EC=$?
ABSENT_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: evidence outside the ## Merge Evidence heading is refused" "$ABSENT_EC" 1
assert_eq "ttg_verify_merge_evidence: no heading reasons 'absent'" "$TTG_MERGE_REASON" "absent"
assert_contains "ttg_verify_merge_evidence: the absent diagnostic names the enforcement boundary" \
  "$ABSENT_STDERR" "enforcement boundary"

me_verify "$(merge_manifest "")" "$TEST_DIR" TASK-050 && EMPTY_EC=0 || EMPTY_EC=$?
EMPTY_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: a present-but-empty section is refused" "$EMPTY_EC" 1
assert_eq "ttg_verify_merge_evidence: an empty section reasons 'absent'" "$TTG_MERGE_REASON" "absent"

# TASK-008's mechanism reused, not re-derived: the pre/post-strip comparison through the
# one _ttg_strip_html_comments is what "inside a comment" means for this section too.
me_verify "$(merge_manifest "<!--
${MERGE_VALID_BODY}
-->")" "$TEST_DIR" TASK-050 && COMMENTED_EC=0 || COMMENTED_EC=$?
COMMENTED_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: commented-out evidence is refused" "$COMMENTED_EC" 1
assert_eq "ttg_verify_merge_evidence: commented-out reasons 'commented_out', not 'absent'" \
  "$TTG_MERGE_REASON" "commented_out"
assert_contains "ttg_verify_merge_evidence: commented-out is reported present-but-not-counted" \
  "$COMMENTED_STDERR" "nothing was counted"
if [ "$COMMENTED_STDERR" != "$EMPTY_STDERR" ]; then
  _pass "ttg_verify_merge_evidence: commented_out and absent emit distinct diagnostics"
else
  _fail "ttg_verify_merge_evidence: commented_out and absent emit distinct diagnostics" \
    "expected: different stderr text" "  actual: byte-identical"
fi

me_verify "$(merge_manifest '- **host**: github.com
- **pr**: 91
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')" "$TEST_DIR" TASK-050 && TRUNC_EC=0 || TRUNC_EC=$?
TRUNCATED_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: a section missing merged-at is refused" "$TRUNC_EC" 1
assert_eq "ttg_verify_merge_evidence: a missing required field reasons 'truncated'" "$TTG_MERGE_REASON" "truncated"
assert_contains "ttg_verify_merge_evidence: the truncated diagnostic names the missing field" \
  "$TRUNCATED_STDERR" "merged-at"

me_verify "$(merge_manifest "- **host**: github.com
- **pr**: not-a-number
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && MALF_EC=0 || MALF_EC=$?
MALFORMED_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: a non-numeric pr is refused" "$MALF_EC" 1
assert_eq "ttg_verify_merge_evidence: a bad field value reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"
assert_contains "ttg_verify_merge_evidence: the malformed diagnostic names the offending field" \
  "$MALFORMED_STDERR" "pr="

ttg_verify_merge_evidence "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: yesterday
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a free-text merged-at reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

ttg_verify_merge_evidence "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: zzzznotahexsha
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a non-hex merge-commit reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

ttg_verify_merge_evidence "$(merge_manifest "- **host**: not a host name
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a whitespace-bearing host reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

# The forged block ADR-023 names as a REJECTED alternative: four shaped lines a human can
# type. Without a named producer it is refused before the host is ever asked.
FORGED_BODY='- **host**: x
- **pr**: 1
- **merged-at**: 1970-01-01T00:00:00Z
- **merge-commit**: 0000000'
me_verify "$(merge_manifest "$FORGED_BODY")" "$TEST_DIR" TASK-050 && FORGED_EC=0 || FORGED_EC=$?
FORGED_STDERR="$ME_STDERR"
assert_exit_code "forgery: a hand-typed four-line block is REFUSED" "$FORGED_EC" 1
assert_eq "forgery: a block with no producer reasons 'truncated'" "$TTG_MERGE_REASON" "truncated"
assert_contains "forgery: the refusal names the missing provenance field" \
  "$FORGED_STDERR" "recorded-by"

me_verify "$(merge_manifest "${MERGE_VALID_BODY%$'\n'*}
- **recorded-by**: me, by hand")" "$TEST_DIR" TASK-050 && PROD_EC=0 || PROD_EC=$?
assert_exit_code "forgery: a producer outside the closed set is REFUSED" "$PROD_EC" 1
assert_eq "forgery: an unrecognised producer reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

# The host is the authority, so its three unusable answers stay three separate verdicts.
MP_RESULT="api_failure"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && UNVER_EC=0 || UNVER_EC=$?
UNVERIFIABLE_STDERR="$ME_STDERR"
assert_exit_code "host: an unreachable host does NOT admit a closure" "$UNVER_EC" 1
assert_eq "host: an unaskable host reasons 'unverifiable'" "$TTG_MERGE_REASON" "unverifiable"
assert_contains "host: 'could not look' is stated as distinct from 'not merged'" \
  "$UNVERIFIABLE_STDERR" "NOT 'not merged'"
assert_contains "host: the merge-provider result token is carried through" \
  "$UNVERIFIABLE_STDERR" "api_failure"
mp_reset

MP_MERGED="false"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOTM_EC=0 || NOTM_EC=$?
NOT_MERGED_STDERR="$ME_STDERR"
assert_exit_code "host: a PR the host says is NOT merged is refused" "$NOTM_EC" 1
assert_eq "host: an answered-and-open PR reasons 'not_merged'" "$TTG_MERGE_REASON" "not_merged"
assert_contains "host: the not-merged diagnostic says the host ANSWERED" "$NOT_MERGED_STDERR" "ANSWERED"
if [ "$NOT_MERGED_STDERR" != "$UNVERIFIABLE_STDERR" ]; then
  _pass "host: 'not merged' and 'could not look' are different sentences"
else
  _fail "host: 'not merged' and 'could not look' are different sentences" \
    "expected: different stderr text" "  actual: byte-identical"
fi
mp_reset

MP_AT="2026-01-01T00:00:00Z"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && CTS_EC=0 || CTS_EC=$?
CONTRADICTED_STDERR="$ME_STDERR"
assert_exit_code "host: a merged-at the host contradicts is refused" "$CTS_EC" 1
assert_eq "host: a contradicted merged-at reasons 'contradicted'" "$TTG_MERGE_REASON" "contradicted"
mp_reset

MP_COMMIT="cafebabecafebabecafebabecafebabecafebabe"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && CTC_EC=0 || CTC_EC=$?
assert_exit_code "host: a merge-commit the host contradicts is refused" "$CTC_EC" 1
assert_eq "host: a contradicted merge-commit reasons 'contradicted'" "$TTG_MERGE_REASON" "contradicted"
mp_reset

# A host answer with no fields to compare corroborates nothing — it is not a pass.
MP_AT=""
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && THIN_EC=0 || THIN_EC=$?
assert_exit_code "host: merged=true with no merged-at is unverifiable, not verified" "$THIN_EC" 1
assert_eq "host: a fieldless merged answer reasons 'unverifiable'" "$TTG_MERGE_REASON" "unverifiable"
mp_reset

# A manifest recording an abbreviation of the host's oid names the same commit.
MP_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00.000Z
- **merge-commit**: deadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && ABBR_EC=0 || ABBR_EC=$?
assert_exit_code "host: an abbreviated merge-commit and a fractional timestamp still verify" "$ABBR_EC" 0
mp_reset

# TASK-042 / PR #240 finding #7. `host` was the ONE required field that reached diagnostics
# only, so a manifest could durably record a host nothing ever contacted.
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && HOSTOK_EC=0 || HOSTOK_EC=$?
assert_exit_code "host identity: a manifest naming the host actually asked still verifies" "$HOSTOK_EC" 0
assert_contains "host identity: the route records the host that ANSWERED, not only the claim" \
  "$ME_STDERR" "host-asked=github.com"

me_verify "$(merge_manifest "- **host**: gitlab.example.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && HOSTMIS_EC=0 || HOSTMIS_EC=$?
HOST_MISMATCH_STDERR="$ME_STDERR"
assert_exit_code "host identity: a manifest naming a host that was never asked is REFUSED" "$HOSTMIS_EC" 1
assert_eq "host identity: a contradicted host reasons 'contradicted', as its three siblings do" \
  "$TTG_MERGE_REASON" "contradicted"
assert_contains "host identity: the refusal quotes the value the manifest recorded" \
  "$HOST_MISMATCH_STDERR" "host=gitlab.example.com"
assert_contains "host identity: and the host the answer actually came from" \
  "$HOST_MISMATCH_STDERR" "verified against github.com"
assert_contains "host identity: the refusal says outright that host was never asked" \
  "$HOST_MISMATCH_STDERR" "names a host that was never asked"

# The seam normalises www.github.com to github.com and everything below compares; the
# manifest's copy is operator-typed, so case must not fabricate a contradiction either.
MP_HOST="www.github.com"
me_verify "$(merge_manifest "- **host**: GitHub.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && HOSTNORM_EC=0 || HOSTNORM_EC=$?
assert_exit_code "host identity: www. and case differences are one host, not a contradiction" \
  "$HOSTNORM_EC" 0
mp_reset

# An answer carrying no host at all is UNCOMPARABLE, and silently passing an uncomparable
# required field is the defect being fixed — so it fails closed, beside ok_no_head_ref.
MP_HOST=""
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOHOST_EC=0 || NOHOST_EC=$?
NO_HOST_STDERR="$ME_STDERR"
assert_exit_code "host identity: a merged answer naming no host does NOT admit a closure" "$NOHOST_EC" 1
assert_eq "host identity: an uncomparable host reasons 'unverifiable', not 'verified'" \
  "$TTG_MERGE_REASON" "unverifiable"
assert_eq "host identity: the host state names the missing fact rather than a generic failure" \
  "$TTG_MERGE_HOST_RESULT" "ok_no_host"
assert_contains "host identity: the refusal says the answer named no host" \
  "$NO_HOST_STDERR" "answer names no host"
assert_contains "host identity: and that an uncontradictable field is not a verified one" \
  "$NO_HOST_STDERR" "not verified"
mp_reset

# THE OBJECTIVE BINDING (FEAT-031 second board). "Is PR N merged?" is not the question: another
# objective's merged PR, copied from the host's own answer, passes every check above.
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && BOUND_EC=0 || BOUND_EC=$?
assert_exit_code "binding: a PR merged from THIS objective's branch still verifies" "$BOUND_EC" 0
assert_contains "binding: the verified route names the head branch it bound against" \
  "$ME_STDERR" "head-ref=${MERGE_BRANCH}"

MP_HEAD_REF="$MERGE_OTHER_BRANCH"
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 88
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_OTHER_BRANCH}
- **recorded-by**: scripts/close-objective.sh (host API, ok)")" "$TEST_DIR" TASK-050 \
  && OTHEROBJ_EC=0 || OTHEROBJ_EC=$?
NOT_THIS_OBJ_STDERR="$ME_STDERR"
assert_exit_code "binding: another objective's genuinely merged PR is REFUSED" "$OTHEROBJ_EC" 1
assert_eq "binding: a merged PR of another objective reasons 'not_this_objective'" \
  "$TTG_MERGE_REASON" "not_this_objective"
assert_contains "binding: the refusal names the branch it actually merged from" \
  "$NOT_THIS_OBJ_STDERR" "$MERGE_OTHER_BRANCH"
assert_contains "binding: the refusal names this objective's own branch" \
  "$NOT_THIS_OBJ_STDERR" "$MERGE_BRANCH"
assert_contains "binding: the refusal says outright whose evidence this is" \
  "$NOT_THIS_OBJ_STDERR" "evidence about a DIFFERENT objective"
assert_contains "binding: the refusal names the base branch the host reported, not <unknown>" \
  "$NOT_THIS_OBJ_STDERR" "(into main)"
assert_eq "binding: the host's base branch is captured for the caller that reports it" \
  "$TTG_MERGE_HOST_BASE_REF" "main"
# An unreported base must not be printed as a base literally named "<unknown>". The host
# blanks a base failing _mp_ref_ok, so this form is reachable, not hypothetical.
NOBASE_WHY=$(ttg_pr_bound "$TEST_DIR/nazgul" "$MERGE_FEAT_ID" "$MERGE_OTHER_BRANCH" 91)
assert_contains "binding: an unreported base says the host reported none" \
  "$NOBASE_WHY" "the host reported no usable base branch"
assert_not_contains "binding: and never invents a base branch called <unknown>" \
  "$NOBASE_WHY" "<unknown>"
mp_reset

# The manifest is operator-writable, so a head-ref it claims that the host does not report
# is the same class of lie as a wrong merge-commit, and lands in the same reason.
MP_HEAD_REF="$MERGE_OTHER_BRANCH"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && HRMIS_EC=0 || HRMIS_EC=$?
HEADREF_MISMATCH_STDERR="$ME_STDERR"
assert_exit_code "binding: a head-ref the host contradicts is refused" "$HRMIS_EC" 1
assert_eq "binding: a contradicted head-ref reasons 'contradicted'" "$TTG_MERGE_REASON" "contradicted"
assert_contains "binding: the contradiction quotes both sides" \
  "$HEADREF_MISMATCH_STDERR" "was merged from ${MERGE_OTHER_BRANCH}"
mp_reset

# Fail CLOSED on a host that returned no usable head branch: a PR that cannot be SHOWN to
# be this objective's is not thereby this objective's.
MP_HEAD_REF=""
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOHEAD_EC=0 || NOHEAD_EC=$?
NO_HEAD_REF_STDERR="$ME_STDERR"
assert_exit_code "binding: a merged PR with no head branch in the answer is REFUSED" "$NOHEAD_EC" 1
assert_eq "binding: an unattributable merge reasons 'unverifiable', not 'verified'" \
  "$TTG_MERGE_REASON" "unverifiable"
assert_eq "binding: the host state names the missing fact rather than a generic failure" \
  "$TTG_MERGE_HOST_RESULT" "ok_no_head_ref"
assert_contains "binding: the refusal says a merge nobody can attribute closes nothing" \
  "$NO_HEAD_REF_STDERR" "no usable head branch"
mp_reset

# A branch name no git ref could carry is refused at the shape, exactly as
# merge-provider.sh drops such a value rather than passing it on.
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: not a branch name
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && HRSHAPE_EC=0 || HRSHAPE_EC=$?
assert_exit_code "binding: a head-ref that is not ref-shaped is refused" "$HRSHAPE_EC" 1
assert_eq "binding: an unusable head-ref reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

# lean-comments: allow-run — cites the oracle row this task's File Scope forbids adding.
# TASK-045 AC1/AC2. A backtick is legal in a git ref — a DELIMITER for `_ttg_merge_field`, not
# noise to `tr -d` away. `_mp_ref_ok` already agrees with `git check-ref-format --branch` on it
# (cited here rather than added as a row to test-merge-provider.sh's table, TASK-037's file), so
# the finding is purely in the field reader below.
MERGE_BACKTICK_BRANCH='feat/we`ird'
assert_eq "AC2: _mp_ref_ok already accepts a git-legal backtick" \
  "$(_mp_ref_ok "$MERGE_BACKTICK_BRANCH" && echo accept || echo reject)" "accept"
assert_eq "AC2: git check-ref-format --branch agrees with it" \
  "$(git -C "$TEST_DIR" check-ref-format --branch "$MERGE_BACKTICK_BRANCH" >/dev/null 2>&1 && echo accept || echo reject)" "accept"

mp_reset
MP_HEAD_REF="$MERGE_BACKTICK_BRANCH"
merge_config '.agents.reviewers = ["code-reviewer"]' ".branch.feature = \"$MERGE_BACKTICK_BRANCH\""
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: \`${MERGE_BACKTICK_BRANCH}\`
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && BACKTICK_EC=0 || BACKTICK_EC=$?
assert_exit_code "AC1: a delimiting backtick pair round-trips to a value that matches the host" "$BACKTICK_EC" 0
assert_eq "AC1: the round-tripped closure still reasons 'verified'" "$TTG_MERGE_REASON" "verified"
assert_contains "AC1: the verified route names the unwrapped branch, not the delimiters" \
  "$ME_STDERR" "head-ref=${MERGE_BACKTICK_BRANCH}"

# The converse: a fix that stopped COMPARING would also "fix" a genuine mismatch. It must not.
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: \`${MERGE_BACKTICK_BRANCH}x\`
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && BACKTICK_MIS_EC=0 || BACKTICK_MIS_EC=$?
assert_exit_code "AC1: a genuinely mismatched backtick-bearing head-ref still refuses" "$BACKTICK_MIS_EC" 1
assert_eq "AC1: the mismatch still reasons 'contradicted'" "$TTG_MERGE_REASON" "contradicted"
merge_config '.agents.reviewers = ["code-reviewer"]'
mp_reset

# Under stacking the PR is opened from the layer's branch, which need not be branch.feature
# — the registry entry for this feat_id binds it just as well. ONE authority, both callers.
merge_config '.branch.feature = null' \
  ".stack.layers = [{feat_id: \"$MERGE_FEAT_ID\", branch: \"feat/FEAT-031-layer-2\", pr: \"\",
                     base: \"main\", state: \"open\", opened_at: \"2026-08-16T00:00:00Z\",
                     merged_at: null}]"
MP_HEAD_REF="feat/FEAT-031-layer-2"
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: feat/FEAT-031-layer-2
- **recorded-by**: scripts/close-objective.sh")" "$TEST_DIR" TASK-050 && STACKED_EC=0 || STACKED_EC=$?
assert_exit_code "binding: a stack layer's own branch binds the PR to this objective" "$STACKED_EC" 0

# No feat_id is not "anything binds" — it is "nothing can be shown to bind".
mp_reset
merge_config '.feat_id = null'
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOFEAT_EC=0 || NOFEAT_EC=$?
assert_exit_code "binding: with no feat_id the gate fails CLOSED" "$NOFEAT_EC" 1
assert_eq "binding: an unnameable objective reasons 'not_this_objective'" \
  "$TTG_MERGE_REASON" "not_this_objective"
merge_config '.agents.reviewers = ["code-reviewer"]'
mp_reset

# lean-comments: allow-run — names the hazard and why the fixture is the real one.
# THE TASK BINDING (FEAT-031 third board), the same defect one granularity down. Everything
# above establishes that PR 91 is THIS objective's genuinely merged PR — so the block the
# closer writes into a roster manifest is valid evidence, and copying it verbatim into a
# manifest of a DIFFERENT objective must still be refused. Nothing here is forged: the
# evidence is perfect, only the task is somebody else's.
mp_reset
merge_config '.agents.reviewers = ["code-reviewer"]'
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-999 && NEIGHBOUR_EC=0 || NEIGHBOUR_EC=$?
NOT_OUR_TASK_STDERR="$ME_STDERR"
assert_exit_code "roster: this objective's own merge does NOT close another objective's task" \
  "$NEIGHBOUR_EC" 1
assert_eq "roster: a manifest outside the roster reasons 'not_this_objectives_task'" \
  "$TTG_MERGE_REASON" "not_this_objectives_task"
assert_contains "roster: the refusal names the task it refused" "$NOT_OUR_TASK_STDERR" "TASK-999"
assert_contains "roster: the refusal names the roster it is missing from" \
  "$NOT_OUR_TASK_STDERR" "## Tasks roster"
assert_contains "roster: and says outright that the PR itself is genuine" \
  "$NOT_OUR_TASK_STDERR" "genuinely merged PR, but"

# A roster member with the identical evidence still closes: the refusal above is about
# membership, not about the evidence, and a check that refused both would prove neither.
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && ROSTERED_EC=0 || ROSTERED_EC=$?
assert_exit_code "roster: the same evidence still verifies for a task the roster lists" "$ROSTERED_EC" 0

# "the roster does not list it" and "there is no roster to read" are different answers.
# The second must fail CLOSED rather than degrade into closing anything on disk.
mv "$TEST_DIR/nazgul/plan.md" "$TEST_DIR/nazgul/plan.md.away"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOROSTER_EC=0 || NOROSTER_EC=$?
NO_ROSTER_STDERR="$ME_STDERR"
mv "$TEST_DIR/nazgul/plan.md.away" "$TEST_DIR/nazgul/plan.md"
assert_exit_code "roster: an unreadable roster refuses rather than admits" "$NOROSTER_EC" 1
assert_eq "roster: an unreadable roster reasons 'not_this_objectives_task'" \
  "$TTG_MERGE_REASON" "not_this_objectives_task"
assert_contains "roster: it says membership was never established, not that the id is absent" \
  "$NO_ROSTER_STDERR" "membership was never established"
if [ "$NOT_OUR_TASK_STDERR" != "$NO_ROSTER_STDERR" ]; then
  _pass "roster: not-listed and no-roster are the same reason but different sentences"
else
  _fail "roster: not-listed and no-roster are the same reason but different sentences" \
    "both printed: $NO_ROSTER_STDERR"
fi

# lean-comments: allow-run — the shipped-template regression this case exists to catch.
# "declares nothing" is NOT "declares someone else": templates/plan.md shipped without any
# frontmatter, so treating absence as a contradiction made the merge route unreachable for
# every project using the shipped template while this repo's own hand-written plan worked.
printf -- '# Plan\n\n## Tasks\n\n- TASK-050\n' > "$TEST_DIR/nazgul/plan.md"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && NOFM_EC=0 || NOFM_EC=$?
NO_FM_STDERR="$ME_STDERR"
assert_exit_code "roster: a plan with no frontmatter refuses (fail-closed)" "$NOFM_EC" 1
assert_contains "roster: and says the frontmatter is ABSENT, not that it names another objective" \
  "$NO_FM_STDERR" "declares no frontmatter feat_id"
assert_not_contains "roster: absence is not reported as a contradiction" \
  "$NO_FM_STDERR" "but config names"
assert_contains "roster: the refusal states the remedy rather than only the fault" \
  "$NO_FM_STDERR" "add a leading"
# Asserting the key's PRESENCE is what let the half-done fix pass: it ships inert. Drive the
# template's OWN declared value; its producer is covered by tests/test-plan-objective-binding.sh.
TPL_DECLARED=$(ttg_plan_feat_id "$REPO_ROOT/templates/plan.md")
printf -- '---\nfeat_id: %s\n---\n# Plan\n\n## Tasks\n\n- TASK-050\n' "$TPL_DECLARED" > "$TEST_DIR/nazgul/plan.md"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && TPL_EC=0 || TPL_EC=$?
TPL_STDERR="$ME_STDERR"
assert_exit_code "the shipped template's own feat_id value closes NOTHING until a producer substitutes it" "$TPL_EC" 1
assert_contains "and an un-run producer is named as such, not reported as a rival objective" \
  "$TPL_STDERR" "unsubstituted placeholder"
merge_plan

# A roster whose frontmatter names a DIFFERENT objective cannot scope this one either.
printf -- '---\nfeat_id: FEAT-999\n---\n# Plan\n\n## Tasks\n\n- TASK-050\n' > "$TEST_DIR/nazgul/plan.md"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && DRIFT_EC=0 || DRIFT_EC=$?
ROSTER_DRIFT_STDERR="$ME_STDERR"
merge_plan
assert_exit_code "roster: a plan declaring another objective refuses" "$DRIFT_EC" 1
assert_contains "roster: the drift diagnostic names both ids rather than silently picking one" \
  "$ROSTER_DRIFT_STDERR" 'declares feat_id "FEAT-999" but config names "FEAT-031"'

# THE PATCH ARM (FEAT-031 fifth board, arch-F1): removed, not left dead — no id outside
# ^TASK-[0-9]+$ reaches the question, and what replaced it names the section it read.
printf -- '---\nfeat_id: %s\n---\n# Plan\n\n## Tasks\n\n- PATCH-007: a patch record, not a roster entry\n' \
  "$MERGE_FEAT_ID" > "$TEST_DIR/nazgul/plan.md"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && PATCHONLY_EC=0 || PATCHONLY_EC=$?
PATCH_ONLY_STDERR="$ME_STDERR"
assert_exit_code "patch arm: a roster of only patch ids scopes nothing, so the gate refuses" \
  "$PATCHONLY_EC" 1
assert_contains "patch arm: the refusal names the patch id it actually read" \
  "$PATCH_ONLY_STDERR" "names ONLY patch ids (PATCH-007)"
assert_contains "patch arm: and states the scope limit rather than a cause it cannot establish" \
  "$PATCH_ONLY_STDERR" "merge closure is scoped to TASK-NNN manifests"
assert_not_contains "patch arm: 'names only patch ids' is NOT collapsed into 'names nothing'" \
  "$PATCH_ONLY_STDERR" "carries no ## Tasks roster to read"

# An empty section still gets the OTHER answer: the refusal added a state, not absorbed one.
printf -- '---\nfeat_id: %s\n---\n# Plan\n\n## Tasks\n\n## Wave Groups\n' \
  "$MERGE_FEAT_ID" > "$TEST_DIR/nazgul/plan.md"
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && EMPTYROSTER_EC=0 || EMPTYROSTER_EC=$?
assert_exit_code "patch arm: an empty roster still refuses" "$EMPTYROSTER_EC" 1
assert_contains "patch arm: an empty roster gets its own sentence, not the patch one" \
  "$ME_STDERR" "carries no ## Tasks roster to read"

# A patch id beside real entries is simply not a member: the roster still scopes this
# objective, and the task it does list still closes on the same evidence.
printf -- '---\nfeat_id: %s\n---\n# Plan\n\n## Tasks\n\n- TASK-050\n- PATCH-007 named inline\n' \
  "$MERGE_FEAT_ID" > "$TEST_DIR/nazgul/plan.md"
assert_eq "patch arm: the parser returns the TASK ids and drops the patch id" \
  "$(ttg_objective_roster_ids "$TEST_DIR/nazgul/plan.md" | tr '\n' ' ')" "TASK-050 "
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && MIXED_EC=0 || MIXED_EC=$?
assert_exit_code "patch arm: a listed task still closes beside an ignored patch record" "$MIXED_EC" 0
merge_plan

# arch-F1's second half: a refusal may state what the gate read, never why the id is absent.
assert_not_contains "roster: the refusal claims no cause the predicate cannot establish" \
  "$NOT_OUR_TASK_STDERR" "belongs to a different one"
assert_contains "roster: it states the checked fact instead" \
  "$NOT_OUR_TASK_STDERR" "that roster does not name this one"

# The binding's anchor is config.json itself, so config contradicting ITSELF cannot bind:
# objectives_history attributing this PR to another objective refuses even while
# branch.feature says otherwise. Not an independent anchor — a one-key edit is simply
# no longer enough (RULES.md §2, the stated boundary).
merge_config '.agents.reviewers = ["code-reviewer"]' \
  '.objectives_history = [{feat_id: "FEAT-030", objective: "prior", started_at: "2026-08-09T00:00:00Z",
                           pr: "https://github.com/OrodruinLabs/nazgul/pull/91"}]'
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && HIST_EC=0 || HIST_EC=$?
HIST_STDERR="$ME_STDERR"
assert_exit_code "history: a PR config itself attributes to another objective is REFUSED" "$HIST_EC" 1
assert_eq "history: an internally contradicted binding reasons 'not_this_objective'" \
  "$TTG_MERGE_REASON" "not_this_objective"
assert_contains "history: the refusal names the objective config credits the PR to" \
  "$HIST_STDERR" "records PR 91 as FEAT-030's PR"

# The same registry naming THIS objective is not an obstacle — the check refuses a
# contradiction, never the ordinary case where history and identity agree.
merge_config '.agents.reviewers = ["code-reviewer"]' \
  '.objectives_history = [{feat_id: "FEAT-031", objective: "this one", started_at: "2026-08-15T00:00:00Z",
                           pr: "https://github.com/OrodruinLabs/nazgul/pull/91"}]'
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && HISTOK_EC=0 || HISTOK_EC=$?
assert_exit_code "history: our own registered PR still verifies" "$HISTOK_EC" 0
# A neighbouring PR number must not be read as this one: 191 ends in 91.
merge_config '.agents.reviewers = ["code-reviewer"]' \
  '.objectives_history = [{feat_id: "FEAT-030", objective: "prior", started_at: "2026-08-09T00:00:00Z",
                           pr: "https://github.com/OrodruinLabs/nazgul/pull/191"}]'
me_verify "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 && HISTNEAR_EC=0 || HISTNEAR_EC=$?
assert_exit_code "history: PR 191 is not PR 91 — a suffix match would refuse the wrong closure" \
  "$HISTNEAR_EC" 0
merge_config '.agents.reviewers = ["code-reviewer"]'

# lean-comments: allow-run — an assertion that PASSES on a bypass needs its reason attached.
# DELIBERATELY INVERTED: this asserts the residual gap RULES.md §2 states, so the boundary is
# a recorded fact rather than a rediscovered one. `branch.feature` is the binding's only
# anchor and `task-state-guard.sh` blanket-permits config.json, so ONE key edit — with the PR
# registry silent, which is the ordinary case — still admits a foreign objective's real merge.
# If a future change closes this, THIS TEST GOES RED: update §2's boundary sentence with it,
# never delete the case to restore green.
mp_reset
MP_HEAD_REF="$MERGE_OTHER_BRANCH"
merge_config '.agents.reviewers = ["code-reviewer"]' \
  ".branch.feature = \"$MERGE_OTHER_BRANCH\"" '.objectives_history = []'
ONEKEY_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: ${MERGE_OTHER_BRANCH}
- **recorded-by**: scripts/close-objective.sh (host API, ok)"
me_verify "$(merge_manifest "$ONEKEY_BODY")" "$TEST_DIR" TASK-050 && ONEKEY_EC=0 || ONEKEY_EC=$?
assert_exit_code "boundary: one branch.feature edit STILL admits a foreign merge (§2, stated not fixed)" \
  "$ONEKEY_EC" 0
assert_eq "boundary: and it is admitted as fully verified, not as a degraded pass" \
  "$TTG_MERGE_REASON" "verified"
# The corroboration that DOES bite: same one-key edit, registry naming the PR's real owner.
merge_config '.agents.reviewers = ["code-reviewer"]' \
  ".branch.feature = \"$MERGE_OTHER_BRANCH\"" \
  '.objectives_history = [{feat_id: "FEAT-030", objective: "prior", started_at: "2026-08-09T00:00:00Z",
                           pr: "https://github.com/OrodruinLabs/nazgul/pull/91"}]'
me_verify "$(merge_manifest "$ONEKEY_BODY")" "$TEST_DIR" TASK-050 && ONEKEY2_EC=0 || ONEKEY2_EC=$?
assert_exit_code "boundary: the one-key edit IS refused once the registry records that PR" "$ONEKEY2_EC" 1
assert_eq "boundary: refused because config contradicts itself, not because the branch was checked" \
  "$TTG_MERGE_REASON" "not_this_objective"
mp_reset
merge_config '.agents.reviewers = ["code-reviewer"]'

# Every refusal state must be its own token AND its own sentence — a state folded into
# a neighbour's bucket would leave both censuses unchanged.
MERGE_DISTINCT=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$ABSENT_STDERR" "$COMMENTED_STDERR" \
  "$TRUNCATED_STDERR" "$MALFORMED_STDERR" "$UNVERIFIABLE_STDERR" "$NOT_MERGED_STDERR" \
  "$NOT_THIS_OBJ_STDERR" "$NO_HEAD_REF_STDERR" "$NOT_OUR_TASK_STDERR" "$NO_HOST_STDERR" \
  "$HOST_MISMATCH_STDERR" \
  | sort -u | grep -c '[^[:space:]]')
assert_eq "ttg_verify_merge_evidence: eleven refusal diagnostics, eleven distinct sentences" "$MERGE_DISTINCT" "11"

MERGE_VOCAB_EXPECTED='absent commented_out contradicted malformed not_merged not_this_objective not_this_objectives_task truncated unverifiable'
MERGE_VOCAB_ARGS=$(grep -oE '_ttg_merge_deny "[^"]*" "[^"]*" "[^"]*"' \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" | sed -E 's/.*"([^"]*)"$/\1/')
MERGE_VOCAB_SCANNED=$(printf '%s\n' "$MERGE_VOCAB_ARGS" | grep -c '[^[:space:]]')
MERGE_VOCAB_CHECKED=$(printf '%s\n' "$MERGE_VOCAB_ARGS" | grep -cE '^[a-z_]+$')
MERGE_VOCAB_SKIPPED=$((MERGE_VOCAB_SCANNED - MERGE_VOCAB_CHECKED))
MERGE_VOCAB_SET=$(printf '%s\n' "$MERGE_VOCAB_ARGS" | grep -E '^[a-z_]+$' | sort -u)
MERGE_VOCAB_FINDINGS=$(comm -3 <(printf '%s\n' "$MERGE_VOCAB_SET") \
  <(printf '%s\n' "$MERGE_VOCAB_EXPECTED" | tr ' ' '\n' | sort) | grep -c '[^[:space:]]')
echo "  merge-vocabulary: ${MERGE_VOCAB_SCANNED} scanned, ${MERGE_VOCAB_SKIPPED} skipped (variable-passthrough=${MERGE_VOCAB_SKIPPED}), ${MERGE_VOCAB_CHECKED} checked, ${MERGE_VOCAB_FINDINGS} findings"
assert_eq "merge-vocabulary: scanned == skipped + checked" "$MERGE_VOCAB_SCANNED" "$((MERGE_VOCAB_SKIPPED + MERGE_VOCAB_CHECKED))"
assert_eq "merge-vocabulary: the closed set is exactly the enumerated reasons" \
  "$(printf '%s\n' "$MERGE_VOCAB_SET" | tr '\n' ' ')" \
  "$(printf '%s\n' "$MERGE_VOCAB_EXPECTED" | tr ' ' '\n' | sort | tr '\n' ' ')"
# lean-comments: allow-run — the hand-off this AC exists to force, argued not just asserted.
# TASK-045 AC5. tests/test-doc-contract-fields.sh (TASK-044's File Scope) derives its claim
# families from producers the same way, but does not yet bind TTG_MERGE_BASE_ANCESTRY's or
# TTG_MERGE_HOST_RESULT's outcome vocabularies to RULES.md §2 — so an addition to either would
# pass there silently. Bound here instead, off the actual assignment sites, not retyped.
ANCESTRY_DRIFT_TOKENS=$(grep -oE '(TTG_MERGE_BASE_ANCESTRY|outcome)="(base_behind_merge|not_ancestor)"' \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" | sed -E 's/.*="([a-z_]+)"/\1/' | sort -u)
assert_eq "AC5: the two ancestry outcomes RULES.md §2 must distinguish are exactly these two" \
  "$(printf '%s\n' "$ANCESTRY_DRIFT_TOKENS" | tr '\n' ' ')" "base_behind_merge not_ancestor "
RULES_ANCESTRY_BULLET=$(grep "only one ancestry check can block" "$REPO_ROOT/RULES.md")
for _tok in $ANCESTRY_DRIFT_TOKENS; do
  assert_contains "AC5: RULES.md §2's ancestry bullet names $_tok" "$RULES_ANCESTRY_BULLET" "$_tok"
done

HOSTRESULT_DRIFT_TOKENS=$(grep -oE 'TTG_MERGE_HOST_RESULT="(ok_no_host|ok_no_head_ref)"' \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" | sed -E 's/.*="([a-z_]+)"/\1/' | sort -u)
assert_eq "AC5: the two host-result states RULES.md §2 must enumerate are exactly these two" \
  "$(printf '%s\n' "$HOSTRESULT_DRIFT_TOKENS" | tr '\n' ' ')" "ok_no_head_ref ok_no_host "
RULES_UNVERIFIABLE_BULLET=$(grep -oE "\`unverifiable\` \(the host[^)]*\)" "$REPO_ROOT/RULES.md")
for _tok in $HOSTRESULT_DRIFT_TOKENS; do
  assert_contains "AC5: RULES.md §2's unverifiable parenthetical names $_tok" "$RULES_UNVERIFIABLE_BULLET" "$_tok"
done

assert_eq "merge-vocabulary: no refusal state is folded into another's bucket" "$MERGE_VOCAB_FINDINGS" "0"
teardown_temp_dir

# Ancestry is CORROBORATION ONLY (ADR-023 decision 1). After a server-side squash no
# recorded SHA reaches the merge commit, so a failed check must never block.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
NAZGUL_DIR="$TEST_DIR/nazgul"
ANC_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
ANC_PARENT=$(git -C "$TEST_DIR" rev-parse HEAD~1)
ANC_BASE=$(git -C "$TEST_DIR" rev-parse --abbrev-ref HEAD)
merge_config ".branch.base = \"${ANC_BASE}\""
merge_plan

ANC_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_HEAD}
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh"
MP_COMMIT="$ANC_HEAD"
me_verify "$(merge_manifest "$ANC_BODY" "- ${ANC_PARENT}")" "$TEST_DIR" TASK-050 && CORROB_EC=0 || CORROB_EC=$?
CORROB_STDERR="$ME_STDERR"
assert_exit_code "ancestry: a reachable merge commit verifies" "$CORROB_EC" 0
assert_eq "ancestry: a recorded commit reaching the merge commit is corroborated" "$TTG_MERGE_ANCESTRY" "corroborated"
assert_contains "ancestry: corroboration is named in the diagnostic" "$CORROB_STDERR" "corroborates"

INV_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_PARENT}
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh"
MP_COMMIT="$ANC_PARENT"
me_verify "$(merge_manifest "$INV_BODY" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 && SQUASH_EC=0 || SQUASH_EC=$?
SQUASH_STDERR="$ME_STDERR"
assert_exit_code "ancestry: a FAILED is-ancestor check against API-merged evidence does NOT block" "$SQUASH_EC" 0
assert_eq "ancestry: a failed check is recorded as the expected squash signature" "$TTG_MERGE_ANCESTRY" "squash_signature"
assert_contains "ancestry: the squash signature is recorded, not reported as an anomaly" \
  "$SQUASH_STDERR" "expected squash signature"

mp_reset
ttg_verify_merge_evidence "$(merge_manifest "$MERGE_VALID_BODY" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 2>/dev/null \
  && GONE_EC=0 || GONE_EC=$?
assert_exit_code "ancestry: a merge commit absent from local history does not block" "$GONE_EC" 0
assert_eq "ancestry: an unresolvable merge commit is the squash signature, not 'malformed'" \
  "$TTG_MERGE_ANCESTRY" "squash_signature"
assert_eq "base ancestry: an unresolvable merge commit is 'unresolved', the post-squash norm" \
  "$TTG_MERGE_BASE_ANCESTRY" "unresolved"

# lean-comments: allow-run — two states that look identical, so both directions are pinned.
# TASK-042 / PR #240 finding #8. `resolved but not an ancestor` was ONE bucket holding two
# states, and only one of them is the local repository disagreeing with the host.
# Direction 1 — the local base is merely BEHIND. This is the shape a real merge leaves in a
# checkout that has not fetched since: the merge commit descends from the base tip. It used
# to be refused as 'contradicted', overriding the host's own confirmation.
git -C "$TEST_DIR" checkout -q -b anc-merged-on-host
echo "shipped" > "$TEST_DIR/shipped.txt"
git -C "$TEST_DIR" add shipped.txt
git -C "$TEST_DIR" commit -q -m "merged on the host; nothing has fetched here since"
ANC_AHEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
git -C "$TEST_DIR" checkout -q "$ANC_BASE"
MP_COMMIT="$ANC_AHEAD"
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_AHEAD}
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 && STALE_EC=0 || STALE_EC=$?
STALE_STDERR="$ME_STDERR"
assert_exit_code "base ancestry: a host-CONFIRMED merge whose local base is merely stale is NOT refused" \
  "$STALE_EC" 0
assert_eq "base ancestry: a stale base leaves the verdict 'verified'" "$TTG_MERGE_REASON" "verified"
assert_eq "base ancestry: staleness is its OWN outcome, not folded into not_ancestor" \
  "$TTG_MERGE_BASE_ANCESTRY" "base_behind_merge"
assert_contains "base ancestry: the outcome still reaches TTG_MERGE_ROUTE" \
  "$STALE_STDERR" "base=base_behind_merge"
assert_contains "base ancestry: stderr states the distinction rather than erasing it" \
  "$STALE_STDERR" "uninformed, not disagreeing"
assert_contains "base ancestry: and names the fetch the gate itself must not run" \
  "$STALE_STDERR" "git fetch"

# Direction 2 — genuine divergence, which no unfetched merge produces. A fix that stopped
# refusing here would be worse than the defect, so it is pinned as hard as the pass above.
git -C "$TEST_DIR" checkout -q -b anc-diverged "$ANC_PARENT"
echo "elsewhere" > "$TEST_DIR/elsewhere.txt"
git -C "$TEST_DIR" add elsewhere.txt
git -C "$TEST_DIR" commit -q -m "forked before the base tip and never rejoined"
ANC_DIVERGED=$(git -C "$TEST_DIR" rev-parse HEAD)
git -C "$TEST_DIR" checkout -q "$ANC_BASE"
assert_exit_code "base ancestry fixture: the diverged commit really is off both directions" \
  "$(git -C "$TEST_DIR" merge-base --is-ancestor "$ANC_BASE" "$ANC_DIVERGED" 2>/dev/null && echo 0 || echo 1)" 1
MP_COMMIT="$ANC_DIVERGED"
me_verify "$(merge_manifest "- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_DIVERGED}
- **head-ref**: ${MERGE_BRANCH}
- **recorded-by**: scripts/close-objective.sh" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 && OFFBASE_EC=0 || OFFBASE_EC=$?
OFFBASE_STDERR="$ME_STDERR"
assert_exit_code "base ancestry: a merge commit genuinely diverged from the base is still REFUSED" \
  "$OFFBASE_EC" 1
assert_eq "base ancestry: a diverged merge commit still reasons 'contradicted'" \
  "$TTG_MERGE_REASON" "contradicted"
assert_eq "base ancestry: the blocking outcome is still named 'not_ancestor'" \
  "$TTG_MERGE_BASE_ANCESTRY" "not_ancestor"
assert_contains "base ancestry: the refusal says diverged, not merely off-base" \
  "$OFFBASE_STDERR" "diverged from the base branch"
assert_contains "base ancestry: and names the remedy the operator could not previously guess" \
  "$OFFBASE_STDERR" "git fetch"
if [ "$OFFBASE_STDERR" != "$STALE_STDERR" ]; then
  _pass "base ancestry: stale and diverged are different sentences, not one bucket"
else
  _fail "base ancestry: stale and diverged are different sentences, not one bucket" \
    "expected: different stderr text" "  actual: byte-identical"
fi
mp_reset
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
merge_config
merge_plan
NAZGUL_DIR="$TEST_DIR/nazgul"
ttg_verify_merge_evidence "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 2>/dev/null \
  && NOGIT_EC=0 || NOGIT_EC=$?
assert_exit_code "ancestry: a non-git project root does not block the merge route" "$NOGIT_EC" 0
assert_eq "ancestry: an uncheckable corroboration is named 'unavailable'" "$TTG_MERGE_ANCESTRY" "unavailable"
assert_eq "base ancestry: with no repository the outcome is named 'no_git'" \
  "$TTG_MERGE_BASE_ANCESTRY" "no_git"
teardown_temp_dir

# The edge and its condition are two separate facts, so both are asserted: present in
# the graph, and REFUSED by ttg_validate_transition without merge evidence.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
merge_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = false' '.afk.task_pr = false'
merge_plan
NAZGUL_DIR="$TEST_DIR/nazgul"
create_task_file TASK-050 IMPLEMENTED

MERGE_OK_MANIFEST=$(merge_manifest "$MERGE_VALID_BODY")
NO_MERGE_MANIFEST="---
status: IMPLEMENTED
---
## Metadata
- **ID**: TASK-050

## Description
no merge evidence anywhere"

ID_OK_STDERR=$(ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-050 IMPLEMENTED DONE "$MERGE_OK_MANIFEST" 2>&1 >/dev/null) \
  && ID_OK_EC=0 || ID_OK_EC=$?
assert_exit_code "IMPLEMENTED -> DONE: valid merge evidence is accepted" "$ID_OK_EC" 0
assert_contains "IMPLEMENTED -> DONE: the diagnostic names the merge-evidence route" \
  "$ID_OK_STDERR" "merge-evidence route"

ID_NO_STDERR=$(ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-050 IMPLEMENTED DONE "$NO_MERGE_MANIFEST" 2>&1 >/dev/null) \
  && ID_NO_EC=0 || ID_NO_EC=$?
assert_exit_code "IMPLEMENTED -> DONE: NOT an unconditional edge — refused without merge evidence" "$ID_NO_EC" 1
assert_contains "IMPLEMENTED -> DONE: the refusal names the missing evidence" \
  "$ID_NO_STDERR" "## Merge Evidence"

ID_CMT_EC=0
ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-050 IMPLEMENTED DONE "$(merge_manifest "<!--
${MERGE_VALID_BODY}
-->")" 2>/dev/null || ID_CMT_EC=$?
assert_exit_code "IMPLEMENTED -> DONE: commented-out merge evidence is refused" "$ID_CMT_EC" 1

# The review route must survive untouched, and the merge route must be an ALTERNATIVE
# to it rather than a way around it — so all three combinations are asserted.
create_task_file TASK-051 IN_REVIEW
create_review_dir TASK-051
IR_REVIEW_STDERR=$(ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-051 IN_REVIEW DONE "$NO_MERGE_MANIFEST" 2>&1 >/dev/null) \
  && IR_REVIEW_EC=0 || IR_REVIEW_EC=$?
assert_exit_code "IN_REVIEW -> DONE: the review-evidence route still completes on its own" "$IR_REVIEW_EC" 0
assert_contains "IN_REVIEW -> DONE: the diagnostic names the review-evidence route" \
  "$IR_REVIEW_STDERR" "review-evidence route"
assert_not_contains "IN_REVIEW -> DONE: an approval is never described as a closure" \
  "$IR_REVIEW_STDERR" "merge-evidence route"

create_task_file TASK-052 IN_REVIEW
IR_MERGE_STDERR=$(ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-052 IN_REVIEW DONE "$MERGE_OK_MANIFEST" 2>&1 >/dev/null) \
  && IR_MERGE_EC=0 || IR_MERGE_EC=$?
assert_exit_code "IN_REVIEW -> DONE: merge evidence alone completes when the review route does not" "$IR_MERGE_EC" 0
assert_contains "IN_REVIEW -> DONE: the diagnostic names the merge-evidence route" \
  "$IR_MERGE_STDERR" "merge-evidence route"
assert_not_contains "IN_REVIEW -> DONE: a closure is never described as an approval" \
  "$IR_MERGE_STDERR" "via the review-evidence route"

create_task_file TASK-053 IN_REVIEW
IR_NEITHER_STDERR=$(ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-053 IN_REVIEW DONE "$NO_MERGE_MANIFEST" 2>&1 >/dev/null) \
  && IR_NEITHER_EC=0 || IR_NEITHER_EC=$?
assert_exit_code "IN_REVIEW -> DONE: NOT a bypass — refused when neither route validates" "$IR_NEITHER_EC" 1
assert_contains "IN_REVIEW -> DONE: the refusal names both routes" "$IR_NEITHER_STDERR" "neither did"

IR_CR_EC=0
ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" TASK-053 IN_REVIEW CHANGES_REQUESTED "$NO_MERGE_MANIFEST" 2>/dev/null \
  || IR_CR_EC=$?
assert_exit_code "IN_REVIEW -> CHANGES_REQUESTED is unaffected by the merge route" "$IR_CR_EC" 0

# Route-disposition matrix: every row is a (from,to,evidence) combination whose verdict
# is stated here rather than inferred, so a row that stops being reachable is visible.
MERGE_ROWS=0
MERGE_ROWS_CHECKED=0
MERGE_ROWS_SKIPPED=0
MERGE_ROWS_FINDINGS=0
merge_row() {
  local name="$1" task="$2" from="$3" to="$4" manifest="$5" expect="$6" actual=0
  MERGE_ROWS=$((MERGE_ROWS + 1))
  if [ -z "$manifest" ]; then
    MERGE_ROWS_SKIPPED=$((MERGE_ROWS_SKIPPED + 1))
    echo "  SKIP: merge-route row '${name}' — no fixture manifest"
    return 0
  fi
  MERGE_ROWS_CHECKED=$((MERGE_ROWS_CHECKED + 1))
  ttg_validate_transition "$NAZGUL_DIR" "$TEST_DIR" "$task" "$from" "$to" "$manifest" 2>/dev/null || actual=$?
  if [ "$actual" = "$expect" ]; then
    _pass "merge-route row: ${name}"
  else
    MERGE_ROWS_FINDINGS=$((MERGE_ROWS_FINDINGS + 1))
    _fail "merge-route row: ${name}" "expected exit: $expect" "  actual exit: $actual"
  fi
}
create_task_file TASK-054 IN_REVIEW
create_review_dir TASK-054
merge_row "IMPLEMENTED->DONE + merge evidence = accept" TASK-050 IMPLEMENTED DONE "$MERGE_OK_MANIFEST" 0
merge_row "IMPLEMENTED->DONE + no evidence = refuse" TASK-050 IMPLEMENTED DONE "$NO_MERGE_MANIFEST" 1
merge_row "IN_REVIEW->DONE + review only = accept" TASK-051 IN_REVIEW DONE "$NO_MERGE_MANIFEST" 0
merge_row "IN_REVIEW->DONE + merge only = accept" TASK-052 IN_REVIEW DONE "$MERGE_OK_MANIFEST" 0
merge_row "IN_REVIEW->DONE + both = accept" TASK-054 IN_REVIEW DONE "$MERGE_OK_MANIFEST" 0
merge_row "IN_REVIEW->DONE + neither = refuse" TASK-053 IN_REVIEW DONE "$NO_MERGE_MANIFEST" 1
merge_row "IMPLEMENTED->IN_REVIEW is untouched by the merge route" TASK-051 IMPLEMENTED IN_REVIEW "$NO_MERGE_MANIFEST" 0
echo "  merge-route: ${MERGE_ROWS} scanned, ${MERGE_ROWS_SKIPPED} skipped (no-fixture=${MERGE_ROWS_SKIPPED}), ${MERGE_ROWS_CHECKED} checked, ${MERGE_ROWS_FINDINGS} findings"
assert_eq "merge-route: scanned == skipped + checked" "$MERGE_ROWS" "$((MERGE_ROWS_SKIPPED + MERGE_ROWS_CHECKED))"
assert_eq "merge-route: every declared row was actually driven" "$MERGE_ROWS_CHECKED" "7"
assert_eq "merge-route: no row disagreed with its declared verdict" "$MERGE_ROWS_FINDINGS" "0"
teardown_temp_dir
rm -f "$MERGE_ERR"

report_results
