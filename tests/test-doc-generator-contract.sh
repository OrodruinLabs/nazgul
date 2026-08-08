#!/usr/bin/env bash
set -uo pipefail
# Test: the doc-generator's Artifact Claim Evidence Ledger (FEAT-029 TASK-005,
# PRD AC6). The historical defect: a generated doc asserted the exact packaged
# path `content/orolab-api/.template.config/template.json` from source intent
# alone, while the real pack produced `content/templates/orolab-api/...`.
#
# This is a contract test over a prompt, so the producer is the render pipeline
# that actually hands the prompt to the agent (`render_agent_prompt`, the
# bootstrap-project path), not the file on disk. The row rules below are parsed
# OUT of the rendered contract and then applied to sample ledger rows: delete a
# clause from the contract and the corresponding assertion stops holding, which
# is what the two controls at the end demonstrate.

TEST_NAME="test-doc-generator-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/bootstrap-render.sh"

echo "=== $TEST_NAME ==="

DOC_GENERATOR="$REPO_ROOT/agents/doc-generator.md"
TEST_PLAN_TEMPLATE="$REPO_ROOT/templates/docs/test-plan.md"
CONFIG_TEMPLATE="$REPO_ROOT/templates/config.json"

for f in "$DOC_GENERATOR" "$TEST_PLAN_TEMPLATE" "$CONFIG_TEMPLATE"; do
  if [ ! -f "$f" ]; then
    _fail "required file exists: $f" "file not found"
  fi
done

# One `key: value` line from the machine-readable contract block. Empty when the
# block or key is absent — an absent contract must not read as a satisfied one.
spec_field() {
  printf '%s\n' "$1" | awk -v key="$2" '
    index($0, "artifact-claim-ledger:begin") { inb = 1; next }
    index($0, "artifact-claim-ledger:end")   { inb = 0 }
    inb && index($0, key ": ") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  '
}

ledger_section() {
  printf '%s\n' "$1" | awk '
    /^## Artifact Claim Evidence Ledger/ { ins = 1; print; next }
    ins && /^## / { ins = 0 }
    ins { print }
  '
}

example_rows() {
  printf '%s\n' "$1" | awk '
    /^\| *Claim *\| *Class *\| *Status *\|/ { inb = 1; next }
    inb && /^\|[- :|]*\|$/ { next }
    inb && /^\|/ { print; next }
    inb { inb = 0 }
  '
}

row_cells() {
  printf '%s\n' "$1" \
    | sed 's/^[[:space:]]*|//; s/|[[:space:]]*$//' \
    | tr '|' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

cell_at() { row_cells "$1" | sed -n "${2}p"; }
cell_count() { row_cells "$1" | wc -l | tr -d ' '; }

col_index() {
  printf '%s' "$SPEC_COLUMNS" | tr '|' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -n -x -F -e "$1" | head -1 | cut -d: -f1
}

# Applies the ledger rule AS DECLARED in the parsed contract: each check is gated
# on its own clause, so a clause removed upstream disarms exactly one assertion.
validate_row() {
  local row="$1"
  local n status claim command observed disposition bare_claim bare_observed

  n=$(cell_count "$row")
  if [ "$n" != "$SPEC_COL_COUNT" ]; then echo "REJECT:column_count"; return 0; fi

  claim=$(cell_at "$row" "$IDX_CLAIM")
  status=$(cell_at "$row" "$IDX_STATUS")
  command=$(cell_at "$row" "$IDX_COMMAND")
  observed=$(cell_at "$row" "$IDX_OBSERVED")
  disposition=$(cell_at "$row" "$IDX_DISPOSITION")

  case " $SPEC_STATUS_TOKENS " in
    *" $status "*) ;;
    *) echo "REJECT:status_token"; return 0 ;;
  esac

  if [ "$status" = "VERIFIED" ]; then
    case "$SPEC_VERIFIED_ROW" in
      *"command != n/a"*)
        if [ -z "$command" ] || [ "$command" = "n/a" ]; then echo "REJECT:verified_without_command"; return 0; fi ;;
    esac
    case "$SPEC_VERIFIED_ROW" in
      *"observed != n/a"*)
        if [ -z "$observed" ] || [ "$observed" = "n/a" ]; then echo "REJECT:verified_without_observed"; return 0; fi ;;
    esac
    case "$SPEC_VERIFIED_ROW" in
      *"observed contains claim"*)
        bare_claim=$(printf '%s' "$claim" | tr -d '`')
        bare_observed=$(printf '%s' "$observed" | tr -d '`')
        case "$bare_observed" in
          *"$bare_claim"*) ;;
          *) echo "REJECT:invented_evidence"; return 0 ;;
        esac ;;
    esac
    echo "OK"
    return 0
  fi

  case "$SPEC_UNVERIFIED_ROW" in
    *"command == n/a"*)
      if [ "$command" != "n/a" ]; then echo "REJECT:unverified_with_command"; return 0; fi ;;
  esac
  case "$SPEC_UNVERIFIED_ROW" in
    *"observed == n/a"*)
      if [ "$observed" != "n/a" ]; then echo "REJECT:unverified_with_observed"; return 0; fi ;;
  esac
  case "$SPEC_UNVERIFIED_ROW" in
    *"test-plan obligation"*)
      case "$disposition" in
        *test-plan*|*"test plan"*) ;;
        *) echo "REJECT:no_test_plan_obligation"; return 0 ;;
      esac ;;
  esac
  echo "OK"
}

