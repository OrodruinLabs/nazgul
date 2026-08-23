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
printf '%s %s %s\n' "$HOOK_PAYLOAD_OUTCOME" "${HOOK_PAYLOAD_REASON:-none}" "${#HOOK_PAYLOAD}"
EOS
assert_eq "outcome 1 of 3: a delivered payload reads as 'payload'" \
  "$(printf '{"a":1}\n' | bash "$SCRATCH/outcome.sh" "$REPO_ROOT")" "payload none 7"
assert_eq "outcome 2 of 3: a clean EOF with nothing on it reads as 'empty'" \
  "$(bash "$SCRATCH/outcome.sh" "$REPO_ROOT" </dev/null)" "empty none 0"

TFIFO="$SCRATCH/tf"; mkfifo "$TFIFO"
( exec 3> "$TFIFO"; printf '{"a":1}' >&3; sleep 30; exec 3>&- ) >/dev/null 2>&1 &
TWPID=$!
TOUT="$(bash "$SCRATCH/outcome.sh" "$REPO_ROOT" < "$TFIFO")"
kill -9 "$TWPID" 2>/dev/null; wait "$TWPID" 2>/dev/null
# Bytes must be 0: bash 5 hands back the partial read, and a truncated envelope
# parsed as a payload is the exact bypass this outcome exists to prevent.
assert_eq "outcome 3 of 3: a stalled pipe reads as 'timeout', with no partial content" \
  "$TOUT" "timeout stall 0"

HP_BOUND="$(sed -n 's/^HOOK_PAYLOAD_TIMEOUT_SECONDS=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/$READER_LIB")"
[ -n "$HP_BOUND" ] || HP_BOUND=2
# A read completing INSIDE the bound must never read as `timeout`. $SECONDS counts
# wall-second boundaries crossed, not seconds spent, so the defect is phase-dependent.
SENTINEL="$((HP_BOUND - 1)).9"
STRADDLE_FLOOR=48

# _straddle <root> <trials> <hold-seconds> <stagger-ms> -> "<timeouts> <conclusive> <trials>"
# Trials run concurrently, staggered to SWEEP the starting phase rather than sample it.
_straddle() {
  local root="$1" n="$2" hold="$3" ms="$4" d="$SCRATCH/st.$RANDOM" i off
  mkdir -p "$d"
  for i in $(seq 1 "$n"); do
    off="$(printf '%d.%03d' "$(( (i * ms) / 1000 ))" "$(( (i * ms) % 1000 ))")"
    (
      sleep "$off"
      f="$d/f$i"
      mkfifo "$f" 2>/dev/null || { echo "skip 1" > "$d/o$i"; exit 0; }
      ( exec 3> "$f"; printf '%s' "$PAYLOAD" >&3; sleep "$hold"; exec 3>&- ) >/dev/null 2>&1 &
      w=$!
      # Clock-free over-bound detector: a marker this trial outran cannot have fired.
      ( sleep "$SENTINEL"; : > "$d/late$i" ) >/dev/null 2>&1 &
      s=$!
      o="$(bash "$SCRATCH/outcome.sh" "$root" < "$f")"
      late=0; [ -e "$d/late$i" ] && late=1
      kill -9 "$s" "$w" 2>/dev/null; wait "$s" "$w" 2>/dev/null
      printf '%s %s\n' "${o%% *}" "$late" > "$d/o$i"
    ) &
  done
  wait
  awk '{ t++; if ($1 == "skip" || $2 == 1) next; c++; if ($1 == "timeout") to++ }
       END { printf "%d %d %d", to+0, c+0, t+0 }' "$d"/o*
  rm -rf "$d"
}

read -r NARROW_TO NARROW_C NARROW_N <<< "$(_straddle "$REPO_ROOT" 40 1.05 25)"
assert_eq "40 swept phases: a payload delivered at ~1.05s never reads as 'timeout'" \
  "$NARROW_TO" "0"
