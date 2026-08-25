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

# lean-comments: allow-run — the tautology this derivation replaces, kept at the derivation.
# The denominator is DERIVED from RULES.md §15's own registry bullet by
# tests/lib/rules-registry.sh, never authored here: an authored copy counts the list
# it validates, so it can never disagree with itself, and a member added to the
# registry with no driver would read as covered.
RULES_DOC="$REPO_ROOT/RULES.md"
# shellcheck disable=SC2034  # read by tests/lib/rules-registry.sh, not within this file
REGISTRY_DRIVER_REL="tests/$(basename "$0")"
source "$SCRIPT_DIR/lib/rules-registry.sh"

REGISTRY_MEMBERS=$(_registry_members "$RULES_DOC")
REGISTRY_N=$(printf '%s\n' "$REGISTRY_MEMBERS" | grep -c . || true)
ENTRY_POINTS=""
while IFS= read -r _rp; do
  [ -n "$_rp" ] || continue
  ENTRY_POINTS="${ENTRY_POINTS}$(_registry_token "$_rp" "$REPO_ROOT")
"
done <<< "$REGISTRY_MEMBERS"
COVERED=""

REGISTRY_FLOOR=5
if [ "$REGISTRY_N" -ge "$REGISTRY_FLOOR" ]; then
  _pass "RULES.md §15: the registry bullet was actually parsed ($REGISTRY_N members >= $REGISTRY_FLOOR)"
else
  _fail "RULES.md §15: the registry bullet was actually parsed" \
    "derived $REGISTRY_N member(s) from $RULES_DOC — a derivation that finds nothing is 'never looked', not an empty registry"
fi
assert_eq "RULES.md §15: the registry's stated size matches the members derived from it" \
  "$REGISTRY_N" "$(_registry_declared_count "$RULES_DOC")"

_entry_covered() {
  COVERED="$COVERED $1"
}

# _grammar_check <label> <entry-point> <closed-reason-list> <line> [<k-noun> <f-noun>] —
# grammar, N == M + K, reasons in order summing to M; nouns default to checked/findings.
_grammar_check() {
  local label="$1" entry="$2" reasons="$3" line="$4"
  local knoun="${5:-checked}" fnoun="${6:-findings}"
  local reason_re="" r first=1 n m k f sum
  for r in $reasons; do
    if [ "$first" = "1" ]; then reason_re="$r=([0-9]+)"; first=0
    else reason_re="$reason_re, $r=([0-9]+)"; fi
  done
  local grammar="^$entry: ([0-9]+) scanned, ([0-9]+) skipped \($reason_re\), ([0-9]+) $knoun, ([0-9]+) $fnoun$"
  if ! printf '%s' "$line" | grep -qE "$grammar"; then
    _fail "$label: coverage line conforms to the RULES.md §15 grammar" "got: '$line'"
    return 1
  fi
  _pass "$label: coverage line conforms to the RULES.md §15 grammar"

  n=$(printf '%s' "$line" | sed -E 's/^[^:]*: ([0-9]+) scanned.*/\1/')
  m=$(printf '%s' "$line" | sed -E 's/^.* ([0-9]+) skipped \(.*/\1/')
  k=$(printf '%s' "$line" | sed -E "s/^.*\), ([0-9]+) $knoun.*/\1/")
  f=$(printf '%s' "$line" | sed -E "s/^.*, ([0-9]+) $fnoun\$/\1/")
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

# test-dispatch-brief-contract, forced all-skip: a candidate file holding no
# dispatch site at all — scanned, counted, and named, never never-looked-at.
mkdir -p "$SCRATCH/db/skills/fake"
printf '# nothing to dispatch here\n' > "$SCRATCH/db/skills/fake/SKILL.md"
DB_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$SCRATCH/db" \
  bash "$REPO_ROOT/tests/test-dispatch-brief-contract.sh" 2>"$SCRATCH/db.err")
DB_RC=$?
_grammar_check "test-dispatch-brief-contract (all-skip)" "test-dispatch-brief-contract" \
  "no-dispatch-site unreadable" "$(_last_line "$DB_OUT")" && _entry_covered test-dispatch-brief-contract
assert_contains "test-dispatch-brief-contract: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/db.err")" "test-dispatch-brief-contract: NOTHING CHECKED — all 1 candidates skipped"
assert_exit_code "test-dispatch-brief-contract: blocking — nothing checked is a failure" "$DB_RC" 1
# Pinned, not derived: an inherited scan root would aim the "full run" at whatever
# tree the caller named, and an empty tree passes while checking nothing.
DB_FULL=$(NAZGUL_DISPATCH_SCAN_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/test-dispatch-brief-contract.sh" 2>/dev/null)
_grammar_check "test-dispatch-brief-contract (full run)" "test-dispatch-brief-contract" \
  "no-dispatch-site unreadable" "$(_last_line "$DB_FULL")"
DB_CHECKED=$(_last_line "$DB_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
case "${DB_CHECKED:-}" in ''|*[!0-9]*) DB_CHECKED_N=0 ;; *) DB_CHECKED_N="$DB_CHECKED" ;; esac
if [ "$DB_CHECKED_N" -ge 1 ]; then
  _pass "test-dispatch-brief-contract: a full run actually checks something"
