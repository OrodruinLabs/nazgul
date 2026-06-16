#!/usr/bin/env bash
set -euo pipefail

# Test: Config migration script handles all scenarios correctly
TEST_NAME="test-migrate-config"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

MIGRATE="$REPO_ROOT/scripts/migrate-config.sh"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a fresh nazgul dir for each test
setup_nazgul_dir() {
  local test_name="$1"
  local dir="$TMPDIR_BASE/$test_name/nazgul"
  mkdir -p "$dir"
  echo "$dir"
}

# --- Test 1: No config file → exit 0, no output ---
NAZGUL_DIR=$(setup_nazgul_dir "no-config")
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_eq "no config → no output" "$OUTPUT" ""

# --- Test 2: v1 config → migrated to v2, models added ---
NAZGUL_DIR=$(setup_nazgul_dir "v1-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "mode": "hitl",
  "objective": null,
  "max_iterations": 40,
  "current_iteration": 0,
  "project": {
    "language": "typescript"
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null)
assert_contains "v1 → v2 output" "$OUTPUT" "migrated"
assert_json_field "v1 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
val=$(jq -r '.models | type' "$NAZGUL_DIR/config.json")
assert_eq "v1 → v2 models section added" "$val" "object"
assert_json_field "v1 → v2 models.default" "$NAZGUL_DIR/config.json" ".models.default" "sonnet"

# --- Test 3: v2 config → migrated to v3, branch section added ---
NAZGUL_DIR=$(setup_nazgul_dir "v2-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 2,
  "mode": "hitl",
  "models": {
    "default": "sonnet"
  },
  "afk": {
    "enabled": false,
    "yolo": false,
    "branch_per_task": true,
    "last_task_branch": null
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v2 → v3 output" "$OUTPUT" "migrated"
assert_json_field "v2 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
val=$(jq -r '.branch | type' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 branch section added" "$val" "object"
val=$(jq -r '.afk | has("branch_per_task")' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 afk.branch_per_task removed" "$val" "false"
val=$(jq -r '.afk | has("last_task_branch")' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 afk.last_task_branch removed" "$val" "false"

# --- Test 3b: v3 config → migrated to v4, webhooks + sparse_paths + fast_mode added ---
NAZGUL_DIR=$(setup_nazgul_dir "v3-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 3,
  "mode": "hitl",
  "branch": {
    "feature": null,
    "base": null
  },
  "models": {
    "default": "sonnet"
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v3 → v4 output" "$OUTPUT" "migrated"
assert_json_field "v3 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
val=$(jq -r '.webhooks | type' "$NAZGUL_DIR/config.json")
assert_eq "v3 → v4 webhooks section added" "$val" "object"
assert_json_field "v3 → v4 webhooks.enabled" "$NAZGUL_DIR/config.json" ".webhooks.enabled" "false"

# --- Test 3c: v4 config → migrated to v5, unused fields removed ---
NAZGUL_DIR=$(setup_nazgul_dir "v4-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 4,
  "install_mode": "shared",
  "mode": "hitl",
  "objective_set_at": "2025-01-01",
  "project_spec": "some spec",
  "branch": {
    "feature": null,
    "base": null,
    "sparse_paths": null
  },
  "models": {
    "default": "sonnet",
    "fast_mode_implementation": false
  },
  "documents": {
    "required": ["prd"],
    "generated": [],
    "approved": [],
    "existing": [],
    "dir": "nazgul/docs"
  },
  "context": {
    "budget_strategy": "aggressive",
    "compact_custom_instructions": "something"
  },
  "parallelism": {
    "enabled": true,
    "wave_execution": true,
    "require_settings": "enableAgentTeams"
  },
  "project": {
    "language": "typescript",
    "tools_verified": false,
    "tools_installed": ["npm"]
  },
  "discovery": {
    "last_run": null,
    "files_scanned": 100,
    "context_dir": "nazgul/context",
    "existing_docs_count": 3,
    "existing_docs_quality": "good"
  },
  "webhooks": {
    "enabled": false,
    "url": null,
    "events": ["stop", "compact", "task_complete"],
    "headers": {}
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v4 → v5 output" "$OUTPUT" "migrated"
assert_json_field "v4 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
# install_mode is stripped at 4→5 but RESTORED at 6→7 (default "shared")
assert_json_field "v4 → v7 install_mode restored to shared" "$NAZGUL_DIR/config.json" ".install_mode" "shared"
# Verify the other v4→v5-removed fields stay gone through the full chain
val=$(jq 'has("project_spec")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 project_spec removed" "$val" "false"
val=$(jq 'has("objective_set_at")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 objective_set_at removed" "$val" "false"
val=$(jq '.documents | has("required")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 documents.required removed" "$val" "false"
val=$(jq '.models | has("fast_mode_implementation")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 models.fast_mode_implementation removed" "$val" "false"
val=$(jq '.parallelism | has("wave_execution")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 parallelism.wave_execution removed" "$val" "false"
val=$(jq '.project | has("tools_verified")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 project.tools_verified removed" "$val" "false"
val=$(jq '.discovery | has("files_scanned")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 discovery.files_scanned removed" "$val" "false"
# Verify kept fields still present
assert_json_field "v4 → v5 documents.dir preserved" "$NAZGUL_DIR/config.json" ".documents.dir" "nazgul/docs"
assert_json_field "v4 → v5 discovery.context_dir preserved" "$NAZGUL_DIR/config.json" ".discovery.context_dir" "nazgul/context"
assert_json_field "v4 → v5 models.default preserved" "$NAZGUL_DIR/config.json" ".models.default" "sonnet"

# --- Test 3d: v5 config → migrated to v6, simplify section added ---
NAZGUL_DIR=$(setup_nazgul_dir "v5-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 5,
  "mode": "hitl",
  "branch": {
    "feature": null,
    "base": null,
    "sparse_paths": null
  },
  "models": {
    "default": "sonnet"
  },
  "webhooks": {
    "enabled": false,
    "url": null,
    "events": ["stop", "compact", "task_complete"],
    "headers": {}
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v5 → v6 output" "$OUTPUT" "migrated"
assert_json_field "v5 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
val=$(jq -r '.simplify | type' "$NAZGUL_DIR/config.json")
assert_eq "v5 → v6 simplify section added" "$val" "object"
assert_json_field "v5 → v6 simplify.post_loop" "$NAZGUL_DIR/config.json" ".simplify.post_loop" "true"
val=$(jq -r '.simplify.focus' "$NAZGUL_DIR/config.json")
assert_eq "v5 → v6 simplify.focus null" "$val" "null"
val=$(jq -r '.guards | type' "$NAZGUL_DIR/config.json")
assert_eq "v5 → v6 guards section added" "$val" "object"
assert_json_field "v5 → v6 guards.requireActiveTask" "$NAZGUL_DIR/config.json" ".guards.requireActiveTask" "true"

# --- Test 3d-b: v5 config with explicit simplify.per_task=false preserved ---
NAZGUL_DIR=$(setup_nazgul_dir "v5-config-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 5,
  "mode": "hitl",
  "simplify": {
    "post_loop": false,
    "focus": "performance"
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
# per_task removed — simplify always runs, no config opt-out
assert_json_field "v5 → v6 preserves post_loop=false" "$NAZGUL_DIR/config.json" ".simplify.post_loop" "false"
assert_json_field "v5 → v6 preserves focus value" "$NAZGUL_DIR/config.json" ".simplify.focus" "performance"

# --- Test 3e: v6 config → migrated to v7, install_mode restored (default shared) ---
NAZGUL_DIR=$(setup_nazgul_dir "v6-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 6,
  "mode": "hitl",
  "simplify": {
    "post_loop": true,
    "focus": null
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v6 → v7 output" "$OUTPUT" "migrated"
assert_json_field "v6 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
assert_json_field "v6 → v7 install_mode defaults to shared" "$NAZGUL_DIR/config.json" ".install_mode" "shared"

# --- Test 3e-b: v6 config with install_mode=local → preserved through v7 ---
NAZGUL_DIR=$(setup_nazgul_dir "v6-config-local")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 6,
  "install_mode": "local",
  "mode": "hitl"
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v6 config → v8 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "8"
assert_json_field "v6 → v7 install_mode=local preserved" "$NAZGUL_DIR/config.json" ".install_mode" "local"

# --- Test 3e-c: v6 config with invalid install_mode → clamped to shared ---
NAZGUL_DIR=$(setup_nazgul_dir "v6-config-bogus")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 6,
  "install_mode": "bogus",
  "mode": "hitl"
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v6 → v7 invalid install_mode clamped to shared" "$NAZGUL_DIR/config.json" ".install_mode" "shared"

# --- Test 3f: v7 config → migrated to v8, budget added (default disabled) ---
NAZGUL_DIR=$(setup_nazgul_dir "v7-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 7,
  "install_mode": "shared",
  "mode": "hitl"
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v7 → v8 output" "$OUTPUT" "migrated"
assert_json_field "v7 → v8 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "8"
assert_json_field "v7 → v8 budget.enabled defaults false" "$NAZGUL_DIR/config.json" ".budget.enabled" "false"

# --- Test 3g: existing budget preserved through v8 ---
NAZGUL_DIR=$(setup_nazgul_dir "v7-budget")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 7,
  "budget": { "enabled": true, "max_usd": 25, "spent_usd": 3, "per_iteration_usd": null, "model_iteration_cost": {} }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v7 → v8 existing budget.max_usd preserved" "$NAZGUL_DIR/config.json" ".budget.max_usd" "25"
assert_json_field "v7 → v8 existing budget.enabled preserved" "$NAZGUL_DIR/config.json" ".budget.enabled" "true"

# --- Test 3h: v8 config → no-op ---
NAZGUL_DIR=$(setup_nazgul_dir "v8-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 8, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_eq "v8 config → no output" "$OUTPUT" ""

# --- Test 4: Backup file created on migration ---
NAZGUL_DIR=$(setup_nazgul_dir "backup-check")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "mode": "autonomous"
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "backup created" "$NAZGUL_DIR/config.json.v1.bak"

# --- Test 5: Existing data preserved ---
NAZGUL_DIR=$(setup_nazgul_dir "preserve-data")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "mode": "autonomous",
  "max_iterations": 99,
  "project": {
    "language": "rust",
    "framework": "actix"
  }
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_json_field "preserves mode" "$NAZGUL_DIR/config.json" ".mode" "autonomous"
assert_json_field "preserves max_iterations" "$NAZGUL_DIR/config.json" ".max_iterations" "99"
assert_json_field "preserves project.language" "$NAZGUL_DIR/config.json" ".project.language" "rust"
assert_json_field "preserves project.framework" "$NAZGUL_DIR/config.json" ".project.framework" "actix"

# --- Test 6: Existing custom models section preserved ---
NAZGUL_DIR=$(setup_nazgul_dir "custom-models")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "mode": "hitl",
  "models": {
    "planning": "haiku",
    "default": "haiku"
  }
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_json_field "custom models preserved" "$NAZGUL_DIR/config.json" ".models.planning" "haiku"
assert_json_field "custom models.default preserved" "$NAZGUL_DIR/config.json" ".models.default" "haiku"

# --- Test 7: Migration log written ---
NAZGUL_DIR=$(setup_nazgul_dir "log-check")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "mode": "hitl"
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "migration log created" "$NAZGUL_DIR/logs/migrations.log"
assert_file_contains "log has migration entry" "$NAZGUL_DIR/logs/migrations.log" "Migrated 1 -> 2"

report_results
