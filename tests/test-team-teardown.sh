#!/usr/bin/env bash
set -uo pipefail
# Test: team-teardown.sh — teammate dismissal detection, self-heal, sweep
# (spec docs/superpowers/specs/2026-07-24-team-teardown-design.md)

TEST_NAME="test-team-teardown"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/team-teardown.sh"
source "$REPO_ROOT/scripts/lib/session-tracker.sh"

# Helper: fake team dir with members. Usage: make_team <name> <member>...
make_team() {
  local team="$1"; shift
  mkdir -p "$TEST_DIR/teams/$team"
  local members="[]"
  local m
  for m in "$@"; do
    members=$(jq -c --arg n "$m" '. + [{name:$n, cwd:"'"$TEST_DIR"'"}]' <<< "$members")
  done
  jq -n --arg name "$team" --argjson m "$members" \
    '{name:$name, leadSessionId:"dead-lead-0000", members:([{name:"team-lead", cwd:"'"$TEST_DIR"'"}] + $m)}' \
    > "$TEST_DIR/teams/$team/config.json"
}

# Helper: dispatch manifest. Usage: make_manifest <name> <report_path> [team] [spawned_epoch] [teardown_blocks]
make_manifest() {
  mkdir -p "$TEST_DIR/nazgul/dispatch"
  jq -n --arg t "$1" --arg rp "$2" --arg team "${3:-}" --argjson sae "${4:-0}" --argjson tb "${5:-0}" \
    '{teammate:$t, report_path:$rp, feat_id:"default", spawned_at_epoch:$sae, blocks:0, teardown_blocks:$tb}
     + (if $team != "" then {team:$team} else {} end)' \
    > "$TEST_DIR/nazgul/dispatch/$1.json"
}

export NAZGUL_TEAMS_DIR=""  # set per test after TEST_DIR exists

# --- 1: delivered + still a member -> emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_contains "leaked teammate emitted" "$OUT" "rv-code-TASK-001"
assert_eq "one leaked line" "$(printf '%s' "$OUT" | grep -c .)" "1"
teardown_temp_dir

# --- 1b: exact output contract line (4 fields, teardown_blocks passthrough) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001" 0 2
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
EXPECTED=$(printf 'rv-code-TASK-001\tnazgul/reviews/TASK-001/code.md\t%s/nazgul-review-TASK-001\t2' "$TEST_DIR/teams")
assert_eq "contract: exact TSV line" "$OUT" "$EXPECTED"
teardown_temp_dir

