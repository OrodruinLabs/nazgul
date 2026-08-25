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
# source in BOTH directions, so the hand-maintained half cannot drift either; A4
# searches the writer-instructing half of that population alone, because an
# append-only RECORD names a path forever and would make it unfalsifiable.
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
# The population is every tree that can INSTRUCT A WRITER, not every tree that names a path:
# an instruction file, a hook config or a CI workflow can each introduce a real producer (#254 C4).
SOURCE_DIRS="scripts skills agents templates references hooks .github"
# These four instruct the operator. docs/ is excluded on measurement — 30 files, 375 occurrences,
# 24 keys, 6 undeclared and NOT ONE of the six with a producer (four are not project paths at all).
SOURCE_FILES="CLAUDE.md RULES.md README.md CHANGELOG.md"
# A1 keeps sweeping these; A4's comparison set alone drops them, because an append-only RECORD names
# a path forever and a row whose last writer was deleted could otherwise never read as stale (#254 C-d).
RECORD_ONLY_FILES="CHANGELOG.md"
# Residual risk of that one exclusion: a design doc naming a runtime path before its writer lands is
# unswept — but the writer itself always lands above, so the path is caught once it can be written.
INIT_SKILL="skills/init/SKILL.md"
CLEAN_SKILL="skills/clean/SKILL.md"
# Sentinels are matched by PREFIX, never as an exact line: the shipped start line carries a
# ` (vN)` stamp and a pre-stamp install carries none, so exact matching reads a v1 block as absent.
BLOCK_MARKER="# Nazgul Framework — ephemeral runtime"
BLOCK_END="# Nazgul Framework — end ephemeral runtime"
LOCAL_MARKER="# Nazgul Framework (local mode)"
LOCAL_END="# Nazgul Framework — end local mode"

# Family 1 is the literal `nazgul/<seg>`; family 2 is the variable-rooted shape
# ($NAZGUL_DIR/<seg>), which is dominant and carries no literal for family 1.
OCC_RE='nazgul/[^[:space:]'"'"'"`]*|\$\{?[Nn][Aa][Zz][Gg][Uu][Ll]_[Dd][Ii][Rr]\}?/[^[:space:]'"'"'"`]*'
TRAIL_PUNCT='.,;)}"'"'"'`'
# The characters after which a path CONTINUES with content the sweep cannot know — a substitution,
# a brace, a glob, a `<placeholder>`. Every other non-literal character ends the token instead.
VAR_INTRO='${*?<'

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
nazgul/scratch|record|-|Prose illustration of a USER pattern that the legacy fallback would consume (skills/init/SKILL.md, ownership rule); nothing writes it, so it must never be a block line
nazgul/notes.md|record|-|The file-shaped half of the same illustration; a user path indistinguishable by shape from a block entry is the residual that rule records, and ignoring it would delete the very content the warning is about
nazgul/pull|record|-|The tail of a github.com/OrodruinLabs/nazgul/pull/<n> PR URL in skills/complete/SKILL.md:15, not a project path at all; nothing writes it, so it must never be a block line
nazgul/.nazgul-plan.XXXXXX|ephemeral|nazgul/.nazgul-plan.*|The mktemp template scripts/stamp-plan-objective.sh:149 writes plan.md through; a transient scratch file with a random suffix, the same shape as the nazgul/config.json.tmp row above
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
nazgul/learning|ephemeral|nazgul/learning/.last-run|Transient autolearning working file
nazgul/context.backup.*|ephemeral|nazgul/context.backup.*/|Timestamped local snapshot of the tracked nazgul/context/, made on re-run by /nazgul:discover
nazgul/.nazgul-plan.*|ephemeral|nazgul/.nazgul-plan.*|The wildcard form of the row above, which is what the block line and the Step 4 pathspecs must spell: the mktemp suffix is random, so a literal key can never be the pattern. Two keys because the writer names the template and the block names the glob'

# A1-A4 increment `findings` directly; the dogfood, P1/P2/P3 and copy-sync regions raise
# TESTS_FAILED instead, and each folds its own delta in as it closes, before the next baseline.
scanned=0; skipped_no_path=0; skipped_unreadable=0; checked=0; findings=0
unresolvable=0; block_excluded=0; record_only=0
KEY_HITS=""
BLOCK_REGIONS=""

# A segment is UNRESOLVABLE only when its LITERAL PREFIX is empty. Discarding a whole occurrence
# on the first non-literal byte is what left nazgul/context.backup.*/ unpinnable (#254 C1).
_resolve_segment() {
  local s="$1" last prefix nxt
  while [ -n "$s" ]; do
    last="${s: -1}"
    case "$TRAIL_PUNCT" in *"$last"*) s="${s%?}" ;; *) break ;; esac
  done
  [ -n "$s" ] || return 1
  prefix="${s%%[!A-Za-z0-9._-]*}"
  [ -n "$prefix" ] || return 1
  if [ "$prefix" = "$s" ]; then RESOLVED="$s"; return 0; fi
  # Which key the prefix earns is decided by the byte that ENDED it, never by the prefix alone:
  # `config.json|__DROP__` is a table cell holding a whole path, `context.backup.$(date` is not.
  nxt="${s:${#prefix}:1}"
  case "$VAR_INTRO" in *"$nxt"*) RESOLVED="$prefix*" ;; *) RESOLVED="$prefix" ;; esac
  return 0
}

