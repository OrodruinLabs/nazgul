#!/usr/bin/env bash
set -euo pipefail

# Test: the repo content boundary (PATCH-002, RULES.md §15).
# R1 — no tracked file carries a REAL operator home path.
# R2 — every immediate subdirectory of tests/fixtures/ declares its provenance,
#      and a captured-redacted fixture's form pins are recomputed from disk.
# CI is the only tier. The incident this closes arrived through a Bash `cp`, which
# a Write|Edit|MultiEdit PreToolUse guard cannot see, and a Bash guard would reopen
# RULES.md §15's non-convergence verdict on parsing command strings for intent.
#
# R2 grammar, all fields anchored at line start inside PROVENANCE.md:
#   tier: <synthetic|captured-redacted|verbatim>   required, closed set
#   consumer: <text>                               required at every tier
#   synthetic         -> reason:
#   verbatim          -> producer:, captured:
#   captured-redacted -> producer:, captured:, redacted:, and >=1 pin: line
# A pin is `pin: <kind> | <expected> | <dir> | <pattern>`, kind one of file-count
# (shell glob), occurrences (ERE), matching-files (ERE). Every pin is RECOMPUTED
# from disk, so a pin cannot rot the way the pre-PATCH-002 one did.
TEST_NAME="test-repo-content-boundary"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# Env-injectable for the same reason test-shellcheck.sh's scan root is: the R1
# violation branch is unreachable against a healthy tree, so it is driven from outside.
SCAN_ROOT="${NAZGUL_BOUNDARY_SCAN_ROOT:-$REPO_ROOT}"
SELF_REL="tests/$(basename "$0")"

# Three arms. The Windows arm is `[A-Za-z]:\\Users\\` — ONE escaped backslash per
# separator; a doubled `\\\\` matches two literal backslashes and can never fire.
R1_PATTERN='(/Users/|/home/)[A-Za-z0-9._][A-Za-z0-9._-]*/|[A-Za-z]:\\Users\\[A-Za-z0-9._][A-Za-z0-9._-]*\\'

# CLOSED allowlist of synthetic placeholder names. Enumerate-the-allowed-set, never
# a disallowed-set grammar: adding a name here is a deliberate, reviewable act.
R1_ALLOWED_NAMES="dev test tester user example runner ubuntu alice bob someone"

# _r1_name_of <match> -> the user-name component of a matched path prefix.
_r1_name_of() {
  printf '%s' "$1" | sed -E -e 's#^(/Users/|/home/)##' -e 's#^[A-Za-z]:\\Users\\##' \
    -e 's#/$##' -e 's#\\$##'
}

_r1_is_allowed() {
  local name="$1" allowed
  for allowed in $R1_ALLOWED_NAMES; do
    [ "$name" = "$allowed" ] && return 0
  done
  return 1
}

# _r1_findings_in_file <path> -> one `<line>:<match>` record per violating
# OCCURRENCE (grep -o, not grep -c, which counts lines and undercounts).
_r1_findings_in_file() {
  local file="$1" hit line match name
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit%%:*}"
    match="${hit#*:}"
    name="$(_r1_name_of "$match")"
    _r1_is_allowed "$name" && continue
    printf '%s:%s\n' "$line" "$match"
  done < <(grep -noE "$R1_PATTERN" "$file" 2>/dev/null || true)
}

R1_SCANNED=0
R1_CHECKED=0
R1_FINDINGS=0
R1_SKIP_SELF=0
R1_SKIP_BINARY=0
R1_SKIP_UNREADABLE=0
R1_SKIP_NOT_A_FILE=0
R1_VIOLATIONS=""

if ! git -C "$SCAN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  _fail "R1 scan root is a git repository" "$SCAN_ROOT has no git dir — the tracked-file enumerator cannot run"
else
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    R1_SCANNED=$((R1_SCANNED + 1))
    full="$SCAN_ROOT/$rel"
    # Named and counted, never a silent skip: this file necessarily contains the
    # very patterns and placeholder names it hunts.
    if [ "$rel" = "$SELF_REL" ]; then
      R1_SKIP_SELF=$((R1_SKIP_SELF + 1))
      continue
    fi
    if [ ! -f "$full" ]; then
      R1_SKIP_NOT_A_FILE=$((R1_SKIP_NOT_A_FILE + 1))
      continue
    fi
    if [ ! -r "$full" ]; then
      R1_SKIP_UNREADABLE=$((R1_SKIP_UNREADABLE + 1))
      continue
    fi
    # `-s` first: `grep -Iq .` reports no-match on an EMPTY file exactly as it does
    # on a binary one, which would misfile a zero-byte tracked file as unscannable.
    if [ -s "$full" ] && ! grep -Iq . "$full" 2>/dev/null; then
      R1_SKIP_BINARY=$((R1_SKIP_BINARY + 1))
      continue
    fi
    R1_CHECKED=$((R1_CHECKED + 1))
    hits="$(_r1_findings_in_file "$full")"
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      R1_FINDINGS=$((R1_FINDINGS + 1))
      R1_VIOLATIONS="${R1_VIOLATIONS}${rel}:${hit}
