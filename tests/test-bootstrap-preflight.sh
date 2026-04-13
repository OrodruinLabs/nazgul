#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-preflight"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-preflight.sh
source "$REPO_ROOT/scripts/lib/bootstrap-preflight.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-preflight-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- check_no_hydra_dir ---
mkdir -p "$WORK/with-hydra/hydra"
mkdir -p "$WORK/clean"

(cd "$WORK/clean" && check_no_hydra_dir) && _pass "clean: no hydra dir" || _fail "clean: no hydra dir"

set +e
(cd "$WORK/with-hydra" && check_no_hydra_dir >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "hydra dir present: exit 10" "$ec" 10

# --- check_docs_agents_empty ---
mkdir -p "$WORK/empty"
(cd "$WORK/empty" && check_docs_agents_empty) && _pass "empty: passes" || _fail "empty: passes"

mkdir -p "$WORK/has-docs/docs"
touch "$WORK/has-docs/docs/PRD.md"
set +e
(cd "$WORK/has-docs" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "docs non-empty: exit 11" "$ec" 11

mkdir -p "$WORK/has-agents/.claude/agents"
touch "$WORK/has-agents/.claude/agents/reviewer.md"
set +e
(cd "$WORK/has-agents" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "agents non-empty: exit 11" "$ec" 11

# --- check_scratch_state ---
mkdir -p "$WORK/no-scratch"
(cd "$WORK/no-scratch" && check_scratch_state) && _pass "no scratch: passes" || _fail "no scratch: passes"

mkdir -p "$WORK/with-scratch/.bootstrap-scratch"
set +e
(cd "$WORK/with-scratch" && check_scratch_state >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "scratch exists: exit 12" "$ec" 12

# --- check_git_clean (non-blocking; returns 0 but sets warning flag) ---
cd "$WORK/clean"
git init -q
BOOTSTRAP_GIT_WARNING=""
check_git_clean
assert_eq "clean git: no warning" "$BOOTSTRAP_GIT_WARNING" ""

touch "$WORK/clean/dirty.txt"
BOOTSTRAP_GIT_WARNING=""
check_git_clean
assert_contains "dirty git: warning set" "$BOOTSTRAP_GIT_WARNING" "uncommitted"

cd "$REPO_ROOT"
report_results
