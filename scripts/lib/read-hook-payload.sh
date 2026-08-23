#!/usr/bin/env bash
# scripts/lib/read-hook-payload.sh — the hook layer's one bounded stdin read.
#
# Sixteen hooks each hand-rolled `INPUT=$(cat)`, which blocks forever on a pipe
# nobody closes. This file is their single owner. Sourced, never executed, and
# it sets no shell options (the documented scripts/lib/* `set -e` exception).
#
# read_hook_payload() sets two globals and ALWAYS returns 0, so a caller under
# `set -euo pipefail` can call it unguarded:
#
#   HOOK_PAYLOAD          the content; empty unless the outcome is `payload`
#   HOOK_PAYLOAD_OUTCOME  payload | empty | timeout
#
# THREE outcomes, never two. `timeout` means the bound fired and whatever
# arrived is untrustworthy. It must never share a branch with `empty`, or a
# slow payload silently becomes a bypassed guard reporting the wrong cause.
#
# Classifying `timeout` cannot use read's exit status alone. Measured on the
# two bash builds this repo runs against:
#
#   bash 3.2.57   timeout -> rc=1    partial data DISCARDED
#   bash 5.3.15   timeout -> rc=142  partial data RETURNED
#   both          clean EOF -> rc=1, because `-d ''` never finds its NUL
#                 delimiter, so a fully successful read reports failure too
#
# rc=1 therefore means all three things on 3.2 and a second signal is needed.
# $SECONDS is the only clock available without a fork per hook invocation, and
# it counts wall-clock second boundaries crossed, not seconds spent: a 1.05s
# read starting at fraction .99 measures 2 and fires a 2s bound at half of it.
# Measured on both builds, 40 trials, producer closing at ~1.05s: 2 of 40 clean
# complete payloads discarded as `timeout`. The clock is therefore consulted
# LAST, and only where nothing else can decide:
#
#   1  rc > 128                  -> timeout   bash 5, definitive
#   2  any byte arrived          -> payload   3.2 discards on timeout, so a byte
#                                             rules a 3.2 timeout out, and a
#                                             bash 5 timeout already left at 1
#   3  rc == 1, no byte arrived,
#      $SECONDS at the bound     -> timeout   the one case still ambiguous
#   4  otherwise                 -> empty
#
# Step 2 retires that misclassification for every payload, not for a measured
# window of them. Residual, left deliberately: a producer holding the pipe 1-2s
# and closing having sent NOTHING still straddles to `timeout` rather than
# `empty`. Separating those needs sub-second time — bash-5-only $EPOCHREALTIME,
# or a fork on the hot path — and buys no caller anything, the payload being
# empty under both readings and `timeout` the more conservative of the two for
# the six hooks that fail closed.
#
# The bound is a payload ceiling as well as a wait ceiling. Throughput of the
# byte-at-a-time primitive through a PIPE, measured: ~2.6 MB/s on 3.2.57 and
# ~0.85 MB/s on 5.3.15 — the newer build is the slower one here — so the
# ceiling is a build- and machine-dependent 1-5 MB rather than one number, and
# it now sits where the bound genuinely fires. The 1-2s band below it used to
# be nondeterministic; that nondeterminism was the defect, not the ceiling.
# A hook envelope carries one tool_input and sits orders of magnitude under it.

[ -n "${_NAZGUL_READ_HOOK_PAYLOAD_SOURCED:-}" ] && return 0
_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1

HOOK_PAYLOAD_TIMEOUT_SECONDS=2
_HP_LIB_DIR="${BASH_SOURCE[0]%/*}"

read_hook_payload() {
  HOOK_PAYLOAD=""
  HOOK_PAYLOAD_OUTCOME="empty"

  # A terminal has no payload to deliver and no EOF coming; reading would block
  # on a human. The six hooks that already had this check keep their behaviour.
  [ -t 0 ] && return 0

  local started rc elapsed delivered outcome
  started=$SECONDS
  rc=0
  IFS= read -r -d '' -t "$HOOK_PAYLOAD_TIMEOUT_SECONDS" HOOK_PAYLOAD || rc=$?
  elapsed=$((SECONDS - started))
  delivered=${#HOOK_PAYLOAD}

  # $(cat) strips every trailing newline; matching it exactly is what keeps each
  # caller's `[ -z "$INPUT" ]` test deciding what it decided before.
  while [ "${HOOK_PAYLOAD%$'\n'}" != "$HOOK_PAYLOAD" ]; do
    HOOK_PAYLOAD="${HOOK_PAYLOAD%$'\n'}"
  done

  outcome="empty"
  if [ "$rc" -gt 128 ]; then
    outcome="timeout"
  elif [ "$delivered" -gt 0 ]; then
    [ -n "$HOOK_PAYLOAD" ] && outcome="payload"
  elif [ "$rc" -eq 1 ] && [ "$elapsed" -ge "$HOOK_PAYLOAD_TIMEOUT_SECONDS" ]; then
    outcome="timeout"
  fi

  # Cleared on timeout so no caller can parse a truncated envelope on either build.
  [ "$outcome" = "timeout" ] && HOOK_PAYLOAD=""
  # shellcheck disable=SC2034  # read by every sourcing hook, not within this file
  HOOK_PAYLOAD_OUTCOME="$outcome"
  return 0
}

# hook_payload_timeout_report <hook> <fail-open|fail-closed> <action phrase>
# One grammar on stderr and on the bus; the caller still picks its disposition.
hook_payload_timeout_report() {
  printf '%s: stdin read timeout after %ss (payload untrusted) — %s, %s\n' \
    "$1" "$HOOK_PAYLOAD_TIMEOUT_SECONDS" "$2" "$3" >&2
  ( # shellcheck source=./nazgul-root.sh
    . "$_HP_LIB_DIR/nazgul-root.sh" 2>/dev/null || exit 0
    NAZGUL_DIR="$(resolve_nazgul_dir 2>/dev/null)" || exit 0
    { [ -n "${NAZGUL_DIR:-}" ] && [ -f "$NAZGUL_DIR/config.json" ]; } || exit 0
    # shellcheck disable=SC2034  # read by emit_event, sourced just below
    EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"
    # shellcheck source=./emit-event.sh
    . "$_HP_LIB_DIR/emit-event.sh" 2>/dev/null || exit 0
    emit_event "hook_stdin_timeout" hook "$1" disposition "$2" \
      bound_seconds:n "$HOOK_PAYLOAD_TIMEOUT_SECONDS"
  ) >/dev/null 2>&1 || true
}
