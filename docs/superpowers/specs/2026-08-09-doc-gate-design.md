# Doc Gate — design

**Date:** 2026-08-09
**Status:** design approved, spec pending user review
**Reviewed by:** `architect-reviewer` (verdict `CHANGES_REQUESTED`, confidence 87) — every REJECT and CONCERN it raised is folded into the design below
**Verified against:** commit `c44add2`, worktree `.claude/worktrees/doc-gate-design`, baseline `99 files checked, 99 passed, 0 failed`

> **Freshness re-check — 2026-08-15, against `d6f7582` (v2.32.0).** Two releases shipped since this
> design was written (FEAT-029 v2.31.0, FEAT-030 v2.32.0). Re-verified:
>
> - **The core thesis is unchanged.** Generated documents are still consumed as source of truth and
>   still reviewed by nothing; the post-loop doc-verifier still fires at objective end and still only
>   existence-checks. The design's reason to exist stands.
> - **The motivating incident below still reproduces.** `nazgul-root.sh:56` is still
>   `git rev-parse --show-toplevel` and `_nr_has_marker` is still at `:44`. Probed from a worktree cwd
>   on 2026-08-15 with `CLAUDE_PROJECT_DIR` unset: `resolve_nazgul_dir` returns the *worktree's own*
>   `nazgul/`, exactly as recorded below. FEAT-030 did **not** change the resolver — it made callers
>   designate the main worktree explicitly (`CLAUDE_PROJECT_DIR=`, `<main_worktree_path>/` in agent
>   specs), which mitigates the agent-facing blast radius without removing the mechanism. Read the
>   incident as "still true, now less reachable from the loop's own agents."
> - **Three citations were corrected** for line drift: `stop-hook.sh:1077`→`:1083` (doc-verifier
>   gate), `stop-hook.sh:952`→`:957` (`TOTAL_COUNT == 0` exit), and `doc-generator.md:112-148`→
>   `:114,130,132` (Artifact Claim Evidence Ledger — that range now holds FEAT-030's rewritten
>   `<main_worktree_path>` path handling, so the old citation pointed at different content, not just a
>   shifted line). `RULES.md:230` was checked and is still exact.
> - **Not audited:** the remaining ~30 file:line citations in this spec and its plan. All cited files
>   exist; individual line numbers were not each re-verified. Treat them as indicative and re-check
>   before implementing.
> - Baseline in the header (`99 files checked`) predates the current suite (105 test files).

## Problem

`agents/doc-generator.md` produces the PRD, TRD, ADRs, and test plan that every downstream
agent treats as source of truth. Nothing reviews them.

- The review board gates **code only**. No document ever passes a reviewer. The planner
  consumes the TRD the moment it is written.
- The one existing document check — the post-loop doc-verifier gate at
  `scripts/stop-hook.sh:1083` — fires at objective **end**, after every task already
  consumed the docs, and only existence-checks event names, config keys, and script paths.
  It does not assess design soundness.
- The one honesty mechanism inside the generator, the Artifact Claim Evidence Ledger
  (`agents/doc-generator.md:114,130,132`), covers only generated-path claims, and `RULES.md:230`
  states its tier plainly: *"Nothing mechanically stops that claim; a reviewer must catch it."*

The whole pre-planning phase is model-driven prose in `skills/start/SKILL.md`. The stop-hook
is inert there by construction — `scripts/stop-hook.sh:957` exits unconditionally when
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

**Why not the Stop event.** Gating `stop-hook.sh:957` keys on what the loop happens to hold
*when a turn ends*, which is not the pre-planning phase. In `DOCS_READY` the skill runs
doc-generator → planner inside one uninterrupted turn (`skills/start/SKILL.md:435-438`);
`DISCOVERY_DONE` (`:452-453`) and `FRESH` (`:466+`) do the same. So in AFK the planner
routinely runs in the same turn as the generator, tasks exist by Stop time, and the gate
never sees the state it was written for. In HITL, *"pause for doc review"* (`:436`, `:452`)
guarantees a stop in exactly that state. The gate would fire reliably only in the mode where
a human is already reading the docs, and unreliably in the mode designed for by decision 1.

**Backstop.** The `stop-hook.sh:957` branch survives, demoted, for the case where the planner
is reached by another route. It carries two mandatory properties:

