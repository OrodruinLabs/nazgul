#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.

# Test: the coverage-honesty contract holds across EVERY entry point named by
# RULES.md §15 — one with no conforming line FAILS here, never "nothing to check".
TEST_NAME="test-coverage-honesty"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-coverage-honesty-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

# Every entry point named by RULES.md §15; the tally at the bottom fails if one
# was never driven through _entry_covered.
ENTRY_POINTS="run-tests lean-comments test-shellcheck doctor comment-verifier heartbeat-triage self-audit audit-agent-state-paths"
COVERED=""

_entry_covered() {
  COVERED="$COVERED $1"
}

# _grammar_check <label> <entry-point> <closed-reason-list> <line> — grammar,
# N == M + K, and the closed reason list in order, summing to M.
_grammar_check() {
  local label="$1" entry="$2" reasons="$3" line="$4"
  local reason_re="" r first=1 n m k f sum
  for r in $reasons; do
    if [ "$first" = "1" ]; then reason_re="$r=([0-9]+)"; first=0
    else reason_re="$reason_re, $r=([0-9]+)"; fi
  done
  local grammar="^$entry: ([0-9]+) scanned, ([0-9]+) skipped \($reason_re\), ([0-9]+) checked, ([0-9]+) findings$"
  if ! printf '%s' "$line" | grep -qE "$grammar"; then
    _fail "$label: coverage line conforms to the RULES.md §15 grammar" "got: '$line'"
    return 1
  fi
  _pass "$label: coverage line conforms to the RULES.md §15 grammar"

  n=$(printf '%s' "$line" | sed -E 's/^[^:]*: ([0-9]+) scanned.*/\1/')
  m=$(printf '%s' "$line" | sed -E 's/^.* ([0-9]+) skipped \(.*/\1/')
  k=$(printf '%s' "$line" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
  f=$(printf '%s' "$line" | sed -E 's/^.*, ([0-9]+) findings$/\1/')
  assert_eq "$label: N == M + K" "$n" "$((m + k))"

  sum=0
  for r in $(printf '%s' "$line" | sed -E 's/^.*\(([^)]*)\).*/\1/' | tr ',' ' '); do
    case "$r" in
      *=*) sum=$((sum + ${r##*=})) ;;
    esac
  done
  assert_eq "$label: the enumerated skip reasons account for all M" "$sum" "$m"
  [ -n "$f" ] || _fail "$label: findings count is present" "line: '$line'"
  return 0
}

_last_line() { printf '%s' "$1" | tail -1; }

# run-tests.sh, forced all-skip: a filter no test file can match, so every
# candidate is scanned and skipped — looked-and-found-none, not never-looked.
RT_OUT=$(bash "$REPO_ROOT/tests/run-tests.sh" --filter=__nazgul_no_such_test__ 2>"$SCRATCH/rt.err")
RT_RC=$?
_grammar_check "run-tests (all-skip)" "run-tests" "filtered-out unreadable" "$(_last_line "$RT_OUT")" \
  && _entry_covered run-tests
assert_contains "run-tests: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/rt.err")" "run-tests: NOTHING CHECKED — all"
assert_exit_code "run-tests: a filter matching nothing is a hard failure" "$RT_RC" 2
assert_not_contains "run-tests: never claims a vacuous pass" "$RT_OUT" "All tests passed."

# lean-comments-guard.sh --check
mkdir -p "$SCRATCH/lc/nazgul/logs"
printf '{"schema_version":1}\n' > "$SCRATCH/lc/nazgul/config.json"
printf 'plain text, no comment style\n' > "$SCRATCH/lc/notes.txt"
LC_OUT=$(NAZGUL_CONFIG="$SCRATCH/lc/nazgul/config.json" \
  bash "$REPO_ROOT/scripts/lean-comments-guard.sh" --check "$SCRATCH/lc/notes.txt" 2>"$SCRATCH/lc.err")
LC_RC=$?
_grammar_check "lean-comments (all-skip)" "lean-comments" "unsupported-extension unreadable" "$(_last_line "$LC_OUT")" \
  && _entry_covered lean-comments
assert_contains "lean-comments: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/lc.err")" "lean-comments: NOTHING CHECKED — all 1 candidates skipped"
assert_exit_code "lean-comments: advisory surface — exit code unchanged by a vacuous run" "$LC_RC" 0
assert_contains "lean-comments: the vacuous run reaches the bus" \
  "$(cat "$SCRATCH/lc/nazgul/logs/events.jsonl" 2>/dev/null)" '"event":"coverage_vacuous"'

# test-shellcheck.sh: a directory named *.sh is a candidate the enumerator
# produces and the checker cannot open — deterministic without chmod games.
mkdir -p "$SCRATCH/sc/scripts/decoy.sh"
SC_OUT=$(NAZGUL_SHELLCHECK_SCAN_ROOT="$SCRATCH/sc" bash "$REPO_ROOT/tests/test-shellcheck.sh" 2>"$SCRATCH/sc.err")
SC_RC=$?
_grammar_check "test-shellcheck (all-skip)" "test-shellcheck" "not-a-file unreadable" "$(_last_line "$SC_OUT")" \
  && _entry_covered test-shellcheck
assert_contains "test-shellcheck: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/sc.err")" "test-shellcheck: NOTHING CHECKED — all 1 candidates skipped"
assert_exit_code "test-shellcheck: blocking — nothing checked is a failure" "$SC_RC" 1
SC_ZERO=$(NAZGUL_SHELLCHECK_SCAN_ROOT="$SCRATCH/lc" bash "$REPO_ROOT/tests/test-shellcheck.sh" 2>"$SCRATCH/sc0.err")
assert_exit_code "test-shellcheck: zero candidates is a broken enumerator, not a clean repo" "$?" 1
assert_contains "test-shellcheck: zero candidates is named as its own condition" \
  "$(cat "$SCRATCH/sc0.err")" "NOTHING CHECKED — no shell scripts discovered"
