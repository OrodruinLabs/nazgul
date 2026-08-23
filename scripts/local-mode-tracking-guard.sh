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
# Deeply exotic shell forms (process substitution, eval'd strings, $'...' ANSI-C
# quoting) are out of scope by design and degrade to allow — acceptable for normal
# Nazgul loop usage.
#
# Command substitution nested inside a double-quoted span (`"$(...)"`) is a
# narrow, deliberately small exception to that degrade-to-allow posture (TASK-004
# attempt 5, replacing four attempts' worth of general-purpose tracking that
# repeatedly reopened new false-ALLOW bypasses). A heredoc is recognized inside
# `"$(...)"` ONLY when the token immediately after `$(` is a known
# heredoc-consuming command (`cat`, `tee`) followed by `<<`/`<<-` — a short
# enumerated list, not a pattern guess. Once recognized, the heredoc body is
# skipped as inert text exactly like a top-level heredoc, regardless of where the
# enclosing `$(...)` lexically closes on the opener line (a real heredoc's body
# always comes from the next physical line, no matter what follows the redirect
# on the same line).
#
# Any `$(...)` nested in `"..."` that does NOT match that narrow shape is treated
# as opaque content: its characters carry no quote or heredoc meaning at all,
# tracked only by a plain paren-depth count so the tokenizer knows where the
# nested substitution ends and outer double-quote tracking resumes. This is
# deliberately less precise than tracking real nested quoting (a literal `)`
# inside opaque content can miscount as the substitution's close) — accepted
# because a false BLOCK on such content is the safe direction for this
# defence-in-depth guard, and because avoiding that imprecision would require
# reintroducing the general-purpose nested-quote/arithmetic state machine this
# attempt replaces.
#
# The same cat/tee gate applies at the true top level too (TASK-004 attempt
# 6): a top-level `<<` only arms a heredoc when the word immediately before it
# is `cat`/`tee`, so `echo $((1<<2))` is a shift operator, not a heredoc open.

# Read tool input from stdin (Claude Code passes JSON for PreToolUse hooks)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RHP_LIB="$SCRIPT_DIR/lib/read-hook-payload.sh"
# lean-comments: allow-run — the fallback exists for a failure this file cannot observe.
# This guard's scope question, answered WITHOUT depending on a second library loading.
# nazgul-root.sh stays primary (ADR-008), but the reader-unavailable path below exists
# precisely BECAUSE scripts/lib/ may be unusable, and an unconditional `source` there was
# defeated by its own cause: the missing file aborted under `set -e` with exit 1, which a
# PreToolUse hook reads as ALLOW. The fallback reproduces the resolver's own order for this
# one question, so the two agree wherever the resolver can answer at all.
_lmtg_config_path() {
  local root=""
  if [ -r "$SCRIPT_DIR/lib/nazgul-root.sh" ] \
     && source "$SCRIPT_DIR/lib/nazgul-root.sh" 2>/dev/null \
     && declare -F resolve_project_root >/dev/null; then
    root="$(resolve_project_root 2>/dev/null || true)"
  fi
  if [ -z "$root" ]; then
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
      root="$CLAUDE_PROJECT_DIR"
    else
      root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$root" ] && [ -r "$root/nazgul/config.json" ] || root="$(pwd)"
    fi
  fi
  printf '%s\n' "$root/nazgul/config.json"
}

# A load that returns 0 having defined nothing is still no payload, and it is
# scoped like the timeout branch below rather than denying every repo.
rhp_unavailable() {
  local cfg
  cfg="$(_lmtg_config_path)"
  if [ -f "$cfg" ] \
    && [ "$(jq -r '.install_mode // ""' "$cfg" 2>/dev/null || echo "")" = "local" ]; then
    printf 'local-mode-tracking-guard: stdin reader unavailable: %s — fail-closed, blocking the command\n' "$1" >&2
    exit 2
  fi
  printf 'local-mode-tracking-guard: stdin reader unavailable: %s — fail-open, guard is out of scope here\n' "$1" >&2
  exit 0
}
[ -r "$RHP_LIB" ] || rhp_unavailable "$RHP_LIB is missing or unreadable"
rhp_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_rc=$?
declare -F read_hook_payload >/dev/null && declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "$RHP_LIB defines no reader API after sourcing (source returned $rhp_rc)"
read_hook_payload
if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
  # With no command text every pre-filter below would allow, so the deny is
  # decided here — and only for the local-mode project this guard is scoped to.
  TIMEOUT_CONFIG="$(_lmtg_config_path)"
  if [ -f "$TIMEOUT_CONFIG" ] \
    && [ "$(jq -r '.install_mode // ""' "$TIMEOUT_CONFIG" 2>/dev/null || echo "")" = "local" ]; then
    hook_payload_timeout_report "local-mode-tracking-guard" "fail-closed" "blocking the command"
    exit 2
  fi
  hook_payload_timeout_report "local-mode-tracking-guard" "fail-open" "guard is out of scope here"
  exit 0
