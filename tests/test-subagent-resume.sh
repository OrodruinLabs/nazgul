#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-subagent-resume"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# write_dispatch_manifest: builds a real, production-shaped .dispatch.json
# fixture so a reviewer's unit resolves, same helper review-gate itself calls.
source "$REPO_ROOT/scripts/lib/review-provenance.sh"

echo "=== $TEST_NAME ==="

HOOK="$REPO_ROOT/scripts/subagent-stop.sh"

# Real subagent-transcript-shaped JSONL: tool-use turn, tool-result turn, final text-only turn.
_write_fixture_transcript() {
  local path="$1" final_text="$2"
  mkdir -p "$(dirname "$path")"
  {
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working..."}]}}\n'
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}\n'
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file contents"}]}}\n'
    jq -cn --arg t "$final_text" \
      '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'
  } > "$path"
}

_hook_input() {
  local transcript="$1" agent_type="$2" agent_id="$3" stop_hook_active="${4:-false}"
  jq -cn --arg tp "$transcript" --arg at "$agent_type" --arg aid "$agent_id" --argjson sha "$stop_hook_active" \
    '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:$at,agent_id:$aid,stop_hook_active:$sha}'
}

_config_with_resume() {
  local resume="$1"
  printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-024","guards":{"subagent_resume":%s}}' \
    "$resume" > "$TEST_DIR/nazgul/config.json"
}

# --- Test 1 (kill-switch true, default): first detection on a reviewer with
# empty final_text -> exit 2, a block-decision JSON on stdout, attempt
# recorded, event carries action:resumed ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-1.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-1")

OUT=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-1.log"); rc=$?
assert_exit_code "first detection: exit 2" "$rc" "2"
assert_contains "first detection: stdout is a block decision" "$OUT" '"decision":"block"'
assert_contains "first detection: directive tells reviewer to lead with verdict:" "$OUT" "verdict:"
assert_file_contains "first detection: directive also delivered on stderr" \
  "$TEST_DIR/stderr-1.log" "verdict:"
DECISION_REASON=$(printf '%s' "$OUT" | jq -r '.reason')
assert_eq "first detection: decision JSON parses (reason non-empty)" "$([ -n "$DECISION_REASON" ] && echo yes || echo no)" "yes"
assert_file_contains "first detection: subagent_empty_return emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_empty_return"'
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "first detection: action is resumed" "$event_line" '"action":"resumed"'
attempts_count=$(find "$TEST_DIR/nazgul/logs/.resume-attempts" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "first detection: exactly one attempts file recorded" "$attempts_count" "1"
teardown_temp_dir

# --- Test 2: second detection, SAME agent_id -> exit 2 again, action:resumed,
# cap (2) not yet exceeded ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-2.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-2")

printf '%s' "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>&1; rc1=$?
OUT2=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-2.log"); rc2=$?
assert_exit_code "first call (setup): exit 2" "$rc1" "2"
assert_exit_code "second detection same agent: exit 2 (cap 2)" "$rc2" "2"
assert_contains "second detection: stdout is a block decision" "$OUT2" '"decision":"block"'
assert_file_contains "second detection: directive also delivered on stderr" \
  "$TEST_DIR/stderr-2.log" "final deliverable"
last_event=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)
assert_contains "second detection: action is resumed" "$last_event" '"action":"resumed"'
teardown_temp_dir

# --- Test 3: third detection, SAME agent_id -> cap exhausted, exit 0,
# action:exhausted, loud named diagnostic on stderr ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-3.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-3")

printf '%s' "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>&1
printf '%s' "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>&1
OUT3=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-3.log"); rc3=$?
assert_exit_code "third detection: exit 0 (cap exhausted)" "$rc3" "0"
assert_not_contains "third detection: no block decision on stdout" "$OUT3" '"decision":"block"'
assert_file_contains "third detection: resume_exhausted named diagnostic on stderr" \
  "$TEST_DIR/stderr-3.log" "resume_exhausted"
last_event=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)
assert_contains "third detection: action is exhausted" "$last_event" '"action":"exhausted"'
teardown_temp_dir

# --- Test 4: kill-switch false -> resume mechanism fully inert, detection
# still emits the event, action:detected_only, exit 0 ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "false"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-4.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-4")

OUT4=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1); rc4=$?
assert_exit_code "kill-switch false: exit 0" "$rc4" "0"
assert_not_contains "kill-switch false: no block decision on stdout" "$OUT4" '"decision":"block"'
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "kill-switch false: subagent_empty_return still emitted" "$event_line" '"event":"subagent_empty_return"'
assert_contains "kill-switch false: action is detected_only" "$event_line" '"action":"detected_only"'
assert_dir_not_exists "kill-switch false: no attempts dir created" "$TEST_DIR/nazgul/logs/.resume-attempts"
teardown_temp_dir

# --- Test 5: non-reviewer empty-text dispatch gets the SAME resume flow as a
# reviewer (universal detection, TASK-004) -> exit 2, action:resumed ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-5.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "architect" "dispatch-5")