assert_contains "test-shellcheck: zero candidates still emits a coverage line" \
  "$(_last_line "$SC_ZERO")" "test-shellcheck: 0 scanned, 0 skipped (not-a-file=0, unreadable=0), 0 checked, 0 findings"

# doctor.sh, forced all-skip via --only on two checks with nothing to inspect.
# The one entry point with NO bus path: zero-write outranks the event.
mkdir -p "$SCRATCH/proj/nazgul"
git -C "$SCRATCH/proj" init -q 2>/dev/null
printf '{"schema_version":1,"guards":{"git_hooks":false}}\n' > "$SCRATCH/proj/nazgul/config.json"
DR_OUT=$(cd "$SCRATCH/proj" && bash "$REPO_ROOT/scripts/doctor.sh" --only=git-hooks,stacking 2>"$SCRATCH/dr.err")
DR_RC=$?
_grammar_check "doctor (all-skip)" "doctor" \
  "not-applicable-config not-applicable-env no-candidates unreadable" "$(_last_line "$DR_OUT")" \
  && _entry_covered doctor
assert_contains "doctor: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/dr.err")" "doctor: NOTHING CHECKED — all 2 candidates skipped"
assert_contains "doctor: a skipped check still reports pass with an explicit Not applicable" \
  "$DR_OUT" "Not applicable —"
assert_exit_code "doctor: exit code still encodes the worst verdict, not the coverage" "$DR_RC" 0
assert_file_not_exists "doctor: the nothing-checked path writes NO event (zero-write outranks the bus)" \
  "$SCRATCH/proj/nazgul/logs/events.jsonl"
DR_FULL=$(cd "$SCRATCH/proj" && bash "$REPO_ROOT/scripts/doctor.sh" 2>/dev/null)
_grammar_check "doctor (full run)" "doctor" \
  "not-applicable-config not-applicable-env no-candidates unreadable" "$(_last_line "$DR_FULL")"
