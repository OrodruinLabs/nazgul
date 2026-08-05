#!/usr/bin/env bash
set -euo pipefail

# Test: All shell scripts pass bash -n and shellcheck
TEST_NAME="test-shellcheck"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# Discover scripts via glob (sorted, deterministic) rather than a hand-maintained
# array, so every script under scripts/ — including libraries added after this
# file was last touched — gets bash -n + shellcheck coverage automatically.
# tests/ files use dynamic `source` and are not standalone scripts; shellcheck
# cannot resolve the sourced paths without annotations. The glob is
# intentionally scoped to scripts/ only to keep the convention consistent.
# Git hook entry points (scripts/git-hooks/pre-commit, pre-merge-commit) are
# bash scripts without a .sh suffix, by githooks(5) naming convention; a bare
# `-name '*.sh'` glob would silently drop them, so they're picked up via their
# shebang instead of a second hardcoded name list.
# Env-injectable for the same reason SHELLCHECK_FALLBACK_BIN is: the zero-candidate
# and all-skipped branches are unreachable against a healthy repo.
SCAN_ROOT="${NAZGUL_SHELLCHECK_SCAN_ROOT:-$REPO_ROOT}"

mapfile -t SCRIPTS < <(cd "$SCAN_ROOT" && {
  find scripts -name '*.sh'
  find scripts -type f ! -name '*.sh' -exec grep -lE '^#!.*/(env )?(bash|sh)([[:space:]]|$)' {} \;
} 2>/dev/null | sort -u)

