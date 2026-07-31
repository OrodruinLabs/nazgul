#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — this test drives a script whose exit code IS the
# assertion under test, so a nonzero exit must reach the assertions, not kill
# the runner.

# Test: scripts/doctor.sh (FEAT-025/TASK-001) — the read-only preflight
# check engine plus checks (b) dependencies, (f) config-schema staleness,
# (g) never-EOF-stdin note. Checks (a)/(c)/(d)/(e) are added to this same
# file by TASK-002/TASK-003 and are out of scope here.
TEST_NAME="test-doctor"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

DOCTOR="$REPO_ROOT/scripts/doctor.sh"

_dr_hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Recursive file-list + checksum snapshot of a directory, one "path hash"
# line per file, sorted — order-independent and content-sensitive.
_dr_snapshot() {
  local dir="$1" f
  while IFS= read -r f; do
    printf '%s %s\n' "${f#"$dir"/}" "$(_dr_hash_file "$f")"
  done < <(find "$dir" -type f | sort)
}

# _dr_shim_path <bin...> -> a directory on its own containing symlinks to the
# real location of each named binary, and nothing else — used to simulate a
# binary being entirely absent from PATH (unlike a PATH-prefix shim, which
# only shadows a name still resolvable further down the real PATH).
_dr_shim_path() {
  local shim; shim=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-shim-XXXXXX")
  local bin real
  for bin in "$@"; do
    real=$(command -v "$bin" 2>/dev/null) || continue
    ln -sf "$real" "$shim/$bin"
  done
  printf '%s' "$shim"
}

HIGHEST_MIGRATION=$(grep -oE 'migrate_[0-9]+_to_[0-9]+' "$REPO_ROOT/scripts/migrate-config.sh" \
  | sed -E 's/^migrate_[0-9]+_to_//' | sort -n | tail -1)

# --- Fixture 1: fully healthy project (pass branch for every scored check) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' '.board.enabled = false'

OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "healthy fixture: aggregate exit 0 (all pass)" "$EXIT" 0
assert_contains "healthy fixture: config-present pass" "$OUT" "$(printf 'pass\tconfig-present')"
assert_contains "healthy fixture: dependencies pass" "$OUT" "$(printf 'pass\tdependencies')"
assert_contains "healthy fixture: config-schema pass" "$OUT" "$(printf 'pass\tconfig-schema')"
assert_contains "healthy fixture: stdin-hazard note always printed" "$OUT" "$(printf 'note\tstdin-hazard')"
assert_not_contains "healthy fixture: no fail lines" "$OUT" "$(printf 'fail\t')"
assert_not_contains "healthy fixture: no warn lines" "$OUT" "$(printf 'warn\t')"

teardown_temp_dir

# --- config-present: warn branch (no nazgul/config.json at all) ---
setup_temp_dir
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "no-config fixture: aggregate exit 1 (worst=warn)" "$EXIT" 1
assert_contains "no-config fixture: config-present warns" "$OUT" "$(printf 'warn\tconfig-present')"
assert_contains "no-config fixture: still runs dependencies check" "$OUT" "$(printf '\tdependencies\t')"
assert_contains "no-config fixture: still prints stdin-hazard note" "$OUT" "$(printf 'note\tstdin-hazard')"
teardown_temp_dir

