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

# lean-comments: allow-run — a deleted function needs a pin or it comes back; this one's only
# shape was the one whose dedup key cannot survive the call.
# ITEM 10 — nz_bounded_timeout_cmd was retained "for callers outside this file" and had none. Its
# only form is `tcmd=$(nz_bounded_timeout_cmd)`, which resolves in a subshell, so every
# degradation the resolution names was written into a shell that then exited. Deleted, and pinned
# deleted: the resolution is _bnet_resolve_timeout_cmd, which sets _BNET_TCMD in the CALLER.
assert_eq "the printing wrapper whose only shape loses its own dedup key is gone" \
  "$(declare -F nz_bounded_timeout_cmd >/dev/null 2>&1 && echo defined || echo deleted)" "deleted"
BN_DEAD_CALLS=$(grep -rn 'nz_bounded_timeout_cmd' "$REPO_ROOT/scripts" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#' | grep -c '[^[:space:]]')
assert_eq "and no shipped script defines or calls it — a name with no definition is a 127 waiting for a caller" \
  "$BN_DEAD_CALLS" "0"
assert_eq "the resolution it wrapped is still reachable, so the deletion removed a shape and not a capability" \
  "$(declare -F _bnet_resolve_timeout_cmd >/dev/null 2>&1 && echo present || echo missing)" "present"

for fn in nz_bounded_run nz_bounded_run_q nz_bounded_git nz_bounded_run_split; do
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

# lean-comments: allow-run — the population is the point; pinning ONE reason is how the
# subshell defect survived a suite that already had a dedup test.
# Every `_bnet_degrade` reason must dedup, and the one pinned above deduped only because
# nz_bounded_run emits it from the CALLER's shell. A sibling emitted inside
# `tcmd=$(nz_bounded_timeout_cmd)` wrote its dedup key into a subshell that then exited, so
# three calls printed three lines and forked three emit-event subshells; that printing wrapper
# has since been DELETED, because its only shape was the losing one. The reason set is
# DERIVED from the call sites, so a reason added later is covered where it lands rather
# than where a hand-kept list happens to name it; a reason with no driver is REPORTED as
# undriven, never counted as passing.
BN_ONLY_GTIMEOUT=""
if command -v gtimeout >/dev/null 2>&1; then
  BN_ONLY_GTIMEOUT="$TEST_DIR/only-gtimeout"
  mkdir -p "$BN_ONLY_GTIMEOUT"
  ln -sf "$(command -v gtimeout)" "$BN_ONLY_GTIMEOUT/gtimeout"
  # `timeout` is deliberately absent; the library's own source-time needs are not.
  for _bn_tool in dirname mkdir date; do
    _bn_path=$(command -v "$_bn_tool" 2>/dev/null) || continue
    ln -sf "$_bn_path" "$BN_ONLY_GTIMEOUT/$_bn_tool"
  done
fi
BN_TRUE_BIN=/usr/bin/true
[ -x "$BN_TRUE_BIN" ] || BN_TRUE_BIN=/bin/true

# bn_dedup_run <reason> -> stderr of three consecutive calls in ONE process that all reach
# <reason>, using ONE label throughout because the contract is once per label per process.
bn_dedup_run() {
  local reason="$1" body=""
  case "$reason" in
    unbounded_no_timeout_binary)
      body='NAZGUL_TIMEOUT_CMD= nz_bounded_run net dedup-probe true' ;;
    wallclock_unbounded_transfer_bounded)
      body='NAZGUL_TIMEOUT_CMD= nz_bounded_git net dedup-probe --version >/dev/null' ;;
    refused_timeout_cmd_override)
      body='NAZGUL_TIMEOUT_CMD=/nonexistent/hostile-timeout nz_bounded_run net dedup-probe true' ;;
    unresolvable_timeout_cmd_override)
      [ -n "$BN_ONLY_GTIMEOUT" ] || return 3
      body="NAZGUL_TIMEOUT_CMD=timeout nz_bounded_run net dedup-probe $BN_TRUE_BIN" ;;
    diagnostic_not_captured)
      body="TMPDIR=$TEST_DIR/no-such-tmpdir nz_bounded_run_split net dedup-probe '$TEST_DIR/split-dedup.err' true" ;;
    *) return 3 ;;
  esac
  case "$reason" in
    unresolvable_timeout_cmd_override)
      PATH="$BN_ONLY_GTIMEOUT" "$BASH" -c ". '$LIB'; $body; $body; $body" 2>&1 >/dev/null ;;
    *)
      "$BASH" -c ". '$LIB'; $body; $body; $body" 2>&1 >/dev/null ;;
  esac
}

