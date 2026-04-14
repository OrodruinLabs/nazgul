#!/usr/bin/env bash
# bootstrap-relocate.sh — Preflight-checked file relocation from scratch to
# final target paths.
#
# Exit codes:
#   20 — dry-run feasibility check failed (target unreachable/unwritable)
#   21 — write failed mid-run; bundle may be partially relocated
#   0  — success
#
# Not transactionally atomic. The dry-run pass catches the common failure modes
# (missing/unwritable ancestors, target-as-file collisions) before any
# filesystem mutation, so most failures surface with the project untouched. It
# does NOT cover disk-full, race conditions (concurrent chmod between dry-run
# and real-move), or hardware errors mid-stream — those exit 21 with a loud
# stderr message and may leave the project in a partial state. True
# transactional atomicity would require staging into an adjacent dir and
# doing a single rename, which this implementation intentionally avoids for
# simplicity.

# relocate_bundle <scratch-root> <project-root>
#   Moves files from scratch/{docs,context,agents,.claude} into project root
#   under ./docs/, ./docs/context/, ./.claude/agents/, ./.claude/.
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

  # --- Dry-run: verify every target dir is reachable WITHOUT creating anything ---
  # For each dst_dir, walk up to the nearest existing ancestor and check it's
  # a writable directory. Bailing here prevents the common failure modes from
  # writing anything. Does NOT provide a true all-or-nothing guarantee: a later
  # failure in the real-moves pass (disk full, races) can still leave the
  # project partially relocated — see the file header for the exact contract.
  local pair src dst dst_dir
  local checked_str=""
  for pair in "${moves[@]}"; do
    dst="${pair#*|}"
    dst_dir=$(dirname "$dst")
    if ! printf '%s\n' "$checked_str" | grep -qxF "$dst_dir"; then
      # Walk up to find the nearest existing ancestor
      local ancestor="$dst_dir"
      while [ ! -e "$ancestor" ]; do
        local parent
        parent=$(dirname "$ancestor")
        if [ "$parent" = "$ancestor" ]; then
          break
        fi
        ancestor="$parent"
      done
      if [ ! -d "$ancestor" ]; then
        echo "error: target path unreachable (ancestor not a directory): $dst_dir ($ancestor)" >&2
        return 20
      fi
      # mkdir -p needs BOTH write (create child) AND execute/search (traverse
      # into existing path). Without -x, a later mkdir inside the real-moves
      # pass could fail after earlier moves succeeded, breaking atomicity.
      if [ ! -w "$ancestor" ] || [ ! -x "$ancestor" ]; then
        echo "error: target path ancestor not writable or not searchable: $ancestor" >&2
        return 20
      fi
      checked_str="$checked_str$dst_dir"$'\n'
    fi
  done

  # --- Real moves: NOW create dirs and mv files ---
  local created_str=""
  for pair in "${moves[@]}"; do
    src="${pair%|*}"
    dst="${pair#*|}"
    dst_dir=$(dirname "$dst")
    if ! printf '%s\n' "$created_str" | grep -qxF "$dst_dir"; then
      if ! mkdir -p "$dst_dir" 2>/dev/null; then
        echo "error: failed to create target directory: $dst_dir" >&2
        return 21
      fi
      created_str="$created_str$dst_dir"$'\n'
    fi
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
