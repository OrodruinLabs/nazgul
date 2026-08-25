#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — this test drives a script whose exit code IS the
# assertion under test, so a nonzero exit must reach the assertions, not kill
# the runner.

# Test: scripts/doctor.sh — the read-only preflight check engine (TASK-001,
# checks (b)/(f)/(g)) plus checks (a) cache-vs-repo version, (c) git-hooks
# drift, (d) bash-vs-zsh hazard (TASK-002), and (e) NAZGUL_DIR footgun
# (TASK-003), and (k) messaging / (l) remote-control / (m) sessions
# (FEAT-032/TASK-009).
TEST_NAME="test-doctor"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/git-hooks.sh"

echo "=== $TEST_NAME ==="

DOCTOR="$REPO_ROOT/scripts/doctor.sh"

# The roster size is read from the script under test, so "every check reported"
# is a comparison against the DECLARED roster rather than a literal that drifts.
DR_ROSTER_COUNT=$(grep -m1 '^_DOC_CHECK_IDS=' "$DOCTOR" | sed -E 's/^_DOC_CHECK_IDS="([^"]*)"$/\1/' | wc -w | tr -d ' ' || true)

# The shipped ephemeral-block first line, read from the skill that writes it — the same
# derivation check (j) performs, so this fixture tracks a version bump instead of pinning one.
DR_SHIPPED_BLOCK_LINE=$(grep -m1 '^# Nazgul Framework — ephemeral runtime' "$REPO_ROOT/skills/init/SKILL.md")
DR_SHIPPED_LOCAL_LINE=$(grep -m1 '^# Nazgul Framework (local mode)' "$REPO_ROOT/skills/init/SKILL.md")

# Local-mode fixtures need the LOCAL block: _dr_config writes the shared one, and since round-3
# finding 7 check (j) reads whichever block install_mode names rather than skipping local outright.
_dr_local_gitignore() {
  printf '%s\nnazgul/\n.claude/agents/generated/\n.mcp.json\n%s\n' \
    "$DR_SHIPPED_LOCAL_LINE" '# Nazgul Framework — end local mode' > "$TEST_DIR/.gitignore"
}

# templates/config.json ships install_mode "shared", so check (j) fires in EVERY fixture below and
# an absent block would push each aggregate exit to 1. _dr_config installs the current block too.
_dr_config() {
  create_config "$@"
  printf '%s\nnazgul/logs/\n# Nazgul Framework — end ephemeral runtime\n' "$DR_SHIPPED_BLOCK_LINE" > "$TEST_DIR/.gitignore"
}

# Checks (k)/(l) read the operator's real shell env, so a host that exports a
# feature-flag killer would flip every full-run aggregate-exit assertion below.
unset DO_NOT_TRACK DISABLE_TELEMETRY DISABLE_GROWTHBOOK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
unset ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX

# Snapshots are taken inside $( ), where a failure cannot reach the counters. An
# absent helper AND an absent tool both yield a non-64 probe, so neither is silent.
NZ_DIGEST_PROBE=$(digest_string probe || true)
assert_eq "doctor snapshots: the shared digest helper returns a 64-hex digest, so no byte-identity check here is vacuous" \
  "${#NZ_DIGEST_PROBE}" "64"

_dr_hash_file() { digest_file "$1"; }

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

# _dr_plugin_root <version> -> a standalone dir with a .claude-plugin/plugin.json
# of that version, simulating $CLAUDE_PLUGIN_ROOT (the ACTIVE plugin instance).
_dr_plugin_root() {
  local ver="$1" dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-pluginroot-XXXXXX")
  mkdir -p "$dir/.claude-plugin"
  printf '{"name":"nazgul","version":"%s"}\n' "$ver" > "$dir/.claude-plugin/plugin.json"
  printf '%s' "$dir"
}

HIGHEST_MIGRATION=$(grep -oE 'migrate_[0-9]+_to_[0-9]+' "$REPO_ROOT/scripts/migrate-config.sh" \
  | sed -E 's/^migrate_[0-9]+_to_//' | sort -n | tail -1)

# --- Fixture 1: fully healthy project (pass branch for every scored check) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'