# The two ```gitignore fences inside the init skill are the block regions: without
# excluding them the block would enumerate precisely what it ignores.
_compute_block_regions() {
  local f="$SWEEP_ROOT/$INIT_SKILL"
  [ -r "$f" ] || return 0
  # Leading whitespace is stripped before matching here and in both extractors below on purpose:
  # every block installed before the de-indent is indented on disk, and removal must still read it.
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

# Region = start sentinel through end sentinel. The closing fence stays as the v1 legacy
# terminator, and _block_terminator below names which one was hit rather than degrading silently.
_extract_block() {
  local f="$SWEEP_ROOT/$INIT_SKILL"
  [ -r "$f" ] || return 0
  awk -v marker="$BLOCK_MARKER" -v endm="$BLOCK_END" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    !inb && index(line, marker) == 1 { inb = 1; next }
    inb && (line == endm || line == "```") { exit }
    inb { print line }
  ' "$f"
}

_block_terminator() {
  local f="$SWEEP_ROOT/$INIT_SKILL"
  [ -r "$f" ] || { printf 'unreadable'; return 0; }
  awk -v marker="$BLOCK_MARKER" -v endm="$BLOCK_END" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    !inb && index(line, marker) == 1 { inb = 1; next }
    inb && line == endm { print "end-sentinel"; hit = 1; exit }
    inb && line == "```" { print "closing-fence"; hit = 1; exit }
    END { if (!hit) print (inb ? "eof" : "no-marker") }
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
# An absent root file is skipped rather than counted: the dogfood fixtures below build a scan root
# out of two directories, and a missing CHANGELOG.md there is not an unreadable one.
for s in $SOURCE_FILES; do
  [ -f "$SWEEP_ROOT/$s" ] || continue
  scan_file "$SWEEP_ROOT/$s"
done

FIRST_HIT=$(printf '%s' "$KEY_HITS" | awk -F'|' 'NF && !seen[$1]++')
ENUM_KEYS=$(printf '%s' "$FIRST_HIT" | cut -d'|' -f1 | sort -u)
DECL_KEYS=$(printf '%s\n' "$DECLARATIONS" | cut -d'|' -f1 | sort -u)
enumerated_count=$(printf '%s' "$ENUM_KEYS" | grep -c . || true)
declared_count=$(printf '%s' "$DECL_KEYS" | grep -c . || true)

# The direction split (#254 C-d): every occurrence above is still enumerated for A1, and the
# record-only files are dropped from THIS set alone — tallied as they go, never silently discarded.
A4_SOURCE_FILES=""
for s in $SOURCE_FILES; do
  case " $RECORD_ONLY_FILES " in *" $s "*) continue ;; esac
  A4_SOURCE_FILES="$A4_SOURCE_FILES $s"
done
A4_SOURCE_FILES="${A4_SOURCE_FILES# }"
PRODUCER_HITS="$KEY_HITS"
for s in $RECORD_ONLY_FILES; do
  record_only=$((record_only + $(printf '%s' "$PRODUCER_HITS" | grep -cF -- "|$s:" || true)))
  PRODUCER_HITS=$(printf '%s' "$PRODUCER_HITS" | grep -vF -- "|$s:" || true)
done
PRODUCED_KEYS=$(printf '%s' "$PRODUCER_HITS" | cut -d'|' -f1 | sort -u)

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
  if printf '%s' "$PRODUCED_KEYS" | grep -Fxq -- "$key"; then continue; fi
  stale=$((stale + 1)); findings=$((findings + 1))
  _fail "A4 stale-declaration: $key is declared but no writer still names it" \
    "no occurrence under $SWEEP_ROOT/{$(printf '%s %s' "$SOURCE_DIRS" "$A4_SOURCE_FILES" | tr ' ' ',')} — a removed writer must retire its declaration"
done <<EOF
$DECL_KEYS
EOF
[ "$stale" -eq 0 ] && _pass "A4 stale-declaration: all $declared_count declared key(s) are still named by a writer ($record_only record-only occurrence(s) excluded)"

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

# One predicate for the single mktemp -d site, for its routes subtree and for C7's control below: a
# second, independently written test would be the divergence the SWEEP_ROOT disposition above avoids.
_scratch_usable() { [ -n "${1:-}" ] && [ -d "$1" ]; }

# Removal is guarded on a non-empty value, so a trap installed before a failed mktemp -d
# cannot degrade to `rm -rf ""`.
_rm_scratch() { local d; for d in "$@"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }

# MISSING, never an empty string: a field these cannot find must fail an assertion
# rather than silently compare equal to another absent field.
_run_findings() {
  printf '%s\n' "$1" | awk '/, [0-9]+ findings$/ { f = $(NF - 1) } END { print (f == "" ? "MISSING" : f) }'
}

_run_paths_field() {
  printf '%s\n' "$1" | awk -v want="$2" '
    /^paths: / { sub(/^paths: /, ""); n = split($0, p, ", ")
      for (i = 1; i <= n; i++) { split(p[i], kv, " "); if (kv[2] == want) { print kv[1]; f = 1 } } }
    END { if (!f) print "MISSING" }'
}

# ONE tree for every region that writes a fixture, created before the FIRST of them rather than in a
# branch of the first: the dogfood region has three branches and only its third assigned SCRATCH,
SCRATCH=""
# while P0, routes and copy-sync are guarded on NAZGUL_IGNORE_SWEEP_ROOT alone and reached it on the
# other two, unbound under `set -u` (#254 C-l). An unusable tree is a REPORTED finding every
SCRATCH_USABLE=0
# dependent region skips — never `exit 1`, which would end the run before the coverage line this
# file is §15 entry point eleven for (#254 C-b), and never "", which is C7's root-relative /x.
if [ -z "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-ignore-sweep-XXXXXX" 2>/dev/null) || SCRATCH=""
  if _scratch_usable "$SCRATCH"; then
    trap '_rm_scratch "$SCRATCH"' EXIT
    mkdir -p "$SCRATCH/routes/home" 2>/dev/null || true
    _scratch_usable "$SCRATCH/routes/home" && SCRATCH_USABLE=1
  fi
  if [ "$SCRATCH_USABLE" -ne 1 ]; then
    findings=$((findings + 1))
    _fail "scratch tree: mktemp -d under ${TMPDIR:-/tmp} yields a usable tree" \
      "got '$SCRATCH' — the dogfood, P0, routes and copy-sync regions all write fixtures under it and are SKIPPED below; reported here as one finding so the run still reaches its coverage line"
  fi
fi

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
elif [ "$SCRATCH_USABLE" -ne 1 ]; then
  _skip "dogfood fixtures (no usable scratch tree — reported as a finding above)"
else
# C7 control: the same predicate the scratch site and its routes subtree use, driven both ways — a
# guard that refused everything and one that refused nothing would otherwise read identically.
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
    index(t, m) == 1 { print "   " e }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

_dog_unproduce() {
  local f="$DOG/scripts/producer.sh"
  grep -vF "write_state \"$1\"" "$f" > "$f.new" && mv "$f.new" "$f"
}

# Strikes a path out of the fixture skill's PROSE only, leaving the fences alone: the block entry
# has to survive, or an arm about a retired WRITER would be measuring an A2 finding as well.
_dog_unmention() {
  local f="$DOG/$INIT_SKILL"
  awk -v pat="$1" '
    { t = $0; sub(/^[[:space:]]+/, "", t) }
    !inf && t == "```gitignore" { inf = 1; print; next }
    inf && t == "```" { inf = 0; print; next }
    inf { print; next }
    { while ((p = index($0, pat)) > 0) $0 = substr($0, 1, p - 1) substr($0, p + length(pat)); print }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

# Occurrences outside the fences, so a strike that matched nothing cannot read as a retired writer.
_dog_prose_hits() {
  awk -v pat="$1" '
    { t = $0; sub(/^[[:space:]]+/, "", t) }
    !inf && t == "```gitignore" { inf = 1; next }
    inf && t == "```" { inf = 0; next }
    inf { next }
    { s = $0; while ((p = index(s, pat)) > 0) { n++; s = substr(s, p + length(pat)) } }
    END { print n + 0 }
  ' "$DOG/$INIT_SKILL"
}

_dog_n() { local n; n=$(printf '%s\n' "$1" | grep -cF "FAIL: $2"); printf '%s' "$n"; }

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
BASE_UNRES=$(_run_paths_field "$D_OUT" unresolvable)
BASE_ENUM=$(_run_paths_field "$D_OUT" enumerated)
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
D_FOLD_CLEAN=$(_run_findings "$D_OUT")
D_FOLD_OUT=$(_dog_fold_run); D_FOLD_RC=$?
D_FOLD_PROBE=$(_run_findings "$D_FOLD_OUT")
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
D_FOLD_MUT=$(_run_findings "$D_MUT_OUT")
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
  "A4 stale-declaration: nazgul/x is declared but no writer still names it"
_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C4 clears: restoring the writer clears the stale-declaration finding" "$D_OUT" "$D_RC"

# C-d, A1's side of the split: an append-only RECORD is still swept, so a path named only there is
# still ENUMERATED and still has to carry a declaration. Dropping the file would lose exactly this.
_dog_reset
printf '# Changelog\n- FEAT-999 writes nazgul/recorded-only-dir\n' > "$DOG/CHANGELOG.md"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C-d A1 side: a path named ONLY by the append-only record is enumerated all the same" "$D_OUT" "$D_RC" A1
assert_contains "C-d A1 side: the finding names the record-only path" "$D_OUT" \
  "A1 undeclared: nazgul/recorded-only-dir has no declaration row"
assert_eq "C-d A1 side: and its occurrence is TALLIED as excluded from A4, not dropped unrecorded" \
  "$(_run_paths_field "$D_OUT" record-only-excluded)" "1"

# C-d, A4's side: nazgul/conductor is the finding's own live proof — declared, block entry present,
# sole producer scripts/migrate-config.sh:583. Retire that writer and A4 must fire past the record.
_dog_reset
printf '# Changelog\n- migrate_25_to_26 removed the nazgul/conductor runtime dir\n' > "$DOG/CHANGELOG.md"
D_CD_PROSE_BEFORE=$(_dog_prose_hits "nazgul/conductor")
_dog_unproduce "nazgul/conductor"
_dog_unmention "nazgul/conductor"
assert_eq "C-d A4 side: the fixture really did lose every writer of the path, prose included" \
  "$([ "$D_CD_PROSE_BEFORE" -ge 1 ] && printf 'had-%s' "$D_CD_PROSE_BEFORE" || printf 'had-none')/$(_dog_prose_hits "nazgul/conductor")/$(grep -cF 'write_state "nazgul/conductor"' "$DOG/scripts/producer.sh" || true)" \
  "had-$D_CD_PROSE_BEFORE/0/0"
assert_eq "C-d A4 side: while the block entry the A2 arms read is untouched, so this arm measures one class" \
  "$(grep -cxF 'nazgul/conductor/' "$DOG/$INIT_SKILL" || true)" "1"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "C-d A4 side: a retired writer is reported stale even while the record still names the path" "$D_OUT" "$D_RC" A4
assert_contains "C-d A4 side: the finding names the retired declaration" "$D_OUT" \
  "A4 stale-declaration: nazgul/conductor is declared but no writer still names it"
assert_contains "C-d A4 side: and the message names the population A4 actually searched" "$D_OUT" \
  "CLAUDE.md,RULES.md,README.md} —"
assert_not_contains "C-d A4 side: which does not include the record file A1 still sweeps (that would be C-j's defect here)" \
  "$D_OUT" "README.md,CHANGELOG.md}"

# The split's own control: the same fixture against a copy whose record-only set is EMPTY — the
# pre-change comparison set — must report nothing, or "A4 fired" would also fit a detector that always does.
D_CD_LINE='RECORD_ONLY_FILES="CHANGELOG.md"'
D_CD_MUT="$SCRATCH/no-split"
mkdir -p "$D_CD_MUT" && ln -sfn "$SCRIPT_DIR/lib" "$D_CD_MUT/lib"
awk -v old="$D_CD_LINE" '{ if ($0 == old) print "RECORD_ONLY_FILES=\"\""; else print }' \
  "$SCRIPT_DIR/$TEST_NAME.sh" > "$D_CD_MUT/$TEST_NAME.sh"
assert_eq "C-d CONTROL: this file names the record-only set exactly once, and the mutant empties it in place" \
  "$(grep -cxF -- "$D_CD_LINE" "$SCRIPT_DIR/$TEST_NAME.sh" || true)/$(grep -cxF -- "$D_CD_LINE" "$D_CD_MUT/$TEST_NAME.sh" || true)/$(( $(wc -l < "$SCRIPT_DIR/$TEST_NAME.sh") - $(wc -l < "$D_CD_MUT/$TEST_NAME.sh") ))" \
  "1/0/0"
assert_eq "C-d CONTROL: and the emptied set is the only difference, so a mutant that failed to apply cannot read as agreement" \
  "$(grep -cxF -- 'RECORD_ONLY_FILES=""' "$D_CD_MUT/$TEST_NAME.sh" || true)" "1"
D_CD_OUT=$(env NAZGUL_IGNORE_SWEEP_ROOT="$DOG" bash "$D_CD_MUT/$TEST_NAME.sh" 2>&1); D_CD_RC=$?
_dog_clear "C-d CONTROL: without the direction split the very same fixture reports nothing at all" "$D_CD_OUT" "$D_CD_RC"

_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "C-d clears: restoring the writer clears the stale-declaration finding" "$D_OUT" "$D_RC"

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

# One token per member of $VAR_INTRO plus the all-punctuation case: an EMPTY literal prefix is
# unknowable and must stay unresolvable, or the prefix rule starts inventing keys (#254 C1).
_dog_reset
printf 'nazgul/$SOMEVAR\nnazgul/<name>\nnazgul/**\nnazgul/{a,b}\nnazgul/?x\nnazgul/...\n' > "$DOG/scripts/unresolvable.sh"
D_OUT=$(_dog_run); D_RC=$?
assert_eq "S4: all six unresolvable tokens move the tally, none silently dropped" \
  "$(_run_paths_field "$D_OUT" unresolvable)" "$((BASE_UNRES + 6))"
assert_eq "S4: and none of them is reported as a path" \
  "$(_run_paths_field "$D_OUT" enumerated)" "$BASE_ENUM"
_dog_clear "S4: an unresolvable token is counted, not a finding" "$D_OUT" "$D_RC"

# S5/S6 are S4's other half: a NON-empty literal prefix earns a key, and which key it earns is
# decided by the byte that ended it. Read out through A1, exactly as S1-S3 are.
_dog_reset
printf '#!/usr/bin/env bash\ncp -r nazgul/context "nazgul/novel.backup.$(date +%%Y%%m%%d)"\n' > "$DOG/scripts/wild.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "S5 literal-prefixed write (skills/discover/SKILL.md:43's own shape)" "$D_OUT" "$D_RC" A1
assert_contains "S5: the resolvable prefix earns a wildcard key instead of being discarded whole" "$D_OUT" \
  "A1 undeclared: nazgul/novel.backup.* has no declaration row"
assert_eq "S5: and it is one key, not one per timestamp the writer could produce" \
  "$(_run_paths_field "$D_OUT" enumerated)" "$((BASE_ENUM + 1))"

_dog_reset
printf '#!/usr/bin/env bash\nRULES=("nazgul/terminated-dir|__DROP__")\n' > "$DOG/scripts/term.sh"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "S6 delimiter-terminated write (scripts/lib/bootstrap-scrub-map.sh:19's own shape)" "$D_OUT" "$D_RC" A1
assert_contains "S6: a byte that ENDS the token yields the exact path the table cell holds" "$D_OUT" \
  "A1 undeclared: nazgul/terminated-dir has no declaration row"
assert_not_contains "S6: never the wildcard form, which no .gitignore line for that path would match" \
  "$D_OUT" "nazgul/terminated-dir*"

# P12 — the pin that would have caught #251 the day nazgul/in-flight/ was introduced.
_dog_reset
_dog_block_drop "nazgul/in-flight/"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "P12 #251: a block that no longer contains its own subject" "$D_OUT" "$D_RC" A2
assert_contains "P12: the finding names nazgul/in-flight/" "$D_OUT" \
  "A2 unignored: 'nazgul/in-flight/' is absent from the shared-mode block"

# P13 is P12 for the one path the sweep used to be structurally unable to protect: at 0bef561 this
# same deletion produced 0 findings and exit 0, because no key was ever enumerated to compare.
_dog_reset
_dog_block_drop "nazgul/context.backup.*/"
D_OUT=$(_dog_run); D_RC=$?
_dog_only "P13 #254 C1: a block that no longer contains its literal-prefixed entry" "$D_OUT" "$D_RC" A2
assert_contains "P13: the finding names nazgul/context.backup.*/" "$D_OUT" \
  "A2 unignored: 'nazgul/context.backup.*/' is absent from the shared-mode block"

# C-k: C1's BEFORE state, permanently in-file and driven, where it was a hand reproduction inside a
# task manifest no run ever executes — the C3 fold CONTROL idiom, on this file's headline claim.
K_DECL_ROW='nazgul/context.backup.*|ephemeral|'
K_NXT_LINE='  nxt="${s:${#prefix}:1}"'
K_CASE_LINE='  case "$VAR_INTRO" in *"$nxt"*) RESOLVED="$prefix*" ;; *) RESOLVED="$prefix" ;; esac'
# BOTH halves go at once: with either alive the other still reports P13's finding. The declaration
# row is blanked to its closing quote, not deleted — that row carries the DECLARATIONS terminator.
K_MUT="$SCRATCH/pre-c1"
mkdir -p "$K_MUT" && ln -sfn "$SCRIPT_DIR/lib" "$K_MUT/lib"
awk -v row="$K_DECL_ROW" -v q="'" -v nxt="$K_NXT_LINE" -v cse="$K_CASE_LINE" '
  index($0, row) == 1 { print q; if (substr($0, length($0)) != q) intail = 1; next }
  intail == 1 { if (substr($0, length($0)) == q) intail = 0; next }
  $0 == nxt { next }
  $0 == cse { print "  return 1"; next }
  { print }
' "$SCRIPT_DIR/$TEST_NAME.sh" > "$K_MUT/$TEST_NAME.sh"
# Counted by the mutation's OWN predicate, never by a second one: the row's literal also appears in
# the K_DECL_ROW assignment three lines up, which the mutation deliberately leaves alone.
_k_rows() { awk -v row="$K_DECL_ROW" 'index($0, row) == 1 { n++ } END { print n + 0 }' "$1"; }
assert_eq "C-k CONTROL: this file states each mutated site exactly once, and the mutant states neither" \
  "$(_k_rows "$SCRIPT_DIR/$TEST_NAME.sh")/$(grep -cxF -- "$K_CASE_LINE" "$SCRIPT_DIR/$TEST_NAME.sh" || true)::$(_k_rows "$K_MUT/$TEST_NAME.sh")/$(grep -cxF -- "$K_CASE_LINE" "$K_MUT/$TEST_NAME.sh" || true)" \
  "1/1::0/0"
# The blanking truncates DECLARATIONS at K_DECL_ROW, so it removes that row AND every row after
# it — the wildcard tail. Deleted lines = (tail rows - 1 folded into the printed quote) + the
# resolver's nxt line = exactly the tail size. Derived, so adding a wildcard row cannot silently
# skew it; the arm below asserts the resulting mutant still parses and runs.
K_TAIL_ROWS=$(printf '%s\n' "$DECLARATIONS" | awk -v row="$K_DECL_ROW" 'index($0, row) == 1 { f = 1 } f { n++ } END { print n + 0 }')
assert_eq "C-k CONTROL: the wildcard tail the blanking truncates is measured, not assumed" \
  "$([ "$K_TAIL_ROWS" -ge 1 ] && echo yes || echo no)" "yes"
assert_eq "C-k CONTROL: the mutant is exactly the wildcard tail shorter — those rows plus the resolver's nxt line, the only deletions" \
  "$(( $(wc -l < "$SCRIPT_DIR/$TEST_NAME.sh") - $(wc -l < "$K_MUT/$TEST_NAME.sh") ))" "$K_TAIL_ROWS"
assert_eq "C-k CONTROL: with the prefix branch replaced by the pre-change discard, so a mutant that failed to apply cannot read as agreement" \
  "$(grep -cxF -- '  return 1' "$K_MUT/$TEST_NAME.sh" || true)" \
  "$(( $(grep -cxF -- '  return 1' "$SCRIPT_DIR/$TEST_NAME.sh" || true) + 1 ))"
K_OUT=$(env NAZGUL_IGNORE_SWEEP_ROOT="$DOG" bash "$K_MUT/$TEST_NAME.sh" 2>&1); K_RC=$?
_dog_clear "C-k: before C1, the very fixture P13 just failed on reported nothing at all" "$K_OUT" "$K_RC"
# Two, not one: the mutant discards every PARTIAL-LITERAL occurrence, and the tail of
# DECLARATIONS now carries two such keys — nazgul/context.backup.* and nazgul/.nazgul-plan.*.
# Both are truncated away by the same blanking, so neither leaves a stale declaration behind.
K_WILDCARD_KEYS=$(printf '%s\n' "$DECL_KEYS" | grep -c '\*$' || true)
assert_eq "C-k CONTROL: the wildcard-key count the delta below is built on is measured, not assumed" \
  "$K_WILDCARD_KEYS" "2"
assert_eq "C-k: because the entry had no key to compare against — the occurrence was discarded whole, not resolved" \
  "$(_run_paths_field "$K_OUT" enumerated)/$(printf '%s\n' "$K_OUT" | grep -c 'context.backup' || true)" \
  "$((BASE_ENUM - K_WILDCARD_KEYS))/0"

_dog_reset
D_OUT=$(_dog_run); D_RC=$?
_dog_clear "P13 clears: restoring the block entry clears the unignored finding" "$D_OUT" "$D_RC"
fi
findings=$((findings + TESTS_FAILED - D_FAILED_BEFORE))

# The committed mode, not the working-tree one: `cp` over a checked-out file leaves the mode
# alone, so only the index says whether this file's own `./tests/…` dogfood idiom can run.
M_FAILED_BEFORE=$TESTS_FAILED
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip "committed-mode pin (inner run under an injected sweep root: \$REPO_ROOT is the fixture's parent, not a checkout tracking this file)"
else
M_MODE=$(git -C "$REPO_ROOT" ls-files -s -- "tests/$TEST_NAME.sh" 2>/dev/null | awk '{print $1}')
if [ -z "$M_MODE" ]; then
  _fail "C8 mode: git reports a committed mode for tests/$TEST_NAME.sh" \
    "git ls-files -s named nothing under $REPO_ROOT — a mode that could not be read must not stand in for an executable one"
else
  assert_eq "C8 mode: committed 100755, so ./tests/$TEST_NAME.sh runs instead of giving permission denied" \
    "$M_MODE" "100755"
fi
fi
findings=$((findings + TESTS_FAILED - M_FAILED_BEFORE))

# P0 pins the SOURCE's flush-left property and its region contract, which P2's git arms can only
# observe indirectly. Skipped on an inner run: _dog_block_add indents its insert on purpose.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip "P0 source-structure pins (inner run under an injected sweep root: the dogfood fixtures indent an inserted entry deliberately, so an indented line there is a fixture, not drift)"
elif [ "$SCRATCH_USABLE" -ne 1 ]; then
  _skip "P0 source-structure pins (no usable scratch tree — reported as a finding above; every control below writes its mutant under it)"
else
S_FAILED_BEFORE=$TESTS_FAILED

# Entries and comments are tallied apart: an indented comment is inert but harmless, while an
# indented ENTRY is #251 itself — one combined number could not say which of the two was found.
_fence_indent_counts() {
  awk -v regions="$2" '
    BEGIN { cnt = split(regions, r, /[[:space:]]+/)
      for (i = 1; i <= cnt; i++) { if (r[i] == "") continue; split(r[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
    {
      inr = 0
      for (i = 1; i <= cnt; i++) if (r[i] != "" && NR >= lo[i] && NR <= hi[i]) inr = 1
      if (!inr) next
      t = $0; sub(/^[[:space:]]+/, "", t)
      if (t == "") { blank++; next }
      ind = ($0 ~ /^[[:space:]]/)
      if (t ~ /^#/) { if (ind) ci++; else cu++ } else { if (ind) ei++; else eu++ }
    }
    END { printf "%d %d %d %d %d\n", ei + 0, eu + 0, ci + 0, cu + 0, blank + 0 }
  ' "$1"
}

# One occurrence must precede EACH fence: a bare file-wide count of two is equally consistent
# with both sentences sitting in the shared branch and neither in the local one.
_flush_per_fence() {
  awk -v phrase="$1" -v regions="$2" '
    BEGIN { cnt = split(regions, r, /[[:space:]]+/)
      for (i = 1; i <= cnt; i++) { if (r[i] == "") continue; split(r[i], b, "-"); open[i] = b[1] - 1 } }
    index($0, phrase) { hits[++h] = NR }
    END {
      for (k = 1; k <= h; k++) {
        best = 0
        for (i = 1; i <= cnt; i++) if (r[i] != "" && open[i] > hits[k] && (best == 0 || open[i] < open[best])) best = i
        if (best) n[best]++
      }
      for (i = 1; i <= cnt; i++) if (r[i] != "") out = out (out == "" ? "" : " ") (n[i] + 0)
      print out
    }
  ' "$3"
}

S_REGIONS=$(printf '%s' "$BLOCK_REGIONS" | tr '\n' ' ')
S_REGION_N=$(printf '%s\n' "$BLOCK_REGIONS" | grep -c . || true)
assert_eq "P0 regions: both \`\`\`gitignore fences of $INIT_SKILL are located" "$S_REGION_N" "2"
read -r S_ENT_IND S_ENT_UN S_COM_IND S_COM_UN S_BLANK <<< "$(_fence_indent_counts "$SWEEP_ROOT/$INIT_SKILL" "$S_REGIONS")"
assert_eq "P0 flush-left: no entry line inside either fence carries leading whitespace (#254 C2)" "$S_ENT_IND" "0"
assert_eq "P0 flush-left: nor does any of the $S_COM_UN interleaved justification comment(s)" "$S_COM_IND" "0"
if [ "$S_ENT_UN" -gt 0 ] && [ "$S_COM_UN" -gt 0 ]; then
  _pass "P0 flush-left floor: the two fences hold $S_ENT_UN entry and $S_COM_UN comment line(s) ($S_BLANK blank), so the two zeros above are measured zeros"
else
  _fail "P0 flush-left floor: the two fences hold at least one entry line and one comment line" \
    "entries=$S_ENT_UN comments=$S_COM_UN — an empty region satisfies an indented==0 assertion vacuously"
fi

# The counter's own control: re-indent the very same lines and it must SEE what it reports zero
# of above, or "indented == 0" is equally consistent with a counter that cannot count.
S_IND_FILE="$SCRATCH/init-indented.md"
awk -v regions="$S_REGIONS" '
  BEGIN { cnt = split(regions, r, /[[:space:]]+/)
    for (i = 1; i <= cnt; i++) { if (r[i] == "") continue; split(r[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
  { inr = 0
    for (i = 1; i <= cnt; i++) if (r[i] != "" && NR >= lo[i] && NR <= hi[i]) inr = 1
    print (inr ? "   " $0 : $0) }
' "$SWEEP_ROOT/$INIT_SKILL" > "$S_IND_FILE"
read -r S_C_ENT_IND S_C_ENT_UN S_C_COM_IND S_C_COM_UN _ <<< "$(_fence_indent_counts "$S_IND_FILE" "$S_REGIONS")"
assert_eq "P0 flush-left CONTROL: re-indenting the same lines moves every entry into the indented tally" \
  "$S_C_ENT_IND/$S_C_ENT_UN" "$S_ENT_UN/0"
assert_eq "P0 flush-left CONTROL: and every comment with them, so neither tally is hard-wired to zero" \
  "$S_C_COM_IND/$S_C_COM_UN" "$S_COM_UN/0"

assert_eq "P0 region: _extract_block terminates at the end sentinel, not at the closing fence" \
  "$(_block_terminator)" "end-sentinel"
S_END_LN=$(awk -v e="$BLOCK_END" '{ t = $0; sub(/^[[:space:]]+/, "", t) } t == e { print NR; exit }' "$SWEEP_ROOT/$INIT_SKILL")
if [ -z "$S_END_LN" ]; then
  _fail "P0 region: the shared-mode block carries its end sentinel" \
    "no line of $INIT_SKILL reads '$BLOCK_END' — without it the region degrades to the v1 legacy fallback"
  S_END_LN=0
else
  _pass "P0 region: the shared-mode end sentinel is present at $INIT_SKILL:$S_END_LN"
fi
S_END_IN="no"; _in_block_region "$S_END_LN" && S_END_IN="yes"
assert_eq "P0 region: and it sits inside a fence, not in the prose that describes the region" "$S_END_IN" "yes"
S_AFTER_END=$(awk -v n="$S_END_LN" 'NR == n + 1 { t = $0; sub(/^[[:space:]]+/, "", t); print t }' "$SWEEP_ROOT/$INIT_SKILL")
assert_eq "P0 region: the closing fence immediately follows it, so the sentinel is the block's last line" \
  "$S_AFTER_END" '```'

# Prefix, for the reason :42-44 gives for the shared marker: the local start line now carries a
# ` (vN)` stamp too (#254 C-f), and an exact-line match reads a stamped block as ABSENT.
S_LOC_START=$(awk -v e="$LOCAL_MARKER" '{ t = $0; sub(/^[[:space:]]+/, "", t) } index(t, e) == 1 { n++ } END { print n + 0 }' "$SWEEP_ROOT/$INIT_SKILL")
S_LOC_END=$(awk -v e="$LOCAL_END" '{ t = $0; sub(/^[[:space:]]+/, "", t) } index(t, e) == 1 { n++ } END { print n + 0 }' "$SWEEP_ROOT/$INIT_SKILL")
assert_eq "P0 local region: the local-mode block carries its own sentinel pair, once each" \
  "$S_LOC_START/$S_LOC_END" "1/1"

_stamp_suffix() {
  awk -v e="$1" '{ t = $0; sub(/^[[:space:]]+/, "", t) } index(t, e) == 1 { print substr(t, length(e) + 1); exit }' "$2"
}
# Three-way, so a bare pre-stamp line and an unrelated suffix cannot both read as "not stamped".
S_LOC_SUFFIX=$(_stamp_suffix "$LOCAL_MARKER" "$SWEEP_ROOT/$INIT_SKILL")
S_LOC_STAMP="other"
[ -z "$S_LOC_SUFFIX" ] && S_LOC_STAMP="bare-v1"
printf '%s\n' "$S_LOC_SUFFIX" | grep -qE '^ \(v[0-9]+\)$' && S_LOC_STAMP="stamped"
assert_eq "P0 local stamp: the local block's first line carries the (vN) suffix the prefix match above ignores (#254 C-f)" \
  "$S_LOC_STAMP" "stamped"
# Shape, not literal, HERE: the two fences are pinned to each other, and the prose that copies their
# literal is #254 C-g's subject immediately below, which derives the value rather than naming one.
assert_eq "P0 local stamp: and it is the same version the shared block ships, in the two fences that are the authoritative copy" \
  "$S_LOC_SUFFIX" "$(_stamp_suffix "$BLOCK_MARKER" "$SWEEP_ROOT/$INIT_SKILL")"

# #254 C-g. The shipped version is DERIVED from the shared fence's own first line — the copy
# skills/init/SKILL.md:82 calls authoritative — never named here, which would be one more copy.
_shipped_stamp() { _stamp_suffix "$BLOCK_MARKER" "$1" | sed -nE 's/^ \(v([0-9]+)\)$/v\1/p'; }

# Version literals OUTSIDE the fences, bucketed by what each can mean: the derived stamp, the
# permanent pre-stamp class v1, or a THIRD value — a site a bump updated the fence but not the prose for.
_version_buckets() {
  awk -v ship="$1" -v regions="$2" '
    BEGIN { cnt = split(regions, r, /[[:space:]]+/)
      for (i = 1; i <= cnt; i++) { if (r[i] == "") continue; split(r[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
    { inr = 0
      for (i = 1; i <= cnt; i++) if (r[i] != "" && NR >= lo[i] && NR <= hi[i]) inr = 1
      if (inr) next
      n = split($0, w, /[^A-Za-z0-9]+/)
      for (j = 1; j <= n; j++) {
        if (w[j] !~ /^v[0-9]+$/) continue
        if (w[j] == ship) sh++
        else if (w[j] == "v1") lg++
        else { ot++; otl = otl (otl == "" ? "" : " ") w[j] "@" FILENAME ":" NR } } }
    END { printf "%d %d %d %s\n", sh + 0, lg + 0, ot + 0, (otl == "" ? "-" : otl) }
  ' "$3"
}

# scripts/doctor.sh is in the population precisely BECAUSE it names one v2 literal — in the comment
# explaining why it derives the stamp instead of copying it. Covered, never excluded (#254 C-g).
G_SITE_FILES="$INIT_SKILL $CLEAN_SKILL scripts/doctor.sh"
_version_tally() {
  local init="$1" ship="$2" spec f sh=0 lg=0 ot=0 otl="" a b c d
  for f in $G_SITE_FILES; do
    case "$f" in "$INIT_SKILL") spec="$init|$S_REGIONS" ;; *) spec="$SWEEP_ROOT/$f|" ;; esac
    read -r a b c d <<< "$(_version_buckets "$ship" "${spec#*|}" "${spec%%|*}")"
    sh=$((sh + a)); lg=$((lg + b)); ot=$((ot + c))
    [ "$d" = "-" ] || otl="$otl${otl:+ }$d"
  done
  printf '%s %s %s %s' "$sh" "$lg" "$ot" "${otl:--}"
}

G_SITE_N=0
for g_f in $G_SITE_FILES; do [ -r "$SWEEP_ROOT/$g_f" ] && G_SITE_N=$((G_SITE_N + 1)); done
assert_eq "P0 C-g: every file in the version-site population is readable, so an absent one cannot read as a site that agreed" \
  "$G_SITE_N" "3"
G_SHIP=$(_shipped_stamp "$SWEEP_ROOT/$INIT_SKILL")
if [ -n "$G_SHIP" ]; then
  _pass "P0 C-g: the shipped version is DERIVED from the shared fence's first line ($G_SHIP), never named by this pin"
else
  _fail "P0 C-g: the shipped version is DERIVED from the shared fence's first line" \
    "no ' (vN)' suffix on the marker line under $SWEEP_ROOT — with nothing derived, every site below would be compared against the empty string"
  G_SHIP="__underived__"
fi
read -r G_SH G_LG G_OT G_OTL <<< "$(_version_tally "$SWEEP_ROOT/$INIT_SKILL" "$G_SHIP")"
assert_eq "P0 C-g: no prose site across the $G_SITE_N scanned file(s) names a version other than the derived $G_SHIP or the pre-stamp class v1" \
  "$G_OT/$G_OTL" "0/-"
if [ "$G_SH" -ge 3 ] && [ "$G_LG" -ge 1 ]; then
  _pass "P0 C-g floor: $G_SH prose mention(s) of $G_SHIP and $G_LG of v1 were bucketed, so the zero above is a measured zero"
else
  _fail "P0 C-g floor: the population names the shipped version at least three times and the v1 class at least once" \
    "shipped=$G_SH legacy=$G_LG — a population that stopped naming any version satisfies 'no other version' vacuously; re-measure the sites and move this floor deliberately"
fi

# The pin's control: bump the FENCE alone, derived one past the shipped stamp so it can never
# coincide with it. Every prose site then names the old version and the pin has to fail.
if [ "$G_SHIP" = "__underived__" ]; then
  _skip "P0 C-g CONTROL (no derived stamp to bump — reported as a finding above)"
else
G_NEXT="v$(( ${G_SHIP#v} + 1 ))"
G_V_MUT="$SCRATCH/init-bumped.md"
awk -v m="$BLOCK_MARKER" -v nv="$G_NEXT" '
  !done { t = $0; sub(/^[[:space:]]+/, "", t); if (index(t, m) == 1) { print m " (" nv ")"; done = 1; next } }
  { print }' "$SWEEP_ROOT/$INIT_SKILL" > "$G_V_MUT"
assert_eq "P0 C-g CONTROL: the mutant carries the bumped stamp and the same line count, so nothing but the fence moved" \
  "$(_shipped_stamp "$G_V_MUT")/$(wc -l < "$G_V_MUT" | tr -d ' ')" \
  "$G_NEXT/$(wc -l < "$SWEEP_ROOT/$INIT_SKILL" | tr -d ' ')"
read -r G_M_SH _ G_M_OT G_M_OTL <<< "$(_version_tally "$G_V_MUT" "$G_NEXT")"
assert_eq "P0 C-g CONTROL: against it the pin FIRES on every prose site the bump left behind, and finds none naming the bumped value" \
  "$([ "$G_M_OT" -ge 1 ] && printf 'fires-%s' "$G_M_OT" || printf 'silent')/$G_M_SH" "fires-$G_SH/0"
assert_contains "P0 C-g CONTROL: and it names the stale literal it found, not merely that one exists" \
  "$G_M_OTL" "$G_SHIP@"
fi

# Literal strike-out: the phrases below carry backticks, slashes and `^…$`, so a sed s/// control
# would be a regex bug waiting to read as agreement. Struck out, never deleted, so line counts hold.
_strike() {
  awk -v phrase="$1" '{ while ((p = index($0, phrase)) > 0) $0 = substr($0, 1, p - 1) substr($0, p + length(phrase)); print }' "$2"
}
_differs() { cmp -s "$1" "$2" && printf 'same' || printf 'differs'; }

# #254 C-a, per FILE and never one combined count of two: two hits are equally consistent with
# both sentences in the init skill and neither in the clean skill — and clean is what DELETES lines.
_own_counts() {
  printf '%s/%s' "$(grep -cF -- "$1" "$2" || true)" "$(grep -cF -- "$1" "$3" || true)"
}
S_OWN='A line belongs to the region only if it is a `#` comment or a pattern beginning `nazgul/`'
S_OWN_STOP='name the line removal stopped at'
S_OWN_RESID='BOTH ownership clauses consume abutting user content silently'
S_OWN_REPORT='REPORT EVERY LINE IT REMOVED'
assert_eq "P0 C-a: the ownership bound on the legacy fallback is stated in init and in clean, once each" \
  "$(_own_counts "$S_OWN" "$SWEEP_ROOT/$INIT_SKILL" "$SWEEP_ROOT/$CLEAN_SKILL")" "1/1"
assert_eq "P0 C-a: so is the instruction to NAME the line removal stopped at, which is what tells a user why their tail survived" \
  "$(_own_counts "$S_OWN_STOP" "$SWEEP_ROOT/$INIT_SKILL" "$SWEEP_ROOT/$CLEAN_SKILL")" "1/1"
assert_eq "P0 C-a: and the residual it does NOT close, stated for BOTH ownership clauses and not the comment one alone (round-3 finding 8)" \
  "$(_own_counts "$S_OWN_RESID" "$SWEEP_ROOT/$INIT_SKILL" "$SWEEP_ROOT/$CLEAN_SKILL")" "1/1"
# The silent half needs an ACTION, not just a disclosure: the qualifies-as-neither case is loud,
# so a consumed user line must be reported too, in both copies of the rule.
assert_eq "P0 C-a: and the removal must report every line it removed, which is the only notice a silently-consumed user line ever gets" \
  "$(_own_counts "$S_OWN_REPORT" "$SWEEP_ROOT/$INIT_SKILL" "$SWEEP_ROOT/$CLEAN_SKILL")" "1/1"
# Negative pin: the v2 block's four-entry lead-in described a population this fallback cannot run
# on (v2 carries an end sentinel). Its return would be the same mis-citation, so it reads zero.
assert_eq "P0 C-a: the v1 rule does not cite the v2 block's entry count, the population it never governs" \
  "$(_own_counts 'that first interior comment arrives after only four entries' "$SWEEP_ROOT/$INIT_SKILL" "$SWEEP_ROOT/$CLEAN_SKILL")" "0/0"

S_OWN_MUT_I="$SCRATCH/init-no-own.md"; S_OWN_MUT_C="$SCRATCH/clean-no-own.md"
_strike "$S_OWN" "$SWEEP_ROOT/$INIT_SKILL" > "$S_OWN_MUT_I"
_strike "$S_OWN" "$SWEEP_ROOT/$CLEAN_SKILL" > "$S_OWN_MUT_C"
assert_eq "P0 C-a CONTROL: struck out, the same search reports the rule missing from both copies" \
  "$(_own_counts "$S_OWN" "$S_OWN_MUT_I" "$S_OWN_MUT_C")" "0/0"
assert_eq "P0 C-a CONTROL: and the strike-out changed both files, so 0/0 is not a mutant that did nothing" \
  "$(_differs "$SWEEP_ROOT/$INIT_SKILL" "$S_OWN_MUT_I")/$(_differs "$SWEEP_ROOT/$CLEAN_SKILL" "$S_OWN_MUT_C")" \
  "differs/differs"

# One destructive operation, one rule: the two copies are compared whole, not phrase by phrase.
# BOTH paragraphs: round-3 finding 8 split the residual onto its own, and a byte-identity check
# that stopped at the first would let the two copies drift in exactly the half that is destructive.
_own_para() {
  awk -v a='**Legacy fallback**, for a v1 region carrying no end sentinel' \
      -v b='**The residual this does not close' \
      'index($0, a) == 1 || index($0, b) == 1 { print }' "$1"
}
S_OWN_PARA=$(_own_para "$SWEEP_ROOT/$INIT_SKILL")
if [ -n "$S_OWN_PARA" ]; then
  _pass "P0 C-a floor: the legacy-fallback paragraph is located in $INIT_SKILL (${#S_OWN_PARA} bytes)"
else
  _fail "P0 C-a floor: the legacy-fallback paragraph is located in $INIT_SKILL" \
    "no line begins with the rule — two empty strings would satisfy the byte-identity check below vacuously"
fi
assert_eq "P0 C-a: and $CLEAN_SKILL states that rule byte for byte, so the two cannot drift into two rules" \
  "$(_own_para "$SWEEP_ROOT/$CLEAN_SKILL")" "$S_OWN_PARA"

S_CLEAN_LOC='the region from `# Nazgul Framework (local mode)` — matched by that prefix alone'
S_CLEAN_LOC_N=$(grep -cF -- "$S_CLEAN_LOC" "$SWEEP_ROOT/$CLEAN_SKILL" || true)
assert_eq "P0 C-f: /nazgul:clean matches the local start sentinel by PREFIX, so a stamped local block is still found" \
  "$S_CLEAN_LOC_N" "1"
S_CLEAN_LOC_CTRL="$SCRATCH/clean-loc.md"
{ cat "$SWEEP_ROOT/$CLEAN_SKILL"; printf 'Also delete %s.\n' "$S_CLEAN_LOC"; } > "$S_CLEAN_LOC_CTRL"
assert_eq "P0 C-f CONTROL: appending one occurrence moves the same count by exactly one" \
  "$(grep -cF -- "$S_CLEAN_LOC" "$S_CLEAN_LOC_CTRL" || true)" "$((S_CLEAN_LOC_N + 1))"

# #254 C-c, three-valued on purpose (§15): a branch that lost its probe and a branch that
# vanished are different findings, and one combined count of two could report neither.
_probe_in_bullet() {
  local line
  line=$(grep -m1 -F -- "$1" "$3" 2>/dev/null || true)
  [ -n "$line" ] || { printf 'no-bullet'; return 0; }
  case "$line" in *"$2"*) printf 'probed' ;; *) printf 'unprobed' ;; esac
}
# --no-index is part of the probe, not decoration (round-3 finding 1): without it the probe
# consults the index and answers 1 for a TRACKED path, which is the #251 population itself.
S_PROBE='git check-ignore -q --no-index nazgul/in-flight/'
S_BUL_ABS='- **Absent** —'
S_BUL_CUR='- **Present at the shipped version** —'
_probe_pair() { printf '%s/%s' "$(_probe_in_bullet "$S_BUL_ABS" "$S_PROBE" "$1")" "$(_probe_in_bullet "$S_BUL_CUR" "$S_PROBE" "$1")"; }
assert_eq "P0 C-c: the read-back probe is stated in the append branch AND in the already-current branch" \
  "$(_probe_pair "$SWEEP_ROOT/$INIT_SKILL")" "probed/probed"
S_PROBE_MUT="$SCRATCH/init-no-probe.md"
_strike "$S_PROBE" "$SWEEP_ROOT/$INIT_SKILL" > "$S_PROBE_MUT"
assert_eq "P0 C-c CONTROL: struck out, each branch reports UNPROBED on its own line, not one shared number" \
  "$(_probe_pair "$S_PROBE_MUT")" "unprobed/unprobed"
S_BUL_MUT1="$SCRATCH/init-no-bullet1.md"; S_BUL_MUT="$SCRATCH/init-no-bullets.md"
_strike "$S_BUL_ABS" "$SWEEP_ROOT/$INIT_SKILL" > "$S_BUL_MUT1"
_strike "$S_BUL_CUR" "$S_BUL_MUT1" > "$S_BUL_MUT"
assert_eq "P0 C-c CONTROL: with the two bullets themselves struck out it says no-bullet, never 'unprobed' — looked-and-found-none is not never-looked" \
  "$(_probe_pair "$S_BUL_MUT")" "no-bullet/no-bullet"

S_FIFTH='leading whitespace on any region line makes the block STALE regardless of its stamp'
S_INERT='never report success on an inert block'
S_SHARED_ONLY='the probe belongs to the shared branch alone'
_once() { grep -cF -- "$1" "$2" || true; }
assert_eq "P0 C-c: the leading-whitespace version case, the never-report-success rule and the shared-branch-only boundary are each stated exactly once" \
  "$(_once "$S_FIFTH" "$SWEEP_ROOT/$INIT_SKILL")/$(_once "$S_INERT" "$SWEEP_ROOT/$INIT_SKILL")/$(_once "$S_SHARED_ONLY" "$SWEEP_ROOT/$INIT_SKILL")" \
  "1/1/1"
S_CC_CTRL="$SCRATCH/init-cc.md"
{ cat "$SWEEP_ROOT/$INIT_SKILL"; printf 'Again: %s, %s, %s.\n' "$S_FIFTH" "$S_INERT" "$S_SHARED_ONLY"; } > "$S_CC_CTRL"
assert_eq "P0 C-c CONTROL: appending one occurrence of each moves all three counts by exactly one" \
  "$(_once "$S_FIFTH" "$S_CC_CTRL")/$(_once "$S_INERT" "$S_CC_CTRL")/$(_once "$S_SHARED_ONLY" "$S_CC_CTRL")" \
  "2/2/2"

# #254 C-h, split at the Step 4 heading: :176 is the block instruction and :219 the printed
# remedy, and a rule stated at one but not the other is exactly this finding's shape.
_count_split_at() {
  awk -v anchor="$1" -v phrase="$2" '
    index($0, anchor) == 1 { seen = 1 }
    { n = 0; s = $0
      while ((p = index(s, phrase)) > 0) { n++; s = substr(s, p + length(phrase)) }
      if (seen) after += n; else before += n }
    END { if (!seen) { print "no-anchor"; exit } print (before + 0) "/" (after + 0) }
  ' "$3"
}
S_STEP4='### Step 4: Display Summary'
S_CH_RE='^[A-Za-z0-9._/-]+$'
# Round-3 finding 2 generalised the rule from one hand-written copy per key to ONE rule over a
# table of keys, so the refusal wording no longer names a key. The per-key coverage that used
# to ride along in this literal is now its own pin, below.
S_CH_KEY='naming the KEY that failed and the rule it failed'
S_CH_ECHO='Never echo the rejected value'
_ch_triple() {
  printf '%s %s %s' "$(_count_split_at "$S_STEP4" "$S_CH_RE" "$1")" \
    "$(_count_split_at "$S_STEP4" "$S_CH_KEY" "$1")" "$(_count_split_at "$S_STEP4" "$S_CH_ECHO" "$1")"
}
assert_eq "P0 C-h: the allowlist regex, the refuse-and-name-the-KEY rule and the never-echo rule are each stated at the Step 2.5 site AND the Step 4 site" \
  "$(_ch_triple "$SWEEP_ROOT/$INIT_SKILL")" "1/1 1/1 1/1"
S_CH_MUT1="$SCRATCH/init-ch1.md"; S_CH_MUT2="$SCRATCH/init-ch2.md"; S_CH_MUT="$SCRATCH/init-no-ch.md"
_strike "$S_CH_RE" "$SWEEP_ROOT/$INIT_SKILL" > "$S_CH_MUT1"
_strike "$S_CH_KEY" "$S_CH_MUT1" > "$S_CH_MUT2"
_strike "$S_CH_ECHO" "$S_CH_MUT2" > "$S_CH_MUT"
assert_eq "P0 C-h CONTROL: struck out, all three report missing from both sites" \
  "$(_ch_triple "$S_CH_MUT")" "0/0 0/0 0/0"

# Round-3 finding 2: `self_audit.backlog_path` was as configurable as the inbox dir and as
# hardcoded in the block, and the fix for one key was never applied to the other. The rule is now
# one rule over a TABLE, so this pins the WHOLE table — every configurable key stated at the Step
# 2.5 site AND the Step 4 site. Without it, generalising the wording would pass while a key was
# quietly missing from the table it claims to govern.
S_CH_KEYS='automation.heartbeat.inbox.dir self_audit.backlog_path'
S_CH_KEYS_N=0
for _ch_k in $S_CH_KEYS; do
  S_CH_KEYS_N=$((S_CH_KEYS_N + 1))
  assert_eq "P0 finding-2: the configurable key $_ch_k is named at the Step 2.5 site AND the Step 4 site" \
    "$(_count_split_at "$S_STEP4" "$_ch_k" "$SWEEP_ROOT/$INIT_SKILL")" "1/1"
done
assert_eq "P0 finding-2 (floor): the configurable-key roster is measured, so the loop above cannot pass vacuously" \
  "$S_CH_KEYS_N" "2"
# CONTROL: strike one key and its site pair collapses, so the 1/1s above are measured, not assumed.
S_CH_K_MUT="$SCRATCH/init-no-backlog.md"
_strike 'self_audit.backlog_path' "$SWEEP_ROOT/$INIT_SKILL" > "$S_CH_K_MUT"
assert_eq "P0 finding-2 CONTROL: with the backlog key struck out its pair reads 0/0, the pre-fix state this pin exists to catch" \
  "$(_count_split_at "$S_STEP4" 'self_audit.backlog_path' "$S_CH_K_MUT")" "0/0"
S_CH_NOANCHOR="$SCRATCH/init-no-step4.md"
_strike "$S_STEP4" "$SWEEP_ROOT/$INIT_SKILL" > "$S_CH_NOANCHOR"
assert_eq "P0 C-h CONTROL: with the Step 4 heading gone the splitter says no-anchor, not a 2/0 that would read as one site satisfying both" \
  "$(_count_split_at "$S_STEP4" "$S_CH_RE" "$S_CH_NOANCHOR")" "no-anchor"

# The property security praised in scripts/in-flight-marker.sh: the rejection names the KEY and
# never interpolates the VALUE — least of all into a command a human is asked to run.
S_CH_VAL='naming the value'
assert_eq "P0 C-h CONTROL: and neither site instructs naming the rejected VALUE" \
  "$(_count_split_at "$S_STEP4" "$S_CH_VAL" "$SWEEP_ROOT/$INIT_SKILL")" "0/0"
S_CH_VAL_CTRL="$SCRATCH/init-ch-value.md"
{ cat "$SWEEP_ROOT/$INIT_SKILL"; printf 'Print a notice %s it rejected.\n' "$S_CH_VAL"; } > "$S_CH_VAL_CTRL"
assert_eq "P0 C-h CONTROL: appending one such instruction after Step 4 moves the AFTER count to one, so those zeros are measured" \
  "$(_count_split_at "$S_STEP4" "$S_CH_VAL" "$S_CH_VAL_CTRL")" "0/1"

S_FLUSH='Write every line flush-left, exactly as shown'
assert_eq "P0 prose: both Step 2.5 branches state the flush-left requirement, exactly once each" \
  "$(_flush_per_fence "$S_FLUSH" "$S_REGIONS" "$SWEEP_ROOT/$INIT_SKILL")" "1 1"
# Absent-sentinel control, struck out rather than deleted so the pinned line numbers still hold.
S_PROSE_MUT="$SCRATCH/init-no-flush.md"
sed "s/$S_FLUSH//" "$SWEEP_ROOT/$INIT_SKILL" > "$S_PROSE_MUT"
assert_eq "P0 prose CONTROL: with that sentence struck out the same search reports it missing from both branches" \
  "$(_flush_per_fence "$S_FLUSH" "$S_REGIONS" "$S_PROSE_MUT")" "0 0"

# B3: the removal rule that stopped at the first comment orphaned everything after it.
S_B3='up to the next blank line / comment'
S_B3_N=$(grep -cF -- "$S_B3" "$SWEEP_ROOT/$INIT_SKILL" || true)
assert_eq "P0 B3: $INIT_SKILL no longer terminates block removal '$S_B3'" "$S_B3_N" "0"
assert_eq "P0 B3: and the region rule that replaced it names the blank-line/EOF terminator, exactly once" \
  "$(grep -cF -- 'terminating at the first BLANK line or EOF' "$SWEEP_ROOT/$INIT_SKILL" || true)" "1"
# Measured against the file's own count, not against 1: the control has to prove this search can
# SEE the phrasing, and a fixed expectation would instead re-assert the absence above.
S_B3_CTRL="$SCRATCH/init-b3.md"
{ cat "$SWEEP_ROOT/$INIT_SKILL"; printf 'Removing a block means deleting its marker line and the lines under it %s.\n' "$S_B3"; } > "$S_B3_CTRL"
assert_eq "P0 B3 CONTROL: appending one occurrence moves the same count by exactly one, so the zero above is a measured zero" \
  "$(grep -cF -- "$S_B3" "$S_B3_CTRL" || true)" "$((S_B3_N + 1))"

findings=$((findings + TESTS_FAILED - S_FAILED_BEFORE))
fi

# P1/P2/P3 prove the block changes GIT'S BEHAVIOUR, not the skill's text alone, and
# run in a scratch `git init` tree: this checkout is local-mode, so there is no in-tree repro.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip "P1/P2/P3 git-behaviour arms (inner run under an injected sweep root)"
elif [ "$SCRATCH_USABLE" -ne 1 ]; then
  _skip "P1/P2/P3 git-behaviour arms (no usable scratch tree — reported as a finding above)"
else
R_FAILED_BEFORE=$TESTS_FAILED
# A child of the one scratch tree, created and proven usable with it: one mktemp -d site, one guard
# and one trap is what makes "every region shares a guard condition" true rather than nearly true.
ROUTES="$SCRATCH/routes"

# The local-mode fence's sha256 as FEAT-036/TASK-022 stamps it (#254 C-f); 25f78f95… was ff64f76's
# pre-stamp fence. A content baseline, pinned rather than read from a shallow CI clone's git.
LOCAL_FENCE_SHA_BASE="aa19b1b87d8a15f3bb6783b4d8d646a3125179b4ec2298637bbb9fb42a3d1b7f"

# Raw fence lines for the ```gitignore fence CONTAINING a marker. P1 must see WHICH
# line comes first, so this cannot start AT the marker the way _extract_block does.
_fenced_lines() {
  # Prefix, for the same reason detection is: an exact-line match against a ` (vN)`-stamped start
  # line returns the fence when asked for the stamp and zero lines when asked for the prefix.
  awk -v marker="$1" '
    { t = $0; sub(/^[[:space:]]+/, "", t) }
    !inf && t == "```gitignore" { inf = 1; n = 0; hit = 0; split("", buf); next }
    inf && t == "```" { if (hit) { for (i = 1; i <= n; i++) print buf[i]; exit } inf = 0; next }
    inf { buf[++n] = $0; if (index(t, marker) == 1) hit = 1 }
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
  assert_eq "P1 extractors agree: the fence is the marker, _extract_block's $R_BLOCK_N line(s) and the end sentinel" \
    "$R_FENCE_N" "$((R_BLOCK_N + 2))"

  R_L1=$(head -n 1 "$ROUTES/shared.raw" | sed 's/^[[:space:]]*//')
  R_L2=$(sed -n '2p' "$ROUTES/shared.raw" | sed 's/^[[:space:]]*//')
  R_LN=$(tail -n 1 "$ROUTES/shared.raw" | sed 's/^[[:space:]]*//')
  R_L1_CLASS="other"
  [ "${R_L1#"$BLOCK_MARKER"}" != "$R_L1" ] && R_L1_CLASS="marker-prefix"
  assert_eq "P1 marker: the block's first line begins with the detection prefix ($INIT_SKILL:82 matches that alone)" \
    "$R_L1_CLASS" "marker-prefix"
  # Three-way, so a bare v1 line and an unrelated line cannot both read as "not stamped".
  R_L1_STAMP="other"
  if [ "$R_L1" = "$BLOCK_MARKER" ]; then
    R_L1_STAMP="bare-v1"
  elif printf '%s\n' "$R_L1" | grep -qE '^# Nazgul Framework — ephemeral runtime \(v[0-9]+\)$'; then
    R_L1_STAMP="stamped"
  fi
  assert_eq "P1 stamp: and it carries a (vN) version stamp, which detection above deliberately does not require" \
    "$R_L1_STAMP" "stamped"
  assert_eq "P1 sentinel: the block's LAST line is the end sentinel, so the region has a closed boundary" \
    "$R_LN" "$BLOCK_END"
  R_L2_CLASS="other"
  case "$R_L2" in
    "$BLOCK_MARKER") R_L2_CLASS="marker-repeated" ;;
    "#"*) R_L2_CLASS="comment" ;;
  esac
  assert_eq "P1 comment: the block's second line is the descriptive comment, not an entry" "$R_L2_CLASS" "comment"

  R_BLANKS=$(grep -c '^[[:space:]]*$' "$ROUTES/shared.raw" || true)
  assert_eq "P1 structure: no blank line inside the block (one would truncate what --force removal sees)" \
    "$R_BLANKS" "0"

  # RAW, never a de-indented copy: normalising the fence before git reads it is what let a fully
  # inert block report green (#254 C2). The shipped bytes are the thing under test.
  cp "$ROUTES/shared.raw" "$ROUTES/green.gitignore"
  sed 's/^/   /' "$ROUTES/shared.raw" > "$ROUTES/indented.gitignore"
  grep -vxF 'nazgul/in-flight/' "$ROUTES/green.gitignore" > "$ROUTES/red.gitignore" || true
  R_GREEN_N=$(wc -l < "$ROUTES/green.gitignore" | tr -d ' ')
  R_RED_N=$(wc -l < "$ROUTES/red.gitignore" | tr -d ' ')
  R_IND_N=$(wc -l < "$ROUTES/indented.gitignore" | tr -d ' ')
  assert_eq "P2 control built: dropping nazgul/in-flight/ removes exactly one line of the block" \
    "$((R_GREEN_N - R_RED_N))" "1"
  assert_eq "P2 control built: and no nazgul/in-flight/ line survives in the RED variant" \
    "$(grep -cxF 'nazgul/in-flight/' "$ROUTES/red.gitignore" || true)" "0"
  R_IND_SAME="differs"
  sed 's/^[[:space:]]*//' "$ROUTES/indented.gitignore" | cmp -s - "$ROUTES/green.gitignore" && R_IND_SAME="same"
  assert_eq "P2 control built: the INDENTED variant is the RAW fence plus three leading spaces, nothing else" \
    "$R_IND_N/$R_IND_SAME" "$R_GREEN_N/same"
  assert_eq "P2 control built: and RAW carries no indented line of its own, so that prefix is the only difference" \
    "$(grep -c '^[[:space:]]' "$ROUTES/green.gitignore" || true)" "0"

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

  # The INDENTED control: the same 29 entries, three spaces to the left. Its 1 and its 2s are
  # what make the RAW zeros above a statement about the shipped bytes rather than about a copy.
  R_IND_REPO="$ROUTES/indented-repo"; _routes_repo "$R_IND_REPO" "$ROUTES/indented.gitignore"
  R_I_IGN=$(_route_ignored "$R_IND_REPO" nazgul/in-flight/m.json)
  R_I_PAT=$(_route_pattern "$R_IND_REPO" nazgul/in-flight/m.json)
  R_I_STAGE=$(_route_staging "$R_IND_REPO")
  R_I_ADD=$(_route_add "$R_IND_REPO")
  assert_eq "P2 INDENTED CONTROL 3/3: an indented copy of the very same block leaves check-ignore at 1" \
    "$R_I_IGN" "1"
  assert_eq "P2 INDENTED CONTROL: for the stated reason — check-ignore -v names no matching pattern at all" \
    "$R_I_PAT" ""
  assert_eq "P2 INDENTED CONTROL 2/3: the staging route then lists both markers" "$R_I_STAGE" "2"
  assert_eq "P2 INDENTED CONTROL 1/3: and git add -A stages both — #251's reported symptom, fully restored" \
    "$R_I_ADD" "2"
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
R_LOCAL_N=$(wc -l < "$ROUTES/local.raw" | tr -d ' ')
assert_eq "P3 local block: the local-mode fence is its marker, three entries and its end sentinel" \
  "$R_LOCAL_N" "5"
R_LOC_L1=$(head -n 1 "$ROUTES/local.raw" | sed 's/^[[:space:]]*//')
R_LOC_L1_CLASS="other"
[ "${R_LOC_L1#"$LOCAL_MARKER"}" != "$R_LOC_L1" ] && R_LOC_L1_CLASS="marker-prefix"
[ "$R_LOC_L1" = "$LOCAL_MARKER" ] && R_LOC_L1_CLASS="bare-v1"
assert_eq "P3 local block: opened by its start-sentinel PREFIX (the line carries a stamp) and closed by its end sentinel" \
  "$R_LOC_L1_CLASS/$(tail -n 1 "$ROUTES/local.raw" | sed 's/^[[:space:]]*//')" \
  "marker-prefix/$LOCAL_END"
R_SHA_TOOL="none"
command -v sha256sum >/dev/null 2>&1 && R_SHA_TOOL="sha256sum"
[ "$R_SHA_TOOL" = "none" ] && command -v shasum >/dev/null 2>&1 && R_SHA_TOOL="shasum"
if [ "$R_SHA_TOOL" = "none" ]; then
  _fail "P3 local block: a sha256 tool (sha256sum or shasum) is on PATH" \
    "neither resolves — an empty digest must not be able to read as agreement"
else
  _pass "P3 local block: hashed with $R_SHA_TOOL"
fi
assert_eq "P3 local block: byte-identical to its pinned baseline, whitespace included" \
  "$(_sha256 < "$ROUTES/local.raw")" "$LOCAL_FENCE_SHA_BASE"

findings=$((findings + TESTS_FAILED - R_FAILED_BEFORE))
fi

# A sibling region to the P1/P2/P3 arms, reusing their extractions ($R_DETECT, $R_RM_R,
# $R_RM_GLOB) under the same guard: one comparison per copy, never two rival ones.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ]; then
  _skip 'P3 copy-sync arms (inner run under an injected sweep root: the $R_DETECT/$R_RM_R/$R_RM_GLOB these arms compare against are assigned only inside the P1/P2/P3 region above, which the same guard skipped)'
elif [ "$SCRATCH_USABLE" -ne 1 ]; then
  _skip 'P3 copy-sync arms (no usable scratch tree: the same P1/P2/P3 region that assigns $R_DETECT/$R_RM_R/$R_RM_GLOB was skipped for it)'
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

# Removal keys on the REGION, so Step 8 must name both sentinels: reverting it to the entry list
# alone would still satisfy the two comparisons above, which read only that list.
assert_contains "P3 copy 3 region: Step 8's shared-mode item names the start sentinel as the removal boundary" \
  "$C_CLEAN_LINE" "$BLOCK_MARKER"
assert_contains "P3 copy 3 region: and the end sentinel that closes it" "$C_CLEAN_LINE" "$BLOCK_END"
assert_not_contains "P3 copy 3 region CONTROL: and not the local-mode end sentinel, which is item 2's boundary" \
  "$C_CLEAN_LINE" "$LOCAL_END"

findings=$((findings + TESTS_FAILED - C_FAILED_BEFORE))
fi

# #254 C-b and C-l, driven as CHILD runs rather than asserted about this file's text: a guard that
# ended the run before the emitter cannot be observed from inside the run it ended.
if [ -n "${NAZGUL_IGNORE_SWEEP_ROOT:-}" ] || [ -n "${NAZGUL_IGNORE_SWEEP_CHILD:-}" ]; then
  _skip "degradation controls (inner or control-child run: driving them from here would recurse without bound)"
elif [ "$SCRATCH_USABLE" -ne 1 ]; then
  _skip "degradation controls (no usable scratch tree — reported as a finding above; the broken-TMPDIR arm needs a path under it)"
else
X_FAILED_BEFORE=$TESTS_FAILED

# One parse of a child's tail line into its four numbers, MISSING rather than empty: a run that
# printed no tail must fail an assertion, not compare equal to one whose numbers happened to match.
_tail_fields() {
  printf '%s\n' "$1" | awk -v t="$TEST_NAME" '
    index($0, t ": ") == 1 && $0 ~ / scanned, / { n = $2; m = $4; k = $(NF - 3); f = $(NF - 1); ok = 1 }
    END { if (ok) print n, m, k, f; else print "MISSING MISSING MISSING MISSING" }'
}

# Both degraded shapes are checked against the same four properties, because C-b is not "the guard
# was reached" — it is that a REACHED guard still leaves this §15 entry point its coverage line.
_degraded_arm() {
  local label="$1" out="$2" rc="$3" n m k f
  read -r n m k f <<< "$(_tail_fields "$out")"
  assert_eq "$label: the run still prints its paths line, exactly once" \
    "$(printf '%s\n' "$out" | grep -c '^paths: ' || true)" "1"
  if [ "$n" = "MISSING" ]; then
    _fail "$label: the run still prints its RULES.md §15 coverage line" \
      "no '$TEST_NAME: N scanned …' line in the child's output — a guard that ends the run before the emitter IS C-b"
    return 0
  fi
  _pass "$label: the run still prints its RULES.md §15 coverage line ($n scanned, $m skipped, $k checked, $f findings)"
  assert_eq "$label: and the accounting identity holds in the degraded run too (N == M + K)" "$n" "$((m + k))"
  if [ "$f" -ge 1 ]; then
    _pass "$label: the degradation is REPORTED in that tally ($f), not removed from it"
  else
    _fail "$label: the degradation is REPORTED in that tally" \
      "findings=$f — C3's shape with the number wrong instead of absent"
  fi
  assert_exit_code "$label: and the run is blocking" "$rc" 1
}

# Never created, so mktemp -d genuinely fails rather than being told to fail.
X_TMPDIR="$SCRATCH/tmpdir-never-created"
assert_eq "C-b precondition: the TMPDIR handed to the child does not exist, so its mktemp -d really fails" \
  "$([ -e "$X_TMPDIR" ] && printf 'exists' || printf 'absent')" "absent"
X_CB_OUT=$(env TMPDIR="$X_TMPDIR" NAZGUL_IGNORE_SWEEP_CHILD=1 bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1); X_CB_RC=$?
_degraded_arm "C-b unusable scratch" "$X_CB_OUT" "$X_CB_RC"
assert_contains "C-b: the finding names the tree it could not create" "$X_CB_OUT" \
  "FAIL: scratch tree: mktemp -d under $X_TMPDIR yields a usable tree"
assert_contains "C-b: and every region that needed one says SKIP rather than nothing at all" "$X_CB_OUT" \
  "SKIP: dogfood fixtures (no usable scratch tree"
assert_contains "C-b: including the routes region, whose own guard used to exit before the emitter too" "$X_CB_OUT" \
  "SKIP: P1/P2/P3 git-behaviour arms (no usable scratch tree"

# C-l's exact combination: the third dogfood branch, with no injected sweep root, so the P0 region
# below it is entered with SCRATCH assigned. At 7c0a267 this died at :679 on an unbound $SCRATCH.
X_CL_OUT=$(env NAZGUL_IGNORE_SWEEP_FOLD_PROBE=1 NAZGUL_IGNORE_SWEEP_CHILD=1 bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1); X_CL_RC=$?
_degraded_arm "C-l fold probe with no injected sweep root" "$X_CL_OUT" "$X_CL_RC"
assert_contains "C-l: it fails for the fold probe it was asked to raise" "$X_CL_OUT" \
  "FAIL: fold probe: a deliberate dogfood-region failure"
assert_not_contains "C-l: never for an unbound \$SCRATCH, which aborted before either tail line" \
  "$X_CL_OUT" "SCRATCH: unbound variable"
assert_contains "C-l: and the P0 region it used to abort inside runs to its own controls" "$X_CL_OUT" \
  "PASS: P0 flush-left CONTROL:"

findings=$((findings + TESTS_FAILED - X_FAILED_BEFORE))
fi

# The unresolvable and block-region tallies are path-level, not file-level: one
# file can hold both kinds, so neither can live in M without breaking N == M + K.
RC=0
report_results || RC=1
printf 'paths: %d enumerated, %d declared, %d undeclared, %d unresolvable, %d block-region-excluded, %d record-only-excluded\n' \
  "$enumerated_count" "$declared_count" "$undeclared" "$unresolvable" "$block_excluded" "$record_only"
printf '%s: %d scanned, %d skipped (no-nazgul-path=%d, unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$scanned" "$((skipped_no_path + skipped_unreadable))" \
  "$skipped_no_path" "$skipped_unreadable" "$checked" "$findings"
exit "$RC"
