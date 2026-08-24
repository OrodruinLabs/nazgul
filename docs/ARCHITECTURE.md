# Architecture

## Pipeline

```
Objective → Discovery (+Classification) → Doc Generator → Planner → Implementer → Review Board → Loop → Post-Loop → NAZGUL_COMPLETE
```

1. **Discovery Agent** scans the codebase, classifies the project, generates tailored reviewer agents
2. **Doc Generator** produces PRDs, TRDs, ADRs based on project type
3. **Planner Agent** decomposes the objective into dependency-ordered tasks
4. **Implementer Agent** builds one task at a time, delegates to specialists as needed
5. **Review Board** (Architect, Code, Security + project-specific reviewers) reviews each task
6. **Feedback Aggregator** classifies findings as AUTO-FIX or ASK (per `references/fix-first-heuristic.md`), then consolidates into actionable fixes
7. Loop continues until ALL tasks pass ALL reviewers
8. **Post-Loop** agents update docs, manage releases, verify observability

## Agent Roster (core agents + project-specific reviewers)

| Category | Agents |
|----------|--------|
| Pipeline (always) | Discovery, Doc Generator, Planner, Implementer, Review Gate, Feedback Aggregator, Team Orchestrator |
| Reviewers (conditional) | Architect, Code, Security, QA, Performance, A11y, DB, API, Type, Infra, Dependency, Mobile, Data |
| Specialists (conditional) | Designer, Frontend Dev, Mobile Dev, DevOps, CI/CD, DB Migration, Debugger |
| Post-Loop (conditional) | Documentation, Release Manager, Observability, Simplifier |

Discovery generates only the agents a given project needs. The full set of core agents exists as specs, plus a reviewer template (`agents/templates/reviewer-base.md`) that spawns project-specific reviewers driven by `agents/templates/reviewer-domains.json`.

## Telemetry & Observability

Nazgul maintains a canonical, schema-versioned event stream at `nazgul/logs/events.jsonl` — an append-only JSONL file where hooks and agents emit structured telemetry. This consolidates what was previously scattered across multiple files (`iterations.jsonl`, `subagents.jsonl`, in-place config mutations, and dotfiles).

### Event Stream

The event stream captures the complete lifecycle:

- **Iteration boundaries** — when the loop stops after each iteration
- **Task lifecycle** — task completion events
- **Review verdicts** — approvals/rejections from the review board with confidence scores
- **Retries and blocks** — re-attempts after CHANGES_REQUESTED, and blocking states that require intervention
- **Compaction milestones** — checkpoints during context compression
- **Subagent lifecycle** — when specialized agents (implementer, discovery, etc.) complete
- **Subagent empty/verdict-less returns** — `subagent_empty_return` (reasons `empty_final_text`|`no_verdict_line`, actions `resumed`|`exhausted`|`detected_only`) fires for any completing subagent whose transcript shows no usable final text, or (for reviewers) no fenced verdict line
- **Gate-triggered stops** — `stop_gate` (reasons `afk_timeout`, `in_flight_hold`, `in_flight_orphan`, `in_flight_stale`, `in_flight_unverifiable`, `stacking_unavailable`) fires whenever a stop-hook gate ends or holds a turn, so the telemetry always shows a mechanism acted rather than a bare `exit 0`
- **Stacked-PR continuation lifecycle** — `stack_layer_merged`, `stack_rework_filed`, `stack_sync_conflict`, `stack_api_failure`, `stack_remote_layer_imported`/`stack_remote_layer_import_failed` (opt-in, `execution.stacking`) — see `docs/CONFIGURATION.md` → **Stacked-PR Continuation**
- **Budget/cost warnings** — proactive alerts before spending limits

See `docs/superpowers/specs/2026-06-24-telemetry-bus-design.md` for the full event taxonomy and schema.

### Emit Library

`scripts/lib/emit-event.sh` is the canonical append mechanism — writes one JSON event line per call. When `flock` is available (typically Linux) it serialises concurrent writers with an exclusive lock; when absent (stock macOS) it falls back to a best-effort direct append relying on `O_APPEND` atomicity for the short JSONL lines. Callers pass event type + key-value pairs; the library handles schema versioning, timestamps (ISO 8601 UTC), and iteration context. Emits are best-effort: a write failure never aborts the calling hook.

