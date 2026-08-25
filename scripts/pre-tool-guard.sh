#!/usr/bin/env bash
set -euo pipefail

# Nazgul Pre-Tool Guard — blocks destructive bash commands
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RHP_LIB="$SCRIPT_DIR/lib/read-hook-payload.sh"
# The same four facts dp_unavailable asks below, and for the same reason: this hook
# blocks only on exit 2, so a load that returns 0 having DEFINED NOTHING leaves the
# call command-not-found, exits 127 under `set -e`, and reads as allow-unscreened.
rhp_unavailable() {
  echo "NAZGUL SAFETY: Blocked — stdin reader unavailable: $1" >&2
  echo "Expected authority: $RHP_LIB" >&2
  echo "Repair the Nazgul install (scripts/lib/ must ship alongside scripts/) — fail-closed, blocking the unscreened command." >&2
  exit 2
}
[ -f "$RHP_LIB" ] || rhp_unavailable "file is missing"
[ -r "$RHP_LIB" ] || rhp_unavailable "file is not readable"
# `source` returns the sourced file's LAST statement's status, so a non-zero there
# is not evidence of a broken library — parse and API are asked as separate facts.
bash -n "$RHP_LIB" 2>/dev/null || rhp_unavailable "file has a syntax error (bash -n rejected it)"
rhp_src_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_src_rc=$?
declare -F read_hook_payload >/dev/null \
  || rhp_unavailable "read_hook_payload is not defined after sourcing (source returned $rhp_src_rc)"
declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "hook_payload_timeout_report is not defined after sourcing (source returned $rhp_src_rc)"
if [ "$rhp_src_rc" -ne 0 ]; then
  echo "NAZGUL SAFETY: note — $RHP_LIB returned $rhp_src_rc on load, but both reader functions are defined; the read proceeds." >&2
fi

# The command being executed is passed via stdin or $ARGUMENTS
INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  read_hook_payload
  # lean-comments: allow-run — the two reasons share a disposition for DIFFERENT reasons.
  # Nothing scopes this guard to a project, so the only alternative to denying is an
  # unscreened command — the stance dp_unavailable already takes below. `oversize` is asked
  # SEPARATELY rather than inheriting the stall answer by proximity: it is deterministic
  # where a stall is transient, so it costs the operation rather than a retry. It still
  # denies, because allowing it would make a cap-sized pad a screening bypass, and unlike
  # the guards with a backstop this one is the last thing between the command and the shell.
  if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
    PTG_ACTION="blocking the unscreened command"
    if [ "${HOOK_PAYLOAD_REASON:-}" = "oversize" ]; then
      PTG_ACTION="$PTG_ACTION — allowing it would make a ${HOOK_PAYLOAD_MAX_CHARS}-char pad a screening bypass; send a shorter command, or write large content with the Write tool"
    fi
    hook_payload_timeout_report "pre-tool-guard" "fail-closed" "$PTG_ACTION"
    exit 2
  fi
  INPUT="$HOOK_PAYLOAD"
fi

# If no input, allow
if [ -z "$INPUT" ]; then
  exit 0
fi

# Production stdin is {"tool_input":{"command":"..."}}; the test harness passes the
# raw command. Scanning the envelope would make the whole command one quoted string.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [ -z "$CMD" ]; then
  CMD="$INPUT"
fi

DP_LIB="$SCRIPT_DIR/lib/destructive-patterns.sh"

# A PreToolUse hook blocks ONLY on exit 2, so an unloadable authority would let
# every destructive command through unscreened and unannounced: fail closed.
dp_unavailable() {
  echo "NAZGUL SAFETY: Blocked — destructive-command screen unavailable: $1" >&2
  echo "Expected authority: $DP_LIB" >&2
  echo "Repair the Nazgul install (scripts/lib/ must ship alongside scripts/) — no command is screened until it loads." >&2
  exit 2
}

[ -f "$DP_LIB" ] || dp_unavailable "file is missing"
[ -r "$DP_LIB" ] || dp_unavailable "file is not readable"
# `source` returns the sourced file's LAST statement's status, so a non-zero there
# is not evidence of a broken library — parse and API are asked as separate facts.
bash -n "$DP_LIB" 2>/dev/null || dp_unavailable "file has a syntax error (bash -n rejected it)"
dp_src_rc=0
# shellcheck source=./lib/destructive-patterns.sh
source "$DP_LIB" || dp_src_rc=$?
declare -F dp_scan_command >/dev/null || dp_unavailable "dp_scan_command is not defined after sourcing (source returned $dp_src_rc)"
declare -F dp_scan_manifest_write >/dev/null || dp_unavailable "dp_scan_manifest_write is not defined after sourcing (source returned $dp_src_rc)"
if [ "$dp_src_rc" -ne 0 ]; then
  echo "NAZGUL SAFETY: note — $DP_LIB returned $dp_src_rc on load, but both screen functions are defined; screening proceeds." >&2
fi

# The patterns live in ONE sourceable authority because red-run.sh executes a
# config-supplied command outside the Bash tool and must screen the same list.
dp_ec=0
dp_scan_command "$CMD" || dp_ec=$?
if [ "$dp_ec" -eq 2 ]; then
  echo "NAZGUL SAFETY: Blocked — $DP_REASON" >&2
  echo "Command contained: $DP_PATTERN" >&2
  exit 2
fi

# Block ONLY on the funnel's "found a manifest write" signal (exit 2); any other
# non-zero degrades to allow — the guard never blocks on its own malfunction.
manifest_funnel_ec=0
dp_scan_manifest_write "$CMD" || manifest_funnel_ec=$?
if [ "$manifest_funnel_ec" -eq 2 ]; then
  echo "NAZGUL SAFETY: Blocked — Direct write to task manifest via Bash (use Write/Edit tools)" >&2
  echo "Command: $CMD" >&2
  exit 2
fi

# All checks passed
exit 0
