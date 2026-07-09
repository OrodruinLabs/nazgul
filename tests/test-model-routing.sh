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
assert_json_field "review defaults to haiku"          "$CONFIG" ".models.review"          "haiku"
assert_json_field "implementation defaults to sonnet" "$CONFIG" ".models.implementation"  "sonnet"
assert_json_field "specialists defaults to sonnet"    "$CONFIG" ".models.specialists"     "sonnet"
assert_json_field "post_loop defaults to sonnet"      "$CONFIG" ".models.post_loop"       "sonnet"
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

# ── Test: conductor dispatch passes models.conductor explicitly (ADR-002 Option 2) ──
start_content=$(cat "$REPO_ROOT/skills/start/SKILL.md")
assert_contains "start dispatches nazgul:conductor with explicit model" "$start_content" \
  'subagent_type: "nazgul:conductor"`, `model: "$(jq -r '\''.models.conductor // "sonnet"'\'' nazgul/config.json)"`'
assert_contains "start Model Selection table lists a Conductor row" "$start_content" "| Conductor"
assert_contains "start Model Selection table Conductor row keys off models.conductor" "$start_content" "models.conductor"
assert_contains "start Model Selection table Review Gate row keys off models.review_orchestrator" "$start_content" "models.review_orchestrator"

# ── Test: agents/conductor.md resolves MODEL_REVIEW via the orchestrator fallback chain ──
conductor_content=$(cat "$REPO_ROOT/agents/conductor.md")
assert_contains "conductor MODEL_REVIEW reads review_orchestrator with legacy fallback" "$conductor_content" \
  'MODEL_REVIEW=$(jq -r '"'"'.models.review_orchestrator // .models.review // "sonnet"'"'"' "$CONFIG")'

# ── Test: agents/review-gate.md resolves reviewer-default + feedback-aggregator via the reviewer-default fallback chain ──
review_gate_content=$(cat "$REPO_ROOT/agents/review-gate.md")
assert_contains "review-gate reviewer-default fallback reads review_default with legacy fallback" "$review_gate_content" \
  'models.review_default // models.review // "haiku"'
assert_contains "review-gate reviewer-default fallback still pins security/architect to sonnet" "$review_gate_content" \
  "ALWAYS resolve to \`sonnet\`"
assert_contains "review-gate feedback-aggregator model uses the same fallback chain" "$review_gate_content" \
  'feedback-aggregator to consolidate feedback (use `models.review_default // models.review // "haiku"`'

# ── Test: three-way fallback resolution (legacy-only / new-only / neither) ──
resolve_review_orchestrator() {
  jq -r '.models.review_orchestrator // .models.review // "sonnet"' <<<"$1"
}
resolve_review_default() {
  jq -r '.models.review_default // .models.review // "haiku"' <<<"$1"
}

legacy_only='{"models":{"review":"opus"}}'
new_only='{"models":{"review_orchestrator":"opus","review_default":"opus"}}'
neither='{"models":{}}'

assert_eq "orchestrator fallback: legacy-only models.review wins" \
  "$(resolve_review_orchestrator "$legacy_only")" "opus"
assert_eq "reviewer-default fallback: legacy-only models.review wins" \
  "$(resolve_review_default "$legacy_only")" "opus"

assert_eq "orchestrator fallback: new-only models.review_orchestrator wins" \
  "$(resolve_review_orchestrator "$new_only")" "opus"
assert_eq "reviewer-default fallback: new-only models.review_default wins" \
  "$(resolve_review_default "$new_only")" "opus"

assert_eq "orchestrator fallback: neither key set defaults to sonnet" \
  "$(resolve_review_orchestrator "$neither")" "sonnet"
assert_eq "reviewer-default fallback: neither key set defaults to haiku" \
  "$(resolve_review_default "$neither")" "haiku"

report_results
