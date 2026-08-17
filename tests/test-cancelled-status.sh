#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# Test: the CANCELLED terminal status (ADR-022) — vocabulary, edge set, quarantine
# refusal, dependency gate, shared counter, loop completion, and /nazgul:task skip.
TEST_NAME="test-cancelled-status"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$SCRIPT_DIR/lib/status-consumer-scan.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# FIRST assertion deliberately: at the pre-change base this edge falls through to
# `*) return 1`, which reads honestly as "the token did not exist".
if ttg_valid_transition READY CANCELLED; then
  _pass "ttg_valid_transition: READY -> CANCELLED allowed"
else
  _fail "ttg_valid_transition: READY -> CANCELLED allowed" "expected: 0" "  actual: nonzero"
fi

for from in PLANNED IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED BLOCKED; do
  if ttg_valid_transition "$from" CANCELLED; then
    _pass "ttg_valid_transition: ${from} -> CANCELLED allowed"
  else
    _fail "ttg_valid_transition: ${from} -> CANCELLED allowed" "expected: 0" "  actual: nonzero"
  fi
done

# CANCELLED is terminal: no out-edge, and DONE has no edge into it.
for to in PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED DONE BLOCKED CANCELLED; do
  if ttg_valid_transition CANCELLED "$to"; then
    _fail "ttg_valid_transition: CANCELLED -> ${to} refused" "expected: nonzero" "  actual: 0"
  else
    _pass "ttg_valid_transition: CANCELLED -> ${to} refused"
  fi
done
if ttg_valid_transition DONE CANCELLED; then
  _fail "ttg_valid_transition: DONE -> CANCELLED refused" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_valid_transition: DONE -> CANCELLED refused"
fi

# One token, one meaning: the status vocabulary gains it, the verdict one must not.
if _in_list CANCELLED "$VALID_STATUSES"; then
  _pass "VALID_STATUSES: CANCELLED is a member"
else
  _fail "VALID_STATUSES: CANCELLED is a member" "expected: 0" "  actual: nonzero"
fi
if _in_list CANCELLED "$VALID_VERDICTS"; then
  _fail "VALID_VERDICTS: CANCELLED does not collide with a verdict" "expected: nonzero" "  actual: 0"
else
  _pass "VALID_VERDICTS: CANCELLED does not collide with a verdict"
fi
if _in_list SKIPPED "$VALID_VERDICTS"; then
  _pass "VALID_VERDICTS: SKIPPED still means a skipped review"
else
  _fail "VALID_VERDICTS: SKIPPED still means a skipped review" "expected: 0" "  actual: nonzero"
fi

setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "CANCELLED"
assert_eq "get_task_status: CANCELLED manifest resolves to CANCELLED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md" "PLANNED")" "CANCELLED"
teardown_temp_dir

# Shared counter: its own bucket, never the off-vocabulary arm.
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "BLOCKED" "none" "skipped by operator — mentions skip in free text"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks" 2>"$TEST_DIR/count.err" >/dev/null
COUNT_ERR=$(cat "$TEST_DIR/count.err")
assert_eq "count_tasks_and_find_active: CANCELLED_COUNT is 1" "${CANCELLED_COUNT:-unset}" "1"
assert_eq "count_tasks_and_find_active: INVALID_COUNT is 0" "${INVALID_COUNT:-unset}" "0"
assert_eq "count_tasks_and_find_active: BLOCKED_COUNT is 1" "${BLOCKED_COUNT:-unset}" "1"
assert_eq "count_tasks_and_find_active: TOTAL_COUNT is 3" "${TOTAL_COUNT:-unset}" "3"
assert_eq "count_tasks_and_find_active: INVALID_TASKS is empty" "${INVALID_TASKS-unset}" ""
assert_not_contains "count_tasks_and_find_active: no off-vocabulary diagnostic for CANCELLED" \
  "$COUNT_ERR" "off-vocabulary"
teardown_temp_dir

