#!/usr/bin/env bash
set -euo pipefail

# Nazgul Config Migration — upgrades project config to latest schema version
# Called by session-context.sh on every session start.
# Usage: migrate-config.sh [nazgul_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
NAZGUL_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul}"
CONFIG="$NAZGUL_DIR/config.json"
TEMPLATE="$PLUGIN_ROOT/templates/config.json"

# Nothing to migrate if no project config or no template
if [ ! -f "$CONFIG" ]; then
  exit 0
fi
if [ ! -f "$TEMPLATE" ]; then
  exit 0
fi

CURRENT_VERSION=$(jq -r '.schema_version // 1' "$CONFIG")
TARGET_VERSION=$(jq -r '.schema_version // 1' "$TEMPLATE")

# Already up to date
if [ "$CURRENT_VERSION" -ge "$TARGET_VERSION" ]; then
  exit 0
fi

# Create log directory
LOG_DIR="$NAZGUL_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/migrations.log"

log_migration() {
  printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$LOG_FILE"
}

# Backup before migration
BACKUP="$CONFIG.v${CURRENT_VERSION}.bak"
cp "$CONFIG" "$BACKUP"
log_migration "Backup created: $BACKUP"

# --- Migration functions (incremental) ---

migrate_1_to_2() {
  local tmp
  tmp=$(mktemp)

  # Add schema_version field
  jq '.schema_version = 2' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  # Add models section only if not already present
  if [ "$(jq 'has("models")' "$CONFIG")" = "false" ]; then
    tmp=$(mktemp)
    jq '.models = {
      "planning": "opus",
      "discovery": "sonnet",
      "docs": "sonnet",
      "review": "sonnet",
      "implementation": "sonnet",
      "specialists": "sonnet",
      "post_loop": "haiku",
      "default": "sonnet"
    }' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi

  log_migration "Migrated 1 -> 2: added schema_version, ensured models section"
}

migrate_2_to_3() {
  local tmp

  # Move afk.last_task_branch to branch.last_task_branch
  local last_branch
  last_branch=$(jq -r '.afk.last_task_branch // null' "$CONFIG")

  # Fill the branch section NON-DESTRUCTIVELY. An earlier version assigned
  # `.branch = { ... }` wholesale, which clobbered an already-populated branch
  # section (e.g. a modern/unversioned config force-marched from v1: it has a
  # live .branch.feature, but no .schema_version, so the chain runs from v1 and
  # this step wiped it). Clamp a non-object .branch to {} first, then add each
  # field only when absent so an existing branch (feature, base, worktree paths)
  # survives. last_task_branch backfills from afk only when not already set.
  tmp=$(mktemp)
  jq --arg lb "$last_branch" '
    .schema_version = 3
    | .branch = ((if (.branch | type) == "object" then .branch else {} end)
        | .feature = (if has("feature") then .feature else null end)
        | .base = (if has("base") then .base else null end)
        | .main_worktree_path = (if has("main_worktree_path") then .main_worktree_path else null end)
        | .worktree_dir = (if has("worktree_dir") then .worktree_dir else null end)
        | .last_task_branch = (if has("last_task_branch") then .last_task_branch
                               elif $lb == "null" then null else $lb end)
        | .created_at = (if has("created_at") then .created_at else null end)
        | .auto_pr_on_complete = (if has("auto_pr_on_complete") then .auto_pr_on_complete else true end))
    | del(.afk.branch_per_task)
    | del(.afk.last_task_branch)
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  log_migration "Migrated 2 -> 3: filled branch section defaults non-destructively (preserves an existing branch)"
}

migrate_3_to_4() {
  local tmp

  # Add webhooks section
  tmp=$(mktemp)
  jq '.schema_version = 4
    | .webhooks = (.webhooks // {
        "enabled": false,
        "url": null,
        "events": ["stop", "compact", "task_complete"],
        "headers": {}
      })
    | .branch.sparse_paths = (.branch.sparse_paths // null)
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  log_migration "Migrated 3 -> 4: added webhooks, branch.sparse_paths"
}

