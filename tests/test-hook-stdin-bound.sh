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
# Each script gets the bound plus slack; a hang is anything still alive after it. DERIVED, not
# a literal: two readers ship (read-hook-payload.sh at 5s, #245's hook-stdin.sh at 10s) and a
# deadline shorter than the larger bound reports a correctly-bounded hook as a hang.
_HSB_D1="$(sed -n 's/^HOOK_PAYLOAD_DEADLINE_SECONDS=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/scripts/lib/read-hook-payload.sh" 2>/dev/null | head -1)"
_HSB_D2="$(sed -n 's/^__HS_DEFAULT_TIMEOUT=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/scripts/lib/hook-stdin.sh" 2>/dev/null | head -1)"
case "$_HSB_D1" in ''|*[!0-9]*) _HSB_D1=5 ;; esac
case "$_HSB_D2" in ''|*[!0-9]*) _HSB_D2=10 ;; esac
if [ "$_HSB_D1" -ge "$_HSB_D2" ]; then DEADLINE=$((_HSB_D1 + 3)); else DEADLINE=$((_HSB_D2 + 3)); fi
FLOOR=16

# Three roots: $PROJ puts all six fail-closed guards inside their authority, and the other
# two put each scope-gated guard on the far side of the gate it actually reads.
PROJ="$SCRATCH/proj"
mkdir -p "$PROJ/nazgul/tasks" "$PROJ/nazgul/logs"
printf '%s\n' '{"feat_id":"T","mode":"hitl","install_mode":"local","execution":{"parallel":true}}' \
  > "$PROJ/nazgul/config.json"
OUT="$SCRATCH/outscope"
mkdir -p "$OUT/nazgul/tasks" "$OUT/nazgul/logs"
printf '%s\n' '{"feat_id":"T","mode":"hitl","install_mode":"plugin","execution":{"parallel":false,"enforce":{"dispatch_guard":false}}}' \
  > "$OUT/nazgul/config.json"
NOPROJ="$SCRATCH/noproj"
mkdir -p "$NOPROJ"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hi","file_path":"/tmp/x"},"session_id":"t","prompt":"hi"}'

# _run_held_open <script-abs> <root> -> the exit code, or 124 if it never ended. A bg
# job inherits /dev/null stdin, and a per-command redirect shuts the fifo at once.
_run_held_open() {
  local script="$1" root="$2" fifo="$SCRATCH/f.$$.$RANDOM" rcfile="$SCRATCH/rc.$$.$RANDOM"
  rm -f "$fifo" "$rcfile"; mkfifo "$fifo" || { echo 125; return 0; }
  ( exec 3> "$fifo"; printf '%s' "$PAYLOAD" >&3; sleep 60; exec 3>&- ) >/dev/null 2>&1 &
  local wpid=$!
  ( CLAUDE_PROJECT_DIR="$root" NAZGUL_FORMATTER_ENABLED=1 NAZGUL_STAGING_DISABLE=1 \
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

# The disposition each hook DECLARES, off its own reporter call — matching that string
# proves the string, and the exit code below is the behaviour it claims.
DENY_RC=2
CLOSED_HOOKS=""; OPEN_HOOKS=""; UNDECLARED=""; BAD_DISPOSITION=""
for h in $HOOKS; do
  f="$REPO_ROOT/scripts/$h"
  ds="$(grep -oE 'hook_payload_timeout_report "[^"]+" "[^"]+"' "$f" 2>/dev/null \
        | sed -E 's/.*" "([^"]+)"$/\1/' | LC_ALL=C sort -u | tr '\n' ' ')"
  for d in $ds; do
    case " $DISPOSITIONS " in *" $d "*) ;; *) BAD_DISPOSITION="$BAD_DISPOSITION$h:$d " ;; esac
  done
  case " $ds " in
    *" fail-closed "*) CLOSED_HOOKS="$CLOSED_HOOKS$h " ;;
    *" fail-open "*)   OPEN_HOOKS="$OPEN_HOOKS$h " ;;
    *)                 UNDECLARED="$UNDECLARED$h " ;;
  esac
