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
Read hydra/context/foo.md and write to hydra/docs/bar.md.
Config lives in hydra/config.json.
IN

render_agent_prompt "$WORK/in.md" ".bootstrap-scratch" > "$WORK/out.md"

assert_file_contains "path replaced: hydra/context/" "$WORK/out.md" ".bootstrap-scratch/context/foo.md"
assert_file_contains "path replaced: hydra/docs/"    "$WORK/out.md" ".bootstrap-scratch/docs/bar.md"
assert_file_contains "path replaced: hydra/config"   "$WORK/out.md" ".bootstrap-scratch/config.json"

# --- Bundle-mode conditional stripping ---
cat > "$WORK/tmpl.md" <<'TMPL'
Before.
{{^bundle_mode}}
This is the Hydra branch.
{{/bundle_mode}}
{{#bundle_mode}}
This is the bundle branch.
{{/bundle_mode}}
After.
TMPL

# Default (bundle_mode=false) — keep inverse, drop positive
render_template "$WORK/tmpl.md" > "$WORK/tmpl-default.md"
assert_file_contains "default keeps inverse" "$WORK/tmpl-default.md" "Hydra branch"
assert_file_not_contains "default drops positive" "$WORK/tmpl-default.md" "bundle branch"

# Bundle mode on — drop inverse, keep positive
BUNDLE_MODE=true render_template "$WORK/tmpl.md" > "$WORK/tmpl-bundle.md"
assert_file_not_contains "bundle drops inverse" "$WORK/tmpl-bundle.md" "Hydra branch"
assert_file_contains "bundle keeps positive" "$WORK/tmpl-bundle.md" "bundle branch"

report_results
