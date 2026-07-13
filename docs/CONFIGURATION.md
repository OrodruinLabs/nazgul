# Configuration

## Flags for `/nazgul:start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
- `--task-pr` — (with `--yolo`) Create stacked per-task PRs targeting the feature branch instead of a single PR at completion
- `--continue` — Explicit resume (backward compat — bare `/nazgul:start` auto-detects this)

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
| Review (orchestrator) | Sonnet | The review-gate/conductor orchestrator coordinates the board |
| Implementation | Sonnet | Code generation is Sonnet's sweet spot |
| Specialists | Sonnet | Same as implementation |
| Conductor | Sonnet | The conductor drives waves and dispatch, not code |
| Post-loop | Sonnet | Changelog and docs updates need judgment |

Three presets are available: **Balanced** (default), **Quality** (all Opus), and **Fast/cheap** (Haiku where possible). Or pick per stage.

**Conductor tier.** `models.conductor` (default `sonnet`) pins the Conductor's own model tier. `/nazgul:start` dispatches `agents/conductor.md` with `model: $(jq -r '.models.conductor // "sonnet"')`, so a Conductor run does not silently inherit the launching session's tier. It selects only the Conductor's own tier — the implementers and review-gate it dispatches resolve their tiers independently (`models.implementation`, and the review keys below).

**Review tiers — two keys, with a legacy fallback.** The single `models.review` tier is now split into two keys:

- `models.review_default` (default `haiku`) — the default per-reviewer tier for the mechanical code/qa reviewers.
- `models.review_orchestrator` (default `sonnet`) — the review-gate and conductor review orchestrator tier.

Both resolve with the exact fallback order **new key → legacy `models.review` → hardcoded default** (`review_orchestrator` falls back to `sonnet`, `review_default` to `haiku`). A config still carrying only `models.review` is therefore honored unchanged — it seeds both new keys — so no manual migration is needed.

`models.review_by_reviewer` overrides `models.review_default` (and legacy `models.review`) per reviewer name. The default pins the two judgment reviewers to Sonnet even when `models.review_default` is a cheaper tier:

