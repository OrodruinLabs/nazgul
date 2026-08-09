#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — we assert on exit codes explicitly throughout.

# Test: scripts/self-audit.sh mines in-repo signals + findings.jsonl + transcript
# cost, appends one entry per finding, reports coverage, and never errors.
TEST_NAME="test-self-audit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SELF_AUDIT="$REPO_ROOT/scripts/self-audit.sh"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# mk_project <name> -> prints the project root; sets up a git repo with a
# nazgul/ dir + config.json (feat_id = FEAT-<NAME upper>).
mk_project() {
  local name="$1" root
  root="$TMPDIR_BASE/$name"
  mkdir -p "$root/nazgul"
  git -C "$root" init -q
  git -C "$root" config user.email "test@nazgul.dev"
  git -C "$root" config user.name "Nazgul Test"
  cp "$REPO_ROOT/templates/config.json" "$root/nazgul/config.json"
  jq --arg f "FEAT-$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')" '.feat_id = $f' \
    "$root/nazgul/config.json" > "$root/nazgul/config.json.tmp" \
    && mv "$root/nazgul/config.json.tmp" "$root/nazgul/config.json"
  touch "$root/.gitkeep"
  git -C "$root" add .gitkeep nazgul/config.json
  git -C "$root" commit -q -m "initial commit"
  printf '%s\n' "$root"
}

run_self_audit() {
  local nazgul_dir="$1"
  SA_OUTPUT=$(unset NAZGUL_TRANSCRIPTS_DIR; bash "$SELF_AUDIT" "$nazgul_dir" 2>&1)
  SA_EC=$?
}

run_self_audit_with_transcripts() {
  local nazgul_dir="$1" transcripts_dir="$2"
  SA_OUTPUT=$(NAZGUL_TRANSCRIPTS_DIR="$transcripts_dir" bash "$SELF_AUDIT" "$nazgul_dir" 2>&1)
  SA_EC=$?
}

# --- Test 1: reviewer CHANGES_REQUESTED -> one finding ---
ROOT=$(mk_project "t1")
mkdir -p "$ROOT/nazgul/reviews/TASK-001"
printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 90\n---\nSome finding.\n' \
  > "$ROOT/nazgul/reviews/TASK-001/code-reviewer.md"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T1: exits 0" "$SA_EC" 0
assert_file_exists "T1: backlog created" "$ROOT/nazgul/improvements.md"
assert_contains "T1: entry titled for TASK-001/code-reviewer" "$(cat "$ROOT/nazgul/improvements.md")" \
  "Review rejection: TASK-001/code-reviewer"
assert_contains "T1: entry has Severity/Leverage" "$(cat "$ROOT/nazgul/improvements.md")" "Severity/Leverage"
assert_contains "T1: entry has Status: open" "$(cat "$ROOT/nazgul/improvements.md")" "Status**: open"
assert_contains "T1: entry has feat_id header" "$(cat "$ROOT/nazgul/improvements.md")" "[FEAT-T1]"

# --- Test 2: guard/state-machine "blocked" event -> one finding ---
ROOT=$(mk_project "t2")
mkdir -p "$ROOT/nazgul/logs"
printf '{"event":"blocked","task_id":"TASK-002","reason":"git conflict"}\n' \
  > "$ROOT/nazgul/logs/events.jsonl"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T2: exits 0" "$SA_EC" 0
assert_contains "T2: mentions blocked task+reason" "$(cat "$ROOT/nazgul/improvements.md")" "TASK-002:git conflict"

# --- Test 3: TODO/FIXME delta between two commits -> one finding ---
ROOT=$(mk_project "t3")
printf 'no markers here\n' > "$ROOT/src.txt"
git -C "$ROOT" add src.txt
git -C "$ROOT" commit -q -m "add src"
printf 'no markers here\n# TODO: fix this later\n' > "$ROOT/src.txt"
git -C "$ROOT" add src.txt
git -C "$ROOT" commit -q -m "add todo"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T3: exits 0" "$SA_EC" 0
assert_contains "T3: TODO/FIXME delta finding present" "$(cat "$ROOT/nazgul/improvements.md")" "TODO/FIXME delta"
assert_contains "T3: the finding names the file to act on" \
  "$(cat "$ROOT/nazgul/improvements.md")" "src.txt"

# --- Test 3b (PR #86 review): count and file list must use ONE pathspec, or a
# nazgul/-only marker delta reports a count with no file to act on. ---
ROOT=$(mk_project "t3b")
printf 'no markers here\n' > "$ROOT/src.txt"
git -C "$ROOT" add src.txt
git -C "$ROOT" commit -q -m "add src"
mkdir -p "$ROOT/nazgul/tasks"
printf '# TASK-009\n# TODO: runtime note\n' > "$ROOT/nazgul/tasks/TASK-009.md"
git -C "$ROOT" add -f nazgul/tasks/TASK-009.md
git -C "$ROOT" commit -q -m "add runtime todo"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T3b: exits 0" "$SA_EC" 0
assert_not_contains "T3b: a nazgul/-only marker delta raises no unactionable finding" \
  "$(cat "$ROOT/nazgul/improvements.md")" "TODO/FIXME delta"
