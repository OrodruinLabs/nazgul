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

# Design files are also managed — must block if present.
mkdir -p "$WORK/has-tokens/.claude"
echo '{}' > "$WORK/has-tokens/.claude/design-tokens.json"
set +e
(cd "$WORK/has-tokens" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "design-tokens.json present: exit 11" "$ec" 11

mkdir -p "$WORK/has-design/.claude"
echo "# Design" > "$WORK/has-design/.claude/design-system.md"
set +e
(cd "$WORK/has-design" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "design-system.md present: exit 11" "$ec" 11

# Error message should list ALL blockers at once, not one at a time.
mkdir -p "$WORK/has-many/docs" "$WORK/has-many/.claude/agents"
echo x > "$WORK/has-many/docs/PRD.md"
echo x > "$WORK/has-many/.claude/agents/code-reviewer.md"
MANY_ERR=$(cd "$WORK/has-many" && check_docs_agents_empty 2>&1 >/dev/null || true)
assert_contains "error lists ./docs blocker"           "$MANY_ERR" "./docs"
assert_contains "error lists ./.claude/agents blocker" "$MANY_ERR" "./.claude/agents"

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
