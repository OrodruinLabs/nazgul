#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero `git merge` exit code.

TEST_NAME="test-git-hooks-premerge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

PRE_MERGE="$REPO_ROOT/scripts/git-hooks/pre-merge-commit"
DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

# Minimal manual install (NOT production install_git_hooks, to stay acyclic):
# copies the hook + dispatcher into a per-repo hooks dir and points
# core.hooksPath at it directly.
install_hooks() {
  local repo="$1"
  mkdir -p "$repo/.githooks"
  cp "$PRE_MERGE" "$repo/.githooks/pre-merge-commit"
  cp "$DISPATCH" "$repo/.githooks/_dispatch.sh"
  chmod +x "$repo/.githooks/pre-merge-commit" "$repo/.githooks/_dispatch.sh"
  git -C "$repo" config core.hooksPath "$repo/.githooks"
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "t@t.t"
  git -C "$repo" config user.name "t"
  git -C "$repo" commit -q --allow-empty -m "init"
}

make_unit_branch() {
  local repo="$1" branch="$2"
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" commit -q --allow-empty -m "unit work"
  git -C "$repo" checkout -q main
}

branch_sha() {
  local repo="$1" branch="$2"
  git -C "$repo" rev-parse "$branch"
}

write_config() {
  local repo="$1" json="$2"
  mkdir -p "$repo/nazgul"
  printf '%s' "$json" > "$repo/nazgul/config.json"
}

# Writes a task manifest with a ## Commits section (the commit-lookup source
# the hook greps) and a list-item ## Status line (the verdict source).
write_task() {
  local repo="$1" id="$2" status="$3" sha="$4"
  mkdir -p "$repo/nazgul/tasks"
  cat > "$repo/nazgul/tasks/$id.md" <<EOF
# $id

- **Status**: $status

## Commits

- $sha task work
EOF
}

do_merge() {
  local repo="$1" branch="$2"
  MERGE_STDERR=$(git -C "$repo" merge --no-ff -m "merge $branch" "$branch" 2>&1) && MERGE_EC=0 || MERGE_EC=$?
  git -C "$repo" merge --abort 2>/dev/null || true
}

# Merges $branch while GIT_REFLOG_ACTION is pre-set to falsely claim
# $claimed_ref. Real `git merge` porcelain, exercising the exact spoof git
# itself won't overwrite (setenv overwrite=0 only fires when unset). Proves
# GIT_REFLOG_ACTION carries zero weight in identity resolution.
do_merge_reflog_spoofed() {
  local repo="$1" branch="$2" claimed_ref="$3"
  MERGE_STDERR=$(GIT_REFLOG_ACTION="merge $claimed_ref" git -C "$repo" merge --no-ff -m "merge $branch" "$branch" 2>&1) && MERGE_EC=0 || MERGE_EC=$?
  git -C "$repo" merge --abort 2>/dev/null || true
}

# Merges $branch while a decoy GITHEAD_<claimed_sha>=<label> is pre-set,
# alongside the genuine GITHEAD_<real-sha> git itself adds for $branch's
# actual tip. Proves a decoy claiming an approved unit's identity cannot
# mask the real, unapproved content also present.
do_merge_githead_spoofed() {
  local repo="$1" branch="$2" claimed_sha="$3"
  MERGE_STDERR=$(env "GITHEAD_${claimed_sha}=feat/FEAT-010-x/TASK-999" git -C "$repo" merge --no-ff -m "merge $branch" "$branch" 2>&1) && MERGE_EC=0 || MERGE_EC=$?
  git -C "$repo" merge --abort 2>/dev/null || true
}

