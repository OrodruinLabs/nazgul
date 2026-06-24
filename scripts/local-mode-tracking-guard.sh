#!/usr/bin/env bash
set -euo pipefail

# Nazgul Local-Mode Tracking Guard — blocks git add/stage/commit on nazgul/ paths
# when install_mode is "local".
#
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)
#
# Degradation: exits 0 when config absent, install_mode absent/non-local,
# command has no nazgul/ pathspec, or stdin is empty.
#
# Known limitation: the awk tokenizer strips single- and double-quoted spans only.
# It does not handle $'...' ANSI-C quoting or backslash-escaped spaces in unquoted
# tokens. Those edge cases degrade to allow, which is acceptable for Nazgul loop usage.

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
if ! echo "$CMD" | grep -qiE 'git[[:space:]]+(add|stage|commit)'; then
  exit 0
fi

# Parse POSITIONAL pathspec arguments — excluding flags and their value tokens.
# The awk tokenizer splits on whitespace while collapsing single- and double-quoted
# spans (strips the outermost quote pair). It then:
#   1. Skips the "git" token itself.
#   2. Skips the subcommand (add/stage/commit).
#   3. Consumes value-taking flags (-m/-am/--message, -F/--file, -C/--reuse-message,
#      --author, --date) plus their next token (or inline --flag=value), so a commit
#      message mentioning nazgul/ is never mistaken for a pathspec.
#   4. After a -- end-of-options marker, treats every remaining token as a pathspec.
#   5. Reports 1 if any positional token equals "nazgul" or starts with "nazgul/".
HAS_NAZGUL_PATH=$(printf '%s' "$CMD" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""; found = 0
  git_seen = 0; subcmd_seen = 0; end_of_opts = 0; skip_next = 0
}

function emit(t,    is_value_flag) {
  if (skip_next) { skip_next = 0; return }
  if (!git_seen)    { git_seen = 1;    return }
  if (!subcmd_seen) { subcmd_seen = 1; return }
  if (end_of_opts)  { check_path(t);   return }
  if (t == "--")    { end_of_opts = 1; return }
  is_value_flag = (t ~ /^(-[a-zA-Z]*m|--message|--message=.*|-F|--file|-C|--reuse-message|--author|--date)$/)
  if (is_value_flag) {
    if (t !~ /=/) skip_next = 1
    return
  }
  if (t ~ /^-/) { return }
  check_path(t)
}

function check_path(t) {
  if (t == "nazgul" || index(t, "nazgul/") == 1) found = 1
}

{
  for (i = 1; i <= length($0); i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      if (c == "'\''") { in_sq = 0; emit(tok); tok = "" }
      else tok = tok c
    } else if (in_dq) {
      if (c == "\"") { in_dq = 0; emit(tok); tok = "" }
      else tok = tok c
    } else if (c == "'\''") {
      if (tok != "") { emit(tok); tok = "" }
      in_sq = 1
    } else if (c == "\"") {
      if (tok != "") { emit(tok); tok = "" }
      in_dq = 1
    } else if (c == " " || c == "\t") {
      if (tok != "") { emit(tok); tok = "" }
    } else {
      tok = tok c
    }
  }
  if (tok != "") { emit(tok); tok = "" }
}

END { print found }
')

if [ "$HAS_NAZGUL_PATH" != "1" ]; then
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