SRC=$(cat "$DOC_GENERATOR")

setup_temp_dir
STATE_ROOT="$TEST_DIR/docgen-state"
mkdir -p "$STATE_ROOT"

RENDER_RC=0
RENDERED=$(render_agent_prompt "$DOC_GENERATOR" "$STATE_ROOT") || RENDER_RC=$?
assert_exit_code "doc-generator renders through the real bootstrap agent-prompt producer" "$RENDER_RC" 0

SPEC_COLUMNS=$(spec_field "$RENDERED" "columns")
SPEC_STATUS_TOKENS=$(spec_field "$RENDERED" "status_tokens")
SPEC_VERIFIED_ROW=$(spec_field "$RENDERED" "verified_row")
SPEC_UNVERIFIED_ROW=$(spec_field "$RENDERED" "unverified_row")
SPEC_DOC_REQUIRES=$(spec_field "$RENDERED" "document_requires")
SPEC_COMMAND_SOURCE=$(spec_field "$RENDERED" "command_source")
SPEC_FORBIDDEN=$(spec_field "$RENDERED" "forbidden")

assert_eq "the rendered contract declares the six ledger columns" \
  "$SPEC_COLUMNS" "claim | class | status | command | observed | disposition"
assert_eq "the rendered contract declares exactly two status tokens" \
  "$SPEC_STATUS_TOKENS" "VERIFIED UNVERIFIED"

SPEC_COL_COUNT=$(printf '%s\n' "$SPEC_COLUMNS" | tr '|' '\n' | wc -l | tr -d ' ')
IDX_CLAIM=$(col_index "claim")
IDX_STATUS=$(col_index "status")
IDX_COMMAND=$(col_index "command")
IDX_OBSERVED=$(col_index "observed")
IDX_DISPOSITION=$(col_index "disposition")
assert_eq "column positions resolve from the contract, not from this test's assumptions" \
  "$IDX_CLAIM/$IDX_STATUS/$IDX_COMMAND/$IDX_OBSERVED/$IDX_DISPOSITION" "1/3/4/5/6"

# --- AC1: source intent vs empirically verified output ---

LEDGER=$(ledger_section "$SRC")
assert_contains "the ledger separates what a project is meant to produce from what it does produce" \
  "$LEDGER" "tells you what the project is *meant* to produce"
assert_contains "the ledger names the inspected result of a real command as the only proof of output" \
  "$LEDGER" "Only the inspected result of a command that actually ran"