else
  _fail "test-dispatch-brief-contract: a full run actually checks something" "checked: $DB_CHECKED"
fi

# close-objective, forced all-skip: one already-DONE manifest, listed in its objective's own
# roster so the scan reaches it, in a tree with no remote — counted, and no host is asked.
CO_REASONS="already-terminal not-closable-status unreadable not-this-objective pr-not-this-objective not-merged merge-unverifiable evidence-write-failed transition-refused"
mkdir -p "$SCRATCH/co/nazgul/tasks" "$SCRATCH/co/nazgul/logs"
printf '{"schema_version":1,"feat_id":"FEAT-001"}\n' > "$SCRATCH/co/nazgul/config.json"
printf -- '---\nfeat_id: FEAT-001\n---\n# Plan\n\n## Tasks\n\n| TASK-001 | already closed | DONE |\n' \
  > "$SCRATCH/co/nazgul/plan.md"
printf -- '---\nstatus: DONE\n---\n# TASK-001: already closed\n' > "$SCRATCH/co/nazgul/tasks/TASK-001.md"
CO_OUT=$(bash "$REPO_ROOT/scripts/close-objective.sh" --pr 1 --project-root "$SCRATCH/co" 2>"$SCRATCH/co.err")
CO_RC=$?
_grammar_check "close-objective (all-skip)" "close-objective" "$CO_REASONS" "$(_last_line "$CO_OUT")" \
  closed refused && _entry_covered close-objective
assert_contains "close-objective: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/co.err")" "close-objective: NOTHING CHECKED — all 1 candidate(s) skipped"
assert_exit_code "close-objective: blocking — nothing closed is a failure" "$CO_RC" 2
assert_contains "close-objective: the vacuous run reaches the bus" \
  "$(cat "$SCRATCH/co/nazgul/logs/events.jsonl" 2>/dev/null)" '"entry_point":"close-objective"'

# test-messaging-posture, forced empty surface root: no shipped surface exists to
# enumerate, so the K>0 floor must FAIL rather than report a clean surface.
mkdir -p "$SCRATCH/empty"
MP_OUT=$(NAZGUL_POSTURE_SURFACE_ROOT="$SCRATCH/empty" \
  bash "$REPO_ROOT/tests/test-messaging-posture.sh" 2>"$SCRATCH/mp.err")
MP_RC=$?
_grammar_check "test-messaging-posture (empty surface root)" "test-messaging-posture" \
  "unreadable" "$(_last_line "$MP_OUT")" && _entry_covered test-messaging-posture
assert_contains "test-messaging-posture: a zero-check scan names the K>0 floor as its failure" \
  "$MP_OUT" "FAIL: K>0 floor: the scan examined at least one file"
assert_contains "test-messaging-posture: an all-skipped run says NOTHING CHECKED on stderr" \
  "$(cat "$SCRATCH/mp.err")" \
  "test-messaging-posture: NOTHING CHECKED — no shipped surface files discovered under $SCRATCH/empty"
