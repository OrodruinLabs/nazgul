# Changelog

All notable changes to this project will be documented in this file.

## [2.19.0] - 2026-07-23

FEAT-015, the second repair wave from the FEAT-013 360 reliability audit — guard integrity and
enforcement. Sixteen commits (`6a8e9d0`..`2b685fa`).

### Added
- **`scripts/lib/task-transition-guard.sh`**: `valid_transition()`, the commit-SHA gate, and the
  review-evidence check extracted out of `task-state-guard.sh` into a reusable library, callable
  from both the PreToolUse path and a new stop-hook-time reconciliation pass (MF-022,
  ADR-003 Decision 2). At the top of every `stop-hook.sh` iteration, each task manifest's live
  status is diffed against the last checkpointed status; any change that didn't pass through the
  shared transition-guard library since the last checkpoint is flagged `BLOCKED` with a named
  diagnostic instead of silently trusted — closing the Bash-write forgery bypass. Gated by
  `guards.bash_write_reconciliation` (default `true`).
- **Config schema v27 → v28** (`migrate_27_to_28`): two additive kill-switch keys —
  `guards.bash_write_reconciliation` (default `true`) and
  `automation.heartbeat.lock_stale_seconds` (default `300`) — following the existing
  additive-merge-with-explicit-value-preservation convention.
- **Real commit-SHA evidence gate** (MF-026): the IMPLEMENTED transition now verifies the manifest's
  `## Commits` SHA actually exists in the repo instead of trusting an unchecked string.
- **Heartbeat atomic claim** (MF-039): `heartbeat.sh` now `mkdir`s an atomic lock directory as its
  first action, so two concurrent ticks race on the `mkdir` itself instead of a stale `ls` read;
  released via `trap ... EXIT`.

### Fixed
- **Git-hooks lifecycle activation + worktree cwd-safety** (MF-034, MF-035): `skills/start/SKILL.md`'s
  five inline branch-setup prose blocks now call the existing `create_feature_branch` /
  `cleanup_all_worktrees` library functions, which already install/uninstall the managed
  `core.hooksPath` guards durably — closing both the dead-activation gap and the worktree-cwd merge
  escape it created.
- **Three dead guards revived**: `scripts/lib/task-utils.sh`'s new shared `get_task_files_modified()`
  accessor (MF-025) replaces three independent ad hoc comma-split `Files modified` parsers across
  `task-state-guard.sh`'s File Scope check, `parallel-batch.sh`'s disjoint-scope check, and
  `parallel-rework-guard.sh`'s `_scope_has()` — all three now correctly match bracket/quote-laden
  JSON arrays. `scripts/prompt-guard.sh` (MF-023) now reads the real `UserPromptSubmit` stdin JSON
  envelope instead of an env var Claude Code never sets in production.
- **Guard precision** (MF-027, MF-028): `pre-tool-guard.sh`'s `rm -rf` root/home patterns are now
  anchored so legitimate absolute-path deletions (`rm -rf /tmp/build-cache`) are allowed while
  `rm -rf /`, `rm -rf ~`, `rm -rf $HOME` stay blocked; the force-push check now ANDs two independent
  boolean conditions instead of two ordered regexes, so `git push origin main --force` and
  `git push origin main -f` are blocked alongside the previously-covered forms.
- **Parallel guards fail closed** (MF-053, ADR-003 Decision 3): `parallel-dispatch-guard.sh` and
  `parallel-rework-guard.sh` now distinguish "config missing" (safe no-op) from "config present but
  unparseable" (fail closed with a loud diagnostic), replacing a silent `jq ... || echo "false"`
  fallback that no-opped the guard on a torn/corrupt write.
- **Wave Groups parsing** (MF-040): `parallel-batch.sh` now parses each `### Wave N` heading plus
  all following `- TASK-NNN` bullets in any format (one-per-line or comma-grouped) instead of
  requiring same-line comma-grouped bullets, which previously silently degraded a one-bullet-per-task
  plan to fully sequential dispatch.
- **Connector push local-id threading** (MF-038): `connector_github_pull_archive` now threads the
  picked issue number through to a real local id via `heartbeat.sh`'s archive-then-start flow
  (bounded poll of `nazgul/config.json → feat_id`), so `_cgh_map_resolve` can match and
  `push_status`/`push_pr` are no longer unconditional no-ops.

## [2.18.0] - 2026-07-22

FEAT-014, the first repair wave from the FEAT-013 360 reliability audit (63
verified findings). Seven commits (`c411880`..`2a4516d`).

### Added
- **Test-realism foundation** (MF-052, MF-055): `create_task_file()` now
  emits canonical frontmatter by default instead of the legacy shape, with
  `create_task_file_legacy()` preserved for tests that still need it.
  `tests/test-shellcheck.sh` globs every script instead of a fixed list,
  growing coverage from 64 to 105 checks. The realistic fixtures immediately
  surfaced a real production bug (see Fixed).
- **Telemetry-dark detection**: SessionStart now flags a stale `plan.md`
  Status Summary against recomputed task counts instead of trusting a
  number that could silently drift from reality (MF-060). Retired 4
  already-fixed backlog items found stale during the sweep (MF-062).

### Fixed
- **`stop-hook.sh`'s git-conflict handler silently never set tasks
  `BLOCKED`** on real frontmatter-shaped manifests — `set_task_status` was
  comparing against a literal `".*"` instead of doing a proper
  compare-and-swap against the current status. Found by the MF-052/MF-055
  fixtures; this was live in production against real task files.
- **Enum drift** (MF-001, MF-010, MF-063): `APPROVED` added to
  `VALID_STATUSES`/`VALID_VERDICTS`; `task-state-guard.sh` now derives its
  status list from `structured-state.sh` instead of hand-maintaining a
  duplicate, closing the drift vector that produced MF-001. Fixes the YOLO
  wedge and completion-unreachable bugs (MF-004, MF-005).
- **Recovery Pointer**: format-tolerant label matching plus a loud no-op
  warning so a mismatched format fails loudly instead of silently returning
  nothing against a live `plan.md` (MF-003).

