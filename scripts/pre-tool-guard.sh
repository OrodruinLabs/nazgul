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

# Case-insensitive, fork-free `[[ =~ ]]` match. `\s` is a GNU/BSD grep extension
# undefined in POSIX ERE (the regcomp(3) engine behind `=~` does not implement it,
# see scripts/local-mode-tracking-guard.sh:50-53 for the same lesson learned once
# already) — translate it to `[[:space:]]` for matching only; callers still print
# the original `\s`-bearing pattern text so blocked-command messages are unchanged.
# nocasematch is scoped to this one match, never left ambient.
_ci_match() {
  local str="$1" pattern="$2"
  local mpattern="${pattern//\\s/[[:space:]]}"
  local rc
  shopt -s nocasematch
  if [[ "$str" =~ $mpattern ]]; then rc=0; else rc=1; fi
  shopt -u nocasematch
  return $rc
}

# Destructive patterns to block. Scan the extracted command ($CMD), not the raw
# stdin — in production stdin is the JSON envelope, whose escaping/encoding could
# hide or distort a pattern match. Matched per LINE (a here-string read loop, zero
# forks) to preserve grep's line-oriented semantics: a `$`-anchored pattern must
# still fire on an interior line of a multi-line command, and a `.*`-bearing
# pattern must not span lines and over-match across them.
check_pattern() {
  local pattern="$1"
  local reason="$2"
  local line
  while IFS= read -r line; do
    if _ci_match "$line" "$pattern"; then
      echo "NAZGUL SAFETY: Blocked — $reason" >&2
      echo "Command contained: $pattern" >&2
      exit 2
    fi
  done <<< "$CMD"
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

# Database destruction (MF-029). Bare substring greps here previously fired on any
# quoted prose naming these keywords (a python3 heredoc, a jq argument, a commit
# message, a grep pattern — see LR-005). A first attempt anchored keyword+identifier
# shape to a DB-CLI token within the same ;/&&/||/| segment (mirroring
# check_force_push), but a quoted multi-statement arg (`psql -c "SELECT 1; DROP TABLE
# x;"`) and a heredoc body both split into separate segments on `;` and on embedded
# newlines, decoupling the token from the keyword and letting both bypass the guard.
# Require instead that the DB-CLI token and the anchored keyword+identifier shape each
# appear ANYWHERE in the whole command: narrower than the old bare grep (still
# requires a DB-CLI token present) and immune to segment-splitting bypasses. Tradeoff:
# a DB-CLI invocation elsewhere in a compound command can now co-occur with unrelated
# prose naming a keyword and block it — pinned as a deliberate over-block test below.
check_sql_destructive() {
  local dbcli='(^|[^A-Za-z0-9_-])(mysqldump|sqlite3|sqlcmd|mysql|psql|redis-cli)([^A-Za-z0-9_-]|$)'
  local ident="[][A-Za-z_\`'\"][][A-Za-z0-9_.\`'\"-]*"
  local drop_table="(^|[^A-Za-z0-9_])DROP\s+TABLE\s+$ident"
  local drop_database="(^|[^A-Za-z0-9_])DROP\s+DATABASE\s+$ident"
  local truncate="(^|[^A-Za-z0-9_])TRUNCATE\s+(TABLE\s+)?$ident"

  # Whole-command matching, deliberately NOT line-iterated (see comment above):
  # segment/line-splitting is exactly the bypass FEAT-019 closed.
  _ci_match "$CMD" "$dbcli" || return 0

  if _ci_match "$CMD" "$drop_table"; then
    echo "NAZGUL SAFETY: Blocked — SQL table drop" >&2
    echo "Command contained: $drop_table" >&2
    exit 2
  fi
  if _ci_match "$CMD" "$drop_database"; then
    echo "NAZGUL SAFETY: Blocked — SQL database drop" >&2
    echo "Command contained: $drop_database" >&2
    exit 2
  fi
  if _ci_match "$CMD" "$truncate"; then
    echo "NAZGUL SAFETY: Blocked — SQL table truncation" >&2
    echo "Command contained: $truncate" >&2
    exit 2
  fi
}
check_sql_destructive

# Git force push to protected branches (MF-028). The force flag and the branch
# name can appear in either order (`git push origin main --force` is as idiomatic
# as `git push --force origin main`), so this ANDs two independent presence checks
# within one `git push` segment instead of matching one fixed ordering.
check_force_push() {
  local segment
  while IFS= read -r segment; do
    if _ci_match "$segment" 'git\s+push' \
      && _ci_match "$segment" '(^|\s)(--force|-f)(\s|$)' \
      && _ci_match "$segment" '(^|\s)(main|master)(\s|$)'; then
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

# Task manifest status protection lives entirely in the structural funnel below
# (the old text-substring sed/cat/tee rules both over- and under-matched).

# Task manifest write funnel (ADR-020): scripts/task-transition.sh is the single
# sanctioned status writer; RULES.md §5 states the rules and their known limits.
_check_manifest_write_funnel() {
  printf '%s' "$CMD" | awk '
BEGIN {
  in_sq = 0; in_dq = 0; tok = ""; found_cmd = 0
  redirect_pending = 0; found = 0; fd_target_pending = 0
  cmd_word = ""; seg_writes_manifest = 0; last_arg = ""
  has_inplace = 0; has_dash_c = 0; seg_heredoc = 0
  manifest_arg = 0; manifest_embedded = 0
  wrapper_pending = 0; line_cont = 0
  dq_subst = 0; paren_depth = 0; dq_btick = 0
  in_heredoc = 0; heredoc_delim = ""; heredoc_delim_pending = 0
  heredoc_owner_interp = 0
}

# Quotes are stripped during accumulation, so the reconstructed shell word is
# matched whole — bare, ./-prefixed and absolute spellings all resolve here.
function is_manifest_path(t) {
  return (t ~ /(^|\/)nazgul\/tasks\/TASK-[0-9*?]+\.md$/)
}

# The same path INSIDE a larger word (interpreter script text, an option value),
# which is the shape every one-liner writer takes.
function has_manifest_path(t) {
  return (t ~ /(^|[^A-Za-z0-9_.-])nazgul\/tasks\/TASK-[0-9*?]+\.md/)
}

function base_cmd(t) {
  sub(/^.*\//, "", t)
  return t
}

function writes_by_last_arg(c) {
  return (c == "mv" || c == "cp" || c == "install" || c == "ln")
}

function edits_in_place(c) {
  return (c == "sed" || c == "gsed" || c == "perl" || c == "ruby" || c == "awk" || c == "gawk")
}

function interpreter(c) {
  return (c == "sed" || c == "gsed" || c == "awk" || c == "gawk" || c == "mawk" || c == "nawk" ||
          c == "perl" || c == "python" || c == "python2" || c == "python3" || c == "ruby" ||
          c == "node" || c == "php" || c == "ed" || c == "ex")
}

function shell_dash_c(c) {
  return (c == "bash" || c == "sh" || c == "zsh" || c == "ksh" || c == "dash")
}

# Commands that run another command: the writer is the word AFTER them, so the
# real command word is only found by looking through the wrapper.
function wrapper_cmd(c) {
  return (c == "env" || c == "command" || c == "nohup" || c == "nice" ||
          c == "ionice" || c == "setsid" || c == "stdbuf" || c == "time" ||
          c == "timeout" || c == "sudo" || c == "doas" || c == "xargs" ||
          c == "exec" || c == "builtin")
}

# Flush the accumulated word. A word may be built from adjacent quoted and
# unquoted fragments (e.g. "nazgul/tasks/"TASK-001.md) — quote chars are stripped
# during accumulation, so the reconstructed shell word is validated as a whole.
# Redirect targets are resolved BEFORE the command-word check so a leading
# redirect (> file echo ok) attributes its target correctly.
function flush_tok(    t, d) {
  t = tok; tok = ""
  if (t == "") return
  if (heredoc_delim_pending) { heredoc_delim = t; heredoc_delim_pending = 0; return }
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
  if (!found_cmd) {
    # Leading VAR=value env assignments precede the command word in bash — skip
    # them so the real command word is still recognised.
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    # A wrapper (env, xargs, timeout …) delegates: skip its own options and
    # operands so the wrapped command is classified instead of the wrapper.
    if (wrapper_pending && (t ~ /^-/ || t ~ /^[0-9]+(\.[0-9]+)?[smhd]?$/)) return
    if (wrapper_cmd(base_cmd(t))) { wrapper_pending = 1; return }
    wrapper_pending = 0
    found_cmd = 1
    cmd_word = base_cmd(t)
    return
  }
  if (t ~ /^-/) {
    if (t == "-c") has_dash_c = 1
    if (t ~ /^--in-place/ || t ~ /^-[A-Za-z0-9]*i(\.[A-Za-z0-9]*)?$/) has_inplace = 1
  } else {
    last_arg = t
  }
  # `<<WORD` / `<<-WORD` opens a heredoc whose body is read from later lines;
  # `<<<` is a here-string and carries its data inline, so it opens nothing.
  if (t ~ /^<</ && t !~ /^<<</) {
    seg_heredoc = 1
    d = t; sub(/^<<-?/, "", d)
    if (d != "") heredoc_delim = d
    else heredoc_delim_pending = 1
  }
  if (is_manifest_path(t)) manifest_arg = 1
  else if (has_manifest_path(t)) manifest_embedded = 1
}

function end_segment() {
  flush_tok()
  # Any real redirect into a manifest, whatever the command (or none at all).
  if (seg_writes_manifest) found = 1
  if (writes_by_last_arg(cmd_word) && is_manifest_path(last_arg)) found = 1
  if (cmd_word == "tee" && (manifest_arg || manifest_embedded)) found = 1
  if (edits_in_place(cmd_word) && has_inplace && (manifest_arg || manifest_embedded)) found = 1
  # An interpreter carrying the path inside its program text is a writer shape;
  # read-only inspection passes the path as its own bare argument instead.
  if (interpreter(cmd_word) && manifest_embedded) found = 1
  if (shell_dash_c(cmd_word) && has_dash_c && (manifest_arg || manifest_embedded)) found = 1
  # `eval` runs its argument as shell text, not as an operand of a writer.
  if (cmd_word == "eval" && (manifest_arg || manifest_embedded)) found = 1
  # A heredoc-fed interpreter: evidence is scoped to THIS command — the path on
  # its own line, or (below) in the body its own delimiter closes.
  if (interpreter(cmd_word) && seg_heredoc) {
    heredoc_owner_interp = 1
    if (manifest_arg || manifest_embedded) found = 1
  }
}

function reset_segment() {
  end_segment()
  found_cmd = 0; redirect_pending = 0; fd_target_pending = 0
  cmd_word = ""; seg_writes_manifest = 0; last_arg = ""
  has_inplace = 0; has_dash_c = 0; seg_heredoc = 0
  manifest_arg = 0; manifest_embedded = 0; wrapper_pending = 0
}

# A heredoc body is data, not shell code: lex nothing until its own delimiter
# closes it, and charge a manifest path there to the interpreter that opened it.
in_heredoc {
  hd = $0; sub(/^[ \t]+/, "", hd); sub(/[ \t]+$/, "", hd)
  if (hd == heredoc_delim) { in_heredoc = 0; heredoc_delim = ""; heredoc_owner_interp = 0; next }
  if (heredoc_owner_interp && has_manifest_path($0)) found = 1
  next
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
      # Command substitution stays live inside double quotes, so "$(sed -i … )"
      # must be lexed as its own command rather than swallowed into one word.
      if (c == "\\" && i < n) { i++; tok = tok substr($0, i, 1) }
      else if (c == "$" && i < n && substr($0, i+1, 1) == "(") {
        i++; reset_segment(); dq_subst = 1; paren_depth = 0; in_dq = 0
      }
      else if (c == "`") { reset_segment(); dq_btick = 1; in_dq = 0 }
      else if (c == "\"") in_dq = 0
      else tok = tok c
    } else if (c == "'\''") {
      in_sq = 1
    } else if (c == "\"") {
      in_dq = 1
    } else if (c == "\\") {
      # A trailing unquoted backslash is a line continuation: the command has not
      # ended, so its operands on the next line still belong to this segment.
      if (i == n) line_cont = 1
      else { i++; tok = tok substr($0, i, 1) }
    } else if (c == "(") {
      reset_segment()
      if (dq_subst) paren_depth++
    } else if (c == ")") {
      reset_segment()
      if (dq_subst) {
        paren_depth--
        if (paren_depth < 0) { dq_subst = 0; paren_depth = 0; in_dq = 1 }
      }
    } else if (c == "`") {
      reset_segment()
      if (dq_btick) { dq_btick = 0; in_dq = 1 }
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
  } else if (line_cont) {
    line_cont = 0
    flush_tok()
  } else {
    flush_tok()
    if (seg_heredoc && heredoc_delim != "") in_heredoc = 1
    reset_segment()
  }
}

END {
  exit (found ? 2 : 0)
}
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
