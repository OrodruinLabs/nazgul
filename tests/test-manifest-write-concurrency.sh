#!/usr/bin/env bash
set -uo pipefail

# Test: the three concurrency properties of scripts/lib/manifest-write.sh
# (FEAT-036 / ADR-031) — an interrupted write leaves the manifest intact (AC-7),
# two writers serialize on ONE lock (AC-8), and the inner/outer reentrancy split
# cannot regress into a deadlock. Every case drives the primitive directly against
# fixture manifests; none invokes tests/run-tests.sh or any project test command.
#
# Determinism: no case races a timer. The interruption is landed through a marker
# file plus a FIFO the producer itself blocks on, and the two-writer overlap is
# pinned by a gate-file handshake, so the ordering is decided by the code under
# test rather than by wall clock. The seeded delay varies timing WITHIN that
# pinned ordering so a flake would be a finding rather than noise.
TEST_NAME="test-manifest-write-concurrency"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

MWC_STARTED_AT=$(date +%s)

# The real consumer's reader, sourced independently of the primitive so "still parses"
# stays checkable in a tree where the primitive does not exist yet.
# shellcheck source=../scripts/lib/task-utils.sh
source "$REPO_ROOT/scripts/lib/task-utils.sh"

LIB="$REPO_ROOT/scripts/lib/manifest-write.sh"
PRIMITIVE_PRESENT=0
if [ -f "$LIB" ]; then
  # shellcheck source=/dev/null
  source "$LIB" && PRIMITIVE_PRESENT=1
fi

setup_temp_dir
setup_nazgul_dir
NZ="$TEST_DIR/nazgul"
SCRATCH="$TEST_DIR/scratch"
BIN="$TEST_DIR/writers"
mkdir -p "$SCRATCH" "$BIN"

MWC_REPEAT=20
MWC_SEED=20260826
CTL_FIRED=""

record_control() { CTL_FIRED="${CTL_FIRED} $1"; }

assert_control_fired() { # <what-it-controls> <control-id>
  case " $CTL_FIRED " in
    *" $2 "*) _pass "positive control fired for ${1}" ;;
    *) _fail "positive control fired for ${1}" "control '$2' was never recorded" \
        "  a probe whose control cannot fire proves nothing" ;;
  esac
}

mwc_fixture() { # <task-id> <status>
  cat > "$NZ/tasks/${1}.md" <<FIXTURE_EOF
---
status: ${2}
---
# ${1}: concurrency fixture manifest

## Metadata
- **ID**: ${1}
- **Base SHA**: 3b0b859d6d3fbf35be58e67acd22f3cbf97f3f7c

## Commits
- 0123456789abcdef0123456789abcdef01234567

## Red-Run Evidence
FIXTURE_EOF
}

# Bounded poll for a path. Returns 1 on expiry so a caller reports a timeout
# instead of blocking. Usage: wait_for_path <path> <deciseconds>
wait_for_path() {
  local path="$1" limit="$2" n=0
  while [ ! -e "$path" ]; do
    [ "$n" -ge "$limit" ] && return 1
    sleep 0.1
    n=$((n + 1))
  done
  return 0
}

# The bound IS the assertion: a reentrancy or lock regression is a deadlock, and an
# unbounded deadlock in this suite is a 16-minute hang. Returns 124 on expiry.
run_bounded() { # <seconds> <command…>
  local secs="$1" pid pgid waited=0
  shift
  set -m
  "$@" > "$SCRATCH/bounded.out" 2> "$SCRATCH/bounded.err" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$((secs * 20))" ]; then
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -n "$pgid" ] && [ "$pgid" != "$MWC_OWN_PGID" ]; then
        kill -9 -- -"$pgid" 2>/dev/null || true
      fi
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  wait "$pid"
}

bounded_err() { cat "$SCRATCH/bounded.err" 2>/dev/null || true; }

MWC_OWN_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')

# Reproducible interleaving offsets from a fixed seed, so the repeat below is
# bounded and re-runnable rather than a fresh dice roll each time.
seeded_delay() { # <iteration> -> seconds
  local slot
  slot=$(( (MWC_SEED + $1 * 1103515245 + 12345) % 4 ))
  printf '0.0%02d\n' "$((slot * 5))"
}

