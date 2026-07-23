#!/usr/bin/env bash
set -euo pipefail

# Nazgul Pre-Tool Guard — blocks destructive bash commands
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)

# The command being executed is passed via stdin or $ARGUMENTS
INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  INPUT=$(cat 2>/dev/null || echo "")
fi

# If no input, allow
if [ -z "$INPUT" ]; then
  exit 0
fi

# Extract the command from the PreToolUse JSON envelope. In production the hook
# receives {"tool_input":{"command":"..."}} on stdin; the test harness passes the
# raw command. Fall back to INPUT when it is not JSON so both paths work. The awk
# tokenizer below MUST tokenize the real command — feeding it the JSON wrapper
# would make the whole command one quoted string and the echo/printf check a no-op.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [ -z "$CMD" ]; then
  CMD="$INPUT"
fi

# Destructive patterns to block. Scan the extracted command ($CMD), not the raw
# stdin — in production stdin is the JSON envelope, whose escaping/encoding could
# hide or distort a pattern match.
check_pattern() {
  local pattern="$1"
  local reason="$2"
  if echo "$CMD" | grep -qiE "$pattern"; then
    echo "NAZGUL SAFETY: Blocked — $reason" >&2
    echo "Command contained: $pattern" >&2
    exit 2
  fi
}

# Filesystem destruction. Anchored on a boundary (whitespace/end/;/&/|) after the
# target so `rm -rf /tmp/x` and other legitimate absolute-path deletions are
# allowed (MF-027) while the bare root, ~, and $HOME forms stay blocked.
# `/?` (`/+` for root) covers the equivalent trailing-slash spellings
# (`rm -rf ~/`, `rm -rf /root/`, `rm -rf //`) without touching real subpaths
# like `~/tmp` or `/root/subdir`.
check_pattern 'rm\s+-rf\s+/+(\s|$|;|&|\|)' "Recursive delete of root filesystem"
check_pattern 'rm\s+-rf\s+/root/?(\s|$|;|&|\|)' "Recursive delete of root user home directory"
check_pattern 'rm\s+-rf\s+~/?(\s|$|;|&|\|)' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\$HOME/?(\s|$|;|&|\|)' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\.\s*$' "Recursive delete of current directory"

# Database destruction
check_pattern 'DROP\s+TABLE' "SQL table drop"
check_pattern 'DROP\s+DATABASE' "SQL database drop"
check_pattern 'TRUNCATE' "SQL table truncation"

