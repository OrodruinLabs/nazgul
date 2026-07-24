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

report_results
