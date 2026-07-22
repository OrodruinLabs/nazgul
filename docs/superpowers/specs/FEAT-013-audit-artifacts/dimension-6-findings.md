# Dimension 6 Findings — Config & file contracts (TASK-006)

Scope: config schema v27 + `scripts/migrate-config.sh` (full v1→v27 migration chain),
`templates/config.json` (canonical defaults), `nazgul/config.json` (this repo's live dogfood
instance, including its `config.json.v*.bak` sprawl), `docs/CONFIGURATION.md`, CLAUDE.md's
documented `nazgul/` runtime-file-contract vs what scripts actually read/write, and README.md
(spot-checked). Method: read every migration function in `migrate-config.sh` end-to-end;
diffed `templates/config.json` (v27, ~30 top-level sections) key-by-key against every
`docs/CONFIGURATION.md` key table and against grep-verified runtime consumers in
`scripts/`, `scripts/lib/`, `agents/*.md`, `skills/*/SKILL.md`, `RULES.md`; inspected the live
`nazgul/` directory and `nazgul/logs/migrations.log` on this repo as direct empirical evidence.

**Coverage disclosure**: every key in `templates/config.json` was checked for at least one
runtime consumer (grep across `scripts/`, `agents/`, `skills/`, `RULES.md`). Deep prose-level
cross-reference against `docs/CONFIGURATION.md` was exhaustive for every section that
`docs/CONFIGURATION.md` documents. Sections `docs/CONFIGURATION.md` does **not** document at all
(`project.*`, `discovery.*`, `agents.*`, `documents.*`, `board.*` key table, `context.*`) were
checked only for runtime-consumer presence/absence, not for a docs claim to falsify (there is no
claim to falsify — flagged instead as a documentation *gap*, not drift, where relevant).
README.md was spot-checked (grep for stale `conductor`/`execution.engine` terms — clean, no hits)
but not swept key-by-key the way `docs/CONFIGURATION.md` and `CLAUDE.md` were. `agents/*.md` and
`skills/*/SKILL.md` were grepped for config-key references, not read end-to-end.

---

## Anchor 1 — `config.json.v*.bak` accumulation (root-caused)

- **severity**: high
- **class**: fragility / architecture
- **evidence**:
  - `scripts/migrate-config.sh:39-42` — every time the script runs with
    `CURRENT_VERSION < TARGET_VERSION`, it unconditionally does
    `BACKUP="$CONFIG.v${CURRENT_VERSION}.bak"; cp "$CONFIG" "$BACKUP"` **before** the migration
    chain runs, once per invocation (not once per version step) — this part is fine in isolation.
  - No pruning/rotation/retention logic exists anywhere for these files. Exhaustive grep
    (`grep -rn "prune\|rotate\|retention\|find.*-mtime\|find.*-delete" scripts/*.sh scripts/lib/*.sh`)
    returns zero hits touching `.bak` files anywhere in the plugin.
  - Contrast with the established precedent the codebase already has for bounded runtime state:
    `scripts/stop-hook.sh:719-720` prunes checkpoints to the 2 most recent
    (`ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json | tail -n +3 | xargs rm -f`). No equivalent
    call exists in `migrate-config.sh`.
  - **Live proof, this repo**: `nazgul/config.json.v{11,12,13,16,17,19,20,22,23,24}.bak` — 10 files,
    17KB average, spanning 2026-06-22 to 2026-07-22 (`nazgul/logs/migrations.log` corroborates one
    `Backup created:` line per file, one per session that crossed a schema boundary). One month of
    active dogfooding produced 10 permanent files with no cleanup path; extrapolated over a
    project's lifetime this grows unbounded.
  - `install_mode` (default `"shared"`, `templates/config.json:3`) is the **default** mode: per
    `docs/CONFIGURATION.md:202-210`, only `--local` mode gitignores `nazgul/`. In the default shared
    mode, every `.bak` file is committed to the project's git history permanently — this repo
    happens to run in local mode (`.gitignore:15` = `nazgul/`, confirmed via
    `git check-ignore -v nazgul/config.json.v24.bak` → ignored), which is why the sprawl is only
    visible on disk here, not in `git log`. A default-shared-mode project gets no such shelter.
