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

report_results
