#!/usr/bin/env bash
# bootstrap-relocate.sh — Atomic, staged file relocation from scratch to final.
#
# Exit codes:
#   20 — dry-run check failed (target would not be writable)
#   21 — write failed mid-run (should not happen after dry-run passes)
#   0  — success

# relocate_bundle <scratch-root> <project-root>
#   Moves files from scratch/{docs,context,agents,.claude} into project root
#   under ./docs/, ./docs/context/, ./.claude/agents/, ./.claude/.
#
# Atomicity: runs a dry-run feasibility pass first (checks every target dir is
# writable). Only if all pass does it perform the actual moves. If a real move
# fails after dry-run passed, exits 21 with loud error (should be rare — only
# under racy conditions like concurrent chmod).
relocate_bundle() {
  local scratch="$1"
  local project="$2"

  # Build the move list as "src|dst" pairs
  local -a moves=()

  # Docs
  if [ -d "$scratch/docs" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/docs/$base")
    done < <(find "$scratch/docs" -maxdepth 1 -type f -name '*.md')
  fi

  # Context
  if [ -d "$scratch/context" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/docs/context/$base")
    done < <(find "$scratch/context" -maxdepth 1 -type f -name '*.md')
  fi

  # Agents
  if [ -d "$scratch/agents" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/.claude/agents/$base")
    done < <(find "$scratch/agents" -maxdepth 1 -type f -name '*.md')
  fi

  # Design system
  for f in design-tokens.json design-system.md; do
    if [ -f "$scratch/.claude/$f" ]; then
      moves+=("$scratch/.claude/$f|$project/.claude/$f")
    fi
  done

  # --- Dry-run: ensure every target dir can be created and written ---
  local pair src dst dst_dir checked_str
  for pair in "${moves[@]}"; do
    dst="${pair#*|}"
    dst_dir=$(dirname "$dst")
    # Avoid associative arrays; use a string match instead
    if ! printf '%s\n' "$checked_str" | grep -qxF "$dst_dir"; then
      if ! mkdir -p "$dst_dir" 2>/dev/null; then
        echo "error: cannot create target directory: $dst_dir" >&2
        return 20
      fi
      if [ ! -w "$dst_dir" ]; then
        echo "error: target directory is not writable: $dst_dir" >&2
        return 20
      fi
      checked_str="$checked_str$dst_dir"$'\n'
    fi
  done

  # --- Real moves ---
  for pair in "${moves[@]}"; do
    src="${pair%|*}"
    dst="${pair#*|}"
    if ! mv "$src" "$dst" 2>/dev/null; then
      echo "error: failed to move $src -> $dst" >&2
      return 21
    fi
  done

  return 0
}

# append_gitignore <project-root>
#   Idempotently appends .bootstrap-scratch/ to .gitignore. Non-fatal on failure.
append_gitignore() {
  local project="$1"
  local gitignore="$project/.gitignore"
  local entry=".bootstrap-scratch/"

  if [ -f "$gitignore" ] && grep -qxF "$entry" "$gitignore"; then
    return 0
  fi
  if ! printf '\n%s\n' "$entry" >> "$gitignore" 2>/dev/null; then
    echo "warning: could not append $entry to .gitignore" >&2
    return 0
  fi
  return 0
}

# cleanup_scratch <scratch-root>
#   Removes the scratch dir. Non-fatal on failure.
cleanup_scratch() {
  local scratch="$1"
  if ! rm -rf "$scratch" 2>/dev/null; then
    echo "warning: could not remove $scratch" >&2
  fi
  return 0
}