assert_not_contains "T3b: and never reports a count with no file to act on" \
  "$(cat "$ROOT/nazgul/improvements.md")" "<no changed files>"

# --- Test 4: task retry count -> one finding ---
ROOT=$(mk_project "t4")
mkdir -p "$ROOT/nazgul/tasks"
cat > "$ROOT/nazgul/tasks/TASK-003.md" << 'EOF'
# TASK-003: Test task
- **Status**: IN_REVIEW
- **Retry count**: 2/3
EOF
run_self_audit "$ROOT/nazgul"
assert_exit_code "T4: exits 0" "$SA_EC" 0
assert_contains "T4: retry finding present" "$(cat "$ROOT/nazgul/improvements.md")" "TASK-003 required 2 retry attempt(s)"

# --- Test 5: append-only across a second run with new fixture signals ---
ROOT=$(mk_project "t5")
mkdir -p "$ROOT/nazgul/tasks"
cat > "$ROOT/nazgul/tasks/TASK-010.md" << 'EOF'
# TASK-010: Test task
- **Status**: IN_REVIEW
- **Retry count**: 1/3
EOF
run_self_audit "$ROOT/nazgul"
assert_exit_code "T5a: first run exits 0" "$SA_EC" 0
PREFIX_LEN=$(wc -c < "$ROOT/nazgul/improvements.md" | tr -d ' ')
PREFIX_CONTENT=$(cat "$ROOT/nazgul/improvements.md")
cat > "$ROOT/nazgul/tasks/TASK-011.md" << 'EOF'
# TASK-011: Test task
- **Status**: IN_REVIEW
- **Retry count**: 3/3
EOF
run_self_audit "$ROOT/nazgul"
assert_exit_code "T5b: second run exits 0" "$SA_EC" 0
NEW_PREFIX=$(head -c "$PREFIX_LEN" "$ROOT/nazgul/improvements.md")
assert_eq "T5c: original prefix byte-for-byte unchanged" "$NEW_PREFIX" "$PREFIX_CONTENT"
assert_contains "T5d: new signal appended after second run" "$(cat "$ROOT/nazgul/improvements.md")" \
  "TASK-011 required 3 retry attempt(s)"

# --- Test 6: findings.jsonl absent -> clean no-op, no error ---
ROOT=$(mk_project "t6")
run_self_audit "$ROOT/nazgul"
assert_exit_code "T6: absent findings.jsonl exits 0" "$SA_EC" 0
assert_file_not_contains "T6: no jsonl-sourced entry" "$ROOT/nazgul/improvements.md" "raised by"

# --- Test 7: findings.jsonl ingestion, deduped ---
ROOT=$(mk_project "t7")
mkdir -p "$ROOT/nazgul/logs"
cat > "$ROOT/nazgul/logs/findings.jsonl" << 'EOF'
{"ts":"2026-07-09T00:00:00Z","agent":"conductor","unit":"UNIT-1","severity":"high","category":"cost","title":"Conductor unpinned","detail":"no model passed","suggested_fix":"pin model","evidence":"skills/start/SKILL.md"}
{"ts":"2026-07-09T00:05:00Z","agent":"implementer","unit":"TASK-005","severity":"low","category":"process","title":"Cannot spawn teammates","detail":"team backend degraded to serial","suggested_fix":"route via conductor","evidence":""}
{"ts":"2026-07-09T00:10:00Z","agent":"review-gate","unit":"UNIT-1","severity":"high","category":"cost","title":"Conductor unpinned","detail":"no model passed","suggested_fix":"pin model","evidence":"skills/start/SKILL.md"}
EOF
run_self_audit "$ROOT/nazgul"
assert_exit_code "T7: exits 0" "$SA_EC" 0
BACKLOG=$(cat "$ROOT/nazgul/improvements.md")
assert_contains "T7: first finding ingested" "$BACKLOG" "Conductor unpinned"
assert_contains "T7: second finding ingested" "$BACKLOG" "Cannot spawn teammates"
DUP_COUNT=$(grep -c "Conductor unpinned" "$ROOT/nazgul/improvements.md")
assert_eq "T7: duplicate finding deduped (only one entry)" "$DUP_COUNT" "1"
assert_contains "T7: evidence attributes raising agent" "$BACKLOG" "raised by conductor (unit: UNIT-1)"

# --- Test 8: cost data unavailable (transcript dir absent) -> logged, exit 0, no drift findings ---
ROOT=$(mk_project "t8")
run_self_audit_with_transcripts "$ROOT/nazgul" "$TMPDIR_BASE/does-not-exist-transcripts"
assert_exit_code "T8: exits 0" "$SA_EC" 0
assert_contains "T8: logs cost data unavailable" "$SA_OUTPUT" "cost data unavailable"
assert_file_not_contains "T8: no model-tier drift entry" "$ROOT/nazgul/improvements.md" "Model-tier drift"

