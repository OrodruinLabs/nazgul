#!/usr/bin/env bash
set -uo pipefail
# test-hook-stdin-bound — every shipped hook entry point reads stdin through the
# ONE bounded reader, and a held-open pipe ends the process instead of parking it.
# The inverse of the probe that found the defect: that one asserted 124, this one
# asserts completion. Population DERIVED from scripts/*.sh, never authored, so a
# new hook that hand-rolls `$(cat)` is a finding rather than an omission.
# Coverage grammar per RULES §15. K>0 floor; the floor BLOCKS, because a
# derivation that stops matching would report a clean tree with nothing checked.
TEST_NAME="test-hook-stdin-bound"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

READER_LIB="scripts/lib/read-hook-payload.sh"
# An unbounded read is `cat` with NO operand; `$(cat "$f")` reads a FILE and is not
# this defect (an operand-blind pattern named six such call sites before it was pinned).
UNBOUNDED_RE='\$\(cat[[:space:]]*(\)|2>|\|)|^[[:space:]]*cat[[:space:]]*>[[:space:]]*/dev/null'
DISPOSITIONS="fail-open fail-closed"
# Each script gets the bound plus slack; a hang is anything still alive after it.
DEADLINE=6
FLOOR=16

# The scratch project every probe runs against.
PROJ="$SCRATCH/proj"
mkdir -p "$PROJ/nazgul/tasks" "$PROJ/nazgul/logs"
printf '%s\n' '{"feat_id":"T","mode":"hitl","install_mode":"local","execution":{"parallel":true}}' \
  > "$PROJ/nazgul/config.json"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hi","file_path":"/tmp/x"},"session_id":"t","prompt":"hi"}'

# _run_held_open <script-abs> <root> -> the exit code, or 124 if it never ended. A bg
# job inherits /dev/null stdin, and a per-command redirect shuts the fifo at once.
_run_held_open() {
  local script="$1" root="$2" fifo="$SCRATCH/f.$$.$RANDOM" rcfile="$SCRATCH/rc.$$.$RANDOM"
  rm -f "$fifo" "$rcfile"; mkfifo "$fifo" || { echo 125; return 0; }
  ( exec 3> "$fifo"; printf '%s' "$PAYLOAD" >&3; sleep 60; exec 3>&- ) >/dev/null 2>&1 &
  local wpid=$!
  ( CLAUDE_PROJECT_DIR="$root" NAZGUL_FORMATTER_ENABLED=1 \
      bash "$script" >/dev/null 2>&1 < "$fifo"; echo $? > "$rcfile" ) &
  local pid=$! waited=0
  while [ "$waited" -lt "$DEADLINE" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; rm -f "$fifo" "$rcfile"
    echo 124; return 0
  fi
  wait "$pid" 2>/dev/null
  kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  cat "$rcfile" 2>/dev/null || echo "?"
  rm -f "$fifo" "$rcfile"
}

# A hook entry point is a top-level scripts/*.sh that touches stdin at all:
# either through the shared reader, or through a hand-rolled unbounded read.
SCANNED=0; SKIP_NO_STDIN=0; SKIP_UNREADABLE=0; CHECKED=0; FINDINGS=0
HOOKS=""
for f in "$REPO_ROOT"/scripts/*.sh; do
  [ -e "$f" ] || continue
  SCANNED=$((SCANNED + 1))
  if [ ! -r "$f" ]; then SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1)); continue; fi
  if grep -q 'read_hook_payload' "$f" 2>/dev/null || grep -qE "$UNBOUNDED_RE" "$f" 2>/dev/null; then
    HOOKS="$HOOKS ${f##*/}"
  else
    SKIP_NO_STDIN=$((SKIP_NO_STDIN + 1))
  fi
done

HUNG=""
for h in $HOOKS; do
  CHECKED=$((CHECKED + 1))
  rc="$(_run_held_open "$REPO_ROOT/scripts/$h" "$PROJ")"
  if [ "$rc" = "124" ]; then
    FINDINGS=$((FINDINGS + 1)); HUNG="$HUNG$h "
    _fail "$h completes on a held-open pipe" "still running after ${DEADLINE}s — unbounded stdin read"
  else
    _pass "$h completes on a held-open pipe (exit $rc)"
  fi
done

assert_eq "no derived hook parks on a held-open pipe" "${HUNG% }" ""

if [ "$CHECKED" -ge "$FLOOR" ]; then
  _pass "the hook derivation actually looked ($CHECKED checked >= $FLOOR)"
else
  _fail "the hook derivation actually looked" \
    "checked $CHECKED under $REPO_ROOT/scripts — a derivation finding fewer than $FLOOR is 'never looked', not a clean tree"
fi

NO_BRANCH=""; BAD_DISPOSITION=""
for h in $HOOKS; do
  f="$REPO_ROOT/scripts/$h"
  grep -q 'read_hook_payload' "$f" || continue
  grep -q 'HOOK_PAYLOAD_OUTCOME' "$f" || NO_BRANCH="$NO_BRANCH$h "
  grep -q 'hook_payload_timeout_report' "$f" || NO_BRANCH="$NO_BRANCH$h "
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case " $DISPOSITIONS " in *" $d "*) ;; *) BAD_DISPOSITION="$BAD_DISPOSITION$h:$d " ;; esac
  done <<< "$(grep -oE 'hook_payload_timeout_report "[^"]+" "[^"]+"' "$f" | sed -E 's/.*" "([^"]+)"$/\1/')"
