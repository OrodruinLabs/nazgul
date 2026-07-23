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

# 1. report file present and non-empty -> ALLOW. MF-045: `.delivered` is no
# longer written back (was write-only, zero consumers); the log line is the durable record now.
make_manifest "rev-a" "nazgul/reviews/TASK-001/rev-a.md" "FEAT-013" 0
echo "# review: APPROVED" > "$TEST_DIR/nazgul/reviews/TASK-001/rev-a.md"
assert_eq "report present allowed" "$(guard_ec rev-a)" "0"
assert_eq "manifest has no .delivered field (MF-045: dead field removed, not wired)" \
  "$(jq -r '.delivered' "$TEST_DIR/nazgul/dispatch/rev-a.json")" "null"
assert_contains "delivery recorded via log line instead" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "report delivered"

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

# Re-setup nazgul dir for test 13
mkdir -p "$TEST_DIR/nazgul/dispatch" "$TEST_DIR/nazgul/logs" "$TEST_DIR/nazgul/reviews/TASK-001"
create_config '.feat_id = "FEAT-013"'

# 13. corrupt manifest JSON -> whole-script robustness: jq reads on the corrupt
# JSON fall back to their defaults, so this exits via the "manifest has no
# report_path" fail-open branch (never reaches the fail-soft manifest writes)
# — degrades to fail-open (exit 0), no crash under set -e.
printf 'not json' > "$TEST_DIR/nazgul/dispatch/rev-corrupt.json"
EC=0; jq -n '{from:"rev-corrupt"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
if [ "$EC" -eq 0 ] || [ "$EC" -eq 2 ]; then
  _pass "corrupt manifest does not crash (exit $EC)"
else
  _fail "corrupt manifest does not crash" "expected exit 0 or 2, got $EC"
fi


# 18. non-numeric .blocks (corrupted/manually edited) -> still blocks (exit 2)
# AND self-heals .blocks back to numeric 1 (the shell-sanitized counter is
# reused for the write, not the raw jq `// 0` fallback which leaves a
# non-null non-numeric value untouched and would loop forever).
jq -n --arg t "rev-blockscorrupt" --arg rp "nazgul/reviews/TASK-001/rev-blockscorrupt.md" \
  --arg f "FEAT-013" --arg sa "2026-07-22T00:00:00Z" --argjson sae 0 \
  '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:"corrupt"}' \
  > "$TEST_DIR/nazgul/dispatch/rev-blockscorrupt.json"
BC_EC="$(guard_ec rev-blockscorrupt)"
BC_BLOCKS="$(jq -r '.blocks' "$TEST_DIR/nazgul/dispatch/rev-blockscorrupt.json")"
if [ "$BC_EC" = "2" ] && [ "$BC_BLOCKS" = "1" ]; then
  _pass "non-numeric blocks blocked and self-healed to numeric 1"
else
  _fail "non-numeric blocks blocked and self-healed to numeric 1" \
    "expected exit 2 + blocks=1, got exit $BC_EC + blocks=$BC_BLOCKS"
fi

# 19. mktemp failure (unwritable TMPDIR) must not propagate an undocumented
# exit code -- the delivered-report path must still exit 0. On some machines
# mktemp may fall back and still succeed under an unwritable TMPDIR; either
# way the exit-code-0 contract on the delivered path must hold.
make_manifest "rev-tmpdirfail" "nazgul/reviews/TASK-001/rev-tmpdirfail.md" "FEAT-013" 0
echo "# review: APPROVED" > "$TEST_DIR/nazgul/reviews/TASK-001/rev-tmpdirfail.md"
EC=0
jq -n --arg n "rev-tmpdirfail" '{type:"idle_notification", from:$n, idleReason:"available"}' \
  | TMPDIR=/nonexistent/subdir bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "mktemp failure under unwritable TMPDIR still exits 0 on delivered path" "$EC" "0"