BN_DEDUP_REASONS=$(grep -oE '_bnet_degrade "[^"]*" "[a-z_]+"' "$LIB" | sed 's/.*"\([a-z_]*\)"$/\1/' | sort -u)
BN_DD_N=0; BN_DD_M=0; BN_DD_K=0; BN_DD_F=0; BN_DD_UNDRIVEN=""
for _bn_reason in $BN_DEDUP_REASONS; do
  BN_DD_N=$((BN_DD_N + 1))
  BN_DD_RC=0
  BN_DD_OUT=$(bn_dedup_run "$_bn_reason") || BN_DD_RC=$?
  if [ "$BN_DD_RC" = "3" ]; then
    BN_DD_M=$((BN_DD_M + 1))
    BN_DD_UNDRIVEN="${BN_DD_UNDRIVEN}${BN_DD_UNDRIVEN:+ }${_bn_reason}"
    continue
  fi
  BN_DD_K=$((BN_DD_K + 1))
  BN_DD_COUNT=$(printf '%s\n' "$BN_DD_OUT" | grep -c "$_bn_reason")
  if [ "$BN_DD_COUNT" = "1" ]; then
    _pass "bounded-net degradation '${_bn_reason}' is named once per label per process, not once per call"
  else
    BN_DD_F=$((BN_DD_F + 1))
    _fail "bounded-net degradation '${_bn_reason}' is named once per label per process" \
      "three calls printed it ${BN_DD_COUNT} time(s) — the dedup key was written into a subshell that exited, so every call also forked an emit-event subshell"
  fi
done
printf '  bnet-dedup: %d scanned, %d skipped (no-driver=%d%s), %d checked, %d findings\n' \
  "$BN_DD_N" "$BN_DD_M" "$BN_DD_M" "${BN_DD_UNDRIVEN:+: $BN_DD_UNDRIVEN}" "$BN_DD_K" "$BN_DD_F"
assert_eq "bnet-dedup: scanned == skipped + checked" "$BN_DD_N" "$((BN_DD_M + BN_DD_K))"
if [ "$BN_DD_K" -ge 3 ]; then
  _pass "bnet-dedup: the walk examined the reason population, not a sample"
else
  _fail "bnet-dedup: the walk examined the reason population" \
    "only ${BN_DD_K} reason(s) driven — a dedup contract proven on one reason is how the subshell defect survived"
fi

# lean-comments: allow-run — the silent-substitution hazard is the point and it is invisible
# from the assertion text.
# An ACCEPTED but unresolvable NAZGUL_TIMEOUT_CMD fell through to auto-detect saying nothing:
# on a gtimeout-only host `NAZGUL_TIMEOUT_CMD=timeout` silently became gtimeout — neither
# honoured nor refused by name, in the one function whose stated rationale is that every
# unusable input is refused by name.
if [ -n "$BN_ONLY_GTIMEOUT" ]; then
  BN_UNRES_ERR="$TEST_DIR/unresolvable.err"
  BN_UNRES_OUT=$(PATH="$BN_ONLY_GTIMEOUT" NAZGUL_TIMEOUT_CMD=timeout \
    "$BASH" -c ". '$LIB'; _bnet_resolve_timeout_cmd; printf '%s' \"\$_BNET_TCMD\"" 2>"$BN_UNRES_ERR")
  assert_eq "an accepted-but-unresolvable override still falls back to the detected binary" \
    "$BN_UNRES_OUT" "gtimeout"
  assert_file_contains "and the substitution is named, not silent — the operator asked for a binary that is not here" \
    "$BN_UNRES_ERR" "unresolvable_timeout_cmd_override"
  assert_file_contains "the diagnostic names the value that was not honoured" \
    "$BN_UNRES_ERR" "timeout"
  BN_RES_ERR="$TEST_DIR/resolvable.err"
  BN_RES_OUT=$(PATH="$BN_ONLY_GTIMEOUT" NAZGUL_TIMEOUT_CMD=gtimeout \
    "$BASH" -c ". '$LIB'; _bnet_resolve_timeout_cmd; printf '%s' \"\$_BNET_TCMD\"" 2>"$BN_RES_ERR")
  assert_eq "an override that DOES resolve is still honoured silently" "$BN_RES_OUT" "gtimeout"
  assert_eq "and an honoured override says nothing — the two states stay distinguishable" \
    "$(wc -c < "$BN_RES_ERR" | tr -d ' ')" "0"
