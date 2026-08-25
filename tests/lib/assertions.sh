#!/usr/bin/env bash
# Nazgul Test Assertions Library
# Sourced by all test-*.sh files. Tracks pass/fail counts and prints results.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0
TESTS_SKIPPED=0
NOTHING_CHECKED_EXIT=2

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "  PASS: %s\n" "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "  FAIL: %s\n" "$1"
  shift
  for line in "$@"; do
    printf "        %s\n" "$line"
  done
}

# A check the environment could not run. Counted apart from pass/fail so an absent
# tool or an unproducible condition never reads as a check that passed (MF-057).
_skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf "  SKIP: %s\n" "$1"
}

# grep exit >=2 means it could not evaluate the needle at all (a `-`-leading needle
# is read as an option; a malformed BRE aborts) — a test defect, not a no-match.
_assert_unevaluable() {
  _fail "$1" "grep could not evaluate the needle/pattern (exit $2) — test defect, not a negative result" \
    "  needle: '$3'" "  fix: the needle is unparseable as given; pass it via -e/-- or escape it"
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected: '$expected'" "  actual: '$actual'"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3" rc=0
  # lean-comments: allow-run — the pipefail hazard the here-string removes, kept at the site.
  # String assertions are literal: callers do not need to escape BRE syntax.
  # Here-string, not `echo | grep`: grep -q's early exit SIGPIPEs the writer, which
  # pipefail reports as failure once the haystack exceeds the pipe buffer (~64KB).
  grep -qF -e "$needle" <<<"$haystack" || rc=$?
  case "$rc" in
    0) _pass "$name" ;;
    1) _fail "$name" "expected to contain: '$needle'" "  in: '${haystack:0:200}'" ;;
    *) _assert_unevaluable "$name" "$rc" "$needle" ;;
  esac
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3" rc=0
  # String assertions are literal: callers do not need to escape BRE syntax.
  grep -qF -e "$needle" <<<"$haystack" || rc=$?
  case "$rc" in
    0) _fail "$name" "expected NOT to contain: '$needle'" "  in: '${haystack:0:200}'" ;;
    1) _pass "$name" ;;
    *) _assert_unevaluable "$name" "$rc" "$needle" ;;
  esac
}

assert_exit_code() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" -eq "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit code: $expected" "  actual exit code: $actual"
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "file does not exist: $path"
  fi
}

assert_file_not_exists() {
  local name="$1" path="$2"
  if [ ! -f "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "file should not exist: $path"
  fi
}

assert_dir_exists() {
  local name="$1" path="$2"
  if [ -d "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "directory does not exist: $path"
  fi
}

assert_dir_not_exists() {
  local name="$1" path="$2"
  if [ ! -d "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "directory should not exist: $path"
  fi
}

assert_json_field() {
  local name="$1" file="$2" jq_path="$3" expected="$4"
  if [ ! -f "$file" ]; then
    _fail "$name" "JSON file not found: $file"
    return
  fi
  local actual
  actual=$(jq -r "$jq_path" "$file" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "jq '$jq_path' expected: '$expected'" "  actual: '$actual'"
  fi
}

assert_file_contains() {
  local name="$1" file="$2" pattern="$3" rc=0
  # File assertions intentionally accept a basic regular expression (BRE).
  if [ ! -f "$file" ]; then
    _fail "$name" "file not found: $file"
    return
  fi
  grep -q -e "$pattern" "$file" || rc=$?
  case "$rc" in
    0) _pass "$name" ;;
    1) _fail "$name" "file '$file' does not contain pattern: '$pattern'" ;;
    *) _assert_unevaluable "$name" "$rc" "$pattern" ;;
  esac
}

assert_file_not_contains() {
  local name="$1" file="$2" pattern="$3" rc=0
  # File assertions intentionally accept a basic regular expression (BRE).
  # An absent file is "never looked", not "looked and found none" (RULES §15).
  if [ ! -f "$file" ]; then
    _fail "$name" "file not found: $file — absence cannot stand in for a negative result"
    return
  fi
  grep -q -e "$pattern" "$file" || rc=$?
  case "$rc" in
    0) _fail "$name" "file '$file' should not contain pattern: '$pattern'" ;;
    1) _pass "$name" ;;
    *) _assert_unevaluable "$name" "$rc" "$pattern" ;;
  esac
}