fi
INPUT="$HOOK_PAYLOAD"

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
  in_heredoc = 0; heredoc_delim = ""; heredoc_strip = 0
  cs_depth = 0; heredoc_armed = 0
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

function flush_pre_redirect() {
  if (tok ~ /^[0-9]+$/) tok = ""
  else if (tok != "") { emit(tok); tok = "" }
}

# The only two heredoc-consuming commands this guard recognizes inside a
# $(...) nested in "..." (the TASK-004 attempt 5 narrow rule). Not a pattern
# guess — an explicit, short, enumerated list.
function is_heredoc_command(w) {
  return (w == "cat" || w == "tee")
}

# True iff, starting at `pos` in `line` (the character right after a just-seen
# "$("), the next word is a known heredoc-consuming command and the next
# non-whitespace thing after that word is "<<"/"<<-". This is a forward
# lookahead only — it never tries to locate where the substitution itself
# closes, so it needs no depth or quote state of its own.
function nested_heredoc_ok(line, pos,    j, n2, word, ch2) {
  n2 = length(line)
  j = pos
  while (j <= n2 && (substr(line, j, 1) == " " || substr(line, j, 1) == "\t")) j++
  word = ""
  while (j <= n2) {
    ch2 = substr(line, j, 1)
    if (ch2 !~ /[A-Za-z]/) break
    word = word ch2
    j++
  }
  if (!is_heredoc_command(word)) return 0
  while (j <= n2 && (substr(line, j, 1) == " " || substr(line, j, 1) == "\t")) j++
  return (substr(line, j, 2) == "<<")
}

# True iff, scanning backward in `line` from just before position `pos` (the
# start of a candidate "<<"/"<<-"), the immediately preceding word is a known
# heredoc-consuming command. This is the top-level mirror of
# the nested_heredoc_ok forward lookahead — same is_heredoc_command() predicate,
# same enumerated list, applied at the true top level (TASK-004 attempt 6:
# a bare "$((1<<2))" was previously arming a bogus heredoc there because only
# the $(...)-nested case was gated).
#
# Two grammar checks past the letter-run itself (TASK-004 attempt 7): a digit
# or "_" right at the boundary means the run was only a suffix of a longer
# identifier ("_cat", "2tee"), not the whole word — refuse. And a boundary of
# "((" (skipping back over any whitespace first, so "$(( cat << " still
# counts) means the word is a bareword arithmetic operand inside $((...)),
# where "<<" is unconditionally the shift operator — refuse. A single "("
# (real command substitution/subshell open) is left alone.
function heredoc_command_before(line, pos,    j, word, ch3) {
  j = pos - 1
  while (j >= 1 && (substr(line, j, 1) == " " || substr(line, j, 1) == "\t")) j--
  word = ""
  while (j >= 1) {
    ch3 = substr(line, j, 1)
    if (ch3 !~ /[A-Za-z]/) break
    word = ch3 word
    j--
  }
  if (!is_heredoc_command(word)) return 0
  if (j >= 1 && substr(line, j, 1) ~ /[0-9_]/) return 0
  while (j >= 1 && (substr(line, j, 1) == " " || substr(line, j, 1) == "\t")) j--
  if (j > 1 && substr(line, j, 1) == "(" && substr(line, j - 1, 1) == "(") return 0
  return 1
}

# Heredoc start (<< or <<-), recognized at the true top level ONLY when
# heredoc_command_before() holds, and — only when heredoc_armed (see the
# in_dq loop below) — inside a $(...) nested in a double-quoted span. NOT
# recognized inside a real single-quoted span: nothing is special inside
# '"'"'...'"'"' in real shell.
# Returns the index of the last consumed char, or 0 if `line` at `i` is not a
# genuine "<<"/"<<-" start (also rejects mid-run matches inside "<<<").
#
# The delimiter word is quote-COMPOSABLE, mirroring the main tokenizer
# adjacent-quoted+unquoted-fragments-form-one-word rule (in_sq/in_dq above):
# real bash applies quote removal across the WHOLE delimiter word, even when
# only part of it is quoted (an unquoted prefix or suffix glued to a quoted
# span). Treating any quote character as an unquoted-delimiter BREAK char
# (rather than composing it) truncates a mixed-quote delimiter early, so the
# real terminator line never matches and in_heredoc never resets, silently
# swallowing every line after it (found via adversarial security re-probe).
function try_heredoc(line, i,    j, n2, delim, ch, lsq, ldq) {
  if (i > 1 && substr(line, i - 1, 1) == "<") return 0
  if (substr(line, i, 2) != "<<") return 0
  j = i + 2
  heredoc_strip = 0
  if (substr(line, j, 1) == "-") { heredoc_strip = 1; j++ }
  n2 = length(line)
  while (j <= n2 && (substr(line, j, 1) == " " || substr(line, j, 1) == "\t")) j++
  delim = ""; lsq = 0; ldq = 0
  while (j <= n2) {
    ch = substr(line, j, 1)
    if (lsq) {
      if (ch == "'\''") lsq = 0
      else delim = delim ch
    } else if (ldq) {
      if (ch == "\"") ldq = 0
      else delim = delim ch
    } else if (ch == "'\''") {
      lsq = 1
    } else if (ch == "\"") {
      ldq = 1
    } else if (ch ~ /[ \t;|&<>()]/) {
      break
    } else {
      delim = delim ch
    }
    j++
  }
  if (lsq || ldq) return 0
  if (delim == "") return 0
  heredoc_delim = delim
  in_heredoc = 1
  return j - 1
}

