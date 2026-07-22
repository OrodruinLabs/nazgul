#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-structured-state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/structured-state.sh"

echo "=== $TEST_NAME ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# read_frontmatter_field
printf -- '---\nverdict: APPROVE\nconfidence: 92\n---\nbody\n' > "$TMP/fm.md"
assert_eq "reads frontmatter field" "$(read_frontmatter_field "$TMP/fm.md" verdict)" "APPROVE"
assert_eq "reads second field" "$(read_frontmatter_field "$TMP/fm.md" confidence)" "92"

printf -- 'no frontmatter here\n' > "$TMP/plain.md"
rc=0; read_frontmatter_field "$TMP/plain.md" verdict >/dev/null || rc=$?
assert_exit_code "missing block returns 1" "$rc" 1

printf -- '---\nverdict: APPROVE\n---\n' > "$TMP/nokey.md"
rc=0; read_frontmatter_field "$TMP/nokey.md" status >/dev/null || rc=$?
assert_exit_code "missing key returns 1" "$rc" 1

# read_verdict
printf -- '---\nverdict: APPROVE\n---\n' > "$TMP/v_ok.md"
out=$(read_verdict "$TMP/v_ok.md"); rc=$?
assert_eq "valid verdict value" "$out" "APPROVE"; assert_exit_code "valid verdict rc" "$rc" 0

printf -- '---\nverdict: CHANGES_REQUESTED\n---\n' > "$TMP/v_cr.md"
assert_eq "changes_requested verdict" "$(read_verdict "$TMP/v_cr.md")" "CHANGES_REQUESTED"

printf -- '---\nverdict: SKIPPED\n---\n' > "$TMP/v_skip.md"
out=$(read_verdict "$TMP/v_skip.md"); rc=$?
assert_eq "skipped verdict value" "$out" "SKIPPED"; assert_exit_code "skipped verdict rc" "$rc" 0

printf -- '---\nverdict: UNVERIFIED\n---\n' > "$TMP/v_unver.md"
out=$(read_verdict "$TMP/v_unver.md"); rc=$?
assert_eq "unverified verdict value" "$out" "UNVERIFIED"; assert_exit_code "unverified verdict rc" "$rc" 0

printf -- '---\nverdict: MAYBE\n---\n' > "$TMP/v_bad.md"
assert_eq "off-enum verdict -> INVALID" "$(read_verdict "$TMP/v_bad.md" || true)" "INVALID"
rc=0; read_verdict "$TMP/v_bad.md" >/dev/null || rc=$?
assert_exit_code "off-enum verdict rc=2" "$rc" 2

printf -- 'Final Verdict: APPROVED\n' > "$TMP/v_none.md"
assert_eq "no verdict block -> NONE" "$(read_verdict "$TMP/v_none.md" || true)" "NONE"
rc=0; read_verdict "$TMP/v_none.md" >/dev/null || rc=$?
assert_exit_code "no verdict block rc=1" "$rc" 1

# read_task_status
printf -- '---\nstatus: IN_REVIEW\n---\n# TASK\n' > "$TMP/s_ok.md"
out=$(read_task_status "$TMP/s_ok.md"); rc=$?
assert_eq "valid status value" "$out" "IN_REVIEW"; assert_exit_code "valid status rc" "$rc" 0

printf -- '---\nstatus: WIBBLE\n---\n' > "$TMP/s_bad.md"
assert_eq "off-enum status -> INVALID" "$(read_task_status "$TMP/s_bad.md" || true)" "INVALID"
rc=0; read_task_status "$TMP/s_bad.md" >/dev/null || rc=$?
assert_exit_code "off-enum status rc=2" "$rc" 2

printf -- '# TASK\n- **Status**: READY\n' > "$TMP/s_none.md"
rc=0; read_task_status "$TMP/s_none.md" >/dev/null || rc=$?
assert_exit_code "no status block rc=1" "$rc" 1
assert_eq "no status block prints nothing" "$(read_task_status "$TMP/s_none.md" || true)" ""

# MF-001 regression: APPROVED is a real, canonical status (Task-PR YOLO flow, RULES.md:34).
printf -- '---\nstatus: APPROVED\n---\n# TASK\n' > "$TMP/s_approved.md"
out=$(read_task_status "$TMP/s_approved.md"); rc=$?
assert_eq "APPROVED status value" "$out" "APPROVED"; assert_exit_code "APPROVED status rc" "$rc" 0

# MF-063 regression: APPROVED is also accepted as a verdict alias alongside APPROVE
# (review-gate has been observed emitting the past-participle form).
printf -- '---\nverdict: APPROVED\n---\n' > "$TMP/v_approved.md"
out=$(read_verdict "$TMP/v_approved.md"); rc=$?
assert_eq "APPROVED verdict value" "$out" "APPROVED"; assert_exit_code "APPROVED verdict rc" "$rc" 0

# FIX 1: IFS sensitivity — a caller with IFS=, must not break list membership.
printf -- '---\nverdict: APPROVE\n---\n' > "$TMP/ifs.md"
OLD_IFS="$IFS"; IFS=,
ifs_out=$(read_verdict "$TMP/ifs.md"); ifs_rc=$?
IFS="$OLD_IFS"
assert_eq "IFS=, valid verdict value" "$ifs_out" "APPROVE"
assert_exit_code "IFS=, valid verdict rc" "$ifs_rc" 0

# FIX 2: CRLF tolerance.
printf -- '---\r\nverdict: APPROVE\r\n---\r\n' > "$TMP/crlf.md"
crlf_out=$(read_verdict "$TMP/crlf.md"); crlf_rc=$?
assert_eq "CRLF verdict value" "$crlf_out" "APPROVE"
assert_exit_code "CRLF verdict rc" "$crlf_rc" 0

# FIX 3: quoted scalars.
printf -- '---\nverdict: "APPROVE"\n---\n' > "$TMP/q_dq.md"
dq_out=$(read_verdict "$TMP/q_dq.md"); dq_rc=$?
assert_eq "double-quoted verdict value" "$dq_out" "APPROVE"
assert_exit_code "double-quoted verdict rc" "$dq_rc" 0

printf -- "---\nstatus: 'DONE'\n---\n" > "$TMP/q_sq.md"
sq_out=$(read_task_status "$TMP/q_sq.md"); sq_rc=$?
assert_eq "single-quoted status value" "$sq_out" "DONE"
assert_exit_code "single-quoted status rc" "$sq_rc" 0

# FIX B: idempotent source guard — a second source is a safe no-op and leaves
# functions/enums intact (the file `return 0`s early instead of re-defining).
source "$REPO_ROOT/scripts/lib/structured-state.sh"
assert_eq "double-source: enum intact" "$VALID_VERDICTS" "APPROVE APPROVED CHANGES_REQUESTED SKIPPED UNVERIFIED"
assert_eq "double-source: function still works" "$(read_verdict "$TMP/v_ok.md")" "APPROVE"

# Shipped templates must carry valid canonical frontmatter
assert_eq "task-manifest template status valid" \
  "$(read_task_status "$REPO_ROOT/templates/task-manifest.md")" "PLANNED"

report_results
