#!/usr/bin/env bash
set -euo pipefail

# Nazgul Base-Branch Commit Guard — blocks `git commit` on the base branch
# while a loop is active (branch.feature is set).
#
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)
#
# Degradation: exits 0 when config absent, branch.feature null/absent, the
# target repo is not on the base branch, the command is not a git commit,
# empty stdin, or the target of a `-C` flag is not a git repo at all.
#
# ADR-003: resolves the ACTUAL target repo of the `git commit` command instead
# of trusting `$CLAUDE_PROJECT_DIR` alone. A bounded, no-`eval`, no-whole-
# string-regex tokenizer (FEAT-005 discipline) walks the command's own
# argument list — per `;`/`&&`/`||`/`|`/`&`/newline-separated segment, quote
# aware — to (a) determine whether a segment is actually a `git ... commit`
# invocation (a plain substring/regex check like the previous `git\s+commit`
# filter cannot see past an intervening `-C <path>` or other global option)
# and (b) extract that segment's `-C <path>` value, if any. The target's
# canonical repo root (`git rev-parse --show-toplevel`) is then compared
# against the active-loop project's own resolved root — a different repo is
# allowed immediately (closes the false positive: `git -C /unrelated/repo
# commit` never touches this project). Only when the roots match does the
# guard resolve the TARGET's current branch (not `$CLAUDE_PROJECT_DIR`'s) for
# the base-branch decision (closes the false negative: a `-C` pointing at
# this project's own base-branch checkout is now correctly inspected instead
# of blindly trusting whatever branch `$CLAUDE_PROJECT_DIR` happens to be on).

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

# --- Bounded, no-eval tokenizer: is this a `git commit` invocation, and does
# it carry a `-C <path>`? -----------------------------------------------------
# Splits the command into words on whitespace while respecting single/double
# quotes (a closing quote does not flush — an adjacent quoted+unquoted
# fragment stays one word), resetting per-segment state on shell separators
# (`;` `&&` `||` `|` `&` newline, outside quotes) so each pipeline segment is
# evaluated independently — the same discipline already used by
# `scripts/local-mode-tracking-guard.sh` (FEAT-005). For the FIRST segment
# whose command word is "git", it skips known global options (value-taking
# `-C`/`-c`, single-token `--work-tree=`/`--git-dir=`/`--exec-path=`/
# `--namespace=`, flag-only `-p`/`--paginate`/`--no-pager`/`--bare`/
# `--no-replace-objects`/`--literal-pathspecs`, and any other unrecognized
# `-`-prefixed flag) to find the subcommand. If that subcommand is "commit",
# prints `1` then the segment's last-seen `-C` value (possibly empty);
# otherwise prints `0` and an empty second line. No `eval`, no whole-string
# regex extraction of untrusted content: the only use of the extracted `-C`
# value is as a single quoted argument to `git -C`, so shell metacharacters
# embedded in it (e.g. `$(...)`, `;`, backticks) are inert.
detect_commit_and_dash_c() {
  printf '%s' "$1" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""
  seg_git = 0; seg_subcmd = ""; seg_cpath = ""; seg_skipval = 0; skipval_is_C = 0
  found_commit = 0; final_cpath = ""
}
function reset_seg() { seg_git = 0; seg_subcmd = ""; seg_cpath = ""; seg_skipval = 0; skipval_is_C = 0 }
function handle_tok(t) {
  if (found_commit) return
  if (seg_skipval) {
    seg_skipval = 0
    if (skipval_is_C) seg_cpath = t
    skipval_is_C = 0
    return
  }
  if (!seg_git) {
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    if (t != "git") { return }
    seg_git = 1
    return
  }
  if (seg_subcmd == "") {
    if (t == "-C" || t == "-c") { seg_skipval = 1; skipval_is_C = (t == "-C"); return }
    if (t ~ /^--(work-tree|git-dir|exec-path|namespace)=/) return
    if (t ~ /^(-p|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs)$/) return
    if (t ~ /^-/) return
    seg_subcmd = t
    if (seg_subcmd == "commit") { found_commit = 1; final_cpath = seg_cpath }
    return
  }
}
{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      if (c == "'"'"'") in_sq = 0
      else tok = tok c
    } else if (in_dq) {
      if (c == "\\" && i < n) { i++; tok = tok substr($0, i, 1) }
      else if (c == "\"") in_dq = 0
      else tok = tok c
    } else if (c == "'"'"'") {
      in_sq = 1
    } else if (c == "\"") {
      in_dq = 1
    } else if (c == " " || c == "\t") {
      if (tok != "") { handle_tok(tok); tok = "" }
    } else if (c == ";" || c == "|") {
      if (tok != "") { handle_tok(tok); tok = "" }
      reset_seg()
    } else if (c == "&") {
      if (tok != "") { handle_tok(tok); tok = "" }
      reset_seg()
    } else {
      tok = tok c
    }
  }
  if (in_sq || in_dq) {
    # quoted string spans the newline — keep accumulating
  } else {
    if (tok != "") { handle_tok(tok); tok = "" }
    reset_seg()
  }
}
END {
  print found_commit
  print final_cpath
}
'
}

DETECT_OUT=$(detect_commit_and_dash_c "$CMD")
IS_COMMIT=$(printf '%s\n' "$DETECT_OUT" | sed -n '1p')
CPATH=$(printf '%s\n' "$DETECT_OUT" | sed -n '2p')

# Not a `git commit` invocation (in any segment we recognize) — allow.
if [ "$IS_COMMIT" != "1" ]; then
  exit 0
fi

# Resolve the actual target of this commit: the `-C` value if present,
# otherwise `$CLAUDE_PROJECT_DIR`.
TARGET_DIR="${CPATH:-$PROJECT_ROOT}"

# Degrade gracefully: target is not a git repo at all (bogus/nonexistent path,
# including a `-C` value stuffed with shell metacharacters — it is never
# evaluated, just handed to `git -C` as a literal argument, so it simply fails
# to resolve and we allow, with zero side effects).
TARGET_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$TARGET_ROOT" ]; then
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

# Resolve the active-loop project's own canonical root the same way.
PROJECT_ROOT_RESOLVED=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")

# Different repo (or the active-loop project itself isn't a git repo) — the
# command never touches this project. Allow immediately (closes the false
# positive: `git -C /unrelated/repo commit` was previously blocked solely
# because $CLAUDE_PROJECT_DIR happened to be on the base branch).
if [ -z "$PROJECT_ROOT_RESOLVED" ] || [ "$TARGET_ROOT" != "$PROJECT_ROOT_RESOLVED" ]; then
  exit 0
fi

# Base branch (default "main")
BASE=$(jq -r '.branch.base // "main"' "$CONFIG" 2>/dev/null || echo "main")

# Same repo — resolve the TARGET's current branch (not $CLAUDE_PROJECT_DIR's)
# for the actual decision (closes the false negative: a `-C` pointing at this
# project's own base-branch checkout is now inspected on its own terms).
# Empty result (detached HEAD, error) degrades to allow.
CURRENT=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || echo "")
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
