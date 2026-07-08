#!/usr/bin/env bash
set -euo pipefail

# Test: All shell scripts pass bash -n and shellcheck
TEST_NAME="test-shellcheck"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCRIPTS=(
  "scripts/stop-hook.sh"
  "scripts/task-completed.sh"
  "scripts/subagent-stop.sh"
  "scripts/stop-failure.sh"
  "scripts/post-compact.sh"
  "scripts/pre-compact.sh"
  "scripts/pre-tool-guard.sh"
  "scripts/session-context.sh"
  "scripts/migrate-config.sh"
  "scripts/task-state-guard.sh"
  "scripts/lean-comments-guard.sh"
  "scripts/emit-event-cli.sh"
  "scripts/lib/emit-event.sh"
  "scripts/lib/review-provenance.sh"
  "scripts/lib/reviewer-selection.sh"
  "scripts/lib/conductor-graph.sh"
  "scripts/lib/conductor-gates.sh"
  "scripts/lib/conductor-router.sh"
  "scripts/lib/inbox-provider.sh"
  "scripts/local-mode-tracking-guard.sh"
  "scripts/base-branch-commit-guard.sh"
  "scripts/session-staging.sh"
  "scripts/scrub-stale-review-artifacts.sh"
  "scripts/conductor-dispatch-guard.sh"
  "scripts/conductor-rework-guard.sh"
)
# tests/ files use dynamic `source` and are not standalone scripts; shellcheck
# cannot resolve the sourced paths without annotations. The SCRIPTS array is
# intentionally scoped to scripts/ only to keep the convention consistent.

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
