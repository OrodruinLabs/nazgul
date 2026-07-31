# Decision Log — Subagent Non-Delivery (2026-07-31)

Objective: `nazgul/config.json → .objective` (FEAT-024). PRD: `nazgul/docs/PRD.md`. TRD: `nazgul/docs/TRD.md`.

## TASK-001 — Reviewer `maxTurns` ceiling: repo-wide audit, before and after

Fresh `grep -rn "maxTurns" agents/ .claude/agents/generated/` run at implementation time (not the PRD's
doc-generation-time table, re-verified per AC1). Base commit: `9b0542d` (`main` @ v2.25.0).

### `agents/` (committed specs) — before vs. after

| Agent spec | Before | After | Changed? |
|---|---|---|---|
| `agents/templates/reviewer-base.md` | 12 | **30** | YES — this task |
| `agents/self-audit.md` | 15 | 15 | no |
| `agents/comment-verifier.md` | 20 | 20 | no |
| `agents/feedback-aggregator.md` | 20 | 20 | no |
| `agents/release-manager.md` | 20 | 20 | no |
| `agents/doc-verifier.md` | 20 | 20 | no |
| `agents/debugger.md` | 30 | 30 | no |
| `agents/db-migration.md` | 30 | 30 | no |
| `agents/observability.md` | 30 | 30 | no |
| `agents/learner.md` | 30 | 30 | no |
| `agents/documentation.md` | 40 | 40 | no |
| `agents/cicd.md` | 40 | 40 | no |
| `agents/devops.md` | 40 | 40 | no |
| `agents/review-gate.md` | 40 | 40 | no |
| `agents/team-orchestrator.md` | 40 | 40 | no |
| `agents/designer.md` | 40 | 40 | no |
| `agents/discovery.md` (own frontmatter, line 11) | 50 | 50 | no |
| `agents/discovery.md` (embedded example, line 478) | 30 | 30 | no — see out-of-scope drift below |
| `agents/discovery.md` (embedded example, line 793) | 40 | 40 | no |
| `agents/discovery.md` (embedded example, line 885) | 30 | 30 | no |
| `agents/planner.md` | 50 | 50 | no |
| `agents/doc-generator.md` | 50 | 50 | no |
| `agents/frontend-dev.md` | 50 | 50 | no |
| `agents/mobile-dev.md` | 50 | 50 | no |
| `agents/simplifier.md` | 50 | 50 | no |
| `agents/implementer.md` | 100 | 100 | no |

### `.claude/agents/generated/` (local, gitignored runtime artifacts) — before vs. after

Regenerated on disk in the main worktree as an operational step (never committed — `.gitignore:16`):

| Generated agent | Before | After | Changed? |
|---|---|---|---|
| `.claude/agents/generated/architect-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/code-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/security-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/qa-reviewer.md` | 12 | **30** | YES |
| `.claude/agents/generated/documentation.md` | 30 | 30 | no — out-of-scope drift, see below |
| `.claude/agents/generated/cicd.md` | 40 | 40 | no |
| `.claude/agents/generated/release-manager.md` | 20 | 20 | no |

### Value chosen: 30, not 24

30 was chosen over the PRD/TRD's 24-30 range floor because this repo's own bootstrap test fixtures already
use `maxTurns: 30` for reviewers — matching it avoids introducing a second reviewer-turn-budget convention.
24 would be a new number appearing nowhere else in the repo.

### Out-of-scope drifts confirmed unchanged (per TRD Scope Item 1 required verification)

1. **`agents/discovery.md`'s embedded "Reviewer Agent Template" fragment (~lines 460-500).** Still shows
   `tools: Read, Glob, Grep, Bash`, an `allowed-tools:` Bash-test-command allowlist, `maxTurns: 30`, a
   per-agent `hooks: SubagentStop: type: prompt` block, and `nazgul/reviews/[TASK-ID]/` paths — none of
   which match the live template (`agents/templates/reviewer-base.md`: Read/Glob/Grep only, no
   `allowed-tools`/`hooks` block, `[UNIT-ID]` paths). Predates FEAT-006's reviewer-persistence redesign.
   Filed by TASK-009, not fixed here.
