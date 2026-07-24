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

# --- 2: delivered + member ABSENT -> manifest self-healed (deleted), nothing emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001"   # no reviewer member
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "dismissed: nothing emitted" "$OUT" ""
assert_file_not_exists "dismissed: manifest self-healed" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 3: team dir gone (session-exit cleanup) -> manifest self-healed ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "gone-team"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "gone team: nothing emitted" "$OUT" ""
assert_file_not_exists "gone team: manifest deleted" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
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

# --- 9: migration v30 -> v31 adds guards keys, preserves explicit values ---
setup_temp_dir; setup_nazgul_dir
create_config '.schema_version = 30 | .guards.team_sweep = false'
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/migrate-config.sh" >/dev/null 2>&1
assert_json_field "v31: schema bumped" "$TEST_DIR/nazgul/config.json" '.schema_version' "31"
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

# --- 15: live session lock -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "live-team" "live-lead-2222"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{}' > "$TEST_DIR/nazgul/sessions/live-lead-2222.lock"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "lock: team kept" "$TEST_DIR/teams/live-team"
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

report_results
