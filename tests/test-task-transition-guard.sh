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
