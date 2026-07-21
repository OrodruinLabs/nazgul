# Parallel Execution Collapse — Design

**Date:** 2026-07-21
**Status:** Approved for planning
**Supersedes:** the `conductor` execution engine (FEAT-007, v2.9.0–v2.15.x)

## Problem

The Conductor engine runs `agents/conductor.md` as a background subagent whose job is to
spawn other subagents (implementers, review boards) and wait for each before advancing a
wave-based task graph. The platform does not support that design:

- Since Claude Code v2.1.198, subagents run in the background by default. Nested Agent
  calls made *from inside a subagent* do not block.
- Background-completion notifications are documented to re-engage only the **main
  session**. There is no documented mechanism that gives a nested parent subagent a fresh
  turn when its children finish.

Result: the conductor stalls at every await point in its own Step 5 — wave boundaries,
post-commit review dispatch, and review tallying — and each manual resume costs ~150k
tokens to re-orient. The work quality is fine; the orchestration layer is the defect.

Research ranking (full findings in the session that produced this spec; key sources:
code.claude.com/docs sub-agents, hooks, workflows, agent-teams pages):

1. **Main-session driver + Stop hook** — only fully documented AND crash-durable option.
   Stop-hook `decision:"block"` + injected instructions is first-class; multiple Agent
   calls in one message run concurrently; the main session reliably re-engages.
2. Workflow tool — awaited `agent()` fan-out, but not crash-durable across CC exit and
   cannot be launched programmatically by a plugin (human-typed trigger only, v2.1.210).
3. Agent Teams — SendMessage wakes idle teammates, but experimental, teammates cannot
   background their children, and no session resumption for teammates.
4. Background subagent + watchdog — automates the babysitting instead of eliminating it;
   drive mechanism undocumented.

## Decision

Delete the conductor as a separate engine. There is **one engine** — the existing
sequential stop-hook loop — with a new **parallel dispatch option**. The main session is
the only driver; parallelism comes from the documented concurrency mechanism (multiple
Agent dispatches emitted in one message from the main session).

A new ADR records the platform rationale so the background-conductor design is not
reinvented: *nested subagents are not re-engageable drivers; only the main session is.*

## 1. Config & CLI surface

- `execution.engine` is removed.
- New keys: `execution.parallel` (bool, default `false`), `execution.max_parallel`
  (int, default 3; inherits old `conductor.max_parallel` on migration).
- `/nazgul:start --parallel` enables it. `--conductor` remains as a deprecated alias
  (sets `parallel: true`, prints a deprecation note).
