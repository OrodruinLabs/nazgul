# c0 & the Agent-Platform Landscape — Full Research Synthesis

**Date:** 2026-08-03 · **Trigger:** operator flagged https://github.com/Consensys/c0 as "AWESOME" post graph-domains program design
**Method:** 3 parallel research agents (c0 deep-dive; remote-execution platforms; orchestration platforms) → architect validation pass → AI-specialist feature take (new `ai-specialist` agent, first dispatch) → architect reconciliation ruling. Remote Control claims independently verified against https://code.claude.com/docs/en/remote-control by the main session.
**Full inputs:** `research-c0.md`, `research-remote-platforms.md`, `research-orchestration-platforms.md`, `architect-ruling.md`, `ai-specialist-take.md` (same directory).

---

## Executive summary

1. **c0 cannot host Nazgul and there is almost nothing to take from it.** The repo is ONE DAY old (created 2026-08-02, 4 squashed commits, 1 contributor, no docs, no announcement, LGPL-3.0, structural Cloudflare lock-in). Decisive architectural fact: it drives Claude Code through Vercel's `@ai-sdk/harness-claude-code` — no hooks, no settings.json, no plugins, no skills, no session resume. Nazgul IS a hook system, so c0 is in the Devin/Factory category (competitor-shaped platform), not the E2B category (substrate). Honest transferable value ≈ one deferred React component (`subagent-group.tsx` nested-agent rendering, read-for-ideas only under LGPL).

2. **The genuinely important finding came from the specialist, not the research: Claude Code Remote Control.** All three research agents missed it. `claude remote-control` gives a browser + mobile window into a LOCAL session — hooks fire, git/gh/stacking intact — with synced subagent progress, steering, auto-reconnect, and mobile push on "Claude decides"/"actions required". Server mode `--spawn worktree --capacity 32` multiplexes sessions each in its own git worktree. This obsoletes the xterm.js terminal panel and service-worker push notifications in Objective C's recorded frontend shape, and answers the operator pain ("monitor my agents from anywhere") that motivated the remote-execution idea — for free, today.

3. **The A/B/C program architecture survives contact with the entire landscape — strengthened, not weakened.** All four binding principles hold. Two independent serious data points (DBOS's library-over-your-database model; builderz-labs' MIT/SQLite single-process Mission Control, 5.9k stars) arrived at exactly the shape Nazgul chose. No durable-workflow engine accepts bash as a workflow language — "adopting" one means rewriting the loop, which is a different product. A loop with an unreachable collector is still a correct loop; every engine destroys that property.

4. **The only lift-and-shift remote host for Nazgul is Claude Code on the web** — the one platform running the real CLI where repo-committed hooks and plugins load. Confirmed blockers: `git push` restricted to the session's current branch (collides with stacking), `gh` not preinstalled (`GH_TOKEN=proxy-injected`), marketplace publication needed, VM reclamation vs gitignored `nazgul/` (a doctrine collision, not a plumbing task). Fallback tier if remote stacking ever becomes non-negotiable: E2B (works first try) or Fly Sprites (persistent microVMs, ~$0.44/4-hr session).

## The verdicts

### c0 (Consensys) — patterns-only, and barely

| Claimed steal | Specialist verdict |
|---|---|
| Cursor-based poll `poll(cursor)→{events,cursor}` | Already the C plan's design; c0 = corroboration. One free refinement: cheap `?probe=1`/HEAD current-cursor call so `/nazgul:fleet` polls many loops cheaply |
| `modelSignature` reuse hash | Reframed: env-drift signature in checkpoints (see inbox item below); c0's form answers a question one-shot dispatch doesn't ask |
| `subagent-group.tsx` | The one real want (Agent View collapses subagents); frontend-spec reference only; LGPL = reimplement |
| `local-sandbox.ts` confinement | IGNORE — `task-state-guard.sh`'s PROJECT_ROOT-bounded gate is already stronger; a second implementation violates house rules |
| Isolate-vs-container split | IGNORE — exists for c0's billing model, which doesn't even apply to its own coding-agent path |

Re-check trigger: an actual Consensys announcement — not a calendar date.

### Remote-execution landscape (objective-D question)

Ranked: (1) **Claude Code on the web + Routines** — engine runs unmodified; four prerequisites (marketplace publish ~already satisfied via `.claude-plugin/marketplace.json`; stacking fail-closed on `CLAUDE_CODE_REMOTE=true`; setup script for gh + gh-stack; `connector-github.sh` tolerating proxy token) plus the real task 1: the state-durability doctrine decision. (2) **E2B / Fly Sprites** raw microVMs if remote stacking is non-negotiable. (3) **Daytona** (AGPL) if self-hosting required. (4) **Managed Agents as design reference only** — its SSE event taxonomy and `ant beta:worker` claim protocol are prior art for the collector schema and any future lease. Not substrates: Codex cloud, Jules, Cursor, Devin, Factory, Blitzy, Agent HQ — each runs its own loop, and Nazgul IS a loop.