### Changed
- **Counting consolidation**: one shared `count_tasks_and_find_active()`
  helper replaces four duplicated blocks across `stop-hook.sh`,
  `pre-compact.sh`, `post-compact.sh`, and `session-context.sh`, with a loud
  `INVALID` arm so an off-vocabulary status is diagnosed instead of silently
  dropped (MF-002, MF-009, MF-011).

## [2.17.3] - 2026-07-22

### Removed
- **Per-skill `metadata.version` fields (all 25 skills).** The "lockstep"
  was an illusion: only `start`/`status` were ever bumped, 23 skills were
  frozen at 2.7.1, and nothing — no script, test, or platform feature —
  reads the field. Removing it closes the drift class instead of syncing 25
  files on every release. `.claude-plugin/plugin.json` is the single
  version of record.

### Changed
- Release workflow title derivation: single `git/ref/tags` API call (was
  two) and first-line extraction via jq (was a `head -1` pipeline under
  `pipefail`).

## [2.17.2] - 2026-07-22

### Fixed
- **Release-on-tag workflow checkout failure**: `fetch-tags: true` (added on
  review advice, unverified) conflicts with checkout's trigger-ref mapping on
  tag-push events (`Cannot fetch both <sha> and refs/tags/<tag>`), which
  failed the v2.17.1 run before any step executed. Reverted to the default
  shallow checkout; the release title's tag-annotation subject is now read
  via the GitHub API (`git/ref/tags` → `git/tags`), removing every local-ref
  dependence. The v2.17.1 Release itself was backfilled manually.

## [2.17.1] - 2026-07-22

### Added
- **Release-on-tag workflow** (`.github/workflows/release.yml`): every pushed
  `v*` tag now mechanically gets a GitHub Release — notes extracted from the
  matching `CHANGELOG.md` section, title derived from the annotated tag
  subject when it follows the release convention. Idempotent (no-op when the
  Release already exists), so it composes with the release-manager agent's
  own step 10. Closes the third instance of Releases drifting from tags
  (v2.14.0/v2.15.0 backfilled late; v2.17.0 published only on request) —
  instructions weren't enforcement, now the tag push is the trigger.

## [2.17.0] - 2026-07-22

### Added
- **Teammate Report Contract (3 layers).** In Agent Teams mode a teammate's
  final text is delivered to no one, so teammates finished work then idled
  without reporting, forcing a manual nudge per agent. Now: every teammate
  dispatch ends with a Report Contract block naming an explicit report file
  (`templates/skill-partials/report-contract.md`); dispatchers register the
  expected deliverable in `nazgul/dispatch/<session-name>.json`; and a new
  `TeammateIdle` hook guard (`scripts/teammate-idle-guard.sh`) blocks a
  registered teammate from idling while its report file is missing — bounded
  (≤3 blocks then fail-open escalation), fail-open on unknown payloads, and
  kill-switchable via `execution.enforce.teammate_report_guard` (config
  schema v26 → v27, additive). Completion signal is now idle notification +
  report file on disk; SendMessage is coordination-only courtesy.
- Telemetry: every TeammateIdle payload is appended to
  `nazgul/logs/teammate-idle.jsonl` (ongoing payload-schema discovery).

### Changed
- `agents/team-orchestrator.md`: explicit dispatch-manifest lifecycle
  (manifest before spawn → contract block in prompt → idle+file = complete →
  teardown deletes manifests); "signal completion to the caller" vagueness
  removed.
- `scripts/stop-hook.sh` parallel-batch dispatch: carries the Report Contract
  instruction for teammate-dispatched implementers.
- RULES.md §3.9: corrected the stale claim that subagent dispatch cannot be
  pre-gated (the PreToolUse `Agent` matcher exists and is in use).

## [2.16.0] - 2026-07-21

### Removed
- **Conductor execution engine.** `agents/conductor.md`, its libraries
  (`scripts/lib/conductor-graph.sh`, `scripts/lib/conductor-gates.sh`,
  `scripts/lib/conductor-router.sh`), its guards (`scripts/conductor-dispatch-guard.sh`,
  `scripts/conductor-rework-guard.sh`), and their tests are deleted outright. `execution.engine`
  is removed from the config schema. See `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md`
  for the platform rationale: since Claude Code v2.1.198 subagents run in the background by
  default, nested `Agent` calls from inside a subagent do not block, and background-completion
  notifications are documented to re-engage only the main session — there is no documented
  mechanism giving a nested parent subagent a fresh turn when its children finish. That made the
  Conductor's own "wait for every dispatch to return" step stall at every wave boundary,
  post-commit review dispatch, and review tally.

### Added
- **`execution.parallel` batch dispatch in the sequential loop.** There is now one engine — the
  existing stop-hook loop — with an opt-in parallel-batch option computed deterministically by
  `compute_dispatch_batch` (`scripts/lib/parallel-batch.sh`, absorbing the wave-layering logic
  from the retired conductor libs). `/nazgul:start --parallel` enables it (composes with any mode
  flag, e.g. `--parallel --afk`); `--conductor` is now a deprecated alias that sets
  `execution.parallel: true` and prints a deprecation note. New keys: `execution.parallel` (bool,
  default `false`) and `execution.max_parallel` (int, default 3).
- **Config schema v25 → v26**, migrating conductor configs automatically: `execution.engine ==
  "conductor"` → `execution.parallel: true`; `conductor.max_parallel` → `execution.max_parallel`;
  `conductor.gates.approve_graph`/`approve_each_wave`/`approve_final_pr` → `execution.gates.
  approve_plan`/`approve_batch`/`approve_final_pr`; the `nazgul/conductor/` runtime directory
  (including `graph.json`) is deleted by the migration. In-flight conductor runs resume from task
  manifests via the ordinary loop — there is no separate graph state to recover.
- **Guards and the premerge git hook re-keyed to task manifests.** `scripts/parallel-dispatch-guard.sh`
  and `scripts/parallel-rework-guard.sh` replace the conductor dispatch/rework guards, keyed off
  task manifests instead of `graph.json`. `scripts/git-hooks/pre-merge-commit` now parses a task
  manifest's YAML frontmatter `status:` field first (falling back to the legacy `- **Status**:`
  line only when frontmatter is absent) — there is no conductor graph left to read a unit's status
  from.
