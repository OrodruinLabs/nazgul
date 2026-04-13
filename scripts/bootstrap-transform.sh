#!/usr/bin/env bash
# bootstrap-transform.sh — Scrub Hydra references from a scratch tree.
# Usage: bootstrap-transform.sh <scratch-root>
#
# Applies rules from scripts/lib/bootstrap-scrub-map.sh. Actual execution order
# in the main walk is:
#   1. Drop files listed in BOOTSTRAP_SCRUB_DROP_FILES
#   2. For each remaining *.md / *.json file:
#      a. Class 4 — frontmatter stripping (agent files only)
#      b. Classes 2 & 3 — prose scrub safety net (body text, sentence/line drops)
#      c. Class 1 — path rewrites (with line-drop for __DROP__ tokens)
#   3. Final assertion — no residual [Hh]ydra|HYDRA tokens (exits 3 on match)
#
# Transform mutates the scratch tree in place.

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
# Classes 2 & 3 — prose term rewrites + sentence/line removal
# -----------------------------------------------------------------------------

# For each prose rule, if it matches in the file body, delete the containing
# sentence or list item. Skips YAML frontmatter.
apply_prose_rules() {
  local file="$1"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-transform.XXXXXX")

  # Build a single extended-regex OR of all prose patterns
  local patterns=()
  local rule
  for rule in "${BOOTSTRAP_SCRUB_PROSE_RULES[@]}"; do
    patterns+=("${rule%%|*}")
  done
  local joined
  joined=$(printf '%s|' "${patterns[@]}")
  joined="${joined%|}"

  awk -v pat="$joined" '
    BEGIN { in_fm=0 }
    NR==1 && /^---$/ { in_fm=1; print; next }
    in_fm && /^---$/ { in_fm=0; print; next }
    in_fm { print; next }
    {
      line = $0
      if (match(line, pat)) {
        # If a list item, drop the whole line
        if (line ~ /^[ \t]*([-*]|[0-9]+\.)[ \t]/) {
          next
        }
        # Tokenize by walking characters and splitting at . ? ! followed by space.
        out = ""
        buf = ""
        L = length(line)
        for (j = 1; j <= L; j++) {
          c = substr(line, j, 1)
          buf = buf c
          # End of sentence: terminator followed by space or EOL
          nextc = (j < L) ? substr(line, j+1, 1) : ""
          if ((c == "." || c == "?" || c == "!") && (nextc == " " || nextc == "\t" || nextc == "")) {
            if (buf !~ pat) {
              out = (out == "") ? buf : out buf
            }
            buf = ""
          }
        }
        if (buf != "" && buf !~ pat) {
          out = (out == "") ? buf : out buf
        }
        if (out ~ /^[ \t]*$/) next
        # Trim leading spaces carried over from dropped preceding sentence
        sub(/^[ \t]+/, "", out)
        print out
        next
      }
      print
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

# -----------------------------------------------------------------------------
# Class 4 — frontmatter stripping (agent files only)
# -----------------------------------------------------------------------------

# Is this file an agent (has YAML frontmatter starting at line 1)?
_is_agent_file() {
  local file="$1"
  head -1 "$file" 2>/dev/null | grep -qx -- '---'
}

# Parse, filter, and rewrite YAML frontmatter in place.
# Simple line-oriented parser: handles block keys (list values indented) by
# treating any line with no leading whitespace as a new top-level key.
strip_frontmatter() {
  local file="$1"
  _is_agent_file "$file" || return 0

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-transform.XXXXXX")

  # Join BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE into an alternation pattern.
  # Exact match: e.g. "hydra|review-board|loop-phase".
  local _fm_key
  local _fm_exact=""
  for _fm_key in "${BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE[@]}"; do
    if [ -z "$_fm_exact" ]; then
      _fm_exact="$_fm_key"
    else
      _fm_exact="$_fm_exact|$_fm_key"
    fi
  done

  # Join BOOTSTRAP_SCRUB_DESCRIPTION_PREFIXES into an alternation pattern for
  # leading-prefix removal in the description value.
  local _prefix
  local _desc_prefixes=""
  for _prefix in "${BOOTSTRAP_SCRUB_DESCRIPTION_PREFIXES[@]}"; do
    if [ -z "$_desc_prefixes" ]; then
      _desc_prefixes="$_prefix"
    else
      _desc_prefixes="$_desc_prefixes|$_prefix"
    fi
  done

  awk -v fm_exact="$_fm_exact" -v desc_prefixes="$_desc_prefixes" '
    BEGIN {
      in_fm=0; skipping_block=0; emitted_open=0
      # Exact-match pattern: anchor both ends so e.g. "hydra" does not match "hydrant".
      fm_pat = "^(" fm_exact ")$"
      # Prefix-strip pattern for description values. The scrub map owns the
      # list; we compose the regex here.
      prefix_pat = "^(" desc_prefixes ")[ \\t]*"
    }
    NR==1 && /^---$/ { in_fm=1; print; emitted_open=1; next }
    in_fm && /^---$/ { in_fm=0; skipping_block=0; print; next }
    in_fm {
      # Top-level key? (no leading whitespace, contains colon)
      if (match($0, /^[A-Za-z_][A-Za-z0-9_.-]*:/)) {
        key = substr($0, 1, RLENGTH-1)
        # Drop if the key matches the scrub-map exact list, OR starts with
        # "hydra_" (underscore-prefixed namespace is a known extension).
        if (key ~ fm_pat || key ~ /^hydra_/) {
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
          # Strip any one leading prefix listed in the scrub map.
          sub(prefix_pat, "", rest)
          # Always re-emit as a double-quoted YAML scalar so the value is
          # YAML-safe regardless of what chars survived (e.g. "#", ":", "{", "[").
          # Escape backslashes and double-quotes per YAML double-quoted rules.
          gsub(/\\/, "\\\\", rest)
          gsub(/"/, "\\\"", rest)
          print "description: \"" rest "\""
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
#
# IMPORTANT: the transform only operates on directories that will be relocated
# into the final bundle — docs/, context/, agents/, .claude/. The skill writes
# rendered pipeline prompts (e.g. .discovery-prompt.md) at the scratch root;
# those prompts preserve Hydra prose from the source agents (by design, since
# the LLM executes them in bundle-scratch mode) and must NOT be scrubbed or
# asserted against. The relocate step ignores them too.

# Scope the walk to the relocated subtree.
RELOCATED_DIRS=(
  "$SCRATCH/docs"
  "$SCRATCH/context"
  "$SCRATCH/agents"
  "$SCRATCH/.claude"
)

_existing_relocated_dirs() {
  local d
  for d in "${RELOCATED_DIRS[@]}"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# Drop files first (only within relocated subtree).
for basename in "${BOOTSTRAP_SCRUB_DROP_FILES[@]}"; do
  while IFS= read -r dir; do
    while IFS= read -r path; do
      rm -f "$path"
    done < <(find "$dir" -type f -name "$basename")
  done < <(_existing_relocated_dirs)
done

# Apply rules per file (only within relocated subtree).
while IFS= read -r dir; do
  while IFS= read -r file; do
    strip_frontmatter "$file"
    apply_prose_rules "$file"
    apply_path_rules "$file"
  done < <(find "$dir" -type f \( -name '*.md' -o -name '*.json' \))
done < <(_existing_relocated_dirs)

# -----------------------------------------------------------------------------
# Final assertion — no residual Hydra tokens (scoped to the relocated subtree)
# -----------------------------------------------------------------------------

# Build the target list dynamically so the assertion doesn't error on a
# missing directory (e.g. when .claude/ isn't populated this run).
ASSERT_TARGETS=()
while IFS= read -r dir; do
  ASSERT_TARGETS+=("$dir")
done < <(_existing_relocated_dirs)

if [ "${#ASSERT_TARGETS[@]}" -eq 0 ]; then
  ASSERT_MATCHES=""
else
  ASSERT_MATCHES=$(grep -rinE '[Hh]ydra|HYDRA' "${ASSERT_TARGETS[@]}" 2>/dev/null || true)
fi

if [ -n "$ASSERT_MATCHES" ]; then
  {
    echo "bootstrap-transform: residual Hydra tokens found after scrub pass:"
    echo ""
    echo "$ASSERT_MATCHES" | sed 's/^/  /'
    echo ""
    echo "Fix: add a rule to scripts/lib/bootstrap-scrub-map.sh covering the"
    echo "matched token, then re-run. Suggested shape:"
    echo ""
    echo "  BOOTSTRAP_SCRUB_PROSE_RULES+=(\"<your-token>|__DROP__\")"
    echo ""
    echo "After adding the rule, update the fixture so the regression test"
    echo "locks the new behavior: tests/fixtures/bootstrap-transform/."
  } >&2
  exit 3
fi

exit 0
