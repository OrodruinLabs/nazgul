#!/usr/bin/env bash
# scripts/lib/destructive-patterns.sh — THE destructive-command denylist.
#
# One authority, three call sites. scripts/pre-tool-guard.sh screens Bash tool
# calls (PreToolUse), scripts/task-state-guard.sh screens writes that put a
# command into nazgul/config.json, and scripts/red-run.sh screens the command it
# is about to execute itself. A denylisted command relocated into
# `project.test_command` never reaches the Bash tool, so the PreToolUse hook
# never sees it — the runner must consult the same list at execution time, or the
# whole denylist becomes bypassable by moving the command into config and
# triggering a red run, which the loop does automatically on any scripts/ or
# tests/ task.
#
# Sourced only; never executed. No `set -e` and no work at source time (a sourced
# lib must not alter the caller's shell options), and no `exit` — every check
# RETURNS and names its verdict in DP_REASON/DP_PATTERN so each call site decides
# what a hit means.
#
# Contract: `dp_scan_command "<command>"` returns 0 to allow, 2 to block, and on
# a block sets DP_REASON (the human sentence) and DP_PATTERN (the second line the
# guards print). `dp_scan_manifest_write "<command>"` returns the manifest-write
# funnel's own code: 0 allow, 2 found, anything else the funnel's OWN malfunction,
# which callers degrade to allow per the defense-in-depth contract.
#
# Matching notes, carried here with the patterns they explain:
#   * `\s` is a GNU/BSD grep extension undefined in POSIX ERE (the regcomp(3)
#     engine behind `=~` does not implement it — see local-mode-tracking-guard.sh
#     for the same lesson learned once already), so it is translated to
#     `[[:space:]]` for matching only; callers still print the original
#     `\s`-bearing pattern text, and blocked-command messages are unchanged.
#     `nocasematch` is scoped to the one match, never left ambient.
#   * Simple patterns match per LINE, preserving grep's line-oriented semantics:
#     a `$`-anchored pattern must still fire on an interior line of a multi-line
#     command, and a `.*`-bearing pattern must not span lines.
#   * The SQL check is deliberately NOT line- or segment-iterated. Bare substring
#     greps once fired on any quoted prose naming these keywords (LR-005); an
#     anchored keyword+identifier shape scoped to a ;/&&/||/| segment was then
#     bypassed by a quoted multi-statement argument and by heredoc bodies, both of
#     which split the DB-CLI token away from the keyword. Requiring the token and
#     the keyword shape each ANYWHERE in the whole command is narrower than the
#     bare grep and immune to splitting. Tradeoff: a DB-CLI invocation co-occurring
#     with unrelated prose naming a keyword now blocks — pinned as a deliberate
#     over-block test.
#   * Force push ANDs three independent presence checks within one `git push`
#     segment because the force flag and the branch name appear in either order.

DP_REASON=""
DP_PATTERN=""

_dp_ci_match() {
  local str="$1" pattern="$2"
  local mpattern="${pattern//\\s/[[:space:]]}"
  local rc
  shopt -s nocasematch
  if [[ "$str" =~ $mpattern ]]; then rc=0; else rc=1; fi
  shopt -u nocasematch
  return $rc
}

# 1 = this pattern matched (DP_REASON/DP_PATTERN set), 0 = clean.
_dp_pattern() {
  local cmd="$1" pattern="$2" reason="$3" line
  while IFS= read -r line; do
    if _dp_ci_match "$line" "$pattern"; then
      DP_REASON="$reason"
      DP_PATTERN="$pattern"
      return 1
    fi
  done <<< "$cmd"
  return 0
}

