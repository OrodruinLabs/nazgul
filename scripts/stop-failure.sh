#!/usr/bin/env bash
set -euo pipefail

# Nazgul StopFailure — fires when a turn ends due to an API error (not a normal
# Stop). Without this, an AFK/autonomous loop can silently stall on a transient
# API failure with no record and no notification. This records the failure so
# recovery can resume, and alerts the operator.
#
# Input: hook JSON on stdin (ignored — we only need to know the turn errored).

# Drain stdin so the producer never blocks on a full pipe.
cat >/dev/null 2>&1 || true

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul is not initialized here, do nothing.
[ -f "$CONFIG" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Emit stop_failure to the telemetry bus (replaces legacy iterations.jsonl write).
# CURRENT_ITERATION is intentionally null — script does not read config.
# shellcheck disable=SC2034
CURRENT_ITERATION="null"
emit_event "stop_failure"

# Leave a recovery breadcrumb so the next session knows the last turn errored.
mkdir -p "$NAZGUL_DIR/logs"
printf '{"last_stop_failure":"%s"}\n' "$TS" > "$NAZGUL_DIR/.stop_failure"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Alert the operator — a silently stalled AFK run is the failure mode we guard
# against. notify.sh only fires on loop *completion*, so run the configured
# notification command directly here (on_failure, falling back to on_complete).
if command -v jq >/dev/null 2>&1; then
  NOTIFY_CMD=$(jq -r '.notifications.on_failure // .notifications.on_complete // empty' "$CONFIG" 2>/dev/null || true)
  if [ -n "${NOTIFY_CMD:-}" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 30 /bin/sh -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
    else
      /bin/sh -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
    fi
  fi
fi

# Forward to any configured webhook for real-time monitoring.
if [ -f "$PLUGIN_ROOT/scripts/webhook-forward.sh" ]; then
  "$PLUGIN_ROOT/scripts/webhook-forward.sh" "stop_failure" 2>/dev/null || true
fi

exit 0