# --- 2b: corrupt team config -> ambiguous, manifest KEPT (fail open) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
mkdir -p "$TEST_DIR/teams/broken-team"
echo '{not json' > "$TEST_DIR/teams/broken-team/config.json"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "broken-team"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "corrupt config: nothing emitted" "$OUT" ""
assert_file_exists "corrupt config: manifest kept (fail open)" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 2: delivered + member ABSENT -> manifest self-healed (deleted), HEALED line emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001"   # no reviewer member
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "dismissed: HEALED line emitted" "$OUT" "$(printf 'HEALED\trv-code-TASK-001')"
assert_file_not_exists "dismissed: manifest self-healed" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 2c: member absent, report NOT delivered -> ambiguous (teammate may still
# be live), manifest KEPT, nothing emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001"   # no reviewer member
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "member absent + undelivered: nothing emitted" "$OUT" ""
assert_file_exists "member absent + undelivered: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 2d: team config .members is a non-array (valid JSON, wrong shape) ->
# ambiguous, manifest KEPT, nothing emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
mkdir -p "$TEST_DIR/teams/odd-members-team"
echo '{"members": "oops"}' > "$TEST_DIR/teams/odd-members-team/config.json"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "odd-members-team"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "non-array members: nothing emitted" "$OUT" ""
assert_file_exists "non-array members: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 3: team dir gone (session-exit cleanup) -> manifest self-healed ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "gone-team"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "gone team: nothing emitted" "$OUT" ""
assert_file_not_exists "gone team: manifest deleted" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 3b: team dir gone, manifest has NO explicit team field (implicit
# session-<id8> fallback), report delivered -> too unreliable to delete ->
# manifest KEPT, nothing emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "impl-TASK-003" "nazgul/tasks/TASK-003.md"   # no team arg -> implicit fallback
mkdir -p "$TEST_DIR/nazgul/tasks"
echo "Status: IMPLEMENTED" > "$TEST_DIR/nazgul/tasks/TASK-003.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "implicit fallback + team gone: nothing emitted" "$OUT" ""
assert_file_exists "implicit fallback + team gone: manifest kept" "$TEST_DIR/nazgul/dispatch/impl-TASK-003.json"
teardown_temp_dir

# --- 4: report NOT delivered -> not leaked (idle guard's domain), manifest kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "undelivered: nothing emitted" "$OUT" ""
assert_file_exists "undelivered: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 5: report predates spawn -> treated as undelivered ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "stale" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
FUTURE=$(( $(date +%s) + 3600 ))
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001" "$FUTURE"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "stale report: nothing emitted" "$OUT" ""
teardown_temp_dir

# --- 6: stale feat_id -> skipped, manifest kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.feat_id = "FEAT-002"'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "stale feat: nothing emitted" "$OUT" ""
assert_file_exists "stale feat: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 7: no team field -> implicit team session-<first 8 of session id> ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "session-sess1234" "impl-TASK-002"
make_manifest "impl-TASK-002" "nazgul/tasks/TASK-002.md"
mkdir -p "$TEST_DIR/nazgul/tasks"
echo "Status: IMPLEMENTED" > "$TEST_DIR/nazgul/tasks/TASK-002.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd-9999")
assert_contains "implicit team resolved" "$OUT" "impl-TASK-002"
teardown_temp_dir

# --- 8: unsafe teammate name in manifest -> skipped (fail open) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
mkdir -p "$TEST_DIR/nazgul/dispatch"
jq -n '{teammate:"../evil", report_path:"r.md", feat_id:"default", spawned_at_epoch:0}' \
  > "$TEST_DIR/nazgul/dispatch/evil.json"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "unsafe name: nothing emitted" "$OUT" ""
teardown_temp_dir

# --- 8b: teammate name containing a space (outside allowlist) -> skipped,
# nothing emitted, manifest kept (fail open) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
mkdir -p "$TEST_DIR/nazgul/dispatch"
jq -n '{teammate:"rv code TASK-001", report_path:"r.md", feat_id:"default", spawned_at_epoch:0}' \
  > "$TEST_DIR/nazgul/dispatch/spacey.json"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "space in name: nothing emitted" "$OUT" ""
assert_file_exists "space in name: manifest kept" "$TEST_DIR/nazgul/dispatch/spacey.json"
teardown_temp_dir

# --- 9: migration v30 -> v31 adds guards keys, preserves explicit values ---
setup_temp_dir; setup_nazgul_dir
create_config '.schema_version = 30 | .guards.team_sweep = false'
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/migrate-config.sh" >/dev/null 2>&1
assert_json_field "v31: schema bumped" "$TEST_DIR/nazgul/config.json" '.schema_version' "32"
assert_json_field "v31: team_teardown default true" "$TEST_DIR/nazgul/config.json" '.guards.team_teardown' "true"
assert_json_field "v31: explicit team_sweep=false preserved" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep' "false"
assert_json_field "v31: min_age default 24" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep_min_age_hours' "24"
teardown_temp_dir

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
run_hook() { HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?; }

# Shared fixture for stop-hook gate tests: initialized nazgul + one leaked teammate
setup_gate_fixture() {  # $1 = extra create_config jq filter (optional)
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  create_config "${1:-.}"
  create_plan
  create_task_file TASK-001 READY none
  export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
  make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
  make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
  mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
  echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
}

# --- 10: leaked teammate -> directive in loop prompt, blocks incremented ---
setup_gate_fixture
run_hook
assert_exit_code "gate: loop continues" "$HOOK_EC" 2
assert_contains "gate: directive injected" "$HOOK_OUTPUT" "TEAM TEARDOWN"
assert_contains "gate: names teammate" "$HOOK_OUTPUT" "rv-code-TASK-001"
assert_json_field "gate: blocks incremented" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" '.teardown_blocks' "1"
assert_not_contains "gate: no new dispatch while pending" "$HOOK_OUTPUT" "DELEGATE:"
assert_contains "gate: dispatch withheld" "$HOOK_OUTPUT" "DISPATCH WITHHELD"
teardown_temp_dir

# --- 11: kill-switch guards.team_teardown=false -> no directive ---
setup_gate_fixture '.guards.team_teardown = false'
run_hook
assert_not_contains "kill-switch: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
teardown_temp_dir

# --- 12: 3 strikes -> escalation (finding raised once), directive stops ---
setup_gate_fixture
tmp=$(mktemp); jq '.teardown_blocks = 3' "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" > "$tmp" \
  && mv "$tmp" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
run_hook
assert_not_contains "escalated: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
assert_not_contains "escalated: dispatch resumes" "$HOOK_OUTPUT" "DISPATCH WITHHELD"
assert_file_exists "escalated: finding raised" "$TEST_DIR/nazgul/logs/findings.jsonl"
assert_json_field "escalated: flag set" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" '.teardown_escalated' "true"
FINDINGS_LINES=$(wc -l < "$TEST_DIR/nazgul/logs/findings.jsonl" | tr -d ' ')
run_hook   # second run must NOT raise a duplicate finding
assert_eq "escalated: finding raised once" "$(wc -l < "$TEST_DIR/nazgul/logs/findings.jsonl" | tr -d ' ')" "$FINDINGS_LINES"
teardown_temp_dir

# --- 13: nothing leaked -> no directive, clean prompt ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
run_hook
assert_not_contains "clean: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
teardown_temp_dir

# Helper: team owned by a given lead session, attributed to TEST_DIR
make_owned_team() {  # <team> <leadSessionId>
  mkdir -p "$TEST_DIR/teams/$1" "$TEST_DIR/team-tasks/$1"
  jq -n --arg name "$1" --arg lead "$2" --arg cwd "$TEST_DIR" \
    '{name:$name, leadSessionId:$lead, members:[{name:"team-lead", cwd:$cwd}]}' \
    > "$TEST_DIR/teams/$1/config.json"
  touch "$TEST_DIR/team-tasks/$1/tasks.json"
}

export NAZGUL_TEAM_TASKS_DIR=""  # set per test
export NAZGUL_PROJECTS_DIR=""

# --- 14: dead + attributed -> swept (both dirs), logged ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "old-team" "dead-lead-1111"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_contains "sweep: reported" "$OUT" "old-team"
assert_dir_not_exists "sweep: team dir gone" "$TEST_DIR/teams/old-team"
assert_dir_not_exists "sweep: tasks dir gone" "$TEST_DIR/team-tasks/old-team"
assert_file_exists "sweep: logged" "$TEST_DIR/nazgul/logs/team-sweep.jsonl"
teardown_temp_dir

# --- 15: live session lock (real production lock filename) -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "live-team" "live-lead-2222"
register_session "live-lead-2222" "$TEST_DIR/nazgul/sessions"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "lock: team kept" "$TEST_DIR/teams/live-team"
teardown_temp_dir

# --- 15b: un-suffixed lock filename form also counts as alive ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "live-team-b" "live-lead-5555"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{}' > "$TEST_DIR/nazgul/sessions/live-lead-5555.lock"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "unsuffixed lock: team kept" "$TEST_DIR/teams/live-team-b"
teardown_temp_dir

# --- 16: fresh transcript -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "fresh-team" "fresh-lead-3333"
mkdir -p "$TEST_DIR/projects/proj-a"
echo '{}' > "$TEST_DIR/projects/proj-a/fresh-lead-3333.jsonl"   # mtime = now
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "fresh transcript: team kept" "$TEST_DIR/teams/fresh-team"
teardown_temp_dir

# --- 17: foreign cwd -> never touched ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
mkdir -p "$TEST_DIR/teams/foreign-team"
jq -n '{name:"foreign-team", leadSessionId:"dead-lead-4444", members:[{name:"team-lead", cwd:"/somewhere/else"}]}' \
  > "$TEST_DIR/teams/foreign-team/config.json"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "foreign: kept" "$TEST_DIR/teams/foreign-team"
teardown_temp_dir

# --- 18: current session's own team -> never touched ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "my-team" "current-sess"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "own team: kept" "$TEST_DIR/teams/my-team"
teardown_temp_dir

# --- 19: no leadSessionId (ambiguous) -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
mkdir -p "$TEST_DIR/teams/odd-team"
jq -n --arg cwd "$TEST_DIR" '{name:"odd-team", members:[{name:"team-lead", cwd:$cwd}]}' \
  > "$TEST_DIR/teams/odd-team/config.json"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "ambiguous: kept" "$TEST_DIR/teams/odd-team"
teardown_temp_dir

# --- 20: report_path contains a literal tab -> unsafe path, treated as not
# delivered -> ambiguous, manifest KEPT, nothing emitted (TSV-safety fix) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
TAB_REPORT="$(printf 'nazgul/reviews/x\ty.md')"
make_manifest "rv-code-TASK-001" "$TAB_REPORT" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "tab in report_path: nothing emitted" "$OUT" ""
assert_file_exists "tab in report_path: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 21: session lock refreshed across continuing runs (ADR-007 Option A) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export CLAUDE_SESSION_ID="lock-lifecycle-test-0001"
LOCK_FILE="$TEST_DIR/nazgul/sessions/$(_sanitize_session_id "$CLAUDE_SESSION_ID").lock"
run_hook
assert_exit_code "lock: continuing run exits 2" "$HOOK_EC" 2
assert_file_exists "lock: present after 1st continuing run" "$LOCK_FILE"
run_hook
assert_exit_code "lock: 2nd continuing run exits 2" "$HOOK_EC" 2
assert_file_exists "lock: still present after refresh (not one-shot)" "$LOCK_FILE"
unset CLAUDE_SESSION_ID
teardown_temp_dir

# --- 21b: lock removed only on a genuinely-ending (exit 0) run ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.paused = true'
create_plan; create_task_file TASK-001 READY none
export CLAUDE_SESSION_ID="lock-lifecycle-test-0002"
LOCK_FILE="$TEST_DIR/nazgul/sessions/$(_sanitize_session_id "$CLAUDE_SESSION_ID").lock"
run_hook
assert_exit_code "lock: genuinely-ending run exits 0" "$HOOK_EC" 0
assert_file_not_exists "lock: removed after genuinely-ending run" "$LOCK_FILE"
unset CLAUDE_SESSION_ID
teardown_temp_dir

# --- 22: guards.team_sweep_min_age_hours=0 floored to 1 -> a fresh transcript
# keeps the team; an unfloored 0 disables the freshness AND-term entirely and
# would sweep it regardless of age ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "floor-team" "floor-lead-7777"
mkdir -p "$TEST_DIR/projects/proj-a"
echo '{}' > "$TEST_DIR/projects/proj-a/floor-lead-7777.jsonl"   # mtime = now
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 0)
assert_dir_exists "floor: min_age_hours=0 clamped to 1, fresh transcript kept" "$TEST_DIR/teams/floor-team"
teardown_temp_dir

