# Backlog Remediation Programme

**Status:** chartered, not started. Architect-validated 2026-08-23 (`CHANGES_REQUESTED`, confidence 88 — the
corrections below are already folded in).

**Thesis:** 144 open issues on a 353-file, 66-script repo are **not 144 independent defects**. A
classification pass over all 144 found they collapse into 13 root-cause classes plus 22 residue —
roughly 96% of the real defect backlog. Fixing a class kills its instances *and* the ones not yet filed.

That thesis survived architect review. The programme built on it did not survive intact, and this
document is the corrected version.

---

## Move 0 — re-derive before anything is planned (NOT code)

**Land PR #240, then PR #245. Then re-derive every class's membership against post-merge `main`.**

This is not caution, it is mechanical necessity. Three reasons:

1. **`create_feature_branch` will refuse.** FEAT-027 shipped an assertion — for *all* users regardless of
   the stacking opt-in — that the checked-out branch equals `branch.base`, closing the accidental-stacking
   hazard. `execution.stacking.enabled` is `false` here. Branching a new objective off FEAT-031's unmerged
   tip is not inadvisable; **the shipped mechanism refuses it.** Starting early means enabling an
   unexercised opt-in or routing around our own guard.
2. **The backlog is stale by 15–18 issues.** They close on merge. Until then you cannot tell which of a
   class's members are already dead.
3. **PR #245 overlaps #240 on 15 files.** A third branch touching `scripts/**` — which every early class
   does — makes a three-way conflict on the guard surface, during a remediation about guard correctness.

**Move 0's deliverable is this document's class table, re-counted.** Half a day of mechanical work:
re-run the guard inventory's own reproducing grep (`docs/guard-fail-open-inventory.md:62-71`) and
re-derive its 125/90/18/17 split; re-check the six stdin rows `read-hook-payload.sh` closed and
TASK-050's instance; confirm which dead-on-merge issues sat in which class; record every delta as
**measured**, not carried forward.

> A count carried forward unverified is exactly the failure this repo keeps writing rules about
> (RULES.md §15).

---

## Standing clause — binds every objective below

> **A new defect surfaced mid-objective is filed to `nazgul/inbox/` with a reproduction, and the
> objective continues. Absorbing it is a scope violation, not diligence.**

This is the first clause of every exit criterion, not a closing paragraph. The evidence for why:
FEAT-031 chartered 14 tasks, shipped 50, and its plan document was never updated — it is 3.6× wrong on
disk today.

---

## Why one class per PR, and not the two obvious alternatives

| Shape | Verdict |
|---|---|
| **Waves inside one objective** | Not an execution mode here. `execution.parallel: false`; the Wave column is dependency depth and file-overlap ordering only. Buys a nicer plan document, changes nothing about execution or review. |
| **One 13-class mega-objective** | FEAT-031 again at 4× scale. One objective is one review unit under `feature` granularity; `FEATURE-FEAT-031` needed nine boards at roughly this size. |
| **One class = one objective = one PR** | **Recommended.** Keeping the objective small is the *only* lever on board size, because granularity is global config, not per-objective. Each merge retires issues visibly. A wrong class costs one objective, not the programme. |

Two options considered and rejected with reasons:

- **Switch `review_gate.granularity` to `"task"`** — would shrink boards, but changes the
  dependency-satisfaction rule globally (`ttg_dependency_satisfied` demands DONE/APPROVED under `task`,
  IMPLEMENTED-or-later under `group`/`feature`). A state-machine semantics change mid-remediation is the
  wrong risk.
- **Enable `execution.parallel`** — requires disjoint file scopes. C3, C6, C7, C8 and C9 all converge on
  `scripts/**` and the same handful of guards. Parallelism is unavailable *in practice*, not merely
  disabled.

---

## Dependency graph

- **C15 precedes everything.** `red-run.sh:965` rewrites the manifest wholesale with no lock; every
  class's tasks owe red-run evidence; a corrupted manifest under the reconciliation pass costs a
  quarantine plus a `repair`. A tax paid per task, on every subsequent class.
- **C2 → C3 (hard).** The shared payload reader is the *fix mechanism* for C3's largest coherent
  sub-class. C3 cannot be sized until C2 is trustworthy.
- **C5 → C6 (soft but real).** If C5 makes `.claude/agents/generated/` a mechanical render, C6's findings
  in those files become *derived* — fix the template, fix them all. C6 first means converting eight
  generated files by hand and then regenerating over the fix.
- **Every §15-enrolling class → every other one (hard, serialization).** C3, C5, C6, C7 and C10 all enrol
  or widen a checking entry point, and all edit the same hand-ordinalled `RULES.md:599-660` bullet whose
  counts `tests/test-doc-contract-fields.sh` derives. Independent in *mechanism*, coupled in *file*.
  Strict sequencing, no exceptions.

