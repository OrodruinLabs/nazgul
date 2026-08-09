# Doc Gate — design

**Date:** 2026-08-09
**Status:** design approved, spec pending user review
**Reviewed by:** `architect-reviewer` (verdict `CHANGES_REQUESTED`, confidence 87) — every REJECT and CONCERN it raised is folded into the design below
**Verified against:** commit `c44add2`, worktree `.claude/worktrees/doc-gate-design`, baseline `99 files checked, 99 passed, 0 failed`

## Problem

`agents/doc-generator.md` produces the PRD, TRD, ADRs, and test plan that every downstream
agent treats as source of truth. Nothing reviews them.

- The review board gates **code only**. No document ever passes a reviewer. The planner
  consumes the TRD the moment it is written.
- The one existing document check — the post-loop doc-verifier gate at
  `scripts/stop-hook.sh:1077` — fires at objective **end**, after every task already
  consumed the docs, and only existence-checks event names, config keys, and script paths.
  It does not assess design soundness.
- The one honesty mechanism inside the generator, the Artifact Claim Evidence Ledger
  (`agents/doc-generator.md:112-148`), covers only generated-path claims, and `RULES.md:230`
  states its tier plainly: *"Nothing mechanically stops that claim; a reviewer must catch it."*

The whole pre-planning phase is model-driven prose in `skills/start/SKILL.md`. The stop-hook
is inert there by construction — `scripts/stop-hook.sh:952` exits unconditionally when
`TOTAL_COUNT == 0`.

## Motivating incident

On objective FEAT-030, the doc-generator reported six spec↔codebase contradictions —
including that `scripts/lib/nazgul-root.sh` cannot redirect to the main worktree. Those
findings went nowhere. The next pipeline action was "Dispatching the Planner," which
produced 13 tasks.

The finding was independently verified by direct probe from a worktree cwd with
`CLAUDE_PROJECT_DIR` unset:

```
resolved root  : .../.claude/worktrees/doc-gate-design
resolved nazgul: .../.claude/worktrees/doc-gate-design/nazgul
config.json at resolved path? : NO
```

Mechanism: `nazgul-root.sh:56` takes `git rev-parse --show-toplevel`, which in a worktree
returns the worktree's own toplevel; `_nr_has_marker` (`:44-46`) fails there because
`nazgul/` is gitignored and therefore absent; `:68` falls back to `candidates[0]`. A
subsequent `mkdir -p` **creates** the wrong tree rather than failing, so the failure is silent.

Scope precision the generator's summary omitted: `:49` returns `CLAUDE_PROJECT_DIR`
**unconditionally** when set, so every hook is unaffected. The defect window is exactly a
dispatched agent whose cwd is a task worktree resolving without an explicit designation.

Consequence for the objective statement — *"resolve … via `nazgul-root.sh` and
`branch.main_worktree_path`"* — it is **imprecise, not wrong**: `nazgul-root.sh` alone cannot
redirect to the main tree; it does so only when paired with an explicit `CLAUDE_PROJECT_DIR=`,
which `CLAUDE.md` already prescribes for agents. That correction should have gated planning.

The generalized defect, in this repo's own idiom: **a finding that nothing consumes is
indistinguishable from no finding.**

## Decisions

1. **AFK failure mode — severity split.** Architecture-invariant and security findings fail
   closed: the objective BLOCKS and waits for a human. Everything else proceeds with the
   dissent recorded. Mirrors the shipped `block_on_security_reject` posture — fail closed
   only where being wrong is expensive, keep the unattended night productive otherwise.
2. **Finding sources — both, one channel.** The doc-generator emits its own contradictions as
   a typed machine-readable artifact, **and** a reviewer reviews the docs. Both feed one
   severity split. The generator already produces blocking-grade findings for free; the
   reviewer supplies what a self-grader structurally cannot.
3. **Trigger — a staleness predicate, not a fixed phase.**
4. **Convergence — fix-first split.** Verifiable contradictions (doc claims X, code says Y)
   return to the doc-generator with bounded retries and converge, because code is ground
   truth. Judgment findings never enter the retry loop — they route straight to the severity
   split. Only findings with an objective answer can loop, so deadlock is impossible by
   construction.

## Architecture

### (a) Pre-planning gate — on the planner dispatch, not the Stop event

Enforced by a `PreToolUse` matcher on the `Agent` tool that blocks a `nazgul:planner`
dispatch when doc-gate evidence is absent for the current doc set. Precedent is in
production: `hooks/hooks.json:88-102` with `scripts/parallel-dispatch-guard.sh`, and
`RULES.md:92` states it verbatim — *"Subagent dispatch CAN now be pre-gated."*