migrate_4_to_5() {
  local tmp
  tmp=$(mktemp)
  # NOTE: documents.existing and discovery.files_scanned/existing_docs_count/
  # existing_docs_quality are NOT deleted here. They are live, discovery-owned
  # fields (written by agents/discovery.md Step 8 and read downstream). An earlier
  # version of this migration deleted them as "unused" and silently destroyed a
  # project's discovery state on any v<5 → v5 force-march. Only genuinely retired
  # fields are removed below.
  jq '.schema_version = 5
    | del(.install_mode)
    | del(.project_spec)
    | del(.objective_set_at)
    | del(.documents.required)
    | del(.documents.generated)
    | del(.documents.approved)
    | del(.context.compact_custom_instructions)
    | del(.parallelism.wave_execution)
    | del(.parallelism.require_settings)
    | del(.models.fast_mode_implementation)
    | del(.project.tools_verified)
    | del(.project.tools_installed)
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  log_migration "Migrated 4 -> 5: removed retired fields (preserved discovery-owned documents.existing + discovery.files_scanned/existing_docs_count/existing_docs_quality)"
}

migrate_5_to_6() {
  local tmp
  tmp=$(mktemp)
  jq '
    (if (.simplify | type) == "object" then .simplify else {} end) as $existing
    | .schema_version = 6
    | .simplify = {
        "post_loop": (if $existing | has("post_loop") then $existing.post_loop else true end),
        "focus": (if $existing | has("focus") then $existing.focus else null end)
      }
    | (if (.guards | type) == "object" then .guards else {} end) as $guards
    | .guards = ($guards + {
        "requireActiveTask": (if $guards | has("requireActiveTask") then $guards.requireActiveTask else true end)
      })
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v5→v6: Added simplify section and guards.requireActiveTask (enabled by default)"
}

