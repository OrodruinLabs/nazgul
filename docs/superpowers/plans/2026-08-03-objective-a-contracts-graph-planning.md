# Objective A — Contract-Bound Domains + Graph-Aware Planning: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. (These are external Superpowers-plugin skills, not part of this repo; human contributors can treat them as optional process guides.) Steps use checkbox (`- [ ]`) syntax for tracking. When executed as a Nazgul objective instead, the Nazgul planner derives task manifests from this plan; task boundaries below are the intended manifest boundaries.

**Goal:** Ship the contract-as-ADR convention, planner guidance for domain/contract/wiring decomposition, a plan validator that catches broken task DAGs at plan time, and a fail-open dependency-edge veto gate for parallel batch dispatch.

**Architecture:** All loop machinery stays bash+jq. The veto gate shells out to an external code-graph CLI (probed empirically in Task 1 before any integration code) and degrades announced to today's file-disjointness behavior. The validator reuses the existing, currently-dead `compute_waves()` Kahn layering in `scripts/lib/parallel-batch.sh`. Conventions (contract ADRs, acceptance-criteria honesty scoping) are documentation + planner-prompt changes with zero new mechanism.

**Tech Stack:** bash, jq, git, `code-graph-mcp` CLI (external, optional at runtime), existing test harness (`tests/run-tests.sh`).

**Binding spec:** `docs/superpowers/specs/2026-08-03-graph-domains-concurrency-mission-control-design.md` §2, §3.

## Global Constraints

- Re-ground all file:line references before editing — they were verified 2026-08-03 against the FEAT-027 tree; FEAT-027 (v2.29.0) may have landed since.
- Config schema bump is additive-only, following the newest existing `migrate_N_to_N+1` in `scripts/migrate-config.sh` verbatim (v35→v36 as of grounding; confirm current N first).
- New config keys: `execution.graph.enabled` (default `true`), `execution.graph.tool` (default `"code-graph-mcp"`), `execution.graph.timeout_seconds` (default `10`).
- Every fail-open path emits `graph_tool_degraded` via `emit_event` (numeric fields need the `:n` suffix — see `scripts/lib/emit-event.sh` MF-016 comment).
- Veto-gate edges are computed ONLY between tasks inside the candidate batch; edges into files of tasks outside the batch (e.g. DONE contract tasks) are ignored. This rule is load-bearing for contract-first parallelism — a test must pin it.
- Every batch-rejection path returns through `_pb_single_result "<reason>"`; never introduce a second result shape.
- Shell code passes `bash -n` and `shellcheck`; sourced libs omit `set -e` (documented exception); tests use `set -uo pipefail`.
- The default branch is `main`. Commit messages below are suffixed by Nazgul's dynamic prefix at execution time.

---

### Task 1: Empirical probe — code-graph CLI + `compute_waves` reuse (ADR before integration code)

**Files:**
- Create: `docs/adr/ADR-<next>-code-graph-cli-probe.md` (TRACKED path — `nazgul/docs/` is gitignored, and this ADR is a durable design record the commit step below must actually capture; number sequentially after the highest ADR across both `docs/adr/` and any runtime `nazgul/docs/` ADRs)
- Create (scratch, not committed): probe sandbox under the session scratchpad

**Interfaces:**
- Produces: ADR with a GO/NO-GO verdict and, on GO, the exact CLI invocation shape Task 5 uses (`<tool> <subcommand> <args>` returning edges between two file sets), measured latency envelope, and index-staleness behavior.

