#!/usr/bin/env bash
set -euo pipefail

# Nazgul heartbeat tick engine (FEAT-008). Gates on automation.heartbeat.enabled,
# enforces the two unconditional hard stops (reused from parallel-batch.sh,
# independent of enabled/mode incl. yolo), triages the inbox, and enforces the
# concurrency guard. On actionable+clear it atomically archives the picked item
# (the archive move IS the claim) then auto-starts it — archive-then-start so a
# crash between the two leaves the inbox consistent: the item never reappears
# in inbox_list once archived, so a re-run can't repick or double-start it.
# Appends one decision record per tick to nazgul/logs/heartbeat-<date>.jsonl.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"

PROJECT_ROOT="$(resolve_project_root)"
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
# shellcheck source=lib/parallel-batch.sh
source "$SCRIPT_DIR/lib/parallel-batch.sh"
# shellcheck source=lib/session-tracker.sh
source "$SCRIPT_DIR/lib/session-tracker.sh"
# shellcheck source=lib/inbox-provider.sh
source "$SCRIPT_DIR/lib/inbox-provider.sh"
# shellcheck source=lib/heartbeat-triage.sh
source "$SCRIPT_DIR/lib/heartbeat-triage.sh"
# shellcheck source=lib/connector-github.sh
source "$SCRIPT_DIR/lib/connector-github.sh"
# shellcheck source=lib/stack-utils.sh
source "$SCRIPT_DIR/lib/stack-utils.sh"

# Degrade to a safe no-op when Nazgul is uninitialized, matching stop-hook.sh.
[ -f "$CONFIG" ] || exit 0

# MF-039: atomic concurrency claim, first action after the degrade gate and
# ahead of count_active_sessions (which stays a secondary, non-primary check).
# `mkdir` is atomic at the filesystem level, so two overlapping ticks race on
# the mkdir itself rather than a stale `ls` read. Held for the tick's whole
# lifetime (including the blocking _hb_start call) via `trap ... EXIT`.
HB_LOCK_DIR="$NAZGUL_DIR/.heartbeat.lock"
HB_LOCK_STALE=$(jq -r '.automation.heartbeat.lock_stale_seconds // 300' "$CONFIG" 2>/dev/null) || HB_LOCK_STALE=300
case "$HB_LOCK_STALE" in ''|*[!0-9]*) HB_LOCK_STALE=300 ;; esac

if [ -d "$HB_LOCK_DIR" ]; then
  HB_LOCK_NOW=$(date +%s)
  HB_LOCK_MTIME=$(stat -c %Y "$HB_LOCK_DIR" 2>/dev/null || stat -f %m "$HB_LOCK_DIR" 2>/dev/null || echo "$HB_LOCK_NOW")
  case "$HB_LOCK_MTIME" in ''|*[!0-9]*) HB_LOCK_MTIME="$HB_LOCK_NOW" ;; esac
  if [ $((HB_LOCK_NOW - HB_LOCK_MTIME)) -gt "$HB_LOCK_STALE" ]; then
    # Age alone can't tell a crashed tick from a live long one — the dir mtime
    # never advances while _hb_start runs. Reclaim only when the recorded
    # owner is provably dead; a missing/garbled pid file (torn write) falls
    # back to the age check alone.
    HB_LOCK_PID=$(cat "$HB_LOCK_DIR/pid" 2>/dev/null || echo "")
    case "$HB_LOCK_PID" in *[!0-9]*) HB_LOCK_PID="" ;; esac
    if [ -z "$HB_LOCK_PID" ] || ! kill -0 "$HB_LOCK_PID" 2>/dev/null; then
      rm -f "$HB_LOCK_DIR/pid" 2>/dev/null || true
      rmdir "$HB_LOCK_DIR" 2>/dev/null || true
    fi
  fi
fi

