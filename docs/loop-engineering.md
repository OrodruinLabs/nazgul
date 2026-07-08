# Loop Engineering

Addy Osmani's "loop engineering" thesis: *you design the system that prompts the agent instead of
prompting it yourself.* He names six components a durable agent loop needs. This doc maps each one to
a concrete Nazgul artifact — where Nazgul already has it, and where the Conductor (FEAT-007) closes the
one gap that was missing.

## The six components

| # | Component | Nazgul artifact |
|---|-----------|------------------|
| 1 | Automations / heartbeat | The `Stop` hook (`hooks/hooks.json` → `scripts/stop-hook.sh`) re-fires after every turn, reads `nazgul/plan.md`, and either continues the loop (exit 2) or lets it end (exit 0). This is the loop's heartbeat — it never needs a human to press "continue." |
| 2 | Worktrees | The `EnterWorktree`/`ExitWorktree` tools give each task (or Conductor unit) an isolated git worktree and branch, so parallel work never collides on the working tree. See `agents/team-orchestrator.md` for the pattern; `agents/implementer.md` and `agents/conductor.md` both use it. |
| 3 | Skills | `skills/*/SKILL.md` are the user-facing entry points (`/nazgul:init`, `/nazgul:start`, `/nazgul:status`, etc.) — the operator's interface to the loop, independent of which execution engine is driving underneath. |
| 4 | Connectors | Not yet first-class loop I/O (pull work in, push results out via Linear/Slack/CI) — deferred to FEAT-009. Today the only connector-shaped piece is `scripts/board-sync-github.sh` (GitHub Projects board sync), a one-way status mirror rather than a two-way work inbox. |
| 5 | Maker/checker sub-agents | `agents/implementer.md` (maker) builds one task; `agents/review-gate.md` (checker) orchestrates the review board and `agents/feedback-aggregator.md` consolidates findings before any retry. No task reaches DONE without the checker's approval — this split is structural, not optional. |
| 6 | Persistent, on-disk state | `nazgul/` is the loop's only memory: `nazgul/config.json`, `nazgul/plan.md` (with its Recovery Pointer), `nazgul/tasks/*.md`, `nazgul/checkpoints/`. Context is ephemeral; files are truth (CLAUDE.md's Key Concepts, RULES.md §4 Recovery Protocol). |

Five of the six were already structural to Nazgul before FEAT-007. The gap was the **top-level
conductor**: the sequential engine runs *inside* one main session, one task at a time, so a whole-system
build eventually exhausts that session's context window. Nothing held only orchestration state across
the whole build — the driver's own context grew with the work.

## The sixth component: the Conductor

`agents/conductor.md` is the top-level driver. It reads the Planner's task graph and `nazgul/plan.md`
ordering, computes waves via `scripts/lib/conductor-graph.sh`, checks gates and hard stops via
`scripts/lib/conductor-gates.sh`, and routes each unit to a backend (subagent, Agent Team teammate, or
worktree-isolated) via `scripts/lib/conductor-router.sh`. It invokes the existing Review Board
(component 5) per unit — no new reviewer logic — and records only a one-line verdict and a commit SHA
per task into `nazgul/conductor/graph.json` (component 6), never a diff or a file body. That graph-only
invariant is what lets the Conductor drive an entire objective without its own context growing past a
single window: it holds the shape of the build, not the build itself.

The Conductor is opt-in: `execution.engine` in config selects `"sequential"` (default, today's
behavior, unchanged) or `"conductor"`. It composes with the existing mode flags — `--conductor` is
orthogonal to `--afk`/`--hitl`/`--yolo`. `conductor.gates` (`approve_graph`, `approve_each_wave`,
`approve_final_pr`) default `false` for an autonomous-first posture; two hard stops — any `BLOCKED` task,
any security rejection — always halt for a human regardless of gate config or mode.

## Mechanical enforcement (Enforced Conductor follow-up)

FEAT-007 shipped the Conductor as a working driver whose correct behavior was, in the end, prose in its
own prompt: nothing stopped it from firing a work unit and moving on without waiting, or from
re-implementing a unit it had already committed. A follow-up objective ("Enforced Conductor",
`feat/conductor-enforcement`) closed that gap with five layers backing one headline invariant —
**"completed = cached, never re-executed"**: a unit that reached `IMPLEMENTED`/`DONE` with a commit SHA is
never re-dispatched or re-implemented.

1. `scripts/conductor-dispatch-guard.sh` (PreToolUse on the `Agent` tool) denies background dispatch of a
   work-unit subagent and denies re-dispatching a unit whose status makes that dispatch wasted work —
   `implementer`/`team-orchestrator` at `IMPLEMENTED`/`DONE`, but `review-gate` only at `DONE` (an
   `IMPLEMENTED` unit still legitimately needs its review dispatched, not re-implemented). Dispatch is
   synchronous and one-shot per unit per subagent kind.
2. `scripts/conductor-rework-guard.sh` (PreToolUse on `Write|Edit|MultiEdit`) denies writing to a file
   inside a committed unit's `file_scope`.
