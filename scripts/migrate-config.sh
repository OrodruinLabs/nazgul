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

# MF-048: keep-N-most-recent .bak pruning (mirrors stop-hook.sh's checkpoint pruning).
# NUL-delimited find/read, not `ls | xargs` — a space in NAZGUL_DIR would split paths.
BAK_KEEP=5
CONFIG_BASENAME="$(basename "$CONFIG")"
{
  while IFS= read -r -d '' _bak; do
    _bak_mtime=$(stat -f %m "$_bak" 2>/dev/null || stat -c %Y "$_bak" 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$_bak_mtime" "$_bak"
  done < <(find "$NAZGUL_DIR" -maxdepth 1 -type f -name "${CONFIG_BASENAME}.v*.bak" -print0 2>/dev/null)
} | sort -t "$(printf '\t')" -k1,1rn | tail -n "+$((BAK_KEEP + 1))" | cut -f2- | while IFS= read -r _stale_bak; do
  rm -f -- "$_stale_bak"
  log_migration "Pruned stale backup: $_stale_bak"
done

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

migrate_14_to_15() {
  local tmp
  tmp=$(mktemp)
  # Add review_gate.simplify_before_review (default false). ADDITIVE ONLY +
  # type-guard pattern. The pre-review Simplifier pass is now opt-in — the
  # post-loop simplify pass already cleans up modified files, so running a full
  # simplifier agent before every review board was wasteful.
  # Clamp to a real boolean: keep an existing boolean value (so a hand-set
  # opt-in survives), but coerce a missing or non-boolean value to false.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .simplify_before_review = (
          if (has("simplify_before_review") and (.simplify_before_review | type) == "boolean")
          then .simplify_before_review
          else false
          end))
    | .schema_version = 15
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v14→v15: Added review_gate.simplify_before_review (default false; pre-review simplify is now opt-in)"
}

migrate_15_to_16() {
  local tmp
  tmp=$(mktemp)
  # Add review_gate.enforce_granularity (default "block"). ADDITIVE ONLY + type-guard.
  # "block" halts NAZGUL_COMPLETE on granularity violation; "warn" logs and continues.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .enforce_granularity = (if has("enforce_granularity") then .enforce_granularity else "block" end))
    | .schema_version = 16
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v15→v16: Added review_gate.enforce_granularity (default block; warn downgrades violation to warning)"
}

migrate_16_to_17() {
  local tmp
  tmp=$(mktemp)
  # Defaults overhaul (ADR-002). Two different rules:
  # - granularity / post_loop: flip when ABSENT or still at the OLD default
  #   (task / haiku). A deliberately-chosen old default is indistinguishable from
  #   untouched and IS flipped — accepted limitation, recorded in the log.
  # - wave_execution / docs.verify_post_loop: ADDITIVE ONLY — set the new default
  #   when the key is absent, but PRESERVE any explicit value (including false).
  #   false is the supported opt-out, so it must never be overwritten.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .granularity = (
          if (.granularity == "task" or (.granularity | not))
          then "group"
          else .granularity
          end))
    | .models = ((if (.models | type) == "object" then .models else {} end)
      | .post_loop = (
          if (.post_loop == "haiku" or (.post_loop | not))
          then "sonnet"
          else .post_loop
          end))
    | .parallelism = ((if (.parallelism | type) == "object" then .parallelism else {} end)
      | .wave_execution = (if has("wave_execution") then .wave_execution else true end))
    | .docs = ((if (.docs | type) == "object" then .docs else {} end)
      | .verify_post_loop = (if has("verify_post_loop") then .verify_post_loop else true end))
    | .schema_version = 17
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v16→v17: granularity task→group + post_loop haiku→sonnet (when absent or at old default); wave_execution defaults true only when absent (explicit value incl. false preserved); added docs.verify_post_loop: true"
}