done
assert_eq "every timeout disposition is in the closed set {$DISPOSITIONS}" "${BAD_DISPOSITION% }" ""
CLOSED_FLOOR=6
CLOSED_N=$(printf '%s\n' "$CLOSED_HOOKS" | tr ' ' '\n' | grep -c '[^[:space:]]')
if [ "$CLOSED_N" -ge "$CLOSED_FLOOR" ]; then
  _pass "the fail-closed set was derived from the hooks' own reporter calls ($CLOSED_N >= $CLOSED_FLOOR)"
else
  _fail "the fail-closed set was derived from the hooks' own reporter calls" \
    "derived $CLOSED_N — a derivation that stopped matching would assert nothing about any deny"
fi

HUNG=""; WRONG_RC=""; IN_SCOPE_RC=""
for h in $HOOKS; do
  CHECKED=$((CHECKED + 1))
  rc="$(_run_held_open "$REPO_ROOT/scripts/$h" "$PROJ")"
  IN_SCOPE_RC="$IN_SCOPE_RC$h=$rc "
  if [ "$rc" = "124" ]; then
    FINDINGS=$((FINDINGS + 1)); HUNG="$HUNG$h "
    _fail "$h completes on a held-open pipe" "still running after ${DEADLINE}s — unbounded stdin read"
    continue
  fi
  case " $CLOSED_HOOKS " in
    *" $h "*)
      if [ "$rc" = "$DENY_RC" ]; then
        _pass "$h declares fail-closed and DENIES on a held-open pipe in scope (exit $rc)"
      else
        FINDINGS=$((FINDINGS + 1)); WRONG_RC="$WRONG_RC$h:$rc "
        _fail "$h declares fail-closed and DENIES on a held-open pipe in scope" \
          "exited $rc, not $DENY_RC — the label says deny and the process allowed"
      fi ;;
    *)
      case " $OPEN_HOOKS " in
        *" $h "*)
          if [ "$rc" = "0" ]; then
            _pass "$h declares fail-open and ALLOWS on a held-open pipe (exit $rc)"
          else
            FINDINGS=$((FINDINGS + 1)); WRONG_RC="$WRONG_RC$h:$rc "
            _fail "$h declares fail-open and ALLOWS on a held-open pipe" \
              "exited $rc, not 0 — the label says allow and the process blocked"
          fi ;;
        *) _pass "$h completes on a held-open pipe (exit $rc; declares no disposition)" ;;
      esac ;;
  esac
done

assert_eq "no derived hook parks on a held-open pipe" "${HUNG% }" ""
assert_eq "every declared disposition is the exit code the hook actually produced" "${WRONG_RC% }" ""

if [ "$CHECKED" -ge "$FLOOR" ]; then
  _pass "the hook derivation actually looked ($CHECKED checked >= $FLOOR)"
else
  _fail "the hook derivation actually looked" \
    "checked $CHECKED under $REPO_ROOT/scripts — a derivation finding fewer than $FLOOR is 'never looked', not a clean tree"
fi

# Anchored to a CALL SITE, same shape as the disposition derivation above: every hook
# carries `declare -F hook_payload_timeout_report`, which satisfies a bare-name grep alone.
NO_BRANCH=""
for h in $HOOKS; do
  f="$REPO_ROOT/scripts/$h"
  # Scoped to OUR reader by the LIBRARY it sources, not by the function name: #245's
  # scripts/lib/hook-stdin.sh defines a read_hook_payload too, with its own outcome contract.
  grep -q 'lib/read-hook-payload.sh' "$f" || continue
  grep -q 'read_hook_payload' "$f" || continue
  grep -q 'HOOK_PAYLOAD_OUTCOME' "$f" || NO_BRANCH="$NO_BRANCH$h "
  grep -qE 'hook_payload_timeout_report "[^"]+" "[^"]+"' "$f" || NO_BRANCH="$NO_BRANCH$h "
done
assert_eq "every caller of the reader branches on the timeout outcome by name" "${NO_BRANCH% }" ""

