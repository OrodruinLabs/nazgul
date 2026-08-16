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

# Production stdin is {"tool_input":{"command":"..."}}; the test harness passes the
# raw command. Scanning the envelope would make the whole command one quoted string.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [ -z "$CMD" ]; then
  CMD="$INPUT"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
# shellcheck source=./lib/destructive-patterns.sh
source "$DP_LIB" || dp_unavailable "file could not be sourced"
declare -F dp_scan_command >/dev/null || dp_unavailable "dp_scan_command is not defined after sourcing"
declare -F dp_scan_manifest_write >/dev/null || dp_unavailable "dp_scan_manifest_write is not defined after sourcing"

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
