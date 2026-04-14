#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-relocate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-relocate.sh
source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"

# --- Happy path: complete relocation succeeds ---
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-relocate-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SCRATCH="$WORK/.bootstrap-scratch"
mkdir -p "$SCRATCH/docs" "$SCRATCH/context" "$SCRATCH/agents" "$SCRATCH/.claude"
echo "PRD" > "$SCRATCH/docs/PRD.md"
echo "TRD" > "$SCRATCH/docs/TRD.md"
echo "profile" > "$SCRATCH/context/project-profile.md"
echo "reviewer" > "$SCRATCH/agents/code-reviewer.md"
echo '{"colors":{}}' > "$SCRATCH/.claude/design-tokens.json"

cd "$WORK"
relocate_bundle "$SCRATCH" "$WORK"

assert_file_exists "PRD relocated"        "$WORK/docs/PRD.md"
assert_file_exists "TRD relocated"        "$WORK/docs/TRD.md"
assert_file_exists "context relocated"    "$WORK/docs/context/project-profile.md"
assert_file_exists "agents relocated"     "$WORK/.claude/agents/code-reviewer.md"
assert_file_exists "design relocated"     "$WORK/.claude/design-tokens.json"

# --- Atomicity: simulate mid-run failure by making one target read-only ---
WORK2=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-relocate2-XXXXXX")
trap 'rm -rf "$WORK" "$WORK2"' EXIT
SCRATCH2="$WORK2/.bootstrap-scratch"
mkdir -p "$SCRATCH2/docs" "$SCRATCH2/agents"
echo "PRD" > "$SCRATCH2/docs/PRD.md"
echo "reviewer" > "$SCRATCH2/agents/code-reviewer.md"

# Pre-create .claude/agents as a read-only directory — relocate must pre-check
# and abort before touching ./docs/
mkdir -p "$WORK2/.claude/agents"
chmod 555 "$WORK2/.claude/agents"

set +e
(cd "$WORK2" && relocate_bundle "$SCRATCH2" "$WORK2" >/dev/null 2>&1)
ec=$?
set -e
chmod 755 "$WORK2/.claude/agents"

assert_exit_code "relocate fails on unwritable target" "$ec" 20
assert_file_not_exists "PRD NOT relocated (atomic)" "$WORK2/docs/PRD.md"

report_results