# Each scope-gated guard driven from the far side of its own gate, where it must ALLOW.
# The last row is the counterpart: pre-tool-guard has no scope to defer past, and says so.
DEFERRALS="task-state-guard.sh|NOPROJ|0|no nazgul/config.json, so an unrelated repo's edits were never this guard's to refuse
prompt-guard.sh|NOPROJ|0|no nazgul/config.json, so the prompt sits outside this guard's authority
local-mode-tracking-guard.sh|OUT|0|install_mode is 'plugin', and this guard screens only local-mode projects
parallel-rework-guard.sh|OUT|0|execution.parallel is off, and completed-unit enforcement applies only when it is on
parallel-dispatch-guard.sh|OUT|0|the execution.enforce.dispatch_guard kill switch is off
pre-tool-guard.sh|NOPROJ|2|nothing scopes this guard to a project, so it denies everywhere"
DEF_SCANNED=0; DEF_SKIPPED=0; DEF_CHECKED=0; DEF_FINDINGS=0; UNDISCRIMINATING=""
while IFS='|' read -r dh droot dwant dwhy; do
  [ -n "$dh" ] || continue
  DEF_SCANNED=$((DEF_SCANNED + 1))
  case " $HOOKS " in
    *" $dh "*) ;;
    *) DEF_SKIPPED=$((DEF_SKIPPED + 1))
       _skip "$dh is not in the derived hook population, so its scope gate was not driven"
       continue ;;
  esac
  eval "droot_abs=\$$droot"
  DEF_CHECKED=$((DEF_CHECKED + 1))
  drc="$(_run_held_open "$REPO_ROOT/scripts/$dh" "$droot_abs")"
  if [ "$drc" = "$dwant" ]; then
    _pass "$dh on a held-open pipe in $droot: exit $drc — $dwhy"
  else
    DEF_FINDINGS=$((DEF_FINDINGS + 1))
    _fail "$dh on a held-open pipe in $droot: exit $dwant — $dwhy" \
      "exited $drc"
  fi
  # A row expecting an ALLOW is a deferral only if the SAME guard denied in $PROJ; a guard
  # answering 0 on both sides has no gate, it just never denies.
  if [ "$dwant" = "0" ]; then
    inrc=""
    for kv in $IN_SCOPE_RC; do [ "${kv%%=*}" = "$dh" ] && inrc="${kv#*=}"; done
    [ "$inrc" = "$DENY_RC" ] || UNDISCRIMINATING="$UNDISCRIMINATING$dh(in=$inrc,out=$drc) "
  fi
done <<< "$DEFERRALS"
assert_eq "every scope-gated guard answered BOTH ways — denying in scope, allowing outside it" \
  "${UNDISCRIMINATING% }" ""
echo "  scope-deferral: ${DEF_SCANNED} scanned, ${DEF_SKIPPED} skipped (not-in-derived-population=${DEF_SKIPPED}), ${DEF_CHECKED} checked, ${DEF_FINDINGS} findings"
assert_eq "scope-deferral: scanned == skipped + checked" "$DEF_SCANNED" "$((DEF_SKIPPED + DEF_CHECKED))"

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

# The reader's documented interface is three globals. A fourth, holding up to one chunk
# of payload, would ride into all sixteen sourcing hooks unannounced.
CHUNK_LEAK="$(printf '{"a":1}' | bash -c '. "$1/scripts/lib/read-hook-payload.sh"; read_hook_payload; printf "%s" "${chunk-<unset>}"' _ "$REPO_ROOT")"
assert_eq "the reader leaks no chunk buffer past its three documented globals" "$CHUNK_LEAK" "<unset>"

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

