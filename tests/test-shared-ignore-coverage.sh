#!/usr/bin/env bash
set -uo pipefail
# test-shared-ignore-coverage — sweeps skills/init/SKILL.md's shared-mode
# ephemeral-ignore block against the `nazgul/` paths this codebase actually
# names, so a future ephemeral dir cannot be forgotten the way #251 was.
#   DERIVED from source: WHICH `nazgul/` paths the tree touches (the enumerator
#     below, deliberately over-inclusive — under-collection is what produced
#     #251 and it is silent; over-collection is loud and costs one row).
#   DECLARED, never derived: WHETHER a path is ephemeral machine-local state or
#     a shared decision record. Guessing that from a name would be confidently
#     wrong for exactly the ambiguous cases where the answer matters.
# Four assertions, four finding classes: A1 undeclared, A2 unignored,
# A3 over-ignored, A4 stale-declaration. A1 and A4 pin the declaration table to
# source in BOTH directions, so the hand-maintained half cannot drift either.
# The block is EXTRACTED from the skill at test time, never retyped: a copy
# carried here would assert only that the copy is correct. Block membership is
# tested PER-DECLARATION against exact block lines, never by prefix, so
# nazgul/reviews stays a record while four of its children are ephemeral.
# Coverage grammar per RULES.md §15. K>0 floor, N == M + K asserted, blocking.
TEST_NAME="test-shared-ignore-coverage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
export LC_ALL=C

# NOT normalized, on purpose: `find "$SWEEP_ROOT/$s"` and `${f#"$SWEEP_ROOT"/}` are one
# expression, so `.`, `./` and a trailing slash cancel (#254 C5, refuted on all four forms).
SWEEP_ROOT="${NAZGUL_IGNORE_SWEEP_ROOT:-$REPO_ROOT}"
SOURCE_DIRS="scripts skills agents templates"
INIT_SKILL="skills/init/SKILL.md"
CLEAN_SKILL="skills/clean/SKILL.md"
BLOCK_MARKER="# Nazgul Framework — ephemeral runtime"

# Family 1 is the literal `nazgul/<seg>`; family 2 is the variable-rooted shape
# ($NAZGUL_DIR/<seg>), which is dominant and carries no literal for family 1.
OCC_RE='nazgul/[^[:space:]'"'"'"`]*|\$\{?[Nn][Aa][Zz][Gg][Uu][Ll]_[Dd][Ii][Rr]\}?/[^[:space:]'"'"'"`]*'
TRAIL_PUNCT='.,;)}"'"'"'`'
FORBIDDEN_CHARS='${}<>*?()"'"'"'|`'