else
  _skip "the accepted-but-unresolvable override (gtimeout is not on this host, so a PATH holding only it cannot be built)"
fi

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

NAZGUL_TIMEOUT_CMD="$FAKEBIN/hostile-timeout" _bnet_resolve_timeout_cmd 2>"$TEST_DIR/ovr.err"
OVR_OUT="$_BNET_TCMD"
assert_not_contains "an override naming an arbitrary executable is never returned as the wrapper" \
  "$OVR_OUT" "hostile-timeout"
assert_file_contains "and the refusal is named rather than silent" \
  "$TEST_DIR/ovr.err" "refused_timeout_cmd_override"
OVR_RUN=$(NAZGUL_TIMEOUT_CMD="$FAKEBIN/hostile-timeout" nz_bounded_run net "suite-override" echo real 2>/dev/null)
assert_eq "nz_bounded_run runs the real command, never the substituted process" "$OVR_RUN" "real"
assert_not_contains "so no attacker-authored payload can reach a caller parsing this stdout" \
  "$OVR_RUN" "deadbeef"

# The override's one legitimate use is the degradation hook, and it must survive the refusal.
NAZGUL_TIMEOUT_CMD= _bnet_resolve_timeout_cmd
assert_eq "the documented empty-string hook still selects the no-binary path" "$_BNET_TCMD" ""
_bnet_resolve_timeout_cmd
BN_DETECTED="$_BNET_TCMD"
if [ -n "$BN_DETECTED" ]; then
  NAZGUL_TIMEOUT_CMD="$BN_DETECTED" _bnet_resolve_timeout_cmd
  assert_eq "an override naming the binary detection would have chosen anyway is still honoured" \
    "$_BNET_TCMD" "$BN_DETECTED"
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
SENT_RP_RC=0
_NAZGUL_REVIEW_PROVENANCE_SOURCED=1 bash -c ". '$BN_LIBDIR/review-provenance.sh'; declare -F validate_review_provenance >/dev/null" \
  >/dev/null 2>&1 || SENT_RP_RC=$?
assert_eq "review-provenance: an exported sentinel no longer leaves the DONE gate's provenance validator undefined" \
  "$SENT_RP_RC" "0"
SENT_PB_RC=0
_NAZGUL_PARALLEL_BATCH_SOURCED=1 bash -c ". '$BN_LIBDIR/parallel-batch.sh'; declare -F compute_dispatch_batch >/dev/null" \
  >/dev/null 2>&1 || SENT_PB_RC=$?
assert_eq "parallel-batch: an exported sentinel no longer leaves the batch selector undefined" \
  "$SENT_PB_RC" "0"

# lean-comments: allow-run — the population is derived, because pinning three names is how the
# fourth and fifth survived PATCH-007 item 7.
# A re-source guard decides whether a library body runs at all, so its SHAPE is the whole
# question. A forgeable one (a `_..._SOURCED` scalar, or a `declare -F` probe) is settable from
# the environment: the scalar makes `source` a no-op defining nothing and every call into that
# library is command-not-found, and `declare -F` is WORSE, because `export -f` survives into a
# child bash and leaves a HOSTILE implementation standing where the scalar merely left a hole.
# The walk therefore classifies rather than counts, and it keeps THREE outcomes apart: a guard it
# recognised, a guard-shaped line it could NOT classify, and a file with no guard at all. The
# middle one is the state item 11 measured as missing — an alternate spelling used to yield an
# empty name and land in the same skip bucket as a file that has no guard, so "looked and could
# not read it" printed exactly what "looked and found none" prints.
bn_guard_region() {
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { exit }
    /^[[:space:]]*#/ { next }
    { print }
  ' "$1"
}
bn_guard_class() {
  local region name
  region=$(bn_guard_region "$1")
  # lean-comments: allow-run — the widened match is the fix, so its reason travels with it.
  # BROAD first, and across the whole region rather than one line: an `if ... then / return 0 /
  # fi` spelling puts the test and the return on different lines, which is exactly the shape the
  # single-line extractor turned into an empty name and a skip.
  printf '%s' "$region" | grep -q 'return' || { printf 'none|'; return 0; }
  printf '%s' "$region" | grep -qE '_[A-Za-z0-9_]*(_SOURCED|_LOADED)|declare -F' || { printf 'none|'; return 0; }
  name=$(printf '%s' "$region" | grep -oE '_[A-Za-z0-9_]*(_SOURCED|_LOADED)' | head -1)
  if printf '%s' "$region" \
    | grep -qE '^\[[[:space:]]+"\$\{_NZ_[A-Z0-9_]+_LOADED\[[1-9][0-9]*\]:-\}"[[:space:]]+=[[:space:]]+"loaded"[[:space:]]+\][[:space:]]*&&[[:space:]]*return 0$'; then
    printf 'env-proof|%s' "$name"
  elif printf '%s' "$region" | grep -qE '_[A-Za-z0-9_]*_SOURCED|declare -F'; then
    printf 'forgeable|%s' "${name:-$(printf '%s' "$region" | grep -oE 'declare -F [A-Za-z0-9_"$]+' | head -1)}"
  else
    printf 'unparsed|%s' "${name:-<unnameable>}"
  fi
}