assert_contains "the ledger prohibits exact-path certainty from intent alone" \
  "$LEDGER" "Stating an exact generated path with certainty on the strength of intent alone is prohibited"
assert_contains "VERIFIED requires the observed text to literally contain the claimed path" \
  "$LEDGER" "the observed text must literally contain the claimed path"

# --- AC2: unsafe/unavailable yields a visible marker and a test-plan obligation ---

assert_contains "unsafe and unavailable verification reach the same UNVERIFIED outcome" \
  "$LEDGER" "Unsafe and unavailable end the same way: the claim is UNVERIFIED"
assert_contains "the ledger accepts an unverified claim but never a fabricated one" \
  "$LEDGER" "a fabricated command or a fabricated output excerpt is not"
assert_contains "a mismatched VERIFIED row is named as invented evidence and downgraded" \
  "$LEDGER" "is invented evidence: downgrade it to UNVERIFIED"
assert_contains "an unverified claim carries a visible marker in prose" \
  "$SPEC_DOC_REQUIRES" "visible UNVERIFIED marker in prose"
assert_contains "an unverified claim becomes a test-plan obligation" \
  "$SPEC_DOC_REQUIRES" "obligation row in the test plan"
assert_contains "the ledger routes obligations into the test plan's real section" \
  "$LEDGER" "## Acceptance Criteria Verification"
assert_file_contains "that section exists in the test-plan template the obligation lands in" \
  "$TEST_PLAN_TEMPLATE" "## Acceptance Criteria Verification"
assert_contains "the contract forbids assumed commands, assumed layouts, and invented output" \
  "$SPEC_FORBIDDEN" "assumed_command; assumed_layout; invented_observed"

# --- Framework neutrality: the command comes from config, never from a guess ---

assert_contains "verification reads the project's own configured build command" \
  "$SPEC_COMMAND_SOURCE" "project.build_command"
assert_contains "verification reads the project's own configured test command" \
  "$SPEC_COMMAND_SOURCE" "project.test_command"
assert_contains "the command source is the project config file" "$SPEC_COMMAND_SOURCE" "config.json"
assert_contains "the rendered command source follows the render pipeline's state root" \
  "$SPEC_COMMAND_SOURCE" "$STATE_ROOT/config.json"
assert_not_contains "the rendered command source leaves no unrendered nazgul/ path behind" \
  "$SPEC_COMMAND_SOURCE" "nazgul/config.json"
assert_file_contains "project.build_command is a real config key, not an invented one" \
  "$CONFIG_TEMPLATE" '"build_command"'
assert_file_contains "project.test_command is a real config key, not an invented one" \
  "$CONFIG_TEMPLATE" '"test_command"'
assert_contains "the ledger refuses to guess a command from language or framework" \
  "$LEDGER" "Do NOT derive a command from a language, framework, or file-extension guess"

for tok in "dotnet " "npm " "mvn " "gradle" "go test" "cargo " "pytest" "tests/run-tests.sh" "make "; do
  assert_not_contains "the ledger hardcodes no framework-specific command ($tok)" "$LEDGER" "$tok"
done

LEDGER_REFS=$(printf '%s\n' "$SRC" | grep -c "Artifact Claim Evidence Ledger")
if [ "$LEDGER_REFS" -ge 3 ]; then
  _pass "the ledger is wired into the generation process and critical rules, not an orphan section"
else
  _fail "the ledger is wired into the generation process and critical rules, not an orphan section" \
    "expected >= 3 references (section + Process + Critical Rules), found: $LEDGER_REFS"
fi

# --- Behavioral: the parsed rule applied to real rows. The `content/orolab-api/...`
# pair is the historical package-layout class, dishonest and honest. ---