# --- (b) dependencies: fail branch — jq entirely absent from PATH ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
NOJQ_SHIM=$(_dr_shim_path dirname git grep sed sort tail cat bash gh)
OUT=$(PATH="$NOJQ_SHIM" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "jq-missing fixture: aggregate exit 2 (worst=fail)" "$EXIT" 2
assert_contains "jq-missing fixture: dependencies fails" "$OUT" "$(printf 'fail\tdependencies')"
assert_contains "jq-missing fixture: remediation names jq" "$OUT" "jq is not on PATH"
rm -rf "$NOJQ_SHIM"
teardown_temp_dir

# --- (b) dependencies: warn branch — gh required (connectors enabled) but absent ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.connectors.github.enabled = true'
NOGH_SHIM=$(_dr_shim_path dirname git grep sed sort tail cat bash jq)
OUT=$(PATH="$NOGH_SHIM" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-missing-but-required fixture: aggregate exit 1 (worst=warn)" "$EXIT" 1
assert_contains "gh-missing-but-required fixture: dependencies warns" "$OUT" "$(printf 'warn\tdependencies')"
assert_contains "gh-missing-but-required fixture: remediation names gh" "$OUT" "gh is not on PATH"
rm -rf "$NOGH_SHIM"
teardown_temp_dir

# --- (b) dependencies: pass branch — gh not required and not installed ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.connectors.github.enabled = false' '.board.enabled = false'
OUT=$(PATH="$(_dr_shim_path dirname git grep sed sort tail cat bash jq)" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-not-required fixture: aggregate exit 0" "$EXIT" 0
assert_contains "gh-not-required fixture: dependencies passes with gh absent+optional" "$OUT" "$(printf 'pass\tdependencies')"
teardown_temp_dir

# --- (b) gh auth status probing: only when connectors.github/board enabled ---
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'FAKE_GH_EOF'
#!/usr/bin/env bash
echo "$*" >> "${NAZGUL_TEST_GH_CALLS:?}"
case "$1 $2" in
  "auth status") [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$FAKEBIN/gh"

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.connectors.github.enabled = false' '.board.enabled = false'
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
OUT=$(NAZGUL_TEST_GH_CALLS="$CALL_LOG" PATH="$FAKEBIN:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-not-needed fixture: aggregate exit 0" "$EXIT" 0
assert_file_not_contains "gh-not-needed fixture: gh auth status is NEVER invoked" "$CALL_LOG" "auth status"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.connectors.github.enabled = true'
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
OUT=$(NAZGUL_TEST_GH_CALLS="$CALL_LOG" NAZGUL_TEST_GH_AUTH=ok PATH="$FAKEBIN:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-authenticated fixture: aggregate exit 0" "$EXIT" 0
assert_contains "gh-authenticated fixture: dependencies pass" "$OUT" "$(printf 'pass\tdependencies')"
assert_file_contains "gh-needed fixture: gh auth status IS invoked" "$CALL_LOG" "auth status"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.board.enabled = true'
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
OUT=$(NAZGUL_TEST_GH_CALLS="$CALL_LOG" NAZGUL_TEST_GH_AUTH=fail PATH="$FAKEBIN:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-not-authenticated fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "gh-not-authenticated fixture: dependencies warns" "$OUT" "$(printf 'warn\tdependencies')"
assert_file_contains "board-enabled fixture: gh auth status IS invoked" "$CALL_LOG" "auth status"
teardown_temp_dir

rm -rf "$FAKEBIN"

# --- (f) config-schema: warn branch — live schema behind the latest migration target ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.schema_version = 1'
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stale-schema fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stale-schema fixture: config-schema warns" "$OUT" "$(printf 'warn\tconfig-schema')"
assert_contains "stale-schema fixture: message names live version" "$OUT" "schema_version 1"
assert_contains "stale-schema fixture: message names highest target" "$OUT" "target $HIGHEST_MIGRATION"
assert_contains "stale-schema fixture: message points at the migration entry point" "$OUT" "scripts/migrate-config.sh"
teardown_temp_dir

# --- (f) config-schema: pass branch — live schema at the latest migration target ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config ".schema_version = $HIGHEST_MIGRATION"
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "current-schema fixture: aggregate exit 0" "$EXIT" 0
assert_contains "current-schema fixture: config-schema passes" "$OUT" "$(printf 'pass\tconfig-schema')"
teardown_temp_dir

# --- Aggregate exit-code contract: fail dominates warn ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.schema_version = 1'
MIXED_SHIM=$(_dr_shim_path dirname git grep sed sort tail cat bash gh)
OUT=$(PATH="$MIXED_SHIM" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "fail+warn mixed fixture: aggregate exit 2 (fail dominates warn)" "$EXIT" 2
assert_contains "fail+warn mixed fixture: dependencies fails" "$OUT" "$(printf 'fail\tdependencies')"
assert_contains "fail+warn mixed fixture: config-schema still warns" "$OUT" "$(printf 'warn\tconfig-schema')"
assert_contains "fail+warn mixed fixture: stdin-hazard note still printed, doesn't change verdict" "$OUT" "$(printf 'note\tstdin-hazard')"
rm -rf "$MIXED_SHIM"
teardown_temp_dir

# --- Zero-write guarantee: nazgul/ is byte-identical before and after a full run ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.schema_version = 1' '.connectors.github.enabled = true'
BEFORE=$(_dr_snapshot "$TEST_DIR/nazgul")
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
FAKEBIN2=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-fakebin2-XXXXXX")
cp "$FAKEBIN/gh" "$FAKEBIN2/gh" 2>/dev/null || cat > "$FAKEBIN2/gh" << 'FAKE_GH_EOF2'
#!/usr/bin/env bash
echo "$*" >> "${NAZGUL_TEST_GH_CALLS:?}"
case "$1 $2" in
  "auth status") exit 0 ;;
esac
exit 0
FAKE_GH_EOF2
chmod +x "$FAKEBIN2/gh"
NAZGUL_TEST_GH_CALLS="$CALL_LOG" NAZGUL_TEST_GH_AUTH=ok PATH="$FAKEBIN2:$PATH" "$DOCTOR" >/dev/null 2>&1
AFTER=$(_dr_snapshot "$TEST_DIR/nazgul")
assert_eq "zero-write guarantee: nazgul/ snapshot identical before/after a full doctor run" "$AFTER" "$BEFORE"
rm -rf "$FAKEBIN2"
teardown_temp_dir

report_results