# kill -9 the writer's process group, or the marker's two pids when job control gave it none.
# Reaps in the CALLER's shell: a $( ) capture reaps in a subshell, so bash prints "Killed: 9" later.
MWC_KILL_ROUTE=""
kill_writer() { # <writer-pid> <marker-path>
  local pid="$1" marker="$2" pgid owner producer
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ] && [ "$pgid" != "$MWC_OWN_PGID" ]; then
    kill -9 -- -"$pgid" 2>/dev/null || true
    MWC_KILL_ROUTE="process-group"
  else
    owner=$(awk 'NR==1{print $1}' "$marker" 2>/dev/null); owner="${owner#owner=}"
    producer=$(awk 'NR==1{print $2}' "$marker" 2>/dev/null); producer="${producer#producer=}"
    [ -n "$producer" ] && kill -9 "$producer" 2>/dev/null
    [ -n "$owner" ] && kill -9 "$owner" 2>/dev/null
    kill -9 "$pid" 2>/dev/null || true
    MWC_KILL_ROUTE="individual-pids"
  fi
  wait "$pid" 2>/dev/null
  return 0
}

residue_count() { find "$NZ/tasks" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

cat > "$BIN/c1-primitive.sh" <<'C1P_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB="$1"; NZ="$2"; TASK="$3"; MARK="$4"; FIFO="$5"
# shellcheck source=/dev/null
source "$LIB"
gate_producer() {
  printf 'owner=%s producer=%s\n' "$$" "$BASHPID" > "$MARK"
  IFS= read -r _gate < "$FIFO" || true
  cat "$1"
  printf -- '- installed-by-the-interrupted-write\n'
}
nz_manifest_write "$NZ" "$TASK" -- gate_producer
C1P_EOF

# The pre-change rr_write_block shape (scripts/red-run.sh:968 at 3b0b859) under the same gate at
# the same instant as the primitive arm: the one difference is that the redirect points AT the manifest.
cat > "$BIN/c1-legacy.sh" <<'C1L_EOF'
#!/usr/bin/env bash
set -uo pipefail
MANIFEST="$1"; MARK="$2"; FIFO="$3"
out=""; line=""
while IFS= read -r line || [ -n "$line" ]; do
  out="${out}${line}
"
done < "$MANIFEST"
out="${out}- installed-by-the-pre-change-shape
"
{
  printf 'owner=%s producer=%s\n' "$$" "$BASHPID" > "$MARK"
  IFS= read -r _gate < "$FIFO" || true
  printf '%s' "$out"
} > "$MANIFEST"
C1L_EOF

cat > "$BIN/c2-status.sh" <<'C2A_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB="$1"; NZ="$2"; TASK="$3"; A_INSIDE="$4"; B_ARRIVED="$5"
# shellcheck source=/dev/null
source "$LIB"
p_status() {
  : > "$A_INSIDE"
  n=0
  while [ ! -e "$B_ARRIVED" ] && [ "$n" -lt 400 ]; do sleep 0.01; n=$((n + 1)); done
  sed 's/^status: IN_PROGRESS$/status: IMPLEMENTED/' "$1"
}
nz_manifest_write "$NZ" "$TASK" -- p_status
C2A_EOF

cat > "$BIN/c2-evidence.sh" <<'C2B_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB="$1"; NZ="$2"; TASK="$3"; A_INSIDE="$4"; B_ARRIVED="$5"; TOKEN="$6"; DELAY="$7"; TRIES="${8:-60}"
# shellcheck source=/dev/null
source "$LIB"
p_evidence() {
  awk -v tok="$TOKEN" '{print} /^## Red-Run Evidence$/ && !d {print "- red-run: " tok; d=1}' "$1"
}
n=0
while [ ! -e "$A_INSIDE" ] && [ "$n" -lt 400 ]; do sleep 0.01; n=$((n + 1)); done
sleep "$DELAY"
: > "$B_ARRIVED"
rc=1; try=0
while [ "$try" -lt "$TRIES" ]; do
  nz_manifest_write "$NZ" "$TASK" -- p_evidence
  rc=$?
  [ "$rc" -eq 0 ] && break
  try=$((try + 1))
  sleep 0.01
done
exit "$rc"
C2B_EOF

cat > "$BIN/c2-status-unlocked.sh" <<'C2AU_EOF'
#!/usr/bin/env bash
set -uo pipefail
MANIFEST="$1"; A_READ="$2"; B_READ="$3"; A_WROTE="$4"
out=""; line=""
while IFS= read -r line || [ -n "$line" ]; do
  out="${out}${line}
"
done < "$MANIFEST"
out=$(printf '%s' "$out" | sed 's/^status: IN_PROGRESS$/status: IMPLEMENTED/')
: > "$A_READ"
n=0
while [ ! -e "$B_READ" ] && [ "$n" -lt 400 ]; do sleep 0.01; n=$((n + 1)); done
printf '%s\n' "$out" > "$MANIFEST"
: > "$A_WROTE"
C2AU_EOF

cat > "$BIN/c2-evidence-unlocked.sh" <<'C2BU_EOF'
#!/usr/bin/env bash
set -uo pipefail
MANIFEST="$1"; A_READ="$2"; B_READ="$3"; A_WROTE="$4"; TOKEN="$5"; DELAY="$6"
n=0
while [ ! -e "$A_READ" ] && [ "$n" -lt 400 ]; do sleep 0.01; n=$((n + 1)); done
sleep "$DELAY"
out=$(awk -v tok="$TOKEN" '{print} /^## Red-Run Evidence$/ && !d {print "- red-run: " tok; d=1}' "$MANIFEST")
: > "$B_READ"
n=0
while [ ! -e "$A_WROTE" ] && [ "$n" -lt 400 ]; do sleep 0.01; n=$((n + 1)); done
printf '%s\n' "$out" > "$MANIFEST"
C2BU_EOF

chmod +x "$BIN"/*.sh

if [ "$PRIMITIVE_PRESENT" -ne 1 ]; then
  _fail "the primitive under test exists in this tree" \
    "scripts/lib/manifest-write.sh is absent or unsourceable: $LIB" \
    "  Cases 1-3 assert on nz_manifest_write / nz_manifest_lock_path and cannot run here" \
    "  the pre-change positive controls below still run: they are what shows the defect is real"
fi

echo "-- case 1: an interrupted write leaves the manifest intact (AC-7)"
C1_TASK=TASK-001
mwc_fixture "$C1_TASK" IN_PROGRESS
C1_M="$NZ/tasks/$C1_TASK.md"
record_file_digest C1_BEFORE "$C1_M" "$C1_TASK pre-write"
C1_MARK="$SCRATCH/c1.marker"
C1_FIFO="$SCRATCH/c1.fifo"
rm -f "$C1_MARK" "$C1_FIFO"
mkfifo "$C1_FIFO"

if [ "$PRIMITIVE_PRESENT" -eq 1 ]; then
  set -m
  bash "$BIN/c1-primitive.sh" "$LIB" "$NZ" "$C1_TASK" "$C1_MARK" "$C1_FIFO" \
    > "$SCRATCH/c1.out" 2> "$SCRATCH/c1.err" &
  C1_PID=$!
  set +m
  if wait_for_path "$C1_MARK" 100; then
    _pass "case 1: the producer signalled from inside the write window"
    kill_writer "$C1_PID" "$C1_MARK"
    rm -f "$C1_FIFO"
    printf '  case 1: interruption delivered by %s\n' "$MWC_KILL_ROUTE"

    assert_file_exists "case 1: the manifest still exists" "$C1_M"
    if [ -s "$C1_M" ]; then
      _pass "case 1: the manifest is non-empty"
    else
      _fail "case 1: the manifest is non-empty" "the interrupted write truncated $C1_M"
    fi
    assert_file_unchanged "case 1: the manifest is byte-identical to the pre-write bytes" \
      "$C1_M" "$C1_BEFORE"
    assert_eq "case 1: get_task_status returns the PRIOR status" \
      "$(get_task_status "$C1_M" "")" "IN_PROGRESS"
    assert_file_contains "case 1: ## Commits survives" "$C1_M" '^## Commits$'
    assert_file_contains "case 1: ## Metadata survives" "$C1_M" '^## Metadata$'
    assert_file_not_contains "case 1: the interrupted producer's output was never installed" \
      "$C1_M" '^- installed-by-the-interrupted-write$'

    assert_eq "case 1: no .nz-rewrite.* residue in tasks/" "$(residue_count '.nz-rewrite.*')" "0"
    assert_eq "case 1: no .${C1_TASK}.transition.* residue in tasks/" \
      "$(residue_count ".${C1_TASK}.transition.*")" "0"
    # Accepted boundary, reported not asserted away: a kill -9ed writer cannot run its cleanup,
    # so colocated snapshot/stage dot-files survive under mktemp names no later writer collides with.
    C1_ORPHANS=$(find "$NZ/tasks" -name ".${C1_TASK}.*" 2>/dev/null | LC_ALL=C sort)
    C1_ORPHAN_N=$(printf '%s' "$C1_ORPHANS" | grep -c . || true)
    printf '  case 1: accepted boundary — %s colocated mktemp dot-file(s) left by kill -9: %s\n' \
      "$C1_ORPHAN_N" "$(printf '%s' "$C1_ORPHANS" | tr '\n' ' ')"
    C1_NONDOT=$(find "$NZ/tasks" -type f ! -name '.*' ! -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "case 1: every residue file is a colocated dot-file, never a visible sibling" \
      "$C1_NONDOT" "0"

    C1_LOCK=$(nz_manifest_lock_path "$NZ" "$C1_TASK")
    assert_dir_exists "case 1: the killed writer's lock directory survives, as expected" "$C1_LOCK"
    run_bounded 15 nz_manifest_write "$NZ" "$C1_TASK" -- cat
    C1_NEXT_RC=$?
    C1_NEXT_ERR=$(bounded_err)
    if [ "$C1_NEXT_RC" -eq 124 ]; then
      _fail "case 1: the next write terminates instead of hanging" \
        "nz_manifest_write did not return within 15s after a kill -9ed writer left the lock"
    else
      _pass "case 1: the next write terminates instead of hanging"
    fi
    if [ "$C1_NEXT_RC" -eq 0 ]; then
      printf '  case 1: lock recovery arm taken — dead-owner reclaim (no grace wait needed)\n'
      _pass "case 1: the next write recovers the lock a kill -9ed writer left behind"
    elif [ "$C1_NEXT_RC" -eq 1 ] && [[ "$C1_NEXT_ERR" == *"another transition already holds"* ]]; then
      printf '  case 1: lock recovery arm taken — named refusal\n'
      _pass "case 1: the next write recovers the lock a kill -9ed writer left behind"
    else
      _fail "case 1: the next write recovers the lock a kill -9ed writer left behind" \
        "expected rc 0 (reclaim) or rc 1 with 'another transition already holds'" \
        "  rc=$C1_NEXT_RC err=${C1_NEXT_ERR:-<empty>}"
    fi
    if [ "$C1_NEXT_RC" -eq 0 ]; then
      assert_eq "case 1: the orphaned dot-files did not collide with the next writer's mktemp" \
        "$(get_task_status "$C1_M" "")" "IN_PROGRESS"
    fi
  else
    _fail "case 1: the producer signalled from inside the write window" \
      "no marker appeared at $C1_MARK within 10s" \
      "  stderr: $(cat "$SCRATCH/c1.err" 2>/dev/null)"
    kill -9 "$C1_PID" 2>/dev/null || true
    rm -f "$C1_FIFO"
  fi
else
  _skip "case 1: primitive arm — scripts/lib/manifest-write.sh absent"
  rm -f "$C1_FIFO"
fi

echo "-- case 1 positive control: the pre-change shape, interrupted at the same instant"
C1C_TASK=TASK-002
mwc_fixture "$C1C_TASK" IN_PROGRESS
C1C_M="$NZ/tasks/$C1C_TASK.md"
record_file_digest C1C_BEFORE "$C1C_M" "$C1C_TASK pre-write"
C1C_MARK="$SCRATCH/c1c.marker"
C1C_FIFO="$SCRATCH/c1c.fifo"
rm -f "$C1C_MARK" "$C1C_FIFO"
mkfifo "$C1C_FIFO"
set -m
bash "$BIN/c1-legacy.sh" "$C1C_M" "$C1C_MARK" "$C1C_FIFO" \
  > "$SCRATCH/c1c.out" 2> "$SCRATCH/c1c.err" &
C1C_PID=$!
set +m
if wait_for_path "$C1C_MARK" 100; then
  kill_writer "$C1C_PID" "$C1C_MARK"
  rm -f "$C1C_FIFO"
  C1C_SIZE=$(wc -c < "$C1C_M" | tr -d ' ')
  if [ "$C1C_SIZE" -eq 0 ]; then
    record_control legacy-truncates
    _pass "control: the pre-change redirect leaves the manifest TRUNCATED (0 bytes)"
  else
    _fail "control: the pre-change redirect leaves the manifest TRUNCATED (0 bytes)" \
      "size after interruption: $C1C_SIZE"
  fi
  C1C_AFTER=$(digest_file "$C1C_M" 2>/dev/null || true)
  if [ "$C1C_AFTER" != "$C1C_BEFORE" ]; then
    _pass "control: the pre-change shape does NOT preserve the prior bytes"
  else
    _fail "control: the pre-change shape does NOT preserve the prior bytes" \
      "the control did not fire — it cannot distinguish the two shapes"
  fi
  C1C_STATUS=$(get_task_status "$C1C_M" "UNREADABLE")
  assert_eq "control: the truncated manifest no longer parses to its prior status" \
    "$C1C_STATUS" "UNREADABLE"
else
  _fail "control: the pre-change producer signalled from inside its write window" \
    "no marker appeared at $C1C_MARK within 10s"
  kill -9 "$C1C_PID" 2>/dev/null || true
  rm -f "$C1C_FIFO"
fi
assert_control_fired "case 1's intact-manifest assertions" legacy-truncates

echo "-- case 1: the orphan grace is driven by ageing the lock, never by waiting 30s"
if [ "$PRIMITIVE_PRESENT" -eq 1 ]; then
  C1G_TASK=TASK-003
  mwc_fixture "$C1G_TASK" IN_PROGRESS
  C1G_LOCK=$(nz_manifest_lock_path "$NZ" "$C1G_TASK")
  rm -rf "$C1G_LOCK"
  if mkdir "$C1G_LOCK"; then
    run_bounded 15 nz_manifest_write "$NZ" "$C1G_TASK" -- cat
    C1G_RC=$?
    C1G_ERR=$(bounded_err)
    assert_exit_code "ownerless lock, un-aged: refused rather than hung" "$C1G_RC" 1
    assert_contains "ownerless lock, un-aged: the named diagnostic" \
      "$C1G_ERR" "another transition already holds the ${C1G_TASK} lock"
    touch -t 202001010000.00 "$C1G_LOCK"
    C1G_AGE=$(_nz_mtime_age_seconds "$C1G_LOCK" 2>/dev/null || true)
    if [ -n "$C1G_AGE" ] && [ "$C1G_AGE" -ge 30 ]; then
      _pass "the lock's mtime was aged past the 30s orphan grace (age=${C1G_AGE}s)"
      run_bounded 15 nz_manifest_write "$NZ" "$C1G_TASK" -- cat
      C1G_RC2=$?
      assert_exit_code "ownerless lock, aged past the grace: reclaimed and the write succeeds" \
        "$C1G_RC2" 0
      assert_eq "the reclaimed write leaves the manifest parseable" \
        "$(get_task_status "$NZ/tasks/$C1G_TASK.md" "")" "IN_PROGRESS"
    else
      _fail "the lock's mtime was aged past the 30s orphan grace" \
        "touch -t did not move the mtime; reported age: ${C1G_AGE:-<unreadable>}"
    fi
  else
    _fail "ownerless orphan lock could be constructed" "mkdir $C1G_LOCK failed"
  fi
else
  _skip "case 1 orphan-grace arm — scripts/lib/manifest-write.sh absent"
fi

echo "-- case 2: concurrent writers serialize on ONE lock (AC-8)"
C2_BOTH=0; C2_REFUSED=0; C2_LOST=0; C2_UNCLASSIFIED=0; C2_PARSES=0
if [ "$PRIMITIVE_PRESENT" -eq 1 ]; then
  C2_TASK=TASK-004
  C2_M="$NZ/tasks/$C2_TASK.md"
  C2_LOCK_A=""; C2_LOCK_B=""
  for i in $(seq 1 "$MWC_REPEAT"); do
    mwc_fixture "$C2_TASK" IN_PROGRESS
    A_INSIDE="$SCRATCH/c2-a-inside.$i"
    B_ARRIVED="$SCRATCH/c2-b-arrived.$i"
    rm -f "$A_INSIDE" "$B_ARRIVED"
    DELAY=$(seeded_delay "$i")
    TOKEN="iter-$i"
    bash "$BIN/c2-status.sh" "$LIB" "$NZ" "$C2_TASK" "$A_INSIDE" "$B_ARRIVED" \
      > /dev/null 2> "$SCRATCH/c2-a.err" &
    PA=$!
    bash "$BIN/c2-evidence.sh" "$LIB" "$NZ" "$C2_TASK" "$A_INSIDE" "$B_ARRIVED" "$TOKEN" "$DELAY" \
      > /dev/null 2> "$SCRATCH/c2-b.err" &
    PB=$!
    wait "$PA"; RA=$?
    wait "$PB"; RB=$?
    STATUS=$(get_task_status "$C2_M" "UNREADABLE")
    case "$STATUS" in IN_PROGRESS|IMPLEMENTED) C2_PARSES=$((C2_PARSES + 1)) ;; esac
    EFF_A=0; [ "$STATUS" = "IMPLEMENTED" ] && EFF_A=1
    EFF_B=0; grep -qF -- "- red-run: $TOKEN" "$C2_M" && EFF_B=1
    ERRS="$(cat "$SCRATCH/c2-a.err" 2>/dev/null)$(cat "$SCRATCH/c2-b.err" 2>/dev/null)"
    if [ "$RA" -eq 0 ] && [ "$RB" -eq 0 ]; then
      if [ "$EFF_A" -eq 1 ] && [ "$EFF_B" -eq 1 ]; then
        C2_BOTH=$((C2_BOTH + 1))
      else
        C2_LOST=$((C2_LOST + 1))
        printf '  case 2: LOST UPDATE at iteration %s (status=%s evidence=%s)\n' \
          "$i" "$EFF_A" "$EFF_B"
      fi
    elif { [ "$RA" -ne 0 ] && [ "$EFF_B" -eq 1 ]; } || { [ "$RB" -ne 0 ] && [ "$EFF_A" -eq 1 ]; }; then
      case "$ERRS" in
        *"cause: cas_mismatch"*|*"cause: lock_unavailable"*) C2_REFUSED=$((C2_REFUSED + 1)) ;;
        *) C2_UNCLASSIFIED=$((C2_UNCLASSIFIED + 1))
           printf '  case 2: loser returned non-zero WITHOUT a named cause at iteration %s: %s\n' \
             "$i" "$ERRS" ;;
      esac
    else
      C2_UNCLASSIFIED=$((C2_UNCLASSIFIED + 1))
      printf '  case 2: unclassified outcome at iteration %s (ra=%s rb=%s a=%s b=%s)\n' \
        "$i" "$RA" "$RB" "$EFF_A" "$EFF_B"
    fi
    rm -f "$A_INSIDE" "$B_ARRIVED"
  done
  printf '  case 2: %d iterations — both-effects=%d, loser-refused=%d, lost-updates=%d, unclassified=%d\n' \
    "$MWC_REPEAT" "$C2_BOTH" "$C2_REFUSED" "$C2_LOST" "$C2_UNCLASSIFIED"
  assert_eq "case 2: no lost update across the bounded repeat" "$C2_LOST" "0"
  assert_eq "case 2: every iteration landed in an allowed disposition" "$C2_UNCLASSIFIED" "0"
  assert_eq "case 2: the manifest parsed after every iteration" "$C2_PARSES" "$MWC_REPEAT"
  assert_eq "case 2: every iteration was accounted for" \
    "$((C2_BOTH + C2_REFUSED + C2_LOST + C2_UNCLASSIFIED))" "$MWC_REPEAT"
  if [ "$C2_BOTH" -gt 0 ]; then
    _pass "case 2: serialization is demonstrated, not merely unfalsified (both effects landed ${C2_BOTH}x)"
  else
    _fail "case 2: serialization is demonstrated, not merely unfalsified" \
      "no iteration produced both effects; the repeat proves only that writers refused each other"
  fi

  C2_LOCK_A=$(nz_manifest_lock_path "$NZ" "$C2_TASK")
  C2_LOCK_B=$(nz_manifest_lock_path "$NZ" "$C2_TASK")
  assert_eq "case 2: both writers resolve the SAME lock path" "$C2_LOCK_A" "$C2_LOCK_B"
  C2_LOCK_OTHER=$(nz_manifest_lock_path "$NZ" TASK-001)
  if [ "$C2_LOCK_A" != "$C2_LOCK_OTHER" ]; then
    _pass "case 2: the lock-path comparison can distinguish two tasks, so equality above is meaningful"
  else
    _fail "case 2: the lock-path comparison can distinguish two tasks" \
      "nz_manifest_lock_path returned the same path for two different task ids"
  fi

  echo "-- case 2: the other allowed disposition — the loser refuses, and nothing is lost"
  mwc_fixture "$C2_TASK" IN_PROGRESS
  A_INSIDE="$SCRATCH/c2-a-inside.forced"
  B_ARRIVED="$SCRATCH/c2-b-arrived.forced"
  rm -f "$A_INSIDE" "$B_ARRIVED"
  bash "$BIN/c2-status.sh" "$LIB" "$NZ" "$C2_TASK" "$A_INSIDE" "$B_ARRIVED" \
    > /dev/null 2> "$SCRATCH/c2-a-forced.err" &
  FA=$!
  bash "$BIN/c2-evidence.sh" "$LIB" "$NZ" "$C2_TASK" "$A_INSIDE" "$B_ARRIVED" forced 0.000 1 \
    > /dev/null 2> "$SCRATCH/c2-b-forced.err" &
  FB=$!
  wait "$FA"; C2F_RA=$?
  wait "$FB"; C2F_RB=$?
  C2F_ERR=$(cat "$SCRATCH/c2-b-forced.err" 2>/dev/null)
  assert_exit_code "case 2 forced contention: the lock holder's write succeeds" "$C2F_RA" 0
  if [ "$C2F_RB" -ne 0 ]; then
    _pass "case 2 forced contention: the loser returns non-zero rather than losing an update"
  else
    _fail "case 2 forced contention: the loser returns non-zero rather than losing an update" \
      "the writer that provably arrived inside the critical section exited 0"
  fi
  assert_contains "case 2 forced contention: the loser names its cause" \
    "$C2F_ERR" "(cause: lock_unavailable)"
  assert_contains "case 2 forced contention: the named diagnostic" \
    "$C2F_ERR" "another transition already holds the ${C2_TASK} lock"
  assert_eq "case 2 forced contention: the winner's effect is present" \
    "$(get_task_status "$C2_M" "UNREADABLE")" "IMPLEMENTED"
  assert_file_not_contains "case 2 forced contention: the loser installed nothing" \
    "$C2_M" '^- red-run: forced$'
  rm -f "$A_INSIDE" "$B_ARRIVED"
else
  _skip "case 2: primitive arm — scripts/lib/manifest-write.sh absent"
fi

echo "-- case 2 positive control: the same pair, unlocked (the pre-change shape)"
C2C_LOST=0
C2C_TASK=TASK-005
C2C_M="$NZ/tasks/$C2C_TASK.md"
for i in $(seq 1 "$MWC_REPEAT"); do
  mwc_fixture "$C2C_TASK" IN_PROGRESS
  A_READ="$SCRATCH/c2c-a-read.$i"
  B_READ="$SCRATCH/c2c-b-read.$i"
  A_WROTE="$SCRATCH/c2c-a-wrote.$i"
  rm -f "$A_READ" "$B_READ" "$A_WROTE"
  DELAY=$(seeded_delay "$i")
  TOKEN="ctl-$i"
  bash "$BIN/c2-status-unlocked.sh" "$C2C_M" "$A_READ" "$B_READ" "$A_WROTE" \
    > /dev/null 2>&1 &
  QA=$!
  bash "$BIN/c2-evidence-unlocked.sh" "$C2C_M" "$A_READ" "$B_READ" "$A_WROTE" "$TOKEN" "$DELAY" \
    > /dev/null 2>&1 &
  QB=$!
  wait "$QA"; QRA=$?
  wait "$QB"; QRB=$?
  QSTATUS=$(get_task_status "$C2C_M" "UNREADABLE")
  QEFF_B=0; grep -qF -- "- red-run: $TOKEN" "$C2C_M" && QEFF_B=1
  if [ "$QRA" -eq 0 ] && [ "$QRB" -eq 0 ] \
    && { [ "$QSTATUS" != "IMPLEMENTED" ] || [ "$QEFF_B" -eq 0 ]; }; then
    C2C_LOST=$((C2C_LOST + 1))
  fi
  rm -f "$A_READ" "$B_READ" "$A_WROTE"
done
printf '  case 2 control: %d iterations — lost-updates=%d\n' "$MWC_REPEAT" "$C2C_LOST"
if [ "$C2C_LOST" -ge 1 ]; then
  record_control unlocked-loses-updates
  _pass "control: the unlocked pair loses an update (${C2C_LOST}/${MWC_REPEAT} iterations)"
else
  _fail "control: the unlocked pair loses an update" \
    "0 lost updates across ${MWC_REPEAT} iterations — the control did not fire"
fi
assert_control_fired "case 2's no-lost-update assertion" unlocked-loses-updates

echo "-- case 3: the reentrancy guard cannot regress into a deadlock"
if [ "$PRIMITIVE_PRESENT" -eq 1 ]; then
  C3_TASK=TASK-006
  mwc_fixture "$C3_TASK" IN_PROGRESS
  C3_M="$NZ/tasks/$C3_TASK.md"
  C3_LOCK=$(nz_manifest_lock_path "$NZ" "$C3_TASK")
  p_append() { cat "$1"; printf -- '- appended-by-producer\n'; }
  c3_inner() { nz_manifest_write_locked "$NZ" "$C3_TASK" -- p_append; }
  c3_outer() { nz_manifest_write "$NZ" "$C3_TASK" -- p_append; }

  C3_T0=$(date +%s)
  run_bounded 10 nz_manifest_with_lock "$NZ" "$C3_TASK" c3_inner
  C3_INNER_RC=$?
  C3_INNER_ELAPSED=$(( $(date +%s) - C3_T0 ))
  if [ "$C3_INNER_RC" -eq 0 ] && grep -q '^- appended-by-producer$' "$C3_M"; then
    record_control locked-inner-write
    _pass "control: from inside the lock the INNER form writes, inside the same bound (${C3_INNER_ELAPSED}s)"
  else
    _fail "control: from inside the lock the INNER form writes, inside the same bound" \
      "rc=$C3_INNER_RC elapsed=${C3_INNER_ELAPSED}s"
  fi

  mwc_fixture "$C3_TASK" IN_PROGRESS
  record_file_digest C3_BEFORE "$C3_M" "$C3_TASK pre-reentrancy-probe"
  C3_T1=$(date +%s)
  run_bounded 10 nz_manifest_with_lock "$NZ" "$C3_TASK" c3_outer
  C3_RC=$?
  C3_ELAPSED=$(( $(date +%s) - C3_T1 ))
  C3_ERR=$(bounded_err)
  printf '  case 3: the outer form returned rc=%s after %ss under a 10s bound\n' "$C3_RC" "$C3_ELAPSED"
  if [ "$C3_RC" -eq 124 ]; then
    _fail "case 3: the outer form returns WITHIN the bound instead of deadlocking" \
      "nz_manifest_write never returned under a 10s bound — this is the deadlock regression"
  else
    _pass "case 3: the outer form returns WITHIN the bound instead of deadlocking"
  fi
  assert_exit_code "case 3: the outer form returns non-zero from inside the lock" "$C3_RC" 1
  assert_contains "case 3: the named cause" "$C3_ERR" "(cause: lock_unavailable)"
  assert_contains "case 3: the named diagnostic" \
    "$C3_ERR" "another transition already holds the ${C3_TASK} lock"
  assert_file_unchanged "case 3: the refused reentrant write left the manifest byte-identical" \
    "$C3_M" "$C3_BEFORE"
  assert_dir_not_exists "case 3: the outer lock is released on the way out" "$C3_LOCK"
  assert_control_fired "case 3's bounded-refusal assertion" locked-inner-write
else
  _skip "case 3 — scripts/lib/manifest-write.sh absent"
fi

echo "-- case coverage"
MWC_N=0; MWC_M=0; MWC_K=0; MWC_F=0
MWC_ABSENT=0
for case_id in case-1-interrupted-write case-2-serialized-writers case-3-bounded-reentrancy; do
  MWC_N=$((MWC_N + 1))
  if [ "$PRIMITIVE_PRESENT" -eq 1 ]; then
    MWC_K=$((MWC_K + 1))
  else
    MWC_M=$((MWC_M + 1)); MWC_ABSENT=$((MWC_ABSENT + 1)); MWC_F=$((MWC_F + 1))
    printf '  manifest-write-concurrency: %s NOT checked — the primitive is absent\n' "$case_id"
  fi
done
printf '  manifest-write-concurrency: %d scanned, %d skipped (primitive-absent=%d), %d checked, %d findings\n' \
  "$MWC_N" "$MWC_M" "$MWC_ABSENT" "$MWC_K" "$MWC_F"
assert_eq "case coverage: scanned == skipped + checked" "$MWC_N" "$((MWC_M + MWC_K))"
if [ "$MWC_K" -gt 0 ]; then
  _pass "case coverage: K > 0, so the three cases were not vacuously clean"
else
  _fail "case coverage: K > 0, so the three cases were not vacuously clean" \
    "no case ran against a live primitive"
fi

MWC_ELAPSED=$(( $(date +%s) - MWC_STARTED_AT ))
printf '  manifest-write-concurrency: whole-file runtime %ss (budget 30s)\n' "$MWC_ELAPSED"
if [ "$MWC_ELAPSED" -lt 30 ]; then
  _pass "runtime budget: the file completes in under 30s, so the scoped filter stays usable"
else
  _fail "runtime budget: the file completes in under 30s" "took ${MWC_ELAPSED}s"
fi

teardown_temp_dir
report_results
