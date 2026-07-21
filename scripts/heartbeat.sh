#!/usr/bin/env bash
set -euo pipefail

# Nazgul heartbeat tick engine (FEAT-008). Gates on automation.heartbeat.enabled,
# enforces the two unconditional hard stops (reused from conductor-gates.sh,
# independent of enabled/mode incl. yolo), triages the inbox, and enforces the
# concurrency guard. On actionable+clear it atomically archives the picked item
# (the archive move IS the claim) then auto-starts it — archive-then-start so a
# crash between the two leaves the inbox consistent: the item never reappears
# in inbox_list once archived, so a re-run can't repick or double-start it.
# Appends one decision record per tick to nazgul/logs/heartbeat-<date>.jsonl.

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/conductor-gates.sh
source "$SCRIPT_DIR/lib/conductor-gates.sh"
# shellcheck source=lib/session-tracker.sh
source "$SCRIPT_DIR/lib/session-tracker.sh"
# shellcheck source=lib/inbox-provider.sh
source "$SCRIPT_DIR/lib/inbox-provider.sh"
# shellcheck source=lib/heartbeat-triage.sh
source "$SCRIPT_DIR/lib/heartbeat-triage.sh"

# Degrade to a safe no-op when Nazgul is uninitialized, matching stop-hook.sh.
[ -f "$CONFIG" ] || exit 0

TICK="hb-$(date -u +%s)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
LOG_DIR="$NAZGUL_DIR/logs"
# Derive the log file's date from $TS itself, not a second `date` call — a
# fresh call here could cross UTC midnight after $TS was captured, filing a
# record's `ts` under a different day's file than its own timestamp claims.
LOG_FILE="$LOG_DIR/heartbeat-${TS%%T*}.jsonl"

ENABLED=$(jq -r '.automation.heartbeat.enabled // false' "$CONFIG" 2>/dev/null || echo false)
[ "$ENABLED" = "true" ] && ENABLED_BOOL=true || ENABLED_BOOL=false

# _hb_emit <decision> <reason> <objective> <seen> <triaged_json> <picked>
#          <session_active> [started] [archived_to]
# Appends one decision record. `started`/`archived_to` default to false/null
# for the no-op gate paths; the actionable+clear path passes the real outcome.
_hb_emit() {
  local decision="$1" reason="$2" objective="$3" seen="$4" triaged_json="$5" picked="$6" session_active="$7"
  local started="${8:-false}" archived_to="${9:-}"
  mkdir -p "$LOG_DIR"
  jq -cn \
    --arg ts "$TS" \
    --arg tick "$TICK" \
    --argjson enabled "$ENABLED_BOOL" \
    --argjson seen "$seen" \
    --argjson triaged "$triaged_json" \
    --arg picked "$picked" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg objective "$objective" \
    --argjson session_active "$session_active" \
    --argjson started "$started" \
    --arg archived_to "$archived_to" \
    '{
      ts: $ts,
      tick: $tick,
      enabled: $enabled,
      seen: $seen,
      triaged: $triaged,
      picked: (if $picked == "" then null else $picked end),
      decision: $decision,
      reason: (if $reason == "" then null else $reason end),
      objective: (if $objective == "" then null else $objective end),
      session_active: $session_active,
      started: $started,
      archived_to: (if $archived_to == "" then null else $archived_to end)
    }' >> "$LOG_FILE"
}

# _hb_objective <inbox_dir> <id> -> the candidate's title, or the body's first
# line when title is absent, or "" when neither is available.
_hb_objective() {
  local inbox_dir="$1" id="$2" json
  json=$(inbox_get "$inbox_dir" "$id" 2>/dev/null) || { echo ""; return 0; }
  printf '%s' "$json" | jq -r '
    if (.title // "") != "" then (.title | split("\n")[0])
    elif (.body // "") != "" then (.body | split("\n")[0])
    else "" end'
}

# _hb_start <objective> -> invoke the auto-start command with the objective
# passed as a single argv argument (data, never eval'd/shell-interpolated).
# Injectable via NAZGUL_HEARTBEAT_START_CMD (called as `$CMD "$objective"`) for
# testing; defaults to the real `/nazgul:start` invocation, mode/parallel flags
# taken from automation.heartbeat.auto_start.{mode,parallel} (default yolo/true).
_hb_start() {
  local objective="$1"
  if [ -n "${NAZGUL_HEARTBEAT_START_CMD:-}" ]; then
    "$NAZGUL_HEARTBEAT_START_CMD" "$objective"
  else
    local mode par mode_flag=""
    mode=$(jq -r '.automation.heartbeat.auto_start.mode // "yolo"' "$CONFIG" 2>/dev/null || echo "yolo")
    # NOT `// true`: jq's `//` treats an explicit `false` as absent, which would
    # silently override a user's explicit auto_start.parallel=false opt-out.
    par=$(jq -r '(.automation.heartbeat.auto_start | if has("parallel") then .parallel else true end)' "$CONFIG" 2>/dev/null || echo "true")
    case "$mode" in
      afk) mode_flag="--afk" ;;
      hitl) mode_flag="--hitl" ;;
      *) mode_flag="--yolo" ;;
    esac
    local par_flag=""
    [ "$par" = "true" ] && par_flag="--parallel"

    # apply-start-flags.sh later strips this span with a literal-quote-paired
    # sed scan that is inherently line-bounded, so a raw `"` or an embedded
    # newline in the objective would close/split the span early and expose
    # the rest as bare flag tokens. Neutralize both before interpolation.
    local safe_objective="${objective//\"/\'}"
    safe_objective="${safe_objective//$'\n'/ }"
    safe_objective="${safe_objective//$'\r'/ }"
    (cd "$PROJECT_ROOT" && claude -p "/nazgul:start \"$safe_objective\" $mode_flag $par_flag")
  fi
}

