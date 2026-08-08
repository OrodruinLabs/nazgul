# self-audit fixture provenance

## `approve-board/`

- **Tier**: `captured-redacted` — the *form* was captured from a real producer; the
  *subject prose* was rewritten. See "What is captured and what is not" below, which
  states precisely which half is evidence and which half is not.
- **Producer**: real generated reviewers writing real verdicts in a real Nazgul run —
  not hand-authored, not reconstructed from memory. Eleven lanes, one file each,
  unanimous APPROVE.
- **Captured on**: 2026-08-08 (TASK-011, FEAT-029)
- **Redacted on**: 2026-08-08 (PATCH-001)

### Why it was redacted

The files were first committed verbatim from a run in an unrelated **private** project,
into this **public** repository. That violated `CLAUDE.md:117` ("Small product-input
goldens; no Nazgul runtime state") and published, in the clear: absolute home-directory
paths, that project's commit SHAs and branch name, its architectural rules and
critical-path source filenames, and its *unresolved* security posture — a list of named
residual advisories, which is the one category here that is actively harmful to publish
rather than merely untidy.

The redaction replaced the review *subject* with a subject-neutral Nazgul task (a shell
library gaining a `## Red-Run Evidence` parser, plus its tests) and left the review
*form* byte-for-byte where the form is what the fixture pins.

### What is captured and what is not

| Aspect | Status | Why it matters |
|---|---|---|
| File count, one file per reviewer lane | **captured** | the real shape of a full board |
| Verdict-line position, spelling, and token | **captured** | this is the surface the consumer parses |
| `REJECT` boilerplate: how many files carry it, in which spellings | **captured** | the exact thing that produced the false findings |
| The near-miss `- **Verdict**:` bullet | **captured** | proves the consumer's anchor rejects it |
| Prose, package names, file paths, SHAs, findings | **rewritten** | not evidence; was the leak |

The rewritten prose is therefore **not** evidence of how a reviewer writes. Nothing in
this fixture should be cited as a sample of real reviewer output. The captured rows
above are the only load-bearing ones.

### Form pins (recomputed from disk, 2026-08-08)

Regenerate all of these with the commands given; do not hand-edit the numbers.

- **11** files, all `*.md`, no `consolidated-feedback.md`
  — its absence is what keeps `not-applicable=0` in the coverage assertion.
  `ls approve-board/*.md | wc -l`
- **11** consumer-visible verdict lines, exactly one per file, **each at line 2**, every
  one of them the single token `verdict: APPROVE`.
  `grep -rnaEi '^[[:space:]]*\**verdict\**:[[:space:]]*[A-Za-z_]+' approve-board/`
- **6** total occurrences of `REJECT` under `approve-board/`, in **6 distinct files**,
  in exactly **2** spellings — and nowhere else under `approve-board/`, in prose or
  otherwise. (This file is the fixture's documentation, not part of it: it sits one
  directory up, the tests copy only `approve-board/*.md`, so the mentions of `REJECT`
  in the prose here are never scanned by anything.)
  | Spelling | Count | Files |
  |---|---|---|
  | `- REJECT: none` | 5 | `a11y`, `api`, `db`, `performance`, `type` |
  | `- REJECT: none.` (trailing period) | 1 | `dependency` |

  `grep -rna 'REJECT' approve-board/` — must print exactly 6 lines.
  `grep -lE '^-[[:space:]]*\*{0,2}REJECT' approve-board/*.md | wc -l` — must print `6`.
- **1** near-miss, at `architect-reviewer.md`:
  `- **Verdict**: PASS (confidence below CONCERN threshold; already covered by verification gate)`
  It begins with `- `, so the consumer's `^[[:space:]]*\**verdict\**:` anchor does **not**
  match it. That is the point: it pins the anchor's tightness. Keep it.

Total load-bearing surface: **17 lines** (11 verdict + 6 boilerplate), plus the
near-miss that must keep *failing* to match.

> **A correction, recorded rather than quietly fixed.** The previous version of this
> file misdescribed its own fixture: it claimed three boilerplate spellings including a
> bold `- **REJECT**: none.` variant, and claimed "two more mention `REJECT` in ordinary
> prose." Neither was true then or now — `grep` finds 6 occurrences in 2 plain
> spellings, zero bold, zero prose. A provenance file that misstates the fixture it
> documents is worse than none, because it is the thing a future reader trusts instead
> of re-running the grep. Hence the commands above: every pin here is reproducible from
> disk in one line.

### What it pins

A unanimous APPROVE board must produce **zero** rejection findings. Against the
pre-TASK-011 miner, whose `elif grep -q 'REJECT'` fallback matched the boilerplate,
this exact board produced six false findings — one per boilerplate line. The census
that motivated the fix measured 70 such entries across four projects.

The redaction preserves this precisely because the count and spellings above are
unchanged: the fixture still reproduces the original defect against the original miner.

### Consumer

`scripts/self-audit.sh` → `_review_verdict()` reads **one** line per file:

```sh
grep -aoEi '^[[:space:]]*\**verdict\**:[[:space:]]*[A-Za-z_]+' "$1" | head -1
```

`-a` is mandatory: BSD `grep` reports NO match in a NUL-bearing file. Nothing else in
these files is parsed by anything.

### Mutations applied at test time (never committed)

- **`qa-reviewer.md` is the mutation target.** Its frontmatter verdict is rewritten to
  `CHANGES_REQUESTED` via `sed 's/^verdict: APPROVE$/verdict: CHANGES_REQUESTED/'`, so
  the board is proven capable of turning red — a fixture that can only pass is evidence
  of nothing. The anchored `^...$` pattern is why that file's verdict line must stay
  exactly `verdict: APPROVE`, with no leading or trailing whitespace.
- **A NUL byte is injected** into a copy of the mutated file. No NUL-bearing verdict
  file was found in the 144-file real corpus scanned on capture day, so this one
  mutation is synthetic and labelled as such; the behaviour it pins is real (BSD `grep`
  without `-a` reports NO match in a NUL-bearing file, so the same board would mine
  differently depending on a byte nobody can see).

### Tests over this fixture

`tests/test-self-audit.sh` — T22 (unanimous board yields zero findings, all 11
classified), T23 (one real rejection is found, exactly once — not once per `REJECT`
mention), T24 (the NUL-bearing rejection is still detected and counted as checked).
All three must pass unchanged so long as the pins above hold.