# --- Test 9: opaque `agent-<hex>.jsonl` transcripts resolve their role from
# attributionAgent (prefix normalized) -> drift flagged, no false positive ---
ROOT=$(mk_project "t9")
TRANSCRIPTS="$TMPDIR_BASE/t9-transcripts/session1/subagents"
mkdir -p "$TRANSCRIPTS"
printf '{"attributionAgent":"nazgul:code-reviewer","message":{"model":"opus","usage":{"input_tokens":100,"output_tokens":50}}}\n' \
  > "$TRANSCRIPTS/agent-a015e06fa8fb1060b.jsonl"
printf '{"attributionAgent":"nazgul:nazgul:implementer","message":{"model":"sonnet","usage":{"input_tokens":200,"output_tokens":80}}}\n' \
  > "$TRANSCRIPTS/agent-a0254f11fcb9191cf.jsonl"
run_self_audit_with_transcripts "$ROOT/nazgul" "$TMPDIR_BASE/t9-transcripts"
assert_exit_code "T9: exits 0" "$SA_EC" 0
BACKLOG9=$(cat "$ROOT/nazgul/improvements.md")
assert_contains "T9: drift flagged for code-reviewer (opus vs haiku)" "$BACKLOG9" \
  "Model-tier drift: code-reviewer ran on opus (expected haiku)"
assert_not_contains "T9: no drift for implementer (sonnet matches)" "$BACKLOG9" "Model-tier drift: implementer"
assert_contains "T9: both opaque files classified from attribution, none skipped" "$SA_OUTPUT" \
  "self-audit/token-cost: 2 scanned, 0 skipped (unreadable=0, unclassifiable=0, not-applicable=0), 2 checked, 1 findings"

# --- Test 10: bare nazgul dir (no reviews/logs/tasks/git) -> exits 0, header-only backlog ---
BARE="$TMPDIR_BASE/t10"
mkdir -p "$BARE/nazgul"
cp "$REPO_ROOT/templates/config.json" "$BARE/nazgul/config.json"
run_self_audit "$BARE/nazgul"
assert_exit_code "T10: bare dir exits 0" "$SA_EC" 0
assert_file_exists "T10: backlog created" "$BARE/nazgul/improvements.md"
assert_contains "T10: backlog has header" "$(cat "$BARE/nazgul/improvements.md")" "Improvements Backlog"

# --- Test 11: unwritable backlog dir -> degrades cleanly (exit 0), never aborts.
# Fails for ANY user (incl. root in CI): the configured backlog's parent is a FILE ---
T11=$(mk_project "t11")
# Seed a real finding so the script would WANT to append (proves it's the write,
# not "nothing to do", that we're exercising).
mkdir -p "$T11/nazgul/reviews/TASK-001"
printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 90\n---\nSome finding.\n' \
  > "$T11/nazgul/reviews/TASK-001/code-reviewer.md"
printf 'i am a file, not a dir\n' > "$T11/blk"   # parent of the configured backlog
jq '.self_audit.backlog_path = "blk/improvements.md"' \
  "$T11/nazgul/config.json" > "$T11/nazgul/config.json.tmp" \
  && mv "$T11/nazgul/config.json.tmp" "$T11/nazgul/config.json"
run_self_audit "$T11/nazgul"
assert_exit_code "T11: unwritable backlog exits 0 (never fails the run)" "$SA_EC" 0
assert_contains "T11: logs a skip message" "$SA_OUTPUT" "run not failed"
assert_file_not_exists "T11: no backlog created at the blocked path" "$T11/blk/improvements.md"

# --- Test 12: feedback-aggregator on haiku is NOT tier drift — review-gate
# dispatches it on the review_default chain, not models.default ---
T12ROOT=$(mk_project "t12")
T12T="$TMPDIR_BASE/t12-transcripts/session1/subagents"
mkdir -p "$T12T"
printf '{"attributionAgent":"feedback-aggregator","message":{"model":"haiku"}}\n' > "$T12T/agent-a03d0dafb0145a2d7.jsonl"
run_self_audit_with_transcripts "$T12ROOT/nazgul" "$TMPDIR_BASE/t12-transcripts"
assert_exit_code "T12: exits 0" "$SA_EC" 0
assert_not_contains "T12: feedback-aggregator on haiku not flagged as drift (review_default)" \
  "$(cat "$T12ROOT/nazgul/improvements.md")" "Model-tier drift: feedback-aggregator"

# --- Test 13: cost mining scopes to the MOST RECENT session dir only ---
# A prior session's drift must NOT bleed into this objective's backlog.
T13ROOT=$(mk_project "t13")
T13T="$TMPDIR_BASE/t13-transcripts"
mkdir -p "$T13T/session-old/subagents" "$T13T/session-new/subagents"
printf '{"attributionAgent":"code-reviewer","message":{"model":"opus"}}\n' \
  > "$T13T/session-old/subagents/agent-a015e06fa8fb1060b.jsonl"   # would drift (opus vs haiku)
printf '{"attributionAgent":"implementer","message":{"model":"sonnet"}}\n' \
  > "$T13T/session-new/subagents/agent-a0254f11fcb9191cf.jsonl"   # matches, no drift