# Hard stops — reused from conductor-gates.sh, unconditional: independent of
# automation.heartbeat.enabled and of mode (including yolo).
if ! HALT_OUT=$(conductor_should_halt "$NAZGUL_DIR" 2>/dev/null); then
  REASON=""
  printf '%s\n' "$HALT_OUT" | grep -q '^BLOCKED_TASK' && REASON="blocked_task"
  if printf '%s\n' "$HALT_OUT" | grep -qE '^SECURITY_REJECTION|^SECURITY_REVIEWS_UNREADABLE'; then
    [ -n "$REASON" ] && REASON="${REASON},security_rejection" || REASON="security_rejection"
  fi
  _hb_emit hard_stop "$REASON" "" 0 "[]" "" false
  exit 0
fi

if [ "$ENABLED_BOOL" != "true" ]; then
  _hb_emit disabled "" "" 0 "[]" "" false
  exit 0
fi

# "file"/"github" route through the provider-aware seam below; a disabled or
# unhealthy github connector degrades there to an empty list. Others fail closed.
INBOX_PROVIDER=$(jq -r '.automation.heartbeat.inbox.provider // "file"' "$CONFIG" 2>/dev/null || echo "file")
case "$INBOX_PROVIDER" in
  file | github) : ;;
  *)
    _hb_emit skipped "unsupported_provider:$INBOX_PROVIDER" "" 0 "[]" "" false
    exit 0
    ;;
esac

INBOX_REL=$(jq -r '.automation.heartbeat.inbox.dir // "nazgul/inbox"' "$CONFIG" 2>/dev/null || echo "nazgul/inbox")
INBOX_DIR="$PROJECT_ROOT/$INBOX_REL"

SEEN_LIST=$(inbox_list "$INBOX_DIR" 2>/dev/null || true)
if [ -n "$SEEN_LIST" ]; then
  # grep -c exits 1 on zero matches (e.g. a provider ever yielding a blank
  # entry) — under set -e that would abort the tick with no decision record
  # at all. `|| true` keeps the correct "0" grep already prints on stdout
  # without letting its exit status kill the script.
  SEEN_COUNT=$(printf '%s\n' "$SEEN_LIST" | grep -c '.' || true)
  TRIAGED_JSON=$(printf '%s\n' "$SEEN_LIST" | jq -R . | jq -s .)
else
  SEEN_COUNT=0
  TRIAGED_JSON="[]"
fi

PICKED=""
if [ "$SEEN_COUNT" -gt 0 ]; then
  PICKED=$(heartbeat_pick "$INBOX_DIR" 2>/dev/null) || PICKED=""
fi

if [ -z "$PICKED" ]; then
  _hb_emit nothing_actionable "" "" "$SEEN_COUNT" "$TRIAGED_JSON" "" false
  exit 0
fi

# Concurrency guard — never a second loop.
SESSION_COUNT=$(count_active_sessions "$NAZGUL_DIR/sessions")
if [ "$SESSION_COUNT" -gt 0 ]; then
  OBJECTIVE=$(_hb_objective "$INBOX_DIR" "$PICKED")
  _hb_emit skipped active_session "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" true
  exit 0
fi

OBJECTIVE=$(_hb_objective "$INBOX_DIR" "$PICKED")

# Archive-then-start: the archive move is the atomic claim. A crash here
# before start leaves the item archived (not lost, not re-pickable) — a
# re-run degrades to nothing_actionable/a different candidate, never a
# double-start of this one.
if inbox_archive "$INBOX_DIR" "$PICKED"; then
  ARCHIVED_TO="$INBOX_REL/archive/$PICKED"
  START_OK=true
  _hb_start "$OBJECTIVE" || START_OK=false
  if [ "$START_OK" = "true" ]; then
    _hb_emit started "" "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false true "$ARCHIVED_TO"
  else
    # The candidate is already archived (the claim happened), so it will never
    # be re-picked even though the start command itself failed — record the
    # real outcome rather than a decision record that always claims success.
    _hb_emit started start_command_failed "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false false "$ARCHIVED_TO"
  fi
else
  _hb_emit skipped archive_failed "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false
fi
exit 0
