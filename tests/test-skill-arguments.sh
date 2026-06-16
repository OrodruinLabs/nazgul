#!/usr/bin/env bash
set -euo pipefail

# Test: Every skill that references $ARGUMENTS in its body must also surface the
# arguments prominently via a bare-line `$ARGUMENTS` substitution block (the
# convention used by the argument-taking skills: clean, patch, task, start, ...).
#
# Background: Claude Code substitutes `$ARGUMENTS` wherever it appears in a skill
# body, so an inline reference is not strictly "broken". But burying the
# placeholder inside numbered-step prose makes the model unreliable at acting on
# CLI flags (the `/nazgul:init --local` silent-drop bug). Requiring the explicit
# block keeps the typed arguments visible at the top of every arg-taking skill.
# See docs/superpowers/specs/2026-04-16-nazgul-init-local-flag-fix-design.md
TEST_NAME="test-skill-arguments"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
  [ -f "$skill_file" ] || continue
  rel_path="${skill_file#"$REPO_ROOT/"}"

  # Body = everything after the closing frontmatter delimiter (second `---`).
  body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$skill_file")

  # Lines that reference $ARGUMENTS anywhere.
  total_refs=$(printf '%s\n' "$body" | grep -c '\$ARGUMENTS' || true)
  # Lines whose trimmed content is exactly `$ARGUMENTS` (the substitution block).
  sub_lines=$(printf '%s\n' "$body" | grep -c '^[[:space:]]*\$ARGUMENTS[[:space:]]*$' || true)

  if [ "$total_refs" -eq 0 ]; then
    # Skill takes no arguments — nothing to enforce.
    continue
  fi

  if [ "$sub_lines" -ge 1 ]; then
    _pass "$rel_path references \$ARGUMENTS and has a substitution block"
  else
    _fail "$rel_path references \$ARGUMENTS but has no bare-line substitution block" \
      "Add a block (after ## Examples) so typed arguments are surfaced:" \
      "  ## Arguments" \
      "  \$ARGUMENTS" \
      "See docs/superpowers/specs/2026-04-16-nazgul-init-local-flag-fix-design.md"
  fi
done

report_results