**Why not the Stop event.** Gating `stop-hook.sh:952` keys on what the loop happens to hold
*when a turn ends*, which is not the pre-planning phase. In `DOCS_READY` the skill runs
doc-generator → planner inside one uninterrupted turn (`skills/start/SKILL.md:435-438`);
`DISCOVERY_DONE` (`:452-453`) and `FRESH` (`:466+`) do the same. So in AFK the planner
routinely runs in the same turn as the generator, tasks exist by Stop time, and the gate
never sees the state it was written for. In HITL, *"pause for doc review"* (`:436`, `:452`)
guarantees a stop in exactly that state. The gate would fire reliably only in the mode where
a human is already reading the docs, and unreliably in the mode designed for by decision 1.

**Backstop.** The `stop-hook.sh:952` branch survives, demoted, for the case where the planner
is reached by another route. It carries two mandatory properties:

- **A bounded attempt counter**, in the `read -r OBJ CNT` / non-numeric-coercion / `-lt 3`
  shape at `stop-hook.sh:1091-1101`, with a loud stderr line, typed event, and — on
  exhaustion — an attestation written in the (d) form recording `backstop_exhausted` as its
  verdict, so an exhausted gate is a readable decision rather than an absent file
  (`:1114-1118` is the shape, with the marker replaced by the content-keyed attestation). Line 952 precedes max-iterations (`:1230`), the budget ceiling
  (`:1240`), consecutive failures (`:1248`), and the parallel hard stop (`:1256`); a block
  there outranks all four. The hazard is already documented in this file at `:973-974`:
  *"A bounded attempt counter keeps an unwritable marker from bricking the loop (this exit
  path is BEFORE the max-iteration backstop)."* Decision 4's doc-generator retries count in
  **this same ladder** — two independent bounds around one gate can ping-pong.
- **An actively-driven-objective predicate.** `feat_id` ∧ `branch.feature` ∧ `objective` all
  non-null. Line 952 is the *"nothing is being driven, get out of the user's way"* branch —
  the opposite of the `IS_COMPLETE` branch (`:967`) the four post-loop gates live in.
  Blocking on mere file presence hijacks ordinary conversation.

Enumerated blast radius (docs present, zero tasks). Must **not** newly block:

| Case | Disposition |
|---|---|
| Interrupted objective, user now doing unrelated work | Excluded by the driven-objective predicate |
| HITL doc-review pause (`SKILL.md:436`) | Excluded — a human is already reviewing |
| Planner legitimately produced zero tasks | Excluded; must be able to admit there is nothing to do |
| Non-Nazgul repo | Safe — exits at `stop-hook.sh:23` |
| Freshly `init`'d project | Safe — no `nazgul/docs/*.md` yet |
| `/nazgul:reset` | Safe — archives `docs/` and `tasks/` together (`skills/reset/SKILL.md:87,90`) |
| New objective start | Safe — moves `plan.md, tasks/, reviews/, docs/, checkpoints/` in one step (`skills/start/SKILL.md:560`) |

### (b) Drift gate — exogenous-only

Each generated doc carries a `## Provenance` block: a base SHA plus the file-scope globs its
claims depend on. Drift is measured **against the merge-base with `branch.base`**, not raw
HEAD movement, and evaluated at objective/wave boundaries rather than per iteration.

**Why exogenous-only.** `git diff <doc-base>..HEAD --name-only` ∩ claimed globs is by
construction *the set of files the plan told implementers to change*. A TRD about the hook
engine declares `scripts/**`; task one edits `scripts/**`; the doc is "stale" at iteration 2
and every iteration after. That is the modal path, not an edge case.

**Degradation posture**, adopted verbatim from the IMPLEMENTED gate: base absent → weaker
check, **announced on stderr**; base present but unresolvable → treat the doc as **corrupt and
fire**. Never the silent `HEAD~1..HEAD` fallback that `files_modified_json`
(`scripts/lib/git-utils.sh:31-34`) takes on an invalid base — that is a silent clean bill of
health. Rebases, squash merges, and `gh stack sync` (`scripts/lib/stack-utils.sh:731-798`,
which can report conflict at exit **0**) all make a recorded base unreachable, so this path is
load-bearing, not theoretical. Each degradation emits a typed event, not stderr alone.

