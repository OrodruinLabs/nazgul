# Configuration

## Flags for `/nazgul:start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
- `--task-pr` — (with `--yolo`) Create stacked per-task PRs targeting the feature branch instead of a single PR at completion
- `--continue` — Explicit resume (backward compat — bare `/nazgul:start` auto-detects this)
- `--parallel` — Opt into stop-hook parallel batch dispatch on top of the same sequential loop (default: sequential); composes with any mode flag, e.g. `--parallel --afk`. `--conductor` is a deprecated alias for `--parallel`.
- `--stack` / `--no-stack` — Opt into (or explicitly out of) stacked-PR continuation: the next objective branches off the current unmerged tip and its PR stacks on top. Three-state — `--stack` persists `execution.stacking.enabled=true`, `--no-stack` persists `false`, and omitting both leaves the persisted value untouched so a prior objective's choice survives a resume. Orthogonal to mode and to `--parallel`. See **Stacked-PR Continuation** below.

## Viewing & Changing Settings

```bash
/nazgul:config               # Interactive settings menu
/nazgul:config models        # Jump straight to model settings
```

### Model Routing

Different pipeline stages have different complexity needs. Assign the right model to each stage:

| Stage | Default | Why |
|-------|---------|-----|
| Planning | Opus | Decomposition and dependency ordering need deep reasoning |
| Discovery | Sonnet | Codebase scanning is pattern matching |
| Docs | Sonnet | Technical writing is well within Sonnet's capability |
| Review (default reviewer) | Haiku | Mechanical reviewers (code, qa) run checklists cheaply |
| Review (orchestrator) | Sonnet | The review-gate orchestrator coordinates the board |
| Implementation | Sonnet | Code generation is Sonnet's sweet spot |
| Specialists | Sonnet | Same as implementation |
| Post-loop | Sonnet | Changelog and docs updates need judgment |

Three presets are available: **Balanced** (default), **Quality** (all Opus), and **Fast/cheap** (Haiku where possible). Or pick per stage.

**Review tiers — two keys, with a legacy fallback.** The single `models.review` tier is now split into two keys:

- `models.review_default` (default `haiku`) — the default per-reviewer tier for the mechanical code/qa reviewers.
- `models.review_orchestrator` (default `sonnet`) — the review-gate orchestrator tier.

Both resolve with the exact fallback order **new key → legacy `models.review` → hardcoded default** (`review_orchestrator` falls back to `sonnet`, `review_default` to `haiku`). A config still carrying only `models.review` is therefore honored unchanged — it seeds both new keys — so no manual migration is needed.

`models.review_by_reviewer` overrides `models.review_default` (and legacy `models.review`) per reviewer name. The default pins the two judgment reviewers to Sonnet even when `models.review_default` is a cheaper tier:

```json
{
  "models": {
    "review_default": "haiku",
    "review_orchestrator": "sonnet",
    "review_by_reviewer": {
      "security-reviewer": "sonnet",
      "architect-reviewer": "sonnet"
    }
  }
}
```

`security-reviewer` guards the BLOCKED gate and `architect-reviewer` guards the state machine — both need deeper reasoning than the mechanical code/qa reviewers. Add other reviewer names to the map to override their model individually; any reviewer not listed falls back to `models.review_default` (then legacy `models.review`, then `haiku`).

### Review Granularity

`review_gate.granularity` controls how often the review board runs and what diff it reviews. Set it via `/nazgul:config` → "Review granularity", or edit `nazgul/config.json` directly.

| Value | When the review board fires | Review scope |
|-------|-----------------------------|--------------|
| `task` (default) | The moment each task reaches IMPLEMENTED | That single task's diff |
| `group` | Once per planner-defined parallel wave/group, after every task in the group is IMPLEMENTED | The group's combined diff (union of its tasks' commits) |
| `feature` | Once, after ALL feature tasks are IMPLEMENTED | The cumulative feature diff `base..HEAD` |

`task` is the default so existing projects are unchanged. In `group`/`feature` mode, tasks are advanced to IMPLEMENTED and **parked** ("awaiting aggregate review") until the whole unit is built; the loop keeps implementing the rest of the unit instead of reviewing each task. Recovery after a compaction reads the "awaiting aggregate review" marker from `plan.md` / the latest checkpoint, so parked tasks are never re-reviewed or re-implemented.

A single shared resolver, `resolve_review_unit()` (`scripts/lib/review-evidence.sh`), maps a task to the review directory its evidence lives in — `task_id` unchanged in `task` granularity, or the task's `GROUP-<n>`/`FEATURE-<feat_id>` in `group`/`feature` granularity — so `task-state-guard.sh`'s IN_REVIEW/DONE checks and the stop-hook's aggregate-review bookkeeping always agree on which directory to look in. Every `reviewer_verdict` event also carries this value in its own `review_unit` field, computed the same way at emit time rather than self-reported by the dispatching agent; the `SubagentStop` review-coverage detector (`nazgul/logs/review-coverage.jsonl`) reads `review_unit` directly off the event as ground truth, falling back to calling the resolver itself only for older events recorded before the field existed. The emit step additionally cross-checks each covered task's resolved unit against the dispatched unit and skips (logging the mismatch) any task that resolves elsewhere, so a coverage event is only ever emitted for a review directory that actually holds that task's evidence.

The other review settings apply identically in all modes:

- `require_all_approve` — **informational only, not read by any script.** The effective policy is hard-coded in `scripts/lib/review-evidence.sh`: every non-skipped reviewer must APPROVE before the unit passes (with `review_gate.conditional_dispatch`, "non-skipped" excludes reviewers carrying an authorized `verdict: SKIPPED` stub). This key documents that policy for humans; changing it has no effect.
- `confidence_threshold` (default 80) — findings below this become non-blocking CONCERNs.
- `block_on_security_reject` — a security REJECT blocks (in AFK mode → BLOCKED for human review).
- `max_retries_per_task` — interpreted **per review unit** (task / group / feature). In group/feature mode it counts retries of the whole unit's review cycle.

In `group`/`feature` mode a CHANGES_REQUESTED re-opens **only the implicated tasks** — the feedback aggregator attributes each finding to the owning task by file scope, so tasks with no findings stay IMPLEMENTED.

### Review Provenance

`review_gate.require_provenance` (default `true`) gates task completion on evidence that the review board actually ran against the current diff. Before spawning reviewers, review-gate writes a diff-bound dispatch manifest (`nazgul/reviews/<unit>/.dispatch.json`) and stamps a matching `review_token:` into each reviewer's persisted file. The stop-hook DONE gate rejects completions that never ran the review-gate code path (no manifest) or whose review is stale against HEAD, routing violations through the existing bounded reset→IMPLEMENTED→BLOCKED escalation.

This is **tamper-evidence and diff-staleness detection, not authentication** — the verifier and the orchestrator share the filesystem, and the token scheme is public. It catches the common accidental cases (board skipped, code changed after approval), not a malicious actor. Set to `false` to disable the gate and degrade to the legacy shape-only check.

### Conditional Review Dispatch

`review_gate.conditional_dispatch` (default `false`) opts into diff-aware reviewer selection: a deterministic helper (`scripts/lib/reviewer-selection.sh select`, not LLM judgment) skips reviewers whose domain the changed files don't touch — `security-reviewer` always runs; `architect-reviewer` only when the scope touches `skills/`, `agents/`, `scripts/`, `hooks/`, or the config schema; `qa-reviewer` only when `tests/` changed; `code-reviewer` on any non-doc change. Any ambiguity falls back to the full board. Skipped reviewers get a `[reviewer].md` stub with `verdict: SKIPPED` and a reason, which the evidence gate treats as gate-satisfying (a missing or unapproved file still hard-fails). Defaults off, mirroring `review_gate.simplify_before_review`.

### Reviewer Stall Retry Tier Escalation

`review_gate.stall_retry_escalate_tier` (default `true`, config schema v29) controls what happens when a dispatched reviewer stalls or returns an unparseable verdict. Its bounded one-shot retry (`scripts/lib/reviewer-tier.sh` `resolve_retry_model`) normally moves the retry up one model tier (e.g. `haiku` → `sonnet`) instead of re-dispatching on the same tier that just failed. Set this to `false` to keep the retry on the same tier as the original dispatch (the pre-v29 behavior). Reviewer dispatch itself is synchronous by construction — every reviewer's Agent-tool call in review-gate's dispatch message is a single foreground, blocking call the orchestrator waits on, never treated as still running in the background.

### Receipt-Hash Enforcement

