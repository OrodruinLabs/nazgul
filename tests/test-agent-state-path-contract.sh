#!/usr/bin/env bash
set -uo pipefail
# NOT using set -e; assertions check return codes and content explicitly.
# Test: the shipped agent roster carries ZERO cwd-dependent state paths
# (FEAT-030 TASK-011, PRD AC3/AC4/AC10). This is the GATE, where
# tests/test-agent-state-path-audit.sh is the auditor's own contract: it drives
# scripts/audit-agent-state-paths.sh over the WHOLE shipped roster — every file
# under agents/ and agents/templates/, not the diff — so a future spec that
# re-adds a relative state path is caught wherever it lands. Same discipline as
# tests/test-agent-worktree-contract.sh, which scans the roster for the sibling
# forbidden construct.
#
# Three obligations, the third load-bearing:
#   R1  F == 0 over the shipped roster.
#   R2  K > 0 and N == M + K — a zero-file scan is a broken scan, not a clean
#       roster (the floor tests/test-repo-content-boundary.sh already uses).
#   D   The gate predicate is dogfooded: a synthetic spec carrying a known
#       relative state write must make _gate_holds return false, through the same
#       _audit driver and the same predicate R1 applies. The roster is clean by
#       construction once TASK-005..009 land, so a gate exercised only against it
#       is a rule that can only pass — evidence of nothing.
TEST_NAME="test-agent-state-path-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

AUDIT="$REPO_ROOT/scripts/audit-agent-state-paths.sh"
ENTRY="audit-agent-state-paths"
GRAMMAR="^$ENTRY: ([0-9]+) scanned, ([0-9]+) skipped \(non-spec=([0-9]+), unreadable=([0-9]+), not-a-file=([0-9]+)\), ([0-9]+) checked, ([0-9]+) findings\$"

if [ ! -f "$AUDIT" ]; then
  _fail "the roster auditor is present" \
    "no file at $AUDIT — the gate has nothing to drive, which is not a clean roster"
  report_results
  exit 1
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-agent-state-path-contract-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

AUDIT_OUT=""
AUDIT_ERR=""
AUDIT_LINE=""
AUDIT_N=0
AUDIT_M=0
AUDIT_K=0
AUDIT_F=0

_field() { printf '%s' "$AUDIT_LINE" | sed -E "s/$1/\\1/"; }

# _audit <scan-root> — the SINGLE driver. The roster arm and the dogfood arm both
# go through it, so a detector proven on one is the detector gating the other.
_audit() {
  NAZGUL_AGENT_AUDIT_SCAN_ROOT="$1" bash "$AUDIT" >"$SCRATCH/out" 2>"$SCRATCH/err"
  AUDIT_OUT="$(cat "$SCRATCH/out")"
  AUDIT_ERR="$(cat "$SCRATCH/err")"
  AUDIT_LINE="$(printf '%s' "$AUDIT_OUT" | tail -1)"
  printf '%s' "$AUDIT_LINE" | grep -qE "$GRAMMAR" || return 1
  AUDIT_N=$(_field '^[^:]*: ([0-9]+) scanned.*')
  AUDIT_M=$(_field '^.* ([0-9]+) skipped \(.*')
  AUDIT_K=$(_field '^.*\), ([0-9]+) checked.*')
  AUDIT_F=$(_field '^.*, ([0-9]+) findings$')
  return 0
}

# _gate_holds — the ONE predicate R1 applies: no state-write or state-read
# occurrence in the scanned tree resolves through a cwd-dependent path.
_gate_holds() { [ "$AUDIT_F" -eq 0 ]; }

if ! _audit "$REPO_ROOT"; then
  _fail "the roster audit emits a parseable coverage line" \
    "the last stdout line does not conform to the RULES.md §15 grammar; F cannot be read" \
    "got: '$AUDIT_LINE'"
  report_results
  exit 1
fi

# R1 FIRST, and the finding count belongs in the case NAME: a red run records the
# first FAIL: line, so an unconverted roster must say how many paths it left behind.
if _gate_holds; then
  _pass "R1: every operational state path in the shipped roster is rooted at <main_worktree_path> (0 findings over $AUDIT_K spec(s))"
