# Test Reality Audit — August 2026

**Objective:** FEAT-028 / TASK-017
**Audit date:** 2026-08-05
**Objective working base:** `264b40725aabfc6942ea1454dccd3e48e6380da6`
**PR base:** `aac124b66a2bf6a5ee0f9062c5290795b867af63` (`v2.29.0`)
**TASK-017 entry point:** `b76d97b` (after TASK-016)

The working base included seven local-only documentation files unrelated to FEAT-028. They are
excluded from the PR; all non-documentation paths at the two base commits are byte-identical.

This is the retroactive audit required by ADR-019 and PRD AC10. It treats “looked and found none”
as different from “never looked,” assigns exactly one verdict to every in-scope file, and applies the
fix-or-file rule to every finding.

## Scope and method

The current scope contains **118 files**: 93 root `tests/test-*.sh` scripts, 2 files in
`tests/lib/`, 12 files in `tests/e2e/`, and 11 pre-existing files in `tests/fixtures/`. TASK-017 began
with 116 of those files; its two new adversarial root tests bring the final count to 118. The broader
objective began with 86 root test scripts and 25 support/fixture files.

Every file below was read or mechanically traced. The audit checked assertion failure capability,
negative-result error handling, skip accounting, zero-candidate entry paths, stub independence,
fixture independence, producer/consumer seams, and scratch-state setup. New tests generate minimal
Nazgul state inside temporary projects; the fixture scope remains limited to the pre-existing
bootstrap-transform corpus. No file is inferred clean merely because the full suite passed.

`test-audit: 118 scanned, 0 skipped (not-audited=0), 118 checked, 9 findings`

## Verdict summary

| Verdict | Files | Meaning |
|---|---:|---|
| `clean` | 84 | Audited; no unfiled V1–V5 defect found. |
| `vacuous-fixed` | 15 | The test/harness defect was repaired in TASK-017 and has red-capability evidence. |
| `vacuous-filed` | 19 | A real V1/V2/V4 defect remains and is linked to a prioritized inbox item. |
| `not-audited` | 0 | Explicitly empty; no scoped file was omitted. |
| **Total** | **118** | Exactly one verdict per file. |

Before TASK-017, the 15 repaired files and 19 filed files were affected (**34 files**). After the
repairs, 19 files remain affected; none is silently deferred.

## Vacuity counts

Counts here are **distinct finding families per class**, not file rows. One family may cover several
files, and F4 spans V4 and V5.

| Class | Before | After | Disposition |
|---|---:|---:|---|
| V1 — authored golden/fixture | 1 | 1 | F6 filed, p3. |
| V2 — consumer-derived response stub | 1 | 1 | F5 filed, p2. |
| V3 — irrelevant-language guard coverage | 0 | 0 | FEAT-028’s shell guard cases are real repo shapes. |
| V4 — assertion cannot prove behavior | 2 | 1 | F4 fixed; F9 filed, p2. |
| V5 — zero-work/fake-work green | 3 | 0 | F4, F7, and F8 fixed. |

## Findings and dispositions

1. **F1 — pre-tool heredoc reachability gap (adjacent product defect, p2).** Generated hook payloads
   exercise the production guard, so `tests/test-pre-tool-guard.sh` is clean; closing the
   residual shell-redirection heredoc gap requires product code outside this audit.
   See [pre-tool-guard-funnel-heredoc-blind](../nazgul/inbox/pre-tool-guard-funnel-heredoc-blind.md).
2. **F2 — red-run sibling evidence replacement/misattribution (adjacent product defect, p2).**
   `tests/test-red-run-script.sh` drives the real tool and is clean for what it asserts, but the
   writer supports only one generated entry per manifest.
   See [red-run-misattributes-case-labels-across-siblings](../nazgul/inbox/red-run-misattributes-case-labels-across-siblings.md).
3. **F3 — pre-merge commit parser rejects a real bare-SHA producer shape (adjacent product defect, p2).**
   The consuming test creates a scratch Git repository and covers supported commit-list forms, so it
   is clean; the filed parser repair belongs to product code.
   See [premerge-commits-verify-blind-to-bare-sha-line](../nazgul/inbox/premerge-commits-verify-blind-to-bare-sha-line.md).
4. **F4 — shared assertions and skip accounting were vacuous (V4/V5, fixed).** Grep errors, absent
   files, and zero assertions can no longer pass; unavailable checks use a shared counted `_skip`;
   local counter resets were removed. `tests/test-assertion-vacuity.sh` enumerates every repaired
   fake-pass consumer and failed at the objective base before passing after the repair.
5. **F5 — fabricated `gh` response shapes (V2, filed p2).** Four tests replay bytes authored from
   their consumers rather than authenticated captures.
   See [gh-response-shapes-are-fabricated-never-captured](../nazgul/inbox/gh-response-shapes-are-fabricated-never-captured.md).
