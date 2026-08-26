#!/usr/bin/env bash
set -uo pipefail

# Test: scripts/lib/manifest-write.sh — the shared transactional manifest-write
# primitive (FEAT-036 / ADR-031). Drives the seven protocol steps and every named
# failure path, each negative probe paired with a positive control that is recorded
# as having fired: a probe whose machinery cannot fire proves nothing.
TEST_NAME="test-manifest-write-primitive"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/manifest-write.sh"
# shellcheck source=/dev/null
source "$LIB"

setup_temp_dir
setup_nazgul_dir
NZ="$TEST_DIR/nazgul"
SCRATCH="$TEST_DIR/scratch"
mkdir -p "$SCRATCH"

# The eight named failure paths this file owes, and the controls that prove each
# probe's machinery is live. Both populations are reported, never assumed.
FAILURE_PATHS="cas_mismatch_snapshot cas_mismatch_install producer_failed producer_empty verify_failed symlink_destination mode_unreadable lock_unavailable"
FP_SEEN=""
CTL_FIRED=""

record_failure_path() { FP_SEEN="${FP_SEEN} $1"; }
record_control() { CTL_FIRED="${CTL_FIRED} $1"; }

assert_control_fired() { # <cause> <control-id>
  case " $CTL_FIRED " in
    *" $2 "*) _pass "positive control fired for ${1}" ;;
    *) _fail "positive control fired for ${1}" "control '$2' was never recorded" \
        "  a negative probe without a firing control proves nothing" ;;
  esac
}

mw_fixture() { # <task-id> <status>
  cat > "$NZ/tasks/${1}.md" <<FIXTURE_EOF
---
status: ${2}
---
# ${1}: fixture manifest

## Metadata
- **ID**: ${1}
- **Base SHA**: 3b0b859d6d3fbf35be58e67acd22f3cbf97f3f7c

## Commits
- 0123456789abcdef0123456789abcdef01234567

## Red-Run Evidence
FIXTURE_EOF
}

# Bounded runner: a reentrancy or lock regression is a deadlock, and a deadlock in a
# suite is a 16-minute hang. Usage: run_bounded <seconds> <command…>
run_bounded() {
  local secs="$1" pid waited=0
  shift
  "$@" > "$SCRATCH/bounded.out" 2> "$SCRATCH/bounded.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$((secs * 10))" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
}

bounded_err() { cat "$SCRATCH/bounded.err" 2>/dev/null || true; }

p_append() { cat "$1"; printf -- '- appended-by-producer\n'; }
p_record_arg() { printf '%s' "$1" > "$SCRATCH/producer-arg"; cp "$1" "$SCRATCH/producer-saw"; cat "$1"; }
p_fail() { cat "$1"; return 1; }
p_empty() { return 0; }
p_corrupt_status() { sed 's/^status: .*/status: NOT_A_REAL_STATUS/' "$1"; }
p_concurrent() {
  printf -- '- concurrent-writer-line\n' >> "$RACE_TARGET"
  cat "$1"
  printf -- '- appended-by-producer\n'
}

v_always_ok() { [ -s "$1" ]; }
v_always_reject() { printf 'v_always_reject: rejecting %s\n' "$1" >&2; return 1; }

echo "-- step 1-7: the happy path, and the producer's argument"
mw_fixture TASK-001 IN_PROGRESS
M1="$NZ/tasks/TASK-001.md"
chmod 600 "$M1"
record_file_digest D1_BEFORE "$M1" "TASK-001 pre-write"
nz_manifest_write "$NZ" TASK-001 -- p_record_arg
assert_exit_code "happy path: nz_manifest_write returns 0" "$?" 0
record_control happy-path
PRODUCER_ARG=$(cat "$SCRATCH/producer-arg")
if [ "$PRODUCER_ARG" != "$M1" ]; then
  _pass "producer is handed the snapshot, not the live manifest"
else
  _fail "producer is handed the snapshot, not the live manifest" \
    "producer received the live path: $PRODUCER_ARG"
fi
assert_eq "the snapshot handed over is colocated with the manifest" \
  "$(dirname "$PRODUCER_ARG")" "$(cd "$(dirname "$M1")" && pwd -P)"
