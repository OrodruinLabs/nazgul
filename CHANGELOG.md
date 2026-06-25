# Changelog

All notable changes to this project will be documented in this file.

## [2.7.1] - 2026-06-25

### Fixed
- **Guard precision — no more false-positive blocks on read-only commands and commit messages (FEAT-005).** The two Bash-matched PreToolUse guards matched command *substrings* instead of the real action, so legitimate commands were blocked:
  - `local-mode-tracking-guard.sh` blocked any command containing `git add`/`stage`/`commit` and the literal `nazgul/` anywhere — including a commit whose **message** mentioned `nazgul/`, a **multiline** message, or even a read-only command whose grep *pattern* contained those tokens. It now parses the actual git **pathspec** with a no-`eval` tokenizer (skipping the subcommand and the values of message flags like `-m`/`-F`) and blocks only when a real `nazgul/` path is being staged in local mode.
  - `pre-tool-guard.sh` blocked any command where `echo`/`printf` co-occurred with `Status` and a `nazgul/tasks/TASK-` path — even a read-only `echo …; grep nazgul/tasks/TASK-*.md`. It now blocks only on an actual redirect (`>`/`>>`) writing **into** a task manifest.
  - The Write/Edit-matched guards (`task-state-guard.sh`, `lean-comments-guard.sh`) were audited and are structurally immune (they inspect the tool's JSON input, not command strings) — recorded in RULES.md.
  No safety regression: every genuine block still blocks (verified by retained + new BLOCK tests alongside the new ALLOW false-positive tests).

## [2.7.0] - 2026-06-24

### Added
- **Post-loop doc-accuracy verifier gate (FEAT-004).** A new read-only `doc-verifier` agent cross-checks the generated docs and CHANGELOG against the source — every event type, config key, command/skill, named script, and schema version a doc references must actually exist in the codebase. On a clean pass it writes an objective-scoped marker (`nazgul/logs/.docs-verified`), and the stop-hook now **blocks `NAZGUL_COMPLETE` until that marker matches the active objective** — catching invented facts (e.g. the kind of hallucinated CHANGELOG event names this project previously shipped) before release instead of relying on an external reviewer. Bounded backstop (≤3 attempts) so it can never deadlock an unattended loop; opt-out `docs.verify_post_loop` (default `true`) makes it a clean no-op. Wired into the post-loop sequence after documentation/release. Schema 16 → 17.

### Changed
- **Better defaults (FEAT-004), applied additively and only when still at the old default (hand-set values are preserved):**
  - `review_gate.granularity`: `task` → **`group`** — per-task review boards were the expensive default; group review matches how waves already run.
  - `models.post_loop`: `haiku` → **`sonnet`** — the cheap post-loop model shipped invented documentation facts; the new doc-verifier gate plus a stronger model close that gap.
  - `parallelism.wave_execution`: now defaults **`true`** — real parallel waves are safe now that the FEAT-003 granularity completion-gate backstops wrong-granularity reviews.
  - Unchanged (they behaved correctly): `confidence_threshold` (80), `require_all_approve`, `auto_approve_concerns`, `default_mode` (null), `formatter` (off).
- **Honest RULES.md.** Documentation accuracy is now recorded as `[enforced]` (via the post-loop verifier gate).

## [2.6.0] - 2026-06-24

### Added
- **Granularity completion-gate enforcement (FEAT-003).** `review_gate.granularity` is now enforced even when a human or orchestrator dispatches reviews directly (bypassing stop-hook sequencing). A `SubagentStop` detector records the review unit each review-gate actually covered into `nazgul/logs/review-coverage.jsonl` (a derived index of existing `reviewer_verdict` telemetry events, not a new state store), and the stop-hook reconciliation gate blocks (or warns) `NAZGUL_COMPLETE` when a DONE task was reviewed at the wrong granularity — with a bounded backstop so it can never deadlock an unattended loop. New config knob `review_gate.enforce_granularity` (`"block"` default, `"warn"` alternative). Subagent dispatch can't be pre-gated (no PreToolUse matcher for the Task tool), so enforcement lives at the completion gate.

### Fixed
- **State machine is now actually enforced (FEAT-003).** `task-state-guard.sh` rejected only a narrow set of transitions: a full-manifest Write whose `status:` lives in YAML frontmatter matched none of its extractors and fell through to allow — so forbidden jumps like `IN_PROGRESS → DONE` and `PLANNED → DONE` (which RULES.md §2 declares forbidden) silently passed. Added frontmatter + bare-token status extractors and per-state exit-2 messages naming the allowed next state(s); every forbidden transition is now blocked at the tool call. Also restored the missing `BLOCKED` transition arms in the allowlist.
- **Local-mode guard no longer false-blocks on commit messages.** `local-mode-tracking-guard.sh` grepped the whole command for `nazgul/`, so a `git commit -m "… nazgul/ …"` whose message merely mentioned a `nazgul/` path was wrongly blocked even when no nazgul path was staged. The guard now strips quoted segments (the message) before looking for a `nazgul/` pathspec.
- **Reviewer persistence — no more "missing review file" re-dispatch waste.** Reviewers were instructed to write their review to a file but had no `Write` tool, so they often returned the review as text and wrote nothing — forcing the review board to re-dispatch reviewers (full re-runs) or scrape output. Reviewers are now strictly read-only (`Read`/`Glob`/`Grep` — no `Write`, **no `Bash`**) and **return** their review; the review-gate orchestrator persists each returned review to `nazgul/reviews/`. Removing `Bash` also stops reviewers re-running the test suite (a major time sink) and makes "reviewers are read-only" genuinely tool-enforced. The generated reviewers were regenerated (`maxTurns` 30 → 12) and the SubagentStop file-write hook removed.

### Changed
- **Config schema 15 → 16.** `migrate_15_to_16` adds `review_gate.enforce_granularity` (additive, idempotent).
- **Honest RULES.md.** The state-machine rule (§2) and the new granularity rule (§3) are documented as genuinely `[enforced]`, with the manual-dispatch-bypass caveat made explicit.

## [2.5.0] - 2026-06-24

### Added
- **Mechanical mutation guards (FEAT-002).** Three PreToolUse guards turn rules that were prose-only into enforced invariants: `local-mode-tracking-guard.sh` blocks `git add`/`stage`/`commit` of `nazgul/` paths when `install_mode` is `"local"` (closes the runtime-state leak that put loop files into a PR); `base-branch-commit-guard.sh` blocks a `git commit` to the base branch while a feature branch is active; and `task-state-guard.sh` now blocks implementer Write/Edit outside the active task's `file_scope` (anchored path matching, `nazgul/`+`docs/` exempt). The `session-staging.sh` auto-stage is gated on `install_mode` so local-mode loops no longer track `nazgul/`.
- **Honest RULES.md.** Every rule is annotated with its real enforcement tier — `[enforced]`, `[hook-driven only]`, or `[advisory]` — with a legend. RULES.md no longer claims enforcement it doesn't have.

### Changed
- **Faster, leaner review board (~3–4×).** Reviewers are now spawned concurrently in a single message (was effectively serial); the pre-review Simplifier pass is opt-in via `review_gate.simplify_before_review` (default false; post-loop simplify already covers cleanup); reviewers no longer re-run the full test suite (pre-checks ran it once); `maxTurns` lowered (orchestrator 60→40, reviewers 30→15); `security-reviewer` pinned to `sonnet` while other reviewers honor `models.review` (set it to `haiku` to cut cost).
- **Config schema 14 → 15.** `migrate_14_to_15` adds `review_gate.simplify_before_review` (additive, idempotent, boolean-clamped).

## [2.4.0] - 2026-06-24

### Added
- **Loop Telemetry Bus — canonical `nazgul/logs/events.jsonl` event stream (FEAT-001).** Replaces the four scattered telemetry stores (iteration journal, subagent log, in-place budget estimate, compaction dotfile) with a single schema-versioned, append-only stream. 10 event types: `iteration_boundary`, `task_completed`, `reviewer_verdict`, `retry`, `blocked`, `compaction`, `subagent_stop`, `stop_failure`, `budget_threshold`, `objective_complete`. Reviewer verdicts, retries, and blocks are now first-class events (not inferrable only from task manifests).
- **5 producer hooks wired to `emit_event`.** `stop-hook.sh`, `task-completed.sh`, `subagent-stop.sh`, `stop-failure.sh`, and `post-compact.sh` now call `scripts/lib/emit-event.sh` — legacy `iterations.jsonl` / `subagents.jsonl` appends removed; those files freeze in place as historical records.
- **Review-gate agent emits `reviewer_verdict` / `retry` / `blocked`.** `agents/review-gate.md` calls `emit-event-cli.sh` at each verdict, CHANGES_REQUESTED retry, and BLOCKED escalation — fulfilling the CONCERN-1 mitigation from the architect review.
- **`/nazgul:metrics` and `/nazgul:log` dual-read the unified stream.** Both consumer skills prefer `events.jsonl` and fall back permanently to frozen legacy files (`iterations.jsonl` / `subagents.jsonl`) for pre-upgrade history — no cutover, no data loss.
- **`telemetry.bus_enabled` kill switch.** Set `telemetry.bus_enabled: false` to suppress all `emit_event` calls without touching hook scripts. `telemetry.record_metered_cost` (default `false`) is reserved for future metered-cost recording.
- **Concurrency-safe append with macOS fallback.** `scripts/lib/emit-event.sh` serialises concurrent writers with `flock` when available; on stock macOS (no `/usr/bin/flock`) it falls back to a best-effort direct append relying on `O_APPEND` atomicity for the short JSONL lines. Three concurrent emitters produce no interleaved JSON lines. Emits are best-effort — a write failure never aborts the calling hook.

### Changed
- **Config schema v13 → v14.** `migrate_13_to_14` adds a `telemetry` block (`bus_enabled: true`, `record_metered_cost: false`) additively — existing keys survive, and `bus_enabled: false` opt-outs are never overwritten. `templates/config.json` updated to v14.
- **`nazgul/logs/` gitignored (shared install mode).** The event stream is an ephemeral runtime artifact, not a decision record.

## [2.3.0] - 2026-06-24

### Added
- **Post-loop learning gate — distilling Learned Rules is now mandatory, not advisory.** Previously the learner ran only because the `/nazgul:start` OBJECTIVE_COMPLETE prose asked for it (config `learning.auto_distill_post_loop`), so it silently got skipped and no candidate rules were ever proposed. `stop-hook.sh` now **gates loop completion** on it: when all tasks are DONE (or APPROVED/DONE in YOLO) but the learner has not run for the current objective, the stop is blocked with a `DELEGATE: spawn nazgul:learner` instruction (mirroring the review-board dispatch). The learner records completion by writing the objective id (`feat_id`) to `nazgul/learning/.distilled`; the loop reaches `NAZGUL_COMPLETE` only once that marker matches. The marker is keyed to the objective, so a new objective re-triggers distillation. Honors the existing opt-out — a no-op when `learning.enabled` or `learning.auto_distill_post_loop` is `false`. A bounded attempt counter (`nazgul/learning/.distill-attempts`, scoped per objective) lets the loop complete with a loud warning after 3 attempts, so an unwritable marker can never brick an unattended loop (this exit path precedes the max-iteration backstop).

### Changed
- `agents/learner.md` now writes the `.distilled` completion marker as its final step (always, even on a clean no-rules run). `skills/start/SKILL.md` OBJECTIVE_COMPLETE documents the gate. New `tests/test-stop-hook.sh` coverage: gate blocks when undistilled, allows when the marker matches, re-gates a new objective with a stale marker, honors the opt-out, and the attempt backstop completes.

## [2.2.0] - 2026-06-24

### Added
- **Lean-comments guard — comment bloat is now mechanically blocked, not just discouraged.** A new deterministic guard (`scripts/lean-comments-guard.sh`) is wired into the plugin hooks as a `PreToolUse` matcher on `Write|Edit|MultiEdit` (alongside `task-state-guard`), and is also runnable as a pre-commit-style check (`scripts/lean-comments-guard.sh --check <files>`) that the implementer and simplifier run before review. It inspects source content (C#, TS/JS, Python, and other `//`/`#` languages; shell and config formats are intentionally exempt) and BLOCKS the write when a change introduces any of:
  - a run of 3+ consecutive line comments that is not a license header;
  - a `<remarks>`/multi-paragraph doc block on a private/internal/protected or test member;
  - a banner/separator comment (`// ── Helpers ──────`, `// =======`);
  - a comment that restates or narrates the next line of code (incl. micro-optimization noise).

  Full XML/JSDoc/docstring on PUBLIC interface members is expected (`<inheritdoc/>` on implementations), and a single short domain/venue-quirk comment is allowed. The block message names the file and offending comment and instructs the author to cut it to a one-line note or delete it. Tunable and fully opt-out-able via `guards.lean_comments` (default `true`) and `guards.max_consecutive_comment_lines` (default `2`) — when `lean_comments` is `false` the guard is a no-op, so existing projects can opt out without breaking.

- **Enforced three ways (defense in depth).** Previously the "lean comments" rule lived only as advisory prose and the review gate downgraded comment bloat to a low-confidence CONCERN that `auto_approve_concerns` waved through. Now: (1) the hook blocks the write; (2) the **code reviewer** treats comment bloat as an ALWAYS-BLOCKING finding reported at confidence >= the gate threshold (never a sub-threshold CONCERN), with explicit bad-vs-good examples — propagated to every project via `agents/templates/reviewer-domains.json` and the reviewer base template; (3) the **implementer** and **simplifier** agents carry an upfront comment-discipline rule with the same examples and run the `--check` pass before review.

### Changed
- **Schema version 12 → 13.** Added `guards.lean_comments` (default `true`) and `guards.max_consecutive_comment_lines` (default `2`). `migrate_12_to_13` sets them additively only when absent — an existing opt-out (`lean_comments: false`) or tuned threshold survives, and a non-object `guards` is clamped to `{}` first. `templates/config.json`, `scripts/migrate-config.sh`, `hooks/hooks.json`, `agents/implementer.md`, `agents/simplifier.md`, `agents/templates/reviewer-base.md`, `agents/templates/reviewer-domains.json`, `RULES.md`, `templates/CLAUDE.md.template`, and `docs/CONFIGURATION.md` updated. New `tests/test-lean-comments-guard.sh` (19 assertions covering each bad/good/allowed example, opt-out, threshold tuning, and hook mode); migration + schema coverage added to `tests/test-migrate-config.sh` and `tests/test-config-schema.sh`; the new script is registered in `tests/test-shellcheck.sh`.

## [2.1.0] - 2026-06-22

### Added
- **Configurable review granularity (`review_gate.granularity`).** New knob with three values controlling how often the review board runs and what diff it reviews:
  - `task` (default — unchanged behavior): the review board fires per task the moment it reaches IMPLEMENTED, reviewing that task's diff.
  - `group`: the board fires once per planner-defined parallel wave/group, after every task in the group is IMPLEMENTED, reviewing the group's combined diff.
  - `feature`: ALL feature tasks advance to IMPLEMENTED, then ONE review board pass covers the cumulative feature diff (`base..HEAD`).

  Backward-compatible — the default is `task`, so existing projects are unchanged. In `group`/`feature` mode tasks are parked at IMPLEMENTED ("awaiting aggregate review") while the rest of the unit is built; an explicit recovery marker in `plan.md` and the iteration checkpoint (`review_unit` block) means parked tasks survive compaction without being re-reviewed or re-implemented. A CHANGES_REQUESTED re-opens only the tasks whose files own the findings (attributed by the feedback aggregator via file scope) — not the whole group/feature. `require_all_approve`, `confidence_threshold`, and `block_on_security_reject` apply identically in all modes; `max_retries_per_task` is interpreted per review unit (task/group/feature). Configurable via `/nazgul:config` → "Review granularity".

### Changed
- **Schema version 11 → 12.** Added `review_gate.granularity` (default `"task"`). `migrate_11_to_12` sets it additively only when absent — an existing `"group"`/`"feature"` (or any hand-set) value is never overwritten, and all other `review_gate` fields are preserved. `templates/config.json`, `scripts/migrate-config.sh`, `agents/review-gate.md`, `agents/feedback-aggregator.md`, `skills/config/SKILL.md`, and `docs/CONFIGURATION.md` updated. State-machine coverage for all three granularities added to `tests/test-stop-hook.sh`; migration coverage (default + existing-value survival) added to `tests/test-migrate-config.sh`.

## [2.0.4] - 2026-06-22

### Fixed
- **Config migration no longer destroys discovery-owned state.** `migrate_4_to_5` deleted `documents.existing` and `discovery.files_scanned`/`existing_docs_count`/`existing_docs_quality` as "unused" — but these are live fields written by `agents/discovery.md` Step 8 and read downstream. Any v<5 → v5 force-march (including an unversioned modern config, treated as v1) silently wiped a project's discovery state. Those fields are now preserved; only genuinely retired fields are removed.
- **`migrate_2_to_3` no longer clobbers an existing branch section.** It assigned `.branch = { … }` wholesale, so an unversioned modern config (live `branch.feature`, no `schema_version` → migrated from v1) lost its branch isolation state on session start. The branch section is now filled non-destructively — each field is added only when absent, so an existing feature/base/worktree config survives the chain.
- **Pause now sticks.** `stop-hook.sh` cleared the `paused` flag on the first Stop, so `/nazgul:pause` only held for one iteration before the loop self-resumed. Pause is now sticky: the stop hook leaves `paused: true` and allows the stop on every iteration; only `/nazgul:start` clears it (in the mandatory Reset Loop Counters step), making resume an explicit, consented action.

### Changed
- **`agents/discovery.md` Step 8 now mandates a `jq` merge.** Discovery must update `config.json` field-by-field (preserving `schema_version` and all runtime state) rather than rewriting the object, so it can never reset the schema version or clobber loop/branch/budget/pause state.

## [2.0.3] - 2026-06-21

### Fixed
- **Stop/pre-compact hooks no longer abort on a single-commit (greenfield) repo.** `stop-hook.sh` and `pre-compact.sh` built the checkpoint's `files_modified` with `git diff … HEAD~1 … | jq … || echo "[]"`. In a fresh repo `HEAD~1` doesn't exist, so git exits non-zero; under `set -o pipefail` the `|| echo "[]"` fired *after* jq had already printed `[]`, producing `[]\n[]` (two JSON values) → `jq: invalid JSON text passed to --argjson` → the hook aborted before writing its checkpoint, and recurred on every Stop until the repo had ≥2 commits. Extracted a robust `files_modified_json` helper (`scripts/lib/git-utils.sh`) that resolves base→HEAD (valid base → `base..HEAD`; else `HEAD~1..HEAD`; else first-commit empty-tree diff; else `[]`) and always emits exactly one valid JSON array. Both hooks now use it. Added `tests/test-git-utils.sh` (incl. the single-commit regression).

## [2.0.2] - 2026-06-19

### Fixed
- **Shared-mode gitignore now excludes `nazgul/reviews/*/diff.patch`.** The review-gate writes a point-in-time captured diff to `nazgul/reviews/<task>/diff.patch` for reviewers to read first. In shared install mode that file was being committed (unlike the already-ignored `test-failures.md` / `simplify-report.md`), so a later review could read a **stale** diff and emit phantom findings against code that had since changed. `/nazgul:init` now adds `nazgul/reviews/*/diff.patch` to the ephemeral-runtime ignore block, and its reinitialization "stop tracking" one-shot includes it for projects that already committed one.

## [2.0.1] - 2026-06-19

### Changed
- **YOLO permission gate recommends `--permission-mode auto`.** `/nazgul:start`'s YOLO pre-flight now treats either `--permission-mode auto` (recommended — autonomous with a background safety classifier that still blocks dangerous actions like `curl|bash`, force-push to main, prod deploys) or `--dangerously-skip-permissions` (blunt bypass; sandbox only) as a valid non-prompting mode. The probe is unchanged (both modes skip routine prompts; there is no API to read the active mode), but the restart guidance now leads with `auto`. Per the current Claude Code docs, `--dangerously-skip-permissions` is still supported (≡ `--permission-mode bypassPermissions`) but `auto` is the recommended path for unattended runs.

## [2.0.0] - 2026-06-19

### Added
- **`/nazgul:plan` — native brainstorm → spec → tasks.** Interactive design front-end that turns a new idea/objective into a per-idea spec (`nazgul/context/objectives/<feat-id>-spec.md`) and a ready-to-run task plan (reusing the existing discovery/doc-generator/planner agents), then offers to run it. Mirrors the Superpowers brainstorm→plan flow but produces native Nazgul artifacts. `/nazgul:plan` owns objective identity (computes `feat_id`, appends `objectives_history`, sets `afk.commit_prefix`); `/nazgul:start` reuses that identity rather than recomputing it.
- **`config.default_mode`** (schema 11) — set a preferred run mode (`hitl`/`afk`/`yolo`) so `/nazgul:start` doesn't prompt; settable via `/nazgul:config`. Type-guarded `migrate_10_to_11`.
- `doc-generator` reads the active objective's per-idea spec as the PRIMARY source for that objective's docs.

### Changed (BREAKING)
- **`/nazgul:start` no longer runs non-interactively by default.** With no mode flag it now resolves the run mode as: explicit flag > `config.default_mode` > an interactive HITL/AFK/YOLO prompt (with "save as default?"). Existing flag usage (`--yolo`/`--afk`/`--hitl`) is unchanged; the change affects the no-flag default.
- **`/nazgul:start` lost its `disable-model-invocation` guard and `context: fork`.** It is now model-invocable and interactive, so `/nazgul:plan` can hand off to it and "start nazgul" in natural language no longer errors. The new safety gate is the mode prompt — **YOLO is always confirmed**, on every path including an explicit `--yolo` flag.

## [1.6.2] - 2026-06-18

### Changed
- **Release flow now publishes a GitHub Release for every tag.** The release-manager agent gained an explicit step to run `gh release create vX.Y.Z --notes-file … --verify-tag --latest` after tagging (gated on a GitHub remote + authenticated `gh`), plus a matching authority-scope entry and rule. This keeps the GitHub Releases page in sync with the git tags — previously tags could be pushed without a corresponding Release (v1.6.0/v1.6.1 had to be backfilled).

## [1.6.1] - 2026-06-18

### Fixed
- **Interactive skills can now actually prompt you.** The skills that use `AskUserQuestion` for multiple-choice prompts (`init`, `config`, `gen-spec`, `board`, `reset`, `clean`, `bootstrap-project`) ran with `context: fork` — a forked subagent has no interactive channel, so `AskUserQuestion` was unavailable in that environment and they silently degraded to printing options as plain text (which can't capture your reply). Removed `context: fork` from these seven skills so they run in the main loop where `AskUserQuestion` is available. (The ToolSearch pre-load they already do was correct; the fork was the blocker.) Mechanical/non-interactive skills keep `context: fork` for context isolation.

## [1.6.0] - 2026-06-18

### Added
- **Autolearning — Nazgul learns from its own recurring mistakes.** A new `learner` agent mines recurring review rejections, debugger diagnoses, and repeated test failures (read from existing on-disk artifacts — no new runtime hooks) and distills them into candidate **Learned Rules**. Rules are **human-gated**: proposed to `nazgul/learning/proposed-rules.md`, then approved/edited/rejected interactively via the new `/nazgul:learn` skill (also supports `--dry-run` and `--retire`). Approved rules get a stable, monotonic `LR-NNN` number and live in `nazgul/learning/learned-rules.md` (committed in shared install mode; tracked so an external AI code reviewer can be pointed at it).
- **Scoped, dispatch-time rule injection.** Each rule declares `Scope-Agents` + `Scope-Globs`; `scripts/lib/learned-rules.sh select` returns only the rules matching a given agent + the files in scope, injected into that agent's dispatch prompt (the registry can grow without bloating any one agent's context). Reviewers cite applicable rules via a new `Rule reference: LR-NNN` finding field, and each citation bumps the rule's hit counter (feeding retirement of un-cited rules).
- **Post-loop auto-distill** (config `learning.auto_distill_post_loop`, default on): the learner runs at objective completion and proposes (never approves) candidate rules for later review.
- **`/nazgul:metrics` Learning section** — active/retired rule counts, total citations, and top-cited rules.
- **Config schema 10** — new `learning` block (`enabled`, `rules_doc`, `min_recurrence`, `max_active_rules`, `auto_distill_post_loop`) with type-guarded `migrate_9_to_10`.

## [1.5.2] - 2026-06-17

### Fixed
- **`/nazgul:start` flags now take effect on every path.** `--yolo` previously set `afk.*` but never `mode`, so mode-gated branches (the objective menu, doc/plan-review pauses) ran as **HITL** under `--yolo`; `--max N` was documented but **never written** to `max_iterations` (silently ignored); `--afk`/`--hitl` were only applied in the ACTIVE_LOOP state; `--task-pr` was honored only with `--yolo`. Flag→config application is now centralized in a single tested helper (`scripts/apply-start-flags.sh`) that `start` calls in a mandatory step on every path — persisting `mode`/`afk.enabled`/`afk.yolo`/`afk.task_pr`/`max_iterations` before state detection. `--hitl` wins over `--afk`/`--yolo` (and clears the autonomous sub-flags); `--max 0`/non-numeric is ignored as a no-op (leaves `max_iterations` unchanged, so it can't brick the loop).
- **Other skills now honor documented args they previously ignored:** `/nazgul:simplify <focus>` (narrows the pass), `/nazgul:metrics reviews` (shows only reviewer stats), `/nazgul:context <type>` (selects the context section; reads `.project.classification` when no arg). `/nazgul:patch` now reads its `--no-review`/`--discuss` decision back from the manifest `## Flags` line (file-truth, compaction-safe) with an `$ARGUMENTS`-substitution backstop.

### Added
- `tests/test-start-flags.sh` — exhaustive unit tests of the flag helper (every flag, combos, precedence, `--max 0`/non-numeric, missing config). **This is the test that would have caught the `--yolo`/`--max` bugs.**
- `tests/test-skill-arguments.sh` extended with a contract check: every `--flag` documented in a skill's `argument-hint` must be referenced in its body (or handled by the helper) — catches the "documented but never handled" class going forward.

## [1.5.1] - 2026-06-17

### Added
- `/nazgul:metrics` now reports **estimated cost** and **subagent activity** (roadmap 2.3). The Cost section surfaces the budget governor's cumulative estimate (`spent_usd`, % of ceiling, cost per task/iteration) — clearly labeled an *estimate* (≈ iterations × per-tier rate, not metered spend; resets per objective). The Subagent Activity section shows total runs + per-agent-type counts from `nazgul/logs/subagents.jsonl`. Both degrade gracefully (governor disabled → "not tracked"; no subagent log → "no data yet"). Read-only, no schema change.

### Note
- Closes the planned enhancement roadmap. **Roadmap 2.2 (`Monitor` tool) was dropped** after research: its "replace bash poll-loops" premise didn't hold (Monitor is for streaming/repeated events, not "wait-for-completion"; Nazgul's test/build run synchronously), and the only substantive fit — long-running e2e smoke — was judged too risky (starts/tears down real processes in an unattended loop) for its value.

## [1.5.0] - 2026-06-17

### Added
- **Runtime-verification gate** (roadmap 2.1, start of Phase 2 "Verification & Observability"). The review gate's pre-checks now run `build_command` as a **hard gate** — previously it was read but never executed, so a task could pass review and reach DONE with code that doesn't build. A new opt-in `project.smoke_command` runs the built artifact as a short, self-terminating check (e.g. `node dist/index.js --version`, an import-smoke, a healthcheck). Pre-check order is test → lint → build → smoke (stop at first failure); build/smoke failures route through the existing IN_PROGRESS→BLOCKED retry path (captured in the task manifest and, on escalation, `test-failures.md`). Discovery suggests a smoke command. Config schema 8→9.
- Scope note: this is **not** full end-to-end verification — the smoke command is short and self-terminating; orchestrating long-running processes (servers, browsers) is deferred to the Monitor item (2.2). `smoke_command: null` ⇒ runtime smoke skipped (libraries/docs unaffected).

## [1.4.2] - 2026-06-17

### Changed
- Checkpoint retention reduced from 10 to 2 per run (roadmap 1.4.3). Recovery only ever reads the latest checkpoint, so the extra 8 were pure per-run churn; one extra is kept for diff-base safety. The diagnostic reports (`test-failures.md`/`simplify-report.md`) are intentionally kept — they're conditional human diagnostics already gitignored in shared mode.
- The AFK-timeout clock now uses `objective_set_at` as its **primary** source (oldest-checkpoint timestamp only as fallback) — more accurate (true objective start) and independent of checkpoint pruning.
- `/nazgul:metrics` and `/nazgul:log` now source iteration history (total iterations, time span, timeline) from the durable, never-pruned `nazgul/logs/iterations.jsonl` rather than the now-retention-limited checkpoint files, so reducing checkpoint retention doesn't regress those views.

## [1.4.1] - 2026-06-16

### Added
- **Cost/budget governor for AFK/YOLO loops** (roadmap 1.4.2, default disabled). When `budget.enabled` and `budget.max_usd` are set, the Stop hook accumulates an estimated per-iteration cost into `budget.spent_usd` and stops the loop once the ceiling is reached — a dollar-denominated, model-aware ceiling alongside `max_iterations` / `afk.timeout_minutes`. The per-iteration cost is `budget.per_iteration_usd` if set, else derived from `budget.model_iteration_cost[models.implementation]` (so a cheaper implementation tier buys more iterations per dollar). `est_iteration_usd` + `budget_spent_usd` are recorded into each checkpoint; `/nazgul:start` resets the accumulator on every loop-start path. Config schema 7→8.
- This is an **estimate** (≈ iterations × configured per-tier rate), a deterministic ceiling — **not** metered spend. Subagent tokens are modeled into the rate, not measured (subagents run in separate transcripts the Stop hook can't meter). Tune `budget.model_iteration_cost` per project. Non-numeric hand-edited values coerce to a safe default rather than aborting the loop.

## [1.4.0] - 2026-06-16

### Changed
- Review verdicts and task status are now read from a canonical YAML frontmatter block via a single shared parser (`scripts/lib/structured-state.sh`), replacing the regex/awk sniffing in `review-evidence.sh` and `task-utils.sh`. Verdicts validate against a fixed enum (`APPROVE`|`CHANGES_REQUESTED`) and task status against the state-machine enum; a malformed block now fails **loudly** (surfaces as `UNAPPROVED` / a blocked transition) instead of silently mis-reading. This retires the parsing-drift bug class behind the 1.3.0, 1.3.2, and #17 review-gate livelocks. Existing files keep working via an absent→legacy fallback (no forced migration). Roadmap item 1.4.1.
- Reviewer agents (`reviewer-base.md`) now write a `verdict:`/`confidence:` frontmatter block at the top of their review file; task manifests carry a canonical `status:` frontmatter block (the `- **Status**:` line is now a display mirror).

### Added
- `scripts/lib/structured-state.sh` — frontmatter parser with enum validation, CRLF tolerance, quoted-scalar handling, an idempotent source guard, and a `set -e`-safe contract.
- `tests/test-structured-state.sh`; regression cases in `test-review-evidence.sh`/`test-task-utils.sh` pinning the historical livelocks and the structured/legacy/INVALID paths.

## [1.3.5] - 2026-06-16

### Changed
- **Shared install mode no longer commits the ephemeral runtime journal to your repo.** Previously `/nazgul:init` only wrote a `.gitignore` block in `--local` mode, so the *default* shared mode tracked the entire `nazgul/` tree — every per-iteration checkpoint, log, session control file, and the write-only review reports landed in your project's git history and PRs (~95–110 files for a 10-task objective). Shared mode now gitignores the regenerable, machine-local journal (`checkpoints/`, `logs/`, `sessions/`, `.session_id`, `.compaction_count`, `archive/`, `reviews/*/test-failures.md`, `reviews/*/simplify-report.md`, `post-loop-simplify-report.md`) while keeping the **decision record** tracked (`config.json`, `plan.md`, `tasks/`, `reviews/` per-reviewer verdicts, `docs/`, `context/`, generated agents) so teammates can still resume the loop from a clone. Verified: recovery reads `plan.md` + task manifests, not checkpoint *content*, so ignoring checkpoints does not weaken cross-machine resume. `init` Step 2.5 now always runs with shared/local branches; `clean` removes either gitignore block.

### Fixed
- **`install_mode` was not durably persisted.** `migrate-config.sh` (`migrate_4_to_5`) deleted `install_mode` as an "unused" field, but `init` writes it and `clean`/the new shared-mode gitignore logic read it — so the flag was silently stripped on the first session-start migration. Re-legitimized as a first-class field: added to `templates/config.json`, schema bumped 6 → 7, and a new `migrate_6_to_7` restores it (`.install_mode // "shared"`, preserving an existing `"local"`).

### Migration
- Existing shared-mode projects that already committed the ephemeral paths: stop tracking them (files stay on disk) — `init` surfaces the one-shot, or run:
  `git rm -r --cached nazgul/{checkpoints,logs,sessions,archive,.session_id,.compaction_count}` (+ the two report files), then commit.

## [1.3.4] - 2026-06-16

### Fixed
- Subagent definitions `agents/discovery.md` and `agents/templates/reviewer-base.md` carried an `allowed-tools:` frontmatter line, which is a **skills** field and is silently ignored on subagents (the honored field is `tools:`, which both files also have). Net effect was a false sense of restriction — notably the reviewer's intended `Bash(npm test *)`-style scoping was never enforced. Removed the dead lines; reviewers keep `Bash` (needed for tests) and remain covered by the PreToolUse destructive-command guard. Verified against the official subagents frontmatter reference
- `CLAUDE.md` build rules listed `memory:` as a valid optional skill frontmatter field; it is **not** supported for skills (silently ignored) and no skill actually used it. Corrected the rule and enumerated the real optional fields (`argument-hint`, `arguments`, `disallowed-tools`, `model`, `paths`)

### Added
- `StopFailure` hook (`scripts/stop-failure.sh`): a turn ending on an API error previously left an AFK/autonomous loop silently stalled. Now records the failure to the iteration log, writes a `.stop_failure` recovery breadcrumb, runs the configured `notifications.on_failure`/`on_complete` command, and forwards a webhook event
- `SubagentStop` hook (`scripts/subagent-stop.sh`): lightweight observability — appends one line per finished subagent (with agent type when present) to `nazgul/logs/subagents.jsonl`
- `effort: high` on the `planner` and `debugger` agents (newly-supported subagent frontmatter field) to route the deepest-reasoning stages to higher reasoning effort
- `argument-hint` autocomplete hints on `init` (`[--local] [--force]`), `config` (`[models]`), and `start` — surfaces accepted flags as the user types, directly improving the discoverability gap behind the original `--local` bug
- `tests/test-observability-hooks.sh` — behavioral tests for the two new hook scripts (no-op without config, correct logging + breadcrumb with config, agent-name extraction)

### Notes
- Reviewed the plugin against current (June 2026) Claude Code docs. Confirmed already-correct and intentionally left unchanged: `PreCompact`/`PostCompact` + `SessionStart` source matching for compaction recovery, bare model aliases (`opus`/`sonnet`/`haiku` — they auto-track the latest snapshot; pinning full versioned IDs would freeze stale models), the hooks.json format, and the hand-rolled checkpoint/Recovery-Pointer system. `isolation: worktree` is a real new subagent field but was intentionally NOT adopted because Nazgul already manages worktrees manually (EnterWorktree/ExitWorktree); adding it would double-create worktrees

## [1.3.3] - 2026-06-16

### Fixed
- `/nazgul:init --local` silently behaved as shared mode: the `--local`/`--force` flags were buried inline in numbered-step prose, so the model unreliably acted on them — `.gitignore` got no `nazgul/` block, `install_mode` was never set to `local`, and the shared-mode CLAUDE.md section was appended anyway. `skills/init/SKILL.md` now carries an explicit `## Arguments` block (the convention other arg-taking skills follow); **Step 0 now parses + echoes the decision (`Parsed arguments: ... LOCAL_MODE = ... FORCE = ...`) before any branching** — including the idempotency/archive step, which now consumes the parsed `FORCE` instead of re-checking the raw token — with a backstop that halts if the `$ARGUMENTS` placeholder ever fails to substitute
- `/nazgul:config models` had the same latent defect: the `models` shortcut token was read from an inline `$ARGUMENTS` reference with no `## Arguments` block. Added the block and pointed the shortcut check at it
- `/nazgul:discover` referenced `$ARGUMENTS` inline under `## Instructions` with no dedicated block; gave it the standard `## Arguments` block
- Note: contrary to the original design spec's root-cause theory, Claude Code substitutes `$ARGUMENTS` wherever it appears in a skill body (and appends `ARGUMENTS:` when absent), so arguments always reached the model — the real defect was instruction reliability, not missing substitution. The `## Arguments` block is a clarity/consistency convention, and the forced echo in Step 0 is the actual robustness fix

### Added
- `tests/test-skill-arguments.sh` — regression test enforcing that every skill referencing `$ARGUMENTS` surfaces it in a **dedicated `## Arguments` block** (an `## Arguments` heading immediately followed by a bare `$ARGUMENTS` line), not merely a bare line buried anywhere in the body. Fails on pre-fix `main` (listing `init`, `config`), passes after the fix. Auto-discovered by `tests/run-tests.sh`

## [1.3.2] - 2026-06-04

### Fixed
- YOLO review-gate livelock from a verdict verb-form mismatch: reviewer agents write `## Verdict: APPROVE`, but `_has_approved_verdict` in `scripts/lib/review-evidence.sh` only matched the past participle `approved`, so every fully-reviewed file read as `UNAPPROVED` and the stop hook reset all tasks `DONE → IMPLEMENTED` every iteration (burning the full `--max` budget after a false `NAZGUL_COMPLETE`). The matcher now accepts `APPROVE`/`APPROVES`/`APPROVED` while keeping anchoring and a word boundary so `approval denied` and the `approved` substring in `UNAPPROVED` don't false-match
- Reviewer template (`agents/templates/reviewer-base.md`) now requires exactly one verbatim verdict line with the canonical token and explicitly forbids the imperative `APPROVE`, preventing recurrence

## [1.3.1] - 2026-06-04

### Fixed
- `/nazgul:start` now resets loop counters (`current_iteration`, `safety.consecutive_failures`, `safety._prev_done_count`) on every loop-starting path. Previously only the ACTIVE_LOOP/`--continue` resume paths reset `current_iteration` and nothing ever reset `consecutive_failures`, so starting a fresh objective (e.g. `/nazgul:start --yolo`) with stale counters at/over their caps silently bricked the loop — the Stop hook hit its max-iteration or consecutive-failure gate and exited 0 (allowed the stop) instead of re-dispatching, despite READY tasks
- Restored four README-linked docs (`docs/ARCHITECTURE.md`, `CONFIGURATION.md`, `SAFETY.md`, `PLUGINS.md`) deleted in the Hydra→Nazgul rebrand, rebranded and fact-checked against the current codebase — the README "Learn More" links no longer 404

## [1.3.0] - 2026-06-03

### Fixed
- YOLO loop livelock: tasks could never reach DONE when review verdicts were written to a consolidated `summary.md` instead of per-reviewer files — the state guard and stop hook silently fought every transition forever
- Stop hook review-gate resets are now diagnostic: the continue message and JSON reason name the exact missing/unapproved reviewers and the repair command (previously stderr-only, never surfaced)
- Evidence validation logic deduplicated into `scripts/lib/review-evidence.sh` — `task-state-guard.sh` and `stop-hook.sh` had already drifted (`simplify-report.md` exclusion differed)
- Review Gate agent now verifies every configured reviewer wrote its file before aggregating verdicts (Step 2.5), and re-reads task manifests from disk before emitting NAZGUL_COMPLETE
- `/nazgul:start` OBJECTIVE_COMPLETE state and Rule 10 require disk verification before any completion claim
- BLOCKED was a dead-end in the state guard's transition matrix — `BLOCKED → READY` (unblock) and `BLOCKED → IN_REVIEW` (materialize, review directory required) are now legal exits

### Added
- `/nazgul:review --materialize [TASK-ID | --all]` — repair command that re-runs the full reviewer board for tasks stuck without per-reviewer evidence, reconstructing `diff.patch` from manifest commit SHAs when missing
- Livelock breaker: a second consecutive review-gate reset for the same task escalates to BLOCKED with a remediation note instead of looping (reset counts in `config.json` `.safety._review_reset_counts`)
- `tests/test-review-evidence.sh` — unit tests for the shared validation library, including the summary.md-only regression case

## [1.2.2] - 2026-04-16

### Fixed
- `/nazgul:bootstrap-project` no longer asks "what are you building?" on brownfield projects — the codebase IS the spec, Discovery derives everything automatically
- `detect_project_type()` uses `-prune` instead of `! -path` filters, avoiding slow traversals into `node_modules/`, `vendor/`, etc.
- `--yes` flag now correctly aborts on greenfield projects with no objective instead of blocking on interactive prompts
- Skill frontmatter `metadata.version` synced to plugin version across all 21 SKILL.md files (was stuck at 1.0.0/1.1.0)

### Added
- `detect_project_type()` in `bootstrap-preflight.sh` — counts source files to classify brownfield (>= 5) vs greenfield
- Three-tier objective collection in bootstrap Phase 2: explicit argument > brownfield auto-derive > greenfield interactive
- 5 new test cases for `detect_project_type` (empty dir, below threshold, at threshold, excluded dirs pruned, config-only files)

## [1.2.1] - 2026-04-14

### Fixed
- Pre-load `AskUserQuestion` via `ToolSearch` in all interactive skills (was failing when the deferred tool hadn't been loaded yet)

## [1.2.0] - 2026-04-14

### Added
- Per-stage model routing — configure which AI model (Opus, Sonnet, Haiku) runs each pipeline stage
- New `/nazgul:config` skill — view and change settings (models, formatter, notifications) after init
- Model presets: Balanced (default), Quality, Fast/cheap
- Per-stage customization via interactive `AskUserQuestion` prompts
- Model configuration step in `/nazgul:init` Step 7
- Generated reviewer and specialist agents now include `model:` in frontmatter
- Unit tests for model routing config and skill wiring

### Changed
- Default model assignments updated to balanced preset (Opus for planning, Sonnet for implementation/review, Haiku for post-loop)

## [1.1.0] - 2026-04-14

### Added
- Interactive selectable prompts via `AskUserQuestion` across 6 skills (init, bootstrap-project, clean, reset, gen-spec, board)

## [1.0.0] - 2026-04-14

### Added
- Initial public release as Nazgul (renamed from Hydra)
- 17 core agents (discovery, planner, implementer, review-gate, and more)
- 20 skills (`/nazgul:init`, `/nazgul:start`, `/nazgul:status`, etc.)
- Review board with unanimous approval requirement
- Fix-first review (auto-fix mechanical issues, ask about risky changes)
- Recovery system (checkpoints, recovery pointers, session tracking)
- Agent Teams support for parallel task execution
- Bootstrap-project for portable Nazgul-free bundles
- `marketplace.json` for Orodruin Labs plugin marketplace distribution
- New logo assets (dark/light theme, transparent backgrounds)
- Modernized README install instructions (marketplace, direct install, manual clone)
- 24 unit/integration tests + E2E test suite
- CI pipelines (test, E2E, skill-docs freshness)