# lean-comments: allow-run — the two guards take OPPOSITE dispositions and the reason is the point.
# PATCH-007 item 3 — `oversize` is mapped onto the `timeout` OUTCOME (deliberately, see the
# reader's header), and both fail-closed guards used to inherit the stall disposition by
# proximity. A stall is transient, so a deny costs a retry; the cap is deterministic, so a deny
# costs the operation forever. Each guard now asks separately and answers by what a false allow
# costs IT: pre-tool-guard still denies, because it is the last thing before the shell and an
# allow would make a cap-sized pad a screening bypass; task-state-guard allows, because it is
# preflight and cannot create authority, and reconciliation is the backstop for the one write it
# could miss. Driven against a copy whose cap is rewritten down, so the ceiling costs the suite
# nothing.
OVERTREE="$SCRATCH/overtree"
mkdir -p "$OVERTREE"
cp -R "$REPO_ROOT/scripts" "$OVERTREE/scripts"
sed -i.bak 's/^HOOK_PAYLOAD_MAX_CHARS=.*/HOOK_PAYLOAD_MAX_CHARS=4096/' "$OVERTREE/$READER_LIB"
rm -f "$OVERTREE/$READER_LIB.bak"
OVER_PROJ="$SCRATCH/overproj"
mkdir -p "$OVER_PROJ/nazgul/tasks" "$OVER_PROJ/nazgul/logs"
printf '%s\n' '{"feat_id":"T","mode":"hitl","install_mode":"local"}' > "$OVER_PROJ/nazgul/config.json"
OVER_PAYLOAD="$SCRATCH/over-envelope.json"
{ printf '{"tool_name":"Write","tool_input":{"file_path":"%s/src/big.txt","content":"' "$OVER_PROJ"
  head -c 16384 /dev/zero | tr '\0' 'x'
  printf '"}}'; } > "$OVER_PAYLOAD"

_run_oversize() {
  local script="$1" ec=0
  CLAUDE_PROJECT_DIR="$OVER_PROJ" NAZGUL_STAGING_DISABLE=1 \
    bash "$script" >/dev/null 2>"$SCRATCH/over.err" < "$OVER_PAYLOAD" || ec=$?
  printf '%s' "$ec"
}

if grep -q '^HOOK_PAYLOAD_MAX_CHARS=4096$' "$OVERTREE/$READER_LIB"; then
  _pass "[fixture] the oversize tree's cap came down to 4096 chars"
  OVER_TSG_RC="$(_run_oversize "$OVERTREE/scripts/task-state-guard.sh")"
  OVER_TSG_ERR="$(cat "$SCRATCH/over.err" 2>/dev/null)"
  assert_eq "task-state-guard: a payload over the cap allows the write, it does not refuse every large Write in the project" \
    "$OVER_TSG_RC" "0"
  assert_contains "task-state-guard: and the allow is LOUD, naming the cap it could not read past" \
    "$OVER_TSG_ERR" "over the 4096-char cap"
  assert_contains "task-state-guard: the disposition is reported as fail-open, not left to be inferred" \
    "$OVER_TSG_ERR" "fail-open"

  OVER_PTG_RC="$(_run_oversize "$OVERTREE/scripts/pre-tool-guard.sh")"
  OVER_PTG_ERR="$(cat "$SCRATCH/over.err" 2>/dev/null)"
  assert_eq "pre-tool-guard: a payload over the cap still DENIES — an allow makes a pad a screening bypass" \
    "$OVER_PTG_RC" "$DENY_RC"
  assert_contains "pre-tool-guard: and the refusal names the cap rather than reporting a stall it did not have" \
    "$OVER_PTG_ERR" "over the 4096-char cap"
  assert_contains "pre-tool-guard: the refusal says what to do instead, since the cap will refuse identically forever" \
    "$OVER_PTG_ERR" "shorter command"
else
  _fail "[fixture] the oversize tree's cap came down to 4096 chars" \
    "no HOOK_PAYLOAD_MAX_CHARS assignment to rewrite — nothing below was driven over the cap"
fi

# A stall is transient, so BOTH still fail closed on one: the split is per-reason, not a blanket
# relaxation of the guard that now allows an oversize payload.
assert_eq "task-state-guard still fails closed on a STALL inside a Nazgul project" \
  "$(_run_held_open "$OVERTREE/scripts/task-state-guard.sh" "$OVER_PROJ")" "$DENY_RC"

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

# The failure this assertion exists to catch: a guard that reports fail-closed and then
# allows anyway, which the old label-matching form passed unchanged.
LIAR="$SCRATCH/liar"
mkdir -p "$LIAR"
cp -R "$REPO_ROOT/scripts" "$LIAR/scripts"
sed -i.bak -e '/hook_payload_timeout_report "pre-tool-guard" "fail-closed"/{n;s/exit 2/exit 0/;}' \
  "$LIAR/scripts/pre-tool-guard.sh"