2. **`.claude/agents/generated/documentation.md` at `maxTurns: 30` vs. its source template
   `agents/documentation.md` at `maxTurns: 40`.** A live generated-vs-template drift, confirmed still
   present above. Filed by TASK-009, not fixed here.

Neither drift was touched by this task; no other agent spec was accidentally modified (full audit table
above covers every file the grep matched).

## TASK-003 — SubagentStop exit-2 probe

**Result in one sentence: exit 2 + `{"decision":"block","reason":...}` from a `type: "command"`
`SubagentStop` hook IS honored — the harness continued the SAME subagent with the reason injected as a
new turn — so TASK-006 implements Branch A (in-hook bounded resume).**

### Method actually used (differs from the manifest's step 2, deliberately)

The manifest proposed temporarily pointing the `SubagentStop` entry in `hooks/hooks.json` at the probe.
That was NOT done, for two reasons discovered at execution time: (a) this session loads the plugin from
the version cache (`~/.claude/plugins/cache/orodruin-labs/nazgul/2.23.1/`), not from this repo checkout,
so editing the repo's `hooks/hooks.json` would be a no-op for the live session; and (b) hook CONFIG may be
snapshotted at session start, which would make a config swap silently untestable — indistinguishable from
"exit 2 has no effect," exactly the ambiguity this framework exists to forbid. Instead the probe swapped
the SCRIPT BODY at the path the already-registered hook command resolves on every event
(`<cache>/scripts/subagent-stop.sh`), which is read fresh at each invocation. The repo's
`hooks/hooks.json` was therefore never modified at all (`git diff --exit-code hooks/hooks.json` clean
throughout), and the cache script was restored byte-identical (verified with `cmp`) immediately after
observation. The probe script lived in the session scratchpad and was deleted after restore.

### Probe payload (exact)

First invocation only (marker-counted, so a working block could not loop forever):

```json
{"decision":"block","reason":"PROBE-CONTINUATION: you were blocked from stopping by a SubagentStop exit-2 probe. Reply with exactly the word PONG and stop."}
```

emitted on stdout, followed by `exit 2`. Subsequent invocations: `exit 0`.

### Dispatch mode observed

