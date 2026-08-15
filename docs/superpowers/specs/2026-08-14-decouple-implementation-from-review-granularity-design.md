# Decouple implementation concurrency from review granularity

**Date:** 2026-08-14
**Status:** Design approved, not yet planned
**Plugin version at design time:** 2.31.0 (config schema 36)

## Problem

`execution.parallel` only activates when `review_gate.granularity` is `"task"`. A project
configured for feature-level review — the shape most real objectives want — is forced fully
sequential, so it pays one task's latency at a time to buy a review cadence that has nothing to do
with implementation.

Implementation concurrency and review cadence are independent concerns. Nothing about "review these
six tasks as one unit" implies "implement them one at a time."

This is not hypothetical. An operator on taxguardian-core ran parallel task branches under
group/feature review, was blocked by `scripts/git-hooks/pre-merge-commit`, and merged with
`--no-verify` — recorded in `nazgul/inbox/premerge-guard-not-granularity-aware-deadlocks-integration.md`
(p1). The framework fights this configuration at three independent layers.

## Why the coupling exists

`--parallel` does not conflate the two concepts abstractly — it conflates them in one string. The
batch dispatch instruction (`scripts/stop-hook.sh`, the `DISPATCH_INSTR` built under the
`EXEC_PARALLEL` branch) is five fused steps:

1. Dispatch one implementer per task, concurrently
2. Wait; record each branch-tip SHA; set IMPLEMENTED
3. **Dispatch one review-gate per task**
4. **Wait; merge only tasks that reached DONE**
5. Do not start work outside the batch

Steps 3-4 hardcode per-task review into the middle of an implementation instruction. That is the
whole reason the branch demands `granularity == "task"`. The seam is already visible: 1-2 are
implementation, 3-4 are review-and-merge.

