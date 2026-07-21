# Decision Log — Parallel Execution Collapse (2026-07-21)

Design: `docs/superpowers/specs/2026-07-21-parallel-execution-collapse-design.md`.

## D-001 — Platform finding: nested subagents are not re-engageable drivers

**Finding:** Since Claude Code v2.1.198, subagents run in the background by default.
Nested `Agent` calls made *from inside a subagent* do not block. Background-completion
notifications are documented to re-engage only the **main session** — there is no
documented mechanism that gives a nested parent subagent a fresh turn when its children
finish.

**Consequence:** the Conductor engine (FEAT-007, v2.9.0) ran `agents/conductor.md` as a
background subagent whose Step 5 required it to "wait for every dispatch to return"
before advancing. That await never resolves on its own — the conductor stalled at every
wave boundary, at post-commit review dispatch, and at review tallying, requiring a
manual resume each time.

**Sources:** code.claude.com/docs — the sub-agents, hooks, workflows, and agent-teams
pages.

## D-002 — Alternatives ranked

1. **Main-session driver + Stop hook (chosen).** The only fully documented AND
   crash-durable option. Stop-hook `decision:"block"` + injected instructions is
   first-class; multiple `Agent` calls issued in one message from the main session run
   concurrently; the main session reliably re-engages after each Stop.
2. **Workflow tool.** Awaited `agent()` fan-out with minimal token burn, but not durable
   across a Claude Code exit and cannot be launched programmatically by a plugin — it
   requires a human-typed trigger, and that entry path was tightened further in v2.1.210.
   Rejected: a plugin cannot self-drive it.
3. **Agent Teams conductor.** `SendMessage` can wake idle teammates, but the feature is
   experimental, teammates cannot background their own children, and there is no session
   resumption for a teammate that stalls. Rejected: same class of undocumented-resume
   risk as the background subagent it would replace.
4. **Background subagent + watchdog.** Automates the babysitting instead of eliminating
   it — some other process still has to notice the stall and re-poke the conductor, and
   the drive mechanism that would wake it remains undocumented. Rejected: treats the
   symptom, not the cause.

## D-003 — Decision

One engine: the existing sequential stop-hook loop, with a new `execution.parallel`
batch-dispatch option computed deterministically by the stop-hook
(`compute_dispatch_batch` in `scripts/lib/parallel-batch.sh`). The Conductor engine —
`agents/conductor.md`, its libs (`conductor-graph.sh`, `conductor-gates.sh`,
`conductor-router.sh`), its guards (`conductor-dispatch-guard.sh`,
`conductor-rework-guard.sh`), and its tests — is deleted outright rather than kept as a
second, opt-in engine. `execution.engine` is removed from the config schema.

**Closing rule:** do not reintroduce a background-subagent driver unless the platform
documents parent re-engagement on child completion.

## D-004 — Follow-on facts recorded for the release

- Parallel batching only activates review-per-task; it requires
  `review_gate.granularity: "task"`. The template default, `"group"`, stays fully
  sequential regardless of `execution.parallel` — a project must opt into both
  independently.
- The `pre-merge-commit` git hook (`scripts/git-hooks/pre-merge-commit`) now parses task
  manifest frontmatter (`status:` in the leading YAML block) to resolve a unit's status,
  falling back to the legacy `- **Status**:` line only when frontmatter is absent —
  re-keyed off task manifests now that there is no `nazgul/conductor/graph.json` to read
  from.
