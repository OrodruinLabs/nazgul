#!/usr/bin/env bash
set -euo pipefail

# Test: review-gate.md / team-orchestrator.md agent-prompt fixes (TASK-008, FEAT-017)
#   - WS2 (LR-002): review-gate.md's frontmatter pins model: sonnet, matching the
#     comment-verifier/doc-verifier/learner/self-audit precedent.
#   - WS2: team-orchestrator.md's review-team spawn logic restates the
#     models.review_orchestrator (default sonnet) tier requirement.
#   - MF-020: review-gate.md's step numbers are sequential (no out-of-order or
#     duplicate step numbers).
#   - MF-043: team-orchestrator.md's review-team step list has no duplicate "3.".
TEST_NAME="test-review-gate-docs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

REVIEW_GATE="$REPO_ROOT/agents/review-gate.md"
TEAM_ORCH="$REPO_ROOT/agents/team-orchestrator.md"

assert_file_exists "review-gate.md exists" "$REVIEW_GATE"
assert_file_exists "team-orchestrator.md exists" "$TEAM_ORCH"

# ── WS2: review-gate.md frontmatter pins model: sonnet ────
frontmatter=$(sed -n '2,/^---$/p' "$REVIEW_GATE" | sed '$d')
if echo "$frontmatter" | grep -q '^model: sonnet$'; then
  _pass "review-gate.md frontmatter pins model: sonnet"
else
  _fail "review-gate.md frontmatter pins model: sonnet" "no 'model: sonnet' line found in frontmatter"
fi

# ── WS2: team-orchestrator.md restates the review-orchestrator tier ──
assert_file_contains "team-orchestrator.md restates models.review_orchestrator tier" \
  "$TEAM_ORCH" "models.review_orchestrator"
assert_file_contains "team-orchestrator.md states default sonnet for review-orchestrator" \
  "$TEAM_ORCH" "review_orchestrator\` (default \`sonnet\`)"
assert_file_contains "team-orchestrator.md states never inherit a lower tier" \
  "$TEAM_ORCH" "never inherit a lower tier"

# ── MF-020: review-gate.md step numbers are sequential, no duplicates ──
# Collect every top-level "### Step N[.M]" heading, in file order.
mapfile -t step_lines < <(grep -n '^### Step [0-9]' "$REVIEW_GATE")

if [ "${#step_lines[@]}" -eq 0 ]; then
  _fail "review-gate.md has Step headings to check" "no '### Step N' headings found"
else
  _pass "review-gate.md has Step headings to check"
fi

declare -a step_numbers=()
for line in "${step_lines[@]}"; do
  # line looks like "58:### Step 0: Simplify Pass ..."
  num=$(echo "$line" | sed -E 's/^[0-9]+:### Step ([0-9]+(\.[0-9]+)?).*/\1/')
  step_numbers+=("$num")
done

# No duplicate step numbers.
dup_found=""
for ((i = 0; i < ${#step_numbers[@]}; i++)); do
  for ((j = i + 1; j < ${#step_numbers[@]}; j++)); do
    if [ "${step_numbers[$i]}" = "${step_numbers[$j]}" ]; then
      dup_found="${step_numbers[$i]}"
    fi
  done
done
if [ -z "$dup_found" ]; then
  _pass "review-gate.md has no duplicate step numbers"
else
  _fail "review-gate.md has no duplicate step numbers" "duplicate step number found: $dup_found (steps: ${step_numbers[*]})"
fi

# Monotonically non-decreasing in physical file order (no out-of-order step,
# e.g. Step 3.6 no longer physically precedes Step 3.5-equivalent).
out_of_order=""
for ((i = 1; i < ${#step_numbers[@]}; i++)); do
  prev="${step_numbers[$((i - 1))]}"
  curr="${step_numbers[$i]}"
  if (($(echo "$curr < $prev" | bc -l 2>/dev/null || awk -v a="$curr" -v b="$prev" 'BEGIN{print (a<b)}'))); then
    out_of_order="$prev -> $curr"
  fi
done
if [ -z "$out_of_order" ]; then
  _pass "review-gate.md step numbers are monotonically sequential (no out-of-order step)"
else
  _fail "review-gate.md step numbers are monotonically sequential (no out-of-order step)" "out-of-order transition: $out_of_order (steps: ${step_numbers[*]})"
fi

# No duplicate "Step 1.5" heading (the granularity-scope subsection must not
# also claim to be "Step 1.5" — only the diff-regeneration step is).
count_1_5=$(grep -c '^### Step 1\.5' "$REVIEW_GATE")
assert_eq "review-gate.md has exactly one 'Step 1.5' heading" "$count_1_5" "1"

# ── MF-043: team-orchestrator.md review-team step list has no duplicate "3." ──
# Extract the numbered list under "## Spawning a Review Team" (stop at the
# next "## " heading).
review_team_block=$(awk '/^## Spawning a Review Team$/{flag=1; next} /^## /{flag=0} flag' "$TEAM_ORCH")

mapfile -t list_numbers < <(echo "$review_team_block" | grep -oE '^[0-9]+\.' | tr -d '.')

dup_step=""
for ((i = 0; i < ${#list_numbers[@]}; i++)); do
  for ((j = i + 1; j < ${#list_numbers[@]}; j++)); do
    if [ "${list_numbers[$i]}" = "${list_numbers[$j]}" ]; then
      dup_step="${list_numbers[$i]}"
    fi
  done
done
if [ -z "$dup_step" ]; then
  _pass "team-orchestrator.md review-team step list has no duplicate numbers"
else
  _fail "team-orchestrator.md review-team step list has no duplicate numbers" "duplicate: $dup_step (list: ${list_numbers[*]})"
fi

# Sequential starting at 1, incrementing by exactly 1 each item.
seq_ok=true
expected=1
for n in "${list_numbers[@]}"; do
  if [ "$n" != "$expected" ]; then
    seq_ok=false
    break
  fi
  expected=$((expected + 1))
done
if $seq_ok; then
  _pass "team-orchestrator.md review-team step list is sequential 1..N"
else
  _fail "team-orchestrator.md review-team step list is sequential 1..N" "got: ${list_numbers[*]}"
fi

report_results