rm -f "$LIAR/scripts/pre-tool-guard.sh.bak"
LIAR_LABEL="$(grep -c 'hook_payload_timeout_report "pre-tool-guard" "fail-closed"' "$LIAR/scripts/pre-tool-guard.sh")"
if [ "$LIAR_LABEL" = "1" ] && ! cmp -s "$REPO_ROOT/scripts/pre-tool-guard.sh" "$LIAR/scripts/pre-tool-guard.sh"; then
  _pass "[mutation] the copy still DECLARES fail-closed and no longer exits $DENY_RC"
  LIAR_RC="$(_run_held_open "$LIAR/scripts/pre-tool-guard.sh" "$PROJ")"
  assert_eq "[mutation] and the exit-code assertion then sees the allow the label hides" \
    "$LIAR_RC" "0"
else
  _fail "[mutation] the copy still DECLARES fail-closed and no longer exits $DENY_RC" \
    "label count=$LIAR_LABEL, or sed left the copy byte-identical — nothing was mutated, so the check below proves nothing"
fi

# --- The reader's LOAD, asserted rather than assumed: a file that loads and defines
# nothing exits 127, which is nobody's declared posture. Both routes to it are driven. ---

# A FRESH root, because the runs above leave state in $PROJ (one rewrites config.json).
LOAD_PROJ="$SCRATCH/loadproj"
mkdir -p "$LOAD_PROJ/nazgul/tasks" "$LOAD_PROJ/nazgul/logs"
# lean-comments: allow-run — the reset does two jobs and only the first is obvious.
# Rewritten before EVERY measurement: some of these hooks update config.json as part
# of doing their job, and a differential is only a differential over the same inputs.
# CLEARED as well, because session-context.sh is the one DEC_OPAQUE hook: its stdout is compared
# VERBATIM across the clean run and every spoofed one, and session locks, logs and the migration
# .bak that suppresses the migration notice all ACCUMULATE between runs. Measured stable over 18
# runs before this change; measurement is not enforcement, and the reset is what enforces it.
_reset_load_proj() {
  rm -rf "$LOAD_PROJ/nazgul"
  mkdir -p "$LOAD_PROJ/nazgul/tasks" "$LOAD_PROJ/nazgul/logs"
  printf '%s\n' '{"feat_id":"T","mode":"hitl","install_mode":"local","execution":{"parallel":true}}' \
    > "$LOAD_PROJ/nazgul/config.json"
}
_reset_load_proj
LOAD_TREE="$SCRATCH/nolib"
mkdir -p "$LOAD_TREE"
cp -R "$REPO_ROOT/scripts" "$LOAD_TREE/scripts"
printf '%s\n%s\n' '# truncated on purpose: this file loads and defines nothing' ':' \
  > "$LOAD_TREE/$READER_LIB"
SPOOF="_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1"
# Every `_NAZGUL_*_SOURCED` name DERIVED from anywhere under scripts/ — a scripts/lib/*.sh
# glob missed the live one in scripts/git-hooks/_dispatch.sh — plus the reader's retired name.
SENTINELS="$(
  { grep -rhoE '_NAZGUL_[A-Z0-9_]+_SOURCED' "$REPO_ROOT"/scripts 2>/dev/null
    printf '%s\n' '_NAZGUL_READ_HOOK_PAYLOAD_SOURCED'; } | LC_ALL=C sort -u | tr '\n' ' ')"
SENTINEL_N=$(printf '%s\n' "$SENTINELS" | tr ' ' '\n' | grep -c '[^[:space:]]')
# Floors the DERIVED POPULATION, not the pair count below: 16 pairs is reachable from ONE
# surviving name, so a derivation collapsed to a straggler would still clear that bar.
SENTINEL_FLOOR=10
if [ "$SENTINEL_N" -ge "$SENTINEL_FLOOR" ]; then
  _pass "the sentinel population was derived from the tree's own names ($SENTINEL_N >= $SENTINEL_FLOOR)"
else
  _fail "the sentinel population was derived from the tree's own names" \
    "derived $SENTINEL_N names under $REPO_ROOT/scripts — a derivation that stopped matching sweeps almost nothing and still reports zero"
fi