Genuinely independent, if a second session ever runs concurrently: **C11**, **C9**, and the C12/C13
residue. Everything else collides on `scripts/**` guards, the §15 registry, or both.

---

## The objectives

Each is one objective, one PR, merged before the next starts.

### OBJ-A — Manifest write integrity (C15 + C1) — *first code objective*

Extract the lock + validate + temp-rename + read-back primitive into `scripts/lib/`; `task-transition.sh`
and `red-run.sh` both call it. **Shared primitive, not shared entry point** — routing red-run through
`task-transition.sh` would make the sole *status* writer also a writer of evidence sections, diluting the
one contract that makes reconciliation sound (ADR-020). Repoint the three hand-rolled manifest readers at
`task-utils.sh`.

**Correction folded in:** keep `status-consumer-scan`'s derived population on `scripts/**`. Widening it to
`skills/**` inverts a documented decision *and* the predicate does not transfer — `scs_code` strips lines
beginning with `#`, which in Markdown removes ATX headings, not comments. Cover the prose surfaces with
behavioural rows in `tests/test-cancelled-status-consumers.sh` instead.

**Exit:** no script writes a task manifest except through the shared primitive; a concurrency test proves
an interrupted red-run write leaves the manifest intact; zero hand-rolled status readers outside
`task-utils.sh`; suite green with `K > 0`.

### OBJ-B — Host seam: submit *and* close (C11, re-scoped) — *slotted early: paid work*

**The original C11 mechanism was rejected as architecturally backwards.** "Restore the prose PR
instruction for the ordinary path" would either drop `stack.layers[]` / `objectives_history[].pr` writes
on that path (a regression) or duplicate them in agent prose — a second writer of script-owned state,
against `stack-utils.sh` being their sole writer and against ADR-021. And the provider layer is not
speculative: `merge-provider.sh` and `inbox-provider.sh` are two shipped instances of exactly this seam.

`stack_submit` stays the single mechanized entry point; its host calls move behind a `merge-provider`-shaped
seam (`detect` / `submit` / `health`, every unusable state its own token).

**Scope correction — this is the one that matters for TaxGuardian.** `_mp_provider_for_host` claims
`github.com` only, so on Azure DevOps `merge_provider_detect` returns `unsupported_host`, the
`## Merge Evidence` route refuses with `merge-unverifiable`, and that gate carries **no kill switch by
design**. Un-hardwiring *submit* while *close* still refuses leaves ADO unable to reach DONE. Scope this
objective to both ends, or state in the release notes that ADO remains blocked at DONE.

**Exit:** no `gh` outside a provider arm on the submit path; a non-GitHub remote yields
`unsupported_host` at submit **and** a named, documented answer at the DONE gate; `stack.layers[]` and
`objectives_history[].pr` still written by `stack-utils.sh` alone; no PR recipe reintroduced into prose.

### OBJ-C — Command-string guard retirement (C9)

Post-staging git truth beats tokenizing shell grammar, and FEAT-010 already made this move once. Two
preconditions the class table did not state:

1. `pre-commit` returns early when `branch.feature` is empty — inert whenever no loop is active. But
   "never stage `nazgul/` in local install mode" applies **always**. The staged-pathspec check must sit
   **above** that gate.
2. `pre-commit` runs only when `guards.git_hooks` is true and `core.hooksPath` is installed, while
   `local-mode-tracking-guard.sh` runs unconditionally — and `git-hooks.sh` can silently install a
   `core.hooksPath` pointing at an *empty* directory under zsh. Retiring the tokenizer is conditional on
   install being **verified**, not attempted.

**Exit:** `git diff --cached --name-only` is the sole authority for the tracking guard; a doctor check
fails loudly when `core.hooksPath` points at an unpopulated dir; the awk tokenizer is **deleted**, not
bypassed.

### OBJ-D — Dispatch identity (C8, keystone-first)

**Task 1 is a payload probe**, because the premise is not readable from source. If `AGENT` really resolves
to `unknown` on every dispatch, four mechanisms die together: `no_verdict_line` detection, the
reviewer-specific resume directive, `maxTurns` resolution, and — most seriously — `_append_review_receipt`
is gated on `unit != "unknown"`, so **LR-001's review-receipt binding, the mechanical
anti-fabricated-board control, never records.**

**Exit:** a recorded real `SubagentStop` envelope in `tests/fixtures/` with `PROVENANCE.md`; `AGENT`
resolves or emits a named non-resolution event; a dogfooded test proves the receipt binding records on a
reviewer dispatch.

### OBJ-E — Granularity consumers (C7)

Verified sound as scoped. `pre-merge-commit` has **zero** `granularity` references and hard-codes
`TASK-`; `resolve_review_unit()` already exists as the shared resolver.