- **`review_gate.granularity` gates parallel batching.** Batch dispatch only reviews per task when
  `review_gate.granularity` is `"task"`; the template default, `"group"`, stays fully sequential
  even with `execution.parallel: true` — a project opts into both independently.

## [2.15.0] - 2026-07-14

### Added
- **GitHub two-way connector (FEAT-012, ADR-001, RULES.md §16).** Completes component 4 of the loop-engineering roadmap: a real remote provider that both pulls work in and pushes results back out. `scripts/lib/connector-github.sh` implements the provider contract — `connector_github_pull_list` (open issues carrying the opt-in label, minus the already-handled set), `connector_github_pull_get` (issue → normalized `{title,body,priority,type}` JSON, byte-capped at `connectors.github.pull.max_body_bytes`, default 65536), `connector_github_pull_archive` (add the claimed label — the idempotent "I took this" signal), `connector_github_push_status` (reflect a local task/objective status onto the mapped issue as a single `nazgul-status:<status>` label), `connector_github_push_pr` (upsert one `<!-- nazgul-pr -->`-marked PR-link comment), and `connector_github_health` (gh-auth + rate-limit check). Both directions are **wired into the running loop** (FEAT-012 TASK-008): `scripts/heartbeat.sh` now consumes the `github` provider so labeled issues pull into the inbox and the heartbeat can auto-start them, and `scripts/stop-hook.sh` pushes task status (and the PR link when one exists) back to the mapped issue on a transition.
- **Generalized provider seam (file vs github).** `scripts/lib/inbox-provider.sh` routes `inbox_list`/`inbox_get`/`inbox_archive` to the GitHub connector when `automation.heartbeat.inbox.provider == "github"`, and keeps the local `file` provider behavior byte-identical otherwise. Linear/Slack are follow-on providers that slot in behind this same seam as sibling `connector-*.sh` — they are **not** shipped in this release.
- **Opt-in and default-off.** The connector is gated by `connectors.github.enabled` (default `false`); no existing project changes behavior until it is explicitly enabled. Push is separately gated by `connectors.github.push.enabled` (default `true`, but only active under the top-level `enabled`).
- **gh-auth-only security model.** Credentials come exclusively from `gh auth`/env — no token is ever written to `config.json` or logged. Remote issue title/body are treated as DATA (reach `jq` only via `--arg`/`--rawfile`, never `eval`'d), and a hostile body is bounded by `max_body_bytes`.
- **Failure degradation.** A failed pull (after retry) bumps `connectors.github.pull_failures`; at 5 consecutive failures the connector auto-disables (`enabled=false`) with a warning, and a good pull resets the counter to 0 — a network/auth/rate-limit fault degrades to a no-op tick, never a crashed hook or a stalled loop.
- **Config schema v24 → v25.** `migrate_24_to_25` (`scripts/migrate-config.sh`) additively adds `connectors.github.{enabled:false, pull.{label:"nazgul", claimed_label:"nazgul-claimed", max_body_bytes:65536}, push.{enabled:true}, pull_failures:0, map:{}}`. Additive (set only when absent); explicit values including `enabled:true`, `push.enabled:false`, and a populated `map` are preserved, and no credential key is ever added. The existing `automation.heartbeat.inbox.provider` key selects `"github"` — no new provider-selection key was needed.

## [2.14.0] - 2026-07-13

### Added
- **`UNVERIFIED` review verdict — role-aware, fail-closed (FEAT-011, ADR-001, RULES.md §3).** The shared Review Board gains a fourth verdict that separates "a reviewer could not assess the change" from "a reviewer reviewed and rejected it" (the `/deep-research` principle: a claim the verifier *could not check* is unverified, not refuted). `UNVERIFIED` is emitted either by a reviewer that self-reports it cannot assess (`agents/templates/reviewer-base.md`) or by the review-gate orchestrator as a token-stamped stub when a dispatched reviewer errors, times out, or returns unparseable text — instead of jumping straight to BLOCKED. It is added to `VALID_VERDICTS` (`scripts/lib/structured-state.sh`) and carries its own bounded counter: a terminal `UNVERIFIED` re-dispatches that one reviewer up to `review_gate.unverified_retries` (default 2) times and never increments the CHANGES_REQUESTED `retry_count`. After retries, resolution is **role-aware** (`agents/review-gate.md` Step 2.6): a critical reviewer (`review_gate.critical_reviewers`, default `["security-reviewer","architect-reviewer"]`) still `UNVERIFIED` escalates to BLOCKED (fail-closed); a non-critical reviewer becomes a non-blocking warning that satisfies the DONE gate only when `review_gate.allow_unverified_nonblocking` is `true` (default). The DONE-gate half is enforced in `scripts/lib/review-evidence.sh` (`_has_approved_verdict` treats `UNVERIFIED` as not-approved; `_re_is_authorized_unverified` admits a non-critical `UNVERIFIED` only under the toggle, falls back to the default critical list on a malformed/ambiguous config — fail closed, not open — and never admits `security-reviewer`). Each finalized `UNVERIFIED` emits a `reviewer_unverified` event.
- **Conductor `SECURITY_UNVERIFIED` hard-stop line (FEAT-011).** `_cgate_security_rejections` (`scripts/lib/conductor-gates.sh`) emits a distinct `SECURITY_UNVERIFIED` line (same unconditional halt as a security rejection) when the security reviewer's verdict is `UNVERIFIED`, so conductor logs separate "could not assess" from "rejected."
- **Bounded borderline adversarial cross-check (FEAT-011).** When `review_gate.adversarial_crosscheck` is `true` (default), a blocking finding whose confidence lands within `review_gate.adversarial_margin` (default 10) of `confidence_threshold` **and** is HIGH severity or on a security-relevant file gets exactly one fresh confirm-or-refute reviewer dispatched for that single finding (`agents/review-gate.md` Step 3); a refute at ≥ threshold downgrades it to a non-blocking CONCERN, otherwise it stays blocking. Bounded by `review_gate.adversarial_max` (default 3) cross-checks per review unit. Per FEAT-006 cost discipline this never re-reviews everything or runs a second board — worst-case added cost is `adversarial_max` single-finding dispatches, and it is a one-line opt-out.
- **Config schema v23 → v24.** `migrate_23_to_24` (`scripts/migrate-config.sh`) additively adds six `review_gate` keys — `unverified_retries` (2), `allow_unverified_nonblocking` (true), `critical_reviewers` (`["security-reviewer","architect-reviewer"]`), `adversarial_crosscheck` (true), `adversarial_margin` (10), `adversarial_max` (3). Additive (set only when absent); explicit values including `false` and a custom `critical_reviewers` list are preserved, keeping today's APPROVE/CHANGES_REQUESTED happy path byte-identical.

## [2.13.1] - 2026-07-10

### Fixed
- **Self-audit script invoked via a bare-relative path — silently never ran outside this repo.** `agents/self-audit.md` and the `stop-hook.sh` fallback hint now invoke `"${CLAUDE_PLUGIN_ROOT}/scripts/self-audit.sh"` instead of `scripts/self-audit.sh` — matching every other agent's plugin-script convention. The bare-relative path only worked when dogfooding in this repo; in a target project (local-mode install syncs only `agents/`) the script did not exist at that path, so the mining core's script-backed cost/perf signals silently never ran.
- **`_transcripts_dir()` transcript-cost resolution ignored `CLAUDE_CONFIG_DIR` and mis-encoded non-alphanumeric path characters.** `scripts/self-audit.sh` now derives the transcripts base from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and maps every non-`[A-Za-z0-9]` character (not just `/`) to `-`, matching Claude Code's own project-directory slug encoding (spaces included). Falls back to a basename glob match on residual encoding drift only when it resolves unambiguously to a single project dir (never arbitrarily picking one of several same-leaf matches), and still degrades to "cost unavailable" rather than failing the run or mining an unrelated project.
- **Fail-loud when `self_audit.enabled: true` but the resolved script is absent.** The self-audit agent now emits a visible warning instead of silently no-op'ing when its script path doesn't exist.
- **Conductor post-loop gate summaries now read from authoritative markers**, not from a subagent's prose return, so a gate that ran with only a best-effort sub-step degradation (e.g. self-audit's transcript cost mining) is no longer mis-reported as "did not run".