else
  _fail "R1: every operational state path in the shipped roster is rooted at <main_worktree_path> ($AUDIT_F unconverted-roster finding(s) over $AUDIT_K spec(s))" \
    "each finding below is a state-write or state-read that resolves against the working directory:" \
    "$(printf '%s' "$AUDIT_OUT" | grep -E '^  agents/' | head -20 | tr '\n' ' ')"
fi

ROSTER_FLOOR="${NAZGUL_STATE_PATH_ROSTER_FLOOR:-20}"
if [ "$AUDIT_K" -ge "$ROSTER_FLOOR" ]; then
  _pass "R2: the scan actually walked the shipped roster ($AUDIT_K checked >= $ROSTER_FLOOR)"
else
  _fail "R2: the scan actually walked the shipped roster" \
    "only $AUDIT_K spec(s) checked of $AUDIT_N enumerated — a broken enumerator, not an empty roster"
fi

assert_eq "R2: coverage accounting adds up over the roster (N == M + K)" \
  "$AUDIT_N" "$((AUDIT_M + AUDIT_K))"
assert_not_contains "R2: a run that gated the roster is not a vacuous run" \
  "$AUDIT_ERR" "NOTHING CHECKED"

# Mirror the auditor's own enumeration (scripts/audit-agent-state-paths.sh: find agents
# \( -type f -o -type l \)) — counting only -type f would make this recount disagree with
# AUDIT_K the moment a spec is symlinked, failing the contract for the wrong reason.
ROSTER_FILES=$(find "$REPO_ROOT/agents" \( -type f -o -type l \) -name '*.md' | grep -c . || true)
assert_eq "R2: the enumerator reached every .md spec under agents/ and agents/templates/" \
  "$AUDIT_K" "$ROSTER_FILES"

# The gate predicate, driven against a roster dirty by construction.
mkdir -p "$SCRATCH/dirty/agents/templates"
cat > "$SCRATCH/dirty/agents/templates/relative-writer.md" <<'SPEC'
# relative-writer

## Completion

```bash
echo "$FEAT_ID" > nazgul/logs/relative.log
```
SPEC

if _audit "$SCRATCH/dirty"; then
  if _gate_holds; then
    _fail "D1: a known relative state write makes the gate predicate fail" \
      "the same _audit driver reported 0 findings on a corpus with one relative state write" \
      "line: '$AUDIT_LINE'"
  else
    _pass "D1: a known relative state write makes the gate predicate fail ($AUDIT_F finding(s))"
  fi
  assert_contains "D2: the finding names the spec, the line, and the state-write class" \
    "$AUDIT_OUT" "agents/templates/relative-writer.md:6: state-write"
  assert_eq "D3: the dirty corpus was checked, not skipped into silence" "$AUDIT_K" "1"
else
  _fail "D1: a known relative state write makes the gate predicate fail" \
    "the dirty corpus produced no parseable coverage line: '$AUDIT_LINE'"
fi

# Same spec, rooted: proves D1 fired on the relative path rather than on the file.
mkdir -p "$SCRATCH/clean/agents/templates"
sed 's#> nazgul/logs/relative.log#> "<main_worktree_path>/nazgul/logs/relative.log"#' \
  "$SCRATCH/dirty/agents/templates/relative-writer.md" \
  > "$SCRATCH/clean/agents/templates/relative-writer.md"

if _audit "$SCRATCH/clean"; then
  if _gate_holds; then
    _pass "D4: rooting that same write at <main_worktree_path> satisfies the gate"
  else
    _fail "D4: rooting that same write at <main_worktree_path> satisfies the gate" \
      "$AUDIT_F finding(s) remain after the only defect was rooted"
  fi
  assert_eq "D5: the rooted corpus was checked, so its pass is a real pass" "$AUDIT_K" "1"
else
  _fail "D4: rooting that same write at <main_worktree_path> satisfies the gate" \
    "the rooted corpus produced no parseable coverage line: '$AUDIT_LINE'"
fi

report_results