migrate_17_to_18() {
  local tmp
  tmp=$(mktemp)
  # FEAT-006: unified bump for Gap A (require_provenance), Gap B (verify_comments),
  # and Gap C Lever 2/3 (model tiering + conditional dispatch). All four flags are
  # ADDITIVE ONLY — set when absent, any explicit value (incl. false) preserved. A
  # non-object review_gate/docs/models section is first clamped to {} (invalid types NOT preserved).
  # models.review flips sonnet→haiku ONLY if it still equals the prior default,
  # mirroring the models.post_loop "change-only-if-still-default" rule from v16→v17.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .require_provenance = (if has("require_provenance") then .require_provenance else true end)
      | .conditional_dispatch = (if has("conditional_dispatch") then .conditional_dispatch else false end))
    | .docs = ((if (.docs | type) == "object" then .docs else {} end)
      | .verify_comments = (if has("verify_comments") then .verify_comments else true end))
    | .models = ((if (.models | type) == "object" then .models else {} end)
      | .review = (if (.review == "sonnet" or (.review | not)) then "haiku" else .review end)
      | .review_by_reviewer = (
          if (.review_by_reviewer | type) == "object"
          then .review_by_reviewer
          else {"security-reviewer": "sonnet", "architect-reviewer": "sonnet"}
          end))
    | .schema_version = 18
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v17→v18: added review_gate.require_provenance (default true) + conditional_dispatch (default false); docs.verify_comments (default true); models.review sonnet→haiku (only when absent or at old default sonnet); added models.review_by_reviewer pinning security-reviewer+architect-reviewer to sonnet"
}

migrate_18_to_19() {
  local tmp
  tmp=$(mktemp)
  # FEAT-007: conductor engine config surface. ADDITIVE ONLY — set when absent,
  # any explicit value (incl. false) preserved. Non-object execution/conductor
  # sections are first clamped to {} (invalid types NOT preserved).
  jq '
    .execution = ((if (.execution | type) == "object" then .execution else {} end)
      | .engine = (if has("engine") then .engine else "sequential" end))
    | .conductor = ((if (.conductor | type) == "object" then .conductor else {} end)
      | .gates = ((if (.gates | type) == "object" then .gates else {} end)
          | .approve_graph = (if has("approve_graph") then .approve_graph else false end)
          | .approve_each_wave = (if has("approve_each_wave") then .approve_each_wave else false end)
          | .approve_final_pr = (if has("approve_final_pr") then .approve_final_pr else false end))
      | .max_parallel = (if has("max_parallel") then .max_parallel else 3 end))
    | .schema_version = 19
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v18→v19: added execution.engine (default sequential); added conductor.gates.{approve_graph,approve_each_wave,approve_final_pr} (default false); added conductor.max_parallel (default 3)"
}

migrate_19_to_20() {
  local tmp; tmp=$(mktemp)
  # Conductor enforcement toggles. ADDITIVE — set when absent, explicit values (incl. false) preserved.
  jq '
    .conductor = ((if (.conductor | type) == "object" then .conductor else {} end)
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .dispatch_guard = (if has("dispatch_guard") then .dispatch_guard else true end)
          | .rework_guard = (if has("rework_guard") then .rework_guard else true end)))
    | .schema_version = 20
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v19→v20: added conductor.enforce.{dispatch_guard,rework_guard} (default true)"
}

migrate_20_to_21() {
  local tmp; tmp=$(mktemp)
  # FEAT-008: automation heartbeat config surface. ADDITIVE — set when absent, explicit values (incl. false) preserved.
  # Non-object automation/heartbeat/inbox/auto_start sections are first clamped to {} (invalid types NOT preserved).
  jq '
    .automation = ((if (.automation | type) == "object" then .automation else {} end)
      | .heartbeat = ((if (.heartbeat | type) == "object" then .heartbeat else {} end)
          | .enabled = (if has("enabled") then .enabled else false end)
          | .interval = (if has("interval") then .interval else "30m" end)
          | .inbox = ((if (.inbox | type) == "object" then .inbox else {} end)
              | .provider = (if has("provider") then .provider else "file" end)
              | .dir = (if has("dir") then .dir else "nazgul/inbox" end))
          | .auto_start = ((if (.auto_start | type) == "object" then .auto_start else {} end)
              | .mode = (if has("mode") then .mode else "yolo" end)
              | .engine = (if has("engine") then .engine else "conductor" end))))
    | .schema_version = 21
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v20→v21: added automation.heartbeat (enabled default false; interval 30m; inbox provider file dir nazgul/inbox; auto_start mode yolo engine conductor)"
}