- **A bounded attempt counter**, `nazgul/logs/.doc-gate-attempts`, in the `read -r OBJ CNT` /
  non-numeric-coercion / `-lt 3` shape at `stop-hook.sh:1091-1101`, with a loud stderr line,
  typed event, and — on exhaustion — an attestation written in the (d) form recording
  `backstop_exhausted` as its verdict, so an exhausted gate is a readable decision rather than
  an absent file. Line 952 precedes max-iterations (`:1230`), the budget ceiling
  (`:1240`), consecutive failures (`:1248`), and the parallel hard stop (`:1256`); a block
  there outranks all four. The hazard is already documented in this file at `:973-974`:
  *"A bounded attempt counter keeps an unwritable marker from bricking the loop (this exit
  path is BEFORE the max-iteration backstop)."* Decision 4's doc-generator retries count in
  **this same ladder** — two independent bounds around one gate can ping-pong.

  **The ladder is objective-keyed (`feat_id`); the attestation is content-keyed. They must
  not share a key.** Retries regenerate documents, which changes `docs_hash`. A ladder keyed
  to the doc set would reset its own counter on every retry — an unbounded loop wearing a
  bounded counter, at the position that outranks all four backstops above. The shipped pair
  gets this right and is the shape to copy: `.docs-verified` and `.docs-verify-attempts` are
  **both** objective-keyed, compared against `feat_id` (`stop-hook.sh:1082-1097`). Only the
  attestation is content-keyed, because it attests bytes and regenerating must invalidate
  it — that is the whole point of (d).
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

## The typed contradiction artifact

**Sidecar file for the DATA, in-prompt fenced block for the CONTRACT. Written by a script,
never hand-authored by the agent.**

The Artifact Claim Evidence Ledger is already this split, and reading it correctly settles the
question rather than leaving it to taste. Its **contract** lives as the fenced
`artifact-claim-ledger:begin/end` block in the agent prompt (`agents/doc-generator.md:140-148`)
and is pinned by `tests/test-doc-generator-contract.sh` rendering the prompt through the real
producer. Its **data** lives inside the document and is pinned by nothing — `RULES.md:230`
says so without flinching. So: copy the contract half, reject the data half. Four reasons
specific to this artifact:

1. **Circularity with (d).** Findings inside a document change the document, which changes
   `docs_hash`, which invalidates the attestation computed over it. Escaping that needs a
   parser hash-excluding a Markdown region. A sidecar *named by* the hash is acyclic.
2. **Findings are cross-document.** "The TRD asserts X, ADR-002 assumed Y, the code does Z"
   has no owning document.
3. **The consumer is a hook with a 10s budget** (`hooks/hooks.json:73-75`). The existing
   contract test needed ~60 lines of `awk`/`sed` to parse a fixed three-row table. A gate
   reads JSON with `jq` — this repo's own rule (`CLAUDE.md` Code Style).
4. **Retry history must survive the retry.** An embedded block is overwritten by the pass that
   fixes it.