# Lock held (and not stale) -> another tick owns this cycle; never a second loop.
mkdir "$HB_LOCK_DIR" 2>/dev/null || exit 0
echo "$$" > "$HB_LOCK_DIR/pid" 2>/dev/null || true
trap 'rm -f "$HB_LOCK_DIR/pid" 2>/dev/null; rmdir "$HB_LOCK_DIR" 2>/dev/null || true' EXIT

TICK="hb-$(date -u +%s)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
LOG_DIR="$NAZGUL_DIR/logs"
# Derive the log file's date from $TS itself, not a second `date` call — a
# fresh call here could cross UTC midnight after $TS was captured, filing a
# record's `ts` under a different day's file than its own timestamp claims.
LOG_FILE="$LOG_DIR/heartbeat-${TS%%T*}.jsonl"

ENABLED=$(jq -r '.automation.heartbeat.enabled // false' "$CONFIG" 2>/dev/null || echo false)
[ "$ENABLED" = "true" ] && ENABLED_BOOL=true || ENABLED_BOOL=false

# Why the FEAT-027 stack pre-steps did or did not run this tick — carried on
# every decision record as `stack_skipped` (null when they ran, or when stacking
# is simply disabled). A pre-step that skips silently is indistinguishable from
# one that had nothing to do, which is how the whole unattended half of stacking
# could be dead in production with every log line looking normal.
STACK_SKIP_REASON=""

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
    --arg stack_skipped "$STACK_SKIP_REASON" \
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
      archived_to: (if $archived_to == "" then null else $archived_to end),
      stack_skipped: (if $stack_skipped == "" then null else $stack_skipped end)
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
# passed as a single argv argument (data, never eval'd/shell-interpolated). An
# EMPTY objective means "no override" — the real path then omits the quoted
# objective span entirely (bare `/nazgul:start $mode_flag $par_flag`), and the
# injectable path calls NAZGUL_HEARTBEAT_START_CMD with NO argv at all, so a
# recording stub can assert "received no objective" the same way in both.
# Used for a stack-rework pick (see the rework-handoff branch below): Stack
# Rework Routing (skills/start/SKILL.md) re-scans the live inbox itself and
# must see the still-live item, not a synthesized new-objective string.
# Defaults to the real `/nazgul:start` invocation, mode/parallel flags taken
# from automation.heartbeat.auto_start.{mode,parallel} (default yolo/true).
_hb_start() {
  local objective="$1"
  if [ -n "${NAZGUL_HEARTBEAT_START_CMD:-}" ]; then
    if [ -z "$objective" ]; then
      "$NAZGUL_HEARTBEAT_START_CMD"
    else
      "$NAZGUL_HEARTBEAT_START_CMD" "$objective"
    fi
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

    if [ -z "$objective" ]; then
      (cd "$PROJECT_ROOT" && claude -p "/nazgul:start $mode_flag $par_flag")
      return
    fi

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

# _hb_poll_feat_id <prev> -> bounded-retry poll (mirrors _cgh_gh_retry's
# backoff) of nazgul/config.json's feat_id until it differs from <prev>, for
# the MF-038 write-back: _hb_start's claude -p call returns before or after
# the new session's own feat_id write is visible depending on timing, and a
# stale pre-existing feat_id must never be mistaken for the new one. Empty
# output + non-zero on exhaustion.
_hb_poll_feat_id() {
  local prev="${1:-}" attempts="${NAZGUL_HB_FEATID_ATTEMPTS:-3}" delay="${NAZGUL_HB_FEATID_DELAY:-1}" i val
  for i in $(seq 1 "$attempts"); do
    val=$(jq -r '.feat_id // empty' "$CONFIG" 2>/dev/null) || val=""
    if [ -n "$val" ] && [ "$val" != "$prev" ]; then
      printf '%s' "$val"
      return 0
    fi
    if [ "$i" -lt "$attempts" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return 1
}

# Hard stops — reused from parallel-batch.sh, unconditional: independent of
# automation.heartbeat.enabled and of mode (including yolo).
if ! HALT_OUT=$(execution_should_halt "$NAZGUL_DIR" 2>/dev/null); then
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

# _hb_own_session_id -> the session id whose nazgul/sessions/ lock belongs to
# THIS tick, or "" when none can be resolved.
#
# Empirically (TASK-013, probed on Claude Code 2.x/macOS): CLAUDE_SESSION_ID —
# the name session-context.sh:38 and stop-hook.sh:32 fall back to — is NOT set in
# a skill's bash environment at all. CLAUDE_CODE_SESSION_ID IS set, but inside a
# subagent it holds the CHILD's id, not the id SessionStart registered, so it is
# only trustworthy when it names a lock that actually exists. The one identifier
# guaranteed to match the lock is the one SessionStart itself persisted:
# session-context.sh:49 writes the resolved id to nazgul/.session_id immediately
# before register_session uses it for the lock filename. So: honor an explicit
# NAZGUL_SESSION_ID (what skills/heartbeat/SKILL.md passes), then the two env
# names, then the persisted file — and use the first candidate that names a real
# lock. A candidate that names no lock means this tick holds no lock, which is
# equally answerable: exclude nothing.
_hb_own_session_id() {
  local cand sanitized
  for cand in "${NAZGUL_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}" "${CLAUDE_CODE_SESSION_ID:-}" \
              "$( [ -s "$NAZGUL_DIR/.session_id" ] && cat "$NAZGUL_DIR/.session_id" 2>/dev/null )"; do
    [ -n "$cand" ] || continue
    sanitized=$(printf '%s' "$cand" | tr -c 'A-Za-z0-9_-' '_')
    # Check BOTH filename forms, as team-teardown.sh:70-77 does: session-tracker.sh's
    # _sanitize_session_id pipes through echo, so real locks are <id>_.lock.
    if [ -f "$NAZGUL_DIR/sessions/${sanitized}.lock" ] || \
       [ -f "$NAZGUL_DIR/sessions/${sanitized}_.lock" ]; then
      printf '%s' "$sanitized"
      return 0
    fi
  done
  return 1
}

# _hb_other_session_count -> active session locks NOT belonging to this tick.
# Prints the count; returns 1 (with the raw count still printed) when locks
# exist but none of them could be attributed to this tick — the caller must
# treat that as ambiguity to report, never as "no other sessions".
_hb_other_session_count() {
  local total
  total=$(count_active_sessions "$NAZGUL_DIR/sessions")
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  [ "$total" -eq 0 ] && { printf '0'; return 0; }
  if _hb_own_session_id >/dev/null; then
    printf '%s' "$((total - 1))"
    return 0
  fi
  printf '%s' "$total"
  return 1
}

# FEAT-027 stack continuation, pre-triage: reconcile any newly-merged layer
# and file rework items for CHANGES_REQUESTED PRs so THIS tick's triage below
# can pick them. Own session check — the concurrency guard below sits AFTER
# triage and can't protect this: a rebase must never run under a live session
# (serialization doctrine). That guard counted the tick's OWN SessionStart lock,
# so on the documented `claude -p /nazgul:heartbeat` firing path it was never
# once satisfied and this entire block was dead; the exclusion above is what
# makes the sanctioned path the tested path.
#
# The CAP is computed whether or not the reconcile/detect half could run: it
# reads only the registry, so a halted stack or missing tooling must not silently
# un-cap new-objective auto-starts. The actual skip decision waits until the
# picked item's type is known (a rework fix on an existing layer is never
# blocked by the cap).
STACK_CAP_REACHED=false
STACK_STATE=$(stack_available "$CONFIG" 2>/dev/null || true)
if [ "$STACK_STATE" != "disabled" ]; then
  STACK_OTHER_SESSIONS=$(_hb_other_session_count) && STACK_SESSIONS_KNOWN=true || STACK_SESSIONS_KNOWN=false

  if [ "$STACK_STATE" = "ready" ] && [ "$STACK_SESSIONS_KNOWN" != "true" ]; then
    STACK_SKIP_REASON="stack_skipped_session_ambiguity"
    echo "heartbeat: $STACK_OTHER_SESSIONS session lock(s) exist and none could be attributed to this tick — skipping the stack pre-steps rather than rebasing under a possibly-live session." >&2
  elif [ "$STACK_STATE" = "ready" ] && [ "$STACK_OTHER_SESSIONS" -gt 0 ]; then
    STACK_SKIP_REASON="stack_active_session"
  elif [ "$STACK_STATE" = "ready" ]; then
    stack_reconcile "$CONFIG" || STACK_SKIP_REASON="stack_reconcile_failed"
    stack_detect_changes_requested "$CONFIG" || STACK_SKIP_REASON="stack_detect_failed"
  else
    case "$STACK_STATE" in
      halted)  STACK_SKIP_REASON="stack_halted" ;;
      missing) STACK_SKIP_REASON="stack_tooling_missing" ;;
      invalid) STACK_SKIP_REASON="stack_config_invalid" ;;
      *)       STACK_SKIP_REASON="stack_not_ready:$STACK_STATE" ;;
    esac
    echo "heartbeat: stacking is enabled but $STACK_STATE — reconcile/rework detection skipped this tick ($STACK_SKIP_REASON); the unmerged cap is still enforced below." >&2
  fi

  STACK_MAX_UNMERGED=$(jq -r '.execution.stacking.max_unmerged // 3' "$CONFIG" 2>/dev/null) || STACK_MAX_UNMERGED=3
  case "$STACK_MAX_UNMERGED" in ''|*[!0-9]*) STACK_MAX_UNMERGED=3 ;; esac
  if STACK_UNMERGED=$(stack_unmerged_count "$CONFIG" 2>/dev/null); then
    case "$STACK_UNMERGED" in ''|*[!0-9]*) STACK_UNMERGED=0 ;; esac
    [ "$STACK_UNMERGED" -ge "$STACK_MAX_UNMERGED" ] && STACK_CAP_REACHED=true
  else
    # Unreadable registry: fail CLOSED. Counting it as 0 would lift the cap
    # exactly when the registry is least trustworthy.
    STACK_CAP_REACHED=true
    [ -n "$STACK_SKIP_REASON" ] || STACK_SKIP_REASON="stack_registry_unreadable"
    echo "heartbeat: stack registry could not be read — treating the unmerged cap as REACHED (fail-closed)." >&2
  fi