**Stated limit, so (b) is not mistaken for coverage it lacks:** drift detection is
structurally blind to a doc that was *wrong at its own base SHA with zero commits since* —
which is exactly the FEAT-030 case. Only (a) catches that.

**Self-attestation floor.** The generator authors the globs that decide whether its own doc is
re-reviewed, so an under-declared scope silently exempts it forever, and "no glob intersected"
would be indistinguishable from "no globs declared" — the collapse `RULES.md` §15 exists to
close. Therefore: a mechanical floor the generator cannot shrink below (union of path tokens
in the doc's own prose, plus the objective's task file scopes); missing, empty, or unparseable
`## Provenance` is **MAX staleness → fire**, never "nothing to compare."

### (c) A distinct `doc-reviewer`, not `architect-reviewer`

Rendered from `agents/templates/reviewer-base.md` plus a new `agents/templates/reviewer-domains.json`
entry (both files change together — standing invariant).

Reusing `architect-reviewer` collides with three name-keyed mechanisms, because the review
plumbing resolves units by **agent name**, not dispatch identity:

1. `_resolve_review_unit_for_agent()` (`scripts/subagent-stop.sh:197-217`) scans every
   `nazgul/reviews/*/.dispatch.json` for `.selected` containing `$AGENT` and returns the most
   recent by `created_at`. A doc-review dispatch has no manifest of its own, so it is
   attributed to the most recent **code** review unit. *(Verified by direct read.)*
2. `_append_review_receipt()` (`:264-282`) then writes
   `{unit: <that code unit>, reviewer: architect-reviewer, hash: <doc-review text>}` into
   `review-receipts.jsonl`. Under `review_gate.receipt_hash_enforcement` (`RULES.md:97`) that
   recomputes to `RECEIPT_MISMATCH` and **fails a code task's DONE gate**.
3. `subagent_empty_return` (§19) carries the wrong `unit` for every doc dispatch, degrading
   the exact signal §19 exists to produce.

Additionally, `architect-reviewer` is a default member of `review_gate.critical_reviewers`
(`RULES.md:95`) whose exhausted-`UNVERIFIED` resolution is defined against a **task** — and
decision (d) means there is no task, so that path has no target here.

The rename keeps everything reuse was for: the fenced `verdict:` grammar, §19 empty-return
detection via the `*-reviewer` suffix (`subagent-stop.sh:246-252`), and a
`models.review_by_reviewer` pin — while defining its own criticality rather than inheriting
task-shaped fail-closed semantics.

**Absent-reviewer degradation.** `doc-reviewer` is generated per project and may be absent.
The gate then runs on generator self-findings only and reports **NOTHING CHECKED** — never
self-findings presented as a clean board. Reported as the fixed-grammar coverage line
`<entry>: N scanned, M skipped (<reason>=<count>…), K checked, F findings` with `N == M + K`
asserted (`RULES.md:523-532`).

### (d) State — a file with content, keyed by content hash

`nazgul/docs/.review/<docs-hash>.json`:

```json
{
  "docs_hash": "…", "base_sha": "…", "verdict": "APPROVE|CHANGES_REQUESTED",
  "findings": [], "severity_split": {}, "dissent": [], "retries": 0, "decided_at": "…"
}
```

**Why content-keyed, not `feat_id`-keyed.** The doc-generator writes to fixed paths and
overwrites in place (`agents/doc-generator.md:92`), and `DOCS_READY`'s sanctioned action is
*"regenerate documents from current context, then run the planner"*
(`skills/start/SKILL.md:429-430`, step 5). A `feat_id` marker would therefore attest a
document set that no longer exists — the same vacuity class this codebase already fixed twice
(the `## Metadata` Base SHA satisfying the evidence gate; the coverage registry citing an
archived TRD section, `RULES.md:541-543`). Hashing the doc set means regenerating any document
mechanically invalidates the attestation. This is the `write_dispatch_manifest` /
`DIFF_HASH_STALE` primitive (`scripts/lib/review-provenance.sh`, `RULES.md:93`), and it
**unifies (a)'s key with (b)'s provenance** — one primitive, two enforcement points, no
disagreement between them.