ROW_VERIFIED_GOOD='| `dist/pkg-1.2.0.tgz` | build output | VERIFIED | `<project.build_command>` | listing shows `dist/pkg-1.2.0.tgz` | stated as an exact path |'
ROW_INVENTED='| `content/orolab-api/.template.config/template.json` | package layout | VERIFIED | `<project.build_command>` | `content/templates/orolab-api/.template.config/template.json` | stated as an exact path |'
ROW_HONEST_UNVERIFIED='| `content/orolab-api/.template.config/template.json` | package layout | UNVERIFIED | n/a | n/a | test-plan obligation: assert the packed template layout |'
ROW_FABRICATED_UNVERIFIED='| `content/orolab-api/config.json` | package layout | UNVERIFIED | `pack` | `content/orolab-api/config.json` | none |'
ROW_NO_OBLIGATION='| `content/orolab-api/config.json` | package layout | UNVERIFIED | n/a | n/a | left as written |'
ROW_UNKNOWN_STATUS='| `dist/pkg-1.2.0.tgz` | build output | ASSUMED | n/a | n/a | none |'
ROW_SHORT='| `dist/pkg-1.2.0.tgz` | build output | VERIFIED | n/a |'

assert_eq "a VERIFIED row whose observed output contains the claim is accepted" \
  "$(validate_row "$ROW_VERIFIED_GOOD")" "OK"
assert_eq "the historical package-layout claim, VERIFIED against output that disagrees, is rejected" \
  "$(validate_row "$ROW_INVENTED")" "REJECT:invented_evidence"
assert_eq "the same claim recorded UNVERIFIED with a test-plan obligation is accepted" \
  "$(validate_row "$ROW_HONEST_UNVERIFIED")" "OK"
assert_eq "an UNVERIFIED row carrying evidence it never ran is rejected" \
  "$(validate_row "$ROW_FABRICATED_UNVERIFIED")" "REJECT:unverified_with_command"
assert_eq "an UNVERIFIED row with no test-plan obligation is rejected" \
  "$(validate_row "$ROW_NO_OBLIGATION")" "REJECT:no_test_plan_obligation"
assert_eq "a row inventing a third status token is rejected" \
  "$(validate_row "$ROW_UNKNOWN_STATUS")" "REJECT:status_token"
assert_eq "a row missing evidence columns is rejected" \
  "$(validate_row "$ROW_SHORT")" "REJECT:column_count"

# The contract's own worked examples must satisfy the contract.
EXAMPLES=$(example_rows "$RENDERED")
EXAMPLE_COUNT=$(printf '%s\n' "$EXAMPLES" | grep -c '^|')
assert_eq "the contract ships two worked example rows" "$EXAMPLE_COUNT" "2"
EXAMPLE_VERDICTS=""
while IFS= read -r example_row; do
  [ -n "$example_row" ] || continue
  EXAMPLE_VERDICTS="${EXAMPLE_VERDICTS}$(validate_row "$example_row") "
done <<EXAMPLE_ROWS
$EXAMPLES
EXAMPLE_ROWS
assert_eq "both worked examples satisfy the rule they illustrate" "$EXAMPLE_VERDICTS" "OK OK "

# --- Controls: these assertions can fail ---

SAVED_VERIFIED_ROW="$SPEC_VERIFIED_ROW"
SPEC_VERIFIED_ROW="command != n/a; observed != n/a"
assert_eq "control: drop the observed-contains-claim clause and the invented row is accepted (the check is contract-driven)" \
  "$(validate_row "$ROW_INVENTED")" "OK"
SPEC_VERIFIED_ROW="$SAVED_VERIFIED_ROW"

STRIPPED=$(printf '%s\n' "$SRC" | awk '
  /^## Artifact Claim Evidence Ledger/ { skip = 1; next }
  skip && /^## / { skip = 0 }
  !skip { print }
')
assert_eq "control: the pre-contract prompt shape exposes no ledger columns" \
  "$(spec_field "$STRIPPED" "columns")" ""
assert_eq "control: the pre-contract prompt shape exposes no verified-row rule" \
  "$(spec_field "$STRIPPED" "verified_row")" ""
assert_not_contains "control: the pre-contract prompt shape carries no evidence-block marker" \
  "$STRIPPED" "artifact-claim-ledger:begin"

teardown_temp_dir
report_results