3. `scripts/subagent-stop.sh` detects an orphaned wave (units dispatched but not yet terminal) on every
   `SubagentStop` event and records a `nazgul/conductor/.resume-needed` marker plus a
   `conductor_orphan_detected` event.
4. `scripts/lib/conductor-router.sh` routes a Planner-marked, zero-overlap parallel wave to
   `team-orchestrator` instead of one bespoke worktree per unit, reusing the sequential engine's proven
   Agent-Teams path and its zero-file-overlap validation.
5. `scripts/lib/conductor-graph.sh`'s `graph_wave_digest` gives the Conductor a cheap per-turn orientation
   snapshot (`{current_wave, next_unit, units}`) instead of a full wave recomputation.

Both guards are scoped to an active conductor run — `nazgul/conductor/.session` present and
`execution.engine == "conductor"` — and gated by an additive kill-switch,
`conductor.enforce.{dispatch_guard,rework_guard}` (both default `true`, config schema v20). See RULES.md
§12 for the full, honest tier breakdown: layers 1-2 are mechanically `[enforced]`; layers 3-4 are
`[hook-driven only]` (wired into a real hook, but detection/routing rather than a block); layer 5 stays
`[advisory]`, same as the rest of §11. The two unconditional hard stops from §11 — any `BLOCKED` task, any
security rejection — are unchanged and sit underneath all five layers regardless of the kill-switch.

### Nazgul's Conductor vs. native dynamic Workflows

Claude Code ships a native dynamic-workflow runtime (`agent()`/`pipeline()`/`parallel()` primitives,
deterministic "plan-in-code," runtime-cached resumption). Before hardening the Conductor with guards, we
evaluated rebuilding it on that runtime instead — the caching model is exactly the "completed = cached,
never re-executed" invariant above, for free. It's the right tool for **one-off, single-session fan-outs**:
audits, migrations, `/deep-research`-style research, anything that starts and finishes inside one session
with no need to survive a restart. We recommend it for those.

We did not build the Conductor on it, for four reasons found during that investigation:

1. **Plugins cannot ship a workflow.** Plugin component types are `skills/ commands/ agents/ hooks/
   .mcp.json .lsp.json monitors/ bin/ settings.json` — there is no `workflows/`. Saved workflows live in
   `.claude/workflows/`, undistributable via the Nazgul plugin.
2. **Workflows don't survive a session exit.** Resume is same-session only; a new session starts fresh.
   This collides with Nazgul's foundational disk-based cross-session/compaction recovery (RULES.md §4) —
   the Conductor's whole reason to exist.
3. **No mid-run human input**, which breaks HITL's `approve_each_wave`/`approve_final_pr` gates
   (`conductor.gates`, §11).
4. **The `Workflow` tool is main-session-only, not available to subagents.** The Conductor is itself a
   subagent (dispatched by `/nazgul:start`), so it can never invoke `Workflow` — this alone rules out
   "Conductor launches inline workflows per wave" as a mechanism.

We adopted the Workflow *patterns* (result caching, plan-in-code) — via mechanical guards, since we get
none of it from the runtime — not the runtime itself.

### Deferred: Review Board robustness (not part of this release)

The `/deep-research` pattern of treating a claim the verifier *could not check* as **unverified**, not
**refuted**, surfaced a real gap in the shared Review Board (`agents/review-gate.md`, used by both
engines): a reviewer that errors, rate-limits, or otherwise can't assess a change is not currently
distinguished from one that reviewed and rejected it. Two follow-ups are captured for a future objective —
a non-blocking `unverified` verdict distinct from `REJECT`, and an adversarial cross-check/voting posture
across reviewers. Both touch code shared by the sequential and Conductor engines, so they are deliberately
**out of scope here** to avoid destabilizing the sequential engine; nothing in this release implements
them.

## Run it as a loop

```bash
/nazgul:start --conductor          # opt into the Conductor engine, autonomous by default
/nazgul:start --conductor --afk    # Conductor + AFK: commits each state transition, unattended
/nazgul:start --conductor --yolo   # Conductor + YOLO: pushes branches and opens PRs as waves land
```

Omit `--conductor` and `/nazgul:start` behaves exactly as before — the sequential stop-hook loop drives
one task at a time.

## Roadmap

FEAT-007 (Conductor) is the first of three sub-projects that together build out the full loop-engineering
picture:

1. **Conductor** (this doc, FEAT-007) — the top-level driver that scales a build past one context window.
2. **Automation Heartbeat** (FEAT-008) — a cron-driven triage → work-inbox → auto-start path, so the loop
   can pick up new work without a human invoking `/nazgul:start`.
3. **Connectors** (FEAT-009) — first-class loop I/O (Linear/Slack/CI pull and push), completing component 4
   above beyond the current one-way GitHub board sync.

None of FEAT-008 or FEAT-009 is implemented yet; both build on the Conductor's graph-only state as their
foundation.
