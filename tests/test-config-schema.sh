#!/usr/bin/env bash
set -euo pipefail

# Test: Config template has all required fields
TEST_NAME="test-config-schema"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

CONFIG="$REPO_ROOT/templates/config.json"

assert_file_exists "config.json exists" "$CONFIG"

# Top-level fields
assert_json_field "has .schema_version" "$CONFIG" ".schema_version" "2"
assert_json_field "has .mode" "$CONFIG" ".mode" "hitl"
assert_json_field "has .max_iterations" "$CONFIG" ".max_iterations" "40"
assert_json_field "has .current_iteration" "$CONFIG" ".current_iteration" "0"
assert_json_field "has .completion_promise" "$CONFIG" ".completion_promise" "HYDRA_COMPLETE"

# Nested: .project
val=$(jq -r '.project | type' "$CONFIG")
assert_eq "has .project object" "$val" "object"

# Nested: .agents.pipeline
val=$(jq -r '.agents.pipeline | type' "$CONFIG")
assert_eq "has .agents.pipeline array" "$val" "array"

# Nested: .agents.reviewers
val=$(jq -r '.agents.reviewers | type' "$CONFIG")
assert_eq "has .agents.reviewers array" "$val" "array"

# Nested: .review_gate.confidence_threshold
assert_json_field "has .review_gate.confidence_threshold" "$CONFIG" ".review_gate.confidence_threshold" "80"

# Nested: .safety.max_consecutive_failures
assert_json_field "has .safety.max_consecutive_failures" "$CONFIG" ".safety.max_consecutive_failures" "5"

# Nested: .afk
val=$(jq -r '.afk | type' "$CONFIG")
assert_eq "has .afk object" "$val" "object"

# Nested: .notifications
val=$(jq -r '.notifications | type' "$CONFIG")
assert_eq "has .notifications object" "$val" "object"

# Nested: .context
val=$(jq -r '.context | type' "$CONFIG")
assert_eq "has .context object" "$val" "object"

# Nested: .parallelism
val=$(jq -r '.parallelism | type' "$CONFIG")
assert_eq "has .parallelism object" "$val" "object"

# Nested: .documents
val=$(jq -r '.documents | type' "$CONFIG")
assert_eq "has .documents object" "$val" "object"

# Nested: .discovery
val=$(jq -r '.discovery | type' "$CONFIG")
assert_eq "has .discovery object" "$val" "object"

# Nested: .board
val=$(jq -r '.board | type' "$CONFIG")
assert_eq "has .board object" "$val" "object"

# Board fields
assert_json_field "has .board.enabled" "$CONFIG" ".board.enabled" "false"
val=$(jq -r '.board.provider' "$CONFIG")
assert_eq "has .board.provider null" "$val" "null"
val=$(jq -r '.board.provider_config | type' "$CONFIG")
assert_eq "has .board.provider_config object" "$val" "object"
val=$(jq -r '.board.task_map | type' "$CONFIG")
assert_eq "has .board.task_map object" "$val" "object"
val=$(jq -r '.board.last_sync' "$CONFIG")
assert_eq "has .board.last_sync null" "$val" "null"
assert_json_field "has .board.sync_failures" "$CONFIG" ".board.sync_failures" "0"

report_results
