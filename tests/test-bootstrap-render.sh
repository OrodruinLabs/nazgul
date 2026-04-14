#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-render"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-render.sh
source "$REPO_ROOT/scripts/lib/bootstrap-render.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-render-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- Path substitution ---
cat > "$WORK/in.md" <<'IN'
Read nazgul/context/foo.md and write to nazgul/docs/bar.md.
Config lives in nazgul/config.json.
IN

render_agent_prompt "$WORK/in.md" ".bootstrap-scratch" > "$WORK/out.md"

assert_file_contains "path replaced: nazgul/context/" "$WORK/out.md" ".bootstrap-scratch/context/foo.md"
assert_file_contains "path replaced: nazgul/docs/"    "$WORK/out.md" ".bootstrap-scratch/docs/bar.md"
assert_file_contains "path replaced: nazgul/config"   "$WORK/out.md" ".bootstrap-scratch/config.json"

# --- Bundle-mode conditional stripping ---
cat > "$WORK/tmpl.md" <<'TMPL'
Before.
{{^bundle_mode}}
This is the Nazgul branch.
{{/bundle_mode}}
{{#bundle_mode}}
This is the bundle branch.
{{/bundle_mode}}
After.
TMPL

# Default (bundle_mode=false) — keep inverse, drop positive
render_template "$WORK/tmpl.md" > "$WORK/tmpl-default.md"
assert_file_contains "default keeps inverse" "$WORK/tmpl-default.md" "Nazgul branch"
assert_file_not_contains "default drops positive" "$WORK/tmpl-default.md" "bundle branch"

# Bundle mode on — drop inverse, keep positive
BUNDLE_MODE=true render_template "$WORK/tmpl.md" > "$WORK/tmpl-bundle.md"
assert_file_not_contains "bundle drops inverse" "$WORK/tmpl-bundle.md" "Nazgul branch"
assert_file_contains "bundle keeps positive" "$WORK/tmpl-bundle.md" "bundle branch"

# --- select_reviewer_domains ---
cat > "$WORK/profile.md" <<'PROF'
Stack: Next.js (React), TypeScript, Tailwind, PostgreSQL. Uses JWT auth.
PROF
cat > "$WORK/domains.json" <<'DOM'
{
  "code-reviewer": {"title": "Code", "description": "d", "checklist": [], "review_steps": []},
  "qa-reviewer": {"title": "QA", "description": "d", "checklist": [], "review_steps": []},
  "frontend-reviewer": {"title": "Frontend", "description": "d", "checklist": [], "review_steps": []},
  "security-reviewer": {"title": "Security", "description": "d", "checklist": [], "review_steps": []}
}
DOM

SELECTED=$(select_reviewer_domains "$WORK/profile.md" "$WORK/domains.json" 2>/dev/null)
assert_contains "baseline: code-reviewer"    "$SELECTED" "code-reviewer"
assert_contains "baseline: qa-reviewer"      "$SELECTED" "qa-reviewer"
assert_contains "frontend detected (nextjs)" "$SELECTED" "frontend-reviewer"
assert_contains "security detected (jwt)"    "$SELECTED" "security-reviewer"
assert_not_contains "no api-reviewer"        "$SELECTED" "api-reviewer"

# --- substitute_domain_vars ---
cat > "$WORK/tpl.md" <<'TPL'
name: {{reviewer_name}}
title: {{title}} Reviewer
description: {{description}}
## Checklist
{{checklist}}
## Steps
1. a
2. b
{{review_steps}}
TPL

OUT=$(substitute_domain_vars "code-reviewer" "$WORK/domains.json" < "$WORK/tpl.md")
assert_contains "name substituted" "$OUT" "name: code-reviewer"
assert_contains "title substituted" "$OUT" "title: Code Reviewer"
assert_not_contains "no placeholder leak" "$OUT" "{{"

report_results