assert_exit_code "test-messaging-posture: blocking — a scan that scans nothing is a failure" "$MP_RC" 1
# Pinned, not derived: an inherited surface root would aim the "full run" at whatever
# tree the caller named, and an empty tree passes while checking nothing.
MP_FULL=$(NAZGUL_POSTURE_SURFACE_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/test-messaging-posture.sh" 2>/dev/null)
_grammar_check "test-messaging-posture (full run)" "test-messaging-posture" \
  "unreadable" "$(_last_line "$MP_FULL")"
MP_CHECKED=$(_last_line "$MP_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
case "${MP_CHECKED:-}" in ''|*[!0-9]*) MP_CHECKED_N=0 ;; *) MP_CHECKED_N="$MP_CHECKED" ;; esac
if [ "$MP_CHECKED_N" -ge 1 ]; then
  _pass "test-messaging-posture: a full run actually checks something"
else
  _fail "test-messaging-posture: a full run actually checks something" "checked: $MP_CHECKED"
fi

# test-shared-ignore-coverage, forced all-skip scan root: one source file carrying
# no nazgul/ path at all — scanned, counted and named, never never-looked-at.
mkdir -p "$SCRATCH/ig/scripts"
printf '#!/usr/bin/env bash\necho no state path is named here\n' > "$SCRATCH/ig/scripts/plain.sh"
IG_OUT=$(NAZGUL_IGNORE_SWEEP_ROOT="$SCRATCH/ig" \
  bash "$REPO_ROOT/tests/test-shared-ignore-coverage.sh" 2>"$SCRATCH/ig.err")
IG_RC=$?
_grammar_check "test-shared-ignore-coverage (all-skip)" "test-shared-ignore-coverage" \
  "no-nazgul-path unreadable" "$(_last_line "$IG_OUT")" && _entry_covered test-shared-ignore-coverage
assert_contains "test-shared-ignore-coverage: a zero-check sweep names the K>0 floor as its failure" \
  "$IG_OUT" "FAIL: K>0 floor: the sweep examined at least one file"
assert_contains "test-shared-ignore-coverage: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/ig.err")" "test-shared-ignore-coverage: NOTHING CHECKED — all 1 candidates skipped"
assert_exit_code "test-shared-ignore-coverage: blocking — nothing checked is a failure" "$IG_RC" 1
# Pinned, not derived: an inherited scan root would aim the "full run" at whatever
# tree the caller named, and an empty tree passes while checking nothing.
IG_FULL=$(NAZGUL_IGNORE_SWEEP_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/test-shared-ignore-coverage.sh" 2>/dev/null)
_grammar_check "test-shared-ignore-coverage (full run)" "test-shared-ignore-coverage" \
  "no-nazgul-path unreadable" "$(_last_line "$IG_FULL")"
IG_CHECKED=$(_last_line "$IG_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
case "${IG_CHECKED:-}" in ''|*[!0-9]*) IG_CHECKED_N=0 ;; *) IG_CHECKED_N="$IG_CHECKED" ;; esac
if [ "$IG_CHECKED_N" -ge 1 ]; then
  _pass "test-shared-ignore-coverage: a full run actually checks something"
else
  _fail "test-shared-ignore-coverage: a full run actually checks something" "checked: $IG_CHECKED"
fi

# test-doc-contract-fields, forced empty doc root: every document is unreadable, so every
# claim binding is scanned and skipped rather than never enumerated.
mkdir -p "$SCRATCH/nodocs"
DC_OUT=$(NAZGUL_DOC_CONTRACT_DOC_ROOT="$SCRATCH/nodocs" \
  bash "$REPO_ROOT/tests/test-doc-contract-fields.sh" 2>"$SCRATCH/dc.err")
DC_RC=$?
_grammar_check "test-doc-contract-fields (all-skip)" "test-doc-contract-fields" \
  "unreadable no-claim" "$(_last_line "$DC_OUT")" && _entry_covered test-doc-contract-fields
