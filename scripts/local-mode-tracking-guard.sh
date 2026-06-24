#!/usr/bin/env bash
set -euo pipefail

# Nazgul Local-Mode Tracking Guard — blocks git add/stage/commit on nazgul/ paths
# when install_mode is "local".
#
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)
#
# Degradation: exits 0 when config absent, install_mode absent/non-local,
# command has no nazgul/ token, or stdin is empty.

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

# Only block git add / git stage / git commit commands that touch nazgul/ paths.
# Check these before reading config — the vast majority of Bash calls exit here.
if ! echo "$CMD" | grep -qiE 'git\s+(add|stage|commit)'; then
  exit 0
fi

# Look for a nazgul/ PATH being staged. Strip ONLY the commit-message argument
# (-m / -am... / --message / --message=...) so a message that merely MENTIONS
# nazgul/ is not falsely blocked — while a real nazgul/ pathspec, even a quoted
# one like `git add "nazgul/config.json"`, is still caught (we do NOT strip all
# quoted text, only the message value).
CMD_PATHS=$(printf '%s' "$CMD" \
  | sed -E "s/(-[a-zA-Z]*m|--message)[[:space:]]+'[^']*'//g" \
  | sed -E "s/(-[a-zA-Z]*m|--message)[[:space:]]+\"[^\"]*\"//g" \
  | sed -E "s/--message=[^[:space:]]*//g")
if ! printf '%s' "$CMD_PATHS" | grep -qiE 'nazgul/'; then
  exit 0
fi

# Degrade gracefully: config absent → allow
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Read install_mode — absent or non-local → allow
INSTALL_MODE=$(jq -r '.install_mode // ""' "$CONFIG" 2>/dev/null || echo "")
if [ "$INSTALL_MODE" != "local" ]; then
  exit 0
fi

# Block: local mode + git tracking + nazgul/ path
echo "NAZGUL GUARD: Blocked — cannot track nazgul/ paths in local install mode." >&2
echo "" >&2
echo "  Command: $CMD" >&2
echo "" >&2
echo "  nazgul/ contains runtime state (config, task manifests, logs) that" >&2
echo "  must NOT be committed when install_mode is \"local\". These files" >&2
echo "  belong to this project workspace only." >&2
echo "" >&2
echo "  To keep the file on disk but untracked, add it to .gitignore:" >&2
echo "    echo 'nazgul/' >> .gitignore" >&2
echo "" >&2
echo "  To stage non-nazgul files, run git add without the nazgul/ path." >&2
exit 2