_dp_check_sql() {
  local cmd="$1"
  local dbcli='(^|[^A-Za-z0-9_-])(mysqldump|sqlite3|sqlcmd|mysql|psql|redis-cli)([^A-Za-z0-9_-]|$)'
  local ident="[][A-Za-z_\`'\"][][A-Za-z0-9_.\`'\"-]*"
  local drop_table="(^|[^A-Za-z0-9_])DROP\s+TABLE\s+$ident"
  local drop_database="(^|[^A-Za-z0-9_])DROP\s+DATABASE\s+$ident"
  local truncate="(^|[^A-Za-z0-9_])TRUNCATE\s+(TABLE\s+)?$ident"

  _dp_ci_match "$cmd" "$dbcli" || return 0

  if _dp_ci_match "$cmd" "$drop_table"; then
    DP_REASON="SQL table drop"; DP_PATTERN="$drop_table"; return 1
  fi
  if _dp_ci_match "$cmd" "$drop_database"; then
    DP_REASON="SQL database drop"; DP_PATTERN="$drop_database"; return 1
  fi
  if _dp_ci_match "$cmd" "$truncate"; then
    DP_REASON="SQL table truncation"; DP_PATTERN="$truncate"; return 1
  fi
  return 0
}

_dp_check_force_push() {
  local cmd="$1" segment split
  # `\n` in a sed replacement is undefined by POSIX, NOT broken on BSD/macOS —
  # this host's sed does emit a real newline. Bash's split cannot vary by PATH.
  split="${cmd//&&/$'\n'}"
  split="${split//||/$'\n'}"
  split="${split//;/$'\n'}"
  split="${split//|/$'\n'}"
  while IFS= read -r segment; do
    if _dp_ci_match "$segment" 'git\s+push' \
      && _dp_ci_match "$segment" '(^|\s)(--force|-f)(\s|$)' \
      && _dp_ci_match "$segment" '(^|\s)(main|master)(\s|$)'; then
      DP_REASON="Force push to main/master branch"
      DP_PATTERN="git push with --force/-f targeting main/master"
      return 1
    fi
  done <<< "$split"
  return 0
}

# The denylist in its enforced order. 0 = allow, 2 = block.
# shellcheck disable=SC2034  # DP_REASON/DP_PATTERN are read by the call sites
dp_scan_command() {
  local cmd="${1:-}"
  DP_REASON=""
  DP_PATTERN=""
  [ -n "$cmd" ] || return 0

  # Anchored on a boundary after the target so `rm -rf /tmp/x` and other
  # legitimate absolute-path deletions are allowed (MF-027).
  _dp_pattern "$cmd" 'rm\s+-rf\s+/+(\s|$|;|&|\|)' "Recursive delete of root filesystem" || return 2
  _dp_pattern "$cmd" 'rm\s+-rf\s+/root/?(\s|$|;|&|\|)' "Recursive delete of root user home directory" || return 2
  _dp_pattern "$cmd" 'rm\s+-rf\s+~/?(\s|$|;|&|\|)' "Recursive delete of home directory" || return 2
  _dp_pattern "$cmd" 'rm\s+-rf\s+\$HOME/?(\s|$|;|&|\|)' "Recursive delete of home directory" || return 2
  _dp_pattern "$cmd" 'rm\s+-rf\s+\.\s*$' "Recursive delete of current directory" || return 2

  _dp_check_sql "$cmd" || return 2
  _dp_check_force_push "$cmd" || return 2

  _dp_pattern "$cmd" ':\(\)\{' "Fork bomb" || return 2
  _dp_pattern "$cmd" 'chmod\s+-R\s+777' "Recursive permission change to 777" || return 2
  _dp_pattern "$cmd" 'mkfs\.' "Filesystem format" || return 2
  _dp_pattern "$cmd" 'dd\s+if=.*of=/dev/' "Direct disk write" || return 2

  _dp_pattern "$cmd" 'curl\s+.*\|\s*(ba)?sh' "Piped internet execution (curl | sh)" || return 2
  _dp_pattern "$cmd" 'wget\s+.*\|\s*(ba)?sh' "Piped internet execution (wget | sh)" || return 2
  _dp_pattern "$cmd" 'curl\s+.*\|\s*sudo' "Piped internet execution with sudo" || return 2
  return 0
}

