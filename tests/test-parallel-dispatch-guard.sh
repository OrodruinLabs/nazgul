#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-parallel-dispatch-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/parallel-dispatch-guard.sh"

# Build an isolated execution.parallel fixture.
setup() {
  setup_temp_dir
  mkdir -p "$TEST_DIR/nazgul/tasks"
  create_config '.execution.parallel = true | .agents.reviewers = ["architect-reviewer", "code-reviewer", "security-reviewer", "qa-reviewer"]'
  WORK="$TEST_DIR"
}
teardown() { teardown_temp_dir; }

# helper: build the Agent PreToolUse envelope and return the guard's exit code
guard_ec() { # <subagent_type> <run_in_background> <prompt>
  local ec=0
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# helper: same envelope, but return the guard's stderr instead of its exit code
guard_stderr() { # <subagent_type> <run_in_background> <prompt>
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" 2>&1 >/dev/null || true
}

# helper for caller-aware/name/missing-field cases the fixed-shape helper above
# cannot represent.
guard_json_ec() { # <json envelope>
  local ec=0
  printf '%s\n' "$1" | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

reviewer_envelope() { # <subagent> <bg-json-or-missing> <name-or-empty> <caller-or-empty>
  local subagent="$1" bg="$2" name="$3" caller="$4"
  jq -nc --arg t "$subagent" --arg bg "$bg" --arg n "$name" --arg caller "$caller" '
    {tool_name:"Agent",tool_input:{subagent_type:$t,prompt:"Review the unit"}}
    | if $bg != "missing" then .tool_input.run_in_background = ($bg == "true") else . end
    | if $n != "" then .tool_input.name = $n else . end
    | if $caller != "" then .agent_type = $caller else . end
  '
}

setup
create_task_file TASK-001 READY
create_task_file_with_commits TASK-002 DONE "abc1234"
create_task_file_with_commits TASK-003 IMPLEMENTED "def5678"

# 1. background implementer dispatch of a not-yet-done unit -> ALLOW (exit 0):
#    background/concurrent dispatch from the main session is now the intended
#    mechanism for the parallel execution option, not a violation (was Rule 1
#    in the old conductor guard; deleted by design).
assert_eq "background implementer allowed (intended mechanism)" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0"
# 2. synchronous first dispatch of a READY unit -> ALLOW (exit 0)
assert_eq "sync first dispatch allowed" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-001")" "0"
# 3. re-dispatch of a DONE unit -> DENY (exit 2)
assert_eq "re-dispatch of DONE unit denied" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
# 4. non-work-unit background dispatch (e.g. general-purpose) -> ALLOW
assert_eq "non-unit background allowed" "$(guard_ec "general-purpose" true "helper")" "0"
# 5. review-gate dispatch for an IMPLEMENTED unit -> ALLOW (the legitimate next step, not a re-dispatch)
assert_eq "review-gate on IMPLEMENTED unit allowed" "$(guard_ec "nazgul:review-gate" false "NAZGUL_UNIT: TASK-003")" "0"
# 6. review-gate re-dispatch for a DONE unit -> DENY (already reviewed, wasted work)
assert_eq "review-gate on DONE unit denied" "$(guard_ec "nazgul:review-gate" false "NAZGUL_UNIT: TASK-002")" "2"
# 7. implementer re-dispatch for an IMPLEMENTED unit -> DENY (implementation already done)
assert_eq "implementer on IMPLEMENTED unit denied" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-003")" "2"
# 8. no NAZGUL_UNIT line for a non-work-unit agent -> ALLOW
assert_eq "no unit line, non-work-unit agent allowed" "$(guard_ec "general-purpose" false "no unit here")" "0"
# 9. unknown task id -> ALLOW (no manifest to check status against)
assert_eq "unknown task id allowed" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-999")" "0"
teardown

# 10. off: execution.parallel=false -> no-redispatch rule is a no-op for
# non-review work units. Reviewer routing is tested separately below and is
# intentionally independent of parallel mode.
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq '.execution.parallel = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "parallel=false no-op" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 11. kill-switch: dispatch_guard=false -> ALLOW everything (operator safety valve)
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq '.execution.enforce.dispatch_guard = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch allows DONE re-dispatch" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 12. kill-switch absent (default) -> still ENFORCES (deny DONE re-dispatch)
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq 'del(.execution.enforce.dispatch_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent kill-switch still enforces" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
teardown

# 13-16. MF-053 fail-closed: a present-but-unparseable config.json must BLOCK
# re-dispatch of an already-DONE unit (not silently no-op as "parallel=false"
# would), across every torn/corrupt shape a real write can leave on disk. A
# genuinely absent config is the one case that still safely no-ops (case 17).
for shape in corrupt empty truncated; do
  setup
  create_task_file_with_commits TASK-002 DONE "abc1234"
  case "$shape" in
    corrupt)   printf 'not json' > "$WORK/nazgul/config.json" ;;
    empty)     : > "$WORK/nazgul/config.json" ;;
    truncated) printf '{"execution": {"para' > "$WORK/nazgul/config.json" ;;
  esac
  assert_eq "$shape config fails closed (DONE re-dispatch blocked)" \
    "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
  assert_contains "$shape config diagnostic names the reason" \
    "$(guard_stderr "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" \
    "config.json is unreadable"
  teardown
done

# 17. missing config.json entirely -> still safely no-ops (ALLOW), distinct
# from "present but unparseable" above.
setup
rm -f "$WORK/nazgul/config.json"
create_task_file_with_commits TASK-002 DONE "abc1234"
assert_eq "missing config still no-ops (allowed)" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 18-25. FEAT-029: configured reviewers are foreground, unnamed one-shot
# calls by mechanism, not prose. This rule applies even when task parallelism
# is disabled. An omitted run_in_background is its own case (#205, below).
setup
jq '.execution.parallel = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"

