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
# Class 4 — frontmatter stripping (agent files only)
# -----------------------------------------------------------------------------

# Is this file an agent (has YAML frontmatter starting at line 1)?
_is_agent_file() {
  local file="$1"
  head -1 "$file" 2>/dev/null | grep -qx -- '---'
}

# Given a frontmatter key, should it be removed?
_frontmatter_key_is_dropped() {
  local key="$1"
  for drop in "${BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE[@]}"; do
    # Remove exact match (hydra, review-board, loop-phase)
    [ "$key" = "$drop" ] && return 0
  done
  # Also remove any key starting with "hydra_" (underscore form)
  case "$key" in
    hydra_*) return 0 ;;
  esac
  return 1
}

# Strip a leading description prefix like "Pipeline:" and unwrap quotes.
_normalize_description() {
  local value="$1"
  # Strip surrounding quotes (single or double)
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  # Strip leading prefix tokens
  for prefix in "${BOOTSTRAP_SCRUB_DESCRIPTION_PREFIXES[@]}"; do
    # prefix followed by optional space, then the rest
    value="${value#"$prefix "}"
    value="${value#"$prefix"}"
  done
  printf '%s' "$value"
}

# Parse, filter, and rewrite YAML frontmatter in place.
# Simple line-oriented parser: handles block keys (list values indented) by
# treating any line with no leading whitespace as a new top-level key.
strip_frontmatter() {
  local file="$1"
  _is_agent_file "$file" || return 0

  local tmp
  tmp=$(mktemp)

  awk '
    BEGIN { in_fm=0; skipping_block=0; emitted_open=0 }
    NR==1 && /^---$/ { in_fm=1; print; emitted_open=1; next }
    in_fm && /^---$/ { in_fm=0; skipping_block=0; print; next }
    in_fm {
      # Top-level key? (no leading whitespace, contains colon)
      if (match($0, /^[A-Za-z_][A-Za-z0-9_.-]*:/)) {
        key = substr($0, 1, RLENGTH-1)
        # Check if this key should be dropped
        if (key ~ /^hydra_/ || key == "hydra" || key == "review-board" || key == "loop-phase") {
          skipping_block=1
          next
        }
        skipping_block=0

        if (key == "description") {
          # Rewrite inline value, then print
          rest = substr($0, RLENGTH+1)
          sub(/^[ \t]*/, "", rest)
          # Strip surrounding quotes
          if ((rest ~ /^".*"$/) || (rest ~ /^'"'"'.*'"'"'$/)) {
            rest = substr(rest, 2, length(rest)-2)
          }
          # Strip known prefixes
          sub(/^Pipeline:[ \t]*/, "", rest)
          sub(/^Post-loop:[ \t]*/, "", rest)
          sub(/^Specialist:[ \t]*/, "", rest)
          print "description: " rest
          next
        }
        print
        next
      }
      # Continuation of previous key (indented). Print only if not skipping.
      if (skipping_block == 0) { print }
      next
    }
    # Outside frontmatter — pass through
    { print }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
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
  strip_frontmatter "$file"
  apply_path_rules "$file"
done < <(find "$SCRATCH" -type f \( -name '*.md' -o -name '*.json' \))

exit 0
