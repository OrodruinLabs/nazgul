#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero exit code.

TEST_NAME="test-git-hooks-install"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/git-hooks.sh"

echo "=== $TEST_NAME ==="

init_repo() {
  local repo="$1" branch="${2:-main}"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@t.t"
  git -C "$repo" config user.name "t"
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" commit -q --allow-empty -m "init"
}

write_config() {
  local repo="$1" json="$2"
  mkdir -p "$repo/nazgul"
  printf '%s' "$json" > "$repo/nazgul/config.json"
}

# ---------------------------------------------------------------------------
# INSTALL (no prior value): core.hooksPath was unset -> managed dir set,
# prior_hooks_path recorded as the empty sentinel, templates + shims present.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"

INSTALLED_PATH=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "install: core.hooksPath set to managed dir" "$INSTALLED_PATH" "nazgul/.githooks"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "install: no-prior-value recorded as empty sentinel" "$RECORDED_PRIOR" ""
assert_file_exists "install: pre-commit template copied" "$TEST_DIR/repo/nazgul/.githooks/pre-commit"
assert_file_exists "install: pre-merge-commit template copied" "$TEST_DIR/repo/nazgul/.githooks/pre-merge-commit"
assert_file_exists "install: dispatcher copied" "$TEST_DIR/repo/nazgul/.githooks/_dispatch.sh"
assert_file_exists "install: pre-push shim generated" "$TEST_DIR/repo/nazgul/.githooks/pre-push"
assert_file_exists "install: commit-msg shim generated" "$TEST_DIR/repo/nazgul/.githooks/commit-msg"
if [ -x "$TEST_DIR/repo/nazgul/.githooks/pre-push" ]; then SHIM_EXEC_EC=0; else SHIM_EXEC_EC=1; fi
assert_exit_code "install: shim is executable" "$SHIM_EXEC_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# INSTALL -> UNINSTALL round trip (no prior value): restores true unset, not
# an empty string ("git config --get" must fail afterward).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "uninstall: no-prior-value case truly unsets (nonzero get)" "$?" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# INSTALL -> UNINSTALL round trip (real prior value): restores it exactly.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "install: real prior value recorded" "$RECORDED_PRIOR" ".husky"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "uninstall: real prior value restored exactly" "$RESTORED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# RE-INSTALL idempotency: calling install twice does not clobber the
# already-recorded prior value with the managed dir itself.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "re-install: prior value not clobbered" "$RECORDED_PRIOR" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# BF-1 REGRESSION: install -> external drift -> re-install must NOT re-record
# the drifted value over the true original (incl. the "was unset" case).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "bf1: first install records true prior (unset sentinel)" "$RECORDED_PRIOR" ""
git -C "$TEST_DIR/repo" config core.hooksPath "/some/other/dir"
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "bf1: reinstall after drift does not clobber true prior" "$RECORDED_PRIOR" ""
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "bf1: uninstall restores the true original (unset), not the drifted value" "$?" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# NULL-SENTINEL REGRESSION: a config seeded the way real init/migration ships
# it — `prior_hooks_path: null` PRESENT (not the key omitted) — must still be
# treated as "not yet recorded" so a real prior `core.hooksPath` gets
# captured on first install, not skipped.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":null},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RECORDED_PRIOR=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "null-sentinel: template-seeded null field still records true prior" "$RECORDED_PRIOR" ".husky"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "null-sentinel: uninstall restores the true prior exactly" "$RESTORED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# TWO-CYCLE SURVIVAL: install -> uninstall -> install -> uninstall with a
# real non-empty prior must restore the true original on BOTH cycles (the
# re-arm after uninstall must be `null`, not "", or cycle 2 would corrupt).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "two-cycle: cycle 1 restores true prior" "$RESTORED" ".husky"
REARMED=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "two-cycle: uninstall re-arms field to null, not empty string" "$REARMED" "null"
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "two-cycle: cycle 2 still restores true prior (not corrupted)" "$RESTORED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# guards.git_hooks: false -> install is a no-op.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":false}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "install: guards.git_hooks=false -> core.hooksPath untouched" "$?" 1
assert_dir_not_exists "install: guards.git_hooks=false -> no managed dir created" "$TEST_DIR/repo/nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: drift -> reasserts managed dir.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config core.hooksPath ".git/hooks"
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
HEALED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: drift reasserts managed dir" "$HEALED" "nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: guards.git_hooks=false (intentional disable) -> drifted value
# left untouched.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":false}}'
git -C "$TEST_DIR/repo" config core.hooksPath ".git/hooks"
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
UNTOUCHED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: guards.git_hooks=false leaves intentional change alone" "$UNTOUCHED" ".git/hooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: no active objective (branch.feature unset) -> left untouched.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":null,"prior_hooks_path":""},"guards":{"git_hooks":true}}'
git -C "$TEST_DIR/repo" config core.hooksPath ".git/hooks"
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
UNTOUCHED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: no active objective leaves change alone" "$UNTOUCHED" ".git/hooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: already correct -> no-op (idempotent, no error).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: already correct is a no-op" "$STILL" "nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: active objective, never installed (prior_hooks_path null) ->
# first-time install (MF-034 residual-gap broadening). A real pre-existing
# user core.hooksPath (e.g. .husky) is durably recorded as the value to
# restore later, not blind-overwritten.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":null},"guards":{"git_hooks":true}}'
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
INSTALLED_NULL=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: active objective + never installed triggers first-time install" "$INSTALLED_NULL" "nazgul/.githooks"
assert_dir_exists "self-heal: first-time install creates the managed dir" "$TEST_DIR/repo/nazgul/.githooks"
RECORDED_NULL=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "self-heal: first-time install records the real prior hooksPath" "$RECORDED_NULL" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SELF-HEAL: never installed (null field) and NO active objective
# (branch.feature unset) -> no-op. The feature gate wins: only an active
# objective's residual gap gets a first-time install.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","prior_hooks_path":null},"guards":{"git_hooks":true}}'
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: never installed, no active objective leaves user hooksPath alone" "$STILL_HUSKY" ".husky"
assert_dir_not_exists "self-heal: never installed, no active objective does not create managed dir" "$TEST_DIR/repo/nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# CHAIN-DISPATCH via a real commit: a pre-existing user pre-commit hook still
# runs after install, and its exit code still propagates.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo" "feat/x"
mkdir -p "$TEST_DIR/repo/.git/hooks"
cat > "$TEST_DIR/repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "prior pre-commit ran" >&2
exit 1
EOF
chmod +x "$TEST_DIR/repo/.git/hooks/pre-commit"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
echo "content" > "$TEST_DIR/repo/a.txt"
git -C "$TEST_DIR/repo" add a.txt
COMMIT_STDERR=$(git -C "$TEST_DIR/repo" commit -q -m "commit a.txt" 2>&1) && COMMIT_EC=0 || COMMIT_EC=$?
assert_exit_code "chain-dispatch: prior pre-commit exit code propagates" "$COMMIT_EC" 1
assert_contains "chain-dispatch: prior pre-commit actually ran" "$COMMIT_STDERR" "prior pre-commit ran"
teardown_temp_dir