# Pinned floor (test-messaging-posture.sh's POSTURE_ROSTER idiom). Four fields:
# key|ephemeral-or-record|block-entry-or-dash|reason; a reason may not contain `|`.
DECLARATIONS='nazgul/config.json|record|-|Runtime configuration; the decision record a teammate resumes the loop from
nazgul/plan.md|record|-|The live task tracker and Recovery Pointer; not regenerable off this machine
nazgul/tasks|record|-|Task manifests carrying status, evidence and review history
nazgul/context|record|-|Discovery output teammates read; only the .backup.* snapshots are machine-local
nazgul/docs|record|-|Generated PRD, TRD and ADRs
nazgul/reviews|record|-|Review artifacts per task; only the four children declared below are ephemeral
nazgul/learning|record|-|Learned-rule registry and declines stay tracked
nazgul/x|record|-|An illustrative placeholder in guard comments only (scripts/local-mode-tracking-guard.sh:71); nothing writes it, so it must never be a block line
nazgul/nazgul|record|-|Prose illustration of the path a NAZGUL_DIR misconfiguration would resolve to (scripts/doctor.sh:335); nothing writes it
nazgul/checkpoints|ephemeral|nazgul/checkpoints/|Per-iteration snapshots the loop regenerates
nazgul/logs|ephemeral|nazgul/logs/|Per-machine event journal
nazgul/sessions|ephemeral|nazgul/sessions/|Per-session locks and tracking
nazgul/archive|ephemeral|nazgul/archive/|Local archive written by /nazgul:reset
nazgul/.session_id|ephemeral|nazgul/.session_id|Current session id; per-machine
nazgul/.compaction_count|ephemeral|nazgul/.compaction_count|Per-session compaction counter
nazgul/.stop_failure|ephemeral|nazgul/.stop_failure|Per-session record of the last turn that ended via an API error
nazgul/.compaction_count.lock|ephemeral|nazgul/.compaction_count.lock|The mkdir lock guarding the counter; a different path component, so the counter entry does not cover it
nazgul/.tool_failures|ephemeral|nazgul/.tool_failures|Consecutive-tool-failure counter; per-session
nazgul/conductor|ephemeral|nazgul/conductor/|Residue of the runtime dir removed by migrate_25_to_26; nothing writes it any more
nazgul/in-flight|ephemeral|nazgul/in-flight/|Per-dispatch markers written at PreToolUse(Agent); the #251 headline path
nazgul/locks|ephemeral|nazgul/locks/|Transient mkdir mutual-exclusion dirs
nazgul/.heartbeat.lock|ephemeral|nazgul/.heartbeat.lock|The heartbeat tick lock; meaningless off its own machine
nazgul/.githooks|ephemeral|nazgul/.githooks/|Generated from scripts/git-hooks/ at install; committing it commits a stale copy of shipped code
nazgul/dispatch|ephemeral|nazgul/dispatch/|Per-dispatch report manifests; per-session
nazgul/improvement-reports|ephemeral|nazgul/improvement-reports/|Per-run self-rating JSON
nazgul/self-audit-window.json|ephemeral|nazgul/self-audit-window.json|A per-machine log-offset cursor
nazgul/.hitl-pending|ephemeral|nazgul/.hitl-pending|A transient approval marker
nazgul/config.json.tmp|ephemeral|nazgul/config.json.tmp|Exists only between a jq rewrite of config.json and its mv
nazgul/inbox|ephemeral|nazgul/inbox/|Local-only work queue; the GitHub board is the durable shareable copy
nazgul/HANDOFF.md|ephemeral|nazgul/HANDOFF.md|Per-session pause note written only by skills/pause/SKILL.md
nazgul/improvements.md|ephemeral|nazgul/improvements.md|Operator-ruled ephemeral; the recorded consequence is that the self-audit backlog does not reach teammates
nazgul/reviews|ephemeral|nazgul/reviews/*/test-failures.md|Regenerated per review under the reviews record dir
nazgul/reviews|ephemeral|nazgul/reviews/*/simplify-report.md|Regenerated per review under the reviews record dir
nazgul/reviews|ephemeral|nazgul/reviews/*/diff.patch|A committed stale captured diff makes reviewers analyze old code and emit phantom findings
nazgul/reviews|ephemeral|nazgul/reviews/post-loop-simplify-report.md|Post-loop working file under the reviews record dir
nazgul/learning|ephemeral|nazgul/learning/proposed-rules.md|Transient autolearning working file
nazgul/learning|ephemeral|nazgul/learning/.last-run|Transient autolearning working file'

# A1-A4 increment `findings` directly; the dogfood, P1/P2/P3 and copy-sync regions raise
# TESTS_FAILED instead, and each folds its own delta in as it closes, before the next baseline.
scanned=0; skipped_no_path=0; skipped_unreadable=0; checked=0; findings=0
unresolvable=0; block_excluded=0
KEY_HITS=""
BLOCK_REGIONS=""

# A segment is UNRESOLVABLE if, after trailing punctuation is stripped, it is
# empty or carries any non-literal character. RESOLVED holds the survivor.
_resolve_segment() {
  local s="$1" last i c
  while [ -n "$s" ]; do
    last="${s: -1}"
    case "$TRAIL_PUNCT" in *"$last"*) s="${s%?}" ;; *) break ;; esac
  done
  [ -n "$s" ] || return 1
  i=0
  while [ "$i" -lt "${#FORBIDDEN_CHARS}" ]; do
    c="${FORBIDDEN_CHARS:$i:1}"
    case "$s" in *"$c"*) return 1 ;; esac
    i=$((i + 1))
  done
  case "$s" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  RESOLVED="$s"
  return 0
}

# The two ```gitignore fences inside the init skill are the block regions: without
# excluding them the block would enumerate precisely what it ignores.
_compute_block_regions() {
  local f="$SWEEP_ROOT/$INIT_SKILL"
  [ -r "$f" ] || return 0
  BLOCK_REGIONS=$(awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    !o && line == "```gitignore" { o = 1; s = NR; next }
    o && line == "```" { if (NR - 1 >= s + 1) print (s + 1) "-" (NR - 1); o = 0 }
    END { if (o && NR >= s + 1) print (s + 1) "-" NR }
  ' "$f")
}

_in_block_region() {
  local ln="$1" r lo hi
  for r in $BLOCK_REGIONS; do
    lo="${r%-*}"; hi="${r#*-}"
    [ "$ln" -ge "$lo" ] && [ "$ln" -le "$hi" ] && return 0
  done
  return 1
}

_extract_block() {
  local f="$SWEEP_ROOT/$INIT_SKILL"
  [ -r "$f" ] || return 0
  awk -v marker="$BLOCK_MARKER" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    !inb && line == marker { inb = 1; next }
    inb && line == "```" { exit }
    inb { print line }
  ' "$f"
}

scan_file() {
  local f="$1" rel="${1#"$SWEEP_ROOT"/}" hits h ln m rest seg
  scanned=$((scanned + 1))
  if [ ! -r "$f" ]; then skipped_unreadable=$((skipped_unreadable + 1)); return 0; fi
  hits=$(grep -noE "$OCC_RE" "$f" 2>/dev/null)
  if [ -z "$hits" ]; then skipped_no_path=$((skipped_no_path + 1)); return 0; fi
  checked=$((checked + 1))
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    ln="${h%%:*}"; m="${h#*:}"
    if [ "$rel" = "$INIT_SKILL" ] && _in_block_region "$ln"; then
      block_excluded=$((block_excluded + 1)); continue
    fi
    rest="${m#*/}"; seg="${rest%%/*}"
    if ! _resolve_segment "$seg"; then unresolvable=$((unresolvable + 1)); continue; fi
    KEY_HITS="${KEY_HITS}nazgul/${RESOLVED}|${rel}:${ln}"$'\n'
  done <<EOF
$hits
EOF
  return 0
}

_compute_block_regions
for s in $SOURCE_DIRS; do
  [ -d "$SWEEP_ROOT/$s" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    scan_file "$f"
  done < <(find "$SWEEP_ROOT/$s" -type f 2>/dev/null | sort)
done

FIRST_HIT=$(printf '%s' "$KEY_HITS" | awk -F'|' 'NF && !seen[$1]++')
ENUM_KEYS=$(printf '%s' "$FIRST_HIT" | cut -d'|' -f1 | sort -u)
DECL_KEYS=$(printf '%s\n' "$DECLARATIONS" | cut -d'|' -f1 | sort -u)
enumerated_count=$(printf '%s' "$ENUM_KEYS" | grep -c . || true)
declared_count=$(printf '%s' "$DECL_KEYS" | grep -c . || true)

BLOCK=$(_extract_block)
block_usable=1
if [ -z "$BLOCK" ]; then
  block_usable=0
  findings=$((findings + 1))
  _fail "block extraction: $INIT_SKILL yields the shared-mode ignore block" \
    "no lines follow the marker '$BLOCK_MARKER' under $SWEEP_ROOT — the block cannot be compared, so A2/A3 were not run"
fi

_block_has_line() { printf '%s\n' "$BLOCK" | grep -Fxq -- "$1"; }
_first_hit_for() { printf '%s' "$FIRST_HIT" | grep -F -m1 -- "$1|" | cut -d'|' -f2; }

undeclared=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  if printf '%s' "$DECL_KEYS" | grep -Fxq -- "$key"; then continue; fi
  undeclared=$((undeclared + 1)); findings=$((findings + 1))
  _fail "A1 undeclared: $key has no declaration row" \
    "first seen at $(_first_hit_for "$key") — decide whether it is ephemeral or a record and add a row; do NOT narrow the enumerator"
done <<EOF
$ENUM_KEYS
EOF
[ "$undeclared" -eq 0 ] && _pass "A1 undeclared: all $enumerated_count enumerated path(s) carry a declaration row"

eph_rows=0; rec_rows=0; unignored=0; over_ignored=0
while IFS='|' read -r key disp entry reason; do
  [ -n "$key" ] || continue
  case "$disp" in
    ephemeral)
      eph_rows=$((eph_rows + 1))
      [ "$block_usable" -eq 1 ] || continue
      if [ "$entry" = "-" ]; then
        unignored=$((unignored + 1)); findings=$((findings + 1))
        _fail "A2 unignored: $key is declared ephemeral with no block entry" \
          "reason given: $reason — an ephemeral path with no line to check is a declaration that asserts nothing"
      elif ! _block_has_line "$entry"; then
        unignored=$((unignored + 1)); findings=$((findings + 1))
        _fail "A2 unignored: '$entry' is absent from the shared-mode block" \
          "declared ephemeral ($reason) but no exact line in $INIT_SKILL matches — this is the #251 defect itself"
      fi
      ;;
    record)
      rec_rows=$((rec_rows + 1))
      [ "$block_usable" -eq 1 ] || continue
      if _block_has_line "$key" || _block_has_line "$key/"; then
        over_ignored=$((over_ignored + 1)); findings=$((findings + 1))
        _fail "A3 over-ignored: '$key' is a record but the shared-mode block ignores it" \
          "reason given: $reason — a decision record silently ignored means a teammate cannot resume from a clone"
      fi
      ;;
    *)
      findings=$((findings + 1))
      _fail "declaration schema: row for $key names a known disposition" \
        "got '$disp' — the closed set is ephemeral|record"
      ;;
  esac
done <<EOF
$DECLARATIONS
EOF

# The trailing slash is the F5 hazard in miniature: block entries carry one and
# keys do not, so A3 tests both forms rather than reporting an unchecked agreement.
if [ "$block_usable" -eq 1 ]; then
  [ "$unignored" -eq 0 ] && _pass "A2 unignored: all $eph_rows ephemeral row(s) appear as exact lines in the shared-mode block"
  [ "$over_ignored" -eq 0 ] && _pass "A3 over-ignored: none of the $rec_rows record row(s) is ignored by the shared-mode block"
else
  _skip "A2/A3 (the shared-mode block could not be extracted — reported as a finding above)"
fi

stale=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  if printf '%s' "$ENUM_KEYS" | grep -Fxq -- "$key"; then continue; fi
  stale=$((stale + 1)); findings=$((findings + 1))
  _fail "A4 stale-declaration: $key is declared but no longer enumerated from source" \
    "no occurrence under $SWEEP_ROOT/{$(printf '%s' "$SOURCE_DIRS" | tr ' ' ',')} — a removed writer must retire its declaration"
done <<EOF
$DECL_KEYS
EOF
[ "$stale" -eq 0 ] && _pass "A4 stale-declaration: all $declared_count declared key(s) are still enumerated from source"

if [ "$checked" -gt 0 ]; then
  [ "$findings" -eq 0 ] && _pass "the shared-mode ignore block agrees with source in both directions ($checked files, $enumerated_count paths)"
else
  if [ "$scanned" -eq 0 ]; then
    echo "$TEST_NAME: NOTHING CHECKED — no source files discovered under $SWEEP_ROOT" >&2
  else
    echo "$TEST_NAME: NOTHING CHECKED — all $scanned candidates skipped" >&2
  fi
  findings=$((findings + 1))
  _fail "K>0 floor: the sweep examined at least one file" \
    "checked=0 — a sweep that reads nothing is a broken sweep, not a clean block"
fi
if [ "$scanned" -ne $((skipped_no_path + skipped_unreadable + checked)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $scanned scanned != $((skipped_no_path + skipped_unreadable)) skipped + $checked checked" >&2
  findings=$((findings + 1))
  _fail "coverage accounting adds up (N == M + K)" \
    "$scanned != $skipped_no_path + $skipped_unreadable + $checked"
fi

# One predicate for both mktemp -d sites and for C7's control below: a second, independently
# written test would be the divergence the SWEEP_ROOT disposition above says to avoid.
_scratch_usable() { [ -n "${1:-}" ] && [ -d "$1" ]; }

# Removal is guarded on a non-empty value, so a trap installed before a failed mktemp -d
# cannot degrade to `rm -rf ""`.
_rm_scratch() { local d; for d in "$@"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }

# Dogfood — a detector that can only ever pass is evidence of nothing (RULES §15).
# Skipped under an injected sweep root: the fixtures re-enter this file and recurse.
D_FAILED_BEFORE=$TESTS_FAILED
if [ -n "${NAZGUL_IGNORE_SWEEP_FOLD_PROBE:-}" ]; then
  # C3's control, driven by _dog_fold_run below: one deliberate failure inside this region
  # and nothing else, so a child's findings delta measures the fold and only the fold.
  _fail "fold probe: a deliberate dogfood-region failure" \
    "raised by NAZGUL_IGNORE_SWEEP_FOLD_PROBE — it must reach the findings tally, not TESTS_FAILED alone"
elif [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip "dogfood fixtures (inner run under an injected sweep root)"
else
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-ignore-sweep-XXXXXX" 2>/dev/null) || SCRATCH=""
if ! _scratch_usable "$SCRATCH"; then
  _fail "dogfood scratch: mktemp -d under ${TMPDIR:-/tmp} yields a directory" \
    "got '$SCRATCH' — an empty value makes \$DOG the root-relative /tree that _dog_reset would remove and recreate outside any temp dir (#254 C7); the dogfood arms did not run"
  exit 1
fi
trap '_rm_scratch "$SCRATCH"' EXIT

# C7 control: the same predicate the two mktemp sites use, driven both ways — a guard that
# refused everything and one that refused nothing would otherwise read identically.
C7_EMPTY_SCRATCH=""
if _scratch_usable "$C7_EMPTY_SCRATCH"; then C7_EMPTY_VERDICT="use"; else C7_EMPTY_VERDICT="refuse"; fi
if _scratch_usable "$SCRATCH"; then C7_REAL_VERDICT="use"; else C7_REAL_VERDICT="refuse"; fi
assert_eq "C7: an empty mktemp -d result is refused" "$C7_EMPTY_VERDICT" "refuse"
assert_eq "C7: and a real one is used, so the guard is not refusing everything" "$C7_REAL_VERDICT" "use"
C7_EMPTY_DOG="$C7_EMPTY_SCRATCH/tree"
assert_eq "C7: the refused value computes the root-relative path — shown here, never passed to rm" \
  "$C7_EMPTY_DOG" "/tree"

DOG="$SCRATCH/tree"
DOG_CLASSES=("A1 undeclared" "A2 unignored" "A3 over-ignored" "A4 stale-declaration")

# One literal producer per DECLARED key, so a pristine fixture is clean in both
# directions: nothing enumerated is undeclared (A1), nothing declared is stale (A4).
_dog_reset() {
  rm -rf "$DOG"
  mkdir -p "$DOG/scripts" "$DOG/${INIT_SKILL%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    while IFS= read -r k; do
      [ -n "$k" ] && printf 'write_state "%s"\n' "$k"
    done <<INNER
$DECL_KEYS
INNER
  } > "$DOG/scripts/producer.sh"
  cp "$REPO_ROOT/$INIT_SKILL" "$DOG/$INIT_SKILL"
}

_dog_run() { NAZGUL_IGNORE_SWEEP_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1; }
_dog_fold_run() { env NAZGUL_IGNORE_SWEEP_FOLD_PROBE=1 NAZGUL_IGNORE_SWEEP_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1; }

# Block variations are made on the fixture's COPY, never on the shipped skill, and
# by the same trimmed-line predicate _extract_block uses.
_dog_block_drop() {
  local f="$DOG/$INIT_SKILL"
  awk -v e="$1" '{ t = $0; sub(/^[[:space:]]+/, "", t) } t != e' "$f" > "$f.new" && mv "$f.new" "$f"
}

_dog_block_add() {
  local f="$DOG/$INIT_SKILL"
  awk -v e="$1" -v m="$BLOCK_MARKER" '
    { print; t = $0; sub(/^[[:space:]]+/, "", t) }
    t == m { print "   " e }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

_dog_unproduce() {
  local f="$DOG/scripts/producer.sh"
  grep -vF "write_state \"$1\"" "$f" > "$f.new" && mv "$f.new" "$f"
}

_dog_n() { local n; n=$(printf '%s\n' "$1" | grep -cF "FAIL: $2"); printf '%s' "$n"; }

# MISSING, never an empty string: a field these cannot find must fail an assertion
# rather than silently compare equal to another absent field.
_dog_findings() {
  printf '%s\n' "$1" | awk '/, [0-9]+ findings$/ { f = $(NF - 1) } END { print (f == "" ? "MISSING" : f) }'
}

_dog_paths_field() {
  printf '%s\n' "$1" | awk -v want="$2" '
    /^paths: / { sub(/^paths: /, ""); n = split($0, p, ", ")
      for (i = 1; i <= n; i++) { split(p[i], kv, " "); if (kv[2] == want) { print kv[1]; f = 1 } } }
    END { if (!f) print "MISSING" }'
}

# Exactly one finding of the named class AND zero of the other three: "a finding
# appeared" would not distinguish a precise detector from one that fires on everything.
_dog_only() {
  local label="$1" out="$2" rc="$3" want="$4"
  local cls got exp detail="" ok=1
  for cls in "${DOG_CLASSES[@]}"; do
    got=$(_dog_n "$out" "$cls")
    if [ "${cls%% *}" = "$want" ]; then exp=1; else exp=0; fi
    detail="$detail ${cls%% *}=$got(want $exp)"
    [ "$got" -eq "$exp" ] || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    _pass "$label: exactly one $want finding, none of the other three —$detail"
  else
    _fail "$label: exactly one $want finding, none of the other three" "got —$detail"
  fi
  assert_exit_code "$label: blocking" "$rc" 1
  assert_contains "$label: counted as exactly one finding overall" "$out" ", 1 findings"
}

_dog_clear() {
  local label="$1" out="$2" rc="$3"
  assert_exit_code "$label: exit 0" "$rc" 0
  assert_contains "$label: zero findings" "$out" ", 0 findings"
  assert_not_contains "$label: no finding line survives" "$out" "FAIL: "
}

_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "D0 baseline: a fixture whose declarations match its source is clean" "$D_OUT" "$D_RC"
BASE_UNRES=$(_dog_paths_field "$D_OUT" unresolvable)
BASE_ENUM=$(_dog_paths_field "$D_OUT" enumerated)
if [ "$BASE_UNRES" = "MISSING" ] || [ "$BASE_ENUM" = "MISSING" ]; then
  _fail "D0: the paths line exposes the enumerated and unresolvable tallies" \
    "enumerated='$BASE_ENUM' unresolvable='$BASE_UNRES' — S4 below cannot measure a delta against a missing baseline"
  BASE_UNRES=-1; BASE_ENUM=-1
else
  _pass "D0: the paths line exposes the enumerated ($BASE_ENUM) and unresolvable ($BASE_UNRES) tallies"
fi
assert_eq "D0: every declared key is produced by the fixture" "$BASE_ENUM" "$declared_count"

# C3: this region raises TESTS_FAILED, not `findings`, so a dogfood failure reaches the §15
# line only through the delta folded in when the region closes. Differenced against D0's run.
D_FOLD_CLEAN=$(_dog_findings "$D_OUT")
D_FOLD_OUT=$(_dog_fold_run); D_FOLD_RC=$?
D_FOLD_PROBE=$(_dog_findings "$D_FOLD_OUT")
if [ "$D_FOLD_CLEAN" = "MISSING" ] || [ "$D_FOLD_PROBE" = "MISSING" ]; then
  _fail "C3 fold: both runs expose a findings tally for the delta to be taken from" \
    "clean='$D_FOLD_CLEAN' probe='$D_FOLD_PROBE' — two absent counts must not read as a delta of zero"
else
  assert_eq "C3 fold: one failure raised inside the dogfood region raises the findings tally by exactly one" \
    "$((D_FOLD_PROBE - D_FOLD_CLEAN))" "1"
fi
assert_exit_code "C3 fold: and a dogfood-region failure is blocking" "$D_FOLD_RC" 1

# The fold assertion's own control: a copy of this file with the fold line mechanically removed
# is the pre-change accounting, and a delta of 1 above would otherwise also fit a constant 1.
D_FOLD_LINE='findings=$((findings + TESTS_FAILED - D_FAILED_BEFORE))'
D_MUT="$SCRATCH/foldless"
mkdir -p "$D_MUT" && ln -sfn "$SCRIPT_DIR/lib" "$D_MUT/lib"
grep -vxF -- "$D_FOLD_LINE" "$SCRIPT_DIR/$TEST_NAME.sh" > "$D_MUT/$TEST_NAME.sh"
assert_eq "C3 fold CONTROL: the mutant differs from this file by exactly the fold line" \
  "$(( $(wc -l < "$SCRIPT_DIR/$TEST_NAME.sh") - $(wc -l < "$D_MUT/$TEST_NAME.sh") ))" "1"
D_MUT_OUT=$(env NAZGUL_IGNORE_SWEEP_FOLD_PROBE=1 NAZGUL_IGNORE_SWEEP_ROOT="$DOG" bash "$D_MUT/$TEST_NAME.sh" 2>&1)
D_MUT_RC=$?
D_FOLD_MUT=$(_dog_findings "$D_MUT_OUT")
if [ "$D_FOLD_MUT" = "MISSING" ] || [ "$D_FOLD_CLEAN" = "MISSING" ]; then
  _fail "C3 fold CONTROL: the mutant run exposes a findings tally to difference" \
    "mutant='$D_FOLD_MUT' clean='$D_FOLD_CLEAN' — an absent count must not read as the under-count being looked for"
else
  assert_eq "C3 fold CONTROL: without the fold the same probe leaves the findings tally unmoved" \
    "$((D_FOLD_MUT - D_FOLD_CLEAN))" "0"
fi
assert_exit_code "C3 fold CONTROL: and the mutant still exits 1, so a 0 tally sits on a failing run" "$D_MUT_RC" 1

_dog_reset
printf '#!/usr/bin/env bash\nmkdir -p "$NAZGUL_DIR/novel-dir"\n' > "$DOG/scripts/novel.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C1 undeclared: a writer of a novel nazgul/ dir with no declaration row" "$D_OUT" "$D_RC" A1
assert_contains "C1: the finding names the novel path" "$D_OUT" \
  "A1 undeclared: nazgul/novel-dir has no declaration row"
rm -f "$DOG/scripts/novel.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C1 clears: removing the writer clears the undeclared finding" "$D_OUT" "$D_RC"

_dog_reset
_dog_block_drop "nazgul/logs/"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C2 unignored: an ephemeral declaration whose block entry is absent" "$D_OUT" "$D_RC" A2
assert_contains "C2: the finding names the absent block entry" "$D_OUT" \
  "A2 unignored: 'nazgul/logs/' is absent from the shared-mode block"
_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C2 clears: restoring the block entry clears the unignored finding" "$D_OUT" "$D_RC"

_dog_reset
_dog_block_add "nazgul/tasks/"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C3 over-ignored: a record key present as an exact block line" "$D_OUT" "$D_RC" A3
assert_contains "C3: the finding names the over-ignored record" "$D_OUT" \
  "A3 over-ignored: 'nazgul/tasks' is a record but the shared-mode block ignores it"
_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C3 clears: removing the block line clears the over-ignored finding" "$D_OUT" "$D_RC"

_dog_reset
_dog_unproduce "nazgul/x"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C4 stale-declaration: a declared key no file in the scan root produces" "$D_OUT" "$D_RC" A4
assert_contains "C4: the finding names the stale declaration" "$D_OUT" \
  "A4 stale-declaration: nazgul/x is declared but no longer enumerated from source"
_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C4 clears: restoring the writer clears the stale-declaration finding" "$D_OUT" "$D_RC"

# S1-S4 use A1 as the readout: an undeclared key can only be REPORTED if it was
# ENUMERATED, so the finding is the enumeration proof and its citation is the line.
_dog_reset
printf '#!/usr/bin/env bash\nX="$NAZGUL_DIR/aliased-dir"\nmkdir -p "$X"\n' > "$DOG/scripts/aliased.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "S1 aliased write (scripts/in-flight-marker.sh:73-74's own shape)" "$D_OUT" "$D_RC" A1
assert_contains "S1: enumerated from the assignment, with no dataflow analysis" "$D_OUT" \
  "A1 undeclared: nazgul/aliased-dir has no declaration row"
assert_contains "S1: cited at the assignment line, not at the later mkdir" "$D_OUT" \
  "first seen at scripts/aliased.sh:2"

_dog_reset
printf '#!/usr/bin/env bash\nmkdir -p nazgul/literal-dir\n' > "$DOG/scripts/literal.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "S2 literal relative write (templates/skill-partials/report-contract.md:19's shape)" "$D_OUT" "$D_RC" A1
assert_contains "S2: an unquoted relative literal is enumerated" "$D_OUT" \
  "A1 undeclared: nazgul/literal-dir has no declaration row"

_dog_reset
printf '#!/usr/bin/env bash\nif [ -d "$ROOT/nazgul/read-only-dir/x" ]; then :; fi\n' > "$DOG/scripts/readonly.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "S3 read-only occurrence (scripts/task-state-guard.sh:353, the sole nazgul/locks literal)" "$D_OUT" "$D_RC" A1
assert_contains "S3: a read is enumerated too — a mutating-line filter would miss nazgul/locks" "$D_OUT" \
  "A1 undeclared: nazgul/read-only-dir has no declaration row"

_dog_reset
printf 'nazgul/$SOMEVAR\nnazgul/<name>\nnazgul/**\nnazgul/...\n' > "$DOG/scripts/unresolvable.sh"
D_OUT=$(_dog_run); D_RC=$?
assert_eq "S4: all four unresolvable tokens move the tally, none silently dropped" \
  "$(_dog_paths_field "$D_OUT" unresolvable)" "$((BASE_UNRES + 4))"
assert_eq "S4: and none of them is reported as a path" \
  "$(_dog_paths_field "$D_OUT" enumerated)" "$BASE_ENUM"
_dog_clear "S4: an unresolvable token is counted, not a finding" "$D_OUT" "$D_RC"

# P12 — the pin that would have caught #251 the day nazgul/in-flight/ was introduced.
_dog_reset
_dog_block_drop "nazgul/in-flight/"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "P12 #251: a block that no longer contains its own subject" "$D_OUT" "$D_RC" A2
assert_contains "P12: the finding names nazgul/in-flight/" "$D_OUT" \
  "A2 unignored: 'nazgul/in-flight/' is absent from the shared-mode block"
fi
findings=$((findings + TESTS_FAILED - D_FAILED_BEFORE))

# P1/P2/P3 prove the block changes GIT'S BEHAVIOUR, not the skill's text alone, and
# run in a scratch `git init` tree: this checkout is local-mode, so there is no in-tree repro.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip "P1/P2/P3 git-behaviour arms (inner run under an injected sweep root)"
else
R_FAILED_BEFORE=$TESTS_FAILED
ROUTES=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-ignore-routes-XXXXXX" 2>/dev/null) || ROUTES=""
if ! _scratch_usable "$ROUTES"; then
  _fail "routes scratch: mktemp -d under ${TMPDIR:-/tmp} yields a directory" \
    "got '$ROUTES' — the P1/P2/P3 arms write their fences and their two git repos under it; refusing an empty path (#254 C7)"
  exit 1
fi
# Supersedes the dogfood trap and must keep removing BOTH trees; the two sections
# share one guard condition, so $SCRATCH is always set by the time this runs.
trap '_rm_scratch "$SCRATCH" "$ROUTES"' EXIT
mkdir -p "$ROUTES/home"

LOCAL_MARKER="# Nazgul Framework (local mode)"
# The local-mode fence's sha256 at 0738a1a, this objective's Base SHA. Pinned rather
# than read back from git, which a shallow CI clone cannot resolve.
LOCAL_FENCE_SHA_BASE="a6dae5f0e33e2fd6c237ce75d77dddb302267e52e7d15ffe0dccf03e0bbc80a6"

# Raw fence lines for the ```gitignore fence CONTAINING a marker. P1 must see WHICH
# line comes first, so this cannot start AT the marker the way _extract_block does.
_fenced_lines() {
  awk -v marker="$1" '
    { t = $0; sub(/^[[:space:]]+/, "", t) }
    !inf && t == "```gitignore" { inf = 1; n = 0; hit = 0; split("", buf); next }
    inf && t == "```" { if (hit) { for (i = 1; i <= n; i++) print buf[i]; exit } inf = 0; next }
    inf { buf[++n] = $0; if (t == marker) hit = 1 }
  ' "$SWEEP_ROOT/$INIT_SKILL"
}

_sha256() { { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'; }

# Whitespace-delimited membership, so nazgul/in-flight cannot be satisfied by a
# substring of a longer pathspec such as nazgul/in-flight-other.
_names_token() { printf '%s' "$1" | tr ' \t' '\n\n' | grep -Fxq -- "$2"; }

# Either slash form counts for a literal directory: the P2 F5 arm below MEASURES
# that both match, unlike the wildcard entries F5 records.
_names_dir_token() { _names_token "$1" "$2" || _names_token "$1" "$2/"; }

# The `git rm` one-shots are joined across their `\` continuations: a truncated join
# would make the glob invocation's NON-membership result an artifact, not an absence.
_join_cmd() {
  awk -v pat="$1" '
    !s { if (index($0, pat)) s = 1; else next }
    s { print; if ($0 !~ /\\[[:space:]]*$/) exit }
  ' "$SWEEP_ROOT/$INIT_SKILL"
}

_fenced_lines "$BLOCK_MARKER" > "$ROUTES/shared.raw"
routes_usable=1
if [ ! -s "$ROUTES/shared.raw" ]; then
  routes_usable=0
  _fail "P1 fence: the shared-mode gitignore fence is extractable from $INIT_SKILL" \
    "no fence under $SWEEP_ROOT contains the marker '$BLOCK_MARKER' — P1 structure and P2 had nothing to run against"
fi

if [ "$routes_usable" -eq 1 ]; then
  R_FENCE_N=$(wc -l < "$ROUTES/shared.raw" | tr -d ' ')
  R_BLOCK_N=$(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ')
  assert_eq "P1 extractors agree: the fence is the marker plus _extract_block's $R_BLOCK_N line(s)" \
    "$R_FENCE_N" "$((R_BLOCK_N + 1))"

  R_L1=$(sed -n '1p' "$ROUTES/shared.raw" | sed 's/^[[:space:]]*//')
  R_L2=$(sed -n '2p' "$ROUTES/shared.raw" | sed 's/^[[:space:]]*//')
  assert_eq "P1 marker: the block's exact first line is still the detection marker ($INIT_SKILL:78-83 matches it alone)" \
    "$R_L1" "$BLOCK_MARKER"
  R_L2_CLASS="other"
  case "$R_L2" in
    "$BLOCK_MARKER") R_L2_CLASS="marker-repeated" ;;
    "#"*) R_L2_CLASS="comment" ;;
  esac
  assert_eq "P1 comment: the block's second line is the descriptive comment, not an entry" "$R_L2_CLASS" "comment"

  R_BLANKS=$(grep -c '^[[:space:]]*$' "$ROUTES/shared.raw" || true)
  assert_eq "P1 structure: no blank line inside the block (one would truncate what --force removal sees)" \
    "$R_BLANKS" "0"

  sed 's/^[[:space:]]*//' "$ROUTES/shared.raw" > "$ROUTES/green.gitignore"
  grep -vxF 'nazgul/in-flight/' "$ROUTES/green.gitignore" > "$ROUTES/red.gitignore" || true
  R_GREEN_N=$(wc -l < "$ROUTES/green.gitignore" | tr -d ' ')
  R_RED_N=$(wc -l < "$ROUTES/red.gitignore" | tr -d ' ')
  assert_eq "P2 control built: dropping nazgul/in-flight/ removes exactly one line of the block" \
    "$((R_GREEN_N - R_RED_N))" "1"
  assert_eq "P2 control built: and no nazgul/in-flight/ line survives in the RED variant" \
    "$(grep -cxF 'nazgul/in-flight/' "$ROUTES/red.gitignore" || true)" "0"

  _rgit() { local d="$1"; shift; env HOME="$ROUTES/home" XDG_CONFIG_HOME="$ROUTES/home/.config" GIT_CONFIG_NOSYSTEM=1 git -C "$d" "$@"; }

  # HOME/XDG/system config are neutralised so a host's core.excludesFile or
  # core.hooksPath cannot decide the verdict; a fresh git init inherits neither.
  _routes_repo() {
    local d="$1" ign="$2"
    mkdir -p "$d/nazgul/in-flight/quarantine"
    cp "$ign" "$d/.gitignore"
    printf '{}\n' > "$d/nazgul/in-flight/m.json"
    printf '{}\n' > "$d/nazgul/in-flight/quarantine/q.json"
    _rgit "$d" -c init.defaultBranch=main init -q
  }

  # Filtered by output PREFIX, never by pathspec — scripts/session-staging.sh:135
  # passes no pathspec either, and F5's trailing-slash hazard lives in pathspecs.
  _route_staging() { _rgit "$1" ls-files --others --exclude-standard 2>/dev/null | grep -c '^nazgul/in-flight/' || true; }
  _route_add() { _rgit "$1" add -A >/dev/null 2>&1; _rgit "$1" diff --cached --name-only 2>/dev/null | grep -c '^nazgul/in-flight/' || true; }
  _route_ignored() { _rgit "$1" check-ignore -v -- "$2" >/dev/null 2>&1; printf '%s' "$?"; }
  _route_pattern() { _rgit "$1" check-ignore -v -- "$2" 2>/dev/null | awk -F'\t' '{print $1}' | cut -d: -f3-; }

  # Staging is probed BEFORE add: `git add -A` moves the markers out of --others.
  R_GREEN_REPO="$ROUTES/green-repo"; _routes_repo "$R_GREEN_REPO" "$ROUTES/green.gitignore"
  R_G_IGN=$(_route_ignored "$R_GREEN_REPO" nazgul/in-flight/m.json)
  R_G_CHILD=$(_route_ignored "$R_GREEN_REPO" nazgul/in-flight/quarantine/q.json)
  R_G_CHILD_PAT=$(_route_pattern "$R_GREEN_REPO" nazgul/in-flight/quarantine/q.json)
  R_G_STAGE=$(_route_staging "$R_GREEN_REPO")
  R_G_ADD=$(_route_add "$R_GREEN_REPO")
  assert_eq "P2 route 3/3 the rule itself: git check-ignore -v nazgul/in-flight/m.json exits 0" "$R_G_IGN" "0"
  assert_eq "P2 child path: git check-ignore -v nazgul/in-flight/quarantine/q.json exits 0" "$R_G_CHILD" "0"
  assert_eq "P2 child path: cited by the DIRECTORY line, so the swept-over quarantine markers need no entry of their own" \
    "$R_G_CHILD_PAT" "nazgul/in-flight/"
  assert_eq "P2 route 2/3 AFK SessionEnd staging (scripts/session-staging.sh:135's exact command): lists nothing under nazgul/in-flight/" \
    "$R_G_STAGE" "0"
  assert_eq "P2 route 1/3 blanket add: git add -A stages nothing under nazgul/in-flight/" "$R_G_ADD" "0"

  # The permanent RED control. Its 2s are what make the three 0s above a real zero
  # rather than a filter that could never have matched anything.
  R_RED_REPO="$ROUTES/red-repo"; _routes_repo "$R_RED_REPO" "$ROUTES/red.gitignore"
  R_R_IGN=$(_route_ignored "$R_RED_REPO" nazgul/in-flight/m.json)
  R_R_CHILD=$(_route_ignored "$R_RED_REPO" nazgul/in-flight/quarantine/q.json)
  R_R_STAGE=$(_route_staging "$R_RED_REPO")
  R_R_PATHSPEC=$(_rgit "$R_RED_REPO" ls-files --others --exclude-standard -- 'nazgul/in-flight/' 2>/dev/null | grep -c . || true)
  R_R_ADD=$(_route_add "$R_RED_REPO")
  assert_eq "P2 CONTROL 3/3: against a block missing nazgul/in-flight/, check-ignore exits 1" "$R_R_IGN" "1"
  assert_eq "P2 CONTROL child path: and the quarantine child is exposed with it" "$R_R_CHILD" "1"
  assert_eq "P2 CONTROL 2/3: the staging route then lists both markers" "$R_R_STAGE" "2"
  assert_eq "P2 CONTROL 1/3: and git add -A then stages both" "$R_R_ADD" "2"
  # F5 measured in place: the trailing slash empties a WILDCARD pathspec, but not a
  # literal directory one — which is what licenses _names_dir_token's either-form check.
  assert_eq "P2 F5: on a literal directory the trailing-slash pathspec still matches both markers" \
    "$R_R_PATHSPEC" "2"