NAZGUL_DIGEST_TOOLS='sha256sum, shasum -a 256, openssl dgst -sha256'
NAZGUL_DIGEST_SENTINEL='DIGEST-UNAVAILABLE'

# lean-comments: allow-run — the false pass this helper removes, kept at the helper.
# A digest that could not be computed is not a digest. The private copies this
# replaces returned the empty string when no tool existed, so BOTH operands of a
# byte-identity assertion came back empty, compared equal, and the assertion
# reported "unchanged" without ever reading the file (PR #240 finding 15). Absence
# is a finding here: the sentinel is non-hex on purpose, so a caller that ignores
# the exit status still holds an operand that cannot compare equal to a digest.
_digest_unavailable() {
  printf '%s(tried: %s)' "$NAZGUL_DIGEST_SENTINEL" "$NAZGUL_DIGEST_TOOLS"
  printf 'DIGEST TOOL ABSENT: tried %s — byte-identity was NOT checked\n' \
    "$NAZGUL_DIGEST_TOOLS" >&2
  return 1
}

# Ordered by host coverage, not preference: GNU coreutils, then the perl script
# macOS ships, then openssl for minimal images carrying neither.
digest_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    _digest_unavailable
  fi
}

digest_file() { # <path> -> hex on stdout; exit 2 absent, exit 1 no tool
  local path="$1"
  if [ ! -f "$path" ]; then
    printf '%s(absent: %s)' "$NAZGUL_DIGEST_SENTINEL" "$path"
    return 2
  fi
  digest_stdin < "$path"
}

digest_string() { printf '%s' "$1" | digest_stdin; }

