# Re-founding the Nazgul mechanism layer in Rust

**Status:** design, approved for spec review
**Date:** 2026-08-27
**Supersedes nothing.** Extends ADR-008, ADR-009, ADR-013, ADR-019, ADR-020, ADR-021, ADR-022/023, ADR-027.

---

## 1. Why — the measured case

The claim under test was *"every new feature creates about 4-5 bugs."* Measured across all 36
features in git history, by counting commits whose subject matches `fix|repair|correct|address`:

| Cohort | Features | Commits | Corrective | Ratio | Corrective per feature |
|---|---:|---:|---:|---:|---:|
| `FEAT-013` … `FEAT-033` | 21 | 54 | 9 | 0.17 | 0.43 |
| `FEAT-034` … `FEAT-036` | 3 | 103 | 43 | 0.42 | **14.3** |

**The last three features consumed twice the commits of the previous twenty-one and produced 4.8×
as many corrective commits.** The ratio climbs monotonically across them: `FEAT-034` 0.27 →
`FEAT-035` 0.48 → `FEAT-036` 0.51. On the most recent objective, more than half of all commits
mentioning it are corrective.

*Method limit, stated:* this counts commit subjects, so it includes in-objective review-round fixes,
not only post-merge defects. That inflates the absolute figure. The same measure is applied to every
feature in history, so the **trend** comparison is sound — and the trend is the argument. The cost
per unit of change is accelerating. That is the signature of a substrate out of headroom, not of a
merely buggy system.

### Where the defects actually are

Of 46 open inbox items at the time of writing: ~14 are shell-language defects (BSD-awk comparing
`gsub()` output lexicographically; a lost `|| echo "0"` aborting the stop hook; `git cat-file -e`
false-positive under zsh 5.9; `nz_manifest_with_lock` running in a subshell so per-process state
vanishes; four-format markdown status parsing), ~9 are semantic contradictions between features,
~13 are docs/board bookkeeping drift, ~10 mixed.

The largest single family is self-inflicted: **§15 "bound entry points" are hand-rolled static
analysis that greps shell source for string literals to prove coverage.** Four inbox items are bugs
*in the scanners themselves*. That family exists only because rules are text conventions rather
than code with types.

### The honest boundary

This rewrite does not fix everything. It deletes the ~14 shell defects and two whole scanner
families outright. It does **not** touch the ~13 bookkeeping items, and the ~9 semantic
contradictions mostly survive — `review_gate.adversarial_crosscheck` writing files that fail-close
the DONE gate is a *design* conflict that would compile fine. The prompt layer (52 agent and skill
markdown files) is unaffected: a reviewer stalling at `maxTurns` before composing a verdict is
exactly as possible afterwards.

**The machinery becomes sound. The judgment does not.** An adversarial architect review put the
share of defect classes that types actually fix at **about one third**.

---

## 2. Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Rust, single static binary | locked |
| 2 | Event-sourced store; append-only ledger; status is a fold | locked |
| 3 | Agents lose raw **write** access to state | locked |
| 4 | MCP for agents, CLI for hooks | locked, **empirically verified** |
| 5 | Strangler migration, **to full parity** | locked |
| 6 | Core reusable by other coding agents | locked |
| 7 | Mutable files stop being the tracked artifact; one immutable log replaces them | locked |

---

## 3. Architecture

### Crate layout — the harness lives at the edge

```
nazgul-core            state machine · store · evidence types · render · git · host provider
                       ZERO knowledge of any harness. This is the reusable asset.
nazgul-mcp             MCP server over core          ← portable agent seam
nazgul-cli             operator commands over core   ← portable
nazgul-adapter-claude  Stop/PreToolUse envelopes, decision:block   ← ONLY Claude-specific crate
```

### One binary, three front-ends

```
nazgul hook <event>   hooks.json invokes this; JSON envelope on stdin, response on stdout
nazgul mcp            plugin .mcp.json; typed tools for agents
nazgul task|status|…  operators and skills
```