OUT5=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1); rc5=$?
assert_exit_code "non-reviewer empty-text: exit 2" "$rc5" "2"
assert_contains "non-reviewer empty-text: stdout is a block decision" "$OUT5" '"decision":"block"'
assert_contains "non-reviewer empty-text: directive delivered (merged stdout+stderr)" "$OUT5" "final deliverable"
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "non-reviewer empty-text: action is resumed" "$event_line" '"action":"resumed"'
teardown_temp_dir

# --- Test 6: an error in the resume path (attempts dir unwritable — a plain
# file blocks the mkdir -p) degrades to exit 0 with a stderr notice, fail-open
# per RULES.md, never a silent pass and never an unbounded block ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
mkdir -p "$TEST_DIR/nazgul/logs"
: > "$TEST_DIR/nazgul/logs/.resume-attempts"

TRANSCRIPT="$TEST_DIR/transcripts/agent-6.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-6")

OUT6=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-6.log"); rc6=$?
assert_exit_code "resume-path error: exit 0 (fail-open)" "$rc6" "0"
assert_not_contains "resume-path error: no block decision on stdout" "$OUT6" '"decision":"block"'
assert_file_contains "resume-path error: stderr notice" \
  "$TEST_DIR/stderr-6.log" "subagent-stop: resume path failed"
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "resume-path error: action is detected_only (degraded)" "$event_line" '"action":"detected_only"'
teardown_temp_dir

# --- Test 7: stop_hook_active re-entry -> the harness's own re-entry signal
# is respected: never block again on it, even with cap headroom left ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-7.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-7" "true")

OUT7=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-7.log"); rc7=$?
assert_exit_code "stop_hook_active re-entry: exit 0, not blocked" "$rc7" "0"
assert_not_contains "stop_hook_active re-entry: no block decision on stdout" "$OUT7" '"decision":"block"'
assert_file_contains "stop_hook_active re-entry: announced on stderr" \
  "$TEST_DIR/stderr-7.log" "stop_hook_active re-entry"
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "stop_hook_active re-entry: action is detected_only" "$event_line" '"action":"detected_only"'
teardown_temp_dir

# --- Test 8 (code-reviewer board concern, confidence 35): a reviewer with
# non-empty final_text lacking a verdict line, unit resolved, resume enabled
# -> blocks (exit 2) BEFORE the receipt-hashing tail ever runs, so NO receipt
# is appended -- a real behavior change from the resume-disabled case (where
# the same fixture's receipt IS appended, per test-subagent-stop.sh's
# no-verdict-line test) that was previously unasserted ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-024" "1" -- code-reviewer >/dev/null
NO_VERDICT_TEXT="I'm satisfied. Let me do a final check..."
TRANSCRIPT="$TEST_DIR/transcripts/agent-8.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "$NO_VERDICT_TEXT"
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "dispatch-8")

OUT8=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1); rc8=$?
assert_exit_code "no-verdict-line + resume enabled: exit 2" "$rc8" "2"
assert_contains "no-verdict-line + resume enabled: stdout is a block decision" "$OUT8" '"decision":"block"'
assert_contains "no-verdict-line + resume enabled: directive delivered (merged stdout+stderr)" "$OUT8" "verdict:"
event_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "no-verdict-line + resume enabled: reason is no_verdict_line" "$event_line" '"reason":"no_verdict_line"'
assert_contains "no-verdict-line + resume enabled: action is resumed" "$event_line" '"action":"resumed"'
assert_file_not_exists "no-verdict-line + resume enabled: no receipt appended" \
  "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 9 (architect concern 40 / security concern 60): no agent_id and no
# session_id in hook input -> the dispatch-key fallback to bare $AGENT is
# announced on stderr, not silent, and the resume still proceeds normally ---
setup_temp_dir
setup_nazgul_dir
_config_with_resume "true"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-9.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
HOOK_INPUT=$(_hook_input "$TRANSCRIPT" "code-reviewer" "")

OUT9=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>"$TEST_DIR/stderr-9.log"); rc9=$?
assert_exit_code "bare-agent fallback: exit 2 (resume still works)" "$rc9" "2"
assert_contains "bare-agent fallback: stdout is a block decision" "$OUT9" '"decision":"block"'
assert_file_contains "bare-agent fallback: announced on stderr" \
  "$TEST_DIR/stderr-9.log" "resume key fallback to bare agent name"
teardown_temp_dir

# --- Test 10: bash -n + shellcheck on subagent-stop.sh (belt-and-suspenders;
# also asserted by test-subagent-stop.sh) ---
bash -n "$HOOK" 2>/dev/null \
  && _pass "bash -n clean: subagent-stop.sh" \
  || _fail "bash -n clean: subagent-stop.sh" "syntax error detected"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$HOOK" 2>/dev/null \
    && _pass "shellcheck clean: subagent-stop.sh" \
    || _fail "shellcheck clean: subagent-stop.sh" "shellcheck warnings found"
else
  _skip "shellcheck skipped (not installed): subagent-stop.sh"
fi

report_results