# --- 23: leaked_detected fires even in the all-at-3-strikes case where
# directive_injected does NOT fire ---
setup_gate_fixture
tmp=$(mktemp); jq '.teardown_blocks = 3' "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" > "$tmp" \
  && mv "$tmp" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
run_hook
EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "leaked_detected: fires at 3-strikes" "$EVENTS" '"action":"leaked_detected"'
assert_file_contains "leaked_detected: count is 1" "$EVENTS" '"count":1'
assert_file_not_contains "leaked_detected: directive_injected does NOT fire at 3-strikes" "$EVENTS" '"action":"directive_injected"'
teardown_temp_dir

# --- 24: verified_clean fires exactly once on the confirmed-dismissal
# self-heal (member absent + report delivered) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001"   # no reviewer member -> confirmed dismissal
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
run_hook
EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "verified_clean: fires on confirmed dismissal" "$EVENTS" '"action":"verified_clean"'
VC_COUNT=$(grep -c '"action":"verified_clean"' "$EVENTS" 2>/dev/null || echo 0)
assert_eq "verified_clean: fires exactly once" "$VC_COUNT" "1"
assert_file_contains "verified_clean: names the teammate" "$EVENTS" '"teammate":"rv-code-TASK-001"'
# HEALED must not leak into the blocks-increment/escalation consumer path
# (the load-bearing regression the filtering in stop-hook.sh exists to prevent).
assert_file_not_contains "confirmed dismissal: no leaked_detected event" "$EVENTS" '"action":"leaked_detected"'
assert_file_not_exists "confirmed dismissal: manifest self-healed by stop-hook" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
BLOCKS=$(jq -r '.teardown_blocks // 0' "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" 2>/dev/null || echo 0)
assert_eq "confirmed dismissal: teardown_blocks NOT incremented" "$BLOCKS" "0"
teardown_temp_dir