migrate_6_to_7() {
  local tmp
  tmp=$(mktemp)
  # Restore install_mode as a durable, first-class field. migrate_4_to_5 had
  # deleted it as "unused", but init writes it and clean/init gitignore logic
  # read it. Clamp to the known values: keep "local" only when explicitly set,
  # otherwise default to "shared" (covers absent, null, and any invalid value).
  jq '
    .install_mode = (if .install_mode == "local" then "local" else "shared" end)
    | .schema_version = 7
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v6→v7: Restored install_mode (clamped to local|shared, default \"shared\")"
}

migrate_7_to_8() {
  local tmp
  tmp=$(mktemp)
  # Add the budget block (default disabled) when absent; preserve an existing
  # OBJECT, but clamp a non-object budget (hand-edited to a string/number) back
  # to the default so downstream `.budget.enabled` lookups can't error
  # (same type-guard pattern as migrate_5_to_6's .simplify/.guards handling).
  jq '
    .budget = (if (.budget | type) == "object" then .budget else {
      "enabled": false,
      "max_usd": null,
      "spent_usd": 0,
      "per_iteration_usd": null,
      "model_iteration_cost": { "opus": 1.20, "sonnet": 0.30, "haiku": 0.05 }
    } end)
    | .schema_version = 8
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v7→v8: Added budget block (cost governor, default disabled)"
}

migrate_8_to_9() {
  local tmp
  tmp=$(mktemp)
  # Add project.smoke_command (runtime-verification gate) when absent; preserve
  # existing. Clamp a non-object .project (hand-edited to a string/array) to {}
  # first, so the assignment can't error and abort the migration (same type-guard
  # pattern as migrate_5_to_6/migrate_7_to_8).
  jq '
    .project = ((if (.project | type) == "object" then .project else {} end) | .smoke_command = (.smoke_command // null))
    | .schema_version = 9
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v8→v9: Added project.smoke_command (runtime-verification gate)"
}

migrate_9_to_10() {
  local tmp
  tmp=$(mktemp)
  # Add the learning block (autolearning feature) when absent; preserve an
  # existing OBJECT, but clamp a non-object .learning back to {} first so the
  # field assignments can't error (same type-guard pattern as 7->8 / 8->9).
  jq '
    .learning = ((if (.learning | type) == "object" then .learning else {} end)
      | .enabled = (if has("enabled") then .enabled else true end)
      | .rules_doc = (.rules_doc // "nazgul/learning/learned-rules.md")
      | .min_recurrence = (.min_recurrence // 2)
      | .max_active_rules = (.max_active_rules // 50)
      | .auto_distill_post_loop = (if has("auto_distill_post_loop") then .auto_distill_post_loop else true end))
    | .schema_version = 10
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v9→v10: Added learning block (autolearning, default enabled)"
}

migrate_10_to_11() {
  local tmp
  tmp=$(mktemp)
  # Add default_mode (null = ask each run). Preserve a valid enum value;
  # downcase and clamp to hitl|afk|yolo — any other string or non-string
  # becomes null so start's mode resolution can't be left in an undefined
  # state (same defensive pattern as prior migrations).
  jq '
    .default_mode = (
      if (.default_mode | type) == "string"
      then (.default_mode | ascii_downcase
            | if (. == "hitl" or . == "afk" or . == "yolo") then . else null end)
      else null end
    )
    | .schema_version = 11
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v10→v11: Added default_mode (null = prompt for run mode)"
}

migrate_11_to_12() {
  local tmp
  tmp=$(mktemp)
  # Add review_gate.granularity ("task" = current per-task review behavior).
  # ADDITIVE ONLY: set it to "task" only when absent — an existing "group"/
  # "feature" (or any hand-set) value MUST survive untouched. Clamp a non-object
  # .review_gate back to {} first so the field assignment can't error and abort
  # the migration (same type-guard pattern as migrate_9_to_10/migrate_10_to_11).
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .granularity = (if has("granularity") then .granularity else "task" end))
    | .schema_version = 12
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v11→v12: Added review_gate.granularity (default \"task\")"
}

migrate_12_to_13() {
  local tmp
  tmp=$(mktemp)
  # Add guards.lean_comments (mechanical comment-bloat block) and
  # guards.max_consecutive_comment_lines. ADDITIVE ONLY: set each only when
  # absent so a project that has opted out (lean_comments=false) or tuned the
  # threshold keeps its value. Clamp a non-object .guards back to {} first so the
  # field assignment can't error and abort the migration (same type-guard pattern
  # as migrate_5_to_6/migrate_11_to_12).
  jq '
    .guards = ((if (.guards | type) == "object" then .guards else {} end)
      | .lean_comments = (if has("lean_comments") then .lean_comments else true end)
      | .max_consecutive_comment_lines = (if has("max_consecutive_comment_lines") then .max_consecutive_comment_lines else 2 end))
    | .schema_version = 13
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v12→v13: Added guards.lean_comments (default true) + max_consecutive_comment_lines (default 2)"
}

migrate_13_to_14() {
  local tmp
  tmp=$(mktemp)
  # Add telemetry.bus_enabled + record_metered_cost. Same ADDITIVE ONLY +
  # type-guard pattern as migrate_12_to_13. NO legacy_write — single-write +
  # dual-read design (Section 6).
  jq '
    .telemetry = ((if (.telemetry | type) == "object" then .telemetry else {} end)
      | .bus_enabled = (if has("bus_enabled") then .bus_enabled else true end)
      | .record_metered_cost = (if has("record_metered_cost") then .record_metered_cost else false end))
    | .schema_version = 14
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v13→v14: Added telemetry.bus_enabled (default true) + record_metered_cost (default false)"
}

# --- Run incremental migrations ---

VERSION="$CURRENT_VERSION"
while [ "$VERSION" -lt "$TARGET_VERSION" ]; do
  NEXT=$((VERSION + 1))
  FUNC="migrate_${VERSION}_to_${NEXT}"
  if type "$FUNC" >/dev/null 2>&1; then
    "$FUNC"
    log_migration "Migration $VERSION -> $NEXT complete"
  else
    log_migration "ERROR: No migration function for $VERSION -> $NEXT"
    echo "ERROR: Missing migration function ${FUNC}" >&2
    exit 1
  fi
  VERSION="$NEXT"
done

log_migration "Config migrated from v${CURRENT_VERSION} to v${TARGET_VERSION}"
echo "Nazgul config migrated from v${CURRENT_VERSION} to v${TARGET_VERSION}."