**Producer: `scripts/doc-gate.sh emit`, logic in `scripts/lib/doc-gate.sh`.** The generator
has `Bash` and calls it once per finding, never writing JSON itself — the `raise_finding()`
posture (`scripts/lib/raise-finding.sh:40-101`, `RULES.md:385-392`). Consequence: *malformed*
means truncation or a crash mid-write, not a model formatting slip, which is what makes it
safe to treat malformed as corrupt. `scripts/lib/doc-gate.sh` is also the **sole** computer of
`docs_hash`, sourced by producer, guard, and backstop — the `resolve_review_unit()` discipline
(`RULES.md:92`: *"both gates read from the same resolution instead of two independent
re-derivations drifting apart"*).

| Path | Contents | Key |
|---|---|---|
| `nazgul/docs/.review/<docs-hash>.contradictions.json` | Generator channel findings | content |
| `nazgul/docs/.review/<docs-hash>.json` | (d) attestation: reviewer verdict + merged split | content |
| `nazgul/logs/.doc-gate-attempts` | `<feat_id> <count>` | **objective** |

Co-location follows `RULES.md:93`. Two free consequences: the post-loop doc-verifier's
`find … -maxdepth 1 -name "*.md"` (`stop-hook.sh:1087`) does not see `.review/`; and
`/nazgul:reset` (`skills/reset/SKILL.md:90`) and new-objective archival
(`skills/start/SKILL.md:560`) move `nazgul/docs/` wholesale, so attestations archive with the
documents they attest.

### `docs_hash` — normative derivation

Computed only by `doc_set_hash()`: candidate set `nazgul/docs/*.md` at `-maxdepth 1`,
**excluding `manifest.md`** (bookkeeping about documents, not a document making claims; its
`Approved` column churns without any claim changing); `LC_ALL=C sort` the relative paths; emit
`<sha256>  <relpath>\n` per file; hash that stream; take the first 16 hex characters. SHA-256
resolves through one helper choosing `shasum -a 256` / `sha256sum`. Neither present → **hard
error, never a fallback hash**: a weaker key silently mints a different namespace and every
doc set reads as unattested forever.

### Sidecar schema — v1

Top level, every field required; `findings` may be empty but never absent.

| Field | Type | Notes |
|---|---|---|
| `sv` | int | `1`. Precedent: `sv:1` at `subagent-stop.sh:180`. |
| `docs_hash` | string | The 16-hex key this finding set is bound to. |
| `feat_id` | string | Objective id at emit time. |
| `generator` | string | `"doc-generator"`. |
| `generated_at` | string | `%Y-%m-%dT%H:%M:%SZ`, UTC. |
| `scanned` / `skipped` / `checked` / `findings_count` | int | Coverage quadruple, **stored**, so the gate reports honestly without re-deriving. `scanned == skipped + checked` asserted at write. |
| `skip_reasons` | object | `{<reason>: <count>}` over the closed set below; must sum to `skipped`. |
| `findings` | array | Below. |

Per finding:

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | `DG-<docs-hash>-<NNN>`. Stable — (e) cites it. |
| `doc` | string | yes | Repo-relative path of the claiming document. |
| `claim` | string | yes | Verbatim quote of the claiming sentence. |
| `claim_locator` | string | yes | `<doc>:<line>` at emit time. |
| `class` | enum | yes | `architecture-invariant` \| `security` \| `ordinary` |
| `invariant_ref` | string | yes when `architecture-invariant`, else `null` | An id from the closed registry below. **The field that makes classification decidable.** |
| `verifiability` | enum | yes | `mechanical` \| `judgment` |
| `expected` | string | yes when `mechanical`, else `null` | What the document asserts. |
| `observed` | string | yes when `mechanical`, else `null` | What the code does. |
| `evidence` | array[string] | yes when `mechanical`, `minItems: 1` | `file:line`; paths must resolve. |
| `probe` | string \| null | yes (nullable) | The command actually run, or `null`. Never one that was not run. |
| `severity` | enum | yes | `HIGH` \| `MEDIUM` \| `LOW` (`RULES.md:89`). |
| `confidence` | int 0-100 | yes | Same axis as the board, so one threshold governs both channels (`RULES.md:85`). |
| `disposition` | enum | yes | `open` \| `retry_filed` \| `converged` \| `dissent_recorded` \| `blocked` |
| `retry_count` | int | yes | Default `0`. |

Every enumerated field is **closed**. Precedent is load-bearing: `_TTG_RED_RUN_NA_TOKENS` is
*"never a pattern guess — an open-ended excuse field is an allow-everything field"*
(`task-transition-guard.sh:129-131`), with unrecognized tokens rejected by name (`:248-249`).

### Fenced contract block — paste into `agents/doc-generator.md`

Mirrors `:140-148` in form, so `spec_field()` parses it with no new machinery:

```
<!-- doc-contradiction-ledger:begin — checked against this contract by tests/test-doc-generator-contract.sh -->
artifact: nazgul/docs/.review/<docs-hash>.contradictions.json
writer: scripts/doc-gate.sh emit
top_level: sv | docs_hash | feat_id | generator | generated_at | scanned | skipped | checked | findings_count | skip_reasons | findings
finding_fields: id | doc | claim | claim_locator | class | invariant_ref | verifiability | expected | observed | evidence | probe | severity | confidence | disposition | retry_count
class_tokens: architecture-invariant security ordinary
verifiability_tokens: mechanical judgment
severity_tokens: HIGH MEDIUM LOW
disposition_tokens: open retry_filed converged dissent_recorded blocked
skip_reasons: unreadable not-a-document no-channel-available
mechanical_finding: expected != null; observed != null; evidence minItems 1; every evidence path resolves
invariant_finding: class == architecture-invariant requires invariant_ref in the RULES.md §21 registry
counts: scanned == skipped + checked; skip_reasons values sum to skipped
forbidden: agent_authored_json; assumed_command; invented_observed; unenumerated_token
absent_artifact_is_not_a_clean_one: true
<!-- doc-contradiction-ledger:end -->
```

### The three absence states

The generator writes documents, **then** hashes, **then** emits — so the sidecar is bound to
the exact bytes it describes. Per `RULES.md:525-532`, "found none" must not collapse into
"never looked":

| On-disk state | Name | Gate disposition |
|---|---|---|
| Sidecar for current hash, `findings: []`, counts consistent | `looked_found_none` | Counts as **checked**; may proceed on this channel |
| **No** sidecar for the current hash | `generator_channel_unrun` | Counts as **skipped** (`no-channel-available`). Never clean. If the reviewer channel also did not run, `K == 0` → NOTHING CHECKED → **block** |
| Present but unparseable, count-inconsistent, or bound to a different hash | `generator_channel_corrupt` | **Fires as its own finding**, `class: architecture-invariant`, `invariant_ref: INV-COVERAGE` |

The third row transplants the IMPLEMENTED gate's posture verbatim — *"a Base SHA present but
unresolvable rejects the manifest as corrupt"* (`task-transition-guard.sh:210-211`). Absent is
a weaker claim than present-and-wrong; they are not the same state.

## Classification — architecture-invariant vs ordinary

**Classify by citation, not by adjective.** A finding is architecture-invariant **iff it names
an invariant from a closed registry and passes at least one of two file-set/reversibility
tests.** That converts a judgment call into a lookup plus two yes/no questions answerable from
the finding record alone — which is what makes it repeatable, and what lets a script verify
the *form* of a classification whose *taste* it cannot verify.

### The registry — new `RULES.md` §21, closed

A durable file, not a per-objective TRD: the coverage registry already rotted once by citing a
TRD section archived out from under it (`RULES.md:541-543`).

| id | Invariant | Source | Implementing files |
|---|---|---|---|
| `INV-STATE` | State-machine edges and their evidence gates | §2, Rule 8 | `lib/task-transition-guard.sh`, `task-transition.sh` |
| `INV-WRITER` | Sole sanctioned status writer; CAS + reconciliation | §2, §5 | `task-transition.sh`, `stop-hook.sh:249-300` |
| `INV-BOARD` | Unanimous board, verdict grammar, confidence threshold, unit resolution | §3.1/3.2/3.6/3.9 | `lib/review-evidence.sh` |
| `INV-SCOPE` | Implementer file scope + `PROJECT_ROOT` bound | §8 | `task-state-guard.sh` |
| `INV-RECOVERY` | Recovery Pointer + checkpoint + manifest fully describe resumable state | §4, Rule 10 | `stop-hook.sh` checkpoint writer, `post-compact.sh` |
| `INV-COVERAGE` | Coverage-honesty grammar; looked-vs-never-looked | §15 | every enrolled entry point |
| `INV-DISPATCH` | One-shot dispatch primacy; caller-created worktrees | §18 | `parallel-dispatch-guard.sh`, agent specs |
| `INV-DELIVERY` | Empty-return detection + bounded resume | §19 | `subagent-stop.sh` |
| `INV-ROOT` | Single shared root resolver; `CLAUDE_PROJECT_DIR` precedence | §15 (ADR-008) | `lib/nazgul-root.sh` |
| `INV-FAILCLOSED` | Fail-closed security posture; AFK security reject → BLOCKED | §3.5, §9 | `stop-hook.sh`, `lib/parallel-batch.sh` |
| `INV-SECRET` | No credential in config or logs; `gh auth` only | §16 | `lib/connector-github.sh` |

Adding an id is a deliberate, reviewable `RULES.md` edit — enumerate-the-allowed-set, as with
R1's operator-name allowlist (`RULES.md:557-564`) and the red-run token list.

### The procedure

**T0 — Security override, before T1.** `class: security` is architecture-invariant
unconditionally. Mirrors fix-first rule 2 (*"Security findings are ALWAYS ASK, regardless of
confidence"*) and `RULES.md:88`.

**T1 — Citation.** Does the finding name an `invariant_ref` present in §21 **and** quote the
clause the document contradicts? → **No: `ordinary`. Stop.** No uncertainty branch here — this
is what keeps T4 narrow by construction.

**T2 — Blast.** Would the claim, implemented as written, require changing a file in the cited
invariant's *Implementing files* column, **or** move any gate's decision in the **allow**
direction (a check that blocks today ceasing to block; a degradation path becoming reachable)?

**T3 — Reversibility.** If the objective ships with the claim uncorrected, is the state
repairable by a later ordinary task — **without** a config migration, **without** re-reviewing
already-`DONE` work, **without** a manual `task-transition.sh repair`? → Not repairable →
architecture-invariant.

**Rule: `architecture-invariant` iff T1 ∧ (T2 ∨ T3).**

**T4 — Default when uncertain: `architecture-invariant` (fail closed).** Reachable only when
T1 passed and T2/T3 are both genuinely ambiguous. Weighed for *this* gate rather than
inherited, as `RULES.md` §15 / ADR-009 requires: a false deny costs **one human
acknowledgement, before planning, nothing built yet, once per objective**. A false allow costs
the FEAT-030 shape — thirteen tasks derived from a contradicted premise, each passing a code
board with no way to know, because the board reviews diffs against docs it never questions.
The asymmetry is not close.

### Relationship to fix-first's AUTO-FIX/ASK

**Orthogonal axes**, and the disagreement is real rather than a modelling artifact.

| | fix-first | this design |
|---|---|---|
| Question | *Who applies the fix?* | *Can it converge by retry?* (`verifiability`) and *what happens if we proceed?* (`class`) |
| Subject | Code review findings | Document findings |
| Applied by | feedback-aggregator, **after** a board verdict | The gate, **before** planning |

Proof of non-identity is the motivating case: fix-first lists *"Design/architecture decisions"*
under ASK (`fix-first-heuristic.md:19`), routing the FEAT-030 finding to ASK — while this
design routes it to a bounded retry that converges. Both are right on their own axis.

**Composition, normative: `verifiability` governs the retry loop; `class` governs the terminal
disposition. They compose in that order and never override each other.**

1. `mechanical` → file a retry carrying `expected`/`observed`/`evidence`, bounded by the
   **objective-keyed** ladder.
2. On convergence → `disposition: converged`, and **`class` becomes irrelevant** — a corrected
   document has nothing to fail closed about. This is why "mechanical ∧ architecture-invariant"
   is not a deadlock: the retry runs first and normally ends it.
3. On non-convergence after the bound, **or** `verifiability: judgment` → `class` decides.
   `architecture-invariant` or `security` → objective **BLOCKS**. `ordinary` → proceed,
   `disposition: dissent_recorded`.
4. Independent of 1–3: any `converged` finding whose `class` is `architecture-invariant` still
   triggers **(e)** if tasks already exist derived from the old claim. Convergence fixes the
   document; it does not retro-fix the plan.

### Worked example — the FEAT-030 finding

The cell where the two classifications disagree. `class: architecture-invariant`,
`invariant_ref: INV-ROOT`, `verifiability: mechanical`, `expected` = redirects a worktree-cwd
caller to the main tree, `observed` = returns the worktree's own toplevel,
`evidence: ["scripts/lib/nazgul-root.sh:49","…:56","…:68"]`, `HIGH`/`95`.

Classification: T0 no. T1 yes. T2 **yes** — implemented as written, thirteen tasks would call
`resolve_project_root()` expecting redirection, changing the behaviour of the invariant's own
implementing file. → `architecture-invariant`.

Routing: `mechanical` → step 1, retry filed. The generator rewrites the objective statement to
*"resolve via an explicit `CLAUDE_PROJECT_DIR=` designation paired with `nazgul-root.sh`"*.
Hash changes, re-emit clean → `converged`. Step 4: no tasks existed yet, so (e) is a no-op.
**Planning proceeds. Nobody is woken.**

That outcome is the argument for the split being placed correctly: the design's own motivating
incident does **not** reach the fail-closed path. It needed one retry, not a human at 2am. The
severity split exists for what retry cannot settle — `judgment` findings and non-convergence.

## Test plan

### Extended

| File | What it gains | Can it fail? |
|---|---|---|
| `tests/test-config-schema.sh` | New keys in `templates/config.json`; kill switch defaults `true` | Yes — drop a key |
| `tests/test-migrate-config.sh` | v36→v37 additive step; **explicit `false` preserved**, per `migrate-config.sh:376` | Yes — a `//` default re-enables an explicit `false` |
| `tests/test-coverage-honesty.sh` | `doc-gate` added to `ENTRY_POINTS` (`:19`), driven under forced all-skip; the tally at `:220-230` fails if never driven | Yes, by construction |
| `tests/test-doc-generator-contract.sh` | Parses the new ledger block from the **rendered** prompt via `render_agent_prompt` (`:144`), reusing `spec_field()`; plus a strip-the-block control in the `:277-287` shape | Yes — the shipped control proves it |
| `tests/test-stop-hook.sh` | Driven-objective predicate; **objective-keyed** ladder; exhaustion writes a `backstop_exhausted` attestation | Yes |
| `tests/test-subagent-stop.sh` | `doc-reviewer` must **not** resolve to a code review unit — assert `_resolve_review_unit_for_agent` returns empty against a populated `reviews/*/.dispatch.json` | Yes — substitute `architect-reviewer` and it resolves, making (c)'s rationale executable |
| `tests/test-shellcheck.sh`, `test-agent-worktree-contract.sh` | No edit; both scan the whole tree/roster | Yes |

### Added

**`tests/test-doc-gate-guard.sh`** — driven through real Agent envelopes in the shipped shape
(`tests/test-parallel-dispatch-guard.sh:21-52`).

| # | Fixture state | Dispatch | Expect |
|---|---|---|---|
| 1 | Attestation for current hash, `APPROVE` | `nazgul:planner` | allow, 0 |
| 2 | No attestation, no sidecar | `nazgul:planner` | **deny, 2** |
| 3 | Sidecar current hash, `findings: []`, no reviewer | `nazgul:planner` | allow, 0 + `doc_gate reason:degraded_no_reviewer` |
| 4 | Sidecar bound to a **stale** hash only | `nazgul:planner` | **deny, 2** |
| 5 | Sidecar truncated mid-write | `nazgul:planner` | **deny, 2**, `generator_channel_corrupt` |
| 6 | One `architecture-invariant`, `disposition: open` | `nazgul:planner` | **deny, 2** |
| 7 | Same finding, `converged` | `nazgul:planner` | allow, 0 |
| 8 | One `ordinary`, `dissent_recorded` | `nazgul:planner` | allow, 0 |
| 9 | Any state | `nazgul:implementer` | allow, 0 — planner-scoped |
| 10 | Kill switch `false`, state as case 6 | `nazgul:planner` | allow, 0, **event still fires** |
| 11 | No `nazgul/config.json` | `nazgul:planner` | allow, 0 |

Cases 2/3/7 are the semantic core and are mutually distinguishing: unrun ≠ clean ≠ converged.

**`tests/test-doc-gate-lib.sh`** — `doc_set_hash()` determinism; sensitivity to a one-byte
edit; **insensitivity to `manifest.md`**; stability under `LC_ALL=C` and creation order; hard
error (not a fallback) with no SHA-256 binary. Then classification over stored records: T1 miss
→ `ordinary`; T1 + T2 → invariant; T1 with T2/T3 ambiguous → invariant by T4; `security` →
invariant with T1 unsatisfied; a non-registry `invariant_ref` → rejected, not silently
downgraded. Then routing: mechanical+invariant → `retry_filed`; **the ladder does not reset
when `docs_hash` changes but `feat_id` does not**.

### Red-run evidence

Every implementing script and both new test files are `scripts/**`/`tests/**`, so
`_ttg_red_run_in_scope()` returns 0 (`task-transition-guard.sh:195`) and IMPLEMENTED is blocked
without evidence. **No enumerated exemption is available to any task in this design** — the
closed list is `docs-only comment-only revert fixture-capture-only` (`:131`) and none fits,
including the prompt/RULES-only task, whose contract test lives under `tests/`.

```
scripts/red-run.sh TASK-NNN --filter=doc-gate-guard --project-root=<main worktree path>
```

One wrinkle to write into the manifest rather than discover: the red run for the
**contract-test** task must copy the changed `test-doc-generator-contract.sh` into the
pre-change tree and fail there *because the fenced block is absent from the pre-change prompt*
— exactly what the shipped control asserts in-suite (`:282-287`). A green red run means the
new assertions are not reading the new block.

### Fixtures

**`tests/fixtures/doc-gate/contradictions/`**, tier `captured-redacted`. Producer: a real run
of the shipped `scripts/doc-gate.sh emit` against this repository's own `nazgul/docs/` on
FEAT-030 — the six real contradictions, first-party subject matter and clear of R3. Form-pins
recomputed from disk in the `tests/fixtures/self-audit/PROVENANCE.md:15-21` block form: file
count, findings count, `mechanical`/`judgment` mix, exactly one `invariant_ref`-bearing
finding, every enum token from the closed sets.

**Mutation applied at test time, never committed** (`PROVENANCE.md:125-131`, *"a fixture that
can only pass is evidence of nothing"*): flip one finding's `class` from
`architecture-invariant` to `ordinary` via anchored `sed`; assert the split changes from block
to proceed.

**`tests/fixtures/doc-gate/envelopes/`**, tier `captured-redacted`. One **real**
`nazgul:planner` PreToolUse envelope from a live dispatch, absolute paths redacted (R1 forbids
`/Users/<name>/`, `RULES.md:557-564`). The guard is driven against **both** the captured
envelope and `jq`-built variants: synthetics cover the matrix cheaply, the capture pins fields
a hand-built envelope would omit (`agent_type`, `name`). Meets ADR-019's dogfooding requirement
without a fixture zoo.

### Coverage-honesty line

Entry point `doc-gate`; candidate = one document in the doc set.

```
doc-gate: N scanned, M skipped (unreadable=<a>, not-a-document=<b>, no-channel-available=<c>), K checked, F findings
```

`N == M + K` asserted by the emitter. Closed skip reasons, each a genuine could-not-look:
`unreadable`; `not-a-document` (non-`.md`, or `manifest.md` per the hash rule — **counted, not
silently dropped**, per `RULES.md:531`); `no-channel-available` (neither sidecar nor
doc-reviewer covered it).

`K == 0` with `N > 0` → `doc-gate: NOTHING CHECKED — all <N> candidates skipped` on stderr,
`coverage_vacuous` on the bus, **and the pre-planning gate blocks (exit 2)**. Chosen for this
gate, not inherited: it matches `test-shellcheck` (blocking, `test-coverage-honesty.sh:96`)
rather than `lean-comments` (advisory, `:83`), for the same asymmetry that decides T4.
Enrollment is two edits in one change: `RULES.md` §15's registry (making eight entry points)
and `ENTRY_POINTS` at `test-coverage-honesty.sh:19`.

### What cannot be mechanically tested — advisory tier

Stated in the register of `RULES.md:230`, which names its own limit without softening it.

- **Whether the `doc-reviewer`'s judgment is any good.** `[advisory]` The gate pins the
  channel, grammar, routing, and persistence. Nothing stops a reviewer returning `APPROVE`
  over a document riddled with contradictions. A human reading the review must catch it.
- **Whether the generator's self-findings are complete.** `[advisory]` A generator noticing
  four of six emits a well-formed artifact reporting four. The schema is enforced; **recall is
  not.** This is the structural reason decision 2 keeps both channels — and two incomplete
  channels are not one complete channel.
- **Whether a classification was applied honestly.** Split. `[enforced]`: `invariant_ref`
  resolves to a real §21 id; a `mechanical` finding carries `expected`/`observed`/≥1 evidence
  path; every evidence path exists. `[advisory]`: that the cited invariant is the *right* one
  and that T2/T3 were reasoned rather than guessed.
- **The second half of (e).** `[advisory]` A script can assert the annotation exists and names
  affected task ids. It cannot assert that "replan / annotate / nothing" is the *correct*
  disposition.
- **Coverage of the generator's own emit call.** `[hook-driven only]` Nothing forces the
  doc-generator to call `scripts/doc-gate.sh emit` — the limit `RULES.md:378-380` states for
  `raise_finding`. What the gate enforces is that a missing call is *visible*:
  `no-channel-available` is a counted skip and, alone, produces NOTHING CHECKED rather than a
  clean board. The omission cannot hide; it cannot be prevented.

## Verification performed for this design

| Claim | Method | Result |
|---|---|---|
| `nazgul-root.sh` resolves to worktree root | Direct probe, `CLAUDE_PROJECT_DIR` empty, worktree cwd | Confirmed |
| Stop-hook inert pre-planning | Read `stop-hook.sh:957-954` | Confirmed |
| Bounded-counter hazard at line 952 | Read `stop-hook.sh:967-980` | Confirmed — documented in-file at `:973-974` |
| Reviewer name-keyed unit resolution | Read `subagent-stop.sh:197-217`, `:264-282` | Confirmed |
| Baseline green at `c44add2` | `tests/run-tests.sh` | 99 scanned, 0 skipped, 99 checked, 0 findings |
