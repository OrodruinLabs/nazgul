# self-audit fixture provenance

## `approve-board/`

- **Captured from**: `~/Documents/Software Development/ChessLens/nazgul/reviews/TASK-003/`
- **Captured on**: 2026-08-08 (TASK-011, FEAT-029)
- **Command**: `cp <that dir>/*.md tests/fixtures/self-audit/approve-board/`
- **Producer**: real generated reviewers writing real verdicts in a real Nazgul
  run — not hand-authored, not reconstructed from memory.
- **Content**: 11 reviewer verdict files, all `verdict: APPROVE`. Six of them
  (`a11y`, `api`, `db`, `dependency`, `performance`, `type`) carry the
  no-rejections boilerplate in one of its real spellings — `- REJECT: none`,
  `- **REJECT**: none.`, `- **REJECT**: None.` — and two more mention `REJECT`
  in ordinary prose.

### What it pins

A unanimous APPROVE board must produce **zero** rejection findings. Against the
pre-TASK-011 miner, whose `elif grep -q 'REJECT'` fallback matched the
boilerplate, this exact board produced six false findings. The census that
motivated the fix measured 70 such entries across four projects.

### Mutations applied at test time (never committed)

- One file's frontmatter verdict is rewritten to `CHANGES_REQUESTED` so the
  board is proven capable of turning red — a fixture that can only pass is
  evidence of nothing.
- A NUL byte is injected into a copy of a rejecting file. No NUL-bearing verdict
  file was found in the 144-file real corpus scanned on capture day, so this one
  mutation is synthetic and labelled as such; the behaviour it pins is real
  (BSD `grep` without `-a` reports NO match in a NUL-bearing file, so the same
  board would mine differently depending on a byte nobody can see).
