#!/usr/bin/env bash
# scripts/lib/read-hook-payload.sh — the hook layer's one bounded stdin read.
#
# Sixteen hooks each hand-rolled `INPUT=$(cat)`, which blocks forever on a pipe
# nobody closes. This file is their single owner. Sourced, never executed, and
# it sets no shell options (the documented scripts/lib/* `set -e` exception).
#
# read_hook_payload() sets three globals and ALWAYS returns 0, so a caller under
# `set -euo pipefail` can call it unguarded:
#
#   HOOK_PAYLOAD          the content; empty unless the outcome is `payload`
#   HOOK_PAYLOAD_OUTCOME  payload | empty | timeout
#   HOOK_PAYLOAD_REASON   stall | deadline | oversize, set only with `timeout`
#
# THREE outcomes, never two. `timeout` means a bound fired and whatever arrived
# is untrustworthy. It must never share a branch with `empty`, or a slow payload
# silently becomes a bypassed guard reporting the wrong cause.
#
# THREE bounds, because each covers a case the other two structurally cannot,
# and each names itself in HOOK_PAYLOAD_REASON:
#
#   stall     `read -t` bounds the wait for input to BECOME available. It is
#             the only bound that fires on a pipe nobody writes to — and the
#             only one that CANNOT fire when the producer already wrote
#             everything, because then read never waits.
#   deadline  $SECONDS across chunks. `read -t` bounds ONE read call, so once
#             the payload arrives chunk by chunk each call completes in time
#             and no single `-t` covers the whole read. This is the bound
#             chunking itself makes necessary, and the only one that fires on a
#             producer steady enough never to stall and slow enough never to
#             reach the cap.
#   oversize  a ceiling on content. The only bound that fires on a producer
#             that is neither slow nor absent, just too large.
#
# An oversized payload is deliberately NOT a fourth OUTCOME. Every caller tests
# `[ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]` by equality, so a fourth value would
# fall through all sixteen branches into the normal path — the exact silent
# reclassification a cap exists to prevent. The distinction a caller acts on is
# "I have no trustworthy payload", which is one branch; the distinction an
# operator diagnoses is the reason, which is a field. The cost, stated: the
# string `timeout` under-describes `oversize`, and widening it means changing
# sixteen callers in lockstep.
#
# Classifying `stall` cannot use read's exit status alone. Measured on the two
# bash builds this repo runs against:
#
#   bash 3.2.57   stall -> rc=1     partial data DISCARDED
#   bash 5.3.15   stall -> rc=142   partial data RETURNED
#   both          clean EOF -> rc=1, because `-d ''` never finds its NUL
#                 delimiter, so a fully successful read reports failure too
#
# rc=1 therefore means all three things on 3.2 and a second signal is needed.
# $SECONDS is the only clock available without a fork per hook invocation, and
# it counts wall-clock second boundaries crossed, not seconds spent: a 1.05s
# read starting at fraction .99 measures 2 and fires a 2s bound at half of it.
# The clock is therefore consulted LAST, per chunk, and only where nothing else
# can decide:
#
#   1  rc > 128                  -> stall     bash 5, definitive
#   2  any byte arrived          -> keep it   3.2 discards on stall, so a byte
#                                             rules a 3.2 stall out, and a bash
#                                             5 stall already left at 1
#   3  rc == 1, no byte arrived,
#      $SECONDS at the bound     -> stall     the one case still ambiguous
#   4  otherwise                 -> end of input
#
# Step 2 retires that misclassification for every payload, not for a measured
# window of them. Residual, left deliberately: a producer holding the pipe 1-2s
# and closing having sent NOTHING still straddles to `timeout` rather than
# `empty`. Separating those needs sub-second time — bash-5-only $EPOCHREALTIME,
# or a fork on the hot path — and buys no caller anything, the payload being
# empty under both readings and `timeout` the more conservative of the two for
# the six hooks that fail closed.
#
# THROUGHPUT, measured on this machine 2026-08-23 on stock /bin/bash 3.2.57 with
# a file already on stdin, wall clock via python3 rather than $SECONDS (KB/s is
# payload size over total process time, so it includes bash startup):
#
#            the single read + suffix-strip       this chunked reader
#    64 KB       0.77s  /     83 KB/s              0.09s  /   704 KB/s
#   128 KB       2.95s  /     43 KB/s              0.14s  /   933 KB/s
#   256 KB      11.46s  /     22 KB/s              0.28s  /   907 KB/s
#   512 KB      45.02s  /     11 KB/s              0.62s  /   823 KB/s
#  1024 KB     212.07s  /    4.8 KB/s              1.94s, and `oversize` at the
#                                                  cap rather than a `payload`
#
# The left column is QUADRATIC — time quadruples per doubling, so throughput
# halves — and the cost was never in `read`, which is linear and took 0.15s for
# 256 KB. It was one `${V%$'\n'}` suffix removal: shortest-suffix pattern removal
# in a UTF-8 locale is O(n^2) in bash, and 11.35s of that 11.46s row sat in a
# SINGLE expansion (LC_ALL=C cuts it ~13x and is still superlinear). Hence the
# windowed strip below.
#
# This corrects the previous header, which claimed ~2.8 MB/s and a ~2.8 MB
# ceiling: it had timed the read and never the strip that followed it, so it was
# wrong by 30-200x in the direction that matters. The real ceiling against the
# 10s hooks.json grants a PreToolUse guard was ~240 KB — under this repo's own
# CHANGELOG.md (241 KB) and not far above RULES.md (163 KB), either of which
# reaches those guards whole as a Write `content` field. And nothing reported it:
# 1024 KB returned `payload` after 212s, because `read -t` bounds the wait for
# input to BECOME available and a producer that already wrote everything never
# makes it wait.
#
# _hp_strip_trailing_newlines exists because `$(cat)` strips every trailing
# newline and each caller's `[ -z "$INPUT" ]` test was written against that. It
# measures the run inside a fixed window and cuts the payload once by substring,
# both linear, rather than removing one suffix at a time. Its residual: a run
# LONGER than the window is resolved only for the all-newline payload — the one
# case where the leftover would change `-z`. A payload with content and 512+
# trailing newlines keeps the surplus, which differs from `$(cat)` in bytes no
# caller reads: `jq` is indifferent and `-z` is already decided by the content.

