#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# lean-comments: allow-run — why this file exists at all is the whole argument, and it is the
# reason two hardening fixes shipped as regressions.
# A PINNED CORPUS of manifest spellings that must ALWAYS read as a live typed reconciliation
# quarantine. The recogniser has been narrowed FOUR times, twice by a change written to harden it.
# Each narrowing was verified against the ONE input its report named, went red then green, and
# shipped — because "drive it red on the reported case" proves a test can fail and says NOTHING
# about what the fix stopped catching. The regressions lived only in the DIFFERENCE between the old
# predicate and the new one, which no test compared.
# So the durable check is not old-vs-new (after a refactor there is no "old"): it is a set of shapes
# that MUST be refused. A consolidation that narrows the predicate turns this red whichever
# direction it narrowed in, and whatever it was trying to fix.
# ADDING ROWS IS THE POINT. Removing one requires an argument that the shape is genuinely not a
# quarantine — never that it is inconvenient.
TEST_NAME="test-quarantine-refusal-corpus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

# Each row: <label>|<manifest text>. Provenance is named so a reader can tell a real shape
# from a guess.
QC_ROWS=(
  "canonical|- **Blocked kind**: reconciliation"
  "two spaces after the dash (PATCH-007 item 9)|-  **Blocked kind**: reconciliation"
  "tab after the dash (same class, never reported)|-	**Blocked kind**: reconciliation"
  "indented two spaces (3rd pass item 4)|  - **Blocked kind**: reconciliation"
  "indented with a tab (same class)|	- **Blocked kind**: reconciliation"
  "second of two kind lines (3rd pass item 1 REGRESSION)|- **Blocked kind**: review-evidence
- **Blocked kind**: reconciliation"
  "reconciliation first, another kind after|- **Blocked kind**: reconciliation
- **Blocked kind**: review-evidence"
  "trailing whitespace after the value|- **Blocked kind**: reconciliation   "
  "uppercase field name|- **BLOCKED KIND**: reconciliation"
  "mixed case value|- **Blocked kind**: Reconciliation"
  "surrounded by other manifest fields|## Metadata
- **Status**: BLOCKED
- **Blocked kind**: reconciliation
- **Blocked from**: DONE"
)

QC_SCANNED=0; QC_CHECKED=0; QC_FINDINGS=0; QC_MISSED=""
for _row in "${QC_ROWS[@]}"; do
  QC_SCANNED=$((QC_SCANNED + 1)); QC_CHECKED=$((QC_CHECKED + 1))
  _label="${_row%%|*}"; _text="${_row#*|}"
  if ttg_is_reconciliation_quarantine "$_text"; then
    _pass "corpus: detected — $_label"
  else
    QC_FINDINGS=$((QC_FINDINGS + 1)); QC_MISSED="$QC_MISSED$_label; "
    _fail "corpus: detected — $_label" \
      "this spelling is a live typed reconciliation quarantine and the recogniser did not see it" \
      "  a record NOT seen costs the block itself — BLOCKED -> CANCELLED would be ADMITTED here"
  fi
done

# The counter-corpus: a predicate widened until it matches everything refuses nothing useful,
# so the set above is only meaningful beside this one.
QC_NEG=(
  "already repaired, so it cannot re-qualify|- **Blocked kind**: reconciliation (repaired 2026-08-24)"
  "a different kind entirely|- **Blocked kind**: review-evidence"
  "a different kind entirely (git conflict)|- **Blocked kind**: git-conflict"
  "the word inside prose, not a field|This task mentions reconciliation in its description."
  "field present but blanked|- **Blocked kind**:"
)
for _row in "${QC_NEG[@]}"; do
  QC_SCANNED=$((QC_SCANNED + 1)); QC_CHECKED=$((QC_CHECKED + 1))
  _label="${_row%%|*}"; _text="${_row#*|}"
  if ttg_is_reconciliation_quarantine "$_text"; then
    QC_FINDINGS=$((QC_FINDINGS + 1))
    _fail "counter-corpus: NOT detected — $_label" \
      "the recogniser matched a shape that is not a live typed reconciliation quarantine" \
      "  a predicate that matches everything refuses nothing"
  else
    _pass "counter-corpus: NOT detected — $_label"
  fi
done

# A floor, so a vanished recogniser cannot pass this file by checking nothing (RULES.md §15).
QC_FLOOR=12
if [ "$QC_CHECKED" -ge "$QC_FLOOR" ]; then
  _pass "corpus floor: the recogniser was actually exercised ($QC_CHECKED shapes >= $QC_FLOOR)"
else
  _fail "corpus floor: the recogniser was actually exercised" \
    "only $QC_CHECKED shape(s) driven — a shrunken corpus is a weakened gate, not a clean one"
fi

printf '  quarantine-corpus: %d scanned, 0 skipped, %d checked, %d findings\n' \
  "$QC_SCANNED" "$QC_CHECKED" "$QC_FINDINGS"
assert_eq "quarantine-corpus: scanned == skipped + checked" "$QC_SCANNED" "$((0 + QC_CHECKED))"
assert_eq "quarantine-corpus: every pinned spelling is still refused" "${QC_MISSED% }" ""

report_results
