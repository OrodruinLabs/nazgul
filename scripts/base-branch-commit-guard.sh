#!/usr/bin/env bash
set -euo pipefail

# Nazgul Base-Branch Commit Guard — blocks `git commit` on the base branch
# while a loop is active (branch.feature is set).
#
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)
#
# Degradation: exits 0 when config absent, branch.feature null/absent, the
# current branch is not the base branch, the command is not a git commit, or
# stdin is empty.

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_ROOT/nazgul/config.json"

# Read tool input from stdin (Claude Code passes JSON for PreToolUse hooks)
INPUT=$(cat 2>/dev/null || echo "")

# No input — allow
if [ -z "$INPUT" ]; then
  exit 0
fi

# Extract command string from JSON input (PreToolUse Bash hook format)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Fall back: if input is plain text (not JSON), treat it as the command
if [ -z "$CMD" ]; then
  CMD="$INPUT"
fi

# No command — allow
if [ -z "$CMD" ]; then
  exit 0
fi

# Only consider `git commit`. The vast majority of Bash calls exit here.
# `\bcommit\b` keeps `git commit` distinct from substrings like `--amend-commit`.
if ! echo "$CMD" | grep -qiE 'git\s+commit'; then
  exit 0
fi

# Degrade gracefully: config absent → allow
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Only active during a loop: branch.feature must be set and non-null.
FEATURE=$(jq -r '.branch.feature // ""' "$CONFIG" 2>/dev/null || echo "")
if [ -z "$FEATURE" ]; then
  exit 0
fi

# Base branch (default "main")
BASE=$(jq -r '.branch.base // "main"' "$CONFIG" 2>/dev/null || echo "main")

# Current branch — empty result (detached HEAD, error) degrades to allow.
CURRENT=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
if [ -z "$CURRENT" ] || [ "$CURRENT" != "$BASE" ]; then
  exit 0
fi

# Block: committing to the base branch while a feature branch is active.
echo "NAZGUL GUARD: Blocked — cannot commit to the base branch '$BASE' during an active loop." >&2
echo "" >&2
echo "  Command: $CMD" >&2
echo "" >&2
echo "  An objective is in progress on feature branch '$FEATURE'. Loop commits" >&2
echo "  must land on the feature branch, never on the base branch directly." >&2
echo "" >&2
echo "  Switch to the feature branch and commit there:" >&2
echo "    git checkout $FEATURE" >&2
exit 2