# The candidate count is read back off the same run's own coverage line: pinning the number
# here would make a document added to the derived population read as a defect.
DC_SCANNED=$(_last_line "$DC_OUT" | sed -E 's/^[^:]*: ([0-9]+) scanned.*/\1/')
case "${DC_SCANNED:-}" in ''|*[!0-9]*) DC_SCANNED_N=0 ;; *) DC_SCANNED_N="$DC_SCANNED" ;; esac
assert_contains "test-doc-contract-fields: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/dc.err")" "test-doc-contract-fields: NOTHING CHECKED — all $DC_SCANNED_N candidates skipped"
if [ "$DC_SCANNED_N" -ge 12 ]; then
  _pass "test-doc-contract-fields: the all-skip run still enumerated its candidates ($DC_SCANNED_N >= 12)"
else
  _fail "test-doc-contract-fields: the all-skip run still enumerated its candidates" \
    "scanned $DC_SCANNED_N — an all-skip run that enumerates nothing proves nothing"
fi
assert_exit_code "test-doc-contract-fields: blocking — nothing checked is a failure" "$DC_RC" 1
# Pinned, not derived: an inherited doc root would aim the "full run" at whatever tree
# the caller named, and a tree holding no documents passes while checking nothing.
DC_FULL=$(NAZGUL_DOC_CONTRACT_DOC_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/test-doc-contract-fields.sh" 2>/dev/null)
_grammar_check "test-doc-contract-fields (full run)" "test-doc-contract-fields" \
  "unreadable no-claim" "$(_last_line "$DC_FULL")"
DC_CHECKED=$(_last_line "$DC_FULL" | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
case "${DC_CHECKED:-}" in ''|*[!0-9]*) DC_CHECKED_N=0 ;; *) DC_CHECKED_N="$DC_CHECKED" ;; esac
if [ "$DC_CHECKED_N" -ge 1 ]; then
  _pass "test-doc-contract-fields: a full run actually checks something"
else
  _fail "test-doc-contract-fields: a full run actually checks something" "checked: $DC_CHECKED"
fi

# red-run-evidence (scripts/lib/task-transition-guard.sh), all-skip on BOTH its scans; the
# gate's seven dispositions decide allow/deny, so a vacuous scan reports, never re-decides.
mkdir -p "$SCRATCH/rr/nazgul" "$SCRATCH/rr/tests"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
printf '{"schema_version":1,"project":{"test_roots":["gone-a","gone-b"]}}\n' > "$SCRATCH/rr/nazgul/config.json"
NAZGUL_DIR="$SCRATCH/rr/nazgul" \
  _ttg_red_run_in_scope "## Metadata
- **ID**: TASK-001
- **Files modified**: [\"docs/PRD.md\"]
" "$SCRATCH/rr" "$SCRATCH/rr/nazgul" >/dev/null 2>"$SCRATCH/rr-roots.err"
RR_ROOTS_LINE=$(grep -E '^red-run-evidence/tests-root: [0-9]+ scanned' "$SCRATCH/rr-roots.err" | tail -1)
_grammar_check "red-run-evidence/tests-root (all-skip)" "red-run-evidence/tests-root" \
  "unsafe unresolvable" "$RR_ROOTS_LINE" && RR_ROOTS_OK=1
assert_contains "red-run-evidence/tests-root: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/rr-roots.err")" "red-run-evidence/tests-root: NOTHING CHECKED — all 2 candidate(s) skipped"
assert_contains "red-run-evidence/tests-root: the §15 line ends at findings; context is its own line" \
  "$(cat "$SCRATCH/rr-roots.err")" "red-run-evidence/tests-root: context=red-run scope predicate;"