Direct Agent-tool dispatch (`subagent_type: general-purpose`, model haiku, one-shot prompt "Reply with
exactly the word PING and nothing else"). **Agent-Teams teammate mode was NOT observed** — this result is
claimed for direct dispatch only, the mode the review board actually uses.

### Observed behaviour

- The subagent's final deliverable was `PONG`, not `PING` — it composed PING, was blocked at stop,
  received the probe's reason as a continuation turn, complied, and stopped again.
- The probe recorded exactly 2 invocations: invocation 1 (blocked, exit 2), invocation 2 (the re-stop,
  allowed with exit 0). Marker files captured the harness's hook input both times.
- Total added latency ~4s on a trivial dispatch; no error surfaced to the orchestrator.

### Hook input fields observed (useful to TASK-006 Branch A)

The `SubagentStop` stdin JSON carried, among others: `agent_id`, `agent_type`, `agent_transcript_path`,
`last_assistant_message`, `stop_hook_active`, `session_id`, `cwd`. Notable: `last_assistant_message`
gives the hook the final text directly (no transcript parse needed for the empty-return check), and
`stop_hook_active` is the harness's own re-entry signal — both directly serve the Branch A resume design.

### Selected branch

**Branch A** (in-hook bounded resume in `scripts/subagent-stop.sh`). TASK-007's Branch B stop-hook gate
is therefore expected to close NOT-APPLICABLE per its manifest.

## TASK-008 — Non-delivery measurement

### The events.jsonl vacuity statement (read this before the numbers below)

`nazgul/logs/events.jsonl` records **zero** `subagent_empty_return` events for this entire objective —
lifetime, not just today. Checked directly:

```console
$ jq -c 'select(.event=="subagent_stop")' nazgul/logs/events.jsonl | wc -l
2021
$ jq -c 'select(.event=="subagent_empty_return")' nazgul/logs/events.jsonl | wc -l
0
$ jq -c 'select(.event=="subagent_stop" and (.ts|startswith("2026-07-31")))' nazgul/logs/events.jsonl | wc -l
47
$ jq '.telemetry.bus_enabled' nazgul/config.json
true
```

That zero is **not a measurement of a low non-delivery rate — it is a vacuous zero**, and reporting it as
the former would be exactly the failure this objective's own governing thesis forbids. The check the
task manifest requires (verify `subagent_stop` fired in the same window, confirm `telemetry.bus_enabled`)
passes: the bus was live all day (47 `subagent_stop` events today, 2021 lifetime), so the hook ran on
every dispatch. The reason the numerator is zero regardless is structural, not empirical: **this
session's live `SubagentStop` hook is the plugin's version-cache copy,
`~/.claude/plugins/cache/orodruin-labs/nazgul/2.23.1/scripts/subagent-stop.sh`**, installed before this
objective started and never reloaded from a checked-out branch mid-session (confirmed by TASK-003's own
probe method note: the cache script, not this repo's `scripts/subagent-stop.sh`, is what the harness
actually invokes). v2.23.1 predates TASK-004/005's instrumentation entirely — it emits `subagent_stop` and
nothing else. The instrumented hook (this feature branch, merged into `scripts/subagent-stop.sh` at
`f81c2f0`) has therefore never run live this session. It could not have recorded a `subagent_empty_return`
event no matter how many real non-deliveries occurred, so the file's zero proves the hook version, not the
delivery rate.

### What was measured instead: replay of real transcripts through the shipped instrument

The instrumented `scripts/subagent-stop.sh` (this branch) was run, unmodified, against the **real JSONL
transcripts** of the reviewer dispatches from this objective's own GROUP-1/GROUP-2 boards — the actual
subagent session files at
`/private/tmp/claude-501/.../650f0c0d-ebc3-4765-b99c-0bf085d19028/tasks/*.output` (symlinks into
`~/.claude/projects/.../subagents/agent-*.jsonl`). This is **replay, not live capture**: the hook never
saw these events at the time; it is being fed the real transcript bytes after the fact to determine what
it *would* have emitted had it been the live hook.

**Isolation method, including a correction made mid-task.** The hook input was constructed as
`{agent_transcript_path, name, agent_id, session_id, stop_hook_active:false}` JSON piped to
`scripts/subagent-stop.sh`. The first attempt set `NAZGUL_DIR` as an environment override, matching this
objective's own instruction — but `scripts/lib/nazgul-root.sh`'s `resolve_nazgul_dir()` (FEAT-021) **does
not read `NAZGUL_DIR` at all**; it resolves unconditionally from `CLAUDE_PROJECT_DIR` if set, else a
git-toplevel/`pwd` marker search. Neither was pointed at the temp dir, so all 7 replay invocations ran
against the **live** `nazgul/`, appending 9 events (7 `subagent_stop` + 2 `subagent_empty_return`), 5 lines
to `review-receipts.jsonl`, and 2 `.resume-attempts` marker files to the real project state — caught
immediately (before any further step) by diffing `wc -l`/`tail` against the pre-run state, and fully
reverted: the 9 trailing `events.jsonl` lines, the 5 trailing `review-receipts.jsonl` lines, and both stray
`.resume-attempts` files were identified by exact timestamp/count match and removed. `git status` on
`nazgul/` was re-checked clean after revert (these files are gitignored, so `git diff` cannot see them —
manual byte-count verification was the only check available, and was done before and after). The corrected
method sets `CLAUDE_PROJECT_DIR` to an isolated temp directory (`nazgul/config.json` with
`guards.subagent_resume: false`, plus copies of the real `.claude/agents/generated/{code,qa,architect,
security}-reviewer.md` for accurate `maxTurns` resolution) — confirmed isolated by re-running
`resolve_nazgul_dir()` under that env and checking the live `events.jsonl` tail timestamp is unchanged
after the full replay batch.

### Replay results

| # | Transcript (agent, dispatch) | Slice fed to the hook | Final assistant record | Event emitted | Reason | Action |
|---|---|---|---|---|---|---|
| 1 | `a7627a15b34b9def3` — code-reviewer, GROUP-1 (token `218321e6d654dc0d`), sonnet | Truncated to line 44 — right before the coordinator's resume nudge (line 45) | Bare `tool_use` (Glob), no text | **YES** | `empty_final_text` | `detected_only` (resume disabled in replay config) |
| 2 | `a7627a15b34b9def3` — same dispatch, full transcript (post-resume) | Full 46-line transcript | Text block carrying `verdict: APPROVE ... reviewer: code-reviewer` | no | — | — |
| 3 | `ad95b964dfe0f85f5` — qa-reviewer, GROUP-2 (token `41e8b23057ecaa41`), haiku | Truncated to line 108 — right before the coordinator's resume nudge (line 109) | Bare `tool_use`, no text | **YES** | `empty_final_text` | `detected_only` |
| 4 | `ad95b964dfe0f85f5` — same dispatch, full transcript (post-resume) | Full 111-line transcript | Text block carrying `verdict: APPROVE ... reviewer: qa-reviewer` | no | — | — |
| 5 | `abd7a41c2930338ff` — architect-reviewer, GROUP-1, first-round clean delivery | Full transcript | Text block carrying verdict | no | — | — |
| 6 | `acc0b3f788a45c7b5` — qa-reviewer, GROUP-1, first-round clean delivery (haiku) | Full transcript | Text block carrying verdict | no | — | — |
| 7 | `af4a996a99a4f2c70` — security-reviewer, GROUP-2, first-round clean delivery | Full transcript | Text block carrying verdict | no | — | — |

All 7 outcomes matched the known ground truth exactly: the two transcripts known (from this session's own
orchestrator record) to have stalled without a verdict reproduce `subagent_empty_return`/`empty_final_text`
when replayed at the pre-resume boundary; the two post-resume completions and the three known first-round
clean deliveries reproduce no event. This is the strongest evidence available this session that the
shipped instrument (TASK-004/005) correctly classifies both the failure and the non-failure case against
real (not synthetic-fixture) transcript shapes.

**A genuine caveat surfaced by the replay, not by inspection of the code.** The real Claude Code session
JSONL format writes **one content block per line** (a `text` block and a following `tool_use` block from
the same logical model turn are two separate `"type":"assistant"` records, chained by
`parentUuid`/`uuid`) — not one line per full API turn. The hook's `turns_used` computation
(`[.[] | select(.type=="assistant")] | length`) counts these records, so it does not equal a true
conversation-turn count when a turn contains multiple content blocks. The replay produced `turns_used: 27`
for the code-reviewer stall and `turns_used: 74` for the qa-reviewer stall against `max_turns: 30` — the
qa-reviewer figure exceeds the ceiling it is being compared to, which is only possible because the metric
is counting content-block records, not turns. **This means AC7's "decisive datum" (does `turns_used` sit
at the ceiling) cannot be read directly off this metric without that correction, and this session produced
no corrected figure** — flagged here as unproven, not glossed over, per the manifest's own instruction not
to reach for a favourable slice of the data.