**Exit:** a derived scan shows zero hard-coded review-unit assumptions outside the resolver; a
`feature`-granularity fixture merges cleanly through `pre-merge-commit`; §15 registry updated in the same
change.

### OBJ-F — Derivation over authorship (C5 + C6, staged, ~8–10 tasks)

**C5 was undersized ~4×.** "Regenerate-and-diff" has no generator to run: `.claude/agents/generated/*.md`
is produced by the discovery agent *following prose*. You cannot diff a regeneration you cannot perform
deterministically. So: build `scripts/render-agent.sh`; move the substitution out of `agents/discovery.md`
into a call to it (the valuable part — a prose render becomes a mechanism, which is the class's own
thesis); then the regenerate-and-diff test; then the doctor surface. Precedent: `scripts/gen-skill-docs.sh`
made this exact move for skill templates.

**C6 cannot land in one task.** `OCCURRENCE_RE` is paired with a *single-string* `ROOT_MARKER`, so widening
the regex requires generalising the marker to a set — every newly-matched occurrence is unrooted by
construction on day one. ~45 raw occurrences across 10 spec files, against a hard `F == 0` gate. **Stage
it:** widen the detector **advisory-only** behind a counter the gate does not read, report `N/M/K/F` so the
true size is measured rather than predicted, convert per spec file, fold into `F` last. This is the
pattern the auditor itself used when it shipped.

**Exit:** `.claude/agents/generated/` is reproducible from `reviewer-base.md` + `reviewer-domains.json` by
a script; the widened audit reports `F == 0` over the shipped roster with the new classes counted in `F`;
`K > 0` floor holds.

### OBJ-G — Guard ambiguity, part 1: the derivable shapes (C3-i + C3-ii)

**Only after C2's own defects land.** C3 was rejected as "one mechanism" — it is three:

- **(i)** `producer | grep -q` / `| head` under `pipefail` — a SIGPIPE exit-status race. Cleanly derivable.
- **(ii)** `|| echo` after a pipeline — the MF-053 value-substitution class, whose fix is a `jq -e .`
  validity pre-check, not `|| true`. Cleanly derivable.
- **(iii)** `[ -z ] && exit 0` on an authorization path — **not derivable.** See OBJ-H.

**Exit:** both scanners emit the §15 grammar with `K > 0` floors and are dogfooded on synthetic violators;
every site found is fixed or enumerated-exempt with a stated reason.

### OBJ-H — Guard ambiguity, part 2: the 18 rows (C3-iii)

