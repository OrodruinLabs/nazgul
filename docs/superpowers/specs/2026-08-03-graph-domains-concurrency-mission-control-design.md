# Nazgul Evolution — Contract-Bound Domain Paths, Concurrent Feature Loops, and Mission Control

**Date:** 2026-08-03
**Status:** Approved design (brainstorming session, 2026-08-03)
**Grounding:** 7 read-only architect passes against this repo + 3 web-research sweeps.
All file:line citations were verified on 2026-08-03 against the FEAT-027 working tree
(base: origin/main @ v2.28.1 / eecd333). Re-verify integration points at planning time —
FEAT-027 (v2.29.0) is mid-flight and moves some of them (e.g. `stack-utils.sh` is new).

## 1. Context and research verdict

The trigger was the "graph engineering" discourse wave (term coined 2026-07-04, viral
2026-07-18). Research verdict: **the label is hype; a minority of the underlying practices
have evidence behind them.** Findings that bound this design:

- **Agentic exploration beats graph retrieval for code localization** (SWE-Explore,
  arXiv 2606.07297: Claude Code 0.938 nDCG, best of all systems; graph-search methods lower).
  Corroborated by Codebase-Memory (arXiv 2603.27277): graph retrieval ~10x cheaper but
  83% vs 92% answer quality. Therefore Nazgul does NOT replace file exploration with graph
  retrieval, ever. Graph queries may only *supplement* (veto gate below).
- **Dependency-aware scheduling beats file-disjointness batching** (Co-Coder,
  arXiv 2606.00953, benchmarked against Claude Code Agent Teams: +14% pass rate,
  2.10x wall-clock, −35% cost). Nazgul's `compute_dispatch_batch` is the "file-based
  parallel baseline" that paper beats. This is the one place Nazgul is measurably behind.
- **Graph runtimes (LangGraph etc.) are rejected.** Nazgul's stop-hook loop already has
  the active-resumption guarantee production critiques fault LangGraph for lacking;
  files-as-truth already provides replay.
- **A graph amplifies whatever verification quality you already had; it does not create
  verification.** Correlated reviewer blind spots and ungrounded topology are the two
  failure modes to keep in view as parallelism grows.

The operator's requirements, refined through the session:

1. Domains (backend, web frontend, mobile, infra, media, ...) are **independent horizontal
   feature tracks** — never merged into one vertical feature. A larger backend must not
   block a finished frontend.
2. Independence comes from **contracts**, written before consumers; consumers build
   against their own stubs; dedicated **wiring features** integrate real implementations.
3. **True concurrency**: multiple feature loops running simultaneously, not merely
   order-flexible sequencing.
4. A **fleet dashboard** ("Mission Control") across all projects/repos/worktrees:
   see every loop and its agents, access each terminal from the browser (Aspire-style),
   pause/stop/restart — with a real database (local or remote) behind it.
5. Reuse over rebuild wherever a maintained seam exists; build thin and own it where
   Nazgul's value lives.

The program ships as three objectives. A before B before C is the natural order
(each stands alone; C observes whatever A/B produce and is orthogonal to both).

## 2. Architecture principles (binding on all three objectives)

- **Files remain each loop's working memory.** Everything the guard layer gates or the
  recovery protocol reads synchronously (config.json, plan.md, task manifests,
  checkpoints, reviews) stays file-native. Grounded: recovery/post-compact/session-context
  are pure file pipelines; `pre-merge-commit` runs standalone in target repos with no
  dependency guarantees (its own header: git cannot see gitignored `nazgul/` state).
  A DB query mid-crash-recovery is a new, worse failure class.
- **The database is a projection, never a dependency.** Loops POST events/snapshots
  best-effort (existing `webhook-forward.sh` idiom: opt-in, kill-switched, `--max-time 5`,
  `|| true`); a collector owns SQLite (local) / Postgres (remote), swappable without
  touching loop scripts. Loops never read the DB to run. Plugin deps stay jq+git+bash.