# The DECISION a hook returned, normalised. Raw stdout is not comparable run to run
# (formatter stamps a timestamp), so parseable JSON is canonicalised and the stamp dropped.
_payload_decision() {
  local out="$1"
  [ -n "$out" ] || { printf 'no-output'; return 0; }
  printf '%s' "$out" | jq -Sc 'walk(if type == "object" then del(.timestamp) else . end)' 2>/dev/null && return 0
  printf '%s' "$out" | tr -d '\037' | tr '\n' ' '
}

# _run_payload <script-abs> <root> [env-assignment] -> "<exit>\x1f<decision>\x1f<stderr>". The
# payload is delivered and the pipe closed, so nothing here can hang: what is measured is the load.
_run_payload() {
  local script="$1" root="$2" envassign="${3:-}" ec=0 err out tmp="$SCRATCH/rp.$$.$RANDOM"
  # session-staging gates on a CWD-RELATIVE nazgul/config.json, so an unset
  # NAZGUL_STAGING_DISABLE reaches `git add` over this repo's own working tree.
  if [ -n "$envassign" ]; then
    err=$(CLAUDE_PROJECT_DIR="$root" NAZGUL_FORMATTER_ENABLED=1 NAZGUL_STAGING_DISABLE=1 \
      env "$envassign" bash "$script" 2>&1 >"$tmp" <<< "$PAYLOAD") || ec=$?
  else
    err=$(CLAUDE_PROJECT_DIR="$root" NAZGUL_FORMATTER_ENABLED=1 NAZGUL_STAGING_DISABLE=1 \
      bash "$script" 2>&1 >"$tmp" <<< "$PAYLOAD") || ec=$?
  fi
  out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  printf '%s\x1f%s\x1f%s' "$ec" "$(_payload_decision "$out")" "$err"
}

LOAD_SCANNED=0; LOAD_SKIPPED=0; LOAD_CHECKED=0; LOAD_FINDINGS=0; SENT_CHECKED=0; SPOOF_FINDINGS=0
UNGUARDED=""; UNNAMED=""; SPOOFABLE=""
DEC_JSON=""; DEC_SILENT=""; DEC_OPAQUE=""
for h in $HOOKS; do
  LOAD_SCANNED=$((LOAD_SCANNED + 1))
  case " $CLOSED_HOOKS " in
    *" $h "*) want="$DENY_RC" ;;
    *) case " $OPEN_HOOKS " in
         *" $h "*) want=0 ;;
         *) LOAD_SKIPPED=$((LOAD_SKIPPED + 1))
            _skip "$h declares no disposition, so no posture was asserted for an unloadable reader"
            continue ;;
       esac ;;
  esac
  LOAD_CHECKED=$((LOAD_CHECKED + 1))
  _reset_load_proj
  res="$(_run_payload "$LOAD_TREE/scripts/$h" "$LOAD_PROJ")"
  rc="${res%%$'\x1f'*}"; rrest="${res#*$'\x1f'}"; err="${rrest#*$'\x1f'}"
  if [ "$rc" = "$want" ]; then
    _pass "$h takes its declared posture when the reader loads but defines nothing (exit $rc)"
  else
    LOAD_FINDINGS=$((LOAD_FINDINGS + 1)); UNGUARDED="$UNGUARDED$h:$rc "
    _fail "$h takes its declared posture when the reader loads but defines nothing" \
      "exited $rc, wanted $want — 127 here is the shell aborting on a command-not-found reader, which is not this hook's posture"
  fi
  case "$err" in
    *"stdin reader unavailable"*) ;;
    *) LOAD_FINDINGS=$((LOAD_FINDINGS + 1)); UNNAMED="$UNNAMED$h " ;;
  esac
  # Every library re-source sentinel, against the SHIPPED tree: one exported variable used
  # to make a load a no-op, so each is a differential against a clean environment.
  _reset_load_proj
  clean="$(_run_payload "$REPO_ROOT/scripts/$h" "$LOAD_PROJ")"
  crc="${clean%%$'\x1f'*}"; crest="${clean#*$'\x1f'}"; cdec="${crest%%$'\x1f'*}"
  case "$cdec" in
    no-output) DEC_SILENT="$DEC_SILENT$h " ;;
    '{'*|'['*) DEC_JSON="$DEC_JSON$h " ;;
    *)         DEC_OPAQUE="$DEC_OPAQUE$h " ;;
  esac
  moved=""
  for v in $SENTINELS; do
    SENT_CHECKED=$((SENT_CHECKED + 1))
    _reset_load_proj
    spoofed="$(_run_payload "$REPO_ROOT/scripts/$h" "$LOAD_PROJ" "$v=1")"
    src="${spoofed%%$'\x1f'*}"; srest="${spoofed#*$'\x1f'}"; sdec="${srest%%$'\x1f'*}"
    [ "$crc" = "$src" ] || moved="$moved$v(exit $crc->$src) "
    [ "$cdec" = "$sdec" ] || moved="$moved$v(decision $cdec->$sdec) "
  done
  if [ -z "$moved" ]; then
    _pass "$h returns the same exit AND the same decision under all $SENTINEL_N exported library sentinels (exit $crc, decision $cdec)"
  else
    LOAD_FINDINGS=$((LOAD_FINDINGS + 1)); SPOOF_FINDINGS=$((SPOOF_FINDINGS + 1))
    SPOOFABLE="$SPOOFABLE$h:{${moved% }} "
    _fail "$h returns the same exit AND the same decision under all $SENTINEL_N exported library sentinels" \
      "$moved— an environment variable changed what this hook did"
  fi
