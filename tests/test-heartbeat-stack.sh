#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes/log content explicitly

# Test: scripts/heartbeat.sh — FEAT-027 TASK-008 continuation wiring: the
# pre-triage stack steps (reconcile, detect, cap gate) slotted between the
# provider gate and inbox_list, guarded by their own count_active_sessions
# check. `gh` is a PATH-shim mock; NO network.
TEST_NAME="test-heartbeat-stack"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Fake `gh` placed first on PATH. Its dir is a colon-free mktemp (NOT under
# $TEST_DIR, whose name carries a literal ":" that would corrupt PATH parsing).
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh for heartbeat-stack wiring tests: extension/auth always report
# ready unless overridden; `pr view` returns one canned JSON object carrying
# every field either stack_reconcile or stack_detect_changes_requested reads,
# regardless of the --json field list requested (mirrors real gh's behavior
# of returning whatever fields exist on the object).
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    action="${1:-}"; shift || true
    case "$action" in
      list) printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  auth)
    action="${1:-}"; shift || true
    case "$action" in
      status) [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    action="${1:-}"; shift || true
    case "$action" in
      view)
        ident="${1:-}"; shift || true
        payload="${NAZGUL_TEST_GH_PR_VIEW_JSON:-}"
        [ -n "$payload" ] || payload='{"number":1,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}'
        printf '%s\n' "$payload"
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stack)
    action="${1:-}"; shift || true
    case "$action" in
      sync) echo "Stack synced."; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

latest_log() {
  ls -1t "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | head -1
}

events_file() { printf '%s' "$TEST_DIR/nazgul/logs/events.jsonl"; }

event_count() {
  local type="$1" f
  f=$(events_file)
  [ -f "$f" ] || { echo 0; return; }
  grep -c "\"event\":\"$type\"" "$f" 2>/dev/null || echo 0
}

