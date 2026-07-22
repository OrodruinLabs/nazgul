# TRD: FEAT-013 — 360 Reliability Audit (Execution Design)

**Release:** NONE — analysis-only, no version bump, no CHANGELOG · **Schema:** unchanged (v25) · **Feat ID:** FEAT-013

## Summary
An evidence-anchored, strictly READ-ONLY audit of the entire Nazgul plugin (v2.17.3). The
deliverables are documents, not code: (1) a verified, severity-ranked findings register, (2) a
structural critique, (3) a dependency-ordered fix roadmap consolidating new findings with the open
`nazgul/improvements.md` backlog into one queue. Method: 8 parallel read-only dimensional sweeps →
dedup & merge → adversarial verification of critical/high findings → in-context synthesis by the
orchestrator. No plugin source file is modified at any point; the final report stays local and
uncommitted.

## Prior Documentation
- `nazgul/context/objectives/FEAT-013-spec.md` — PRIMARY per-idea spec: purpose, scope, method,
  constraints, success criteria. Its Purpose section serves as the PRD for this objective (no
  separate PRD generated).
- `docs/superpowers/specs/2026-07-22-nazgul-360-audit-design.md` — the approved design the spec
  mirrors: phase model, dimension table, honesty rules, post-audit handoff.
- `nazgul/context/discovery-summary.md` — brownfield classification, bash+jq stack, COMPREHENSIVE
  docs posture.
- `nazgul/improvements.md` + session-memory incident list — the known-incident corpus that seeds
  the anchor lists below.

## Execution Architecture

### Phase 1 — Dimensional sweep (8 read-only agents, parallel)
Each agent owns one dimension with an explicit file scope and reports BOTH reliability findings and
structural critique for its territory. Every known anchor incident must be root-caused with evidence
or explicitly cleared.

| # | Dimension | File scope | Known anchors (root-cause or clear) |
|---|-----------|-----------|-------------------------------------|
| 1 | Loop engine & state machine | `scripts/stop-hook.sh`, `scripts/pre-compact.sh`, `scripts/post-compact.sh`, `scripts/session-context.sh`, `scripts/session-staging.sh`, checkpoints, recovery pointer contract, `scripts/lib/task-utils.sh`, structured-state | `APPROVED` status wedges the state guard; HITL gate silently degrading to autonomous; evidence-gate integrity; resume-after-compaction |
| 2 | Review board integrity | `agents/review-gate.md`, `scripts/lib/reviewer-selection.sh`, `scripts/lib/review-provenance.sh`, feedback-aggregator, verdict persistence, UNVERIFIED paths | resolved-without-verdict-file desync; GROUP-N review-evidence keying gap; group-vs-task granularity drift; reviewer stalls (haiku) |
| 3 | Claude-side guards & hooks | `scripts/pre-tool-guard.sh`, `scripts/task-state-guard.sh`, `scripts/prompt-guard.sh`, `scripts/parallel-dispatch-guard.sh`, `scripts/parallel-rework-guard.sh`, `hooks/hooks.json`, notify/webhook/formatter | audit every remaining command-string-parsing guard against the proven "enforce at the layer that knows the truth" principle; false-positive history |
| 4 | Git-level hooks | `scripts/lib/git-hooks.sh`, `scripts/git-hooks/` (`_dispatch.sh`, `pre-commit`, `pre-merge-commit`), `core.hooksPath` lifecycle/self-heal | deferred worktree guard escape; chain-dispatch to pre-existing user hooks |
| 5 | Parallel + heartbeat + connectors | `scripts/lib/parallel-batch.sh`, `scripts/heartbeat.sh`, `scripts/lib/heartbeat-triage.sh`, `scripts/lib/inbox-provider.sh`, `scripts/lib/connector-github.sh`, teammate report contract, `scripts/worktree-utils.sh` | teammate-report follow-ups (fail-open branches, label sweep, first-run telemetry); emit-event jq bug |
| 6 | Config & file contracts | config schema v25 + `scripts/migrate-config.sh` migration chain, defaults, key naming/sprawl, runtime file contracts | `config.json.v*.bak` accumulation in `nazgul/`; docs-vs-code drift for every documented config key |
| 7 | Test suite forensics | `tests/` (65 unit/integration files + e2e) — what the tests actually prove | unrealistic-input tests (pre-tool-guard raw-envelope lesson); fail-open branches with zero coverage; vacuous asserts |
| 8 | Runtime evidence mining | `nazgul/logs/*.jsonl`, `nazgul/reviews/`, `nazgul/checkpoints/`, `nazgul/improvements.md`, session-memory incident list | root-cause each real incident (haiku reviewer stall, emit-event jq bug, self-audit path bugs, HITL degradation) and cross-link to dimensions 1–7 |

