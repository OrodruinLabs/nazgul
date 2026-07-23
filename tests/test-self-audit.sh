#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — we assert on exit codes explicitly throughout.

# Test: scripts/self-audit.sh mines in-repo signals + findings.jsonl + best-effort
# transcript cost, appends one well-formed append-only entry per finding, and
# degrades cleanly (never errors) when any source is absent.
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

# --- Test 9: transcript present -> flags tier drift, no false positive on a match ---
ROOT=$(mk_project "t9")
TRANSCRIPTS="$TMPDIR_BASE/t9-transcripts/session1/subagents"
mkdir -p "$TRANSCRIPTS"
printf '{"message":{"model":"opus","usage":{"input_tokens":100,"output_tokens":50}}}\n' \
  > "$TRANSCRIPTS/code-reviewer.jsonl"
printf '{"message":{"model":"sonnet","usage":{"input_tokens":200,"output_tokens":80}}}\n' \
  > "$TRANSCRIPTS/implementer.jsonl"
run_self_audit_with_transcripts "$ROOT/nazgul" "$TMPDIR_BASE/t9-transcripts"
assert_exit_code "T9: exits 0" "$SA_EC" 0
BACKLOG9=$(cat "$ROOT/nazgul/improvements.md")
assert_contains "T9: drift flagged for code-reviewer (opus vs haiku)" "$BACKLOG9" \
  "Model-tier drift: code-reviewer ran on opus (expected haiku)"
assert_not_contains "T9: no drift for implementer (sonnet matches)" "$BACKLOG9" "Model-tier drift: implementer"

# --- Test 10: bare nazgul dir (no reviews/logs/tasks/git) -> exits 0, header-only backlog ---
BARE="$TMPDIR_BASE/t10"
mkdir -p "$BARE/nazgul"
cp "$REPO_ROOT/templates/config.json" "$BARE/nazgul/config.json"
run_self_audit "$BARE/nazgul"
assert_exit_code "T10: bare dir exits 0" "$SA_EC" 0
assert_file_exists "T10: backlog created" "$BARE/nazgul/improvements.md"
assert_contains "T10: backlog has header" "$(cat "$BARE/nazgul/improvements.md")" "Improvements Backlog"

# --- Test 11: unwritable backlog dir -> degrades cleanly (exit 0), never aborts the run ---
# The script runs under `set -euo pipefail` and promises "never fails the run".
# Force the backlog's parent-dir creation to fail deterministically for ANY user
# (incl. root in CI) by pointing self_audit.backlog_path at a path whose parent is
# a regular FILE — `mkdir -p` then cannot create the directory.
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

# --- Test 12: feedback-aggregator on haiku is NOT flagged as tier drift ---
# review-gate dispatches feedback-aggregator on the review_default chain (haiku),
# so _expected_model_for must resolve it to haiku, not fall through to sonnet.
T12ROOT=$(mk_project "t12")
T12T="$TMPDIR_BASE/t12-transcripts/session1/subagents"
mkdir -p "$T12T"
printf '{"message":{"model":"haiku"}}\n' > "$T12T/feedback-aggregator.jsonl"
run_self_audit_with_transcripts "$T12ROOT/nazgul" "$TMPDIR_BASE/t12-transcripts"
assert_exit_code "T12: exits 0" "$SA_EC" 0
assert_not_contains "T12: feedback-aggregator on haiku not flagged as drift (review_default)" \
  "$(cat "$T12ROOT/nazgul/improvements.md")" "Model-tier drift: feedback-aggregator"

# --- Test 13: cost mining scopes to the MOST RECENT session dir only ---
# A prior session's drift must NOT bleed into this objective's backlog.
T13ROOT=$(mk_project "t13")
T13T="$TMPDIR_BASE/t13-transcripts"
mkdir -p "$T13T/session-old/subagents" "$T13T/session-new/subagents"
printf '{"message":{"model":"opus"}}\n'   > "$T13T/session-old/subagents/code-reviewer.jsonl"  # would drift (opus vs haiku)
printf '{"message":{"model":"sonnet"}}\n' > "$T13T/session-new/subagents/implementer.jsonl"     # matches, no drift
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

# --- Test 17: an AMBIGUOUS basename glob (two projects share the leaf slug)
# must NOT arbitrarily pick one — it degrades to the computed (missing) expected
# path so mining reports cost-unavailable rather than mining an unrelated
# project's transcripts (PR #55 review) ---
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

report_results