# Builds a directory containing every /usr/bin binary EXCEPT jq (as symlinks),
# for prepending to PATH to simulate "jq not installed" without breaking git
# itself (git and jq are typically both resolvable from /usr/bin on macOS).
make_no_jq_bin_dir() {
  local dir="$1" srcdir bin name
  mkdir -p "$dir"
  # Farm every tool from all standard bin dirs EXCEPT jq into an isolated dir,
  # so PATH can point at ONLY this dir and genuinely lose jq on any platform.
  # We must NOT keep /bin etc. on PATH: on usrmerge Linux /bin -> /usr/bin, so
  # /bin/jq would reappear and the guard would never fire (macOS hid this
  # because its jq lives in a Homebrew dir separate from /usr/bin).
  for srcdir in /usr/bin /bin /usr/local/bin /opt/homebrew/bin /usr/sbin /sbin; do
    [ -d "$srcdir" ] || continue
    for bin in "$srcdir"/*; do
      [ -e "$bin" ] || continue
      name="${bin##*/}"
      [ "$name" = "jq" ] && continue
      [ -e "$dir/$name" ] && continue
      ln -sf "$bin" "$dir/$name" 2>/dev/null || true
    done
  done
}

# Builds a directory with a `jq` wrapper that fails ONLY for invocations
# carrying the `-s` flag (the raw-slurp mode used solely by the
# GITHEAD_* candidate-SHA pipeline) and delegates every other call to the
# real jq — a targeted, non-total failure of one pipeline in the hook.
make_flaky_jq_bin_dir() {
  local dir="$1" real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$dir"
  cat > "$dir/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "-s" ] && exit 1
done
exec "$real_jq" "\$@"
EOF
  chmod +x "$dir/jq"
}

PARALLEL_CONFIG='{"execution":{"parallel":true},"guards":{"git_hooks":true}}'

# ---------------------------------------------------------------------------
# BLOCK: content-matched unit, manifest Status != DONE -> merge fails.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "block: non-DONE unit merge -> nonzero" "$MERGE_EC" 1
assert_contains "block message names the unit" "$MERGE_STDERR" "TASK-001"
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW (content-match happy path): the merged commit is listed under a
# DONE unit's ## Commits section -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "DONE" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "allow: content-matched DONE unit -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# SPOOF (primary): a decoy GITHEAD_<sha>=<label> falsely claims a DONE unit
# (TASK-999) while the actual merged content is a DIFFERENT, unapproved unit
# (TASK-888) — git itself still sets the genuine GITHEAD_<real-sha> for
# TASK-888 alongside the decoy. The guard must resolve identity from the
# real content match, not accept the decoy label, so the unreviewed content
# must NOT be admitted under TASK-999's approval.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-999"
APPROVED_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-999")
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888"
MALICIOUS_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-999" "DONE" "$APPROVED_SHA"
write_task "$TEST_DIR/repo" "TASK-888" "IN_REVIEW" "$MALICIOUS_SHA"
do_merge_githead_spoofed "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888" "$APPROVED_SHA"
assert_exit_code "spoof: decoy GITHEAD for DONE unit does not admit unapproved content -> nonzero" "$MERGE_EC" 1
assert_contains "spoof: block message names the REAL (content-resolved) unit, not the decoy" "$MERGE_STDERR" "TASK-888"
teardown_temp_dir

# ---------------------------------------------------------------------------
# SPOOF (secondary): GIT_REFLOG_ACTION falsely claims a DONE unit (TASK-999)
# while the actual merge content is the DIFFERENT, unapproved TASK-888 ->
# proves GIT_REFLOG_ACTION carries zero identity weight at all.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-999"
APPROVED_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-999")
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888"
MALICIOUS_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-999" "DONE" "$APPROVED_SHA"
write_task "$TEST_DIR/repo" "TASK-888" "IN_REVIEW" "$MALICIOUS_SHA"
do_merge_reflog_spoofed "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-888" "feat/FEAT-010-x/TASK-999"
assert_exit_code "spoof: claimed-DONE reflog label does not admit unapproved content -> nonzero" "$MERGE_EC" 1
assert_contains "spoof: block message names the REAL (content-resolved) unit, not the claimed one" "$MERGE_STDERR" "TASK-888"
teardown_temp_dir

