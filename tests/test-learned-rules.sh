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

# parse: emits one JSON object per rule with split agents/globs arrays
parsed=$(bash "$LR" parse --doc "$DOC")
assert_eq "parse emits 2 rules" "$(printf '%s\n' "$parsed" | jq -s 'length')" "2"
assert_eq "parse LR-001 status"  "$(printf '%s\n' "$parsed" | jq -rs '.[0].status')" "active"
assert_eq "parse LR-001 hits int" "$(printf '%s\n' "$parsed" | jq -rs '.[0].hits')" "2"
assert_eq "parse LR-001 agents[1]" "$(printf '%s\n' "$parsed" | jq -rs '.[0].agents[1]')" "code-reviewer"
assert_eq "parse LR-002 globs[0]"  "$(printf '%s\n' "$parsed" | jq -rs '.[1].globs[0]')" "**"

# select: agent + glob match returns the rule block with the heading
sel=$(bash "$LR" select --agent implementer --files "src/api/auth.ts" --doc "$DOC")
assert_contains "select injects heading" "$sel" "Learned Rules"
assert_contains "select includes matching LR-001" "$sel" "LR-001"

# agent not in scope -> no match (LR-001 is implementer/code-reviewer only)
sel2=$(bash "$LR" select --agent designer --files "src/api/auth.ts" --doc "$DOC")
assert_not_contains "designer not in LR-001 scope" "$sel2" "LR-001"

# glob not matching -> no match
sel3=$(bash "$LR" select --agent implementer --files "src/ui/Button.tsx" --doc "$DOC")
assert_not_contains "ui file not in src/api glob" "$sel3" "LR-001"

# retired rules are never injected (LR-002 is retired, scope *,**)
sel4=$(bash "$LR" select --agent implementer --files "anything.ts" --doc "$DOC")
assert_not_contains "retired LR-002 excluded" "$sel4" "LR-002"

# no matches at all -> empty output (caller adds no heading)
sel5=$(bash "$LR" select --agent designer --files "src/ui/Button.tsx" --doc "$DOC")
assert_eq "no match -> empty" "$(printf '%s' "$sel5" | tr -d '[:space:]')" ""

# bump-hits: increments only the target rule's Hits; no-op on absent id
cp "$DOC" "$TMP/bump.md"
bash "$LR" bump-hits LR-001 --doc "$TMP/bump.md"
assert_eq "bump-hits LR-001 -> 3" "$(bash "$LR" parse --doc "$TMP/bump.md" | jq -rs '.[0].hits')" "3"
assert_eq "bump-hits leaves LR-002 at 0" "$(bash "$LR" parse --doc "$TMP/bump.md" | jq -rs '.[1].hits')" "0"
bash "$LR" bump-hits LR-999 --doc "$TMP/bump.md"   # absent -> no-op, no error
assert_eq "bump-hits absent id is no-op" "$(bash "$LR" parse --doc "$TMP/bump.md" | jq -rs '.[0].hits')" "3"

# Regression: an ACTIVE rule scoped */** must match even when cwd has files
# (guards against unquoted-$csv pathname expansion eating the wildcards).
WILD="$TMP/wild.md"
cat > "$WILD" <<'EOF'
# Wild

## LR-010: Wildcard active rule

- **Status**: active
- **Scope-Agents**: *
- **Scope-Globs**: **
- **Hits**: 0
- **Added**: 2026-06-18
- **Evidence**: TASK-099

Applies everywhere.
EOF
touch "$TMP/a.ts" "$TMP/b.ts"
selw=$( cd "$TMP" && bash "$LR" select --agent any-agent --files "a.ts" --doc "$WILD" )
assert_contains "active */** rule matches from a dir with files" "$selw" "LR-010"

report_results
