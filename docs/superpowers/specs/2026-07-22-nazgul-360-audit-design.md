# Nazgul Plugin 360 Audit — Design

**Date:** 2026-07-22
**Status:** Approved design, pending execution
**Trigger:** Operator report: "too many flaky things about the plugin that are not working as expected" — full 360 deep analysis requested to find gaps and recommendations.

## Goal

A comprehensive, evidence-anchored audit of the entire Nazgul plugin (v2.17.3) that produces:

1. A verified, severity-ranked **findings register** (reliability bugs, fragility, test gaps, docs drift).
2. A **structural critique** — challenge-everything review of architecture: overbuilt subsystems, consolidation/removal candidates, config and guard sprawl.
3. A dependency-ordered **fix roadmap** shaped as ready-to-charter Nazgul objectives (FEAT-013+), consolidating both new findings and the open `nazgul/improvements.md` backlog into one queue.

## Scope

- **In:** All plugin source — `scripts/` (~30 scripts + `lib/`), `skills/` (~25), `agents/` (22 + templates), `hooks/hooks.json`, `templates/`, `references/`, `tests/` (65 files + e2e), `.github/workflows/`, `RULES.md`, CLAUDE.md/README docs surface. Plus this repo's own dogfood runtime evidence: `nazgul/logs/*.jsonl`, `nazgul/reviews/`, `nazgul/checkpoints/`, `nazgul/improvements.md`, config backup sprawl.
- **Out:** Runtime state from other projects (known incidents from them already recorded in `improvements.md` count as evidence). Applying fixes — the audit run is strictly read-only.

## Method: 8 parallel dimensions + adversarial verification + in-context synthesis

### Phase 1 — Dimensional sweep (8 read-only agents, parallel)

Each agent owns one dimension with an explicit file scope and reports BOTH reliability findings and structural critique for its territory. Structured return per finding: `severity` (critical/high/medium/low), `class` (bug / fragility / architecture / test-gap / docs-drift), `file:line` evidence, concrete failure scenario, recommendation.

| # | Dimension | Primary scope | Known anchors (must be root-caused or cleared) |
|---|-----------|---------------|-----------------------------------------------|
| 1 | Loop engine & state machine | `stop-hook.sh`, pre/post-compact, session-context/staging, checkpoints, recovery pointer contract, `lib/task-utils.sh`, structured-state | `APPROVED` status wedges state guard; evidence-gate integrity; resume-after-compaction; HITL gate silently degrading to autonomous |
| 2 | Review board integrity | `agents/review-gate.md`, `lib/reviewer-selection.sh`, `lib/review-provenance.sh`, feedback-aggregator, verdict persistence, UNVERIFIED paths | resolved-without-verdict-file desync; group-vs-task granularity drift; GROUP-N review-evidence keying gap; reviewer stalls |
| 3 | Claude-side guards & hooks | `pre-tool-guard.sh`, `task-state-guard.sh`, `prompt-guard.sh`, parallel dispatch/rework guards, `hooks/hooks.json`, notify/webhook/formatter | audit every remaining command-string-parsing guard against the proven "enforce at the layer that knows the truth" principle; false-positive history |
| 4 | Git-level hooks | `lib/git-hooks.sh`, `scripts/git-hooks/` (dispatcher, pre-commit, pre-merge-commit), `core.hooksPath` lifecycle/self-heal | deferred worktree guard escape; chain-dispatch to pre-existing user hooks |
| 5 | Parallel + heartbeat + connectors | `lib/parallel-batch.sh`, `heartbeat.sh`, `lib/heartbeat-triage.sh`, `lib/inbox-provider.sh`, `lib/connector-github.sh`, teammate report contract, `worktree-utils.sh` | teammate-report follow-ups (fail-open branches, label sweep, first-run telemetry); emit-event jq bug |
| 6 | Config & file contracts | config schema (v24) + `migrate-config.sh` chain, defaults, key naming, runtime file contracts | `config.json.v*.bak` accumulation in `nazgul/`; docs-vs-code drift for every documented config key |
| 7 | Test suite forensics | `tests/` — what the 65 files actually prove | unrealistic-input tests (pre-tool-guard raw-envelope lesson); fail-open branches with zero coverage; vacuous asserts |
| 8 | Runtime evidence mining | `nazgul/logs/`, `reviews/`, `checkpoints/`, `improvements.md`, session-memory incident list | root-cause each real incident (haiku reviewer stall, emit-event jq bug, self-audit path bugs, HITL degradation) and cross-link to dimensions 1–7 |

### Phase 2 — Dedup & merge

Collect all findings; merge duplicates surfaced by multiple dimensions (cross-dimension agreement is a severity signal); drop anything lacking concrete `file:line` evidence.

### Phase 3 — Adversarial verification

Every critical/high finding — plus any medium slated for roadmap wave 1 — gets a fresh skeptic agent whose sole job is refutation with file:line proof. Skeptic-killed findings are demoted or dropped. Survivors are marked **CONFIRMED**; unverified findings ship labeled **PLAUSIBLE**, never silently upgraded.

### Phase 4 — Synthesis (orchestrator, in-context — not delegated)

Cross-cutting judgment stays with the orchestrator: root-cause clustering (group by underlying disease, not by file), the structural critique, and roadmap dependency ordering (foundation fixes first — e.g., state-machine wedges before review-board fixes that depend on them).

## Deliverables

- **Report:** `docs/superpowers/specs/2026-07-22-nazgul-360-audit.md` — local, **uncommitted** (operator's standing rule: specs stay local; work ships via branch + PR). Sections: executive TLDR; root-cause clusters; findings register (severity-ranked, CONFIRMED/PLAUSIBLE labeled); structural critique; fix roadmap.
- **Roadmap format:** dependency-ordered waves, each shaped as a charterable Nazgul objective (scope, acceptance criteria, which findings it retires). Open `improvements.md` entries mapped in so there is ONE consolidated queue.
- **Chat TLDR:** top confirmed findings, clusters, proposed wave order.
- **No remote publishing** (no Artifact tool) per standing rule.

## Error handling & honesty rules

- Audit run is read-only; no fixes applied mid-audit, even trivial ones.
- Failed/garbage agent → one re-dispatch; on second failure the report states "dimension N partially covered" instead of feigning completeness.
- No silent caps: any bounded coverage (sampling, top-N) is disclosed in the report.

## After the audit

Operator reviews the report, green-lights wave(s); then either the writing-plans skill turns wave 1 into an implementation plan, or the wave is chartered as a Nazgul objective and the loop dogfoods its own repairs. That choice is deferred until the report exists.

## Testing this design

The audit's own success criteria: (1) every known anchor incident is either root-caused with evidence or explicitly cleared; (2) every critical/high finding in the report is CONFIRMED by an independent skeptic; (3) the roadmap covers 100% of confirmed critical/high findings; (4) `improvements.md` open items all appear in the consolidated queue (fixed, folded, or explicitly rejected with reason).
