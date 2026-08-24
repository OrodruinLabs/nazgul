#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.
#
# Test: scripts/lib/bounded-net.sh and the call sites it bounds — FEAT-031 TASK-048.
#
# THE FIXTURE IS THE SWEEP'S OWN METHOD, not a mock of a bound. A `gh` stub that never
# returns goes on PATH and the real shipped call path runs against it; before this task
# every one of those calls sat there until an outer guard killed it (exit 124, measured).
# Nothing here contacts a network, a credential, or a real PR.
#
# WHAT IS *NOT* CHECKED HERE, stated rather than implied:
#   - the flock -w wait bound is Linux-only. `flock(1)` is absent from macOS, where both
#     libraries take the O_APPEND fallback, so that case is SKIPPED and counted as skipped
#     on this platform — it is not asserted as passing on a branch that never ran.
#   - a real credential prompt cannot be produced without a real remote and a real tty, so
#     the prompt-suppression half is checked by the variables' VALUES, not by observing a
#     helper decline to prompt.
TEST_NAME="test-bounded-net"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/bounded-net.sh"

# Case 1 first, deliberately: the pre-change red reads as "this library did not exist".
if [ ! -f "$LIB" ]; then
  _fail "the bounding seam exists at scripts/lib/bounded-net.sh" \
    "no file at $LIB — nothing below can be checked"
  report_results
  exit 1
fi

setup_temp_dir
setup_nazgul_dir
create_config
export NAZGUL_DIR="$TEST_DIR/nazgul"
EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"

FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-bnet-fakebin-XXXXXX")
trap 'rm -rf "$FAKEBIN"' EXIT

# The stall: a stub that never returns, exactly as the sweep produced exit 124 with.
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "gh version 2.80.0 (stub)"; exit 0 ;; esac
while :; do sleep 60; done
EOF
chmod +x "$FAKEBIN/gh"

# shellcheck source=../scripts/lib/bounded-net.sh
source "$LIB"

for fn in nz_bounded_run nz_bounded_run_q nz_bounded_git nz_bounded_timeout_cmd; do
  if declare -F "$fn" >/dev/null 2>&1; then
    _pass "the seam exposes $fn"
  else
    _fail "the seam exposes $fn" "not defined after sourcing $LIB"
  fi
done

# --- Half 2: prompt suppression, the half `</dev/null` cannot do ---
assert_eq "GIT_TERMINAL_PROMPT is 0 after sourcing (a credential helper reads /dev/tty, not stdin)" \
  "${GIT_TERMINAL_PROMPT:-unset}" "0"
assert_eq "GH_PROMPT_DISABLED is set after sourcing" "${GH_PROMPT_DISABLED:-unset}" "1"
if [ -n "${GIT_ASKPASS:-}" ] && [ -x "${GIT_ASKPASS}" ]; then
  _pass "GIT_ASKPASS names an executable, so a helper that ignores GIT_TERMINAL_PROMPT still cannot block"
else
  _fail "GIT_ASKPASS names an executable" "GIT_ASKPASS='${GIT_ASKPASS:-unset}'"
fi
assert_contains "GIT_SSH_COMMAND closes the ssh passphrase prompt (the same hang over another transport)" \
  "${GIT_SSH_COMMAND:-}" "BatchMode=yes"

OPERATOR_CHOICE=$(GIT_TERMINAL_PROMPT=1 bash -c "unset _NAZGUL_BOUNDED_NET_SOURCED; . '$LIB'; printf '%s' \"\$GIT_TERMINAL_PROMPT\"")
assert_eq "an operator who exported GIT_TERMINAL_PROMPT=1 keeps it — nothing here overrides a deliberate choice" \
  "$OPERATOR_CHOICE" "1"

# --- Half 1: the duration bound, driven against the stalling stub ---
BN_T0=$(date +%s)
BN_RC=0
PATH="$FAKEBIN:$PATH" NAZGUL_NET_TIMEOUT=2 nz_bounded_run net "suite-stall" gh pr view 1 >/dev/null 2>"$TEST_DIR/stall.err" || BN_RC=$?
BN_ELAPSED=$(( $(date +%s) - BN_T0 ))
assert_eq "a stalling call returns 124 rather than waiting forever" "$BN_RC" "124"
if [ "$BN_ELAPSED" -le 8 ]; then
  _pass "the stalling call returned inside its bound (${BN_ELAPSED}s for a 2s bound)"