# ---------------------------------------------------------------------------
# NO-OP: execution.parallel=false -> unit merge allowed regardless of
# manifest status.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"parallel":false},"guards":{"git_hooks":true}}'
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "no-op: execution.parallel=false -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no nazgul/tasks manifests at all -> allowed even under parallel.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: no task manifests -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: untracked merge commit (not recorded against any manifest) ->
# allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "topic-branch"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
do_merge "$TEST_DIR/repo" "topic-branch"
assert_exit_code "degrade: untracked commit, no manifest match -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# FALSE-BLOCK REGRESSION: a /TASK-NNN-suffixed branch WITHOUT the feat/
# prefix, whose commit was never recorded in any manifest's ## Commits
# section, must degrade to allow — content-based resolution means branch
# shape never gates.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "docs/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "0000000"
do_merge "$TEST_DIR/repo" "docs/TASK-001"
assert_exit_code "false-block regression: docs/TASK-001 (non-feat/ prefix) -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: kill-switch execution.enforce.premerge_guard=false -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"parallel":true,"enforce":{"premerge_guard":false}},"guards":{"git_hooks":true}}'
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: kill-switch premerge_guard=false -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: guards.git_hooks=false -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"parallel":true},"guards":{"git_hooks":false}}'
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: guards.git_hooks=false -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no nazgul/config.json -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: no config -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no merge in progress (no GITHEAD_* identity present) -> hook
# invoked directly -> allowed. This is the only scenario requiring direct
# invocation: a real `git merge` always sets GITHEAD_<sha> for each head it
# merges by the time pre-merge-commit runs.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "0000000"
(cd "$TEST_DIR/repo" && "$TEST_DIR/repo/.githooks/pre-merge-commit" >/dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
assert_exit_code "degrade: no GITHEAD_* identity (no merge in progress) -> exit 0" "$HOOK_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# CHAIN-DISPATCH: after allowing (content-matched DONE unit), the prior
# pre-merge-commit hook still runs; if it blocks, its exit propagates.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
mkdir -p "$TEST_DIR/prior-hooks"
cat > "$TEST_DIR/prior-hooks/pre-merge-commit" <<'EOF'
#!/usr/bin/env bash
echo "prior hook ran" >&2
exit 1
EOF
chmod +x "$TEST_DIR/prior-hooks/pre-merge-commit"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "{\"execution\":{\"parallel\":true},\"branch\":{\"prior_hooks_path\":\"$TEST_DIR/prior-hooks\"},\"guards\":{\"git_hooks\":true}}"
write_task "$TEST_DIR/repo" "TASK-001" "DONE" "$UNIT_SHA"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "chain-dispatch: prior hook exit 1 propagates on allow path" "$MERGE_EC" 1
assert_contains "chain-dispatch: prior hook actually ran" "$MERGE_STDERR" "prior hook ran"
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: jq unavailable on PATH -> the hook must never abort under
# `set -e` and block the merge; it must fail open (allow).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
# A dir under TEST_DIR would embed the literal ":" in "nazgul:test-XXXXXX"
# (from setup_temp_dir), corrupting PATH — use a colon-free temp dir instead.
NO_JQ_BIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-no-jq-XXXXXX")
make_no_jq_bin_dir "$NO_JQ_BIN"
PATH="$NO_JQ_BIN" do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: jq missing from PATH -> exit 0 (never blocks)" "$MERGE_EC" 0
rm -rf "$NO_JQ_BIN"
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: the GITHEAD_* candidate-SHA pipeline fails (jq errors on its `-s`
# invocation specifically) -> under `set -e` this must not abort the script
# and block the merge; it must degrade to allow, same as "no candidates".
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
UNIT_SHA=$(branch_sha "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001")
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$PARALLEL_CONFIG"
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$UNIT_SHA"
FLAKY_JQ_BIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-flaky-jq-XXXXXX")
make_flaky_jq_bin_dir "$FLAKY_JQ_BIN"
PATH="$FLAKY_JQ_BIN:$PATH" do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: candidate-SHA pipeline failure -> exit 0 (never blocks)" "$MERGE_EC" 0
rm -rf "$FLAKY_JQ_BIN"
teardown_temp_dir

report_results
