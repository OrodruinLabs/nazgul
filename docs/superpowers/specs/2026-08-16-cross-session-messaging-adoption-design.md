# Cross-Session Messaging Adoption — Design

**Date:** 2026-08-16 · **Status:** approved design, pre-plan · **Target version:** 2.33.0 (MINOR, **no schema step** — this cycle adds no config keys)

**Evidence base:** `2026-08-16-cross-session-messaging-platform-facts.md` (same directory) — the
platform doc distilled, plus six live probes (P1–P6) and on-host measurements. Facts cited as
V1–V10/P1–P6 below live there. Validation trail: two independent platform/architecture reviews, one
architect validation of the first draft, a seven-agent adversarial workflow (binding-docs grounding,
full 114-issue board sweep, mechanical change inventory, four skeptics), and a completeness critic.
The first draft's three central mechanisms were **refuted with evidence and are reversed here**;
the refutations are summarized inline so the record shows why, not just what.

---

## 1. Doctrine

Claude Code cross-session messaging (v2.1.224+) lets independent top-level sessions exchange plain
text, exposes a per-session inbox socket (`CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN`) to hooks and Bash,
and starts a new turn in an idle session on delivery. After adversarial review, Nazgul adopts it as:

> **An operator surface and an attack surface — never a loop mechanism.** The loop's liveness stays
> where D-002 put it: each session's own Stop hook, plus the platform's documented harness resume
> for background dispatches. Adopted rule (new RULES §22): **an unguaranteed channel may shorten a
> wait, but may never authorize one.** Delivery has three outcomes (delivered / held / refused), a
> refusal produces no sender notice, throttling is opaque, and four unrelated settings changes can
> silently reconfigure the transport — nothing with those properties may be the thing a hold's
> legality rests on.

What messaging IS used for: operator HITL steering (native, documented — no Nazgul code);
peer-courtesy FYI in multi-worktree setups (already permitted by RULES §17: "coordination-only
courtesy, never the report channel" — note that rule *permits* courtesy messaging; earlier drafts
mis-paraphrased it as a ban); a hardened inbound trust boundary; and observability corroboration.

What it is NOT used for: waking the loop, carrying state, evidence, verdicts, or reports, or any
gate input.

