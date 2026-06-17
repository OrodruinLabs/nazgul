#!/usr/bin/env bash
set -euo pipefail

# Test: Every skill that references $ARGUMENTS in its body must surface the
# arguments in a dedicated `## Arguments` block — an `## Arguments` heading
# immediately followed (blank lines allowed) by a bare-line `$ARGUMENTS`. This
# is the convention used by the argument-taking skills (clean, patch, task,
# start, ...).
#
# Background: Claude Code substitutes `$ARGUMENTS` wherever it appears in a skill
# body, so an inline reference is not strictly "broken". But burying the
# placeholder inside numbered-step prose makes the model unreliable at acting on
# CLI flags (the `/nazgul:init --local` silent-drop bug). Requiring a dedicated
# `## Arguments` block — not merely a bare line buried somewhere — keeps the
# typed arguments surfaced consistently across every arg-taking skill.
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

  if [ "$total_refs" -eq 0 ]; then
    # Skill takes no arguments — nothing to enforce.
    continue
  fi

  # Does a dedicated block exist? An `## Arguments` heading whose first
  # non-blank following line is exactly `$ARGUMENTS`.
  has_block=$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]+Arguments[[:space:]]*$/ { inblock=1; next }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) next                       # skip blank lines
      if ($0 ~ /^[[:space:]]*\$ARGUMENTS[[:space:]]*$/) found=1
      inblock=0                                              # only the first non-blank line counts
    }
    END { print (found ? "yes" : "no") }
  ')

  if [ "$has_block" = "yes" ]; then
    _pass "$rel_path references \$ARGUMENTS under a dedicated ## Arguments block"
  else
    _fail "$rel_path references \$ARGUMENTS but has no dedicated ## Arguments block" \
      "Add this block (after ## Examples) so typed arguments are surfaced:" \
      "  ## Arguments" \
      "  \$ARGUMENTS" \
      "A bare \$ARGUMENTS buried elsewhere in the body does not satisfy the convention." \
      "See docs/superpowers/specs/2026-04-16-nazgul-init-local-flag-fix-design.md"
  fi
done

# Contract: every --flag a skill documents in its `argument-hint` frontmatter must
# be referenced in the skill BODY (or the body must invoke a helper that handles
# flags). Catches the "documented but never handled" class (e.g. /nazgul:start
# --yolo / --max that were silently ignored). See 2026-06-17-argument-handling spec.
for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
  [ -f "$skill_file" ] || continue
  rel_path="${skill_file#"$REPO_ROOT/"}"
  hint=$(awk -F'argument-hint:' '/^argument-hint:/{print $2; exit}' "$skill_file")
  [ -n "$hint" ] || continue
  body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$skill_file")
  for flag in $(printf '%s\n' "$hint" | grep -oE -- '--[a-z][a-z-]*' | sort -u); do
    if printf '%s\n' "$body" | grep -qF -- "$flag" \
       || printf '%s\n' "$body" | grep -q 'apply-start-flags.sh'; then
      _pass "$rel_path body handles documented flag $flag"
    else
      _fail "$rel_path documents $flag in argument-hint but its body never references it" \
        "Either handle the flag in the body (parse + act on it) or remove it from argument-hint."
    fi
  done
done

report_results
