#!/usr/bin/env bash
# bootstrap-transform.sh — Scrub Hydra references from a scratch tree.
# Usage: bootstrap-transform.sh <scratch-root>
#
# Applies rules from scripts/lib/bootstrap-scrub-map.sh in order:
#   Class 1 — path rewrites (this task)
#   Class 4 — frontmatter stripping (Task 3)
#   Classes 2 & 3 — prose scrub safety net (Task 4)
#   Final assertion — no remaining Hydra tokens (Task 5)
#
# Transform mutates the scratch tree in place. Drops files listed in
# BOOTSTRAP_SCRUB_DROP_FILES.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/bootstrap-scrub-map.sh
source "$SCRIPT_DIR/lib/bootstrap-scrub-map.sh"

SCRATCH="${1:-}"
if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH" ]; then
  echo "usage: bootstrap-transform.sh <scratch-root>" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Class 1 — path rewrites
# -----------------------------------------------------------------------------

# Sort rules by find-length descending so longest matches first.
_sort_rules_longest_first() {
  local -a rules=("$@")
  for rule in "${rules[@]}"; do
    local find="${rule%%|*}"
    printf '%d\t%s\n' "${#find}" "$rule"
  done | sort -rn -k1,1 | cut -f2-
}

apply_path_rules() {
  local file="$1"
  _sort_rules_longest_first "${BOOTSTRAP_SCRUB_PATH_RULES[@]}" | while IFS= read -r rule; do
    local find="${rule%%|*}"
    local repl="${rule#*|}"
    if [ "$repl" = "__DROP__" ]; then
      # Delete whole line containing the token (Task 4 refines this to sentence-level).
      # For now, deleting the line is sufficient for path tokens that stand alone.
      sed -i.bak "/$(printf '%s' "$find" | sed 's/[\/&.]/\\&/g')/d" "$file"
    else
      # Literal replacement. Escape forward slashes for sed.
      local find_esc repl_esc
      find_esc=$(printf '%s' "$find" | sed 's/[\/&.]/\\&/g')
      repl_esc=$(printf '%s' "$repl" | sed 's/[\/&]/\\&/g')
      sed -i.bak "s/$find_esc/$repl_esc/g" "$file"
    fi
    rm -f "${file}.bak"
  done
}

# -----------------------------------------------------------------------------
# Main walk
# -----------------------------------------------------------------------------

# Drop files first
for basename in "${BOOTSTRAP_SCRUB_DROP_FILES[@]}"; do
  while IFS= read -r path; do
    rm -f "$path"
  done < <(find "$SCRATCH" -type f -name "$basename")
done

# Apply rules per file
while IFS= read -r file; do
  apply_path_rules "$file"
done < <(find "$SCRATCH" -type f \( -name '*.md' -o -name '*.json' \))

exit 0