Also in overall scope (covered across dimensions): `skills/` (~25), `agents/` (22 + templates),
`templates/`, `references/`, `.github/workflows/`, `RULES.md`, CLAUDE.md/README docs surface.

### Phase 2 — Dedup & merge
- Collect all findings across dimensions; merge cross-dimension duplicates into one record listing
  every reporting dimension.
- Cross-dimension agreement is a **severity signal** (independent rediscovery raises confidence,
  may raise severity).
- **Hard drop rule:** any finding lacking concrete `file:line` evidence is dropped, regardless of
  severity claimed.

### Phase 3 — Adversarial verification
- **Bar:** every critical and high finding, PLUS any medium slated for roadmap wave 1.
- Each such finding gets a fresh, independent skeptic agent whose sole job is refutation with
  `file:line` proof.
- Skeptic-killed findings are demoted or dropped. Survivors are marked **CONFIRMED**.
- Findings not put through verification ship labeled **PLAUSIBLE** — never silently upgraded to
  CONFIRMED.

### Phase 4 — Synthesis (orchestrator, in-context — not delegated)
Cross-cutting judgment stays with the orchestrator: root-cause clustering (group by underlying
disease, not by file), the structural critique, and roadmap dependency ordering (foundation fixes
first — e.g., state-machine wedges before review-board fixes that depend on them). Open
`improvements.md` entries are mapped into the same queue (folded into a wave, or explicitly rejected
with reason).

## Finding Record Shape
Every finding is a structured record:

| Field | Values / form |
|-------|---------------|
| `severity` | critical / high / medium / low |
| `class` | bug / fragility / architecture / test-gap / docs-drift |
| `evidence` | concrete `file:line` reference(s) — mandatory; no evidence → dropped |
| `failure scenario` | concrete description of how it goes wrong in practice |
| `recommendation` | proposed remediation direction |
| `verification status` | CONFIRMED (survived a skeptic) / PLAUSIBLE (not adversarially verified) |

## Report Structure
Final report: `docs/superpowers/specs/2026-07-22-nazgul-360-audit.md` — local, **uncommitted**.
Five mandatory sections, in order:
1. **Executive TLDR** — top confirmed findings, clusters, proposed wave order.
2. **Root-cause clusters** — grouped by disease, not file.
3. **Findings register** — severity-ranked, CONFIRMED/PLAUSIBLE labeled, `file:line` anchored.
4. **Structural critique** — overbuilt subsystems, consolidation/removal candidates, config and
   guard sprawl.
5. **Fix roadmap** — dependency-ordered waves, each shaped as a charterable Nazgul objective
   (scope, acceptance criteria, which findings it retires); `improvements.md` items consolidated in.

A chat TLDR accompanies the report. No remote publishing (no Artifact tool, no gists).

## Artifact Locations
- **Working artifacts** (per-dimension findings, skeptic verdicts):
  `nazgul/context/objectives/FEAT-013/` — runtime state, never committed.
- **Final report:** `docs/superpowers/specs/2026-07-22-nazgul-360-audit.md` — uncommitted (operator
  rule: specs stay local; work ships later via branch + PR).

## Error Handling & Honesty Rules
- Strictly read-only w.r.t. plugin code — no fixes applied mid-audit, even trivial ones; findings
  go in the report only.
- Failed/garbage audit agent → exactly one re-dispatch; on second failure the report states
  "dimension N partially covered" rather than feigning completeness.
- No silent caps: any bounded coverage (sampling, top-N) is disclosed in the report.
- No runtime state from other projects is read (other-project incidents already recorded in
  `improvements.md` count as evidence).

## Review Gate Adaptation
The review board for this objective reviews the **audit artifacts** — evidence quality (real
`file:line`?), refutability (would a skeptic have material to attack?), and coverage (all anchors
addressed, scope complete?) — NOT code diffs, because there are no code diffs. See ADR-001.

## Acceptance Criteria (from spec)
1. Every known anchor incident is either root-caused with evidence or explicitly cleared.
2. Every critical/high finding in the report is CONFIRMED by an independent skeptic.
3. The roadmap covers 100% of confirmed critical/high findings.
4. All open `nazgul/improvements.md` items appear in the consolidated queue (folded into a wave, or
   explicitly rejected with reason).
5. The final report exists at the specified path with all five sections present.