## [2.13.0] - 2026-07-10

### Added
- **Git-level enforcement of git-action guards (FEAT-010, ADR-001, RULES.md §15).** The base-branch commit guard and the H2 conductor pre-merge verdict guard move from `PreToolUse(Bash)` command-string parsing to real git hooks activated via `git config core.hooksPath` pointing at a plugin-managed directory (`nazgul/.githooks/`, per project). Two proven-non-convergent command-string guards — three review rounds each found new shell-expansion/wrapper bypasses — are replaced by hooks that run after the shell has fully resolved the command, closing the class of bypass entirely rather than patching another rule into a tokenizer.
- **`pre-commit` base-branch guard.** `scripts/git-hooks/pre-commit` blocks a commit on `branch.base` while `branch.feature` is set, resolving "current branch" from the repo the hook itself runs in — fixing the old guard's cwd false-positive (always resolved `$CLAUDE_PROJECT_DIR`'s branch) and its `git -C` false-negative.
- **`pre-merge-commit` H2 conductor verdict guard.** `scripts/git-hooks/pre-merge-commit` blocks `git merge --no-ff` of a Conductor unit whose `nazgul/conductor/graph.json` record lacks a `DONE` status + `APPROVE` verdict, identified via git's content-hash-keyed `GITHEAD_<sha>` environment variables (resistant to the `GIT_REFLOG_ACTION` spoof that defeated the earlier command-string design). Gated by the new `conductor.enforce.premerge_guard` (default `true`) and only active when `execution.engine == "conductor"`.
- **Generic chain-dispatcher preserves user hooks.** `scripts/git-hooks/_dispatch.sh` forwards argv/stdin/exit code to any hook that previously occupied `core.hooksPath`/`.git/hooks`; every other standard githooks(5) name ships as a pass-through shim, so pointing `core.hooksPath` at the managed dir never silently disables a user's own `commit-msg`, `pre-push`, etc.
- **Install/uninstall/self-heal lifecycle.** `scripts/lib/git-hooks.sh` installs the managed hooks inside `create_feature_branch`/`setup_worktree_dir` (`scripts/worktree-utils.sh`) at the moment `branch.feature` is assigned — durably recording the live `core.hooksPath` into the new `branch.prior_hooks_path` first — uninstalls and restores that recorded value at objective completion (`cleanup_all_worktrees`), and self-heals (re-asserts only on detected drift) from `scripts/session-context.sh`'s `SessionStart` block. Gated on the new `guards.git_hooks` toggle (default `true`).
- **Config schema v22 → v23.** `migrate_22_to_23` additively re-adds `conductor.enforce.premerge_guard` (default `true`), adds `branch.prior_hooks_path` (default `null`, the not-yet-recorded sentinel; empty string means recorded-and-was-unset), and adds `guards.git_hooks` (default `true`). Existing values are preserved.

### Removed
- **`scripts/base-branch-commit-guard.sh`.** The old command-string `PreToolUse(Bash)` guard and its `hooks/hooks.json` registration are deleted outright, fully superseded by the `pre-commit` git hook above — see ADR-001 for why it is not retained as a redundant advisory layer.

## [2.12.0] - 2026-07-10