assert_contains "the snapshot carries an unpredictable mktemp suffix" \
  "$(basename "$PRODUCER_ARG")" ".TASK-001.snapshot."
record_file_digest D1_SNAP "$SCRATCH/producer-saw" "snapshot the producer read"
assert_eq "the snapshot is byte-identical to the pre-write manifest" "$D1_SNAP" "$D1_BEFORE"
assert_eq "mode is preserved across the install" "$(nz_file_mode "$M1")" "600"
RESIDUE=$(find "$NZ/tasks" -name '.TASK-001.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no staging residue after a successful write" "$RESIDUE" "0"

nz_manifest_write "$NZ" TASK-001 -- p_append
assert_exit_code "happy path: a second write returns 0" "$?" 0
assert_file_contains "the producer's output is installed" "$M1" '^- appended-by-producer$'
assert_eq "status survives an unrelated write" "$(get_task_status "$M1" "")" "IN_PROGRESS"

echo "-- lock path: one spelling, shared with the status writer"
MW_LOCK=$(nz_manifest_lock_path "$NZ" TASK-001)
TTG_LOCK=$(bash -c 'source "$1"; _ttg_runtime_dir_path "$2" locks true' _ \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" "$NZ")/task-transition-TASK-001.lock
assert_eq "nz_manifest_lock_path resolves the status writer's own lock path" "$MW_LOCK" "$TTG_LOCK"
assert_eq "the lock lives under the canonical locks/ directory" \
  "$(dirname "$MW_LOCK")" "$(cd "$NZ/locks" && pwd -P)"

echo "-- producer non-zero"
mw_fixture TASK-002 IN_PROGRESS
M2="$NZ/tasks/TASK-002.md"
nz_manifest_write "$NZ" TASK-002 -- p_append
if [ "$?" -eq 0 ] && grep -q '^- appended-by-producer$' "$M2"; then
  record_control producer-succeeds
  _pass "control: the same producer shape installs when it returns 0"
else
  _fail "control: the same producer shape installs when it returns 0" "expected rc 0 and the appended line"
fi
mw_fixture TASK-002 IN_PROGRESS
record_file_digest D2_BEFORE "$M2" "TASK-002 pre-write"
ERR2=$(nz_manifest_write "$NZ" TASK-002 -- p_fail 2>&1 >/dev/null); RC2=$?
assert_exit_code "producer non-zero: refused" "$RC2" 1
assert_contains "producer non-zero: named cause" "$ERR2" "(cause: producer_failed)"
record_file_digest D2_AFTER "$M2" "TASK-002 post-refusal"
assert_eq "producer non-zero: manifest byte-identical" "$D2_AFTER" "$D2_BEFORE"
record_failure_path producer_failed
assert_control_fired producer_failed producer-succeeds

echo "-- producer empty output"
mw_fixture TASK-003 IN_PROGRESS
M3="$NZ/tasks/TASK-003.md"
record_file_digest D3_BEFORE "$M3" "TASK-003 pre-write"
ERR3=$(nz_manifest_write "$NZ" TASK-003 -- p_empty 2>&1 >/dev/null); RC3=$?
assert_exit_code "producer empty: refused" "$RC3" 1
assert_contains "producer empty: named cause" "$ERR3" "(cause: producer_empty)"
record_file_digest D3_AFTER "$M3" "TASK-003 post-refusal"
assert_eq "producer empty: manifest byte-identical" "$D3_AFTER" "$D3_BEFORE"
RESIDUE3=$(find "$NZ/tasks" -name '.TASK-003.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "producer empty: no staging residue" "$RESIDUE3" "0"
record_failure_path producer_empty
assert_control_fired producer_empty producer-succeeds

echo "-- verify predicate"
mw_fixture TASK-004 IN_PROGRESS
M4="$NZ/tasks/TASK-004.md"
nz_manifest_write "$NZ" TASK-004 --verify v_always_ok -- p_append
if [ "$?" -eq 0 ] && grep -q '^- appended-by-producer$' "$M4"; then
  record_control verify-accepts
  _pass "control: an accepting --verify predicate lets the write report success"
else
  _fail "control: an accepting --verify predicate lets the write report success" "expected rc 0"
fi
mw_fixture TASK-004 IN_PROGRESS
ERR4=$(nz_manifest_write "$NZ" TASK-004 --verify v_always_reject -- p_append 2>&1 >/dev/null); RC4=$?
assert_exit_code "verify failure: loud non-zero, never a warning" "$RC4" 1
assert_contains "verify failure: named cause" "$ERR4" "(cause: verify_failed)"
assert_contains "verify failure: names the predicate that rejected" "$ERR4" "v_always_reject"
record_failure_path verify_failed
assert_control_fired verify_failed verify-accepts

mw_fixture TASK-005 IN_PROGRESS
M5="$NZ/tasks/TASK-005.md"
ERR5=$(nz_manifest_write "$NZ" TASK-005 -- p_corrupt_status 2>&1 >/dev/null); RC5=$?
assert_exit_code "default verify: a status-destroying producer is caught" "$RC5" 1
assert_contains "default verify: named cause" "$ERR5" "(cause: verify_failed)"
assert_contains "default verify: reports what the installed bytes parse to" "$ERR5" "not a valid status"

mw_fixture TASK-006 IN_PROGRESS
M6="$NZ/tasks/TASK-006.md"
record_file_digest D6_BEFORE "$M6" "TASK-006 pre-write"
ERR6=$(nz_manifest_write "$NZ" TASK-006 --verify 'rm -rf /' -- p_append 2>&1 >/dev/null); RC6=$?
assert_exit_code "--verify names a shell function, never a command string" "$RC6" 1
assert_contains "--verify: named cause" "$ERR6" "(cause: verify_not_a_function)"
record_file_digest D6_AFTER "$M6" "TASK-006 post-refusal"
assert_eq "--verify refusal: manifest byte-identical" "$D6_AFTER" "$D6_BEFORE"

echo "-- symlink destination"
mw_fixture TASK-007 IN_PROGRESS
if [ "$?" -eq 0 ] && [ -f "$NZ/tasks/TASK-007.md" ]; then
  nz_manifest_write "$NZ" TASK-007 -- p_append
  if [ "$?" -eq 0 ]; then
    record_control regular-destination
    _pass "control: a regular non-symlink destination at the same path writes"
  else
    _fail "control: a regular non-symlink destination at the same path writes" "expected rc 0"
  fi
fi
rm -f "$NZ/tasks/TASK-007.md"
printf 'decoy payload\n' > "$SCRATCH/decoy.md"
ln -s "$SCRATCH/decoy.md" "$NZ/tasks/TASK-007.md"
record_file_digest D7_BEFORE "$SCRATCH/decoy.md" "symlink target pre-write"
ERR7=$(nz_manifest_write "$NZ" TASK-007 -- p_append 2>&1 >/dev/null); RC7=$?
assert_exit_code "symlink destination: refused" "$RC7" 1
assert_contains "symlink destination: named cause" "$ERR7" "(cause: symlink_destination)"
record_file_digest D7_AFTER "$SCRATCH/decoy.md" "symlink target post-refusal"
assert_eq "symlink destination: the target is untouched" "$D7_AFTER" "$D7_BEFORE"
rm -f "$NZ/tasks/TASK-007.md"
record_failure_path symlink_destination
assert_control_fired symlink_destination regular-destination

echo "-- nz_file_mode refusal (#204: refuse, never default to 0644)"
mw_fixture TASK-008 IN_PROGRESS
M8="$NZ/tasks/TASK-008.md"
chmod 600 "$M8"
nz_manifest_write "$NZ" TASK-008 -- p_append
if [ "$?" -eq 0 ] && [ "$(nz_file_mode "$M8")" = "600" ]; then
  record_control real-file-mode
  _pass "control: with a working stat dialect the same write succeeds and keeps 600"
else
  _fail "control: with a working stat dialect the same write succeeds and keeps 600" "expected rc 0 and mode 600"
fi
mw_fixture TASK-008 IN_PROGRESS
chmod 600 "$M8"
record_file_digest D8_BEFORE "$M8" "TASK-008 pre-write"
: > "$SCRATCH/mode-shadow-calls"
nz_file_mode() { printf 'x' >> "$SCRATCH/mode-shadow-calls"; return 1; }
ERR8=$(nz_manifest_write "$NZ" TASK-008 -- p_append 2>&1 >/dev/null); RC8=$?
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/task-utils.sh"
assert_exit_code "unreadable mode: refused" "$RC8" 1
assert_contains "unreadable mode: named cause" "$ERR8" "(cause: mode_unreadable)"
if [ -s "$SCRATCH/mode-shadow-calls" ]; then
  _pass "unreadable mode: the shadow provably ran, so the refusal is the one under test"
else
  _fail "unreadable mode: the shadow provably ran, so the refusal is the one under test" \
    "the shadowed nz_file_mode was never called"
fi
record_file_digest D8_AFTER "$M8" "TASK-008 post-refusal"
assert_eq "unreadable mode: manifest byte-identical" "$D8_AFTER" "$D8_BEFORE"
assert_eq "unreadable mode: mode is not silently re-moded" "$(nz_file_mode "$M8")" "600"
record_failure_path mode_unreadable
assert_control_fired mode_unreadable real-file-mode

echo "-- CAS mismatch at step 3 (a racer lands between the snapshot and its validation)"
mw_fixture TASK-009 IN_PROGRESS
M9="$NZ/tasks/TASK-009.md"
RACE_TARGET="$M9"
: > "$SCRATCH/cp-shadow-calls"
CP_SHADOW_RACE=0
cp() {
  command cp "$@"
  printf 'x' >> "$SCRATCH/cp-shadow-calls"
  if [ "$CP_SHADOW_RACE" = "1" ]; then
    printf -- '- raced-after-snapshot\n' >> "$RACE_TARGET"
  fi
  return 0
}
export CP_SHADOW_RACE RACE_TARGET
nz_manifest_write "$NZ" TASK-009 -- p_append
RC9_CTL=$?
if [ "$RC9_CTL" -eq 0 ] && [ -s "$SCRATCH/cp-shadow-calls" ]; then
  record_control cp-shadow-live
  _pass "control: the cp shadow is installed and the un-raced write still succeeds"
else
  _fail "control: the cp shadow is installed and the un-raced write still succeeds" \
    "rc=$RC9_CTL, shadow calls=$(wc -c < "$SCRATCH/cp-shadow-calls" | tr -d ' ')"
fi
mw_fixture TASK-009 IN_PROGRESS
CP_SHADOW_RACE=1
ERR9=$(nz_manifest_write "$NZ" TASK-009 -- p_append 2>&1 >/dev/null); RC9=$?
CP_SHADOW_RACE=0
unset -f cp
assert_exit_code "step-3 CAS mismatch: refused" "$RC9" 1
assert_contains "step-3 CAS mismatch: named cause" "$ERR9" "(cause: cas_mismatch_snapshot)"
assert_contains "step-3 CAS mismatch: says the concurrent content was preserved" "$ERR9" "concurrent content preserved"
assert_file_contains "step-3 CAS mismatch: the racer's line survives" "$M9" '^- raced-after-snapshot$'
assert_file_not_contains "step-3 CAS mismatch: the losing producer's output is not installed" \
  "$M9" '^- appended-by-producer$'
record_failure_path cas_mismatch_snapshot
assert_control_fired cas_mismatch_snapshot cp-shadow-live

echo "-- CAS mismatch at step 5 (#226 mode 1: a lost update, refused instead of taken)"
mw_fixture TASK-010 IN_PROGRESS
M10="$NZ/tasks/TASK-010.md"
RACE_TARGET="$SCRATCH/unrelated-target"
: > "$RACE_TARGET"
nz_manifest_write "$NZ" TASK-010 -- p_concurrent
RC10_CTL=$?
if [ "$RC10_CTL" -eq 0 ] && [ -s "$RACE_TARGET" ]; then
  record_control concurrent-producer-live
  _pass "control: the same producer installs when its concurrent write misses the manifest"
else
  _fail "control: the same producer installs when its concurrent write misses the manifest" \
    "rc=$RC10_CTL"
fi
mw_fixture TASK-010 IN_PROGRESS
RACE_TARGET="$M10"
ERR10=$(nz_manifest_write "$NZ" TASK-010 -- p_concurrent 2>&1 >/dev/null); RC10=$?
assert_exit_code "step-5 CAS mismatch: refused" "$RC10" 1
assert_contains "step-5 CAS mismatch: named cause" "$ERR10" "(cause: cas_mismatch_install)"
assert_file_contains "step-5 CAS mismatch: the concurrent writer's line survives" \
  "$M10" '^- concurrent-writer-line$'
assert_file_not_contains "step-5 CAS mismatch: the losing producer's output is not installed" \
  "$M10" '^- appended-by-producer$'
assert_eq "step-5 CAS mismatch: status survives" "$(get_task_status "$M10" "")" "IN_PROGRESS"
record_failure_path cas_mismatch_install
assert_control_fired cas_mismatch_install concurrent-producer-live

echo "-- the lock: not acquired, and the inner/outer split that keeps it that way"
mw_fixture TASK-011 IN_PROGRESS
M11="$NZ/tasks/TASK-011.md"
LOCK11=$(nz_manifest_lock_path "$NZ" TASK-011)
run_bounded 10 nz_manifest_write "$NZ" TASK-011 -- p_append
RC11_CTL=$?
if [ "$RC11_CTL" -eq 0 ] && grep -q '^- appended-by-producer$' "$M11"; then
  record_control lock-free-write
  _pass "control: with the lock free the identical call succeeds inside the bound"
else
  _fail "control: with the lock free the identical call succeeds inside the bound" "rc=$RC11_CTL"
fi
mw_fixture TASK-011 IN_PROGRESS
record_file_digest D11_BEFORE "$M11" "TASK-011 pre-write"
if _nz_acquire_lock "$LOCK11" 1; then
  HELD_TOKEN="$NZ_LOCK_TOKEN"
  run_bounded 10 nz_manifest_write "$NZ" TASK-011 -- p_append
  RC11=$?
  ERR11=$(bounded_err)
  assert_exit_code "lock held: the outer form fails fast rather than hanging" "$RC11" 1
  assert_contains "lock held: named cause" "$ERR11" "(cause: lock_unavailable)"
  assert_contains "lock held: the diagnostic the status writer already used" \
    "$ERR11" "another transition already holds the TASK-011 lock"
  record_file_digest D11_AFTER "$M11" "TASK-011 post-refusal"
  assert_eq "lock held: manifest byte-identical" "$D11_AFTER" "$D11_BEFORE"

  run_bounded 10 nz_manifest_write_locked "$NZ" TASK-011 -- p_append
  RC11_INNER=$?
  assert_exit_code "lock held: the INNER form writes, because the caller holds the lock" "$RC11_INNER" 0
  assert_file_contains "lock held: the inner form's output is installed" "$M11" '^- appended-by-producer$'

  _nz_release_lock "$LOCK11" "$HELD_TOKEN"
  assert_dir_not_exists "the lock directory is released" "$LOCK11"
else
  _fail "lock held: could not acquire the lock to set up the probe" "_nz_acquire_lock returned non-zero"
fi
record_failure_path lock_unavailable
assert_control_fired lock_unavailable lock-free-write

echo "-- nz_manifest_with_lock: several writes in one critical section"
mw_fixture TASK-012 IN_PROGRESS
M12="$NZ/tasks/TASK-012.md"
LOCK12=$(nz_manifest_lock_path "$NZ" TASK-012)
two_writes_under_one_lock() {
  nz_manifest_write_locked "$NZ" TASK-012 -- p_append || return 1
  nz_manifest_write_locked "$NZ" TASK-012 -- p_record_arg || return 1
  nz_manifest_write "$NZ" TASK-012 -- p_append && return 1
  return 0
}
run_bounded 20 nz_manifest_with_lock "$NZ" TASK-012 two_writes_under_one_lock
RC12=$?
assert_exit_code "nz_manifest_with_lock: two inner writes succeed, the outer one is refused" "$RC12" 0
assert_file_contains "nz_manifest_with_lock: the inner writes landed" "$M12" '^- appended-by-producer$'
assert_dir_not_exists "nz_manifest_with_lock: the lock is released on the way out" "$LOCK12"

echo "-- argument and target refusals"
ERR_A=$(nz_manifest_write "$NZ" TASK-999 -- p_append 2>&1 >/dev/null); RC_A=$?
assert_exit_code "absent manifest: refused" "$RC_A" 1
assert_contains "absent manifest: named cause" "$ERR_A" "(cause: no_manifest)"
ERR_B=$(nz_manifest_write "$NZ" NOT-A-TASK -- p_append 2>&1 >/dev/null); RC_B=$?
assert_exit_code "malformed task id: refused" "$RC_B" 1
assert_contains "malformed task id: named cause" "$ERR_B" "(cause: bad_arguments)"
ERR_C=$(nz_manifest_write_locked "$NZ" TASK-001 p_append 2>&1 >/dev/null); RC_C=$?
assert_exit_code "producer without the -- separator: refused" "$RC_C" 1
assert_contains "missing separator: named cause" "$ERR_C" "(cause: bad_arguments)"
ERR_D=$(nz_manifest_write_locked "$NZ" TASK-001 -- 2>&1 >/dev/null); RC_D=$?
assert_exit_code "no producer at all: refused" "$RC_D" 1
assert_contains "empty producer: named cause" "$ERR_D" "(cause: bad_arguments)"

echo "-- failure-path coverage"
MW_N=0; MW_M=0; MW_K=0; MW_F=0
UNEXERCISED=""
for cause in $FAILURE_PATHS; do
  MW_N=$((MW_N + 1))
  case " $FP_SEEN " in
    *" $cause "*) MW_K=$((MW_K + 1)) ;;
    *) MW_M=$((MW_M + 1)); MW_F=$((MW_F + 1)); UNEXERCISED="${UNEXERCISED} ${cause}" ;;
  esac
done
printf '  manifest-write-failure-paths: %d scanned, %d skipped (unexercised=%d), %d checked, %d findings\n' \
  "$MW_N" "$MW_M" "$MW_M" "$MW_K" "$MW_F"
assert_eq "failure paths: scanned == skipped + checked" "$MW_N" "$((MW_M + MW_K))"
assert_eq "failure paths: every named path was driven" "${UNEXERCISED:-none}" "none"
if [ "$MW_K" -gt 0 ]; then
  _pass "failure paths: K > 0, so the population was not vacuously clean"
else
  _fail "failure paths: K > 0, so the population was not vacuously clean" "nothing was checked"
fi

echo "-- the tree holds exactly one lock implementation"
LOCK_IMPLS=$(grep -l 'mkdir "\$lock"' "$REPO_ROOT"/scripts/lib/*.sh 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one mkdir-lock implementation under scripts/lib" "$LOCK_IMPLS" "1"
assert_file_contains "the surviving implementation is the shared primitive" \
  "$REPO_ROOT/scripts/lib/manifest-write.sh" 'mkdir "\$lock"'
assert_file_contains "task-transition-guard.sh keeps _ttg_acquire_lock as an alias" \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" '^_ttg_acquire_lock() { _nz_acquire_lock'
assert_file_contains "task-transition-guard.sh keeps _ttg_release_lock as an alias" \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" '^_ttg_release_lock() { _nz_release_lock'

echo "-- the alias still publishes the token its callers read"
mw_fixture TASK-013 IN_PROGRESS
ALIAS_LOCK=$(nz_manifest_lock_path "$NZ" TASK-013)
ALIAS_OUT=$(bash -c '
  source "$1"
  _ttg_acquire_lock "$2" 1 || { echo "ACQUIRE-FAILED"; exit 1; }
  printf "%s\n" "$TTG_LOCK_TOKEN"
  _ttg_release_lock "$2" "$TTG_LOCK_TOKEN" || { echo "RELEASE-FAILED"; exit 1; }
  [ -d "$2" ] && echo "STILL-LOCKED"
  exit 0
' _ "$REPO_ROOT/scripts/lib/task-transition-guard.sh" "$ALIAS_LOCK" 2>&1)
ALIAS_TOKEN=$(printf '%s\n' "$ALIAS_OUT" | awk 'NR==1')
if [[ "$ALIAS_TOKEN" =~ ^[0-9a-f]+$ ]]; then
  _pass "_ttg_acquire_lock alias publishes a hex TTG_LOCK_TOKEN"
else
  _fail "_ttg_acquire_lock alias publishes a hex TTG_LOCK_TOKEN" "got: '$ALIAS_OUT'"
fi
assert_not_contains "_ttg_release_lock alias releases the directory it took" "$ALIAS_OUT" "STILL-LOCKED"

teardown_temp_dir
report_results