**Not a scanner.** This repo already built and documented that scan: on the narrowest, most
enforcement-dense 16-file subset it returns 125 rows — **90 correct, 18 real findings, 17
audited-deliberate**. A 72% false-positive rate on the best-case corpus, and the inventory's own header
concludes "classifying all of them has almost no yield." The discriminator ("is this an authorization
decision?") is not textual.

The worklist already exists: the 18 category-(b) rows, re-derived at Move 0.

**Exit:** every surviving (b) row is fixed or re-classified to (c) with an in-code audit comment and a
RULES.md citation; the inventory's counts are **regenerated, not hand-edited**.

### OBJ-I — Backlog enforcement (C10a)

`scripts/sync-inbox-to-github.sh` **is not in the tree.** `CLAUDE.md` documents its flags, its idempotence
and its `N scanned, M skipped, K created, F failed` line as though it ships, and names its `--check` —
"exits 1 if any item lacks an `issue:`" — as **"the enforcement."** That enforcement has never existed.

This is a documentation-vs-tree divergence in the governing file, and it is the rule that would have kept
the 144-issue backlog honest in the first place.

**Exit:** `--check` exits 1 on an unsynced item; the run emits the coverage line; CLAUDE.md's Backlog Rule
cites a file that exists.

---

## Residue — `/nazgul:patch`, not objectives

**C12 and C13 are dissolved.** C13's own row concedes its members are "genuinely individual fixes sharing
a shape" and that it prevents no recurrence; C12's concedes "no single kill." A class whose defining
property is that no single mechanism addresses it is a *shape observation*, not a class — and carrying it
as one costs a planning slot, an objective wrapper, a review board and a merge, to ship work that would
have been cheaper as individual patches.

Route C13's seven, C12's eight, C10b, and the five genuine one-offs (#110 #147 #175 #190 #179) through
`/nazgul:patch`, ordered by p0/p1 weight. **C13 carries 5-of-7 p0/p1** — schedule these *between*
objectives rather than after them all. They are the cheapest morale wins on the board.

One carve-out: **#215's doctor check** (diff `config.guards` against `templates/config.json`) is a genuine
one-task mechanism — attach it to whichever objective already touches `doctor.sh`.

---

## The three ways this programme breaks

1. **A class dissolves on contact and its objective has nothing to do.** Already true of C3: six of its
   worst instances were closed this session by the shared payload reader, TASK-050 closed another, and the
   class was counted against a pre-fix tree. Mitigation is arithmetic, not optimism — **Move 0**.
2. **A derived scanner turns the suite red and cannot be turned green in one task.** C6 is the instance,
   with a number: ~45 occurrences across 10 files against an `F == 0` gate. Mitigation: the advisory
   staging pattern, mandatory for any class widening a derived population.
3. **Scope growth mid-objective, again.** Plan said 14, disk says 50, one review unit needed nine boards.
   Mitigation: small-objective shape plus the standing clause above, as the *first* line of every exit
   criterion.

Fourth, lower-probability and high-cost: **the §15 registry conflict.** Two enrolling classes in flight
simultaneously produce a semantic merge conflict in a prose ordinal chain that a test derives counts from.
Strict sequencing prevents it; nothing else does.

---

## Class → objective map

| Class | Issues | n | Objective |
|---|---|---|---|
| C15 Red-run producer hardening | 140 226 227 235 241 | 5 | OBJ-A |
| C1 Hand-rolled manifest readers | 105 108 169 203 | 4 | OBJ-A |
| C11 Host hardwiring | 114 117 | 2 | OBJ-B |
| C9 Command-string tokenizer guards | 127 139 159 162 163 164 165 202 243 246 | 10 | OBJ-C |
| C8 Dispatch non-delivery | 93 99 126 151 156 199 211 214 218 219 222 238 244 | 13 | OBJ-D |
| C7 Granularity consumers | 106 112 121 122 123 130 208 | 7 | OBJ-E |
| C5 Authored list where derivation belongs | 95 143 161 170 | 4 | OBJ-F |
| C6 Two trees / path root | 113 120 124 145 152 189 191 198 | 8 | OBJ-F |
| C2 Unbounded waits | 155 201 | 2 | shipped — verify at Move 0 |
| C3 Guard fail-open / silent abort | 115 118 119 125 136 137 138 141 144 148 149 150 154 158 160 166 171 173 174 188 213 233 234 237 | 24 | OBJ-G + OBJ-H, **re-count first** |
| C10 Recording without consumption | 101 107 111 133 176 192 193 196 210 225 | 10 | OBJ-I (a) + residue (b) |
| C12 Convention, not mechanism | 102 128 132 153 200 212 215 217 | 8 | **dissolved** → patch |
| C13 Loop-safety gates on wrong quantity | 96 97 98 100 103 224 236 | 7 | **dissolved** → patch |

Verified: 104 issue numbers, 104 unique, 0 duplicates, all exist on the board, none already closed.
**These counts are pre-merge and must be re-derived at Move 0.**

Dead on merge of PR #240 (15, all currently OPEN): #89 #90 #91 #92 #116 #142 #167 #180 #197 #204 #220
#221 #228 #229 #230. Partial, needs a merge-time check: #231 #232 #239.

---

## How this is linked on the board

Board item **#248** (`priority:0`, `type:feature`, `nazgul`) is the programme. **89 issues are linked as
GitHub sub-issues** — these are the class work, and they burn down visibly on the project board's
`Sub-issues progress` field.

The **20 residue items are deliberately NOT sub-issues**: C12's eight, C13's seven, and the five genuine
one-offs. They route through `/nazgul:patch` individually, not through any objective, so parenting them
under the programme would misrepresent them as class work with a mechanism behind them. They are listed
here instead:

- **C12 (dissolved):** #102 #128 #132 #153 #200 #212 #215 #217
- **C13 (dissolved, 5-of-7 p0/p1 — schedule between objectives):** #96 #97 #98 #100 #103 #224 #236
- **Genuine one-offs:** #110 #147 #175 #179 #190

One mechanical constraint found while linking, recorded so it is not rediscovered: **GitHub caps a parent
at 100 sub-issues** (`Parent cannot have more than 100 sub-issues`). At 109 the link silently spilled the
last nine. The 89/20 split above is under the cap by construction, but any future umbrella near 100
children needs a per-objective parent instead of one flat list.

## Two facts not on the board

- **23 of 144 issues are invisible to the connector.** 121 carry the `nazgul` label it queries; 23 do not.
  The gap regrows with every unlabelled filing, so any burn-down measured through the connector
  under-counts. OBJ-I's mechanism is what closes it.
- **The non-delivery detector does not cover the dispatch path an operator actually uses.** Four subagents
  in one session ended their turn announcing the next step with the work already done. The bounded resume
  fires on `SubagentStop` inside the loop; direct `Agent` dispatches from an interactive session are
  uncovered. This strengthens OBJ-D's keystone.
