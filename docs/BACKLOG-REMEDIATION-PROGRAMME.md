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
