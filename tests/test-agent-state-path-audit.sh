#!/usr/bin/env bash
set -uo pipefail
# NOT using set -e; assertions check return codes and content explicitly.
# Test: scripts/audit-agent-state-paths.sh — the FEAT-030 roster audit
# (PRD AC2/AC4, RULES.md §15). Two obligations, and the second is the load-bearing
# one: the coverage record is ASSERTED against the §15 grammar rather than narrated,
# and the detector is DRIVEN against a synthetic corpus that is dirty by
# construction. The shipped roster converges on clean, so a scanner exercised only
# against it would be a rule that can only pass — evidence of nothing
# (tests/test-repo-content-boundary.sh makes the same move for its matcher).
TEST_NAME="test-agent-state-path-audit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

AUDIT="$REPO_ROOT/scripts/audit-agent-state-paths.sh"

# AS-1 FIRST, deliberately: at the pre-change Base SHA this checking surface does
# not exist, and the red run must read as that rather than as an accident.
if [ -f "$AUDIT" ] && [ -x "$AUDIT" ]; then
  _pass "AS-1: the audit entry point exists and is executable"
else
  _fail "AS-1: the audit entry point exists and is executable" \
    "expected an executable at $AUDIT"
  report_results
  exit 1
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-agent-state-path-audit-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

ENTRY="audit-agent-state-paths"
SKIP_REASONS="non-spec unreadable not-a-file"
GRAMMAR="^$ENTRY: ([0-9]+) scanned, ([0-9]+) skipped \(non-spec=([0-9]+), unreadable=([0-9]+), not-a-file=([0-9]+)\), ([0-9]+) checked, ([0-9]+) findings\$"

_last_line() { printf '%s' "$1" | tail -1; }
_field() { printf '%s' "$1" | sed -E "s/$2/\\1/"; }
_n_of() { _field "$1" '^[^:]*: ([0-9]+) scanned.*'; }
_m_of() { _field "$1" '^.* ([0-9]+) skipped \(.*'; }
_k_of() { _field "$1" '^.*\), ([0-9]+) checked.*'; }
_f_of() { _field "$1" '^.*, ([0-9]+) findings$'; }

RUN_OUT=""
RUN_RC=0

# _run <scan-root> — sets RUN_OUT/RUN_RC, stderr to $SCRATCH/err. Not a command
# substitution: an exit code set inside one dies with its subshell under set -u.
_run() {
  NAZGUL_AGENT_AUDIT_SCAN_ROOT="$1" bash "$AUDIT" >"$SCRATCH/out" 2>"$SCRATCH/err"
  RUN_RC=$?
  RUN_OUT="$(cat "$SCRATCH/out")"
}

# The shipped roster, asserted rather than narrated.
_run "$REPO_ROOT"
REAL_OUT="$RUN_OUT"
REAL_RC=$RUN_RC
REAL_LINE=$(_last_line "$REAL_OUT")

if printf '%s' "$REAL_LINE" | grep -qE "$GRAMMAR"; then
  _pass "AS-2: the coverage line conforms to the RULES.md §15 grammar"
else
  _fail "AS-2: the coverage line conforms to the RULES.md §15 grammar" "got: '$REAL_LINE'"
fi

REAL_N=$(_n_of "$REAL_LINE"); REAL_M=$(_m_of "$REAL_LINE")
REAL_K=$(_k_of "$REAL_LINE"); REAL_F=$(_f_of "$REAL_LINE")
assert_eq "AS-3: N == M + K over the shipped roster" "$REAL_N" "$((REAL_M + REAL_K))"

