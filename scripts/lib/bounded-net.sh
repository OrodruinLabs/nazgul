#!/usr/bin/env bash
# Nazgul bounded-net — the ONE place a `git` or `gh` invocation is made unable to
# wait forever, and the ONE place the non-interactive environment is set.
#
# WHY `</dev/null` IS NOT THIS FIX. A credential helper reads /dev/tty directly, not
# stdin, so redirecting stdin leaves the prompt open and the process parked on a
# terminal nobody is attending. TASK-046's run-tests redirect and TASK-047's bounded
# read are both correct and NEITHER covers this class; before this file
# GIT_TERMINAL_PROMPT, GIT_ASKPASS and GH_PROMPT_DISABLED appeared nowhere in
# scripts/ or tests/ — nothing here suppressed a credential prompt anywhere.
#
# BOTH HALVES ARE REQUIRED AND NEITHER SUBSTITUTES: a duration bound (the wrappers
# below) and prompt suppression (the exports below). A bounded call that is parked on
# a prompt still burns its whole bound; an unbounded call that cannot be prompted
# still waits forever on a dead socket.
#
# A RETRY THAT BOUNDS ATTEMPTS IS NOT A BOUND. Three unbounded attempts is unbounded.
# The retry wrappers in connector-github.sh and board-sync-github.sh cap the attempt
# COUNT; they bound each ATTEMPT through this file.
#
# EVERY DEGRADATION IS NAMED (RULES.md §15). `timeout` is GNU coreutils and absent from
# stock macOS, so it cannot be a hard dependency: when it is missing the call still
# runs, but says so by name on stderr and on the bus. "Could not bound this call" and
# "this call was fast" never print the same thing. The git degradation is deliberately
# a DIFFERENT, weaker name than the gh one, because git carries its own transfer bound
# (http.lowSpeedLimit/http.lowSpeedTime) that needs no coreutils and still aborts a
# stalled transfer — a git call without `timeout` is partly bounded, not unbounded,
# and collapsing the two would misreport which one the operator is running.
#
# NOT `set -euo pipefail` — sourced into caller shells that own their own shell options. The
# exports are the one deliberate source-time side effect: a prompt suppressed per call site is a
# prompt the next call site forgets.
#
# NO SENTINEL, for the reason nazgul-root.sh:40-49 measured and read-hook-payload.sh:113-124
# refused to re-introduce: a scalar `_NAZGUL_BOUNDED_NET_SOURCED` sat above every definition
# here, so one exported variable made this source a no-op defining nothing, and every
# nz_bounded_run call site in stack-utils/connector-github/board-sync/doctor then exited 127
# mid-operation under `set -e`. Any name is settable, so the guard is REMOVED rather than
# renamed. Re-sourcing costs the assignments below and RESETS _BNET_WARNED, which duplicates a
# degradation line rather than suppressing one — the safe direction of that trade.

_BNET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BNET_WARNED=""
_BNET_TCMD=""

# lean-comments: allow-run — the fd indirection exists for one reason and it is not obvious.
# A call site that silences its command's noise with `2>/dev/null` silences THIS too, and a
# bound whose firing cannot be seen is the silence this file was written against. Callers
# that redirect use nz_bounded_run_q, or dup the real stderr once and name the fd here.
_bnet_warn_fd() {
  local fd="${NZ_BOUNDED_WARN_FD:-2}"
  case "$fd" in ''|*[!0-9]*) fd=2 ;; esac
  # A named-but-unopened fd would swallow the diagnostic, which is the failure mode
  # this whole indirection exists to prevent.
  if [ "$fd" != "2" ] && ! { true >&"$fd"; } 2>/dev/null; then
    fd=2
  fi
  printf '%s' "$fd"
}

_bnet_warn() {
  local fd
  fd=$(_bnet_warn_fd)
  printf 'bounded-net: %s\n' "$*" >&"$fd"
}

# _bnet_askpass -> a program that answers a credential prompt with nothing, so a helper
# that ignores GIT_TERMINAL_PROMPT fails fast instead of blocking on a terminal.
_bnet_askpass() {
  local c
  for c in /usr/bin/true /bin/true /usr/bin/echo /bin/echo; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf 'true'
}