# Dependency gate (ADR-022 veto site 5), in every granularity.
setup_temp_dir
setup_nazgul_dir
create_config
NAZ="$TEST_DIR/nazgul"
for gran in task group feature; do
  jq --arg g "$gran" '.review_gate.granularity = $g' "$NAZ/config.json" > "$NAZ/config.tmp" \
    && mv "$NAZ/config.tmp" "$NAZ/config.json"
  if ttg_dependency_satisfied "$NAZ" "CANCELLED"; then
    _pass "ttg_dependency_satisfied: CANCELLED satisfies at granularity=${gran}"
  else
    _fail "ttg_dependency_satisfied: CANCELLED satisfies at granularity=${gran}" \
      "expected: 0" "  actual: nonzero (expected set: ${TTG_DEP_EXPECTED})"
  fi
  if ttg_dependency_satisfied "$NAZ" "BLOCKED"; then
    _fail "ttg_dependency_satisfied: BLOCKED does not satisfy at granularity=${gran}" \
      "expected: nonzero" "  actual: 0"
  else
    _pass "ttg_dependency_satisfied: BLOCKED does not satisfy at granularity=${gran}"
  fi
  assert_contains "ttg_dependency_satisfied: diagnostic names CANCELLED at granularity=${gran}" \
    "$TTG_DEP_EXPECTED" "CANCELLED"
done
jq '.review_gate.granularity = "task" | .afk.yolo = true' "$NAZ/config.json" > "$NAZ/config.tmp" \
  && mv "$NAZ/config.tmp" "$NAZ/config.json"
if ttg_dependency_satisfied "$NAZ" "CANCELLED"; then
  _pass "ttg_dependency_satisfied: CANCELLED satisfies in YOLO"
else
  _fail "ttg_dependency_satisfied: CANCELLED satisfies in YOLO" "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir

# The distinction is mechanical: a CANCELLED dependency promotes its dependent, a
# BLOCKED one whose free-text reason says "skipped" does not.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "BLOCKED" "none" "skipped by operator via /nazgul:task skip"
create_task_file "TASK-003" "PLANNED" "TASK-001"
create_task_file "TASK-004" "PLANNED" "TASK-002"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-003" PLANNED READY \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-003.md")" 2>/dev/null; then
  _pass "ttg_validate_transition: PLANNED -> READY promotes behind a CANCELLED dependency"
else
  _fail "ttg_validate_transition: PLANNED -> READY promotes behind a CANCELLED dependency" \
    "expected: 0" "  actual: nonzero"
fi
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-004" PLANNED READY \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-004.md")" 2>/dev/null; then
  _fail "ttg_validate_transition: a BLOCKED dependency whose reason says 'skipped' still holds" \
    "expected: nonzero" "  actual: 0"
else
  _pass "ttg_validate_transition: a BLOCKED dependency whose reason says 'skipped' still holds"
fi
teardown_temp_dir