`nazgul hook` stays **synchronous and off the tokio runtime** — it runs at every turn boundary and
async startup on that path is measurable. Only `nazgul mcp` touches tokio.

### Distribution

Commit `bin/nazgul-{darwin,linux}-{arm64,x64}` plus a small `scripts/nazgul` dispatcher selecting by
`uname`. `hooks.json` points at a stable path, `git clone` still works with no build step, and
runtime dependencies drop from `jq + git` to **`git` alone** (`rusqlite` with `bundled` static-links
SQLite).

---

## 4. State model

### Three layers, one job each

```
nazgul/state.db        runtime truth · never tracked · fully rebuildable
nazgul/ledger.jsonl    append-only · GIT-TRACKED · the shareable, durable artifact
nazgul/tasks/*.md      rendered view — plus agent-authored artifacts it does NOT own
```

**Mutable files stop being the tracked thing.** What git tracks is one immutable log. An
append-only log that is never parsed for state, only replayed, is a different object from 40 mutable
manifests in four status formats.

### The event

```rust
struct Event {
    id:       Ulid,           // sortable, globally unique, needs NO coordination
    task:     TaskId,
    from:     Status,         // what this transition claims to start from
    to:       Status,
    parent:   Option<Ulid>,   // the event this one believed was latest for this task
    actor:    ActorId,        // session + machine
    at:       Timestamp,
    evidence: Evidence,
}
```

`parent` makes the log a per-task chain, which makes **compare-and-swap an append**. Two events
claiming the same `parent` is exactly a CAS violation — a *detected fork*, not silent corruption.
This is ADR-020's existing guarantee, now working across machines, with no locks and no vector
clocks. ULIDs let two machines generate correctly-sorting IDs with zero coordination.

**There is no `status` column.** Status is a fold over the chain. You cannot change a task's state
without appending, because state *is* the log.

### Consequences that were got wrong first, and corrected

These four came from adversarial review and each reverses an earlier draft decision.

1. **Rendering is synchronous, inside the write transaction.** `scripts/post-compact.sh:106-109`
   `sed`s the Recovery Pointer out of `plan.md`, and `:57` counts statuses off `tasks/*.md` to
   compute the next DELEGATE. The projection is the only memory the system has at the one moment it
   has no other. Today the atomic rename of a manifest *is* the commit, so a reader sees old-or-new,
   never "committed but invisible." Async render would manufacture an inconsistency window that does
   not exist today, landing on the agent's reasoning rather than on a gate.

   Synchronous rendering alone is not sufficient, because a forged manifest persists until
   *something* renders. So the projection is also **re-rendered at every read boundary** —
   `SessionStart` and `PostCompact` render before any consumer reads. A forged view is therefore
   corrected before the one consumer that matters ever sees it, which is a stronger guarantee than
   blocking the write and a cheaper one than detecting it afterwards.

2. **`nazgul/tasks/` is not a projection space.** It holds artifacts no ledger regenerates:
   `[TASK-ID]-delegation.md` (`agents/implementer.md:191`), `[TASK-ID]-diagnosis.md`
   (`agents/debugger.md:93`), `TASK-NNN/verification.md` (`skills/verify/SKILL.md:110`, where
   *absence* is the unverified signal), the Implementation Log and Review Results
   (`templates/task-manifest.md:234-274`). The renderer owns **the status block and nothing else**.

3. **`plan.md` keeps an independently-authored component.** `RULES.md:82` forbids the tautology by
   name: *"an unconditional copy of `config.feat_id` into whatever plan.md is on disk would make
   this corroboration tautological."* The merge-evidence roster check
   (`scripts/lib/task-transition-guard.sh:1515-1598`) exists **to be a second, independently-authored
   record**. `## Wave Groups`, read as batching authority by `scripts/lib/parallel-batch.sh:228,267-281`
   and authored by the planner, stays authored.