### The labeled tally (notification-derived — NOT sourced from `events.jsonl`, per this task's own rule)

This is the only per-board tally available this session, and it is explicitly **not** the AC7-mandated
`events.jsonl` measurement — it comes from the orchestrator's own dispatch/resume records, which is a
weaker source than a real event stream and is labeled as such everywhere it appears in this document.

- First-round reviewer dispatches, 3 boards (GROUP-1/2/3), `maxTurns: 30`: **12 total**.
  - GROUP-1: 4 dispatched, 1 non-delivery (code-reviewer, sonnet, mid-analysis trailing text then a bare
    tool call with no text, 16 tool calls before the stall — see replay row 1).
  - GROUP-2: 4 dispatched, 1 non-delivery (qa-reviewer, haiku, 33 tool calls, ended
    "Let me verify..." — see replay row 3).
  - GROUP-3: 4/4 delivered first round.
  - Re-attest round (post-rework, all 3 groups' re-checks): 4/4 delivered.
- **Observed first-round rate this objective: 2/12 ≈ 17%.** n=12 is small; stated plainly, not hedged.
  The two failures were not the same shape (one sonnet mid-analysis, one haiku mid-verification), and
  neither was reported at exactly the nominal turn ceiling by the notification tally (16 and 33 tool
  calls respectively) — tool-call counts are yet another proxy, distinct from both `turns_used`-as-recorded
  and true API turns; none of the three agree with each other, and this document does not pretend they do.
- Historical baseline: **~50%** (24/47 across FEAT-022/FEAT-023, `maxTurns: 12`).
- All resumed agents (2 stalled reviewers here, plus 3 GROUP-3 delta re-attests during the TASK-006 rework
  round) delivered with **~zero further tool calls** after the resume nudge — consistent with
  "judgment-complete-at-stall," i.e., the model had already finished reasoning and simply failed to emit
  the terminal deliverable, rather than needing more work. The replay's identical finding (row 1→2 and
  row 3→4: same dispatch, no further tool calls between the truncated stall point and the delivered
  verdict) corroborates this from the transcript bytes themselves, independent of the tally.