else
  _skip "P1 structure and P2 routes (the shared-mode fence could not be extracted — reported as a finding above)"
fi

if _block_has_line "nazgul/in-flight/"; then
  _pass "P1 subject: 'nazgul/in-flight/' is an exact line of the shared-mode block"
else
  _fail "P1 subject: 'nazgul/in-flight/' is an exact line of the shared-mode block" \
    "the block no longer contains its own #251 subject"
fi

R_OUTSIDE=0
while IFS= read -r r_ln; do
  [ -n "$r_ln" ] || continue
  _in_block_region "$r_ln" || R_OUTSIDE=$((R_OUTSIDE + 1))
done < <(grep -n 'nazgul/in-flight' "$SWEEP_ROOT/$INIT_SKILL" | cut -d: -f1)
if [ "$R_OUTSIDE" -ge 1 ]; then
  _pass "P1 scope: $R_OUTSIDE mention(s) of nazgul/in-flight sit outside every gitignore fence, so the block-scoped check above cannot be satisfied by them"
else
  _fail "P1 scope: at least one mention of nazgul/in-flight sits outside the fences" \
    "found $R_OUTSIDE — with none, a file-wide grep and the block-scoped check are the same assertion and P3's Step 4 halves cannot hold"
fi

R_DETECT_N=$(grep -c 'git ls-files nazgul/' "$SWEEP_ROOT/$INIT_SKILL" || true)
assert_eq "P3 anchor: Step 4's detection command is found by content, exactly once" "$R_DETECT_N" "1"
R_DETECT=$(grep -m1 'git ls-files nazgul/' "$SWEEP_ROOT/$INIT_SKILL" || true)
R_RM_R=$(_join_cmd 'git rm -r --cached')
R_RM_GLOB=$(_join_cmd 'git rm --cached --ignore-unmatch --')
assert_contains "P3 anchor: the detection command reaches its last entry" "$R_DETECT" "nazgul/learning/.last-run"
assert_contains "P3 join: the -r remedy is joined across its continuations to its last entry" \
  "$R_RM_R" "nazgul/learning/.last-run"
