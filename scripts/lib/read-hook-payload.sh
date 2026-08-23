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
# rc=1 therefore means all three things on 3.2. Two signals are used instead —
# rc > 128, or SECONDS elapsed at the bound — and the payload is cleared on
# timeout so no caller can parse a truncated envelope on either build.
#
# Throughput of the byte-at-a-time primitive, measured: ~2.8 MB/s, against
# $(cat)'s ~90 MB/s. The bound is thus a payload CEILING as well as a wait
# ceiling: above roughly 2.8 MB a legitimate payload reports `timeout`. A hook
# envelope carries one tool_input and sits orders of magnitude below that.

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

  local started rc elapsed
  started=$SECONDS
  rc=0
  IFS= read -r -d '' -t "$HOOK_PAYLOAD_TIMEOUT_SECONDS" HOOK_PAYLOAD || rc=$?
  elapsed=$((SECONDS - started))

  if [ "$rc" -gt 128 ] || [ "$elapsed" -ge "$HOOK_PAYLOAD_TIMEOUT_SECONDS" ]; then
    HOOK_PAYLOAD=""
    HOOK_PAYLOAD_OUTCOME="timeout"
    return 0
  fi

  # $(cat) strips every trailing newline; matching it exactly is what keeps each
  # caller's `[ -z "$INPUT" ]` test deciding what it decided before.
  while [ "${HOOK_PAYLOAD%$'\n'}" != "$HOOK_PAYLOAD" ]; do
    HOOK_PAYLOAD="${HOOK_PAYLOAD%$'\n'}"
  done

  if [ -n "$HOOK_PAYLOAD" ]; then
    # shellcheck disable=SC2034  # read by every sourcing hook, not within this file
    HOOK_PAYLOAD_OUTCOME="payload"
  fi
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
