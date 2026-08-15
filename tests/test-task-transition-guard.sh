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
MERGE_VALID_BODY='- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'

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
create_config '.agents.reviewers = ["code-reviewer"]'
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

me_verify "$(merge_manifest '- **host**: github.com
- **pr**: not-a-number
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')" "$TEST_DIR" TASK-050 && MALF_EC=0 || MALF_EC=$?
MALFORMED_STDERR="$ME_STDERR"
assert_exit_code "ttg_verify_merge_evidence: a non-numeric pr is refused" "$MALF_EC" 1
assert_eq "ttg_verify_merge_evidence: a bad field value reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"
assert_contains "ttg_verify_merge_evidence: the malformed diagnostic names the offending field" \
  "$MALFORMED_STDERR" "pr="

ttg_verify_merge_evidence "$(merge_manifest '- **host**: github.com
- **pr**: 91
- **merged-at**: yesterday
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a free-text merged-at reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

ttg_verify_merge_evidence "$(merge_manifest '- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: zzzznotahexsha')" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a non-hex merge-commit reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

ttg_verify_merge_evidence "$(merge_manifest '- **host**: not a host name
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')" "$TEST_DIR" TASK-050 2>/dev/null
assert_eq "ttg_verify_merge_evidence: a whitespace-bearing host reasons 'malformed'" "$TTG_MERGE_REASON" "malformed"

# Every refusal state must be its own token AND its own sentence — a state folded into
# a neighbour's bucket would leave both censuses unchanged.
MERGE_DISTINCT=$(printf '%s\n%s\n%s\n%s\n' "$ABSENT_STDERR" "$COMMENTED_STDERR" "$TRUNCATED_STDERR" "$MALFORMED_STDERR" | sort -u | grep -c '[^[:space:]]')
assert_eq "ttg_verify_merge_evidence: four refusal states, four distinct diagnostics" "$MERGE_DISTINCT" "4"

MERGE_VOCAB_EXPECTED='absent commented_out malformed truncated'
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

ANC_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_HEAD}"
me_verify "$(merge_manifest "$ANC_BODY" "- ${ANC_PARENT}")" "$TEST_DIR" TASK-050 && CORROB_EC=0 || CORROB_EC=$?
CORROB_STDERR="$ME_STDERR"
assert_exit_code "ancestry: a reachable merge commit verifies" "$CORROB_EC" 0
assert_eq "ancestry: a recorded commit reaching the merge commit is corroborated" "$TTG_MERGE_ANCESTRY" "corroborated"
assert_contains "ancestry: corroboration is named in the diagnostic" "$CORROB_STDERR" "corroborates"

INV_BODY="- **host**: github.com
- **pr**: 91
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: ${ANC_PARENT}"
me_verify "$(merge_manifest "$INV_BODY" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 && SQUASH_EC=0 || SQUASH_EC=$?
SQUASH_STDERR="$ME_STDERR"
assert_exit_code "ancestry: a FAILED is-ancestor check against API-merged evidence does NOT block" "$SQUASH_EC" 0
assert_eq "ancestry: a failed check is recorded as the expected squash signature" "$TTG_MERGE_ANCESTRY" "squash_signature"
assert_contains "ancestry: the squash signature is recorded, not reported as an anomaly" \
  "$SQUASH_STDERR" "expected squash signature"

ttg_verify_merge_evidence "$(merge_manifest "$MERGE_VALID_BODY" "- ${ANC_HEAD}")" "$TEST_DIR" TASK-050 2>/dev/null \
  && GONE_EC=0 || GONE_EC=$?
assert_exit_code "ancestry: a merge commit absent from local history does not block" "$GONE_EC" 0
assert_eq "ancestry: an unresolvable merge commit is the squash signature, not 'malformed'" \
  "$TTG_MERGE_ANCESTRY" "squash_signature"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
NAZGUL_DIR="$TEST_DIR/nazgul"
ttg_verify_merge_evidence "$(merge_manifest "$MERGE_VALID_BODY")" "$TEST_DIR" TASK-050 2>/dev/null \
  && NOGIT_EC=0 || NOGIT_EC=$?
assert_exit_code "ancestry: a non-git project root does not block the merge route" "$NOGIT_EC" 0
assert_eq "ancestry: an uncheckable corroboration is named 'unavailable'" "$TTG_MERGE_ANCESTRY" "unavailable"
teardown_temp_dir

# The edge and its condition are two separate facts, so both are asserted: present in
# the graph, and REFUSED by ttg_validate_transition without merge evidence.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = false' '.afk.task_pr = false'
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