# Force mtime ordering AFTER writing contents (writes bump the dir mtime).
touch -t 202601010000 "$T13T/session-old"
touch -t 202601020000 "$T13T/session-new"
run_self_audit_with_transcripts "$T13ROOT/nazgul" "$T13T"
assert_exit_code "T13: exits 0" "$SA_EC" 0
assert_not_contains "T13: prior-session drift NOT mined (newest session dir only)" \
  "$(cat "$T13ROOT/nazgul/improvements.md")" "Model-tier drift: code-reviewer"

# call_transcripts_dir <nazgul_dir> -> sources self-audit.sh (guarded to skip its
# main pipeline when sourced) and prints _transcripts_dir's resolved path.
call_transcripts_dir() {
  local nazgul_dir="$1"
  ( unset NAZGUL_TRANSCRIPTS_DIR
    # shellcheck disable=SC1090
    source "$SELF_AUDIT" "$nazgul_dir" >/dev/null 2>&1
    _transcripts_dir
  )
}

# --- Test 14: _transcripts_dir honors CLAUDE_CONFIG_DIR over ~/.claude ---
T14ROOT=$(mk_project "t14")
T14CONFIGDIR="$TMPDIR_BASE/t14-config-dir"
T14SLUG=$(printf '%s' "$T14ROOT" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$T14CONFIGDIR/projects/$T14SLUG"
T14RESULT=$(CLAUDE_CONFIG_DIR="$T14CONFIGDIR" call_transcripts_dir "$T14ROOT/nazgul")
assert_eq "T14: CLAUDE_CONFIG_DIR honored" "$T14RESULT" "$T14CONFIGDIR/projects/$T14SLUG"

# --- Test 15: _transcripts_dir encodes a SPACE in the project path to '-' ---
T15ROOT="$TMPDIR_BASE/t15 space project"
mkdir -p "$T15ROOT/nazgul"
cp "$REPO_ROOT/templates/config.json" "$T15ROOT/nazgul/config.json"
T15FAKEHOME="$TMPDIR_BASE/t15-home"
T15SLUG=$(printf '%s' "$T15ROOT" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$T15FAKEHOME/.claude/projects/$T15SLUG"
T15RESULT=$(unset CLAUDE_CONFIG_DIR; HOME="$T15FAKEHOME" call_transcripts_dir "$T15ROOT/nazgul")
assert_eq "T15: space in project path encoded to '-'" "$T15RESULT" "$T15FAKEHOME/.claude/projects/$T15SLUG"

# --- Test 16: _transcripts_dir falls back to a basename glob match when the
# computed slug doesn't exist on disk (encoding drift tolerance) ---
T16ROOT="$TMPDIR_BASE/t16 drift project"
mkdir -p "$T16ROOT/nazgul"
cp "$REPO_ROOT/templates/config.json" "$T16ROOT/nazgul/config.json"
T16FAKEHOME="$TMPDIR_BASE/t16-home"
mkdir -p "$T16FAKEHOME/.claude/projects/-some-other-prefix-t16-drift-project"
T16RESULT=$(unset CLAUDE_CONFIG_DIR; HOME="$T16FAKEHOME" call_transcripts_dir "$T16ROOT/nazgul")
assert_eq "T16: falls back to basename glob match" "$T16RESULT" \
  "$T16FAKEHOME/.claude/projects/-some-other-prefix-t16-drift-project"

# --- Test 17: an AMBIGUOUS basename glob must NOT arbitrarily pick one — it
# degrades to the computed (missing) path so cost reads unavailable (PR #55) ---
T17ROOT="$TMPDIR_BASE/t17 drift project"
mkdir -p "$T17ROOT/nazgul"
cp "$REPO_ROOT/templates/config.json" "$T17ROOT/nazgul/config.json"
T17FAKEHOME="$TMPDIR_BASE/t17-home"
mkdir -p "$T17FAKEHOME/.claude/projects/-prefix-a-t17-drift-project"
mkdir -p "$T17FAKEHOME/.claude/projects/-prefix-b-t17-drift-project"
T17SLUG=$(cd "$T17ROOT" && pwd | sed 's/[^A-Za-z0-9]/-/g')
T17RESULT=$(unset CLAUDE_CONFIG_DIR; HOME="$T17FAKEHOME" call_transcripts_dir "$T17ROOT/nazgul")
assert_eq "T17: ambiguous glob degrades to computed expected path" "$T17RESULT" \
  "$T17FAKEHOME/.claude/projects/$T17SLUG"

# --- Test 18: MF-047 -- teammate spawn/manifest discrepancy surfaced when
# fewer dispatch manifests exist than logged spawns (N=3 logged, M=1 manifest) ---
ROOT=$(mk_project "t18")
mkdir -p "$ROOT/nazgul/logs" "$ROOT/nazgul/dispatch"
cat > "$ROOT/nazgul/logs/team-orchestrator.jsonl" << 'EOF'
{"event":"teammate_spawned","session":"nazgul-code-reviewer-TASK-001"}
{"event":"teammate_spawned","session":"nazgul-qa-reviewer-TASK-001"}
{"event":"teammate_spawned","session":"nazgul-architect-reviewer-TASK-001"}
EOF
printf '{}' > "$ROOT/nazgul/dispatch/nazgul-code-reviewer-TASK-001.json"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T18: exits 0" "$SA_EC" 0
assert_contains "T18: discrepancy finding surfaced (3 spawned vs 1 manifest)" \
  "$(cat "$ROOT/nazgul/improvements.md")" \
  "Teammate spawn/manifest discrepancy: 3 logged spawn(s), 1 dispatch manifest(s)"

# --- Test 19: MF-047 -- no discrepancy when manifest count meets/exceeds
# logged spawns (N=2 logged, M=2 manifests) -> no finding, no false positive ---
ROOT=$(mk_project "t19")
mkdir -p "$ROOT/nazgul/logs" "$ROOT/nazgul/dispatch"
cat > "$ROOT/nazgul/logs/team-orchestrator.jsonl" << 'EOF'
{"event":"teammate_spawned","session":"nazgul-code-reviewer-TASK-002"}
{"event":"teammate_spawned","session":"nazgul-qa-reviewer-TASK-002"}
EOF
printf '{}' > "$ROOT/nazgul/dispatch/nazgul-code-reviewer-TASK-002.json"
printf '{}' > "$ROOT/nazgul/dispatch/nazgul-qa-reviewer-TASK-002.json"
run_self_audit "$ROOT/nazgul"
assert_exit_code "T19: exits 0" "$SA_EC" 0
assert_file_not_contains "T19: no discrepancy finding when manifests cover spawns" \
  "$ROOT/nazgul/improvements.md" "Teammate spawn/manifest discrepancy"

# --- Test 20: MF-047 -- no teammate_spawned events logged at all -> no-op,
# no finding (today's reality: nothing emits this event yet) ---
ROOT=$(mk_project "t20")
run_self_audit "$ROOT/nazgul"
assert_exit_code "T20: exits 0" "$SA_EC" 0
assert_file_not_contains "T20: no discrepancy finding with zero logged spawns" \
  "$ROOT/nazgul/improvements.md" "Teammate spawn/manifest discrepancy"

APPROVE_BOARD="$REPO_ROOT/tests/fixtures/self-audit/approve-board"

# sa_line <output> <miner> -> that miner's last coverage line ("" when absent).
sa_line() {
  printf '%s\n' "$1" | grep -E "^self-audit/$2: " | tail -1
}

# sa_num <line> <sed-capture> -> the integer that capture selects.
sa_num() {
  printf '%s' "$1" | sed -E "s/$2/\1/"
}

# assert_coverage <label> <line> <prefix> — fixed grammar, closed reason list,
# N == M + K, and the reasons summing to M.
assert_coverage() {
  local label="$1" line="$2" prefix="$3" n m k u c a
  local re="^${prefix}: [0-9]+ scanned, [0-9]+ skipped \(unreadable=[0-9]+, unclassifiable=[0-9]+, not-applicable=[0-9]+\), [0-9]+ checked, [0-9]+ findings$"
  if printf '%s' "$line" | grep -qE "$re"; then
    _pass "$label: coverage line conforms to the grammar"
  else
    _fail "$label: coverage line conforms to the grammar" "got: '$line'"
    return 1
  fi
  n=$(sa_num "$line" '^[^:]*: ([0-9]+) scanned.*')
  m=$(sa_num "$line" '^.*, ([0-9]+) skipped \(.*')
  u=$(sa_num "$line" '^.*unreadable=([0-9]+).*')
  c=$(sa_num "$line" '^.*unclassifiable=([0-9]+).*')
  a=$(sa_num "$line" '^.*not-applicable=([0-9]+).*')
  k=$(sa_num "$line" '^.*\), ([0-9]+) checked.*')
  assert_eq "$label: N == M + K" "$n" "$((m + k))"
  assert_eq "$label: enumerated reasons account for all M" "$m" "$((u + c + a))"
}

# --- Test 21 (AC5): every miner reports its own coverage, and the run total is
# the sum of them — "looked and found none" never collapses into "never looked" ---
T21=$(mk_project "t21")
mkdir -p "$T21/nazgul/logs" "$T21/nazgul/tasks" "$T21/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\n---\nfine.\n' > "$T21/nazgul/reviews/TASK-001/code-reviewer.md"
printf '{"event":"blocked","task_id":"TASK-001","reason":"lint"}\n' > "$T21/nazgul/logs/events.jsonl"
printf '{"ts":"t","agent":"a","severity":"low","title":"x","detail":"d"}\n' \
  > "$T21/nazgul/logs/findings.jsonl"
cat > "$T21/nazgul/tasks/TASK-001.md" << 'EOF'
# TASK-001
- **Retry count**: 0/3
EOF
T21T="$TMPDIR_BASE/t21-transcripts/session1/subagents"
mkdir -p "$T21T"
printf '{"attributionAgent":"implementer","message":{"model":"sonnet"}}\n' > "$T21T/agent-aaa.jsonl"
run_self_audit_with_transcripts "$T21/nazgul" "$TMPDIR_BASE/t21-transcripts"
assert_exit_code "T21: exits 0" "$SA_EC" 0
T21_SUM_S=0; T21_SUM_M=0; T21_SUM_K=0; T21_SUM_F=0
for miner in review-rejections guard-blocks teammate-spawns todo-delta task-retries token-cost findings-jsonl; do
  LINE=$(sa_line "$SA_OUTPUT" "$miner")
  assert_coverage "T21/$miner" "$LINE" "self-audit/$miner" || continue
  T21_SUM_S=$((T21_SUM_S + $(sa_num "$LINE" '^[^:]*: ([0-9]+) scanned.*')))
  T21_SUM_M=$((T21_SUM_M + $(sa_num "$LINE" '^.*, ([0-9]+) skipped \(.*')))
  T21_SUM_K=$((T21_SUM_K + $(sa_num "$LINE" '^.*\), ([0-9]+) checked.*')))
  T21_SUM_F=$((T21_SUM_F + $(sa_num "$LINE" '^.*, ([0-9]+) findings$')))
done
T21_TOTAL=$(printf '%s\n' "$SA_OUTPUT" | grep -E '^self-audit: [0-9]+ scanned' | tail -1)
assert_coverage "T21/run-total" "$T21_TOTAL" "self-audit"
assert_eq "T21: run total scanned == sum of miners" \
  "$(sa_num "$T21_TOTAL" '^[^:]*: ([0-9]+) scanned.*')" "$T21_SUM_S"
assert_eq "T21: run total skipped == sum of miners" \
  "$(sa_num "$T21_TOTAL" '^.*, ([0-9]+) skipped \(.*')" "$T21_SUM_M"
assert_eq "T21: run total checked == sum of miners" \
  "$(sa_num "$T21_TOTAL" '^.*\), ([0-9]+) checked.*')" "$T21_SUM_K"
assert_eq "T21: run total findings == sum of miners" \
  "$(sa_num "$T21_TOTAL" '^.*, ([0-9]+) findings$')" "$T21_SUM_F"
assert_not_contains "T21: no internal accounting mismatch reported" "$SA_OUTPUT" \
  "coverage accounting mismatch"

# --- Test 22 (AC4): the captured-real 11/11 APPROVE board, six of whose files
# carry `REJECT: none` boilerplate, produces ZERO rejection findings ---
T22=$(mk_project "t22")
mkdir -p "$T22/nazgul/reviews/FEATURE-FEAT-010"
cp "$APPROVE_BOARD"/*.md "$T22/nazgul/reviews/FEATURE-FEAT-010/"
BOILERPLATE=$(grep -lE '^-[[:space:]]*\*{0,2}REJECT' "$T22/nazgul/reviews/FEATURE-FEAT-010"/*.md | wc -l | tr -d ' ')
assert_eq "T22: fixture really carries the boilerplate (6 files)" "$BOILERPLATE" "6"
run_self_audit "$T22/nazgul"
assert_exit_code "T22: exits 0" "$SA_EC" 0
assert_file_not_contains "T22: unanimous APPROVE board emits no rejection finding" \
  "$T22/nazgul/improvements.md" "Review rejection:"
assert_contains "T22: all 11 verdicts were classified, none skipped" "$SA_OUTPUT" \
  "self-audit/review-rejections: 11 scanned, 0 skipped (unreadable=0, unclassifiable=0, not-applicable=0), 11 checked, 0 findings"

# --- Test 23 (AC4): the same board turns red when ONE verdict really rejects —
# a fixture that can only pass is evidence of nothing ---
T23=$(mk_project "t23")
mkdir -p "$T23/nazgul/reviews/FEATURE-FEAT-010"
cp "$APPROVE_BOARD"/*.md "$T23/nazgul/reviews/FEATURE-FEAT-010/"
sed 's/^verdict: APPROVE$/verdict: CHANGES_REQUESTED/' "$APPROVE_BOARD/qa-reviewer.md" \
  > "$T23/nazgul/reviews/FEATURE-FEAT-010/qa-reviewer.md"
run_self_audit "$T23/nazgul"
assert_exit_code "T23: exits 0" "$SA_EC" 0
assert_file_contains "T23: the one real rejection is found" \
  "$T23/nazgul/improvements.md" "Review rejection: FEATURE-FEAT-010/qa-reviewer"
T23_COUNT=$(grep -c "Review rejection:" "$T23/nazgul/improvements.md")
assert_eq "T23: exactly one rejection finding, not one per REJECT mention" "$T23_COUNT" "1"

# --- Test 24 (AC4): a NUL byte flips BSD grep into binary mode and made the same
# board mine differently; `grep -a` keeps the verdict readable ---
T24=$(mk_project "t24")
mkdir -p "$T24/nazgul/reviews/GROUP-1"
{ printf 'binary noise: \000\n'; sed 's/^verdict: APPROVE$/verdict: CHANGES_REQUESTED/' "$APPROVE_BOARD/qa-reviewer.md"; } \
  > "$T24/nazgul/reviews/GROUP-1/qa-reviewer.md"
NULCOUNT=$(LC_ALL=C tr -dc '\000' < "$T24/nazgul/reviews/GROUP-1/qa-reviewer.md" | wc -c | tr -d ' ')
assert_eq "T24: the fixture really carries an embedded NUL" "$NULCOUNT" "1"
run_self_audit "$T24/nazgul"
assert_exit_code "T24: exits 0" "$SA_EC" 0
assert_file_contains "T24: NUL-bearing rejection still detected" \
  "$T24/nazgul/improvements.md" "Review rejection: GROUP-1/qa-reviewer"
assert_contains "T24: NUL file counted as checked, not silently skipped" "$SA_OUTPUT" \
  "self-audit/review-rejections: 1 scanned, 0 skipped (unreadable=0, unclassifiable=0, not-applicable=0), 1 checked, 1 findings"

# --- Test 25 (AC1): a generic harness agent type names no Nazgul role, so it is
# reported unclassifiable instead of compared against models.default ---
T25=$(mk_project "t25")
T25T="$TMPDIR_BASE/t25-transcripts/session1/subagents"
mkdir -p "$T25T"
printf '{"attributionAgent":"general-purpose","message":{"model":"haiku"}}\n' > "$T25T/agent-b1.jsonl"
printf '{"attributionAgent":"Explore","message":{"model":"haiku"}}\n' > "$T25T/agent-b2.jsonl"
run_self_audit_with_transcripts "$T25/nazgul" "$TMPDIR_BASE/t25-transcripts"
assert_exit_code "T25: exits 0" "$SA_EC" 0
assert_file_not_contains "T25: generic agent types emit no drift finding" \
  "$T25/nazgul/improvements.md" "Model-tier drift"
assert_contains "T25: both reported unclassifiable, and the miner says so" "$SA_OUTPUT" \
  "self-audit/token-cost: 2 scanned, 2 skipped (unreadable=0, unclassifiable=2, not-applicable=0), 0 checked, 0 findings"

# --- Test 26 (AC1): a transcript with NO attribution at all is unclassifiable.
# Resolving the role from the opaque filename compared it to models.default ---
T26=$(mk_project "t26")
T26T="$TMPDIR_BASE/t26-transcripts/session1/subagents"
mkdir -p "$T26T"
printf '{"message":{"model":"haiku"}}\n' > "$T26T/agent-c1a2b3c4d5e6f7081.jsonl"
run_self_audit_with_transcripts "$T26/nazgul" "$TMPDIR_BASE/t26-transcripts"
assert_exit_code "T26: exits 0" "$SA_EC" 0
assert_file_not_contains "T26: unattributed transcript emits no drift finding" \
  "$T26/nazgul/improvements.md" "Model-tier drift"
assert_contains "T26: skip is reported, not silent" "$SA_OUTPUT" \
  "self-audit/token-cost: 1 scanned, 1 skipped (unreadable=0, unclassifiable=1, not-applicable=0), 0 checked, 0 findings"

# --- Test 27 (AC2): a configured bare alias is a FAMILY pin — same-family
# resolved ids match, cross-family drift still emits exactly one finding ---
T27=$(mk_project "t27")
T27T="$TMPDIR_BASE/t27-transcripts/session1/subagents"
mkdir -p "$T27T"
printf '{"attributionAgent":"nazgul:implementer","message":{"model":"claude-sonnet-5"}}\n' > "$T27T/agent-d1.jsonl"
printf '{"attributionAgent":"code-reviewer","message":{"model":"claude-3-5-haiku-20241022"}}\n' > "$T27T/agent-d2.jsonl"
printf '{"attributionAgent":"nazgul:planner","message":{"model":"claude-3-5-haiku-20241022"}}\n' > "$T27T/agent-d3.jsonl"
run_self_audit_with_transcripts "$T27/nazgul" "$TMPDIR_BASE/t27-transcripts"
assert_exit_code "T27: exits 0" "$SA_EC" 0
BACKLOG27=$(cat "$T27/nazgul/improvements.md")
assert_not_contains "T27: sonnet alias matches claude-sonnet-5" "$BACKLOG27" "Model-tier drift: implementer"
assert_not_contains "T27: haiku alias matches claude-3-5-haiku-20241022" "$BACKLOG27" "Model-tier drift: code-reviewer"
assert_contains "T27: genuine cross-family drift (opus configured, haiku ran) still reported" \
  "$BACKLOG27" "Model-tier drift: planner ran on claude-3-5-haiku-20241022 (expected opus)"
T27_COUNT=$(grep -c "Model-tier drift" "$T27/nazgul/improvements.md")
assert_eq "T27: exactly one drift finding from three transcripts" "$T27_COUNT" "1"

# --- Test 28 (AC3): an explicit configured full model id stays an EXACT pin, so
# a same-family version mismatch still reports and the exact id does not ---
T28=$(mk_project "t28")
jq '.models.implementation = "claude-sonnet-4-5-20250929"' \
  "$T28/nazgul/config.json" > "$T28/nazgul/config.json.tmp" \
  && mv "$T28/nazgul/config.json.tmp" "$T28/nazgul/config.json"
T28T="$TMPDIR_BASE/t28-transcripts/session1/subagents"
mkdir -p "$T28T"
printf '{"attributionAgent":"implementer","message":{"model":"claude-sonnet-5"}}\n' > "$T28T/agent-e1.jsonl"
run_self_audit_with_transcripts "$T28/nazgul" "$TMPDIR_BASE/t28-transcripts"
assert_exit_code "T28: exits 0" "$SA_EC" 0
assert_file_contains "T28: full-id pin rejects a same-family version mismatch" \
  "$T28/nazgul/improvements.md" \
  "Model-tier drift: implementer ran on claude-sonnet-5 (expected claude-sonnet-4-5-20250929)"
T28B=$(mk_project "t28b")
jq '.models.implementation = "claude-sonnet-4-5-20250929"' \
  "$T28B/nazgul/config.json" > "$T28B/nazgul/config.json.tmp" \
  && mv "$T28B/nazgul/config.json.tmp" "$T28B/nazgul/config.json"
T28BT="$TMPDIR_BASE/t28b-transcripts/session1/subagents"
mkdir -p "$T28BT"
printf '{"attributionAgent":"implementer","message":{"model":"claude-sonnet-4-5-20250929"}}\n' > "$T28BT/agent-e2.jsonl"
run_self_audit_with_transcripts "$T28B/nazgul" "$TMPDIR_BASE/t28b-transcripts"
assert_file_not_contains "T28b: the exact pinned id is not drift" \
  "$T28B/nazgul/improvements.md" "Model-tier drift"

# --- Test 29 (AC6): the mined log window advances — a second run over the same
# events re-reports them as out-of-window instead of re-mining them ---
T29=$(mk_project "t29")
mkdir -p "$T29/nazgul/logs"
printf '{"event":"blocked","task_id":"TASK-001","reason":"lint"}\n{"event":"other"}\n' \
  > "$T29/nazgul/logs/events.jsonl"
run_self_audit "$T29/nazgul"
assert_exit_code "T29a: first run exits 0" "$SA_EC" 0
assert_contains "T29a: first run mines both lines" "$SA_OUTPUT" \
  "self-audit/guard-blocks: 2 scanned, 0 skipped (unreadable=0, unclassifiable=0, not-applicable=0), 2 checked, 1 findings"
assert_file_exists "T29a: high-water mark persisted" "$T29/nazgul/self-audit-window.json"
assert_eq "T29a: mark records the consumed line count" \
  "$(jq -r '.guard_blocks["events.jsonl"]' "$T29/nazgul/self-audit-window.json")" "2"
run_self_audit "$T29/nazgul"
assert_exit_code "T29b: second run exits 0" "$SA_EC" 0
assert_contains "T29b: already-mined lines are out of window, not re-checked" "$SA_OUTPUT" \
  "self-audit/guard-blocks: 2 scanned, 2 skipped (unreadable=0, unclassifiable=0, not-applicable=2), 0 checked, 0 findings"
T29_COUNT=$(grep -c "loop-blocked event" "$T29/nazgul/improvements.md")
assert_eq "T29b: the 2026-08-03-style re-mine does not happen (one entry, not two)" "$T29_COUNT" "1"

# --- Test 30 (AC6): a newly appended event IS mined on the next run ---
printf '{"event":"blocked","task_id":"TASK-002","reason":"conflict"}\n' >> "$T29/nazgul/logs/events.jsonl"
run_self_audit "$T29/nazgul"
assert_exit_code "T30: exits 0" "$SA_EC" 0
assert_contains "T30: only the new line is checked" "$SA_OUTPUT" \
  "self-audit/guard-blocks: 3 scanned, 2 skipped (unreadable=0, unclassifiable=0, not-applicable=2), 1 checked, 1 findings"
assert_file_contains "T30: the new event reaches the backlog" \
  "$T29/nazgul/improvements.md" "TASK-002:conflict"

# --- Test 31 (AC6): a rotated/truncated log is re-mined from the start, loudly —
# a mark ahead of the file is a state change, not a reason to look at nothing ---
printf '{"event":"blocked","task_id":"TASK-009","reason":"rotated"}\n' \
  > "$T29/nazgul/logs/events.jsonl"
run_self_audit "$T29/nazgul"
assert_exit_code "T31: exits 0" "$SA_EC" 0
assert_contains "T31: announces the shrink instead of silently skipping" "$SA_OUTPUT" \
  "is shorter than the recorded mark"
assert_contains "T31: re-mines the whole file" "$SA_OUTPUT" \
  "self-audit/guard-blocks: 1 scanned, 0 skipped (unreadable=0, unclassifiable=0, not-applicable=0), 1 checked, 1 findings"

# --- Test 32 (AC6): snapshot miners are deduped on (title, evidence), so a
# second run over unchanged state appends nothing and says how much it held back ---
T32=$(mk_project "t32")
mkdir -p "$T32/nazgul/tasks"
cat > "$T32/nazgul/tasks/TASK-003.md" << 'EOF'
# TASK-003
- **Retry count**: 2/3
EOF
run_self_audit "$T32/nazgul"
assert_exit_code "T32a: first run exits 0" "$SA_EC" 0
run_self_audit "$T32/nazgul"
assert_exit_code "T32b: second run exits 0" "$SA_EC" 0
T32_COUNT=$(grep -c "TASK-003 required 2 retry attempt(s)" "$T32/nazgul/improvements.md")
assert_eq "T32b: the retry finding appears exactly once across two runs" "$T32_COUNT" "1"
assert_contains "T32b: suppression is reported, not silent" "$SA_OUTPUT" \
  "suppressed as already present in the backlog"

report_results
