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
# ADR-003: resolves the ACTUAL target repo of each `git commit` invocation
# instead of trusting `$CLAUDE_PROJECT_DIR` alone. A bounded, no-`eval`,
# no-whole-string-regex tokenizer (FEAT-005 discipline) walks the command's
# own argument list — per `;`/`&&`/`||`/`|`/`&`/newline-separated segment,
# quote aware — and reports EVERY segment that is a `git ... commit`
# invocation (not just the first) along with its `-C <path>` value, if any.
# Each reported segment is resolved and checked independently via
# `git rev-parse --show-toplevel`; the command is blocked if ANY segment
# resolves to this project's own base branch, so a decoy/unrelated commit
# segment earlier in a compound command cannot hide a real one later.
#
# The tokenizer only recognizes a literal top-level `git` word — it does not
# recurse into quoted strings or command substitutions, so `bash -c 'git
# commit'` or `true "$(git commit)"` are invisible to it (same documented
# blind spot as `scripts/local-mode-tracking-guard.sh`). As a compensating
# control, a raw substring check for `git` + `commit` (adjacent,
# whitespace-separated) always runs against the ORIGINAL command text, in
# ADDITION to the precise per-segment pass, not only when the precise pass
# finds nothing — a tokenizer-visible commit segment elsewhere in the same
# compound command must not suppress detection of a co-occurring
# interpreter-wrapped one. A substring hit is resolved against
# `$CLAUDE_PROJECT_DIR` itself (erring toward block) rather than allowed.

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

# --- Bounded, no-eval tokenizer: which segments are `git commit` invocations,
# and what `-C <path>` (if any) does each carry? ------------------------------
# Splits the command into words on whitespace while respecting single/double
# quotes (a closing quote does not flush — an adjacent quoted+unquoted
# fragment stays one word), resetting per-segment state on shell separators
# (`;` `&&` `||` `|` `&` newline, outside quotes) so each pipeline segment is
# evaluated independently — the same discipline already used by
# `scripts/local-mode-tracking-guard.sh` (FEAT-005). For each segment whose
# command word is "git", it skips known global options (value-taking
# `-C`/`-c`, single-token `--work-tree=`/`--git-dir=`/`--exec-path=`/
# `--namespace=`, flag-only `-p`/`--paginate`/`--no-pager`/`--bare`/
# `--no-replace-objects`/`--literal-pathspecs`, and any other unrecognized
# `-`-prefixed flag) to find the subcommand. Every segment whose subcommand is
# "commit" emits one tab-separated record line (`1<TAB><-C value, possibly
# empty>`) — no segment is skipped once an earlier one matches. No `eval`,
# no whole-string regex extraction of untrusted content: the only
# use of an extracted `-C` value is as a single quoted argument to `git -C`,
# so shell metacharacters embedded in it (e.g. `$(...)`, `;`, backticks) are
# inert.
detect_commit_segments() {
  printf '%s' "$1" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""
  seg_git = 0; seg_subcmd = ""; seg_cpath = ""; seg_skipval = 0; skipval_is_C = 0
}
function reset_seg() { seg_git = 0; seg_subcmd = ""; seg_cpath = ""; seg_skipval = 0; skipval_is_C = 0 }
function handle_tok(t) {
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
    if (seg_subcmd == "commit") { printf "1\t%s\n", seg_cpath }
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
'
}

# Degrade gracefully: config absent → allow
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Only active during a loop: branch.feature must be set and non-null.
FEATURE=$(jq -r '.branch.feature // ""' "$CONFIG" 2>/dev/null || echo "")
if [ -z "$FEATURE" ]; then
  exit 0
fi

BASE=$(jq -r '.branch.base // "main"' "$CONFIG" 2>/dev/null || echo "main")
PROJECT_ROOT_RESOLVED=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")

# Resolve one candidate target dir; block (and exit 2) if it is THIS project,
# currently checked out on the base branch. Any other outcome returns (allow
# this candidate, caller keeps checking the rest).
block_if_target_on_base() {
  local target_dir="$1"
  [ -n "$PROJECT_ROOT_RESOLVED" ] || return 0

  local target_root
  target_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$target_root" ] || return 0
  [ "$target_root" = "$PROJECT_ROOT_RESOLVED" ] || return 0

  local current
  current=$(git -C "$target_dir" branch --show-current 2>/dev/null || echo "")
  [ "$current" = "$BASE" ] || return 0

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
}

DETECT_OUT=$(detect_commit_segments "$CMD")

# Precise pass: evaluate EVERY tokenized commit segment independently (fixes
# the B1 first-match short-circuit — no segment is allowed to hide a later
# one).
if [ -n "$DETECT_OUT" ]; then
  while IFS=$'\t' read -r marker cpath; do
    [ "$marker" = "1" ] || continue
    block_if_target_on_base "${cpath:-$PROJECT_ROOT}"
  done <<< "$DETECT_OUT"
fi

# Fallback pass (B2/B3): the bounded tokenizer does not recurse into quotes or
# command substitutions, so a real commit wrapped in an interpreter
# (`bash -c '...'`) or substitution (`$(...)`, backticks) is invisible to it —
# regardless of whether ANOTHER, tokenizer-visible commit segment is also
# present in the same compound command (B3: a decoy/allowed segment must not
# suppress this check for the rest of the command). Always run the old
# whole-string substring trigger against the RAW command text; on a match,
# resolve conservatively against `$CLAUDE_PROJECT_DIR` itself rather than
# silently allowing.
if printf '%s' "$CMD" | grep -qiE 'git\s+commit'; then
  block_if_target_on_base "$PROJECT_ROOT"
fi

exit 0