DR_CHECKED=$(_last_line "$DR_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
if [ "${DR_CHECKED:-0}" -ge 1 ]; then
  _pass "doctor: a full run actually checks something"
else
  _fail "doctor: a full run actually checks something" "checked: $DR_CHECKED"
fi
assert_not_contains "doctor: a full run emits no nothing-checked signal" \
  "$(_last_line "$DR_FULL")" "NOTHING CHECKED"

# comment-verifier's emitter is an agent, not a process: the spec IS the
# contract, so the spec is asserted. Claiming to have run it would be the vacuity.
CV_SPEC=$(cat "$REPO_ROOT/agents/comment-verifier.md")
CV_LINE="comment-verifier: <N> scanned, <M> skipped (non-source=<a>, unreadable=<b>), <K> checked, <F> findings"
if _grammar_check "comment-verifier (spec template)" "comment-verifier" "non-source unreadable" \
  "$(printf '%s' "$CV_LINE" | sed -e 's/<N>/0/; s/<M>/0/; s/<a>/0/; s/<b>/0/; s/<K>/0/; s/<F>/0/')"; then
  assert_contains "comment-verifier: the spec states the grammar verbatim" "$CV_SPEC" "$CV_LINE"
  _entry_covered comment-verifier
fi
assert_contains "comment-verifier: the spec states the nothing-checked signal" \
  "$CV_SPEC" "comment-verifier: NOTHING CHECKED — all <N> candidates skipped"
assert_contains "comment-verifier: the spec routes the vacuous case to the bus" \
  "$CV_SPEC" 'coverage_vacuous \'
assert_contains "comment-verifier: the spec keeps the advisory disposition (exit code unchanged)" \
  "$CV_SPEC" "The exit code and"
assert_contains "comment-verifier: the spec names the filed marker defect rather than fixing it here" \
  "$CV_SPEC" "comment-verifier-marker-written-despite-findings.md"

# heartbeat-triage's stdout is a value channel (the winning id), so its coverage
# line is the last line of STDERR.
mkdir -p "$SCRATCH/hb/nazgul/logs" "$SCRATCH/hb/inbox"
printf '{"schema_version":1}\n' > "$SCRATCH/hb/nazgul/config.json"
printf '{ not valid json\n' > "$SCRATCH/hb/inbox/broken.json"
HB_ID=$(NAZGUL_DIR="$SCRATCH/hb/nazgul" bash -c \
  "source '$REPO_ROOT/scripts/lib/heartbeat-triage.sh'; heartbeat_pick '$SCRATCH/hb/inbox'" 2>"$SCRATCH/hb.err")
HB_RC=$?
_grammar_check "heartbeat-triage (all-skip)" "heartbeat-triage" "unsafe-id unreadable malformed" \
  "$(_last_line "$(cat "$SCRATCH/hb.err")")" && _entry_covered heartbeat-triage
assert_contains "heartbeat-triage: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/hb.err")" "heartbeat-triage: NOTHING CHECKED — all 1 candidates skipped"
assert_contains "heartbeat-triage: the vacuous run reaches the bus" \
  "$(cat "$SCRATCH/hb/nazgul/logs/events.jsonl" 2>/dev/null)" '"entry_point":"heartbeat-triage"'
assert_eq "heartbeat-triage: nothing actionable still returns no id" "$HB_ID" ""
assert_exit_code "heartbeat-triage: nothing actionable is still a non-zero return" "$HB_RC" 1

printf -- '---\npriority: 2\ntitle: real\n---\nbody\n' > "$SCRATCH/hb/inbox/ok.md"
NAZGUL_DIR="$SCRATCH/hb/nazgul" bash -c \
  "source '$REPO_ROOT/scripts/lib/heartbeat-triage.sh'; heartbeat_pick '$SCRATCH/hb/inbox'" \
  >/dev/null 2>"$SCRATCH/hb2.err"
_grammar_check "heartbeat-triage (mixed)" "heartbeat-triage" "unsafe-id unreadable malformed" \
  "$(_last_line "$(cat "$SCRATCH/hb2.err")")"
assert_contains "heartbeat-triage: a real candidate is counted as checked, not skipped" \
  "$(_last_line "$(cat "$SCRATCH/hb2.err")")" "2 scanned, 1 skipped (unsafe-id=0, unreadable=1, malformed=0), 1 checked"
assert_not_contains "heartbeat-triage: one checked candidate is not a vacuous run" \
  "$(cat "$SCRATCH/hb2.err")" "NOTHING CHECKED"

# self-audit, forced all-skip: with no .git under the project root the todo-delta
# miner's single candidate is not-applicable and every other miner enumerates none.
mkdir -p "$SCRATCH/sa/nazgul" "$SCRATCH/sa-transcripts"
printf '{"schema_version":1}\n' > "$SCRATCH/sa/nazgul/config.json"
SA_OUT=$(NAZGUL_TRANSCRIPTS_DIR="$SCRATCH/sa-transcripts" \
  bash "$REPO_ROOT/scripts/self-audit.sh" "$SCRATCH/sa/nazgul" 2>"$SCRATCH/sa.err")
SA_RC=$?
# Its run total is not the last stdout line — a completion notice follows it.
SA_TOTAL=$(printf '%s\n' "$SA_OUT" | grep -E '^self-audit: [0-9]+ scanned' | tail -1)
_grammar_check "self-audit (all-skip)" "self-audit" \
  "unreadable unclassifiable not-applicable" "$SA_TOTAL" && _entry_covered self-audit
assert_contains "self-audit: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/sa.err")" "self-audit: NOTHING CHECKED — all 1 candidate(s) skipped"
assert_exit_code "self-audit: advisory post-loop miner — a vacuous run never fails it" "$SA_RC" 0
_grammar_check "self-audit/todo-delta (per-miner)" "self-audit/todo-delta" \
  "unreadable unclassifiable not-applicable" \
  "$(printf '%s\n' "$SA_OUT" | grep -E '^self-audit/todo-delta: ' | tail -1)"