### SubagentStop: telemetry plus a bounded resume path

`scripts/subagent-stop.sh` is no longer a pure observer. In addition to its `subagent_stop` telemetry append, it inspects every completing subagent's own transcript for an empty or verdict-less final return and, when `guards.subagent_resume` is `true` (default, config schema v32), can respond with a decision-block JSON payload (`exit 2`) that has the harness re-run the SAME subagent with the empty-return called out as its next turn — a bounded, in-hook fix rather than an orchestrator-level re-dispatch. The resume is capped at 2 attempts per dispatch (tracked under `nazgul/logs/.resume-attempts/`, keyed by `agent_id`/`session_id`), skips itself on the harness's own `stop_hook_active` re-entry signal, and degrades to detection-only (`exit 0`, no block) on any error, a disabled kill-switch, or cap exhaustion — every outcome is recorded in the `subagent_empty_return` event's `action` field. See RULES.md §19.

Used by:
- **5 hook scripts** (`stop-hook.sh`, `task-completed.sh`, `subagent-stop.sh`, `stop-failure.sh`, `post-compact.sh`) — write producer events
- **Review-gate agent** (`agents/review-gate.md`) — emits reviewer verdicts, retry dispatch, and blocks
- **Agents via CLI wrapper** (`scripts/emit-event-cli.sh`) — agent-friendly invoke pattern

### In-Flight Dispatch Hold

`scripts/in-flight-marker.sh` (`PreToolUse` on the `Agent` tool) writes a small marker file under
`nazgul/in-flight/` for every subagent dispatch — never blocking, a failed write is a silent no-op.

**A marker identifies a dispatch by digest, never by prompt text (FEAT-034/ADR-028).** It carries
`prompt_hash` and `prompt_bytes` in place of the former `prompt_head`. The field was RENAMED rather
than redefined because `prompt_head` names content the field no longer has, and the old name is what
generated the now-moot redaction requirements in the mission-control documents. `prompt_head` predates
FEAT-034 and wrote `cut -c1-200` of the prompt — a **per-line** operation, so it kept 200 characters of
*every* line: measured against the pre-change writer, a 150-line prompt produced a marker holding
30,171 characters of prompt text, 151x the bound its own comment claimed.

The value grammar is closed, and its four states are distinguishable by inspection alone:

| `prompt_hash` | `prompt_bytes` | Means |
|---|---|---|
| `^[0-9a-f]{16}$` | `wc -c` of the prompt | computed normally |
| `e3b0c44298fc1c14` | `0` | **computed**, over an empty prompt — not a failure |
| `unavailable` | still populated | no digest, or one that failed `^[0-9a-f]{16}$`; also one stderr line |
| `^[0-9a-f]{16}$` | `${#PROMPT}` under `LC_ALL=C` | `wc`/`tr` unreachable; exact count, different mechanism; also one stderr line |

