#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

TEST_NAME="test-comment-verifier-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# get_task_status: frontmatter-first status reader (matches production, unlike a
# raw legacy-list-item grep) — used below to read back manifests the hook wrote.
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# The gate's three writers must be mutually distinguishable, so the marker assertions
# below are inequalities against the clean-pass value, not pins on a chosen literal.
assert_neq() {
  local name="$1" actual="$2" forbidden="$3"
  if [ "$actual" != "$forbidden" ]; then
    _pass "$name"
  else
    _fail "$name" "expected anything BUT: '$forbidden'" "  actual: '$actual'"
  fi
}

last_marker_stop_gate() {
  local events="$TEST_DIR/nazgul/logs/events.jsonl"
  [ -f "$events" ] || return 0
  jq -c 'select(.event == "stop_gate" and .reason == "comment_verifier_marker_unverified")' \
    "$events" 2>/dev/null | tail -1
}

last_gate_attribution() {
  local events="$TEST_DIR/nazgul/logs/events.jsonl"
  [ -f "$events" ] || return 0
  jq -c 'select(.event == "gate_attribution" and .gate == "comment_verifier")' "$events" 2>/dev/null | tail -1
}

# setup_git_repo leaves HEAD~1..HEAD non-empty (README.md added in 2nd commit),
# so the default fixture always has "source changed". Pin branch.base to HEAD to
# exercise the degrade-to-allow (no source changed) path deterministically.
pin_base_to_head() {
  local sha
  sha=$(git -C "$TEST_DIR" rev-parse HEAD)
  jq --arg b "$sha" '.branch.base = $b' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
    && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
}

# --- Test CV-1: opt-out (docs.verify_comments=false) — no-op, exit 0, no marker ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV1"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "CV-1: opt-out → exit 0" "$HOOK_EC" 0
assert_file_not_exists "CV-1: no marker when opted out" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_not_contains "CV-1: no decision JSON when opted out" "$HOOK_OUTPUT" "comment-verifier gate"
teardown_temp_dir

# --- Test CV-2: no source files changed — degrade-to-allow, marker written, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV2"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
pin_base_to_head
run_hook
assert_exit_code "CV-2: no source changed → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "CV-2: marker written on degrade" "$TEST_DIR/nazgul/logs/.comments-verified"
CV2_MARKER=$(cat "$TEST_DIR/nazgul/logs/.comments-verified")
assert_contains "CV-2: degrade marker scoped to feat_id" "$CV2_MARKER" "FEAT-CV2"
assert_neq "CV-2: degrade marker distinguishable from a clean pass" "$CV2_MARKER" "FEAT-CV2"
teardown_temp_dir

# --- Test CV-3: only doc/config files changed — degrade-to-allow, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV3"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
pin_base_to_head
mkdir -p "$TEST_DIR/docs"
echo "notes" > "$TEST_DIR/docs/notes.md"
git -C "$TEST_DIR" add docs/notes.md
git -C "$TEST_DIR" commit -q -m "docs only"
run_hook
assert_exit_code "CV-3: doc-only change → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "CV-3: marker written on degrade (doc-only)" "$TEST_DIR/nazgul/logs/.comments-verified"
teardown_temp_dir

# --- Test CV-4: source changed, marker absent — block, exit 2, DELEGATE on stderr ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV4"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "CV-4: marker absent + source changed → exit 2" "$HOOK_EC" 2
assert_contains "CV-4: decision block in stdout" "$HOOK_OUTPUT" '"decision": "block"'
assert_contains "CV-4: reason mentions feat_id" "$HOOK_OUTPUT" "FEAT-CV4"
assert_contains "CV-4: DELEGATE instruction emitted" "$HOOK_OUTPUT" "nazgul:comment-verifier"
assert_file_exists "CV-4: attempts file created" "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
assert_contains "CV-4: attempts scoped to feat_id" "$(cat "$TEST_DIR/nazgul/logs/.comments-verify-attempts")" "FEAT-CV4"
teardown_temp_dir