read -r WIDE_TO WIDE_C WIDE_N <<< "$(_straddle "$REPO_ROOT" 24 1.5 40)"
assert_eq "24 swept phases: nor one delivered at ~1.5s, three quarters of the way to the bound" \
  "$WIDE_TO" "0"

CONCLUSIVE=$((NARROW_C + WIDE_C))
if [ "$CONCLUSIVE" -ge "$STRADDLE_FLOOR" ]; then
  _pass "the straddle sweep actually swept ($CONCLUSIVE of $((NARROW_N + WIDE_N)) trials conclusive)"
else
  _fail "the straddle sweep actually swept" \
    "only $CONCLUSIVE of $((NARROW_N + WIDE_N)) trials finished inside ${SENTINEL}s — a sweep that measured almost nothing cannot report zero timeouts"
fi

# Same sweep, same predicate, against a copy whose classifier consults the clock FIRST:
# the ordering this file shipped before, restored by putting elapsed back in branch one.
CLOCKFIRST="$SCRATCH/clockfirst"
mkdir -p "$CLOCKFIRST/scripts"
cp -R "$REPO_ROOT/scripts/lib" "$CLOCKFIRST/scripts/lib"
sed -i.bak 's/if \[ "\$rc" -gt 128 \]; then/if [ "$rc" -gt 128 ] || [ "$elapsed" -ge "$HOOK_PAYLOAD_TIMEOUT_SECONDS" ]; then/' \
  "$CLOCKFIRST/$READER_LIB"
rm -f "$CLOCKFIRST/$READER_LIB.bak"
# Both halves matter: a pattern PRESENT is not a pattern sed applied, and the
# copy sharing the original's bytes would make the sweep below prove nothing.
if ! cmp -s "$REPO_ROOT/$READER_LIB" "$CLOCKFIRST/$READER_LIB" \
   && grep -qF -- '-gt 128 ] || [ "$elapsed"' "$CLOCKFIRST/$READER_LIB"; then
  _pass "[mutation] the clock went back ahead of the payload in the copy"
  read -r MUT_TO MUT_C MUT_N <<< "$(_straddle "$CLOCKFIRST" 24 1.5 40)"
  if [ "$MUT_TO" -ge 1 ]; then
    _pass "[mutation] and the sweep then reports the complete payloads it discards ($MUT_TO of $MUT_C conclusive, $MUT_N run)"
  else
    _fail "[mutation] and the sweep then reports the complete payloads it discards" \
      "0 of $MUT_C conclusive trials misclassified — the sweep cannot fail, so its zero above proves nothing"
  fi
else
  _fail "[mutation] the clock went back ahead of the payload in the copy" \
    "sed matched nothing in the classifier's first branch, or left the copy byte-identical"
fi

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

# `read -t` bounds the wait for input to BECOME available, so a producer that
# already wrote everything can never reach it. Size and total time, below.

HP_DEADLINE="$(sed -n 's/^HOOK_PAYLOAD_DEADLINE_SECONDS=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/$READER_LIB")"
if [ -n "$HP_DEADLINE" ]; then
  HP_DEADLINE_DECLARED=1
  HP_DEADLINE_SRC="the reader's own"
  _pass "the reader declares a total wall-clock deadline (${HP_DEADLINE}s)"
else
  HP_DEADLINE_DECLARED=0
  HP_DEADLINE=5
  HP_DEADLINE_SRC="this test's fallback"
  _fail "the reader declares a total wall-clock deadline" \
    "no HOOK_PAYLOAD_DEADLINE_SECONDS in $READER_LIB — with only \`read -t\`, a payload already sitting in the pipe is read with no bound at all"
fi
HP_CAP="$(sed -n 's/^HOOK_PAYLOAD_MAX_CHARS=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/$READER_LIB")"
if [ -n "$HP_CAP" ]; then
  _pass "the reader declares a content cap (${HP_CAP} chars)"
else
  _fail "the reader declares a content cap" \
    "no HOOK_PAYLOAD_MAX_CHARS in $READER_LIB — an arbitrarily large payload is accepted whole"
fi

