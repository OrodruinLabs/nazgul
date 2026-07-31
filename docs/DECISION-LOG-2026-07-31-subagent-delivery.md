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