**Prior-art check.** `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md` records this
coupling under **D-004 "Follow-on facts recorded for the release"** — a consequence documented after
the fact, not a decision with a rationale. It carries no closing rule. By contrast D-003 ("do not
reintroduce a background-subagent driver unless the platform documents parent re-engagement on child
completion") does carry one, and **this design does not re-open it**: the foreground stop-hook driver
is unchanged; only the instruction text it emits differs.

## Decisions

**D-1 — Task branches merge into the feature branch at IMPLEMENTED, before review.**
The aggregate board then reviews one combined diff (feature branch vs base), exactly as sequential
group/feature does today. Unreviewed code sits on the feature branch — but it already does under
sequential group/feature, so this introduces no new class of exposure. Inter-task conflicts surface
at merge time, while the work is fresh, rather than after a board has already approved.

*Rejected:* holding branches unmerged until the board approves. It would force the board to review N
separate branch diffs instead of one, and would surface conflicts only after approval, potentially
invalidating the verdict.

**D-2 — No new config key.** `execution.parallel` + `execution.max_parallel` already express
"implement up to N concurrently," and `compute_dispatch_batch` already uses plan waves as its
selection unit. A named `execution.granularity` enum would mostly restate what exists while adding a
schema bump, a migration, and a 3x3 matrix of enum combinations to define and test. Revisit only if
real usage shows the existing keys cannot express something wanted.

**D-3 — Rework after an aggregate rejection goes to a fresh branch per rejected task**, re-merged at
IMPLEMENTED, after which the board re-runs over the updated diff. Symmetric with the first pass and
reuses the same machinery.

## Change set

Four sites, all existing. No new files, no schema change, no migration.

### 1. `scripts/stop-hook.sh` — remove the gate

Drop `&& [ "$GRANULARITY" = "task" ]` from the parallel-batch override condition (currently
`~:1370`). Batch dispatch becomes reachable at any review granularity.

### 2. `scripts/stop-hook.sh` — split the batch instruction

Two variants, selected on `GRANULARITY`:

- **`task`** — unchanged five steps. Byte-identical to today's text; this path must not regress.
- **`group` / `feature`** — steps 1-2 only: dispatch implementers concurrently, wait, record full
  40-character branch-tip SHAs under each manifest's `## Commits`, set IMPLEMENTED, merge each task
  branch into the feature branch, then **park**. No review dispatch. No DONE. Control falls through
  to the existing `AWAITING AGGREGATE REVIEW` marker, and the aggregate board fires from the
  existing path (`~:1344`) once the whole unit is IMPLEMENTED.

The aggregate path is already correct. It is simply unreachable today with parallel enabled.

### 3. `scripts/lib/parallel-batch.sh` — granularity-aware dependency rule

`compute_dispatch_batch` currently hardcodes (`~:244`):

```sh
[ "$(get_task_status "$tasks_dir/$d.md" "PLANNED")" = "DONE" ] || { ok=0; break; }
```

Under group/feature nothing reaches DONE before the board, so **every candidate is rejected and the
batch silently falls back to sequential** — change 1 would appear applied while nothing changed.
This is the failure mode most likely to be missed in review, because it produces no error.

Replace with `ttg_dependency_satisfied`, which is already granularity-aware (a dependency at
IMPLEMENTED or later satisfies under group/feature; `task` still demands DONE/APPROVED) and already
used at `scripts/lib/task-transition-guard.sh:522`. Requires sourcing `task-transition-guard.sh`;
`parallel-batch.sh` currently sources only `task-utils.sh`.

### 4. `scripts/git-hooks/pre-merge-commit` — granularity-aware verdict rule

Accept IMPLEMENTED as a valid merge precondition under group/feature. Already filed as p1 with a
field-verified bypass; land it first or fold it into this objective.

## What does not change

Stating this explicitly because the change reads larger than it is:

- `compute_dispatch_batch`'s wave membership and pairwise-disjoint file-scope selection
- The aggregate review path and `resolve_review_unit()`
- `scripts/parallel-rework-guard.sh` — already correct. It blocks edits to tasks at
  `DONE|IMPLEMENTED` (`:79`); a board rejection moves a task to CHANGES_REQUESTED, which exits that
  set. Parked tasks are protected during the wait and reworkable after the verdict.
- `scripts/parallel-dispatch-guard.sh`
- The task state machine, the review board, and every evidence gate (commit SHA, Base SHA descendant,
  red-run)
- Config schema, `migrate-config.sh`, `templates/config.json`

## Error handling

**Merge conflict during batch integration.** N branches merge at IMPLEMENTED with no review between
them. Sequential group/feature already merges unreviewed work to the feature branch, but one task at
a time, so a conflict surfaces alone; in parallel, a conflict on merge 3 of 4 leaves the unit
partially integrated.

Defined behavior, reusing what the task-granularity path already specifies: `git merge --abort`, set
that task CHANGES_REQUESTED with a note, keep its branch and worktree for inspection, continue
merging the remaining tasks. Never force-merge. The unit cannot reach aggregate-ready until that task
is reworked, which is correct.

**Interaction with the aggregate-board deadlock (p0).** A merge-conflicted task at CHANGES_REQUESTED
holds the unit back — intended. But a task that ends up BLOCKED strands the entire unit permanently
under today's readiness predicate. `nazgul/inbox/aggregate-review-board-deadlocks-on-blocked-task.md`
(p0) is therefore a genuine prerequisite, not merely related work.

**Batch falls back to one.** Every existing fallback is preserved: any doubt in
`compute_dispatch_batch` yields a batch of one, which is proven sequential behavior.

## Telemetry

Emit a typed event when a batch fires under group/feature, carrying granularity, batch size, and the
task ids — so "implemented 4 concurrently, reviewed once" is distinguishable in the record from
either mode alone. Per RULES.md §15, a run that used a new path must not be indistinguishable from
one that did not.

## Testing

Extend `tests/test-parallel-batch.sh` and the stop-hook tests:

1. **Red first:** fixture a `feature`-granularity project with a wave of 3 READY tasks, disjoint
   scopes, deps IMPLEMENTED-not-DONE. Assert `compute_dispatch_batch` returns `parallel: false`
   today — this pins change 3's failure mode, which is silent.
2. Post-change: same fixture returns a 3-task batch.
3. `task` granularity: batch selection and instruction text unchanged (byte-comparison against the
   current instruction to prove no regression).
4. `feature` granularity + parallel: the emitted instruction contains no review-gate dispatch and
   ends in the parked/awaiting state.
5. Aggregate readiness is reached after the batch parks, and the board dispatches once over the
   combined diff naming all batch tasks.
6. Merge-conflict path: one task conflicts, is set CHANGES_REQUESTED, its branch survives, the other
   two merge, the unit is not aggregate-ready.
7. The typed event fires with correct granularity and batch size.

Capture red-run evidence against the pre-change base per ADR-019; cases 2, 4, 5, 6 and 7 must fail
before the change.

## Ordering

Genuine prerequisites, in order:

1. `red-run-hardcodes-nazgul-own-test-harness.md` (p0) — blocks `IN_PROGRESS -> IMPLEMENTED` in
   monorepos; nothing parks without it.
2. `aggregate-review-board-deadlocks-on-blocked-task.md` (p0) — a blocked task in a parallel batch
   strands the unit permanently without it.
3. `premerge-guard-not-granularity-aware-deadlocks-integration.md` (p1) — change 4 above; land
   first or fold in.

This objective is realistically third or fourth in sequence, not a cold start.

## Open items

None blocking. D-2 leaves the named `execution.granularity` enum as a possible follow-on, to be
decided by evidence from real use rather than up front.