4. **A stray agent write is NOT harmless.** The earlier rationale — "it gets clobbered on the next
   render" — is withdrawn. The guards stay; only the *reason* for them changes, and the synchronous
   renderer plus the CAS chain is what makes an unsanctioned write ineffective.

### Scale path

```
now    SqliteStore  → state.db + git-tracked ledger.jsonl     handoff scale
later  RemoteStore  → same events, libSQL/Turso or a server   concurrent scale
```

Both behind one `Store` trait. **With an event log, "offline" is not a special mode** — you always
append locally; there is no unreachable database, no fallback path, no dual write. Sync is
replication of an immutable log, the one distributed problem that is genuinely easy.
`.gitattributes: *.jsonl merge=union` makes concatenation the merge.

An explicit rejection: **"write to files when the DB is unreachable, then sync"** was considered and
refused. It is a second write path, and eliminating the second write path is the thesis of this
work. It would delete the quarantine subsystem in step 4 and rebuild it in step 5 under a new name.

---

## 5. Type-level design

Evidence is a **type with a private constructor**, so the gate cannot be forgotten:

```rust
pub struct CommitEvidence(String);            // field private to this module

impl CommitEvidence {
    /// The ONLY way to obtain one. ADR-013's gate, relocated into the constructor.
    pub fn prove(sha: &str, base: &BaseSha, repo: &Repo) -> Result<Self, EvidenceError> {
        repo.cat_file_exists(sha)?;           // resolves and is reachable
        repo.is_strict_descendant(sha, base)?; // forward progress; equality rejected
        Ok(CommitEvidence(sha.into()))
    }
}

pub enum Transition {
    InProgressToImplemented { commit: CommitEvidence, red_run: RedRunEvidence },
    InReviewToDone(DoneEvidence),
    AnyToCancelled { declared_by: Operator },   // the one edge with no evidence gate
}

pub enum DoneEvidence {
    ReviewBoard(ReviewProof),
    Merge(VerifiedMerge),        // ADR-023: an ALTERNATIVE, never a bypass
}
```

`VerifiedMerge` is constructible only from a host API response carrying `merged: true`, so ADR-023's
*"a shape check on operator-writable text certifies whoever typed it"* becomes unrepresentable.
**`IMPLEMENTED` cannot be spelled without the gate having already run.**

Two doctrines stop being conventions:

```rust
/// RULES §15 / ADR-009 — "looked and found none" ≠ "never looked", enforced by the type.
pub enum Scan<T> { Looked { found: Vec<T>, scanned: usize }, CouldNotLook(BlindReason) }

/// stop_gate reasons. The docs tables are GENERATED from this enum,
/// which is why they can no longer disagree by one.
#[derive(strum::EnumIter)]
pub enum StopGate { AfkTimeout, MaxIterations, InFlightHold, StackCapReached, /* … */ }
```

**Rule: a gate lives in an evidence type's constructor; a tool handler may only pass evidence it was
given.** Named risk from review: *"once ~15 typed tools exist, the path of least resistance is to
move checks into tools — converting gates that cannot lie into gates that lie by omission."*

### The classifier that becomes a column

`review_gate.adversarial_crosscheck` (default ON) writes files that fail-close the DONE gate it
exists to inform — a `p1` defect caused by review-unit membership being encoded in **filenames**, so
one classifier (`scripts/lib/review-file-class.sh`, a §15 entry point with two callers) must
disambiguate them. In a store, `kind` is a column; the DONE gate queries `kind = 'seat'`; a
crosscheck row cannot match. **The classifier and both callers evaporate and the bug becomes
unrepresentable.**

This is the pattern the whole port is held to: not *"port this script correctly"* but *"which text
convention is this script disambiguating, and can it be a column instead?"*

---

## 6. Seams

### `TurnSource` — the least portable thing in the system

