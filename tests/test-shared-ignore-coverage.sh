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

SWEEP_ROOT="${NAZGUL_IGNORE_SWEEP_ROOT:-$REPO_ROOT}"
SOURCE_DIRS="scripts skills agents templates"
INIT_SKILL="skills/init/SKILL.md"
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

# EVERY _fail below increments `findings` first: a run that failed while printing
# "0 findings" would be this sweep committing the defect it exists to catch.
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