assert_contains "P3 join: the pathspec-glob remedy is joined to its last entry, so the absence below is a real absence" \
  "$R_RM_GLOB" "nazgul/reviews/post-loop-simplify-report.md"

_assert_named() {
  local label="$1" hay="$2" tok="$3" want="$4" got="no"
  _names_dir_token "$hay" "$tok" && got="yes"
  assert_eq "$label" "$got" "$want"
}
_assert_named "P3 detection: Step 4's git ls-files probe names nazgul/in-flight" "$R_DETECT" "nazgul/in-flight" "yes"
_assert_named "P3 remedy: the git rm -r one-shot names nazgul/in-flight, where a directory belongs" \
  "$R_RM_R" "nazgul/in-flight" "yes"
_assert_named "P3 remedy: and the pathspec-glob one-shot does NOT — a detector with no remedy and a remedy no detector triggers are separate defects" \
  "$R_RM_GLOB" "nazgul/in-flight" "no"

_fenced_lines "$LOCAL_MARKER" > "$ROUTES/local.raw"
assert_eq "P3 local block: the local-mode fence is its marker plus three entries" \
  "$(wc -l < "$ROUTES/local.raw" | tr -d ' ')" "4"
R_SHA_TOOL="none"
command -v sha256sum >/dev/null 2>&1 && R_SHA_TOOL="sha256sum"
[ "$R_SHA_TOOL" = "none" ] && command -v shasum >/dev/null 2>&1 && R_SHA_TOOL="shasum"
if [ "$R_SHA_TOOL" = "none" ]; then
  _fail "P3 local block: a sha256 tool (sha256sum or shasum) is on PATH" \
    "neither resolves — an empty digest must not be able to read as agreement"