### Added
- **Post-loop self-audit gate + durable improvements backlog (FEAT-009, ADR-001).** A new post-loop gate mines this objective's own signals — review rejections, retries, blocks, best-effort transcript token cost, and any first-party findings — and appends one structured entry per finding to a durable, append-only backlog at `nazgul/improvements.md` (path configurable via `self_audit.backlog_path`). `scripts/self-audit.sh` is the testable core (never fails the run — every source degrades to a no-op when absent); `agents/self-audit.md` is the delegated agent; `scripts/stop-hook.sh` blocks `NAZGUL_COMPLETE` until the agent writes an objective-scoped `nazgul/logs/.self-audited` marker, with a bounded ≤3-attempt backstop so it can never deadlock an unattended loop. Opt out with `self_audit.enabled: false`.
- **First-party finding-raise channel (FEAT-009, RULES.md §14).** `scripts/lib/raise-finding.sh` ships a sourceable `raise_finding <severity> <category> <title> <detail> [suggested_fix] [evidence]` helper that any Bash-capable sub-session (implementer, team-orchestrator, debugger, conductor) can call to surface an in-the-moment improvement candidate that survives it exiting — instead of silently working around an out-of-scope problem or inventing unplanned scope creep to fix it mid-task. Each call appends one JSON line to `nazgul/logs/findings.jsonl` (built data-only via `jq --arg`, embedded `\n`/`\r` neutralized before storage, `flock`-guarded when available); the file is ingested by the self-audit gate into the backlog. Reviewer sub-sessions stay read-only and note candidates in their returned review instead.
- **`models.conductor` config key (default `sonnet`).** Pins the Conductor's own model tier explicitly. `/nazgul:start` dispatches `agents/conductor.md` with `model: $(jq -r '.models.conductor // "sonnet"')`, so a Conductor run no longer silently inherits the launching session's tier.
- **`/nazgul:status` conductor-mode view.** When `execution.engine` is `conductor` and a `nazgul/conductor/graph.json` exists, `/nazgul:status` renders a Conductor Wave Progress block (current wave, next unit, per-unit verdicts) in place of the sequential Task Progress block; during the planning phase (no graph yet) it shows a one-line "no graph yet" note. All other status sections are unchanged.

### Changed
- **`models.review` split into `models.review_orchestrator` / `models.review_default`.** The single review tier is now two keys: `review_orchestrator` (the review-gate/conductor orchestrator tier) and `review_default` (the default per-reviewer tier for the mechanical code/qa reviewers). Both resolve with the exact fallback chain **new key → legacy `models.review` → hardcoded** (`sonnet` for the orchestrator, `haiku` for the default reviewer), so existing configs that still carry only `models.review` are honored unchanged. `models.review_by_reviewer` still pins `security-reviewer`/`architect-reviewer` to `sonnet` on top of this.
- **Conductor-owned per-unit fan-out for parallel mutating waves (FEAT-009 H1, ADR-004).** `route_backend`/`route_wave` (`scripts/lib/conductor-router.sh`) now resolve a Planner-marked, zero-overlap parallel mutating batch to the `subagent` backend: the Conductor dispatches each unit as its own concurrent Agent-tool implementer call in one message and waits for all to return, rather than routing the batch to `team-orchestrator` (which has no `Agent`/`Task` tool and silently serialized the wave). A lone mutating unit still routes to `worktree`; reviews always route to `subagent`. The `team` backend is retained only for a currently-unused `coordination`-isolation batch — it is deprecated from the mutating-batch routing path. This also closes the documented "Layer 1 vs. Layer 4" limitation in RULES.md §12.
- **Conductor re-work guard exempts the current task's own scope (FEAT-009 H3, ADR-006).** `scripts/conductor-rework-guard.sh` no longer blocks the actively-dispatched unit from writing inside its own `file_scope`; it still blocks writes into the scope of a *different* unit already committed in `graph.json`. This removes a false-positive that could stall an in-flight unit whose own files overlap the guard's cross-cutting check.
- **Hygiene bundle.** Stale conductor markers (`nazgul/conductor/.session`, `.resume-needed`) now self-heal on a fresh start rather than wedging a new run; starting a new plan archives the prior objective's `nazgul/tasks/` instead of leaving them to bleed into the new objective; and CLAUDE.md's command-form references and a stale migration-name reference were corrected.
- **Config schema v21 → v22.** `migrate_21_to_22` additively adds `models.conductor` (`sonnet`), splits `models.review` into `models.review_orchestrator`/`models.review_default` (seeded from an existing `models.review` when present, else `sonnet`/`haiku`; `models.review` itself is left untouched as the fallback), and adds the `self_audit.{enabled: true, backlog_path: "nazgul/improvements.md"}` block. Existing values are preserved.

### Deferred to FEAT-010
- **H2 — conductor pre-merge review-verdict guard.** A mechanical PreToolUse guard blocking a Conductor `git merge` unless the unit has a recorded `DONE` + `APPROVE` verdict (ADR-005) was reverted; its guard script, `hooks.json` registration, and the `conductor.enforce.premerge_guard` config key are NOT shipped in this release.
- **Base-branch-commit-guard cwd fix (TASK-004).** The fix for the guard's working-directory bug was reverted; the guard remains at its v2.11.0 baseline.

Both were deferred because parsing the `git merge`/`git commit` command string to infer intent proved to be an open-ended command-parsing arms race (multiple bypass classes found across review rounds); the fix belongs at a git-level enforcement layer rather than a hand-rolled tokenizer, and is tracked under "[FEAT-010] git-level enforcement" in `nazgul/improvements.md`.

## [2.11.0] - 2026-07-09

### Added
- **Opt-in Automation Heartbeat (FEAT-008).** A default-off (`automation.heartbeat.enabled: false`), trigger-agnostic tick engine (`scripts/heartbeat.sh`) lets Nazgul pick up unattended work between sessions. It is fired by hand via `/nazgul:heartbeat` (`skills/heartbeat/SKILL.md`) or by an opt-in Claude Code native scheduled agent configured outside the plugin — the heartbeat is never wired to any hook, and running it is a no-op change to the sequential or Conductor execution paths.
- **Inbox-provider seam.** `scripts/lib/inbox-provider.sh` ships a file provider (`nazgul/inbox/*.md|json`, archived on claim to `nazgul/inbox/archive/`) behind a seam a future GitHub/Linear provider can drop into without touching the tick engine; those real connectors are deferred to FEAT-009.
- **Deterministic triage.** `scripts/lib/heartbeat-triage.sh` picks one objective (or reports "nothing actionable") from the inbox candidates using `jq` only — no `eval` is run over inbox or objective text at any point in the pipeline.
- **Session-guarded, hardened auto-start.** When `count_active_sessions` (`scripts/lib/session-tracker.sh`) reports no active session, the heartbeat starts the picked objective via `/nazgul:start`, with the mode/engine flags (`--yolo`/`--afk`/`--hitl`, `--conductor` or omitted) taken from `automation.heartbeat.auto_start.{mode,engine}` — `--yolo --conductor` by default; otherwise it logs a no-op rather than colliding with a running loop. The auto-start objective is truncated to its first line and has embedded `"`/`\n`/`\r` neutralized before being spliced into the `claude -p` command, closing both a quote-breakout and a newline flag-injection vector (`tests/test-heartbeat-start-injection.sh`).
- **Two unconditional hard stops carried over to heartbeat mode.** Any `BLOCKED` task or any security rejection halts the tick regardless of `enabled` or `mode` (including yolo), reusing the same `conductor_should_halt` (`scripts/lib/conductor-gates.sh`) the Conductor engine already enforces.
- **Atomic, idempotent consumption.** Inbox items are claimed via `mv -f` into `nazgul/inbox/archive/` before start, so a crash mid-tick can't double-process a candidate (`tests/test-heartbeat-idempotency.sh`).
- **Auditable decision records.** Every tick writes one JSON line to `nazgul/logs/heartbeat-*.jsonl` (one file per UTC day), surfaced via `/nazgul:log` (`skills/log/SKILL.md`).
- **Config schema v20 → v21.** `migrate_20_to_21` adds `automation.heartbeat` additively: `enabled` (default `false`), `interval` (`"30m"`), `inbox.{provider,dir}` (`"file"`, `"nazgul/inbox"`), `auto_start.{mode,engine}` (`"yolo"`, `"conductor"`) — existing values preserved.
- **RULES.md gained an Automation Heartbeat section** documenting the tick lifecycle, the hardened auto-start sink, and the honest tier of each control (session guard and hard stops are `[enforced]`; interval scheduling itself is `[advisory]`, left to the external trigger).