# A run with a real candidate must actually check something: an entry point that
# only ever conforms while vacuous is not covered by the contract.
mkdir -p "$SCRATCH/sa2/nazgul/reviews/TASK-001"
printf '{"schema_version":1}\n' > "$SCRATCH/sa2/nazgul/config.json"
printf -- '---\nverdict: APPROVE\n---\nfine.\n' \
  > "$SCRATCH/sa2/nazgul/reviews/TASK-001/code-reviewer.md"
SA2_OUT=$(NAZGUL_TRANSCRIPTS_DIR="$SCRATCH/sa-transcripts" \
  bash "$REPO_ROOT/scripts/self-audit.sh" "$SCRATCH/sa2/nazgul" 2>"$SCRATCH/sa2.err")
SA2_TOTAL=$(printf '%s\n' "$SA2_OUT" | grep -E '^self-audit: [0-9]+ scanned' | tail -1)
_grammar_check "self-audit (mixed)" "self-audit" \
  "unreadable unclassifiable not-applicable" "$SA2_TOTAL"
SA2_CHECKED=$(printf '%s' "$SA2_TOTAL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
if [ "${SA2_CHECKED:-0}" -ge 1 ]; then
  _pass "self-audit: a run with a real candidate actually checks something"
else
  _fail "self-audit: a run with a real candidate actually checks something" \
    "checked: $SA2_CHECKED"
fi
assert_not_contains "self-audit: one checked candidate is not a vacuous run" \
  "$(cat "$SCRATCH/sa2.err")" "NOTHING CHECKED"

# audit-agent-state-paths, forced all-skip: a roster holding one non-spec file, so
# the sole candidate is scanned, named, and counted rather than never looked at.
mkdir -p "$SCRATCH/ap/agents"
printf '{"domains":[]}\n' > "$SCRATCH/ap/agents/reviewer-domains.json"
AP_OUT=$(NAZGUL_AGENT_AUDIT_SCAN_ROOT="$SCRATCH/ap" \
  bash "$REPO_ROOT/scripts/audit-agent-state-paths.sh" 2>"$SCRATCH/ap.err")
AP_RC=$?
_grammar_check "audit-agent-state-paths (all-skip)" "audit-agent-state-paths" \
  "non-spec unreadable not-a-file" "$(_last_line "$AP_OUT")" && _entry_covered audit-agent-state-paths
assert_contains "audit-agent-state-paths: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/ap.err")" "audit-agent-state-paths: NOTHING CHECKED — all 1 candidate(s) skipped"
assert_exit_code "audit-agent-state-paths: advisory roster audit — a vacuous run never fails it" "$AP_RC" 0
# Pinned, not derived: an exported NAZGUL_AGENT_AUDIT_SCAN_ROOT would aim the "full run" at
# whatever tree the caller named, and an empty tree passes every assertion while checking nothing.
AP_FULL=$(NAZGUL_AGENT_AUDIT_SCAN_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/scripts/audit-agent-state-paths.sh" 2>/dev/null)
_grammar_check "audit-agent-state-paths (full run)" "audit-agent-state-paths" \
  "non-spec unreadable not-a-file" "$(_last_line "$AP_FULL")"
AP_CHECKED=$(_last_line "$AP_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
case "${AP_CHECKED:-}" in ''|*[!0-9]*) AP_CHECKED_N=0 ;; *) AP_CHECKED_N="$AP_CHECKED" ;; esac
if [ "$AP_CHECKED_N" -ge 1 ]; then
  _pass "audit-agent-state-paths: a full run actually checks something"
else
  _fail "audit-agent-state-paths: a full run actually checks something" "checked: $AP_CHECKED"
fi

# Enumeration completeness — the point of the whole file: an entry point with no
# emitter must FAIL here, not silently drop out of the list.
for entry in $ENTRY_POINTS; do
  case " $COVERED " in
    *" $entry "*) _pass "entry point '$entry' emits the coverage-honesty line" ;;
    *) _fail "entry point '$entry' emits the coverage-honesty line" \
         "no conforming line was produced by its driver — an entry point with no emitter is a gap, not a skip" ;;
  esac
done

COVERED_COUNT=$(printf '%s' "$COVERED" | wc -w | tr -d ' ')
EXPECTED_COUNT=$(printf '%s' "$ENTRY_POINTS" | wc -w | tr -d ' ')
assert_eq "every enumerated entry point was driven" "$COVERED_COUNT" "$EXPECTED_COUNT"

report_results