# lean-comments: allow-run — states why each is `:-` rather than an unconditional set.
# Set once, at source time, and only when the operator has not already chosen. An
# operator who exported GIT_TERMINAL_PROMPT=1 wants the prompt and gets it; nothing
# here overrides a deliberate choice. GIT_SSH_COMMAND's BatchMode closes the ssh
# passphrase prompt, which is the same hang over a different transport.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GIT_ASKPASS="${GIT_ASKPASS:-$(_bnet_askpass)}"
export GH_PROMPT_DISABLED="${GH_PROMPT_DISABLED:-1}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# _bnet_emit <event_type> [k v ...] -> best-effort telemetry against the caller's tree.
# Resolved per CALL; a no-op on an uninitialised one, so stderr is the primary signal.
_bnet_emit() {
  local event="$1" nazgul_dir=""
  shift
  if [ -n "${NZ_BOUNDED_ROOT:-}" ] && [ -f "${NZ_BOUNDED_ROOT}/nazgul/config.json" ]; then
    nazgul_dir="${NZ_BOUNDED_ROOT}/nazgul"
  elif [ -n "${NAZGUL_DIR:-}" ] && [ -f "${NAZGUL_DIR}/config.json" ]; then
    nazgul_dir="$NAZGUL_DIR"
  else
    return 0
  fi
  [ -f "$_BNET_LIB_DIR/emit-event.sh" ] || return 0
  (
    NAZGUL_DIR="$nazgul_dir"
    # shellcheck disable=SC2034  # read by emit_event, sourced just below
    EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"
    # shellcheck source=./emit-event.sh
    . "$_BNET_LIB_DIR/emit-event.sh"
    emit_event "$event" "$@"
  ) >/dev/null 2>&1 || true
  return 0
}

# _bnet_degrade <label> <reason> <detail> -> name a bound that could NOT be applied,
# once per label per process: repeated on every doctor probe it would be noise to skim.
_bnet_degrade() {
  local label="$1" reason="$2" detail="$3" key
  key=" ${label}:${reason} "
  case "$_BNET_WARNED" in *"$key"*) return 0 ;; esac
  _BNET_WARNED="${_BNET_WARNED}${key}"
  _bnet_warn "$reason: $detail"
  _bnet_emit "bounded_call_degraded" label "$label" reason "$reason" detail "$detail"
}