Real connectors (Linear/Slack/CI), two-way sync, the GitHub inbox provider, OS cron/`claude -p` scheduling, and any default-flip to "on" are deferred to FEAT-009.

## [2.10.1] - 2026-07-08

### Fixed
- **Conductor model-tiering gap.** `agents/conductor.md` never read `nazgul/config.json → models` before dispatching an `implementer` or `agents/review-gate.md` — every such dispatch silently inherited the Conductor's own model instead of the configured tier, so a Conductor run resolving to a non-default model (e.g. Opus) paid that tier for every implementer and review-gate orchestrator call, not just the Conductor itself. Individual reviewer dispatches were unaffected (`review-gate.md` already resolves `models.review`/`models.review_by_reviewer` per reviewer) and so was the `team` backend (`team-orchestrator` already reads `models.implementation`/`models.review` for its teammates). Added a "Model Selection" step to `agents/conductor.md`: resolves `models.implementation` (default `sonnet`) and `models.review` (default `sonnet`) once, and passes them explicitly as `model` on every `subagent`/`worktree`-backend implementer dispatch and every `review-gate.md` dispatch in Step 5. No schema change — both keys already existed in config.
- **Conductor rework-guard was inert.** `scripts/conductor-rework-guard.sh` (Layer 2) and `graph_wave_digest` (`scripts/lib/conductor-graph.sh`) both keyed their lookups on a `.commit_sha` field, but `graph_set_verdict` — the only code path that ever writes a commit into `graph.json` — writes `.commit`. Since `.commit_sha` never exists in a real graph, the rework guard's `OWNER` lookup always came back empty and it silently allowed every rework, and `graph_wave_digest`'s `sha` field was always `null`. Existing tests didn't catch this because their fixtures hand-constructed graphs using the same wrong `commit_sha` field name, self-consistently matching the bug instead of production reality. Fixed all three call sites to read `.commit`; updated `tests/test-conductor-rework-guard.sh`, `tests/test-conductor-dispatch-guard.sh`, and `tests/test-conductor-recovery.sh` fixtures to match the real schema (`scripts/lib/conductor-graph.sh`'s own header comment already documented `"commit"` as the correct field).
- **Conductor dispatch-guard false-block on `review-gate` for an `IMPLEMENTED` unit.** `scripts/conductor-dispatch-guard.sh`'s Rule 2 treated any work-unit dispatch (`implementer`, `review-gate`, `team-orchestrator`) against a unit already at `IMPLEMENTED`/`DONE` status as wasted re-dispatch and denied it — but dispatching `review-gate` for an `IMPLEMENTED` unit is the correct next step (Step 5.2), not a re-dispatch; only `DONE` (already reviewed) should deny a `review-gate` call. This mattered most on resume-after-interruption, where Self-Recovery can legitimately mirror a task's real `IMPLEMENTED` manifest status into `graph.json` before its review has run — the guard would have permanently blocked that unit's review. Rule 2 now denies `implementer`/`team-orchestrator` on `IMPLEMENTED`/`DONE` (unchanged) but only denies `review-gate` on `DONE`. Added dispatch-guard test coverage for both the newly-allowed and still-denied cases.

## [2.10.0] - 2026-07-08

### Added
- **Enforced Conductor — mechanical dispatch guards, closing the FEAT-007 double-dispatch/orphan gap.** FEAT-007's Conductor engine was a working driver whose correct dispatch behavior was prose in its own prompt; five layers now back one headline invariant, **"completed = cached, never re-executed"**:
  1. `scripts/conductor-dispatch-guard.sh` — new PreToolUse guard on the `Agent` tool — denies (exit 2) running a work-unit subagent (`implementer`, `review-gate`, `team-orchestrator`) in the background, and denies re-dispatching a unit whose `graph.json` status is already `IMPLEMENTED`/`DONE`, matched via the `NAZGUL_UNIT: TASK-NNN` marker `agents/conductor.md` now emits with every unit dispatch.
  2. `scripts/conductor-rework-guard.sh` — new PreToolUse guard on `Write|Edit|MultiEdit` — denies writing to a file inside a committed unit's `file_scope`.
  3. `scripts/subagent-stop.sh` gained conductor orphan detection: on every `SubagentStop` event it checks `graph.json` for units marked `dispatched` but not yet terminal, writing `nazgul/conductor/.resume-needed` and emitting `conductor_orphan_detected`.
  4. `scripts/lib/conductor-router.sh`'s `route_backend`/`route_wave` now route a Planner-marked, zero-overlap parallel wave to `team-orchestrator` instead of one bespoke worktree per unit, reusing the sequential engine's proven Agent-Teams path.
  5. `scripts/lib/conductor-graph.sh` gained `graph_wave_digest`, a cheap `{current_wave, next_unit, units}` orientation snapshot so the Conductor doesn't pay for a full wave recomputation every turn.

  Both guards are scoped to an active conductor session (`nazgul/conductor/.session`, written/removed by `agents/conductor.md`) and no-op outside it — a stray Nazgul agent or a sequential-engine run is never touched. RULES.md gained a new §12 "Conductor Enforcement" documenting the honest tier for each layer: guards 1-2 are `[enforced]`, orphan detection and team routing are `[hook-driven only]`, the wave digest stays `[advisory]`. The two unconditional hard stops (any `BLOCKED` task, any security rejection) are unchanged and sit underneath all five layers.
