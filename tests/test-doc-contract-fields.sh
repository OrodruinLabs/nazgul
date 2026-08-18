#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# Test: the merge-evidence field list the docs TEACH is bound to the constant the
# gate ENFORCES. The field names are read from the source, never authored here.
TEST_NAME="test-doc-contract-fields"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

GUARD_LIB="$REPO_ROOT/scripts/lib/task-transition-guard.sh"
CONST_NAME="_TTG_MERGE_REQUIRED_FIELDS"

# Documents an operator is expected to learn the block's shape from. This is a list
# of DOCUMENTS, not of fields — the fields come from the constant below.
DOC_PATHS="CLAUDE.md RULES.md"
REGION_MARKER="## Merge Evidence"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doc-contract-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

if [ ! -r "$GUARD_LIB" ]; then
  _fail "the gate library is readable" "not readable: $GUARD_LIB"
  report_results
  exit 1
fi

ASSIGNMENTS=$(grep -cE "^${CONST_NAME}=" "$GUARD_LIB")
assert_eq "${CONST_NAME} has exactly one top-level assignment in $(basename "$GUARD_LIB")" \
  "$ASSIGNMENTS" "1"

# shellcheck source=/dev/null
source "$GUARD_LIB"
FIELDS="${_TTG_MERGE_REQUIRED_FIELDS:-}"

if [ -z "$FIELDS" ]; then
  _fail "${CONST_NAME} is readable from the shell source" \
    "the constant is empty or unset after sourcing $GUARD_LIB" \
    "the field list could not be derived — this is 'never looked', not 'looked and found none'"
  report_results
  exit 1
fi
_pass "${CONST_NAME} is derived from the shell source (fields: ${FIELDS})"

FIELD_COUNT=0
for _f in $FIELDS; do FIELD_COUNT=$((FIELD_COUNT + 1)); done
DOC_COUNT=0
for _d in $DOC_PATHS; do DOC_COUNT=$((DOC_COUNT + 1)); done

# A field name is matched on its own token boundaries so `pr` cannot be satisfied by
# an unrelated word that merely contains it.
_field_in_file() {
  grep -qE "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|$)" "$2"
}

SCANNED=$((DOC_COUNT * FIELD_COUNT))
SKIPPED_UNREADABLE=0
CHECKED=0
FINDINGS=0

for doc in $DOC_PATHS; do
  doc_path="$REPO_ROOT/$doc"
  if [ ! -r "$doc_path" ]; then
    SKIPPED_UNREADABLE=$((SKIPPED_UNREADABLE + FIELD_COUNT))
    _skip "$doc: unreadable — its $FIELD_COUNT field bindings were not checked"
    continue
  fi

  blocks_dir="$SCRATCH/$(echo "$doc" | tr '/.' '__')"
  mkdir -p "$blocks_dir"
  block_count=$(awk -v outdir="$blocks_dir" -v marker="$REGION_MARKER" '
    BEGIN { RS = ""; n = 0 }
    index($0, marker) > 0 { n++; printf "%s\n", $0 > (outdir "/block-" n) }
    END { print n + 0 }
  ' "$doc_path")

  # Best region = the marker-bearing paragraph naming the most fields. One passage must
  # teach the whole list; a field scattered across unrelated paragraphs is not a lesson.
  best_file=""
  best_hits=-1
  i=1
  while [ "$i" -le "$block_count" ]; do
    candidate="$blocks_dir/block-$i"
    hits=0
    for field in $FIELDS; do
      _field_in_file "$field" "$candidate" && hits=$((hits + 1))
    done
    if [ "$hits" -gt "$best_hits" ]; then
      best_hits="$hits"
      best_file="$candidate"
    fi
    i=$((i + 1))
  done

  if [ -z "$best_file" ]; then
    CHECKED=$((CHECKED + FIELD_COUNT))
    FINDINGS=$((FINDINGS + FIELD_COUNT))
    _fail "$doc: contains a '$REGION_MARKER' passage to bind the field list to" \
      "no paragraph in $doc mentions '$REGION_MARKER'" \
      "every one of the $FIELD_COUNT fields is therefore undocumented, not merely unlocated"
    continue
  fi

  for field in $FIELDS; do
    CHECKED=$((CHECKED + 1))
    if _field_in_file "$field" "$best_file"; then
      _pass "$doc documents merge-evidence field '$field'"
    else
      FINDINGS=$((FINDINGS + 1))
      _fail "$doc documents merge-evidence field '$field'" \
        "'$field' is in $CONST_NAME but absent from $doc's '$REGION_MARKER' passage" \
        "the gate refuses a block missing it as 'truncated' — the doc teaches that block"
    fi
  done
done

SKIPPED=$SKIPPED_UNREADABLE
COVERAGE_LINE="$TEST_NAME: $SCANNED scanned, $SKIPPED skipped (unreadable=$SKIPPED_UNREADABLE), $CHECKED checked, $FINDINGS findings"
echo "  $COVERAGE_LINE"
assert_eq "$TEST_NAME: N == M + K" "$SCANNED" "$((SKIPPED + CHECKED))"

report_results