SENT_N=0; SENT_M=0; SENT_K=0; SENT_F=0; SENT_OK=0; SENT_FOUND=""; SENT_UNPARSED=0; SENT_HELD=""
bn_sentinel_walk() {
  local root="$1" f cls name
  SENT_N=0; SENT_M=0; SENT_K=0; SENT_F=0; SENT_OK=0; SENT_FOUND=""; SENT_UNPARSED=0; SENT_HELD=""
  # The denominator is every shipped shell file, not lib/*.sh alone: `scripts/*.sh` and the two
  # git-hook TEMPLATES were outside it, so a guard planted there was never even looked at.
  for f in "$root"/lib/*.sh "$root"/*.sh "$root"/git-hooks/*; do
    [ -f "$f" ] || continue
    case "$f" in *.md|*.json) continue ;; esac
    SENT_N=$((SENT_N + 1))
    cls=$(bn_guard_class "$f")
    name="${cls#*|}"; cls="${cls%%|*}"
    if [ "$cls" = "none" ]; then
      SENT_M=$((SENT_M + 1))
      continue
    fi
    SENT_K=$((SENT_K + 1))
    case "$cls" in
      env-proof)
        SENT_OK=$((SENT_OK + 1))
        SENT_HELD="${SENT_HELD}${SENT_HELD:+, }${f##*/}:${name}" ;;
      unparsed)
        SENT_UNPARSED=$((SENT_UNPARSED + 1))
        SENT_F=$((SENT_F + 1))
        SENT_FOUND="${SENT_FOUND}${SENT_FOUND:+, }${f##*/}:${name}(unparsed)" ;;
      *)
        SENT_F=$((SENT_F + 1))
        SENT_FOUND="${SENT_FOUND}${SENT_FOUND:+, }${f##*/}:${name}(forgeable)" ;;
    esac
  done
}

bn_sentinel_walk "$REPO_ROOT/scripts"
echo "  source-guard: ${SENT_N} scanned, ${SENT_M} skipped (no-guard=${SENT_M}), ${SENT_K} checked, ${SENT_F} findings (forgeable=$((SENT_F - SENT_UNPARSED)), unparsed=${SENT_UNPARSED})"
assert_eq "source-guard: scanned == skipped + checked" "$SENT_N" "$((SENT_M + SENT_K))"
if [ "$SENT_F" -eq 0 ]; then
  _pass "source-guard: every re-source guard in the tree is one the environment cannot supply${SENT_HELD:+ — $SENT_HELD}"
else
  _fail "source-guard: every re-source guard in the tree is one the environment cannot supply" \
    "$SENT_FOUND"
fi
if [ "$SENT_OK" -ge 5 ]; then
  _pass "source-guard: the walk recognised the shared marker across the tree (${SENT_OK} files)"
else
  _fail "source-guard: the walk recognised the shared marker across the tree" \
    "only ${SENT_OK} env-proof guard(s) found — an extractor that stopped matching reports a clean tree"
fi