fi

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

# Exclude this tick's SessionStart lock so the sanctioned `claude -p` path stays reachable.
# Unattributable locks still count in full and gate concurrent starts.
SESSION_COUNT=$(_hb_other_session_count) || true
if [ "$SESSION_COUNT" -gt 0 ]; then
  OBJECTIVE=$(_hb_objective "$INBOX_DIR" "$PICKED")
  _hb_emit skipped active_session "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" true
  exit 0
fi

# Type is needed by both the cap gate below and the rework-handoff
# special-case further down, so it's resolved once here.
PICKED_TYPE=$(inbox_get "$INBOX_DIR" "$PICKED" 2>/dev/null | jq -r '.type // empty') || PICKED_TYPE=""

# Cap gate: the cap bounds NEW layers, not fixes to open ones — a picked
# stack-rework item is never blocked here even when the cap is reached.
if [ "$STACK_CAP_REACHED" = "true" ] && [ "$PICKED_TYPE" != "stack-rework" ]; then
  OBJECTIVE=$(_hb_objective "$INBOX_DIR" "$PICKED")
  _hb_emit skipped stack_cap_reached "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false
  exit 0
fi

OBJECTIVE=$(_hb_objective "$INBOX_DIR" "$PICKED")

# Rework handoff: Stack Rework Routing (skills/start/SKILL.md) is the ONLY
# claimant of a stack-rework item — it re-scans the LIVE inbox itself and
# performs its own archive-as-claim + checkout + patch flow. inbox_list
# structurally excludes archive/, so if this generic block archived the item
# first (as it does for every other type below), the routing's scan would
# find nothing, REWORK_ID would stay empty, and the tick would fall through
# to a bogus New Objective Override built from the rework's title text
# (GROUP-4 Blocking Issue 1, adversarially confirmed). Skip the archive here
# and invoke /nazgul:start with NO objective override so the routing finds
# the item exactly as it expects.
if [ "$PICKED_TYPE" = "stack-rework" ]; then
  START_OK=true
  _hb_start "" || START_OK=false
  if [ "$START_OK" = "true" ]; then
    _hb_emit started rework_handoff "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false true
  else
    _hb_emit started start_command_failed "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false false
  fi
  exit 0
