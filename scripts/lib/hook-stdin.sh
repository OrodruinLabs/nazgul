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
# closed set requires the two to be told apart. So:
#
#   read_hook_payload [VARNAME]   VARNAME defaults to HOOK_PAYLOAD.
#     sets  $VARNAME          the payload, or "" when none was read
#     sets  HOOK_STDIN_WHY    "" when a payload arrived whole; otherwise exactly
#                             one of this reader's three closed-set members:
#                               no_stdin              terminal, closed, or a clean empty EOF
#                               read_timeout          the bound was hit with NOTHING read
#                               read_timeout_partial  the bound was hit with SOME bytes read
#     reads NAZGUL_HOOK_STDIN_TIMEOUT   seconds; default 2, validated at source
#     returns 0 UNCONDITIONALLY — never aborts a caller under `set -euo
#     pipefail`, and needs no `|| true` at the call site.
#
# NAZGUL_HOOK_STDIN_TIMEOUT is VALIDATED at source rather than trusted, in three
# parts, because SHAPE ALONE IS NOT ENOUGH — the claim this header used to make.
# A well-shaped spec can still be one this bash REFUSES (`0.5` under the bash 3.2
# macOS ships as /bin/bash; fractional `read -t` arrived in 4.0) or one it honours
# far too literally (a 20-digit integer, which disarms the bound entirely). So the
# check is: shape, then a ceiling on the integer part, then the RUNNING bash's own
# verdict via __hs_read_spec_accepted, which asks it instead of encoding a version
# table. All three matter because a spec `read` REJECTS returns 1 having consumed
# nothing — the SAME status a clean EOF returns — so the miss reads as `no_stdin`,
# a misconfiguration wearing the label of an absent payload with the whole of #218
# silently inert behind it. Validating hard enough that a rejected spec never
# reaches the read is the deliberate choice: it keeps the `why` set CLOSED AT
# SEVEN rather than minting an eighth member for a case that can no longer arise.
# A rejected value falls back to 2 seconds and says so on stderr (ADR-014). The
# unprefixed `HOOK_STDIN_TIMEOUT` is NOT honoured: no shim, by design.
#
# The remaining four members of #218's `why` set — `not_json`, `field_absent`,
# `field_wrong_type`, `no_jq` — are the CONSUMER's, decided after the payload is
# in hand. Seven in total; this file owns the first three.
#
# A short, absent, or truncated payload is never an error: every consumer must
# degrade to its unknown/today's-behavior arm. But a TIMED-OUT read that already
# had bytes yields a PARTIAL payload, which is non-empty and so fails the
# consumer's JSON parse; that is `read_timeout_partial`, NOT `not_json`. Only
# this reader knows the truncation was its own doing, so `stop-hook.sh` prefers
# an inbound HOOK_STDIN_WHY over its own parse verdict — reporting it as
# `not_json` sends the operator hunting a payload-schema change that never
# happened.
#
# Sourced, never executed. Per CLAUDE.md Code Style's sourced-lib exception this
# file carries no `set -e` and must not alter the caller's shell options.

# The ceiling on the integer part. A hook that waits a minute has already failed, and a larger
# spec either overflows `read`'s own parse or is honoured so literally that the bound is no bound.
__HS_MAX_TIMEOUT=60

# Asks the RUNNING bash whether it will honour this -t spec, instead of encoding a version table.
# The here-string already has a byte ready, so an accepted spec returns 0 at once and never waits.
__hs_read_spec_accepted() {
  local __hs_probe __hs_prc=0
  read -r -t "$1" __hs_probe <<< "nazgul" 2>/dev/null || __hs_prc=$?
  [ "$__hs_prc" -eq 0 ]
}

# Shape (a positive integer or simple decimal — a bare `.`, `0` and `0.0` fail the second case,
# since stripping every dot and zero leaves nothing), then range, then this bash's own verdict.
__hs_valid_timeout() {
  local __hs_int
  case "$1" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "${1//[.0]/}" in '') return 1 ;; esac
  # `.5` has an EMPTY integer part, and `[` refuses a value past intmax outright rather than
  # saturating, so the digit count is bounded before the numeric comparison below.
  __hs_int="${1%%.*}"
  [ -n "$__hs_int" ] || __hs_int=0
  [ "${#__hs_int}" -le 3 ] || return 1
  [ "$__hs_int" -le "$__HS_MAX_TIMEOUT" ] || return 1
  __hs_read_spec_accepted "$1"
}

# Seconds the bounded read waits before giving up on a stdin that never EOFs.
# NAZGUL_-prefixed like every other operator switch here; validated, see header.
NAZGUL_HOOK_STDIN_TIMEOUT="${NAZGUL_HOOK_STDIN_TIMEOUT:-2}"
if ! __hs_valid_timeout "$NAZGUL_HOOK_STDIN_TIMEOUT"; then
  printf 'nazgul: NAZGUL_HOOK_STDIN_TIMEOUT=%s is not a number of seconds this bash will honour (positive, at most %s, and accepted by its own read -t); falling back to 2\n' \
    "$NAZGUL_HOOK_STDIN_TIMEOUT" "$__HS_MAX_TIMEOUT" >&2
  NAZGUL_HOOK_STDIN_TIMEOUT=2
fi

# Why the last read_hook_payload produced nothing; "" when it produced a payload.
HOOK_STDIN_WHY=""

# Reads the payload into ${1:-HOOK_PAYLOAD}; see INTERFACE above. Returns 0 always.
# shellcheck disable=SC2034  # HOOK_STDIN_WHY is written for the caller, not read here
read_hook_payload() {
  local __hs_out="${1:-HOOK_PAYLOAD}"
  # `printf -v` evaluates an array subscript ARITHMETICALLY, and arithmetic evaluation performs
  # command substitution — so an unvalidated [VARNAME] is an execution sink (in-flight-marker.sh:61-65).
  case "$__hs_out" in ''|*[!A-Za-z0-9_]*|[0-9]*)
    # Announced, never silent: a redirected write looks to the caller exactly like an absent payload.
    printf 'nazgul: read_hook_payload: %s is not a shell variable name; reading into HOOK_PAYLOAD instead\n' "$__hs_out" >&2
    __hs_out=HOOK_PAYLOAD
    ;;
  esac
  local __hs_payload="" __hs_rc=0
  HOOK_STDIN_WHY=""
  if [ -t 0 ]; then
    HOOK_STDIN_WHY="no_stdin"
  else
    IFS= read -r -d '' -t "$NAZGUL_HOOK_STDIN_TIMEOUT" __hs_payload <&0 || __hs_rc=$?
    # bash returns >128 from `read` only when the -t bound was exceeded.
    if [ "$__hs_rc" -gt 128 ]; then
      if [ -n "$__hs_payload" ]; then HOOK_STDIN_WHY="read_timeout_partial"; else HOOK_STDIN_WHY="read_timeout"; fi
    elif [ -z "$__hs_payload" ]; then
      HOOK_STDIN_WHY="no_stdin"
    fi
  fi
  printf -v "$__hs_out" '%s' "$__hs_payload"
  return 0
}
