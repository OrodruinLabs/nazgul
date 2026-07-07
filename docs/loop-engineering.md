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
