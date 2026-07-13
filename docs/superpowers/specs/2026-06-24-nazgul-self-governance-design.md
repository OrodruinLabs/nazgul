# Nazgul Self-Governance — Program Design

> Status: DRAFT for review. A program of 4 linked objectives, not one spec.
> Goal: make Nazgul's stated rules actually enforced by the system, not merely
> requested of an agent. Born from the FEAT-001 run, where review granularity
> drifted, the loop leaked runtime state into a PR, and a haiku post-loop agent
> shipped invented facts in docs/CHANGELOG.

## Thesis

Nazgul's enforcement spine is real — 11 rules are held by deterministic guards
(state machine, evidence gates, lean comments, the learning gate, read-only
reviewers via tool allowlist). The failures cluster in two seams:

1. **Boundary leak (Tier 2):** rules coded into `stop-hook.sh` hold only when the
   hook drives the loop. A human or orchestrator that dispatches agents directly
   routes around them. (Granularity drifted this way during FEAT-001.)
2. **Advisory gap (Tier 3):** rules that live as prose in an agent spec, or that
   are semantic and no shell guard can check. All three FEAT-001 follow-up bugs
   live here.

RULES.md:3 claims "every rule here is checked by a hook, agent, or script." The
"**or agent**" is the loophole — "checked by an agent" means *requested*, not
*enforced*.

## Platform constraint (verified 2026-06-24, claude-code-guide)

`PreToolUse` **cannot reliably gate subagent dispatch** (the `Task` tool): no
documented matcher name, no input schema exposing the subagent type/prompt, and
`SubagentStart` fires *after* the spawn. Documented, reliable `PreToolUse`
matchers are `Bash`, `Edit`, `Write`, MCP tools. Consequence: mechanical
mutation invariants CAN be hard-guarded; mis-scoped review dispatch CANNOT be
prevented at dispatch — it must be caught at the completion gate instead.

## The four enforcement levers

| Lever | What it is | Reliable for | Used today |
|-------|-----------|--------------|-----------|
| 1. PreToolUse guard | Shell, pre-call, returns block, driver-independent | Mutation invariants on Bash/Write/Edit | pre-tool, task-state, lean-comments guards |
| 2. Stop-hook gate | Blocks loop progress / NAZGUL_COMPLETE | Completion & sequencing invariants | evidence gate, learning gate |
| 3. Tool allowlist | Agent can't call the tool at all | Capability restriction | read-only reviewers |
| 4. Mandatory gated verifier | A verifier whose marker the stop-hook requires | Semantic rules (doc accuracy) | learning-gate pattern (reusable) |

## Rule inventory (classified by actual mechanism)

**Tier 1 — Enforced (11):** state-machine transitions; source-edit-requires-IN_PROGRESS;
new-task-PLANNED/READY (all `task-state-guard.sh` exit 2); lean comments
(`lean-comments-guard.sh`); destructive cmds + force-push-to-protected
(`pre-tool-guard.sh`); IMPLEMENTED-requires-SHA + DONE-requires-review-dir-with-
`verdict: APPROVE` (`stop-hook` + `review-evidence.sh`); all-reviewers-approve
(verdict-level via review-evidence); learning gate (`stop-hook` blocks
NAZGUL_COMPLETE); reviewers read-only (tool allowlist); iteration/failure/budget
ceilings (`stop-hook`).

**Tier 2 — Leaks at boundary (3):** review granularity (`stop-hook:835` aggregate
DELEGATE, bypassed by manual dispatch); dispatch sequencing; wave gating
(also dormant — `wave_execution` default unset).

