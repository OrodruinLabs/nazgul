# CLAUDE.md — Nazgul Framework Plugin

## What This Project Is

Nazgul is a Claude Code plugin that provides multi-agent autonomous development. This repo IS the installable plugin.

**Install:** `claude --plugin-dir /path/to/ai-nazgul-framework` or clone to `~/.claude/plugins/nazgul`.

## Directory Structure

```text
.claude-plugin/plugin.json           # Plugin manifest (must be at repo root)
RULES.md                             # Enforceable operating rules (consolidated)
skills/                              # User-facing commands (/nazgul:*)
│   ├── init/SKILL.md
│   ├── start/SKILL.md
│   ├── status/SKILL.md
│   ├── review/SKILL.md
│   ├── discover/SKILL.md
│   ├── context/SKILL.md
│   ├── simplify/SKILL.md
│   ├── docs/SKILL.md
│   ├── patch/SKILL.md
│   ├── verify/SKILL.md
│   ├── metrics/SKILL.md
│   ├── heartbeat/SKILL.md           # Opt-in automation-heartbeat tick (inbox triage + auto-start)
│   ├── doctor/SKILL.md              # Read-only environment preflight diagnostic (thirteen checks)
│   ├── complete/SKILL.md            # Close an objective merged outside the loop (host-verified merge evidence)
│   └── bootstrap-project/SKILL.md   # Emit portable Nazgul-free bundle (one-shot)
agents/                              # Subagent definitions
│   ├── discovery.md                 # Pipeline: scans codebase, classifies project
│   ├── doc-generator.md             # Pipeline: generates PRD, TRD, ADRs
│   ├── planner.md                   # Pipeline: decomposes objective into tasks
│   ├── implementer.md               # Pipeline: builds tasks, delegates to specialists
│   ├── review-gate.md               # Pipeline: orchestrates review board
│   ├── feedback-aggregator.md       # Pipeline: consolidates review feedback
│   ├── team-orchestrator.md         # Pipeline: reserved for a genuine multi-turn teammate need (named-teammate spawn paths retired, FEAT-026/ADR-017)
│   ├── designer.md                  # Specialist: design system, visual direction
│   ├── frontend-dev.md              # Specialist: UI component implementation
│   ├── mobile-dev.md                # Specialist: mobile platform implementation
│   ├── devops.md                    # Specialist: Docker, K8s, cloud configs
│   ├── cicd.md                      # Specialist: CI/CD pipeline generation
│   ├── db-migration.md              # Specialist: safe schema changes
│   ├── debugger.md                  # Specialist: investigation on repeated failures
│   ├── documentation.md             # Post-loop: README, API docs, changelog
│   ├── release-manager.md           # Post-loop: versioning, release notes
│   ├── observability.md             # Post-loop: logging, metrics, error tracking
│   ├── comment-verifier.md          # Post-loop: inline doc-comment quality gate
│   └── templates/                   # Reviewer base template + domain config
hooks/hooks.json                     # Hook configuration
scripts/                             # Shell scripts for hooks
│   ├── stop-hook.sh                 # Stop: loop engine, state machine, checkpoints
│   ├── task-transition.sh           # SOLE sanctioned status writer: transactional CAS transition + evidence-gated `repair` (ADR-020)
│   ├── close-objective.sh           # /nazgul:complete engine: host-verified merge closure of an objective merged outside the loop
│   ├── red-run.sh                   # Mechanized pre-change red-run capture + manifest evidence
│   ├── stamp-plan-objective.sh      # Binds nazgul/plan.md's frontmatter feat_id to config.feat_id (Planner-invoked; never automatic)
│   ├── pre-compact.sh               # PreCompact: checkpoint before compaction
│   ├── post-compact.sh              # PostCompact: re-inject state after compaction
│   ├── pre-tool-guard.sh            # PreToolUse: block destructive commands
│   ├── task-state-guard.sh          # PreToolUse: verify task state before edits
│   ├── local-mode-tracking-guard.sh # PreToolUse(Bash): block git add/stage/commit on nazgul/ in local install mode
│   ├── lean-comments-guard.sh       # PreToolUse(Write/Edit/MultiEdit): block comment bloat at write time
│   ├── parallel-dispatch-guard.sh   # PreToolUse(Agent): block re-dispatch of a completed parallel unit
│   ├── parallel-rework-guard.sh     # PreToolUse(Write/Edit): block re-editing a committed parallel unit's scope
│   ├── teammate-idle-guard.sh       # TeammateIdle: enforce the dispatched-teammate report contract
│   ├── prompt-guard.sh              # UserPromptSubmit: validate user prompts
│   ├── session-context.sh           # SessionStart: inject loop state + session tracking
│   ├── session-staging.sh           # SessionEnd: stage files for AFK safety
│   ├── formatter.sh                 # PostToolUse: auto-format after edits (opt-in)
│   ├── notify.sh                    # Stop: completion notifications
│   ├── stop-failure.sh              # StopFailure: record + alert on a turn ending via API error
│   ├── subagent-stop.sh             # SubagentStop: telemetry event per finished subagent
│   ├── webhook-forward.sh           # Stop/Compact: forward events to HTTP endpoints
│   ├── task-completed.sh            # TaskCompleted: update board, record metrics
│   ├── board-sync-github.sh         # GitHub Projects board sync
│   ├── migrate-config.sh            # Config schema migration (v1→v37)
│   ├── worktree-utils.sh            # Git worktree helper functions
│   ├── file-improvement-report.sh   # Self-improvement: write JSON reports
│   ├── gen-skill-docs.sh            # Skill template: resolve {{PARTIAL:name}}
│   ├── bootstrap-transform.sh       # bootstrap-project: Nazgul-token scrub pass
│   ├── heartbeat.sh                 # Opt-in automation-heartbeat tick engine (separate entry path)
│   ├── doctor.sh                    # Read-only preflight diagnostic (thirteen checks, never writes state)
│   ├── audit-agent-state-paths.sh   # Agent-roster runtime-state path audit (advisory; §15 entry point)
│   ├── git-hooks/                   # Templates installed into the managed core.hooksPath dir
│   │   ├── _dispatch.sh             # Chain-dispatcher: forwards to any pre-existing user hook
│   │   ├── pre-commit               # Git-level base-branch guard
│   │   └── pre-merge-commit         # Git-level H2 parallel-unit verdict guard
│   └── lib/                         # Shared libraries
│       ├── nazgul-root.sh           # Shared worktree-aware nazgul/ root resolver (FEAT-021/ADR-008)
│       ├── task-utils.sh            # Task status parsing (4 formats) + counting
│       ├── task-transition-guard.sh # Shared state-machine + evidence lib (task-transition + task-state-guard + stop-hook reconciliation); owns `ttg_apply_transition`, `ttg_dependency_satisfied`, the completed-transition ledger
│       ├── session-tracker.sh       # Concurrent session lock management
│       ├── team-teardown.sh         # Dead-session team sweep (crash-only backstop)
│       ├── bootstrap-scrub-map.sh   # bootstrap-project: scrub rules data
│       ├── bootstrap-render.sh      # bootstrap-project: prompt rendering + domain helpers
│       ├── bootstrap-preflight.sh   # bootstrap-project: pre-flight gate checks
│       ├── bootstrap-relocate.sh    # bootstrap-project: atomic staged relocation
│       ├── review-provenance.sh     # Diff-bound dispatch manifest + provenance validation
│       ├── review-file-class.sh     # SOLE classifier for a reviews/<unit>/*.md: seat / artifact / non-seat / superseded (shared by both DONE-gate validators)
│       ├── reviewer-selection.sh    # Deterministic diff-aware reviewer selection
│       ├── parallel-batch.sh        # execution.parallel: batch selection, gates, hard stops (stop-hook + heartbeat)
│       ├── inbox-provider.sh        # Heartbeat: work-inbox provider seam (list/get/archive), dispatches file vs github
│       ├── heartbeat-triage.sh      # Heartbeat: source-agnostic candidate selection policy
│       ├── connector-github.sh      # Connectors: two-way GitHub provider (pull issues in / push status + PR back)
│       ├── stack-utils.sh           # execution.stacking: sole writer of stack.layers[], only home of `gh stack`
│       ├── merge-provider.sh        # Merge-observation seam: host detect / PR state / health; named degradations, never git ancestry
│       └── git-hooks.sh             # Git hooks: install/uninstall/self-heal core.hooksPath lifecycle
templates/                           # Objective + document templates
│   ├── CLAUDE.md.template           # Injected into target projects by /nazgul:init
│   ├── feature.md / tdd.md / bugfix.md / refactor.md / greenfield.md / migration.md
│   ├── docs/                        # Document templates for doc-generator
│   └── skill-partials/              # Shared partials for SKILL.md templates
│       ├── preamble.md              # Standard output formatting + recovery
│       └── recovery-protocol.md     # 4-step file-first recovery
references/                          # Shared reference docs for agents
│   ├── ui-brand.md                  # Visual identity and output formatting
│   ├── verification-patterns.md     # Stub detection and wiring verification
│   ├── fix-first-heuristic.md       # AUTO-FIX vs ASK classification rules
│   └── self-improvement.md          # Agent self-rating protocol
tests/                               # Plugin validation tests
│   ├── run-tests.sh                 # Test runner (116 unit/integration files); exit 2 = nothing checked
│   ├── test-*.sh                    # Unit/integration tests
│   ├── fixtures/                    # Provenance-declared goldens (tests/fixtures/*/PROVENANCE.md); no third-party subject matter
│   ├── lib/                         # Test assertions + setup helpers
│   ├── e2e/                         # E2E skill tests via claude -p
│   └── smoke/                       # Paid true-entry headless smoke in scratch projects
.github/workflows/                   # CI pipelines
│   ├── test.yml                     # Unit/integration tests on push/PR
│   ├── e2e-tests.yml                # E2E skill tests (manual trigger)
│   ├── e2e-stack.yml                # Two-layer gh-stack E2E against a live scratch repo (manual trigger)
│   ├── smoke.yml                    # Headless smoke (manual + nightly; ANTHROPIC_API_KEY)
│   └── skill-docs.yml               # Skill template freshness check on PR
```