# lean-comments: allow-run — the dogfood is the walk's own allow path, and item 11's finding was
# that the previous one proved only that the extractor RAN.
# Every planted guard below is spelled a way the precise extractor does NOT match verbatim, so a
# pass means the walk DISCRIMINATED. The old dogfood planted the single spelling its own `sed`
# already matched, which is why an alternate spelling silently landing in the skip bucket was
# invisible to it. The denominator's two new arms are planted too: a `scripts/*.sh` file and a
# git-hook template that is not `_dispatch.sh`.
BN_DOG="$TEST_DIR/source-guard-dogfood"
rm -rf "$BN_DOG"
mkdir -p "$BN_DOG/lib" "$BN_DOG/git-hooks"
printf '%s\n' '#!/usr/bin/env bash' \
  '[ "${_NZ_DOGFOOD_MARK_LOADED[1]:-}" = "loaded" ] && return 0' \
  '_NZ_DOGFOOD_MARK_LOADED=(0 loaded)' 'dogfood_mark() { :; }' > "$BN_DOG/lib/dogfood-mark.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ -n "${_NAZGUL_DOGFOOD_ALT_SOURCED:-}" ]; then' '  return 0' 'fi' \
  '_NAZGUL_DOGFOOD_ALT_SOURCED=1' 'dogfood_alt() { :; }' > "$BN_DOG/lib/dogfood-alt.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'declare -F dogfood_df >/dev/null 2>&1 && return 0' 'dogfood_df() { :; }' > "$BN_DOG/lib/dogfood-df.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ -n ${_NAZGUL_DOGFOOD_WEIRD_LOADED:-} || -n ${BN_OTHER:-} ]] && return 0' \
  'dogfood_weird() { :; }' > "$BN_DOG/lib/dogfood-weird.sh"
printf '%s\n' '#!/usr/bin/env bash' 'dogfood_clean() { :; }' > "$BN_DOG/lib/dogfood-clean.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '[ -n "${_NAZGUL_DOGFOOD_TOP_SOURCED:-}" ] && return 0' 'dogfood_top() { :; }' > "$BN_DOG/dogfood-top.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '[ -n "${_NAZGUL_DOGFOOD_HOOK_SOURCED-}" ] && return 0' 'dogfood_hook() { :; }' > "$BN_DOG/git-hooks/pre-commit"

bn_sentinel_walk "$BN_DOG"
assert_eq "source-guard dogfood: every planted file is scanned, including the two arms the old walk never looked at" \
  "$SENT_N" "7"
assert_eq "source-guard dogfood: only the guard-less file is skipped" "$SENT_M" "1"
assert_eq "source-guard dogfood: scanned == skipped + checked" "$SENT_N" "$((SENT_M + SENT_K))"
assert_eq "source-guard dogfood: the shared array marker is recognised as env-proof" "$SENT_OK" "1"
assert_eq "source-guard dogfood: all five defeatable/unreadable guards are found, none of them in the skip bucket" \
  "$SENT_F" "5"
assert_eq "source-guard dogfood: four of them are forgeable, in four different spellings" \
  "$((SENT_F - SENT_UNPARSED))" "4"
assert_eq "source-guard dogfood: a guard-shaped line it cannot classify is its OWN state, not a skip" \
  "$SENT_UNPARSED" "1"
assert_contains "source-guard dogfood: an if/then spelling is classified, not silently skipped" \
  "$SENT_FOUND" "_NAZGUL_DOGFOOD_ALT_SOURCED"
assert_contains "source-guard dogfood: a declare -F probe is classified forgeable, for the export -f reason measured below" \
  "$SENT_FOUND" "dogfood-df.sh"
assert_contains "source-guard dogfood: a scripts/*.sh file is inside the denominator" \
  "$SENT_FOUND" "dogfood-top.sh"
assert_contains "source-guard dogfood: a git-hook template other than _dispatch.sh is inside the denominator" \
  "$SENT_FOUND" "pre-commit"
assert_contains "source-guard dogfood: the unparsed one is NAMED as unparsed, not folded in with the forgeable ones" \
  "$SENT_FOUND" "(unparsed)"
bn_sentinel_walk "$REPO_ROOT/scripts"

# lean-comments: allow-run — the classification above rests on this measurement, so it is
# EXECUTED here rather than asserted in a comment.
# `export -f` puts a function in the child's environment as a BASH_FUNC_ entry, so a `declare -F`
# re-source skip returns 0 for a function this process never defined and the library body — the
# thing that would have OVERWRITTEN it — never runs. An imported ARRAY has no such route: bash
# does not export arrays at all, and an imported SCALAR carries element 0 only, in every spelling.
BN_EXPF=$("$BASH" -c 'bn_victim() { echo HOSTILE; }; export -f bn_victim; "$BASH" -c "declare -F bn_victim >/dev/null 2>&1 && echo defeated || echo intact"')
assert_eq "declare -F as a re-source skip is defeated by an exported FUNCTION, not merely by a scalar" \
  "$BN_EXPF" "defeated"