_digest_is_hex() {
  case "$1" in ""|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

# lean-comments: allow-run — the two call conventions a caller cannot infer from the signature.
# Records digest_file <path> into the variable NAMED by <var>. Never call it through
# $( ): _fail's counters live in the caller's shell, and a subshell drops them. Always
# returns 0, like every assert_* here — a set -e file must report the named failure and
# keep running, not truncate at it. The var is left EMPTY on failure, so the byte-identity
# assertion downstream fails a second time rather than comparing an uncomputed value.
record_file_digest() { # <var-name> <path> [<label>]
  local __var="$1" path="$2" label="${3:-$2}" d rc=0
  d=$(digest_file "$path") || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf -v "$__var" '%s' ""
    _fail "digest baseline: $label" "file does not exist: $path" \
      "  a file with no baseline can never be shown unchanged"
  elif ! _digest_is_hex "$d"; then
    printf -v "$__var" '%s' ""
    _fail "digest baseline: $label" "no digest tool on PATH — tried: $NAZGUL_DIGEST_TOOLS" \
      "  'could not compute' is not 'identical' — byte-identity was NOT checked" \
      "  fix: install coreutils (sha256sum), perl (shasum) or openssl"
  else
    printf -v "$__var" '%s' "$d"
  fi
  return 0
}

# The byte-identity assertion. An uncomputed operand on EITHER side fails by name
# instead of matching its equally uncomputed twin.
assert_file_unchanged() { # <name> <path> <baseline-digest>
  local name="$1" path="$2" before="$3" after rc=0
  if ! _digest_is_hex "$before"; then
    _fail "$name" "no usable baseline digest was recorded (got: '${before:-<empty>}')" \
      "  byte-identity was NOT checked — an uncomputed digest is not a match"
    return 0
  fi
  after=$(digest_file "$path") || rc=$?
  if [ "$rc" -eq 2 ]; then
    _fail "$name" "file no longer exists: $path — absence is not identity"
  elif ! _digest_is_hex "$after"; then
    _fail "$name" "no digest tool on PATH — tried: $NAZGUL_DIGEST_TOOLS" \
      "  'could not compute' is not 'identical' — byte-identity was NOT checked"
  else
    assert_eq "$name" "$after" "$before"
  fi
  return 0
}

# Deliberately WIDE: a digest name anywhere on a non-comment line under tests/** is
# a candidate, and every non-finding disposition below is NAMED and counted.
NZD_TOKEN='(^|[^A-Za-z0-9_])(sha256sum|shasum|md5sum|cksum|openssl[[:space:]]+dgst)([^A-Za-z0-9_]|$)'
NZD_HELPER_FILE='tests/lib/assertions.sh'

# lean-comments: allow-run — what makes an absent arm a finding rather than a silence.
# Enumerated exemptions, keyed by path AND by the distinguishing text of the line, so
# an arm can never blanket a whole file. A candidate that is neither the shared helper,
# an availability probe, nor listed here is a FINDING; and an arm naming a path this
# walk never actually exempted is a finding too (nzd_scan's staleness pass).
nzd_exemption() { # <rel-path> <line-text> -> justification, exit 0 if exempt
  case "$1" in
    tests/test-in-flight-hold.sh)
      case "$2" in
        *'P10_SHIM/sha256sum'*|*'P10_SHIM/shasum'*)
          echo "the token is a FILE PATH: the block writes and chmods stub binaries at those names to drive the no-digest-tool degradation, and never invokes a digest itself"
          return 0 ;;
        *'cksum'*)
          echo "cksum is a byte-identity check on the test's own config.json across one hook run, asserting the hold wrote an attempt ledger and NOT config state — it digests no security-relevant content and gates nothing"
          return 0 ;;
        *'P7B_SHIM/sha256sum'*|*'R2_EMPTY_SHIM/sha256sum'*)
          echo "the token is a FILE PATH: the #254 R2/P7b block writes and chmods stub binaries at those names to drive the malformed-digest rejection, and never invokes a digest itself"
          return 0 ;;
        *'an empty value writes and chmods /sha256sum outside any temp dir'*)
          echo "the token sits inside the _fail MESSAGE reporting that the shim dir was unusable and the P7b arm did not run; it names the hazard rather than computing anything"
          return 0 ;;
        *'shasum: option -a is deprecated'*)
          echo "the token is the STUB's own stdout inside a heredoc: shape 1 makes the fake sha256sum print a deprecation line before its digest, which IS the malformed input under test"
          return 0 ;;
        *'"$P7B_ERR" "shasum:"'*)
          echo "the token is the needle of an assert_not_contains proving the writer's stderr never echoes the rejected value; it asserts an ABSENCE and computes nothing"
          return 0 ;;
      esac ;;
    tests/test-shared-ignore-coverage.sh)
      case "$2" in
        *'a sha256 tool (sha256sum or shasum) is on PATH'*)
          echo "the token sits inside the _fail message of an AVAILABILITY precondition — with neither tool present the local-fence digest pin would be vacuous rather than passing; the hashing itself goes through nz_sha256 (scripts/lib/sha256.sh)"
          return 0 ;;
      esac ;;
    tests/test-task-transition-command.sh)
      case "$2" in
        *'HASHBIN/sha256sum'*)
          echo "the token is a FILE PATH: the block writes, chmods and removes a stub binary at that name and never invokes a digest itself"
          return 0 ;;
        *_skip*)
          echo "the token names the absent tool inside the skip message reporting that the staged-snapshot race was not checked"
          return 0 ;;
      esac ;;
  esac
  return 1
}

NZD_EXEMPTION_FN="${NZD_EXEMPTION_FN:-nzd_exemption}"

# Derived from the live function's own case arms, so a staleness check cannot read
# a list the oracle has moved past.
_nzd_exemption_paths() {
  declare -f "$NZD_EXEMPTION_FN" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(?tests/[A-Za-z0-9._/-]+\)' | tr -d '() \t'
}