**Tier 3 — Advisory / unenforced (7):** don't-track-`nazgul/`-in-local-mode (no
guard — bug #1); never-commit-to-base-mid-loop (only force-push guarded);
docs/CHANGELOG-match-code (semantic, no gate — bug #3 cluster); review-capture
artifacts (gitignore-partial — bug #2); implementer file_scope (prose); tests-
pass-before-review (prose; config flag unverified); follow-patterns / address-all-
feedback (semantic — reviewer-only).

---

## Objective 1 — Mechanical mutation guards + honest RULES.md

**Lever 1 + doc truth. Risk: low. Independent. Do first.**

Scope:
- **Local-mode tracking guard:** a `PreToolUse` Bash guard that, when
  `config.install_mode == "local"`, blocks any `git add`/`git commit` that would
  stage a `nazgul/` path. (Root cause of bug #1 — the loop force-committed
  runtime state into PR #41.)
- **Base-branch commit guard:** block a commit to `branch.base` (e.g. `main`)
  while a loop is active and a `branch.feature` is set. (Today only force-push is
  guarded.)
- **File-scope guard:** extend the Write/Edit guard so an implementer edit to a
  path outside the active task's `file_scope` is blocked until the manifest scope
  is updated. (Currently implementer-prose only.)
- **Honest RULES.md:** rewrite line 3 and annotate each rule with its real tier
  (enforced / hook-driven-only / advisory). Truth in advertising — the doc should
  not claim enforcement it doesn't have.

Acceptance: each guard returns block (exit 2) with an actionable message; bash
unit tests per guard (incl. the local-mode-add and base-commit cases); RULES.md
tier annotations match the verified inventory; full suite green.

Open detail: the commit/add chokepoint. FEAT-001 evidence suggests the loop
force-adds `nazgul/` state somewhere in the commit path — locate the exact site
(`stop-hook.sh` and/or agent commit prose) and decide whether the guard alone
suffices or the force-add itself must also be gated on `install_mode`.

## Objective 2 — Sequencing authority (close the boundary leak)

**Lever 2 (completion gate), NOT a dispatch guard. Risk: high. Needs the platform
constraint above.**

Since dispatch can't be pre-gated, enforce at completion + detect post-hoc:
- **SubagentStop detector:** when a review-gate subagent stops, record the review
  unit it actually covered (it already emits `reviewer_verdict` events post-bus).
  Compare against `review_gate.granularity`.
- **Stop-hook reconciliation:** refuse NAZGUL_COMPLETE (or flag loudly) if a task
  reached DONE through a review unit that violates the configured granularity.
- **Honest scope:** document that *manual/interactive* review dispatch bypasses
  stop-hook sequencing; in autonomous AFK/YOLO the stop-hook is the driver and
  granularity already holds. The detector is defense-in-depth for the manual case.

Acceptance: a per-task review-unit record exists; a granularity violation is
detected and surfaced; completion is blocked or loudly flagged on violation.

## Objective 3 — Semantic verifier gates

**Lever 4. Risk: medium. Reuses the learning-gate pattern.**

- **Doc-accuracy verifier:** a post-loop verification agent that cross-checks
  generated docs/CHANGELOG against the code (e.g. event names in CHANGELOG exist
  in the emitters) and writes a completion marker the stop-hook requires before
  NAZGUL_COMPLETE — exactly how the learning gate works. Catches the haiku
  hallucination class (invented event names, fictional "mv-based swap") before it
  ships, instead of relying on an external bot.
- Leave pure pattern-adherence to the existing reviewers (genuinely reviewer-only).

Acceptance: a doc/code drift is caught and blocks completion until resolved;
no false-positive on accurate docs; honors an opt-out flag.

## Objective 4 — Defaults overhaul

**Risk: low–med. Parallel default depends on Objective 2.**

| Setting | Current | → | Rationale |
|---------|---------|---|-----------|
| `review_gate.granularity` | task | **group** | Per-task is the expensive default; group matches waves |
| `parallelism.wave_execution` | unset/off | **on — after Obj 2** | Parallel is on in name, inert in fact; true fan-out needs gating enforced |
| `models.post_loop` | haiku | **sonnet** (or rely on Obj 3 gate) | Haiku shipped invented doc facts |
| `default_mode` | null | keep null | Explicit per-run consent is a safety feature |
| `confidence_threshold` / `require_all_approve` / `auto_approve_concerns` | 80 / true / true | keep | Behaved correctly |
| `formatter` / `afk.auto_commit` / `auto_pr` | off / true / true | keep | Sensible |

Migration: a `migrate_N_to_N+1` that flips granularity→group and post_loop→sonnet
for existing projects (additive, idempotent), template bump. Note: defaulting
granularity→group also *shrinks* the Objective-2 leak surface.

## Sequencing

1. **Objective 1** — low risk, high trust, fully feasible. Ship first.
2. **Objective 2** — architectural; gated on the (now-answered) platform
   constraint; build the detector + completion reconciliation.
3. **Objective 3** — doc-accuracy verifier (reuses learning-gate plumbing).
4. **Objective 4** — defaults; the parallel-by-default flip lands only after
   Objective 2 makes wave gating safe.

Each objective is its own `/nazgul:plan` cycle (spec → tasks → loop), the same
flow that shipped FEAT-001.