for _bn_spell in '1' 'loaded' '(0 loaded)' ''; do
  BN_MARK=$(_NZ_BOUNDED_NET_LOADED="$_bn_spell" "$BASH" -c 'printf "%s" "${_NZ_BOUNDED_NET_LOADED[1]:-empty}"')
  assert_eq "the array marker cannot be supplied by an exported scalar spelled '${_bn_spell:-<empty>}'" \
    "$BN_MARK" "empty"
done
BN_MARK_REAL=$("$BASH" -c '_NZ_X_LOADED=(0 loaded); printf "%s" "${_NZ_X_LOADED[1]:-empty}"')
assert_eq "and the marker IS satisfiable in-process, so the guard is not vacuously false" \
  "$BN_MARK_REAL" "loaded"

# lean-comments: allow-run — the two halves are opposite failures and a test that drives one
# reads identically to a test that drives both.
# A re-source guard has to do BOTH: skip the body on a re-source (item 12's measured cost — the
# eleven guards PATCH-008 removed added whole library body executions to the PreToolUse hot path)
# and never skip the FIRST load (the 127 hazard, and read-hook-payload.sh:126's `export -f`
# overwrite). The population is DERIVED from the tree's own markers, so a library that adopts one
# later is covered where it lands.
BN_MARKED="$TEST_DIR/marked-libs"
grep -lE '^_NZ_[A-Z0-9_]+_LOADED=\(0 loaded\)$' "$REPO_ROOT"/scripts/lib/*.sh 2>/dev/null | sort > "$BN_MARKED"
BN_RS_N=0; BN_RS_M=0; BN_RS_K=0; BN_RS_F=0; BN_RS_SKIPPED=""
while IFS= read -r _bn_lib; do
  [ -n "$_bn_lib" ] || continue
  BN_RS_N=$((BN_RS_N + 1))
  _bn_fn=$(grep -oE '^[a-z_][a-zA-Z0-9_]*\(\)' "$_bn_lib" | head -1 | tr -d '()')
  if [ -z "$_bn_fn" ]; then
    BN_RS_M=$((BN_RS_M + 1))
    BN_RS_SKIPPED="${BN_RS_SKIPPED}${BN_RS_SKIPPED:+ }${_bn_lib##*/}"
    continue
  fi
  BN_RS_K=$((BN_RS_K + 1))
  _bn_mark=$(grep -oE '^_NZ_[A-Z0-9_]+_LOADED' "$_bn_lib" | head -1)
  BN_RS_FIRST=$(env "${_bn_mark}=1" "$BASH" -c ". '$_bn_lib' >/dev/null 2>&1; declare -F $_bn_fn >/dev/null 2>&1 && echo defined || echo missing")
  BN_RS_AGAIN=$("$BASH" -c ". '$_bn_lib' >/dev/null 2>&1; unset -f $_bn_fn; . '$_bn_lib' >/dev/null 2>&1; declare -F $_bn_fn >/dev/null 2>&1 && echo ran-again || echo skipped")
  if [ "$BN_RS_FIRST" = "defined" ] && [ "$BN_RS_AGAIN" = "skipped" ]; then
    _pass "re-source: ${_bn_lib##*/} loads even with its marker name exported, and skips its body on a genuine re-source"
  else
    BN_RS_F=$((BN_RS_F + 1))
    _fail "re-source: ${_bn_lib##*/} loads even with its marker name exported, and skips its body on a genuine re-source" \
      "first source: $BN_RS_FIRST; second source: $BN_RS_AGAIN"
  fi
done < "$BN_MARKED"
printf '  re-source: %d scanned, %d skipped (no-function=%d%s), %d checked, %d findings\n' \
  "$BN_RS_N" "$BN_RS_M" "$BN_RS_M" "${BN_RS_SKIPPED:+: $BN_RS_SKIPPED}" "$BN_RS_K" "$BN_RS_F"
assert_eq "re-source: scanned == skipped + checked" "$BN_RS_N" "$((BN_RS_M + BN_RS_K))"
if [ "$BN_RS_K" -ge 5 ]; then
  _pass "re-source: the marker population was derived from the tree, not from a list ($BN_RS_K libraries)"