# --- Test CV-5: marker matches feat_id — pass immediately, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV5"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-CV5" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-5: marker matches → exit 0" "$HOOK_EC" 0
assert_not_contains "CV-5: no block when marker matches" "$HOOK_OUTPUT" "comment-verifier gate: comments not yet verified"
teardown_temp_dir

# --- Test CV-6: stale marker (different feat_id) — re-gates, exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV6"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-STALE" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-6: stale marker → exit 2" "$HOOK_EC" 2
assert_contains "CV-6: decision block for stale marker" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- Test CV-7: attempts increment 0→1→2 (still blocking) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV7"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV7" "2" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
run_hook
assert_exit_code "CV-7: attempts=2 → still exit 2" "$HOOK_EC" 2
assert_eq "CV-7: attempts incremented to 3" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.comments-verify-attempts")" "3"
teardown_temp_dir

# --- Test CV-8: backstop (attempts≥3) — completes with warning, exit 0, marker written ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV8"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV8" "3" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
run_hook
assert_exit_code "CV-8: backstop → exit 0" "$HOOK_EC" 0
assert_contains "CV-8: backstop warns" "$HOOK_OUTPUT" "gave up"
assert_file_exists "CV-8: backstop writes marker" "$TEST_DIR/nazgul/logs/.comments-verified"
CV8_MARKER=$(cat "$TEST_DIR/nazgul/logs/.comments-verified")
assert_neq "CV-8: backstop marker distinguishable from a clean pass" "$CV8_MARKER" "FEAT-CV8"
assert_contains "CV-8: backstop marker scoped to feat_id" "$CV8_MARKER" "FEAT-CV8"
run_hook
assert_exit_code "CV-8: backstop marker satisfies the gate on re-run" "$HOOK_EC" 0
assert_not_contains "CV-8: no re-block after backstop" "$HOOK_OUTPUT" "comment-verifier gate: comments not yet verified"
assert_eq "CV-8: backstop marker stable across re-run" \
  "$(cat "$TEST_DIR/nazgul/logs/.comments-verified")" "$CV8_MARKER"
teardown_temp_dir

# --- Test CV-9: reset-counter split — provenance-only violation after an evidence
# violation gets its own grace reset instead of jumping straight to BLOCKED ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
source "$REPO_ROOT/scripts/lib/review-provenance.sh"
# templates/config.json now defaults receipt_hash_enforcement to false
# (TASK-009 round-2: opt-in until the parallel-dispatch attribution
# follow-up lands), so the override below is belt-and-suspenders — kept
# explicit so this test stays pinned against any future default change,
# not because CV-9 needs it to pass today.
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.review_gate.receipt_hash_enforcement = false' \
  '.feat_id = "FEAT-CV9"' \
  '.learning.auto_distill_post_loop = false' \
  '.safety._review_reset_counts = {"TASK-001": 1}'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