# ---------------------------------------------------------------------------
# CHAIN-DISPATCH via a real push: a pre-existing user pre-push hook (a name
# Nazgul does not define) still runs after install.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo" "feat/x"
mkdir -p "$TEST_DIR/repo/.git/hooks"
cat > "$TEST_DIR/repo/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
echo "prior pre-push ran" >&2
exit 1
EOF
chmod +x "$TEST_DIR/repo/.git/hooks/pre-push"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"

git init -q --bare "$TEST_DIR/remote.git"
git -C "$TEST_DIR/repo" remote add origin "$TEST_DIR/remote.git"
PUSH_STDERR=$(git -C "$TEST_DIR/repo" push origin "feat/x" 2>&1) && PUSH_EC=0 || PUSH_EC=$?
assert_exit_code "chain-dispatch: prior pre-push exit code propagates" "$PUSH_EC" 1
assert_contains "chain-dispatch: prior pre-push actually ran" "$PUSH_STDERR" "prior pre-push ran"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MALFORMED CONFIG: install must NOT touch core.hooksPath when config.json
# doesn't parse as JSON — jq can't safely record a prior for later restore.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
mkdir -p "$TEST_DIR/repo/nazgul"
printf '%s' '{not valid json' > "$TEST_DIR/repo/nazgul/config.json"
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "install: malformed config -> core.hooksPath untouched" "$?" 1
assert_dir_not_exists "install: malformed config -> no managed dir created" "$TEST_DIR/repo/nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# NON-OBJECT .branch: install with valid-JSON but `.branch` a scalar must
# NO-OP entirely (not silently coerce and proceed) — a corrupt `.branch`
# field is not a trustworthy place to record a restorable prior.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":"x","guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "install: non-object .branch -> core.hooksPath untouched" "$STILL_HUSKY" ".husky"
assert_dir_not_exists "install: non-object .branch -> no managed dir created" "$TEST_DIR/repo/nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# PERSIST FAILURE: if the prior value can't be durably written (e.g. the
# nazgul dir is not writable), install must NOT set core.hooksPath — a
# later uninstall would have nothing real to restore.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main"},"guards":{"git_hooks":true}}'
chmod 555 "$TEST_DIR/repo/nazgul"
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" 2>/dev/null
chmod 755 "$TEST_DIR/repo/nazgul"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "install: persist failure -> core.hooksPath untouched" "$STILL_HUSKY" ".husky"
assert_dir_not_exists "install: persist failure -> no managed dir created" "$TEST_DIR/repo/nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MALFORMED CONFIG: uninstall must NOT touch a pre-existing real
# core.hooksPath when config.json doesn't parse as JSON.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
mkdir -p "$TEST_DIR/repo/nazgul"
printf '%s' '{not valid json' > "$TEST_DIR/repo/nazgul/config.json"
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "uninstall: malformed config -> pre-existing core.hooksPath unchanged" "$STILL_HUSKY" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# NEVER-RECORDED PRIOR: uninstall with `prior_hooks_path: null` (install
# never ran for this cycle) must NOT touch a pre-existing real
# core.hooksPath — only "" (recorded-as-unset) or a real recorded path may
# act.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":null},"guards":{"git_hooks":true}}'
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "uninstall: never-recorded prior (null) leaves pre-existing core.hooksPath alone" "$STILL_HUSKY" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# NON-OBJECT .branch: uninstall with valid-JSON but `.branch` a scalar must
# NO-OP — pre-existing core.hooksPath left exactly as-is.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":5,"guards":{"git_hooks":true}}'
uninstall_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
STILL_HUSKY=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "uninstall: non-object .branch -> pre-existing core.hooksPath unchanged" "$STILL_HUSKY" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# NON-OBJECT .branch: self-heal with valid-JSON but `.branch` a scalar must
# NO-OP — never blind-overwrite because it can't safely read `feature` or
# the recorded prior.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":"x","guards":{"git_hooks":true}}'
git -C "$TEST_DIR/repo" config core.hooksPath ".git/hooks-other"
self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
UNTOUCHED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: non-object .branch leaves core.hooksPath alone" "$UNTOUCHED" ".git/hooks-other"
teardown_temp_dir

report_results
