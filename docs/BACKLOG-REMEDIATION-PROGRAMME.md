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
merge-evidence route refuses with `merge-unverifiable`, and that gate carries **no kill switch by
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

**Known before you start — two blockers, both verified 2026-08-26 (FEAT-035 W7). Read this before
re-landing anything.**

**1. The mechanism was already built once, and it was pulled on purpose.** A working 137-line
prototype was committed as `e18aa18` (`2026-08-15 11:37:07 +0100`, *"chore: land the inbox-to-board
sync script"*, `scripts/sync-inbox-to-github.sh`, +137) and removed by `6bc5324`
(`2026-08-15 12:57:41 +0100`, `Revert "chore: land the inbox-to-board sync script"`, −137) —
**80 m 34 s** later. The revert body is the bare `git revert` boilerplate (`This reverts commit
e18aa18…`) and carries no trailer, so in git the removal **looks** unexplained. It is not.

**2. The reason is stated — on the board, not in git.** Issue `#193` (**OPEN**, `type:feature`,
`priority:1`, opened `2026-08-15T10:56:02Z`, already classed here under **C10**) records it: the
prototype was hand-written mid-session — *"never planned, never decomposed into tasks, never seen by
the review board, no tests, no red-run evidence"* — was **caught bypassing the loop**, and was
**deliberately not pushed to `main`**. It was filed **18 m 55 s after the landing and 61 m 39 s
before the revert**, i.e. inside the 80-minute window that reads as a silent gap. This is a
**decision, not an unexplained revert, and it changes what the fix is**: the work is *build it
through the loop*, not *restore `e18aa18`*.

**3. The board trail is stale in the one place a reader would start.** One gap has three entries and
two are closed: `#242` (`CLOSED`/`NOT_PLANNED`, `2026-08-23T07:52:04Z`) was closed as a duplicate of
`#247`, and `#247` was itself closed **80 seconds later** (`CLOSED`/`NOT_PLANNED`,
`2026-08-23T07:53:24Z`) as a duplicate of `#193`. `#242`'s closing comment says *"#247 is the live
entry"* — that sentence is now false. **The live entry is `#193`**, and it is the only one of the
three that carries the actual reason. Anyone citing `#247` for the revert history is citing a closed
issue whose own account (*"reverted … with no stated reason"*) `#193` corrects.

**4. Why the history looks absent: it is reachable by message, never by path.** Neither `e18aa18` nor
`6bc5324` is an ancestor of `main` or of any ref — `git branch -a --contains` is empty for both, no
reflog entry references them, and a fresh `git clone` of this repository contains **neither object**
(their parent `d6f7582` clones fine). Consequently
`git log --all -- scripts/sync-inbox-to-github.sh` returns **zero rows**, which is the probe a reader
runs first. The pair survives on `main` only inside the squashed body of `f3de728` (PR #240), which
carries **both** the landing bullet and the revert bullet — so use `git log --grep='inbox-to-board'`,
not a path filter. `#193`'s warning that the bypass might land with FEAT-031 was **checked and did
not happen**: `git ls-tree f3de728 scripts/sync-inbox-to-github.sh` is empty.

**5. The prototype is not a drop-in for what `CLAUDE.md` documents.** It is recoverable today with
`git show e18aa18:scripts/sync-inbox-to-github.sh` (6 723 bytes) **on this machine only**, and it
diverges from the governing text in five measured ways, every one of which is a decision OBJ-I has to
make rather than inherit: it writes `type:<v>` / `priority:<n>` labels where `CLAUDE.md` documents
`type: bug` / `pN`; it prints a **six**-field coverage line (`… skipped (up to date), created,
updated, stale, failed`) where `CLAUDE.md` documents four; its `--check` exits 1 on missing **or
stale** where `CLAUDE.md` documents only "lacks an `issue:`"; the whole `synced_sha` staleness
mechanism is undocumented; and it requires **`python3`** (three invocations), which is not in this
project's stated dependencies. It also runs `set -uo pipefail`, without the `-e` this repo's code
style requires of a non-library, non-fail-open script. `#193` adds six more preconditions (hardcoded
repo/project/field ids, the `inbox-provider.sh` seam, one label-scheme definition, tests plus red-run
evidence, inbox concurrency, and naming the enforcement point).

**6. Direct evidence for the exit criterion, measured inside this objective.** Because the documented
mechanism does not exist, **every** backlog filing here used the manual four-step substitute by hand:
thirteen items (`#260`–`#272`), board ranks 14–26, each one `gh issue create` → `gh project item-add`
→ set `Rank` → write `issue:` back. The invariant currently holds — 26 inbox items, **0** without an
`issue:` — but it holds *because a human did the script's job thirteen times in one objective*, which
is precisely the decay `#193`'s item 6 predicts for a rule enforced only by a manually-run script.

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

### The `#255` / `#128` pairing — a classification defect, not a scheduling one

**Recorded at Move 0 (W5), per ADR-030/D3–D6.** `#128` sits in **C12**, which the paragraph above
dissolved and routed to `/nazgul:patch`. `#255` is not in the class table at all — it postdates it, and
W4 placed it in the derived uncovered population (**row 32** of the 44; **row 30** of this document's
41-row residue-reason table) with a reason and no adjudication, which is this section's job. Two items
with a **stated** causal dependency were separated by a classification boundary — one into "dissolved,
route to patch", one into "not covered" — and until this amendment nothing in the programme bound them.
The cheap patch could ship first and **enlarge** the uncovered defect, and every step of that would
look correct.

**This is a classification defect, not a scheduling one.** A scheduling defect is fixed by reordering.
A classification defect means the taxonomy put related things in unrelated places, and reordering
cannot reach it — there is no order in which "`#128` is an individual patch" and "`#255` is uncovered"
are both true and safe, because the harm is done by the two verdicts, not by their sequence.

**The override fires, and it fires on text, not on resemblance.** ADR-030/D4 admits only a dependency
an issue records **about itself**. `#255` carries one, in its own `## Related` section, quoted verbatim
from `gh issue view 255 --repo OrodruinLabs/nazgul --json body` at `at=2026-08-26T01:34:55Z`:

> Adjacent but distinct from **#128** ("the live, blocking DONE-transition gate never calls
> `validate_review_provenance`"). #128 is about the check not being invoked; this is about the check
> being invoked and passing vacuously. Fixing #128 alone would make this bug *more* reachable.

That is D3's condition met literally: resolving `P` (`#128`) alone leaves `Q` (`#255`) **worse**, and
`Q` says so in its own text. Presence is measured, not eyeballed — `grep -Fc` on the fetched body
returns `1` for that sentence, `1` for a `CONTROL(+)`, and `0` for a `CONTROL(-)` mirror sentence that
is not there. An inferred coupling would not have fired the override, and D4 is deliberate about that:
one that fired on inference would eventually bind every pair of issues touching the same file.

**Why D6's "both directions" is a measurement here, not a style rule.** The same question asked of
`#128`'s body returns the opposite answer: `grep -Fc '255'` over its 6,274 characters finds **no
mention of `#255` at all**. The coupling is stated in exactly **one** direction — and it is stated on
the *expensive* side (`#255`, `priority:1`, no chartered mechanism), while the item that gets scheduled
first is the *cheap* one (`#128`, `priority:2`, residue, routed to patch). Whoever opens `#128` to
patch it finds nothing pointing at `#255`. ADR-030/D6's reason — "a one-directional note is only found
by whoever happens to open the right one first" — is not a hypothetical for this pair; it is the
measured state of the two bodies, which is why the binding is written into this document twice.

**The routing verdict, stated rather than implied:**

- **`#128` — `bound-to: #255`.** It stays residue, and it **may not be routed to `/nazgul:patch`
  independently** (ADR-030/D3). It is patchable only together with `#255`, or after `#255` has been
  disposed of. The annotation is repeated on its own entry in the C12 residue list below.
- **`#255` — `bound-to: #128`.** It stays residue with the W4 reason on its row, and its disposition is
  now gated on the pair rather than on its own row. The annotation is repeated on that row.

**What this does NOT do (ADR-030/D5, ADR-029/D7).** The C12 dissolution argument above is untouched and
is not re-opened — the pair is bound *within* the routing the programme already chose, not against it.
No objective is created, re-chartered or re-scoped for the pair; no class row's `Issues`, `n`, `M` or
ADR-029 token is edited; and neither issue is fixed, closed, commented on, re-labelled or re-parented.
The verdict is recorded; the acting is somebody else's turn.

**The cost, stated rather than discovered.** ADR-030 accepts this in advance, and the instance is worth
naming: a bound item **loses the scheduling freedom** the programme values for its cheapest wins.
`#128`'s first sub-defect is a call-site change — have `ttg_verify_review_evidence` call
`validate_review_provenance` — which is exactly the shape the residue route exists to ship quickly, and
it is now held behind a `priority:1` defect that no chartered mechanism reaches. That is the trade D3
makes on purpose. The alternative is shipping a fix that enlarges a defect nobody is tracking, and
`#255`'s own text is what tells us that is what would happen.

**Filed during W5, not absorbed (standing clause):**

- **#269** (p2, `type:bug`, board Rank 23 / Todo) — two of the 41 residue reasons below (`#232` and
  `#255`) **stop mid-clause** at an escaped pipe, and W4's `w4-d2-completeness` pass scores them clean
  because its predicate is *non-empty*, not *intact*: re-run today it still reports `residue rows=41
  non-empty-reason=41 empty=0 findings=0`. ADR-030/D2 exists so an unassigned issue stays
  distinguishable from an unexamined one; a reason truncated mid-clause is neither. **Not repaired
  here** — W5 prepends its binding to `#255`'s row and leaves the truncation at the row's end byte for
  byte, so `grep -c '[\\] |$'` still returns `2` and the filing keeps a live instance.
- **#270** (p3, `type:bug`, board Rank 24 / Todo) — `#128` carries **two incompatible routings**: this
  document sends it to `/nazgul:patch` as a dissolved-C12 member, while its own body ends with
  `## STATUS 2026-08-01 (alignment pass): CONSUMED BY charter Objective C` — *"close this filing via
  that objective."* Neither document mentions the other, and the binding above now makes a **third**
  constraint on the same item. Found while reading `#128`'s text for the D4 test. Reconciling the two
  is deliberately **not** done here: choosing an owner is re-chartering, which D5 forbids.
- Recorded and deliberately **not** filed: ranks 23 and 24 were already held by `#111` and `#112`, so
  both filings land on duplicate ranks (the board now has 19 duplicated rank values across 152 items).
  That is **#196** — "rank is documented as the backlog ordering key but no code reads it" — so it is
  cited rather than re-filed, and nothing was renumbered, which would imply an ordering authority #196
  proves does not exist.

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

| Class | Issues | n | M open/closed | ADR-029 | Objective |
|---|---|---|---|---|---|
| C15 Red-run producer hardening | 140 226 227 235 241 | 5 | 4/1 | `RESIZED` | OBJ-A |
| C1 Hand-rolled manifest readers | 105 108 169 203 | 4 | 4/0 | `CONFIRMED` | OBJ-A |
| C11 Host hardwiring | 114 117 | 2 | 2/0 | `CONFIRMED` | OBJ-B |
| C9 Command-string tokenizer guards | 127 139 159 162 163 164 165 202 243 246 | 10 | 10/0 | `CONFIRMED` | OBJ-C |
| C8 Dispatch non-delivery | 93 99 126 151 156 199 211 214 218 219 222 238 244 | 13 | 12/1 | `RESIZED` | OBJ-D |
| C7 Granularity consumers | 106 112 121 122 123 130 208 | 7 | 7/0 | `CONFIRMED` | OBJ-E |
| C5 Authored list where derivation belongs | 95 143 161 170 | 4 | 4/0 | `CONFIRMED` | OBJ-F |
| C6 Two trees / path root | 113 120 124 145 152 189 191 198 | 8 | 7/1 | `RESIZED` | OBJ-F |
| C2 Unbounded waits | 155 201 | 2 | 2/0 | `CONFIRMED` | shipped — verify at Move 0 |
| C3 Guard fail-open / silent abort | 115 118 119 125 136 137 138 141 144 148 149 150 154 158 160 166 171 173 174 188 213 233 234 237 | 24 | 24/0 | `CONFIRMED` | OBJ-G + OBJ-H, **re-count first** |
| C10 Recording without consumption | 101 107 111 133 176 192 193 196 210 225 | 10 | 10/0 | `CONFIRMED` | OBJ-I (a) + residue (b) |
| C12 Convention, not mechanism | 102 128 132 153 200 212 215 217 | 8 | 8/0 | `CONFIRMED` | **dissolved** → patch |
| C13 Loop-safety gates on wrong quantity | 96 97 98 100 103 224 236 | 7 | 7/0 | `CONFIRMED` | **dissolved** → patch |

Verified: 104 issue numbers, 104 unique, 0 duplicates, all exist on the board, none already closed.
**These counts are pre-merge and must be re-derived at Move 0.**

**Re-derived at Move 0 (W8), clause by clause —
`documented "104 issue numbers, 104 unique, 0 duplicates, all exist on the board, none already closed"
→ measured "104 raw, 104 unique, 0 duplicates, 104 of 104 on the board, K = 3 already closed"`, at
`at=2026-08-25T23:55:56Z`.** **Four of the five clauses hold; the fifth does not.** The two sentences
above are retained unchanged as the frozen pre-merge baseline the delta is measured against. The
three closed members are **`#235`** (C15), **`#218`** (C8) and **`#198`** (C6) — the same three that
make those rows `RESIZED`, so this is one fact counted once, not a second finding. Clause 4 is the
strongest of the five: 104 of 104 resolve in the snapshot, none `NOT-ON-BOARD` and none `AMBIGUOUS`.

**The extraction is the `Issues` column, and the sentence above never said so.** Clauses 1-3 are
measured over field 3 of each class row (`awk -F'|' '{print $3}'`), not over the whole row. A
column-agnostic `[0-9]{2,3}` scan of the same rows also picks up the `n` and `M` columns and returns
**108 / 107 / 1 duplicate at `92bf60f`** — the tree as it stood before Move 0 amended anything — and
**112 / 108 / 2** today; it has never returned 104, at any SHA in this file's history. The stated
`104` is right and its unstated method is what is wrong; filed as issue **#267** (p2) and **not fixed
here**, per the standing clause. Cross-check, from a second independent quantity in the same table: the
`n` column sums to **104**.

**When clause 5 was true, and what made it false — the two are not the same question.** `#218` closed
`2026-08-23T21:38:32Z`, **1 day 12 h 54 m before `f3de728`** — the single commit that introduced the
sentence above (`2026-08-25T10:32:31Z`). *The claim was already false at the instant it was written*,
by one member, and no merge is involved in that. `#198` and `#235` then closed 4 s and 6 s **after**
that commit. So the clause was last true at some instant before `2026-08-23T21:38:32Z`, which is after
the classification pass this document reports (W3 reconstructs its 144 at `T=2026-08-22`) — the
sentence was true when the classification was done and stale by the time it was committed.

**Measured at Move 0 (W3).** `M` and the `ADR-029` token above are derived from one issue snapshot,
`nazgul/context/FEAT-035-issues-snapshot.json`, taken at `at=2026-08-25T23:55:56Z` (169 issues, `jq
'length'` asserted `< 1000`, so the list is a count and not a floor). Per-issue detail is in
`nazgul/context/FEAT-035-class-membership.tsv`; every figure here recomputes from those two files, and
no figure in Move 0 comes from a second live call. `M` is the count of a row's issues that are **OPEN**
in that snapshot; `n` is untouched, because it is the frozen pre-merge prediction the delta is measured
against.

`documented n = 104 → measured M = 101 open, 3 closed`. Tokens: **10 `CONFIRMED`, 3 `RESIZED`, and
none of the other four** — no class dissolved, nothing grew, and no input was unreadable. The three
closures are `#235` (C15), `#218` (C8) and `#198` (C6), one apiece; the three `RESIZED` rows are exactly
those three classes. **The dissolution this programme was most worried about did not happen.** C3 — the
class named in "the three ways this programme breaks" as the one already dissolving, sized against a
pre-fix tree — measures `24/0`: not one of its issues has closed.

Two boundaries on that result, both of which change what `CONFIRMED` is allowed to mean:

- **`M` measures the board, not the tree.** ADR-029/D1 requires two independently measured facts, and
  `M` is only the first; `X` — whether each member's fix is verifiably present in the tree — is measured
  separately at W4 and is *not* derived from `M`. A member whose fix has shipped while its issue stays
  open still counts as OPEN here (D2), so `C3 CONFIRMED` says "24 of its issues are open", **not** "24
  units of work remain". C2's row is the same shape read from the other side: its objective column says
  *shipped*, and both its issues are still open.
- **`M` is measured over the table's own numbers only, and can still move up.** Sixteen issues filed
  after the classification instant are absent from every row above; twelve are open and are candidate
  members of some class (the thirteenth, `#248`, is the programme itself). Folding them in is W4's work
  under ADR-030, and it can only push an `M` **up** — so a `CONFIRMED` or `RESIZED` row here may yet
  become `GROWN`, and none can become more dissolved than it already is.

**There is no `C4` row and no `C14` row, and the absence is a numbering gap — not a class dropped
without a record.** `grep -cE '^\| C(4|14) '` returns `0`, and the ids appear in **zero bytes** of this
repository. Four independent checks decide it rather than one:

1. **No version of this document ever had such a row.** It has exactly one commit in history (`f3de728`,
   PR #240's squash); `git log --all -S'C14'` and `-S'| C4 '` both return nothing, and the ids are
   absent from board item #248's body and comments and from PR #240's body. There is no deletion to
   find.
2. **The document's convention for a class that stops being a class is to keep the row and mark it.**
   C12 and C13 are dissolved and still occupy rows, marked `**dissolved** → patch`. ADR-029/D3 later
   codifies exactly that ("Row **kept and marked**, never deleted"). Under this document's own practice
   a dropped class leaves a marked row, not a hole.
3. **The id space is a label space, not a sequence.** It is subdivided rather than renumbered (`C3-i`,
   `C3-ii`, `C3-iii`, `C10a`, `C10b`), and the rows are ordered by objective — `C15` first, `C13` last —
   so a gap in it carries no positional meaning. #248's own title states **"13 defect classes"**,
   matching the thirteen rows.
4. **There is no orphan population for a fourteenth class to have held.** Reconstructing this
   document's own 144 from the snapshot (`createdAt <= T`, open at `T`) returns **exactly 144** at
   `T=2026-08-22T00:00:00Z`, and nineteen of them sit in no bucket this document declares: **sixteen
   open `type:feature` roadmap items** (#109 #129 #131 #134 #135 #146 #157 #168 #177 #181 #182 #183 #184
   #185 #186 #216), **one open bug** (#209), and **two already-closed bugs** (#172, #242). One bug is
   not a class — D4's own bar — and sixteen feature requests are not a defect class at all. The
   unaccounted set has no root cause to share.

   The finding does not rest on pinning the instant. The same nineteen are returned at
   `T=2026-08-22T10:37:29Z`, the first instant that contains all 127 declared members; and across
   `2026-08-21T00:00:00Z` … `2026-08-22T23:59:59Z` the count moves only between **18 and 20**, every
   difference being one already-CLOSED bug entering the window (#242, then #247). The eighteen-member
   core is invariant over the whole range.

What the evidence does **not** settle, stated rather than left silent: the classification pass itself
left no artifact in this repository, so whether the ids `C4` and `C14` were transiently allocated during
that unrecorded session and folded into neighbours cannot be recovered. That is a question about a
working note, not about a class with members — checks 1 and 4 close the version history and the member
population respectively, and those are the two things a dropped class would have left behind.

**One row-shape limitation, recorded because a single token cannot express it.** C3's 24 members are
chartered across two objectives (OBJ-G for `C3-i`+`C3-ii`, OBJ-H for `C3-iii`) and C10's 10 across two
destinations (OBJ-I for `C10a`, patch residue for `C10b`), and neither split is enumerated anywhere in
this document — unlike C12's and C13's, which are re-listed member by member below. Their tokens are
therefore **whole-row** tokens: `C3 CONFIRMED` cannot say that one half dissolved and the other did not.
Filed as issue **#264** (p2) under the standing clause; not fixed here, and ADR-029/D7 forbids this
objective from re-chartering an objective in any case.

Dead on merge of PR #240 — **`documented 15 → measured 7 closed / 8 open`**, measured at Move 0 (W3-X) from `nazgul/context/FEAT-035-issues-snapshot.json` (`at=2026-08-25T23:55:56Z`), never from a second live call. The prediction is retained verbatim as the baseline the delta is measured against: *(15, all currently OPEN): #89 #90 #91 #92 #116 #142 #167 #180 #197 #204 #220 #221 #228 #229 #230. Partial, needs a merge-time check: #231 #232 #239.*

- **7 closed**, every one `COMPLETED` on `2026-08-25`: `#89` `#90` `#91` `#92` `#220` `#228` `#229`.
- **8 open**: `#116` `#142` `#167` `#180` `#197` `#204` `#221` `#230`.
- The three partials resolve **individually**, not as a group: **`#239` CLOSED (`COMPLETED`)**,
  **`#231` OPEN**, **`#232` OPEN**.

**Which class row does each survivor sit in? None of them — and that is the measurement, not a hole in
it.** The eight survivors and the two open partials intersect this table's 104 members in **zero**
issues, and intersect the twenty residue items (C12's eight, C13's seven, the five one-offs) in zero as
well. `comm` over lexicographically sorted sets, `sort -c`-verified before any output was trusted, with
a positive control that returns 5 on five known members. Each survivor appears in this whole document
exactly **once** — in the sentence above. So the shortfall of eight did **not** get absorbed by one
class and did not spread thinly across several: **it falls entirely outside the class table, and no
row's `M` moves because of it.** The planning consequence is the sharp part: these ten issues are owned
by no objective, because the programme excluded them on the prediction that they would be dead.

| survivor | class row | residue bucket | `X` — fix present in the tree at `92bf60f`? |
|---|---|---|---|
| #116 | none | none | **PARTIAL** — `red-run.sh`'s `--state-root` shipped; `task-transition.sh:70` still derives `NAZGUL_DIR="$PROJECT_ROOT/nazgul"`, one root for two trees |
| #142 | none | none | **PRESENT** — `tests/lib/assertions.sh`, all four helpers `-e` + three-way `rc>=2`; regression `tests/test-assertion-vacuity.sh` |
| #167 | none | none | **PRESENT** — `review-file-class.sh:49` excludes `adversarial-*.md` |
| #180 | none | none | **PRESENT** — `nazgul-root.sh:57-58` returns a set `CLAUDE_PROJECT_DIR` unconditionally |
| #197 | none | none | **PRESENT** — `webhook-forward.sh:52` calls `count_tasks_and_find_active` |
| #204 | none | none | **PRESENT** — `tests/test-hook-command-modes.sh`, population derived from `hooks/hooks.json` |
| #221 | none | none | **PRESENT** — same shipped change as #167 |
| #230 | none | none | **PRESENT** — `status-consumer-scan.sh` walks on fd 9 |
| #231 (partial) | none | none | **ABSENT** — the `producer \| early-exit-consumer` shape is still live under `pipefail` in all three named files |
| #232 (partial) | none | none | **PARTIAL** — the validator now refuses a typed quarantine; the issue's own "still open" clause (absent `Blocked kind` line) holds, verified by running the shipped predicate |

**`X`, and why a fixed issue still counts as open (ADR-029/D1, D2).** `M` above is board state. `X` —
whether the fix a class's mechanism would deliver is verifiably present in the tree at `92bf60f` — is
counted **separately, and is not derived from `M`**. Read together they overturn the reading a bare
`-8` invites: **seven of the eight survivors are already fixed in the tree.** The prediction was
substantively right about the *work* and wrong about the *board* — the merge shipped the fixes and
closed 7 of 15 issues, and nothing observed the other 8. Per **D2 these seven still count as OPEN**;
`X` never silently reduces `M`, because the board is the durable record and a shipped-but-open issue is
a backlog-hygiene defect rather than a smaller class. They are flagged `stale-issue` and **filed**:
**issue #265** (p2, board Rank 19). A second defect surfaced while measuring them — three of the
eighteen `nazgul/inbox/` items are for closed or already-shipped work and the heartbeat would auto-start
an objective for one — is **issue #266** (p1, board Rank 20). Per-issue results, including the
`not-separately-measured` reason for every member outside `X`'s bounded population, are in
`nazgul/context/FEAT-035-fix-presence.tsv`; the transcript is `### W3-X`.

**Population note for the "none already closed" claim above — the warning has two halves, and taking
only the first is how a reader gets it wrong in the other direction.** *Half one:* the seven closures
do **not** falsify `Verified: … none already closed` **by membership**. That sentence is about the
**104 class members**; the fifteen dead-on-merge issues and the three partials are disjoint from them,
measured at W8 as `comm -12` over lexicographically sorted sets (`sort -c`-verified on both inputs
first, since a numeric sort makes `comm` report every line as unique) → **empty**, against a positive
control on five known members that returns **5**. The two populations must not be added together, and
the 104's own closure count is `K = 3` (`#235`, `#218`, `#198`).

*Half two, and it is the half a disjointness result invites you to skip:* **disjoint lists do not mean
an unrelated event.** Ten issues closed in the five seconds after `f3de728` was committed — eight of
the enumerated eighteen **and `#198` and `#235`, two of the 104**. The merge instant reached both
populations; the *prediction list* reached only one, because those two were never predicted to die.
And `#218`, the third, closed a day and a half **before** that commit, so no merge explains it at all.
The correct statement is therefore **"no issue this document listed as dead-on-merge is among the
104"** — which is what was measured — and **not** "the merge left the 104 alone", which is false.
Causation for `#198`/`#235` is *not* asserted: `f3de728`'s message carries no `Closes #N` keyword at
all (probed with a positive control), so what is recorded here is a measured coincidence of instants,
and the closing event itself is not in the snapshot.

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
  - `#128` — **bound-to: #255** (ADR-030/D3+D6): **not routable to `/nazgul:patch` independently**; see
    "The `#255` / `#128` pairing" in the Residue section. A second, unreconciled routing is claimed on
    the issue's own body — **#270**. *(Indented on purpose: the residue-cardinality extraction counts
    ids only on `^- **` lines, and `#255` is not a C12 member, so the three bullets still extract
    8 + 7 + 5 = 20.)*
- **C13 (dissolved, 5-of-7 p0/p1 — schedule between objectives):** #96 #97 #98 #100 #103 #224 #236
- **Genuine one-offs:** #110 #147 #175 #179 #190

One mechanical constraint found while linking, recorded so it is not rediscovered: **GitHub caps a parent
at 100 sub-issues** (`Parent cannot have more than 100 sub-issues`). At 109 the link silently spilled the
last nine. The 89/20 split above is under the cap by construction, but any future umbrella near 100
children needs a per-objective parent instead of one flat list.


---

**Re-derived at Move 0 (W4) — the issues the two lists above do not cover, per ADR-030.**
**`documented "89 sub-issues + 20 residue = 109 accounted" → measured "109 accounted, and 44 open
issues in neither"`**, at `at=2026-08-25T23:55:56Z` (frozen snapshot) plus a bounded delta at
`at=2026-08-26T01:10:27Z`. **The 89/20 split, its three bullets and the cap note above are retained
verbatim as the frozen baseline the delta is measured against.**

The uncovered set is **derived, never enumerated**: every `OPEN` issue in the snapshot, minus the class
table's 104, minus the 20 above. The two covered sets overlap by 15 — C12's eight and C13's seven sit
in both — so `104 + 20 − 15 = 109` accounted, and `comm -23` over lexicographically sorted inputs
(`sort -c`-verified, with a `sort -n` control proving `sort -c` can refuse) returns **40**. Four more
issues (`#264`–`#267`) were filed after the snapshot instant and are added from a bounded delta query;
a number-and-state `comm` in both directions proves **no state drifted** among the frozen 169, which is
what licenses reusing the snapshot rather than replacing a record three other work items cite.
**Population: 44.**

This is a larger set than W3's "16 created after the classification instant", and the two reconcile
exactly: `16 − 3 now-closed + 27 that pre-date the classification instant + 4 post-snapshot = 44`. Of
the 27, ten are precisely the population W3-X named as "owned by **no** objective and by no residue
bucket" (the eight still-open dead-on-merge issues plus `#231` and `#232`), and seventeen are W3's own
orphan test's open half — whose `16 type:feature + 1 type:bug (#209)` label split W4 reproduces by an
independent route.

**Three join a class. The test is ADR-030/D1 — the mechanism, never the resemblance:**

| Issue | Class | Mechanism that fixes it without additional scope |
|---|---|---|
| #231 | **C3** (i) → OBJ-G | OBJ-G(i)'s derivable scanner for `producer \| grep -q` / `\| head` under `set -o pipefail` — the SIGPIPE exit-status race. That is the issue's own measured mechanism verbatim, and OBJ-G's exit ("every site found is fixed or enumerated-exempt with a stated reason") disposes of all three of its sites. `X=ABSENT`: live work. |
| #262 | **C3** (iii) → OBJ-H | OBJ-H's own exit criterion — "the inventory's counts are **regenerated, not hand-edited**". Regenerating `docs/guard-fail-open-inventory.md`'s 125-row table from a committed SHA *is* #262's fix, and re-anchors its 24 stale `file:line` rows as a byproduct. W1 already performed that regeneration, so the mechanism is demonstrated, not predicted. |
| #250 | **C5** → OBJ-F | The source→doc derivation C5's objective must build to kill **#143** (`agents/doc-verifier.md`'s hard-coded stale 10-event taxonomy). #250 is the same authored-enumeration defect in the same file, one list over: the fence enumerates 10 `stop_gate` reasons while source emits 13. |

**Arithmetic consequence, recorded and NOT applied here:** C3's `n` would go `24 → 26` and C5's `4 → 5`,
with each row's `M` moving with its `n` (all three are `OPEN`). No class row's `Issues`, `n`, `M` or
ADR-029 token is edited by W4 — TASK-010's verdict line is where that lands.

**Everything else is residue, and every entry carries a reason (ADR-030/D2).** An issue in neither a
class row nor this list **is a finding, not a gap** — `RULES.md` §15 applied to a classification, so
that an unassigned issue stays distinguishable from an unexamined one. **That count is `0`, asserted
mechanically over the two sets and carrying a control that returns `1` when a verdict is removed.**

Seven entries route to **closure, not patch work**: W3-X measured their fixes already present in the
tree at `92bf60f`. ADR-029/D2 forbids `X` from reducing `M`, so they stay open and stay in this
population — but sending them to `/nazgul:patch` would schedule work that does not exist.

| Issue | State | Residue reason |
|---|---|---|
| #109 | OPEN | no class mechanism touches install-mode ignore-routing or `red-run.sh`'s harness-path hardcoding. The fix is `.git/info/exclude` routing plus reading the `project.test_command` that already exists — new behaviour, not an instance any chartered mechanism kills. Nearest by name is C6, whose OBJ-F mechanism is the roster-scoped agent-spec auditor and never reads `scripts/**`. |
| #116 | OPEN | C6's shape exactly; the reason it is not a C6 member is SCOPE, not resemblance. OBJ-F's C6 exit is `F == 0` over the **shipped agent roster** — a prose auditor whose population is `agents/**` path strings. #116 is a root-derivation defect in shell (`scripts/task-transition.sh:70` still derives `NAZGUL_DIR="$PROJECT_ROOT/nazgul"` from one root), which that auditor never reads; absorbing it means widening both its population and its predicate. **Nearest-miss, recorded per D1's stated purpose.** This is the ONE genuinely-live survivor of the dead-on-merge eight (W3-X `X=PARTIAL`) — real work owned by nobody. |
| #129 | OPEN | proposes a new review-orchestration architecture (direct boards + scripted aggregation, no gate transcript). No chartered mechanism builds it; C7's derived scan finds hard-coded review-unit assumptions and does not change who orchestrates a board. |
| #131 | OPEN | C8-adjacent, but OBJ-D's mechanism is dispatch IDENTITY (`AGENT` resolution, a recorded `SubagentStop` envelope, the receipt binding). #131 asks for a new detector for a subagent ending its turn holding a live background task; none of OBJ-D's exit criteria produce it. |
| #134 | OPEN | a new upfront product-breakdown mode (`/nazgul:plan --product`). A feature, not an instance of any class's defect; no chartered mechanism. |
| #135 | OPEN | a new env-signature field in checkpoints plus a drift event. New detection capability; no class's objective builds it. |
| #142 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `tests/lib/assertions.sh` passes needles via `-e` and routes `rc>=2` to `_assert_unevaluable`). No mechanism has anything left to kill. `action: close on the board` — tracked by #265, NOT patch work. |
| #146 | OPEN | the doc-gate, already chartered on PR #87 (22 unresolved review findings, `REVIEW_REQUIRED`). Its own design spec owns it; no class mechanism. |
| #157 | OPEN | C6-adjacent (two trees) but the fix is identity GENERATION (`feat_id` derivation, `NAZGUL_UNIT` namespacing), not path rooting. The roster auditor's population is path strings and does not reach it. |
| #167 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `scripts/lib/review-file-class.sh:46-52` matches `adversarial-*.md`; `review-evidence.sh:675` skips class `artifact`). `action: close on the board` — tracked by #265. |
| #168 | OPEN | a separately chartered objective (Objective A — contracts + graph-aware planning) carrying its own binding spec and plan. Not a defect-class member. |
| #177 | OPEN | asks that the S1-S9 seam inventory move into RULES.md as a numbered section — a durable-placement doctrine move, the same one FEAT-029/TASK-012 made for the §15 registry. No class's objective is chartered to make it. |
| #180 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `scripts/lib/nazgul-root.sh:57-58` returns a set, non-empty `CLAUDE_PROJECT_DIR` unconditionally; `heartbeat.sh:33` gates on the config). `action: close on the board` — tracked by #265. |
| #181 | OPEN | reviewer teammate reuse, design-first — and FEAT-026/ADR-017 retired the named-teammate spawn paths the item is written against, so its premise needs re-grounding before any mechanism could apply to it. |
| #182 | OPEN | a separately chartered objective (Objective B — concurrent feature loops) with its own binding spec. Not a defect-class member. |
| #183 | OPEN | a separately chartered objective (Objective C — Mission Control) with its own binding spec. Not a defect-class member. |
| #184 | OPEN | a separately chartered objective (Objective D slice 1 — Remote Control access). Not a defect-class member. |
| #185 | OPEN | a separately chartered objective (Objective D slice 2 — cloud-hosted loops), explicitly SPEC-GATED on a doctrine decision. Not a defect-class member. |
| #186 | OPEN | a repo-wide lean-comments housekeeping pass, explicitly deliberately low-priority and explicitly "research and ask before implementing". No class mechanism; the count is not urgency. |
| #197 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `scripts/webhook-forward.sh:11` sources `lib/task-utils.sh`, `:52` calls `count_tasks_and_find_active`). `action: close on the board` — tracked by #265. **Mechanism affinity, recorded so it is not lost and explicitly NOT counted in C1's `n`:** had it been live it is a textbook C1 — OBJ-A's "repoint the hand-rolled manifest readers at `task-utils.sh`" — and #203 is the identical defect in `notify.sh` and IS a C1 member. |
| #204 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `tests/test-hook-command-modes.sh` asserts the executable bit on every directly-invoked hook, population derived from `hooks/hooks.json`). `action: close on the board` — tracked by #265. |
| #209 | OPEN | an explicitly-undecomposed umbrella (`pending planning/validation`, "do not auto-start") mixing five reproduced defects with unverified proposals. D1's test cannot be run against a set that has not been separated; assigning the umbrella would put speculative work in a class row. |
| #216 | OPEN | proposes a new cross-reviewer verification round beyond Step 3.6. A new mechanism, not an instance of a chartered one. |
| #221 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: the same shipped change as #167 — the closed four-name `_is_review_meta_file` loop the issue quotes does not exist in this tree). `action: close on the board` — tracked by #265. It sits in `nazgul/inbox/` at rank 4 with `priority: 1`, so the heartbeat would auto-start an objective for shipped work; that consequence is #266's. |
| #230 | OPEN | **fix present in the tree** at `92bf60f` (W3-X `X=PRESENT`: `tests/lib/status-consumer-scan.sh` reads every walk on fd 9). `action: close on the board` — tracked by #265. |
| #232 | OPEN | the quarantine-escape validator gap. Not C3-(i) (no pipeline), not C3-(ii) (no `\ |
| #248 | OPEN | **not a defect.** This is the programme's own board item — the `priority:0` parent of the 89 sub-issues. It is the container for the classes, not a member of one. (TASK-003 excluded it from its 12 candidates for the same reason.) |
| #249 | OPEN | names C2's territory (unbounded `gh`), and C2's shipped mechanism is exactly what does not reach it: `scripts/lib/bounded-net.sh` bounds only processes that SOURCE it, while #249's two populations are skill-load bang-commands and `gh`/`git` in agent and skill PROSE, neither of which sources anything. |
| #253 | OPEN | proposes a NEW cross-cutting mechanism — a registered, honesty-checked refusal corpus per gate. Mechanism-creating, not an instance of a chartered mechanism; no class's objective builds it. |
| #255 | OPEN | **bound-to: #128** (ADR-030/D3+D6, adjudicated by W5 — see "The `#255` / `#128` pairing" in the Residue section): `#128` may not be routed to `/nazgul:patch` independently, and this row's disposition is gated on the pair, not on this row alone. As an assignment, neither candidate class reaches it. Not C3-(i)/(ii)/(iii): the defect is a self-referential comparison (both operands are artifacts of the round that wrote the directory), not a pipeline race, a `\ |
| #256 | OPEN | `cleanup_all_worktrees`'s sweep predicate recognises only `TASK-*` and reports success while leaving `RW-*` state behind. A narrowed predicate, but not C3-(i)/(ii)/(iii) and not on an authorization path; no chartered mechanism produces the `scanned / removed` coverage line it asks for. |
| #257 | OPEN | C10's shape (items recorded, never consumable) but OBJ-I's chartered mechanism is `sync-inbox-to-github.sh --check`, the **inbox to board** enforcement. #257 needs a provider-switch MIGRATION enrolling file-provider items into `connectors.github.map`; OBJ-I builds no migration step. |
| #258 | OPEN | asks for a §15 enrolment of `scripts/lib/gitignore-block.sh`. No class's objective is chartered to enrol entry points generally, and this is an unreported partition rather than a fail-open, so C3's three mechanisms do not address it. |
| #259 | OPEN | a test-fixture gap — the P2 route arms never commit, so the tracked case is exercised nowhere. No chartered mechanism builds fixtures for it. |
| #260 | OPEN | silent truncation at `gh issue list --limit 100` with no record of the drop — §15's looked-vs-never-looked applied to a CAP rather than a lookup. Not C3: a cap is not a guard fail-open. Not C10/OBJ-I: `--check` is the inbox-to-board direction, not the connector's pull path. |
| #261 | OPEN | C2-adjacent, but C2's shipped mechanism bounds each CALL while #261's cost is ~100 sequential calls per tick. Its fix is to read `.priority` from the list query's labels, which bounding does not do. |
| #263 | OPEN | a defect in the programme document itself (`TASK-050` resolves to no artifact). Move 0's own subject matter; no class mechanism kills a dangling identifier in the charter. |
| #264 | OPEN | a defect in the programme document itself (C3's and C10's splits are unenumerated). Same family as #263 and #267. **Read from its title plus `nazgul/inbox/class-sub-splits-are-unenumerated.md`: its board body is EMPTY (0 bytes), filed as #268 under the standing clause.** |
| #265 | OPEN | board-versus-tree reconciliation (7 fixed-but-open issues). C10's shape, but OBJ-I builds `--check` for the **inbox to board** direction and nothing in it observes whether a fix is present in the tree. |
| #266 | OPEN | the **board to inbox** direction — exactly the direction OBJ-I's chartered mechanism does not provide. The issue states it itself: "`sync-inbox-to-github.sh` propagates **inbox to board**. Nothing propagates the other way." |
| #267 | OPEN | a defect in the programme document itself (the `Verified:` line names no extraction method). Same family as #263 and #264. W8 has already amended the sentence to state the extraction, so part of the fix is present; the residual is the missing self-check. |

**Provenance of this list.** Every figure above is recomputable from
`nazgul/context/FEAT-035-issues-snapshot.json` by the commands recorded in
`nazgul/context/FEAT-035-move0-measurements.md` → `### W4`, with the per-issue detail in
`nazgul/context/FEAT-035-uncovered.md`. **Those three files live under a gitignored `nazgul/`
(`install_mode: local`) and are therefore local-only**, which is why the result is written into this
tracked document in full rather than cited from there — the same durability rule the Backlog Rule
states for the inbox, applied to a measurement.

**Filed during W4, not absorbed (standing clause):** **#268** — the board copy of `#264` carries an
empty body (0 bytes) while its inbox item carries 6,940, so the durable copy of that finding is its
title alone. Found while reading `#264`'s text for the D1 mechanism test. A sibling of **#266**, not a
duplicate: #266 is the *state* axis (board → inbox), #268 is the *content* axis on the inbox → board
hand-off, and neither one's check finds the other's instance.

## Two facts not on the board

- **53 of 153 open issues are invisible to the connector — by TWO independent mechanisms, not one, and
  they compose.** The programme recorded a single invisibility. Its **claim** is unchanged and now
  larger: a burn-down measured through the connector under-counts, and OBJ-I's mechanism is what closes
  it. Its **numbers** move and its **scope roughly doubles**. Documented: *23 of 144 invisible, 121
  carrying the label* — retained here beside the measured values rather than silently replaced.
  Re-measured live at `caecf14`, `at=2026-08-26T01:57:37Z`.
  - **By LABEL — 22 of 153 open.** The connector queries `--label nazgul`; an open issue without it is
    never seen. Documented 23 of 144 with 121 labelled; measured **22 of 153 with 131 labelled**. This
    gap did *not* grow during Move 0 — the 22 ids are byte-identical to the frozen snapshot's.
  - **By CAP — 31 of the 131 it does query, and the drop is silent.** `connector_github_pull_list`
    (`scripts/lib/connector-github.sh:204-211`) reads `.connectors.github.pull.max_items` with a default
    of `100` at `:208` and hands it to `gh issue list --limit` at `:211`. **This config has no
    `max_items` key** — `.connectors.github.pull` holds only `label`, `claimed_label` and
    `max_body_bytes` — so the default *always* applies. `gh issue list` returns newest-first, so the cap
    keeps the 100 newest and discards the **oldest**: measured boundary `max(dropped)=125` against
    `min(returned)=126`, a clean partition on issue number. Nothing reports it. The real instrument,
    `inbox_list nazgul/inbox` through the provider seam, returns exactly 100 ids with **0 bytes on
    stderr**, no `scanned / skipped / checked` coverage line and no event — `RULES.md` §15 at a cap
    instead of a lookup, and worse than either, because it looked at 100 of 131 and answered as though
    it had looked at all of them. Filed **#260**; the sibling per-candidate API cost is **#261**.
  - **They do not overlap, so they add.** The cap acts only on what the label admitted, so `comm -12`
    of the two sets is `0` and the union is exactly `22 + 31 = 53`. The visible set is **exactly 100**
    and is pinned there: past 100 labelled issues every further filing is invisible on arrival.
  - **The composition is where the harm lands. All seven C13 issues are invisible.**
    #96 #97 #98 #100 #103 are lost to the CAP (every one `priority:1`); #224 and #236 are lost to
    the LABEL. So the class this programme dissolves to `/nazgul:patch` and calls *"the cheapest
    morale wins on the board"* is **0 of 7 visible** to the mechanism that would schedule it.
    Neither invisibility finds all seven alone; only the composed view
    does. Across the whole class table 41 of the 101 classed-and-open issues are invisible, and **39 of
    the 55 open p0/p1 issues — 71%** — while nothing at p3 or below is invisible at all. The cap
    discards by age, and in this backlog age tracks priority.
  - **Move 0 widened the gap it was measuring, one for one, and that is a property rather than a
    confound.** The composed total at three reference points: **42 of 142** at `92bf60f` (the
    figure Move 0 opened with), **46 of 146** at the frozen snapshot, **53 of 153** live — the
    denominator and the gap grow together, and the gap grows faster.
    Its eleven filings (#260–#270) moved the labelled count 120 → 131 and the dropped count
    20 → 31; filing #271 during this measurement moved them to 132 / 32, evicting #126 — measured before
    and after, inside the same task. The ids evicted are never the ids filed: new work enters at the top
    and old work falls off the bottom, so a positional cap turns every act of filing into an act of
    hiding. **#271** is the compounding defect found here: the "handled" filter runs *after* the cap, so
    each claimed issue shrinks the pool (measured 100 → 90) and admits none of the 31 in its place —
    under normal operation the visible pool decays while the invisible tail never moves.
  - Full derivation, both sets enumerated, every `comm` input verified lexicographically sorted and
    every live call timestamped: `nazgul/context/FEAT-035-connector-visibility.md` (W6). **Recorded, not
    executed** (ADR-029/D7): the connector is untouched, no `max_items` key was added, the cap was not
    raised, and no issue was labelled or edited — including **#260**, whose own text still says *"the 20
    oldest"* and is stale by the very mechanism it describes.
- **The non-delivery detector does not cover the dispatch path an operator actually uses.** Four subagents
  in one session ended their turn announcing the next step with the work already done. The bounded resume
  fires on `SubagentStop` inside the loop; direct `Agent` dispatches from an interactive session are
  uncovered. This strengthens OBJ-D's keystone.