# 20. MF-041/MF-054: traversal NAME (contains "..") -> ALLOW (fail-open),
# specific log message, no file touched anywhere the traversal could escape to.
EC=0
jq -n '{from:"../evil"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "traversal NAME allowed (fail-open)" "$EC" "0"
assert_contains "traversal NAME logs specific message" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "unsafe teammate name"
assert_file_not_exists "traversal NAME touches no file at the escaped path" \
  "$TEST_DIR/nazgul/evil.json"
assert_file_not_exists "traversal NAME touches no file inside dispatch dir" \
  "$TEST_DIR/nazgul/dispatch/../evil.json"

# 21. MF-041/MF-054: NAME containing a bare separator -> same fail-open branch.
EC=0
jq -n '{from:"sub/dir"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "separator NAME allowed (fail-open)" "$EC" "0"
assert_contains "separator NAME logs specific message" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "unsafe teammate name"
assert_file_not_exists "separator NAME touches no file at the nested path" \
  "$TEST_DIR/nazgul/dispatch/sub/dir.json"

# Decoy planted at the exact path REPORT_ABS resolves to, so a future reorder of the checks vs the delivered-report read would be caught.
TRAV_REPORT_PATH="../outside-marker-$$.md"
TRAV_DECOY_TARGET="$TEST_DIR/$TRAV_REPORT_PATH"
echo "decoy: must never be read as a delivered report" > "$TRAV_DECOY_TARGET"
make_manifest "rev-trav-rp" "$TRAV_REPORT_PATH" "FEAT-013" 0
EC=0
jq -n '{from:"rev-trav-rp"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "traversal report_path allowed (fail-open)" "$EC" "0"
TRAV_LOG_TAIL=$(tail -1 "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
assert_contains "traversal report_path logs specific message" "$TRAV_LOG_TAIL" "unsafe report_path"
assert_not_contains "traversal report_path decoy not misread as delivered" "$TRAV_LOG_TAIL" "report delivered"
rm -f "$TRAV_DECOY_TARGET"

# 23. MF-041/MF-054: absolute report_path -> same fail-open branch. Same
# decoy-at-the-real-computed-target technique as test 22.
ABS_REPORT_PATH="/abs-outside-marker.md"
ABS_DECOY_TARGET="$TEST_DIR/$ABS_REPORT_PATH"
echo "decoy: must never be read as a delivered report" > "$ABS_DECOY_TARGET"
make_manifest "rev-abs-rp" "$ABS_REPORT_PATH" "FEAT-013" 0
EC=0
jq -n '{from:"rev-abs-rp"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "absolute report_path allowed (fail-open)" "$EC" "0"
ABS_LOG_TAIL=$(tail -1 "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
assert_contains "absolute report_path logs specific message" "$ABS_LOG_TAIL" "unsafe report_path"
assert_not_contains "absolute report_path decoy not misread as delivered" "$ABS_LOG_TAIL" "report delivered"
rm -f "$ABS_DECOY_TARGET"

# 24. MF-056: both `stat -c` (GNU) and `stat -f` (BSD) forms failing must not
# crash the guard — shadow `stat` on PATH with one that always fails either way.
FAKE_STAT_DIR="$TEST_DIR/fakebin"
mkdir -p "$FAKE_STAT_DIR"
cat > "$FAKE_STAT_DIR/stat" << 'FAKE_STAT_EOF'
#!/usr/bin/env bash
exit 1
FAKE_STAT_EOF
chmod +x "$FAKE_STAT_DIR/stat"
make_manifest "rev-nostat" "nazgul/reviews/TASK-001/rev-nostat.md" "FEAT-013" 0
echo "# review: APPROVED" > "$TEST_DIR/nazgul/reviews/TASK-001/rev-nostat.md"
EC=0
jq -n '{from:"rev-nostat"}' | PATH="$FAKE_STAT_DIR:$PATH" bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "dual-stat-failure treated as delivered, no crash" "$EC" "0"
assert_contains "dual-stat-failure logs delivered (not blocked)" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "report delivered at nazgul/reviews/TASK-001/rev-nostat.md"

teardown
report_results
