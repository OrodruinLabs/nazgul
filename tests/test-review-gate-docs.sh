#!/usr/bin/env bash
set -euo pipefail

# Test: review-gate.md agent-prompt fixes (TASK-008, FEAT-017)
#   - WS2 (LR-002): review-gate.md's frontmatter pins model: sonnet, matching the
#     comment-verifier/doc-verifier/learner/self-audit precedent.
#   - MF-020: review-gate.md's step numbers are sequential (no out-of-order or
#     duplicate step numbers).
#
# The WS2/MF-043 checks against team-orchestrator.md's "Spawning a Review Team"
# section (models.review_orchestrator tier restatement, review-team step-list
# numbering) were retired along with that section by FEAT-026/ADR-017 — the
# tier requirement now lives solely on the replacement dispatch path
# (scripts/stop-hook.sh's DISPATCH_INSTR, review-gate.md's own model: sonnet
# pin), which this file already checks above.
TEST_NAME="test-review-gate-docs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

REVIEW_GATE="$REPO_ROOT/agents/review-gate.md"

assert_file_exists "review-gate.md exists" "$REVIEW_GATE"

# ── WS2: review-gate.md frontmatter pins model: sonnet ────
frontmatter=$(sed -n '2,/^---$/p' "$REVIEW_GATE" | sed '$d')
if echo "$frontmatter" | grep -q '^model: sonnet$'; then
  _pass "review-gate.md frontmatter pins model: sonnet"
else
  _fail "review-gate.md frontmatter pins model: sonnet" "no 'model: sonnet' line found in frontmatter"
fi

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

report_results
