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
assert_json_field "v1 → v2 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "3"
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
assert_json_field "v2 → v3 schema_version" "$HYDRA_DIR/config.json" ".schema_version" "3"
val=$(jq -r '.branch | type' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 branch section added" "$val" "object"
val=$(jq -r '.afk | has("branch_per_task")' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 afk.branch_per_task removed" "$val" "false"
val=$(jq -r '.afk | has("last_task_branch")' "$HYDRA_DIR/config.json")
assert_eq "v2 → v3 afk.last_task_branch removed" "$val" "false"

# --- Test 3b: v3 config → no-op ---
HYDRA_DIR=$(setup_hydra_dir "v3-config")
cat > "$HYDRA_DIR/config.json" << 'EOF'
{
  "schema_version": 3,
  "mode": "hitl",
  "branch": {
    "feature": null,
    "base": null
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$HYDRA_DIR" 2>/dev/null) || true
assert_eq "v3 config → no output" "$OUTPUT" ""

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
