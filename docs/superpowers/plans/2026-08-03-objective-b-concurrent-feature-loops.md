# Objective B — Concurrent Feature Loops (Worktree-per-Feature): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. (These are external Superpowers-plugin skills, not part of this repo; human contributors can treat them as optional process guides.) Steps use checkbox (`- [ ]`) syntax for tracking. When executed as a Nazgul objective instead, the Nazgul planner derives task manifests from this plan; task boundaries below are the intended manifest boundaries.

**Goal:** Make two or more Nazgul feature loops runnable simultaneously in sibling git worktrees — each with its own private `nazgul/` state — with per-domain PR stacks, a git-truth `requires:` gate for the integration domain, and doctor checks for the two footguns.

**Architecture:** Per-worktree state isolation already exists (`resolve_project_root()` is worktree-scoped and `nazgul/` is gitignored) — this objective adds only the missing mechanics: a feature-worktree constructor, a worktree-scoped `core.hooksPath` install (fixes a real cross-worktree clobber bug that ships for ALL users), the requires-gate (branch-ancestry evidence, dual-path, fail-closed loudly), and doctor visibility. No state-path changes, no stop-hook changes, no schema-shape changes beyond additive keys if the requires-escalation counter needs one.

**Tech Stack:** bash, jq, git (worktrees, `merge-base --is-ancestor`, `config --worktree`), existing test harness.

**Binding spec:** `docs/superpowers/specs/2026-08-03-graph-domains-concurrency-mission-control-design.md` §2, §4.

## Global Constraints

- Re-ground all file:line references before editing (verified 2026-08-03; FEAT-027 may have moved them — `stack-utils.sh` line numbers especially).
- Feature "done" evidence = `git merge-base --is-ancestor <tip> <branch.base>` — NEVER PR `mergedAt`, NEVER `objectives_history`.
- `requires:` is a comma-separated string frontmatter key (no YAML arrays in this format), read raw off the candidate file like the existing `branch:`/`pr:` keys.
- Two distinct not-ready reasons, never shared: `requires_unmerged` (quiet, expected) vs `requires_unresolvable` (escalates after 3 consecutive ticks → p1 inbox item, mirroring `_su_file_conflict_inbox`).
- A skipped candidate is always visible: additive `requires_skipped` field on the heartbeat decision record.
- The requires check runs on BOTH paths: `heartbeat.sh` and `skills/start/SKILL.md` (dual-path precedent: stack cap).
- Never stack across domains: concurrent domain features branch as siblings off `main` (existing non-stacking path); stacks are per-worktree/per-domain only.
- Shell rules as repo standard (`bash -n`, `shellcheck`, sourced libs without `set -e`, tests `set -uo pipefail`).

---

### Task 1: Fix — worktree-scoped git-hooks install (ships for all users)

**Files:**
- Modify: `scripts/lib/git-hooks.sh` (`install_git_hooks`, uninstall/self-heal paths)
- Test: `tests/test-git-hooks.sh` (extend)

**Interfaces:**
- Produces: `install_git_hooks` writes `core.hooksPath` per-worktree; behavior unchanged for single-worktree repos.

- [ ] **Step 1: Write the failing regression test** — the clobber bug itself:

```bash
test_second_worktree_install_does_not_disarm_first() {
  setup_repo_with_nazgul                      # main checkout, hooks installed
  git -C "$REPO" worktree add "$WT2" -b feat/b main
  mkdir -p "$WT2/nazgul"; cp -R "$REPO/nazgul/.githooks" "$WT2/nazgul/"
  (cd "$WT2" && install_git_hooks "$WT2")     # second install
  # main checkout's effective hooksPath must still resolve to ITS OWN managed dir
  local main_hp; main_hp=$(git -C "$REPO" config core.hooksPath)
  assert_contains "$main_hp" "nazgul/.githooks"
  # and a guarded commit in the main checkout must still hit the guard
  assert_hook_fires_in "$REPO"                # helper: attempts a base-branch commit, expects block
}
```

- [ ] **Step 2: Run** `tests/run-tests.sh --filter=git-hooks` — FAIL (second install clobbers; main checkout's guard no longer fires or points at WT2's dir).
- [ ] **Step 3: Implement**: in `install_git_hooks`, before writing the path: `git -C "$project_root" config extensions.worktreeConfig true` (idempotent), then `git -C "$project_root" config --worktree core.hooksPath "$_GH_MANAGED_RELDIR"`. Mirror in uninstall (`--worktree --unset`) and the self-heal drift check (compare against the worktree-scoped value). Guard for ancient git without `--worktree` support: detect via `git config --worktree --get core.hooksPath 2>/dev/null; [ $? -ne 129 ]`-style probe; if unsupported, fall back to the old write and emit a stderr warning naming the multi-worktree hazard (announced degradation).
- [ ] **Step 4: Run** filter — PASS. Confirm existing single-worktree git-hooks tests still pass unchanged.
- [ ] **Step 5: Commit**: `fix: worktree-scoped core.hooksPath — second feature worktree no longer disarms the first's guards`