done
assert_eq "no hook answers an unloadable reader with anything but its declared posture" "${UNGUARDED% }" ""
assert_eq "every hook NAMES the unloadable reader on stderr rather than exiting mute" "${UNNAMED% }" ""
assert_eq "no hook's exit code OR decision is settable from the environment through any lib sentinel" \
  "${SPOOFABLE% }" ""
DEC_JSON_N=$(printf '%s\n' "$DEC_JSON" | tr ' ' '\n' | grep -c '[^[:space:]]')
DEC_SILENT_N=$(printf '%s\n' "$DEC_SILENT" | tr ' ' '\n' | grep -c '[^[:space:]]')
DEC_OPAQUE_N=$(printf '%s\n' "$DEC_OPAQUE" | tr ' ' '\n' | grep -c '[^[:space:]]')
# The DECISION bound here is stdout plus exit code, and nothing else: a hook that decided
# by writing a file rather than answering the harness is bound by neither of them.
printf 'decision surface: %d parseable-JSON, %d silent (the silence IS the bound value), %d non-JSON stdout compared verbatim [%s]\n' \
  "$DEC_JSON_N" "$DEC_SILENT_N" "$DEC_OPAQUE_N" "${DEC_OPAQUE% }"
if [ "$SENT_CHECKED" -ge "$FLOOR" ]; then
  _pass "the sentinel sweep actually looked ($SENT_CHECKED hook-by-sentinel pairs over $SENTINEL_N names)"
else
  _fail "the sentinel sweep actually looked" \
    "$SENT_CHECKED pairs from $SENTINEL_N derived names — a sweep that drove almost nothing cannot report zero"
fi

# The sharp case behind the differential: the repo's primary safety control, the
# destructive command it exists to stop, and the one variable that used to disable it.
PTG_SPOOF_EC=0
_reset_load_proj
CLAUDE_PROJECT_DIR="$LOAD_PROJ" env "$SPOOF" bash "$REPO_ROOT/scripts/pre-tool-guard.sh" \
  >/dev/null 2>&1 <<< 'rm -rf /' || PTG_SPOOF_EC=$?
assert_eq "an exported sentinel does not unscreen 'rm -rf /' at pre-tool-guard" "$PTG_SPOOF_EC" "$DENY_RC"

# Static counterpart: the reader must carry no re-source guard keyed on a variable,
# because any such name is settable by whoever can set an environment variable.
if grep -qE '^\[ -n "\$\{_[A-Za-z_]+SOURCED' "$REPO_ROOT/$READER_LIB"; then
  _fail "the reader carries no environment-settable re-source sentinel" \
    "$READER_LIB opens with a scalar sentinel again — one exported variable makes the load a no-op and every caller's reader command-not-found"
else
  _pass "the reader carries no environment-settable re-source sentinel"
fi