**Why a file rather than a bare marker.** The four existing markers gate *post-loop advisory*
actions whose worst failure is skipping a nice-to-have at the very end. This gates a
*pre-loop* action the whole plan derives from, and decision 1 lets it **BLOCK an objective
awaiting a human**. A content-free marker carries no verdict, findings, dissent, or retry
count, and appears in no checkpoint — the schema (`stop-hook.sh:691-720`) snapshots
`task_statuses`, `plan_snapshot`, `git`, `active_task` and nothing else. "BLOCKED on an
architecture-invariant doc finding, awaiting human" would survive only as the absence of a
file plus a vanished stderr line. That regresses Rule 10 / `RULES.md` §4, worst in AFK where
nobody reads stderr. Therefore: **one checkpoint field and one Recovery Pointer line.**

**Why still not a pseudo-task.** `TASK-000` would corrupt `count_tasks_and_find_active`, every
`*_COUNT`, `resolve_review_unit()`, the aggregate-review walk (`stop-hook.sh:479-536`), and the
granularity coverage gate. Doc review is phase-level state and stays out of the state machine.
**No new state-machine edge, no `task-transition.sh` change.**

### (e) The plan-invalidation edge

Both enforcement points above terminate at the *document*. The motivating incident is not
"a doc was wrong" — it is **"13 tasks were derived from a doc that was wrong."** Without this
edge, a drift gate firing at iteration 9 corrects a TRD claim while `nazgul/plan.md`, the task
manifests, their file scopes, their Wave Groups, and any task already `IMPLEMENTED`/`DONE`
under the old claim stay untouched and unannotated — a *correct document over an uncorrected
plan*, which is strictly worse than today because the doc now reads as verified.

Therefore a confirmed **architecture-invariant** finding must:

1. Record the affected doc, claim, and finding id into an artifact the planner reads; and
2. Name what happens to tasks already derived from that claim — replan, annotate, or
   explicitly "nothing, and here is why that is acceptable."

Because (d) forbids new state-machine edges, the honest minimum is **an annotation plus a
required planner re-read, not a status change** — and the spec says so out loud rather than
leaving it implicit, in the same register as `RULES.md:92`'s admission that its granularity
gate is *"post-hoc defense-in-depth (the review already ran at the wrong scope)."*

### (f) Telemetry

A new typed `doc_gate` event with reasons `fired` / `satisfied` / `degraded_no_reviewer` /
`backstop_exhausted`. **Not** `stop_gate`: every existing emission of that type precedes a
run-ending `exit 0` or a degradation (`stop-hook.sh:109`, `:160`, `:165`;
`stack-utils.sh:357,378,385`). Using it for an `exit 2` that *extends* the run would make the
event stream unable to separate the two — the exact distinction *"a mechanism that fails must
not look like a mechanism that had nothing to do"* was introduced to preserve.

### (g) Config surface

Standing trio, in one change: defaults in `templates/config.json`; an **additive** step in
`scripts/migrate-config.sh` with a `schema_version` bump (chain currently at v36); coverage in
`tests/test-config-schema.sh`. Keys: pre-planning toggle, drift toggle, AFK severity-split
policy, retry bounds.

A kill switch is mandatory, matching all four sibling gates — and per the shipped idiom it
suppresses **the block only**, never detection or telemetry (`CLAUDE.md` on
`guards.red_run_evidence`). Read with `if .x == false then "false" else "true" end`, never
`// true`, which false-coalesces an explicit `false` back on (`stop-hook.sh:258-260`).

### (h) Coverage honesty

If the doc gate becomes a checking entry point it joins the `RULES.md` §15 registry **and**
`tests/test-coverage-honesty.sh` in the same change — that registry is asserted, not assumed
(`RULES.md:534-543`).

## Open — not yet brainstormed

Settled here as proposals; they need review before planning:

- The exact schema of the generator's typed contradiction artifact (decision 2's first channel).
- The classification rule separating *architecture-invariant* from ordinary findings — the cut
  decision 1's severity split depends on entirely.
- The test plan, including the red-run evidence a `scripts/**` change requires
  (`guards.red_run_evidence`, `RULES.md` §15).

## Verification performed for this design

| Claim | Method | Result |
|---|---|---|
| `nazgul-root.sh` resolves to worktree root | Direct probe, `CLAUDE_PROJECT_DIR` empty, worktree cwd | Confirmed |
| Stop-hook inert pre-planning | Read `stop-hook.sh:952-954` | Confirmed |
| Bounded-counter hazard at line 952 | Read `stop-hook.sh:967-980` | Confirmed — documented in-file at `:973-974` |
| Reviewer name-keyed unit resolution | Read `subagent-stop.sh:197-217`, `:264-282` | Confirmed |
| Baseline green at `c44add2` | `tests/run-tests.sh` | 99 scanned, 0 skipped, 99 checked, 0 findings |