- **Config schema v19 → v20.** `migrate_19_to_20` adds `conductor.enforce.{dispatch_guard,rework_guard}` (both default `true`) additively — an explicit kill-switch for either guard, existing values preserved.
- **`docs/loop-engineering.md`** gained a "Mechanical enforcement" section describing the five layers, plus a subsection contrasting Nazgul's durable Conductor with Claude Code's native dynamic Workflow runtime: Workflows are the right tool for one-off, single-session fan-outs (audits, migrations, `/deep-research`-style research), but the Conductor isn't built on them — plugins can't ship a `workflows/` directory, Workflows don't survive a session exit (breaking Nazgul's cross-session recovery), there's no mid-run human input for HITL gates, and the `Workflow` tool is main-session-only (the Conductor is itself a subagent). A "Review Board robustness" follow-up — treating a reviewer's unverified assessment as distinct from a rejection, plus adversarial cross-checking — is noted as deferred future work, not implemented in this release.

## [2.9.0] - 2026-07-08

### Added
- **Opt-in conductor execution engine (FEAT-007).** A new graph-only driver agent (`agents/conductor.md`) offers an alternative to the sequential stop-hook loop for objectives whose plan has independent waves: it reads `nazgul/plan.md`'s dependency graph, computes waves via `scripts/lib/conductor-graph.sh`, and dispatches each wave's tasks through the existing Implementer → Review Board pipeline — no new reviewer logic, and the conductor + its libs never read file bodies or diffs, only paths, scope, one-line verdicts, and commit SHAs (the graph-only invariant, mechanically validated). State lives in `nazgul/conductor/graph.json`, is self-recovering across restarts, and falls back to the checkpoint if the graph file is missing or invalid.
- **`conductor.gates` — autonomous-first, opt-in approval checkpoints, plus two unconditional hard stops.** `conductor.gates.{approve_graph,approve_each_wave,approve_final_pr}` (all default `false`) let a human pause the conductor before dispatch, before each wave, or before the final PR; `scripts/lib/conductor-gates.sh` evaluates them. Independent of any gate setting or `mode` (including `yolo`), the conductor always halts for a human on a `BLOCKED` task or a security rejection — the same two hard stops the sequential engine enforces, now covered under conductor mode too.
- **`conductor.max_parallel`** (default `3`) caps how many tasks in a wave the conductor dispatches concurrently, evaluated by `scripts/lib/conductor-router.sh`, which also selects the dispatch backend (subagent, Agent Team, or worktree) per task.
- **`/nazgul:start --conductor`** opts a run into the new engine. It sets `execution.engine: "conductor"` orthogonally to `--afk`/`--hitl`/`--yolo` (composable, no interaction with `set_mode`) and is a pure no-op when omitted — `execution.engine` stays `"sequential"`, the existing default. `skills/start/SKILL.md` gained an "Engine Selection" section plus a dispatch gate at each of the four resume states.
- **`docs/loop-engineering.md`** documents the conductor architecture: graph model, wave computation, gates, hard stops, and recovery.
- **Config schema v18 → v19.** `migrate_18_to_19` adds `execution.engine` (default `"sequential"`) and `conductor.gates.{approve_graph,approve_each_wave,approve_final_pr}` (default `false`) and `conductor.max_parallel` (default `3`) additively.

Sequential remains the default engine — zero behavior change for existing runs; no task in this objective edited `scripts/stop-hook.sh` or other sequential-path code.

### Fixed
- **`task-state-guard.sh` multi-line `old_string` (macOS/BSD awk).** The guard reconstructed an Edit's `old_string` via `awk -v old=...`, which throws `awk: newline in string` on BSD awk whenever the value spans multiple lines (e.g. the `---`/`status:`/`---` frontmatter block) — silently no-opping the state-transition check. It now passes the value via `ENVIRON[...]`, portable on GNU and BSD awk; validation semantics are unchanged.
- **Transient-artifact hygiene on new plans.** `/nazgul:plan` previously proceeded past a *completed* prior objective without clearing its `nazgul/reviews/` and `nazgul/learning/proposed-rules.md`, so a new objective could read the prior one's review verdicts and learner proposals as current. A new `scripts/scrub-stale-review-artifacts.sh` (archive-then-clear, `mv`-only, guarded to no-op while any task is active, `feat_id` path-sanitized) is now invoked by `/nazgul:plan` before task generation, and the learner overwrites (never appends) `proposed-rules.md` scoped to the current objective.

## [2.8.0] - 2026-07-07

