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
assert_json_field "has .schema_version" "$CONFIG" ".schema_version" "29"
assert_json_field "review_gate.simplify_before_review default false" "$CONFIG" ".review_gate.simplify_before_review" "false"
assert_json_field "review_gate.enforce_granularity default block" "$CONFIG" ".review_gate.enforce_granularity" "block"
assert_json_field "has .default_mode" "$CONFIG" ".default_mode" "null"
assert_json_field "project has smoke_command" "$CONFIG" ".project.smoke_command" "null"
assert_json_field "has .budget.enabled" "$CONFIG" ".budget.enabled" "false"
assert_json_field "has .install_mode" "$CONFIG" ".install_mode" "shared"
assert_json_field "has .mode" "$CONFIG" ".mode" "hitl"
assert_json_field "has .max_iterations" "$CONFIG" ".max_iterations" "40"
assert_json_field "has .current_iteration" "$CONFIG" ".current_iteration" "0"
assert_json_field "has .completion_promise" "$CONFIG" ".completion_promise" "NAZGUL_COMPLETE"

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
# Nested: .review_gate.granularity (v17 default "group")
assert_json_field "has .review_gate.granularity" "$CONFIG" ".review_gate.granularity" "group"

# Nested: .guards
val=$(jq -r '.guards | type' "$CONFIG")
assert_eq "has .guards object" "$val" "object"
assert_json_field "has .guards.requireActiveTask" "$CONFIG" ".guards.requireActiveTask" "true"
assert_json_field "has .guards.lean_comments" "$CONFIG" ".guards.lean_comments" "true"
assert_json_field "has .guards.max_consecutive_comment_lines" "$CONFIG" ".guards.max_consecutive_comment_lines" "2"

# Nested: .safety.max_consecutive_failures
assert_json_field "has .safety.max_consecutive_failures" "$CONFIG" ".safety.max_consecutive_failures" "5"

# Nested: .branch
val=$(jq -r '.branch | type' "$CONFIG")
assert_eq "has .branch object" "$val" "object"

# Nested: .afk
val=$(jq -r '.afk | type' "$CONFIG")
assert_eq "has .afk object" "$val" "object"

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

# Nested: .simplify
val=$(jq -r '.simplify | type' "$CONFIG")
assert_eq "has .simplify object" "$val" "object"
assert_json_field "has .simplify.post_loop" "$CONFIG" ".simplify.post_loop" "true"
val=$(jq -r '.simplify.focus' "$CONFIG")
assert_eq "has .simplify.focus null" "$val" "null"

# Nested: .telemetry (v14 — Loop Telemetry Bus block)
val=$(jq -r '.telemetry | type' "$CONFIG")
assert_eq "has .telemetry object" "$val" "object"
assert_json_field "has .telemetry.bus_enabled" "$CONFIG" ".telemetry.bus_enabled" "true"
assert_json_field "has .telemetry.record_metered_cost" "$CONFIG" ".telemetry.record_metered_cost" "false"
# Exactly 2 fields — no legacy_write (single-write design, Section 6)
assert_json_field "telemetry has exactly 2 fields" "$CONFIG" '.telemetry | keys | length' "2"
assert_json_field "telemetry has no legacy_write field" "$CONFIG" '.telemetry | has("legacy_write")' "false"

# v17 new defaults
assert_json_field "v17 models.post_loop is sonnet" "$CONFIG" ".models.post_loop" "sonnet"
assert_json_field "v17 parallelism.wave_execution is true" "$CONFIG" ".parallelism.wave_execution" "true"
val=$(jq -r '.docs | type' "$CONFIG")
assert_eq "v17 has .docs object" "$val" "object"
assert_json_field "v17 docs.verify_post_loop is true" "$CONFIG" ".docs.verify_post_loop" "true"

# v18 new defaults (FEAT-006: provenance + comment-verify + model map + conditional-dispatch)
assert_json_field "v18 review_gate.require_provenance is true" "$CONFIG" ".review_gate.require_provenance" "true"
assert_json_field "v18 review_gate.conditional_dispatch is false" "$CONFIG" ".review_gate.conditional_dispatch" "false"
assert_json_field "v18 docs.verify_comments is true" "$CONFIG" ".docs.verify_comments" "true"
assert_json_field "v18 models.review is haiku" "$CONFIG" ".models.review" "haiku"
val=$(jq -r '.models.review_by_reviewer | type' "$CONFIG")
assert_eq "v18 has .models.review_by_reviewer object" "$val" "object"
assert_json_field "v18 models.review_by_reviewer security-reviewer is sonnet" "$CONFIG" '.models.review_by_reviewer["security-reviewer"]' "sonnet"
assert_json_field "v18 models.review_by_reviewer architect-reviewer is sonnet" "$CONFIG" '.models.review_by_reviewer["architect-reviewer"]' "sonnet"

