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
# Defense-in-depth note: primary protection is .gitignore + the session-staging
# install_mode chokepoint. This guard is a best-effort secondary layer. Leading and
# fd-numbered redirects (1>, 2>, &>) ARE skipped so they cannot hide a pathspec.
# Deeply exotic shell forms (process substitution, eval'd strings, nested subshells,
# command substitution, $'...' ANSI-C quoting) are out of scope by design and degrade
# to allow — acceptable for normal Nazgul loop usage.

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

# Cheap pre-filter: skip commands that contain neither "git" nor one of the tracked
# subcommands. Both must appear for any segment to be checkable. This is deliberately
# loose — the awk tokenizer below is the correctness gate. The pattern allows
# "git -C repo add nazgul/x" because git and add both appear.
# Word boundaries use explicit POSIX ERE character classes ((^|[^[:alnum:]_])…) rather
# than \b, which is a GNU/BSD extension undefined in POSIX ERE (it can match a backspace
# on some platforms, which would silently disable the whole guard).
if ! echo "$CMD" | grep -qiE '(^|[^[:alnum:]_])git([^[:alnum:]_]|$)'; then
  exit 0
fi
if ! echo "$CMD" | grep -qiE '(^|[^[:alnum:]_])(add|stage|commit)([^[:alnum:]_]|$)'; then
  exit 0
fi

# Tokenizer: splits on whitespace/separators while respecting single- and double-
# quoted spans. Adjacent quoted+unquoted fragments form ONE word (a closing quote
# does not flush), so a value like -m "foo"nazgul/x stays one message token and is
# never mis-split into a phantom nazgul/ pathspec. Each input LINE is one awk record. A newline INSIDE a quote continues the token
# (so a multiline commit message stays one skipped token); an UNQUOTED newline is a
# command separator that resets per-segment state — otherwise a multi-line input like
# `echo ok\n git add nazgul/x` would be read as one non-git segment and the real
# `git add` would slip through.
# Handles compound commands by resetting per-segment state on shell separators
# (;  &&  ||  |  newline  that occur OUTSIDE quotes) so each pipeline segment is
# checked independently. A segment whose first unquoted token is NOT "git" is skipped
# — preserving the false-positive fixes for grep/echo/etc. Redirect tokens that embed
# `&` (2>&1, >&2, &>) are NOT treated as separators, so a pathspec after them is still
# checked.
#
# git global options: after "git", the subcommand is identified by skipping known
# globals: value-taking -C/-c consume the next token; --work-tree=/--git-dir=/
# --exec-path=/--namespace= (with =) are single tokens; flag-only globals
# (-p/--paginate/--no-pager/--bare/--no-replace-objects/--literal-pathspecs) are
# skipped; the first remaining token is the subcommand.
HAS_NAZGUL_PATH=$(printf '%s' "$CMD" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""; found = 0
  git_seen = 0; subcmd_seen = 0; end_of_opts = 0
  skip_next = 0; not_git = 0; skip_global_val = 0; redir_skip_next = 0
}

function reset_segment() {
  git_seen = 0; subcmd_seen = 0; end_of_opts = 0
  skip_next = 0; not_git = 0; skip_global_val = 0; redir_skip_next = 0
}

function emit(t,    is_value_flag, is_global_val_flag, is_global_flag) {
  # A redirect target (file after >, or fd after >&) is neither the command word
  # nor a pathspec — skip it FIRST, before the not_git/git_seen logic, so a
  # leading redirect never marks the segment not_git.
  if (redir_skip_next) { redir_skip_next = 0; return }
  if (not_git) return
  if (skip_next) { skip_next = 0; return }
  if (skip_global_val) { skip_global_val = 0; return }
  if (!git_seen) {
    # Leading VAR=value env assignments precede the command — skip without marking
    # the segment not_git, so a following git still registers.
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    if (t != "git") { not_git = 1; return }
    git_seen = 1
    return
  }
  if (!subcmd_seen) {
    # Skip git global options before the subcommand.
    # Value-taking globals: -C <dir> and -c <name=value> consume the next token.
    is_global_val_flag = (t ~ /^(-C|-c)$/)
    if (is_global_val_flag) { skip_global_val = 1; return }
    # Single-token globals with = (--work-tree=X, --git-dir=X, --exec-path=X, --namespace=X)
    if (t ~ /^--(work-tree|git-dir|exec-path|namespace)=/) return
    # Flag-only globals (no value consumed)
    is_global_flag = (t ~ /^(-p|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs)$/)
    if (is_global_flag) return
    # Anything else is the subcommand
    if (t !~ /^(add|stage|commit)$/) { not_git = 1; return }
    subcmd_seen = 1
    return
  }
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
  while (substr(t, 1, 2) == "./") t = substr(t, 3)
  if (t == "nazgul" || index(t, "nazgul/") == 1) found = 1
}

{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      # Closing quote does NOT flush — adjacent quoted+unquoted fragments form one
      # shell word (e.g. -m "foo"nazgul/x is one message value, not a pathspec).
      if (c == "'\''") in_sq = 0
      else tok = tok c
    } else if (in_dq) {
      # Inside double quotes a backslash escapes the next char (\" \\ …), so it
      # must not toggle quote state — append the escaped char literally.
      if (c == "\\" && i < n) { i++; tok = tok substr($0, i, 1) }
      else if (c == "\"") in_dq = 0
      else tok = tok c
    } else if (c == "'\''") {
      in_sq = 1
    } else if (c == "\"") {
      in_dq = 1
    } else if (c == ">" || c == "<") {
      # Redirect operator. An all-digit token glued before it is an fd descriptor
      # (1>, 2<) — discard it; otherwise flush the preceding word normally. Consume
      # multi-char forms (>>, >|, >>|) and skip the following redirect target so a
      # leading redirect cannot hide the real git pathspec, and a target file is
      # never mistaken for a pathspec.
      if (tok ~ /^[0-9]+$/) tok = ""
      else if (tok != "") { emit(tok); tok = "" }
      if (c == ">") {
        rn1 = (i < n) ? substr($0, i+1, 1) : ""
        rn2 = (i+1 < n) ? substr($0, i+2, 1) : ""
        if (rn1 == ">") { i++; if (rn2 == "|") i++ }
        else if (rn1 == "|") i++
      }
      redir_skip_next = 1
    } else if (c == " " || c == "\t") {
      if (tok != "") { emit(tok); tok = "" }
    } else if (c == ";" || c == "|") {
      # Shell separator outside quotes — flush current token then reset segment state.
      # For "||", the second "|" also resets (empty tok, harmless).
      if (tok != "") { emit(tok); tok = "" }
      reset_segment()
    } else if (c == "&") {
      prevc = (i > 1) ? substr($0, i-1, 1) : ""
      nxtc  = (i < n) ? substr($0, i+1, 1) : ""
      if (prevc == ">" || nxtc ~ /^[0-9>]$/) {
        # part of a redirect (2>&1, >&2, &>) — NOT a command separator
        if (tok != "") { emit(tok); tok = "" }
      } else {
        # "&&" (logical) or background "&" — segment separator
        if (tok != "") { emit(tok); tok = "" }
        reset_segment()
      }
    } else {
      tok = tok c
    }
  }
  # End of record (line). A newline inside a quote continues the token; an unquoted
  # newline is a command separator, so flush and reset per-segment state.
  if (in_sq || in_dq) {
    # quoted string spans the newline — keep accumulating
  } else {
    if (tok != "") { emit(tok); tok = "" }
    reset_segment()
  }
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