6. **F6 — bootstrap-transform goldens have no provenance (V1, filed p3).** Independent authorship
   cannot be proved retroactively without fabricating history.
   See [bootstrap-transform-golden-fixtures-have-no-provenance](../nazgul/inbox/bootstrap-transform-golden-fixtures-have-no-provenance.md).
7. **F7 — JSON validation hand-listed only five paths (V5, fixed).** It now discovers all tracked
   plugin JSON, requires load-bearing files, rejects zero coverage, and has a malformed-JSON canary.
8. **F8 — E2E no-work paths returned green (V5, fixed).** The runner and direct bootstrap scenario
   now exit 2 with fixed-grammar accounting when no Claude CLI or no matching scenario is available;
   `tests/test-e2e-harness-shape.sh` was red at the objective base.
9. **F9 — skill E2E assertions cannot distinguish success from an echoed command name (V4, filed p2).**
   Session failures are also swallowed. Mechanical counter/helper defects were repaired, but honest
   semantic assertions require a captured authenticated run.
   See [e2e-skill-tests-assert-the-skill-name-and-swallow-session-failure](../nazgul/inbox/e2e-skill-tests-assert-the-skill-name-and-swallow-session-failure.md).

## Red-capability evidence

- **F4:** `scripts/red-run.sh TASK-017 --filter=assertion-vacuity --copy=tests/test-assertion-vacuity.sh`
  failed at the objective base; the current scoped run is 29/29 green.
- **F7:** the real JSON test was driven against a scratch Git repo containing malformed tracked JSON
  and reported one finding; this is explicitly a canary, not mislabeled as a pre-change red run.
- **F8:** `scripts/red-run.sh TASK-017 --filter=e2e-harness-shape --copy=tests/test-e2e-harness-shape.sh`
  failed at the objective base on “absent claude CLI: exit 2, not 0.”

## Not-audited bucket

**None (0 files).** An authenticated paid Claude session was not executed during this static
retroactive audit, but that does not make the E2E files unaudited: their entry paths, exit handling,
assertions, and fixtures were inspected. The missing live semantic oracle is recorded as F9 rather
than hidden as an omission.

## Per-file verdict ledger

### Root test scripts (93)

| File | Verdict | Basis / disposition |
|---|---|---|
| `tests/test-assertion-vacuity.sh` | `clean` | New adversarial pin for F4; red against the objective base and green after the repair. |
| `tests/test-board-sync-github.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-bootstrap-preflight.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-bootstrap-project.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-bootstrap-relocate.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-bootstrap-render.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-bootstrap-transform.sh` | `vacuous-filed` | F6 (V1, p3): the golden corpus has no provenance, so independent authorship cannot be established. |
| `tests/test-comment-verifier-gate.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-config-schema.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-connector-github.sh` | `vacuous-filed` | F5 (V2, p2): fake `gh` responses were authored from the consumer call sites and have no independent producer oracle. |
| `tests/test-coverage-honesty.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-cross-worktree-resolution.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-doc-verifier-gate.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-doctor.sh` | `vacuous-filed` | F5 (V2, p2): fake `gh` TSV/JSON responses have no independent producer oracle. |
| `tests/test-e2e-harness-shape.sh` | `clean` | New adversarial pin for F8 and the mechanical E2E helper repairs; red against the objective base. |
| `tests/test-emit-event.sh` | `vacuous-fixed` | F4 (V5): unavailable shellcheck checks are counted as skips, never passes. |
| `tests/test-fix-first-classification.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-formatter.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-frontmatter.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-hooks-activation.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-hooks-dispatch.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-hooks-install.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-hooks-precommit.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-hooks-premerge.sh` | `clean` | Scratch Git state covers supported forms; adjacent producer-format incompatibility is filed as F3. |
| `tests/test-git-hooks-wiring.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-git-utils.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-granularity-gate.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-hard-stops.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-idempotency.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-log.sh` | `vacuous-filed` | F5 (V2, p2): the `gh` response stub has no independent producer oracle. |
| `tests/test-heartbeat-session-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-stack.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-start-injection.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-heartbeat-triage.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-hooks-schema.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-hygiene.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-in-flight-hold.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-inbox-provider.sh` | `vacuous-filed` | F5 (V2, p2): fake `gh` issue responses were authored from the consumer and have no independent producer oracle. |
| `tests/test-json-validation.sh` | `vacuous-fixed` | F7 (V5): tracked plugin JSON is discovered rather than hand-listed; zero coverage fails and accounting is emitted. |
| `tests/test-lean-comments-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-learned-rules.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-local-mode-tracking-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-migrate-config.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-model-routing.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-nazgul-root.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-notify.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-observability-hooks.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-one-shot-dispatch.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-parallel-batch.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-parallel-dispatch-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-parallel-rework-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-post-compact.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-pre-compact.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-pre-tool-guard.sh` | `clean` | Generated hook payloads exercise the production guard; the adjacent heredoc product gap is filed as F1. |
| `tests/test-prompt-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-raise-finding.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-red-run-evidence.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-red-run-script.sh` | `clean` | Exercises the real red-run producer; adjacent writer defects are filed as F2 rather than hidden in this verdict. |
| `tests/test-review-contract.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-review-evidence.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-review-gate-docs.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-review-gate-retry.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-review-provenance-gate.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-review-provenance.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-reviewer-readonly.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-reviewer-selection.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-rules-tiers.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-run-tests-harness.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-scrub-stale-review-artifacts.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-self-audit.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-self-improvement.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-session-context.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-session-tracker.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-shellcheck.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-simplifier-agent.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-skill-arguments.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-skill-templates.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-smoke-shape.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-stack-seam.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-stack-utils.sh` | `vacuous-fixed` | F4 (V5): the root-only permission branch is a counted skip, never a fabricated pass. |
| `tests/test-start-flags.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-stop-hook-parallel.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-stop-hook.sh` | `vacuous-fixed` | F4 (V5): unavailable date/conflict branches are counted as skips instead of synthetic passes. |
| `tests/test-structured-state.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-subagent-resume.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-subagent-stop.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-task-state-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-task-transition-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-task-utils.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-team-teardown.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-teammate-idle-guard.sh` | `clean` | Reviewed assertions, fixtures/stubs, failure paths, and entry-point accounting; no V1–V5 issue found. |
| `tests/test-webhook-forward.sh` | `vacuous-fixed` | F4 (V5): an unavailable shellcheck is a counted skip, never a fabricated pass. |
| `tests/test-worktree-utils.sh` | `vacuous-fixed` | F4 (V5): local skip functions and counter resets were removed; the shared counter now covers both conditional branches. |