# The per-file scan, forced all-skip: one changed test file discharged by an enumerated
# N/A, so the population is enumerated and every member lands in a named skip bucket.
git -C "$SCRATCH/rr" init -q 2>/dev/null
git -C "$SCRATCH/rr" config user.email t@t.t; git -C "$SCRATCH/rr" config user.name t
printf '{"schema_version":1,"project":{"test_roots":["tests"]}}\n' > "$SCRATCH/rr/nazgul/config.json"
printf '#!/usr/bin/env bash\necho x\n' > "$SCRATCH/rr/tests/test-x.sh"
git -C "$SCRATCH/rr" add -A >/dev/null 2>&1
git -C "$SCRATCH/rr" commit -q -m "seed" >/dev/null 2>&1
RR_SHA=$(git -C "$SCRATCH/rr" rev-parse HEAD)
NAZGUL_DIR="$SCRATCH/rr/nazgul" ttg_verify_red_run_evidence "## Metadata
- **ID**: TASK-001
- **Files modified**: [\"tests/test-x.sh\"]

## Commits
- $RR_SHA

## Red-Run Evidence
- red-run: N/A — revert
" "$SCRATCH/rr" TASK-001 2>"$SCRATCH/rr-files.err"
RR_FILES_LINE=$(grep -E '^red-run-evidence/files: [0-9]+ scanned' "$SCRATCH/rr-files.err" | tail -1)
_grammar_check "red-run-evidence/files (all-skip)" "red-run-evidence/files" \
  "support enumerated-na" "$RR_FILES_LINE" && RR_FILES_OK=1
assert_contains "red-run-evidence/files: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/rr-files.err")" "red-run-evidence/files: NOTHING CHECKED — all 1 candidate(s) skipped"
# One entry point, two scans: it is covered only when BOTH conform, never on the easier one.
[ "${RR_ROOTS_OK:-0}${RR_FILES_OK:-0}" = "11" ] && _entry_covered red-run-evidence

# And a run with a real candidate must actually check something: an entry point that only
# ever conforms while vacuous is not covered by the contract.
printf '#!/usr/bin/env bash\necho y\n' > "$SCRATCH/rr/tests/test-y.sh"
git -C "$SCRATCH/rr" add -A >/dev/null 2>&1
git -C "$SCRATCH/rr" commit -q -m "second" >/dev/null 2>&1
RR_SHA2=$(git -C "$SCRATCH/rr" rev-parse HEAD)
NAZGUL_DIR="$SCRATCH/rr/nazgul" ttg_verify_red_run_evidence "## Metadata
- **ID**: TASK-001
- **Files modified**: [\"tests/test-y.sh\"]

## Commits
- $RR_SHA2

## Red-Run Evidence
- red-run: tests/test-y.sh :: case \"x\"
  - pre-change-ref: $RR_SHA
  - result: FAILED (exit 1)
" "$SCRATCH/rr" TASK-001 2>"$SCRATCH/rr-full.err"
RR_FULL_LINE=$(grep -E '^red-run-evidence/files: [0-9]+ scanned' "$SCRATCH/rr-full.err" | tail -1)
_grammar_check "red-run-evidence/files (mixed)" "red-run-evidence/files" \
  "support enumerated-na" "$RR_FULL_LINE"
assert_contains "red-run-evidence: a run with a real candidate actually checks something" \
  "$RR_FULL_LINE" "1 checked"
assert_not_contains "red-run-evidence: one checked candidate is not a vacuous run" \
  "$(cat "$SCRATCH/rr-full.err")" "NOTHING CHECKED"

# The derivation, dogfooded against scratch registries: the shipped RULES.md
# yields exactly the driven set, so the failing directions never run against it.
REG_MUT="$SCRATCH/rules-mutant.md"
{
  printf -- '- **The registry of bound entry points lives HERE, not in a per-objective TRD.** `[enforced]` Twelve entry points are bound\n'
  printf -- '  by the contract above: `tests/run-tests.sh`, `scripts/lean-comments-guard.sh --check`,\n'
  printf -- '  `tests/test-phantom-entry.sh`, and `tests/test-coverage-honesty.sh` drives every one of them.\n'
  printf -- '\n'
} > "$REG_MUT"
MUT_MEMBERS=$(_registry_members "$REG_MUT")
assert_contains "registry dogfood: a member added to the bullet is derived" \
  "$MUT_MEMBERS" "tests/test-phantom-entry.sh"
assert_not_contains "registry dogfood: the driver named in its own bullet is not a member" \
  "$MUT_MEMBERS" "tests/test-coverage-honesty.sh"
MUT_TOKENS=$(while IFS= read -r _rp; do [ -n "$_rp" ] || continue; _registry_token "$_rp" "$REPO_ROOT"; done <<< "$MUT_MEMBERS")
assert_contains "registry dogfood: a registered member nothing drives is reported missing" \
  "$(_registry_missing "$MUT_TOKENS" "$COVERED")" "test-phantom-entry"
assert_eq "registry dogfood: the stated size is read from the bullet, not from the list" \
  "$(_registry_declared_count "$REG_MUT")" "12"
assert_eq "registry dogfood: a bullet stating 12 while listing 3 is a contradiction the test can see" \
  "$(printf '%s\n' "$MUT_MEMBERS" | grep -c .)" "3"

REG_GONE="$SCRATCH/rules-no-registry.md"
printf '## 15. Git-Level Guards\n\nno registry bullet here at all\n' > "$REG_GONE"
assert_eq "registry dogfood: a doc with no registry bullet derives nothing (the floor's input)" \
  "$(_registry_members "$REG_GONE" | grep -c . || true)" "0"

# review-file-class prints for BOTH DONE-gate passes, so — like red-run-evidence's two scans — the
# entry is covered only when BOTH tokens conform. Forced all-skip: a dir of orchestrator artifacts.
RFC_EVIDENCE_OK=0; RFC_PROVENANCE_OK=0
mkdir -p "$SCRATCH/re/nazgul/reviews/TASK-001"
source "$REPO_ROOT/scripts/lib/review-evidence.sh"
printf '{"schema_version":1,"agents":{"reviewers":["code-reviewer"]},"review_gate":{"granularity":"task"}}\n' \
  > "$SCRATCH/re/nazgul/config.json"
printf '# BOARD-2-OUTCOME\n' > "$SCRATCH/re/nazgul/reviews/TASK-001/BOARD-2-OUTCOME.md"
printf '# adversarial\n' > "$SCRATCH/re/nazgul/reviews/TASK-001/adversarial-SEC-1.md"
RE_OUT=$(validate_review_evidence "$SCRATCH/re/nazgul" TASK-001 2>"$SCRATCH/re.err") || true
RE_LINE=$(grep -E '^review-evidence/verdict-files: [0-9]+ scanned' "$SCRATCH/re.err" | tail -1)
_grammar_check "review-evidence/verdict-files (all-skip)" "review-evidence/verdict-files" \
  "artifact non-seat superseded" "$RE_LINE" && RFC_EVIDENCE_OK=1
assert_contains "review-evidence: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/re.err")" "review-evidence/verdict-files: NOTHING CHECKED — all 2 candidate(s) skipped"
# This entry point's floor BLOCKS rather than only reporting: an all-skipped scan is the exact
# shape of a classifier that stopped matching, which must never read as a clean review directory.
assert_contains "review-evidence: the blocking floor reaches the caller, not just stderr" \
  "$RE_OUT" "NOTHING_CHECKED"

