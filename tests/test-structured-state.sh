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

report_results
