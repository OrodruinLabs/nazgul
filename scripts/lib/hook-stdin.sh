#!/usr/bin/env bash
# Nazgul bounded hook-stdin reader (#218 C1) — one shared, EOF-INDEPENDENT read
# for hook scripts that must consume a Claude Code hook payload.
#
# NEW IDIOM. There is no `read -t` prior art anywhere in this repo; the ten
# scripts already reading hook stdin all use `INPUT=$(cat)` behind `[ ! -t 0 ]`
# (scripts/notify.sh:69-73, scripts/stop-failure.sh:11-12, ...). That shape IS
# the #155 deadlock class — do NOT copy it here, and do NOT "simplify" the read
# below back to `cat`. Migrating those ten is #155's job, not this file's.
#
# Every element of `IFS= read -r -d '' -t 2 payload <&0` is load-bearing:
#
#   [ -t 0 ]    Necessary, NEVER sufficient. #155 records the terminal test as
#               the WRONG PREDICATE, with a live 1h03m deadlock reproduced by
#               `tail -f /dev/null | bash tests/run-tests.sh`: the hang
#               condition is stdin that never reaches EOF, not stdin that is a
#               terminal. #229 is the same class through session-context.sh.
#               Both still OPEN.
#   -t 2        The bound that actually closes that hazard, and the only reason
#               a never-EOF stdin returns at all. `read` is a bash BUILTIN, so
#               this needs no timeout(1) — macOS ships none, which is why
#               scripts/formatter.sh:218-221 carries a gtimeout ladder.
#   -d ''       Consume to NUL/EOF rather than to the first newline, so a
#               pretty-printed multi-line JSON payload is not truncated.
#   IFS= -r     No word splitting, no backslash interpretation — a payload is
#               bytes, not shell words.
#   || rc=$?    `read` returns non-zero on BOTH timeout and
#               EOF-without-delimiter, and both are the normal case here, so it
#               must never propagate under the caller's `set -euo pipefail`.
#
# INTERFACE — it assigns rather than printing, and that is deliberate. A
# `$(...)` capture is a SUBSHELL, so a stdout-only reader can report the payload
# but never WHY the payload is empty; "the read hit its bound" and "there was no
# payload" would collapse into one indistinguishable answer. That collapse is
# precisely the defect RULES §15 / ADR-009 exists to prevent, and #218's own
# closed set (`no_stdin` / `read_timeout` / ...) requires the two to be told
# apart. So:
#
#   read_hook_payload [VARNAME]   VARNAME defaults to HOOK_PAYLOAD.
#     sets  $VARNAME          the payload, or "" when none was read
#     sets  HOOK_STDIN_WHY    "" when a payload was read; otherwise "no_stdin"
#                             (terminal, closed, or a clean empty EOF) or
#                             "read_timeout" (the bound was hit with nothing).
#     reads HOOK_STDIN_TIMEOUT   seconds; default 2
#     returns 0 UNCONDITIONALLY — never aborts a caller under `set -euo
#     pipefail`, and needs no `|| true` at the call site.
#
# A short, absent, or truncated payload is never an error: every consumer must
# degrade to its unknown/today's-behavior arm. A TIMED-OUT read can still yield
# a partial payload, which is non-empty and therefore fails the caller's own
# JSON parse — same arm, reached honestly.
#
# Sourced, never executed. Per CLAUDE.md Code Style's sourced-lib exception this
# file carries no `set -e` and must not alter the caller's shell options.

# Seconds the bounded read waits before giving up on a stdin that never EOFs.
HOOK_STDIN_TIMEOUT="${HOOK_STDIN_TIMEOUT:-2}"

# Why the last read_hook_payload produced nothing; "" when it produced a payload.
HOOK_STDIN_WHY=""

# Reads the payload into ${1:-HOOK_PAYLOAD}; see INTERFACE above. Returns 0 always.
# shellcheck disable=SC2034  # HOOK_STDIN_WHY is written for the caller, not read here
read_hook_payload() {
  local __hs_out="${1:-HOOK_PAYLOAD}"
  local __hs_payload="" __hs_rc=0
  HOOK_STDIN_WHY=""
  if [ -t 0 ]; then
    HOOK_STDIN_WHY="no_stdin"
  else
    IFS= read -r -d '' -t "$HOOK_STDIN_TIMEOUT" __hs_payload <&0 || __hs_rc=$?
    if [ -z "$__hs_payload" ]; then
      # bash returns >128 from `read` only when the -t bound was exceeded.
      if [ "$__hs_rc" -gt 128 ]; then HOOK_STDIN_WHY="read_timeout"; else HOOK_STDIN_WHY="no_stdin"; fi
    fi
  fi
  printf -v "$__hs_out" '%s' "$__hs_payload"
  return 0
}