# Git force push to protected branches (MF-028). The force flag and the branch
# name can appear in either order (`git push origin main --force` is as idiomatic
# as `git push --force origin main`), so this ANDs two independent presence checks
# within one `git push` segment instead of matching one fixed ordering.
check_force_push() {
  local segment
  while IFS= read -r segment; do
    if echo "$segment" | grep -qiE 'git\s+push' \
      && echo "$segment" | grep -qiE '(^|\s)(--force|-f)(\s|$)' \
      && echo "$segment" | grep -qiE '(^|\s)(main|master)(\s|$)'; then
      echo "NAZGUL SAFETY: Blocked — Force push to main/master branch" >&2
      echo "Command contained: git push with --force/-f targeting main/master" >&2
      exit 2
    fi
  done < <(printf '%s\n' "$CMD" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')
}
check_force_push

# Fork bombs and system destruction
check_pattern ':\(\)\{' "Fork bomb"
check_pattern 'chmod\s+-R\s+777' "Recursive permission change to 777"
check_pattern 'mkfs\.' "Filesystem format"
check_pattern 'dd\s+if=.*of=/dev/' "Direct disk write"

# Piped execution from internet
check_pattern 'curl\s+.*\|\s*(ba)?sh' "Piped internet execution (curl | sh)"
check_pattern 'wget\s+.*\|\s*(ba)?sh' "Piped internet execution (wget | sh)"
check_pattern 'curl\s+.*\|\s*sudo' "Piped internet execution with sudo"

# Task manifest status protection — prevent bypassing Write/Edit hooks
check_pattern 'sed.*nazgul/tasks/TASK-.*Status' "Direct sed on task manifest status (use Write/Edit tools)"
check_pattern 'cat.*>.*nazgul/tasks/TASK-' "Direct cat redirect to task manifest (use Write/Edit tools)"
check_pattern 'tee.*nazgul/tasks/TASK-' "Direct tee to task manifest (use Write/Edit tools)"

# Task manifest write protection: a segment is blocked when it EITHER (a) invokes
# echo/printf AND has a REAL redirect operator (>, >>, >|, >>| outside quotes) whose
# target resolves to a nazgul/tasks/TASK-*.md path — in either order, so a leading
# redirect (`> nazgul/tasks/TASK-001.md echo ok`) is caught too — OR (b) invokes
# mv/cp with a manifest path as its final non-flag argument (MF-022 funnel; the
# common `mv/cp SRC nazgul/tasks/TASK-NNN.md` forgery shape). The awk tokenizer
# tracks single/double-quote state (a > inside quotes is data, not a redirect) and
# reconstructs the full shell word from adjacent quoted+unquoted fragments, so a
# split target like `> "nazgul/tasks/"TASK-001.md` rejoins to one path before
# validation. Compound commands (;, &&, ||, |, newline outside quotes) reset
# per-segment state so each segment is checked independently. Scoped to
# echo/printf/mv/cp; sed/cat/tee rules above handle those separately.
#
# Defense-in-depth note: primary protection is the Write/Edit tool hooks and
# task-state guard. This is a best-effort secondary layer — the structural fix for
# MF-022 is the stop-hook-time recompute-and-compare reconciliation (ADR-003
# Decision 2), not this funnel. fd-numbered and combined redirects (1>, 2>, &>,
# 2>&1) ARE handled. Deeply exotic shell forms (process substitution, eval'd
# strings, nested subshells, command substitution) are out of scope by design and
# degrade to allow.
_check_manifest_write_funnel() {
  printf '%s' "$CMD" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""; found_cmd = 0
  redirect_pending = 0; found = 0; fd_target_pending = 0
  seg_has_cmd = 0; seg_writes_manifest = 0
  seg_is_mv_cp = 0; mv_cp_target = ""
}

function is_manifest_path(t) {
  # tok already has quotes stripped during accumulation — check the whole word.
  while (substr(t,1,2) == "./") t = substr(t, 3)
  return (t ~ /^nazgul\/tasks\/TASK-[^[:space:]]*\.md$/)
}

# Flush the accumulated word. A word may be built from adjacent quoted and
# unquoted fragments (e.g. "nazgul/tasks/"TASK-001.md) — quote chars are stripped
# during accumulation, so the reconstructed shell word is validated as a whole.
# Redirect targets are resolved BEFORE the command-word check so a leading
# redirect (> file echo ok) attributes its target correctly.
function flush_tok(    t) {
  t = tok; tok = ""
  if (t == "") return
  if (fd_target_pending) {
    # fd-duplication target (the 1 in 2>&1, the - in >&-) — never a command word
    fd_target_pending = 0
    return
  }
  if (redirect_pending) {
    if (is_manifest_path(t)) seg_writes_manifest = 1
    redirect_pending = 0
    return
  }
  # mv/cp arguments: track the last non-flag word as the candidate destination
  # (the common `mv/cp SRC DEST` shape — DEST is whatever word came last).
  if (seg_is_mv_cp && t !~ /^-/) mv_cp_target = t
  if (!found_cmd) {
    # Leading VAR=value env assignments precede the command word in bash — skip
    # them so a later echo/printf/mv/cp is still recognised as the command.
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    found_cmd = 1
    if (t == "echo" || t == "printf") seg_has_cmd = 1
    if (t == "mv" || t == "cp") seg_is_mv_cp = 1
  }
}

# A segment blocks when it either (a) invokes echo/printf AND redirects into a
# manifest, in either order (handles leading redirects), or (b) invokes mv/cp with
# a manifest path as the final argument.
function end_segment() {
  flush_tok()
  if (seg_has_cmd && seg_writes_manifest) found = 1
  if (seg_is_mv_cp && is_manifest_path(mv_cp_target)) found = 1
}

function reset_segment() {
  end_segment()
  found_cmd = 0; redirect_pending = 0; fd_target_pending = 0
  seg_has_cmd = 0; seg_writes_manifest = 0
  seg_is_mv_cp = 0; mv_cp_target = ""
}

{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      # Stay in the same token across the closing quote so adjacent fragments join.
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
    } else if (c == ">") {
      # An all-digit token glued before > is an fd descriptor (1>, 2>), not a
      # command word — discard it so the real command later still registers.
      if (tok ~ /^[0-9]+$/) tok = ""
      else flush_tok()
      nxt1 = (i < n) ? substr($0, i+1, 1) : ""
      nxt2 = (i+1 < n) ? substr($0, i+2, 1) : ""
      if (nxt1 == ">") {
        i++
        if (nxt2 == "|") i++
      } else if (nxt1 == "|") {
        # >| noclobber-override redirect
        i++
      }
      redirect_pending = 1
    } else if (c == ";") {
      reset_segment()
    } else if (c == "&") {
      nxtc = (i < n) ? substr($0, i+1, 1) : ""
      prevc = (i > 1) ? substr($0, i-1, 1) : ""
      if (nxtc == ">") {
        # &> / &>> redirect (stdout+stderr) — treat as a redirect operator
        flush_tok()
        i++                                            # consume the >
        if (i < n && substr($0, i+1, 1) == ">") i++    # &>>
        redirect_pending = 1
      } else if (prevc == ">" || nxtc ~ /^[0-9]$/) {
        # fd duplication (2>&1, >&2) — not a separator, not a file target. The
        # following fd number/- is a dup target, not the command word.
        flush_tok()
        redirect_pending = 0
        fd_target_pending = 1
      } else {
        # && (logical) or background & — segment separator
        reset_segment()
      }
    } else if (c == "|") {
      reset_segment()
    } else if (c == " " || c == "\t") {
      flush_tok()
    } else {
      tok = tok c
    }
  }
  # End of record (line). A newline inside a quote continues the token; an
  # unquoted newline is a command separator, so reset per-segment state to avoid
  # carrying found_cmd/seg_* across multi-line commands (else a later echo/printf
  # segment could be mis-attributed and a manifest write slip through).
  if (in_sq || in_dq) {
    # quoted string spans the newline — keep accumulating
  } else {
    reset_segment()
  }
}

END { exit (found ? 2 : 0) }
'
}

# Block ONLY on the specific "found a manifest write" signal (awk exit 2). Any
# other non-zero (e.g. an awk runtime error) degrades to allow, per the
# defense-in-depth contract — the guard never blocks on its own malfunction.
manifest_funnel_ec=0
_check_manifest_write_funnel || manifest_funnel_ec=$?
if [ "$manifest_funnel_ec" -eq 2 ]; then
  echo "NAZGUL SAFETY: Blocked — Direct write to task manifest via Bash (use Write/Edit tools)" >&2
  echo "Command: $CMD" >&2
  exit 2
fi

# All checks passed
exit 0