# And a run with a real reviewer file must actually check something.
printf -- '---\nverdict: APPROVE\n---\nbody\n' > "$SCRATCH/re/nazgul/reviews/TASK-001/code-reviewer.md"
validate_review_evidence "$SCRATCH/re/nazgul" TASK-001 >/dev/null 2>"$SCRATCH/re-full.err" || true
RE_FULL_LINE=$(grep -E '^review-evidence/verdict-files: [0-9]+ scanned' "$SCRATCH/re-full.err" | tail -1)
_grammar_check "review-evidence/verdict-files (mixed)" "review-evidence/verdict-files" \
  "artifact non-seat superseded" "$RE_FULL_LINE"
assert_contains "review-evidence: a run with a real reviewer file checks something" \
  "$RE_FULL_LINE" "1 checked"

# review-provenance (scripts/lib/review-provenance.sh), forced all-skip over the SAME directory:
# it shares the fourteenth entry point's classifier, so the two partitions must be identical.
rm -f "$SCRATCH/re/nazgul/reviews/TASK-001/code-reviewer.md"
printf 'diff\n' > "$SCRATCH/re/nazgul/reviews/TASK-001/diff.patch"
write_dispatch_manifest "$SCRATCH/re/nazgul" TASK-001 "$SCRATCH/re/nazgul/reviews/TASK-001/diff.patch" \
  FEAT-000 1 -- code-reviewer >/dev/null
