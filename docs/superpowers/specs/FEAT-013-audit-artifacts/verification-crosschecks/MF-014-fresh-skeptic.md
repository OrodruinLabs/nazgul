# MF-014 — Fresh independent skeptic cross-check (differently-primed)

**Requested by:** TASK-010 security-reviewer (CONDITIONAL) + the verifier itself, both flagging that MF-014's platform-internals half rests on inference about undocumented Claude Code behavior a static check can't reach.
**Skeptic:** fresh general-purpose agent, given ONLY the claim (no dimension narrative).
**Verdict: PARTIALLY-CONFIRMED.**

## Claim under scrutiny
MF-014: review-gate.md dispatches reviewers via the Agent tool without `run_in_background: false`; the Agent tool DEFAULTS to background dispatch; therefore reviewers stall (verdict returns async, unpersisted) — claimed the single highest-recurrence defect (FEAT-009/010/012/013).

## Findings
- **Code-level half — CONFIRMED.** `grep run_in_background|background` over `agents/review-gate.md` + `agents/templates/reviewer-base.md` = zero matches. review-gate.md Step 2 dispatches one Agent call per reviewer and its own prose asserts synchronous semantics ("The single message returns once ALL SELECTED reviewers have completed"). So the code omits the flag AND assumes synchrony.
- **Platform-behavior half — NOT independently established.** The "defaults to background" mechanism rests on one quoted tool-description line ("Agents run in the background by default…"). The in-repo empirical probe (`probe-agent-hook.md`, 2026-07-08) only shows `run_in_background` is *absent from the logged tool_input* when unset — a fact about the logged payload, not proof of internal default execution. FEAT-010's evidence tested explicit-true vs explicit-false, never the *omitted* case that review-gate.md actually hits.
- **Stalls are real but MULTI-CAUSAL, not one mechanism:**
  1. `maxTurns: 12` (`reviewer-base.md:14`) + open-ended exploration prompts → turn-budget exhaustion before the verdict block (fully explains FEAT-012 TASK-007 RT-01, no background theory needed).
  2. Haiku-tier format non-adherence (FEAT-009 improvements.md:282-286 names model capability, not dispatch mode).
  3. Historically-explicit `run_in_background: true` (FEAT-010) — real, but since removed from the design.
  4. **This FEAT-013 run's own stalls come from Agent-Teams `SendMessage` fan-out, which is async-by-design — a DIFFERENT dispatch primitive than review-gate.md's Agent-tool path.** Citing RT-06 as corroboration for the review-gate.md code gap is a path mismatch.

## Consequence for the register
MF-014's SYMPTOM (reviewer verdict-capture stalls recur and cost real reliability) is CONFIRMED and cross-objective. Its single-mechanism FRAMING ("Agent tool defaults to background") is PARTIALLY-CONFIRMED at best and should be reframed as one hypothesis among several. The roadmap fix must be multi-pronged (raise/remove maxTurns cap for reviewers, pin synchronous dispatch defensively, enforce verdict-schema-or-retry, and separately handle Agent-Teams async persistence) — not just "add run_in_background: false", which would not address the turn-budget or Agent-Teams causes. This is a live experiment worth running before committing fix effort.