else
  _fail "the stalling call returned inside its bound" "took ${BN_ELAPSED}s for a 2s bound"
fi
assert_file_contains "a fired bound is NAMED on stderr, so 'could not bound' never prints as 'was fast'" \
  "$TEST_DIR/stall.err" "bound_exceeded"
assert_file_contains "the diagnostic says a timeout is not an answer from the other end" \
  "$TEST_DIR/stall.err" "TIMEOUT, not an answer"
if [ -f "$EVENTS" ] && grep -q '"event":"bounded_call_timeout"' "$EVENTS"; then
  _pass "a fired bound is recorded on the bus as bounded_call_timeout"
else
  _fail "a fired bound is recorded on the bus as bounded_call_timeout" "not found in $EVENTS"
fi

# A call that simply succeeds must leave neither signal — otherwise the two are the same thing.
: > "$TEST_DIR/fast.err"
nz_bounded_run net "suite-fast" true 2>"$TEST_DIR/fast.err"
assert_eq "a fast call prints nothing (the two states are distinguishable)" \
  "$(wc -c < "$TEST_DIR/fast.err" | tr -d ' ')" "0"

# --- the quiet variant: a call site's own 2>/dev/null must not hide a fired bound ---
BN_RC=0
PATH="$FAKEBIN:$PATH" NAZGUL_NET_TIMEOUT=2 nz_bounded_run_q net "suite-quiet" gh pr view 1 >/dev/null 2>"$TEST_DIR/quiet.err" || BN_RC=$?
assert_eq "nz_bounded_run_q still returns the bound's 124" "$BN_RC" "124"
assert_file_contains "nz_bounded_run_q discards the COMMAND's stderr and keeps this library's own" \
  "$TEST_DIR/quiet.err" "bound_exceeded"

# --- AC2: three unbounded attempts is unbounded — the ATTEMPT is what is bounded ---
CGH="$REPO_ROOT/scripts/lib/connector-github.sh"
RETRY_T0=$(date +%s)
RETRY_RC=0
PATH="$FAKEBIN:$PATH" NAZGUL_NET_TIMEOUT=1 NAZGUL_CGH_RETRY_DELAY=0 \
  bash -c ". '$CGH'; _cgh_gh_retry gh issue list" >/dev/null 2>&1 || RETRY_RC=$?
RETRY_ELAPSED=$(( $(date +%s) - RETRY_T0 ))
assert_eq "_cgh_gh_retry gives up instead of retrying a stall forever" "$RETRY_RC" "1"
if [ "$RETRY_ELAPSED" -le 12 ]; then
  _pass "_cgh_gh_retry's whole 3-attempt budget is bounded (${RETRY_ELAPSED}s), not 3 x infinity"
else
  _fail "_cgh_gh_retry's whole 3-attempt budget is bounded" "took ${RETRY_ELAPSED}s against a 1s-per-attempt bound"
fi

# --- AC4: the two "no timeout binary" states have DIFFERENT names, because they differ ---
NOBIN_OUT=$(NAZGUL_TIMEOUT_CMD= nz_bounded_run net "suite-nobin-gh" echo ran 2>&1)
assert_contains "a gh call with no timeout binary is named unbounded_no_timeout_binary" \
  "$NOBIN_OUT" "unbounded_no_timeout_binary"
assert_contains "and it still RUNS — refusing would turn hardening into an outage on stock macOS" \
  "$NOBIN_OUT" "ran"
NOBIN_GIT=$(NAZGUL_TIMEOUT_CMD= nz_bounded_git net "suite-nobin-git" --version 2>&1)
assert_contains "a git call with no timeout binary gets a DIFFERENT, weaker name — it is partly bounded, not unbounded" \
  "$NOBIN_GIT" "wallclock_unbounded_transfer_bounded"
assert_not_contains "the git degradation is not the gh one wearing another label" \
  "$NOBIN_GIT" "unbounded_no_timeout_binary"