# v19-era default: conductor engine config surface. Superseded in place by the
# Parallel Execution Collapse (v26) — execution.engine and .conductor are gone,
# but the intent they carried flows forward into execution.{parallel,max_parallel,gates}:
# execution.engine="sequential" → execution.parallel=false;
# conductor.gates.{approve_graph,approve_each_wave,approve_final_pr} → execution.gates.{approve_plan,approve_batch,approve_final_pr}.
val=$(jq -r '.execution | type' "$CONFIG")
assert_eq "v19 has .execution object" "$val" "object"
assert_json_field "v19→v26 execution.engine=sequential → execution.parallel is false" "$CONFIG" ".execution.parallel" "false"
assert_json_field "v19→v26 conductor.max_parallel → execution.max_parallel is 3" "$CONFIG" ".execution.max_parallel" "3"
val=$(jq -r '.execution.gates | type' "$CONFIG")
assert_eq "v19→v26 has .execution.gates object" "$val" "object"
assert_json_field "v19→v26 conductor.gates.approve_graph → execution.gates.approve_plan is false" "$CONFIG" ".execution.gates.approve_plan" "false"
assert_json_field "v19→v26 conductor.gates.approve_each_wave → execution.gates.approve_batch is false" "$CONFIG" ".execution.gates.approve_batch" "false"
assert_json_field "v19→v26 conductor.gates.approve_final_pr → execution.gates.approve_final_pr is false" "$CONFIG" ".execution.gates.approve_final_pr" "false"

# v20-era default: conductor enforcement toggles, now execution.enforce.* (v26)
val=$(jq -r '.execution.enforce | type' "$CONFIG")
assert_eq "v20→v26 has .execution.enforce object" "$val" "object"
assert_json_field "v20→v26 conductor.enforce.dispatch_guard → execution.enforce.dispatch_guard is true" "$CONFIG" ".execution.enforce.dispatch_guard" "true"
assert_json_field "v20→v26 conductor.enforce.rework_guard → execution.enforce.rework_guard is true" "$CONFIG" ".execution.enforce.rework_guard" "true"

# v21 new defaults (FEAT-008: automation heartbeat, default off)
val=$(jq -r '.automation | type' "$CONFIG")
assert_eq "v21 has .automation object" "$val" "object"
val=$(jq -r '.automation.heartbeat | type' "$CONFIG")
assert_eq "v21 has .automation.heartbeat object" "$val" "object"
assert_json_field "v21 automation.heartbeat.enabled defaults false" "$CONFIG" ".automation.heartbeat.enabled" "false"
assert_json_field "v21 automation.heartbeat.interval is 30m" "$CONFIG" ".automation.heartbeat.interval" "30m"
assert_json_field "v21 automation.heartbeat.inbox.provider is file" "$CONFIG" ".automation.heartbeat.inbox.provider" "file"
assert_json_field "v21 automation.heartbeat.inbox.dir is nazgul/inbox" "$CONFIG" ".automation.heartbeat.inbox.dir" "nazgul/inbox"
assert_json_field "v21 automation.heartbeat.auto_start.mode is yolo" "$CONFIG" ".automation.heartbeat.auto_start.mode" "yolo"
# v21-era default: auto_start.engine="conductor", now auto_start.parallel (v26)
assert_json_field "v21→v26 auto_start.engine=conductor → auto_start.parallel is true" "$CONFIG" ".automation.heartbeat.auto_start.parallel" "true"

# v22 new defaults (FEAT-009: model-tier + review-key split + self-audit)
# (models.conductor removed by v26 — no successor field; see the v26 block below)
assert_json_field "v22 models.review_orchestrator is sonnet" "$CONFIG" ".models.review_orchestrator" "sonnet"
assert_json_field "v22 models.review_default is haiku" "$CONFIG" ".models.review_default" "haiku"
assert_json_field "v22 models.review still present (retained fallback)" "$CONFIG" ".models.review" "haiku"
val=$(jq -r '.self_audit | type' "$CONFIG")
assert_eq "v22 has .self_audit object" "$val" "object"
assert_json_field "v22 self_audit.enabled is true" "$CONFIG" ".self_audit.enabled" "true"
assert_json_field "v22 self_audit.backlog_path is nazgul/improvements.md" "$CONFIG" ".self_audit.backlog_path" "nazgul/improvements.md"