# The deadline is only meaningful against the budget the harness actually grants.
MIN_HOOK_TIMEOUT="$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[]? | .timeout // empty] | min // empty' \
  "$REPO_ROOT/hooks/hooks.json" 2>/dev/null || echo "")"
if [ "$HP_DEADLINE_DECLARED" = "0" ]; then
  _fail "the read deadline fits inside the smallest budget hooks.json grants a hook" \
    "the reader declares no deadline, so there was no value to compare — this check did not run, which is not the same as passing"
elif [ -n "$MIN_HOOK_TIMEOUT" ] && [ "$MIN_HOOK_TIMEOUT" != "null" ]; then
  if [ "$HP_DEADLINE" -lt "$MIN_HOOK_TIMEOUT" ]; then
    _pass "the read deadline (${HP_DEADLINE}s) fits inside the smallest budget hooks.json grants a hook (${MIN_HOOK_TIMEOUT}s)"
  else
    _fail "the read deadline fits inside the smallest budget hooks.json grants a hook" \
      "deadline ${HP_DEADLINE}s >= ${MIN_HOOK_TIMEOUT}s — the harness kills the hook mid-read and the guard never decides"
  fi
else
  _fail "the read deadline fits inside the smallest budget hooks.json grants a hook" \
    "could not read any timeout out of hooks/hooks.json — the comparison was never made"
fi

# 256 KB is under this repo's own CHANGELOG.md (241 KB) and over RULES.md (163 KB),
# either of which reaches a guard whole as a Write `content` field.
BIG="$SCRATCH/big.json"
{ printf '{"tool_name":"Write","tool_input":{"content":"'
  head -c 262144 /dev/zero | tr '\0' 'x'
  printf '"}}'; } > "$BIG"
BIG_CHARS="$(wc -c < "$BIG" | tr -d ' ')"
BIG_T0=$SECONDS
BIG_OUT="$(bash "$SCRATCH/outcome.sh" "$REPO_ROOT" < "$BIG")"
BIG_SECS=$((SECONDS - BIG_T0))
assert_eq "a 256 KB payload already in the pipe still reads back whole" \
  "$BIG_OUT" "payload none $BIG_CHARS"
if [ "$BIG_SECS" -le "$HP_DEADLINE" ]; then
  _pass "and reads it inside ${HP_DEADLINE_SRC} ${HP_DEADLINE}s deadline (${BIG_SECS}s)"
else
  _fail "and reads it inside ${HP_DEADLINE_SRC} ${HP_DEADLINE}s deadline" \
    "took ${BIG_SECS}s for ${BIG_CHARS} chars — nothing bounded it, and hooks.json gives the PreToolUse guards ${MIN_HOOK_TIMEOUT:-10}s total"
fi

# Same reader, cap rewritten down, so the ceiling is proven at a size that costs
# the suite nothing. A copy that cannot be rewritten has no ceiling to prove.
CAPPED="$SCRATCH/capped"
mkdir -p "$CAPPED/scripts"
cp -R "$REPO_ROOT/scripts/lib" "$CAPPED/scripts/lib"
sed -i.bak 's/^HOOK_PAYLOAD_MAX_CHARS=.*/HOOK_PAYLOAD_MAX_CHARS=4096/' "$CAPPED/$READER_LIB"
rm -f "$CAPPED/$READER_LIB.bak"
if grep -q '^HOOK_PAYLOAD_MAX_CHARS=4096$' "$CAPPED/$READER_LIB"; then
  _pass "[fixture] the cap came down to 4096 chars in the copy"
else
  _fail "[fixture] the cap came down to 4096 chars in the copy" \
    "no HOOK_PAYLOAD_MAX_CHARS assignment to rewrite — this reader has no cap, so the probe below reads the full payload"
