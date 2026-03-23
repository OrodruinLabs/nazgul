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

# Helper: create a fresh hydra dir for each test
setup_hydra_dir() {
  local test_name="$1"
  local dir="$TMPDIR_BASE/$test_name/hydra"
  mkdir -p "$dir"
  echo "$dir"
}

# --- Test 1: No config file → exit 0, no output ---
HYDRA_DIR=$(setup_hydra_dir "no-config")
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_eq "no config → no output" "$OUTPUT" ""

# --- Test 2: v1 config → migrated to v2, models added ---
HYDRA_DIR=$(setup_hydra_dir "v1-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
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
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null)
assert_contains "v1 → v2 output" "$OUTPUT" "migrated"
assert_json_field "v1 → v2 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "6"
val=$(jq -r '.models | type' "$HYDRA_DIR/config.json")
assert_eq "v1 → v2 models section added" "$val" "object"
assert_json_field "v1 → v2 models.default" "$HYDRA_DIR/config.json" ".models.default" "sonnet"

# --- Test 3: v2 config → migrated to v3, branch section added ---
HYDRA_DIR=$(setup_hydra_dir "v2-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
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
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_contains "v2 → v3 output" "$OUTPUT" "migrated"
assert_json_field "v2 → v3 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "6"
val=$(jq -r '.branch | type' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 branch section added" "$val" "object"
val=$(jq -r '.afk | has("branch_per_task")' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 afk.branch_per_task removed" "$val" "false"
val=$(jq -r '.afk | has("last_task_branch")' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 afk.last_task_branch removed" "$val" "false"

# --- Test 3b: v3 config → migrated to v4, webhooks + sparse_paths + fast_mode added ---
HYDRA_DIR=$(setup_hydra_dir "v3-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
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
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_contains "v3 → v4 output" "$OUTPUT" "migrated"
assert_json_field "v3 → v4 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "6"
val=$(jq -r '.webhooks | type' "$HYDRA_DIR/config.json")
assert_eq "v3 → v4 webhooks section added" "$val" "object"
assert_json_field "v3 → v4 webhooks.enabled" "$HYDRA_DIR/config.json" ".webhooks.enabled" "false"

# --- Test 3c: v4 config → migrated to v5, unused fields removed ---
HYDRA_DIR=$(setup_hydra_dir "v4-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
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
    "dir": "hydra/docs"
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
    "context_dir": "hydra/context",
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
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_contains "v4 → v5 output" "$OUTPUT" "migrated"
assert_json_field "v4 → v5 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "6"
# Verify removed fields are gone
val=$(jq 'has("install_mode")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 install_mode removed" "$val" "false"
val=$(jq 'has("project_spec")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 project_spec removed" "$val" "false"
val=$(jq 'has("objective_set_at")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 objective_set_at removed" "$val" "false"
val=$(jq '.documents | has("required")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 documents.required removed" "$val" "false"
val=$(jq '.models | has("fast_mode_implementation")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 models.fast_mode_implementation removed" "$val" "false"
val=$(jq '.parallelism | has("wave_execution")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 parallelism.wave_execution removed" "$val" "false"
val=$(jq '.project | has("tools_verified")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 project.tools_verified removed" "$val" "false"
val=$(jq '.discovery | has("files_scanned")' "$HYDRA_DIR/config.json")
assert_eq "v4 → v5 discovery.files_scanned removed" "$val" "false"
# Verify kept fields still present
assert_json_field "v4 → v5 documents.dir preserved" "$HYDRA_DIR/config.json" ".documents.dir" "hydra/docs"
assert_json_field "v4 → v5 discovery.context_dir preserved" "$HYDRA_DIR/config.json" ".discovery.context_dir" "hydra/context"
assert_json_field "v4 → v5 models.default preserved" "$HYDRA_DIR/config.json" ".models.default" "sonnet"

# --- Test 3d: v5 config → migrated to v6, simplify section added ---
HYDRA_DIR=$(setup_hydra_dir "v5-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
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
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_contains "v5 → v6 output" "$OUTPUT" "migrated"
assert_json_field "v5 → v6 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "6"
val=$(jq -r '.simplify | type' "$HYDRA_DIR/config.json")
assert_eq "v5 → v6 simplify section added" "$val" "object"
assert_json_field "v5 → v6 simplify.per_task" "$HYDRA_DIR/config.json" ".simplify.per_task" "true"
assert_json_field "v5 → v6 simplify.post_loop" "$HYDRA_DIR/config.json" ".simplify.post_loop" "true"
val=$(jq -r '.simplify.focus' "$HYDRA_DIR/config.json")
assert_eq "v5 → v6 simplify.focus null" "$val" "null"
val=$(jq -r '.guards | type' "$HYDRA_DIR/config.json")
assert_eq "v5 → v6 guards section added" "$val" "object"
assert_json_field "v5 → v6 guards.requireActiveTask" "$HYDRA_DIR/config.json" ".guards.requireActiveTask" "true"

# --- Test 3d-b: v5 config with explicit simplify.per_task=false preserved ---
HYDRA_DIR=$(setup_hydra_dir "v5-config-false")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "schema_version": 5,
  "mode": "hitl",
  "simplify": {
    "per_task": false,
    "post_loop": false,
    "focus": "performance"
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_json_field "v5 → v6 preserves per_task=false" "$HYDRA_DIR/config.json" ".simplify.per_task" "false"
assert_json_field "v5 → v6 preserves post_loop=false" "$HYDRA_DIR/config.json" ".simplify.post_loop" "false"
assert_json_field "v5 → v6 preserves focus value" "$HYDRA_DIR/config.json" ".simplify.focus" "performance"

# --- Test 3e: v6 config → no-op ---
HYDRA_DIR=$(setup_hydra_dir "v6-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "schema_version": 6,
  "mode": "hitl",
  "simplify": {
    "per_task": true,
    "post_loop": true,
    "focus": null
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_eq "v6 config → no output" "$OUTPUT" ""

# --- Test 4: Backup file created on migration ---
HYDRA_DIR=$(setup_hydra_dir "backup-check")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "mode": "autonomous"
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" >/dev/null 2>/dev/null
assert_file_exists "backup created" "$HYDRA_DIR/config.json.v1.bak"

# --- Test 5: Existing data preserved ---
HYDRA_DIR=$(setup_hydra_dir "preserve-data")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "mode": "autonomous",
  "max_iterations": 99,
  "project": {
    "language": "rust",
    "framework": "actix"
  }
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" >/dev/null 2>/dev/null
assert_json_field "preserves mode" "$HYDRA_DIR/config.json" ".mode" "autonomous"
assert_json_field "preserves max_iterations" "$HYDRA_DIR/config.json" ".max_iterations" "99"
assert_json_field "preserves project.language" "$HYDRA_DIR/config.json" ".project.language" "rust"
assert_json_field "preserves project.framework" "$HYDRA_DIR/config.json" ".project.framework" "actix"

# --- Test 6: Existing custom models section preserved ---
HYDRA_DIR=$(setup_hydra_dir "custom-models")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "mode": "hitl",
  "models": {
    "planning": "haiku",
    "default": "haiku"
  }
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" >/dev/null 2>/dev/null
assert_json_field "custom models preserved" "$HYDRA_DIR/config.json" ".models.planning" "haiku"
assert_json_field "custom models.default preserved" "$HYDRA_DIR/config.json" ".models.default" "haiku"

# --- Test 7: Migration log written ---
HYDRA_DIR=$(setup_hydra_dir "log-check")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "mode": "hitl"
}
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" >/dev/null 2>/dev/null
assert_file_exists "migration log created" "$HYDRA_DIR/logs/migrations.log"
assert_file_contains "log has migration entry" "$HYDRA_DIR/logs/migrations.log" "Migrated 1 -> 2"

report_results