[ -n "${_NAZGUL_READ_HOOK_PAYLOAD_SOURCED:-}" ] && return 0
_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1

HOOK_PAYLOAD_TIMEOUT_SECONDS=2
# Half the smallest timeout hooks.json grants any hook (10s), so a hook that
# spends its whole read budget still has half its own budget left to decide.
HOOK_PAYLOAD_DEADLINE_SECONDS=5
# Chars, not bytes — bash counts what the locale calls one; the two agree for an
# ASCII JSON envelope. 1 MiB is 4x this repo's largest text file.
HOOK_PAYLOAD_MAX_CHARS=1048576
HOOK_PAYLOAD_CHUNK_CHARS=8192
# Trailing newlines are stripped exactly through a window this wide.
HOOK_PAYLOAD_STRIP_WINDOW=512
_HP_LIB_DIR="${BASH_SOURCE[0]%/*}"

# Matches `$(cat)`'s trailing-newline strip in linear time; the obvious spelling
# is the O(n^2) trap above. Window, residual and cost in the header.
_hp_strip_trailing_newlines() {
  local n w tail run k
  n=${#HOOK_PAYLOAD}
  [ "$n" -eq 0 ] && return 0
  w=$HOOK_PAYLOAD_STRIP_WINDOW
  [ "$w" -gt "$n" ] && w=$n
  tail="${HOOK_PAYLOAD:$((n - w)):$w}"
  # Longest prefix ending in a non-newline, removed: what is left IS the run, and
  # an all-newline window matches nothing, so k lands on w and says so.
  run="${tail##*[!$'\n']}"
  k=${#run}
  if [ "$k" -eq "$w" ] && [ "$w" -lt "$n" ]; then
    case "$HOOK_PAYLOAD" in
      *[!$'\n']*) ;;
      *) k=$n ;;
    esac
  fi
  [ "$k" -gt 0 ] && HOOK_PAYLOAD="${HOOK_PAYLOAD:0:$((n - k))}"
  return 0
}

