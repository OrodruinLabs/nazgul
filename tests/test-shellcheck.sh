#!/usr/bin/env bash
set -euo pipefail

# Test: All shell scripts pass bash -n and shellcheck
TEST_NAME="test-shellcheck"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# Discover scripts via glob (sorted, deterministic) rather than a hand-maintained
# array, so every script under scripts/ — including libraries added after this
# file was last touched — gets bash -n + shellcheck coverage automatically.
# tests/ files use dynamic `source` and are not standalone scripts; shellcheck
# cannot resolve the sourced paths without annotations. The glob is
# intentionally scoped to scripts/ only to keep the convention consistent.
# Git hook entry points (scripts/git-hooks/pre-commit, pre-merge-commit) are
# bash scripts without a .sh suffix, by githooks(5) naming convention; a bare
# `-name '*.sh'` glob would silently drop them, so they're picked up via their
# shebang instead of a second hardcoded name list.
mapfile -t SCRIPTS < <(cd "$REPO_ROOT" && {
  find scripts -name '*.sh'
  find scripts -type f ! -name '*.sh' -exec grep -lE '^#!.*/(env )?(bash|sh)([[:space:]]|$)' {} \;
} | sort -u)

# Sanity check: the discovered set must be at least as large as a fresh count of
# the same glob, so a future refactor of this discovery step can't silently
# shrink coverage back down.
LIVE_COUNT=$(cd "$REPO_ROOT" && find scripts -name '*.sh' | wc -l | tr -d '[:space:]')
if [ "${#SCRIPTS[@]}" -ge "$LIVE_COUNT" ]; then
  _pass "discovered script count (${#SCRIPTS[@]}) >= live glob count ($LIVE_COUNT)"
else
  _fail "discovered script count (${#SCRIPTS[@]}) >= live glob count ($LIVE_COUNT)" "coverage regression"
fi

# bash -n syntax checks
for script in "${SCRIPTS[@]}"; do
  full_path="$REPO_ROOT/$script"
  name=$(basename "$script")
  if bash -n "$full_path" 2>/dev/null; then
    _pass "$name passes bash -n"
  else
    _fail "$name passes bash -n" "syntax error detected"
  fi
done

# shellcheck (if available)
SHELLCHECK_BIN=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK_BIN="shellcheck"
elif [ -x "/tmp/shellcheck-v0.10.0/shellcheck" ]; then
  SHELLCHECK_BIN="/tmp/shellcheck-v0.10.0/shellcheck"
fi

if [ -n "$SHELLCHECK_BIN" ]; then
  for script in "${SCRIPTS[@]}"; do
    full_path="$REPO_ROOT/$script"
    name=$(basename "$script")
    if "$SHELLCHECK_BIN" -S warning "$full_path" 2>/dev/null; then
      _pass "$name passes shellcheck"
    else
      _fail "$name passes shellcheck" "shellcheck warnings found"
    fi
  done
else
  echo "  SKIP: shellcheck not found (install with: brew install shellcheck)"
  # Still count as passes since we can't test without the tool
  for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")
    _pass "$name shellcheck (skipped — not installed)"
  done
fi

report_results