**Why the "doorbell" (socket-post wake for the in-flight hold) was cut.** P2/P5 proved the mechanism
*works* (a message-woken turn's Stop hook blocks and drives — the engine genuinely re-enters). It was
cut anyway, on four independently sufficient grounds established by the skeptic panel:

1. **Shape mismatch.** The canonical unattended shape is heartbeat's `claude -p` run
   (`scripts/heartbeat.sh:169,180`), which has **no idle state** — the hold's `exit 0` is process
   exit; there is nothing to wake, ever, while every readiness precondition reads true.
2. **Redundant where it works, impossible where it is needed.** A genuine background dispatch
   already has the documented harness resume (`docs/CONFIGURATION.md:293-295`, D-002). The
   foreground-leak case (#104 Gap 3) has its trigger event (SubagentStop) *in the past* at hold
   time — no future post exists.
3. **Unbounded silent failure.** A checked-in project `crossSessionInbound: refuse` outranks every
   other source and drops delivery with no sender notice; managed settings do the same invisibly;
   `nc` hangs indefinitely against a wedged socket inside a 10-second hook budget (measured), and a
   `nc -w 1` false-succeeds (measured). Every backstop that could notice runs only inside a
   stop-hook turn — the very thing that failed to arrive.
4. **The record already ruled.** D-002 item 3 rejected SendMessage-wake; D-002 item 4 rejected the
   watchdog re-poke ("treats the symptom, not the cause"). The doorbell is that shape.

The residual case a doorbell could someday serve — a background dispatch whose harness resume never
arrives — is named in §6 as a platform-bug class with a future opt-in option behind its own spec
cycle, not built now.

---

## 2. Phase 0 — Fix-now (live defects; zero messaging dependency)

Ordered. A ships first because everything after it needs review, and A is what makes reviewer
dispatch possible on affected hosts.

### 0-A · #205: dispatch guard blocks all main-session reviewer dispatch (also moots #94)

`scripts/parallel-dispatch-guard.sh:86-88` exits 2 whenever `run_in_background` is absent from a
configured reviewer's `Agent` payload and the caller is not nested. On a host whose `Agent` tool
schema has no `run_in_background` field (this host, reproduced live), the model *cannot* supply it —
every main-session reviewer dispatch is blocked; the review board is unusable.

**Decision (ADR-009 cost-weighing, stated per guard):** the hook payload cannot distinguish
"schema lacks the field" from "caller omitted it". A false BLOCK costs the entire review discipline
(live, severe). A false ALLOW costs a possibly-background reviewer dispatch — bounded by FEAT-024's
empty-return detection and the guard's other protections (roster naming, completed-unit re-dispatch
block), which are untouched. Therefore: **`missing` → ALLOW + emit a named event**
(`dispatch_guard_background_unverifiable`, carrying agent + caller type), keep blocking explicit
`run_in_background: true` for reviewers. "Looked and could not verify" gets its own name — never
collapsed into "verified false".

Bookkeeping: `docs/guard-fail-open-inventory.md` rows for this guard; `tests/test-parallel-dispatch-guard.sh`
(the only test referencing the field); CLAUDE.md Key Concepts sentence ("both fields enforced…")
amended; the reproduction recorded in the fix PR (issue #205's body is empty — nothing durable
records it today). Scope wording everywhere: it blocked **main-session** reviewer dispatches
(nested callers pass at `:74-75`).

### 0-B · #104: `_clear_in_flight_marker` three-way fix

`scripts/subagent-stop.sh:62-97`. The fallback (`:88-93`) accumulates over every agent-matching
marker *unconditionally* and engages whenever the unit-matched pick is empty — including when the
unit **was** derived but no marker matched it. That is cross-unit marker theft: a fresh completion
against an orphan backlog deletes a *different unit's live marker* (the #104 Gap 3 incident's own
mechanism — TASK-001's completion cleared a FEAT-027 orphan and left its own marker to poison the
hold).

**Fix — three explicit cases, each named and counted:**

| Case | Action |
|---|---|
| unit derived, marker matched | clear that marker (unchanged) |
| unit derived, **no marker matched** | clear **nothing**; named counted skip (`clear_skipped_no_match`) |
| unit underivable | **newest**-matching agent fallback; named counted skip (`clear_fallback_underivable`) |

Also: fix the stale doc comment (`:58-61`), amend `docs/CONFIGURATION.md:289-291` ("clears the
oldest marker"). Note for the plan: skip events route through `emit_event` — already sourced in this
file — and inherit the ADR-021 `NAZGUL_DIR` contract (§5, event bookkeeping).

### 0-C · #104 Gap 3: hold classification (REPLACES the first draft's "inversion")

**Refutation that forced this.** The draft's "block and burn unless a wake path is confirmed" was
proven strictly worse than the bug: burned wait-iterations increment `CONSEC_FAILURES`
(`scripts/stop-hook.sh:417-432` — progress is DONE-count growth only, no reason field), so an
hour-long *legitimate* background dispatch force-stops the run in ≤5 burns (`:1306-1309`,
default `max_consecutive_failures: 5`) after ~1–5 minutes, **unrecoverably** (the eventual resume
yields IMPLEMENTED, not DONE — counters stay pegged; next tick exits instantly). It also silently
repealed the documented invariant that the hold never increments counters (`:126-129`), and it did
not fix its own incident: nothing clears a leaked marker, so the same sleep arrives ~4 minutes
later. The correct observation: **"confirmed wake path" is a per-dispatch property, decidable at
marker-write time** — not a session-global flag.

**The classification:**

1. **Marker records the dispatch class.** `scripts/in-flight-marker.sh` (fields today:
   `agent, unit, dispatched_at, dispatched_at_epoch, prompt_head` — `:63-66`) additionally records
   `background` (tri-state `"true"|"false"|"missing"` from `tool_input.run_in_background`; the
   exact extraction pattern already ships at `scripts/parallel-dispatch-guard.sh:58-70`) and
   `named` (whether `tool_input.name` is present — teammate-shaped dispatches never participate in
   the hold; they have the §17 report contract).
2. **Hold predicate** (`scripts/stop-hook.sh:133-172`): hold ONLY a fresh marker with
   `background == "true"` and `named` absent. For that class the printed claim — "the harness
   resumes this loop when the background agent finishes" — is true by construction (D-002;
   `docs/CONFIGURATION.md:293-295`).