# nzd_scan <tests-root> — N/M/K count candidate LINES; F additionally counts unreadable
# files and stale exemption arms, which are findings without being candidate lines.
nzd_scan() {
  local root="$1" f rel entry lineno text stripped
  NZD_N=0; NZD_M=0; NZD_K=0; NZD_F=0
  NZD_M_COMMENT=0; NZD_HELPER_LINES=0; NZD_PROBE=0; NZD_EXEMPT=0; NZD_UNREADABLE=0
  NZD_FINDINGS=""; NZD_UNREADABLE_FILES=""; NZD_STALE=""; NZD_EXEMPTED_PATHS=""

  [ -d "$root" ] || return 1

  while IFS= read -r -u 9 f; do
    rel="tests/${f#"$root"/}"
    if [ ! -r "$f" ]; then
      NZD_UNREADABLE=$((NZD_UNREADABLE + 1)); NZD_F=$((NZD_F + 1))
      NZD_UNREADABLE_FILES="${NZD_UNREADABLE_FILES}${rel}"$'\n'
      continue
    fi
    while IFS= read -r -u 8 entry; do
      lineno="${entry%%:*}"; text="${entry#*:}"
      stripped="${text#"${text%%[![:space:]]*}"}"
      NZD_N=$((NZD_N + 1))
      case "$stripped" in
        '#'*) NZD_M=$((NZD_M + 1)); NZD_M_COMMENT=$((NZD_M_COMMENT + 1)); continue ;;
      esac
      NZD_K=$((NZD_K + 1))
      if [ "$rel" = "$NZD_HELPER_FILE" ]; then
        NZD_HELPER_LINES=$((NZD_HELPER_LINES + 1)); continue
      fi
      case "$stripped" in
        *'command -v'*) NZD_PROBE=$((NZD_PROBE + 1)); continue ;;
      esac
      if "$NZD_EXEMPTION_FN" "$rel" "$stripped" >/dev/null; then
        NZD_EXEMPT=$((NZD_EXEMPT + 1))
        NZD_EXEMPTED_PATHS="${NZD_EXEMPTED_PATHS}${rel}"$'\n'
        continue
      fi
      NZD_F=$((NZD_F + 1))
      NZD_FINDINGS="${NZD_FINDINGS}${rel}:${lineno}: ${stripped}"$'\n'
    done 8< <(grep -nE "$NZD_TOKEN" "$f" || true)
  done 9< <(find "$root" -name '*.sh' -type f | LC_ALL=C sort)

  while IFS= read -r -u 9 rel; do
    [ -n "$rel" ] || continue
    case $'\n'"$NZD_EXEMPTED_PATHS" in *$'\n'"$rel"$'\n'*) continue ;; esac
    NZD_STALE="${NZD_STALE}${rel}"$'\n'; NZD_F=$((NZD_F + 1))
  done 9< <(_nzd_exemption_paths)
  return 0
}

nzd_coverage_line() { # <label>
  printf '  %s: %d scanned, %d skipped (comment=%d), %d checked, %d findings\n' \
    "$1" "$NZD_N" "$NZD_M" "$NZD_M_COMMENT" "$NZD_K" "$NZD_F"
}

# The three pre-fix shapes PR #240 reported, synthesised from the SAME tool names the
# dispatch above uses, so a regex that stopped matching them cannot read as a clean sweep.
nzd_dogfood_fixture() { # <path>
  local path="$1" gnu='sha256sum' perl='shasum'
  {
    printf '#!/usr/bin/env bash\n'
    printf '# a prose mention of %s is not an invocation\n' "$perl"
    printf 'Q_BEFORE=$(%s "$Q_TASK" | cut -d" " -f1)\n' "$perl"
    printf 'LIVE_SUM_BEFORE=$(%s "$LIVE_CONFIG" | cut -d" " -f1)\n' "$perl"
    printf 'CONFIG_BEFORE=$(%s -a 256 < "$CFG" | cut -d" " -f1)\n' "$perl"
    printf 'if command -v %s >/dev/null 2>&1; then :; fi\n' "$gnu"
  } > "$path"
}

report_results() {
  echo ""
  echo "---"
  printf "%s: %d/%d passed" "${TEST_NAME:-tests}" "$TESTS_PASSED" "$TESTS_RUN"
  [ "$TESTS_SKIPPED" -gt 0 ] && printf " (%d SKIPPED — not checked)" "$TESTS_SKIPPED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf " (%d FAILED)" "$TESTS_FAILED"
    echo ""
    return 1
  fi
  echo ""
  # A file that asserted nothing has not passed; it has not run. Reporting success
  # here is the vacuous green the harness's own zero-match fix abolished (D-6).
  if [ "$TESTS_RUN" -eq 0 ]; then
    printf '%s: NOTHING CHECKED — 0 assertions ran (%d skipped)\n' \
      "${TEST_NAME:-tests}" "$TESTS_SKIPPED" >&2
    return "$NOTHING_CHECKED_EXIT"
  fi
  return 0
}