# Task manifest write funnel (ADR-020): scripts/task-transition.sh is the single
# sanctioned status writer; RULES.md §5 states the rules and their known limits.
dp_scan_manifest_write() {
  printf '%s' "${1:-}" | awk '
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

# Which options of a wrapper consume the NEXT word as their value. Shape cannot
# answer this, so the argument-taking options are enumerated per wrapper.
function wrapper_short_optargs(w) {
  # sudo -h is BOTH --help and -h host, i.e. optional-arg; only --host is safe.
  if (w == "sudo")    return "ugpCaUrtTDR"
  if (w == "doas")    return "uCa"
  if (w == "env")     return "uC"
  if (w == "nice")    return "n"
  if (w == "ionice")  return "cnpPu"
  if (w == "timeout") return "sk"
  if (w == "stdbuf")  return "ioe"
  # xargs -i/-e take an OPTIONAL, attached-only argument: consuming the next
  # word there would swallow the real command. Only -I/-E are required-arg.
  if (w == "xargs")   return "nPIdELsa"
  if (w == "time")    return "of"
  if (w == "exec")    return "a"
  return ""
}

# Space-delimited so a lookup anchors on " name " and cannot match a prefix.
function wrapper_long_optargs(w) {
  if (w == "sudo")    return " user group prompt close-from host other-user role type command-timeout chdir chroot "
  if (w == "doas")    return " user "
  # env --block-signal/--default-signal/--ignore-signal are optional-arg, omitted.
  if (w == "env")     return " unset chdir "
  if (w == "nice")    return " adjustment "
  if (w == "ionice")  return " class classdata pid pgid uid "
  if (w == "timeout") return " signal kill-after "
  if (w == "stdbuf")  return " input output error "
  # --replace, --eof and --max-lines are optional-arg too, so they are omitted.
  if (w == "xargs")   return " max-args max-procs delimiter max-chars arg-file "
  if (w == "time")    return " format output "
  return ""
}

# Consume one word of the option syntax belonging to wrapper w. Returns 1 when
# the word is the wrappers, 0 when it should be treated as the command word.
function wrapper_consume(w, t,    name, letters, i, ch) {
  if (wrapper_endopts) return 0
  if (t == "--") { wrapper_endopts = 1; return 1 }
  if (t == "-") return 1
  if (t ~ /^--/) {
    name = substr(t, 3)
    # `--opt=value` carries its value attached and consumes nothing after it.
    if (index(name, "=") > 0) return 1
    if (index(wrapper_long_optargs(w), " " name " ") > 0) wrapper_optarg_pending = 1
    return 1
  }
  if (t ~ /^-/) {
    letters = wrapper_short_optargs(w)
    name = substr(t, 2)
    for (i = 1; i <= length(name); i++) {
      ch = substr(name, i, 1)
      if (letters != "" && index(letters, ch) > 0) {
        # Getopt clustering: the rest of the cluster is the value when any
        # remains (`-o0`), otherwise the value is the next word.
        if (i == length(name)) wrapper_optarg_pending = 1
        return 1
      }
    }
    return 1
  }
  # A bare numeric operand belongs to the wrapper (nice 10, timeout 5).
  if (t ~ /^[0-9]+(\.[0-9]+)?[smhd]?$/) return 1
  return 0
}

# Adjacent quoted/unquoted fragments join into ONE word before validation, and a
# redirect target is resolved before the command-word check (`> file echo ok`).
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
    # The value of a wrapper option belongs to that wrapper whatever it looks
    # like, so it is claimed before any other reading of this token.
    if (wrapper_optarg_pending) { wrapper_optarg_pending = 0; return }
    # Leading VAR=value env assignments precede the command word in bash — skip
    # them so the real command word is still recognised.
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    # A wrapper (env, xargs, timeout …) delegates: skip its own options and
    # operands so the wrapped command is classified instead of the wrapper.
    if (wrapper_pending && wrapper_consume(wrapper_name, t)) return
    if (wrapper_cmd(base_cmd(t))) {
      wrapper_pending = 1; wrapper_name = base_cmd(t); wrapper_endopts = 0
      return
    }
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
  wrapper_name = ""; wrapper_endopts = 0; wrapper_optarg_pending = 0
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
  # An unquoted newline separates commands, so per-segment state resets: without
  # it a later echo/printf segment absorbs the attribution and a write slips through.
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