- **failure scenario**: A long-lived shared-mode project that upgrades the Nazgul plugin regularly
  (the intended, encouraged usage pattern — migrations are described as fully automatic,
  `docs/CONFIGURATION.md:263-271`) accumulates one committed `.bak` file per schema bump forever.
  Over a year of active use this is dozens of files, each 10-20KB, permanently bloating the repo,
  showing up as unreviewable noise in `git log -- nazgul/`, and confusing anyone who greps
  `nazgul/` for the current config (multiple near-identical `config.json*` files with no indication
  which is authoritative).
- **recommendation**: Mirror the existing checkpoint-pruning pattern
  (`scripts/stop-hook.sh:719-720`) inside `migrate-config.sh` immediately after the backup line
  (`scripts/migrate-config.sh:41-42`): keep only the N most recent `.bak` files (e.g. `ls -1t
  "$CONFIG".v*.bak | tail -n +6 | xargs rm -f`) or drop backups older than a fixed age. This is a
  same-file, one-line-of-precedent fix with no schema/contract implications.

## Anchor 2 — Docs-vs-code drift for every documented config key (root-caused)

- **severity**: high
- **class**: docs-drift
- **evidence — the entire "Execution Engine" architecture section is stale (most severe instance)**:
  - `docs/CONFIGURATION.md:95-112` ("## Execution Engine") documents `execution.engine` (values
    `"sequential"`/`"conductor"`) and a `conductor.*` key table
    (`conductor.gates.approve_graph`, `conductor.gates.approve_each_wave`,
    `conductor.gates.approve_final_pr`, `conductor.max_parallel`) as live, current config surface,
    and cites `scripts/lib/conductor-gates.sh` by name (`docs/CONFIGURATION.md:112`) as the file
    that enforces the HITL `approve_graph` override.
  - `scripts/migrate-config.sh:527-570` (`migrate_25_to_26`, "Parallel Execution Collapse") deletes
    `.execution.engine`, `.conductor` (whole tree), and `.models.conductor`, replacing them with
    `execution.parallel`/`execution.gates.{approve_plan,approve_batch,approve_final_pr}`/
    `execution.enforce.*` — this migration shipped in v2.16.0 (commit `fc96f75`, per this repo's own
    git log) and is at schema v26, one step below the current template v27.
    `scripts/lib/conductor-gates.sh` no longer exists on disk (`test -f
    scripts/lib/conductor-gates.sh` → MISSING) and `agents/conductor.md` no longer exists either
    (`ls agents/ | grep -i conductor` → empty). `docs/CONFIGURATION.md` was never updated for this
    collapse — it still describes the pre-v2.16.0 architecture as current, including a reference to
    a deleted file.
  - `docs/CONFIGURATION.md:32` (model-routing table row) and `:37` ("**Conductor tier.**
    `models.conductor`...`/nazgul:start` dispatches `agents/conductor.md`...") both describe
    `models.conductor` and `agents/conductor.md` as live — both deleted by the same migration.
  - `docs/CONFIGURATION.md:124-125` documents `automation.heartbeat.auto_start.engine` (default
    `"conductor"`) as a live key; `scripts/migrate-config.sh:561-565` converts it to
    `auto_start.parallel` and deletes `.engine` as part of the same v25→v26 migration.
  - This is a whole-section drift, not a single stale line — CLAUDE.md (this project's own root
    doc) already reflects the post-collapse architecture correctly ("One engine, optional parallel
    dispatch... `execution.parallel`..."), proving the update was made in one doc and simply never
    propagated to `docs/CONFIGURATION.md`.
- **evidence — reverse direction: real, active keys undocumented**:
  - `docs/CONFIGURATION.md:3-10` ("## Flags for `/nazgul:start`") lists `--afk`, `--yolo`, `--hitl`,
    `--max N`, `--task-pr`, `--continue` but omits `--parallel` and the deprecated `--conductor`
    alias entirely, despite both being live, actively parsed flags
    (`scripts/apply-start-flags.sh:10,23-24`) that write `execution.parallel=true`
    (`scripts/apply-start-flags.sh:56`) — the flag CLAUDE.md's own command reference documents
    (`/nazgul:start "objective"` line: "flags: --afk, --yolo, --hitl, --max N, --parallel;
    --conductor is a deprecated alias").
- **evidence — dead key documented as functional (worse than stale prose: actively misleading
  runtime instructions)**:
  - `docs/CONFIGURATION.md:304-314` ("## Fast Mode") documents `models.fast_mode_implementation` as
    a working feature with a JSON example. `scripts/migrate-config.sh:141` (`migrate_4_to_5`,
    schema v5, shipped long before the current v27) explicitly deletes this key:
    `del(.models.fast_mode_implementation)`. No later migration re-adds it. Worse,
    `skills/start/SKILL.md:80` still instructs the orchestrating agent as live guidance: "If
    `models.fast_mode_implementation` is `true`, implementation and specialist agents use fast mode
    for ~2.5x speed improvement" — this is a skill prompt read by the agent driving every
    `/nazgul:start`, telling it to branch on a config key that migration actively purges from every
    project that has ever crossed schema v5 (i.e. every project on the current template, v27).
  - Confirmed no other consumer exists: `grep -rn fast_mode_implementation scripts/ agents/
    templates/ skills/` returns only the deletion line and the two doc/skill references above.
- **evidence — documented key with no default scaffold (undiscoverable)**:
  - `docs/CONFIGURATION.md:325-338` ("## Self-Improvement Mode") documents `self_improvement.enabled`
    / `self_improvement.threshold` with a JSON example, and `agents/implementer.md:151-163`
    references it as an optional post-task step ("if `self_improvement.enabled` is true in
    `nazgul/config.json`... Skip this step silently if... false or missing"). Neither key appears
    anywhere in `templates/config.json` (confirmed: `grep self_improvement templates/config.json` →
    no hits) — there is no default scaffold, so `/nazgul:config`'s interactive menu (which reads the
    template to enumerate settable keys, per its own SKILL.md) has nothing to expose. The feature
    only activates if a user hand-edits `nazgul/config.json` to add a section the tooling never
    shows them exists.
- **per-key disposition for every section `docs/CONFIGURATION.md` documents** (✓ = consumer
  confirmed, matches docs; ✗ = drift, see finding above; — = not applicable):
  | Doc section | Key(s) | Disposition |
  |---|---|---|
  | Flags | `--afk/--yolo/--hitl/--max/--task-pr/--continue` | ✓ (`scripts/apply-start-flags.sh`) |
  | Flags | `--parallel`, `--conductor` | ✗ undocumented (see above) |
  | Model Routing | `models.planning/discovery/docs/implementation/specialists/post_loop/default` | ✓ |
  | Model Routing | `models.conductor` | ✗ stale — deleted key, still documented |
  | Model Routing | `models.review_default`/`review_orchestrator`/`review_by_reviewer`, legacy `models.review` fallback | ✓ (`agents/review-gate.md:128,415,535`; `scripts/self-audit.sh:161,167,173` genuinely implement the documented 3-step fallback chain) |
  | Review Granularity | `review_gate.granularity`, `require_all_approve` (self-documented as informational-only), `confidence_threshold`, `block_on_security_reject`, `max_retries_per_task` | ✓ |
  | Review Provenance | `review_gate.require_provenance` | ✓ (`scripts/lib/review-provenance.sh`) |
  | Conditional Dispatch | `review_gate.conditional_dispatch` | ✓ (`scripts/lib/reviewer-selection.sh`) |
  | Execution Engine | `execution.engine`, `conductor.*` | ✗ entire section stale (see above) |
  | Automation Heartbeat | `automation.heartbeat.*` | ✓ except `auto_start.engine` (✗, renamed to `.parallel`) |
  | Lean Comments Guard | `guards.lean_comments`, `guards.max_consecutive_comment_lines` | ✓ (`scripts/lean-comments-guard.sh`) |
  | Comment Quality Gate | `docs.verify_comments` | ✓ |
  | Post-Loop Learning Gate | `learning.enabled`, `learning.auto_distill_post_loop` | ✓ |
  | Self-Audit Gate | `self_audit.enabled`, `self_audit.backlog_path` | ✓ |
  | Telemetry Bus | `telemetry.bus_enabled`, `telemetry.record_metered_cost` | ✓ (`record_metered_cost` correctly documented as "reserved, not yet implemented") |
  | Local Mode | `install_mode` | ✓ |
  | Connectors | `connectors.github.*` | ✓ (matches `scripts/lib/connector-github.sh` in every particular checked) |
  | Config Upgrades | schema-version compare/backup/migrate flow | ✓ mechanism accurate; see Anchor 1 for the backup-pruning gap it doesn't mention |
  | Webhooks | `webhooks.enabled/url/events/headers` | ✓ (`scripts/webhook-forward.sh` fully implements the filter-by-event-list behavior shown in the example, including the `task_complete` event which is wired via `scripts/task-completed.sh:42-43`, not the `hooks.json` Stop/PostCompact paths — non-obvious but correct) |
  | Worktree Sparse Paths | `branch.sparse_paths` | ✓ (referenced by name in the doc; not independently re-verified against worktree creation code — sampled) |
  | Fast Mode | `models.fast_mode_implementation` | ✗ dead key, documented as live (see above) |
  | Auto-Enhancement | (no config key, skill-only) | — |
  | Self-Improvement Mode | `self_improvement.enabled/threshold` | ✗ no default scaffold (see above) |
  | Concurrent Session Detection | (no config key) | — |
- **failure scenario**: An operator reading `docs/CONFIGURATION.md` today to decide whether to
  enable `--parallel` mode or tune conductor gates will configure keys
  (`conductor.gates.approve_graph`, etc.) that are silently dropped by the next migration and have
  zero effect from that point forward; conversely, an operator trying to enable fast mode per the
  documented example gets a feature that never activates and is invisible in the settings menu.
  Both are silent failures — no error, no warning, just documented behavior that never happens.
- **recommendation**: Regenerate `docs/CONFIGURATION.md`'s "Execution Engine" section to match
  CLAUDE.md's already-correct description of the collapsed single-engine model
  (`execution.parallel`/`execution.gates.*`/`execution.enforce.*`); delete the "Fast Mode" section
  entirely (dead since schema v5, ~22 schema versions ago) or re-wire it with a real migration
  entry; either give `self_improvement.*` a default scaffold in `templates/config.json` or drop it
  from docs and `agents/implementer.md`; add `--parallel`/`--conductor` to the flags list. This is
  exactly the kind of drift `docs/doc-verifier` (per `agents/doc-verifier.md`) is meant to catch for
  *generated* docs — `docs/CONFIGURATION.md` is hand-maintained and evidently outside that gate's
  reach.

---

## Additional reliability finding

### Finding 3 — Live dogfood config is schema-stale mid-session, producing mixed old/new key coexistence

- **severity**: medium
- **class**: fragility
- **evidence**:
  - This repo's own `nazgul/config.json` is at `schema_version: 25`
    (`jq '.schema_version' nazgul/config.json` → `25`) while `templates/config.json` (the plugin's
    canonical target) is at `schema_version: 27` (`jq '.schema_version' templates/config.json` →
    `27`) — confirmed at the moment of this audit.
  - Migration only runs via the `SessionStart` hook (`scripts/session-context.sh:31-40`, wired in
    `hooks/hooks.json` under `"SessionStart"`); it is never re-invoked mid-session (`PostCompact`'s
    `scripts/post-compact.sh` has no call to `migrate-config.sh`). A long-running session (such as
    the one driving this very FEAT-013 audit) can span a plugin upgrade — v2.16.0/v2.17.0 landed
    (per this repo's own recent git log: `fc96f75`, `a0c25ed`) while this session's config was still
    at the pre-upgrade schema.
  - Concrete effect: `nazgul/config.json` currently carries **both** the old and new execution
    surface simultaneously — `.execution = {engine: "sequential", parallel: true, max_parallel: 4}`
    (mixing a deleted-in-v26 field, `engine`, with the v26+ field, `parallel`) **and** the full
    legacy `.conductor` tree (`gates.*`, `max_parallel`, `enforce.*`) that `migrate_25_to_26` is
    supposed to have deleted, **and** `.models.conductor: "sonnet"` (also supposed to be deleted).
    `.execution.enforce.teammate_report_guard` (added at v27) is absent entirely.
  - Physical corroboration: `nazgul/conductor/` still exists on disk (empty dir) even though
    `migrate_25_to_26` (`scripts/migrate-config.sh:568`) does `rm -rf
    "$(dirname "$CONFIG")/conductor"` — proof the migration genuinely has not run yet, not just a
    stale `jq` read.
  - Downstream guards read only the new key path:
    `scripts/parallel-dispatch-guard.sh:26` reads `.execution.enforce.dispatch_guard` exclusively
    (`.execution.enforce.dispatch_guard == null` → default enforce=true). Because the live config
    lacks that new path entirely during the stale window, the guard silently ignores whatever the
    old-path equivalent (`.conductor.enforce.dispatch_guard`) was explicitly set to — in this case
    it fails toward *more* enforcement (safe direction), but the general pattern (new code reading
    only the new key, old key still present and non-empty) means an explicit opt-out set under the
    old key silently stops applying the moment a migration renames the surface, until the next
    session-start migration catches up.
- **failure scenario**: A project mid-migration-lag (any session spanning a plugin upgrade) has
  config state where old and new keys for the same feature both exist. Code paths that read only
  the new key get correct fail-safe defaults here, but the general shape of this bug class is
  fragile: a future migration that flips a default (as `migrate_16_to_17`/`migrate_17_to_18` already
  do deliberately for other keys) during this same lag window would apply the NEW default while the
  OLD, still-present key silently continues to be read by any code that hasn't been updated yet —
  a two-writer hazard the codebase has no general guard against.
- **recommendation**: Either invoke `migrate-config.sh` from `post-compact.sh` as well (cheap,
  idempotent, no-ops when already current) so long sessions can't lag a full plugin release behind,
  or add a startup assertion that logs (non-fatally) when `CURRENT_VERSION < TARGET_VERSION` at any
  point other than the SessionStart migration call itself, so a stale mid-session config is visible
  rather than silently tolerated.

---

## Structural critique — config key sprawl

### Finding 4 — Multiple dead config-key clusters with zero runtime consumers

- **severity**: medium
- **class**: architecture
- **evidence** (each confirmed via `grep -rn "<key>" scripts/ scripts/lib/ agents/*.md
  skills/*/SKILL.md RULES.md`, excluding `templates/config.json`'s own definition and — where noted
  — display-only references):
  - `context.*` (`templates/config.json:188-194`): of 5 keys, only `context.budget_strategy` has any
    reference outside the template, and that reference (`skills/status/SKILL.md:28,89`) is
    display-only (prints the value in a status report; nothing branches on it).
    `context.compact_threshold_pct`, `context.max_file_read_lines`,
    `context.use_subagents_for_exploration`, `context.checkpoint_state_before_compact` have **zero**
    references anywhere else in the plugin, including in the scripts that would naturally consume
    them (`scripts/pre-compact.sh`, `scripts/post-compact.sh`, `scripts/session-context.sh` — none
    reference `context.` at all).
  - `parallelism.*` (`templates/config.json:195-202`): of 6 keys, only `parallelism.wave_execution`
    (`agents/doc-verifier.md:62`, `scripts/migrate-config.sh`) and `parallelism.parallel_reviews`
    (`agents/review-gate.md:142,161`) have real consumers. `parallelism.enabled`,
    `parallelism.use_agent_teams`, `parallelism.parallel_independent_tasks`,
    `parallelism.max_parallel_teammates` have zero references anywhere outside the template.
  - `safety.block_destructive_commands` (`templates/config.json:149`): zero references outside the
    template. `scripts/pre-tool-guard.sh` (the script this key's name implies it gates) blocks
    destructive commands **unconditionally** — it never reads `safety.block_destructive_commands`
    at all (confirmed: `grep -n "safety\." scripts/pre-tool-guard.sh` → no hits). Setting this key to
    `false` has no effect; the key is purely decorative.
  - `safety.require_tests_pass_before_review` (`templates/config.json:150`): zero script consumers.
    `RULES.md:71` self-discloses this precisely: "The config flag
    `require_tests_pass_before_review` is not mechanically gated at the pre-review boundary" — so
    this one is a *known*, already-documented-as-advisory gap in RULES.md, but it is absent from
    `docs/CONFIGURATION.md` entirely, so a user reading the config-reference doc has no way to learn
    this key is inert.
  - Top-level path-config keys `task_file`, `log_dir`, `review_dir`, `completion_promise`
    (`templates/config.json:13-16`): zero consumers via `jq`/config-path access anywhere in the
    plugin. Every script that needs these paths hardcodes the literal strings
    (`nazgul/plan.md`, `nazgul/logs`, `nazgul/reviews`) directly rather than reading them from
    config — e.g. `scripts/session-context.sh:9` (`PLAN="$NAZGUL_DIR/plan.md"`, not
    `jq -r '.task_file'`). `completion_promise` is the one exception with a real (if unusual)
    consumer: it is checked at the prompt/instruction layer by the agent's own reading of its
    transcript for the literal string `NAZGUL_COMPLETE`, per `scripts/stop-hook.sh:43`'s comment and
    live references in `agents/implementer.md`, `agents/review-gate.md`, `skills/help/SKILL.md`,
    `skills/start/SKILL.md`, `RULES.md` — genuinely consumed, just not by a shell script grep would
    catch on `.completion_promise`.
  - `guards.requireActiveTask` (`templates/config.json:143`): real consumer confirmed
    (`scripts/task-state-guard.sh`), not dead — flagged instead as a naming-convention outlier:
    it is the only camelCase key in a config schema that is snake_case everywhere else
    (`lean_comments`, `max_consecutive_comment_lines`, `git_hooks` sit right next to it in the same
    `guards` object).
- **failure scenario**: None of these cause incorrect behavior today — a dead key silently doing
  nothing is not a crash. The cost is discoverability and trust: an operator who sets
  `safety.block_destructive_commands: false` believing it disables the destructive-command guard
  has not disabled anything, with no error or warning; a security-conscious reviewer of
  `templates/config.json` has ~15 keys across 4 clusters that look load-bearing but aren't, making
  the ~30-section schema harder to audit than its real (smaller) functional surface, and inflating
  every project's `config.json` with noise that migrations must carry forward forever.
- **recommendation**: Either wire each dead key to real behavior (cheapest: `context.*` is the most
  plausible candidate — `max_file_read_lines`/`compact_threshold_pct` map naturally onto existing
  behavior in `pre-compact.sh`/exploration-subagent dispatch) or remove them in a future schema
  migration and drop the corresponding doc/template lines. `safety.block_destructive_commands`
  should either gate `pre-tool-guard.sh`'s check for real or be deleted — a security-flavored config
  key that silently does nothing is the worse of the two failure modes (false sense of control).

---

## Cross-reference (not re-litigated here)

`nazgul/.githooks/` missing + `core.hooksPath` not pointed at it despite `guards.git_hooks: true`
was independently observed during this sweep (same live-repo evidence: `branch.prior_hooks_path:
null`, `git config --get core.hooksPath` → OS default) but is already fully root-caused as
**Dimension 4 / TASK-004 Finding 1** ("the entire git-hooks install/uninstall lifecycle is never
invoked by production code") with deeper evidence than this task's scope required — not duplicated
here to avoid a diluted double-count at dedup time.
