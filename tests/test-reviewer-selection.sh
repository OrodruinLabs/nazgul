#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-reviewer-selection"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
RS="$REPO_ROOT/scripts/lib/reviewer-selection.sh"
echo "=== $TEST_NAME ==="

ROSTER="security-reviewer architect-reviewer qa-reviewer code-reviewer"

# doc-only diff: only security-reviewer selected, everything else skipped
out=$(bash "$RS" select --files "README.md docs/guide.md" --reviewers "$ROSTER")
assert_eq "doc-only SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer"
assert_contains "doc-only skips architect" "$out" "architect-reviewer:no architecture-surface change"
assert_contains "doc-only skips qa" "$out" "qa-reviewer:no tests/ change"
assert_contains "doc-only skips code-reviewer" "$out" "code-reviewer:doc-only change"

# tests/ change: qa-reviewer and code-reviewer selected, architect skipped
out=$(bash "$RS" select --files "tests/test-foo.sh" --reviewers "$ROSTER")
assert_eq "tests-only SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer qa-reviewer code-reviewer"
assert_contains "tests-only skips architect" "$out" "architect-reviewer:no architecture-surface change"

# agents/scripts change: architect + code-reviewer selected, qa skipped
out=$(bash "$RS" select --files "agents/implementer.md scripts/lib/foo.sh" --reviewers "$ROSTER")
assert_eq "agents/scripts SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer architect-reviewer code-reviewer"
assert_contains "agents/scripts skips qa" "$out" "qa-reviewer:no tests/ change"

# config-schema file counts as architecture surface too
out=$(bash "$RS" select --files "templates/config.json" --reviewers "$ROSTER")
assert_contains "config-schema selects architect" "$out" "SELECTED: security-reviewer architect-reviewer code-reviewer"

# MF-021: the five path patterns the classifier previously missed all count
# as architecture surface too — asserted via the SELECTED line only (several
# of these are also *.md doc files, an independent axis that separately
# controls whether code-reviewer is skipped as doc-only).
for f in "templates/feature.md" "references/verification-patterns.md" \
         ".github/workflows/test.yml" "RULES.md" "CLAUDE.md"; do
  out=$(bash "$RS" select --files "$f" --reviewers "$ROSTER")
  sel_line=$(printf '%s\n' "$out" | sed -n '1p')
  assert_contains "MF-021: '$f' selects architect" "$sel_line" "architect-reviewer"
done

# .github/workflows/*.yml is also non-doc, so code-reviewer is selected too.
out=$(bash "$RS" select --files ".github/workflows/test.yml" --reviewers "$ROSTER")
assert_eq "MF-021: workflow file (non-doc) SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer architect-reviewer code-reviewer"

# RULES.md/CLAUDE.md are also *.md doc files, so code-reviewer is skipped
# (doc-only change) even though architect-reviewer is selected.
out=$(bash "$RS" select --files "RULES.md" --reviewers "$ROSTER")
assert_eq "MF-021: RULES.md (doc) SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer architect-reviewer"
assert_contains "MF-021: RULES.md skips code-reviewer (doc-only)" "$out" "code-reviewer:doc-only change"

# mixed scope: src + tests -> architect skipped, everything else selected;
# unknown reviewers are always selected (never skipped on ambiguity)
out=$(bash "$RS" select --files "src/app.py tests/test_app.py" --reviewers "$ROSTER custom-reviewer")
assert_eq "mixed SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: security-reviewer qa-reviewer code-reviewer custom-reviewer"
assert_contains "mixed skips architect" "$out" "architect-reviewer:no architecture-surface change"

# empty --files: degrade to full board, nothing skipped
out=$(bash "$RS" select --files "" --reviewers "$ROSTER")
assert_eq "empty-files SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: $ROSTER"
assert_eq "empty-files SKIPPED empty" "$(printf '%s\n' "$out" | sed -n '2p')" "SKIPPED: "

# unparseable (whitespace-only) --files: same degrade-to-allow behavior
out=$(bash "$RS" select --files "   " --reviewers "$ROSTER")
assert_eq "whitespace-files SELECTED" "$(printf '%s\n' "$out" | sed -n '1p')" "SELECTED: $ROSTER"

# security-reviewer is never skipped, across every scenario above
for files in "README.md" "tests/x.sh" "agents/y.md" "" "src/z.py"; do
  out=$(bash "$RS" select --files "$files" --reviewers "$ROSTER")
  assert_contains "security never skipped (files='$files')" "$(printf '%s\n' "$out" | sed -n '1p')" "security-reviewer"
done

# only reviewers present in --reviewers may appear in output
out=$(bash "$RS" select --files "src/app.py" --reviewers "security-reviewer code-reviewer")
assert_not_contains "architect absent when not in roster" "$out" "architect-reviewer"
assert_not_contains "qa absent when not in roster" "$out" "qa-reviewer"

# --- verify subcommand (recompute-and-compare authenticity check) ---

rc=0
bash "$RS" verify --files "README.md" --reviewers "$ROSTER" \
  --claimed-skipped "architect-reviewer qa-reviewer code-reviewer" || rc=$?
assert_exit_code "verify: matching claim exits 0" "$rc" 0

# claimed skip does NOT match (qa claimed skipped but files touch tests/)
rc=0
bash "$RS" verify --files "tests/test-foo.sh" --reviewers "$ROSTER" \
  --claimed-skipped "qa-reviewer" || rc=$?
assert_exit_code "verify: mismatched claim exits 1" "$rc" 1

# claiming nothing skipped when a skip is legitimate -> set inequality
rc=0
bash "$RS" verify --files "README.md" --reviewers "$ROSTER" --claimed-skipped "" || rc=$?
assert_exit_code "verify: under-claim (missing skip) exits 1" "$rc" 1

# order independence of the claimed-skipped set
rc=0
bash "$RS" verify --files "README.md" --reviewers "$ROSTER" \
  --claimed-skipped "code-reviewer qa-reviewer architect-reviewer" || rc=$?
assert_exit_code "verify: claim order independent" "$rc" 0

# empty files (degrade to full board, nothing skipped) -> empty claim matches
rc=0
bash "$RS" verify --files "" --reviewers "$ROSTER" --claimed-skipped "" || rc=$?
assert_exit_code "verify: empty files + empty claim exits 0" "$rc" 0

report_results