- `migrate-config.sh` bumps schema v25 → v26 (v25 was taken by FEAT-012):
  - `execution.engine == "conductor"` → `execution.parallel: true`
  - `conductor.max_parallel` → `execution.max_parallel`
  - `conductor.gates.approve_graph` → `execution.gates.approve_plan` (approve the
    plan's wave layout once, up front)
  - `conductor.gates.approve_each_wave` → `execution.gates.approve_batch` (approve
    each parallel batch before dispatch)
  - `conductor.gates.approve_final_pr` → `execution.gates.approve_final_pr`
    (unchanged semantics, relocated key)
  - `nazgul/conductor/` runtime dir (incl. `graph.json`) deleted by migration
- The two hard stops (any BLOCKED task, any non-APPROVE security verdict) remain
  unconditional and mode-independent, enforced by the stop-hook every iteration.

## 2. Batch selection — deterministic shell

New lib `scripts/lib/parallel-batch.sh`, absorbing `compute_waves` (Kahn layering) and
the gate-effective helper from the retired conductor libs.

`compute_dispatch_batch <tasks_dir> <plan_md> <max_parallel>` →
`{tasks: [...], parallel: bool, reason}`.

Rules — every doubt falls back to a batch of one (today's proven sequential behavior):

- Candidates: READY tasks whose manifest `Depends on` entries are all DONE. Manifests
  are the only state source; there is no stored graph.
- A multi-task batch forms only when plan.md's `## Wave Groups` explicitly lists ≥2 of
  the candidates on the same wave line (Planner already emits this).
- File scopes (from manifests) must be pairwise disjoint. Any overlap, missing scope,
  or unparseable Wave Groups section → batch of one.
- Batch size capped at `max_parallel`.

`compute_waves` also serves `/nazgul:status` and the upfront plan-approval display,
computed on demand from manifests.

## 3. Dispatch contract

**N = 1 (or `parallel: false`):** byte-identical to today's loop. In-place
implementation, single implementer dispatch, then review-gate. No behavior change.

**N > 1:**

1. The stop-hook's dispatch instruction tells the main session to emit all N implementer
   dispatches **in one message** (documented concurrency), each given only its task ID,
   manifest path, and file scope, and each running **in its own git worktree**
   (implementers already carry `EnterWorktree`/`ExitWorktree`; `worktree-utils.sh`
   provides naming/helpers). Shared-working-tree concurrent commits would race the git
   index — worktrees are mandatory for multi-task batches.
2. Every dispatch prompt includes `NAZGUL_UNIT: TASK-NNN` (guard contract, §5).
3. When all N return, the **main session merges the worktree branches sequentially**
   into the feature branch (disjoint scopes ⇒ clean merges), records each commit SHA in
   its task manifest (evidence gate for IMPLEMENTED), then dispatches the N review
   boards — also in one message. Reviewers are read-only; no isolation needed.
   Review-gate internals are unchanged.
4. **Rework is always sequential.** A task ending CHANGES_REQUESTED is picked up by a
   normal single-task iteration via the existing retry machinery. No parallel rework.

## 4. Stop-hook changes

One new branch in the CONTINUE section (~`scripts/stop-hook.sh:1088`): when
`execution.parallel` is true, call `compute_dispatch_batch` and emit the batch
instruction instead of the single-task instruction. Everything else is untouched and
applies per task: iteration counting, budget accumulation, evidence gates (commit SHA
before IMPLEMENTED, review dir before IN_REVIEW), consecutive-failure tracking,
checkpoints, Recovery Pointer rewrite, post-loop gates.

This also removes the latent engine-interference bug: today's stop-hook has no conductor
awareness and would emit competing sequential dispatch instructions under
`execution.engine == "conductor"`. With one engine there is nothing to fight.

## 5. Guards

Both guards drop the `nazgul/conductor/.session` activation marker (written only by the
deleted conductor agent) and activate on: `nazgul/config.json` exists AND
`execution.parallel == true`. Existing per-guard kill-switches remain.

- **conductor-dispatch-guard.sh** (PreToolUse/Agent) — keep Rule 2 only: parse
  `NAZGUL_UNIT: TASK-NNN` from the dispatch prompt; block re-dispatch of an implementer
  for an IMPLEMENTED/DONE task or a review board for a DONE task. Rule 1 (blocking
  `run_in_background`) is dropped — concurrent dispatch from the main session is now the
  intended mechanism, and the main session reliably collects completions.
- **conductor-rework-guard.sh** (PreToolUse/Write|Edit) — logic unchanged (block edits
  to a DONE task's file scope mid-objective), new activation key only.
- **subagent-stop.sh** — delete the graph.json orphan detector and the
  `.resume-needed` breadcrumb (written today, consumed by nobody). The Stop hook is the
  reader now, structurally: a dead batch means the session stops → stop-hook fires →
  state re-derived from manifests → re-instruct.

Guard scripts may be renamed (`parallel-dispatch-guard.sh`, `parallel-rework-guard.sh`)
during implementation; hooks.json entries update accordingly.

## 6. Deletions & migration

Deleted: `agents/conductor.md`; `scripts/lib/conductor-graph.sh`,
`conductor-gates.sh`, `conductor-router.sh` (after migrating `compute_waves` + gate
helper into `parallel-batch.sh`); conductor checkpoint format; `nazgul/conductor/`
runtime dir; the engine fork in `skills/start/SKILL.md`; conductor-specific tests.

Docs updated: CLAUDE.md, RULES.md, README, CHANGELOG, plus a new ADR
(platform rationale). Version bump: v2.16.0.

**In-flight conductor runs** (e.g., a project mid-objective at 4/19 DONE): after plugin
update, config migration flips to `parallel: true` and deletes `nazgul/conductor/`.
Task manifests were always canonical (graph.json only mirrored them), so the next
`/nazgul:start` resumes the remaining tasks through the ordinary loop. No manual surgery.

## 7. Failure handling

- **Partial batch failure:** outcomes are independent. Successes merge and get reviewed;
  a failed/BLOCKED task keeps its state and the stop-hook's existing consecutive-failure
  and hard-stop logic sees it at the next boundary. One bad task never poisons its
  batchmates' completed work.
- **Merge conflict despite disjoint scopes** (implementer strayed out of scope): stop
  the merge, reset that task to CHANGES_REQUESTED with a note, keep its worktree branch
  for inspection. Never force-merge.
- **Hard stops** are checked every stop-hook iteration, which is every batch boundary —
  one enforcement point, unconditional in every mode including yolo.
- **Crash/compaction mid-batch:** manifests + Recovery Pointer + worktree branches on
  disk are the truth. Orphaned worktrees are detected by naming convention and either
  resumed (a commit exists) or discarded (dirty/no commit) — a deterministic rule, no
  model judgment.

## 8. Testing

- Unit tests for `compute_dispatch_batch`: dep-gating, wave-group parsing, file-scope
  overlap → fallback, missing/ambiguous Wave Groups → fallback, `max_parallel` cap,
  single-candidate passthrough.
- Stop-hook tests: parallel config emits the batch instruction; sequential config emits
  today's instruction **byte-identical** (regression guarantee).
- Migration test: v25 conductor config → v26, including gates mapping and
  `nazgul/conductor/` cleanup.
- Guard tests re-pointed at the new activation key; conductor-specific tests deleted
  with the code they covered.
- Full existing suite stays green; sequential mode is behaviorally unchanged.

## Out of scope

- Parallel rework/retry (rework is always sequential by design).
- The `team` dispatch backend and Agent Teams coordination (no current caller; the
  router that offered it is deleted).
- Any change to review-gate internals, the task state machine, or post-loop gates.