RP_OUT=$(validate_review_provenance "$SCRATCH/re/nazgul" TASK-001 2>"$SCRATCH/rp.err") || true
RP_LINE=$(grep -E '^review-provenance/subject-files: [0-9]+ scanned' "$SCRATCH/rp.err" | tail -1)
_grammar_check "review-provenance/subject-files (all-skip)" "review-provenance/subject-files" \
  "artifact non-seat superseded" "$RP_LINE" && RFC_PROVENANCE_OK=1
assert_contains "review-provenance: forced all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/rp.err")" "NOTHING CHECKED — all 2 candidate(s) skipped after a board was dispatched"
# Conditional floor: a board WAS dispatched here, so nothing-read blocks. Without the manifest the
# same directory is the ordinary pre-review state — "looked and found none", not "never looked".
assert_contains "review-provenance: the floor reaches the caller when a board was dispatched" \
  "$RP_OUT" "NOTHING_CHECKED"
rm -f "$SCRATCH/re/nazgul/reviews/TASK-001/.dispatch.json"
RP_PRE=$(validate_review_provenance "$SCRATCH/re/nazgul" TASK-001 2>"$SCRATCH/rp-pre.err") || true
assert_eq "review-provenance: the same all-skip scan pre-review says nothing to the caller" "$RP_PRE" ""
assert_contains "review-provenance: and still names the state on stderr" \
  "$(cat "$SCRATCH/rp-pre.err")" "nothing to check — all 2 candidate(s) skipped, no dispatch manifest (pre-review)"

# One emitter, two tokens: half a conforming entry point is not a covered one.
if [ "$RFC_EVIDENCE_OK$RFC_PROVENANCE_OK" = "11" ]; then
  _entry_covered review-file-class
  _pass "review-file-class: BOTH tokens conform, so the shared emitter counts as covered"
else
  _fail "review-file-class: BOTH tokens conform" \
    "verdict-files=$RFC_EVIDENCE_OK subject-files=$RFC_PROVENANCE_OK — one conforming token does not cover an emitter that prints two"
fi
assert_eq "review-file-class: the two passes partition the same directory identically" \
  "$(printf '%s' "$RE_LINE" | sed 's/^[^:]*: //')" "$(printf '%s' "$RP_LINE" | sed 's/^[^:]*: //')"

# Enumeration completeness — the point of the whole file: an entry point with no
# emitter must FAIL here, not silently drop out of the list.
for entry in $ENTRY_POINTS; do
  case " $COVERED " in
    *" $entry "*) _pass "entry point '$entry' emits the coverage-honesty line" ;;
    *) _fail "entry point '$entry' emits the coverage-honesty line" \
         "no conforming line was produced by its driver — an entry point with no emitter is a gap, not a skip" ;;
  esac
done

# The other direction: a driver for something §15 does not list is an unregistered
# entry point, not extra credit — the registry and the drivers must be the same set.
for entry in $COVERED; do
  case " $(printf '%s' "$ENTRY_POINTS" | tr '\n' ' ') " in
    *" $entry "*) ;;
    *) _fail "driver '$entry' names an entry point RULES.md §15 registers" \
         "this file drives it, the registry does not list it — enroll it there or stop counting it here" ;;
  esac
done

