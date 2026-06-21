#!/usr/bin/env bash
set -euo pipefail
# Test: files_modified_json always emits exactly ONE valid JSON array, including
# the single-commit (greenfield) case that previously produced "[]\n[]" and
# aborted the stop hook with "jq: invalid JSON text passed to --argjson".
TEST_NAME="test-git-utils"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/git-utils.sh"
echo "=== $TEST_NAME ==="

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkrepo() {
  local d="$1"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
}
# single valid JSON value? (slurp -> exactly one) — this is the core regression
is_one_json() { printf '%s\n' "$1" | jq -s -e 'length==1 and (.[0]|type=="array")' >/dev/null 2>&1 && echo yes || echo no; }

# --- No commits: -> [] (one value) ---
R="$TMP/empty"; mkrepo "$R"
out=$(files_modified_json "$R")
assert_eq "no commits -> single JSON" "$(is_one_json "$out")" "yes"
assert_eq "no commits -> []" "$(printf '%s' "$out" | jq -c .)" "[]"

# --- Single commit (THE BUG): no HEAD~1 -> empty-tree diff, ONE valid array ---
R="$TMP/one"; mkrepo "$R"
printf 'a\n' > "$R/a.txt"; printf 'b\n' > "$R/b.txt"
git -C "$R" add -A; git -C "$R" commit -qm first
out=$(files_modified_json "$R")
assert_eq "single commit -> single JSON value (not []\\n[])" "$(is_one_json "$out")" "yes"
assert_eq "single commit lists a.txt" "$(printf '%s' "$out" | jq -r 'index("a.txt") != null')" "true"
assert_eq "single commit lists b.txt" "$(printf '%s' "$out" | jq -r 'index("b.txt") != null')" "true"
# It must be consumable by --argjson (the exact failure mode reported)
assert_eq "single commit feeds --argjson" "$(jq -nc --argjson f "$out" '$f|length')" "2"

# --- Two commits, no base: HEAD~1..HEAD lists only the 2nd commit's change ---
R="$TMP/two"; mkrepo "$R"
printf '1\n' > "$R/keep.txt"; git -C "$R" add -A; git -C "$R" commit -qm c1
printf '2\n' > "$R/changed.txt"; git -C "$R" add -A; git -C "$R" commit -qm c2
out=$(files_modified_json "$R")
assert_eq "two commits -> single JSON" "$(is_one_json "$out")" "yes"
assert_eq "two commits list changed.txt" "$(printf '%s' "$out" | jq -r 'index("changed.txt") != null')" "true"
assert_eq "two commits exclude keep.txt (committed earlier)" "$(printf '%s' "$out" | jq -r 'index("keep.txt") == null')" "true"

# --- Valid base ref: diff base..HEAD ---
BASE=$(git -C "$R" rev-parse HEAD~1)
out=$(files_modified_json "$R" "$BASE")
assert_eq "base..HEAD lists changed.txt" "$(printf '%s' "$out" | jq -r 'index("changed.txt") != null')" "true"

# --- Invalid base: falls back gracefully to one valid array ---
out=$(files_modified_json "$R" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
assert_eq "invalid base -> single JSON" "$(is_one_json "$out")" "yes"

report_results