`review_gate.receipt_hash_enforcement` (config schema v30) is a kill switch for a receipt-hash content check (`RECEIPT_MISMATCH <reviewer>`, alongside the existing `MISSING`/`UNAPPROVED` problem lines) in `scripts/lib/review-evidence.sh`'s DONE-gate evidence validation, which compares each approving reviewer's persisted verdict file against an independently captured receipt that `scripts/subagent-stop.sh` writes to `nazgul/logs/review-receipts.jsonl` when that reviewer's subagent turn ends — outside review-gate's own dispatch turn, so a rewritten verdict can't retroactively alter the receipt it's checked against. The check is **opt-in, default `false`** — the template (`templates/config.json`), the `migrate_29_to_30` migration, and the gate's own absent-key read in `validate_review_evidence()` all agree on the off default; enforcement activates only on an explicit `true`. When enabled, reconstruction tolerates the two sanctioned review-gate edit shapes before comparing — a top-of-file resolution-note verdict flip and a trailing orchestrator note — so an ordinary Step 3/3.6/3.75 resolution doesn't false-trip a mismatch. As with Review Provenance above, this is **tamper-evidence, not tamper-authentication**: review-gate has ordinary filesystem access to `nazgul/logs/` and nothing here cryptographically prevents it from suppressing or forging a receipt outright; what the check guarantees is that a receipt, once genuinely captured, can't be made to match arbitrary rewritten content.

## Execution Engine

There is one engine — the stop-hook loop is the only driver of an objective. `execution.parallel` (opt-in via `/nazgul:start --parallel`; `--conductor` is a deprecated alias) layers concurrent batch dispatch on top of the same sequential loop instead of switching to a separate engine: when `review_gate.granularity` is `"task"` and a wave in `nazgul/plan.md`'s `## Wave Groups` section has 2+ READY tasks whose dependencies are all DONE and whose file scopes are disjoint, the stop-hook's `compute_dispatch_batch` (`scripts/lib/parallel-batch.sh`) dispatches them together instead of one at a time, reusing the same Review Board per task. Sequential and parallel dispatch share the same Planner output, task state machine, and review gate — the option only changes how many tasks start at once, not what "done" means.

| Key | Default | Meaning |
|-----|---------|---------|
| `execution.parallel` | `false` | Opt into stop-hook parallel batch dispatch (set by `--parallel`/`--conductor`). |
| `execution.max_parallel` | `3` | Maximum units dispatched concurrently within a wave. |

The `execution.gates` block pauses for human approval at wave-execution checkpoints, autonomous-first (all default `false`):

| Key | Default | Meaning |
|-----|---------|---------|
| `execution.gates.approve_plan` | `false` | Pause for human approval of the computed task/wave plan before dispatch. |
| `execution.gates.approve_batch` | `false` | Pause for human approval before dispatching each parallel batch. |
| `execution.gates.approve_final_pr` | `false` | Pause for human approval before opening the final PR. |

In `--hitl` mode, `scripts/lib/parallel-batch.sh`'s `execution_gate_effective` forces the *effective* `approve_plan` gate to `true` regardless of the stored value — the stored config default stays `false`. Every other gate always equals its stored value in every mode.

The `execution.enforce` block toggles the mechanical guards that back parallel dispatch, all default `true`:

| Key | Default | Meaning |
|-----|---------|---------|
| `execution.enforce.dispatch_guard` | `true` | `scripts/parallel-dispatch-guard.sh` (PreToolUse/Agent) blocks re-dispatch of a parallel unit that already committed. |
| `execution.enforce.rework_guard` | `true` | `scripts/parallel-rework-guard.sh` (PreToolUse/Write,Edit,MultiEdit) blocks re-editing a committed parallel unit's file scope. |
| `execution.enforce.premerge_guard` | `true` | Git-level `pre-merge-commit` hook (`scripts/git-hooks/pre-merge-commit`) blocks merging a parallel unit without an approved review verdict. |
| `execution.enforce.teammate_report_guard` | `true` | `scripts/teammate-idle-guard.sh` (TeammateIdle) blocks a dispatched teammate from going idle without writing its expected report file. |

## Stacked-PR Continuation

`execution.stacking` configures an opt-in, **default-off** continuation policy (FEAT-027, ADR-018): with it enabled, objective N+1 branches off objective N's still-unmerged tip and its PR stacks on top via the official `gh-stack` CLI extension (`gh extension install github/gh-stack`), instead of the loop opening a PR to `main` and idling until a human merges it. **Stacking changes when work starts, never what "done" means** — one objective is still one PR, and the task state machine, review board, and per-objective release flow are untouched. GitHub owns all retarget/rebase/merge mechanics server-side; Nazgul owns only the `stack.layers[]` registry and the policy gates (cap, rework priority, fail-closed on missing tooling). There is no hand-rolled `rebase --onto` anywhere in the implementation, by doctrine — see RULES.md §20.

**One behavior change lands for ALL users, opt-in or not** (see the hazard fix below).

| Key | Default | Meaning |
|-----|---------|---------|
| `execution.stacking.enabled` | `false` | Master switch, and the kill switch. Set by `--stack`/`--no-stack`. `false` means every stacking entry point (`stack_available` → `"disabled"`) behaves exactly as the loop did before, with a plain `gh pr create` at objective end. |
| `execution.stacking.max_unmerged` | `3` | Cap on `state:"open"` layers. At or over the cap, a new objective does not auto-start — the heartbeat records `decision: skipped, reason: stack_cap_reached` and `/nazgul:start`'s continuation gate stops with the count, the cap, and the remediation. A `stack-rework` pick is never blocked by the cap (fixing an open layer does not add one). |
| `execution.stacking.rework_priority` | `1` | `priority` written into an auto-filed `stack-rework` inbox item. `heartbeat_pick`'s existing numeric-ascending sort makes `1` outrank the rest of the corpus (all ≥2), so rework is picked before new work. |

Five further `execution.stacking.*` keys are **written at runtime by `scripts/lib/stack-utils.sh`**, not by the template or the migration — they are absent from a fresh config and appear only after the condition they record occurs. Operators read them (and clear `halted` by hand); nothing else writes them:

| Runtime key | Written when | Meaning |
|-------------|--------------|---------|
| `execution.stacking.halted` | A sync conflict/divergence, or 3 consecutive API failures on one operation | `true` makes `stack_available` report `"halted"` (exit 3) — its own fail-closed state, **not** folded into `"missing"`, so a caller can name the halt as the reason it stopped. **Never cleared automatically**; a human clears it (with `halt_reason`) after resolving the underlying problem. Surfaced by `/nazgul:status`, SessionStart, and `/nazgul:doctor`. |
| `execution.stacking.halt_reason` | With `halted` | `"conflict"` or `"api_failures"`. |
| `execution.stacking.api_failures` | On any `gh`/`gh stack` API failure | The **maximum** across `api_failures_by_op`, mirrored here for at-a-glance reads and for configs written before scoping existed. **Zeroed when stacking halts**, so the documented remediation (clear `halted`) does not leave a counter at `3` that re-halts on the very next hiccup. |
| `execution.stacking.api_failures_by_op` | On any `gh`/`gh stack` API failure | Consecutive-failure counter **scoped per operation** (`reconcile`, `detect`), each reset to `0` on that operation's next success (that reset is what makes it *consecutive*). At `3` for one operation it halts stacking with a `stderr` warning naming the operation. Scoping is what makes the halt reachable: one shared counter let a healthy layer reset a broken layer's count forever. A tick bumps each operation at most once, and an operation with no entry yet starts at `0` — it never inherits another operation's count. Mirrors `connectors.github.pull_failures`, except the fail-closed action is a halt rather than an auto-disable. |
| `execution.stacking.needs_sync` | A post-merge `gh stack sync` cascade conflicts or hits the API | `true` records the deferred rebase cascade as debt. `stack_reconcile` retries the cascade on the next ready tick even when nothing newly merged, and clears the marker on a clean sync — an interrupted cascade is never simply forgotten. |

### The `stack.layers[]` registry

`stack.layers` is the runtime registry of stack layers. **It is script-owned: `scripts/lib/stack-utils.sh` is its sole writer** (`stack_register_layer`, `_su_mark_layer_merged`, `_su_advance_base_above`). Operators read it — via `/nazgul:status`, the SessionStart context line, or `jq` — and never hand-edit it; no agent, skill, or hook writes it by convention. One entry per layer:

```json
{
  "stack": {
    "layers": [
      {
        "feat_id": "FEAT-027",
        "branch": "feat/FEAT-027-stacked-pr-continuation",
        "pr": "https://github.com/owner/repo/pull/42",
        "base": "main",
        "state": "open",
        "opened_at": "2026-08-02T18:36:37Z",
        "merged_at": null
      }
    ]
  }
}
```

`pr` is `null` until the layer's PR is opened. `state` is `"open"` or `"merged"`; `merged_at` is set with the flip. Registration is idempotent per `feat_id` — a repeat call updates `branch`/`base`/`pr` in place and preserves `opened_at` rather than appending a duplicate. A layer imported from a remote-only PR (see below) is registered under a synthesized `remote-pr-<N>` `feat_id`, since it has no Nazgul objective of its own.

### The accidental-stacking hazard fix (applies to everyone)