else
  _fail "re-source: the marker population was derived from the tree" \
    "$BN_RS_K marked librar(ies) found under scripts/lib — a derivation that stopped matching checks almost nothing"
fi

# lean-comments: allow-run — the residual is measured and PINNED because the fix is partial by
# choice, and an unstated partial fix reads as a complete one.
# A library sourced by two or more OTHER files under scripts/ can have its whole body executed
# more than once per process. These carry no marker and are NOT fixed here: nazgul-root.sh and
# read-hook-payload.sh each record a deliberate refusal that deserves its own cost argument, and
# the rest (task-utils, structured-state, review-evidence, emit-event, session-tracker,
# destructive-patterns, task-transition-guard) are the widest blast radius in the repo — the
# measured PreToolUse hot path runs task-utils' body 4 times and structured-state's 7, which no
# filter this subtask is allowed to run would cover. The COUNT is pinned so the residual cannot
# grow quietly; shrinking it is a deliberate edit to this number.
BN_RESID=""
for _bn_lib in "$REPO_ROOT"/scripts/lib/*.sh; do
  _bn_n=$(basename "$_bn_lib")
  grep -qE '^_NZ_[A-Z0-9_]+_LOADED=\(0 loaded\)$' "$_bn_lib" && continue
  _bn_cnt=$(grep -rl -- "/$_bn_n" "$REPO_ROOT"/scripts --include='*.sh' 2>/dev/null \
    | grep -v "scripts/lib/$_bn_n" \
    | while read -r _bn_f; do grep -qE "^[[:space:]]*[^#]*/$_bn_n" "$_bn_f" && echo x; done | wc -l | tr -d ' ')
  [ "${_bn_cnt:-0}" -ge 2 ] && BN_RESID="${BN_RESID}${BN_RESID:+ }${_bn_n}"
done
BN_RESID_N=$(printf '%s\n' "$BN_RESID" | tr ' ' '\n' | grep -c '[^[:space:]]')
echo "  re-source residual: ${BN_RESID_N} unguarded librar(ies) reachable from 2+ sourcing files: ${BN_RESID}"
assert_eq "re-source residual: the unfixed population is exactly the one this subtask measured and named" \
  "$BN_RESID_N" "13"

# lean-comments: allow-run — the SHAPE of the call is the defect, so the test has to use the
# shape production uses; driving the direct form is how the previous fix passed while reaching
# nothing.
# ITEM 7 — every production call site of nz_bounded_run_split wraps it in `$( )` to keep the
# payload clean, and a `$( )` subshell can write no variable back to its caller. `_BNET_WARNED`
# was therefore re-created empty on every call: three calls printed three identical degradation
# lines and forked three emit-event subshells. The call-site shape is DERIVED from the shipped
# sources, so this test cannot keep passing against a shape production no longer uses.
BN_SPLIT_TOTAL=0; BN_SPLIT_SUBST=0
while IFS= read -r _bn_site; do
  [ -n "$_bn_site" ] || continue
  BN_SPLIT_TOTAL=$((BN_SPLIT_TOTAL + 1))
  _bn_sf="${_bn_site%%:*}"; _bn_sl="${_bn_site#*:}"; _bn_sl="${_bn_sl%%:*}"
  # A call spanning a line continuation puts `out=$(` two lines above the wrapper's own name, so
  # the window is the statement, not the matched line.
  if sed -n "$(( _bn_sl > 2 ? _bn_sl - 2 : 1 )),${_bn_sl}p" "$_bn_sf" | grep -q '=\$('; then
    BN_SPLIT_SUBST=$((BN_SPLIT_SUBST + 1))
  fi
done <<< "$(grep -rn 'nz_bounded_run_split ' "$REPO_ROOT"/scripts/lib/*.sh \
  | grep -v 'bounded-net\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' | grep -vF 'nz_bounded_run_split <')"

echo "  split-call-sites: ${BN_SPLIT_TOTAL} scanned, 0 skipped, ${BN_SPLIT_TOTAL} checked, $((BN_SPLIT_TOTAL - BN_SPLIT_SUBST)) findings"
if [ "$BN_SPLIT_TOTAL" -ge 3 ]; then
  _pass "split-call-sites: the production population was derived from the tree (${BN_SPLIT_TOTAL} sites)"
else
  _fail "split-call-sites: the production population was derived from the tree" \
    "found ${BN_SPLIT_TOTAL} call site(s) — a derivation that stopped matching drives nothing"