- [ ] **Step 1: Install and index.** Install `code-graph-mcp` (github.com/sdsrss/code-graph-mcp, MIT) per its README into the sandbox. Create a fixture repo with two coupled modules (`a.sh` sources `b.sh`; a TS pair `a.ts` imports `b.ts`) and one uncoupled module `c.sh`. Run its index command; record where the index lands (expected `.code-graph/index.db`) and indexing time.
- [ ] **Step 2: Measure edge queries.** Run the CLI's edge-relevant subcommands (`refs`, `callgraph`, `impact`) between file pairs. Record: does it report the a→b edge? Does it correctly report NO edge for c? Latency per query? Behavior when the index is stale (edit a file, query without reindex)?
- [ ] **Step 3: Failure-mode probe.** Run with: tool absent from PATH, corrupted index file, and a 1-second `timeout(1)` wrapper. Record exit codes and stderr for each — Task 5's fail-open branch keys off these.
- [ ] **Step 4: `compute_waves` reuse check.** In this repo, write 4 throwaway task manifests (one diamond: B,C depend on A; D depends on B,C; plus one cycle pair) into a temp dir; source `scripts/lib/parallel-batch.sh` and call `compute_waves` against them. Confirm: diamond → 3 waves with B,C co-waved; cycle → `CYCLE:` error naming members. Record any format friction.
- [ ] **Step 5: Write the ADR.** Sections: Context, Probe Results (tables from steps 1-4), Verdict (GO/NO-GO for `code-graph-mcp`; alternate tool or veto-gate descoping if NO-GO), Binding Design Adjustments (exact invocation, timeout value confirmation, exit-code table), and an Appendix recording every probe command verbatim so the probe is re-runnable (PR #80 review: the probe's verification is its recorded, reproducible results). Follow the FEAT-027 probe-ADR structure (ADR-018, a runtime artifact — mirror its section shape: Context / Probe Results / Verdict / Binding Design Adjustments; the tracked destination is this task's `docs/adr/` path).
- [ ] **Step 6: Commit** the ADR: `docs: ADR — code-graph CLI probe results and binding invocation shape`

### Task 2: Config schema — `execution.graph` (additive migration)

**Files:**
- Modify: `templates/config.json` (add `execution.graph` block; bump `schema_version`)
- Modify: `scripts/migrate-config.sh` (new `migrate_N_to_N+1`)
- Test: `tests/test-migrate-config.sh` (extend)

**Interfaces:**
- Produces: `jq '.execution.graph.enabled // true'`, `.execution.graph.tool // "code-graph-mcp"`, `.execution.graph.timeout_seconds // 10` readable by Tasks 4-5.

- [ ] **Step 1: Write the failing test** in `tests/test-migrate-config.sh`, following that file's newest existing migration test verbatim as a template:

```bash
test_migrate_adds_execution_graph() {
  local cfg="$TEST_DIR/config.json"
  printf '{"schema_version": %s, "execution": {"parallel": false}}' "$OLD_V" > "$cfg"
  run_migration "$cfg"
  assert_eq "$(jq -r '.execution.graph.enabled' "$cfg")" "true" "graph.enabled defaults true"
  assert_eq "$(jq -r '.execution.graph.tool' "$cfg")" "code-graph-mcp" "graph.tool default"
  assert_eq "$(jq -r '.execution.graph.timeout_seconds' "$cfg")" "10" "graph timeout default"
  # explicit false preserved on re-run (idempotence + preserve-explicit-false idiom)
  jq '.execution.graph.enabled = false' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  run_migration "$cfg"
  assert_eq "$(jq -r '.execution.graph.enabled' "$cfg")" "false" "explicit false preserved"
}
```

- [ ] **Step 2: Run** `tests/run-tests.sh --filter=migrate-config` — expect the new test FAILS.
- [ ] **Step 3: Implement** `migrate_N_to_N+1` in `scripts/migrate-config.sh`, copying the newest migration's structure exactly: clamp non-object `.execution` to `{}` guard, set each leaf only `if has(...) | not`, preserve explicit `false`. Bump `templates/config.json` `schema_version` and add the block with defaults.
- [ ] **Step 4: Run** `tests/run-tests.sh --filter=migrate-config` — expect PASS.
- [ ] **Step 5: Commit**: `feat: execution.graph config block (additive schema migration)`

### Task 3: Plan validator — `validate_task_dag()` reusing `compute_waves`

**Files:**
- Modify: `scripts/lib/parallel-batch.sh` (new function beside `compute_waves`)
- Test: `tests/test-parallel-batch.sh` (extend)

**Interfaces:**
- Consumes: `compute_waves`/`_pb_layer_waves` (existing).
- Produces: `validate_task_dag <tasks_dir>` → exit 0 silent on valid; exit 1 with one diagnostic line per defect on stdout, each prefixed `DAG_INVALID:` — forms: `DAG_INVALID: cycle: TASK-002,TASK-003`, `DAG_INVALID: unknown-dep: TASK-004 -> TASK-099`, `DAG_INVALID: premature-ready: TASK-005 (dep TASK-004 is PLANNED)`.

- [ ] **Step 1: Write failing tests** (fixture manifests in a temp dir per case):

```bash
test_validate_dag_detects_cycle() {
  make_manifest TASK-002 "READY" "TASK-003"   # helper writes minimal manifest w/ Depends on
  make_manifest TASK-003 "READY" "TASK-002"
  run_fn validate_task_dag "$TASKS_DIR"
  assert_exit_code 1
  assert_output_contains "DAG_INVALID: cycle:"
}
test_validate_dag_detects_premature_ready() {
  make_manifest TASK-004 "PLANNED" ""
  make_manifest TASK-005 "READY" "TASK-004"
  run_fn validate_task_dag "$TASKS_DIR"
  assert_exit_code 1
  assert_output_contains "premature-ready: TASK-005"
}
test_validate_dag_passes_diamond() {
  make_manifest TASK-001 "DONE" ""; make_manifest TASK-002 "READY" "TASK-001"
  make_manifest TASK-003 "READY" "TASK-001"; make_manifest TASK-004 "PLANNED" "TASK-002, TASK-003"
  run_fn validate_task_dag "$TASKS_DIR"
  assert_exit_code 0
}
```

- [ ] **Step 2: Run** `tests/run-tests.sh --filter=parallel-batch` — new tests FAIL (`validate_task_dag: command not found`).
- [ ] **Step 3: Implement** `validate_task_dag()`: call `compute_waves` (cycle + unknown-dep detection come free — translate its `CYCLE:`/unknown outputs to the `DAG_INVALID:` forms); then one pass over manifests for premature-ready (status READY/IN_PROGRESS while any dep not DONE, statuses via `get_task_status` from `task-utils.sh`). No `set -e` (sourced lib).
- [ ] **Step 4: Run** filter — PASS. Also run `shellcheck scripts/lib/parallel-batch.sh`.
- [ ] **Step 5: Commit**: `feat: validate_task_dag — mechanical plan-DAG validation reusing compute_waves`

### Task 4: Stop-hook planner post-gate (BLOCKED-with-diagnostic, no new stop mechanism)

**Files:**
- Modify: `scripts/stop-hook.sh` (call site after the planner-completion detection point — locate the phase transition where the planner's output is accepted)
- Test: `tests/test-stop-hook.sh` (extend, following its existing gate-test pattern)

**Interfaces:**
- Consumes: `validate_task_dag` (Task 3).
- Produces: on invalid DAG — offending tasks set BLOCKED with `Blocked reason: <the DAG_INVALID line>`, `emit_event "blocked"` per existing idiom, and the loop halts via the existing BLOCKED-task path in `execution_should_halt` (verify that function still halts on any BLOCKED task; if the live code has narrowed, gate through whatever the current halt predicate is).

- [ ] **Step 1: Write failing test**: fixture nazgul/ dir with a cyclic pair post-"planning complete"; run the stop-hook iteration entry; assert both manifests' status becomes BLOCKED, the reason names the cycle, and the hook's decision output shows a halt (reuse the harness's existing stop-hook invocation helpers).
- [ ] **Step 2: Run** `tests/run-tests.sh --filter=stop-hook` — FAIL.
- [ ] **Step 3: Implement** the gate: after planner acceptance, `validate_task_dag "$NAZGUL_DIR/tasks"`; on nonzero, for each named task write BLOCKED through the same guarded write path the reconciliation pass uses, emit the event, fall through to the existing halt.
- [ ] **Step 4: Run** filter — PASS.
- [ ] **Step 5: Commit**: `feat: planner post-gate — invalid task DAG blocks loudly at plan time`

### Task 5: Dependency-edge veto gate in `compute_dispatch_batch` (fail-open, intra-batch-scoped)

**Files:**
- Modify: `scripts/lib/parallel-batch.sh` (new `_pb_cross_scope_edges()`; call inside `compute_dispatch_batch` after the file-overlap pass)
- Test: `tests/test-parallel-batch.sh` (extend; stub tool via PATH shim)

**Interfaces:**
- Consumes: ADR invocation shape (Task 1), `execution.graph.*` config (Task 2), `_pb_single_result` (existing), `emit_event`.
- Produces: `_pb_cross_scope_edges <files_a_csv> <files_b_csv>` → stdout `edge: <src> -> <dst>` lines (empty = none); exit 0 = answered, exit 2 = tool unavailable/failed/timeout (caller degrades).

- [ ] **Step 1: Write failing tests** using a PATH-shim fake tool (the harness pattern for `gh` stubs):

```bash
test_veto_blocks_cross_scope_edge() {          # fake tool reports a.sh -> b.sh
  install_fake_graph_tool "edge"
  result=$(compute_dispatch_batch ...)          # two READY tasks, disjoint files a.sh / b.sh
  assert_eq "$(jq -r '.parallel' <<<"$result")" "false"
  assert_contains "$(jq -r '.reason' <<<"$result")" "cross-scope dependency edge"
}
test_veto_ignores_edge_to_done_task() {        # edge from candidate into DONE contract task's file
  install_fake_graph_tool "edge-to-contract"
  result=$(compute_dispatch_batch ...)          # contract task DONE owns contract.sh; consumers import it
  assert_eq "$(jq -r '.parallel' <<<"$result")" "true"   # LOAD-BEARING: contract-first must survive
}
test_veto_fail_open_tool_absent() {
  remove_fake_graph_tool
  result=$(compute_dispatch_batch ...)
  assert_eq "$(jq -r '.parallel' <<<"$result")" "true"   # today's behavior
  assert_event_emitted "graph_tool_degraded" "reason" "not found"
}
test_veto_disabled_is_not_degraded() {                   # PR #80: disabled != failed
  set_config '.execution.graph.enabled = false'
  install_fake_graph_tool "edge"                          # even with edges present
  result=$(compute_dispatch_batch ...)
  assert_eq "$(jq -r '.parallel' <<<"$result")" "true"   # veto skipped entirely
  assert_no_event_emitted "graph_tool_degraded"           # and NO degradation event
  assert_fake_tool_never_invoked                          # helper not even called
}
test_veto_fail_open_timeout() {
  install_fake_graph_tool "hang"                # sleeps past timeout_seconds
  result=$(compute_dispatch_batch ...)
  assert_eq "$(jq -r '.parallel' <<<"$result")" "true"
  assert_event_emitted "graph_tool_degraded" "reason" "timeout"
}
```

- [ ] **Step 2: Run** filter — FAIL.
- [ ] **Step 3: Implement.** The CALLER (`compute_dispatch_batch`) checks `.execution.graph.enabled` FIRST: false → skip the veto pass entirely, no helper call, no event (disabled is intentional, not degraded — PR #80 review). `_pb_cross_scope_edges` itself: locate tool from `.execution.graph.tool`, wrap invocation in `timeout "$(jq -r '.execution.graph.timeout_seconds // 10' "$CONFIG")"`, parse edges, filter to ONLY pairs where both endpoints are inside the two candidate scopes (the intra-batch rule); exit 2 strictly means tool unavailable/failed/timeout. In `compute_dispatch_batch`: for each surviving candidate pair after file-overlap, call it; edges found → `_pb_single_result "cross-scope dependency edge: $first_edge"`; exit 2 → `emit_event "graph_tool_degraded" reason "<why>" tool "$tool" fallback "file_disjointness"` once for the iteration, continue with today's behavior.
- [ ] **Step 4: Run** filter — PASS; `shellcheck` clean.
- [ ] **Step 5: Commit**: `feat: dependency-edge veto gate — intra-batch scoped, fail-open with graph_tool_degraded`

### Task 6: Planner guidance + contract conventions (docs, zero mechanism)

**Files:**
- Modify: `agents/planner.md` (new subsection "Contract-First Decomposition" between Task Decomposition Rules and Parallel Groups; one added decomposition rule)
- Modify: `RULES.md` (new section: contract-as-ADR convention, binding-citation pattern, consumer/wiring acceptance-criteria honesty scoping, integration-domain model, never-stack-across-domains rule)
- Modify: `templates/task-manifest.md` (comment in Acceptance Criteria section noting the mock-scoped wording for consumer-feature tasks)

**Interfaces:**
- Produces: prose contracts consumed by future planners and by Objective B / the upfront-breakdown item.

- [ ] **Step 1: Write the planner subsection.** Content (spec §3 A4): trigger = producer/consumer layer split within an objective → emit contract task first (interface artifact only, minutes-sized), consumers depend only on it and own their stubs (never listing contract files in Creates/Modifies), wiring task last with stub-deletion + integration-test criteria; cite the contract ADR pattern; note Rule 5's "document why not" escape for first-ever contract tasks.
- [ ] **Step 2: Write the RULES.md section** covering the four conventions above verbatim from spec §3 A4 + §4 B3's stacking rule (cross-reference, since B ships it).
- [ ] **Step 3: Verify docs build/freshness**: run `scripts/gen-skill-docs.sh` check mode if any templated file was touched (planner.md is not templated — confirm; if the live tree templates it, edit the template instead).
- [ ] **Step 4: Commit**: `docs: contract-first decomposition guidance + contract-as-ADR convention`

### Task 7: CLAUDE.md / CHANGELOG / doctor note

**Files:**
- Modify: `CLAUDE.md` (Key Concepts: one paragraph on the veto gate + validator + contract convention; Commands unchanged)
- Modify: `skills/doctor/SKILL.md` + `scripts/doctor.sh` (one new check: `execution.graph.enabled` true but tool absent → advisory "veto gate will run degraded", read-only, text-only)
- Test: `tests/test-doctor.sh` (extend: tool absent → advisory present; tool present → silent)

- [ ] **Step 1: Write failing doctor test** (PATH-shim absence/presence, following existing doctor test pattern).
- [ ] **Step 2: Run** `tests/run-tests.sh --filter=doctor` — FAIL.
- [ ] **Step 3: Implement** the check (never writes state; matches the existing check output format), update CLAUDE.md paragraph and CHANGELOG entry per repo convention.
- [ ] **Step 4: Run** filter — PASS. Run FULL suite `tests/run-tests.sh` — PASS.
- [ ] **Step 5: Commit**: `feat: doctor advisory for degraded graph veto + docs sync`

## Self-review notes (done at plan time)

Spec coverage: §3 A1→Task 1, A2→Tasks 3-4, A3→Task 5, A4→Task 6, A5→Task 2, A6 needs no task (design-compatibility note lives in the spec; the breakdown item consumes conventions when IT is built). Deferred items (§3) intentionally have no tasks. Type consistency: `DAG_INVALID:` prefix and `_pb_cross_scope_edges` exit-code contract used consistently across Tasks 3-5.