"
    done <<EOF
$hits
EOF
  done < <(git -C "$SCAN_ROOT" ls-files -z)
fi

if [ "$R1_FINDINGS" -eq 0 ]; then
  _pass "R1: no tracked file contains a real operator home path"
else
  _fail "R1: no tracked file contains a real operator home path" \
    "$R1_FINDINGS occurrence(s) in the tracked tree:" \
    "$(printf '%s' "$R1_VIOLATIONS" | head -20 | tr '\n' ' ')"
fi

# A zero-file scan is a broken scan, not a clean repo.
R1_FLOOR="${NAZGUL_BOUNDARY_R1_FLOOR:-100}"
if [ "$R1_CHECKED" -ge "$R1_FLOOR" ]; then
  _pass "R1: the scan actually ran over the tracked tree ($R1_CHECKED checked >= $R1_FLOOR)"
else
  _fail "R1: the scan actually ran over the tracked tree" \
    "only $R1_CHECKED tracked file(s) checked — below the floor of $R1_FLOOR"
fi

R1_SKIPPED=$((R1_SKIP_SELF + R1_SKIP_BINARY + R1_SKIP_UNREADABLE + R1_SKIP_NOT_A_FILE))
if [ "$R1_SCANNED" -eq $((R1_SKIPPED + R1_CHECKED)) ]; then
  _pass "R1: coverage accounting adds up (N == M + K)"
else
  _fail "R1: coverage accounting adds up (N == M + K)" \
    "$R1_SCANNED scanned != $R1_SKIPPED skipped + $R1_CHECKED checked"
fi

if git -C "$SCAN_ROOT" ls-files --error-unmatch "$SELF_REL" >/dev/null 2>&1; then
  assert_eq "R1: the self-exemption is counted, never silent" "$R1_SKIP_SELF" "1"
else
  _skip "R1 self-exemption count ($SELF_REL is not tracked in $SCAN_ROOT)"
fi

# The tracked tree is clean by construction, so the matcher is also driven against
# a synthetic corpus: a rule that can only pass is evidence of nothing.
R1_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-boundary-XXXXXX")"
trap 'rm -rf "$R1_TMP"' EXIT

_r1_count_in() {
  printf '%s' "$(_r1_findings_in_file "$1")" | grep -c '[^[:space:]]' || true
}

printf '/Users/mallory/Documents/leaked/file.md\n' > "$R1_TMP/posix-real"
assert_eq "R1 self-check: a non-allowlisted macOS home path is a finding" \
  "$(_r1_count_in "$R1_TMP/posix-real")" "1"

printf '/home/mallory/src/leaked.md\n' > "$R1_TMP/linux-real"
assert_eq "R1 self-check: a non-allowlisted Linux home path is a finding" \
  "$(_r1_count_in "$R1_TMP/linux-real")" "1"

printf 'C:\\Users\\mallory\\AppData\\Local\\x\n' > "$R1_TMP/windows-real"
assert_eq "R1 self-check: the Windows arm fires (the doubled-backslash form never could)" \
  "$(_r1_count_in "$R1_TMP/windows-real")" "1"

printf '/Users/dev/proj/nazgul/tasks/TASK-001.md\n' > "$R1_TMP/posix-allowed"
assert_eq "R1 self-check: an allowlisted placeholder stays quiet (tests/test-pre-tool-guard.sh)" \
  "$(_r1_count_in "$R1_TMP/posix-allowed")" "0"

printf 'C:\\Users\\runner\\work\\repo\\x\n' > "$R1_TMP/windows-allowed"
assert_eq "R1 self-check: an allowlisted Windows placeholder stays quiet" \
  "$(_r1_count_in "$R1_TMP/windows-allowed")" "0"

printf 'a /Users/mallory/x and /home/mallory/y on one line\n' > "$R1_TMP/two-on-one-line"
assert_eq "R1 self-check: two hits on ONE line count as two occurrences, not one" \
  "$(_r1_count_in "$R1_TMP/two-on-one-line")" "2"

R2_TIERS="synthetic captured-redacted verbatim"
R2_PIN_KINDS="file-count occurrences matching-files"
FIXTURES_DIR="$SCAN_ROOT/tests/fixtures"

