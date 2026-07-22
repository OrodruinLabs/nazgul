#!/usr/bin/env bash
set -euo pipefail
# Nazgul Teammate Idle Guard — TeammateIdle hook.
# Enforces the teammate report contract: a Nazgul-dispatched teammate may not
# go idle while its expected report file (recorded in nazgul/dispatch/<name>.json
# by the dispatcher) is missing or empty. Blocks at most 3 times per teammate,
# then fails open with an escalation log line — never deadlocks a team.
# Deliberately fails OPEN on unparseable payloads / unknown teammates (the
# TeammateIdle payload schema is not fully documented; blocking on garbage
# would strand teammates). Exit 0 = allow idle. Exit 2 = block (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
NAZGUL_DIR="$PROJECT_DIR/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
DISPATCH_DIR="$NAZGUL_DIR/dispatch"
LOG_DIR="$NAZGUL_DIR/logs"
LOG_FILE="$LOG_DIR/teammate-idle.jsonl"

# Not a Nazgul project → allow.
[ -f "$CONFIG" ] || exit 0

# Telemetry first: append the raw payload (compacted) regardless of outcome.
# Doubles as ongoing TeammateIdle schema discovery. Never fails the guard.
log_event() { # <status> [detail]
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg st "$1" \
    --arg detail "${2:-}" --argjson payload "$PAYLOAD_JSON" \
    '{ts:$ts, status:$st, detail:$detail, payload:$payload}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Parse payload; unparseable → fail open (log with payload as a string).
if PAYLOAD_JSON=$(printf '%s' "$INPUT" | jq -c '.' 2>/dev/null); then :; else
  PAYLOAD_JSON=$(jq -cn --arg raw "$INPUT" '{unparseable:$raw}')
  log_event "allow" "unparseable payload"
  exit 0
fi

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.teammate_report_guard == null then "true" else (.execution.enforce.teammate_report_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
if [ "$ENFORCE" = "false" ]; then
  log_event "allow" "kill-switch off"
  exit 0
fi

# Resolve teammate name — the payload schema is not fully documented, so try
# every plausible field. No name → fail open.
NAME=$(printf '%s' "$PAYLOAD_JSON" | jq -r '.teammate_name // .teammate // .from // .name // .agent_id // ""' 2>/dev/null || echo "")
if [ -z "$NAME" ]; then
  log_event "allow" "no teammate name in payload"
  exit 0
fi

# NAME comes from the hook payload and is interpolated into a write path — never allow separators or dot-dot.
case "$NAME" in
  */*|*..*) log_event "allow" "unsafe teammate name"; exit 0 ;;
esac

# Manifest lookup — no manifest means not a Nazgul-dispatched teammate.
MANIFEST="$DISPATCH_DIR/$NAME.json"
if [ ! -f "$MANIFEST" ]; then
  log_event "allow" "no dispatch manifest for $NAME"
  exit 0
fi

# Stale manifest (different objective) → allow.
CUR_FEAT=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
MAN_FEAT=$(jq -r '.feat_id // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ -n "$MAN_FEAT" ] && [ "$MAN_FEAT" != "$CUR_FEAT" ]; then
  log_event "allow" "stale feat_id $MAN_FEAT (current $CUR_FEAT)"
  exit 0
fi

REPORT_PATH=$(jq -r '.report_path // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ -z "$REPORT_PATH" ]; then
  log_event "allow" "manifest has no report_path"
  exit 0
fi
# REPORT_PATH comes from the dispatch manifest and is joined onto PROJECT_DIR —
# reject absolute paths and any ".." traversal segment, fail open.
case "$REPORT_PATH" in
  /*|*..*) log_event "allow" "unsafe report_path"; exit 0 ;;
esac
REPORT_ABS="$PROJECT_DIR/$REPORT_PATH"

# Delivered: file exists and is non-empty. mtime >= spawned_at_epoch is checked
# best-effort (BSD/GNU stat); on stat failure existence+non-empty wins (open).
if [ -s "$REPORT_ABS" ]; then
  SPAWNED_EPOCH=$(jq -r '.spawned_at_epoch // 0' "$MANIFEST" 2>/dev/null || echo 0)
  case "$SPAWNED_EPOCH" in ''|*[!0-9]*) SPAWNED_EPOCH=0 ;; esac
  MTIME=$(stat -c %Y "$REPORT_ABS" 2>/dev/null || stat -f %m "$REPORT_ABS" 2>/dev/null || echo "")
  case "$MTIME" in ''|*[!0-9]*) MTIME="" ;; esac
  if [ -z "$MTIME" ] || [ "$MTIME" -ge "$SPAWNED_EPOCH" ]; then
    tmp=$(mktemp)
    if jq '.delivered = true' "$MANIFEST" > "$tmp" 2>/dev/null; then mv "$tmp" "$MANIFEST" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
    log_event "allow" "report delivered at $REPORT_PATH"
    exit 0
  fi
  # File predates spawn: treat as missing (falls through to block/backstop).
fi

# Report missing: block up to 3 times, then fail open with escalation.
BLOCKS=$(jq -r '.blocks // 0' "$MANIFEST" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge 3 ]; then
  log_event "allow" "escalation: $NAME idled 3x without report at $REPORT_PATH — giving up (manual nudge required)"
  exit 0
fi
tmp=$(mktemp)
if jq '.blocks = ((.blocks // 0) + 1)' "$MANIFEST" > "$tmp" 2>/dev/null; then mv "$tmp" "$MANIFEST" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
log_event "block" "report missing at $REPORT_PATH (block $((BLOCKS + 1))/3)"
echo "NAZGUL TEAMMATE REPORT CONTRACT: Your report at ${REPORT_PATH} was not written — your final plain text is invisible to the parent. Write your full report to ${REPORT_PATH} now, then idle." >&2
exit 2