migrate_21_to_22() {
  local tmp; tmp=$(mktemp)
  # FEAT-009: model-tier + review-key split + self-audit config. ADDITIVE — set when absent,
  # explicit values preserved; models.review untouched (seed source for the two new review keys).
  local review
  # Only a non-empty STRING models.review is a valid seed. `// empty` already
  # drops JSON null, but a non-string (number/object/bool) would otherwise be
  # printed by `jq -r` and seed review_orchestrator/review_default with garbage.
  review=$(jq -r '(.models.review? | select(type=="string")) // empty' "$CONFIG")
  jq --arg review "$review" '
    .models = ((if (.models | type) == "object" then .models else {} end)
      | .conductor = (if has("conductor") then .conductor else "sonnet" end)
      | .review_orchestrator = (if has("review_orchestrator") then .review_orchestrator
                                elif $review != "" then $review else "sonnet" end)
      | .review_default = (if has("review_default") then .review_default
                           elif $review != "" then $review else "haiku" end))
    | .self_audit = ((if (.self_audit | type) == "object" then .self_audit else {} end)
        | .enabled = (if has("enabled") then .enabled else true end)
        | .backlog_path = (if has("backlog_path") then .backlog_path else "nazgul/improvements.md" end))
    | .schema_version = 22
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v21→v22: added models.conductor (sonnet); split models.review into models.review_orchestrator/models.review_default (seeded from existing models.review, else sonnet/haiku; models.review untouched); added self_audit.{enabled:true,backlog_path:nazgul/improvements.md}"
}

migrate_22_to_23() {
  local tmp; tmp=$(mktemp)
  # FEAT-010: git-level hook enforcement config. ADDITIVE — set when absent, explicit values
  # (incl. false) preserved; sibling conductor.enforce/guards keys untouched.
  jq '
    .conductor = ((if (.conductor | type) == "object" then .conductor else {} end)
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .premerge_guard = (if has("premerge_guard") then .premerge_guard else true end)))
    | .branch = ((if (.branch | type) == "object" then .branch else {} end)
        | .prior_hooks_path = (if has("prior_hooks_path") then .prior_hooks_path else null end))
    | .guards = ((if (.guards | type) == "object" then .guards else {} end)
        | .git_hooks = (if has("git_hooks") then .git_hooks else true end))
    | .schema_version = 23
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v22→v23: added conductor.enforce.premerge_guard (default true); added branch.prior_hooks_path (default null, not-yet-recorded sentinel; empty string means recorded-and-was-unset); added guards.git_hooks (default true)"
}

migrate_23_to_24() {
  local tmp; tmp=$(mktemp)
  # FEAT-011: review-board robustness config. ADDITIVE — set when absent, explicit values
  # (incl. false and a custom critical_reviewers array) preserved; sibling review_gate keys untouched.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .unverified_retries = (if has("unverified_retries") then .unverified_retries else 2 end)
      | .allow_unverified_nonblocking = (if has("allow_unverified_nonblocking") then .allow_unverified_nonblocking else true end)
      | .critical_reviewers = (if has("critical_reviewers") then .critical_reviewers else ["security-reviewer","architect-reviewer"] end)
      | .adversarial_crosscheck = (if has("adversarial_crosscheck") then .adversarial_crosscheck else true end)
      | .adversarial_margin = (if has("adversarial_margin") then .adversarial_margin else 10 end)
      | .adversarial_max = (if has("adversarial_max") then .adversarial_max else 3 end))
    | .schema_version = 24
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v23→v24: added review_gate.{unverified_retries:2, allow_unverified_nonblocking:true, critical_reviewers:[security-reviewer,architect-reviewer], adversarial_crosscheck:true, adversarial_margin:10, adversarial_max:3} (additive; explicit values incl. false and custom critical_reviewers preserved)"
}

migrate_24_to_25() {
  local tmp; tmp=$(mktemp)
  # FEAT-012: connectors.github (default-OFF remote connector). ADDITIVE — set when absent, explicit
  # values (incl. enabled:false, push.enabled:false, and a populated map) preserved; no token/credential
  # key is ever written. Nested pull/push objects guarded defensively so custom values survive.
  jq '
    .connectors = ((if (.connectors | type) == "object" then .connectors else {} end)
      | .github = ((if (.github | type) == "object" then .github else {} end)
          | .enabled = (if has("enabled") then .enabled else false end)
          | .pull = ((if (.pull | type) == "object" then .pull else {} end)
              | .label = (if has("label") then .label else "nazgul" end)
              | .claimed_label = (if has("claimed_label") then .claimed_label else "nazgul-claimed" end)
              | .max_body_bytes = (if has("max_body_bytes") then .max_body_bytes else 65536 end))
          | .push = ((if (.push | type) == "object" then .push else {} end)
              | .enabled = (if has("enabled") then .enabled else true end))
          | .pull_failures = (if has("pull_failures") then .pull_failures else 0 end)
          | .map = (if has("map") then .map else {} end)))
    | .schema_version = 25
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v24→v25: added connectors.github.{enabled:false, pull.{label:nazgul, claimed_label:nazgul-claimed, max_body_bytes:65536}, push.enabled:true, pull_failures:0, map:{}} (additive, default-off; explicit values incl. enabled:true, push.enabled:false, and a populated map preserved; no credential key added)"
}

