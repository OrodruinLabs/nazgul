# FEAT-013 — 360 Reliability Audit

**Objective:** Evidence-anchored, read-only audit of the entire Nazgul plugin (v2.17.3) producing a verified findings register, structural critique, and dependency-ordered fix roadmap.

**Objective type:** feature (brownfield, analysis-only deliverable — produces documents, not code changes)

**Approved design (PRIMARY reference, read it):** `docs/superpowers/specs/2026-07-22-nazgul-360-audit-design.md`

## Purpose

The operator reports persistent flakiness across the plugin — loop/stop-hook engine, review board, guards & hooks, and parallel/heartbeat/connectors were all named. `nazgul/improvements.md` carries a long open backlog (HITL gate silently degrading to autonomous, resolved-without-verdict-file desync, `APPROVED` status wedging the state guard, the command-parsing arms race) and session memory records more (haiku reviewer stall, emit-event jq bug, review-evidence GROUP-N keying gap, worktree guard escape). This objective performs one comprehensive 360 audit so all reliability debt is found, verified, root-cause-clustered, and consolidated into a single prioritized fix queue — instead of being whack-a-moled incident by incident.

## Scope

**In:**
- All plugin source: `scripts/` (+`lib/`), `skills/`, `agents/`, `hooks/hooks.json`, `templates/`, `references/`, `tests/` (+e2e), `.github/workflows/`, `RULES.md`, docs surface (CLAUDE.md, README).
- This repo's own dogfood runtime evidence: `nazgul/logs/*.jsonl`, `nazgul/reviews/`, `nazgul/checkpoints/`, `nazgul/improvements.md`, config backup sprawl.
- Both audit lenses: reliability (bugs, races, fail-open paths, state-machine holes, test gaps) AND structural critique (overbuilt subsystems, consolidation/removal candidates, config and guard sprawl).

**Out (hard):**
- NO fixes applied — the audit is strictly read-only with respect to plugin code, even for trivial defects. Findings go in the report only.
- NO runtime state from other projects (known other-project incidents already recorded in `improvements.md` count as evidence).
- NO version bump, NO CHANGELOG entry, NO release (nothing ships to the plugin).
- NO remote publishing of any deliverable (no Artifact tool, no gists).

## Method (from the approved design)

1. **Dimensional sweep** — 8 read-only audit dimensions, each with explicit file scope and known anchor incidents that must be root-caused or explicitly cleared:
   1. Loop engine & state machine (stop-hook, checkpoints, compaction, recovery pointer, structured-state; anchors: APPROVED wedge, HITL degradation, evidence gates)
   2. Review board integrity (review-gate, reviewer-selection, provenance, verdict persistence; anchors: resolved-without-file desync, GROUP-N keying gap, granularity drift, reviewer stalls)
   3. Claude-side guards & hooks (pre-tool/task-state/prompt/dispatch/rework guards, hooks.json; anchor: audit remaining command-string parsing against the "enforce at the layer that knows the truth" principle)
   4. Git-level hooks (git-hooks.sh lifecycle, dispatcher, pre-commit/pre-merge-commit, hooksPath self-heal; anchor: worktree guard escape)
   5. Parallel + heartbeat + connectors (parallel-batch, heartbeat + triage + inbox provider, connector-github, teammate report contract, worktree-utils; anchors: teammate-report follow-ups, emit-event jq bug)
   6. Config & file contracts (schema v25 + migration chain, defaults, key sprawl, .bak accumulation, docs-vs-code key drift)
   7. Test suite forensics (what the 65 test files actually prove; unrealistic-input tests, uncovered fail-open branches, vacuous asserts)
   8. Runtime evidence mining (logs/reviews/checkpoints/improvements.md; root-cause each known incident, cross-link to dimensions 1–7)
2. **Dedup & merge** — merge cross-dimension duplicates (agreement = severity signal); drop findings without concrete `file:line` evidence.
3. **Adversarial verification** — every critical/high finding (plus mediums slated for roadmap wave 1) gets an independent skeptic whose sole job is refutation with file:line proof. Survivors = CONFIRMED; unverified ship labeled PLAUSIBLE, never silently upgraded.
4. **Synthesis** — root-cause clusters (grouped by disease, not file), severity-ranked findings register, structural critique, and a fix roadmap of dependency-ordered waves each shaped as a charterable objective (scope, acceptance criteria, findings retired). Open `improvements.md` entries are mapped into the same queue.

Finding record shape: `severity` (critical/high/medium/low), `class` (bug / fragility / architecture / test-gap / docs-drift), `file:line` evidence, concrete failure scenario, recommendation, verification status (CONFIRMED / PLAUSIBLE).

## Constraints

- Working artifacts (per-dimension findings, verification verdicts) live under `nazgul/` runtime state (e.g. `nazgul/context/objectives/FEAT-013/`), never committed.
- Final report: `docs/superpowers/specs/2026-07-22-nazgul-360-audit.md` — local, **uncommitted** (operator rule: specs stay local; work ships later via branch + PR).
- Failed/garbage audit agent → one re-dispatch; on second failure the report states "dimension N partially covered" rather than feigning completeness. Any bounded coverage (sampling, top-N) is disclosed.
- Reviewer board for this objective reviews the AUDIT ARTIFACTS (evidence quality, refutability, coverage), not code diffs.

## Success criteria

1. Every known anchor incident is either root-caused with evidence or explicitly cleared.
2. Every critical/high finding in the report is CONFIRMED by an independent skeptic.
3. The roadmap covers 100% of confirmed critical/high findings.
4. All open `nazgul/improvements.md` items appear in the consolidated queue (folded into a wave, or explicitly rejected with reason).
5. The final report exists at the specified path with all five sections: executive TLDR, root-cause clusters, findings register, structural critique, fix roadmap.