> **Amendment (2026-08-16, messaging-adoption cycle):** Task 1 (the SPATIAL per-worktree hooksPath fix) additionally inherits the TEMPORAL question this cycle filed: what protects the base branch between objectives, given the pre-commit guard's own predicate exits when branch.feature is empty? Sequencing: spatial scoping lands first or together — an install-more-often change before spatial scoping aggravates the clobber. /nazgul:clean now restores core.hooksPath (2026-08-16); cleanup_all_worktrees' uninstall is unchanged by that cycle.

### Task 1.5: Probe — Remote Control server-mode composability (timeboxed, non-blocking)

Half-day timebox, before Task 2 freezes the worktree directory convention (2026-08-03
platform research). Question: can a `claude remote-control --spawn worktree` server-mode
session adopt — or be pointed at — a pre-created named worktree + branch off a chosen
base, with its own `nazgul/` brain and hooks firing? Deliverable: ADR appendix with the
commands recorded verbatim (Objective A probe precedent, spec §6) AND an explicit
pass/fail result per check (CodeRabbit PR #82):
(1) session CWD equals the pre-created worktree path; (2) branch and base preserved
(`git branch --show-current`, `git merge-base`); (3) `resolve_project_root()` from inside
the session resolves to the worktree; (4) worktree-scoped git hooks fire (Task 1's
guards); (5) state writes land under that worktree's `nazgul/` tree. Any check without a
recorded result → the probe is INCONCLUSIVE, same as the timebox case below.

**Non-blocking:** Task 2 ships regardless of the outcome — branch naming and base-branch
choice are Nazgul stacking policy, and no first-party spawner supplies them. The probe
decides only: (a) whether Task 5's operator docs gain a "server-mode session hosting"
paragraph (`claude remote-control --spawn worktree` as the session multiplexer above
Nazgul-created worktrees); (b) whether the `<repo>-worktrees/<feat_id>` directory
convention needs aligning with what server mode can serve. Inconclusive at timebox →
record that and proceed unchanged.

### Task 2: `create_feature_worktree()` (self-contained feature sandbox)

**Files:**
- Modify: `scripts/worktree-utils.sh` (new function after `create_feature_branch`)
- Test: `tests/test-worktree-utils.sh` (extend)

**Interfaces:**
- Consumes: `slugify_objective`, `install_git_hooks` (Task 1 version).
- Produces: `create_feature_worktree <objective> <feat_id> [base_branch]` → creates `<repo>-worktrees/<feat_id>` at branch `feat/<feat_id>-<slug>` off `<base_branch>` (default `main`), prints the worktree path. Does NOT export `CLAUDE_PROJECT_DIR` (a feature worktree owns its own brain — the exact inverse of `create_task_worktree`). Appends to the Objective C registry IF `~/.nazgul/registry.json` exists (soft integration; C owns creating it).

- [ ] **Step 1: Write failing tests**:

```bash
test_create_feature_worktree_is_self_contained() {
  wt=$(create_feature_worktree "backend api" "FEAT-B")
  assert_dir_exists "$wt"
  assert_eq "$(git -C "$wt" branch --show-current)" "feat/FEAT-B-backend-api"
  assert_file_not_exists "$wt/nazgul/config.json"   # fresh brain; init happens inside it
  # resolver isolation: from inside wt, project root must be wt itself
  assert_eq "$(cd "$wt" && resolve_project_root)" "$wt"
}
test_create_feature_worktree_branches_off_main_not_current() {
  git -C "$REPO" checkout -b feat/other main
  wt=$(create_feature_worktree "frontend" "FEAT-C")
  assert_eq "$(git -C "$wt" merge-base HEAD main)" "$(git -C "$REPO" rev-parse main)"
}
```

- [ ] **Step 2: Run** `tests/run-tests.sh --filter=worktree-utils` — FAIL.
- [ ] **Step 3: Implement** mirroring `create_task_worktree`'s add/error-handling shape: `git -C "$project_root" worktree add "$dir" -b "$branch" "$base"`, call `install_git_hooks "$dir"` (worktree-scoped per Task 1), registry append guarded by file existence, no env exports.
- [ ] **Step 4: Run** filter — PASS; `shellcheck` clean.
- [ ] **Step 5: Commit**: `feat: create_feature_worktree — self-contained sibling worktree for a concurrent feature loop`

### Task 3: Requires-gate library — parse + resolve + verdict

**Files:**
- Create: `scripts/lib/requires-gate.sh` (sourced lib, no `set -e`)
- Modify: `scripts/lib/inbox-provider.sh` (`_inbox_yaml_val` gains no changes; new one-line raw read for `requires` mirroring the `branch:`/`pr:` sed in skills/start)
- Test: `tests/test-requires-gate.sh` (new)

**Interfaces:**
- Produces:
  - `rg_parse_requires <candidate_file>` → newline list of FEAT ids (empty if key absent)
  - `rg_check_requirement <feat_id> <base_branch> <repo_root>` → exit 0 `satisfied`; exit 3 `unmerged` (branch found, not ancestor); exit 4 `unresolvable` (no branch matching `feat/<feat_id>-*` locally or on origin); exit 5 `ambiguous` (MULTIPLE refs match one id — never newest-wins, PR #80 review catch; treated like unresolvable downstream: skip loudly + escalate)
  - `rg_gate <candidate_file> <base_branch> <repo_root>` → stdout one word: `satisfied` | `unmerged:<id>` | `unresolvable:<id>` | `ambiguous:<id>` (first blocker wins), exit 0/3/4/5 to match

- [ ] **Step 1: Write failing tests** (fixture repo with real branches/merges):

```bash
test_requires_satisfied_when_merged() {
  make_branch_and_merge "feat/FEAT-B-api" main
  echo 'requires: FEAT-B' | make_candidate
  run_fn rg_gate "$CANDIDATE" main "$REPO"; assert_exit_code 0; assert_output "satisfied"
}
test_requires_unmerged_when_branch_open() {
  make_branch "feat/FEAT-B-api" main "one commit, unmerged"
  echo 'requires: FEAT-B' | make_candidate
  run_fn rg_gate "$CANDIDATE" main "$REPO"; assert_exit_code 3; assert_output "unmerged:FEAT-B"
}
test_requires_unresolvable_when_no_branch() {
  echo 'requires: FEAT-ZZ' | make_candidate
  run_fn rg_gate "$CANDIDATE" main "$REPO"; assert_exit_code 4; assert_output "unresolvable:FEAT-ZZ"
}
test_requires_comma_list_first_blocker_wins() {
  make_branch_and_merge "feat/FEAT-B-api" main
  echo 'requires: FEAT-B, FEAT-C' | make_candidate   # C never started
  run_fn rg_gate "$CANDIDATE" main "$REPO"; assert_exit_code 4; assert_output "unresolvable:FEAT-C"
}
test_stacked_layer_pr_merged_but_content_not_in_main_is_unmerged() {
  # branch exists whose tip is NOT ancestor of main even though a PR object might say merged:
  make_branch "feat/FEAT-B-api" main "diverged"
  echo 'requires: FEAT-B' | make_candidate
  run_fn rg_gate "$CANDIDATE" main "$REPO"; assert_exit_code 3   # ancestry is the only witness
}
```

- [ ] **Step 2: Run** `tests/run-tests.sh --filter=requires-gate` — FAIL.
- [ ] **Step 3: Implement**: parse via `sed -n 's/^requires:[[:space:]]*//p' | tr ',' '\n'` trimmed; resolve via `git -C "$repo" for-each-ref 'refs/heads/feat/<id>-*' 'refs/remotes/origin/feat/<id>-*'`, deduping local/remote pairs of the SAME branch name; >1 distinct branch name for one id → `ambiguous` (exit 5); exactly one → verdict via `git merge-base --is-ancestor "$tip" "refs/heads/$base"` (fall back to `origin/$base` when local base absent). Add a test: two distinct `feat/FEAT-B-*` branches → `ambiguous:FEAT-B`, exit 5.
- [ ] **Step 4: Run** filter — PASS; `shellcheck` clean.
- [ ] **Step 5: Commit**: `feat: requires-gate lib — feature-level dependency verdict from branch ancestry`

### Task 4: Heartbeat enforcement — filter, visible skip, escalation

**Files:**
- Modify: `scripts/lib/heartbeat-triage.sh` (`heartbeat_pick`: requires-filter before final sort/pick)
- Modify: `scripts/heartbeat.sh` (source requires-gate lib; decision-record field; escalation counter + p1 filing)
- Test: `tests/test-heartbeat-triage.sh`, `tests/test-heartbeat.sh` (extend)

**Interfaces:**
- Consumes: `rg_gate` (Task 3).
- Produces: unsatisfied candidates skipped in-tick (next eligible wins); decision record gains `requires_skipped: [{id, reason}]`; `unresolvable` for the same candidate 3 consecutive ticks → p1 inbox item `requires-unresolvable-<feat_id>.md` filed once (counter persisted in the candidate's own frontmatter, `requires_unresolvable_ticks: N`, additive).

- [ ] **Step 1: Write failing tests**: (a) tick with wiring candidate `requires: FEAT-B` unmerged + a second eligible candidate → second one picked AND decision record lists the skip; (b) all candidates skipped → tick ends idle with `requires_skipped` populated (not silent); (c) unresolvable candidate ticked 3x → p1 item exists, filed exactly once on further ticks.
- [ ] **Step 2: Run** filters — FAIL.
- [ ] **Step 3: Implement**: in `heartbeat_pick`, for each candidate run `rg_gate`; drop non-satisfied from the pick set, collecting `{id, reason}` pairs the caller emits into the decision record. In `heartbeat.sh`: merge collected skips into `_hb_emit`'s record (additive field); on `unresolvable` OR `ambiguous`, bump the frontmatter counter via a temp-file rewrite, file the p1 item at 3 mirroring `_su_file_conflict_inbox`'s shape (the p1 item names which of the two states it was).
- [ ] **Step 4: Run** filters — PASS.
- [ ] **Step 5: Commit**: `feat: heartbeat requires-gate — skip visibly, escalate unresolvable to p1`

### Task 5: Manual-start path + docs

**Files:**
- Modify: `skills/start/SKILL.md` (requires check step alongside the existing stack-cap gate; template source if this file is generated — check `templates/skill-partials/` first and edit the true source)
- Modify: `RULES.md` (integration-domain requires convention), `CLAUDE.md` (concurrent workflow paragraph: one session per feature worktree; stacking per-domain only; `max_unmerged` is per-domain)
- Test: manual verification checklist in the skill change (skills are prose; the mechanical check itself is Task 3's lib, already tested)

- [ ] **Step 1: Add the start-path step**: when the chosen objective's spec/inbox item carries `requires:`, run `rg_gate`; `unmerged` → refuse with the listed blockers and stop; `unresolvable`/`ambiguous` → refuse naming the id and the state (never proceed silently past any of the three) — same wording discipline as the stack-cap step.
- [ ] **Step 2: Run** `scripts/gen-skill-docs.sh` freshness check if templated; full suite `tests/run-tests.sh` — PASS.
- [ ] **Step 3: Commit**: `docs+skill: requires-gate on manual start; concurrent-loops operator workflow`

### Task 6: Doctor checks — the two concurrency footguns

**Files:**
- Modify: `scripts/doctor.sh`, `skills/doctor/SKILL.md`
- Test: `tests/test-doctor.sh` (extend)

**Interfaces:**
- Produces: two read-only checks: (1) `CLAUDE_PROJECT_DIR` set AND its resolved root ≠ `git rev-parse --show-toplevel` of cwd → warn "all worktrees will share one nazgul/ state — unset for concurrent loops"; (2) >1 feature worktree detected (`git worktree list` with `feat/` branches) AND `extensions.worktreeConfig` unset → warn "git hooks install will clobber across worktrees".

- [ ] **Step 1: Write failing tests** for both checks (env-var fixture; two-worktree fixture without worktreeConfig).
- [ ] **Step 2: Run** `tests/run-tests.sh --filter=doctor` — FAIL.
- [ ] **Step 3: Implement** both checks in doctor's existing check format (never writes state, text-only fix guidance).
- [ ] **Step 4: Run** filter, then FULL suite — PASS.
- [ ] **Step 5: Commit**: `feat: doctor — concurrency footgun checks (CLAUDE_PROJECT_DIR, worktreeConfig)`

## Self-review notes (done at plan time)

Spec coverage: §4 B1→Task 2, B2→Task 1 (ordered first — it ships for all users and Task 2 depends on it), B3→docs in Task 5 (no mechanism: stacking-off is the existing default path; the rule is convention + doctor visibility), B4→Tasks 3-4-5, B5→Tasks 5-6. E2E two-loop manual workflow lives in Task 5's CLAUDE.md paragraph; automated two-loop E2E deliberately not planned (needs two live sessions — out of harness reach; the isolation invariants are covered by Tasks 1-2 unit tests). Type consistency: `rg_gate` exit codes 0/3/4/5 and reason words `unmerged`/`unresolvable`/`ambiguous` used identically in Tasks 3, 4, 5.

> **Amendment (2026-08-16, messaging-adoption cycle):** premise now questionable — `--name`, `-p` inbox sockets, and scriptable `claude agents --json` may put a two-live-session harness in reach; anthropics/claude-code#84945 (silent same-directory bind failure) is the known hazard. Re-evaluate at pickup.