The loop exists only because something grants the model another turn. **MCP sampling is formally
deprecated** (spec `2026-07-28`, SEP-2577, `SHOULD NOT` adopt) and fires mid-tool-call, never after
a turn ends — it could not have served even if implemented.

```rust
pub trait TurnSource {
    fn request_next_turn(&self, reason: &Continuation) -> Result<Granted>;
    fn strength(&self) -> Guarantee;   // Enforced | PromptCompliance
}
```

- **`ClaudeCodeStopHook` → `Enforced`.** `{"decision":"block","reason":…}`. Verified: no documented
  cap, identical in `claude -p` headless.
- **`AgentPolledDriver` → `PromptCompliance`.** The loop inverts: the agent calls
  `nazgul_next_action` at the end of each turn. Works on any MCP client; weaker, and honest about it.

`{"decision":"block"}` has convergently standardized — Codex CLI and Continue CLI copied it
field-for-field, with variants in Cursor (`followup_message`, `loop_limit` default 5), Amp
(`{action:'continue'}`) and Gemini (`AfterAgent` + `decision:"deny"`, reject-and-redo). Windsurf,
Cline, Zed and Aider have no mechanism at all.

**Ship one implementation plus the polled fallback; emit a named `turn_source_unavailable`
degradation everywhere else.** Every non-Claude implementation carries a named defect — Codex has
two open bugs on the continuation path itself (openai/codex #20783, #17532). Building five untested
adapters is insurance against a shrinking risk.

*Prior art, both cautionary:* `jpicklyk/task-orchestrator` (MCP + SQLite + phase state machine, near-identical
target) concedes enforcement is **rejection, not compulsion**. `fusengine/harness` extracted a Claude
Code plugin across 13 harnesses and **grants additional turns on none of them** — it kept the gates
and left the driver behind. That is the shape of failure to avoid.

---

## 7. Migration plan

Cut order was **reversed** on review. The defect this codebase actually suffers is **duplicated
predicates** — `RULES.md:77` records three consumers drifting from one readiness predicate *while
`CANCELLED` was being added*. A shared validator fixes that on day one; a database does not. Worse,
store-first maximises split-brain: `stop-hook.sh`'s six sanctioned raw `set_task_status` arms,
`red-run.sh`'s evidence append and `close-objective.sh`'s merge-evidence write all still write
markdown, and every such write would be silently discarded by the next render — losing auto-blocks,
quarantines and merge closures with no error anywhere.

| Step | Content | Store |
|---|---|---|
| **0** | Toolchain, crate skeleton, CI, spikes | — |
| **1** | Status vocabulary + transition validator as CLI | markdown |
| **2** | Evidence gates as types | markdown |
| **3** | Read-only hook entry points | markdown |
| **4** | **The store** — every writer cut in one atomic change, synchronous renderer | ledger + db |
| **5** | Prompt layer (`agents/**`, `skills/**`) | ledger + db |
| **6** | Periphery, shell deleted | ledger + db |

**Precondition for step 1:** extend `tests/test-manifest-write-integrity.sh`'s two scans
(`manifest-writers`, `status-readers`) to `agents/**` and `skills/**`. Today it walks `scripts/**`
only — it would report a clean tree while 20 skills (64 `jq`-on-`config.json` occurrences) and ~25
agents still speak the old format.

**Split before delete:** `scripts/pre-tool-guard.sh:96-102` (`dp_scan_command`) is `RULES.md` §5's
destructive-command screen — `rm -rf /`, `DROP TABLE`. The status funnel is a separable eight lines
at `:104-112`. `:94-95` records that the screen is a shared authority *because `red-run.sh` executes
an operator-supplied command outside the Bash tool, where no hook can see it*. Extract the screen as
a library both the binary and any future non-Claude host call; only then remove the funnel. The same
trap exists in `task-state-guard.sh:354-382` and `:297-331`.

### Parity inventory

**Must port:** loop engine (`stop-hook.sh`, ~22 phases — AFK timeout, in-flight hold and budget
valve, reconciliation, review-gate enforcement, granularity reconciliation, context-rot,
checkpointing, Recovery Pointer rewrite, board sync, connector push, auto-promote, git-conflict,
exit conditions, HITL gate); transition guard and evidence gates; review evidence/provenance/
receipts/file-class; reviewer selection; parallel batch; heartbeat and inbox seam; GitHub connector;
stack-utils; merge-provider; git-hooks lifecycle; worktree-utils; session-tracker; telemetry bus;
`close-objective.sh`; `red-run.sh`; `stamp-plan-objective.sh`; doctor; config migration;
bootstrap-project; **22** hook command entries across 12 events (not 18 — and merging Stop's three
collapses three independent timeouts of 30/60/10 and three exit codes).

**Genuinely hard in Rust, flagged rather than discovered later:**
- **Config migration v1→v37** — 36 chained `jq` expressions over an untyped document
  (`scripts/migrate-config.sh:61-747`). Keep them data-driven; do **not** type 37 historical shapes.
- **`bootstrap-project`** scrub/relocate — four libs of whole-tree text rewriting. Candidate to
  leave in shell.
- **`gh stack` shelling** — `RULES.md` §20 records the tool aborts a real divergence with exit **0**,
  so the wrapper classifies stderr. Prose-matching a third-party CLI gains nothing from Rust.
- **Git-hooks lifecycle** — the chain-dispatcher and shims must stay shell scripts git can exec.
  This subsystem is partly shell forever.
- **`red-run.sh`** — executes an operator-supplied command, so it must carry the destructive screen.
- **Doctor's 17 checks** — several are host probes and inherently shell-shaped.

---

## 8. What dies, what survives

| Subsystem | Why it exists today | Fate |
|---|---|---|
| Reconciliation / quarantine / `repair` | state files are agent-writable | **gone** — CAS chain replaces detection |
| `task-state-guard.sh` status funnel | ditto | **gone** after the screen is extracted — replaced by render-at-read-boundary, not by a guard |
| §15 write-site scanners (P7, Scan A/B) | prove no script writes raw | **gone** — `pub(crate)` proves it |
| FEAT-030 *state-path* discipline + 4 scanners | agents shell in an unknown cwd | **gone** |
| `review-file-class.sh` + 2 callers | filename convention needs disambiguating | **gone** — `kind` column |
| Four-format markdown status parsing | organic growth | **gone** — one renderer, one schema |
| FEAT-030 *worktree* discipline | the agent's **code** tree, not state | **survives** — `implementer.md:153-165` |
| `pre-tool-guard.sh` destructive screen | `RULES.md` §5 hard blocks | **survives** as a library |
| `nazgul-root.sh` resolution | two roots, mode-dependent | **survives**, gains a mode-aware answer |
| Prompt layer | irreducibly prompts | **unaffected** |

**The MCP server must take an explicit root and refuse, never infer.** `RULES.md:1132-1134`:
*"An agent that sources the resolver converts a visible relative path into an invisible
confidently-wrong one, which is strictly worse."* A server that opened the wrong `state.db` would
reproduce that failure once per lifetime, where it is least visible. `.mcp.json` is itself gitignored
in local mode and the server starts before `/nazgul:init` creates any marker.

The CLI carries the same rule: **if neither `--project-root` nor `NAZGUL_PROJECT_ROOT` is set, refuse
loudly.** FEAT-030's failure mode becomes a `Result::Err` instead of four scanners.

---

## 9. Testing strategy

1. **Rust unit tests over `nazgul-core`** replace the bulk of 61,326 lines of shell tests. Evidence
   constructors, the transition validator, the fold, and the renderer are pure functions over typed
   inputs.
2. **Differential testing during the strangler** is the highest-value safety net: run the shell
   implementation and the Rust implementation on the same input and assert identical output. This is
   what makes steps 1-3 safe, since markdown remains the store throughout.
3. **A thin shell integration layer survives**: real hook envelopes piped into the binary, asserting
   stdout JSON. Existing captured-real fixtures (`tests/fixtures/*/PROVENANCE.md`) stay as golden
   inputs — they are provenance-declared and must not be regenerated by the thing under test.
4. **Ledger round-trip is the store cutover's acceptance gate**: import every existing manifest →
   ledger → db → render → diff against the originals. The cut does not land until the diff is empty.
5. **`nazgul rebuild` is a first-class tested path**, not a recovery afterthought — it is what keeps
   *files are memory* a guarantee rather than a slogan. `doctor` verifies the round trip.
6. **The prompt layer gets its own coverage line.** It is what actually drives the loop and the
   compiler never sees it. Both write-site scans extend to `agents/**` and `skills/**` on day one.
7. **CI must prove an artifact exists, not that a command returned zero.** Observed during this
   design: `cargo build` failed its MSRV check and the wrapper still reported exit 0; the failure was
   caught only because the binary was absent from disk. This is `RULES.md` §15's own doctrine —
   "looked and found none" versus "never looked" — applied to the build step.

Every checking entry point keeps the fixed-grammar coverage line: `N scanned, M skipped, K checked,
F findings`, with `N == M + K` asserted by the emitter.

---

## 10. Error handling

- **`thiserror` for domain and evidence errors; `anyhow` only at the `main` boundary.** Every named
  refusal reason is an enum variant, and the documentation tables are generated from the enum.
- **Hooks must never panic.** A panicking hook can wedge the harness. `catch_unwind` at the hook
  boundary, with the fail direction matching today's documented split: **guards fail closed,
  observers fail open.**
- **Hook exit-code and timeout independence is preserved.** Stop's three commands keep three
  timeouts and three exit codes; they are not merged into one invocation.
- **Every degradation is named and emitted**, never silent — `turn_source_unavailable`,
  `store_unavailable`, `ledger_fork_detected`, plus the existing `stop_gate` family.
- **A detected CAS fork is a first-class state**, not corruption: both events are retained, the fork
  is reported, and resolution is explicit. Recording both endpoints is what makes recovery possible.

---

## 11. Verified facts and measurements

Measured on this machine unless marked otherwise.

| Fact | Value |
|---|---|
| Rust binary, full stack (`rmcp` 0.9.1 + `tokio` + `clap` + `rusqlite` + `serde`) | **1.4 MB** |
| Store layer only (`serde` + `rusqlite` bundled) | 1.2 MB |
| Dynamic dependencies | 3 system libs; **SQLite statically linked** |
| Binary startup (JSON parse + open store + derive status) | **~12-18 ms** (±5 ms load variance) |
| `/bin/echo` exec floor | ~3 ms |
| SQLite's contribution to startup | **~0 ms** (11.50 bare vs 11.46 with store) |
| `task-state-guard.sh` modelled (bash + 11× `jq`) | 42.8 ms |
| `stop-hook.sh` (bash + 95× `jq`) | ~465 ms |
| Node equivalent | 65 ms × 3 hooks per edit — **disqualifying** |
| macOS ad-hoc signing | recovers ~2.7 ms |

**Platform, verified against docs:** hooks can invoke a committed native binary; `${CLAUDE_PLUGIN_ROOT}`
is set on every hook event; plugins register MCP servers via `.mcp.json` at plugin root or inline in
`plugin.json`, started **once per session**; `{"decision":"block"}` on Stop grants a turn with no
documented cap, identical headless; no deprecation on hooks, plugin MCP servers, or Agent-Teams.

**MCP tool propagation, verified empirically** (zero-dependency stdio MCP server, `--strict-mcp-config`,
so no user configuration was modified):

```json
{"main_session":        ["mcp__nazgulprobe__nazgul_probe_ping"],
 "foreground_subagent": "call SUCCEEDED — PROBE_OK echo=FG",
 "background_subagent": "call SUCCEEDED — PROBE_OK echo=BG"}
```

**Background subagents do receive MCP tools and can call them.** MCP tools arrive as **deferred**
tools — present in a system-reminder, schemas fetched on demand via `ToolSearch`. They therefore
**cost no context until used**, which withdraws an objection raised in earlier drafts; the trade is
a one-line prompt contract telling agents to search for them.

**Stack:** `rmcp` 3.1.4 (official SDK, MSRV **1.88**; use the macros and 3.x migration is
source-compatible), `clap` 4.6, `thiserror`, `rusqlite` with `bundled`, `tokio`. CI is a plain native
GitHub matrix — `bundled` needs a C toolchain and `ubuntu-24.04-arm` runners are free.

**Toolchain gap:** this machine has `rustc 1.86.0` from Homebrew with **no `rustup`**. Step 0 must
resolve this and pin `rust-toolchain.toml` so CI and development agree.

---

## 12. Open spikes

| # | Question | Why it blocks |
|---|---|---|
| 1 | Do **tool-restricted** agent specs (`reviewer-base.md`: `tools: Read, Glob, Grep`) still receive `mcp__*`? | `RULES.md:102` — reviewers being read-only is tool-enforced. Verified only for `general-purpose` so far |
| 2 | Does **plugin-provided** `.mcp.json` propagate identically to `--mcp-config`? | Same path presumed, unproven |
| 3 | Is the working tree on a synced filesystem? | Repo lives under `~/Documents/…`, commonly iCloud-synced, where **WAL is documented-unsafe**. Needs WAL + `busy_timeout` + single-writer, plus network-FS refusal. `state.db-wal`/`-shm` must join the ignore block |
| 4 | Shared-mode store scope | Shared mode tracks `nazgul/` in git (`skills/init/SKILL.md:131-132`); the ledger is tracked, `state.db` must not be |
| 5 | Real binary size with a **fully wired** MCP server | 1.4 MB is a lower bound; the probe touches a small `rmcp` surface, so LTO may strip much of the SDK |

---

## 13. Risks and the predicted failure mode

**The predicted failure is not a Rust bug — it is a stall at 80%.** The store moves, hooks and
transitions become Rust, and the long tail remains: 36 config migrations, `bootstrap-project`,
doctor's host probes, the `gh stack` stderr classifier, and above all ~60 uncompiled prompt files.
Shell cannot be deleted, both stores are live, every feature is written twice — the 4-5-bugs dynamic
**plus** a language boundary.

The cycle's cause is visible in the repo's own record, and types address perhaps a third of it:
`RULES.md:77` (three stale copies of one predicate — **fixed** by one `Status` enum),
`RULES.md:82` (a template placeholder no producer substituted, leaving a gate unreachable for 31
objectives — **not fixed**), `RULES.md:18` (a gate satisfiable by the wrong section of the right
file — **fixed** by evidence types). What survives untouched is everything at the
**prompt/mechanism boundary**: a spec saying X while the gate checks Y, a producer nobody invokes,
operator-writable identity anchors, and every `[advisory]` tier in `RULES.md`.

**The rewrite also adds a drift surface** — MCP tool schema versus prompt text — with no scanner for
it. That scanner is in scope, not optional.

### Preconditions before step 1

1. **A hard deletion date for the shell**, agreed in advance. Without it, step 6 never arrives and
   the stall at 80% is the outcome.
2. **Both write-site scans extended to `agents/**` and `skills/**`** on day one.
3. **The prompt layer treated as a first-class port target** with its own coverage line, because it
   is what actually drives the loop and the compiler will never see it.

---

## 14. What this does not change

The task state machine's semantics; the review board's authority; `CANCELLED` and `## Merge Evidence`
as ADR-022/023 defined them; the two-root split between the main worktree and a task worktree; the
one-shot dispatch doctrine; and the requirement that every degradation be named and loud rather than
silent. This is a change of substrate, not of policy.