{
  if (in_heredoc) {
    cmp = $0
    if (heredoc_strip) gsub(/^\t+/, "", cmp)
    if (cmp == heredoc_delim) { in_heredoc = 0 }
    next
  }
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
      # cs_depth counts plain paren nesting once past an unrecognized "$("
      # (see below) — just enough to know where that substitution ends,
      # never enough to interpret what is inside it (TASK-004 attempt 5).
      if (c == "\\" && i < n) { i++; tok = tok substr($0, i, 1) }
      else if (c == "<" && heredoc_armed) {
        hd_end = try_heredoc($0, i)
        heredoc_armed = 0
        if (hd_end > 0) { i = hd_end }
        else tok = tok c
      }
      else if (cs_depth > 0 && c == "(") { cs_depth++; tok = tok c }
      else if (cs_depth > 0 && c == ")") { cs_depth--; tok = tok c }
      else if (cs_depth > 0) {
        # Opaque content of an unrecognized $(...): no character here — quote,
        # heredoc, or otherwise — carries any special meaning.
        tok = tok c
      }
      else if (c == "\"") { in_dq = 0 }
      else if (c == "$" && i < n && substr($0, i + 1, 1) == "(") {
        # A $(...) nested in "..." resets quoting in real bash. Only the
        # narrow cat/tee-heredoc idiom is interpreted further (heredoc_armed);
        # everything else becomes opaque paren-counted content (AC1: TASK-004).
        heredoc_armed = nested_heredoc_ok($0, i + 2)
        cs_depth++
        tok = tok c substr($0, i + 1, 1); i++
      }
      else tok = tok c
    } else if (c == "\\") {
      # A backslash outside any quote escapes the next char, so it must not be
      # separately interpreted as heredoc/redirect syntax (e.g. \<<EOF is a
      # literal "<" followed by a plain "< EOF" redirect, never a heredoc).
      if (i < n) { i++; tok = tok substr($0, i, 1) }
      else tok = tok c
    } else if (c == "'\''") {
      in_sq = 1
    } else if (c == "\"") {
      in_dq = 1
    } else if (c == "<") {
      # Redirect or heredoc. try_heredoc() wins when "<<" starts here AND the
      # preceding word is a known heredoc-consuming command
      # (heredoc_command_before) — the same narrow gate as the $(...)-nested
      # case, applied uniformly (TASK-004 attempt 6). Otherwise this is a
      # plain input redirect (or an arithmetic/other "<<" that never arms a
      # heredoc) and the target token is skipped like ">".
      hd_end = heredoc_command_before($0, i) ? try_heredoc($0, i) : 0
      if (hd_end > 0) {
        flush_pre_redirect()
        i = hd_end
      } else {
        flush_pre_redirect()
        redir_skip_next = 1
      }
    } else if (c == ">") {
      # Redirect operator. An all-digit token glued before it is an fd descriptor
      # (1>, 2<) — discard it; otherwise flush the preceding word normally. Consume
      # multi-char forms (>>, >|, >>|) and skip the following redirect target so a
      # leading redirect cannot hide the real git pathspec, and a target file is
      # never mistaken for a pathspec.
      flush_pre_redirect()
      rn1 = (i < n) ? substr($0, i+1, 1) : ""
      rn2 = (i+1 < n) ? substr($0, i+2, 1) : ""
      if (rn1 == ">") { i++; if (rn2 == "|") i++ }
      else if (rn1 == "|") i++
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

# Resolution deferred to here (past the pre-filters and the tokenizer) so the
# overwhelming majority of Bash calls — which never carry a nazgul/ pathspec —
# never pay for it.
source "$SCRIPT_DIR/lib/nazgul-root.sh"

PROJECT_ROOT="$(resolve_project_root)"
CONFIG="$PROJECT_ROOT/nazgul/config.json"

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