3. **A fresh non-background marker at Stop time is a proven leak** — a synchronous `Agent` call
   keeps the main turn alive, so it cannot span a Stop; reviewer dispatches are guard-forced
   foreground besides. Action: emit `stop_gate reason:in_flight_orphan` (unit, agent, background
   value), move the marker to `nazgul/in-flight/quarantine/` (evidence preserved per the existing
   stale-marker doctrine at `:159-166`, re-fire noise stopped), and **continue the normal loop** —
   a productive iteration, not a burn: no counter surgery, no new failure semantics.
4. **`"missing"` classifies as non-background**, by explicit cost-weighing: a false hold costs the
   whole run; a false continue costs at most bounded pre-ADR-015 churn — and on any host whose
   schema lacks the field (this one), dispatch is provably synchronous. Legacy field-less markers
   classify the same way.
5. **SessionStart sweep** (#104 fix direction c): markers older than the staleness bound are
   quarantined with an event at SessionStart (the `guards.team_sweep` precedent), so orphan
   backlogs cannot regrow across sessions.
6. **Kill switch unchanged:** `guards.in_flight_hold: false` still means "never hold" — its
   semantics do not collapse, because holding remains the default for the background class.
7. **Scope:** `in-flight-marker.sh` writes markers for every Agent dispatch in an initialized
   project (patch/review sessions included); classification is *safe* there — a foreground leak in
   an interactive session quarantines and continues, which is today's behavior minus the false
   hold.

**Probe owed (named, not blocking):** on a background-capable host, confirm SubagentStop fires and
the harness resumes the main session for a `run_in_background: true` dispatch — the single platform
fact the legitimate hold rests on (D-002, `docs/CONFIGURATION.md:293-295`). Unprobeable on this
host (schema lacks the field). C ships regardless: orphan handling is correct either way, and the
background-hold branch preserves today's documented behavior.

**Explicitly still open in #104:** Gap 1 (phantom marker on sibling-hook-blocked dispatch), Gap 2
(message-resumed agents get no marker), and #144's reaper residue beyond the SessionStart sweep.
The issue is *partially* addressed and stays open with a disposition comment.

### 0-D · #195 blind spot / #96: session-lock lifecycle (REPLACES the draft's "add fields")

**Refutation that forced this.** V7's original inference ("the tracker is not being fed") was
wrong. It is fed twice (`scripts/session-context.sh:54` at SessionStart; `scripts/stop-hook.sh:41`
per Stop) and **drained by design**: the EXIT trap at `stop-hook.sh:42` unregisters on every
exit-0 run — every allowed stop, including the hold path, AFK timeout, and the failure stops — and
`session-context.sh:55` sweeps locks older than 2h. Zero locks beside four live sessions is the
designed steady state. The recorded `pid` is the hook shell's own `$$`, dead moments later. Adding
fields to records that don't exist when the #195 incident shape occurs (housekeeping sessions
outside a loop) is decoration. **Corollary of fact:** RULES §13's `[enforced]` "never a second
loop" is false today even within one tree — a session parked on a hold is alive and uncounted
(§4, record corrections).

**The fix — lifetime first, fields second:**

1. Unregister at **SessionEnd**, not on stop-hook exit-0 (the SessionEnd hook entry exists —
   `session-staging.sh` runs there; the plan chooses whether to extend that script or add a
   sibling command, noting `tests/test-hooks-schema.sh` pins matcher sets).
2. Stop-time registration becomes **refresh-only** (mtime/content update; no removal trap).
3. Record a **liveness-checkable identity**: the session process pid (derivable from
   `CLAUDE_CODE_MESSAGING_SOCKET`'s `<pid>.sock` basename when exported, else the hook's parent
   chain), so `kill -0` means something. Never the hook's `$$`.
