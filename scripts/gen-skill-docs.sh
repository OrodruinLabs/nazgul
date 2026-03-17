#!/usr/bin/env bash
set -euo pipefail

# gen-skill-docs.sh — resolves {{PARTIAL:name}} placeholders in SKILL.md.tmpl files
# Usage:
#   scripts/gen-skill-docs.sh              # Generate all SKILL.md from .tmpl
#   scripts/gen-skill-docs.sh --dry-run    # Show what would change without writing
#   scripts/gen-skill-docs.sh --check      # Exit 1 if any SKILL.md is stale

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTIALS_DIR="$ROOT_DIR/templates/skill-partials"
DRY_RUN=false
CHECK_MODE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check) CHECK_MODE=true ;;
  esac
done

STALE=0
PROCESSED=0

# Find all .tmpl files
while IFS= read -r tmpl_file; do
  [ -f "$tmpl_file" ] || continue
  PROCESSED=$((PROCESSED + 1))
  target="${tmpl_file%.tmpl}"
  result=$(cat "$tmpl_file")

  # Replace {{PARTIAL:name}} with contents of templates/skill-partials/name.md
  # Use a loop to handle nested or multiple replacements
  MAX_DEPTH=10
  depth=0
  while [[ "$result" == *'{{PARTIAL:'* ]] && [ "$depth" -lt "$MAX_DEPTH" ]; do
    depth=$((depth + 1))
    # Extract the first partial name
    partial_name=$(echo "$result" | grep -oE '\{\{PARTIAL:[a-zA-Z0-9_-]+\}\}' | head -1 | sed 's/{{PARTIAL://;s/}}//' || true)
    if [ -z "$partial_name" ]; then
      break
    fi
    partial_file="$PARTIALS_DIR/${partial_name}.md"
    if [ -f "$partial_file" ]; then
      partial_content=$(cat "$partial_file")
      # Use awk for safe replacement (handles special chars in content)
      result=$(awk -v placeholder="{{PARTIAL:${partial_name}}}" -v replacement="$partial_content" '{
        idx = index($0, placeholder)
        if (idx > 0) {
          print substr($0, 1, idx-1) replacement substr($0, idx + length(placeholder))
        } else {
          print
        }
      }' <<< "$result")
    else
      echo "WARNING: partial not found: $partial_file" >&2
      break
    fi
  done

  if $CHECK_MODE; then
    if [ -f "$target" ]; then
      if ! diff -q <(printf '%s\n' "$result") "$target" >/dev/null 2>&1; then
        echo "STALE: $target (regenerate with scripts/gen-skill-docs.sh)"
        STALE=$((STALE + 1))
      fi
    else
      echo "MISSING: $target"
      STALE=$((STALE + 1))
    fi
  elif $DRY_RUN; then
    echo "Would generate: $target from $tmpl_file (partials resolved)"
  else
    printf '%s\n' "$result" > "$target"
    echo "Generated: $target"
  fi
done < <(find "$ROOT_DIR/skills" -name "SKILL.md.tmpl" 2>/dev/null)

if $CHECK_MODE && [ "$STALE" -gt 0 ]; then
  echo ""
  echo "$STALE stale SKILL.md file(s) detected. Run: scripts/gen-skill-docs.sh"
  exit 1
fi

if $DRY_RUN || $CHECK_MODE; then
  echo "Partials available in $PARTIALS_DIR:"
  for f in "$PARTIALS_DIR"/*.md; do
    [ -f "$f" ] && echo "  - $(basename "$f" .md)"
  done
fi

if [ "$PROCESSED" -eq 0 ] && ! $CHECK_MODE; then
  echo "No .tmpl files found. Skills use direct SKILL.md editing."
  echo "To use templates, rename a SKILL.md to SKILL.md.tmpl and add {{PARTIAL:name}} placeholders."
fi