migrate_25_to_26() {
  local tmp; tmp=$(mktemp)
  # Parallel Execution Collapse: conductor engine removed; one engine with an
  # execution.parallel option. Seeds execution.* from conductor.* (explicit
  # values incl. false preserved via has()), then deletes .execution.engine,
  # .conductor, .models.conductor, and auto_start.engine. Also removes the
  # nazgul/conductor runtime dir (graph.json was a mirror of task manifests).
  jq '
    . as $root
    | ((if ($root.conductor | type) == "object" then $root.conductor else {} end)) as $c
    | ((if ($c.gates | type) == "object" then $c.gates else {} end)) as $cg
    | ((if ($c.enforce | type) == "object" then $c.enforce else {} end)) as $ce
    | .execution = ((if (.execution | type) == "object" then .execution else {} end)
      | .parallel = (if has("parallel") then .parallel
                     else (($root.execution.engine // "sequential") == "conductor") end)
      | .max_parallel = (if has("max_parallel") then .max_parallel
                         else (if ($c | has("max_parallel")) then $c.max_parallel else 3 end) end)
      | .gates = ((if (.gates | type) == "object" then .gates else {} end)
          | .approve_plan = (if has("approve_plan") then .approve_plan
                             else (if ($cg | has("approve_graph")) then $cg.approve_graph else false end) end)
          | .approve_batch = (if has("approve_batch") then .approve_batch
                              else (if ($cg | has("approve_each_wave")) then $cg.approve_each_wave else false end) end)
          | .approve_final_pr = (if has("approve_final_pr") then .approve_final_pr
                                 else (if ($cg | has("approve_final_pr")) then $cg.approve_final_pr else false end) end))
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .dispatch_guard = (if has("dispatch_guard") then .dispatch_guard
                               else (if ($ce | has("dispatch_guard")) then $ce.dispatch_guard else true end) end)
          | .rework_guard = (if has("rework_guard") then .rework_guard
                             else (if ($ce | has("rework_guard")) then $ce.rework_guard else true end) end)
          | .premerge_guard = (if has("premerge_guard") then .premerge_guard
                               else (if ($ce | has("premerge_guard")) then $ce.premerge_guard else true end) end))
      | del(.engine))
    | del(.conductor)
    | (if (.models | type) == "object" then .models |= del(.conductor) else . end)
    | (if (.automation.heartbeat.auto_start | type) == "object"
       then .automation.heartbeat.auto_start |=
         ((.parallel = (if has("parallel") then .parallel else ((.engine // "conductor") == "conductor") end))
          | del(.engine))
       else . end)
    | .schema_version = 26
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  rm -rf "$(dirname "$CONFIG")/conductor"
  log_migration "v25→v26: conductor engine collapsed — execution.parallel/max_parallel/gates{approve_plan,approve_batch,approve_final_pr}/enforce{dispatch,rework,premerge} seeded from conductor.* (explicit values incl. false preserved); deleted execution.engine, conductor.*, models.conductor, auto_start.engine (→auto_start.parallel); removed nazgul/conductor dir"
}

migrate_26_to_27() {
  local tmp; tmp=$(mktemp)
  # Teammate Report Contract: additive kill-switch for the TeammateIdle guard.
  # Explicit values (incl. false) preserved; non-object execution/enforce clamped.
  jq '
    .execution = ((if (.execution | type) == "object" then .execution else {} end)
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .teammate_report_guard = (if has("teammate_report_guard") then .teammate_report_guard else true end)))
    | .schema_version = 27
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v26→v27: added execution.enforce.teammate_report_guard:true (additive; explicit false preserved) — TeammateIdle report-contract guard kill-switch"
}

migrate_27_to_28() {
  local tmp; tmp=$(mktemp)
  # Reliability Wave 2: two additive kill-switch keys for guard-hardening consumers.
  # Explicit values (incl. false/non-default) preserved; non-object guards/automation sections clamped.
  jq '
    .guards = ((if (.guards | type) == "object" then .guards else {} end)
      | .bash_write_reconciliation = (if has("bash_write_reconciliation") then .bash_write_reconciliation else true end))
    | .automation = ((if (.automation | type) == "object" then .automation else {} end)
      | .heartbeat = ((if (.heartbeat | type) == "object" then .heartbeat else {} end)
          | .lock_stale_seconds = (if has("lock_stale_seconds") then .lock_stale_seconds else 300 end)))
    | .schema_version = 28
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v27→v28: added guards.bash_write_reconciliation:true (stop-hook recompute-and-compare kill switch) and automation.heartbeat.lock_stale_seconds:300 (heartbeat claim-lock staleness) (additive; explicit values incl. false/non-default preserved)"
}

migrate_28_to_29() {
  local tmp; tmp=$(mktemp)
  # Reliability Wave 3: additive kill-switch for TASK-004's Bundle 2 model-tier
  # escalation on a reviewer's bounded stall/malformed-return retry. Explicit
  # values (incl. false) preserved; non-object review_gate clamped.
  jq '
    .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
      | .stall_retry_escalate_tier = (if has("stall_retry_escalate_tier") then .stall_retry_escalate_tier else true end))
    | .schema_version = 29
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v28→v29: added review_gate.stall_retry_escalate_tier:true (model-tier escalation on a reviewer's bounded stall/malformed-return retry kill switch) (additive; explicit value incl. false preserved)"
}

migrate_29_to_30() {
  local tmp; tmp=$(mktemp)
  # ADR-005 Decision 4: additive review_gate.receipt_hash_enforcement kill switch;
  # models.review_orchestrator is deliberately untouched (already sonnet since v22).
  jq '
    (if (.safety | type) == "object" then .safety else {} end) as $safety
    # MF-051: drop confirmed zero-consumer dead keys; a customized non-default value
    # survives under ._deprecated_removed instead of being silently dropped.
    | (if (._deprecated_removed | type) == "object" then ._deprecated_removed else {} end) as $dep
    | ($dep
        + (if has("task_file") and (.task_file != "nazgul/plan.md") then {"task_file": .task_file} else {} end)
        + (if has("log_dir") and (.log_dir != "nazgul/logs") then {"log_dir": .log_dir} else {} end)
        + (if has("review_dir") and (.review_dir != "nazgul/reviews") then {"review_dir": .review_dir} else {} end)
        + (if ($safety | has("block_destructive_commands")) and ($safety.block_destructive_commands != true)
           then {"safety.block_destructive_commands": $safety.block_destructive_commands} else {} end)
        + (if ($safety | has("require_tests_pass_before_review")) and ($safety.require_tests_pass_before_review != true)
           then {"safety.require_tests_pass_before_review": $safety.require_tests_pass_before_review} else {} end)
      ) as $newdep
    | (if ($newdep | length) > 0 then ._deprecated_removed = $newdep else . end)
    | del(.task_file) | del(.log_dir) | del(.review_dir)
    | .safety = ($safety | del(.block_destructive_commands) | del(.require_tests_pass_before_review))
    | .review_gate = ((if (.review_gate | type) == "object" then .review_gate else {} end)
        | .receipt_hash_enforcement = (if has("receipt_hash_enforcement") then .receipt_hash_enforcement else false end))
    | .schema_version = 30
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v29→v30: added review_gate.receipt_hash_enforcement:false (additive; explicit value incl. true preserved) — TASK-009 DONE-gate receipt-hash kill switch (ADR-005 Decision 4). DEFAULT OFF (opt-in), a TASK-009 round-2 correction to this same migration: TASK-002's carried-forward parallel-dispatch receipt-attribution weakness (most-recent-.dispatch.json-wins tie-break, no independent correlation) can false-trip mismatches in execution.parallel mode — this repo's own actual run mode — until an attribution-hardening follow-up lands; default-on waits for that. models.review_orchestrator untouched (already sonnet since migrate_21_to_22). MF-051: removed dead keys task_file/log_dir/review_dir/safety.block_destructive_commands/safety.require_tests_pass_before_review (any customized non-default value preserved under ._deprecated_removed, not silently dropped); parallelism.*/context.* left untouched (deprecated-in-template-only per ADR-005 Risk table)"
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