NO_ASSERT=""
for h in $HOOKS; do
  f="$REPO_ROOT/scripts/$h"
  grep -q 'read-hook-payload.sh' "$f" || continue
  grep -q 'declare -F read_hook_payload' "$f" || NO_ASSERT="$NO_ASSERT$h "
  grep -q 'declare -F hook_payload_timeout_report' "$f" || NO_ASSERT="$NO_ASSERT$h "
done
assert_eq "every hook asserts BOTH reader functions exist after sourcing" "${NO_ASSERT% }" ""

# The assertion is worth what it can catch. Same truncated tree, one copy of the primary
# guard with its post-source check defanged: it must go back to the 127 measured above.
NOASSERT_TREE="$SCRATCH/noassert"
mkdir -p "$NOASSERT_TREE"
cp -R "$LOAD_TREE/scripts" "$NOASSERT_TREE/scripts"
sed -i.bak -e 's/|| rhp_unavailable "read_hook_payload is not defined/|| : "read_hook_payload is not defined/' \
           -e 's/|| rhp_unavailable "hook_payload_timeout_report is not defined/|| : "hook_payload_timeout_report is not defined/' \
  "$NOASSERT_TREE/scripts/pre-tool-guard.sh"
rm -f "$NOASSERT_TREE/scripts/pre-tool-guard.sh.bak"
if grep -q 'rhp_unavailable "read_hook_payload is not defined' "$NOASSERT_TREE/scripts/pre-tool-guard.sh" \
   || cmp -s "$LOAD_TREE/scripts/pre-tool-guard.sh" "$NOASSERT_TREE/scripts/pre-tool-guard.sh"; then
  _fail "[mutation] the post-source check was actually removed from the copy" \
    "sed matched nothing, or left the copy byte-identical — the assertion above proves nothing"
else
  _pass "[mutation] the post-source check was actually removed from the copy"
  _reset_load_proj
  NOASSERT_RES="$(_run_payload "$NOASSERT_TREE/scripts/pre-tool-guard.sh" "$LOAD_PROJ")"
  assert_eq "[mutation] and the guard then exits 127 on the reader it never checked" \
    "${NOASSERT_RES%%$'\x1f'*}" "127"
fi

printf 'load-guard: %d scanned, %d skipped (declares-no-disposition=%d), %d checked, %d findings\n' \
  "$LOAD_SCANNED" "$LOAD_SKIPPED" "$LOAD_SKIPPED" "$LOAD_CHECKED" "$LOAD_FINDINGS"
# Counted in hook-by-sentinel PAIRS: a hook the load pass skipped never had its sentinels
# driven, and reporting a hard-coded 0 skipped said otherwise.
SENT_SCANNED=$((LOAD_SCANNED * SENTINEL_N)); SENT_SKIPPED=$((LOAD_SKIPPED * SENTINEL_N))
printf 'sentinel-sweep: %d scanned, %d skipped (declares-no-disposition=%d), %d checked, %d findings\n' \
  "$SENT_SCANNED" "$SENT_SKIPPED" "$SENT_SKIPPED" "$SENT_CHECKED" "$SPOOF_FINDINGS"
if [ "$SENT_SCANNED" -ne $((SENT_SKIPPED + SENT_CHECKED)) ]; then
  printf '%s: INTERNAL — sentinel-sweep accounting mismatch: %d != %d + %d\n' \
    "$TEST_NAME" "$SENT_SCANNED" "$SENT_SKIPPED" "$SENT_CHECKED" >&2
  exit 3
fi
if [ "$LOAD_SCANNED" -ne $((LOAD_SKIPPED + LOAD_CHECKED)) ]; then
  printf '%s: INTERNAL — load-guard accounting mismatch: %d != %d + %d\n' \
    "$TEST_NAME" "$LOAD_SCANNED" "$LOAD_SKIPPED" "$LOAD_CHECKED" >&2
  exit 3
fi
if [ "$LOAD_CHECKED" -lt "$FLOOR" ]; then
  _fail "the load-guard pass actually looked" \
    "checked $LOAD_CHECKED of $LOAD_SCANNED derived hooks, under the floor of $FLOOR — a pass that checked almost nothing cannot report zero findings"
else
  _pass "the load-guard pass actually looked ($LOAD_CHECKED checked >= $FLOOR)"
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