- A **second, different failure class** was also observed and must not be conflated with the above: two
  **implementer** dispatches (TASK-004, TASK-005) ended their turn waiting on a **backgrounded test run**
  rather than at a turn/output ceiling — recovered by the same resume mechanism, but the cause
  (background-wait, not turn-count) is distinct and is not counted in the 12/2 reviewer tally above.

### Reproducible `jq` — to run once the instrumented hook (`scripts/subagent-stop.sh` at this branch, or any
release `>= 2.26.0`) is the *live* plugin for a real objective run

```bash
# 0. Confirm the instrumentation is live before trusting a zero (do this FIRST):
jq '.telemetry.bus_enabled' nazgul/config.json                                   # must be true
jq -c 'select(.event=="subagent_stop" and .ts >= "<RUN_START>")' \
  nazgul/logs/events.jsonl | wc -l                                                # must be > 0

# 1. Denominator — subagent_stop events in the run window:
jq -c 'select(.event=="subagent_stop" and .ts >= "<RUN_START>" and .ts <= "<RUN_END>")' \
  nazgul/logs/events.jsonl | wc -l

# 2. Numerator — subagent_empty_return events in the same window:
jq -c 'select(.event=="subagent_empty_return" and .ts >= "<RUN_START>" and .ts <= "<RUN_END>")' \
  nazgul/logs/events.jsonl | wc -l

# 3. Breakout by cause:
jq -s '[ .[] | select(.event=="subagent_empty_return" and .ts >= "<RUN_START>") ]
       | group_by(.reason) | map({reason: .[0].reason, count: length})' \
  nazgul/logs/events.jsonl

# 4. Breakout by agent:
jq -s '[ .[] | select(.event=="subagent_empty_return" and .ts >= "<RUN_START>") ]
       | group_by(.agent) | map({agent: .[0].agent, count: length})' \
  nazgul/logs/events.jsonl

# 5. turns_used vs max_turns distribution (see the content-block-vs-turn caveat above
#    before treating this as a literal turn count):
jq -c 'select(.event=="subagent_empty_return" and .ts >= "<RUN_START>")
       | {agent, turns_used, max_turns, at_ceiling: (.turns_used >= .max_turns)}' \
  nazgul/logs/events.jsonl

# 6. Rate:
python3 -c "print(round(<numerator> / <denominator>, 3))"
```

### AC8 verdict

The measured first-round rate **did drop materially this objective — 2/12 ≈ 17%, against a ~50% (24/47)
baseline — but the drop is not proven to be caused by the `maxTurns` bump specifically**, because the
one datum that would prove or disprove that (`turns_used` sitting at the ceiling, sourced from a live
`events.jsonl` under the instrumented hook) was never available this session: the live hook predates the
instrumentation (vacuous zero, documented above), and the replay-derived `turns_used` proxy is
demonstrably miscalibrated against `max_turns` (content-block-per-line vs. turn-per-line, row above) and
so cannot substitute. What **is** proven, by real replay against the real transcripts (not a fixture, not
an estimate): the instrumented detector correctly flags both real non-deliveries as `empty_final_text` and
correctly stays silent on all five known clean/resumed-and-delivered cases, and the bounded auto-resume
backstop (TASK-006) is what actually recovered both real stalls, with zero further tool calls needed in
either case — the residual this objective leaves standing is exactly the ~17% (n=12, small-sample) that
backstop exists to catch, not a number claimed to be zero. The next objective's starting hypotheses for
whatever fraction of that residual is not explained by the turn ceiling are, as before: **(H2)** a
per-turn output-token cap independent of `maxTurns`, and **(H3)** a harness tool-result boundary
independent of any counter this repo sets — and a live instrumented capture (this branch or `>= 2.26.0`)
against a real multi-board run is the only way to get the ceiling-vs-cause question a real answer, using
the reproducible `jq` above.