# v23 new defaults (FEAT-010: git-level hook enforcement config)
assert_json_field "v23 branch.prior_hooks_path is null" "$CONFIG" ".branch.prior_hooks_path" "null"
assert_json_field "v23 guards.git_hooks is true" "$CONFIG" ".guards.git_hooks" "true"
# v23-era default: conductor.enforce.premerge_guard, now execution.enforce.premerge_guard (v26)
assert_json_field "v23→v26 conductor.enforce.premerge_guard → execution.enforce.premerge_guard is true" "$CONFIG" ".execution.enforce.premerge_guard" "true"

# v24 new defaults (FEAT-011: review board robustness — unverified verdict + adversarial cross-check)
assert_json_field "v24 review_gate.unverified_retries is 2" "$CONFIG" ".review_gate.unverified_retries" "2"
assert_json_field "v24 review_gate.allow_unverified_nonblocking is true" "$CONFIG" ".review_gate.allow_unverified_nonblocking" "true"
assert_json_field "v24 review_gate.critical_reviewers[0] is security-reviewer" "$CONFIG" ".review_gate.critical_reviewers[0]" "security-reviewer"
assert_json_field "v24 review_gate.critical_reviewers[1] is architect-reviewer" "$CONFIG" ".review_gate.critical_reviewers[1]" "architect-reviewer"
assert_json_field "v24 review_gate.critical_reviewers length is 2" "$CONFIG" ".review_gate.critical_reviewers | length" "2"
assert_json_field "v24 review_gate.adversarial_crosscheck is true" "$CONFIG" ".review_gate.adversarial_crosscheck" "true"
assert_json_field "v24 review_gate.adversarial_margin is 10" "$CONFIG" ".review_gate.adversarial_margin" "10"
assert_json_field "v24 review_gate.adversarial_max is 3" "$CONFIG" ".review_gate.adversarial_max" "3"

# v25 new defaults (FEAT-012: connectors — GitHub remote connector, default-off)
assert_json_field "v25 connectors.github.enabled is false" "$CONFIG" ".connectors.github.enabled" "false"
assert_json_field "v25 connectors.github.pull.label is nazgul" "$CONFIG" ".connectors.github.pull.label" "nazgul"
assert_json_field "v25 connectors.github.pull.claimed_label is nazgul-claimed" "$CONFIG" ".connectors.github.pull.claimed_label" "nazgul-claimed"
assert_json_field "v25 connectors.github.pull.max_body_bytes is 65536" "$CONFIG" ".connectors.github.pull.max_body_bytes" "65536"
assert_json_field "v25 connectors.github.push.enabled is true" "$CONFIG" ".connectors.github.push.enabled" "true"
assert_json_field "v25 connectors.github.pull_failures is 0" "$CONFIG" ".connectors.github.pull_failures" "0"
assert_json_field "v25 connectors.github.map is empty object" "$CONFIG" ".connectors.github.map | length" "0"

# v26 new defaults (Parallel Execution Collapse: conductor engine removed,
# execution.parallel replaces it on the one sequential engine). Value-equivalence
# assertions for the migrated keys live inline above (v19/v20/v21/v23 sections);
# this block covers only what's new to v26 — the old keys' removal.
assert_json_field "v26 execution.engine no longer exists" "$CONFIG" '.execution | has("engine")' "false"
assert_json_field "v26 conductor section no longer exists" "$CONFIG" 'has("conductor")' "false"
assert_json_field "v26 models.conductor no longer exists" "$CONFIG" '.models | has("conductor")' "false"
assert_json_field "v26 auto_start.engine no longer exists" "$CONFIG" '.automation.heartbeat.auto_start | has("engine")' "false"

# v27 new defaults (Teammate Report Contract: TeammateIdle guard kill-switch, default on)
assert_json_field "v27 execution.enforce.teammate_report_guard is true" "$CONFIG" ".execution.enforce.teammate_report_guard" "true"

# v28 new defaults (Reliability Wave 2: guard-hardening kill switches, both default on)
assert_json_field "v28 guards.bash_write_reconciliation is true" "$CONFIG" ".guards.bash_write_reconciliation" "true"
assert_json_field "v28 automation.heartbeat.lock_stale_seconds is 300" "$CONFIG" ".automation.heartbeat.lock_stale_seconds" "300"

# v29 new default (Reliability Wave 3: model-tier escalation kill switch for a
# reviewer's bounded stall/malformed-return retry)
assert_json_field "v29 review_gate.stall_retry_escalate_tier is true" "$CONFIG" ".review_gate.stall_retry_escalate_tier" "true"

report_results