### Added
- **Review provenance — diff-bound tamper-evidence for the DONE gate (FEAT-006, Gap A).** The only mechanical DONE gate (`validate_review_evidence`) checked the SHAPE of reviewer files, not whether they came from the review board or were run against the current diff. `review-gate` now writes a per-unit dispatch manifest (`nazgul/reviews/<unit>/.dispatch.json`, `write_dispatch_manifest` in `scripts/lib/review-provenance.sh`) BEFORE spawning reviewers — capturing a nonce, a `diff.patch` hash, and a review token — and **stamps** the matching `review_token:` into the frontmatter it authors when it persists each read-only reviewer's return (the reviewer never echoes its own token). A new `validate_review_provenance` (`scripts/lib/review-provenance.sh`, wired into `scripts/stop-hook.sh`) blocks completion when a review has no matching dispatch manifest, or when the manifest's `diff_hash` no longer matches HEAD (`DIFF_HASH_STALE`) — routed through the existing bounded reset→`IMPLEMENTED`→`BLOCKED` escalation. **Honest tier: tamper-evidence + staleness detection, not authentication** — the verifier and the orchestrator share the filesystem, so its value is catching accidental cases (board skipped, code changed after approval), not adversarial forgery. Default-on (`review_gate.require_provenance`), degrades to allow for legacy no-token reviews.
- **`comment-verifier` — inline doc-comment quality gate (FEAT-006, Gap B).** No gate previously inspected inline source doc-comments (XML `<summary>`, JSDoc, docstrings); reviewers could only flag them as sub-80 non-blocking concerns. A new language-generic `agents/comment-verifier.md` post-loop agent grades doc-comments changed this objective for templated, restatement, and contradiction defects and writes an objective-scoped completion marker; `scripts/stop-hook.sh` now blocks `NAZGUL_COMPLETE` until that marker matches (mirroring the FEAT-004 `doc-verifier` gate). Default-on (`docs.verify_comments`), bounded to 3 attempts, degrades to allow.
- **Diff-aware conditional reviewer dispatch, opt-in (FEAT-006, Gap C, Lever 3).** A new deterministic `scripts/lib/reviewer-selection.sh select` picks reviewers by changed-file scope instead of always running the full board: `security-reviewer` always runs; `architect-reviewer` only when the scope touches `skills/`, `agents/`, `scripts/`, `hooks/`, or the config schema; `qa-reviewer` only when `tests/` changed; `code-reviewer` on any non-doc change; any ambiguity falls back to the full board. `SKIPPED` is now a first-class verdict (`scripts/lib/structured-state.sh`); `review-gate` writes a `verdict: SKIPPED` stub with a reason for each skipped reviewer and emits `reviewer_skipped`, and `validate_review_evidence` treats an authorized SKIPPED stub as gate-satisfying while still hard-failing MISSING/UNAPPROVED. Gated behind `review_gate.conditional_dispatch` (default `false`, mirroring `simplify_before_review`).

### Changed
- **Review cost redesign (FEAT-006, Gap C, Levers 1-2).** Reviewers now receive `diff.patch` only by default — the blanket full-file-list grant in review-gate Step 2 is gone, and the code-reviewer's "read full files for any non-trivial change" override (`agents/templates/reviewer-domains.json`) is replaced by the disciplined rule in `agents/templates/reviewer-domains.json`: read a full file only when a hunk is truncated mid-function, never crawl the codebase, never re-run tests. The `learned-rules.sh select` injection is now capped (top-N by recurrence within a token budget) instead of unbounded. `models.review` now defaults to `haiku` for the mechanical reviewers (code, qa) — applied additively and only when still absent or at the old `sonnet` default; `security-reviewer` and `architect-reviewer` are pinned to `sonnet` via a new `models.review_by_reviewer` map read in review-gate Step 2.
- **`review_gate.require_all_approve` reclassified as informational.** It was already dead — no script reads it; the effective policy is the hard-coded "every non-skipped reviewer must APPROVE" loop in `scripts/lib/review-evidence.sh`. The key still documents that policy for humans but changing it has no effect.
- **Config schema v17 → v18.** `migrate_17_to_18` adds `review_gate.require_provenance` (default `true`), `review_gate.conditional_dispatch` (default `false`), `docs.verify_comments` (default `true`), and `models.review_by_reviewer` (`{"security-reviewer": "sonnet", "architect-reviewer": "sonnet"}`) additively — existing values are preserved.

## [2.7.1] - 2026-06-25

### Fixed
- **Guard precision — no more false-positive blocks on read-only commands and commit messages (FEAT-005).** The two Bash-matched PreToolUse guards matched command *substrings* instead of the real action, so legitimate commands were blocked:
  - `local-mode-tracking-guard.sh` blocked any command containing `git add`/`stage`/`commit` and the literal `nazgul/` anywhere — including a commit whose **message** mentioned `nazgul/`, a **multiline** message, or even a read-only command whose grep *pattern* contained those tokens. It now parses the actual git **pathspec** with a no-`eval` tokenizer (skipping the subcommand and the values of message flags like `-m`/`-F`) and blocks only when a real `nazgul/` path is being staged in local mode.
  - `pre-tool-guard.sh` blocked any command where `echo`/`printf` co-occurred with `Status` and a `nazgul/tasks/TASK-` path — even a read-only `echo …; grep nazgul/tasks/TASK-*.md`. It now blocks only on an actual redirect (`>`, `>>`, the noclobber-override `>|`/`>>|`, and the combined `&>`/`&>>`) writing **into** a task manifest.
  - The Write/Edit-matched guards (`task-state-guard.sh`, `lean-comments-guard.sh`) were audited and are structurally immune (they inspect the tool's JSON input, not command strings) — recorded in RULES.md.
  No safety regression: every genuine block still blocks (verified by retained + new BLOCK tests alongside the new ALLOW false-positive tests).
- **`pre-tool-guard.sh` now reads the command from the PreToolUse JSON envelope.** The echo/printf manifest-write check tokenized raw stdin — which in production is `{"tool_input":{"command":"…"}}` JSON, so the command sat inside JSON quotes and the check never fired outside the (raw-command) test harness. The guard now extracts `.tool_input.command` (falling back to raw input for the test path, matching `local-mode-tracking-guard.sh`), and a new JSON-envelope test locks in the production contract.
- **Both Bash-matched guards harden their no-`eval` tokenizers against realistic shell forms** (surfaced by PR review): compound commands (`;`, `&&`, `||`, `|`) and unquoted newlines reset per-segment state so a later segment can't be skipped; redirect targets are reconstructed from adjacent quoted+unquoted fragments (`> "nazgul/tasks/"TASK-001.md`) and resolved before the command word (leading redirects); git global options (`-C`, `-c`, `--work-tree=`, `-p`, …) and leading `VAR=value` env assignments are skipped before the subcommand; backslash-escaped quotes inside double-quoted spans don't desync quote state; and fd-numbered/combined redirects (`1>`, `2>`, `2>&1`, `>&2`, `&>`) are handled rather than mistaken for command separators or command words. Genuinely exotic forms (process substitution, `eval`, command substitution, nested subshells) remain out of scope by design and degrade to allow — the primary protection is `.gitignore` + the session-staging chokepoint.

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
