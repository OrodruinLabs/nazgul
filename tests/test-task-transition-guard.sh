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
IMPLEMENTED:IN_REVIEW IN_REVIEW:DONE IN_REVIEW:APPROVED \
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

report_results