else
  _pass "P3 local block: hashed with $R_SHA_TOOL"
fi
assert_eq "P3 local block: byte-identical to 0738a1a, whitespace included" \
  "$(_sha256 < "$ROUTES/local.raw")" "$LOCAL_FENCE_SHA_BASE"

findings=$((findings + TESTS_FAILED - R_FAILED_BEFORE))
fi

# A sibling region to the P1/P2/P3 arms, reusing their extractions ($R_DETECT, $R_RM_R,
# $R_RM_GLOB) under the same guard: one comparison per copy, never two rival ones.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip 'P3 copy-sync arms (inner run under an injected sweep root: the $R_DETECT/$R_RM_R/$R_RM_GLOB these arms compare against are assigned only inside the P1/P2/P3 region above, which the same guard skipped)'
else
C_FAILED_BEFORE=$TESTS_FAILED
CLEAN_ANCHOR='Remove the \*\*shared-mode ephemeral\*\* block'

# Members of $1 absent from $2, space-joined; "" is agreement. Each disagreement
# names itself, so a failure says which entry drifted rather than only that one did.
_only_in() {
  local t out=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf '%s\n' "$2" | grep -Fxq -- "$t" || out="$out $t"
  done <<INNER
$1
INNER
  printf '%s' "${out# }"
}