read_hook_payload() {
  HOOK_PAYLOAD=""
  HOOK_PAYLOAD_OUTCOME="empty"
  HOOK_PAYLOAD_REASON=""

  # A terminal has no payload to deliver and no EOF coming; reading would block
  # on a human. The six hooks that already had this check keep their behaviour.
  [ -t 0 ] && return 0

  local started chunk_started rc want got total elapsed reason outcome
  started=$SECONDS
  total=0
  reason=""

  while :; do
    want=$((HOOK_PAYLOAD_MAX_CHARS - total + 1))
    if [ "$want" -le 0 ]; then reason="oversize"; break; fi
    [ "$want" -gt "$HOOK_PAYLOAD_CHUNK_CHARS" ] && want=$HOOK_PAYLOAD_CHUNK_CHARS

    chunk=""
    rc=0
    chunk_started=$SECONDS
    IFS= read -r -d '' -n "$want" -t "$HOOK_PAYLOAD_TIMEOUT_SECONDS" chunk || rc=$?
    elapsed=$((SECONDS - chunk_started))
    got=${#chunk}
    HOOK_PAYLOAD="$HOOK_PAYLOAD$chunk"
    total=$((total + got))

    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -gt 128 ]; then
        reason="stall"
      elif [ "$got" -eq 0 ] && [ "$elapsed" -ge "$HOOK_PAYLOAD_TIMEOUT_SECONDS" ]; then
        reason="stall"
      fi
      break
    fi
    [ "$got" -eq 0 ] && break
    if [ $((SECONDS - started)) -ge "$HOOK_PAYLOAD_DEADLINE_SECONDS" ]; then
      reason="deadline"
      break
    fi
  done

  _hp_strip_trailing_newlines
  [ -z "$reason" ] && [ "${#HOOK_PAYLOAD}" -gt "$HOOK_PAYLOAD_MAX_CHARS" ] && reason="oversize"

  outcome="empty"
  if [ -n "$reason" ]; then
    outcome="timeout"
  elif [ -n "$HOOK_PAYLOAD" ]; then
    outcome="payload"
  fi

  # Cleared on every bound so no caller can parse a truncated envelope, on
  # either build and whichever of the three fired.
  [ "$outcome" = "timeout" ] && HOOK_PAYLOAD=""
  # shellcheck disable=SC2034  # read by every sourcing hook, not within this file
  HOOK_PAYLOAD_OUTCOME="$outcome"
  # shellcheck disable=SC2034  # read by hook_payload_timeout_report and by tests
  HOOK_PAYLOAD_REASON="$reason"
  return 0
}

# hook_payload_timeout_report <hook> <fail-open|fail-closed> <action phrase>
# One grammar on stderr and on the bus; the caller still picks its disposition.
hook_payload_timeout_report() {
  local reason bound detail
  reason="${HOOK_PAYLOAD_REASON:-stall}"
  case "$reason" in
    deadline)
      bound="$HOOK_PAYLOAD_DEADLINE_SECONDS"
      detail="timeout at the ${bound}s total read deadline" ;;
    oversize)
      bound="$HOOK_PAYLOAD_MAX_CHARS"
      detail="payload over the ${bound}-char cap" ;;
    *)
      reason="stall"
      bound="$HOOK_PAYLOAD_TIMEOUT_SECONDS"
      detail="timeout after ${bound}s waiting for input" ;;
  esac
  printf '%s: bounded stdin read failed: %s (payload untrusted) — %s, %s\n' \
    "$1" "$detail" "$2" "$3" >&2
  ( # shellcheck source=./nazgul-root.sh
    . "$_HP_LIB_DIR/nazgul-root.sh" 2>/dev/null || exit 0
    NAZGUL_DIR="$(resolve_nazgul_dir 2>/dev/null)" || exit 0
    { [ -n "${NAZGUL_DIR:-}" ] && [ -f "$NAZGUL_DIR/config.json" ]; } || exit 0
    # shellcheck disable=SC2034  # read by emit_event, sourced just below
    EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"
    # shellcheck source=./emit-event.sh
    . "$_HP_LIB_DIR/emit-event.sh" 2>/dev/null || exit 0
    emit_event "hook_stdin_timeout" hook "$1" disposition "$2" \
      reason "$reason" bound:n "$bound"
  ) >/dev/null 2>&1 || true
}
