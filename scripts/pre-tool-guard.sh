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

# Destructive patterns to block
check_pattern() {
  local pattern="$1"
  local reason="$2"
  if echo "$INPUT" | grep -qiE "$pattern"; then
    echo "NAZGUL SAFETY: Blocked — $reason" >&2
    echo "Command contained: $pattern" >&2
    exit 2
  fi
}

# Filesystem destruction
check_pattern 'rm\s+-rf\s+/' "Recursive delete of root filesystem"
check_pattern 'rm\s+-rf\s+~' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\$HOME' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\.\s*$' "Recursive delete of current directory"

# Database destruction
check_pattern 'DROP\s+TABLE' "SQL table drop"
check_pattern 'DROP\s+DATABASE' "SQL database drop"
check_pattern 'TRUNCATE' "SQL table truncation"

# Git force push to protected branches
check_pattern 'git\s+push\s+.*--force.*\s+(main|master)' "Force push to main/master branch"
check_pattern 'git\s+push\s+-f\s+.*\s+(main|master)' "Force push to main/master branch"

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

# Task manifest write protection for echo/printf: detect a REAL redirect operator
# (>, >>, >|, >>| outside quotes) whose target resolves to a nazgul/tasks/TASK-*.md
# path. The awk tokenizer tracks single/double-quote state so a > inside quotes is
# data, not a redirect. Compound commands (;, &&, ||, |, newline outside quotes) reset
# per-segment state so each segment is checked independently — a non-echo/printf segment
# is skipped without false-positives. Scoped to echo/printf; sed/cat/tee rules above
# handle those commands separately.
#
# Defense-in-depth note: primary protection is the Write/Edit tool hooks and
# task-state guard. This is a best-effort secondary layer. Deeply exotic shell forms
# (process substitution, eval'd strings, fd-numbered redirects like 1>, nested
# subshells) are out of scope by design and degrade to allow.
_check_echo_redirect() {
  printf '%s' "$INPUT" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""; found_cmd = 0
  redirect_pending = 0; found = 0
}

function is_manifest_path(t) {
  if (substr(t,1,1) == "\"" && substr(t,length(t),1) == "\"")
    t = substr(t, 2, length(t)-2)
  else if (substr(t,1,1) == "'\''" && substr(t,length(t),1) == "'\''")
    t = substr(t, 2, length(t)-2)
  while (substr(t,1,2) == "./") t = substr(t, 3)
  return (t ~ /^nazgul\/tasks\/TASK-[^[:space:]]*\.md$/)
}

function flush_tok(    t) {
  t = tok; tok = ""
  if (t == "") return
  if (!found_cmd) {
    if (t == "echo" || t == "printf") found_cmd = 1
    return
  }
  if (redirect_pending) {
    if (is_manifest_path(t)) found = 1
    redirect_pending = 0
    return
  }
}

function reset_segment() {
  flush_tok()
  found_cmd = 0
  redirect_pending = 0
}

{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      if (c == "'\''") { in_sq = 0; flush_tok() }
      else tok = tok c
    } else if (in_dq) {
      if (c == "\"") { in_dq = 0; flush_tok() }
      else tok = tok c
    } else if (c == "'\''") {
      flush_tok()
      in_sq = 1
    } else if (c == "\"") {
      flush_tok()
      in_dq = 1
    } else if (c == ">" && found_cmd) {
      flush_tok()
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
    } else if ((c == ";" || c == "\n") && !in_sq && !in_dq) {
      reset_segment()
    } else if (c == "&" && !in_sq && !in_dq) {
      reset_segment()
    } else if (c == "|" && !in_sq && !in_dq) {
      reset_segment()
    } else if (c == " " || c == "\t") {
      flush_tok()
    } else {
      tok = tok c
    }
  }
  flush_tok()
}

END { exit (found ? 2 : 0) }
'
}

if ! _check_echo_redirect; then
  echo "NAZGUL SAFETY: Blocked — Direct echo/printf redirect to task manifest (use Write/Edit tools)" >&2
  echo "Command: $INPUT" >&2
  exit 2
fi

# All checks passed
exit 0