- **Gates stand on evidence that can't lie.** Task level: commit ancestry. Feature level:
  branch ancestry in the base branch (`git merge-base --is-ancestor`) — never PR
  `mergedAt` (a stacked layer's PR can show merged before content reaches main), never
  `objectives_history` (three documented silent close-out failures; root cause was an
  unmechanized write, which a DB would not have fixed — FEAT-027's `stack_submit`
  mechanizes it).
- **Degradation is always announced.** Every fail-open path emits a named event;
  every skipped candidate logs a reason. (RULES.md §15 / §1 doctrine, applied throughout.)

## 3. Objective A — Contract-bound domains + graph-aware planning

### A1. Empirical probe first (Task 1, ADR before integration code)

Sandbox probe of the candidate code-graph CLI (`code-graph-mcp` — MIT, single binary,
SQLite index, CLI equivalents for every query incl. `impact`/`callgraph`/`refs`) on
representative repos: edge accuracy, latency, index freshness behavior. Also verifies
that the existing dead code `compute_waves()`/`_pb_layer_waves()`
(`scripts/lib/parallel-batch.sh:48-103` — full Kahn layering with `CYCLE:` and
unknown-dependency detection, zero production call sites) is reusable as the plan
validator. If the tool disappoints, the design bends before the code does
(FEAT-027 gh-stack probe precedent).

### A2. Plan validator (wire up existing dead code)

One shared function (house pattern: `task-transition-guard.sh`'s "no second
implementation to drift out of sync"), reusing `compute_waves`, extended with
unreachable-task and deps-satisfied-before-READY checks. Call sites: a planner post-gate
in `stop-hook.sh`, and the dispatch path (via `_pb_layer_waves` reuse). Failure mode:
offending tasks → BLOCKED with a named diagnostic (cycle members listed), loop halt via
the existing `execution_should_halt` — matching the bash-write reconciliation pattern,
no new stop mechanism. Context: `agents/planner.md:113-127` builds waves by pure LLM
judgment today; nothing catches a cyclic plan.

### A3. Dependency-edge veto gate (batching stays selection-compatible)

One additional check inside `compute_dispatch_batch` after the existing pairwise
file-scope disjointness pass (`parallel-batch.sh:310-325`): query the CLI for
import/call edges between candidate tasks' file scopes; any cross-pair edge →
`_pb_single_result "cross-scope dependency edge: <detail>"` (the existing any-doubt →
solo contract; every rejection returns through `_pb_single_result` so downstream
consumers are untouched).

**Binding scoping rule:** edges are computed only between tasks *within the candidate
batch*. Edges into files owned by tasks outside the batch (notably already-DONE contract
tasks) are ignored — otherwise the gate would re-serialize every contract-first split
(both consumers legitimately import the contract's files). No exemption tags needed;
correct scoping makes them unnecessary.

Fail-open: CLI absent / nonzero / timeout (config `timeout_seconds`, default 10) →
today's file-disjointness behavior + `emit_event "graph_tool_degraded"` with
`reason` / `tool` / `fallback:"file_disjointness"`, emitted once per affected iteration
(matches `stop_gate` shape; numeric fields use the `:n` suffix per emit-event.sh MF-016).

Explicitly deferred: full Co-Coder partitioning (hub isolation, community detection) —
waves are 2-3 tasks here, nothing to chew on; revisit if veto telemetry shows frequent
firing. Also deferred: impact-aware `reviewer-selection.sh` (would couple its pure
offline `verify` recompute to an external tool — separate objective after the fail-open
path earns trust).

### A4. Contract / domain conventions (documentation + planner guidance, zero new machinery)

- **Contract = ordinary sequentially-numbered ADR** in `nazgul/docs/ADR-NNN-<contract>.md`,
  written before consumer specs. Binding via the exact ADR-018 ↔ FEAT-027-spec citation
  pattern (spec lists the ADR as binding input; ADR declares downstream features inherit
  it). Doc-generator's existing ADR-ingestion step picks it up automatically. Contracts
  are typed by boundary: API (endpoints/schemas), design system (tokens/components),
  infra (container/ports/env), data (schema/migration policy).
- **Consumer features own their stubs** inside their own `Creates`/`Modifies` scope and
  never list contract-owned files there. (Grounded free: the scope model tracks writes
  only — there is no Reads field; reading other tasks' files was never gated.)
- **Honesty-scoped acceptance criteria**: consumer "done" = "verified against this
  feature's contract-conformant mocks; integration is the wiring feature's criteria."
  Review boards judge acceptance criteria as ground truth (review-gate Step 3.8), so
  scoping the criteria is sufficient enforcement.
- **Wiring features**: file scope explicitly includes deleting/replacing stubs;
  acceptance criteria require integration tests against real implementations. Rides the
  normal review board + commit-evidence machinery. (No stub-grep transition gate — out
  of scope unless later requested.)
- **Integration is a domain**: recurring wiring features form their own track (own
  worktree/stack under Objective B). Degenerate case (small product): one wiring feature.
- **Planner guidance additions** (`agents/planner.md`, new subsection between Task
  Decomposition Rules and Parallel Groups): recognize producer/consumer splits; within a
  feature emit contract task → parallel consumers → wiring task; note Rule 5's
  "document why not" escape for first-ever contract tasks with no in-repo pattern.

### A5. Config + migration

`execution.graph.enabled` (default **true** — fail-open makes an opt-in flag a second
way to silently do nothing), `execution.graph.tool` (default `"code-graph-mcp"`),
`execution.graph.timeout_seconds` (default 10). Additive migration in the
`migrate_34_to_35` idiom; version = next after whatever FEAT-027 lands (v35→v36 as of
grounding — confirm at planning time).

### A6. Interaction with the upfront-product-breakdown inbox item

`nazgul/inbox/upfront-product-breakdown-docs-roadmap.md` runs the same doc-generator and
planner for every roadmap feature up front, so it inherits contract-first decomposition
and plan validation automatically (one rulebook, two callers). Product-breakdown time is
when domain boundaries are identified, contract ADRs written, per-domain tracks and
wiring features laid out on the board. That item consumes this objective's conventions;
design them compatibly, build them separately.

## 4. Objective B — Concurrent feature loops (worktree-per-feature)

The recursive application of Nazgul's own pattern one level up: today = feature branch
integrates task worktrees; new = `main` integrates feature worktrees. Grounded result:
**per-worktree state isolation already exists** — `resolve_project_root()`
(`scripts/lib/nazgul-root.sh:48-70`) resolves via worktree-scoped
`git rev-parse --show-toplevel`, and `nazgul/` is gitignored, so each feature worktree
gets its own complete brain for free. Two loops in two worktrees already almost work.
The gaps are small and specific:

### B1. `create_feature_worktree()` (new, `scripts/worktree-utils.sh`)

`git worktree add <path> -b feat/FEAT-X-<slug> <base>` mirroring `create_task_worktree`
(line 281) but WITHOUT its main-checkout `CLAUDE_PROJECT_DIR` export — a feature worktree
is self-contained (that export exists precisely because task worktrees must NOT have
their own brain; feature worktrees must). Registers the worktree in the Objective C
registry (B4) when present.

### B2. Fix: worktree-scoped git-hooks install (ships for all users — real bug)

`install_git_hooks` (`scripts/lib/git-hooks.sh:144`) writes `core.hooksPath` via plain
`git config`, which is physically shared across all linked worktrees — the second
feature's init silently disarms the first feature's pre-commit/pre-merge guards.
Fix: `git config extensions.worktreeConfig true` once, then `git config --worktree
core.hooksPath ...`. Hook *logic* is already worktree-correct (guards resolve
`REPO_ROOT` via their own `git rev-parse --show-toplevel` at call time); only the
config write needs scoping. Uninstall/self-heal paths in `git-hooks.sh` updated to match.

### B3. Per-domain stacks; sibling branches across domains

Stacking (FEAT-027) stays exactly as built, scoped per worktree: `stack.layers[]` lives
in each worktree's own config.json, so each domain track gets a private linear stack
(FEAT-B1 → FEAT-B2 → ...). **Never stack across domains** — with stacking enabled the
second feature would branch off the first's tip and inherit its commits, destroying
independence. Concurrent domain features are siblings off `main` (the existing
non-stacking `create_feature_branch` path). Note in docs: `max_unmerged` (default 3)
is a per-domain budget.

### B4. Requires-gate for the integration domain (git-truth dependency gate)

- Frontmatter: `requires: FEAT-B, FEAT-C` (comma string — no YAML-array precedent in
  this format), read raw off the candidate file exactly like the existing `branch:`/`pr:`
  stack-rework keys (written at `stack-utils.sh:641-644`, read by sed in
  `skills/start/SKILL.md:162-192`); `_inbox_yaml_val` gains one split step.
- Resolution: branch-name-convention scan (`feat/<id>-*`) + `git merge-base
  --is-ancestor <tip> <branch.base>`. Works across sibling worktrees for free (shared
  refs namespace). Never PR state, never objectives_history, never cross-worktree config.
- Enforcement: filter inside `heartbeat_pick` (`heartbeat-triage.sh:31-62`) before the
  final sort — the next eligible candidate wins the same tick — paired with a new
  additive `requires_skipped` field on the tick's decision record (a skip is visible,
  never silent). Same check in `skills/start/SKILL.md` (dual-path precedent: stack cap).
- Two distinct not-ready states: "exists, not yet merged" = quiet/expected skip;
  "unresolvable" (no matching branch anywhere) = escalates after 3 consecutive ticks by
  filing a p1 inbox item (threshold and mechanism mirror stack-utils's
  3-consecutive-failure halt / `_su_file_conflict_inbox`). Fail-closed, loudly.
- Independent of the stack cap gate (no shared state); decision log must show both
  reasons distinctly if both fire.

### B5. Doctor checks + operator workflow

`/nazgul:doctor` additions: flag `CLAUDE_PROJECT_DIR` set in the environment when its
target disagrees with `pwd`'s worktree (the one env var that silently collapses all
worktrees onto one brain — `nazgul-root.sh:49-52` honors it unconditionally); flag
missing `extensions.worktreeConfig` when multiple feature worktrees exist. v1 operator
workflow: one Claude Code session per feature worktree (heartbeat per worktree already
works — per-NAZGUL_DIR locks); dashboard-driven and heartbeat-driven multi-loop
orchestration arrive with Objective C.

## 5. Objective C — Mission Control (fleet dashboard + platform layer)

**Verdict from research: integrate the outer layer, build the inner layer.** Anthropic's
Agent View (`claude agents`, research preview since 2026-05-11, v2.1.139+) owns
session-fleet chrome: `--json` state (also on disk: `~/.claude/daemon/roster.json`,
`~/.claude/jobs/<id>/state.json`), and control verbs `attach`/`logs`/`stop`/`kill`/
`respawn`. Every dead OSS competitor (Vibe Kanban, Crystal, Omnara, claude-code-webui)
died competing with first-party features; the live ones are AGPL (license risk) or have
no event seam. Nothing renders Nazgul's inner state (tasks/waves/verdicts/blockers) —
Agent View deliberately collapses subagents into the parent row. That layer is ours.

### C1. Registry

`~/.nazgul/registry.json`, appended by `/nazgul:init` and `create_feature_worktree`:
`{project_root, worktree, feat_id, created_at}`. Dashboard scans and prunes dead paths.
(First machine-global state; nothing in scripts/ uses `$HOME` for state today.)

### C2. Collector + database (the projection layer)

Small service owning the DB: **SQLite (WAL) locally, Postgres remotely — swappable
behind the collector API; loops never know which.** Ingest paths: (a) extend
`webhook-forward.sh` (or migrate to declarative `http` hook handlers) to forward the
FULL event bus — `nazgul/logs/events.jsonl` records (20+ event types incl. `stop_gate`,
`subagent_empty_return`, reviewer/stacking families) — plus per-iteration checkpoint
snapshots (`checkpoints/iteration-NNN.json` is already a complete dashboard payload:
task buckets, active task + next action, git state, reviewers/verdicts, budget, context
health); (b) `nazgul/in-flight/*.json` for currently-dispatched agents. Tables: events,
snapshots, sessions, loops, heartbeat decisions. Opt-in, kill-switched, non-blocking —
the `connectors.github` idiom.

### C3. Web frontend (the product surface; Aspire-style single pane)

- **Fleet page**: attention-ordered queue (needs-input / BLOCKED / ready-for-review
  first, completed last), one row per loop joined from `claude agents --json` (liveness,
  PID, session) × registry × latest snapshot (project, domain, feature, wave, buckets,
  one-line summary, cost meter, PR badge).
- **Loop drill-down**: Recovery Pointer, task board, review verdicts, event timeline,
  attention badges for the mechanism signals only Nazgul records (`stop_gate`,
  reconciliation flags, unverified-critical-reviewer, `subagent_empty_return`).
- **Terminal panel**: embedded xterm.js over a WebSocket→server-side-PTY bridge running
  `claude logs -f <id>` (read-only peek, default) or `claude attach <id>` (interactive,
  one click deeper). Session lifecycle stays Agent View's supervisor's problem. Validated
  pattern (marcnuri.com dashboard: browser terminal over WS relay incl. mobile) — used
  as existence proof, not copied.
- **Actions**: pause/resume = toggling `paused` in the loop's config.json (stop-hook
  already obeys at the next iteration boundary); stop/respawn = delegated to `claude`
  CLI; start-next-feature = drop an inbox item.
- **Notifications**: service-worker push on needs-input / completion / requires-gate
  unblock.
- **Auth**: none locally; pre-shared key for remote deployment (OIDC = later hardening).

### C4. Near-free additions

- **OTel stamping**: export `OTEL_RESOURCE_ATTRIBUTES="nazgul.objective=…,nazgul.task=…,
  nazgul.wave=…"` (+ `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES=true`) at dispatch —
  Anthropic's own cost/token metrics become sliceable per task/objective with ~10 lines
  of shell. Sink: SigNoz or Grafana (OTLP).
- **Optional web-surface shortcut**: Claude-Code-Agent-Monitor (MIT, active) accepts
  hook events at `POST /api/hooks/event` — viable interim surface or reference
  implementation; Nazgul domain events would need schema mapping or a fork. Decision
  deferred to Objective C planning; the collector API is designed so the frontend is
  swappable.

### C5. Hazards (handled the house way)

- Agent View is a research preview: probe + version assertion in `/nazgul:doctor`;
  fallback = read `roster.json`/`state.json` directly. A missing/changed contract
  degrades the fleet page to registry+files-only, announced — never silently empty.
- Backgrounded sessions auto-isolate into `.claude/worktrees/` and auto-commit/PR,
  which would fight Nazgul's worktree and commit discipline: document
  `worktree.bgIsolation: "none"` as a requirement for Nazgul repos (doctor check).

## 6. Testing

- **A**: unit tests in the existing harness — veto gate (edge → solo; tool absent/hung →
  today's behavior + `graph_tool_degraded`; intra-batch scoping ignores DONE-task edges);
  validator (cycle → BLOCKED with named members; unreachable; clean plan passes);
  migration idempotence. Probe task produces the ADR, not tests.
- **B**: hooksPath fix (two worktrees, both guards still fire — regression test for the
  clobber); requires-gate (merged/unmerged/unresolvable × heartbeat/manual paths;
  `requires_skipped` visible in the decision record); `create_feature_worktree`
  (self-contained brain, registry append). E2E (manual workflow): two concurrent loops
  in sibling worktrees complete two features without cross-talk.
- **C**: collector ingest contract tests (event/snapshot schemas); fleet join renders
  with Agent View present, absent, and contract-drifted (degraded-and-announced);
  pause write obeyed at next iteration boundary. Frontend gets its own test story at
  planning time (it's a separate app, not plugin bash).

## 7. Out of scope (explicit)

Graph runtimes (LangGraph et al.); GraphRAG/knowledge-graph memory; replacing agentic
exploration with graph retrieval; full Co-Coder partitioning; impact-aware reviewer
selection; a stub-grep transition gate; cross-domain stacking; full-DB state migration;
building a session supervisor (Agent View owns it); org-graph/work-graph taxonomy;
mechanizing `requires:` against objectives_history.

## 8. Cross-references

- `nazgul/inbox/upfront-product-breakdown-docs-roadmap.md` — consumes A's conventions
  (contracts + domain tracks laid out at breakdown time); board tiers per
  `board-sync-incompatible-with-manifest-format.md` part C.
- `nazgul/inbox/objective-never-appended-to-history-and-never-tagged.md` — why the
  requires-gate stands on git ancestry; close-out mechanization ships in FEAT-027.
- FEAT-027 (stacked-PR continuation) — per-domain stacks reuse it unchanged; B's
  sibling-branch rule is its complement, not a change to it.
- Research corpus (key): SWE-Explore 2606.07297; Co-Coder 2606.00953; Codebase-Memory
  2603.27277; GraphRAG-Bench 2506.05690 (ICLR'26); Agent View docs
  (code.claude.com/docs/en/agent-view); marcnuri.com/ai-coding-agent-dashboard
  (reference only).