assert_eq "reviewer explicit foreground allowed outside parallel mode" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' false '' '')")" "0"
assert_eq "reviewer background denied outside parallel mode" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' true '' '')")" "2"
assert_eq "named reviewer denied even when foreground" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' false 'review-1' '')")" "2"
assert_eq "nested synchronous-only reviewer may omit unavailable background field" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' missing '' 'nazgul:review-gate')")" "0"
assert_eq "nested reviewer explicit background still denied" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' true '' 'nazgul:review-gate')")" "2"
assert_eq "nested named reviewer still denied" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' missing 'review-1' 'nazgul:review-gate')")" "2"
assert_eq "unconfigured helper remains outside reviewer route" \
  "$(guard_json_ec "$(reviewer_envelope 'general-purpose' true 'helper' '')")" "0"

# The foreground requirement is typed, not truthy: only boolean false satisfies
# it, so a string/null/number in that field is a denial and not an accidental pass.
for bg_raw in '"false"' '"true"' 'null' '0' '1'; do
  assert_eq "non-boolean run_in_background ${bg_raw} denied on the reviewer route" \
    "$(guard_json_ec "$(jq -nc --argjson bg "$bg_raw" \
      '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:code-reviewer",prompt:"Review the unit",run_in_background:$bg}}')")" \
    "2"
  assert_eq "non-boolean run_in_background ${bg_raw} denied from a nested caller too" \
    "$(guard_json_ec "$(jq -nc --argjson bg "$bg_raw" \
      '{tool_name:"Agent",agent_type:"nazgul:review-gate",tool_input:{subagent_type:"nazgul:code-reviewer",prompt:"Review the unit",run_in_background:$bg}}')")" \
    "2"
done

jq '.agents.reviewers += ["performance-reviewer"]' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "project-generated configured reviewer uses the same route" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:performance-reviewer' true '' '')")" "2"
teardown

# #205: a host whose Agent schema lacks run_in_background makes the field
# unsupplyable — "missing" is now ALLOW + named event, never a block.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]'
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"security-reviewer",prompt:"review it"}}')
EC=0
OUT=$(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$GUARD" 2>&1) || EC=$?
assert_exit_code "#205: reviewer dispatch with run_in_background ABSENT is allowed" "$EC" 0
assert_contains "#205: the allow announces itself on stderr" "$OUT" "run_in_background absent"
EVENT_LINE=$(grep 'dispatch_guard_background_unverifiable' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | head -1 || true)
assert_contains "#205: dispatch_guard_background_unverifiable event emitted" "$EVENT_LINE" "security-reviewer"
teardown_temp_dir

# Explicit true is STILL blocked (unchanged contract).
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]'
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"security-reviewer",prompt:"review",run_in_background:true}}')
EC=0
(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$GUARD" >/dev/null 2>&1) || EC=$?
assert_exit_code "#205: explicit run_in_background:true still blocked" "$EC" 2
teardown_temp_dir

# 27. The existing dispatch-guard kill switch remains the emergency valve for
# both reviewer-route and completed-unit enforcement.
setup
jq '.execution.parallel = false | .execution.enforce.dispatch_guard = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch disables reviewer route enforcement" \
  "$(guard_json_ec "$(reviewer_envelope 'nazgul:code-reviewer' true 'review-1' '')")" "0"
teardown

# 28-40. The producers must request the route the hook enforces and keep the
# canonical returned-text contract. Keep these assertions beside the real
# envelope tests so one red run covers both sides of the seam.
REVIEW_GATE_TEXT=$(cat "$REPO_ROOT/agents/review-gate.md")
PATCH_SKILL=$(cat "$REPO_ROOT/skills/patch/SKILL.md")
assert_contains "review-gate makes reviewer foreground choice explicit" \
  "$REVIEW_GATE_TEXT" '`run_in_background: false`'
assert_contains "review-gate forbids reviewer Agent names" \
  "$REVIEW_GATE_TEXT" 'Do not set the Agent `name` field'
assert_not_contains "review-gate no longer calls reviewers teammates" \
  "$REVIEW_GATE_TEXT" 'Reviewer teammates'
assert_not_contains "review-gate no longer says reviewers write review files" \
  "$REVIEW_GATE_TEXT" 'Write their review to nazgul/reviews/'
assert_not_contains "patch is not a background fork" "$PATCH_SKILL" 'context: fork'
assert_contains "patch main-session driver can ask interactive questions" "$PATCH_SKILL" 'AskUserQuestion'
assert_contains "patch resolves shared UI guidance from plugin root" \
  "$PATCH_SKILL" '${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md'
assert_contains "patch dispatches its reviewer explicitly foreground" "$PATCH_SKILL" '`run_in_background: false`'
assert_contains "patch forbids reviewer Agent names" "$PATCH_SKILL" 'Do not set the Agent `name` field'
assert_contains "patch uses the canonical returned verdict enum" \
  "$PATCH_SKILL" 'APPROVE | CHANGES_REQUESTED | UNVERIFIED'
assert_contains "patch makes the orchestrator persist returned review text" \
  "$PATCH_SKILL" 'persist the returned review text'
assert_contains "patch handles empty or malformed reviewer returns" "$PATCH_SKILL" 'empty or malformed'
assert_not_contains "patch no longer expects obsolete APPROVED token" "$PATCH_SKILL" 'If APPROVED:'

report_results