# Copies 1 and 2 are pathspec lists, so both sides drop a trailing slash: that is F5
# for the wildcard entries, and either-form tolerance for the literal directory ones.
_norm_pathspec() { printf '%s\n' "$1" | sed 's:/$::' | sort -u; }

# Whitespace-split, shell quotes and the `\` continuation dropped, then narrowed to
# nazgul/ paths — the flags and the git subcommand are not part of any copy.
_cmd_paths() { printf '%s' "$1" | tr ' \t' '\n\n' | sed "s/^['\"]//; s/['\"]\$//" | grep '^nazgul/' | sort -u; }

# The detection bullet ALSO quotes nazgul/context.backup.*/ in prose as the form that
# matches nothing, so the command is read from its own code span, never from the line.
_code_span() {
  awk -v pat="$1" '{ n = split($0, p, "`"); for (i = 2; i <= n; i += 2) if (index(p[i], pat) == 1) { print p[i]; exit } }' <<< "$2"
}

C_ENTRIES=$(printf '%s\n' "$BLOCK" | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u)
C_ENTRY_N=$(printf '%s\n' "$C_ENTRIES" | grep -c . || true)
if [ "$C_ENTRY_N" -gt 0 ]; then
  _pass "P3 copies: the block yields $C_ENTRY_N entr(ies) for the three copies to be compared against"