# lean-comments: allow-run — the tier table and the `0` refusal are the two facts a
# reader needs and neither is visible from the code.
# _bnet_secs <tier> -> the tier's bound in whole seconds, read per CALL so an override
# lands whenever it is set rather than whenever this file was sourced. Tiers: `quick`
# for liveness probes, `net` (default) for ordinary API reads, `long` for transfers. An
# override of 0 is REFUSED and named: GNU `timeout 0` means no limit at all, so honouring
# it would turn an explicit bound into a silent unbounded call.
_bnet_secs() {
  local tier="$1" raw def norm trimmed
  case "$tier" in
    quick) def=20;  raw="${NAZGUL_NET_TIMEOUT_QUICK:-}" ;;
    long)  def=300; raw="${NAZGUL_NET_TIMEOUT_LONG:-}" ;;
    *)     def=60;  raw="${NAZGUL_NET_TIMEOUT:-}" ;;
  esac
  if [ -n "$raw" ]; then
    case "$raw" in
      *[!0-9]*) _bnet_warn "unusable_timeout_override: '$raw' is not a positive whole number of seconds for tier '$tier' — using the ${def}s default instead" ;;
      *)
        # `00` is all-digits and is not the string "0", so a literal match let it reach
        # `timeout 00`, which GNU reads as no limit at all — the zero refusal defeated by a spelling.
        norm=$((10#$raw))
        trimmed="$raw"
        while [ "${#trimmed}" -gt 1 ] && [ "${trimmed:0:1}" = "0" ]; do trimmed="${trimmed:1}"; done
        # A digit run past bash's 64-bit arithmetic WRAPS rather than erroring, so an override
        # that does not survive the round trip is refused rather than honoured as some other bound.
        if [ "$norm" -le 0 ] || [ "$norm" != "$trimmed" ]; then
          _bnet_warn "unusable_timeout_override: '$raw' is not a positive whole number of seconds for tier '$tier' — using the ${def}s default instead"
        else
          def="$norm"
        fi
        ;;
    esac
  fi
  printf '%s' "$def"
}

# lean-comments: allow-run — the accepted set is a security boundary, and the vector it does
# NOT close has to be named or the next reader will over-trust it.
# nz_bounded_timeout_cmd -> `timeout` / `gtimeout` / empty. NAZGUL_TIMEOUT_CMD overrides, but
# ONLY to a value auto-detection could have chosen by itself: the empty string (the documented
# hook that drives the degradation path under test) or a resolvable `timeout`/`gtimeout`.
# Anything else is refused by name and the detected binary used instead, because nz_bounded_run
# EXECUTES this value as `"$tcmd" -k 5 "$secs" "$@"` — so an ambient variable naming an arbitrary
# executable substitutes the process whose stdout becomes the sole admitting evidence for the
# merge gate, which by design has no kill switch. merge-provider's `--repo` pinning and its url
# self-certification are both DOWNSTREAM of that process and never see the substitution. This
# does NOT close PATH poisoning: `command -v` reads PATH, and whoever controls PATH already owns
# `gh`, `git` and `jq` alike. It closes the Nazgul-specific variable nobody audits.
# lean-comments: allow-run — why the resolution sets a global instead of printing, and
# why an accepted-but-absent name is its own refusal.
# _bnet_resolve_timeout_cmd -> set _BNET_TCMD in the CALLER's shell. The degradations below
# dedup through _BNET_WARNED, and `tcmd=$(nz_bounded_timeout_cmd)` wrote that key into a
# subshell that then exited: three calls printed three lines and forked three emit-event
# subshells apiece, while the one reason the suite pinned deduped fine because nz_bounded_run
# emits it directly. An ACCEPTED name that does not resolve is a THIRD state, distinct from
# both the refused arbitrary value and the honoured one: on a gtimeout-only host
# NAZGUL_TIMEOUT_CMD=timeout silently became gtimeout, neither honoured nor refused by name.
_bnet_resolve_timeout_cmd() {
  local want
  _BNET_TCMD=""
  if [ -n "${NAZGUL_TIMEOUT_CMD+set}" ]; then
    want="$NAZGUL_TIMEOUT_CMD"
    case "$want" in
      "") return 0 ;;
      timeout|gtimeout)
        if command -v "$want" >/dev/null 2>&1; then _BNET_TCMD="$want"; return 0; fi
        _bnet_degrade "timeout-cmd" "unresolvable_timeout_cmd_override" \
          "NAZGUL_TIMEOUT_CMD='$want' is an accepted name but is not on PATH — the override is NOT honoured and auto-detection is used instead, which may select the OTHER binary" ;;
      *)
        _bnet_degrade "timeout-cmd" "refused_timeout_cmd_override" \
          "NAZGUL_TIMEOUT_CMD='$want' is neither the empty string nor timeout/gtimeout, and this value is EXECUTED around every bounded call — the override is REFUSED and the detected binary used instead" ;;
    esac
  fi
  if command -v timeout >/dev/null 2>&1; then
    _BNET_TCMD="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    _BNET_TCMD="gtimeout"
  fi
  return 0
}

# nz_bounded_timeout_cmd -> the resolved wrapper on stdout, for callers outside this file.
nz_bounded_timeout_cmd() {
  _bnet_resolve_timeout_cmd
  printf '%s' "$_BNET_TCMD"
}

# lean-comments: allow-run — the two exit codes and the SIGKILL escalation are contract.
# nz_bounded_run <tier> <label> <cmd...> -> <cmd> under a wall-clock bound, returning its
# exit status unchanged. A bound that fired is 124 (SIGTERM) or 137 (SIGKILL, after the
# 5s grace `-k` grants a process that ignores the term), and both are named on stderr and
# on the bus before the status is handed back — a caller that reports only "failed" still
# leaves the reason in the record. With no timeout binary the call is run ANYWAY and the
# missing bound is named: refusing to run would turn a hardening change into an outage on
# every stock macOS host.
nz_bounded_run() {
  local tier="$1" label="$2" secs tcmd rc=0
  shift 2
  secs=$(_bnet_secs "$tier")
  # Resolved in THIS shell, never `$(nz_bounded_timeout_cmd)`: the resolution can degrade,
  # and a dedup key written in a subshell is a dedup that never happened.
  _bnet_resolve_timeout_cmd
  tcmd="$_BNET_TCMD"
  if [ -z "$tcmd" ]; then
    _bnet_degrade "$label" "unbounded_no_timeout_binary" \
      "neither timeout nor gtimeout is on PATH (GNU coreutils is not installed by default on macOS), so '$label' runs with NO duration bound and can wait indefinitely — install coreutils to bound it"
    "$@"
    return $?
  fi
  "$tcmd" -k 5 "$secs" "$@"
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    _bnet_warn "bound_exceeded: '$label' was killed after ${secs}s (exit $rc) — this is a TIMEOUT, not an answer from the other end, and nothing may be inferred from it"
    _bnet_emit "bounded_call_timeout" label "$label" timeout_s:n "$secs" exit_code:n "$rc"
  fi
  return "$rc"
}