fi
assert_eq "split-call-sites: every one of them captures stdout in a command substitution, which is the shape under test" \
  "$BN_SPLIT_SUBST" "$BN_SPLIT_TOTAL"

BN_SUB_ERR="$TEST_DIR/subshell-dedup.err"
BN_SUB_OUT=$(NAZGUL_TIMEOUT_CMD= "$BASH" -c "
  . '$LIB'
  for _i in 1 2 3; do
    out=\$(nz_bounded_run_split net subshell-probe '$BN_SUB_ERR' echo payload)
  done
  printf '%s' \"\$out\"" 2>"$TEST_DIR/subshell-dedup.stderr")
assert_eq "the command-substituted form still returns the command's stdout alone" "$BN_SUB_OUT" "payload"
assert_eq "a degradation raised inside \$( ) is named ONCE per process, not once per call" \
  "$(grep -c 'unbounded_no_timeout_binary' "$TEST_DIR/subshell-dedup.stderr")" "1"

# The same three calls in the DIRECT form must still dedup: the ledger is an addition to the
# in-shell key, never a replacement for it.
BN_DIR_ERR="$TEST_DIR/direct-dedup.err"
NAZGUL_TIMEOUT_CMD= "$BASH" -c "
  . '$LIB'
  for _i in 1 2 3; do
    nz_bounded_run_split net direct-probe '$BN_DIR_ERR' echo payload >/dev/null
  done" 2>"$TEST_DIR/direct-dedup.stderr"
assert_eq "and the direct form, which already deduped, still does" \
  "$(grep -c 'unbounded_no_timeout_binary' "$TEST_DIR/direct-dedup.stderr")" "1"

# Two DIFFERENT processes must each say it once: the ledger is per process, and a dedup that
# leaked across processes would silence the second operator's only warning.
BN_P1=$(NAZGUL_TIMEOUT_CMD= "$BASH" -c ". '$LIB'; out=\$(nz_bounded_run_split net cross-proc '$TEST_DIR/x1.err' echo p)" 2>&1)
BN_P2=$(NAZGUL_TIMEOUT_CMD= "$BASH" -c ". '$LIB'; out=\$(nz_bounded_run_split net cross-proc '$TEST_DIR/x2.err' echo p)" 2>&1)
assert_contains "a second, unrelated process still gets the degradation named to it" \
  "$BN_P1$BN_P2" "unbounded_no_timeout_binary"
assert_eq "and each of the two processes named it exactly once" \
  "$(printf '%s\n%s\n' "$BN_P1" "$BN_P2" | grep -c 'unbounded_no_timeout_binary')" "2"

# lean-comments: allow-run — the two directions of this failure are opposite and only one of
# them is safe, which is the whole reason it gets a name.
# ITEM 8 — when mktemp cannot produce the diagnostic file, nz_bounded_run_split falls back to
# sending this library's own diagnostics to the terminal and NOT to the caller's errfile. That is
# the pre-fix behaviour restored silently: a bound that fires kills the command before it says
# anything, so the caller's failure record then names an exit code and no reason at all. It is the
# opposite direction from the dedup ledger's own failure, which merely duplicates a line.
BN_MK_ERR="$TEST_DIR/mktemp-fail.err"
: > "$BN_MK_ERR"
BN_MK_STDERR="$TEST_DIR/mktemp-fail.stderr"
BN_MK_OUT=$(NAZGUL_TIMEOUT_CMD= TMPDIR="$TEST_DIR/no-such-tmpdir" "$BASH" -c "
  . '$LIB'
  nz_bounded_run_split net mktemp-probe '$BN_MK_ERR' echo payload" 2>"$BN_MK_STDERR")
assert_eq "an unusable TMPDIR does not stop the call from running" "$BN_MK_OUT" "payload"
assert_file_contains "the lost-diagnostic path is NAMED, like every other unusable state in this file" \
  "$BN_MK_STDERR" "diagnostic_not_captured"
assert_file_contains "and the name says what was lost, not merely that something happened" \
  "$BN_MK_STDERR" "NOT the caller's stderr file"
BN_MK_REASONS=$(grep -oE '_bnet_degrade "[^"]*" "[a-z_]+"' "$LIB" | sed 's/.*"\([a-z_]*\)"$/\1/' | sort -u | tr '\n' ' ')
assert_contains "and it joins the derived reason population, so the dedup walk above covers it too" \
  "$BN_MK_REASONS" "diagnostic_not_captured"

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
