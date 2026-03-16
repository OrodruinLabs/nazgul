#!/usr/bin/env bash
set -euo pipefail

# Hydra TeammateIdle — detects stuck Agent Teams teammates
# Fires when a teammate has been idle too long.
# Logs the event and marks tasks BLOCKED after repeated idle detections.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# If Hydra not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

IDLE_FILE="$HYDRA_DIR/.teammate_idle"
IDLE_THRESHOLD=2  # Mark as BLOCKED after this many consecutive idle checks

# Read current idle count
if [ -f "$IDLE_FILE" ]; then
  IDLE_COUNT=$(jq -r '.consecutive_idle // 0' "$IDLE_FILE" 2>/dev/null || echo "0")
else
  IDLE_COUNT=0
fi

NEW_COUNT=$((IDLE_COUNT + 1))

# Write updated count
printf '{"consecutive_idle": %d, "last_idle": "%s"}\n' \
  "$NEW_COUNT" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$IDLE_FILE"

# Log to iterations.jsonl
LOG_DIR="$HYDRA_DIR/logs"
mkdir -p "$LOG_DIR"
printf '{"event":"teammate_idle","timestamp":"%s","consecutive":%d}\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$NEW_COUNT" >> "$LOG_DIR/iterations.jsonl"

# After threshold, warn about stuck teammate
if [ "$NEW_COUNT" -ge "$IDLE_THRESHOLD" ]; then
  echo "WARNING: A teammate has been idle for $NEW_COUNT consecutive checks. It may be stuck." >&2
  echo "Consider checking Agent Teams status or restarting the stuck teammate." >&2

  # Forward webhook if enabled
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
  if [ -f "$PLUGIN_ROOT/scripts/webhook-forward.sh" ]; then
    "$PLUGIN_ROOT/scripts/webhook-forward.sh" "teammate_idle" 2>/dev/null || true
  fi
fi