fi

# Archive-then-start: the archive move is the atomic claim. A crash here
# before start leaves the item archived (not lost, not re-pickable) — a
# re-run degrades to nothing_actionable/a different candidate, never a
# double-start of this one.
if inbox_archive "$INBOX_DIR" "$PICKED"; then
  ARCHIVED_TO="$INBOX_REL/archive/$PICKED"
  PRE_FEAT_ID=$(jq -r '.feat_id // empty' "$CONFIG" 2>/dev/null) || PRE_FEAT_ID=""
  START_OK=true
  _hb_start "$OBJECTIVE" || START_OK=false
  if [ "$START_OK" = "true" ] && [ "$INBOX_PROVIDER" = "github" ]; then
    # MF-038: thread the picked issue# through to the real local id the
    # auto-started session resolved, so push_status/push_pr can later match it.
    NEW_FEAT_ID=$(_hb_poll_feat_id "$PRE_FEAT_ID") || NEW_FEAT_ID=""
    [ -n "$NEW_FEAT_ID" ] && connector_github_map_local_id "$CONFIG" "$PICKED" "$NEW_FEAT_ID"
  fi
  if [ "$START_OK" = "true" ]; then
    _hb_emit started "" "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false true "$ARCHIVED_TO"
  else
    # MF-044: the candidate is already archived (the claim happened), so it
    # will never be re-picked even though the start command itself failed —
    # previously that meant a silent, permanent drop with only a dated JSONL
    # log line nothing monitors. Relocate it to a visibly distinct
    # nazgul/inbox/failed/ so an operator (or a future status/heartbeat pass)
    # can actually find and requeue it. Only the "file" provider has a real
    # on-disk archive path to move; github's "archive" is a label edit with
    # nothing to relocate, so it keeps the log-line-only signal it already
    # had. A failed relocation (e.g. permissions) leaves ARCHIVED_TO pointing
    # at the archive/ path it's actually still sitting in, so the log record
    # never claims a move that didn't happen.
    if [ "$INBOX_PROVIDER" = "file" ]; then
      FAILED_DIR="$INBOX_DIR/failed"
      mkdir -p "$FAILED_DIR" 2>/dev/null || true
      # Collision-safe: a same-named candidate that failed before must not have
      # its prior failed payload clobbered — uniquify with a timestamp suffix.
      FAILED_NAME="$PICKED"
      [ -e "$FAILED_DIR/$FAILED_NAME" ] && FAILED_NAME="$PICKED.$(date +%s).$$"
      if mv -f "$INBOX_DIR/archive/$PICKED" "$FAILED_DIR/$FAILED_NAME" 2>/dev/null; then
        ARCHIVED_TO="$INBOX_REL/failed/$FAILED_NAME"
      fi
    fi
    _hb_emit started start_command_failed "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false false "$ARCHIVED_TO"
  fi
else
  _hb_emit skipped archive_failed "$OBJECTIVE" "$SEEN_COUNT" "$TRIAGED_JSON" "$PICKED" false
fi
exit 0
