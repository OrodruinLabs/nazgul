#!/usr/bin/env bash
set -uo pipefail
# Test: team-teardown.sh — dead-session team sweep (ADR-017 crash-only
# backstop) plus the FEAT-026 deletion-proving regressions for the retired
# per-iteration teardown gate and tt_detect_undismissed().

TEST_NAME="test-team-teardown"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/team-teardown.sh"
source "$REPO_ROOT/scripts/lib/session-tracker.sh"

# --- D1 (deletion-proving, FEAT-026): tt_detect_undismissed no longer exists ---
DECL_RC=0
declare -f tt_detect_undismissed >/dev/null 2>&1 || DECL_RC=$?
assert_eq "deletion: tt_detect_undismissed is gone (declare -f non-zero)" "$DECL_RC" "1"

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

# --- 9: migration v30 -> v33 adds guards.team_sweep* at v31, then removes
# guards.team_teardown at v33 (dead key, TASK-001 deleted its only consumer) ---
setup_temp_dir; setup_nazgul_dir
create_config '.schema_version = 30 | .guards.team_sweep = false'
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/migrate-config.sh" >/dev/null 2>&1
assert_json_field "v30 chain: schema_version reaches terminal 33" "$TEST_DIR/nazgul/config.json" '.schema_version' "33"
assert_eq "v33: guards.team_teardown removed (was at default true)" \
  "$(jq -r '.guards | has("team_teardown")' "$TEST_DIR/nazgul/config.json")" "false"
assert_json_field "v31: explicit team_sweep=false preserved through v33" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep' "false"
assert_json_field "v31: min_age default 24 preserved through v33" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep_min_age_hours' "24"
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

# --- D2 (deletion-proving, FEAT-026): a stop-hook iteration run against the
# old "would-be-leaked" fixture (dispatch manifest on disk + teammate still
# listed as a team member) emits a prompt with neither TEAM TEARDOWN nor
# DISPATCH WITHHELD — there is nothing left to detect or withhold on ---
setup_gate_fixture
run_hook
assert_exit_code "deletion: loop still continues" "$HOOK_EC" 2
assert_not_contains "deletion: no TEAM TEARDOWN in prompt" "$HOOK_OUTPUT" "TEAM TEARDOWN"
assert_not_contains "deletion: no DISPATCH WITHHELD in prompt" "$HOOK_OUTPUT" "DISPATCH WITHHELD"
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

# --- 14: dead + attributed -> swept (both dirs), logged with a reason
# (TASK-006 AC: a future false sweep must be diagnosable from telemetry) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "old-team" "dead-lead-1111"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_contains "sweep: reported" "$OUT" "old-team"
assert_dir_not_exists "sweep: team dir gone" "$TEST_DIR/teams/old-team"
assert_dir_not_exists "sweep: tasks dir gone" "$TEST_DIR/team-tasks/old-team"
assert_file_exists "sweep: logged" "$TEST_DIR/nazgul/logs/team-sweep.jsonl"
assert_eq "sweep: reason recorded on the swept record" \
  "$(jq -r '.reason' "$TEST_DIR/nazgul/logs/team-sweep.jsonl")" "no_lock_no_fresh_transcript"
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

# --- 28 (TASK-006): current session's own team, identified ONLY by NAME FORM
# (session-<first 8 chars of cur_sid>) with an unrelated leadSessionId, no
# lock, no transcript — the exact production shape from
# nazgul/inbox/team-sweep-kills-live-session-team-file.md. Kept, and the
# sweep still returns 0 (fail-open contract preserved) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
CUR_SID="29ebbe09-4aff-4dfc-b566-e9c9cd41f359"
make_owned_team "session-29ebbe09" "unrelated-dead-lead"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "$CUR_SID" 24)
RC=$?
assert_eq "name-form exclusion: sweep still returns 0" "$RC" "0"
assert_dir_exists "name-form exclusion: own team kept (no lock, no transcript)" "$TEST_DIR/teams/session-29ebbe09"
assert_not_contains "name-form exclusion: not reported as swept" "$OUT" "session-29ebbe09"
teardown_temp_dir

report_results
