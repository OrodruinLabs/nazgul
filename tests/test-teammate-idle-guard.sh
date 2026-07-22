#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-teammate-idle-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/teammate-idle-guard.sh"

setup() {
  setup_temp_dir
  mkdir -p "$TEST_DIR/nazgul/dispatch" "$TEST_DIR/nazgul/logs" "$TEST_DIR/nazgul/reviews/TASK-001"
  create_config '.feat_id = "FEAT-013"'
}
teardown() { teardown_temp_dir; }

# helper: write a dispatch manifest
# usage: make_manifest <name> <report_path> <feat_id> <blocks>
make_manifest() {
  jq -n --arg t "$1" --arg rp "$2" --arg f "$3" --argjson b "$4" \
    --arg sa "2026-07-22T00:00:00Z" --argjson sae 0 \
    '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:$b}' \
    > "$TEST_DIR/nazgul/dispatch/$1.json"
}

# helper: run guard with a payload naming teammate $1; echo exit code
guard_ec() {
  local ec=0
  jq -n --arg n "$1" '{type:"idle_notification", from:$n, idleReason:"available"}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup

# 1. report file present and non-empty -> ALLOW, manifest marked delivered
make_manifest "rev-a" "nazgul/reviews/TASK-001/rev-a.md" "FEAT-013" 0
echo "# review: APPROVED" > "$TEST_DIR/nazgul/reviews/TASK-001/rev-a.md"
assert_eq "report present allowed" "$(guard_ec rev-a)" "0"
assert_eq "manifest marked delivered" \
  "$(jq -r '.delivered' "$TEST_DIR/nazgul/dispatch/rev-a.json")" "true"

# 2. report missing -> BLOCK (exit 2), blocks incremented, reason names path
make_manifest "rev-b" "nazgul/reviews/TASK-001/rev-b.md" "FEAT-013" 0
assert_eq "report missing blocked" "$(guard_ec rev-b)" "2"
assert_eq "blocks incremented" \
  "$(jq -r '.blocks' "$TEST_DIR/nazgul/dispatch/rev-b.json")" "1"
ERR=$(jq -n '{from:"rev-b"}' | bash "$GUARD" 2>&1 >/dev/null || true)
assert_contains "reason names report path" "$ERR" "nazgul/reviews/TASK-001/rev-b.md"

# 3. empty report file counts as missing -> BLOCK
make_manifest "rev-empty" "nazgul/reviews/TASK-001/rev-empty.md" "FEAT-013" 0
: > "$TEST_DIR/nazgul/reviews/TASK-001/rev-empty.md"
assert_eq "empty report blocked" "$(guard_ec rev-empty)" "2"

# 4. blocks already at 3 -> ALLOW (backstop) + escalation logged
make_manifest "rev-c" "nazgul/reviews/TASK-001/rev-c.md" "FEAT-013" 3
assert_eq "backstop after 3 blocks allows" "$(guard_ec rev-c)" "0"
assert_contains "escalation logged" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "escalation"

# 5. malformed payload -> ALLOW (fail open)
EC=0; printf 'not json at all' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "malformed payload allowed" "$EC" "0"

# 6. payload with no resolvable name -> ALLOW
EC=0; jq -n '{type:"idle_notification"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "nameless payload allowed" "$EC" "0"

# 7. foreign teammate (no manifest) -> ALLOW
assert_eq "no manifest allowed" "$(guard_ec unknown-teammate)" "0"

# 8. stale feat_id -> ALLOW even though report missing
make_manifest "rev-old" "nazgul/reviews/TASK-001/rev-old.md" "FEAT-001" 0
assert_eq "stale feat_id allowed" "$(guard_ec rev-old)" "0"

# 9. kill-switch off -> ALLOW even though report missing
create_config '.feat_id = "FEAT-013"' '.execution.enforce.teammate_report_guard = false'
make_manifest "rev-d" "nazgul/reviews/TASK-001/rev-d.md" "FEAT-013" 0
assert_eq "kill-switch disables guard" "$(guard_ec rev-d)" "0"
create_config '.feat_id = "FEAT-013"'

# 10. every invocation appends telemetry (count lines grew)
LINES_BEFORE=$(wc -l < "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
guard_ec rev-a >/dev/null
LINES_AFTER=$(wc -l < "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
assert_eq "telemetry appended" "$((LINES_AFTER > LINES_BEFORE))" "1"

# 11. alternate payload field names resolve (teammate_name)
make_manifest "rev-e" "nazgul/reviews/TASK-001/rev-e.md" "FEAT-013" 0
EC=0; jq -n '{teammate_name:"rev-e"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "teammate_name field resolves (blocks: missing report)" "$EC" "2"

# 12. no nazgul dir at all -> ALLOW (not a Nazgul project)
rm -rf "$TEST_DIR/nazgul"
EC=0; jq -n '{from:"rev-a"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "no nazgul dir allowed" "$EC" "0"

teardown
report_results