```json
{
  "models": {
    "review_default": "haiku",
    "review_orchestrator": "sonnet",
    "conductor": "sonnet",
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

## Execution Engine

`execution.engine` selects which engine drives the objective: `"sequential"` (default) is today's one-task-at-a-time main-session loop; `"conductor"` opts into the graph-only driver that decomposes the Planner's task graph into waves and farms each unit to a fresh sub-session. `sequential` behavior is unchanged either way.

| Key | Default | Meaning |
|-----|---------|---------|
| `execution.engine` | `"sequential"` | `"sequential"` or `"conductor"`. |

The `conductor` block configures the conductor engine's gates and parallelism, autonomous-first (all gates default `false`):

| Key | Default | Meaning |
|-----|---------|---------|
| `conductor.gates.approve_graph` | `false` | Pause for human approval of the computed task graph before dispatch. |
| `conductor.gates.approve_each_wave` | `false` | Pause for human approval before dispatching each wave. |
| `conductor.gates.approve_final_pr` | `false` | Pause for human approval before opening the final PR. |
| `conductor.max_parallel` | `3` | Maximum units dispatched concurrently within a wave. |

In `--hitl` mode, `scripts/lib/conductor-gates.sh` forces the *effective* `approve_graph` gate to `true` regardless of the stored value — the stored config default stays `false`. Every other gate always equals its stored value in every mode.

## Automation Heartbeat

`automation.heartbeat` configures an opt-in, default-off tick engine (`scripts/heartbeat.sh`) that triages a local work inbox (`nazgul/inbox/`) and auto-starts the next objective when idle. Fire a tick by hand with `/nazgul:heartbeat`, or point an opt-in Claude Code native scheduled agent (routine) at that skill on your chosen interval — the plugin itself wires no OS cron / `claude -p` scheduling (deferred to FEAT-009).

| Key | Default | Meaning |
|-----|---------|---------|
| `automation.heartbeat.enabled` | `false` | Master switch. `false` means every tick is a `decision: disabled` no-op before any inbox read. |
| `automation.heartbeat.interval` | `"30m"` | Suggested firing interval for the scheduled-agent routine you configure outside the plugin — not enforced by the script itself. |
| `automation.heartbeat.inbox.provider` | `"file"` | Inbox provider behind the `inbox_list`/`inbox_get`/`inbox_archive` seam (`scripts/lib/inbox-provider.sh`). The heartbeat *tick engine* consumes both `"file"` (local dir, default) and `"github"` (the GitHub connector — see **Connectors** below); a labelled remote issue is pulled, triaged, claimed, and auto-started like a local candidate. A genuinely unknown value fails closed — the tick logs `decision: skipped, reason: unsupported_provider:<value>` and exits without touching the inbox, rather than silently falling back to the file provider. With `provider="github"` but the connector disabled (`connectors.github.enabled=false`) or unhealthy, the seam degrades to a safe empty list, so the tick simply finds `nothing_actionable` — it does **not** fall back to the local `file` inbox. |
| `automation.heartbeat.inbox.dir` | `"nazgul/inbox"` | Directory scanned for `.md`/`.json` candidates; claimed candidates move to `<dir>/archive/`. |
| `automation.heartbeat.auto_start.mode` | `"yolo"` | Mode passed to `/nazgul:start` when a candidate is picked and no session is active. |
| `automation.heartbeat.auto_start.engine` | `"conductor"` | Execution engine passed to `/nazgul:start` for the auto-started objective. |

Two unconditional hard stops (a `BLOCKED` task, a non-`APPROVE` security-reviewer verdict) halt every tick regardless of `enabled` or `mode` — see RULES.md §13. The session-tracker concurrency guard (`scripts/lib/session-tracker.sh`) refuses to auto-start over an active session, and the picked candidate is archived before `/nazgul:start` is invoked (atomic claim-then-archive, never double-started). Every tick appends one decision record to `nazgul/logs/heartbeat-<date>.jsonl`, surfaced via `/nazgul:log`.

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

## Comment Quality Gate

`docs.verify_comments` (default `true`) blocks `NAZGUL_COMPLETE` until a post-loop `comment-verifier` agent grades inline source doc-comments (XML `<summary>`, JSDoc, docstrings) across the objective's changed files. Reviewers can already flag comment issues, but only as sub-80 non-blocking concerns; this gate makes templated, restatement, and contradiction defects blocking, mirroring the FEAT-004 doc-accuracy verifier. Bounded to at most 3 backstop retries; on exhaustion it degrades to allow rather than bricking an unattended run. Set to `false` to opt out.

## Post-Loop Learning Gate

When an objective finishes, Nazgul distills recurring mistakes (review rejections, debugger diagnoses, repeated failures) into **candidate** Learned Rules via the `nazgul:learner` agent — it proposes only; you approve them later with `/nazgul:learn`. This step is **mandatory**: `stop-hook.sh` blocks loop completion until the learner has run for the current objective (it records completion by writing the objective id to `nazgul/learning/.distilled`). A bounded attempt counter lets the loop finish with a warning if the marker can't be written, so it can never brick an unattended run.

| Key | Default | Meaning |
|-----|---------|---------|
| `learning.enabled` | `true` | Master switch for the learning subsystem. |
| `learning.auto_distill_post_loop` | `true` | Run (and gate completion on) the learner at objective completion. Set either flag to `false` to opt out — the gate becomes a no-op. |

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
- **stop_failure** — when the loop stop hook itself fails
- **budget_threshold** — proactive warning when spending reaches 50% or 90% of the configured limit
- **objective_complete** — when all tasks finish and the post-loop phase begins

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

## Fast Mode

Enable fast mode for implementation agents to get faster inference at higher token cost:

```json
{
  "models": {
    "fast_mode_implementation": true
  }
}
```

## Auto-Enhancement

Nazgul can periodically check for new Claude Code features and propose improvements:

```bash
/nazgul:enhance              # One-time check
/loop 2w /nazgul:enhance     # Auto-check every 2 weeks
```

## Self-Improvement Mode

Enable agent self-rating and improvement reports:

```json
{
  "self_improvement": {
    "enabled": true,
    "threshold": 7
  }
}
```

Agents rating their experience below the threshold file structured JSON reports to `nazgul/improvement-reports/`. Reports include task ID, agent name, rating, summary, and improvement suggestions. View aggregated data with `/nazgul:metrics`.

## Concurrent Session Detection

Nazgul automatically tracks active sessions via filesystem locks in `nazgul/sessions/`. Stale locks (>2 hours) are cleaned automatically. If multiple sessions target the same project, a warning is issued on startup. No configuration needed — always active.
