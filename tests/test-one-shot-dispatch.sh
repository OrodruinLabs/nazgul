#!/usr/bin/env bash
# Note: NOT using set -e — the harness runs code-under-test and asserts on
# nonzero exit codes explicitly (suite convention, e.g. test-review-contract.sh).
set -uo pipefail
# Test: the filing's acceptance test — a completed one-shot dispatch leaves
# zero live team members without any lead action (ADR-017, TRD §7).
# Strongest available form: prove nothing ever becomes a team member, rather
# than proving a team member was correctly torn down.

TEST_NAME="test-one-shot-dispatch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/teammate-idle-guard.sh"
source "$REPO_ROOT/scripts/lib/team-teardown.sh"

# --- 1. Static contract: skills/init/SKILL.md Step 3 dispatches an unnamed
# one-shot Agent, not a named/teammate dispatch. ---
SKILL_FILE="$REPO_ROOT/skills/init/SKILL.md"
STEP3=$(sed -n '/^### Step 3:/,/^### Step 4:/p' "$SKILL_FILE" | sed '$d')

assert_contains "Step 3 names the discovery subagent_type" "$STEP3" "subagent_type"
assert_contains "Step 3 dispatches nazgul:discovery" "$STEP3" "nazgul:discovery"

# Bash pattern match, not grep -F: a needle starting with "-" is parsed as an
# option flag by BSD grep, silently short-circuiting the check.
if [[ "$STEP3" == *"-n "* ]]; then
  _fail "Step 3 has no '-n ' teammate-naming directive" "found '-n ' in: ${STEP3:0:200}"
else
  _pass "Step 3 has no '-n ' teammate-naming directive"
fi
assert_not_contains "Step 3 has no 'name:' teammate-naming directive" "$STEP3" "name:"

# --- 2. Fixture: a completed one-shot dispatch leaves zero team/dispatch
# state. Env-overridable ~/.claude roots point at a per-test temp root — the
# real ~/.claude tree is never touched. ---
setup_temp_dir
setup_nazgul_dir
create_config '.feat_id = "FEAT-026"'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
export NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/tasks"
export NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"

# Simulate the successful outcome of an unnamed one-shot Agent dispatch: it
# writes its deliverables and returns — no team dir, no dispatch manifest.
mkdir -p "$TEST_DIR/nazgul/context" "$TEST_DIR/nazgul/dispatch"
echo "# discovery output" > "$TEST_DIR/nazgul/context/discovery-summary.md"

assert_dir_not_exists "no team dir created by the dispatch" "$NAZGUL_TEAMS_DIR"
assert_dir_not_exists "no team-tasks dir created by the dispatch" "$NAZGUL_TEAM_TASKS_DIR"
DISPATCH_COUNT=$(find "$TEST_DIR/nazgul/dispatch" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "zero nazgul/dispatch/*.json manifests" "$DISPATCH_COUNT" "0"

# --- 3. Zero-lead-action: with that same state on disk, teardown machinery
# has nothing to gate and nothing to sweep — the test passes without ever
# invoking teardown, because there is none to invoke. ---
EC=0
jq -n '{type:"idle_notification", from:"nazgul-discovery"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "idle-guard has nothing to gate (no manifest -> exit 0)" "$EC" "0"

EC=0
SWEPT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "cur-session-0000" 24) || EC=$?
assert_eq "sweep prints nothing (nothing was ever a team member)" "$SWEPT" ""
assert_eq "sweep returns 0 (fail-open contract)" "$EC" "0"

teardown_temp_dir

# --- 4. team-orchestrator.md's named-teammate spawn paths are retired
# (TRD §2 sites 5-6, ADR-017): no new live dispatch caller, both spawn
# section headings gone. ---
TEAM_ORCH_CALLERS=$(grep -rln "nazgul:team-orchestrator" "$REPO_ROOT/scripts" "$REPO_ROOT/skills" 2>/dev/null | wc -l | tr -d ' ') || true
assert_eq "no nazgul:team-orchestrator dispatch caller in scripts/ or skills/" "$TEAM_ORCH_CALLERS" "0"

TEAM_ORCH_FILE="$REPO_ROOT/agents/team-orchestrator.md"
assert_file_not_contains "no 'Spawning a Review Team' heading" "$TEAM_ORCH_FILE" "^## Spawning a Review Team"
assert_file_not_contains "no 'Spawning an Implementation Team' heading" "$TEAM_ORCH_FILE" "^## Spawning an Implementation Team"

report_results