_r2_field() {
  grep -E "^$2:[[:space:]]*" "$1" 2>/dev/null | head -1 | sed -E "s#^$2:[[:space:]]*##" || true
}

# _r2_eval_pin <fixture-dir> <kind> <target> <pattern> -> prints the recomputed
# value; returns nonzero when the kind is unknown or the target is not a directory.
_r2_eval_pin() {
  local base="$1" kind="$2" target="$3" pattern="$4" dir
  dir="$base/$target"
  [ -d "$dir" ] || return 1
  case "$kind" in
    file-count)
      # Unglobbed on purpose; an unmatched glob stays literal and fails `-e`, giving 0.
      # shellcheck disable=SC2086
      ( cd "$dir" || exit 1
        n=0
        for f in $pattern; do [ -e "$f" ] && n=$((n + 1)); done
        printf '%s\n' "$n" ) ;;
    occurrences)
      grep -rhoaE -e "$pattern" "$dir" 2>/dev/null | grep -c '[^[:space:]]' || echo 0 ;;
    matching-files)
      grep -rlaE -e "$pattern" "$dir" 2>/dev/null | grep -c '[^[:space:]]' || echo 0 ;;
    *) return 1 ;;
  esac
}

R2_SCANNED=0
R2_CHECKED=0
R2_SKIP_UNREADABLE=0
R2_SKIP_UNTRACKED=0
R2_FINDINGS=0

_r2_finding() {
  local name="$1"
  shift
  R2_FINDINGS=$((R2_FINDINGS + 1))
  _fail "R2: $name" "$@"
}

if [ ! -d "$FIXTURES_DIR" ]; then
  _fail "R2: tests/fixtures exists under the scan root" "no directory at $FIXTURES_DIR"