fi
OVER="$SCRATCH/over.json"
{ printf '{"c":"'; head -c 16384 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$OVER"
assert_eq "a payload over the cap reads as 'timeout/oversize' with no content — never 'payload', never 'empty'" \
  "$(bash "$SCRATCH/outcome.sh" "$CAPPED" < "$OVER")" "timeout oversize 0"

# Never stalls (each chunk lands inside the stall bound) and never stops, while
# staying under the cap: only a total deadline ends this one.
TRICKLE="$SCRATCH/trickle"
mkdir -p "$TRICKLE/scripts"
cp -R "$REPO_ROOT/scripts/lib" "$TRICKLE/scripts/lib"
sed -i.bak 's/^HOOK_PAYLOAD_DEADLINE_SECONDS=.*/HOOK_PAYLOAD_DEADLINE_SECONDS=2/' "$TRICKLE/$READER_LIB"
rm -f "$TRICKLE/$READER_LIB.bak"
if grep -q '^HOOK_PAYLOAD_DEADLINE_SECONDS=2$' "$TRICKLE/$READER_LIB"; then
  _pass "[fixture] the deadline came down to 2s in the copy"
else
  _fail "[fixture] the deadline came down to 2s in the copy" \
    "no HOOK_PAYLOAD_DEADLINE_SECONDS assignment to rewrite — this reader has no total bound to shorten"
fi
TRICKLE_CHUNK="$(head -c 9000 /dev/zero | tr '\0' 'y')"
DFIFO="$SCRATCH/df"; mkfifo "$DFIFO"
( exec 3> "$DFIFO"
  i=0
  while [ "$i" -lt 20 ]; do printf '%s' "$TRICKLE_CHUNK" >&3; sleep 0.5; i=$((i + 1)); done
  exec 3>&- ) >/dev/null 2>&1 &
DPID=$!
DOUT="$(bash "$SCRATCH/outcome.sh" "$TRICKLE" < "$DFIFO")"
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
assert_eq "a producer that never stalls and never stops is ended by the total deadline" \
  "$DOUT" "timeout deadline 0"

# Termination alone proves nothing about its cause; the same producer against the
# same reader with the deadline moved out of reach must NOT end inside the probe.
LONG="$SCRATCH/longdeadline"
mkdir -p "$LONG/scripts"
cp -R "$REPO_ROOT/scripts/lib" "$LONG/scripts/lib"
sed -i.bak 's/^HOOK_PAYLOAD_DEADLINE_SECONDS=.*/HOOK_PAYLOAD_DEADLINE_SECONDS=600/' "$LONG/$READER_LIB"
rm -f "$LONG/$READER_LIB.bak"
if grep -q '^HOOK_PAYLOAD_DEADLINE_SECONDS=600$' "$LONG/$READER_LIB"; then
  _pass "[mutation] the deadline went out of reach (600s) in the copy"
  DFIFO2="$SCRATCH/df2"; mkfifo "$DFIFO2"
  ( exec 3> "$DFIFO2"
    i=0
    while [ "$i" -lt 40 ]; do printf '%s' "$TRICKLE_CHUNK" >&3; sleep 0.5; i=$((i + 1)); done
    exec 3>&- ) >/dev/null 2>&1 &
  DPID2=$!
  ( bash "$SCRATCH/outcome.sh" "$LONG" < "$DFIFO2" >/dev/null 2>&1 ) &
  RPID=$!
  MWAIT=0
  while [ "$MWAIT" -lt 4 ]; do
    kill -0 "$RPID" 2>/dev/null || break
    sleep 1; MWAIT=$((MWAIT + 1))
  done
  if kill -0 "$RPID" 2>/dev/null; then
    _pass "[mutation] and the same producer then runs past ${MWAIT}s — the 2s end above was the deadline, not the producer"
  else
    _fail "[mutation] and the same producer then runs past 4s" \
      "it ended anyway with the deadline at 600s, so the assertion above cannot tell a deadline from a producer that simply stopped"
  fi
  kill -9 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
  kill -9 "$DPID2" 2>/dev/null; wait "$DPID2" 2>/dev/null
else
  _fail "[mutation] the deadline went out of reach (600s) in the copy" \
    "no HOOK_PAYLOAD_DEADLINE_SECONDS assignment to rewrite"
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