DIFF="$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
# Manifest token is intentionally NOT stamped into the reviewer file below —
# this simulates a genuine TOKEN_MISMATCH provenance violation.
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-CV9" "1" -- code-reviewer >/dev/null
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nreview_token: %s\n---\nLooks good.\n' "deadbeef" \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
run_hook
# Evidence is valid (token stamped, roster satisfied) but the token doesn't match the
# manifest's, so this is a genuinely-first PROVENANCE violation. A pre-existing stale
# evidence reset count (1) must not escalate it straight to BLOCKED.
assert_exit_code "CV-9: independent ladder → exit 2 (reset, not BLOCKED)" "$HOOK_EC" 2
assert_contains "CV-9: names provenance" "$HOOK_OUTPUT" "review provenance invalid"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "CV-9: reset to IMPLEMENTED, not escalated" "$status" "IMPLEMENTED"
prov_count=$(jq -r '.safety._provenance_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "CV-9: provenance counter starts its own ladder at 1" "$prov_count" "1"
# Evidence passed to reach the provenance branch, so its stale counter must be
# cleared here — leaving it would over-escalate a later, genuinely-first evidence
# violation straight to BLOCKED.
evid_count=$(jq -r 'if (.safety._review_reset_counts | has("TASK-001")) then .safety._review_reset_counts["TASK-001"] else "absent" end' "$TEST_DIR/nazgul/config.json")
assert_eq "CV-9: stale evidence counter cleared on provenance branch" "$evid_count" "absent"
teardown_temp_dir

# --- Test CV-10: backstop at every attempt count at or past the bound — the marker is
# never the value a clean pass writes, and the gate is satisfied on the next run ---
for CV10_ATTEMPTS in 3 4 7 99; do
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  create_config \
    '.agents.reviewers = ["code-reviewer"]' \
    '.feat_id = "FEAT-CV10"' \
    '.learning.auto_distill_post_loop = false' \
    '.self_audit.enabled = false'
  create_plan
  create_task_file "TASK-001" "DONE"
  create_review_dir "TASK-001"
  mkdir -p "$TEST_DIR/nazgul/logs"
  printf '%s %s\n' "FEAT-CV10" "$CV10_ATTEMPTS" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
  run_hook
  assert_exit_code "CV-10(attempts=$CV10_ATTEMPTS): backstop → exit 0" "$HOOK_EC" 0
  CV10_MARKER=$(cat "$TEST_DIR/nazgul/logs/.comments-verified" 2>/dev/null || echo "")
  assert_neq "CV-10(attempts=$CV10_ATTEMPTS): marker distinguishable from a clean pass" \
    "$CV10_MARKER" "FEAT-CV10"
  assert_contains "CV-10(attempts=$CV10_ATTEMPTS): marker scoped to feat_id" "$CV10_MARKER" "FEAT-CV10"
  assert_eq "CV-10(attempts=$CV10_ATTEMPTS): attribution names the backstop" \
    "$(last_gate_attribution | jq -r '.writer')" "backstop-exhausted"
  run_hook
  assert_exit_code "CV-10(attempts=$CV10_ATTEMPTS): satisfied on re-run, no deadlock" "$HOOK_EC" 0
  teardown_temp_dir
done

# --- Test CV-11: degrade-to-allow is a third writer, attributed as itself; the seeded
# attempts file pins the pair's other half — attempts:0 reads as "gave up at zero". ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV11"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV11" "2" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
pin_base_to_head
run_hook
assert_exit_code "CV-11: degrade → exit 0" "$HOOK_EC" 0
CV11_MARKER=$(cat "$TEST_DIR/nazgul/logs/.comments-verified")
assert_neq "CV-11: degrade marker distinguishable from a clean pass" "$CV11_MARKER" "FEAT-CV11"
CV11_ATTR=$(last_gate_attribution)
assert_eq "CV-11: attribution names the degrade writer" "$(jq -r '.writer' <<<"$CV11_ATTR")" "degrade-to-allow"
assert_eq "CV-11: attribution names the gate" "$(jq -r '.gate' <<<"$CV11_ATTR")" "comment_verifier"
assert_eq "CV-11: attribution carries the persisted marker" "$(jq -r '.marker' <<<"$CV11_ATTR")" "$CV11_MARKER"
assert_eq "CV-11: degrade reports the attempts actually spent, not 0" \
  "$(jq -r '.attempts' <<<"$CV11_ATTR")" "2"
run_hook
assert_exit_code "CV-11: degrade marker satisfies the gate on re-run" "$HOOK_EC" 0
CV11_ATTR2=$(last_gate_attribution)
assert_eq "CV-11: re-run attributed to the degrade writer, not a clean pass" \
  "$(jq -r '.writer' <<<"$CV11_ATTR2")" "degrade-to-allow"
assert_eq "CV-11: gate satisfied by a pre-existing marker still reports the real count" \
  "$(jq -r '.attempts' <<<"$CV11_ATTR2")" "2"
teardown_temp_dir

# --- Test CV-12: a clean verifier pass (bare feat_id) is attributed as verifier-clean and
# is never confused with either give-up writer ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV12"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-CV12" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-12: clean marker → exit 0" "$HOOK_EC" 0
CV12_ATTR=$(last_gate_attribution)
assert_eq "CV-12: attribution names the verifier" "$(jq -r '.writer' <<<"$CV12_ATTR")" "verifier-clean"
assert_eq "CV-12: clean marker unchanged by the gate" \
  "$(cat "$TEST_DIR/nazgul/logs/.comments-verified")" "FEAT-CV12"
teardown_temp_dir

# --- Test CV-13: the degrade value taken from the AGENT SPEC and driven through the real
# gate. Reading it out of the spec is what makes this dogfood, not a restatement. ---
CV_SPEC="$REPO_ROOT/agents/comment-verifier.md"
# The degrade paragraph, banner through the blank line that ends it.
CV13_PARA=$(awk '/\*\*Degrade-to-allow\*\*/ { f = 1 } f { print } f && /^$/ { exit }' "$CV_SPEC")
if [ -n "$CV13_PARA" ]; then
  _pass "CV-13: the degrade-to-allow paragraph was extracted from the spec"
else
  _fail "CV-13: the degrade-to-allow paragraph was extracted from the spec" \
    "no **Degrade-to-allow** section in $CV_SPEC — every assertion below would be vacuous"
fi
CV13_SUFFIX=$(printf '%s' "$CV13_PARA" | grep -o ':NO-SOURCE-CHANGED' | head -1)
CV13_VALUE="FEAT-CV13${CV13_SUFFIX}"

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV13"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "$CV13_VALUE" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-13: the spec's degrade value satisfies the gate" "$HOOK_EC" 0
CV13_ATTR=$(last_gate_attribution)
assert_eq "CV-13: the value the SPEC tells the degrade path to write is attributed to the degrade writer" \
  "$(jq -r '.writer' <<<"$CV13_ATTR")" "degrade-to-allow"
assert_neq "CV-13: a run that checked nothing is never recorded as a clean pass" \
  "$(jq -r '.writer' <<<"$CV13_ATTR")" "verifier-clean"
teardown_temp_dir

# --- Test CV-14/CV-15: the hook's OWN give-up writers, held to the read-back rule. The
# marker path is a directory, so a writer that only checks "I wrote it" claims satisfied. ---
cv_block_marker_path() {
  mkdir -p "$TEST_DIR/nazgul/logs/.comments-verified"
}

# CV-14 — degrade-to-allow: no source changed, and the marker cannot be written.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV14"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
pin_base_to_head
cv_block_marker_path
run_hook
assert_exit_code "CV-14: an unverifiable degrade write blocks rather than completing" "$HOOK_EC" 2
assert_contains "CV-14: the failure names the marker it could not prove" \
  "$HOOK_OUTPUT" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_contains "CV-14: the failure is reported as a read-back failure" \
  "$HOOK_OUTPUT" "marker read-back"
assert_eq "CV-14: no attribution claims the gate was satisfied" "$(last_gate_attribution)" ""
CV14_SG=$(last_marker_stop_gate)
assert_eq "CV-14: the existing stop_gate diagnostic names the unverified marker" \
  "$(jq -r '.marker' <<<"${CV14_SG:-{\}}")" "$TEST_DIR/nazgul/logs/.comments-verified"
teardown_temp_dir

# CV-15 — backstop-exhausted: source changed, attempts spent, and the marker cannot be written.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV15"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV15" "3" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
cv_block_marker_path
run_hook
assert_exit_code "CV-15: an unverifiable exhausted write blocks rather than completing" "$HOOK_EC" 2
assert_contains "CV-15: the failure is reported as a read-back failure" \
  "$HOOK_OUTPUT" "marker read-back"
assert_eq "CV-15: no attribution claims the gate was satisfied" "$(last_gate_attribution)" ""
CV15_SG=$(last_marker_stop_gate)
assert_eq "CV-15: the existing stop_gate diagnostic names the unverified marker" \
  "$(jq -r '.marker' <<<"${CV15_SG:-{\}}")" "$TEST_DIR/nazgul/logs/.comments-verified"
teardown_temp_dir

report_results