# git's own transfer bound is the half that needs no coreutils — assert it is really passed.
TRACE_OUT=$(NAZGUL_TIMEOUT_CMD= GIT_TRACE=1 nz_bounded_git net "suite-flags" --version 2>&1)
assert_contains "http.lowSpeedLimit is actually handed to git, not merely described" "$TRACE_OUT" "lowSpeedLimit=1000"
assert_contains "http.lowSpeedTime is actually handed to git" "$TRACE_OUT" "lowSpeedTime=60"

# `timeout 0` means NO limit in GNU coreutils, so honouring a 0 override would be a silent unbound.
ZERO_OUT=$(NAZGUL_NET_TIMEOUT=0 nz_bounded_run net "suite-zero" true 2>&1)
assert_contains "a 0 timeout override is refused by name, not honoured into an unbounded call" \
  "$ZERO_OUT" "unusable_timeout_override"
# PATCH-007 item 6: the refusal must cover zero's SPELLINGS. `00` is all-digits and is not the
# string "0", so a literal match let it through — and GNU `timeout 00` is the same no-limit.
assert_eq "a padded-zero override does not become the bound" \
  "$(NAZGUL_NET_TIMEOUT=00 _bnet_secs net)" "60"
assert_contains "and it is refused by the same name, not silently" \
  "$(NAZGUL_NET_TIMEOUT=00 _bnet_secs net 2>&1 >/dev/null)" "unusable_timeout_override"
assert_eq "a padded-zero long-tier override falls back to that tier's own default" \
  "$(NAZGUL_NET_TIMEOUT_LONG=000 _bnet_secs long)" "300"
assert_eq "a legitimately padded positive value is normalised, not refused" \
  "$(NAZGUL_NET_TIMEOUT=030 _bnet_secs net)" "30"
assert_eq "a digit run that overflows bash arithmetic is refused rather than wrapped into a bound" \
  "$(NAZGUL_NET_TIMEOUT=99999999999999999999 _bnet_secs net)" "60"

# A degradation repeated on every probe is noise; once per label is the contract.
DUP_OUT=$(NAZGUL_TIMEOUT_CMD= bash -c ". '$LIB'; nz_bounded_run net dup-label true; nz_bounded_run net dup-label true" 2>&1)
assert_eq "the missing-binary degradation is named once per label per process, not once per call" \
  "$(printf '%s\n' "$DUP_OUT" | grep -c 'unbounded_no_timeout_binary')" "1"

# lean-comments: allow-run — the threat is the point and it is not visible from the assertions.
# NAZGUL_TIMEOUT_CMD is EXECUTED as `"$tcmd" -k 5 "$secs" "$@"`, so an ambient value naming any
# executable substitutes the process whose stdout becomes the merge gate's sole admitting
# evidence — downstream of --repo pinning and of merge-provider's url self-certification alike.
# SYNTHETIC: an attacker-authored wrapper has no real producer to be captured from.
cat > "$FAKEBIN/hostile-timeout" << 'HOSTILE'
#!/usr/bin/env bash
printf '%s\n' '{"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},"headRefName":"attacker/branch","baseRefName":"main","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'
exit 0
HOSTILE
chmod +x "$FAKEBIN/hostile-timeout"

OVR_OUT=$(NAZGUL_TIMEOUT_CMD="$FAKEBIN/hostile-timeout" nz_bounded_timeout_cmd 2>"$TEST_DIR/ovr.err")
assert_not_contains "an override naming an arbitrary executable is never returned as the wrapper" \
  "$OVR_OUT" "hostile-timeout"
assert_file_contains "and the refusal is named rather than silent" \
  "$TEST_DIR/ovr.err" "refused_timeout_cmd_override"
OVR_RUN=$(NAZGUL_TIMEOUT_CMD="$FAKEBIN/hostile-timeout" nz_bounded_run net "suite-override" echo real 2>/dev/null)
assert_eq "nz_bounded_run runs the real command, never the substituted process" "$OVR_RUN" "real"
assert_not_contains "so no attacker-authored payload can reach a caller parsing this stdout" \
  "$OVR_RUN" "deadbeef"

# The override's one legitimate use is the degradation hook, and it must survive the refusal.
assert_eq "the documented empty-string hook still selects the no-binary path" \
  "$(NAZGUL_TIMEOUT_CMD= nz_bounded_timeout_cmd)" ""
