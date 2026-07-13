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
assert_json_field "v1 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
assert_json_field "v2 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
val=$(jq -r '.branch | type' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 branch section added" "$val" "object"
val=$(jq -r '.afk | has("branch_per_task")' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 afk.branch_per_task removed" "$val" "false"
val=$(jq -r '.afk | has("last_task_branch")' "$NAZGUL_DIR/config.json")
assert_eq "v2 → v3 afk.last_task_branch removed" "$val" "false"

# --- Test 3a2: v2 with a REAL afk.last_task_branch and NO branch section ---
# Exercises the backfill path: migrate_2_to_3 copies afk.last_task_branch into the
# new branch section (and still removes it from afk). Distinct from Test 3, whose
# afk.last_task_branch is null.
NAZGUL_DIR=$(setup_nazgul_dir "v2-afk-branch-backfill")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{
  "schema_version": 2,
  "mode": "afk",
  "afk": {
    "enabled": true,
    "branch_per_task": true,
    "last_task_branch": "task/TASK-009"
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v2 backfill → branch.last_task_branch copied from afk" "$NAZGUL_DIR/config.json" ".branch.last_task_branch" "task/TASK-009"
val=$(jq -r '.afk | has("last_task_branch")' "$NAZGUL_DIR/config.json")
assert_eq "v2 backfill → afk.last_task_branch still removed" "$val" "false"

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
assert_json_field "v3 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
assert_json_field "v4 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
val=$(jq '.parallelism.wave_execution' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 parallelism.wave_execution removed then re-added by v17" "$val" "true"
val=$(jq '.project | has("tools_verified")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 project.tools_verified removed" "$val" "false"
# Discovery-owned fields are NOW PRESERVED (regression: they were deleted as "unused").
assert_json_field "v4 → v5 discovery.files_scanned PRESERVED" "$NAZGUL_DIR/config.json" ".discovery.files_scanned" "100"
assert_json_field "v4 → v5 discovery.existing_docs_count PRESERVED" "$NAZGUL_DIR/config.json" ".discovery.existing_docs_count" "3"
assert_json_field "v4 → v5 discovery.existing_docs_quality PRESERVED" "$NAZGUL_DIR/config.json" ".discovery.existing_docs_quality" "good"
val=$(jq '.documents | has("existing")' "$NAZGUL_DIR/config.json")
assert_eq "v4 → v5 documents.existing PRESERVED" "$val" "true"
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
assert_json_field "v5 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
assert_json_field "v6 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
assert_json_field "v6 config → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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
assert_json_field "v7 → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
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

# --- Test 3h: v8 config → migrated to v9, project.smoke_command added ---
NAZGUL_DIR=$(setup_nazgul_dir "v8-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 8, "mode": "hitl", "project": { "test_command": "npm test" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v8 → v9 output" "$OUTPUT" "migrated"
assert_json_field "v8 → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v8 → v9 smoke_command added (null)" "$NAZGUL_DIR/config.json" ".project.smoke_command" "null"
assert_json_field "v8 → v9 preserves existing project field" "$NAZGUL_DIR/config.json" ".project.test_command" "npm test"

# --- Test 3i: existing smoke_command preserved through v9 ---
NAZGUL_DIR=$(setup_nazgul_dir "v8-smoke")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 8, "project": { "smoke_command": "node dist/index.js --version" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v8 → v9 existing smoke_command preserved" "$NAZGUL_DIR/config.json" ".project.smoke_command" "node dist/index.js --version"

# --- Test 3i-b: non-object project (hand-edited) → clamped to object at v9 ---
NAZGUL_DIR=$(setup_nazgul_dir "v8-project-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 8, "project": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v8 → v9 non-object project clamped to object" "$NAZGUL_DIR/config.json" ".project | type" "object"
assert_json_field "v8 → v9 clamped project.smoke_command null" "$NAZGUL_DIR/config.json" ".project.smoke_command" "null"

# --- Test 3j: v12 config → migrated to v13, guards.lean_comments added ---
NAZGUL_DIR=$(setup_nazgul_dir "v12-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 12, "mode": "hitl", "guards": { "requireActiveTask": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v12 → v13 output" "$OUTPUT" "migrated"
assert_json_field "v12 → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v12 → v13 lean_comments defaults true" "$NAZGUL_DIR/config.json" ".guards.lean_comments" "true"
assert_json_field "v12 → v13 max_consecutive_comment_lines defaults 2" "$NAZGUL_DIR/config.json" ".guards.max_consecutive_comment_lines" "2"
assert_json_field "v12 → v13 preserves existing guards field" "$NAZGUL_DIR/config.json" ".guards.requireActiveTask" "true"

# --- Test 3j-b: existing lean_comments opt-out + threshold survive v12 → v13 ---
NAZGUL_DIR=$(setup_nazgul_dir "v12-lean-optout")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 12, "guards": { "lean_comments": false, "max_consecutive_comment_lines": 5 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v12 → v13 existing lean_comments=false preserved" "$NAZGUL_DIR/config.json" ".guards.lean_comments" "false"
assert_json_field "v12 → v13 existing threshold preserved" "$NAZGUL_DIR/config.json" ".guards.max_consecutive_comment_lines" "5"

# --- Test 3j-c: non-object guards (hand-edited) → clamped to object at v13 ---
NAZGUL_DIR=$(setup_nazgul_dir "v12-guards-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 12, "guards": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v12 → v13 non-object guards clamped to object" "$NAZGUL_DIR/config.json" ".guards | type" "object"
assert_json_field "v12 → v13 clamped guards gets lean_comments=true" "$NAZGUL_DIR/config.json" ".guards.lean_comments" "true"

# --- Test 3k: v13 config → full-chain migrate to terminal v16; asserts the v13→v14 telemetry fields ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-config")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 13, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v13 → v14 output" "$OUTPUT" "migrated"
assert_json_field "v13 → v24 (full chain) schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v13 → v14 telemetry.bus_enabled defaults true" "$NAZGUL_DIR/config.json" ".telemetry.bus_enabled" "true"
assert_json_field "v13 → v14 telemetry.record_metered_cost defaults false" "$NAZGUL_DIR/config.json" ".telemetry.record_metered_cost" "false"
assert_json_field "v13 → v14 no legacy_write field added" "$NAZGUL_DIR/config.json" '.telemetry | has("legacy_write")' "false"

# --- migrate_13_to_14: preserves pre-existing fields (additive only) ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-to-14-preserve")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 13, "mode": "hitl", "guards": { "requireActiveTask": true }, "review_gate": { "granularity": "task" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v13 → v14 preserves guards.requireActiveTask" "$NAZGUL_DIR/config.json" ".guards.requireActiveTask" "true"
assert_json_field "v13 → v17 full chain flips granularity task→group" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"
assert_json_field "v13 → v14 preserves mode" "$NAZGUL_DIR/config.json" ".mode" "hitl"

# --- migrate_13_to_14: hand-set bus_enabled=false survives (idempotent opt-out) ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-to-14-optout")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 13, "telemetry": { "bus_enabled": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v13 → v14 preserves bus_enabled=false (opt-out)" "$NAZGUL_DIR/config.json" ".telemetry.bus_enabled" "false"
assert_json_field "v13 → v14 backfills record_metered_cost=false when absent" "$NAZGUL_DIR/config.json" ".telemetry.record_metered_cost" "false"

# --- migrate_13_to_14: hand-set record_metered_cost=true survives ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-to-14-metered")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 13, "telemetry": { "record_metered_cost": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v13 → v14 preserves record_metered_cost=true" "$NAZGUL_DIR/config.json" ".telemetry.record_metered_cost" "true"
assert_json_field "v13 → v14 backfills bus_enabled=true when absent" "$NAZGUL_DIR/config.json" ".telemetry.bus_enabled" "true"

# --- migrate_13_to_14 fields preserved across the v14 → v15 step ---
NAZGUL_DIR=$(setup_nazgul_dir "v14-to-15")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 14, "telemetry": { "bus_enabled": true, "record_metered_cost": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v14 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v14 → v15 telemetry.bus_enabled preserved" "$NAZGUL_DIR/config.json" ".telemetry.bus_enabled" "true"
assert_json_field "v14 → v15 adds review_gate.simplify_before_review=false" "$NAZGUL_DIR/config.json" ".review_gate.simplify_before_review" "false"

# --- migrate_13_to_14: non-object .telemetry clamped to {} before fields set ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-to-14-garbage")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 13, "telemetry": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v13 → v14 non-object telemetry clamped to object" "$NAZGUL_DIR/config.json" ".telemetry | type" "object"
assert_json_field "v13 → v14 clamped telemetry.bus_enabled defaults true" "$NAZGUL_DIR/config.json" ".telemetry.bus_enabled" "true"
assert_json_field "v13 → v14 clamped telemetry.record_metered_cost defaults false" "$NAZGUL_DIR/config.json" ".telemetry.record_metered_cost" "false"

# --- migrate_13_to_14: exactly 2 fields in telemetry block (no legacy_write) ---
NAZGUL_DIR=$(setup_nazgul_dir "v13-to-14-field-count")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 13, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v13 → v14 telemetry has exactly 2 fields" "$NAZGUL_DIR/config.json" '.telemetry | keys | length' "2"
assert_json_field "v13 → v14 telemetry has no legacy_write field" "$NAZGUL_DIR/config.json" '.telemetry | has("legacy_write")' "false"

# --- migrate_14_to_15: adds review_gate.simplify_before_review (default false), additive + idempotent ---
NAZGUL_DIR=$(setup_nazgul_dir "v14-to-15-fields")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 14, "mode": "hitl", "review_gate": { "granularity": "group" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v14 → v15 output" "$OUTPUT" "migrated"
assert_json_field "v14 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v14 → v15 simplify_before_review defaults false" "$NAZGUL_DIR/config.json" ".review_gate.simplify_before_review" "false"
assert_json_field "v14 → v15 preserves review_gate.granularity" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"

# --- migrate_14_to_15: hand-set simplify_before_review=true survives ---
NAZGUL_DIR=$(setup_nazgul_dir "v14-to-15-optin")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 14, "review_gate": { "simplify_before_review": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v14 → v15 preserves hand-set simplify_before_review=true" "$NAZGUL_DIR/config.json" ".review_gate.simplify_before_review" "true"

# --- v16 config → migrates to v17 ---
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v16 → v17 output" "$OUTPUT" "migrated"
assert_json_field "v16 → v24 schema_version (via v17)" "$NAZGUL_DIR/config.json" ".schema_version" "24"

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

# --- Test 3k: non-object budget (hand-edited) → clamped to default object at v8 ---
NAZGUL_DIR=$(setup_nazgul_dir "v7-budget-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 7, "budget": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v7 → v8 non-object budget clamped to object" "$NAZGUL_DIR/config.json" ".budget | type" "object"
assert_json_field "v7 → v8 clamped budget.enabled false" "$NAZGUL_DIR/config.json" ".budget.enabled" "false"

# --- migrate_9_to_10: learning block (superseded; terminal schema is now 11) ---
NAZGUL_DIR=$(setup_nazgul_dir "v9-to-10")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 9, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v9 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v9 → v10 learning.enabled" "$NAZGUL_DIR/config.json" ".learning.enabled" "true"
assert_json_field "v9 → v10 learning.rules_doc" "$NAZGUL_DIR/config.json" ".learning.rules_doc" "nazgul/learning/learned-rules.md"
assert_json_field "v9 → v10 learning.min_recurrence" "$NAZGUL_DIR/config.json" ".learning.min_recurrence" "2"
assert_json_field "v9 → v10 learning.max_active_rules" "$NAZGUL_DIR/config.json" ".learning.max_active_rules" "50"
assert_json_field "v9 → v10 learning.auto_distill_post_loop" "$NAZGUL_DIR/config.json" ".learning.auto_distill_post_loop" "true"

# idempotent + type-guard: existing learning object preserved, missing fields backfilled
NAZGUL_DIR=$(setup_nazgul_dir "v9-to-10-existing")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 9, "learning": { "enabled": false, "max_active_rules": 99 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v9 → v10 preserves learning.enabled=false" "$NAZGUL_DIR/config.json" ".learning.enabled" "false"
assert_json_field "v9 → v10 preserves max_active_rules=99" "$NAZGUL_DIR/config.json" ".learning.max_active_rules" "99"
assert_json_field "v9 → v10 backfills missing rules_doc" "$NAZGUL_DIR/config.json" ".learning.rules_doc" "nazgul/learning/learned-rules.md"
assert_json_field "v9 → v10 backfills auto_distill_post_loop" "$NAZGUL_DIR/config.json" ".learning.auto_distill_post_loop" "true"

# non-object .learning clamped to object (hand-edited to a string)
NAZGUL_DIR=$(setup_nazgul_dir "v9-to-10-garbage")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 9, "learning": "garbage" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v9 → v10 non-object learning clamped" "$NAZGUL_DIR/config.json" ".learning | type" "object"
assert_json_field "v9 → v10 clamped learning.enabled default" "$NAZGUL_DIR/config.json" ".learning.enabled" "true"
assert_json_field "v9 → v10 clamped auto_distill_post_loop default" "$NAZGUL_DIR/config.json" ".learning.auto_distill_post_loop" "true"

# --- migrate_10_to_11: default_mode (terminal schema is now 11) ---
NAZGUL_DIR=$(setup_nazgul_dir "v10-to-11")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 10, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v10 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v10 → v11 default_mode null" "$NAZGUL_DIR/config.json" ".default_mode" "null"

NAZGUL_DIR=$(setup_nazgul_dir "v10-to-11-existing")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 10, "default_mode": "afk" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v10 → v11 preserves default_mode=afk" "$NAZGUL_DIR/config.json" ".default_mode" "afk"

NAZGUL_DIR=$(setup_nazgul_dir "v10-to-11-garbage")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 10, "default_mode": { "bad": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v10 → v11 clamps non-string default_mode to null" "$NAZGUL_DIR/config.json" ".default_mode" "null"

# unsupported string → clamped to null
NAZGUL_DIR=$(setup_nazgul_dir "v10-to-11-badstring")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 10, "default_mode": "turbo" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v10 → v11 clamps unsupported default_mode string to null" "$NAZGUL_DIR/config.json" ".default_mode" "null"

# --- migrate_11_to_12: review_gate.granularity (default "task", additive) ---
# Default: when absent, granularity is added as "task" and review_gate fields survive.
NAZGUL_DIR=$(setup_nazgul_dir "v11-to-12-default")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 11, "review_gate": { "require_all_approve": true, "max_retries_per_task": 3, "confidence_threshold": 80 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v11 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v11 → v12 granularity set task then v17 flips to group" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"
assert_json_field "v11 → v12 preserves require_all_approve" "$NAZGUL_DIR/config.json" ".review_gate.require_all_approve" "true"
assert_json_field "v11 → v12 preserves max_retries_per_task" "$NAZGUL_DIR/config.json" ".review_gate.max_retries_per_task" "3"
assert_json_field "v11 → v12 preserves confidence_threshold" "$NAZGUL_DIR/config.json" ".review_gate.confidence_threshold" "80"

# Existing "feature" value survives untouched (never overwritten).
NAZGUL_DIR=$(setup_nazgul_dir "v11-to-12-feature")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 11, "review_gate": { "granularity": "feature", "require_all_approve": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v11 → v12 preserves granularity=feature" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "feature"
assert_json_field "v11 → v12 preserves sibling require_all_approve=false" "$NAZGUL_DIR/config.json" ".review_gate.require_all_approve" "false"

# Existing "group" value survives untouched.
NAZGUL_DIR=$(setup_nazgul_dir "v11-to-12-group")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 11, "review_gate": { "granularity": "group" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v11 → v12 preserves granularity=group" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"

# Non-object review_gate (hand-edited) is clamped to {} then granularity added — no abort.
NAZGUL_DIR=$(setup_nazgul_dir "v11-to-12-garbage")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{ "schema_version": 11, "review_gate": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v11 → v12 clamps non-object review_gate to object" "$NAZGUL_DIR/config.json" ".review_gate | type" "object"
assert_json_field "v11 → v12 clamped review_gate task then v17 flips to group" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"

# --- Regression: unversioned MODERN config survives the full v1→v12 force-march ---
# A config with no schema_version is treated as v1, so the whole chain runs over it.
# Two historical bugs destroyed live state on this path:
#   migrate_2_to_3 used to assign .branch wholesale → wiped an existing branch.
#   migrate_4_to_5 used to delete documents.existing + discovery.files_scanned/
#     existing_docs_count/existing_docs_quality as "unused" → destroyed discovery state.
# This config carries a populated branch, discovery, and documents section; all of
# it must survive intact (and reach schema_version 11).
NAZGUL_DIR=$(setup_nazgul_dir "unversioned-modern")
cat > "$NAZGUL_DIR/config.json" <<'EOF'
{
  "mode": "afk",
  "branch": {
    "feature": "feat/FEAT-007-payments",
    "base": "main",
    "main_worktree_path": "/repo",
    "worktree_dir": "/repo/.worktrees",
    "last_task_branch": "task/TASK-003",
    "created_at": "2026-06-20T00:00:00Z",
    "auto_pr_on_complete": true
  },
  "discovery": {
    "files_scanned": 412,
    "existing_docs_count": 7,
    "existing_docs_quality": "PARTIAL",
    "context_dir": "nazgul/context"
  },
  "documents": {
    "dir": "nazgul/docs",
    "existing": [
      { "path": "README.md", "type": "readme", "relevance": "high" }
    ]
  }
}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "unversioned modern → migrated" "$OUTPUT" "migrated"
assert_json_field "unversioned modern → reaches v24" "$NAZGUL_DIR/config.json" ".schema_version" "24"
# Branch survived migrate_2_to_3 (no wholesale clobber)
assert_json_field "branch.feature survives full chain" "$NAZGUL_DIR/config.json" ".branch.feature" "feat/FEAT-007-payments"
assert_json_field "branch.base survives full chain" "$NAZGUL_DIR/config.json" ".branch.base" "main"
assert_json_field "branch.last_task_branch survives full chain" "$NAZGUL_DIR/config.json" ".branch.last_task_branch" "task/TASK-003"
# v3→v4 still backfills the new field non-destructively
assert_json_field "branch.sparse_paths backfilled" "$NAZGUL_DIR/config.json" ".branch.sparse_paths" "null"
# Discovery-owned fields survived migrate_4_to_5 (not deleted as "unused")
assert_json_field "discovery.files_scanned survives full chain" "$NAZGUL_DIR/config.json" ".discovery.files_scanned" "412"
assert_json_field "discovery.existing_docs_count survives full chain" "$NAZGUL_DIR/config.json" ".discovery.existing_docs_count" "7"
assert_json_field "discovery.existing_docs_quality survives full chain" "$NAZGUL_DIR/config.json" ".discovery.existing_docs_quality" "PARTIAL"
assert_json_field "documents.existing survives full chain" "$NAZGUL_DIR/config.json" ".documents.existing | length" "1"
assert_json_field "documents.existing[0].path survives full chain" "$NAZGUL_DIR/config.json" ".documents.existing[0].path" "README.md"

# --- migrate_15_to_16: adds review_gate.enforce_granularity (default "block"), additive + idempotent ---
NAZGUL_DIR=$(setup_nazgul_dir "v15-to-16-default")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 15, "mode": "hitl", "review_gate": { "granularity": "group" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v15 → v16 output" "$OUTPUT" "migrated"
assert_json_field "v15 → v24 schema_version (full chain)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v15 → v16 enforce_granularity defaults block" "$NAZGUL_DIR/config.json" ".review_gate.enforce_granularity" "block"
assert_json_field "v15 → v16 preserves review_gate.granularity" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"

# --- migrate_15_to_16: hand-set enforce_granularity="warn" survives (preserve existing) ---
NAZGUL_DIR=$(setup_nazgul_dir "v15-to-16-warn")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 15, "review_gate": { "enforce_granularity": "warn" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v15 → v16 preserves hand-set enforce_granularity=warn" "$NAZGUL_DIR/config.json" ".review_gate.enforce_granularity" "warn"

# --- v16 migrates to v17, enforce_granularity survives ---
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-enforce")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "enforce_granularity": "block" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v16 → v17 migrates (enforce test)" "$OUTPUT" "migrated"
assert_json_field "v16 → v24 schema_version (via v17)" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v16 → v17 enforce_granularity preserved" "$NAZGUL_DIR/config.json" ".review_gate.enforce_granularity" "block"

# --- migrate_15_to_16: non-object review_gate clamped to object at v16 ---
NAZGUL_DIR=$(setup_nazgul_dir "v15-to-16-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 15, "review_gate": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v15 → v16 non-object review_gate clamped to object" "$NAZGUL_DIR/config.json" ".review_gate | type" "object"
assert_json_field "v15 → v16 clamped review_gate gets enforce_granularity=block" "$NAZGUL_DIR/config.json" ".review_gate.enforce_granularity" "block"

# --- migrate_16_to_17: granularity equivalence partitions ---

# granularity: "task" (old default) → "group"
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-granularity-task")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "granularity": "task" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 granularity task→group (old default flip)" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"
assert_json_field "v16→v17 granularity task→group schema=21 (via v17)" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# granularity: "group" (new default) → "group" (idempotent / new value unchanged)
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-granularity-group")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "granularity": "group" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 granularity group→group (new default, unchanged)" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"

# granularity: "feature" (hand-set) → "feature" preserved
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-granularity-feature")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "granularity": "feature" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 granularity feature preserved (hand-set)" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "feature"

# granularity: "custom" (arbitrary hand-set) → "custom" preserved
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-granularity-custom")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "granularity": "custom" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 granularity custom preserved (hand-set)" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "custom"

# --- migrate_16_to_17: post_loop equivalence partitions ---

# post_loop: "haiku" (old default) → "sonnet"
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-post-loop-haiku")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "models": { "post_loop": "haiku" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 post_loop haiku→sonnet (old default flip)" "$NAZGUL_DIR/config.json" ".models.post_loop" "sonnet"

# post_loop: "sonnet" (new default) → "sonnet" (idempotent)
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-post-loop-sonnet")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "models": { "post_loop": "sonnet" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 post_loop sonnet→sonnet (new default, unchanged)" "$NAZGUL_DIR/config.json" ".models.post_loop" "sonnet"

# post_loop: "opus" (hand-set) → "opus" preserved
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-post-loop-opus")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "models": { "post_loop": "opus" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 post_loop opus preserved (hand-set)" "$NAZGUL_DIR/config.json" ".models.post_loop" "opus"

# --- migrate_16_to_17: wave_execution equivalence partitions ---

# wave_execution: absent → true added
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-wave-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "parallelism": { "enabled": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 wave_execution absent→true" "$NAZGUL_DIR/config.json" ".parallelism.wave_execution" "true"

# wave_execution: explicit false is PRESERVED (false is the supported opt-out — additive-only)
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-wave-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "parallelism": { "wave_execution": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 explicit wave_execution=false preserved (opt-out)" "$NAZGUL_DIR/config.json" ".parallelism.wave_execution" "false"

# wave_execution: true → true (idempotent)
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-wave-true")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "parallelism": { "wave_execution": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 wave_execution true→true (idempotent)" "$NAZGUL_DIR/config.json" ".parallelism.wave_execution" "true"

# --- migrate_16_to_17: docs.verify_post_loop equivalence partitions ---

# docs block absent → { "verify_post_loop": true } added
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-docs-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 docs absent → verify_post_loop added as true" "$NAZGUL_DIR/config.json" ".docs.verify_post_loop" "true"

# docs.verify_post_loop: false (hand-set opt-out) → false preserved
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-docs-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "docs": { "verify_post_loop": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 docs.verify_post_loop=false preserved (hand-set opt-out)" "$NAZGUL_DIR/config.json" ".docs.verify_post_loop" "false"

# docs.verify_post_loop: true (already present) → true preserved
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-docs-true")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "docs": { "verify_post_loop": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v16→v17 docs.verify_post_loop=true preserved (idempotent)" "$NAZGUL_DIR/config.json" ".docs.verify_post_loop" "true"

# --- migrate_16_to_17: backup file created at v16.bak ---
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-backup")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v16→v17 backup created at config.json.v16.bak" "$NAZGUL_DIR/config.json.v16.bak"

# --- migrate_16_to_17: migrations.log records the change ---
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-log")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v16→v17 migration log created" "$NAZGUL_DIR/logs/migrations.log"
assert_file_contains "v16→v17 log records v16→v17 entry" "$NAZGUL_DIR/logs/migrations.log" "v16→v17"

# --- migrate_16_to_17: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v16-to-17-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 16, "review_gate": { "granularity": "task" }, "models": { "post_loop": "haiku" } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v16→v17 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- v17 config → migrates to v18 (no longer terminal) ---
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v17 → v18 output" "$OUTPUT" "migrated"
assert_json_field "v17 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# --- migrate_17_to_18: review_gate.require_provenance equivalence partitions ---

# require_provenance: absent → true added
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-provenance-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 require_provenance absent→true" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "true"

# require_provenance: explicit false preserved (opt-out)
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-provenance-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "review_gate": { "require_provenance": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 require_provenance=false preserved (hand-set opt-out)" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "false"

# --- migrate_17_to_18: review_gate.conditional_dispatch equivalence partitions ---

# conditional_dispatch: absent → false added
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-dispatch-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 conditional_dispatch absent→false" "$NAZGUL_DIR/config.json" ".review_gate.conditional_dispatch" "false"

# conditional_dispatch: explicit true preserved (opt-in)
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-dispatch-true")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "review_gate": { "conditional_dispatch": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 conditional_dispatch=true preserved (hand-set opt-in)" "$NAZGUL_DIR/config.json" ".review_gate.conditional_dispatch" "true"

# non-object review_gate clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-review-gate-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "review_gate": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 non-object review_gate clamped to object" "$NAZGUL_DIR/config.json" ".review_gate | type" "object"
assert_json_field "v17→v18 clamped review_gate gets require_provenance=true" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "true"

# --- migrate_17_to_18: docs.verify_comments equivalence partitions ---

# verify_comments: absent → true added
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-comments-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 docs.verify_comments absent→true" "$NAZGUL_DIR/config.json" ".docs.verify_comments" "true"

# verify_comments: explicit false preserved (opt-out)
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-comments-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "docs": { "verify_comments": false, "verify_post_loop": true } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 docs.verify_comments=false preserved (hand-set opt-out)" "$NAZGUL_DIR/config.json" ".docs.verify_comments" "false"
assert_json_field "v17→v18 docs.verify_post_loop untouched by comments migration" "$NAZGUL_DIR/config.json" ".docs.verify_post_loop" "true"

# --- migrate_17_to_18: models.review equivalence partitions ---

# models.review: absent → haiku added
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-review-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 models.review absent→haiku" "$NAZGUL_DIR/config.json" ".models.review" "haiku"

# models.review: "sonnet" (old default) → "haiku" (flip)
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-review-sonnet")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "models": { "review": "sonnet" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 models.review sonnet→haiku (old default flip)" "$NAZGUL_DIR/config.json" ".models.review" "haiku"

# models.review: "opus" (hand-set) → "opus" preserved
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-review-opus")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "models": { "review": "opus" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 models.review opus preserved (hand-set)" "$NAZGUL_DIR/config.json" ".models.review" "opus"

# models.review: "haiku" (new default) → "haiku" (idempotent)
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-review-haiku")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "models": { "review": "haiku" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 models.review haiku→haiku (new default, unchanged)" "$NAZGUL_DIR/config.json" ".models.review" "haiku"

# --- migrate_17_to_18: models.review_by_reviewer equivalence partitions ---

# review_by_reviewer: absent → default map added
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-map-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 review_by_reviewer absent→security-reviewer sonnet" "$NAZGUL_DIR/config.json" '.models.review_by_reviewer["security-reviewer"]' "sonnet"
assert_json_field "v17→v18 review_by_reviewer absent→architect-reviewer sonnet" "$NAZGUL_DIR/config.json" '.models.review_by_reviewer["architect-reviewer"]' "sonnet"

# review_by_reviewer: hand-set customized map preserved
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-map-custom")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "models": { "review_by_reviewer": { "code-reviewer": "opus" } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v17→v18 review_by_reviewer custom map preserved" "$NAZGUL_DIR/config.json" '.models.review_by_reviewer["code-reviewer"]' "opus"
assert_json_field "v17→v18 review_by_reviewer custom map has no security-reviewer added" "$NAZGUL_DIR/config.json" '.models.review_by_reviewer | has("security-reviewer")' "false"

# --- migrate_17_to_18: backup file created at v17.bak ---
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-backup")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v17→v18 backup created at config.json.v17.bak" "$NAZGUL_DIR/config.json.v17.bak"

# --- migrate_17_to_18: migrations.log records the change ---
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-log")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v17→v18 migration log created" "$NAZGUL_DIR/logs/migrations.log"
assert_file_contains "v17→v18 log records v17→v18 entry" "$NAZGUL_DIR/logs/migrations.log" "v17→v18"

# --- migrate_17_to_18: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-18-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "models": { "review": "sonnet" } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v17→v18 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- v18 config → migrates to v19 (no longer terminal) ---
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v18 → v19 output" "$OUTPUT" "migrated"
assert_json_field "v18 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# --- migrate_18_to_19: execution.engine equivalence partitions ---

# execution.engine: absent → sequential added
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-engine-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 execution.engine absent→sequential" "$NAZGUL_DIR/config.json" ".execution.engine" "sequential"

# execution.engine: explicit conductor preserved (opt-in)
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-engine-conductor")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "execution": { "engine": "conductor" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 execution.engine=conductor preserved (hand-set opt-in)" "$NAZGUL_DIR/config.json" ".execution.engine" "conductor"

# non-object execution clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-execution-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "execution": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 non-object execution clamped to object" "$NAZGUL_DIR/config.json" ".execution | type" "object"
assert_json_field "v18→v19 clamped execution gets engine=sequential" "$NAZGUL_DIR/config.json" ".execution.engine" "sequential"

# --- migrate_18_to_19: conductor.gates equivalence partitions ---

# conductor.gates: absent → all false added
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-gates-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 conductor.gates.approve_graph absent→false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_graph" "false"
assert_json_field "v18→v19 conductor.gates.approve_each_wave absent→false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_each_wave" "false"
assert_json_field "v18→v19 conductor.gates.approve_final_pr absent→false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_final_pr" "false"

# conductor.gates: explicit true preserved (hand-set opt-in)
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-gates-true")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "conductor": { "gates": { "approve_graph": true } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 conductor.gates.approve_graph=true preserved (hand-set)" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_graph" "true"
assert_json_field "v18→v19 conductor.gates.approve_each_wave still defaults false alongside hand-set sibling" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_each_wave" "false"

# non-object conductor / conductor.gates clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-conductor-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "conductor": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 non-object conductor clamped to object" "$NAZGUL_DIR/config.json" ".conductor | type" "object"
assert_json_field "v18→v19 clamped conductor gets gates.approve_graph=false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_graph" "false"

NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-gates-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "conductor": { "gates": "oops" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 non-object conductor.gates clamped to object" "$NAZGUL_DIR/config.json" ".conductor.gates | type" "object"
assert_json_field "v18→v19 clamped conductor.gates gets approve_graph=false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_graph" "false"

# --- migrate_18_to_19: conductor.max_parallel equivalence partitions ---

# max_parallel: absent → 3 added
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-maxparallel-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 conductor.max_parallel absent→3" "$NAZGUL_DIR/config.json" ".conductor.max_parallel" "3"

# max_parallel: explicit value preserved (hand-set)
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-maxparallel-custom")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "conductor": { "max_parallel": 8 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v18→v19 conductor.max_parallel=8 preserved (hand-set)" "$NAZGUL_DIR/config.json" ".conductor.max_parallel" "8"

# --- migrate_18_to_19: backup file created at v18.bak ---
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-backup")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v18→v19 backup created at config.json.v18.bak" "$NAZGUL_DIR/config.json.v18.bak"

# --- migrate_18_to_19: migrations.log records the change ---
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-log")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "mode": "hitl" }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
assert_file_exists "v18→v19 migration log created" "$NAZGUL_DIR/logs/migrations.log"
assert_file_contains "v18→v19 log records v18→v19 entry" "$NAZGUL_DIR/logs/migrations.log" "v18→v19"

# --- migrate_18_to_19: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v18-to-19-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 18, "conductor": { "gates": { "approve_graph": true }, "max_parallel": 5 } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v18→v19 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- v20 config → migrates to v21 (automation.heartbeat added) ---
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "mode": "hitl", "conductor": { "enforce": { "dispatch_guard": true, "rework_guard": true } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v20 → v21 output" "$OUTPUT" "migrated"
assert_json_field "v20 → v24 schema_version" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v20 → v21 automation.heartbeat.enabled defaults false" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "false"
assert_json_field "v20 → v21 conductor.enforce.dispatch_guard preserved" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"

# --- v24 config → no-op (terminal schema) ---
NAZGUL_DIR=$(setup_nazgul_dir "v24-terminal")
cp "$REPO_ROOT/templates/config.json" "$NAZGUL_DIR/config.json"
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null); MIG_EC=$?
assert_exit_code "v24 terminal no-op: migrator exits 0 (not a crash)" "$MIG_EC" 0
assert_eq "v24 config → no output (terminal no-op)" "$OUTPUT" ""
assert_json_field "v24 terminal → schema_version still 24" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# --- v23 config → v24 (v23 is no longer terminal) ---
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null); MIG_EC=$?
assert_exit_code "v23 → v24: migrator exits 0" "$MIG_EC" 0
assert_contains "v23 → v24 output" "$OUTPUT" "migrated"
assert_json_field "v23 → v24 schema_version reaches 24" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# --- chain test: v1 → v24 completes ---
NAZGUL_DIR=$(setup_nazgul_dir "v1-to-22-chain")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v1→v23 chain migrated" "$OUTPUT" "migrated"
assert_json_field "v1→v24 chain reaches schema_version 24" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v1→v23 chain granularity is group" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"
assert_json_field "v1→v23 chain post_loop is sonnet" "$NAZGUL_DIR/config.json" ".models.post_loop" "sonnet"
assert_json_field "v1→v23 chain wave_execution is true" "$NAZGUL_DIR/config.json" ".parallelism.wave_execution" "true"
assert_json_field "v1→v23 chain docs.verify_post_loop is true" "$NAZGUL_DIR/config.json" ".docs.verify_post_loop" "true"
assert_json_field "v1→v23 chain review_gate.require_provenance is true" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "true"
assert_json_field "v1→v23 chain review_gate.conditional_dispatch is false" "$NAZGUL_DIR/config.json" ".review_gate.conditional_dispatch" "false"
assert_json_field "v1→v23 chain docs.verify_comments is true" "$NAZGUL_DIR/config.json" ".docs.verify_comments" "true"
assert_json_field "v1→v23 chain models.review is haiku" "$NAZGUL_DIR/config.json" ".models.review" "haiku"
assert_json_field "v1→v23 chain models.review_by_reviewer security-reviewer is sonnet" "$NAZGUL_DIR/config.json" '.models.review_by_reviewer["security-reviewer"]' "sonnet"
assert_json_field "v1→v23 chain execution.engine is sequential" "$NAZGUL_DIR/config.json" ".execution.engine" "sequential"
assert_json_field "v1→v23 chain conductor.gates.approve_graph is false" "$NAZGUL_DIR/config.json" ".conductor.gates.approve_graph" "false"
assert_json_field "v1→v23 chain conductor.max_parallel is 3" "$NAZGUL_DIR/config.json" ".conductor.max_parallel" "3"
assert_json_field "v1→v23 chain conductor.enforce.dispatch_guard is true" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v1→v23 chain automation.heartbeat.enabled is false" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "false"
assert_json_field "v1→v23 chain automation.heartbeat.auto_start.engine is conductor" "$NAZGUL_DIR/config.json" ".automation.heartbeat.auto_start.engine" "conductor"
assert_json_field "v1→v23 chain models.conductor is sonnet" "$NAZGUL_DIR/config.json" ".models.conductor" "sonnet"
assert_json_field "v1→v23 chain models.review_orchestrator seeded from review (haiku)" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "haiku"
assert_json_field "v1→v23 chain models.review_default seeded from review (haiku)" "$NAZGUL_DIR/config.json" ".models.review_default" "haiku"
assert_json_field "v1→v23 chain self_audit.enabled is true" "$NAZGUL_DIR/config.json" ".self_audit.enabled" "true"
assert_json_field "v1→v23 chain self_audit.backlog_path" "$NAZGUL_DIR/config.json" ".self_audit.backlog_path" "nazgul/improvements.md"
assert_json_field "v1→v23 chain conductor.enforce.premerge_guard is true" "$NAZGUL_DIR/config.json" ".conductor.enforce.premerge_guard" "true"
assert_json_field "v1→v23 chain branch.prior_hooks_path is null" "$NAZGUL_DIR/config.json" ".branch.prior_hooks_path" "null"
assert_json_field "v1→v23 chain guards.git_hooks is true" "$NAZGUL_DIR/config.json" ".guards.git_hooks" "true"
assert_json_field "v1→v24 chain review_gate.unverified_retries is 2" "$NAZGUL_DIR/config.json" ".review_gate.unverified_retries" "2"
assert_json_field "v1→v24 chain review_gate.allow_unverified_nonblocking is true" "$NAZGUL_DIR/config.json" ".review_gate.allow_unverified_nonblocking" "true"
assert_json_field "v1→v24 chain review_gate.critical_reviewers[0]" "$NAZGUL_DIR/config.json" ".review_gate.critical_reviewers[0]" "security-reviewer"
assert_json_field "v1→v24 chain review_gate.adversarial_crosscheck is true" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_crosscheck" "true"
assert_json_field "v1→v24 chain review_gate.adversarial_margin is 10" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_margin" "10"
assert_json_field "v1→v24 chain review_gate.adversarial_max is 3" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_max" "3"

# --- v19 -> v20: conductor.enforce (additive, default true) ---
TMPDIR_V20=$(mktemp -d)
cp "$REPO_ROOT/templates/config.json" "$TMPDIR_V20/config.json"
# simulate a v19 config lacking the new block
jq '.schema_version = 19 | del(.conductor.enforce)' "$TMPDIR_V20/config.json" > "$TMPDIR_V20/c.tmp" && mv "$TMPDIR_V20/c.tmp" "$TMPDIR_V20/config.json"
mkdir -p "$TMPDIR_V20/nazgul"; mv "$TMPDIR_V20/config.json" "$TMPDIR_V20/nazgul/config.json"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/scripts/migrate-config.sh" "$TMPDIR_V20/nazgul" >/dev/null 2>&1 || true
assert_json_field "v19 → v24 schema_version (walks to terminal)" "$TMPDIR_V20/nazgul/config.json" ".schema_version" "24"
assert_json_field "v19 → v20 conductor.enforce.dispatch_guard defaults true" "$TMPDIR_V20/nazgul/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v19 → v20 conductor.enforce.rework_guard defaults true" "$TMPDIR_V20/nazgul/config.json" ".conductor.enforce.rework_guard" "true"
rm -rf "$TMPDIR_V20"

# --- migrate_19_to_20: conductor.enforce equivalence partitions ---

# dispatch_guard: explicit false preserved (kill-switch), rework_guard still backfilled true
NAZGUL_DIR=$(setup_nazgul_dir "v19-to-20-dispatch-guard-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 19, "conductor": { "enforce": { "dispatch_guard": false } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v19→v20 conductor.enforce.dispatch_guard=false preserved (kill-switch, hand-set)" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "false"
assert_json_field "v19→v20 conductor.enforce.rework_guard still defaults true alongside hand-set sibling" "$NAZGUL_DIR/config.json" ".conductor.enforce.rework_guard" "true"

# non-object conductor clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v19-to-20-conductor-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 19, "conductor": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v19→v20 non-object conductor clamped to object" "$NAZGUL_DIR/config.json" ".conductor | type" "object"
assert_json_field "v19→v20 clamped conductor gets enforce.dispatch_guard=true" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v19→v20 clamped conductor gets enforce.rework_guard=true" "$NAZGUL_DIR/config.json" ".conductor.enforce.rework_guard" "true"

# non-object conductor.enforce clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v19-to-20-enforce-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 19, "conductor": { "enforce": "oops" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v19→v20 non-object conductor.enforce clamped to object" "$NAZGUL_DIR/config.json" ".conductor.enforce | type" "object"
assert_json_field "v19→v20 clamped conductor.enforce gets dispatch_guard=true" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v19→v20 clamped conductor.enforce gets rework_guard=true" "$NAZGUL_DIR/config.json" ".conductor.enforce.rework_guard" "true"

# --- migrate_19_to_20: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v19-to-20-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 19, "conductor": { "enforce": { "dispatch_guard": false } } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v19→v20 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- migrate_20_to_21: automation.heartbeat (additive, default off) ---

# absent → full default block added, enabled false
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v20→v21 automation.heartbeat.enabled absent→false" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "false"
assert_json_field "v20→v21 automation.heartbeat.interval absent→30m" "$NAZGUL_DIR/config.json" ".automation.heartbeat.interval" "30m"
assert_json_field "v20→v21 automation.heartbeat.inbox.provider absent→file" "$NAZGUL_DIR/config.json" ".automation.heartbeat.inbox.provider" "file"
assert_json_field "v20→v21 automation.heartbeat.inbox.dir absent→nazgul/inbox" "$NAZGUL_DIR/config.json" ".automation.heartbeat.inbox.dir" "nazgul/inbox"
assert_json_field "v20→v21 automation.heartbeat.auto_start.mode absent→yolo" "$NAZGUL_DIR/config.json" ".automation.heartbeat.auto_start.mode" "yolo"
assert_json_field "v20→v21 automation.heartbeat.auto_start.engine absent→conductor" "$NAZGUL_DIR/config.json" ".automation.heartbeat.auto_start.engine" "conductor"

# enabled: explicit true preserved (hand-set opt-in), sibling defaults still backfilled
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21-enabled-true")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "automation": { "heartbeat": { "enabled": true, "interval": "5m" } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v20→v21 automation.heartbeat.enabled=true preserved (hand-set opt-in)" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "true"
assert_json_field "v20→v21 automation.heartbeat.interval=5m preserved (hand-set)" "$NAZGUL_DIR/config.json" ".automation.heartbeat.interval" "5m"
assert_json_field "v20→v21 automation.heartbeat.inbox.provider still backfilled file" "$NAZGUL_DIR/config.json" ".automation.heartbeat.inbox.provider" "file"

# non-object automation clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21-automation-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "automation": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v20→v21 non-object automation clamped to object" "$NAZGUL_DIR/config.json" ".automation | type" "object"
assert_json_field "v20→v21 clamped automation gets heartbeat.enabled=false" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "false"

# non-object automation.heartbeat clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21-heartbeat-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "automation": { "heartbeat": "oops" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v20→v21 non-object heartbeat clamped to object" "$NAZGUL_DIR/config.json" ".automation.heartbeat | type" "object"
assert_json_field "v20→v21 clamped heartbeat gets inbox.dir=nazgul/inbox" "$NAZGUL_DIR/config.json" ".automation.heartbeat.inbox.dir" "nazgul/inbox"

# --- migrate_20_to_21: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v20-to-21-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 20, "automation": { "heartbeat": { "enabled": true } } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v20→v21 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- migrate_21_to_22: models.conductor / review split / self_audit (additive) ---

# absent → full defaults; models.review absent so review_orchestrator/review_default fall back
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v21 → v22 output" "$OUTPUT" "migrated"
assert_json_field "v21→v22 models.conductor absent→sonnet" "$NAZGUL_DIR/config.json" ".models.conductor" "sonnet"
assert_json_field "v21→v22 models.review_orchestrator absent review→sonnet" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "sonnet"
assert_json_field "v21→v22 models.review_default absent review→haiku" "$NAZGUL_DIR/config.json" ".models.review_default" "haiku"
assert_json_field "v21→v22 self_audit.enabled absent→true" "$NAZGUL_DIR/config.json" ".self_audit.enabled" "true"
assert_json_field "v21→v22 self_audit.backlog_path absent→nazgul/improvements.md" "$NAZGUL_DIR/config.json" ".self_audit.backlog_path" "nazgul/improvements.md"

# explicit models.review value is inherited as the seed for both new review keys
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-review-seed")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "review": "opus" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 models.review left untouched" "$NAZGUL_DIR/config.json" ".models.review" "opus"
assert_json_field "v21→v22 models.review_orchestrator seeded from models.review" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "opus"
assert_json_field "v21→v22 models.review_default seeded from models.review" "$NAZGUL_DIR/config.json" ".models.review_default" "opus"

# a non-string models.review (null / number) must NOT be used as a seed — fall back to defaults
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-review-null")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "review": null } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 null models.review not seeded → orchestrator defaults sonnet" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "sonnet"
assert_json_field "v21→v22 null models.review not seeded → default defaults haiku" "$NAZGUL_DIR/config.json" ".models.review_default" "haiku"
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-review-number")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "review": 5 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 numeric models.review not seeded → orchestrator defaults sonnet" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "sonnet"
assert_json_field "v21→v22 numeric models.review not seeded → default defaults haiku" "$NAZGUL_DIR/config.json" ".models.review_default" "haiku"

# explicit opt-outs / overrides preserved (hand-set values incl. self_audit.enabled=false)
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-optout")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "conductor": "haiku", "review_orchestrator": "haiku" }, "self_audit": { "enabled": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 hand-set models.conductor preserved" "$NAZGUL_DIR/config.json" ".models.conductor" "haiku"
assert_json_field "v21→v22 hand-set models.review_orchestrator preserved" "$NAZGUL_DIR/config.json" ".models.review_orchestrator" "haiku"
assert_json_field "v21→v22 review_default sibling still backfilled (absent review)" "$NAZGUL_DIR/config.json" ".models.review_default" "haiku"
assert_json_field "v21→v22 hand-set self_audit.enabled=false preserved" "$NAZGUL_DIR/config.json" ".self_audit.enabled" "false"

# non-object models / self_audit clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-models-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": "oops", "self_audit": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 non-object models clamped to object" "$NAZGUL_DIR/config.json" ".models | type" "object"
assert_json_field "v21→v22 clamped models gets conductor=sonnet" "$NAZGUL_DIR/config.json" ".models.conductor" "sonnet"
assert_json_field "v21→v22 non-object self_audit clamped to object" "$NAZGUL_DIR/config.json" ".self_audit | type" "object"
assert_json_field "v21→v22 clamped self_audit gets enabled=true" "$NAZGUL_DIR/config.json" ".self_audit.enabled" "true"

# no existing key removed or renamed — models.review and conductor.enforce siblings survive
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-no-key-lost")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "review": "haiku", "default": "sonnet" }, "conductor": { "enforce": { "dispatch_guard": true, "rework_guard": true } } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v21→v22 models.review not removed" "$NAZGUL_DIR/config.json" ".models.review" "haiku"
assert_json_field "v21→v22 models.default not renamed" "$NAZGUL_DIR/config.json" ".models.default" "sonnet"
assert_json_field "v21→v22 conductor.enforce.dispatch_guard not removed" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v21→v22 conductor.enforce.rework_guard not removed" "$NAZGUL_DIR/config.json" ".conductor.enforce.rework_guard" "true"

# --- migrate_21_to_22: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v21-to-22-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 21, "models": { "review": "sonnet" } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v21→v22 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- migrate_22_to_23: conductor.enforce.premerge_guard / branch.prior_hooks_path / guards.git_hooks (additive) ---

# absent → full defaults
NAZGUL_DIR=$(setup_nazgul_dir "v22-to-23-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 22, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v22 → v23 output" "$OUTPUT" "migrated"
assert_json_field "v22→v23 conductor.enforce.premerge_guard absent→true" "$NAZGUL_DIR/config.json" ".conductor.enforce.premerge_guard" "true"
assert_json_field "v22→v23 branch.prior_hooks_path absent→null" "$NAZGUL_DIR/config.json" ".branch.prior_hooks_path" "null"
assert_json_field "v22→v23 guards.git_hooks absent→true" "$NAZGUL_DIR/config.json" ".guards.git_hooks" "true"

# explicit opt-outs / overrides preserved (hand-set values incl. a real prior hooks path)
NAZGUL_DIR=$(setup_nazgul_dir "v22-to-23-optout")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 22, "conductor": { "enforce": { "premerge_guard": false } }, "branch": { "prior_hooks_path": ".husky" }, "guards": { "git_hooks": false } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v22→v23 hand-set conductor.enforce.premerge_guard=false preserved (kill-switch)" "$NAZGUL_DIR/config.json" ".conductor.enforce.premerge_guard" "false"
assert_json_field "v22→v23 hand-set branch.prior_hooks_path preserved" "$NAZGUL_DIR/config.json" ".branch.prior_hooks_path" ".husky"
assert_json_field "v22→v23 hand-set guards.git_hooks=false preserved" "$NAZGUL_DIR/config.json" ".guards.git_hooks" "false"

# non-object conductor.enforce / branch / guards clamped to object
NAZGUL_DIR=$(setup_nazgul_dir "v22-to-23-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 22, "conductor": { "enforce": "oops" }, "branch": "oops", "guards": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v22→v23 non-object conductor.enforce clamped to object" "$NAZGUL_DIR/config.json" ".conductor.enforce | type" "object"
assert_json_field "v22→v23 clamped conductor.enforce gets premerge_guard=true" "$NAZGUL_DIR/config.json" ".conductor.enforce.premerge_guard" "true"
assert_json_field "v22→v23 non-object branch clamped to object" "$NAZGUL_DIR/config.json" ".branch | type" "object"
assert_json_field "v22→v23 clamped branch gets prior_hooks_path=null" "$NAZGUL_DIR/config.json" ".branch.prior_hooks_path" "null"
assert_json_field "v22→v23 non-object guards clamped to object" "$NAZGUL_DIR/config.json" ".guards | type" "object"
assert_json_field "v22→v23 clamped guards gets git_hooks=true" "$NAZGUL_DIR/config.json" ".guards.git_hooks" "true"

# no existing key removed or renamed — sibling conductor.enforce/guards keys survive
NAZGUL_DIR=$(setup_nazgul_dir "v22-to-23-no-key-lost")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 22, "conductor": { "enforce": { "dispatch_guard": true, "rework_guard": false } }, "guards": { "requireActiveTask": true, "lean_comments": false }, "branch": { "feature": "feat/FEAT-010" } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v22→v23 conductor.enforce.dispatch_guard not removed" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v22→v23 conductor.enforce.rework_guard not removed" "$NAZGUL_DIR/config.json" ".conductor.enforce.rework_guard" "false"
assert_json_field "v22→v23 guards.requireActiveTask not removed" "$NAZGUL_DIR/config.json" ".guards.requireActiveTask" "true"
assert_json_field "v22→v23 guards.lean_comments not removed" "$NAZGUL_DIR/config.json" ".guards.lean_comments" "false"
assert_json_field "v22→v23 branch.feature not removed" "$NAZGUL_DIR/config.json" ".branch.feature" "feat/FEAT-010"

# --- migrate_22_to_23: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v22-to-23-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 22, "branch": { "prior_hooks_path": ".husky" } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v22→v23 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- migrate_23_to_24: review_gate robustness keys (additive) ---

# absent → full defaults
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24-absent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "mode": "hitl" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v23 → v24 output" "$OUTPUT" "migrated"
assert_json_field "v23→v24 review_gate.unverified_retries absent→2" "$NAZGUL_DIR/config.json" ".review_gate.unverified_retries" "2"
assert_json_field "v23→v24 review_gate.allow_unverified_nonblocking absent→true" "$NAZGUL_DIR/config.json" ".review_gate.allow_unverified_nonblocking" "true"
assert_json_field "v23→v24 review_gate.critical_reviewers[0] absent→security-reviewer" "$NAZGUL_DIR/config.json" ".review_gate.critical_reviewers[0]" "security-reviewer"
assert_json_field "v23→v24 review_gate.critical_reviewers[1] absent→architect-reviewer" "$NAZGUL_DIR/config.json" ".review_gate.critical_reviewers[1]" "architect-reviewer"
assert_json_field "v23→v24 review_gate.adversarial_crosscheck absent→true" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_crosscheck" "true"
assert_json_field "v23→v24 review_gate.adversarial_margin absent→10" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_margin" "10"
assert_json_field "v23→v24 review_gate.adversarial_max absent→3" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_max" "3"
assert_json_field "v23→v24 schema_version is 24" "$NAZGUL_DIR/config.json" ".schema_version" "24"

# explicit false / custom array preserved (opt-outs and overrides not clobbered)
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24-explicit")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "review_gate": { "allow_unverified_nonblocking": false, "adversarial_crosscheck": false, "critical_reviewers": ["custom-reviewer"], "unverified_retries": 5 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v23→v24 hand-set allow_unverified_nonblocking=false preserved" "$NAZGUL_DIR/config.json" ".review_gate.allow_unverified_nonblocking" "false"
assert_json_field "v23→v24 hand-set adversarial_crosscheck=false preserved" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_crosscheck" "false"
assert_json_field "v23→v24 custom critical_reviewers preserved" "$NAZGUL_DIR/config.json" ".review_gate.critical_reviewers[0]" "custom-reviewer"
assert_json_field "v23→v24 custom critical_reviewers length preserved" "$NAZGUL_DIR/config.json" ".review_gate.critical_reviewers | length" "1"
assert_json_field "v23→v24 hand-set unverified_retries=5 preserved" "$NAZGUL_DIR/config.json" ".review_gate.unverified_retries" "5"
assert_json_field "v23→v24 explicit-case backfills adversarial_margin=10" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_margin" "10"

# non-object review_gate clamped to object, then backfilled
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "review_gate": "oops" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v23→v24 non-object review_gate clamped to object" "$NAZGUL_DIR/config.json" ".review_gate | type" "object"
assert_json_field "v23→v24 clamped review_gate gets adversarial_max=3" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_max" "3"

# no existing review_gate key removed — siblings survive
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24-no-key-lost")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "review_gate": { "granularity": "group", "require_provenance": true, "confidence_threshold": 80 } }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_json_field "v23→v24 review_gate.granularity not removed" "$NAZGUL_DIR/config.json" ".review_gate.granularity" "group"
assert_json_field "v23→v24 review_gate.require_provenance not removed" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "true"
assert_json_field "v23→v24 review_gate.confidence_threshold not removed" "$NAZGUL_DIR/config.json" ".review_gate.confidence_threshold" "80"

# --- migrate_23_to_24: full idempotency — run twice yields same output ---
NAZGUL_DIR=$(setup_nazgul_dir "v23-to-24-idempotent")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 23, "review_gate": { "critical_reviewers": ["custom-reviewer"] } }
EOF
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v23→v24 full idempotency (run twice = run once)" "$FIRST" "$SECOND"

# --- ordered walk: v17 → v18 → v19 → v20 → v21 → v22 → v23, no key lost ---
# A v17 config carrying a hand-set marker must walk every step in order and land at
# v23 with automation.heartbeat, models.conductor, and guards.git_hooks present, each
# intermediate step's field added, and the marker preserved (additive-only guarantee
# across the whole chain).
NAZGUL_DIR=$(setup_nazgul_dir "v17-to-23-walk")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{ "schema_version": 17, "mode": "hitl", "marker": "keep-me" }
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
assert_contains "v17→v23 walk migrated" "$OUTPUT" "migrated"
assert_json_field "v17→v24 walk reaches schema_version 24" "$NAZGUL_DIR/config.json" ".schema_version" "24"
assert_json_field "v17→v23 walk hand-set marker preserved (no key lost)" "$NAZGUL_DIR/config.json" ".marker" "keep-me"
assert_json_field "v17→v23 walk v18 step review_gate.require_provenance present" "$NAZGUL_DIR/config.json" ".review_gate.require_provenance" "true"
assert_json_field "v17→v23 walk v19 step execution.engine present" "$NAZGUL_DIR/config.json" ".execution.engine" "sequential"
assert_json_field "v17→v23 walk v20 step conductor.enforce.dispatch_guard present" "$NAZGUL_DIR/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "v17→v23 walk v21 step automation.heartbeat present" "$NAZGUL_DIR/config.json" ".automation.heartbeat.enabled" "false"
assert_json_field "v17→v23 walk v22 step models.conductor present" "$NAZGUL_DIR/config.json" ".models.conductor" "sonnet"
assert_json_field "v17→v23 walk v23 step conductor.enforce.premerge_guard present" "$NAZGUL_DIR/config.json" ".conductor.enforce.premerge_guard" "true"
assert_json_field "v17→v23 walk v23 step branch.prior_hooks_path present" "$NAZGUL_DIR/config.json" ".branch.prior_hooks_path" "null"
assert_json_field "v17→v23 walk v23 step guards.git_hooks present" "$NAZGUL_DIR/config.json" ".guards.git_hooks" "true"
assert_json_field "v17→v24 walk v24 step review_gate.unverified_retries present" "$NAZGUL_DIR/config.json" ".review_gate.unverified_retries" "2"
assert_json_field "v17→v24 walk v24 step review_gate.adversarial_max present" "$NAZGUL_DIR/config.json" ".review_gate.adversarial_max" "3"
# idempotent re-run over the already-migrated config leaves it unchanged
FIRST=$(jq -c '.' "$NAZGUL_DIR/config.json")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" >/dev/null 2>/dev/null
SECOND=$(jq -c '.' "$NAZGUL_DIR/config.json")
assert_eq "v17→v23 walk idempotent re-run (terminal no-op)" "$FIRST" "$SECOND"

report_results