# nz_bounded_run_q <tier> <label> <cmd...> -> as nz_bounded_run, with the COMMAND's stderr
# discarded and this library's own diagnostics kept on the caller's real stderr.
nz_bounded_run_q() {
  local tier="$1" label="$2" rc=0
  shift 2
  { NZ_BOUNDED_WARN_FD=9 nz_bounded_run "$tier" "$label" "$@" 2>/dev/null; rc=$?; } 9>&"$(_bnet_warn_fd)"
  return "$rc"
}

# lean-comments: allow-run — the fd split is what made a fired bound unrecordable, and the
# re-emit is why nothing that used to be visible stops being visible.
# nz_bounded_run_split <tier> <label> <errfile> <cmd...> -> as nz_bounded_run, with the COMMAND's
# stdout alone on stdout and BOTH its stderr and this library's own diagnostics in <errfile>. A
# caller that splits stderr to keep the payload clean used to send those diagnostics to fd 9
# instead, so when the bound actually fired (124/137) the command's own stderr was empty and the
# caller's failure record named the exit code and nothing else — `bound_exceeded` reached the
# terminal and never the record a later refusal is read back from. The diagnostics are still
# re-emitted on the caller's real stderr; they are added to <errfile>, never moved there.
nz_bounded_run_split() {
  local tier="$1" label="$2" errfile="$3" bnetfile rc=0
  shift 3
  bnetfile=$(mktemp "${TMPDIR:-/tmp}/nazgul-bnet-diag-XXXXXX" 2>/dev/null) || bnetfile=""
  if [ -z "$bnetfile" ]; then
    { NZ_BOUNDED_WARN_FD=9 nz_bounded_run "$tier" "$label" "$@" 2>"$errfile"; rc=$?; } 9>&2
    return "$rc"
  fi
  { NZ_BOUNDED_WARN_FD=9 nz_bounded_run "$tier" "$label" "$@" 2>"$errfile"; rc=$?; } 9>"$bnetfile"
  if [ -s "$bnetfile" ]; then
    cat "$bnetfile" >&2
    cat "$bnetfile" >> "$errfile" 2>/dev/null || true
  fi
  rm -f "$bnetfile"
  return "$rc"
}

# lean-comments: allow-run — why git gets its own wrapper rather than nz_bounded_run.
# nz_bounded_git <tier> <label> <git-args...> -> git under BOTH bounds. The
# http.lowSpeed* pair is git's own and needs no coreutils, so a stalled transfer aborts
# (exit 128) even where `timeout` is absent — which is why the missing-coreutils case
# here is a different, weaker degradation than nz_bounded_run's: the call is partly
# bounded, not unbounded, and a stall that is not a transfer stall (credential helper,
# a hook, DNS) is the part that remains uncovered.
nz_bounded_git() {
  local tier="$1" label="$2" secs limit
  shift 2
  secs=$(_bnet_secs "$tier")
  limit="${NAZGUL_GIT_LOW_SPEED_LIMIT:-1000}"
  _bnet_resolve_timeout_cmd
  if [ -z "$_BNET_TCMD" ]; then
    _bnet_degrade "$label" "wallclock_unbounded_transfer_bounded" \
      "neither timeout nor gtimeout is on PATH, so '$label' has no wall-clock bound; git's own http.lowSpeedLimit=${limit}/http.lowSpeedTime=${secs} still aborts a stalled transfer, but a non-transfer stall is NOT covered"
    git -c "http.lowSpeedLimit=$limit" -c "http.lowSpeedTime=$secs" "$@"
    return $?
  fi
  nz_bounded_run "$tier" "$label" git -c "http.lowSpeedLimit=$limit" -c "http.lowSpeedTime=$secs" "$@"
}