REAL_SUM=0
for r in $(printf '%s' "$REAL_LINE" | sed -E 's/^.*\(([^)]*)\).*/\1/' | tr ',' ' '); do
  case "$r" in *=*) REAL_SUM=$((REAL_SUM + ${r##*=})) ;; esac
done
assert_eq "AS-4: the enumerated skip reasons account for all M" "$REAL_SUM" "$REAL_M"

REAL_REASONS=$(printf '%s' "$REAL_LINE" | sed -E 's/^.*\(([^)]*)\).*/\1/' | tr ',' ' ' \
  | sed -E 's/=[0-9]+//g' | tr -s ' ' | sed -E 's/^ | $//g')
assert_eq "AS-5: the skip reasons are exactly the closed set, in order" \
  "$REAL_REASONS" "$SKIP_REASONS"

# A scan that only ever conforms while vacuous is not covered by the contract.
if [ "${REAL_K:-0}" -ge 20 ]; then
  _pass "AS-6: the audit actually walked the roster ($REAL_K specs checked)"
else
  _fail "AS-6: the audit actually walked the roster" \
    "only $REAL_K spec(s) checked — the enumerator is broken, not the roster empty"
fi
assert_not_contains "AS-7: a run that checked something is not a vacuous run" \
  "$(cat "$SCRATCH/err")" "NOTHING CHECKED"
assert_contains "AS-8: the classification summary counts the prose exemption (PRD AC4)" \
  "$REAL_OUT" "$ENTRY: occurrences "
assert_exit_code "AS-9: the audit reports and never gates — exit 0 even with findings" "$REAL_RC" 0
[ -n "$REAL_F" ] || _fail "AS-9b: the findings count is present" "line: '$REAL_LINE'"

# The detector, driven against a corpus dirty by construction.
mkdir -p "$SCRATCH/dirty/agents/templates"
cat > "$SCRATCH/dirty/agents/writer.md" <<'SPEC'
# writer

## Completion

```bash
mkdir -p nazgul/logs
echo "$FEAT_ID" > nazgul/logs/.written
```

Read `nazgul/config.json` for the objective id.
SPEC
cat > "$SCRATCH/dirty/agents/emitter.md" <<'SPEC'
# emitter

Emit the coverage event with `NAZGUL_DIR="$(pwd)/nazgul"` so the bus sees it.

Emit the coverage event with `NAZGUL_DIR="$PWD/nazgul"` so the bus sees it.

Emit the coverage event with `NAZGUL_DIR="${PWD}/nazgul"` so the bus sees it.
SPEC
cat > "$SCRATCH/dirty/agents/templates/prose.md" <<'SPEC'
# prose only

The orchestrator persists your returned review to `nazgul/reviews/[UNIT-ID]/x.md`
for you. Do NOT attempt to write `nazgul/reviews/[UNIT-ID]/x.md` yourself.
SPEC
# Same exemption, sentence-initial. A negation is a negation wherever the sentence
# starts, so the classifier must not read case as consent.
cat > "$SCRATCH/dirty/agents/templates/prose-caps.md" <<'SPEC'
# prose only, capitalised negations

Don't write `nazgul/reviews/[UNIT-ID]/x.md` yourself — the orchestrator does it.

Cannot write `nazgul/logs/.x` from here; the orchestrator owns that file.

Must not write `nazgul/inbox/x.md` from a task worktree.
SPEC

_run "$SCRATCH/dirty"
DIRTY_OUT="$RUN_OUT"
DIRTY_RC=$RUN_RC
DIRTY_LINE=$(_last_line "$DIRTY_OUT")

if printf '%s' "$DIRTY_LINE" | grep -qE "$GRAMMAR"; then
  _pass "AS-10: the dirty corpus still emits a conforming coverage line"
else
  _fail "AS-10: the dirty corpus still emits a conforming coverage line" "got: '$DIRTY_LINE'"
fi
assert_eq "AS-11: N == M + K over the dirty corpus" \
  "$(_n_of "$DIRTY_LINE")" "$(( $(_m_of "$DIRTY_LINE") + $(_k_of "$DIRTY_LINE") ))"

assert_contains "AS-12: a relative marker write in a fenced block FIRES as state-write" \
  "$DIRTY_OUT" "agents/writer.md:7: state-write"
assert_contains "AS-13: a relative mkdir FIRES as state-write" \
  "$DIRTY_OUT" "agents/writer.md:6: state-write"
assert_contains "AS-14: a relative prose-form config read FIRES as state-read" \
  "$DIRTY_OUT" "agents/writer.md:10: state-read"
assert_contains "AS-15: the \$(pwd)/nazgul event idiom FIRES — cwd is not the main worktree" \
  "$DIRTY_OUT" 'agents/emitter.md:3: state-'
# Same defect, other spellings: no trailing `nazgul/`, so a $(pwd)-only matcher yields
# nothing on an admitted line and the occurrence counts as neither write, read, nor prose.
assert_contains "AS-15b: the \$PWD/nazgul spelling FIRES too" \
  "$DIRTY_OUT" 'agents/emitter.md:5: state-'
assert_contains "AS-15c: the \${PWD}/nazgul spelling FIRES too" \
  "$DIRTY_OUT" 'agents/emitter.md:7: state-'
assert_not_contains "AS-16: a path another actor writes, under an explicit prohibition, stays prose" \
  "$DIRTY_OUT" "agents/templates/prose.md:"
assert_not_contains "AS-16b: a capitalised prohibition is the same prohibition — still prose" \
  "$DIRTY_OUT" "agents/templates/prose-caps.md:"

DIRTY_F=$(_f_of "$DIRTY_LINE")
if [ "${DIRTY_F:-0}" -ge 6 ]; then
  _pass "AS-17: every enumerated defect is counted in F ($DIRTY_F)"
else
  _fail "AS-17: every enumerated defect is counted in F" \
    "expected >= 6 findings on a corpus with six defects, got $DIRTY_F"
fi
assert_contains "AS-18: the dirty corpus still counts its prose exemptions" \
  "$DIRTY_OUT" "prose="
assert_exit_code "AS-19: a corpus full of findings still exits 0 (reports, never gates)" "$DIRTY_RC" 0

# The same corpus rooted, so a zero-finding pass means something.
mkdir -p "$SCRATCH/clean/agents/templates"
sed -e 's#mkdir -p nazgul/logs#mkdir -p "<main_worktree_path>/nazgul/logs"#' \
    -e 's#> nazgul/logs/.written#> "<main_worktree_path>/nazgul/logs/.written"#' \
    -e 's#`nazgul/config.json`#`<main_worktree_path>/nazgul/config.json`#' \
    "$SCRATCH/dirty/agents/writer.md" > "$SCRATCH/clean/agents/writer.md"
sed -e 's#\$(pwd)/nazgul#<main_worktree_path>/nazgul#' \
    -e 's#\${PWD}/nazgul#<main_worktree_path>/nazgul#' \
    -e 's#\$PWD/nazgul#<main_worktree_path>/nazgul#' \
    "$SCRATCH/dirty/agents/emitter.md" > "$SCRATCH/clean/agents/emitter.md"
cp "$SCRATCH/dirty/agents/templates/prose.md" "$SCRATCH/clean/agents/templates/prose.md"

_run "$SCRATCH/clean"
CLEAN_OUT="$RUN_OUT"
CLEAN_LINE=$(_last_line "$CLEAN_OUT")
assert_eq "AS-20: the same corpus rooted at <main_worktree_path> yields zero findings" \
  "$(_f_of "$CLEAN_LINE")" "0"
assert_eq "AS-21: a clean corpus is still fully checked, never skipped into silence" \
  "$(_k_of "$CLEAN_LINE")" "3"
assert_contains "AS-22: the rooted occurrences are counted, not made invisible" \
  "$CLEAN_OUT" " already rooted"

# Looked-and-found-none must never collapse into never-looked.
mkdir -p "$SCRATCH/allskip/agents"
printf '{"domains":[]}\n' > "$SCRATCH/allskip/agents/reviewer-domains.json"
_run "$SCRATCH/allskip"
SKIP_OUT="$RUN_OUT"
SKIP_RC=$RUN_RC
assert_contains "AS-23: a candidate that is not an agent spec is a NAMED, COUNTED skip" \
  "$(_last_line "$SKIP_OUT")" "1 scanned, 1 skipped (non-spec=1, unreadable=0, not-a-file=0), 0 checked"
assert_contains "AS-24: all-skip emits the nothing-checked signal" \
  "$(cat "$SCRATCH/err")" "$ENTRY: NOTHING CHECKED — all 1 candidate(s) skipped"
assert_exit_code "AS-25: advisory surface — exit code unchanged by a vacuous run" "$SKIP_RC" 0

mkdir -p "$SCRATCH/empty/agents"
_run "$SCRATCH/empty"
EMPTY_OUT="$RUN_OUT"
assert_contains "AS-26: zero candidates is a broken enumerator, named as its own condition" \
  "$(cat "$SCRATCH/err")" "$ENTRY: NOTHING CHECKED — no agent specs discovered"
assert_contains "AS-27: zero candidates still emits a coverage line" \
  "$(_last_line "$EMPTY_OUT")" \
  "$ENTRY: 0 scanned, 0 skipped (non-spec=0, unreadable=0, not-a-file=0), 0 checked, 0 findings"

_run "$SCRATCH"
NOROSTER_OUT="$RUN_OUT"
assert_contains "AS-28: a scan root with no agents/ at all says so rather than passing quietly" \
  "$(cat "$SCRATCH/err")" "no agents/ directory under"
assert_contains "AS-29: a scan root with no agents/ still emits a coverage line" \
  "$(_last_line "$NOROSTER_OUT")" "0 checked, 0 findings"

mkdir -p "$SCRATCH/dangling/agents"
ln -s "$SCRATCH/dangling/agents/gone.md" "$SCRATCH/dangling/agents/link.md"
_run "$SCRATCH/dangling"
DANGLING_OUT="$RUN_OUT"
assert_contains "AS-30: a candidate that is not a regular file is counted, never silently dropped" \
  "$(_last_line "$DANGLING_OUT")" "1 scanned, 1 skipped (non-spec=0, unreadable=0, not-a-file=1), 0 checked"

report_results