4. `cleanup_stale_sessions` retuned: liveness check before age-based removal, so long-idle-but-live
   sessions survive the sweep while crash leftovers still go.
5. New lock fields: `cwd`, `git rev-parse --show-toplevel`, current branch.
6. `is_concurrent_session_warning` (`scripts/lib/session-tracker.sh:69-78`, already called at
   `session-context.sh:57`) groups live locks by toplevel and warns loudly on ≥2 against one tree.
7. **#96 folded in:** `count_active_sessions` (or its heartbeat call site,
   `scripts/heartbeat.sh:275`) gains a current-session exclusion — a reliable tracker otherwise
   makes the heartbeat's own-lock self-block deterministic.

**Gate:** #201 (the SessionStart hang inside a `session-context.sh` command substitution with
sibling worktrees) is diagnosed first, or every new git invocation on that path is bounded
(timeout + fail-open) — this item must not grow the surface of an undiagnosed hang.

Consumers to re-verify: `heartbeat.sh:275`, `session-context.sh:56-59`, and the fixtures in
`tests/test-heartbeat-session-guard.sh` that fabricate lock files.

### 0-E · `/nazgul:clean` leaves `core.hooksPath` dangling (new defect, found this cycle)

`skills/clean/SKILL.md` contains no git-hooks step (verified: zero matches for
hooksPath/githooks). Today's only uninstall site is `cleanup_all_worktrees`
(`scripts/worktree-utils.sh:444-451`) — so a clean that runs after an aborted objective deletes
`nazgul/` *including `nazgul/.githooks/`* while `core.hooksPath` still points at it. Git then runs
**no hooks at all — including the operator's own pre-existing hooks — silently, indefinitely.**

Fix: clean gains an `uninstall_git_hooks` step (the function — `scripts/lib/git-hooks.sh:157-180` —
already no-ops safely when `prior_hooks_path` was never recorded), ordered before the `nazgul/`
deletion. Test: clean-after-abort with hooks installed restores the prior `core.hooksPath`.

**What happened to the draft's 0.4 (install at SessionStart, uninstall only at clean):** cut.
The SessionStart install already exists (`session-context.sh:173` → `self_heal_git_hooks`,
`scripts/lib/git-hooks.sh:201-230`), gated on `branch.feature`; and the pre-commit guard is itself
inert without `branch.feature` (`scripts/git-hooks/pre-commit:35-36`) — so installing earlier
closes nothing in the exact window it targeted, while opening real hazards (unlocked concurrent
`prior_hooks_path` writes; repointing the *shared* `core.hooksPath` from sibling worktrees at every
session start, aggravating the #182 Task-1 bug before its spatial fix lands; hooks imposed on
non-Nazgul sessions). The real question — *what protects the base branch between objectives?* — is
a guard-predicate doctrine decision, filed into #182's cycle together with PLAN-B Task 1
(`extensions.worktreeConfig` + per-worktree `core.hooksPath`), with an explicit sequencing note
that the temporal and spatial changes land together or spatial-first. The first draft's claim
"0.4 is #182 Task 1" was false — they are different defects (WHEN vs WHERE).

### 0-F · Doctor: `messaging`, `remote-control`, and `sessions` checks (#184's check half; #195 fix direction 4)

Three new check ids beside the existing ten (enrollment: `_DOC_CHECK_IDS` at `scripts/doctor.sh:522`,
`_doc_run` in `main()` at `:594-604`, header comment). Doctor is already a §15-enrolled entry point;
adding checks adds **no** new registry entry. The three-state outputs are **verdict messages**
(pass/warn/note), not new skip reasons — the four-reason skip vocabulary is closed and pinned
(`tests/test-doctor.sh:759`), and this design does not amend it.

