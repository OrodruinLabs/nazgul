#!/usr/bin/env bash
set -euo pipefail

# Test: All agent and skill markdown files have valid YAML frontmatter
TEST_NAME="test-frontmatter"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

check_frontmatter() {
  local file="$1"
  local type="$2"  # "agent" or "skill"
  local rel_path="${file#"$REPO_ROOT/"}"

  # Check starts with ---
  local first_line
  first_line=$(head -1 "$file")
  if [ "$first_line" != "---" ]; then
    _fail "$rel_path starts with ---"
    return
  fi
  _pass "$rel_path starts with ---"

  # Extract frontmatter (between first and second ---)
  local frontmatter
  frontmatter=$(sed -n '2,/^---$/p' "$file" | sed '$d')

  # Check name field
  if echo "$frontmatter" | grep -q '^name:'; then
    _pass "$rel_path has name field"
  else
    _fail "$rel_path has name field"
  fi

  # Check description field
  if echo "$frontmatter" | grep -q '^description:'; then
    _pass "$rel_path has description field"
  else
    _fail "$rel_path has description field"
  fi

  # Agent-specific checks
  if [ "$type" = "agent" ]; then
    if echo "$frontmatter" | grep -q '^maxTurns:'; then
      _pass "$rel_path has maxTurns field"
    else
      _fail "$rel_path has maxTurns field"
    fi
  fi
}

# Check all agents
for agent_file in "$REPO_ROOT"/agents/*.md; do
  [ -f "$agent_file" ] || continue
  check_frontmatter "$agent_file" "agent"
done

# Check all agent templates
for template_file in "$REPO_ROOT"/agents/templates/*.md; do
  [ -f "$template_file" ] || continue
  check_frontmatter "$template_file" "agent"
done

# Check all skills
for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
  [ -f "$skill_file" ] || continue
  check_frontmatter "$skill_file" "skill"
done

report_results
