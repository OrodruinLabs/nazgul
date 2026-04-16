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

# --- check_no_nazgul_dir ---
mkdir -p "$WORK/with-nazgul/nazgul"
mkdir -p "$WORK/clean"

(cd "$WORK/clean" && check_no_nazgul_dir) && _pass "clean: no nazgul dir" || _fail "clean: no nazgul dir"

set +e
(cd "$WORK/with-nazgul" && check_no_nazgul_dir >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "nazgul dir present: exit 10" "$ec" 10

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

# Unreadable dir must FAIL CLOSED — not be silently treated as empty.
mkdir -p "$WORK/unreadable/docs"
chmod 000 "$WORK/unreadable/docs"
set +e
(cd "$WORK/unreadable" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
UNREAD_ERR=$(cd "$WORK/unreadable" && check_docs_agents_empty 2>&1 >/dev/null || true)
set -e
chmod 755 "$WORK/unreadable/docs"
assert_exit_code     "unreadable docs: exit 11" "$ec" 11
assert_contains      "error names unreadable"   "$UNREAD_ERR" "unreadable"

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

# --- detect_project_type ---
# Helper: runs detect_project_type in the given directory and echoes
# "<type> <count>" so the caller can capture it without losing state to a subshell.
_run_detect() {
  ( cd "$1" && detect_project_type && echo "$BOOTSTRAP_PROJECT_TYPE $BOOTSTRAP_SOURCE_COUNT" )
}

# Empty dir → greenfield, count=0
mkdir -p "$WORK/empty-proj"
result=$(_run_detect "$WORK/empty-proj")
assert_eq "empty dir: greenfield + count=0" "$result" "greenfield 0"

# Below threshold → greenfield
mkdir -p "$WORK/small-proj"
touch "$WORK/small-proj/a.js" "$WORK/small-proj/b.py" "$WORK/small-proj/c.ts"
result=$(_run_detect "$WORK/small-proj")
assert_eq "3 files: greenfield + count=3"   "$result" "greenfield 3"

# At/above threshold (5) → brownfield
mkdir -p "$WORK/big-proj/src"
touch "$WORK/big-proj/src/a.js" "$WORK/big-proj/src/b.ts" \
      "$WORK/big-proj/src/c.py" "$WORK/big-proj/src/d.go" \
      "$WORK/big-proj/src/e.rs"
result=$(_run_detect "$WORK/big-proj")
assert_eq "5 files: brownfield + count=5"   "$result" "brownfield 5"

# Excluded dirs must not be counted AND must be pruned (not descended into)
mkdir -p "$WORK/with-vendored/node_modules/foo" \
         "$WORK/with-vendored/vendor" \
         "$WORK/with-vendored/.bootstrap-scratch/context" \
         "$WORK/with-vendored/.git" \
         "$WORK/with-vendored/dist" \
         "$WORK/with-vendored/build" \
         "$WORK/with-vendored/.next" \
         "$WORK/with-vendored/target" \
         "$WORK/with-vendored/__pycache__" \
         "$WORK/with-vendored/.venv" \
         "$WORK/with-vendored/venv"
# Drop a pile of source-looking files INTO the excluded dirs — if prune works
# these shouldn't count even though there are more than 5 of them.
touch "$WORK/with-vendored/node_modules/foo/a.js" \
      "$WORK/with-vendored/node_modules/foo/b.js" \
      "$WORK/with-vendored/node_modules/foo/c.js" \
      "$WORK/with-vendored/vendor/d.py" \
      "$WORK/with-vendored/vendor/e.py" \
      "$WORK/with-vendored/.bootstrap-scratch/context/f.ts" \
      "$WORK/with-vendored/dist/g.js" \
      "$WORK/with-vendored/build/h.ts" \
      "$WORK/with-vendored/.next/i.js" \
      "$WORK/with-vendored/target/j.rs" \
      "$WORK/with-vendored/__pycache__/k.py" \
      "$WORK/with-vendored/.venv/l.py" \
      "$WORK/with-vendored/venv/m.py"
# Plus two real source files at the root.
touch "$WORK/with-vendored/real1.js" "$WORK/with-vendored/real2.py"
result=$(_run_detect "$WORK/with-vendored")
assert_eq "excluded dirs ignored: greenfield + count=2" "$result" "greenfield 2"

# Non-source files don't inflate the count (config, markdown, JSON).
mkdir -p "$WORK/config-heavy"
touch "$WORK/config-heavy/package.json" \
      "$WORK/config-heavy/tsconfig.json" \
      "$WORK/config-heavy/README.md" \
      "$WORK/config-heavy/.eslintrc" \
      "$WORK/config-heavy/Dockerfile" \
      "$WORK/config-heavy/.env.example"
result=$(_run_detect "$WORK/config-heavy")
assert_eq "config files only: greenfield + count=0" "$result" "greenfield 0"

cd "$REPO_ROOT"
report_results