BN_DETECTED=$(nz_bounded_timeout_cmd)
if [ -n "$BN_DETECTED" ]; then
  assert_eq "an override naming the binary detection would have chosen anyway is still honoured" \
    "$(NAZGUL_TIMEOUT_CMD="$BN_DETECTED" nz_bounded_timeout_cmd)" "$BN_DETECTED"
else
  _skip "the honoured-override case (neither timeout nor gtimeout is on this host, so there is no binary to name)"
fi

# lean-comments: allow-run — the sentinel is a 127-exit hazard, not a style preference.
# PATCH-007 item 7 — bounded-net carried `_NAZGUL_BOUNDED_NET_SOURCED` above every definition, so
# ONE exported variable made `source` a no-op defining nothing, and every nz_bounded_run call site
# in stack-utils/connector-github/board-sync/doctor then exited 127 mid-operation under `set -e`.
# The same shape nazgul-root.sh:40-49 measured and read-hook-payload.sh:113-124 refused to re-add.
BN_LIBDIR="$(dirname "$LIB")"
SENT_RC=0
SENT_OUT=$(_NAZGUL_BOUNDED_NET_SOURCED=1 bash -c ". '$LIB'; nz_bounded_run net sentinel-probe echo ran" 2>&1) || SENT_RC=$?
assert_eq "an exported source sentinel no longer leaves nz_bounded_run undefined" "$SENT_RC" "0"
assert_contains "and the command still runs" "$SENT_OUT" "ran"
SENT_MP_RC=0
_NAZGUL_MERGE_PROVIDER_SOURCED=1 bash -c ". '$BN_LIBDIR/merge-provider.sh'; declare -F merge_provider_pr_state >/dev/null" \
  >/dev/null 2>&1 || SENT_MP_RC=$?
assert_eq "merge-provider: an exported sentinel no longer leaves the DONE gate's seam undefined" "$SENT_MP_RC" "0"
SENT_RFC_RC=0
_NAZGUL_REVIEW_FILE_CLASS_SOURCED=1 bash -c ". '$BN_LIBDIR/review-file-class.sh'; declare -F review_classify_unit_file >/dev/null" \
  >/dev/null 2>&1 || SENT_RFC_RC=$?
assert_eq "review-file-class: an exported sentinel no longer leaves the shared classifier undefined" "$SENT_RFC_RC" "0"

# --- The load-bearing site: the IMPLEMENTED -> DONE merge-evidence gate ---
setup_git_repo
git -C "$TEST_DIR" remote add origin https://github.com/OrodruinLabs/nazgul.git 2>/dev/null
cat > "$FAKEBIN/gh-auth-ok" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in auth) exit 0 ;; esac
while :; do sleep 60; done
EOF
chmod +x "$FAKEBIN/gh-auth-ok"
cp "$FAKEBIN/gh-auth-ok" "$FAKEBIN/gh"

MP_T0=$(date +%s)
MP_OUT=$(PATH="$FAKEBIN:$PATH" NAZGUL_NET_TIMEOUT=2 NAZGUL_NET_TIMEOUT_QUICK=2 \
  bash -c ". '$REPO_ROOT/scripts/lib/merge-provider.sh'; merge_provider_pr_state '$TEST_DIR' 88" 2>&1)
MP_RC=$?
MP_ELAPSED=$(( $(date +%s) - MP_T0 ))
if [ "$MP_ELAPSED" -le 10 ]; then
  _pass "the IMPLEMENTED -> DONE merge-evidence gate returns against a stalled host (${MP_ELAPSED}s) instead of hanging the loop"
else
  _fail "the merge-evidence gate returns against a stalled host" "took ${MP_ELAPSED}s"
fi
assert_contains "a stalled host is api_failure — emphatically NOT a quietly not-merged ok" "$MP_OUT" "api_failure"
assert_not_contains "no closure is inferable from a bound that fired" "$MP_OUT" '"merged":true'