# BLOCKED -> CANCELLED must not become a second exit from the ADR-020 quarantine.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "BLOCKED"
QUARANTINED="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked kind**: reconciliation
- **Blocked reason**: status changed outside a completed transition"
LAUNDER_ERR=$(ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$QUARANTINED" 2>&1) && LAUNDER_EC=0 || LAUNDER_EC=$?
assert_eq "ttg_validate_transition: reconciliation quarantine refuses BLOCKED -> CANCELLED" \
  "$LAUNDER_EC" "1"
assert_contains "ttg_validate_transition: the refusal names repair" "$LAUNDER_ERR" "repair"

ORDINARY="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked reason**: skipped by operator via /nazgul:task skip"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$ORDINARY" 2>/dev/null; then
  _pass "ttg_validate_transition: an ordinary BLOCKED task may be cancelled"
else
  _fail "ttg_validate_transition: an ordinary BLOCKED task may be cancelled" \
    "expected: 0" "  actual: nonzero"
fi

# Anchored like its sibling check: an already-repaired kind is not in quarantine.
REPAIRED="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked kind**: reconciliation (repaired 2026-08-15T00:00:00Z)"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$REPAIRED" 2>/dev/null; then
  _pass "ttg_validate_transition: an already-repaired kind does not re-qualify as quarantine"
else
  _fail "ttg_validate_transition: an already-repaired kind does not re-qualify as quarantine" \
    "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir

COMPLETION_CONFIG=('.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false'
  '.docs.verify_comments = false' '.self_audit.enabled = false')

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "CANCELLED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_exit_code "completion: DONE + CANCELLED completes the loop" "$HOOK_EC" 0
assert_file_contains "completion: objective_complete emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
assert_file_contains "completion: objective_complete carries cancelled_count" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"cancelled_count"'
assert_contains "completion: reports the done/cancelled split" "$HOOK_OUTPUT" "2/3 done, 1 cancelled"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "CANCELLED"
run_hook
assert_exit_code "completion: an all-cancelled objective completes" "$HOOK_EC" 0
assert_contains "completion: an objective that shipped nothing says so" \
  "$HOOK_OUTPUT" "0/3 done, 3 cancelled — no task shipped"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_exit_code "completion: an all-done objective is unchanged" "$HOOK_EC" 0
assert_not_contains "completion: all-done reports no cancellation" "$HOOK_OUTPUT" "cancelled"
assert_file_contains "completion: all-done records cancelled_count 0" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"cancelled_count":0'
teardown_temp_dir

# The post-loop gates announce the same summary, so a cancelled task is named there too.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "CANCELLED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_contains "completion: the learning gate names the done/cancelled split" \
  "$HOOK_OUTPUT" "2/3 done, 1 cancelled — POST-LOOP LEARNING GATE"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_contains "completion: an uncancelled objective keeps the original wording" \
  "$HOOK_OUTPUT" "all 3/3 tasks complete — POST-LOOP LEARNING GATE"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "BLOCKED" "none" "skipped by operator via /nazgul:task skip"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_file_not_contains "completion: a BLOCKED task does not complete the loop" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
# RW-B: the per-iteration census now always prints a `N cancelled` bucket, so the
# original whole-output substring match hit its own zero. Count, then exclude it.
assert_contains "completion: the census counts the BLOCKED task as blocked, not cancelled" \
  "$HOOK_OUTPUT" "1 blocked, 0 planned, 0 cancelled"
assert_not_contains "completion: a 'skip'-worded BLOCKED reason is not read as cancellation" \
  "$(printf '%s\n' "$HOOK_OUTPUT" | grep -v '^Tasks: ')" "cancelled"
teardown_temp_dir

SKILL="$REPO_ROOT/skills/task/SKILL.md"
SKIP_SECTION=$(awk '/^#### `skip TASK-NNN`/{f=1} f && /^#### `unblock TASK-NNN`/{exit} f' "$SKILL")
UNBLOCK_SECTION=$(awk '/^#### `unblock TASK-NNN`/{f=1} f && /^#### `add /{exit} f' "$SKILL")

assert_contains "skip: transitions to CANCELLED" "$SKIP_SECTION" "<CURRENT_STATUS> CANCELLED"
assert_not_contains "skip: no longer records the skip as BLOCKED" "$SKIP_SECTION" "<CURRENT_STATUS> BLOCKED"
assert_not_contains "skip: no dependency-graph surgery" "$SKIP_SECTION" "edit that line to"
assert_not_contains "skip: does not report a removed dependency" \
  "$SKIP_SECTION" "had the dependency removed"
assert_contains "skip: reports the downstream auto-promotion count" "$SKIP_SECTION" "auto-promote"
assert_contains "skip: names the reconciliation refusal" "$SKIP_SECTION" "repair"
assert_contains "skip: treats DONE and CANCELLED as terminal" "$SKIP_SECTION" "\`DONE\` or \`CANCELLED\`"
assert_contains "unblock: refuses a terminal status" "$UNBLOCK_SECTION" "which is terminal"
assert_contains "unblock: still refuses a reconciliation quarantine" \
  "$UNBLOCK_SECTION" "\`reconciliation\` — do NOT unblock"

# THE GATE. An authored list prints neither "looked and found none" nor "never
# looked" (RULES.md §15); this population is derived by tests/lib/status-consumer-scan.sh.
scan_report() { # <label>
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _pass "consumer-scan [$rel]: CANCELLED-aware"
  done <<< "$SCS_AWARE"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _skip "consumer-scan [$rel]: exempt — $("$SCS_EXEMPTION_FN" "$rel")"
  done <<< "$SCS_EXEMPT"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _fail "consumer-scan [$rel]: no exemption outlives its defect" \
      "the file is CANCELLED-aware now, so its exemption states a defect that no longer exists" \
      "  fix: delete the $rel arm from scs_exemption() in tests/lib/status-consumer-scan.sh"
  done <<< "$SCS_RETIRED"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _fail "consumer-scan [$rel]: every exemption names a discovered consumer" \
      "an exemption arm names this path, but the walk never classified it as a consumer" \
      "  fix: delete the $rel arm, or explain why an unreached path needs one"
  done <<< "$SCS_ORPHANED"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _fail "consumer-scan [$rel]: CANCELLED-aware or enumerated-exempt" \
      "this file reads task status, does not name CANCELLED, and is on no exemption list" \
      "  fix: make it CANCELLED-aware, or add a justified entry to scs_exemption() in tests/lib/status-consumer-scan.sh"
  done <<< "$SCS_UNCLASSIFIED"
  scs_coverage_line "$1"
}

if ! scs_run "$REPO_ROOT"; then
  _fail "consumer-scan: the shipped tree is walkable" "no scripts/ directory under $REPO_ROOT"
else
  scan_report "consumer-scan"
  assert_eq "consumer-scan: coverage accounting adds up (N == M + K)" \
    "$SCS_N" "$((SCS_M + SCS_K))"
  assert_eq "consumer-scan: every status consumer is CANCELLED-aware or enumerated-exempt" \
    "$SCS_F" "0"

  # NEW-3: a retired exemption used to route to a silent _skip, so a counterfactual
  # justification could sit in the list indefinitely. Both staleness modes now fail.
  assert_eq "consumer-scan: no exemption outlives its defect" \
    "$(printf '%s' "$SCS_RETIRED" | grep -c .)" "0"
  assert_eq "consumer-scan: no exemption names a path the walk never reached" \
    "$(printf '%s' "$SCS_ORPHANED" | grep -c .)" "0"

  # The staleness checks read the live oracle's own case arms. An extraction that
  # returns nothing would pass both of them by never looking (RULES.md §15).
  EXEMPTION_ARMS=$(scs_exemption_paths | grep -c .)
  if [ "$EXEMPTION_ARMS" -ge 1 ]; then
    _pass "consumer-scan: the exemption enumeration reached the oracle ($EXEMPTION_ARMS arms)"
  else
    _fail "consumer-scan: the exemption enumeration reached the oracle" \
      "scs_exemption_paths returned nothing, so the staleness checks above examined no arm"
  fi
  assert_eq "consumer-scan: every enumerated arm is exempt under the oracle" \
    "$(scs_exemption_paths | while IFS= read -r a; do "$SCS_EXEMPTION_FN" "$a" >/dev/null || echo "$a"; done | grep -c .)" "0"

  # K > 0 floor: a scan that discovers no consumers is a broken predicate, not a
  # clean tree. The floor sits well under the current population.
  CONSUMER_FLOOR="${NAZGUL_STATUS_CONSUMER_FLOOR:-12}"
  if [ "$SCS_K" -ge "$CONSUMER_FLOOR" ]; then
    _pass "consumer-scan: the walk actually reached the tree ($SCS_K consumers >= $CONSUMER_FLOOR)"
  else
    _fail "consumer-scan: the walk actually reached the tree" \
      "only $SCS_K consumer(s) discovered of $SCS_N file(s) walked — a broken predicate, not a clean tree"
  fi

  # Three live cases pin the predicate against narrowing — the first two were
  # invisible to the authored list this scan replaces; prompt-guard.sh is
  # reachable only through the widened reach signal (board-3 QA Finding A).
  for known in scripts/webhook-forward.sh scripts/notify.sh scripts/prompt-guard.sh; do
    assert_contains "consumer-scan: discovery still reaches $known" "$SCS_CONSUMERS" "$known"
  done
fi

# The gate predicate, dogfooded against a tree dirty by construction. The shipped
# tree is clean, so a gate exercised only against it is a rule that can only pass.
SCS_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-consumer-scan-XXXXXX")
mkdir -p "$SCS_SCRATCH/scripts"
cat > "$SCS_SCRATCH/scripts/blind-consumer.sh" <<'BLIND'
#!/usr/bin/env bash
st=$(get_task_status "$NAZGUL_DIR/tasks/$1.md" "")
case "$st" in DONE|BLOCKED) exit 0 ;; esac
BLIND
# Board-3 QA Finding A's PoC, kept permanently: it reaches its manifest through a
# caller-supplied path, so it spells none of the tasks-dir or helper literals.
cat > "$SCS_SCRATCH/scripts/path-param-consumer.sh" <<'PARAM'
#!/usr/bin/env bash
manifest="$1"
current=$(sed -n 's/^status: *//p' "$manifest" | head -1)
if [ "$current" = "DONE" ]; then echo "already terminal, skipping"; exit 0; fi
PARAM
cat > "$SCS_SCRATCH/scripts/aware-consumer.sh" <<'AWARE'
#!/usr/bin/env bash
st=$(get_task_status "$NAZGUL_DIR/tasks/$1.md" "")
case "$st" in DONE|CANCELLED) exit 0 ;; esac
AWARE
cat > "$SCS_SCRATCH/scripts/fixed-exempt-consumer.sh" <<'FIXED'
#!/usr/bin/env bash
st=$(get_task_status "$NAZGUL_DIR/tasks/$1.md" "")
case "$st" in DONE|CANCELLED) exit 0 ;; esac
FIXED
printf '#!/usr/bin/env bash\necho hello\n' > "$SCS_SCRATCH/scripts/not-a-consumer.sh"