SC_SCANNED=${#SCRIPTS[@]}
SC_CHECKED=0
SC_SKIP_NOT_A_FILE=0
SC_SKIP_UNREADABLE=0
SC_FINDINGS=0

# Sanity check: validate coverage by PATH, not by total count. A count-only check
# (discovered >= live .sh count) can pass while a real .sh file is dropped, because
# the discovered set also includes extensionless hooks that can mask the shortfall.
# Instead, assert every scripts/**/*.sh path is present in the discovered set.
MISSING_SH=$(comm -23 \
  <(cd "$SCAN_ROOT" && find scripts -type f -name '*.sh' 2>/dev/null | sort -u) \
  <(printf '%s\n' "${SCRIPTS[@]}" | sort -u))
if [ -z "$MISSING_SH" ]; then
  _pass "every scripts/**/*.sh file is in the shellcheck set"
else
  _fail "every scripts/**/*.sh file is in the shellcheck set" "missing: $(echo "$MISSING_SH" | tr '\n' ' ')"
fi

# bash -n syntax checks. A candidate the enumerator produced but this stage
# cannot open is counted and named, never folded into the passing set.
CHECKED_SCRIPTS=()
for script in "${SCRIPTS[@]}"; do
  full_path="$SCAN_ROOT/$script"
  name=$(basename "$script")
  if [ ! -f "$full_path" ]; then
    SC_SKIP_NOT_A_FILE=$((SC_SKIP_NOT_A_FILE + 1))
    echo "  SKIP: $name (not a regular file — not checked)"
    continue
  fi
  if [ ! -r "$full_path" ]; then
    SC_SKIP_UNREADABLE=$((SC_SKIP_UNREADABLE + 1))
    echo "  SKIP: $name (unreadable — not checked)"
    continue
  fi
  SC_CHECKED=$((SC_CHECKED + 1))
  if bash -n "$full_path" 2>/dev/null; then
    CHECKED_SCRIPTS+=("$script")
    _pass "$name passes bash -n"
  else
    SC_FINDINGS=$((SC_FINDINGS + 1))
    _fail "$name passes bash -n" "syntax error detected"
  fi
done

# MF-057's local _skip/TESTS_SKIPPED moved into tests/lib/assertions.sh by
# FEAT-028 TASK-017, so every file in the suite counts skips the same way.

# _resolve_shellcheck_bin -> prints the shellcheck binary to use, or nothing
# when absent from both PATH and the CI-installed fallback path. Factored out
# so the MF-057 self-check below can drive it with a PATH-shadowing test
# double instead of depending on this machine's real toolchain state.
_resolve_shellcheck_bin() {
  # Fallback path is env-injectable (SHELLCHECK_FALLBACK_BIN) so the MF-057
  # self-check can force it absent deterministically instead of assuming the
  # default path doesn't exist on this machine.
  local fallback="${SHELLCHECK_FALLBACK_BIN:-/tmp/shellcheck-v0.10.0/shellcheck}"
  if command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck"
  elif [ -x "$fallback" ]; then
    echo "$fallback"
  fi
}

# _report_shellcheck_stage <bin> <script...> -> shellcheck's the given
# scripts with <bin>, or reports each as SKIPPED (not PASSED) when <bin> is
# empty. Factored out of the main stage so the MF-057 self-check can invoke
# the real reporting logic directly with a forced-absent <bin>, instead of
# asserting against a hand-duplicated copy of it.
_report_shellcheck_stage() {
  local bin="$1"
  shift
  local script full_path name
  if [ -n "$bin" ]; then
    for script in "$@"; do
      full_path="$SCAN_ROOT/$script"
      name=$(basename "$script")
      if "$bin" -S warning "$full_path" 2>/dev/null; then
        _pass "$name passes shellcheck"
      else
        SC_FINDINGS=$((SC_FINDINGS + 1))
        _fail "$name passes shellcheck" "shellcheck warnings found"
      fi
    done
  else
    echo "  SKIP: shellcheck not found (install with: brew install shellcheck)"
    for script in "$@"; do
      name=$(basename "$script")
      _skip "$name shellcheck (skipped — not installed)"
    done
  fi
}

SHELLCHECK_BIN=$(_resolve_shellcheck_bin)
_report_shellcheck_stage "$SHELLCHECK_BIN" ${CHECKED_SCRIPTS[@]+"${CHECKED_SCRIPTS[@]}"}

# --- MF-057 self-check: prove the "not installed" branch reports SKIPPED,
# never a fake PASS, rather than trusting this machine's real toolchain to
# stay absent/present the same way in every environment. ---

# 1. PATH-shadowing test double: an empty stub dir on PATH, with the fallback
#    forced to a guaranteed-nonexistent path — fully deterministic regardless
#    of what exists at the real fallback location on this machine.
STUB_PATH_DIR=$(mktemp -d)
RESOLVED_UNDER_STUB=$(PATH="$STUB_PATH_DIR" SHELLCHECK_FALLBACK_BIN="$STUB_PATH_DIR/definitely-absent" _resolve_shellcheck_bin)
if [ -z "$RESOLVED_UNDER_STUB" ]; then
  _pass "MF-057 self-check: _resolve_shellcheck_bin reports absent under a PATH-shadowing test double"
else
  _fail "MF-057 self-check: _resolve_shellcheck_bin reports absent under a PATH-shadowing test double" \
    "resolved: '$RESOLVED_UNDER_STUB'"
fi
rmdir "$STUB_PATH_DIR" 2>/dev/null || true

# 2. Real reporting function, forced-absent bin: must emit SKIP, never a
#    fake "passes shellcheck" PASS line, for a stand-in script name.
FAKE_ABSENT_OUTPUT=$(_report_shellcheck_stage "" "scripts/mf-057-selfcheck-fake.sh")
assert_contains "MF-057 self-check: absent-shellcheck branch reports SKIP" \
  "$FAKE_ABSENT_OUTPUT" "SKIP: mf-057-selfcheck-fake.sh shellcheck (skipped — not installed)"
assert_not_contains "MF-057 self-check: absent-shellcheck branch never emits a fake PASS" \
  "$FAKE_ABSENT_OUTPUT" "passes shellcheck"

if [ "$TESTS_SKIPPED" -gt 0 ]; then
  echo "  ($TESTS_SKIPPED shellcheck check(s) SKIPPED — shellcheck not installed on this machine/PATH)"
fi

# Blocking disposition (TRD §6): zero candidates is a broken enumerator, not a clean
# repo. No bus write — a test file never touches runtime state (TASK-006 precedent).
SC_SKIPPED=$((SC_SKIP_NOT_A_FILE + SC_SKIP_UNREADABLE))
if [ "$SC_SCANNED" -ne $((SC_SKIPPED + SC_CHECKED)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $SC_SCANNED scanned != $SC_SKIPPED skipped + $SC_CHECKED checked" >&2
  _fail "coverage accounting adds up (N == M + K)" "$SC_SCANNED != $SC_SKIPPED + $SC_CHECKED"
fi
if [ "$SC_CHECKED" -eq 0 ]; then
  if [ "$SC_SCANNED" -eq 0 ]; then
    echo "$TEST_NAME: NOTHING CHECKED — no shell scripts discovered under $SCAN_ROOT/scripts" >&2
    _fail "the enumerator found at least one shell script to check" \
      "zero candidates under $SCAN_ROOT/scripts — a broken enumerator, not a clean repo"
  else
    echo "$TEST_NAME: NOTHING CHECKED — all $SC_SCANNED candidates skipped" >&2
    _fail "at least one discovered shell script was actually checked" \
      "all $SC_SCANNED candidates skipped"
  fi
fi

RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (not-a-file=%d, unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$SC_SCANNED" "$SC_SKIPPED" "$SC_SKIP_NOT_A_FILE" "$SC_SKIP_UNREADABLE" \
  "$SC_CHECKED" "$SC_FINDINGS"
exit "$RC"