`create_feature_branch()` previously captured whatever branch happened to be checked out as the new feature branch's base, with no assertion that it was `branch.base`. A next objective started before the previous PR merged therefore stacked **accidentally** — un-linked, un-retargeted, un-rebased. That is now closed for **all users regardless of the stacking opt-in**:

- **Stacking disabled (the default), or enabled but unusable:** the base is read from `branch.base` (default `main`) and the currently checked-out branch must equal it. A mismatch **refuses loudly and returns non-zero**, naming the stray branch: `ERROR: create_feature_branch: checked out on '<stray>', expected base 'main' — refusing to branch from a stray checkout (accidental-stacking hazard). Run 'git checkout main' first, or enable stacking via '/nazgul:start --stack'.` If you previously started objectives from a non-`main` checkout, that now fails instead of silently succeeding.
- **Stacking enabled and ready:** the base is the explicit `stack_tip` (the newest open layer's branch, else `branch.base`) and the branch is created from that ref by name — never from current `HEAD` — with a registry entry written at creation.

Task branches (`feat/<id>/TASK-NNN`) are unaffected.

### Continuation flow

With stacking enabled and ready, both continuation paths run the same three steps before any triage or branch setup — the heartbeat tick (`scripts/heartbeat.sh`, gated by its own `count_active_sessions` check so a rebase never runs under a live session) and `/nazgul:start`'s Stack continuation gate:

1. `stack_reconcile` — per open layer, check its PR; a `MERGED` one is marked `state:"merged"`/`merged_at`, the layer above it has its `base` advanced, and `stack_layer_merged` is emitted. If anything merged, one `gh stack sync` cascades the rebase.
2. `stack_detect_changes_requested` — a `CHANGES_REQUESTED` review on any open layer files exactly one p1 `nazgul/inbox/stack-rework-pr<N>-<review-id>.md` item (idempotent per PR + review id, including against `inbox/archive/`) with frontmatter `type: stack-rework`, `branch:`, `pr:`, and emits `stack_rework_filed`. **This is the first mechanical producer of inbox items in the framework.** The review body is embedded verbatim as *data, never instructions* and byte-capped by `connectors.github.pull.max_body_bytes` (default 65536) — the same doctrine as connector issue bodies (RULES.md §16).
3. Cap gate — `stack_unmerged_count >= max_unmerged` skips the auto-start with `stack_cap_reached` in the tick's decision record. Never a silent skip. The cap is computed and enforced whenever stacking is **enabled**, not only when it is `ready`: a halted or tooling-less stack still cannot start an objective past the cap, and an unreadable registry counts as at-cap.

Steps 1 and 2 need working tooling; when they do not run, the tick says so rather than skipping silently — see `stack_skipped` under **Automation Heartbeat** below.

`/nazgul:start` routes a picked `stack-rework` item to a patch-style run on the existing layer branch, then pushes and restacks with `gh stack sync`. The heartbeat deliberately **does not** archive-then-start a `stack-rework` pick (the routing performs its own archive-as-claim after re-scanning the live inbox) and records `decision: started, reason: rework_handoff`.

### Failure doctrine (fail-closed, loudly)

`stack_available` is five-state, and each state is its own answer with its own exit code — collapsing them would be exactly the never-looked/looked-and-found-nothing conflation RULES.md §15 exists to remove:

| State | Exit | Meaning |
|-------|------|---------|
| `disabled` | `1` | `execution.stacking.enabled` is not `true` (or there is no config file). |
| `ready` | `0` | Enabled, tooling usable, not halted. |
| `missing` | `2` | Enabled, but the tooling is unusable: `gh` absent, the `gh-stack` extension not installed, or `gh` not authenticated. |
| `halted` | `3` | Enabled and installed, but a human-clearable halt is set (`execution.stacking.halted`). |
| `invalid` | `4` | The config could not be parsed at all. A corrupt config is **not** "stacking disabled". |

Callers fail closed on everything except `"ready"`; they never silently degrade, and because `halted` and `invalid` are no longer folded into `missing`, every caller can name *which* state stopped it:

- **Objective end with stacking unusable:** `stack_submit` opens the same plain `gh pr create` PR the non-stacking path would, **plus** a stderr line and a loud `stop_gate` event with `reason: stacking_unavailable` and the offending `state`.
- **Sync conflict or divergence:** stacking is halted, a p1 `nazgul/inbox/stack-sync-conflict.md` item is filed, and `stack_sync_conflict` is emitted. **A conflict is never auto-resolved** — resolve it by hand, then clear `execution.stacking.halted`/`halt_reason` (the failure counters were already zeroed by the halt). A halt whose write cannot be verified is fatal-loud and returns non-zero rather than reporting a halt it did not persist.
- **API failure:** the operation's counter in `api_failures_by_op` is bumped (at most once per tick per operation) and `stack_api_failure` is emitted (carrying an independent `gh auth status` probe, because gh-stack can misattribute an auth failure); 3 consecutive failures of one operation halts stacking.
- **Corrupt `stack.layers[]`:** `stack_tip`, `stack_unmerged_count`, `stack_reconcile` and `stack_detect_changes_requested` refuse a malformed registry loudly (stderr + non-zero + `stack_registry_invalid`) instead of failing open to `branch.base`/`0`/a no-op, and the heartbeat's cap gate treats an unreadable registry as at-cap.

### Two gh-stack behaviors that will surprise you

Both were found empirically by ADR-018's probe and contradict the vendor's own documentation. Nazgul's wrapper defeats them by classifying `gh stack`'s **stderr text**, not its exit code — but they still shape what an operator can do by hand:

- **`gh pr merge` is rejected outright for a PR that is part of a stack.** GitHub's GraphQL API returns *"This pull request is part of a stack and must be merged using the asynchronous merge REST API"* (exit 1). This is documented nowhere in gh-stack's README. Merge a layer with `gh stack merge <pr#> --squash --yes` or GitHub's own web-UI merge button. Nazgul never auto-merges anything, so this only bites a human merging a layer manually.
- **`gh stack sync` exits 0 when it aborts on a real divergence.** Non-interactively, a diverged stack prints `⚠ Your local stack has diverged … ℹ Sync aborted — no changes were made` **to stderr and exits 0** — vendor-documented behavior, and the opposite of what an exit-code-driven caller expects. `_su_classify_sync_result` therefore treats that text as a conflict regardless of exit code, and splits exit 3 on stderr text as well (`local stack composition differs from remote` is benign stale tracking after a `link`, not a rebase conflict). One consequence: this classification is coupled to gh-stack v0.1.0's exact message strings, and a future release could reword them.

A third, narrower case: a clean remote-ahead sync leaves the new remote layer **un-imported** locally despite the README's claim, warning only `already contains #<N>, which is not in your local stack`. `stack_reconcile` parses that PR number and runs the explicit `gh stack checkout <N>` itself, then registers the layer (`stack_remote_layer_imported`, or `stack_remote_layer_import_failed` — loud but non-halting, since it is retryable rather than a conflict). This detection is scoped to sync's own warning text and imports one PR per tick, which is narrower than ADR-018's literal "diff the registry against `gh stack view`" wording — deliberately so, because `gh stack view`'s output contract was never empirically verified.

### Visibility

- `/nazgul:status` renders a **Stack** section (enabled, unmerged vs cap, one line per layer with its PR and state, an at/over-cap warning, and a `HALTED:` line). An unreadable config renders the section as unreadable rather than as healthy.
- SessionStart (`scripts/session-context.sh`) injects a one-line stack map — `Stack: N open / cap M | tip: <branch> (PR #N open)` — shown whenever stacking is enabled or any layer exists.
- `/nazgul:doctor` gains two read-only checks: **stacking** (tooling readiness — `gh`, the `gh-stack` extension, `gh auth`, and the halted flag, each named individually) and **stack-registry** (registry-vs-GitHub drift for open layers). Both report `Not applicable` when stacking is disabled, and neither writes state.

Added by the additive `migrate_34_to_35` migration (schema v34→v35); existing projects upgrade automatically with `execution.stacking` default-off and `stack.layers` empty — see Config Upgrades below.

## Automation Heartbeat

`automation.heartbeat` configures an opt-in, default-off tick engine (`scripts/heartbeat.sh`) that triages a local work inbox (`nazgul/inbox/`) and auto-starts the next objective when idle. Fire a tick by hand with `/nazgul:heartbeat`, or point an opt-in Claude Code native scheduled agent (routine) at that skill on your chosen interval — the plugin itself wires no OS cron / `claude -p` scheduling (deferred to FEAT-009).

| Key | Default | Meaning |
|-----|---------|---------|
| `automation.heartbeat.enabled` | `false` | Master switch. `false` means every tick is a `decision: disabled` no-op before any inbox read. |
| `automation.heartbeat.interval` | `"30m"` | Suggested firing interval for the scheduled-agent routine you configure outside the plugin — not enforced by the script itself. |
| `automation.heartbeat.inbox.provider` | `"file"` | Inbox provider behind the `inbox_list`/`inbox_get`/`inbox_archive` seam (`scripts/lib/inbox-provider.sh`). The heartbeat *tick engine* consumes both `"file"` (local dir, default) and `"github"` (the GitHub connector — see **Connectors** below); a labelled remote issue is pulled, triaged, claimed, and auto-started like a local candidate. A genuinely unknown value fails closed — the tick logs `decision: skipped, reason: unsupported_provider:<value>` and exits without touching the inbox, rather than silently falling back to the file provider. With `provider="github"` but the connector disabled (`connectors.github.enabled=false`) or unhealthy, the seam degrades to a safe empty list, so the tick simply finds `nothing_actionable` — it does **not** fall back to the local `file` inbox. |
| `automation.heartbeat.inbox.dir` | `"nazgul/inbox"` | Directory scanned for `.md`/`.json` candidates; claimed candidates move to `<dir>/archive/`. |
| `automation.heartbeat.auto_start.mode` | `"yolo"` | Mode passed to `/nazgul:start` when a candidate is picked and no session is active. |
| `automation.heartbeat.auto_start.parallel` | `true` | Whether the auto-started `/nazgul:start` invocation passes `--parallel`. An explicit `false` opt-out is honored (the tick never silently overrides it). Replaced `auto_start.engine` in the v25→v26 collapse. |
| `automation.heartbeat.lock_stale_seconds` | `300` | Staleness threshold (seconds) for the atomic `mkdir`-based claim-lock directory (`nazgul/.heartbeat.lock`) a tick holds for its whole run. A lock older than this is reclaimed only when its recorded owner pid is provably dead (`kill -0` fails, or no pid file survives) — a live tick legitimately running longer than the threshold keeps its lock. Recovers from a crashed tick without waiting on `session-tracker.sh`'s much longer 7200s staleness window. Added by `migrate_27_to_28` (schema v27→v28). |

Concurrency is guarded twice: `heartbeat.sh` `mkdir`-claims the lock directory as its very first action
(before even `count_active_sessions`), releasing it via `trap ... EXIT`, so two overlapping ticks race on
the atomic `mkdir` itself rather than a stale `ls` read — `count_active_sessions` stays a secondary,
defense-in-depth check. Two unconditional hard stops (a `BLOCKED` task, a non-`APPROVE` security-reviewer verdict) halt every tick regardless of `enabled` or `mode` — see RULES.md §13. The session-tracker concurrency guard (`scripts/lib/session-tracker.sh`) refuses to auto-start over an active session, and the picked candidate is archived before `/nazgul:start` is invoked (atomic claim-then-archive, never double-started). Every tick appends one decision record to `nazgul/logs/heartbeat-<date>.jsonl`, surfaced via `/nazgul:log`.

Each record also carries a `stack_skipped` field (FEAT-027): `null` when the stack pre-steps ran, or when stacking is simply disabled; otherwise the named reason they did not — `stack_halted`, `stack_tooling_missing`, `stack_config_invalid`, `stack_not_ready:<state>`, `stack_active_session`, `stack_skipped_session_ambiguity`, `stack_registry_unreadable`, `stack_reconcile_failed`, or `stack_detect_failed`. A pre-step that skips silently is indistinguishable from one that had nothing to do, which is how the unattended half of stacking could be dead in production with every log line still looking normal (RULES.md §1 rule 2, §5).

Added by the additive `migrate_20_to_21` migration (schema v20→v21); existing projects upgrade automatically — see Config Upgrades below.

## Lean Comments Guard

`scripts/lean-comments-guard.sh` is a deterministic PreToolUse guard (on `Write`/`Edit`/`MultiEdit`) that **blocks comment bloat at write time**, so verbose comments can't reach the review board and get auto-approved as a low-confidence CONCERN. The code reviewer also treats the same violations as always-blocking. The implementer and simplifier run it as a pre-commit-style check: `scripts/lean-comments-guard.sh --check <files>`.

It inspects source files (C#, TS/JS, Python, and other `//`/`#` languages — shell and config formats are intentionally exempt) and blocks when a change introduces:

- a run of 3+ consecutive line comments that is not a license header;
- a `<remarks>`/multi-paragraph doc block on a private/internal/protected or test member;
- a banner/separator comment (`// ── Helpers ──────`, `// =======`);
- a comment that restates or narrates the next line of code.

Full XML/JSDoc/docstring on PUBLIC interface members is expected (`<inheritdoc/>` on implementations), and a single short comment explaining a non-obvious domain/venue quirk is allowed.

| Key | Default | Meaning |
|-----|---------|---------|
| `guards.lean_comments` | `true` | Master switch. Set to `false` to opt out entirely (the guard becomes a no-op). |
| `guards.max_consecutive_comment_lines` | `2` | Longest run of line comments allowed before it's flagged as bloat. |

## Bounded Subagent Resume

`guards.subagent_resume` (default `true`, config schema v32) is the kill switch for a bounded in-hook auto-resume in `scripts/subagent-stop.sh`: on every `SubagentStop` event, the hook reads the completing subagent's own transcript and detects two empty-return shapes — no final assistant text at all (`empty_final_text`), or, for a reviewer agent, final text with no fenced `verdict: APPROVE|CHANGES_REQUESTED|UNVERIFIED` line (`no_verdict_line`). Reviewer `maxTurns` was raised 12→30 (`agents/templates/reviewer-base.md`) alongside this gate, since a starved turn budget was one contributing cause of the empty returns it detects.

When enabled and a cap is not yet exhausted, the hook responds with a decision-block JSON payload (`{"decision":"block","reason":...}`, `exit 2`) that has the harness re-run the SAME subagent with a directive to reply immediately with its final deliverable — no marker file, no orchestrator re-dispatch. The resume is bounded on two independent axes: a hard cap of 2 attempts per dispatch (tracked in a small counter file under `nazgul/logs/.resume-attempts/`, keyed by the dispatch's `agent_id` or, failing that, `session_id:agent`), and the harness's own `stop_hook_active` re-entry flag, which the hook treats as "never block again on this turn" regardless of remaining cap headroom.

Every detected empty-return emits exactly one `subagent_empty_return` event (see Event Types above) whose `action` field records the outcome — `resumed`, `exhausted` (cap reached), or `detected_only` (kill-switch off, or the resume path itself degraded on error, e.g. an unwritable attempts directory). The mechanism is fail-open by construction: any failure in the resume path falls back to detection-only rather than either silently passing or blocking indefinitely.

Added by the additive `migrate_31_to_32` migration (schema v31→v32); existing projects upgrade automatically with `guards.subagent_resume` default `true` — see Config Upgrades below.

## In-Flight Dispatch Hold

`guards.in_flight_hold` (default `true`, config schema v34) lets the stop-hook take an ALLOWED, uncounted
stop instead of burning an iteration when the work it just dispatched is still running. `PreToolUse(Agent)`
writes a marker (`scripts/in-flight-marker.sh`, one file per dispatch under `nazgul/in-flight/`, never
blocking — a failed write is a silent no-op); `SubagentStop` clears the marker matching the completing
subagent's unit; a derived-but-unmatched unit clears nothing (`clear_skipped_no_match`), and an underivable
unit clears the newest agent match (`clear_fallback_underivable`) — see `scripts/subagent-stop.sh`; and
`stop-hook.sh` checks for a fresh marker right before the iteration increment. A fresh marker whose
recorded dispatch class is provably background (`background: "true"` captured at write time from
`tool_input.run_in_background`, and not a named/teammate-shaped dispatch) allows the stop
(`exit 0`), leaves `current_iteration` and `safety.consecutive_failures` untouched, and
emits one `stop_gate` event with `reason: "in_flight_hold"` — for that class the wake-up genuinely
is the harness's own task-notification when the dispatched agent finishes. A fresh marker that is
NOT provably background (`"false"`, `"missing"` — including every pre-upgrade marker — or a named
dispatch) is not provably awaited work, so no resume can be relied on and the loop continues NORMALLY
instead of holding. What happens to the MARKER then splits by how much was actually known, and the
two halves must not be collapsed. When the class was PROVEN (`background: "false"`, or a named
dispatch whose report contract owns it) the marker is residue — a synchronous dispatch cannot span a
Stop — so it is moved to `nazgul/in-flight/quarantine/` (evidence preserved, re-fire stopped) and a
`stop_gate` event is emitted with `reason: "in_flight_orphan"`. When the class was NOT OBSERVABLE at
all (`"missing"`) the event is `reason: "in_flight_unverifiable"` and the marker is **left in place,
not quarantined**: `mv` is irreversible, the dispatch it names may still be running, and destroying it
would foreclose the reconciliation #218 is built on — the SessionStart sweep is the bounded backstop
that eventually retires it. Either way the iteration that follows is
a productive iteration, not a burned one. This closes the 2026-08-04 incident class (#104 Gap 3):
an 8-hour sleep on a foreground marker whose completion had already fired. Without this gate,
a session could otherwise burn an iteration on every ~15-second re-invocation while dispatched work was
still running, until a soft limit (or the harness's own `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`) force-ended
the turn from outside the loop's own control.

A fresh marker whose `background` field is `"missing"` records that the dispatch class was **not observable
at write time** — it does not record a foreground dispatch. Claude Code omits the Agent tool's
`run_in_background` parameter from the exposed schema in fork mode (the interactive default since v2.1.232)
and under `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, and absence means the **opposite** thing in those two
configurations: background in the first, foreground in the second. In the session type this loop runs in,
absence therefore means the dispatch is most likely **background**, so quarantining it is a cost-weighed
default that is usually wrong about the dispatch it names. On such a host the class-aware hold never
engages, `stop_gate` `reason: "in_flight_unverifiable"` fires on essentially every dispatch, and the loop
continues concurrently with live subagents. That was the whole of the defect #218 named, and
**FEAT-033 closes it** — the Stop-payload path described below is the fix #218 asked for, and it
ships here. The authoritative signals existed one event later: `PostToolUse` `tool_response.status` (`async_launched` vs `completed`)
and the `background_tasks[]` array on `Stop`/`SubagentStop`. Both are present in the shipped hook
schema as of Claude Code 2.1.238 and were **empirically captured 2026-08-21** — real `Stop` and
`SubagentStop` payloads from two sessions, kept as `tests/fixtures/stop-payload/` — but neither is in
the PUBLIC hook reference, which lists only `last_assistant_message` and `effort` for `Stop`. The
shipped schema is a strict SUPERSET of the published one, so this rests on observation rather than on
documentation, and the field can change without a deprecation notice. Since FEAT-033 the stop-hook
READS `background_tasks[]` at `Stop`: a live subagent for this session takes the hold even when every
marker records `background: "missing"`, so the "never engages" sentence above now describes only the
case where the payload carries no such field.

Liveness does not reach a marker whose own recorded class already disposes of it: a
`background: "false"` marker is quarantined on a live tick exactly as on any other, because no other
dispatch's liveness makes a synchronous one able to span a Stop. A NAMED marker on a live tick is
held, not quarantined — its proof is contractual rather than mechanical, and a named dispatch can be
background and running. The consequence is worth stating on its own, because it is what the hold's
record shows an operator: the hold's `units` field never names a `background: "false"` marker.

`tool_response.status` is still unread, and that is the deliberate, explicitly out-of-scope
remainder rather than an unfixed piece of #218 — it is a second, corroborating signal for the same
question the Stop payload now answers, so reading it would not change any disposition this hook
takes. `reason: "in_flight_orphan"` is reserved for `background: "false"` or a named dispatch,
which are genuinely proven.

**A third disposition — `in_flight_orphan_candidate`, DETECT-ONLY.** The `yes` observation splits into two independent counts (ADR-027 Q2): `LIVE` (`type=="subagent"` with an allowlisted `running`/`pending` status) gates the HOLD above; `SUBAGENT_PRESENT` (`type=="subagent"`, status-blind) gates this arm. When `SUBAGENT_PRESENT == 0` — the payload was read and reports no subagent of any status for this session — the marker is neither held on nor quarantined: `stop_gate` `reason: "in_flight_orphan_candidate"` (`evidence: "background_tasks_empty"`) records the observation and the marker is **left in place**, deliberately NOT `in_flight_orphan`, which names a class that was PROVEN and really was moved (`skills/status/SKILL.md`). An unrecognised status (neither `running`/`pending` nor absent) produces **neither a hold nor a candidate** — but "neither" is a claim about the two DISPOSITIONS and never about the counts, since such an entry still increments the status-blind `SUBAGENT_PRESENT`. That is what makes present-but-not-live a third STATE rather than an absence, and it has its own record: `stop_gate` `reason: "in_flight_present_not_live"` (fields `unit`/`agent`/`subagents_present`/`live`/`statuses`) plus a stderr line, so the marker is preserved and the iteration proceeds while the arm still shows that a mechanism looked. It earns the "looked and could not tell" comparison with `in_flight_stale` below only because that reason exists; before it, the arm emitted nothing at all and the comparison was false. The `mv` for this arm stays deferred until ADR-027's numeric bar — **≥20 `in_flight_orphan_candidate` events across ≥2 objectives, zero cases where a later `subagent_stop` shows the candidate's agent+unit still running** — is met.

A marker older than `guards.in_flight_stale_minutes` (default `30`, floored to `>=1`) is NOT held on — the
stop proceeds normally (iteration increments) — but the staleness is surfaced loudly: a stderr line plus a
`stop_gate` event with `reason: "in_flight_stale"` naming the unit and its age, so a crashed subagent shows
up in telemetry instead of silently vanishing. Stale markers are left on disk rather than deleted, so the
retention itself doesn't hide the incident from the next tick's diagnostics.

**Release gate — one SUPERVISED objective before any unattended run.** FEAT-033 (#218) makes the hold
REACHABLE on a host class where it previously never engaged: the `Stop` payload's `background_tasks[]`
can now take a hold that the write-time class alone never took here. The first release carrying that
reachable hold must be exercised for **one supervised objective before any AFK or overnight run**. The
reason is R2: the wake path a hold depends on — the harness's own task-notification resuming this
session — is documented and believed, but has never been OBSERVED re-engaging a fork-mode session
(`docs/DECISION-LOG-2026-08-16-cross-session-messaging.md` D-005, still an owed probe). A hold that is
never woken is a stalled run, and a supervised objective is how that gets caught by a human in minutes
rather than by an overnight silence. The bounded hold budget (`_IN_FLIGHT_HOLD_CAP = 1` in
`scripts/stop-hook.sh`: one hold per unchanged marker set, ledgered under
`nazgul/logs/.in-flight-holds/`, then `stop_gate reason: "in_flight_hold_budget_exhausted"`) is a valve
that caps the compound failure at one stop — it is not a substitute for the supervised run, and it
cannot rescue a wake that never fires at all, because `exit 0` gives up control and the bound is only
read at a Stop that never comes.

The immediate revert is `guards.in_flight_hold: false`, and it is worth being blunt about what that
turns off: it is a **full-subsystem** switch, not a hold switch. With it `false`,
`scripts/in-flight-marker.sh` stops WRITING markers (`:36-37`) and the SessionStart sweep stops running
(`scripts/session-context.sh:77-79`), so there is no marker to hold on, none to quarantine, and no
sweep to retire one. That is deliberate — a guard that disables a subsystem must disable its producer
too, or the writer keeps producing markers with no retirement path. Note also that this repository's
own `nazgul/config.json` currently sets `guards.in_flight_hold: false` while the template default is
`true`, so running the supervised objective here takes a deliberate operator flip: an operator act, not
a code change.

| Key | Default | Meaning |
|-----|---------|---------|
| `guards.in_flight_hold` | `true` | Master switch for the whole subsystem, not just the hold. `false` stops the marker WRITER (`scripts/in-flight-marker.sh:36-37`) and the SessionStart sweep (`scripts/session-context.sh:77-79`) as well as the stop on a marker's account; `SubagentStop`'s clear stays live and harmless. |
| `guards.in_flight_stale_minutes` | `30` | Age past which a marker is ignored (hold not taken) and reported as stale rather than fresh. |

Added by the additive `migrate_33_to_34` migration (schema v33→v34, chained after `migrate_32_to_33` below);
existing projects upgrade automatically — see Config Upgrades below. See RULES.md §1 (the no-bare-`exit 0`
rule) and ADR-015.

## Environment Variables (NOT `config.json` fields)

The switches below are **environment variables**, not configuration keys. They are deliberately
absent from `nazgul/config.json` and from `templates/config.json`, nothing reads them from a config
file, and adding one does **not** move `schema_version` — they are per-invocation debugging aids an
operator turns on for a single run, not project state worth migrating. These four are the
debug/capture switches; other `NAZGUL_*` variables exist (notification and staging disables, for
example) and are documented in their own script headers.

| Environment variable | Default | Effect |
|---|---|---|
| `NAZGUL_STOP_PAYLOAD_CAPTURE` | unset | `1` makes `scripts/stop-hook.sh` write the raw Stop payload to `nazgul/logs/stop-payload-last.json` |
| `NAZGUL_HOOK_STDIN_TIMEOUT` | `2` | Seconds bounding the shared hook-stdin read (`scripts/lib/hook-stdin.sh`). Validated at source, not trusted: a non-numeric or non-positive value prints a stderr notice and falls back to `2`, because `read -t` would otherwise abort with the payload empty and the miss would read as `why:"no_stdin"` — a misconfiguration wearing an observation's name. The unprefixed `HOOK_STDIN_TIMEOUT` is NOT honoured; there is no shim, by design |
| `NAZGUL_NOTIFY_DEBUG` | `0` | `1` makes `scripts/notify.sh` log its decisions to stderr |
| `NAZGUL_STAGING_DEBUG` | `0` | `1` makes `scripts/session-staging.sh` log its decisions to stderr |

### `NAZGUL_STOP_PAYLOAD_CAPTURE`

The Stop payload is the one place the dispatch class of in-flight work is observable (#218), so the
loop emits a bounded, structured `stop_payload_observed` event for it on every Stop it processes:
`bg_seen`, the closed seven-member `why` above, `entries`/`subagents`/`live` counts, and the distinct
`types`/`statuses` seen. It is emitted above the `guards.in_flight_hold` kill switch — the
measurement accumulates with the subsystem off — but BELOW the `paused` gate, which returns first, so
a paused loop records nothing and a gap in these events is not by itself evidence about the host.
That event carries no paths and no message text, and it is what `/nazgul:doctor`'s `stop-payload`
note reads. The note reports **field present**, **field absent**, **field present but wrong shape**
or **never observed**, and otherwise SKIPS with the reason it could not tell — the telemetry bus is
off, the record is present but unselectable, or the payload itself did not arrive intact — because
"looked and found none" and "could not look" are different answers.

Set `NAZGUL_STOP_PAYLOAD_CAPTURE=1` when the structured event is not enough to explain a
classification and you need the payload verbatim:

```bash
NAZGUL_STOP_PAYLOAD_CAPTURE=1 claude
cat nazgul/logs/stop-payload-last.json
```

- **A single overwritten file, never appended.** Each Stop replaces it, so it cannot grow without
  bound and it always answers exactly one question: what the LAST Stop delivered.
- **Never written while the variable is unset, and never written unconditionally.** The raw payload
  carries `cwd`, `transcript_path`, `agent_transcript_path` and `last_assistant_message` — which is
  exactly why the always-on event is bounded and structured and this capture is opt-in.
- Written even when the payload is empty, so "capture on, nothing arrived" stays distinguishable
  from "capture off".
- It is a debugging artifact, not project state: if your project tracks `nazgul/`, exclude this file
  before committing.

## Red-Run Evidence Gate

`guards.red_run_evidence` (default `true`, config schema v36) is the kill switch for the red-run
evidence check that `scripts/lib/task-transition-guard.sh` adds to the IMPLEMENTED gate. A task whose
file scope touches `scripts/**` or `tests/**` must carry a `## Red-Run Evidence` section in its manifest
recording that its tests were actually run against the pre-change tree and **failed** there — a test that
passes without the change under test is evidence of nothing. Capture it mechanically with
`scripts/red-run.sh <TASK-ID> --filter=<scoped>`, never by hand: the script builds a detached worktree at
the manifest's Base SHA, copies the task's changed `tests/` files in, runs the scoped filter, and writes
the block itself.

The check's dispositions mirror the `## Commits` gate's shape — the section heading is the enforcement
boundary, and "looked and found none" is kept distinct from "never looked":

| Manifest state | Outcome |
|---|---|
| Section absent, scope touches `scripts/**` or `tests/**` | **BLOCK** (`absent`) |
| Section absent, scope touches neither | ALLOW, and the skipped check is announced on stderr (`not_applicable`) |
| Section present with no parseable `red-run:` entry | **BLOCK** as corrupt (`corrupt`) — present-but-unreadable is a stronger trouble signal than absent |
| Entry present but its test path or `pre-change-ref` is unresolvable, not an ancestor, or records exit 0 | **BLOCK** (`ref_unresolvable` / `not_ancestor` / `exit_zero`) — the evidence claims something git can refute |
| `red-run: N/A — <token>` with `<token>` in the closed list `docs-only`, `comment-only`, `revert`, `fixture-capture-only` | ALLOW, recorded (`enumerated_na`) |
| `red-run: N/A — <free text>` | **BLOCK** (`bad_na_token`) — an open-ended excuse field is an allow-everything field |

| Key | Default | Meaning |
|-----|---------|---------|
| `guards.red_run_evidence` | `true` | Set to `false` to suppress the **block only**. Detection still runs: the stderr diagnostic still names the reason, the `red_run_missing` event is still emitted, and a second stderr line records that the block was suppressed. There is no setting that makes the gate stop looking. |

It ships default-on deliberately. This is an enforcement mechanism, and a default-off enforcement
mechanism reproduces the problem it exists to fix — the objective's whole premise is that a test suite
whose redness was never observed is a count, not evidence (RULES.md §1 rule 4). Existing projects with a
task that predates the gate see one block, resolved by capturing the evidence (or recording an
enumerated `N/A` token) rather than by flipping the switch.

Added by the additive `migrate_35_to_36` migration (schema v35→v36); existing projects upgrade
automatically with `guards.red_run_evidence` default `true`, and an explicit `false` is preserved — see
Config Upgrades below. See RULES.md §1 rule 4 and ADR-019 D1.

## One-Shot Dispatch Primacy (`guards.team_teardown` removed)

FEAT-026/ADR-017 converted every one-shot Nazgul dispatch (discovery, review, implementation, post-loop
verifiers) to an unnamed one-shot `Agent` dispatch and deleted the teardown subsystem that used to remediate
a resulting idle Agent-Teams teammate — a dispatch that never becomes a teammate has nothing to dismiss. The
now-unused `guards.team_teardown` key was removed by the additive `migrate_32_to_33` migration (schema
v32→v33): an explicit non-default value survives under `._deprecated_removed["guards.team_teardown"]`, and
`guards.team_sweep`/`guards.team_sweep_min_age_hours` (below) are untouched.

`guards.team_sweep` (default `true`) is unchanged in mechanism — SessionStart still sweeps dead-session team
state under `~/.claude/teams/`/`~/.claude/tasks/` as a crash-only backstop, logged to
`nazgul/logs/team-sweep.jsonl` — but its current-session exclusion now actually fires: `session-context.sh`
resolves the real session id from the SessionStart payload (falling back to `CLAUDE_SESSION_ID`, then the
persisted `nazgul/.session_id`, then a synthetic `epoch-pid` form) and excludes a team whose `leadSessionId`
matches that id OR whose directory name matches the session's implicit team-name form. When resolution
bottoms out at the synthetic form — no real harness session id was obtainable — the sweep is SKIPPED
entirely rather than run against an unverifiable identity, recording a `skipped`/`unresolved_session_id`
line instead of silently proceeding. `/nazgul:clean --teams`'s direct invocation is unaffected. See RULES.md
§18 and ADR-017.

## Bash-Write Reconciliation

`guards.bash_write_reconciliation` (default `true`) gates a second, detection-only layer behind
`task-state-guard.sh`'s live PreToolUse gate. At the top of every `stop-hook.sh` iteration, it diffs
each task manifest's live status against the status recorded in the previous checkpoint; a change since
then that is not traceable to a guarded transition (logged by `task-state-guard.sh` via
`scripts/lib/task-transition-guard.sh`'s `ttg_log_transition`) means the status was written outside the
guarded Write/Edit/MultiEdit path — e.g. `mv`/`cp` over the manifest — and is flagged `BLOCKED` with a
named diagnostic. It never rewrites a "corrected" status, only blocks. Set to `false` to disable the
pass entirely. Added by the additive `migrate_27_to_28` migration (schema v27→v28); existing projects
upgrade automatically — see Config Upgrades below.

## Comment Quality Gate

`docs.verify_comments` (default `true`) blocks `NAZGUL_COMPLETE` until a post-loop `comment-verifier` agent grades inline source doc-comments (XML `<summary>`, JSDoc, docstrings) across the objective's changed files. Reviewers can already flag comment issues, but only as sub-80 non-blocking concerns; this gate makes templated, restatement, and contradiction defects blocking, mirroring the FEAT-004 doc-accuracy verifier. Bounded to at most 3 backstop retries; on exhaustion it degrades to allow rather than bricking an unattended run. Set to `false` to opt out.

## Post-Loop Learning Gate

When an objective finishes, Nazgul distills recurring mistakes (review rejections, debugger diagnoses, repeated failures) into **candidate** Learned Rules via the `nazgul:learner` agent — it proposes only; you approve them later with `/nazgul:learn`. This step is **mandatory**: `stop-hook.sh` blocks loop completion until the learner has run for the current objective (it records completion by writing the objective id to `nazgul/learning/.distilled`). A bounded attempt counter lets the loop finish with a warning if the marker can't be written, so it can never brick an unattended run.

| Key | Default | Meaning |
|-----|---------|---------|
| `learning.enabled` | `true` | Master switch for the learning subsystem. |
| `learning.auto_distill_post_loop` | `true` | Run (and gate completion on) the learner at objective completion. Set either flag to `false` to opt out — the gate becomes a no-op. |

## Self-Improvement Mode

`self_improvement.{enabled,threshold}` is a distinct, separately-opt-in mechanism from **Self-Audit Gate** below — not a duplicate. This one is the implementer's per-task self-rating gate: after setting a task to IMPLEMENTED, if `self_improvement.enabled` is `true`, the implementer (`agents/implementer.md:149-163`) rates its own experience 0-10 and, if the rating falls below `self_improvement.threshold` (default `7`), files a report via `scripts/file-improvement-report.sh` into `nazgul/improvement-reports/` for `/nazgul:metrics` to aggregate. See `references/self-improvement.md` for the rating rubric and report shape. Self-Audit Gate, by contrast, is a mandatory post-loop pass that mines objective-wide signals (review rejections, retries, blocks, findings) into a durable backlog — the two run at different times, on different triggers, gated by different config keys, and neither substitutes for the other.

| Key | Default | Meaning |
|-----|---------|---------|
| `self_improvement.enabled` | `false` | Master switch. When `false` or absent, the implementer skips the self-rating step silently. |
| `self_improvement.threshold` | `7` | Rating below which a report is filed; ratings at or above the threshold file nothing. |

## Self-Audit Gate

When an objective finishes, a post-loop `self-audit` agent (`agents/self-audit.md`, core `scripts/self-audit.sh`) mines the objective's own signals — review rejections, retries, blocks, best-effort transcript token cost, and any first-party findings raised into `nazgul/logs/findings.jsonl` (see `scripts/lib/raise-finding.sh`) — and appends one structured entry per finding to a durable, append-only backlog. `stop-hook.sh` blocks `NAZGUL_COMPLETE` until the agent writes an objective-scoped `nazgul/logs/.self-audited` marker, with a bounded ≤3-attempt backstop so it can never deadlock an unattended run. The audit core never fails the run: every signal source degrades to a no-op when absent.

| Key | Default | Meaning |
|-----|---------|---------|
| `self_audit.enabled` | `true` | Master switch. Set to `false` and the gate becomes a complete no-op — no marker required, no block. |
| `self_audit.backlog_path` | `nazgul/improvements.md` | Path (relative to the project root, or absolute) of the append-only improvements backlog the audit writes findings to. |

## Telemetry Bus

Nazgul emits structured telemetry to a canonical event stream at `nazgul/logs/events.jsonl`. This replaces the legacy scattered telemetry (iterations.jsonl, subagents.jsonl, budget mutations, dotfiles) with a unified, schema-versioned JSONL record.

### Event Stream Configuration

| Key | Default | Meaning |
|-----|---------|---------|
| `telemetry.bus_enabled` | `true` | Master switch for event emission. Set to `false` to suppress all telemetry writes without modifying hook scripts. |
| `telemetry.record_metered_cost` | `false` | Reserved for future metered token-cost recording (not yet implemented). |

### Event Types

The stream captures:
- **iteration_boundary** — fired when the loop stops after each iteration
- **task_completed** — when the TaskCompleted hook fires
- **reviewer_verdict** — review board decisions (APPROVE, CHANGES_REQUESTED, REJECTED) with confidence scores
- **retry** — when a task is retried after CHANGES_REQUESTED
- **blocked** — when a task or the loop is blocked (git conflict, security reject, max retries)
- **compaction** — context compression checkpoints
- **subagent_stop** — when specialized agents (implementer, discovery, etc.) complete
- **subagent_empty_return** — a completing subagent's transcript carried no usable final text, or (for reviewers) no fenced verdict line; fields `agent`/`unit`/`turns_used`/`max_turns`/`reason` (`empty_final_text`|`no_verdict_line`)/`action` (`resumed`|`exhausted`|`detected_only`) — see Bounded Subagent Resume below
- **stop_failure** — when the loop stop hook itself fails
- **budget_threshold** — proactive warning when spending reaches 50% or 90% of the configured limit
- **objective_complete** — when all tasks finish and the post-loop phase begins
- **stack_layer_merged** — a stack layer's PR was found merged and its registry entry flipped to `state:"merged"`; fields `feat_id`/`branch`/`pr`
- **stack_rework_filed** — a `CHANGES_REQUESTED` review on an open layer produced a new p1 `stack-rework` inbox item; fields `pr`/`review_id`/`feat_id`/`branch`
- **stack_sync_conflict** — `gh stack sync` hit a conflict or a divergence it cannot auto-resolve; stacking is halted and a p1 inbox item filed. Fields `reason`/`exit_code`/`detail`
- **stack_api_failure** — a `gh`/`gh stack` API call failed; fields `stage`/`auth_status` (an independent `gh auth status` probe, since gh-stack can misattribute auth failures) plus the call's own identifiers
- **stack_remote_layer_imported** / **stack_remote_layer_import_failed** — an explicit `gh stack checkout <pr>` of a remote layer that `sync` left un-imported succeeded / failed; fields `pr`/`feat_id`/`branch`, or `pr`/`exit_code`/`detail`
- **red_run_missing** — the IMPLEMENTED red-run evidence check found no usable evidence; fields `task_id` and `reason` (`absent`, `corrupt`, `ref_unresolvable`, `not_ancestor`, `exit_zero`, `bad_na_token`). Emitted whether or not `guards.red_run_evidence` suppressed the block — see Red-Run Evidence Gate above
- **stop_payload_observed** — one bounded, structured record of what the `Stop` payload's `background_tasks[]` contained, emitted once per Stop the hook processes and above the `guards.in_flight_hold` kill switch, so the measurement accumulates even with the whole in-flight subsystem off. Fields: `bg_seen` (`yes`|`unknown`), `entries`/`subagents`/`live` counts, the distinct `types`/`statuses` seen, and — on the `unknown` arm only, so the set stays closed — `why`, whose seven members each assert something different about the payload: `no_stdin` (nothing arrived — stdin was a terminal, closed, or a clean empty EOF), `read_timeout` (the bounded read hit `NAZGUL_HOOK_STDIN_TIMEOUT` having read NOTHING), `read_timeout_partial` (the bound was hit with SOME bytes read, so what the classifier held was truncated by Nazgul's own bound rather than malformed by the producer), `not_json` (bytes arrived but did not parse), `field_absent` (the payload parsed and carried no `background_tasks` key), `field_wrong_type` (the key was there and is not an array — `null` and an id-keyed object both land here, deliberately NOT on `not_json`, because the payload itself arrived intact), and `no_jq` (`jq` is absent, so nothing could be inspected). It is an event TYPE and never a `stop_gate` reason, so a consumer keying on `stop_gate` will not see it and must not read that absence as the observation never having happened
- **stop_gate** — a gate ended or short-circuited an autonomous run rather than exiting silently; `reason` values include `afk_timeout`, `in_flight_hold`, `in_flight_stale` (a marker older than `guards.in_flight_stale_minutes`; also emitted on a LIVE tick carrying `held_over_age: "true"`, where the marker IS held on — #211 forbids a stale bound from DECLINING a hold, never from reporting the possibly-crashed subagent that produced it), `in_flight_orphan_candidate` (the payload was read and reports no subagent of any status; DETECT-ONLY, the marker is left in place), `in_flight_present_not_live` (subagents are present but none positively live — records and does nothing else), `in_flight_hold_budget_exhausted` (a second hold on an UNCHANGED marker set, refused by the `_IN_FLIGHT_HOLD_CAP = 1` valve: the budget worked exactly as designed), `in_flight_hold_unbudgetable` (a mechanism FAILURE, deliberately not the reason above: the Q1 ledger could not be written or could not be keyed to an episode, so the hold could not be BOUNDED, and an unbounded hold is DECLINED rather than taken), `in_flight_orphan` (a provably non-background in-flight marker found at Stop time — `background: "false"`, or a named dispatch whose report contract owns it — so the marker is moved to `nazgul/in-flight/quarantine/` and the loop continues normally; fields `unit`/`agent`/`background`), `in_flight_unverifiable` (dispatch class not observable at write time; fires on every dispatch where `run_in_background` is omitted from the exposed schema — same fields as `in_flight_orphan` but explicitly NOT the same disposition: the marker is LEFT IN PLACE, never quarantined, because the class was never observed, the dispatch may still be running, and `mv` is irreversible — it would also foreclose #218's fix, which reconciles these markers against the Stop payload's `background_tasks[]`. See In-Flight Dispatch Hold above and #218), and `stacking_unavailable` (stacking enabled but the tooling is unusable — the loop fell back to a plain PR). Those ten are the enumeration `agents/doc-verifier.md`'s fence checks against; a reason is never an event name and must not be looked up in the list above
- **in_flight_swept** — the SessionStart sweep quarantined an over-age in-flight marker; fields `source` (`session_start_sweep`), `unit`, and `age_minutes` (a JSON number). Named distinctly from the `stop_gate` reason `in_flight_orphan` ON PURPOSE (PR #223 review #2): `orphan` asserts a PROVEN dispatch class, whereas this sweep only ever proves AGE. Same quarantine directory, different producer, different fields, different claim — a consumer keying only on `stop_gate` misses every SessionStart sweep, and one keying on `in_flight_orphan` must not count these as leaks. Skipped entirely when `guards.in_flight_hold` is `false` or when SessionStart's `source` is `compact` (compaction is not a new session, and sweeping there destroyed a running AFK loop's crashed-subagent evidence)
- **dispatch_guard_background_unverifiable** — `scripts/parallel-dispatch-guard.sh` allowed an unnamed reviewer dispatch whose payload carried no `run_in_background` field at all, because on schemas lacking that field it is unsupplyable (#205); fields `agent`/`caller`
- **clear_skipped_no_match** — a completing subagent cleared no in-flight marker because none matched its unit; fields `agent`/`unit`
- **clear_fallback_underivable** — a completing subagent could not derive its unit, so the OLDEST marker for that agent was cleared as a fallback; fields `agent`/`marker`. Oldest, not newest (PR #223 review #3): newest-first deleted the marker of the dispatch most likely STILL RUNNING, so with two concurrent implementers the first to finish silently stripped the second of its hold. An aged marker needs no help from this fallback — the hold classifies it stale and the SessionStart sweep retires it

See `docs/superpowers/specs/2026-06-24-telemetry-bus-design.md` for the full event schema and payload details.

### Accessing Telemetry

Consumer skills (`/nazgul:metrics`, `/nazgul:log`) automatically read from `events.jsonl`. For projects upgraded from v2.3.0 or earlier, frozen legacy files (`iterations.jsonl`, `subagents.jsonl`) are read as fallback for pre-upgrade history — **zero data loss, zero manual migration needed**. This is the "single-write + dual-read" migration: producers write only the new stream, consumers read new stream first, then legacy files for pre-upgrade events.

## Local Mode

By default, `/nazgul:init` creates files that are tracked in git (shared mode). To keep all Nazgul artifacts out of your project's repository, use local mode:

```bash
/nazgul:init --local
```

This automatically adds `nazgul/`, `.claude/agents/generated/`, and `.mcp.json` to your `.gitignore` and skips CLAUDE.md injection. All Nazgul functionality works identically — the files just stay local to your machine.

## External Board Sync

Nazgul can sync task progress to external project boards so your team has visibility without leaving their existing tools.

```bash
# Connect to GitHub Projects
/nazgul:board github

# Take over an existing project (archives current items)
/nazgul:board github --clean

# Check sync health
/nazgul:board status

# Disconnect
/nazgul:board disconnect
```

**How it works:**

- **One-way sync**: Nazgul is always the source of truth. Local tasks push to GitHub — changes on GitHub are ignored.
- **Automatic**: Discovery detects GitHub repos. `/nazgul:start` prompts to connect. After that, the planner creates issues for new tasks and the stop hook syncs status changes — no manual intervention.
- **Non-blocking**: Sync failures never stop local work. After 5 consecutive failures, sync auto-disables with a warning.
- **Provider-pluggable**: GitHub Projects V2 is the first provider. Adding new providers (ADO, Trello) requires only a new `scripts/board-sync-{provider}.sh` — no changes to config schema or agents.

Each Nazgul task becomes a GitHub Issue with `nazgul:*` labels and custom project fields (Nazgul Status, Task ID, Group). Issues close automatically when tasks reach DONE.

## Connectors

`connectors` configures an opt-in, **default-OFF** two-way sync between Nazgul and an external issue tracker. **GitHub is the only shipped connector** (`scripts/lib/connector-github.sh`); Linear/Slack are planned behind the same contract but are **not** shipped. This is distinct from **External Board Sync** above (one-way push of task status to a GitHub *Projects V2 board*): the connector pulls opt-in-labelled *issues* into the objective-inbox seam and pushes status + PR links back onto the originating issue.

**Provider selection reuses the existing heartbeat key — there is no new selector.** Set `automation.heartbeat.inbox.provider` to `"github"` to route the inbox-provider seam (`scripts/lib/inbox-provider.sh` — `inbox_list`/`inbox_get`/`inbox_archive`) to the GitHub connector, and set `connectors.github.enabled` to `true` to arm it. Both are required; with either unset the seam keeps its default local-`file` behavior.

**Credentials come from `gh auth` / env only** — no token is ever read from, written to, or logged via `config.json`. Run `gh auth login` before enabling. Remote issue title/body are treated strictly as data (passed to `jq` via `--arg`/`--rawfile`, never `eval`'d) and the body is byte-capped (`pull.max_body_bytes`).

| Key | Default | Meaning |
|-----|---------|---------|
| `connectors.github.enabled` | `false` | Master switch. Must be `true` (together with `inbox.provider="github"`) to arm the connector. |
| `connectors.github.pull.label` | `"nazgul"` | Opt-in label. Only OPEN issues carrying this label are pull candidates. |
| `connectors.github.pull.claimed_label` | `"nazgul-claimed"` | Nazgul's "I took this" marker, added on claim (`pull_archive`). A claimed issue is excluded from future pulls and is **never** removed by a push, so a pushed update can't make the issue re-enter the pull list. |
| `connectors.github.pull.max_body_bytes` | `65536` | Byte cap applied to a pulled issue body, bounding memory against a hostile huge issue. |
| `connectors.github.push.enabled` | `true` | Push-half toggle. Only effective under the top-level `enabled` (which defaults `false`); an explicit `false` disables push while leaving pull on. |
| `connectors.github.pull_failures` | `0` | Consecutive-pull-failure counter. Increments on a terminal `gh` failure, resets to `0` on a good pull, and auto-disables the connector (`enabled=false`) at `5` — pull failures never block or crash the loop. |
| `connectors.github.map` | `{}` | Remote-issue# ↔ local-feat/task-id map recorded on claim. Authoritative for idempotency: a mapped issue stays out of the pull list even if its remote claimed label lags or is stripped. |

**Two-way flow:** a pull candidate is an OPEN issue that carries `pull.label` and neither carries `pull.claimed_label` nor appears in `map`. On claim the connector adds the claimed label and records `map[issue#]=feat_id`; the pulled issue surfaces through the inbox-provider seam as an objective-inbox candidate. The push side reflects a local task/objective status onto the mapped issue as a single `nazgul-status:<status>` label and upserts one `<!-- nazgul-pr -->`-marked PR-link comment — each idempotent, and neither ever touches the opt-in or claimed labels (so a push can never re-trigger a pull). Both halves are wired into the running loop: with `provider="github"` the heartbeat tick engine (`scripts/heartbeat.sh`) pulls, triages, and auto-starts labelled issues, and the stop-hook (`scripts/stop-hook.sh`) pushes `push_status` (plus `push_pr` when a task manifest carries a `- **PR**:` URL) for each task whose status changed since the last push — a per-task `_last_pushed_status` cache makes an unchanged status a no-op, and every push is degrade-safe (`|| true`) so a `gh` failure never breaks the loop.

**Failure degradation:** every connector operation is degrade-safe — a missing/unauthenticated `gh`, a network/rate-limit error, or malformed remote JSON logs and no-ops rather than blocking the loop, and `pull_failures` auto-disables pull after 5 consecutive failures (mirroring `board.sync_failures`).

Added by the additive `migrate_24_to_25` migration (schema v24→v25); existing projects upgrade automatically with `connectors.github` default-off — see Config Upgrades below.

## Config Upgrades

When the Nazgul plugin template evolves (new fields, new sections), existing projects upgrade automatically:

1. On every session start, Nazgul compares your project's `nazgul/config.json` schema version against the plugin template
2. If your config is outdated, it creates a backup (`config.json.v1.bak`), applies incremental migrations, and logs to `nazgul/logs/migrations.log`
3. Existing settings are preserved — only missing fields are added

No manual action required. You'll see a one-time notice: `"Nazgul config migrated from v4 to v5."`

## Webhooks

Nazgul can forward loop events to external HTTP endpoints for remote monitoring of AFK/YOLO runs.

```json
{
  "webhooks": {
    "enabled": true,
    "url": "https://hooks.slack.com/services/...",
    "events": ["stop", "compact", "task_complete"],
    "headers": { "Authorization": "Bearer ..." }
  }
}
```

Events are POSTed as JSON with iteration count, task status, objective, and branch info. Webhook failures never block the loop.

## Worktree Sparse Paths

For monorepos, configure sparse checkout to speed up task worktree creation:

```json
{
  "branch": {
    "sparse_paths": ["src/api/", "tests/api/", "package.json"]
  }
}
```

When set, task worktrees only check out the specified directories instead of the full repo.

## Auto-Enhancement

Nazgul can periodically check for new Claude Code features and propose improvements:

```bash
/nazgul:enhance              # One-time check
/loop 2w /nazgul:enhance     # Auto-check every 2 weeks
```

## Concurrent Session Detection

Nazgul automatically tracks active sessions via filesystem locks in `nazgul/sessions/`. Stale locks (>2 hours) are cleaned automatically. If multiple sessions target the same project, a warning is issued on startup. No configuration needed — always active.