scratch_exemption() {
  case "$1" in
    scripts/fixed-exempt-consumer.sh) echo "scratch: exempt, and the file went on to name CANCELLED anyway" ;;
    scripts/deleted-consumer.sh) echo "scratch: exempt, and the file is not in this tree at all" ;;
    *) return 1 ;;
  esac
  return 0
}
SCS_EXEMPTION_FN=scratch_exemption

assert_eq "dogfood: the exemption enumeration follows the live oracle, not a fixed list" \
  "$(scs_exemption_paths | tr '\n' ' ')" "scripts/fixed-exempt-consumer.sh scripts/deleted-consumer.sh "

if scs_run "$SCS_SCRATCH"; then
  assert_eq "dogfood: findings = 1 blind + 1 path-param + 1 retired + 1 orphaned" "$SCS_F" "4"
  assert_contains "dogfood: the finding names the offending file" \
    "$SCS_UNCLASSIFIED" "scripts/blind-consumer.sh"
  assert_contains "dogfood: a caller-supplied manifest path is still a consumer (QA Finding A PoC)" \
    "$SCS_UNCLASSIFIED" "scripts/path-param-consumer.sh"
  assert_contains "dogfood: an exemption whose defect was fixed is retired, not skipped" \
    "$SCS_RETIRED" "scripts/fixed-exempt-consumer.sh"
  assert_contains "dogfood: an exemption naming an unreached path is orphaned" \
    "$SCS_ORPHANED" "scripts/deleted-consumer.sh"
  assert_contains "dogfood: the CANCELLED-aware sibling classifies clean" \
    "$SCS_AWARE" "scripts/aware-consumer.sh"
  assert_not_contains "dogfood: a file that reads no task status is not a consumer" \
    "$SCS_CONSUMERS" "scripts/not-a-consumer.sh"
  assert_eq "dogfood: coverage accounting adds up on the dirty tree (N == M + K)" \
    "$SCS_N" "$((SCS_M + SCS_K))"
  assert_eq "dogfood: the non-consumer was skipped with a reason, not dropped" \
    "$SCS_M_NONCONSUMER" "1"
else
  _skip "dogfood: the scratch tree could not be built — gate predicate not exercised"
fi
SCS_EXEMPTION_FN=scs_exemption
rm -rf "$SCS_SCRATCH"

report_results