# --- AC3: flock -w. Honestly scoped: flock(1) is absent on macOS, so this is Linux-only. ---
FLOCK_SCANNED=2
FLOCK_CHECKED=0
FLOCK_SKIPPED=0
for f in scripts/lib/emit-event.sh scripts/lib/raise-finding.sh; do
  if grep -q 'flock -w' "$REPO_ROOT/$f"; then
    _pass "$f takes its exclusive lock with a wait bound (flock -w)"
    FLOCK_CHECKED=$((FLOCK_CHECKED + 1))
  else
    _fail "$f takes its exclusive lock with a wait bound" "no 'flock -w' found — a bare 'flock -x' waits forever"
  fi
done
if command -v flock >/dev/null 2>&1; then
  LOCKDIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-bnet-lock-XXXXXX")
  export EVENTS_FILE="$LOCKDIR/events.jsonl"
  mkdir -p "$LOCKDIR"
  : > "$EVENTS_FILE"
  flock -x "$EVENTS_FILE.lock" sleep 6 &
  HOLDER=$!
  sleep 0.3
  LOCK_ERR="$LOCKDIR/lock.err"
  NAZGUL_EMIT_LOCK_WAIT=1 bash -c ". '$REPO_ROOT/scripts/lib/emit-event.sh'; NAZGUL_DIR='$TEST_DIR/nazgul' EVENTS_FILE='$EVENTS_FILE' emit_event bnet_lock_probe" 2>"$LOCK_ERR"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  assert_file_contains "a held lock is named lock_wait_exceeded rather than waited on forever" "$LOCK_ERR" "lock_wait_exceeded"
  assert_file_contains "and the record is still appended, not dropped" "$EVENTS_FILE" "bnet_lock_probe"
  rm -rf "$LOCKDIR"
else
  _skip "the flock -w wait bound firing (flock(1) is not on this host, so both libs take the O_APPEND fallback — Linux CI only, NOT measured here)"
  FLOCK_SKIPPED=1
fi
printf '%s: flock sites: %d scanned, %d skipped (no-flock-binary=%d), %d checked\n' \
  "$TEST_NAME" "$FLOCK_SCANNED" "$FLOCK_SKIPPED" "$FLOCK_SKIPPED" "$FLOCK_CHECKED"

# --- The whole-tree contract: no `gh` in scripts/** may be reachable unbounded. ---
# Scanned, not sampled: a site added later is caught wherever it lands.
GH_SCANNED=0; GH_CHECKED=0; GH_SKIPPED=0; GH_FINDINGS=0
GH_FILES=$(grep -rlE '(^|[^_[:alnum:]])gh [a-z]' "$REPO_ROOT/scripts" --include='*.sh' 2>/dev/null | sort)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  GH_SCANNED=$((GH_SCANNED + 1))
  rel="${f#"$REPO_ROOT"/}"
  # Sites reached ONLY through a wrapper in the same file are bounded by that wrapper.
  if ! grep -qE '(^|[^_[:alnum:]])gh [a-z]' "$f"; then
    GH_SKIPPED=$((GH_SKIPPED + 1)); continue
  fi
  if grep -q 'nz_bounded_run\|nz_bounded_git\|_GH_BIN' "$f"; then
    GH_CHECKED=$((GH_CHECKED + 1))
  elif grep -q 'destructive-patterns\|DP_PATTERN' "$f"; then
    GH_SKIPPED=$((GH_SKIPPED + 1))
  else
    GH_FINDINGS=$((GH_FINDINGS + 1))
    _fail "every scripts/** file invoking gh routes it through a bound" \
      "$rel invokes gh but references neither nz_bounded_run/nz_bounded_git nor a bounding wrapper"
  fi
done <<< "$GH_FILES"
if [ "$GH_CHECKED" -ge 4 ]; then
  _pass "the gh-bounding scan actually examined the tree ($GH_CHECKED file(s) bounded)"
else
  _fail "the gh-bounding scan actually examined the tree" \
    "only $GH_CHECKED bounded file(s) found — a scan that finds almost nothing is 'never looked', not a clean tree"
fi
[ "$GH_FINDINGS" -eq 0 ] && _pass "no scripts/** file invokes gh outside a bound"
printf '%s: gh call sites: %d scanned, %d skipped (no-gh-invocation=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$GH_SCANNED" "$GH_SKIPPED" "$GH_SKIPPED" "$GH_CHECKED" "$GH_FINDINGS"

teardown_temp_dir
report_results
