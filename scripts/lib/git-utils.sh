#!/usr/bin/env bash
# Nazgul git-utils — small, robust git helpers shared by hooks.
# Sourced by stop-hook.sh and pre-compact.sh.

# NO SENTINEL: the scalar `_NAZGUL_GIT_UTILS_SOURCED` that sat here made one exported variable
# enough to leave the diff helpers undefined — the 127-exit hazard nazgul-root.sh:40-49 measured.

# files_modified_json <repo_dir> [<base_ref>]
# Print a JSON array of paths changed between a base and HEAD. Always prints
# exactly ONE valid JSON array — robust against a single-commit repo (no
# HEAD~1), a missing/invalid base, and a repo with no commits at all.
#
# Resolution order:
#   valid <base_ref> -> diff base..HEAD
#   else HEAD~1 exists -> diff HEAD~1..HEAD
#   else (first commit) -> diff <empty-tree>..HEAD  (lists that commit's files)
#   else (no commits) -> []
#
# WHY NOT `git ... | jq ... || echo "[]"`: under `set -o pipefail`, a non-zero
# upstream git (e.g. HEAD~1 missing in a fresh single-commit repo) trips the
# `||` even though jq already printed "[]", producing "[]\n[]" — two JSON
# values that make a downstream `jq --argjson` abort the hook. We capture git
# separately (`|| true`) so its exit status can't double-emit, then feed jq once.
files_modified_json() {
  local repo="$1" base="${2:-}" files=""
  if ! git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi
  if [ -n "$base" ] && git -C "$repo" rev-parse -q --verify "${base}^{commit}" >/dev/null 2>&1; then
    files=$(git -C "$repo" diff --name-only "$base" HEAD 2>/dev/null || true)
  elif git -C "$repo" rev-parse -q --verify "HEAD~1^{commit}" >/dev/null 2>&1; then
    files=$(git -C "$repo" diff --name-only HEAD~1 HEAD 2>/dev/null || true)
  else
    local empty
    empty=$(git -C "$repo" hash-object -t tree /dev/null 2>/dev/null || true)
    [ -n "$empty" ] && files=$(git -C "$repo" diff --name-only "$empty" HEAD 2>/dev/null || true)
  fi
  printf '%s' "$files" | jq -R -s 'split("\n") | map(select(length > 0))'
}