- **`messaging`:** three states, never two — `available` / `disabled-because-<named var>` **naming
  which source** (shell env vs a settings `env` map vs managed settings) / `undetermined`
  (`CLAUDE_CODE_MESSAGING_SOCKET` not exported into this context — legitimate in the pre-flag-fetch
  window; explicitly NOT a "messaging unavailable" claim). Also reports the effective
  `crossSessionInbound` when a readable settings file sets one, plus the precedence note
  (project/local `refuse` outranks every source). Read-only: env + settings files; **no socket
  connect, ever** (doctor's zero-write charter, and the scan in §3 forbids posts globally).
- **`remote-control`:** same helper, second id (`--only` must isolate each): the shared
  four flag-killers plus #184's named causes — `disableRemoteControl` (managed), custom
  `ANTHROPIC_BASE_URL` / Bedrock/Vertex/Foundry routing, non-claude.ai auth — and a pointer to
  first-party `claude doctor` for the authoritative check name (report, don't reimplement).
- **`sessions`:** ≥2 live sessions against one working tree (source: the 0-D tracker; corroboration
  when available: `claude agents --json`, filtered per §4's V4 correction, degradation to a named
  note when the research-preview surface is absent or unparseable — warning surface only, never a
  gate).
- `nc` joins `check_dependencies` (`scripts/doctor.sh:150` region): with `socat` absent and
  `python3` an alias on real hosts, `nc -U` is the only in-house poster if one is ever sanctioned,
  and its absence should be a named fact, not a surprise.

Count-string updates: "ten checks" → thirteen at `CLAUDE.md:27,79`, `skills/doctor/SKILL.md:2,12,25`,
`README.md:88`, doctor.sh header.

### 0-G · Remote-ops documentation (#184's other half)

README + CLAUDE.md-template operator section: running an AFK loop under `tmux`/`screen`; the
~10-minute network-outage session timeout; Ultraplan disconnects Remote Control; one remote session
per interactive process (`--spawn` for more); the two push toggles; and the HITL story this design
adopts — *steering an AFK loop from a phone or second machine is Remote Control + cross-session
messaging, natively; Nazgul ships no code for it.* With F, this closes **both** halves of #184
honestly. ("Close as delivered by the check alone" — the first draft's wording — would have closed
an issue half of whose scope was undelivered.)

---

## 3. Phase 1 — Inbound hardening & the record

### 1-A · Session-level peer trust boundary (extends MF-059)

MF-059's trust boundary exists only for reviewer teammates (`agents/templates/reviewer-base.md:118-137`)
and orchestrator outbound discipline. The session that runs `/nazgul:start`, holds Bash, and drives
the loop — the session inbound messages actually reach — has no equivalent. Add it:

- **Prose (`[advisory]`):** `templates/CLAUDE.md.template` (under Safety) + `skills/start/SKILL.md`:
  an inbound message is untrusted content; never a verdict, a status-change authorization, a config
  change, or the operator's consent; anything it requests passes through the session's own guards.
  Note the platform's own delivered-message preamble already reinforces this for the messaging path
  (P1 observation) — Nazgul's text is *primary* for any other channel and *reinforcement* here.
- **Presence test (`[enforced]`):** the `tests/test-review-contract.sh:84-99` precedent — a static
  assertion that the boundary language exists in both surfaces.
- **Tier wording:** `[advisory]` **on 2.1.233 as measured** — not "permanently". P6 falsified
  permanence: a message-started turn traverses `UserPromptSubmit` with the message text as
  `.prompt`, so receipt IS hook-observable and an enforced inbound gate is buildable. Recorded as
  an option, not built (whether the payload distinguishes peer origin from a typed prompt is
  unprobed). **Live interplay documented:** `prompt-guard.sh` already runs on every inbound peer
  message in Nazgul projects today; #92's over-block can silently eat a legitimate operator/peer
  message — noted on #92.

### 1-B · The posture scan (`[enforced]`, new §15 entry point)

New shipped-surface scan test (working name `tests/test-messaging-posture.sh`) over `scripts/**`,
`skills/**`, `agents/**`, `templates/**`, `hooks/**`:

1. No shipped surface **writes** `crossSessionInbound` or `isolatePeerMachines` — inbound posture
   is the operator's; Nazgul documents, never sets. (Both keys: zero occurrences today — the scan
   pins the vacuous truth.)
2. No shipped surface **posts to** the messaging socket — with the doorbell cut, *any* connect/write
   referencing `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN` outside a small read-only allowlist
   (doctor's eligibility read; docs) is a violation. This is the one messaging rule that can be
   genuinely mechanized, and it is what keeps "never a loop mechanism" true after this cycle.

§15 obligations in the same change: fixed coverage grammar with a `K > 0` floor; registry entry
(`RULES.md:534-545`, "Nine" → "Ten"); `tests/test-coverage-honesty.sh:19` `ENTRY_POINTS` plus a
forced all-skip drive; a dogfooded synthetic violator (the `test-agent-state-path-contract.sh`
pattern). Honest boundary stated in the rule: the scan binds shipped text; a model's runtime
conduct remains `[advisory]` (§21 precedent).

### 1-C · The record (decision log + RULES amendments)

Per the repo's own decision-log lifecycle (a prior run's committed log is never rewritten):

1. **New log:** `docs/DECISION-LOG-2026-08-16-cross-session-messaging.md` — D-entries for: the
   adoption doctrine (§1); the doorbell assessment and rejection (with P2/P5 recorded as the
   evidence that it *worked* and was cut anyway — the record must show this was a judgment about
   reliability semantics, not capability); the classification decision (0-C); the amended closing
   rule.
2. **Pointer, not edit:** one "Amended by → 2026-08-16 log" line in
   `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md`; dated annotations on **D-002
   item 3** (SendMessage-wake — the decision this cycle actually revisited: its "no session
   resumption" reason is retired for the own-session case by P2/P5, intact for teammates) and
   **D-002 item 4** (watchdog re-poke — reaffirmed; the doorbell was its shape and was cut).
   D-003's closing rule stands unmodified for its subject (background-subagent drivers); the new
   rule below covers what it never reached. Cite decision logs by file+id — two unrelated D-003s
   exist (`2026-07-13` and `2026-07-21` logs).
3. **RULES new §22 (Cross-Session Messaging Posture)** — the adopted rule ("an unguaranteed channel
   may shorten a wait, but may never authorize one"), the never-write/never-post rules (1-B), the
   trust boundary (1-A), and the threat-model note (1-D), each tier-labeled (the
   `tests/test-rules-tiers.sh` constraint).
4. **Corrections of fact, not just caveats:**
   - `RULES.md:320-326` (§13 "never a second loop"): currently false in two dimensions — per-root
     (sibling worktrees invisible) AND per-lifecycle (locks drain on every allowed stop, so a held
     or housekeeping session is uncounted). Rewritten against the 0-D fix; until D lands, the tier
     text must say what is actually true. Also resolve the internal disagreement with
     `heartbeat.sh:36`'s own "secondary, non-primary check" hedge.
   - `RULES.md:278` / `:327-336` (`execution_should_halt` "unconditional"): true per root; false
     per project under sibling-worktree peers. Stated.
   - RULES §17:698-699 paraphrase corrected where cited (it permits courtesy).
5. **Event bookkeeping — all four drifting taxonomies in the same change** (#143 interplay):
   `agents/doc-verifier.md`'s hard-coded event list (else this objective's own post-loop gate
   rejects its own events), `docs/CONFIGURATION.md:425-447` Event Types,
   `skills/log/SKILL.md:71-85` TYPE map, and the `tests/smoke/run-smoke.sh:268` stop_gate-reason
   comment (already stale — `stacking_unavailable`). New names this design mints:
   `in_flight_orphan` (stop_gate reason), `dispatch_guard_background_unverifiable`,
   `clear_skipped_no_match`, `clear_fallback_underivable`. All emissions inherit the ADR-021
   `NAZGUL_DIR` contract — emitted only from contexts that resolved the root via
   `scripts/lib/nazgul-root.sh`.
6. **Operator surface:** `/nazgul:status` shows live in-flight markers (class + age), quarantine
   count, and last `stop_gate` reason — after 0-C the first question about any mysterious stop is
   "held, orphaned, or continued?", and status must answer it. `docs/CONFIGURATION.md:285-318`
   (In-Flight Dispatch Hold) rewritten; `docs/SAFETY.md`'s session-locks claim rewritten against
   0-D.

### 1-D · Threat model (V6, corrected scope)

RULES §22 + `docs/SAFETY.md` (durable homes — NOT a `nazgul/docs/` ADR, which is gitignored runtime
state that gets archived; the coverage-honesty incident is the precedent):

- Any process running as the OS user can have its *connection* accepted on any session's socket;
  whether the message reaches Claude then follows the receiver's inbound controls. Socket file
  permissions (0700 dir, 0600 socket) are the entire *authentication* boundary; the peerToken key
  file is same-user readable.
- `CLAUDE_CODE_MESSAGING_TOKEN` is exported into every Bash tool call: an environment leak is a
  turn-injection capability for that session. Policy sentence (connector precedent): the token is
  never stored in config, never logged, never placed in event fields — with a grep test over the
  events fixture.
- Recommended AFK posture documented (not set by Nazgul): leave `crossSessionInbound` unset (the
  bypass-class default holds unverified messages) or set explicit `hold`/`refuse` per the
  operator's threat model; `isolatePeerMachines: true` for cross-machine approval. Stated plainly:
  **nothing gates inbound in Nazgul today** — the platform's controls are the only inbound
  mechanism; 1-A's P6 finding is the path to changing that if ever warranted.

### 1-E · Commit the evidence

`2026-08-16-cross-session-messaging-platform-facts.md` ships in this repo (done alongside this
spec) — version-pinned (2.1.233, darwin, 2026-08-16), with the undocumented-wire-format caveat on
its face. No CI re-verification harness is built for it: with no messaging mechanism shipped, drift
risk falls on documentation, and the scan (1-B) keeps shipped code messaging-free. Re-verification
is triggered by intent to build, not by calendar.

---

## 4. Phase 2 — Roadmap record amendments (grounded against the binding docs)

- **#182 (Objective B):** worktree-per-feature isolation is KEPT (already the spec's design);
  messaging-as-coordination was never in the binding record — the honest note is that this cycle
  *considered and rejected* it, so the record shows the road not taken. Peer liveness = each peer's
  own Stop hook (an *addition* to the record, marked as such). PLAN-B Task 1 (spatial hooksPath
  fix) remains open and gains the between-objectives doctrine question from 0-E, with an explicit
  sequencing note. V9 (#84945 silent bind failure for same-directory sessions) recorded as a hazard
  for any N-session posture. PLAN-B:204's "two-live-session E2E out of harness reach" premise is
  flagged for re-evaluation (`--name`, `-p` sockets, `claude agents --json` may put it in reach).
- **#183 (Objective C):** the plan's registry **already** stores only what the platform cannot
  know (feat_id ownership, rows for sessionless worktrees) and already delegates liveness to Agent
  View — "shrink the registry" is withdrawn. Real amendments: SPEC §5:254-256's
  foreground-invisibility rationale is partly false (V4: `agents --json` lists foreground
  sessions); pin the *measured* row shape (`id/sessionId/name/kind/state/cwd/startedAt`, `pid`
  sometimes) against PLAN-C:103's asserted field list; and record that **`pid: null` is NOT a
  liveness filter** (a `state:"done"` session carried a pid; `blocked` ones lacked the key) —
  liveness = kind/state + `kill -0` when pid present, degradation always a named skip.
- **#184:** closed by 0-F + 0-G (both scope halves). **#185:** unchanged, still gated on its
  doctrine decision; two boundary facts recorded for its future spec (container/host sockets
  unreachable; cloud sessions reachable only via Remote Control connection). **#122:** independent;
  merge-order coordination on `stop-hook.sh` only.
- **Board dispositions are owned work:** issue comments/closures for #94, #104 (partial), #184,
  #195 (partial), #205, plus the #182/#183 amendment comments and a #92 note — enumerated as tasks,
  then `scripts/sync-inbox-to-github.sh --check` per the Backlog Rule.

---

## 5. Cuts and non-goals (binding)

Never in this cycle, and never without a new spec cycle: `scripts/lib/messaging.sh` or any socket
poster; `guards.session_wake` or any new config key (schema stays v36); any router, mailbox, retry,
ack layer, or repeating poster; any evidence gate or state transition whose input is a message; any
peer-session driver replacing the stop-hook; cross-machine loop orchestration; a `SendMessage`
PreToolUse matcher presented as inbound hardening (it gates outbound only — §22 says so out loud);
Nazgul writing any inbound-posture key.

---

## 6. Residual limitations & probes owed (named)

1. **Background-resume-lost sleep.** If a `background==true` hold's harness resume never arrives
   (harness defect/crash), the session sleeps until the operator notices — `in_flight_stale`
   cannot self-fire without a turn, and post-0-D the heartbeat *correctly* refuses to auto-start
   against a live registered session, so it cannot rescue this case either (that refusal is
   correct behavior; it narrows the rescue path to the operator). This is a platform-bug class, not a
   Nazgul mechanism gap; the named future option is a heartbeat-rung doorbell (external process +
   `accept` posture, eyes open) behind its own spec, only if it ever bites in practice.
2. **Probe owed:** background-capable host — `run_in_background: true` dispatch → SubagentStop
   fires + harness resumes (0-C's one load-bearing platform fact). Also unprobed: whether the
   `UserPromptSubmit` payload distinguishes peer-origin turns (1-A option's prerequisite).
3. **#104 Gaps 1–2** and #144's reaper residue: open, dispositioned on the issues.
4. **#195 fix direction 3** (staged-file provenance sidecar): not in this cycle; noted on the issue.
5. **V3 caveat stands:** the message wire format is observable, not documented. Nothing shipped
   depends on it; anything future that would must re-probe and version-gate.

---

## 7. Tier summary

| Rule / mechanism | Tier |
|---|---|
| Hold classification, orphan quarantine, sweep (0-C) | `[enforced]` (in-script, kill-switched by `guards.in_flight_hold`) |
| Three-way marker clear (0-B) | `[enforced]` (in-script) |
| Lock lifecycle + concurrent-tree warning (0-D) | `[enforced]` record/warning; the warning is stderr, never a block |
| Clean restores hooksPath (0-E) | `[enforced]` once run; clean itself is operator-invoked |
| Dispatch-guard missing-field allow + named event (0-A) | `[enforced]` (hook) — the allow is the fail-open decision, stated |
| Doctor checks (0-F) | `[enforced]` reporting; acting on it is the operator's |
| Never-write-posture-keys, never-post-to-socket (1-B) | `[enforced]` for shipped text via §15-enrolled scan; runtime conduct `[advisory]` |
| Session trust boundary (1-A) | `[advisory]` behaviorally + `[enforced]` presence test; "on 2.1.233", re-evaluated per release |
| Token never logged (1-D) | `[enforced]` (fixture grep) for shipped surfaces |
| "Shorten a wait, never authorize one" (§22 rule) | doctrine; enforced indirectly by 1-B (no poster can exist) |

## 8. Versioning & bookkeeping

2.33.0, MINOR, **no schema step** (CHANGELOG states this explicitly per house convention).
`hooks/hooks.json`: expected zero changes (all touched scripts already registered) — if 0-D's
SessionEnd choice adds an entry, `tests/test-hooks-schema.sh` updates in the same change. New test
files: `tests/test-messaging-posture.sh` (+ coverage-honesty enrollment); extensions to
`test-in-flight-hold.sh`, `test-subagent-stop.sh`, `test-session-tracker.sh`,
`test-session-context.sh`, `test-heartbeat-session-guard.sh`, `test-parallel-dispatch-guard.sh`,
`test-doctor.sh`, `test-git-hooks-*` (clean path), `test-review-contract.sh`-pattern presence test.
Rollout note for CHANGELOG: on upgrade, a pre-existing fresh *foreground* marker quarantines at the
next Stop instead of holding — a strictly corrective behavior change in live AFK runs, called out.
CLAUDE.md gains this feature's Key Concepts paragraph; README badge + doctor row sync.