# The CONVERSE direction (RULES §15): every shipped §15-grammar emitter is a registered entry
# point. The loops above ask only "is every member driven?". Population DERIVED, not authored.
EMIT_SCANNED=0; EMIT_SKIP_TESTS=0; EMIT_SKIP_UNREADABLE=0; EMIT_CHECKED=0; EMIT_FINDINGS=0
EMIT_UNREGISTERED=""
REGISTRY_MEMBERS_ALL="$REGISTRY_MEMBERS
$REGISTRY_DRIVER_REL"
while IFS="$(printf '\t')" read -r _state _rel; do
  [ -n "${_rel:-}" ] || continue
  EMIT_SCANNED=$((EMIT_SCANNED + 1))
  if [ "$_state" = "unreadable" ]; then
    EMIT_SKIP_UNREADABLE=$((EMIT_SKIP_UNREADABLE + 1)); continue
  fi
  case "$_rel" in
    tests/*) EMIT_SKIP_TESTS=$((EMIT_SKIP_TESTS + 1)); continue ;;
  esac
  EMIT_CHECKED=$((EMIT_CHECKED + 1))
  if ! printf '%s\n' "$REGISTRY_MEMBERS_ALL" | grep -qxF "$_rel"; then
    EMIT_FINDINGS=$((EMIT_FINDINGS + 1)); EMIT_UNREGISTERED="$EMIT_UNREGISTERED$_rel "
  fi
done <<< "$(_registry_emitter_scan "$REPO_ROOT")"

_grammar_check "registry converse (emitter -> member)" "registry-converse" \
  "tests-tree unreadable" \
  "registry-converse: $EMIT_SCANNED scanned, $((EMIT_SKIP_TESTS + EMIT_SKIP_UNREADABLE)) skipped (tests-tree=$EMIT_SKIP_TESTS, unreadable=$EMIT_SKIP_UNREADABLE), $EMIT_CHECKED checked, $EMIT_FINDINGS findings"
if [ "$EMIT_CHECKED" -ge 5 ]; then
  _pass "registry converse: the emitter derivation actually looked ($EMIT_CHECKED checked >= 5)"
else
  _fail "registry converse: the emitter derivation actually looked" \
    "checked $EMIT_CHECKED under $REPO_ROOT — a derivation that finds nothing is 'never looked', not a clean tree"
fi
assert_eq "registry converse: every scripts/** and agents/** grammar emitter is a §15 member" \
  "${EMIT_UNREGISTERED% }" ""

# Mutation, the direction TASK-016/017's B1/B2 do not cover: an emitter added with no
# registration must go RED. A registered member with no driver is already covered above.
EMIT_MUT="$SCRATCH/emitter-mutant"
mkdir -p "$EMIT_MUT/scripts" "$EMIT_MUT/tests"
printf "printf 'rogue: %%d scanned, %%d skipped (why=%%d), %%d checked, %%d findings\\\\n'\n" \
  > "$EMIT_MUT/scripts/rogue-check.sh"
printf "printf 'in-tests: %%d scanned, %%d skipped (why=%%d), %%d checked, %%d findings\\\\n'\n" \
  > "$EMIT_MUT/tests/test-rogue.sh"
MUT_SCAN=$(_registry_emitter_scan "$EMIT_MUT")
assert_contains "[mutation] an unregistered scripts/ emitter is derived from the tree" \
  "$MUT_SCAN" "scripts/rogue-check.sh"
MUT_UNREG=""
while IFS="$(printf '\t')" read -r _state _rel; do
  [ "${_state:-}" = "emitter" ] || continue
  case "$_rel" in tests/*) continue ;; esac
  printf '%s\n' "$REGISTRY_MEMBERS_ALL" | grep -qxF "$_rel" || MUT_UNREG="$MUT_UNREG$_rel "
done <<< "$MUT_SCAN"
assert_eq "[mutation] and the same predicate that passes on the shipped tree reports it" \
  "${MUT_UNREG% }" "scripts/rogue-check.sh"
assert_contains "[mutation] the stated tests/** residual is real, not assumed: it is skipped, not found" \
  "$MUT_SCAN" "tests/test-rogue.sh"

# A test that only asserts on a literal coverage line is not an emitter — otherwise the
# scan would name every file in this directory and the finding would mean nothing.
NOT_EMIT="$SCRATCH/not-emitter"
mkdir -p "$NOT_EMIT/scripts"
printf 'assert_contains "x" "$OUT" "doctor: 3 scanned, 0 skipped (a=0), 3 checked, 0 findings"\n' \
  > "$NOT_EMIT/scripts/asserts-only.sh"
assert_eq "registry converse: a literal assertion is not mistaken for a producer" \
  "$(_registry_emitter_scan "$NOT_EMIT" | grep -c . || true)" "0"

COVERED_COUNT=$(printf '%s' "$COVERED" | wc -w | tr -d ' ')
assert_eq "every entry point RULES.md §15 registers was driven" "$COVERED_COUNT" "$REGISTRY_N"

report_results
