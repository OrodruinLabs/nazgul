#!/usr/bin/env bash
set -euo pipefail

# Test: Model routing config defaults and config skill wiring
TEST_NAME="test-model-routing"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

CONFIG="$REPO_ROOT/templates/config.json"

# ── Test: config template has balanced defaults ──────────
assert_json_field "planning defaults to opus"         "$CONFIG" ".models.planning"        "opus"
assert_json_field "discovery defaults to sonnet"      "$CONFIG" ".models.discovery"       "sonnet"
assert_json_field "docs defaults to sonnet"           "$CONFIG" ".models.docs"            "sonnet"
assert_json_field "review defaults to sonnet"         "$CONFIG" ".models.review"          "sonnet"
assert_json_field "implementation defaults to sonnet" "$CONFIG" ".models.implementation"  "sonnet"
assert_json_field "specialists defaults to sonnet"    "$CONFIG" ".models.specialists"     "sonnet"
assert_json_field "post_loop defaults to haiku"       "$CONFIG" ".models.post_loop"       "haiku"
assert_json_field "default is sonnet"                 "$CONFIG" ".models.default"         "sonnet"

# ── Test: all model values are valid ──────────────────────
valid_models=("opus" "sonnet" "haiku" "inherit")
for key in planning discovery docs review implementation specialists post_loop default; do
  value=$(jq -r ".models.$key" "$CONFIG")
  found=false
  for valid in "${valid_models[@]}"; do
    if [[ "$value" == "$valid" ]]; then
      found=true
      break
    fi
  done
  if $found; then
    _pass "models.$key value '$value' is valid"
  else
    _fail "models.$key value '$value' is valid" "got: '$value', expected one of: ${valid_models[*]}"
  fi
done

# ── Test: config template models section has all required keys ──
for key in planning discovery docs review implementation specialists post_loop default; do
  value=$(jq -r ".models.$key" "$CONFIG")
  if [ "$value" != "null" ]; then
    _pass "models.$key exists in config template"
  else
    _fail "models.$key exists in config template" "models.$key is null/missing"
  fi
done

# ── Test: config skill exists with correct frontmatter ────
assert_file_exists "config skill exists" "$REPO_ROOT/skills/config/SKILL.md"

skill_name=$(head -10 "$REPO_ROOT/skills/config/SKILL.md" | grep "^name:" | sed 's/name: *//; s/"//g')
assert_eq "config skill name is nazgul:config" "$skill_name" "nazgul:config"

tools_line=$(head -10 "$REPO_ROOT/skills/config/SKILL.md" | grep "allowed-tools:")
assert_contains "config skill has ToolSearch in allowed-tools" "$tools_line" "ToolSearch"

# ── Test: discovery agent references models.review config key ──
discovery_content=$(cat "$REPO_ROOT/agents/discovery.md")
assert_contains "discovery references models.review" "$discovery_content" "models.review"

# ── Test: help skill lists config command ─────────────────
help_content=$(cat "$REPO_ROOT/skills/help/SKILL.md")
assert_contains "help lists /nazgul:config" "$help_content" "nazgul:config"

report_results