# --- 24b: team-dir-gone self-heal gets NO verified_clean event (session-exit
# cleanup, not a confirmed dismissal) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "gone-team"
run_hook
assert_file_not_contains "team-dir-gone: no verified_clean event" "$TEST_DIR/nazgul/logs/events.jsonl" '"action":"verified_clean"'
teardown_temp_dir

# --- 25: symlink-equivalent cwd (e.g. macOS /tmp vs /private/tmp) is
# correctly attributed and swept (existing test 17's genuinely-foreign-cwd
# control is unaffected — it never resolves through a symlink) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
REAL_DIR="$TEST_DIR/real-project"
mkdir -p "$REAL_DIR"
SYMLINK_DIR="$TEST_DIR/symlinked-project"
ln -s "$REAL_DIR" "$SYMLINK_DIR"
mkdir -p "$TEST_DIR/teams/symlink-team" "$TEST_DIR/team-tasks/symlink-team"
jq -n --arg name "symlink-team" --arg lead "symlink-lead-8888" --arg cwd "$SYMLINK_DIR" \
  '{name:$name, leadSessionId:$lead, members:[{name:"team-lead", cwd:$cwd}]}' \
  > "$TEST_DIR/teams/symlink-team/config.json"
touch "$TEST_DIR/team-tasks/symlink-team/tasks.json"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$REAL_DIR" "current-sess" 24)
assert_contains "symlink cwd: attributed and swept" "$OUT" "symlink-team"
teardown_temp_dir