## Build Rules

1. **Skills use YAML frontmatter.** Every skill in `skills/` is a SKILL.md with frontmatter: `name`, `description`, `allowed-tools`, and optionally `context: fork`, `disable-model-invocation: true`, `agent:`. Other supported optional fields per the Claude Code skills reference: `argument-hint`, `arguments`, `disallowed-tools`, `model`, `paths`. (`memory:` is NOT a supported skill field — it is silently ignored; the supported subagent field of that name does not apply to skills.)

2. **Agents use markdown with frontmatter.** Each agent in `agents/` has YAML frontmatter with `name`, `description`, `allowed-tools`, `maxTurns`, and a prompt body.

3. **Shell scripts must be POSIX-safe.** All scripts in `scripts/` should pass `bash -n` and `shellcheck`. They use `jq` for JSON manipulation.

4. **Runtime files are NOT part of the plugin.** The `nazgul/` directory (config.json, plan.md, tasks/, checkpoints/, etc.) is created per-project by `/nazgul:init`. This repo contains only the plugin code.

## Code Style

- Shell scripts: Use `set -euo pipefail`. Quote all variables. Use `jq` for JSON, not sed/grep. Two documented exceptions omit `-e`: sourced libs (`scripts/lib/*` — must not alter the caller's shell options) and fail-open observe-only hooks (e.g. `scripts/in-flight-marker.sh` — every path must fall through to an unconditional `exit 0` rather than abort); test harness files under `tests/` use `set -uo pipefail` so they can assert on nonzero exit codes from code under test.
- Markdown: Use ATX headers (`#`). Fenced code blocks with language tags.
- YAML frontmatter: Consistent indentation (2 spaces). Quote string values with special characters.
- File naming: kebab-case for all files. UPPERCASE for docs (CLAUDE.md, README.md).
- Git: The default branch is always `main`, never `master`. All agent and skill references to the default branch must use `main`.

## Key Concepts

**Files are memory, context is working memory.** Every piece of state lives on disk. The context window is ephemeral.

**Classify first, always.** Discovery classifies the project (greenfield/brownfield/refactor/bugfix/migration) to determine which agents spawn and which documents generate.

**Documents before code.** After classification, the Doc Generator creates PRDs, TRDs, ADRs before any planning happens.

**Conditional agent roster.** Discovery generates only the agents this project needs. 22 core agents exist as specs, plus a reviewer template that spawns project-specific reviewers. Only relevant ones are instantiated per-project.

**One engine, optional parallel dispatch.** The stop-hook loop is the only driver — there is no separate engine to opt into. `execution.parallel` (opt-in via `/nazgul:start --parallel`, default `false`) layers concurrent batch dispatch on top of the same sequential loop: when `review_gate.granularity` is `"task"` (the template default `"group"` stays sequential with aggregate reviews) and a wave in `nazgul/plan.md`'s `## Wave Groups` section has `>=2` READY tasks whose dependencies are all DONE and whose file scopes are disjoint, the stop-hook's `compute_dispatch_batch` (`scripts/lib/parallel-batch.sh`) dispatches them together instead of one at a time, reusing the same Review Board per task. Sequential and parallel dispatch share the same Planner output, task state machine, and review gate — the option only changes how many tasks start at once, not what "done" means.

**One-shot subagents for one-shot work.** Agent-Teams teammates idle forever unless the lead sends a `shutdown_request` — and naming an otherwise-plain `Agent` dispatch is enough to fold it into team infrastructure, even without an explicit team spawn. Nazgul's actual work (discovery, one review verdict, one task's implementation) is one-shot by definition, so FEAT-026/ADR-017 converted every such dispatch site to an unnamed one-shot `Agent` dispatch and deleted the teardown subsystem that used to remediate the resulting idling (`tt_detect_undismissed()`, the stop-hook's `TEAM TEARDOWN` gate, `teammate-idle-guard.sh`'s `"...then idle"` instruction) — a dispatch that never becomes a teammate has nothing to dismiss. SessionStart still sweeps team state left by a dead session as a crash-only backstop (`guards.team_sweep`), now with a current-session exclusion that actually fires (both by session id and by the session's implicit team-name form). See RULES.md §18 (One-Shot Dispatch Primacy & Dead-Session Team Sweep).

**Connectors are opt-in and default-off.** `scripts/lib/connector-github.sh` (FEAT-012) is a two-way GitHub connector behind the generalized provider seam (`scripts/lib/inbox-provider.sh`): it pulls opt-in-labeled issues into the inbox so the heartbeat auto-starts them, and pushes task status + PR links back to the mapped issue. It is enabled only when `connectors.github.enabled` is `true` and selected via `automation.heartbeat.inbox.provider: "github"` (the `file` provider is the default). Credentials come from `gh auth` only — no token is ever stored in config or logged — and remote issue content is treated as data. Linear/Slack are follow-on providers behind the same seam. See RULES.md §16.

**Stacking changes when work starts, never what "done" means.** An objective's end used to idle the loop: a PR opened to `main`, nothing to merge it, and no honest way to start the next objective. `execution.stacking` (FEAT-027/ADR-018, opt-in via `/nazgul:start --stack`, default `false`, schema v35) makes objective N+1 branch off objective N's unmerged tip and stack its PR on top. One objective is still one PR — the task state machine, review board, and per-objective release flow are untouched. GitHub owns every retarget/rebase/merge mechanic via the official `gh-stack` CLI extension (no hand-rolled `rebase --onto`, ever — two prior attempts in this repo failed to converge); Nazgul owns only the script-written `stack.layers[]` registry (`scripts/lib/stack-utils.sh` is its sole writer and the only home of `gh stack`) and the policy gates: a cap on unmerged layers (`max_unmerged`, default 3) that skips auto-start loudly with `stack_cap_reached`, and a `CHANGES_REQUESTED` review auto-filed as a p1 `stack-rework` inbox item (`rework_priority`, default 1) the heartbeat picks first. Every degradation is fail-closed and loud: unusable tooling still opens the ordinary PR but emits `stop_gate reason:stacking_unavailable`; a sync conflict halts stacking, files a p1 item, and emits `stack_sync_conflict` — never auto-resolved. Because gh-stack aborts a real divergence with exit **0**, the wrapper classifies its stderr rather than trusting exit codes. New event types: `stack_layer_merged`, `stack_rework_filed`, `stack_sync_conflict`, `stack_api_failure`, `stack_remote_layer_imported`, `stack_remote_layer_import_failed`. **One piece ships for ALL users regardless of the opt-in**: `create_feature_branch` now asserts the checked-out branch equals `branch.base` and refuses loudly otherwise, closing the accidental-stacking hazard (it used to take whatever was checked out as the base). See RULES.md §20.

**State machine is sacred.** Tasks follow: PLANNED -> READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE (or CHANGES_REQUESTED -> retry, or BLOCKED). No skipping states. `CANCELLED` is the second terminal status alongside `DONE` (FEAT-031/ADR-022): reachable from every non-terminal state, no out-edge, written through the same sole writer, and counted in its own bucket so `DONE + CANCELLED == TOTAL` completes the loop without a cancelled task passing for a shipped one — the honest boundary being that it is the one status with no evidence gate, because an unshippable task produces no artifact to gate on. Every transition is validated against one shared source of truth (`scripts/lib/task-transition-guard.sh`), used by `scripts/task-transition.sh` (the sole sanctioned writer, below), `task-state-guard.sh`'s live PreToolUse gate, and `stop-hook.sh`'s bash-write reconciliation pass — `PLANNED -> READY`'s dependency condition is granularity-aware through one shared `ttg_dependency_satisfied` (under `group`/`feature`, where every task parks at IMPLEMENTED until ONE aggregate board, a dependency at IMPLEMENTED or later satisfies it; `task` granularity still demands DONE/APPROVED), and the IMPLEMENTED gate additionally requires a commit SHA recorded inside the manifest's `## Commits` section (a hex token anywhere else — notably the `## Metadata` Base SHA every manifest carries at creation — is invisible to the gate) that resolves to a real, reachable commit (`git cat-file -e`) AND is a strict descendant of the manifest's own Base SHA (`git merge-base --is-ancestor`, equality rejected): forward progress, not mere existence. With no Base SHA in the manifest the gate degrades to existence-only and announces the skipped forward-progress check on stderr; a Base SHA present but unresolvable rejects the manifest as corrupt.

**A permitted write is not a completed write.** FEAT-029/ADR-020's thesis: a `PreToolUse` hook can validate a *proposed* status change but can never observe whether the tool call succeeded, so a cancelled or failed edit still left a ledger entry that reconciliation later accepted as authorization for an entirely different raw write. Authority moved to the completion side. `scripts/task-transition.sh` is now the SOLE sanctioned status writer: under a per-task lock it validates the live manifest, rechecks the source status immediately before an atomic rename, verifies the target on disk, and only then records the exact `FROM -> TO` edge — reconciliation matches a *chain* of completed edges, not a reusable endpoint pair. `task-state-guard.sh` remains preflight safety and cannot create authority. Honest boundary: the Write/Edit route is blocked mechanically, the Bash routes by the closed-but-not-exhaustive denylist in `RULES.md` §5; what makes an unsanctioned write ineffective is the compare-and-swap plus reconciliation, not the denylist. See RULES.md §2.

**Bash-mediated bypasses are detected, not just blocked — and quarantine is not a graph edge.** A status write through the Write/Edit/MultiEdit tools is gated live; one made outside that path (e.g. `mv`/`cp` over a manifest) is caught after the fact — `stop-hook.sh` diffs every task's live status against the last checkpoint at the top of each iteration and quarantines any change not traceable to a completed transition, never silently "corrected." The quarantine is a TYPED integrity annotation (`Blocked kind: reconciliation`, `Blocked from`, `Blocked observed`, plus a `reconciliation_quarantine` event), not a claim that `DONE -> BLOCKED` is a legal product-flow edge; recording both endpoints is what makes recovery possible. Its only exit is `scripts/task-transition.sh repair TASK-NNN`, which revalidates five independent facts (commit evidence, red-run evidence, review-directory path safety, review verdicts, review provenance) before taking `BLOCKED -> IN_REVIEW -> DONE` through the same transactional primitive — never `READY`, never an implementer redispatch, because the work was already reviewed. Six named refusal reasons, each on stderr and as a `reconciliation_repair` event. Kill-switched by `guards.bash_write_reconciliation` (default `true`, config schema v28).

**A subagent cannot change its own working directory, so address the directory explicitly.** `EnterWorktree`/`ExitWorktree` are host-session tools; a dispatched agent's cwd is fixed for its whole life, so an instruction to "enter a worktree" was never executable by the agent it was written for. FEAT-029/TASK-006 removed those grants and the prose that used them from every agent spec. The canonical pattern now: the CALLER creates the task worktree and passes `<task_worktree>` plus `<main_worktree_path>` in the dispatch brief; the agent verifies it with `git -C "<task_worktree>" rev-parse --show-toplevel` and STOPs rather than creating one — an unrequested branch or worktree is a finding, not a recovery. Every git command carries `-C`, every remaining `cd` is joined to the command it serves, file tools take absolute paths (task code under `<task_worktree>/`, the nazgul runtime under `<main_worktree_path>/nazgul/`), `red-run.sh` takes `--project-root=`, and `task-transition.sh` is invoked with an explicit `CLAUDE_PROJECT_DIR=`. The agent leaves the worktree on disk and reports it back; whoever created it removes it. The reviewer pattern is the sibling rule: unnamed one-shot `Agent` calls with `run_in_background: false` from the main session, verdicts returned as text and persisted by the orchestrator. `name` absence and explicit `run_in_background:false` are enforced by `scripts/parallel-dispatch-guard.sh`; a payload with NO `run_in_background` field is allowed with a `dispatch_guard_background_unverifiable` event, because on schemas without the field it is unsupplyable (#205). `tests/test-agent-worktree-contract.sh` scans the whole shipped roster, not the diff, so a future spec that re-adds either grant is caught wherever it lands.

**Runtime state is addressed, never inherited — and a write is not written until it is read back.** FEAT-030/ADR-021's thesis: *"I wrote it" and "it is there" were the same claim, and they are not any more.* Two populations reach `nazgul/`. Scripts RESOLVE it (the shared `nazgul-root.sh` resolver under `scripts/lib/`, unchanged — ADR-008 stands). Agents resolve nothing: a spec is a prompt whose `nazgul/...` strings a Bash tool runs in whatever tree the dispatch left it in, and a subagent cannot change its own cwd — so a relative state path is not a choice of tree, and every step of the wrong-tree write succeeds (`mkdir -p` creates the wrong tree's `nazgul/logs/`, the redirect exits 0, the agent's success report is honest, and the gate reads the real file and sees a stale value). Every `nazgul/` read and write in `agents/**` is now written `<main_worktree_path>/nazgul/...` from the caller's dispatch brief, falling back to `branch.main_worktree_path` and then STOPping — never cwd; `CLAUDE_PROJECT_DIR="<main_worktree_path>"` is the bridge to scripts, and a third mechanism was NOT invented because sourcing the resolver from a task worktree returns the *task worktree* (with `nazgul/` gitignored there is no `nazgul/config.json` marker to arbitrate with) — a visible relative path turned into an invisible confidently-wrong one. `NAZGUL_DIR="$(pwd)/nazgul"` is the same defect under another name, with two different failure modes: `emit-event.sh:21-22` returns 0 without writing when `NAZGUL_DIR` is UNSET, but when it is SET and names a tree with no initialised `nazgul/` it is worse — `:70-72` creates that tree's `logs/` and writes the event there, so the record lands where nobody reads it. Marker writers must now prove the write landed: validate the value, write, re-read the same absolute path, report the path and the persisted value, FAIL on mismatch. And the comment-verifier gate's three writers now leave three different values — the bare `feat_id`, `<feat_id>:NO-SOURCE-CHANGED`, `<feat_id>:EXHAUSTED` — plus an additive `gate_attribution` event naming `verifier-clean` / `degrade-to-allow` / `backstop-exhausted`, so a satisfied gate records WHO satisfied it. Enforcement scans the whole shipped roster, not the diff (`scripts/audit-agent-state-paths.sh` + `tests/test-agent-state-path-contract.sh`'s `F == 0` with a `K > 0` floor and a dogfooded predicate; `tests/test-gate-delegate-paths.sh`; `tests/test-marker-readback-contract.sh`, which runs each spec's own extracted recipe in a two-tree fixture). The honest boundary is stated in the tier itself: whether a dispatched model actually performs the read-back on its turn is `[advisory]` — a prompt contract cannot be enforced inside a model's turn. See RULES.md §21.

**Work that shipped elsewhere must be closable without lying about it — and work that will never ship must be sayable.** FEAT-031/ADR-022+ADR-023's thesis: the loop had exactly one route to `DONE` (a full review board) and no way at all to record "this will never ship", so an operator whose objective PR merged outside the loop, or who abandoned a task, was left with one honest-looking option — hand-editing `status:` in a manifest, which is precisely the forgery route ADR-020 closed. Two additive records replace the surgery. `CANCELLED` is operator-declared unshippable: terminal like `DONE`, reachable from every non-terminal state, no out-edge, written through the same sole writer, refused out of a typed `reconciliation` quarantine so cancelling cannot launder an integrity block, counted in its own bucket (`DONE + CANCELLED == TOTAL` completes the loop, reported as `N/M done, K cancelled`), and satisfying the dependency gate in every granularity — with the accepted cost, stated rather than discovered, that a downstream task which genuinely needed the cancelled work is auto-promoted anyway. **The quarantine refusal's residual is measured rather than asserted (#232): it reads one line in a file, and TWO shapes of write unlock it, not one.** Deleting the `- **Blocked kind**:` line leaves nothing to match; mutating its value past the end-of-line anchor (`reconciliation (repaired by hand)`, `reconciliation-quarantine`, `reconciliation.`) is admitted by the very anchor that stops an already-repaired kind from re-qualifying — one property, two consequences. Both shapes were executed against the shipped predicate: intact refused, both admitted, case variants and trailing whitespace still caught. `task-state-guard.sh` refuses both shapes on the Write/Edit route (it compares the three quarantine fields' values, not merely their presence) and `pre-tool-guard.sh` refuses the Bash writes its funnel recognizes, so what is open is a write neither observes, and the ceiling is `CANCELLED`, never `DONE`. `## Merge Evidence` (`host`, `pr`, `merged-at`, `merge-commit`, `head-ref`, `recorded-by` — six fields under that heading and nowhere else, a block short of any one of them refused as `truncated`) is what makes `IMPLEMENTED -> DONE` reachable at all, and `head-ref` is the one that asks WHOSE PR it is, so a block naming somebody else's genuinely merged PR is refused rather than honoured. For `IN_REVIEW -> DONE` it is an ALTERNATIVE to the review route, never a bypass: one of the two must validate and the accepted one is always named on stderr. The shape check is only the first half — the gate then asks the host through `merge_provider_pr_state` and admits the edge only on `result: "ok"` AND `merged: true`, with the manifest's `merged-at`/`merge-commit` matching the host's own, because a shape check on operator-writable text certifies whoever typed it; `unverifiable` (could not ask) is a named refusal distinct from `not_merged` (asked, and the answer was no), and an unreachable host never admits a closure. It carries **no kill switch** — a switch on the last gate before DONE would be the bypass. Merge state is read from the host's PR API through a three-function seam (`scripts/lib/merge-provider.sh`) where every unusable state has its own name (`unsupported_host`/`no_remote`/`provider_unavailable`/`api_failure`/`invalid_pr`/`repo_mismatch`/`unbindable_repo`) and `merged` is three-valued, so "the host says not merged" never collapses into "we could not ask"; **git ancestry is corroboration, never a predicate**, because after a server-side squash no recorded SHA reaches the merge commit and ancestry would report demonstrably shipped work as unshipped. `scripts/close-objective.sh` (`/nazgul:complete`) is the operator entry point and a CALLER of the sole writer, never a writer, enrolled in §15's registry of bound entry points. Aggregate review learns the same distinction: a `CANCELLED` task is carried out of a `group`/`feature` unit and the dispatch SAYS so (a `CARVE-OUT:` note plus an `aggregate_board_cancelled_carveout` event whose `cancelled_tasks` field carries the ids, alongside the `implemented / total` counts) — an excluded task is removed from the unit, never approved by it, and an all-cancelled unit dispatches no board at all, because an empty board is not a clean one. `BLOCKED` is deliberately not carried out: "needs human help" is not "will never ship". See RULES.md §2 (Cancellation, Merge Evidence), §3.15 (the carve-out record), and §16 (the seam).

**Messaging is an operator surface, never a loop mechanism.** Cross-session messaging (Claude Code ≥2.1.224) was evaluated end-to-end (six live probes, committed as `docs/superpowers/specs/2026-08-16-cross-session-messaging-platform-facts.md`) and adopted ONLY for operator steering, peer courtesy, and hardening — the loop's turn source remains `decision:"block"` on Stop plus the harness's documented background-dispatch resume. RULES §22: an unguaranteed channel may shorten a wait but may never authorize one; no shipped surface posts to the messaging socket (`tests/test-messaging-posture.sh`, §15-enrolled); Nazgul never writes inbound-posture settings keys. The same cycle made the in-flight hold class-aware (hold only provably-background dispatches; a PROVEN foreground or named dispatch quarantines as `in_flight_orphan`; an UNOBSERVABLE class is recorded as `in_flight_unverifiable` and LEFT IN PLACE, never quarantined — the move is irreversible, the dispatch may still be running, and destroying the marker would foreclose #218's own fix — #104 Gap 3). The hold's honest boundary ships with it: `run_in_background` is omitted from the exposed Agent schema under fork mode, so on that host class the hold never engages and every marker is recorded unverifiable and left in place; making the class observable rather than predicted is #218, deliberately out of this objective, made session locks session-lifetime with tree identity (#195), taught `/nazgul:clean` to restore `core.hooksPath`, and gave doctor messaging/remote-control/sessions checks.

**A guard that finds nothing must know why.** A lookup guard's allow path is "no candidate matched" — but "looked and found none" and "never actually looked" are different states, and collapsing them into the same allow reopens exactly what the guard exists to close. `pre-merge-commit`'s original exact-substring `## Commits` lookup treated a manifest recording a short SHA as no-candidate instead of candidate-present-but-invisible-to-this-comparison; `task-state-guard.sh` treated a readable `nazgul/config.json` with a missing `nazgul/tasks/` directory as "not a Nazgul project" instead of "IS a Nazgul project whose task state can't be read." Both guards now distinguish the two explicitly, deciding whether the ambiguous case allows or blocks by weighing what a false allow costs against what a false deny costs, per guard, rather than inheriting a prior guard's answer by proximity (RULES.md §15, ADR-009).

**A mechanism that fails must not look like a mechanism that had nothing to do.** The sibling thesis to the paragraph above, for the machinery that RUNS the loop rather than guards it: when a gate ends or short-circuits an autonomous run, or a check silently weakens, the record must show that a mechanism acted — a bare `exit 0` and a vacuously-satisfied gate are indistinguishable from "nothing happened." Three shipped instances (FEAT-023): a `date -j -f` probe that tested whether the command *succeeded* rather than whether it *parsed correctly*, so the AFK timeout gate skewed with the host timezone in both directions; that same safety gate ending an autonomous run with a bare `exit 0` — a gate-triggered stop now emits a `stop_gate` event (`reason`/`computed`/`limit`) before exiting; and an evidence gate satisfiable by the `## Metadata` Base SHA every manifest carries at creation — now scoped to `## Commits` and required to prove forward progress, with its one degradation path (no Base SHA) announced on stderr rather than taken silently (RULES.md §1 rules 2/8 and §5, ADR-013, ADR-014).

**A green test is evidence only after it proved it can turn red.** FEAT-028/ADR-019 makes that thesis mechanical: `scripts/red-run.sh` runs a task's changed tests against its pre-change Base SHA, and the same shared transition library that verifies commit evidence blocks IMPLEMENTED when required red-run evidence is missing or corrupt. Fixtures at load-bearing seams are captured from real producers, carry machine-checked provenance and mutation pins, guards are dogfooded on this shell-heavy repository's own language and real hook envelopes, and every checking entry point reports `scanned / skipped / checked / findings` so “looked and found none” cannot collapse into “never looked.” The registry of bound entry points lives in `RULES.md` §15 (fourteen entry points are bound: `scripts/self-audit.sh` enrolled by FEAT-029/TASK-012, `scripts/audit-agent-state-paths.sh` and `tests/test-dispatch-brief-contract.sh` by FEAT-030, `scripts/close-objective.sh` by FEAT-031/TASK-011, `tests/test-messaging-posture.sh` by FEAT-032/TASK-012, `tests/test-doc-contract-fields.sh` by FEAT-031/TASK-016, `scripts/lib/task-transition-guard.sh`'s red-run scans by FEAT-031/TASK-019, and the shared review-unit classifier `scripts/lib/review-file-class.sh` by FEAT-031/TASK-034, relocated there from `review-evidence.sh` by TASK-035 when the same rule and the same printf came to answer for BOTH of the DONE gate's passes — this sentence stood at `eleven` for two enrolments, so the number is now DERIVED from §15's own bullet by `tests/test-doc-contract-fields.sh` and a fifteenth enrolment turns this file red rather than leaving it quietly stale) and `tests/test-coverage-honesty.sh` fails if any enumerated one is never driven — it previously cited a per-objective TRD section that was archived out from under the citation. `guards.red_run_evidence` (schema v36, default `true`) suppresses the block only; the diagnostic and `red_run_missing` event remain.

**A dispatch that ends without a deliverable must not look like one that had nothing to say.** FEAT-024's instance: all four generated reviewers ran at a stale `maxTurns: 12` (`agents/templates/reviewer-base.md`, raised to 30) and stalled mid-tool-loop, before ever reaching a turn in which to compose a verdict — while `scripts/subagent-stop.sh` already computed the empty-handed signal (`[ -n "$final_text" ] || return 0`) and silently discarded it on every dispatch. It now emits `subagent_empty_return` for EVERY completing subagent, not just review-gate dispatches, on either an empty final turn (`empty_final_text`) or, for reviewers specifically, prose with no fenced `verdict:` line (`no_verdict_line`) — carrying `agent`/`unit`/`turns_used`/`max_turns` plus an `action` of `resumed`/`exhausted`/`detected_only`. A disposable `SubagentStop` exit-2 probe (direct dispatch, not Agent-Teams) proved the harness honors `{"decision":"block","reason":...}` on this hook exactly as it does on the main `Stop` event, so the fix ships as a bounded in-hook resume rather than a `stop-hook.sh` gate: up to 2 automatic re-prompts per dispatch, gated by `guards.subagent_resume` (disables the resume only — detection and the event still fire), never blocking twice on the harness's own `stop_hook_active` re-entry signal. Every resumed dispatch measured this objective delivered with near-zero further tool calls — judgment was already complete at stall time; the resume only grants the turn it was never given to state it. See RULES.md §19 (Subagent Non-Delivery & Bounded Resume).

**Review board is non-negotiable.** ALL reviewers must approve before a task can be DONE. Confidence scores below 80 become non-blocking warnings instead of rejections. A fourth `UNVERIFIED` verdict marks a review that genuinely could not run (reviewer errored/timed out, or self-reported it couldn't assess) — distinct from a rejection and bounded by its own `review_gate.unverified_retries` counter, not the CHANGES_REQUESTED `retry_count`. Its resolution is role-aware: a critical reviewer (`review_gate.critical_reviewers`, default security/architect) still `UNVERIFIED` after retries fails closed to BLOCKED; a non-critical one becomes a non-blocking warning under `review_gate.allow_unverified_nonblocking` (default true). Borderline blocking findings near the confidence threshold get one bounded adversarial cross-check (`review_gate.adversarial_crosscheck`/`adversarial_margin`/`adversarial_max`). These six `review_gate` keys are additive (config schema v24). In `group`/`feature` granularity, one shared resolver, `resolve_review_unit()` (`scripts/lib/review-evidence.sh`), maps a task to its review directory (`GROUP-<n>`/`FEATURE-<feat_id>`) so the IN_REVIEW/DONE evidence gates and the `reviewer_verdict` event's `review_unit` field (read by the `SubagentStop` coverage detector as ground truth) always agree on which unit a task was reviewed under (RULES.md §3.9, schema v29).

**Fix-first review.** Feedback aggregator classifies findings as AUTO-FIX (mechanical — applied automatically) or ASK (risky — requires judgment). Review gate Step 3.75 applies auto-fixes before presenting remaining items.

**Recovery must be automatic.** After any interruption, reading the Recovery Pointer + latest checkpoint + active task manifest must give enough information to resume.

## Dependencies

- `jq` — Required for all JSON manipulation in shell scripts
- `git` — Required for commit tracking and state persistence
- Claude Code with Agent Teams support (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)

## Testing

```bash
tests/run-tests.sh                    # Run all unit/integration tests (116 files)
tests/run-tests.sh --filter=stop-hook # Run specific test file
tests/e2e/run-e2e.sh                  # Run E2E skill tests (requires claude CLI, costs money)
tests/e2e/run-stack-e2e.sh            # Two-layer gh-stack E2E (real repo/PRs; CI-only via e2e-stack.yml)
tests/smoke/run-smoke.sh               # True-entry headless smoke (authenticated, paid, scratch only)
```

**Harness exit codes:** `0` all checked files passed, `1` a checked file failed, `2` NOTHING CHECKED (the
`--filter` matched nothing, or no test file was discovered), `3` internal coverage-accounting defect. A
zero-match filter is a failure, not a silent pass — every run ends with the fixed-grammar coverage line
`run-tests: N scanned, M skipped (filtered-out=…, unreadable=…), K checked, F findings` (`N == M + K`,
asserted by the emitter). See `tests/README.md`.

CI runs automatically on push (`test.yml`) and checks skill template freshness on PRs (`skill-docs.yml`). Skill E2E and stack E2E are manual trigger only (`e2e-tests.yml`, `e2e-stack.yml` — the latter needs a `STACK_E2E_GH_TOKEN` secret and creates real GitHub repos/PRs). Headless smoke is manual + nightly (`smoke.yml`) and needs `ANTHROPIC_API_KEY`; it is never a push/PR gate.

---

# Nazgul Framework — Project Instructions

## Architecture
This project uses the Nazgul autonomous development pipeline:

```
Objective → Discovery (+ Classification) → Doc Generator → Planner → Implementer → Review Board → Loop → Post-Loop → Complete
```

## Key Files
- `nazgul/config.json` — Runtime configuration (mode, iteration, reviewers)
- `nazgul/plan.md` — Live task tracker with Recovery Pointer
- `nazgul/tasks/` — Individual task manifests with full state
- `nazgul/checkpoints/` — Per-iteration JSON snapshots
- `nazgul/reviews/` — Review artifacts per task
- `nazgul/context/` — Project context from Discovery
- `nazgul/docs/` — Generated project documents (PRD, TRD, ADRs)
- `nazgul/inbox/` (+ `nazgul/inbox/archive/`) — Automation-heartbeat work inbox: candidate `.md`/`.json` files picked up by `scripts/heartbeat.sh` and archived on claim; only populated/consumed when `automation.heartbeat.enabled: true`
- `config.json → guards.red_run_evidence` — Default-on schema-v36 kill switch for the IMPLEMENTED red-run evidence block. `false` suppresses the block only; detection, stderr, and `red_run_missing` telemetry still run
- `config.json → connectors.github` — GitHub two-way connector config (opt-in, `enabled: false` by default): `pull.{label, claimed_label, max_body_bytes}`, `push.enabled`, `pull_failures` counter, and the remote-issue ↔ local-id `map`. No credential is stored here — auth is `gh` only. Consumed by `scripts/lib/connector-github.sh` via the `scripts/lib/inbox-provider.sh` seam (`automation.heartbeat.inbox.provider: "github"`)
- `nazgul/.githooks/` — Per-project managed git hooks dir (generated by `scripts/lib/git-hooks.sh`), pointed to by `core.hooksPath` when `guards.git_hooks: true`; holds the `pre-commit`/`pre-merge-commit` guards, the chain-dispatcher, and pass-through shims for every other githooks(5) name
- `config.json → execution.stacking` — Stacked-PR continuation policy (opt-in, `enabled: false` by default, schema v35): `max_unmerged` (default 3, the auto-start cap) and `rework_priority` (default 1). Three further keys are written at runtime by `scripts/lib/stack-utils.sh` and absent from a fresh config: `halted`/`halt_reason` (fail-closed flag, cleared only by a human) and `api_failures` (consecutive-failure counter, halts at 3)
- `config.json → stack.layers[]` — Script-owned layer registry, one entry per layer (`{feat_id, branch, pr, base, state: "open"|"merged", opened_at, merged_at}`). `scripts/lib/stack-utils.sh` is its SOLE writer — operators read it (via `/nazgul:status`, SessionStart, or `jq`) and never hand-edit it
- `nazgul/logs/heartbeat-*.jsonl` — One decision record per heartbeat tick (one file per UTC day)

## Commands
- `/nazgul:init` — First-time setup: run Discovery, generate reviewers, create runtime dirs
- `/nazgul:start` — Auto-detects project state and continues or starts work (derives objective from context)
- `/nazgul:start "objective"` — Override: start a specific new objective (flags: --afk, --yolo, --hitl, --max N, --parallel, --stack/--no-stack; --conductor is a deprecated alias for --parallel)
- `/nazgul:start --stack` / `--no-stack` — Opt into (or explicitly out of) stacked-PR continuation; persists `execution.stacking.enabled`. Three-state: omitting both leaves the persisted value untouched, so a prior objective's choice survives a resume. Orthogonal to mode and to `--parallel`
- `/nazgul:status` — Check loop progress, task counts, reviewer board
- `/nazgul:task` — Task lifecycle: skip, unblock, add, prioritize, info, list
- `/nazgul:pause` — Gracefully pause the loop at next iteration boundary
- `/nazgul:log` — View run history: iterations, commits, reviews, blockers
- `/nazgul:reset` — Archive current state and reset to clean slate
- `/nazgul:clean` — Fully remove Nazgul from this project
- `/nazgul:review` — Manually trigger review for a task
- `/nazgul:discover` — Re-run codebase discovery
- `/nazgul:context` — Collect targeted context for an objective type
- `/nazgul:simplify` — Post-loop cleanup pass on modified files
- `/nazgul:docs` — View or regenerate project documents
- `/nazgul:patch` — Lightweight task mode for bug fixes, config changes, and small features
- `/nazgul:verify` — Human acceptance testing for completed tasks
- `/nazgul:heartbeat` — Run one automation-heartbeat tick by hand: triages `nazgul/inbox/` and auto-starts the next objective if idle and clear. Opt-in and default-off (`automation.heartbeat.enabled: false`); a separate entry path from the main loop with no changes to the sequential or parallel execution path
- `/nazgul:complete` — Close an objective whose PR merged outside the loop: reads merge state from the host's PR API, records `## Merge Evidence` in each stranded manifest from the host's own answer, and walks each task to DONE through `scripts/task-transition.sh`. Never edits frontmatter, never fabricates a review, and never infers a merge from git ancestry
- `/nazgul:doctor` — Read-only environment preflight: reports plugin-version drift, `jq`/`gh` deps, git-hooks drift, the bash-vs-zsh hazard, the `NAZGUL_DIR` footgun, config-schema staleness, cross-session messaging and Remote Control eligibility, shared-working-tree session collisions, and — when `execution.stacking` is enabled — gh-stack tooling readiness plus registry-vs-GitHub drift. Never writes state; its only fix path is text on stdout
- `/nazgul:help` — Quick reference for all commands and modes

## Backlog Rule — every inbox item exists on the GitHub board

**Every file in `nazgul/inbox/` MUST have a GitHub issue on the `Nazgul: framework` project board**
(org project #4, `OrodruinLabs/nazgul` issues). The inbox is gitignored and local-only, so an item
that exists nowhere else is one machine failure away from gone — the board is the durable, shareable
copy.

The binding is recorded in the item's own frontmatter, which is what makes the rule checkable rather
than aspirational:

```yaml
priority: 1        # p0..p7 -> the `pN` label
type: bug          # bug | feature -> the `type: bug` / `type: feature` label
rank: 6            # position within the whole queue -> the board's Rank number field
issue: 94          # the GitHub issue. ABSENT = unsynced.
```

`type` is normalized to exactly two values. `rank` replaces file mtime as the ordering key — mtime
does not survive a copy, clone, or re-save, so an order stored only in filesystem metadata is lost
by any transport.

**Mechanism:** `scripts/sync-inbox-to-github.sh`

- `--check` — report only; **exits 1** if any item lacks an `issue:`. This is the enforcement.
- no flag — normalize `type`/`rank` on new arrivals, create the missing issues, write `issue:` back,
  add each to the board, and set its Rank.

Idempotent: an item carrying `issue: N` is skipped, never re-created, so the command is safe to
re-run and safe to interrupt. It reports `N scanned, M skipped, K created, F failed` — per RULES.md
§15, "nothing to do" and "nothing was examined" must never print the same thing.

Run it after filing anything. The inbox is written concurrently by other sessions, so the set grows
without this session's knowledge; `--check` is the cheap way to find out.

## The 10 Rules for the Nazgul Loop

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately. Never rely on conversational memory.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing. Match the style.
4. **Tests are mandatory.** Every task includes tests. Run them after every change. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** When CHANGES_REQUESTED, fix every REJECT item.
7. **One task at a time.** Don't work on multiple tasks simultaneously (unless parallel mode with Agent Teams).
8. **Update Recovery Pointer on every state change.** This is how you survive compaction. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA recorded under the manifest's `## Commits` section that resolves to a real, reachable commit (`git cat-file -e`) and is a strict descendant of the manifest's Base SHA (existence-only, announced on stderr, when no Base SHA is present); a `scripts/**`/`tests/**` task also requires usable `## Red-Run Evidence` or a scope-valid enumerated N/A token. Missing/corrupt evidence emits `red_run_missing` and blocks unless `guards.red_run_evidence: false` suppresses that block. IN_REVIEW requires a review directory, source edits require an IN_PROGRESS task — and only for paths inside this project's root (`task-state-guard.sh` is PROJECT_ROOT-bounded; in-project paths reached via symlink or `..` are still gated). Write every status change with `scripts/task-transition.sh transition TASK-NNN FROM TO` — it is the only sanctioned route, and the evidence above must already be on disk because the command reads the live manifest. A status change written outside it is quarantined by `stop-hook.sh`'s bash-write reconciliation pass at the next iteration and only `scripts/task-transition.sh repair` can leave that quarantine.
9. **Commit in AFK mode.** Every state transition gets a commit with the dynamic prefix from config (e.g., `feat(FEAT-003):`).
10. **NAZGUL_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

## Git Convention
- The default branch is `main`. All Nazgul branch operations (stacking, PRs, merges) target `main`.

## Safety
- Pre-tool guard blocks destructive commands (rm -rf /, DROP TABLE, etc.)
- Security rejections in AFK mode → BLOCKED (requires human review)
- Max retries per task: 3 (configurable in config.json)
- Max consecutive failures: 5 (auto-stops if no progress)

## Recovery
After any interruption (compaction, crash, timeout):
1. Read `nazgul/plan.md` → Recovery Pointer
2. Read latest checkpoint in `nazgul/checkpoints/`
3. Read active task manifest in `nazgul/tasks/`
4. Resume from the Next Action