### Shared test helpers (2)

| File | Verdict | Basis / disposition |
|---|---|---|
| `tests/lib/assertions.sh` | `vacuous-fixed` | F4 (V4/V5): negative assertions now distinguish no-match from grep errors; absent files and zero-assertion runs fail; skips are counted. |
| `tests/lib/setup.sh` | `clean` | Reviewed shared helper behavior and consumers; no V1–V5 issue found. |

### E2E files (12)

| File | Verdict | Basis / disposition |
|---|---|---|
| `tests/e2e/fixtures/minimal-greenfield/.gitkeep` | `clean` | Scenario input, not an expected-output oracle; no V1–V5 issue found in the file. |
| `tests/e2e/fixtures/minimal-greenfield/README.md` | `clean` | Scenario input, not an expected-output oracle; no V1–V5 issue found in the file. |
| `tests/e2e/fixtures/nextjs-brownfield/README.md` | `clean` | Scenario input, not an expected-output oracle; no V1–V5 issue found in the file. |
| `tests/e2e/fixtures/nextjs-brownfield/app/page.tsx` | `clean` | Scenario input, not an expected-output oracle; no V1–V5 issue found in the file. |
| `tests/e2e/fixtures/nextjs-brownfield/package.json` | `clean` | Scenario input, not an expected-output oracle; no V1–V5 issue found in the file. |
| `tests/e2e/lib/session-runner.sh` | `vacuous-filed` | F9 (V4, p2): session failures/timeouts are still swallowed, so callers cannot require a successful run. |
| `tests/e2e/probe-agent-hook.md` | `clean` | Reviewed entry/support behavior; no unfiled V1–V5 issue found. |
| `tests/e2e/run-e2e.sh` | `vacuous-fixed` | F8 (V5): absent CLI and zero-match filters now report NOTHING CHECKED and exit 2 with closed accounting. |
| `tests/e2e/run-stack-e2e.sh` | `clean` | Reviewed entry/support behavior; no unfiled V1–V5 issue found. |
| `tests/e2e/test-bootstrap-project.sh` | `vacuous-fixed` | F8 (V5): an absent Claude CLI is a counted skip and nonzero NOTHING CHECKED result. |
| `tests/e2e/test-init-skill.sh` | `vacuous-filed` | F9 (V4, p2): the only assertion is the invoked skill name and cannot distinguish success from an error echoing that name. |
| `tests/e2e/test-status-skill.sh` | `vacuous-filed` | F9 (V4, p2): the only assertion is Nazgul branding and cannot prove status behavior. |

### Fixture files (11)

| File | Verdict | Basis / disposition |
|---|---|---|
| `tests/fixtures/bootstrap-transform/expected/agents/dirty-prose-reviewer.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/expected/agents/legacy-reviewer.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/expected/context/project-profile.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/expected/docs/PRD.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/expected/docs/TRD.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/agents/dirty-prose-reviewer.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/agents/legacy-reviewer.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/context/project-profile.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/docs/PRD.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/docs/TRD.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
| `tests/fixtures/bootstrap-transform/input/docs/manifest.md` | `vacuous-filed` | F6 (V1, p3): member of the provenance-less bootstrap-transform golden corpus. |