open_layer_config() {
  # open_layer_config <pr> [max_unmerged]
  local pr="$1" max="${2:-3}"
  jq --arg pr "$pr" --argjson max "$max" '
    .execution.stacking.enabled = true
    | .execution.stacking.max_unmerged = $max
    | .stack.layers = [{feat_id:"FEAT-700", branch:"feat/FEAT-700-x", pr:$pr, base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
  ' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
    && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
}

# --- Test 1: stack steps invoked when ready+idle — reconcile+detect run,
# the rework item filed this tick is picked and started ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/700"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":700,"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_A","state":"CHANGES_REQUESTED","body":"needs a fix"}]}'
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "invoked: detect filed the rework item" "$(event_count stack_rework_filed)" "1"
assert_eq "invoked: decision is started" "$(jq -r '.decision' "$LOG")" "started"
assert_eq "invoked: picked the freshly-filed rework item" "$(jq -r '.picked' "$LOG")" "stack-rework-pr700-REVIEW_A.md"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 2: stacking disabled -> byte-identical behavior, no stack function
# ran (no rework filed, registry untouched, normal nothing_actionable) ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
jq '.execution.stacking.enabled = false
  | .stack.layers = [{feat_id:"FEAT-701", branch:"feat/FEAT-701-x", pr:"https://github.com/o/r/pull/701", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":701,"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_B","state":"CHANGES_REQUESTED","body":"needs a fix"}]}'
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "disabled: no rework item filed" "$(event_count stack_rework_filed)" "0"
assert_eq "disabled: registry layer state unchanged" \
  "$(jq -r '.stack.layers[0].state' "$TEST_DIR/nazgul/config.json")" "open"
assert_eq "disabled: decision falls through to nothing_actionable" "$(jq -r '.decision' "$LOG")" "nothing_actionable"
assert_eq "disabled: inbox has no stack-rework file" \
  "$(find "$TEST_DIR/nazgul/inbox" -name 'stack-rework-*' 2>/dev/null | wc -l | tr -d ' ')" "0"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 3: cap reached (unmerged >= max_unmerged) + a non-rework candidate
# -> skipped/stack_cap_reached, no auto-start, candidate stays in the inbox ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/702" 1
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:5, type:"feature"}' \
  > "$TEST_DIR/nazgul/inbox/cand.json"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":702,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}'
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "cap reached: decision is skipped" "$(jq -r '.decision' "$LOG")" "skipped"
assert_eq "cap reached: reason is stack_cap_reached" "$(jq -r '.reason' "$LOG")" "stack_cap_reached"
assert_eq "cap reached: picked candidate recorded" "$(jq -r '.picked' "$LOG")" "cand.json"
assert_eq "cap reached: started is false" "$(jq -r '.started' "$LOG")" "false"
assert_eq "cap reached: session_active is false" "$(jq -r '.session_active' "$LOG")" "false"
assert_file_exists "cap reached: candidate NOT archived, stays in inbox" "$TEST_DIR/nazgul/inbox/cand.json"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 4: below cap -> proceeds to normal auto-start ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/703" 3
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:5, type:"feature"}' \
  > "$TEST_DIR/nazgul/inbox/cand.json"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":703,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}'
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "below cap: decision is started" "$(jq -r '.decision' "$LOG")" "started"
assert_eq "below cap: reason is null" "$(jq -r '.reason' "$LOG")" "null"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 5: rework item startable AT cap — the cap bounds new layers, not
# fixes to existing ones ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/704" 1
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":704,"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_C","state":"CHANGES_REQUESTED","body":"needs a fix"}]}'
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "rework at cap: decision is started, not skipped" "$(jq -r '.decision' "$LOG")" "started"
assert_eq "rework at cap: picked the rework item" "$(jq -r '.picked' "$LOG")" "stack-rework-pr704-REVIEW_C.md"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 6: active session -> stack steps skipped (no rework filed, registry
# untouched), normal flow proceeds to the existing post-triage session guard ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/705"
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:5, type:"feature"}' \
  > "$TEST_DIR/nazgul/inbox/cand.json"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{"pid":"1","session":"s1","started":"now"}' > "$TEST_DIR/nazgul/sessions/s1.lock"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":705,"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_D","state":"CHANGES_REQUESTED","body":"needs a fix"}]}'
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_eq "active session: no rework item filed (stack steps skipped)" "$(event_count stack_rework_filed)" "0"
assert_eq "active session: registry layer state unchanged" \
  "$(jq -r '.stack.layers[0].state' "$TEST_DIR/nazgul/config.json")" "open"
assert_eq "active session: normal flow proceeds to skipped/active_session" \
  "$(jq -r '.decision' "$LOG")" "skipped"
assert_eq "active session: reason is active_session, not stack_cap_reached" \
  "$(jq -r '.reason' "$LOG")" "active_session"
assert_eq "active session: picked the pre-existing (non-stack) candidate" \
  "$(jq -r '.picked' "$LOG")" "cand.json"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

# --- Test 7: rework handoff seam — a picked stack-rework item must stay LIVE
# in the inbox (not archived by this generic block) and the start command
# must receive NO objective override, so Stack Rework Routing's own live-inbox
# scan (skills/start/SKILL.md) can find and claim it itself. Uses a RECORDING
# NAZGUL_HEARTBEAT_START_CMD stub (captures argv) instead of "true" — Tests
# 1/5 mock away this exact seam and would not have caught the archive-before-
# routing-scan race (GROUP-4 Blocking Issue 1, adversarially confirmed 95). ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
open_layer_config "https://github.com/o/r/pull/706" 3
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":706,"state":"OPEN","mergedAt":null,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_E","state":"CHANGES_REQUESTED","body":"needs a fix"}]}'
REWORK_ID="stack-rework-pr706-REVIEW_E.md"
CAPTURE_FILE="$TEST_DIR/start-cmd-capture.txt"
cat > "$FAKEBIN/record-start-cmd" << CAPEOF
#!/usr/bin/env bash
{ printf 'argc=%s\n' "\$#"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done; } > "$CAPTURE_FILE"
CAPEOF
chmod +x "$FAKEBIN/record-start-cmd"
NAZGUL_HEARTBEAT_START_CMD="$FAKEBIN/record-start-cmd" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_file_exists "rework handoff: picked item stays LIVE in the inbox (not archived)" "$TEST_DIR/nazgul/inbox/$REWORK_ID"
assert_eq "rework handoff: start command received NO objective argument" "$(head -1 "$CAPTURE_FILE" 2>/dev/null)" "argc=0"
assert_eq "rework handoff: decision is started" "$(jq -r '.decision' "$LOG")" "started"
assert_eq "rework handoff: reason reflects rework handoff" "$(jq -r '.reason' "$LOG")" "rework_handoff"
assert_eq "rework handoff: archived_to is null (heartbeat did not claim it)" "$(jq -r '.archived_to' "$LOG")" "null"
rm -f "$FAKEBIN/record-start-cmd"
unset NAZGUL_TEST_GH_PR_VIEW_JSON
teardown_temp_dir

rm -rf "$FAKEBIN"
report_results