done
assert_eq "every caller of the reader branches on the timeout outcome by name" "${NO_BRANCH% }" ""
assert_eq "every timeout disposition is in the closed set {$DISPOSITIONS}" "${BAD_DISPOSITION% }" ""

RESIDUAL=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ "$rel" = "$READER_LIB" ] && continue
  # Comment lines are prose about the defect, not the defect.
  grep -nE "$UNBOUNDED_RE" "$REPO_ROOT/$rel" | grep -qvE '^[0-9]+:[[:space:]]*#' \
    && RESIDUAL="$RESIDUAL$rel "
done <<< "$(cd "$REPO_ROOT" && grep -rlE "$UNBOUNDED_RE" scripts 2>/dev/null)"
assert_eq "no scripts/ file still reads stdin unbounded" "${RESIDUAL% }" ""

cat > "$SCRATCH/outcome.sh" <<'EOS'
set -euo pipefail
. "$1/scripts/lib/read-hook-payload.sh"
read_hook_payload
printf '%s %s\n' "$HOOK_PAYLOAD_OUTCOME" "${#HOOK_PAYLOAD}"
EOS
assert_eq "outcome 1 of 3: a delivered payload reads as 'payload'" \
  "$(printf '{"a":1}\n' | bash "$SCRATCH/outcome.sh" "$REPO_ROOT")" "payload 7"
assert_eq "outcome 2 of 3: a clean EOF with nothing on it reads as 'empty'" \
  "$(bash "$SCRATCH/outcome.sh" "$REPO_ROOT" </dev/null)" "empty 0"

TFIFO="$SCRATCH/tf"; mkfifo "$TFIFO"
( exec 3> "$TFIFO"; printf '{"a":1}' >&3; sleep 30; exec 3>&- ) >/dev/null 2>&1 &
TWPID=$!
TOUT="$(bash "$SCRATCH/outcome.sh" "$REPO_ROOT" < "$TFIFO")"
kill -9 "$TWPID" 2>/dev/null; wait "$TWPID" 2>/dev/null
# Bytes must be 0: bash 5 hands back the partial read, and a truncated envelope
# parsed as a payload is the exact bypass this outcome exists to prevent.
assert_eq "outcome 3 of 3: a stalled pipe reads as 'timeout', with no partial content" \
  "$TOUT" "timeout 0"

TFIFO2="$SCRATCH/tf2"; mkfifo "$TFIFO2"
( exec 3> "$TFIFO2"; printf '{"teammate_name":"x"}' >&3; sleep 30; exec 3>&- ) >/dev/null 2>&1 &
TW2=$!
TIDLE_ERR="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$REPO_ROOT/scripts/teammate-idle-guard.sh" \
  < "$TFIFO2" 2>&1 >/dev/null)"
kill -9 "$TW2" 2>/dev/null; wait "$TW2" 2>/dev/null
assert_contains "a guard that fails open on timeout says so" "$TIDLE_ERR" "timeout"
assert_not_contains "and does not blame the payload it never received" \
  "$TIDLE_ERR" "unparseable payload"
if [ -f "$PROJ/nazgul/logs/teammate-idle.jsonl" ]; then
  assert_file_not_contains "nor writes that cause to its own log" \
    "$PROJ/nazgul/logs/teammate-idle.jsonl" "unparseable payload"
else
  _pass "nor writes that cause to its own log (no log line written at all)"
fi
assert_file_contains "the timeout is on the event bus under its own name" \
  "$PROJ/nazgul/logs/events.jsonl" "hook_stdin_timeout"

# The assertion above is worth only as much as its ability to fail. Same predicate,
# same fifo, against a copy whose reader has had `-t` taken out.
MUT="$SCRATCH/mutant"
mkdir -p "$MUT"
cp -R "$REPO_ROOT/scripts" "$MUT/scripts"
sed -i.bak "s/ -t \"\$HOOK_PAYLOAD_TIMEOUT_SECONDS\"//" "$MUT/$READER_LIB"
rm -f "$MUT/$READER_LIB.bak"
if grep -q -- '-t "$HOOK_PAYLOAD_TIMEOUT_SECONDS"' "$MUT/$READER_LIB"; then
  _fail "[mutation] the bound was actually removed from the copy" "sed left the -t clause in place"
else
  _pass "[mutation] the bound was actually removed from the copy"
  MUT_RC="$(_run_held_open "$MUT/scripts/teammate-idle-guard.sh" "$PROJ")"
  assert_eq "[mutation] and the same predicate then reports the hang it is meant to catch" \
    "$MUT_RC" "124"
fi

SKIPPED=$((SKIP_NO_STDIN + SKIP_UNREADABLE))
if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  printf '%s: INTERNAL — coverage accounting mismatch: %d != %d + %d\n' \
    "$TEST_NAME" "$SCANNED" "$SKIPPED" "$CHECKED" >&2
  exit 3
fi
printf 'hook-stdin-bound: %d scanned, %d skipped (no-stdin-read=%d, unreadable=%d), %d checked, %d findings\n' \
  "$SCANNED" "$SKIPPED" "$SKIP_NO_STDIN" "$SKIP_UNREADABLE" "$CHECKED" "$FINDINGS"

report_results