else
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    R2_SCANNED=$((R2_SCANNED + 1))
    fname="$(basename "$sub")"
    if [ ! -r "$sub" ]; then
      R2_SKIP_UNREADABLE=$((R2_SKIP_UNREADABLE + 1))
      _skip "R2 $fname (unreadable directory — not checked)"
      continue
    fi
    # R1 and R2 govern the same thing: TRACKED content. A local scratch directory
    # git has never seen is named and counted here, not silently folded into clean.
    if [ -z "$(git -C "$SCAN_ROOT" ls-files -- "tests/fixtures/$fname" 2>/dev/null | head -1)" ]; then
      R2_SKIP_UNTRACKED=$((R2_SKIP_UNTRACKED + 1))
      _skip "R2 $fname (no tracked file under it — not checked)"
      continue
    fi
    R2_CHECKED=$((R2_CHECKED + 1))
    prov="$sub/PROVENANCE.md"
    if [ ! -r "$prov" ]; then
      _r2_finding "$fname declares its provenance" "no readable PROVENANCE.md at tests/fixtures/$fname/"
      continue
    fi
    tier="$(_r2_field "$prov" tier)"
    if ! printf '%s\n' $R2_TIERS | grep -qx -- "$tier"; then
      _r2_finding "$fname declares a tier from the closed set" \
        "tier: '$tier' is not one of: $R2_TIERS"
      continue
    fi
    missing=""
    required="consumer"
    case "$tier" in
      synthetic) required="$required reason" ;;
      verbatim) required="$required producer captured" ;;
      captured-redacted) required="$required producer captured redacted" ;;
    esac
    for field in $required; do
      [ -n "$(_r2_field "$prov" "$field")" ] || missing="$missing $field"
    done
    if [ -n "$missing" ]; then
      _r2_finding "$fname carries every field its tier requires" \
        "tier '$tier' is missing:$missing"
      continue
    fi
    if [ "$tier" != "captured-redacted" ]; then
      _pass "R2: $fname declares tier '$tier' with every required field"
      continue
    fi
    pin_count=0
    pin_bad=0
    while IFS= read -r pin_line; do
      [ -n "$pin_line" ] || continue
      pin_count=$((pin_count + 1))
      body="${pin_line#pin:}"
      kind="$(printf '%s' "$body" | awk -F'|' '{print $1}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      want="$(printf '%s' "$body" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      target="$(printf '%s' "$body" | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      pattern="$(printf '%s' "$body" | awk -F'|' '{ n=index($0, $4); print substr($0, n) }' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      if ! printf '%s\n' $R2_PIN_KINDS | grep -qx -- "$kind"; then
        pin_bad=$((pin_bad + 1))
        _r2_finding "$fname pin kind is in the closed set" "unknown pin kind: '$kind'"
        continue
      fi
      got="$(_r2_eval_pin "$sub" "$kind" "$target" "$pattern" || true)"
      if [ -z "$got" ]; then
        pin_bad=$((pin_bad + 1))
        _r2_finding "$fname pin is evaluable" "could not recompute '$kind' over '$target'"
      elif [ "$got" != "$want" ]; then
        pin_bad=$((pin_bad + 1))
        _r2_finding "$fname pin matches disk" \
          "$kind over '$target' with /$pattern/ — pinned $want, recomputed $got"
      fi
    done < <(grep -E '^pin:' "$prov" 2>/dev/null || true)
    if [ "$pin_count" -eq 0 ]; then
      _r2_finding "$fname carries a form-pins block" \
        "tier 'captured-redacted' requires at least one 'pin:' line"
    elif [ "$pin_bad" -eq 0 ]; then
      _pass "R2: $fname declares tier 'captured-redacted'; all $pin_count form pin(s) recomputed and matched"
    fi
  done < <(find "$FIXTURES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi

R2_FLOOR="${NAZGUL_BOUNDARY_R2_FLOOR:-1}"
if [ "$R2_SCANNED" -ge "$R2_FLOOR" ]; then
  _pass "R2: the fixture enumerator found at least $R2_FLOOR subdirectory ($R2_SCANNED scanned)"
else
  _fail "R2: the fixture enumerator found at least $R2_FLOOR subdirectory" \
    "zero fixture subdirectories under $FIXTURES_DIR — a broken enumerator, not a clean tree"
fi

R2_SKIPPED=$((R2_SKIP_UNREADABLE + R2_SKIP_UNTRACKED))
if [ "$R2_SCANNED" -eq $((R2_SKIPPED + R2_CHECKED)) ]; then
  _pass "R2: coverage accounting adds up (N == M + K)"
else
  _fail "R2: coverage accounting adds up (N == M + K)" \
    "$R2_SCANNED scanned != $R2_SKIPPED skipped + $R2_CHECKED checked"
fi

# Prove a rotted pin is caught rather than trusted, against a corpus built here.
R2_TMP="$R1_TMP/r2-fixture"
mkdir -p "$R2_TMP/corpus"
printf 'verdict: APPROVE\n- REJECT: none\n' > "$R2_TMP/corpus/a.md"
printf 'verdict: APPROVE\n- REJECT: none.\n' > "$R2_TMP/corpus/b.md"

assert_eq "R2 self-check: file-count recomputes from disk" \
  "$(_r2_eval_pin "$R2_TMP" file-count corpus '*.md')" "2"
assert_eq "R2 self-check: occurrences counts occurrences, not files" \
  "$(_r2_eval_pin "$R2_TMP" occurrences corpus 'REJECT')" "2"
assert_eq "R2 self-check: matching-files counts distinct files" \
  "$(_r2_eval_pin "$R2_TMP" matching-files corpus '^-[[:space:]]*REJECT')" "2"

printf 'verdict: APPROVE\n' > "$R2_TMP/corpus/c.md"
STALE_PIN_GOT="$(_r2_eval_pin "$R2_TMP" file-count corpus '*.md')"
if [ "$STALE_PIN_GOT" != "2" ]; then
  _pass "R2 self-check: a stale pin no longer matches the recomputed value (pinned 2, recomputed $STALE_PIN_GOT)"
else
  _fail "R2 self-check: a stale pin no longer matches the recomputed value" \
    "the evaluator still returned 2 after a third file was added"
fi

if _r2_eval_pin "$R2_TMP" not-a-kind corpus 'x' >/dev/null 2>&1; then
  _fail "R2 self-check: an unknown pin kind is rejected" "the evaluator accepted 'not-a-kind'"
else
  _pass "R2 self-check: an unknown pin kind is rejected"
fi

if [ "$R1_CHECKED" -eq 0 ]; then
  echo "$TEST_NAME: NOTHING CHECKED — R1 checked 0 of $R1_SCANNED tracked files" >&2
fi
if [ "$R2_CHECKED" -eq 0 ]; then
  echo "$TEST_NAME: NOTHING CHECKED — R2 checked 0 of $R2_SCANNED fixture subdirectories" >&2
fi

RC=0
report_results || RC=1
printf '%s-r1: %d scanned, %d skipped (self-exempt=%d, binary=%d, unreadable=%d, not-a-file=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$R1_SCANNED" "$R1_SKIPPED" "$R1_SKIP_SELF" "$R1_SKIP_BINARY" \
  "$R1_SKIP_UNREADABLE" "$R1_SKIP_NOT_A_FILE" "$R1_CHECKED" "$R1_FINDINGS"
printf '%s-r2: %d scanned, %d skipped (unreadable=%d, untracked=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$R2_SCANNED" "$R2_SKIPPED" "$R2_SKIP_UNREADABLE" "$R2_SKIP_UNTRACKED" \
  "$R2_CHECKED" "$R2_FINDINGS"
exit "$RC"