OUT=$(env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "healthy fixture: aggregate exit 0 (all pass)" "$EXIT" 0
assert_contains "healthy fixture: config-present pass" "$OUT" "$(printf 'pass\tconfig-present')"
assert_contains "healthy fixture: plugin-version pass (not applicable)" "$OUT" "$(printf 'pass\tplugin-version')"
assert_contains "healthy fixture: dependencies pass" "$OUT" "$(printf 'pass\tdependencies')"
assert_contains "healthy fixture: git-hooks pass (not applicable)" "$OUT" "$(printf 'pass\tgit-hooks')"
assert_contains "healthy fixture: invoking-shell pass" "$OUT" "$(printf 'pass\tinvoking-shell')"
assert_contains "healthy fixture: nazgul-dir-env pass" "$OUT" "$(printf 'pass\tnazgul-dir-env')"
assert_contains "healthy fixture: config-schema pass" "$OUT" "$(printf 'pass\tconfig-schema')"
assert_contains "healthy fixture: stacking pass (not applicable)" "$OUT" "$(printf 'pass\tstacking')"
assert_contains "healthy fixture: stack-registry pass (not applicable)" "$OUT" "$(printf 'pass\tstack-registry')"
assert_contains "healthy fixture: stdin-hazard note always printed" "$OUT" "$(printf 'note\tstdin-hazard')"
assert_not_contains "healthy fixture: no fail lines" "$OUT" "$(printf 'fail\t')"
assert_not_contains "healthy fixture: no warn lines" "$OUT" "$(printf 'warn\t')"

teardown_temp_dir

# --- config-present: warn branch (no nazgul/config.json at all) ---
setup_temp_dir
OUT=$(env -u CLAUDE_PLUGIN_ROOT "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "no-config fixture: aggregate exit 1 (worst=warn)" "$EXIT" 1
assert_contains "no-config fixture: config-present warns" "$OUT" "$(printf 'warn\tconfig-present')"
assert_contains "no-config fixture: still runs dependencies check" "$OUT" "$(printf '\tdependencies\t')"
assert_contains "no-config fixture: still prints stdin-hazard note" "$OUT" "$(printf 'note\tstdin-hazard')"
# A run that ABORTS mid-roster also exits 1, so the exit code alone cannot tell a
# warn from a truncated run: only the coverage line proves main() reached the end.
assert_contains "no-config fixture: every check after config-present ran too" "$OUT" "$(printf '\tmessaging\t')"
assert_contains "no-config fixture: the last check in the roster ran" "$OUT" "$(printf '\tsessions\t')"
assert_contains "no-config fixture: the run reached the coverage line, so it was not truncated" \
  "$(printf '%s' "$OUT" | tail -1)" "$DR_ROSTER_COUNT scanned"
teardown_temp_dir

# --- (b) dependencies: fail branch — jq entirely absent from PATH ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config
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
_dr_config '.connectors.github.enabled = true'
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
_dr_config '.connectors.github.enabled = false' '.board.enabled = false' '.guards.git_hooks = false'
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
_dr_config '.connectors.github.enabled = false' '.board.enabled = false' '.guards.git_hooks = false'
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
OUT=$(NAZGUL_TEST_GH_CALLS="$CALL_LOG" PATH="$FAKEBIN:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-not-needed fixture: aggregate exit 0" "$EXIT" 0
assert_file_not_contains "gh-not-needed fixture: gh auth status is NEVER invoked" "$CALL_LOG" "auth status"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.connectors.github.enabled = true' '.guards.git_hooks = false'
CALL_LOG="$TEST_DIR/gh-calls.log"; : > "$CALL_LOG"
OUT=$(NAZGUL_TEST_GH_CALLS="$CALL_LOG" NAZGUL_TEST_GH_AUTH=ok PATH="$FAKEBIN:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "gh-authenticated fixture: aggregate exit 0" "$EXIT" 0
assert_contains "gh-authenticated fixture: dependencies pass" "$OUT" "$(printf 'pass\tdependencies')"
assert_file_contains "gh-needed fixture: gh auth status IS invoked" "$CALL_LOG" "auth status"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.board.enabled = true'
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
_dr_config '.schema_version = 1'
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
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.guards.git_hooks = false'
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "current-schema fixture: aggregate exit 0" "$EXIT" 0
assert_contains "current-schema fixture: config-schema passes" "$OUT" "$(printf 'pass\tconfig-schema')"
teardown_temp_dir

# --- Aggregate exit-code contract: fail dominates warn ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.schema_version = 1'
MIXED_SHIM=$(_dr_shim_path dirname git grep sed sort tail cat bash gh)
OUT=$(PATH="$MIXED_SHIM" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "fail+warn mixed fixture: aggregate exit 2 (fail dominates warn)" "$EXIT" 2
assert_contains "fail+warn mixed fixture: dependencies fails" "$OUT" "$(printf 'fail\tdependencies')"
assert_contains "fail+warn mixed fixture: config-schema still warns" "$OUT" "$(printf 'warn\tconfig-schema')"
assert_contains "fail+warn mixed fixture: stdin-hazard note still printed, doesn't change verdict" "$OUT" "$(printf 'note\tstdin-hazard')"
rm -rf "$MIXED_SHIM"
teardown_temp_dir

# --- Zero-write guarantee: nazgul/ is byte-identical before and after a full run
# with every check (including (a)/(c)/(d), now all firing) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.schema_version = 1' '.connectors.github.enabled = true' '.guards.git_hooks = true'
install_git_hooks "$TEST_DIR" "$TEST_DIR/nazgul/config.json"
BEFORE=$(_dr_snapshot "$TEST_DIR/nazgul")
BEFORE_HOOKS_PATH=$(git -C "$TEST_DIR" config --get core.hooksPath)
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
PLUGIN_ROOT_ZW=$(_dr_plugin_root "1.2.3")
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_ZW" NAZGUL_TEST_GH_CALLS="$CALL_LOG" NAZGUL_TEST_GH_AUTH=ok \
  PATH="$FAKEBIN2:$PATH" "$DOCTOR" >/dev/null 2>&1
AFTER=$(_dr_snapshot "$TEST_DIR/nazgul")
AFTER_HOOKS_PATH=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_eq "zero-write guarantee: nazgul/ snapshot identical before/after a full doctor run" "$AFTER" "$BEFORE"
assert_eq "zero-write guarantee: core.hooksPath unchanged after a full doctor run" "$AFTER_HOOKS_PATH" "$BEFORE_HOOKS_PATH"
rm -rf "$FAKEBIN2" "$PLUGIN_ROOT_ZW"
teardown_temp_dir

# ---------------------------------------------------------------------------
# (a) plugin-version: not-applicable, mismatch, and match branches
# ---------------------------------------------------------------------------

# not applicable: default install_mode ("shared") + not a plugin-repo cwd,
# even with CLAUDE_PLUGIN_ROOT set to something real
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
PLUGIN_ROOT_NA=$(_dr_plugin_root "5.5.5")
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_NA" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "plugin-version not-applicable fixture: aggregate exit 0" "$EXIT" 0
assert_contains "plugin-version not-applicable fixture: passes as not applicable" "$OUT" "$(printf 'pass\tplugin-version')"
assert_contains "plugin-version not-applicable fixture: states the reason" "$OUT" "Not applicable"
rm -rf "$PLUGIN_ROOT_NA"
teardown_temp_dir

# not applicable: install_mode local but CLAUDE_PLUGIN_ROOT unset — never guess a path
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.install_mode = "local"' '.guards.git_hooks = false'
_dr_local_gitignore
OUT=$(env -u CLAUDE_PLUGIN_ROOT "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "plugin-version no-CLAUDE_PLUGIN_ROOT fixture: aggregate exit 0" "$EXIT" 0
assert_contains "plugin-version no-CLAUDE_PLUGIN_ROOT fixture: passes as not applicable" "$OUT" "$(printf 'pass\tplugin-version')"
assert_contains "plugin-version no-CLAUDE_PLUGIN_ROOT fixture: names CLAUDE_PLUGIN_ROOT as the reason" "$OUT" "CLAUDE_PLUGIN_ROOT is unset"
teardown_temp_dir

# match: install_mode local, active version == repo version
setup_temp_dir
setup_git_repo
setup_nazgul_dir
mkdir -p "$TEST_DIR/.claude-plugin"
printf '{"name":"nazgul","version":"9.9.9"}\n' > "$TEST_DIR/.claude-plugin/plugin.json"
_dr_config '.install_mode = "local"' '.guards.git_hooks = false'
_dr_local_gitignore
PLUGIN_ROOT_MATCH=$(_dr_plugin_root "9.9.9")
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_MATCH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "plugin-version match fixture: aggregate exit 0" "$EXIT" 0
assert_contains "plugin-version match fixture: passes" "$OUT" "$(printf 'pass\tplugin-version')"
rm -rf "$PLUGIN_ROOT_MATCH"
teardown_temp_dir

# match via plugin-repo cwd: install_mode NOT local, but cwd itself is a plugin repo
setup_temp_dir
setup_git_repo
setup_nazgul_dir
mkdir -p "$TEST_DIR/.claude-plugin"
printf '{"name":"nazgul","version":"3.0.0"}\n' > "$TEST_DIR/.claude-plugin/plugin.json"
_dr_config '.guards.git_hooks = false'
PLUGIN_ROOT_CWD=$(_dr_plugin_root "3.0.0")
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_CWD" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "plugin-version plugin-repo-cwd fixture: aggregate exit 0" "$EXIT" 0
assert_contains "plugin-version plugin-repo-cwd fixture: comparison runs though install_mode != local" "$OUT" "$(printf 'pass\tplugin-version')"
rm -rf "$PLUGIN_ROOT_CWD"
teardown_temp_dir

# mismatch: warn, both versions, cache-path pattern, documented-workaround language
setup_temp_dir
setup_git_repo
setup_nazgul_dir
mkdir -p "$TEST_DIR/.claude-plugin"
printf '{"name":"nazgul","version":"1.0.0"}\n' > "$TEST_DIR/.claude-plugin/plugin.json"
_dr_config '.install_mode = "local"' '.guards.git_hooks = false'
_dr_local_gitignore
PLUGIN_ROOT_MISMATCH=$(_dr_plugin_root "2.0.0")
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_MISMATCH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "plugin-version mismatch fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "plugin-version mismatch fixture: warns" "$OUT" "$(printf 'warn\tplugin-version')"
assert_contains "plugin-version mismatch fixture: names the active version" "$OUT" "2.0.0"
assert_contains "plugin-version mismatch fixture: names the repo version" "$OUT" "1.0.0"
# shellcheck disable=SC2088 # literal substring match, not a path to expand
assert_contains "plugin-version mismatch fixture: prints the cache-path pattern" "$OUT" "~/.claude/plugins/cache/"
assert_contains "plugin-version mismatch fixture: states documented-workaround language" "$OUT" "documented workaround"
assert_contains "plugin-version mismatch fixture: states no-platform-API language" "$OUT" "no platform API"
rm -rf "$PLUGIN_ROOT_MISMATCH"
teardown_temp_dir

# ---------------------------------------------------------------------------
# (c) git-hooks: not-applicable, unset, drifted, missing-hook, and pass branches
# ---------------------------------------------------------------------------

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = true'
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "git-hooks-unset fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "git-hooks-unset fixture: warns" "$OUT" "$(printf 'warn\tgit-hooks')"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = true'
git -C "$TEST_DIR" config core.hooksPath ".husky"
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "git-hooks-drifted fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "git-hooks-drifted fixture: warns" "$OUT" "$(printf 'warn\tgit-hooks')"
assert_contains "git-hooks-drifted fixture: names the drifted path" "$OUT" ".husky"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = true'
mkdir -p "$TEST_DIR/nazgul/.githooks"
touch "$TEST_DIR/nazgul/.githooks/pre-commit"
git -C "$TEST_DIR" config core.hooksPath "nazgul/.githooks"
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "git-hooks-missing-hook fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "git-hooks-missing-hook fixture: warns" "$OUT" "$(printf 'warn\tgit-hooks')"
assert_contains "git-hooks-missing-hook fixture: names the missing hook" "$OUT" "pre-merge-commit"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = true'
install_git_hooks "$TEST_DIR" "$TEST_DIR/nazgul/config.json"
BEFORE_GH_PATH=$(git -C "$TEST_DIR" config --get core.hooksPath)
OUT=$("$DOCTOR" 2>&1); EXIT=$?
AFTER_GH_PATH=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_exit_code "git-hooks-installed fixture: aggregate exit 0" "$EXIT" 0
assert_contains "git-hooks-installed fixture: passes" "$OUT" "$(printf 'pass\tgit-hooks')"
assert_eq "git-hooks-installed fixture: core.hooksPath unchanged after doctor run" "$AFTER_GH_PATH" "$BEFORE_GH_PATH"
teardown_temp_dir

# ---------------------------------------------------------------------------
# (d) invoking-shell: bash pass branch and a simulated non-bash warn branch
# ---------------------------------------------------------------------------

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$("$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "invoking-shell bash fixture: aggregate exit 0" "$EXIT" 0
assert_contains "invoking-shell bash fixture: passes" "$OUT" "$(printf 'pass\tinvoking-shell')"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$(NAZGUL_TEST_SHELL_NAME=zsh "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "invoking-shell non-bash fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "invoking-shell non-bash fixture: warns" "$OUT" "$(printf 'warn\tinvoking-shell')"
assert_contains "invoking-shell non-bash fixture: names the detected shell" "$OUT" "'zsh'"
assert_contains "invoking-shell non-bash fixture: remediation shows the bash -c pattern" "$OUT" "bash -c"
teardown_temp_dir

# ---------------------------------------------------------------------------
# (e) nazgul-dir-env: pass (unset) and warn (set) branches
# ---------------------------------------------------------------------------

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$(env -u NAZGUL_DIR "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "nazgul-dir-env unset fixture: aggregate exit 0" "$EXIT" 0
assert_contains "nazgul-dir-env unset fixture: passes" "$OUT" "$(printf 'pass\tnazgul-dir-env')"
assert_contains "nazgul-dir-env unset fixture: names CLAUDE_PROJECT_DIR as the seam" "$OUT" "CLAUDE_PROJECT_DIR"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$(NAZGUL_DIR="$TEST_DIR/nazgul" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "nazgul-dir-env set fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "nazgul-dir-env set fixture: warns" "$OUT" "$(printf 'warn\tnazgul-dir-env')"
assert_contains "nazgul-dir-env set fixture: states it has no effect" "$OUT" "has NO effect"
assert_contains "nazgul-dir-env set fixture: shows the corrected CLAUDE_PROJECT_DIR invocation with the PROJECT ROOT (trailing /nazgul stripped)" "$OUT" "CLAUDE_PROJECT_DIR=$TEST_DIR ..."
assert_not_contains "nazgul-dir-env set fixture: never suggests the doubled <root>/nazgul path as CLAUDE_PROJECT_DIR" "$OUT" "CLAUDE_PROJECT_DIR=$TEST_DIR/nazgul"
assert_contains "nazgul-dir-env set fixture: states CLAUDE_PROJECT_DIR must be one level above nazgul/" "$OUT" "one level above nazgul/"
teardown_temp_dir

# ---------------------------------------------------------------------------
# (h)/(i) stacking + stack-registry: FAKEBIN gh stub covering extension list
# and pr view, on top of the minimal auth-status variant above.
# ---------------------------------------------------------------------------

FAKEBIN_STACK=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-stack-fakebin-XXXXXX")
cat > "$FAKEBIN_STACK/gh" << 'FAKE_GH_STACK_EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
  "extension list")
    [ "${NAZGUL_TEST_GH_STACK_EXT:-yes}" = "yes" ] && printf 'gh stack\tgithub/gh-stack\t%s\n' "${NAZGUL_TEST_GH_STACK_VER-v0.1.0}"
    exit 0 ;;
  "pr view")
    [ "${NAZGUL_TEST_GH_PR_STATE:-OPEN}" = "FAIL" ] && exit 1
    printf '%s\n' "${NAZGUL_TEST_GH_PR_STATE:-OPEN}"
    exit 0 ;;
esac
exit 0
FAKE_GH_STACK_EOF
chmod +x "$FAKEBIN_STACK/gh"

STACK_LAYER_OPEN='.stack.layers = [{"feat_id":"FEAT-100","branch":"feat/x","pr":"https://github.com/o/r/pull/1","base":"main","state":"open","opened_at":"2026-01-01T00:00:00Z","merged_at":null}]'

# --- stacking disabled: both checks not-applicable, no gh call needed ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$(PATH="$(_dr_shim_path dirname git grep sed sort tail cat bash jq)" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking-disabled fixture: aggregate exit 0" "$EXIT" 0
assert_contains "stacking-disabled fixture: stacking not applicable" "$OUT" "Not applicable — execution.stacking.enabled is false."
assert_contains "stacking-disabled fixture: stack-registry not applicable" "$OUT" "Not applicable — execution.stacking.enabled is false."
teardown_temp_dir

# --- stacking enabled, gh entirely absent from PATH ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(PATH="$(_dr_shim_path dirname git grep sed sort tail cat bash jq)" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking gh-missing fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stacking gh-missing fixture: stacking warns" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "stacking gh-missing fixture: remediation names gh" "$OUT" "gh is not on PATH"
teardown_temp_dir

# --- stacking enabled, gh present but the gh-stack extension is not installed ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(NAZGUL_TEST_GH_STACK_EXT=no PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking extension-missing fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stacking extension-missing fixture: stacking warns" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "stacking extension-missing fixture: remediation names gh-stack install" "$OUT" "gh extension install github/gh-stack"
teardown_temp_dir

# --- stacking enabled, extension present but gh is not authenticated ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(NAZGUL_TEST_GH_AUTH=fail PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking not-authed fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stacking not-authed fixture: stacking warns" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "stacking not-authed fixture: remediation names gh auth login" "$OUT" "gh auth login"
teardown_temp_dir

# --- stacking enabled and halted: warns naming the halt reason, before any gh call ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' \
  '.execution.stacking.halted = true' '.execution.stacking.halt_reason = "sync conflict on FEAT-100"'
OUT=$(PATH="$(_dr_shim_path dirname git grep sed sort tail cat bash jq)" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking halted fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stacking halted fixture: stacking warns" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "stacking halted fixture: names the halt reason" "$OUT" "sync conflict on FEAT-100"
teardown_temp_dir

# --- stacking enabled and fully ready (gh, extension, auth) -> pass ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stacking ready fixture: aggregate exit 0" "$EXIT" 0
assert_contains "stacking ready fixture: stacking passes" "$OUT" "$(printf 'pass\tstacking')"
teardown_temp_dir

# --- stack-registry: open layer, PR still OPEN on GitHub -> pass, no drift ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
OUT=$(NAZGUL_TEST_GH_PR_STATE=OPEN PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry no-drift fixture: aggregate exit 0" "$EXIT" 0
assert_contains "stack-registry no-drift fixture: passes" "$OUT" "$(printf 'pass\tstack-registry')"
teardown_temp_dir

# --- stack-registry: open layer, PR MERGED on GitHub -> drift warn naming the layer ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
OUT=$(NAZGUL_TEST_GH_PR_STATE=MERGED PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry drift fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stack-registry drift fixture: warns" "$OUT" "$(printf 'warn\tstack-registry')"
assert_contains "stack-registry drift fixture: names the drifted layer" "$OUT" "FEAT-100(MERGED)"
assert_contains "stack-registry drift fixture: remediation points at reconcile" "$OUT" "reconcile the stack registry"
teardown_temp_dir

# --- stack-registry: open layer, PR CLOSED (unmerged) on GitHub -> drift warn too ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
OUT=$(NAZGUL_TEST_GH_PR_STATE=CLOSED PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry closed-drift fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stack-registry closed-drift fixture: warns" "$OUT" "$(printf 'warn\tstack-registry')"
assert_contains "stack-registry closed-drift fixture: names the drifted layer" "$OUT" "FEAT-100(CLOSED)"
teardown_temp_dir

# --- stack-registry: open layer with no recorded pr -> the ABANDONED-LAYER
# condition, named as a warn (TASK-013). It is not "drift we couldn't assess":
# nothing can ever mark a PR-less layer merged, so it counts against
# max_unmerged forever and stack_tip keeps handing it out as the next base. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' \
  '.stack.layers = [{"feat_id":"FEAT-101","branch":"feat/y","pr":null,"base":"main","state":"open","opened_at":"2026-01-01T00:00:00Z","merged_at":null}]'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry no-pr fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "stack-registry no-pr fixture: warns, naming the abandoned-layer condition" "$OUT" "Abandoned layer(s)"
assert_contains "stack-registry no-pr fixture: names the layer" "$OUT" "FEAT-101"
assert_not_contains "stack-registry no-pr fixture: never reports pass" "$OUT" "$(printf 'pass\tstack-registry')"
assert_not_contains "stack-registry no-pr fixture: no longer downgraded to a non-blocking note" "$OUT" "$(printf 'note\tstack-registry')"
teardown_temp_dir

# --- stack-registry: gh unavailable to consult -> note, never a false pass ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
OUT=$(PATH="$(_dr_shim_path dirname git grep sed sort tail cat bash jq)" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry gh-unavailable fixture: aggregate exit 1 (stacking check warns too)" "$EXIT" 1
assert_contains "stack-registry gh-unavailable fixture: notes, never falsely passes" "$OUT" "$(printf 'note\tstack-registry')"
assert_not_contains "stack-registry gh-unavailable fixture: never reports pass" "$OUT" "$(printf 'pass\tstack-registry')"
teardown_temp_dir

# --- stack-registry: PR unreadable from GitHub (API failure) -> note, never a false pass ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
OUT=$(NAZGUL_TEST_GH_PR_STATE=FAIL PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry unreadable-api fixture: aggregate exit 0 (note is non-blocking)" "$EXIT" 0
assert_contains "stack-registry unreadable-api fixture: notes, never falsely passes" "$OUT" "$(printf 'note\tstack-registry')"
assert_not_contains "stack-registry unreadable-api fixture: never reports pass" "$OUT" "$(printf 'pass\tstack-registry')"
teardown_temp_dir

# --- stack-registry: stacking enabled but registry has no open layers -> not applicable ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "stack-registry empty-registry fixture: aggregate exit 0" "$EXIT" 0
assert_contains "stack-registry empty-registry fixture: passes not applicable" "$OUT" "$(printf 'pass\tstack-registry')"
assert_contains "stack-registry empty-registry fixture: states the reason" "$OUT" "no open entries"
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-013 — RULES §15 verdicts for the two stacking checks. Each assertion
# below was written against the PRE-FIX tree and observed to FAIL there.
# ---------------------------------------------------------------------------

# --- config exists but does not parse -> FAIL on both checks. Pre-fix _doc_cfg
# swallowed the parse error and returned the caller's default, so an unreadable
# config reported a confident "Not applicable — stacking.enabled is false" on
# BOTH: never-looked presented as looked-and-found-nothing. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
printf '{ "execution": { "stacking": ' > "$TEST_DIR/nazgul/config.json"
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "unparseable-config fixture: aggregate exit 2 (fail)" "$EXIT" 2
assert_contains "unparseable-config fixture: stacking FAILS, never 'not applicable'" "$OUT" "$(printf 'fail\tstacking')"
assert_contains "unparseable-config fixture: stack-registry FAILS too" "$OUT" "$(printf 'fail\tstack-registry')"
assert_not_contains "unparseable-config fixture: never a false pass on stacking" "$OUT" "$(printf 'pass\tstacking')"
assert_not_contains "unparseable-config fixture: never a false pass on stack-registry" "$OUT" "$(printf 'pass\tstack-registry')"
teardown_temp_dir

# --- stack.layers[] is the wrong JSON type -> WARN naming the corruption.
# Pre-fix `[.stack.layers[]? | ...] | length` yielded 0 and the check reported
# "no open entries" — corruption read as an empty stack. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' '.stack.layers = "corrupt"'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "malformed-registry fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "malformed-registry fixture: stack-registry warns" "$OUT" "$(printf 'warn\tstack-registry')"
assert_contains "malformed-registry fixture: names the corruption" "$OUT" "CORRUPT"
assert_not_contains "malformed-registry fixture: never reports 'no open entries'" "$OUT" "no open entries"
teardown_temp_dir

# --- stacking disabled but open layers remain -> warn, not "not applicable".
# Abandoned layers are invisible to every other surface while stacking is off,
# and re-enabling counts them against max_unmerged immediately. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' "$STACK_LAYER_OPEN"
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "disabled-with-layers fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "disabled-with-layers fixture: stack-registry warns" "$OUT" "$(printf 'warn\tstack-registry')"
assert_contains "disabled-with-layers fixture: names the leftover open entries" "$OUT" "still holds 1 open entry"
assert_not_contains "disabled-with-layers fixture: no longer a bare 'not applicable' pass" "$OUT" "$(printf 'pass\tstack-registry')"
teardown_temp_dir

# --- api_failures at 1-2 (below the three-strikes halt) -> warn. Pre-fix the
# counter was never mentioned at any level until it had already halted. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' \
  '.execution.stacking.api_failures = 2'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "api-failures fixture: aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "api-failures fixture: stacking warns before the halt, not after" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "api-failures fixture: names the counter and the threshold" "$OUT" "api_failures is 2"
teardown_temp_dir

# --- halted: the remediation must name the counter too, or clearing `halted`
# alone re-halts on the next single API hiccup. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' \
  '.execution.stacking.halted = true' '.execution.stacking.halt_reason = "conflict"'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_contains "halted fixture: remediation names api_failures, not just the halted flag" "$OUT" "api_failures"
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-014 — vendor-drift canary. stack-utils.sh classifies `gh stack sync`'s
# outcome by matching gh-stack v0.1.0's exact stderr strings, and a reword in a
# v0.1.x release turns a real divergence into a clean sync AND resets the
# three-strikes counter — with the test suite still green, because the fixtures
# are the code's own strings (audit-failpaths.md, top risk #1). Doctor already
# reads the version in `gh extension list`'s row; it just never compared it.
# ---------------------------------------------------------------------------

# --- installed version matches the ADR pin -> pass, and SAYS which version ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "version canary (pinned v0.1.0): aggregate exit 0" "$EXIT" 0
assert_contains "version canary (pinned v0.1.0): stacking still passes" "$OUT" "$(printf 'pass\tstacking')"
assert_contains "version canary (pinned v0.1.0): the pass names the version it checked" "$OUT" "gh-stack v0.1.0"
teardown_temp_dir

# --- a different installed version -> warn naming both versions, the coupled
# strings, and where they are matched ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(NAZGUL_TEST_GH_STACK_VER=v0.2.0 PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "version canary (drifted v0.2.0): aggregate exit 1 (warn)" "$EXIT" 1
assert_contains "version canary (drifted v0.2.0): stacking warns" "$OUT" "$(printf 'warn\tstacking')"
assert_contains "version canary (drifted v0.2.0): names the installed version" "$OUT" "gh-stack v0.2.0 is installed"
assert_contains "version canary (drifted v0.2.0): names the pinned version" "$OUT" "ADR-018 pinned v0.1.0"
assert_contains "version canary (drifted v0.2.0): names the string-coupling risk" "$OUT" "diverged from the stack on GitHub"
assert_contains "version canary (drifted v0.2.0): points at the classifier that does the matching" "$OUT" "_su_classify_sync_result"
assert_contains "version canary (drifted v0.2.0): points at ADR-018 §4" "$OUT" "ADR-018 §4"
assert_not_contains "version canary (drifted v0.2.0): never a pass on a version nobody probed" "$OUT" "$(printf 'pass\tstacking')"
teardown_temp_dir

# --- the row carries no version at all: the canary could not run. That is not
# "matches the pin" — it is reported as its own answer (RULES §15). ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
OUT=$(NAZGUL_TEST_GH_STACK_VER= PATH="$FAKEBIN_STACK:$PATH" "$DOCTOR" 2>&1); EXIT=$?
assert_exit_code "version canary (no version in the row): aggregate exit 0 (note is non-blocking)" "$EXIT" 0
assert_contains "version canary (no version in the row): notes" "$OUT" "$(printf 'note\tstacking')"
assert_contains "version canary (no version in the row): says the canary could not run" "$OUT" "canary could NOT run"
assert_not_contains "version canary (no version in the row): never a pass claiming the version was checked" "$OUT" "$(printf 'pass\tstacking')"
teardown_temp_dir

rm -rf "$FAKEBIN_STACK"

# --- Zero-write guarantee extended: doctor never writes when the new checks
# actually fire (stacking enabled, ready, an open layer to consult) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false' '.execution.stacking.enabled = true' "$STACK_LAYER_OPEN"
BEFORE_STACK_ZW=$(_dr_snapshot "$TEST_DIR/nazgul")
FAKEBIN_STACK2=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-stack-fakebin2-XXXXXX")
cat > "$FAKEBIN_STACK2/gh" << 'FAKE_GH_STACK_EOF2'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "extension list") printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'; exit 0 ;;
  "pr view") printf 'OPEN\n'; exit 0 ;;
esac
exit 0
FAKE_GH_STACK_EOF2
chmod +x "$FAKEBIN_STACK2/gh"
PATH="$FAKEBIN_STACK2:$PATH" "$DOCTOR" >/dev/null 2>&1
AFTER_STACK_ZW=$(_dr_snapshot "$TEST_DIR/nazgul")
assert_eq "stacking zero-write guarantee: nazgul/ snapshot identical before/after a run with stacking checks firing" \
  "$AFTER_STACK_ZW" "$BEFORE_STACK_ZW"
rm -rf "$FAKEBIN_STACK2"
teardown_temp_dir

# --- (k) messaging eligibility: three states, never two ---
# HOME is pinned to the scratch tree: _doc_flag_killers reads ~/.claude/settings.json.
setup_temp_dir
setup_nazgul_dir
_dr_config
OUT=$(cd "$TEST_DIR" && HOME="$TEST_DIR" DO_NOT_TRACK=1 CLAUDE_CODE_MESSAGING_SOCKET= bash "$DOCTOR" --only=messaging 2>/dev/null)
assert_contains "doctor messaging: flag-killer named with source" "$OUT" "DO_NOT_TRACK"
assert_contains "doctor messaging: a flag killer is a warn, not a note" "$OUT" "$(printf 'warn\tmessaging')"
assert_contains "doctor messaging: the killer's source is named, not just the variable" "$OUT" "DO_NOT_TRACK (shell env)"
OUT=$(cd "$TEST_DIR" && HOME="$TEST_DIR" env -u DO_NOT_TRACK -u DISABLE_TELEMETRY -u DISABLE_GROWTHBOOK -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
  CLAUDE_CODE_MESSAGING_SOCKET= bash "$DOCTOR" --only=messaging 2>/dev/null)
assert_contains "doctor messaging: socket-unset is UNDETERMINED, not unavailable" "$OUT" "UNDETERMINED"
assert_contains "doctor messaging: UNDETERMINED is a note, so it never scores the run" "$OUT" "$(printf 'note\tmessaging')"
assert_not_contains "doctor messaging: an unexported socket is never the flag-killer OFF claim" "$OUT" "Cross-session messaging is OFF"
assert_contains "doctor messaging: the note explicitly disclaims an unavailability claim" "$OUT" "NOT a claim that messaging is unavailable"
OUT=$(cd "$TEST_DIR" && HOME="$TEST_DIR" env -u DO_NOT_TRACK -u DISABLE_TELEMETRY -u DISABLE_GROWTHBOOK -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
  CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/1.sock bash "$DOCTOR" --only=messaging 2>/dev/null)
assert_contains "doctor messaging: socket exported reports available" "$OUT" "pass"
assert_contains "doctor messaging: the pass is the messaging check's own verdict" "$OUT" "$(printf 'pass\tmessaging')"
# Zero-write is doctor's charter and the socket is never connected: the check
# reads the env var and reports, it never talks to the path it names.
BEFORE_MSG=$(_dr_snapshot "$TEST_DIR/nazgul")
(cd "$TEST_DIR" && HOME="$TEST_DIR" CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/1.sock bash "$DOCTOR" --only=messaging,remote-control,sessions >/dev/null 2>&1)
assert_eq "the three new checks write nothing under nazgul/" \
  "$(_dr_snapshot "$TEST_DIR/nazgul")" "$BEFORE_MSG"
teardown_temp_dir

# --- (l) remote-control: named causes ---
setup_temp_dir
setup_nazgul_dir
_dr_config
OUT=$(cd "$TEST_DIR" && HOME="$TEST_DIR" env -u DO_NOT_TRACK -u DISABLE_TELEMETRY -u DISABLE_GROWTHBOOK -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
  ANTHROPIC_BASE_URL="https://proxy.example" bash "$DOCTOR" --only=remote-control 2>/dev/null)
assert_contains "doctor remote-control: names ANTHROPIC_BASE_URL" "$OUT" "ANTHROPIC_BASE_URL"
assert_contains "doctor remote-control: points at claude doctor" "$OUT" "claude doctor"
assert_contains "doctor remote-control: a named cause is a warn" "$OUT" "$(printf 'warn\tremote-control')"
# The clean path must still point at the authoritative check — doctor never
# probes auth type, so "no blockers found" is not "Remote Control works".
OUT=$(cd "$TEST_DIR" && HOME="$TEST_DIR" env -u DO_NOT_TRACK -u DISABLE_TELEMETRY -u DISABLE_GROWTHBOOK \
  -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
  bash "$DOCTOR" --only=remote-control 2>/dev/null)
assert_contains "doctor remote-control: no blockers is a pass" "$OUT" "$(printf 'pass\tremote-control')"
assert_contains "doctor remote-control: the pass still names claude doctor as authoritative" "$OUT" "claude doctor"
teardown_temp_dir

# --- (m) sessions: shared-tree collision ---
setup_temp_dir
setup_nazgul_dir
_dr_config
mkdir -p "$TEST_DIR/nazgul/sessions"
jq -cn --arg p "$$" '{pid:$p, session:"a", toplevel:"/repo/x"}' > "$TEST_DIR/nazgul/sessions/a.lock"
jq -cn --arg p "$$" '{pid:$p, session:"b", toplevel:"/repo/x"}' > "$TEST_DIR/nazgul/sessions/b.lock"
OUT=$(cd "$TEST_DIR" && bash "$DOCTOR" --only=sessions 2>/dev/null)
assert_contains "doctor sessions: shared-tree warn names the tree" "$OUT" "/repo/x"
assert_contains "doctor sessions: a collision is a warn" "$OUT" "$(printf 'warn\tsessions')"
# A DEAD pid is not a live session: two locks on one tree where one owner is
# gone is the ordinary sequential case, not the #195 hazard.
jq -cn '{pid:"2147483646", session:"c", toplevel:"/repo/x"}' > "$TEST_DIR/nazgul/sessions/b.lock"
OUT=$(cd "$TEST_DIR" && bash "$DOCTOR" --only=sessions 2>/dev/null)
assert_contains "doctor sessions: a dead lock owner is not a live collision" "$OUT" "$(printf 'pass\tsessions')"
assert_not_contains "doctor sessions: no tree is named when there is no live collision" "$OUT" "/repo/x"
rm -f "$TEST_DIR"/nazgul/sessions/*.lock
OUT=$(cd "$TEST_DIR" && bash "$DOCTOR" --only=sessions 2>"$TEST_DIR/sessions.err")
assert_contains "doctor sessions: no locks is a named no-candidates skip" "$OUT" "sessions"
assert_contains "doctor sessions: the empty case is skipped, not passed on nothing" \
  "$(printf '%s' "$OUT" | tail -1)" "no-candidates=1"
assert_contains "doctor sessions: the skip uses the Not applicable convention" \
  "$OUT" "$(printf 'pass\tsessions\tNot applicable')"
assert_contains "doctor sessions: an all-skipped run says so on stderr" \
  "$(cat "$TEST_DIR/sessions.err")" "doctor: NOTHING CHECKED — all 1 candidates skipped"
teardown_temp_dir

# --- (m) sessions: a lock set the liveness filter empties must not abort main() ---
# Board R1: pre-2.33 locks record the old hook-shell $$ (dead by any later read) and no toplevel, so the duplicate scan sees nothing on the ordinary upgrade path.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
mkdir -p "$TEST_DIR/nazgul/sessions"
jq -cn '{pid:"2147483646", session:"legacy"}' > "$TEST_DIR/nazgul/sessions/legacy.lock"
OUT=$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" 2>/dev/null)
assert_contains "empty-scan fixture: the sessions check still reports" "$OUT" "$(printf 'pass\tsessions')"
# sessions is the LAST check, so a mid-check abort takes the coverage line with it.
assert_contains "empty-scan fixture: the run reached the coverage line, so it was not truncated" \
  "$(printf '%s' "$OUT" | tail -1)" "$DR_ROSTER_COUNT scanned"
teardown_temp_dir

# (j) ignore-block — the R3 check. Every state gets its OWN message, because "looked and found no
# block" and "could not look" collapsing into one allow is what RULES §15 exists to forbid.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config

DR_IB_SHIPPED=$(printf '%s' "$DR_SHIPPED_BLOCK_LINE" | sed -nE 's/.*\(v([0-9]+)\).*/v\1/p')
DR_IB_BARE=${DR_SHIPPED_BLOCK_LINE%% (v*}

_dr_ib_line() {
  local out
  out=$( (cd "$TEST_DIR" && bash "$DOCTOR" --only=ignore-block) 2>/dev/null )
  printf '%s' "$out" | head -1
}
_dr_ib_msg() { printf '%s' "$1" | cut -f3-; }

IB_PASS=$(_dr_ib_line)
assert_contains "(j): a shared install carrying the shipped block passes" "$IB_PASS" "$(printf 'pass\tignore-block')"
assert_contains "(j): the pass names the version it found" "$IB_PASS" "block at $DR_IB_SHIPPED"

printf '%s\nnazgul/logs/\n' "$DR_IB_BARE" > "$TEST_DIR/.gitignore"
IB_V1=$(_dr_ib_line)
assert_contains "(j): a pre-stamp block is found, not read as absent — the prefix match is what makes v1 visible" \
  "$IB_V1" "$(printf 'warn\tignore-block')"
assert_contains "(j): the drift message names the version found AND the version shipped" \
  "$IB_V1" "block at v1; this plugin ships $DR_IB_SHIPPED"
assert_contains "(j): and names the remedy" "$IB_V1" "/nazgul:init --force"

printf '  %s\n' "$DR_SHIPPED_BLOCK_LINE" > "$TEST_DIR/.gitignore"
IB_INDENT=$(_dr_ib_line)
assert_contains "(j): an indented block is stale however current its stamp reads (C-c's residual)" \
  "$IB_INDENT" "$(printf 'warn\tignore-block')"
assert_contains "(j): and the message says the entries are inert, not that the version is old" "$IB_INDENT" "inert"

# Round-3 finding 3: the case the old branch MISSED — sentinel flush-left, ENTRIES indented, which
# is what a partial or hand-edited rewrite produces. The stamp reads current and the block matches
# nothing, so before the region scan this printed `pass ... the version this plugin ships`.
printf '%s\n   nazgul/logs/\n# Nazgul Framework — end ephemeral runtime\n' "$DR_SHIPPED_BLOCK_LINE" > "$TEST_DIR/.gitignore"
IB_INDENT_ENTRY=$(_dr_ib_line)
assert_contains "(j): a flush-left sentinel over INDENTED entries is a finding, not a pass on a current stamp" \
  "$IB_INDENT_ENTRY" "$(printf 'warn\tignore-block')"
assert_contains "(j): and it says the entries are inert, not that the version is old" "$IB_INDENT_ENTRY" "inert"
# CONTROL: the same block with its entries flush-left passes, so the arm above measures the
# indentation and not merely the presence of a second line.
printf '%s\nnazgul/logs/\n# Nazgul Framework — end ephemeral runtime\n' "$DR_SHIPPED_BLOCK_LINE" > "$TEST_DIR/.gitignore"
assert_contains "(j) CONTROL: the same region flush-left passes, so the finding above is the indentation" \
  "$(_dr_ib_line)" "$(printf 'pass\tignore-block')"

printf 'build/\n' > "$TEST_DIR/.gitignore"
IB_NOBLOCK=$(_dr_ib_line)
assert_contains "(j): a shared install whose .gitignore carries no block at all is a finding" \
  "$IB_NOBLOCK" "$(printf 'warn\tignore-block')"
assert_contains "(j): absence is named as #251 itself, not reported as drift" "$IB_NOBLOCK" "#251"

rm -f "$TEST_DIR/.gitignore"
IB_NOFILE=$(_dr_ib_line)
assert_contains "(j): no .gitignore at all is still a determinate observation, not a skip" \
  "$IB_NOFILE" "$(printf 'warn\tignore-block')"
assert_contains "(j): and it says which of the two absences it saw" "$IB_NOFILE" "does not exist at all"

# Round-3 finding 7: this PR stamped the LOCAL block and gave it an end sentinel, so a local
# install can now be v1 — and returning "not applicable" left it with no surface that says so,
# which is the one job skills/doctor/SKILL.md bills this check with.
jq '.install_mode = "local"' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.x" \
  && mv "$TEST_DIR/nazgul/config.json.x" "$TEST_DIR/nazgul/config.json"
printf '%s\nnazgul/\n' "${DR_SHIPPED_LOCAL_LINE%% (v*}" > "$TEST_DIR/.gitignore"
IB_LOCAL=$(_dr_ib_line)
assert_contains "(j): a v1 LOCAL install is reported, where it used to be a not-applicable skip" \
  "$IB_LOCAL" "$(printf 'warn\tignore-block')"
assert_contains "(j): and the local message names the version found" "$IB_LOCAL" "block at v1"
assert_contains "(j): the local cost is stated honestly — nothing is mis-tracked, the sentinel-delimited removal is what is lost" \
  "$IB_LOCAL" "ownership-bounded removal"
# CONTROL: a local install carrying the shipped stamped block passes, so the warn above is the stamp.
printf '%s\nnazgul/\n%s\n' "$DR_SHIPPED_LOCAL_LINE" '# Nazgul Framework — end local mode' > "$TEST_DIR/.gitignore"
IB_LOCAL_OK=$(_dr_ib_line)
assert_contains "(j) CONTROL: a local install at the shipped stamp passes" "$IB_LOCAL_OK" "$(printf 'pass\tignore-block')"
# A mode that is neither is still a NAMED skip: the not-applicable path did not disappear, it moved.
jq '.install_mode = "unset"' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.x" \
  && mv "$TEST_DIR/nazgul/config.json.x" "$TEST_DIR/nazgul/config.json"
IB_MODE_OTHER=$(_dr_ib_line)
assert_contains "(j): a mode that is neither shared nor local is a named not-applicable skip, never a pass on nothing" \
  "$IB_MODE_OTHER" "$(printf 'pass\tignore-block\tNot applicable')"
assert_contains "(j): the skip names the install mode it read" "$IB_MODE_OTHER" "install_mode is 'unset'"

printf 'not json\n' > "$TEST_DIR/nazgul/config.json"
IB_BADCFG=$(_dr_ib_line)
assert_contains "(j): an unparseable config makes install_mode UNKNOWN, never 'unset'" "$IB_BADCFG" "UNKNOWN rather than unset"
_dr_config

DR_IB_SET=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$(_dr_ib_msg "$IB_PASS")" "$(_dr_ib_msg "$IB_V1")" \
  "$(_dr_ib_msg "$IB_INDENT")" "$(_dr_ib_msg "$IB_NOBLOCK")" "$(_dr_ib_msg "$IB_NOFILE")" \
  "$(_dr_ib_msg "$IB_LOCAL")" "$(_dr_ib_msg "$IB_LOCAL_OK")" "$(_dr_ib_msg "$IB_MODE_OTHER")" \
  "$(_dr_ib_msg "$IB_BADCFG")")
assert_eq "(j): the nine reachable states print pairwise-distinct messages, not nine copies of one verdict" \
  "$(printf '%s\n' "$DR_IB_SET" | sort -u | wc -l | tr -d ' ')" "9"

# ---- Round-3 finding 5: every remediation that recommends --force discloses what it destroys ---
# Two of the three said only "re-run /nazgul:init --force"; the absent-block one — #251 live, the
# operator most likely to be hit — read like a .gitignore edit. One suffix now, so they cannot drift.
DR_IB_COST='It archives nazgul/ state and re-runs Discovery.'
for _ib_case in "absent:$IB_NOBLOCK" "no-file:$IB_NOFILE" "indented:$IB_INDENT" "indented-entries:$IB_INDENT_ENTRY" "stale:$IB_V1" "local-stale:$IB_LOCAL"; do
  assert_contains "(j) finding 5: the ${_ib_case%%:*} remediation discloses that --force archives state" \
    "${_ib_case#*:}" "$DR_IB_COST"
done
# CONTROL: the pass message recommends nothing, so it must NOT carry the cost clause — otherwise
# the loop above would pass on a suffix appended unconditionally to every line.
assert_not_contains "(j) finding 5 CONTROL: the pass message recommends no --force, so it carries no cost clause" \
  "$IB_PASS" "$DR_IB_COST"

# The unreadable arm needs a file this process genuinely cannot read; root can, so it is
# announced as skipped rather than asserted vacuously.
chmod 000 "$TEST_DIR/.gitignore"
if [ -r "$TEST_DIR/.gitignore" ]; then
  _skip "(j) unreadable arm (skipped — chmod 000 left the file readable; running as root?)"
else
  IB_UNREADABLE=$(_dr_ib_line)
  assert_contains "(j): an unreadable .gitignore is 'could not look', reported as a skip" \
    "$IB_UNREADABLE" "$(printf 'pass\tignore-block\tNot applicable')"
  assert_contains "(j): and it explicitly disclaims the absence claim" "$IB_UNREADABLE" "NOT a report that the block is missing"
  assert_eq "(j): 'could not look' and 'looked and found no block' never print the same thing (RULES §15)" \
    "$(printf '%s\n%s\n' "$DR_IB_SET" "$(_dr_ib_msg "$IB_UNREADABLE")" | sort -u | wc -l | tr -d ' ')" "10"
fi
chmod 644 "$TEST_DIR/.gitignore"

# The derivation control, and it is the strong one: a shipped block stamped (v3) must move
# doctor's reported expectation to v3. A hardcoded literal in doctor.sh cannot pass this.
DR_IB_V3ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doctor-v3-XXXXXX")
cp -R "$REPO_ROOT/scripts" "$DR_IB_V3ROOT/scripts"
mkdir -p "$DR_IB_V3ROOT/skills/init"
sed "s|^$DR_SHIPPED_BLOCK_LINE\$|$DR_IB_BARE (v3)|" "$REPO_ROOT/skills/init/SKILL.md" > "$DR_IB_V3ROOT/skills/init/SKILL.md"
assert_file_contains "(j) derivation floor: the fixture plugin really does ship a (v3) block" \
  "$DR_IB_V3ROOT/skills/init/SKILL.md" "^$DR_IB_BARE (v3)\$"
printf '%s\nnazgul/logs/\n' "$DR_SHIPPED_BLOCK_LINE" > "$TEST_DIR/.gitignore"
IB_V3=$( (cd "$TEST_DIR" && bash "$DR_IB_V3ROOT/scripts/doctor.sh" --only=ignore-block) 2>/dev/null | head -1)
assert_contains "(j) derivation: a (v3) shipped block flips the same $DR_IB_SHIPPED install to drift" \
  "$IB_V3" "$(printf 'warn\tignore-block')"
assert_contains "(j) derivation: doctor reports the version it READ from the skill, never a literal of its own" \
  "$IB_V3" "this plugin ships v3"
assert_contains "(j) derivation: and names the file it derived from" "$IB_V3" "skills/init/SKILL.md"
rm -rf "$DR_IB_V3ROOT"

# Zero-write, extended to (j): it reads .gitignore and must never repair it — doctor's only
# fix path is the remediation text it prints.
BEFORE_IB=$(_dr_snapshot "$TEST_DIR/nazgul")
BEFORE_IB_GI=$(_dr_hash_file "$TEST_DIR/.gitignore")
(cd "$TEST_DIR" && bash "$DOCTOR" --only=ignore-block >/dev/null 2>&1)
assert_eq "(j) zero-write: nothing under nazgul/ changed" "$(_dr_snapshot "$TEST_DIR/nazgul")" "$BEFORE_IB"
assert_eq "(j) zero-write: the .gitignore it read is byte-identical afterwards" \
  "$(_dr_hash_file "$TEST_DIR/.gitignore")" "$BEFORE_IB_GI"

# R3 part 2: the unreachable notice is gone from the skill, and its action took its place.
DR_NOTICE='Until then the block'
assert_eq "R3: skills/init/SKILL.md no longer carries the stale-block notice Step 0.5 made unreachable" \
  "$(grep -cF -- "$DR_NOTICE" "$REPO_ROOT/skills/init/SKILL.md" || true)" "0"
DR_NOTICE_CTRL="$TEST_DIR/init-notice-control.md"
{ cat "$REPO_ROOT/skills/init/SKILL.md"; printf 'print a notice: %s stays tracked.\n' "$DR_NOTICE"; } > "$DR_NOTICE_CTRL"
assert_eq "R3 CONTROL: appending one occurrence moves that count to one, so the zero above is MEASURED" \
  "$(grep -cF -- "$DR_NOTICE" "$DR_NOTICE_CTRL" || true)" "1"
# Wording-agnostic on purpose: TASK-022 renamed this bullet from "Present, stale" to
# "Present but stale", and a needle pinned to either spelling reads 0 for the wrong reason.
DR_NOFORCE='stale, no `--force`'
assert_eq "R3: and the unreachable fourth state is gone from the version switch too" \
  "$(grep -cF -- "$DR_NOFORCE" "$REPO_ROOT/skills/init/SKILL.md" || true)" "0"
DR_NOFORCE_CTRL="$TEST_DIR/init-noforce-control.md"
{ cat "$REPO_ROOT/skills/init/SKILL.md"; printf -- '- **Present but %s** — report it.\n' "$DR_NOFORCE"; } > "$DR_NOFORCE_CTRL"
assert_eq "R3 CONTROL: that zero is measured too" \
  "$(grep -cF -- "$DR_NOFORCE" "$DR_NOFORCE_CTRL" || true)" "1"
assert_file_contains "R3: the skill states why that state cannot occur, so it cannot be re-added by accident" \
  "$REPO_ROOT/skills/init/SKILL.md" "Three reachable states, not four"
assert_file_contains "R3: and names the read-only surface that reports drift instead" \
  "$REPO_ROOT/skills/init/SKILL.md" "read-only \`ignore-block\` check"
assert_file_contains "R3: the stale branch now replaces the region rather than reporting it" \
  "$REPO_ROOT/skills/init/SKILL.md" "This is the ONLY stale branch"
assert_file_contains "R3: skills/doctor/SKILL.md names the fifteenth check it now runs" \
  "$REPO_ROOT/skills/doctor/SKILL.md" "at the version this plugin ships"
# Round-3 finding 7: the doc billed (j) as "the only surface that tells a v1 install it is v1"
# while the check skipped local mode outright, so half the installs it claimed to cover had no
# surface at all. Both modes must be named where that claim is made.
for _r3_mode in "the ephemeral-runtime block in shared mode" "the local-mode block in local"; do
  assert_file_contains "R3 finding 7: skills/doctor/SKILL.md says (j) covers $_r3_mode" \
    "$REPO_ROOT/skills/doctor/SKILL.md" "$_r3_mode"
done
# And the region scan, which is what finding 3 bought: a stamp alone cannot see an inert block.
assert_file_contains "R3 finding 3: skills/doctor/SKILL.md says the whole region is checked flush-left, not just the stamp" \
  "$REPO_ROOT/skills/doctor/SKILL.md" "every region line flush-left"
teardown_temp_dir

# Coverage honesty (FEAT-028 TASK-015, TRD §6): a check with nothing to inspect is
# skipped with an enumerated reason, and the vacuous case writes nothing.

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config '.guards.git_hooks = false'
OUT=$("$DOCTOR" 2>/dev/null); EXIT=$?
COVERAGE=$(printf '%s' "$OUT" | tail -1)
DR_GRAMMAR="^doctor: ([0-9]+) scanned, ([0-9]+) skipped \(not-applicable-config=([0-9]+), not-applicable-env=([0-9]+), no-candidates=([0-9]+), unreadable=([0-9]+)\), ([0-9]+) checked, ([0-9]+) findings$"
if printf '%s' "$COVERAGE" | grep -qE "$DR_GRAMMAR"; then
  _pass "coverage line is the last stdout line and conforms to the TRD §6 grammar"
else
  _fail "coverage line is the last stdout line and conforms to the TRD §6 grammar" "got: '$COVERAGE'"
fi
read -r D_SCANNED D_SKIPPED D_CHECKED <<<"$(printf '%s' "$COVERAGE" | sed -E "s/$DR_GRAMMAR/\1 \2 \7/")"
assert_eq "coverage line adds up (N == M + K)" "$D_SCANNED" "$((D_SKIPPED + D_CHECKED))"
assert_eq "the declared roster is the fifteen checks the docs name" "$DR_ROSTER_COUNT" "15"
assert_eq "every check reports exactly once, so N is the full check roster" "$D_SCANNED" "$DR_ROSTER_COUNT"
if [ "$D_SKIPPED" -ge 1 ]; then
  _pass "the disabled-guard check is counted as skipped, not as a check that passed on nothing"
else
  _fail "the disabled-guard check is counted as skipped, not as a check that passed on nothing" \
    "skipped: $D_SKIPPED"
fi
assert_exit_code "the coverage line does not change the aggregate exit code" "$EXIT" 0

# Forced all-skip: --only two checks that both have nothing to inspect here.
BEFORE_CH=$(_dr_snapshot "$TEST_DIR/nazgul")
OUT=$("$DOCTOR" --only=git-hooks,stacking 2>"$TEST_DIR/only.err"); EXIT=$?
assert_contains "forced all-skip emits the nothing-checked signal on stderr" \
  "$(cat "$TEST_DIR/only.err")" "doctor: NOTHING CHECKED — all 2 candidates skipped"
assert_contains "forced all-skip still emits the coverage line" \
  "$(printf '%s' "$OUT" | tail -1)" "doctor: 2 scanned, 2 skipped"
assert_contains "a skipped check still reports pass with the Not applicable convention" \
  "$OUT" "$(printf 'pass\tgit-hooks\tNot applicable')"
assert_exit_code "an all-skipped run still exits on the worst verdict, not on the coverage" "$EXIT" 0
assert_eq "zero-write guarantee holds on the nothing-checked path (no event, no log dir)" \
  "$(_dr_snapshot "$TEST_DIR/nazgul")" "$BEFORE_CH"
assert_file_not_exists "the vacuous path writes no events.jsonl — zero-write outranks the bus" \
  "$TEST_DIR/nazgul/logs/events.jsonl"

# A --only typo must not select nothing and report a confident zero-finding run.
OUT=$("$DOCTOR" --only=git-hooks,no-such-check 2>&1); EXIT=$?
assert_exit_code "an unknown --only check id is a usage error, not an empty run" "$EXIT" 1
assert_contains "the unknown --only id is named" "$OUT" "unknown check 'no-such-check'"
assert_not_contains "a rejected --only run emits no coverage line at all" "$OUT" "0 checked, 0 findings"

OUT=$("$DOCTOR" --only=, 2>&1); EXIT=$?
assert_exit_code "an empty comma-only --only list is a usage error" "$EXIT" 1
assert_contains "the empty --only list explains that check ids must be non-empty" \
  "$OUT" "requires one or more non-empty check ids"
assert_not_contains "an empty --only list cannot report a vacuous coverage pass" "$OUT" "0 checked, 0 findings"

OUT=$("$DOCTOR" --only= 2>&1); EXIT=$?
assert_exit_code "an empty --only value is a usage error" "$EXIT" 1
teardown_temp_dir

# --- (k) messaging: a flag set to a FALSY value is NOT a killer (PR #223 review #6) ---
# `jq has($v)` reported a killer for {"env":{"DISABLE_TELEMETRY":"0"}}, so an operator who
# explicitly turned a flag OFF had messaging reported unavailable and doctor's exit pushed
# to 1 on a healthy host. The shell-env arm already required a non-empty value; both arms
# now share _doc_flag_is_on. These two cases are the ones that shipped untested.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'
mkdir -p "$TEST_DIR/.claude"
jq -n '{env:{DISABLE_TELEMETRY:"0", DO_NOT_TRACK:"false"}}' > "$TEST_DIR/.claude/settings.json"
OUT=$(env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR "$DOCTOR" 2>&1); EXIT=$?
assert_not_contains "falsy env flags are not killers: DISABLE_TELEMETRY=\"0\" is not reported" \
  "$OUT" "DISABLE_TELEMETRY"
assert_not_contains "falsy env flags are not killers: DO_NOT_TRACK=\"false\" is not reported" \
  "$OUT" "DO_NOT_TRACK"
assert_exit_code "falsy env flags do not push the aggregate exit to 1" "$EXIT" 0
teardown_temp_dir

# --- (k) messaging: a flag set to a TRUTHY value IS still a killer ---
# The negative above must not be achievable by breaking detection outright.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'
mkdir -p "$TEST_DIR/.claude"
jq -n '{env:{DISABLE_TELEMETRY:"1"}}' > "$TEST_DIR/.claude/settings.json"
OUT=$(env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR "$DOCTOR" 2>&1)
assert_contains "a truthy env flag IS still reported as a killer" "$OUT" "DISABLE_TELEMETRY"
teardown_temp_dir

# --- (l) remote-control: settings.local.json is read (PR #223 review #7) ---
# check_remote_control read only the macOS managed-settings path and dropped
# settings.local.json, so it disagreed with _doc_flag_killers about what
# "env/settings" means — and an enterprise policy on Linux/WSL passed clean.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'
mkdir -p "$TEST_DIR/.claude"
jq -n '{disableRemoteControl:true}' > "$TEST_DIR/.claude/settings.local.json"
OUT=$(env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR "$DOCTOR" 2>&1)
assert_contains "disableRemoteControl in settings.local.json is detected" \
  "$OUT" "disableRemoteControl"
assert_contains "remote-control reports warn, not a clean pass" "$OUT" "$(printf 'warn\tremote-control')"
teardown_temp_dir

# --- (l) remote-control: the Linux/WSL managed-settings path is in the search list ---
# Platform-independent: assert the PATH is consulted, since the real /etc path cannot be
# planted in a temp fixture. A macOS-only list is invisible on this repo's own CI platform.
assert_file_contains "check_remote_control consults the Linux/WSL managed-settings path" \
  "$DOCTOR" "/etc/claude-code/managed-settings.json"
assert_file_contains "check_remote_control consults settings.local.json" \
  "$DOCTOR" 'settings.local.json'

# --- (n) stop-payload: P12c — three named outcomes, and their wordings differ ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'

_dr_stop_payload_msg() { printf '%s' "$1" | grep -m1 'stop-payload' | cut -f3 || true; }

DR_NEVER=$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null)
assert_contains "P12c: with no events.jsonl at all the check still reports, as an unscored note" \
  "$DR_NEVER" "$(printf 'note\tstop-payload')"
assert_contains "P12c: the no-record outcome is named NEVER OBSERVED" "$DR_NEVER" "NEVER OBSERVED"

mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn '{sv:1,event:"stop_payload_observed",bg_seen:"yes",entries:2,subagents:1,live:1,types:"subagent,shell",statuses:"running"}' \
  > "$TEST_DIR/nazgul/logs/events.jsonl"
DR_PRESENT=$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null)
assert_contains "P12c: a record carrying background_tasks is named FIELD PRESENT" "$DR_PRESENT" "FIELD PRESENT"
assert_contains "P12c: and the present wording carries the counts the deferrals are resolved on" \
  "$DR_PRESENT" "entries=2 subagents=1 live=1"

# Appended AFTER the bg_seen:"yes" line on purpose: reporting ABSENT here is what
# proves the check reads the LAST record rather than the first.
jq -cn '{sv:1,event:"stop_payload_observed",bg_seen:"unknown",why:"field_absent",entries:0,subagents:0,live:0,types:"",statuses:""}' \
  >> "$TEST_DIR/nazgul/logs/events.jsonl"
DR_ABSENT=$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null)
assert_contains "P12c: a record without background_tasks is named FIELD ABSENT" "$DR_ABSENT" "FIELD ABSENT"
# Counted in BOTH directions: a bare "does not say FIELD PRESENT" is also satisfied
# by output that says nothing at all, which is what a missing check produces.
assert_eq "P12c: the LAST record decides the outcome, not the first" \
  "$(printf '%s' "$DR_ABSENT" | grep -c 'FIELD PRESENT' || true)/$(printf '%s' "$DR_ABSENT" | grep -c 'FIELD ABSENT' || true)" "0/1"
assert_contains "P12c: the absent wording names the recorded why, so a shape change is distinguishable from a payload that never arrived" \
  "$DR_ABSENT" "why=field_absent"

DR_MSG_NEVER=$(_dr_stop_payload_msg "$DR_NEVER")
DR_MSG_PRESENT=$(_dr_stop_payload_msg "$DR_PRESENT")
DR_MSG_ABSENT=$(_dr_stop_payload_msg "$DR_ABSENT")
# Three equal empty strings would also sort -u to one line, so the non-empty floor
# is what stops "distinct" from being satisfiable by three captures of nothing.
assert_eq "P12c: all three outcome messages were actually captured" \
  "$([ -n "$DR_MSG_NEVER" ] && [ -n "$DR_MSG_PRESENT" ] && [ -n "$DR_MSG_ABSENT" ] && echo yes || echo no)" "yes"
assert_eq "P12c: three outcomes produce three DISTINCT messages" \
  "$(printf '%s\n%s\n%s\n' "$DR_MSG_NEVER" "$DR_MSG_PRESENT" "$DR_MSG_ABSENT" | sort -u | wc -l | tr -d ' ')" "3"
assert_eq "P12c: never-observed does not print the same thing as field-absent (RULES §15)" \
  "$([ "$DR_MSG_NEVER" != "$DR_MSG_ABSENT" ] && echo distinct || echo identical)" "distinct"

DR_FULL=$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" 2>/dev/null); DR_FULL_EC=$?
# Exit 0 alone is also what a roster with no such check at all reports, so the
# note's presence on the same run is what makes this about the note.
assert_eq "P12c: the note rides the full roster and still never moves the aggregate exit code" \
  "$DR_FULL_EC/$(printf '%s' "$DR_FULL" | grep -c "$(printf 'note\tstop-payload')" || true)" "0/1"
assert_contains "P12c: and the full run still reaches its coverage line" \
  "$(printf '%s' "$DR_FULL" | tail -1)" "$DR_ROSTER_COUNT scanned"
teardown_temp_dir

# --- (n) stop-payload: P12e/f/g/h — jq selection, why routing, bus-off (PR #245) ---
# Spelled out in full: bare "FIELD PRESENT" is a substring of the wrong-shape outcome.
_DR_SP_TOKENS=(
  'FIELD PRESENT BUT WRONG SHAPE'
  'FIELD PRESENT at the last recorded Stop'
  'FIELD ABSENT at the last recorded Stop'
  'PAYLOAD UNDETERMINED'
  'NEVER OBSERVED'
  'TELEMETRY BUS DISABLED'
  'LOOP PAUSED'
  'UNSELECTABLE RECORD'
  'UNREADABLE RECORD'
)
# Every outcome token present in one run, joined with "|" — so a single assert_eq
# pins the expected outcome AND the absence of all seven others.
_dr_sp_outcomes() {
  local out="$1" tok acc=""
  for tok in "${_DR_SP_TOKENS[@]}"; do
    case "$out" in *"$tok"*) acc="$acc$tok|" ;; esac
  done
  printf '%s' "$acc"
}
_dr_sp_msg() { printf '%s' "$1" | awk -F'\t' '$2 == "stop-payload" { print $3; exit }'; }

DR_SP_TOK_MISSING=0
for tok in "${_DR_SP_TOKENS[@]}"; do
  grep -qF "$tok" "$DOCTOR" || DR_SP_TOK_MISSING=$((DR_SP_TOK_MISSING + 1))
done
assert_eq "P12e floor: every enumerated outcome token is a real string in doctor.sh" \
  "${#_DR_SP_TOKENS[@]}/$DR_SP_TOK_MISSING" "9/0"

setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false'
mkdir -p "$TEST_DIR/nazgul/logs"
DR_SP_EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
_dr_sp_run() { (cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null); }

# P12e: a pretty-printed record with reordered keys — the exact shape the old
# compact-substring grep skipped, producing a false NEVER OBSERVED.
printf '{\n  "bg_seen" : "yes",\n  "event" : "stop_payload_observed",\n  "entries": 3, "subagents": 2, "live": 1,\n  "types": "subagent", "statuses": "running"\n}\n' > "$DR_SP_EVENTS"
assert_eq "P12e floor: the fixture is invisible to the old compact grep, so this case can only pass via jq" \
  "$(grep -c '"event":"stop_payload_observed"' "$DR_SP_EVENTS" || true)" "0"
DR_SP_OUT=$(_dr_sp_run)
assert_eq "P12e: a pretty-printed, key-reordered record is FOUND and reported present" \
  "$(_dr_sp_outcomes "$DR_SP_OUT")" "FIELD PRESENT at the last recorded Stop|"
assert_contains "P12e: and its counts are read off the same record" "$DR_SP_OUT" "entries=3 subagents=2 live=1"
assert_file_contains "P12e: doctor selects records with a jq predicate" \
  "$DOCTOR" "jq -c 'select(.event == \"stop_payload_observed\")'"
assert_file_not_contains "P12e: and no longer with a compact-format grep" \
  "$DOCTOR" "grep '\"event\":\"stop_payload_observed\"'"

# Appended AFTER: last-record-wins must survive the switch from grep to jq.
printf '{\n  "why" : "field_absent",\n  "event" : "stop_payload_observed",\n  "bg_seen" : "unknown"\n}\n' >> "$DR_SP_EVENTS"
assert_eq "P12e: with jq selection the LAST matching record still decides, across pretty-printed lines" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "FIELD ABSENT at the last recorded Stop|"

# P12f: one outcome per why; read_timeout is a strict PREFIX of read_timeout_partial, so both run.
# DR_SP_MSG is assigned, not printed: a $(...) capture would discard the assertions' PASS/FAIL tally.
_dr_sp_why_case() {
  local why="$1" expected="$2"
  jq -cn --arg w "$why" '{sv:1,event:"stop_payload_observed",bg_seen:"unknown",why:$w}' > "$DR_SP_EVENTS"
  DR_SP_OUT=$(_dr_sp_run)
  assert_eq "P12f: why=$why routes to exactly one outcome and no other" \
    "$(_dr_sp_outcomes "$DR_SP_OUT")" "$expected|"
  assert_contains "P12f: why=$why is named literally in the message" "$DR_SP_OUT" "why=$why"
  DR_SP_MSG=$(_dr_sp_msg "$DR_SP_OUT")
}
_dr_sp_why_case field_absent 'FIELD ABSENT at the last recorded Stop'; DR_SP_M_ABSENT="$DR_SP_MSG"
_dr_sp_why_case field_wrong_type 'FIELD PRESENT BUT WRONG SHAPE'; DR_SP_M_SHAPE="$DR_SP_MSG"
_dr_sp_why_case no_stdin 'PAYLOAD UNDETERMINED'; DR_SP_M_NOSTDIN="$DR_SP_MSG"
_dr_sp_why_case read_timeout 'PAYLOAD UNDETERMINED'; DR_SP_M_TIMEOUT="$DR_SP_MSG"
_dr_sp_why_case read_timeout_partial 'PAYLOAD UNDETERMINED'; DR_SP_M_PARTIAL="$DR_SP_MSG"
_dr_sp_why_case not_json 'PAYLOAD UNDETERMINED'; DR_SP_M_NOTJSON="$DR_SP_MSG"
_dr_sp_why_case no_jq 'PAYLOAD UNDETERMINED'; DR_SP_M_NOJQ="$DR_SP_MSG"
_dr_sp_why_case bad_timeout 'PAYLOAD UNDETERMINED'; DR_SP_M_UNKNOWN="$DR_SP_MSG"

# Eight equal empty strings also sort -u to one line, so the non-empty floor is
# what stops "eight distinct" from being satisfiable by eight captures of nothing.
DR_SP_ALL_MSGS=$(printf '%s\n' "$DR_SP_M_ABSENT" "$DR_SP_M_SHAPE" "$DR_SP_M_NOSTDIN" "$DR_SP_M_TIMEOUT" \
  "$DR_SP_M_PARTIAL" "$DR_SP_M_NOTJSON" "$DR_SP_M_NOJQ" "$DR_SP_M_UNKNOWN")
assert_eq "P12f floor: all eight why messages were actually captured" \
  "$(printf '%s\n' "$DR_SP_ALL_MSGS" | grep -c . || true)" "8"
assert_eq "P12f: eight whys produce eight DISTINCT messages — each names its own reason" \
  "$(printf '%s\n' "$DR_SP_ALL_MSGS" | sort -u | wc -l | tr -d ' ')" "8"
assert_eq "P12f: read_timeout_partial is matched whole, never as the read_timeout prefix" \
  "$([ "$DR_SP_M_PARTIAL" != "$DR_SP_M_TIMEOUT" ] && echo distinct || echo identical)" "distinct"
assert_contains "P12f: the partial payload is described as truncated by Nazgul's own bound" \
  "$DR_SP_M_PARTIAL" "truncated by Nazgul's own bound"
assert_contains "P12f: an unrecognised why is surfaced against the known set, not absorbed" \
  "$DR_SP_M_UNKNOWN" "not a member of this check's known set"
# The defect being fixed, stated as a negative: none of the five undetermined
# whys may claim background_tasks was absent.
DR_SP_FALSE_ABSENT=0
for msg in "$DR_SP_M_NOSTDIN" "$DR_SP_M_TIMEOUT" "$DR_SP_M_PARTIAL" "$DR_SP_M_NOTJSON" "$DR_SP_M_NOJQ"; do
  case "$msg" in *'FIELD ABSENT'*) DR_SP_FALSE_ABSENT=$((DR_SP_FALSE_ABSENT + 1)) ;; esac
done
assert_eq "P12f: no unreadable/undetermined why is reported as FIELD ABSENT (5 scanned)" \
  "$DR_SP_FALSE_ABSENT" "0"

# P12h: jq aborts a JSONL stream at the first malformed line where grep did not,
# so "selected nothing" must not silently become "never observed".
printf '{"event":"stop_payload_observed", TRUNCATED\n' > "$DR_SP_EVENTS"
DR_SP_OUT=$(_dr_sp_run)
assert_eq "P12h: a file whose only stop_payload_observed line is unparseable is UNSELECTABLE, not never-observed" \
  "$(_dr_sp_outcomes "$DR_SP_OUT")" "UNSELECTABLE RECORD|"
assert_contains "P12h: and the unselectable skip is counted as unreadable, not as a checked answer" \
  "$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null | tail -1)" \
  "unreadable=1), 0 checked"
teardown_temp_dir

# P12g: telemetry.bus_enabled=false — emit_event writes nothing, so "run one loop
# iteration and re-run doctor" is advice that can never come true.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.telemetry.bus_enabled = false'
DR_SP_EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
DR_SP_OUT=$(_dr_sp_run)
assert_eq "P12g: with the bus off and no log, the outcome is bus-disabled — never NEVER OBSERVED" \
  "$(_dr_sp_outcomes "$DR_SP_OUT")" "TELEMETRY BUS DISABLED|"
assert_contains "P12g: the message names the config key that made the check unanswerable" \
  "$DR_SP_OUT" "telemetry.bus_enabled is false"
assert_not_contains "P12g: and never repeats the impossible remediation" \
  "$DR_SP_OUT" "Run one loop iteration (any Stop emits the record)"
assert_contains "P12g: the bus-off skip is counted as not-applicable-config" \
  "$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null | tail -1)" \
  "not-applicable-config=1"

# Same fixture, bus back on: proves the branch keys on the config, not on the log.
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn '{sv:1,event:"stop_payload_observed",bg_seen:"yes",entries:1,subagents:0,live:0,types:"shell",statuses:"completed"}' > "$DR_SP_EVENTS"
assert_eq "P12g: a stale record cannot be refreshed while the bus is off, so it is still bus-disabled" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "TELEMETRY BUS DISABLED|"
assert_contains "P12g: and the stale-record wording differs from the no-record wording" \
  "$(_dr_sp_msg "$(_dr_sp_run)")" "can never be refreshed"
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.telemetry.bus_enabled = true'
assert_eq "P12g: flipping the bus back on returns the same record to FIELD PRESENT" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "FIELD PRESENT at the last recorded Stop|"
teardown_temp_dir

assert_file_not_contains "P12g: SKILL.md no longer claims the three-outcome set" \
  "$REPO_ROOT/skills/doctor/SKILL.md" "present, absent, or never observed"
DR_SP_SKILL_MISSING=0
for tok in 'field present but wrong shape' 'field absent' 'payload undetermined' \
           'record unselectable' 'never observed' 'telemetry bus disabled' 'loop paused'; do
  grep -qF "$tok" "$REPO_ROOT/skills/doctor/SKILL.md" || DR_SP_SKILL_MISSING=$((DR_SP_SKILL_MISSING + 1))
done
assert_eq "P12g: SKILL.md enumerates all 7 named outcomes doctor can report (7 scanned)" \
  "$DR_SP_SKILL_MISSING" "0"

# --- (n) stop-payload: P12i — paused=true, the second unreachable remediation ---
# stop-hook.sh returns above the emit and pause is sticky, so no number of iterations makes a record.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.paused = true'
DR_SP_EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
DR_SP_OUT=$(_dr_sp_run)
DR_SP_M_PAUSED=$(_dr_sp_msg "$DR_SP_OUT")
assert_eq "P12i: paused with no record is LOOP PAUSED — never NEVER OBSERVED" \
  "$(_dr_sp_outcomes "$DR_SP_OUT")" "LOOP PAUSED|"
assert_contains "P12i: the message names the pause as the reason no Stop can be recorded" \
  "$DR_SP_OUT" "paused=true"
assert_contains "P12i: and says why more iterations cannot clear it" "$DR_SP_OUT" "pause is STICKY"
assert_contains "P12i: the remediation is the one command that clears a pause" \
  "$DR_SP_OUT" "Run /nazgul:start to resume"
assert_not_contains "P12i: and never repeats the unreachable remediation" \
  "$DR_SP_OUT" "Run one loop iteration (any Stop emits the record)"
assert_contains "P12i: the paused skip is counted as not-applicable-config, not as a checked answer" \
  "$(cd "$TEST_DIR" && env -u CLAUDE_PLUGIN_ROOT -u NAZGUL_DIR bash "$DOCTOR" --only=stop-payload 2>/dev/null | tail -1)" \
  "not-applicable-config=1"

# The has-a-record control: unlike bus-off, a pause is operator-clearable, so a record that
# predates it is still valid evidence and the new arm must not swallow it.
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn '{sv:1,event:"stop_payload_observed",bg_seen:"yes",entries:1,subagents:1,live:1,types:"subagent",statuses:"running"}' > "$DR_SP_EVENTS"
assert_eq "P12i: paused WITH a record still reports that record normally" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "FIELD PRESENT at the last recorded Stop|"

# The NEGATIVE control: same empty log, pause flipped off. Without it an arm that fired
# unconditionally would leave every cell above green.
rm -f "$DR_SP_EVENTS"
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.paused = false'
DR_SP_OUT=$(_dr_sp_run)
DR_SP_M_NEVER2=$(_dr_sp_msg "$DR_SP_OUT")
assert_eq "P12i negative control: NOT paused with no record is still NEVER OBSERVED" \
  "$(_dr_sp_outcomes "$DR_SP_OUT")" "NEVER OBSERVED|"
assert_contains "P12i negative control: and that arm keeps its own reachable remediation" \
  "$DR_SP_OUT" "Run one loop iteration (any Stop emits the record)"

# Two empty strings are also "different from nothing else", so the non-empty floor is what
# stops the distinctness pair below from being satisfiable by two captures of nothing.
assert_eq "P12i floor: both arms' messages were actually captured" \
  "$([ -n "$DR_SP_M_PAUSED" ] && [ -n "$DR_SP_M_NEVER2" ] && echo yes || echo no)" "yes"
assert_eq "P12i: the paused arm does not print the same thing as never-observed (RULES §15)" \
  "$([ "$DR_SP_M_PAUSED" != "$DR_SP_M_NEVER2" ] && echo distinct || echo identical)" "distinct"

# Precedence, pinned both ways: bus-off wins because it is the stronger claim — no record can
# EVER be written — where a pause clears with one operator command.
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.paused = true' '.telemetry.bus_enabled = false'
assert_eq "P12i: paused AND bus off reports bus-disabled — one arm wins, never both" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "TELEMETRY BUS DISABLED|"

# "Could not look" outranks "cannot look yet": a record may already exist, and reporting the
# pause instead would hide that a Stop was in fact measured here.
_dr_config ".schema_version = $HIGHEST_MIGRATION" '.connectors.github.enabled = false' \
  '.board.enabled = false' '.guards.git_hooks = false' '.paused = true'
printf '{"event":"stop_payload_observed", TRUNCATED\n' > "$DR_SP_EVENTS"
assert_eq "P12i: paused with an unselectable record is UNSELECTABLE RECORD, not LOOP PAUSED" \
  "$(_dr_sp_outcomes "$(_dr_sp_run)")" "UNSELECTABLE RECORD|"
teardown_temp_dir

# --- (n) stop-payload: P12d — the enrollment boundary (ruling item 7) ---
# FEAT-031 made this roster DERIVED from RULES.md §15 itself, so the literal
# ENTRY_POINTS= line this block used to read is now empty by construction.
# shellcheck source=./lib/rules-registry.sh
source "$REPO_ROOT/tests/lib/rules-registry.sh"
DR_ENTRY_LINE=$(_registry_members "$REPO_ROOT/RULES.md")
DR_ENTRY_COUNT=$(printf '%s\n' "$DR_ENTRY_LINE" | grep -c . || true)
assert_eq "P12d floor: the §15 registry was actually parsed, not read as empty" \
  "$([ "$DR_ENTRY_COUNT" -ge 5 ] && echo yes || echo no)" "yes"
assert_contains "P12d: doctor's ONE pre-existing enrollment is still there" "$DR_ENTRY_LINE" "doctor"
assert_not_contains "P12d: the unscored note enrolled no entry point of its own" "$DR_ENTRY_LINE" "stop-payload"

# The roster size is a claim two docs restate in words; a count string that drifts
# from the live roster is the stale-claim defect, not a cosmetic one.
_dr_count_word() {
  case "$1" in
    10) printf 'ten' ;; 11) printf 'eleven' ;; 12) printf 'twelve' ;;
    13) printf 'thirteen' ;; 14) printf 'fourteen' ;; 15) printf 'fifteen' ;;
    *) printf 'UNMAPPED-%s' "$1" ;;
  esac
}
DR_COUNT_WORD=$(_dr_count_word "$DR_ROSTER_COUNT")
assert_not_contains "P12d: the live roster size has a word form at all" "$DR_COUNT_WORD" "UNMAPPED"
DR_COUNT_SITES=$(grep -ohE '\b(ten|eleven|twelve|thirteen|fourteen|fifteen) checks\b' \
  "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/skills/doctor/SKILL.md" | wc -l | tr -d ' ')
assert_eq "P12d floor: all four known count-string sites were scanned" \
  "$([ "$DR_COUNT_SITES" -ge 4 ] && echo yes || echo no)" "yes"
DR_COUNT_STALE=$(grep -ohE '\b(ten|eleven|twelve|thirteen|fourteen|fifteen) checks\b' \
  "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/skills/doctor/SKILL.md" | grep -vc "^$DR_COUNT_WORD checks$" || true)
assert_eq "P12d: $DR_COUNT_SITES count-string site(s) scanned — every one names the live roster size" \
  "$DR_COUNT_STALE" "0"

report_results