else
  _fail "P3 copies: the block yields at least one entry to compare the copies against" \
    "no non-comment line follows the marker — all six comparisons below would report agreement on an empty set"
fi

# The comparator's own control: without it, six "" results are equally consistent with
# three synced copies and with a comparator that can only ever return "".
assert_eq "P3 copies CONTROL: the comparator names a member the other side lacks" \
  "$(_only_in "alpha
beta" "alpha")" "beta"
assert_eq "P3 copies CONTROL: and returns empty only when every member is present" \
  "$(_only_in "alpha" "alpha
beta")" ""

C_WANT_PS=$(_norm_pathspec "$C_ENTRIES")
C_P1_RAW=$(_cmd_paths "$(_code_span 'git ls-files nazgul/' "$R_DETECT")")
C_P2_RAW=$(_cmd_paths "$R_RM_R
$R_RM_GLOB")
C_P1=$(_norm_pathspec "$C_P1_RAW")
C_P2=$(_norm_pathspec "$C_P2_RAW")

assert_eq "P3 copy 1 (init Step 4 git ls-files detection): every block entry is named" \
  "$(_only_in "$C_WANT_PS" "$C_P1")" ""
assert_eq "P3 copy 1 (init Step 4 git ls-files detection): and it names nothing the block lacks" \
  "$(_only_in "$C_P1" "$C_WANT_PS")" ""
assert_eq "P3 copy 2 (init Step 4 git rm remedy, both one-shots): every block entry is named" \
  "$(_only_in "$C_WANT_PS" "$C_P2")" ""
assert_eq "P3 copy 2 (init Step 4 git rm remedy, both one-shots): and they name nothing the block lacks" \
  "$(_only_in "$C_P2" "$C_WANT_PS")" ""

# F5 as TASK-009 measured it, not as it was first recorded: `*/` empties a WILDCARD
# pathspec, while a literal directory pathspec matches either way and stays untouched.
C_WILD_N=$(printf '%s\n%s\n' "$C_P1_RAW" "$C_P2_RAW" | grep -c '\*' || true)
if [ "$C_WILD_N" -gt 0 ]; then
  _pass "P3 copies F5: $C_WILD_N wildcard pathspec(s) across copies 1 and 2 for the slash rule to bind on"
else
  _fail "P3 copies F5: at least one wildcard pathspec exists across copies 1 and 2" \
    "none found — the trailing-slash rule below would pass on an empty match"
fi
C_WILD_SLASH=$(printf '%s\n%s\n' "$C_P1_RAW" "$C_P2_RAW" | grep '\*' | grep '/$' | sort -u | tr '\n' ' ' || true)
assert_eq "P3 copies F5: no wildcard pathspec in copies 1 or 2 carries the block's trailing slash" \
  "${C_WILD_SLASH% }" ""

if [ -r "$SWEEP_ROOT/$CLEAN_SKILL" ]; then
  _pass "P3 copy 3 anchor: $CLEAN_SKILL is readable"
else
  _fail "P3 copy 3 anchor: $CLEAN_SKILL is readable" \
    "absent or unreadable under $SWEEP_ROOT — a third copy that was never read must not report as one that agreed"
fi
C_CLEAN_N=$(grep -c "$CLEAN_ANCHOR" "$SWEEP_ROOT/$CLEAN_SKILL" 2>/dev/null || true)
assert_eq "P3 copy 3 anchor: Step 8's shared-mode item is found by content, exactly once" "$C_CLEAN_N" "1"
C_CLEAN_LINE=$(grep -m1 "$CLEAN_ANCHOR" "$SWEEP_ROOT/$CLEAN_SKILL" 2>/dev/null || true)
C_P3=$(printf '%s\n' "$C_CLEAN_LINE" | grep -oE '`[^`]+`' | tr -d '`' | grep '^nazgul/' | sort -u || true)

# Copy 3 quotes the .gitignore LINES rather than pathspecs, so it is compared verbatim:
# the trailing slash is part of the line it tells /nazgul:clean to delete.
assert_eq "P3 copy 3 (clean Step 8 item 3): every block entry is listed, verbatim" \
  "$(_only_in "$C_ENTRIES" "$C_P3")" ""
assert_eq "P3 copy 3 (clean Step 8 item 3): and it lists nothing the block lacks" \
  "$(_only_in "$C_P3" "$C_ENTRIES")" ""

findings=$((findings + TESTS_FAILED - C_FAILED_BEFORE))
fi

# The unresolvable and block-region tallies are path-level, not file-level: one
# file can hold both kinds, so neither can live in M without breaking N == M + K.
RC=0
report_results || RC=1
printf 'paths: %d enumerated, %d declared, %d undeclared, %d unresolvable, %d block-region-excluded\n' \
  "$enumerated_count" "$declared_count" "$undeclared" "$unresolvable" "$block_excluded"
printf '%s: %d scanned, %d skipped (no-nazgul-path=%d, unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$scanned" "$((skipped_no_path + skipped_unreadable))" \
  "$skipped_no_path" "$skipped_unreadable" "$checked" "$findings"
exit "$RC"
