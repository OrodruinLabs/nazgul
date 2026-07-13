# Enforced Conductor — Design Spec

- **Date:** 2026-07-08
- **Status:** Approved (architecture) — pending spec review
- **Objective type:** feature / hardening (brownfield — the Nazgul plugin enhances itself)
- **Target release:** MINOR, 2.9.0 → 2.10.0
- **Vehicle:** direct implementation on a feature branch + PR (NOT the Nazgul pipeline — the conductor is what we're fixing)

## Problem

A live YOLO test of the FEAT-007 Conductor engine (driving FEAT-008 Automation Heartbeat) burned
~200k tokens and produced **zero durable commits**. Root cause, in order of importance:

1. **Fire-and-yield orphaning.** The conductor dispatched Wave 1 implementers as **named background
   agents + a Monitor**, then **ended its own turn**. The background children were orphaned with their
   partial work discarded. On resume it re-dispatched the same units from scratch → double-spend, still
   nothing landed. This directly violates `agents/conductor.md` **Step 5**, which already says in bold:
   *"never fire a nested dispatch and move on before it returns… Wait for every dispatch in the batch to
   return."*
2. **The correct behavior was purely instructional.** Step 5's prose was already right and the LLM
   ignored it. There is **no mechanical enforcement** anywhere for the conductor — PreToolUse hooks today
   match only `Bash` and `Write|Edit|MultiEdit`; nothing references `conductor` or `graph.json`. This is
   exactly the "hoped-for behavior" anti-pattern the FEAT-001…005 self-governance program was built to
   eliminate, but the conductor shipped without any guard.
3. **Routing bypassed the proven parallel primitive.** `conductor-router.sh`'s `route_backend` picks the
   `team` backend (team-orchestrator / Agent Teams) only for `isolation == "coordination"`. File-mutating
   implementer waves are classified `mutation` → `worktree`/`EnterWorktree` (session-coupled), so the
   robust, managed-lifecycle Agent-Teams path the **sequential engine already uses** for waves was never
   engaged.
4. **Orientation cost.** The conductor re-derives wave state from config + plan + all task files every
   turn, spending tokens just to understand "where am I."

## Feasibility findings (verified 2026-07-08, not assumed)

A logging PreToolUse probe + mining of the run's telemetry established:

| Fact | Verdict | Evidence |
|---|---|---|
| PreToolUse fires for the `Agent` tool | ✅ YES | probe: `tool_name:"Agent"` |
| `tool_input` exposes `run_in_background` and `subagent_type` | ✅ YES | probe payload keys `["description","prompt","run_in_background","subagent_type"]` |
| PreToolUse can block via exit 2 / `permissionDecision:"deny"` | ✅ YES | documented general mechanism |
| Plugin PreToolUse fires for a **subagent's** Write/Edit | ✅ YES | FEAT-007 TASK-010: a real implementer-subagent manifest edit tripped `task-state-guard.sh`'s awk bug |
| → therefore fires for the conductor's **`Agent`** dispatches | 🟡 High confidence (inference) | must be smoke-tested as implementation Task 0 |
| `SubagentStop` fires for `nazgul:conductor` and its children, with agent identity | ✅ YES | `events.jsonl`: `nazgul:conductor`, `impl-001`, `impl-002` |
| `SubagentStop` can *block* to force-continue | ❓ unproven | **Design avoids depending on this** — enforcement is at dispatch, not at stop |

**Design consequence:** enforce at the **dispatch** (PreToolUse on `Agent`, proven) rather than at the
stop (SubagentStop blocking, unproven).

## Goals

- The conductor **cannot** silently fire-and-yield (orphan) an in-flight work unit.
- The conductor **cannot** waste tokens re-implementing an already-committed unit.
- Orphaned/incomplete waves are **visible and auto-resumable**, not silent.
- Parallel file-mutating waves reuse the sequential engine's proven Agent-Teams + `git worktree add`.
- The conductor spends materially fewer tokens on per-turn orientation.
- Every enforcement is **mechanical** (a hook/guard), not instructional prose we hope is followed.
- Zero regression to the sequential engine.

## Non-goals

- Proving/using SubagentStop-blocking (avoided by design).
- Changing the graph-only invariant, the wave algorithm, or "what DONE means."
- The `claude -p` backend, the FEAT-008 heartbeat itself, or connectors (FEAT-009) — untouched.
- Flipping the conductor to be the default engine.

## Design — five layers

### Layer 1 — Ceiling: `scripts/conductor-dispatch-guard.sh` (new PreToolUse hook on `Agent`)

Registered in `hooks/hooks.json` under `PreToolUse` with matcher `"Agent"`. Reads the hook JSON on
stdin. **Active only during a conductor run** — a fast no-op (exit 0) unless
`nazgul/config.json.execution.engine == "conductor"` AND a conductor session is active (see the
conductor session marker below). When active, it DENIES (exit 2 with a message) two dispatch shapes:

1. **Background dispatch of a work unit.** `tool_input.run_in_background == true` AND
   `tool_input.subagent_type` ∈ {`nazgul:implementer`, `nazgul:review-gate`, `nazgul:team-orchestrator`}
   → **DENY**: *"Conductor work units must be dispatched synchronously (agents/conductor.md Step 5).
   Remove run_in_background."* This single rule makes the fire-and-yield orphan impossible.
2. **Re-dispatch of a completed unit.** Parse `NAZGUL_UNIT: TASK-NNN` from `tool_input.prompt` (a
   dispatch-contract marker the conductor MUST include). Read that unit's status from
   `nazgul/conductor/graph.json`; if already `IMPLEMENTED`/`DONE` → **DENY**: *"TASK-NNN already
   implemented at <sha> — re-dispatch blocked."*

- **Depends on:** `execution.engine`, a conductor-session marker file, `graph.json`, the `NAZGUL_UNIT`
  prompt marker. POSIX, `set -euo pipefail`, jq-only, **no `eval`** on prompt text (grep the marker with
  a fixed pattern; never execute prompt content).
- **Conductor session marker:** `agents/conductor.md` Step 0 writes `nazgul/conductor/.session`
  (containing its run id) at start and the guard checks its presence + engine. This scopes the guard so a
  human dispatching an unrelated background agent is never blocked.

### Layer 2 — Floor: conductor re-work guard on Write/Edit

Extend the existing `Write|Edit|MultiEdit` PreToolUse chain with a check (new lib function, e.g.
`scripts/lib/conductor-rework.sh`, invoked from the existing guard entry — do NOT overload the
awk-fragile `task-state-guard.sh` internals): during a conductor run, when an implementer writes a file
inside a unit's declared `file_scope` and that unit's task branch **already carries a commit**, DENY
*"unit already implemented — re-work blocked."* This kills double-*implementation* waste even if a
re-dispatch ever slips past Layer 1. Uses the proven Write/Edit subagent interception.

- **Depends on:** graph.json (unit → file_scope, task branch, commit SHA), git. jq + git, no eval.

### Layer 3 — Detection: extend `scripts/subagent-stop.sh`

When the stopping subagent is `nazgul:conductor` (identity already available in the payload) AND
`graph.json` shows a wave with units dispatched but none reaching a terminal state (no active children),
emit a loud `conductor_orphan_detected` telemetry event and write `nazgul/conductor/.resume-needed`
with the incomplete wave/units. Never blocks (blocking is unproven and unnecessary). Makes an orphan
**visible and auto-resumable** — a supervising loop (or `/nazgul:status`) can surface/resume it.

- **Depends on:** the SubagentStop payload identity + `graph.json`. Non-fatal, best-effort.

### Layer 4 — Routing: `conductor-router.sh` + `agents/conductor.md` Step 5

Change `route_backend` so a **parallel, file-mutating** batch routes to `team` (team-orchestrator /
Agent Teams — the sequential engine's proven `git worktree add` + managed spawn/monitor/collect/cleanup
path) instead of bespoke `EnterWorktree`. Reserve raw `subagent` for single-unit waves and read-only
review dispatch; keep `worktree` only where a lone mutating unit genuinely needs isolation without a
team. Update Step 5 to dispatch parallel mutating batches via team-orchestrator and to carry the
`NAZGUL_UNIT` marker on every unit dispatch (the Layer 1 contract).

- **Depends on:** `agents/team-orchestrator.md`'s existing "Spawning an Implementation Team" protocol.
  Reuse, don't reinvent.

### Layer 5 — Orientation cost: wave-state digest

`scripts/lib/conductor-graph.sh` emits a compact **wave-state digest** (current wave, per-unit status +
SHA, next unit, hard-stop state) as a single small artifact the conductor reads once per turn, instead
of re-parsing config + plan + every `TASK-*.md`. `agents/conductor.md` Step 0/2 read the digest first
and only fall back to full re-derivation when the digest is missing/stale. Cuts per-turn orientation
tokens without changing the graph-only invariant (digest holds only ids/status/SHA/wave — never file
bodies).

- **Depends on:** existing `conductor-graph.sh` compute/recovery functions.

## Dispatch contract (new, testable)

The conductor MUST include a line `NAZGUL_UNIT: TASK-NNN` in every implementer/review dispatch prompt.
This is the anchor Layer 1's re-dispatch check and Layer 3's detection rely on. It is a cheap, greppable
contract (fixed-string match, no eval) and is asserted by tests.

## Config

Additive `conductor.enforce` block (default `true`), so enforcement is on by default for conductor runs
but has a documented kill-switch:

```json
"conductor": { "enforce": { "dispatch_guard": true, "rework_guard": true }, "max_parallel": 3, "gates": {…} }
```

ONE additive template schema bump **v19 → v20** + `migrate_19_to_20` + config/migration tests
(idempotent; applies cleanly from any prior version).

## Testing strategy (bash harness)

- **Task 0 (feasibility gate):** a smoke test proving a plugin PreToolUse `Agent` hook actually fires for
  a dispatch made *by a subagent* (a parent test-subagent dispatches a child; assert the guard logged).
  If this fails, Layer 1 is infeasible and the design escalates to SubagentStop-based enforcement — so it
  runs FIRST.
- **Layer 1:** guard denies background implementer dispatch; denies re-dispatch of an `IMPLEMENTED`/`DONE`
  unit; no-ops when engine≠conductor; no-ops for a non-unit `subagent_type`; allows a legitimate first
  synchronous dispatch. Fed real hook-JSON envelopes (learn from the pre-tool-guard envelope bug:
  extract from `.tool_input`, don't test raw commands).
- **Layer 2:** re-work guard blocks a write to an already-committed unit's file_scope; allows first write.
- **Layer 3:** conductor-stop with an incomplete wave writes `.resume-needed` + emits the event; complete
  wave does not.
- **Layer 4:** `route_backend` returns `team` for parallel-mutating, `subagent` for single-unit;
  overlap-abort still falls back to sequential.
- **Layer 5:** digest shape + staleness fallback.
- **Migration:** clean v19→v20; sequential engine full suite stays green (zero regression).
- New scripts registered in `tests/test-shellcheck.sh`; `bash -n` + `shellcheck` clean throughout.

## Rollout / docs

- `RULES.md`: a Conductor-enforcement section with **honest enforcement tiers** (`[enforced]` for the
  dispatch/re-work guards; `[hook-driven]` for detection; `[advisory]` where prose still leads).
- `CLAUDE.md`: new scripts in the directory-structure + roster.
- `docs/loop-engineering.md`: update the conductor section to describe enforced dispatch.
- `CHANGELOG.md` + README badge: 2.9.0 → 2.10.0.

## Risks / open questions

- **Residual inference (mitigated):** plugin PreToolUse firing for a *subagent's* `Agent` dispatch is
  inferred, not directly observed — Task 0 verifies it before the rest is built.
- **`NAZGUL_UNIT` marker discipline:** the conductor must emit it; if omitted, Layer 1's re-dispatch check
  degrades to the background-guard only (still blocks the primary failure). A test asserts Step 5 emits it.
- **Guard scoping:** the conductor-session marker must be reliably present/absent so the guard never
  blocks unrelated human agent dispatches; covered by the engine≠conductor and non-unit no-op tests.

## Dynamic Workflows investigation (2026-07-08) — why we harden, not rebuild

Prompted by the platform's dynamic-workflow docs (`code.claude.com/docs/en/workflows`) and the
`/deep-research` pattern, we evaluated rebuilding the conductor on the native **Workflow** runtime
(the deterministic "plan-in-code" primitive: `agent()`/`pipeline()`/`parallel()`, runtime-cached
resumption, agent caps). Findings, each verified against docs or by probe:

1. **Plugins cannot ship a workflow.** Plugin component types are `skills/ commands/ agents/ hooks/
   .mcp.json .lsp.json monitors/ bin/ settings.json` — there is **no `workflows/`**. Saved workflows
   live in `.claude/workflows/`, undistributable via the Nazgul plugin.
2. **Workflows don't survive a session exit** (docs: resume is same-session only; a new session starts
   fresh). This collides with Nazgul's foundational disk-based cross-session/compaction recovery
   (RULES.md §4) — the conductor's whole reason to exist.
3. **No mid-run user input** (breaks HITL `approve_each_wave`/`approve_final_pr`); **version/plan-gated**
   (v2.1.154+, paid, disable-able) vs. Nazgul's version-agnostic target.
4. **The `Workflow` tool is main-session-only — NOT available to subagents** (probe 2026-07-08: an
   all-tools `general-purpose` subagent's toolset had no `Workflow`, not even deferred). The conductor
   **is** a subagent (dispatched by `/nazgul:start`), so it can never launch a workflow. This killed the
   "conductor launches inline workflows per wave" mechanism outright.

**Conclusion:** adopt the Workflow *patterns*, not the *runtime*. Dynamic Workflows are the right tool
for one-off, single-session fan-outs (audits, migrations, research) and should be documented as such —
separate from Nazgul's durable, HITL-capable, cross-session loop.

### Lessons folded in

- **Named invariant — "completed = cached, never re-executed."** A unit that reached
  `IMPLEMENTED`/`DONE` (with a commit SHA) is never re-implemented. Layers 1 (dispatch guard) and 2
  (re-work guard) mechanically enforce exactly this — the Workflow runtime gets it for free via result
  caching; we get it via guards. This is now the spec's headline invariant.
- **Deferred to a follow-up (`Review Board robustness`):** `/deep-research`'s "a claim the verifier
  could not check is **unverified**, not **refuted**" → a reviewer that errored/rate-limited/couldn't
  assess should be a non-blocking *unverified* verdict, not a rejection; plus an adversarial
  cross-check/voting posture for reviewers. These touch `agents/review-gate.md` (shared by BOTH engines),
  so they are out of scope here to avoid destabilizing the sequential engine — captured as their own
  objective.

## Relationship to other work

- FEAT-008 (Automation Heartbeat) is **parked** (spec/docs/tasks preserved) pending this fix, since its
  whole premise is auto-starting objectives under `--conductor`. Re-test FEAT-008 on the enforced
  conductor after this ships.
- This hardens FEAT-007; it does not change the graph-only invariant or the two unconditional hard stops.