Market context: consolidation at the top (SpaceX→Anysphere $60B; Cognition absorbed Windsurf, $25B; Poolside's infra collapse); the sandbox-infra tier still expanding.

### Orchestration landscape (should anything replace/augment the thin registry+collector?)

**No.** IGNORE as loop-driver replacements: Temporal, Restate (BUSL-1.1), Inngest, Trigger.dev, LangGraph Platform (self-host = Enterprise-only), MS Agent Framework, Mastra, CrewAI/AMP, Letta, Vercel Workflow, FleetQ (AGPL, Laravel monolith), Fleet (commercial competitor). They sell active resumption; the stop-hook already has it — you cannot buy the visibility half without operating the durability half. STEAL THE IDEA: DBOS (library-over-existing-DB). FALLBACK if the fleet story outgrows SQLite: Hatchet (MIT, Postgres-only). INTEGRATE narrowly: read builderz-labs Mission Control's data model before freezing the registry schema (their "Aegis" approval-record-row gate is, notably, the exact bookkeeping-not-reality failure Nazgul's doctrine forbids — read for naming, not gate design); name collector columns mappably to Managed Agents' taxonomy. OTel `gen_ai.*`: naming convention, never a contract (no tagged release, no schema URL — verified). WATCH: GitHub Agent HQ as the likeliest commoditizer of the fleet-dashboard layer — a reason to keep the schema mappable, not to wait.

## Architect's final reconciliation (binding recommendations)

**PR #80 pre-merge amendments (~35 lines, 3 files, docs-only):**
1. **Objective C plan** — Goal + Task 5: registry×files primary; Agent View progressive enhancement (join-on-cwd is documented and sound — no registration API needed); unmatched registry row renders in full with `session: -`; absence from Agent View is NEVER a death signal; new test (e).
2. **Objective C plan** — Tasks 3/4: collector gap-detection/resync handshake (server signals expected offset on gap; client rewinds cursor and resends) + one test each — closes the silent-data-loss degradation and makes the projection provably rebuildable from files.
3. **Objective C plan** — Task 4 read-first sentence (builderz-labs data model + Managed Agents taxonomy, names only); Task 6 rationale (`nazgul.*` deliberate, NOT `gen_ai.*`); Task 8 handoff rewording.
4. **Spec §5** — doctrine line names BOTH first-party surfaces (Agent View = background-session lifecycle; Remote Control = remote access + multi-session spawn); C3's **terminal panel and push-notification bullets STRUCK and replaced** by a First-party boundary bullet with a recorded fallback trigger (if Remote Control is unavailable at frontend-spec time — preview withdrawn/ZDR/Bedrock — that spec cycle re-decides; condition recorded, build not pre-committed). §7 out-of-scope: remote-access surface.
5. **Objective B plan** — new timeboxed half-day probe task before Task 2: can `claude remote-control --spawn worktree` compose with `create_feature_worktree()`? Non-blocking — Task 2 ships regardless; probe decides only docs + directory-convention alignment.

**Post-merge inbox items (no plan changes):**
| Item | Priority | Content |
|---|---|---|
| `env-signature-checkpoint.md` | p2 | Hash plugin version/schema/reviewer roster/model/MCP into each checkpoint; stop-hook announces mid-objective drift as a named event. Detection-only v1. Live correctness gap, patch-sized. |
| `remote-control-access.md` (D slice 1) | p6 (pull-forwardable) | Remote-ops docs (tmux for AFK, 10-min outage limit, Ultraplan disconnect) + `/nazgul:doctor` named eligibility check (`disableRemoteControl`, custom `ANTHROPIC_BASE_URL`, the four silent-break env vars; defer to `claude doctor` for the authoritative failed check). |
| `objective-d-cloud-hosting.md` (D slice 2) | p7, spec-gated after B | Task 1 = state-durability doctrine decision; four fail-closed prerequisites + marketplace sha pinning; Managed Agents claim protocol as lease prior art; Sprites/E2B fallback; c0 recheck on Consensys announcement. |

**Priority order unchanged:** bugs → A → B → C. Nothing found reorders it; A remains the only place Nazgul is measurably behind published work.

## Binding principles — all four survive, two strengthened

- **Files stay loop truth** — both landscape reports *depend* on it ("no engine accepts bash"; cloud-survivability analysis).
- **DB is projection** — validated independently twice (DBOS; builderz-labs); the resync amendment tightens it (projection provably rebuildable).
- **Gates on evidence that can't lie** — untouched; the cloud push restriction weakens stacking, not evidence, and fails closed.
- **Degradation always announced** — the reason for amendments 1 and 2: research surfaced two new silent-degradation classes (Agent View partial visibility; collector data loss).

## Verdict on the original instinct

"c0 is AWESOME" — half right. It detected real engineering (clean control-plane primitives, disciplined tooling). The half that fails: it matters to Nazgul almost not at all — wrong abstraction layer (no hooks), wrong vendor shape (welded to Cloudflare), wrong maturity (a day old), wrong license (LGPL). The session's real yield came from what the investigation surfaced *around* it: Remote Control (free frontend for C, discovered because we went looking), the confirmed lift-and-shift path for future remote hosting, and third-party validation of the entire A/B/C architecture.
