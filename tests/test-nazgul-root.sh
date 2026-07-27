#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-nazgul-root"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/nazgul-root.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-root-test-XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# Real git repo, one commit (worktree add requires at least one commit).
_mk_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@nazgul.dev"
  git -C "$dir" config user.name "Nazgul Test"
  touch "$dir/.gitkeep"
  git -C "$dir" add .gitkeep
  git -C "$dir" commit -q -m "initial"
}

_mk_nazgul_marker() {
  mkdir -p "$1/nazgul"
  echo '{"marker":"'"$2"'"}' > "$1/nazgul/config.json"
}

# Runs `source "$LIB"; resolve_project_root` with cwd=$1 and CLAUDE_PROJECT_DIR=$2
# ("" means unset). PATH is left untouched here; _resolve_no_git shadows it separately.
_resolve() {
  local cwd="$1" cpd="$2"
  (
    cd "$cwd" || exit 1
    if [ -n "$cpd" ]; then export CLAUDE_PROJECT_DIR="$cpd"; else unset CLAUDE_PROJECT_DIR; fi
    # shellcheck source=/dev/null
    source "$LIB"
    resolve_project_root
  )
}

_resolve_no_git() {
  local cwd="$1" cpd="$2"
  (
    cd "$cwd" || exit 1
    if [ -n "$cpd" ]; then export CLAUDE_PROJECT_DIR="$cpd"; else unset CLAUDE_PROJECT_DIR; fi
    # shellcheck disable=SC2123 # deliberately shadow PATH to simulate git being unavailable
    PATH="$TMP_ROOT/empty-bin"
    # shellcheck source=/dev/null
    source "$LIB"
    resolve_project_root
  )
}

mkdir -p "$TMP_ROOT/empty-bin"

# --- Case 1a: plain git init, CLAUDE_PROJECT_DIR unset -> resolves to toplevel ---
repo1="$TMP_ROOT/repo1"
_mk_git_repo "$repo1"
_mk_nazgul_marker "$repo1" "repo1"
result="$(_resolve "$repo1" "")"
assert_eq "plain git repo, env unset: resolves to toplevel" "$result" "$repo1"

# --- Case 1b: same repo, CLAUDE_PROJECT_DIR exported to a DIFFERENT valid root ---
repoB="$TMP_ROOT/repoB"
mkdir -p "$repoB"
_mk_nazgul_marker "$repoB" "repoB"
result="$(_resolve "$repo1" "$repoB")"
assert_eq "git toplevel wins over a stale but valid CLAUDE_PROJECT_DIR" "$result" "$repo1"

# --- Case 2: git worktree add, nested path, own nazgul/config.json ---
mainrepo="$TMP_ROOT/mainrepo"
_mk_git_repo "$mainrepo"
_mk_nazgul_marker "$mainrepo" "main"
worktree="$mainrepo/.claude/worktrees/feat-x"
git -C "$mainrepo" worktree add -q "$worktree" -b feat-x >/dev/null 2>&1
_mk_nazgul_marker "$worktree" "worktree"

result="$(_resolve "$worktree" "")"
assert_eq "worktree cwd resolves to worktree root, not main checkout" "$result" "$worktree"

deep="$worktree/a/b/c"
mkdir -p "$deep"
result="$(_resolve "$deep" "")"
assert_eq "worktree cwd several levels deep still resolves to worktree root" "$result" "$worktree"

# --- Case 3: unrelated repo (no marker) + CLAUDE_PROJECT_DIR pointing at a valid root ---
unrelated="$TMP_ROOT/unrelated"
_mk_git_repo "$unrelated"
valid_root="$TMP_ROOT/valid-root"
mkdir -p "$valid_root"
_mk_nazgul_marker "$valid_root" "valid"
result="$(_resolve "$unrelated" "$valid_root")"
assert_eq "unrelated repo with no marker: falls through to valid CLAUDE_PROJECT_DIR" "$result" "$valid_root"

# --- Case 4a: non-git host, CLAUDE_PROJECT_DIR set (unvalidated fallback) ---
nongit="$TMP_ROOT/nongit"
mkdir -p "$nongit"
cpd_target="$TMP_ROOT/cpd-target"
mkdir -p "$cpd_target"
result="$(_resolve "$nongit" "$cpd_target")"
assert_eq "non-git host + CLAUDE_PROJECT_DIR set: falls back to CLAUDE_PROJECT_DIR" "$result" "$cpd_target"

# --- Case 4b: non-git host, CLAUDE_PROJECT_DIR unset ---
result="$(_resolve "$nongit" "")"
assert_eq "non-git host + env unset: falls back to \$(pwd)" "$result" "$nongit"

# --- Case 5: git unavailable (PATH shadowed), inside a real git repo ---
result="$(_resolve_no_git "$repo1" "")"
assert_eq "git unavailable: same fallback as non-git host (\$(pwd))" "$result" "$repo1"

result="$(_resolve_no_git "$nongit" "$cpd_target")"
assert_eq "git unavailable + CLAUDE_PROJECT_DIR set: falls back to CLAUDE_PROJECT_DIR" "$result" "$cpd_target"

# --- resolve_nazgul_dir() appends /nazgul to the resolved root ---
result="$(
  cd "$repo1" || exit 1
  unset CLAUDE_PROJECT_DIR
  # shellcheck source=/dev/null
  source "$LIB"
  resolve_nazgul_dir
)"
assert_eq "resolve_nazgul_dir appends /nazgul to the resolved root" "$result" "$repo1/nazgul"

# --- Safe to source twice in the same shell (idempotent) ---
result="$(
  cd "$repo1" || exit 1
  unset CLAUDE_PROJECT_DIR
  # shellcheck source=/dev/null
  source "$LIB"
  # shellcheck source=/dev/null
  source "$LIB"
  resolve_project_root
)"
assert_eq "sourcing the library twice is safe and idempotent" "$result" "$repo1"

# --- Sourcing does not impose set -e on the sourcing shell ---
result="$(
  set +e
  # shellcheck source=/dev/null
  source "$LIB"
  false
  echo "survived"
)"
assert_eq "sourcing the library does not set -e on the caller" "$result" "survived"

# --- Safe to source under set -euo pipefail without crashing ---
strict_exit=0
(
  set -euo pipefail
  cd "$repo1" || exit 1
  unset CLAUDE_PROJECT_DIR
  # shellcheck source=/dev/null
  source "$LIB"
  resolve_project_root >/dev/null
) || strict_exit=$?
assert_eq "safe to source and call under set -euo pipefail" "$strict_exit" "0"

# --- Calling the resolver does not leak a cd in the caller's shell ---
before="$(cd "$TMP_ROOT" && pwd -P)"
after="$(
  cd "$TMP_ROOT" || exit 1
  # shellcheck source=/dev/null
  source "$LIB"
  resolve_project_root >/dev/null
  pwd -P
)"
assert_eq "resolver call does not leave the caller's cwd changed" "$after" "$before"

report_results
exit $?