# --- 26: manifest team field is bare "." -> rejected (fail open), mirrors
# the existing unsafe-teammate-name assertions (tests 8/8b) on the team field ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "."
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "bare-dot team: nothing emitted" "$OUT" ""
assert_file_exists "bare-dot team: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 27: transcript mtime unreadable (both stat forms fail) -> mt="" ->
# fail open, team kept. `stat` is shadowed with a bash function for this test
# only (portable across platforms — chmod on the file alone does not make
# stat() fail on Linux/macOS since it needs no read permission on the target,
# only directory search permission; the acceptance bar is exercising the
# mt="" branch, not any one specific construction method) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "unreadable-mtime-team" "unreadable-lead-6666"
mkdir -p "$TEST_DIR/projects/proj-a"
echo '{}' > "$TEST_DIR/projects/proj-a/unreadable-lead-6666.jsonl"
# shellcheck disable=SC2329 # called indirectly by tt_sweep_orphaned_teams below
stat() { return 1; }
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
unset -f stat
assert_dir_exists "unreadable mtime: team kept (fail open)" "$TEST_DIR/teams/unreadable-mtime-team"
teardown_temp_dir

# --- 28: a teammate literally named "HEALED" is still treated as a genuine
# leak, not misparsed as the self-heal marker (field-count disambiguation:
# marker lines have exactly 2 fields, genuine leak lines exactly 4) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "HEALED"
make_manifest "HEALED" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
run_hook
assert_exit_code "HEALED-named teammate: gate still fires" "$HOOK_EC" 2
assert_contains "HEALED-named teammate: directive names it" "$HOOK_OUTPUT" "HEALED"
assert_json_field "HEALED-named teammate: blocks incremented (treated as leak)" "$TEST_DIR/nazgul/dispatch/HEALED.json" '.teardown_blocks' "1"
teardown_temp_dir

report_results