`unavailable` carries non-hex letters (`u`, `n`, `v`, `i`, `l`) and is 11 characters rather than 16, so
it can never parse as a digest — one anchored regex separates "could not compute" from
"computed and got this" — a degradation can never be misread as a digest. **That regex runs at the
writer**, not only in this table: a helper that answers with a deprecation line before the digest, with
uppercase hex, or with fewer than 16 characters is rejected to `unavailable`, and the stderr line names
the cause class (`length=N`, `non-hex-character`) and never the rejected value, which is prompt-derived
(#254 A2, ADR-028 D4). `prompt_bytes` is `wc -c` over the same byte stream that is hashed. Plain
`${#PROMPT}` is never used as the primary count, because it counts characters under a UTF-8 locale and
would disagree with the digest invisibly; it is used only as the fourth-state fallback, re-evaluated
under `LC_ALL=C`, where it counts bytes and agrees with `wc -c` exactly. The fourth row exists because
`wc` can genuinely be absent, and before #254 A1 that path wrote JSON `null` with no stderr at all —
a reachable state the closed grammar did not name.

**Accepted residuals, recorded as decisions rather than oversights.** The digest is unsalted, so a
party holding a candidate prompt can CONFIRM it by recomputing the hash; it cannot recover an unknown
prompt. A keyed digest was rejected because a per-project secret is itself state to store and leak,
and the field's purpose is matching a marker to a dispatch, which a shared secret does not serve.
`prompt_bytes` discloses prompt SIZE. Both are accepted: the exposure being closed is prompt TEXT.
`scripts/subagent-stop.sh` clears the oldest marker matching the completing subagent right after its
existing `subagent_stop` telemetry append. `scripts/stop-hook.sh` checks for a fresh marker immediately
before its iteration increment: with a provably-background unnamed one present, it ALLOWS the stop (`exit 0`)
without touching `current_iteration` or `safety.consecutive_failures`, relying on the harness's own
task-notification to wake the loop when the dispatched agent finishes rather than polling. A fresh marker
that is NOT provably background (`"false"`, `"missing"`, or named) is not provably awaited work, so it is
quarantined under `nazgul/in-flight/quarantine/` and the loop continues NORMALLY (#104 Gap 3) — reported as
`stop_gate` `reason: "in_flight_orphan"` when the class was proven (`background: "false"`, or a named
dispatch whose report contract owns it), and as `reason: "in_flight_unverifiable"` when the class was not
observable at all. A marker older than
`guards.in_flight_stale_minutes` (default 30) does not hold the stop — the loop proceeds normally — but is
reported loudly (stderr + a distinguishable `stop_gate` event) rather than silently ignored. Kill-switched by
`guards.in_flight_hold` (default `true`, config schema v34). Both ends of the mechanism are hooks, per
ADR-015 — the trigger is never orchestrator memory. See RULES.md §1, `docs/CONFIGURATION.md`, ADR-017
(FEAT-026).

A fresh marker whose `background` field is `"missing"` records that the dispatch class was **not observable
at write time** — it does not record a foreground dispatch. Claude Code omits the Agent tool's
`run_in_background` parameter from the exposed schema in fork mode (the interactive default since v2.1.232)
and under `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, and absence means the **opposite** thing in those two
configurations: background in the first, foreground in the second. In the session type this loop runs in,
absence therefore means the dispatch is most likely **background**, so quarantining it is a cost-weighed
default that is usually wrong about the dispatch it names. On such a host the class-aware hold never
engages, `stop_gate` `reason: "in_flight_unverifiable"` fires on essentially every dispatch, and the loop
continues concurrently with live subagents. That was the defect #218 named, and **FEAT-033 closes
it**: the Stop-payload classification path below is the fix #218 asked for, and it ships here. The
authoritative signals existed one event later: `PostToolUse` `tool_response.status` (`async_launched` vs `completed`)
and the `background_tasks[]` array on `Stop`/`SubagentStop`. Both are present in the shipped hook
schema as of Claude Code 2.1.238 and were **empirically captured 2026-08-21** — real `Stop` and
`SubagentStop` payloads from two sessions, kept as `tests/fixtures/stop-payload/` — but neither is in
the PUBLIC hook reference, which lists only `last_assistant_message` and `effort` for `Stop`. The
shipped schema is a strict SUPERSET of the published one, so this rests on observation rather than on
documentation, and the field can change without a deprecation notice. Since FEAT-033 the stop-hook
READS `background_tasks[]` at `Stop`: a live subagent for this session takes the hold even when every
marker records `background: "missing"`, so the "never engages" sentence above now describes only the
case where the payload carries no such field. Liveness is a fact about the SESSION, so it does not reach a marker whose own recorded class already disposes of it: a `background: "false"` marker is quarantined on a live tick exactly as on any other, because no other dispatch's liveness makes a synchronous one able to span a Stop, and the hold's `units` field therefore never names one. A NAMED marker on a live tick is held rather than quarantined — its proof is contractual, not mechanical, and a named dispatch can be genuinely background and running. `tool_response.status` remains unread as the deliberate, explicitly out-of-scope remainder: a second corroborating signal for the question the Stop payload now answers, not an unfixed part of the defect. Only the PROVEN class is quarantined; the unobservable class is LEFT IN PLACE (moving it is irreversible and the dispatch may still be running — it would also foreclose #218's fix, which reconciles these markers against the Stop payload's `background_tasks[]`). `reason: "in_flight_orphan"` is reserved for `background: "false"` or a named dispatch,
which are genuinely proven.

Reading `background_tasks[]` splits the `yes` observation into two independent counts (ADR-027 Q2), never one filter: `LIVE` (`type=="subagent"` AND an allowlisted `running`/`pending` status) gates the HOLD described above; `SUBAGENT_PRESENT` (`type=="subagent"`, status-blind) gates a THIRD disposition. When `SUBAGENT_PRESENT == 0` — the payload was read and reports no subagent of any status for this session — the marker is DETECT-ONLY: `stop_gate` `reason: "in_flight_orphan_candidate"` (`evidence: "background_tasks_empty"`) records the observation and the marker is LEFT IN PLACE, deliberately NOT `in_flight_orphan`, which names a class that was PROVEN and really was quarantined. That arm is ATTRIBUTION-GATED: `background_tasks[]` is this session's registry and markers carry no session id (#248), so when more than one live session shares this `nazgul/` the empty registry cannot speak for the dispatch the marker names, and a distinct `reason: "in_flight_orphan_unattributable"` is recorded instead — the Q3 bar counts only the candidate. Both detect-only arms run at ANY marker age, carrying `age` (`fresh`|`stale`): confining them to the fresh branch excluded the aged markers a real orphan almost always is, so the instrument had been excluding its own target population. An unrecognised status produces **neither a hold nor a candidate** — a claim about the two DISPOSITIONS and never about the counts, since such an entry still increments the status-blind `SUBAGENT_PRESENT`, which is what makes present-but-not-live a third STATE rather than an absence. Its record is `stop_gate` `reason: "in_flight_present_not_live"` plus a stderr line: marker preserved, iteration proceeds, and the arm that acted does not look like one that had nothing to do. The irreversible `mv` for this arm stays deferred until ADR-027's numeric bar (≥20 `in_flight_orphan_candidate` events across ≥2 objectives with zero contradicting `subagent_stop` evidence) is met. A second hold on an unchanged marker set is refused by a bounded valve (`_IN_FLIGHT_HOLD_CAP = 1`, a script constant, ledgered by marker-set fingerprint under `nazgul/logs/.in-flight-holds/`), reported as `stop_gate` `reason: "in_flight_hold_budget_exhausted"`, kept distinct from `reason: "in_flight_hold_unbudgetable"`, which names a mechanism FAILURE rather than a spent budget: the ledger could not be written or could not be keyed to an episode, so the hold could not be BOUNDED and an unbounded hold is DECLINED rather than taken. The valve is episode-scoped — ledger entries whose recorded marker set no longer exists are pruned before a key is derived — because in the canonical unattended shape (`claude -p`) a hold's `exit 0` IS process exit, so the wake this hold now depends on being reachable for the first time is bounded rather than unbounded. Every Stop the hook processes, independent of any marker, also emits a `stop_payload_observed` event (`bg_seen`/a closed seven-member `why`/counts/`types`/`statuses`) above the `guards.in_flight_hold` kill switch and below the `paused` gate so a change to the undocumented `background_tasks[]` field surfaces as vocabulary rather than as a hold that silently stops engaging. See `docs/CONFIGURATION.md` In-Flight Dispatch Hold for the release-gate obligation this reachable hold carries, and ADR-027 for the full four-arm decision.

### Migration: Single-Write + Dual-Read

The migration from scattered telemetry to `events.jsonl` is **single-write + dual-read**:

- **Producers** (hooks and review-gate agent) write ONLY the new `events.jsonl` stream. Legacy `iterations.jsonl` and `subagents.jsonl` are no longer appended; they freeze in place as historical records (not deleted).
- **Consumers** (`/nazgul:metrics`, `/nazgul:log` skills) prefer the new `events.jsonl` but fall back permanently to frozen legacy files for pre-upgrade history. This preserves full event history across upgrades with zero data loss.
- **No parallel writes, no cutover step, no v15.** The emit library is proven by mandatory unit + concurrency tests; one append-only write is the lowest-risk telemetry design. This approach avoids the complexity of dual-write + version cutover while keeping consumers forward/backward compatible.

## Recovery

Nazgul survives compaction, crashes, and session restarts:

1. **Pre-compact hook** writes a checkpoint before compaction
2. **Post-compact hook** re-injects loop state immediately after compaction completes
3. **Session-context hook** re-injects state on startup/compaction
4. **Recovery Pointer** in plan.md tells the agent exactly where to resume
5. **Checkpoint files** in `nazgul/checkpoints/` have full JSON state snapshots
6. **Webhook forwarding** optionally notifies external systems on stop/compact events
7. **TaskCompleted hook** fires immediately when spawned agents finish for faster transitions
8. **Prompt guard hook** validates user prompts on submission
9. **Task-state guard hook** prevents edits outside claimed task scope, and preflight-rejects an illegal status transition — but it is not the transition authority; see Task-Transition Authority below
10. **In-flight dispatch hold** — the stop-hook holds an ALLOWED, uncounted stop while a just-dispatched BACKGROUND `Agent` is still running (`guards.in_flight_hold`), so the loop doesn't burn iterations re-invoking itself every ~15 seconds against work that hasn't finished; any other marker is not held on — quarantined as an orphan when the class was PROVEN, or recorded as `in_flight_unverifiable` and left in place when it was not observable (the move is irreversible and the dispatch may still be running). See In-Flight Dispatch Hold below.

After any interruption:
```bash
/nazgul:start              # Auto-detects state and resumes from last checkpoint
/nazgul:status             # See where things stand
```

## Review Gate & Fix-First Review

When the review board returns CHANGES_REQUESTED, the feedback aggregator classifies each finding:
- **AUTO-FIX**: Mechanical issues (dead code, style, stale comments) — applied automatically
- **ASK**: Risky changes (security, architecture, API contracts) — presented for judgment

The review gate's Step 3.75 applies auto-fixes, re-runs tests, and only surfaces ASK items. This reduces review round-trips significantly. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA in the task manifest, IN_REVIEW requires a review directory, and source edits require an IN_PROGRESS task. Reviewers are dispatched as unnamed one-shot `Agent` calls with `run_in_background: false` and RETURN their verdict as returned text; the orchestrator persists it. `scripts/parallel-dispatch-guard.sh` (PreToolUse on `Agent`) enforces the `name` absence and an explicit `run_in_background: false`; a call that simply OMITS `run_in_background` is allowed with a `dispatch_guard_background_unverifiable` event, because on hosts whose Agent schema lacks the field the value is unsupplyable and a block there disables the whole board (#205). Every status change the gate makes goes through `scripts/task-transition.sh` — see Task-Transition Authority below.

## Testing & CI

### E2E Skill Testing
`tests/e2e/run-e2e.sh` spawns `claude -p` subprocesses to validate skills end-to-end. Gracefully skips when the `claude` CLI is unavailable. CI workflow (`e2e-tests.yml`) is manual-trigger only since tests cost money.

### Skill Template System
`scripts/gen-skill-docs.sh` resolves `{{PARTIAL:name}}` placeholders in `SKILL.md.tmpl` files using shared partials from `templates/skill-partials/`. CI workflow (`skill-docs.yml`) checks for stale SKILL.md files on PRs.

### CI Pipelines
- `test.yml` — runs unit/integration tests on push and PR
- `e2e-tests.yml` — E2E skill tests via `claude -p` (manual trigger)
- `skill-docs.yml` — checks SKILL.md freshness on PRs touching skills/partials
- `e2e-stack.yml` — two-layer `gh-stack` E2E against a live scratch repo (manual trigger, needs a `STACK_E2E_GH_TOKEN` secret)

## Self-Improvement Mode
Agents optionally self-rate their experience (0-10) and file structured JSON reports via `scripts/file-improvement-report.sh`. Enabled per-project in config. `/nazgul:metrics` aggregates reports.

## Concurrent Session Tracking
`scripts/lib/session-tracker.sh` manages filesystem locks in `nazgul/sessions/`. Sessions register on startup, unregister on exit, and stale locks (>2h) are cleaned automatically. Concurrent sessions trigger a warning to prevent state corruption.

## Shared Task Utilities
`scripts/lib/task-utils.sh` provides `get_task_status`, `set_task_status`, `count_tasks_by_status`, and `get_active_task`. Supports 4 status formats: list-item, ATX inline, ATX block, and YAML frontmatter.

## Task-Transition Authority (ADR-020)

`scripts/task-transition.sh` is the sole sanctioned writer of a task's status. Three call sites share one library, `scripts/lib/task-transition-guard.sh`, so the state machine cannot drift between them:

- **`scripts/task-transition.sh`** — the authority. `ttg_apply_transition` takes a per-task lock, validates the staged manifest, rechecks the source status immediately before an atomic rename, verifies the target status on disk, and only then appends the completed edge (`ttg_log_transition` → `nazgul/logs/guarded-transitions.jsonl`, with before/after content hashes). The lock serializes authoritative writers; it does not claim to make an unrelated raw filesystem write transactional.
- **`scripts/task-state-guard.sh`** — preflight only. It rejects EVERY direct status write at the `PreToolUse` boundary, including a legal adjacent one, naming the transition command to run instead; an illegal write is refused earlier by the shared validator so the two causes stay distinguishable. It sees an *intended* write, never a completed one, so it can no longer create the record reconciliation trusts. This is the ADR-020 correction: a cancelled or failed edit used to leave preauthorization behind that a later raw write could ride on.
- **`scripts/stop-hook.sh`** — reconciliation. Each iteration it diffs live status against the previous checkpoint and requires a *chain* of completed edges, not a matching endpoint pair, to accept a change.

`PLANNED -> READY`'s dependency condition runs through one shared `ttg_dependency_satisfied` used by both the transition validator and the stop-hook's auto-promote arm. Under `review_gate.granularity: task` a dependency must be DONE (APPROVED in YOLO); under `group`/`feature` every task parks at IMPLEMENTED until one aggregate board, so IMPLEMENTED or later satisfies it.

### Typed quarantine and evidence-gated repair

A status change with no completed transition behind it is not "corrected" — it is quarantined with machine-readable endpoints (`Blocked kind: reconciliation`, `Blocked from`, `Blocked observed`) and a `reconciliation_quarantine` event. `DONE -> BLOCKED` is deliberately not modeled as an ordinary graph edge; it is an integrity state outside the product flow, and preserving both endpoints is what makes recovery possible. `scripts/task-transition.sh repair TASK-NNN` is its only exit: five independent revalidations (commit evidence, red-run evidence, review-directory path safety, review verdicts, review provenance) run before any write, then `BLOCKED -> IN_REVIEW -> DONE` goes through the same transactional primitive as every other edge — never `READY`, never an implementer redispatch, because re-implementing reviewed work would destroy the evidence being validated. Refusals are individually named (`not_blocked`, `untyped_blocker`, `wrong_blocker_kind`, `corrupt_quarantine_metadata`, `unreviewed_observed_status`, `incomplete_evidence`) on stderr and as `reconciliation_repair` events, and `repair` is closed to every other blocker class. See RULES.md §2.

## Directory Structure

The repo IS the installable plugin. Runtime state lives under `nazgul/` in each target project (created by `/nazgul:init`), never in this repo.

```text
.claude-plugin/plugin.json   # Plugin manifest (must be at repo root)
RULES.md                     # Enforceable operating rules (consolidated)
agents/                      # Agent definitions (22 specs + reviewer template)
│   └── templates/           # reviewer-base.md + reviewer-domains.json
skills/                      # Slash commands (/nazgul:*) — 26 skills
hooks/hooks.json             # Hook definitions (12 hook types: Stop, StopFailure,
│                            #   PreCompact, PostCompact, PreToolUse, PostToolUse,
│                            #   SessionStart, SessionEnd, SubagentStop,
│                            #   TaskCompleted, TeammateIdle, UserPromptSubmit)
scripts/                     # Hook + entry-point scripts (34 + 24 libs)
│   └── lib/                 # Shared libraries (task-utils, session-tracker,
│                            #   emit-event, review-evidence, bootstrap-{scrub-map,render,preflight,relocate})
templates/                   # Objective + doc templates
│   └── skill-partials/      # Shared SKILL.md template partials
references/                  # Shared reference docs for agents
tests/                       # Plugin validation tests (unit, integration, E2E)
.github/workflows/           # CI pipelines (test, e2e, skill-docs freshness)

# Created per-project by /nazgul:init (NOT part of the plugin):
nazgul/
├── config.json              # Runtime configuration
├── plan.md                  # Live task tracker with Recovery Pointer
├── tasks/                   # Individual task manifests with full state
├── checkpoints/             # Per-iteration JSON snapshots
├── reviews/                 # Review artifacts per task
├── context/                 # Project context from Discovery
├── docs/                    # Generated project documents (PRD, TRD, ADRs)
└── logs/                    # Runtime telemetry (events.jsonl + frozen legacy history)
```
