#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-learned-rules"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
LR="$REPO_ROOT/scripts/lib/learned-rules.sh"
echo "=== $TEST_NAME ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DOC="$TMP/learned-rules.md"

cat > "$DOC" <<'EOF'
# Nazgul Learned Rules

## LR-001: Guard null user in API handlers

- **Status**: active
- **Scope-Agents**: implementer, code-reviewer
- **Scope-Globs**: src/api/**
- **Hits**: 2
- **Added**: 2026-06-18
- **Evidence**: TASK-014, TASK-019

API handlers must guard against a null authenticated user.
Use the requireUser(req) helper.

## LR-002: Always set explicit timeouts on fetch

- **Status**: retired
- **Scope-Agents**: *
- **Scope-Globs**: **
- **Hits**: 0
- **Added**: 2026-06-18
- **Evidence**: TASK-021, TASK-022

Network calls must pass an explicit timeout.
EOF

# next-id: max existing + 1, zero-padded
assert_eq "next-id on populated doc" "$(bash "$LR" next-id --doc "$DOC")" "LR-003"
assert_eq "next-id on missing doc"   "$(bash "$LR" next-id --doc "$TMP/none.md")" "LR-001"

# fingerprint: deterministic + whitespace/case-insensitive
fp1=$(bash "$LR" fingerprint "Guard the User")
fp2=$(bash "$LR" fingerprint "guard   the user")
assert_eq "fingerprint normalizes case+space" "$fp1" "$fp2"
fp3=$(bash "$LR" fingerprint "different text")
assert_not_contains "fingerprint differs for different text" "$fp1" "$fp3"

report_results
