# Dimension 4 Findings — Git-level hooks (TASK-004)

Scope: `scripts/lib/git-hooks.sh`, `scripts/git-hooks/{_dispatch.sh,pre-commit,pre-merge-commit}`,
`core.hooksPath` lifecycle touchpoints (`scripts/worktree-utils.sh`, `scripts/session-context.sh`),
config keys `guards.git_hooks` + `branch.prior_hooks_path`. Method: static read of every file in
scope, empirical reproduction of the two named anchors in a scratch git repo (git 2.48.1, macOS),
and live inspection of this project's own running `nazgul/config.json` / `core.hooksPath` (this
repo is mid-objective on FEAT-013 right now, which turned out to be direct evidence for Finding 1).
No plugin source file was modified. Coverage is complete for the declared scope — no sampling, no
top-N cap.

---

## Finding 1 — The entire git-hooks install/uninstall lifecycle is never invoked by production code (dead wiring)

- **severity**: critical
- **class**: bug
- **evidence**:
  - `scripts/worktree-utils.sh:62-64` — `install_git_hooks` is called ONLY from inside
    `create_feature_branch()`.
  - `scripts/worktree-utils.sh:199-205` — `uninstall_git_hooks` is called ONLY from inside
    `cleanup_all_worktrees()`.
  - Neither `create_feature_branch` nor `cleanup_all_worktrees` nor `setup_worktree_dir` nor
    `worktree-utils.sh` (the file) appears anywhere in `skills/*/SKILL.md`, `agents/*.md`, or any
    other `scripts/*.sh` besides its own definition and `tests/test-git-hooks-wiring.sh` — confirmed
    by exhaustive grep across the plugin (`grep -rln "create_feature_branch\|worktree-utils.sh" skills/ agents/ scripts/*.sh templates/` → zero hits outside the defining file).
  - `skills/start/SKILL.md` independently re-implements branch setup FIVE times (ACTIVE_LOOP
    pre-v3 fallback ~line 183-190, OBJECTIVE_COMPLETE cleanup ~line 240-246, DOCS_READY
    ~line 258-266, DISCOVERY_DONE ~line 280-289, FRESH ~line 302-311) as plain prose instructing
    the agent to run `git checkout -b feat/<display_id>-<slug>` directly — never sourcing
    `worktree-utils.sh` and never calling `install_git_hooks`. The OBJECTIVE_COMPLETE step
    (`skills/start/SKILL.md:245`) says only "Clean up all worktrees (remove task worktrees and
    worktree parent dir)" — it does not call `cleanup_all_worktrees()` or `uninstall_git_hooks`.
  - **Live confirmation on this very repo**: `nazgul/config.json` currently has
    `guards.git_hooks: true`, `branch.feature: "feat/FEAT-013-360-reliability-audit"` (an active
    objective, branch already created), but `branch.prior_hooks_path: null` (never recorded — the
    only way it becomes non-null is `install_git_hooks` running) and
    `git config --get core.hooksPath` on the live repo returns the OS-default `.git/hooks`, not
    `nazgul/.githooks`; `nazgul/.githooks/` does not exist on disk. This is dogfooding proof, not
    just static analysis: the objective this very audit runs under has its git-level guards
    completely uninstalled despite the config toggle being on.
- **failure scenario**: Any project that runs `/nazgul:start` gets `guards.git_hooks: true` by
  default and reasonably believes (per RULES.md §"Git-level hooks", CHANGELOG.md v2.12.0-era entry,
  and the FEAT-010 design doc) that the pre-commit base-branch guard and pre-merge-commit H2
  verdict guard are protecting it. In reality `core.hooksPath` is never touched, so neither guard
  is ever installed: a direct commit to the base branch during an active loop is never blocked, and
  — more seriously — a parallel task unit that is CHANGES_REQUESTED/BLOCKED (not DONE) can be
  merged into the feature branch with zero mechanical enforcement, silently defeating the entire
  point of FEAT-010 ("enforce at the layer that knows the truth" instead of trusting agent-followed
  instructions). Every test in `tests/test-git-hooks-wiring.sh` passes because it sources
  `worktree-utils.sh`/`git-hooks.sh` directly and calls the functions itself — it never invokes
  `/nazgul:start` or asserts the skill actually calls them, so the suite is green while the feature
  is inert in production. This is the same class of gap already recorded for this codebase
  (pre-tool-guard.sh envelope bug: "tests only fed raw command," per session memory) — tests
  validate the unit in isolation, not the wiring.
- **recommendation**: Wire `skills/start/SKILL.md`'s five branch-setup blocks and the
  OBJECTIVE_COMPLETE cleanup block to literally source `scripts/worktree-utils.sh` and call
  `create_feature_branch`/`setup_worktree_dir`/`cleanup_all_worktrees`, exactly matching the
  established precedent already used elsewhere in this codebase for other lifecycle libraries
  (`skills/status/SKILL.md:21-22` sources `scripts/lib/parallel-batch.sh` inline;
  `agents/review-gate.md:106-107` sources `scripts/lib/review-provenance.sh` and
  `reviewer-selection.sh`; `skills/bootstrap-project/SKILL.md` sources three `scripts/lib/
  bootstrap-*.sh` files). Add a wiring-level test (spawn `/nazgul:start` or grep the skill file for
  the literal `source`/function-call strings) so this class of regression is caught the way the
  pretool-guard envelope bug's fix added an integration-level check. This finding must be fixed
  together with Finding 2 (worktree escape) and Finding 3 (hook-name coverage gap) — wiring the
  install/uninstall calls back in without also fixing those makes the guards newly *live* but still
  bypassable.

**Self-heal interaction (`scripts/session-context.sh`) — this strengthens Finding 1, not a separate finding.**
`scripts/session-context.sh` is wired to the `SessionStart` hook event (`hooks/hooks.json:117,127`),
so it runs at the start of every Claude Code session and every post-compaction resume, as long as
`nazgul/config.json` exists (`scripts/session-context.sh:15-17` — the file's only early-exit gate).
It unconditionally sources `scripts/lib/git-hooks.sh` and calls `self_heal_git_hooks
"$NAZGUL_DIR/.." "$CONFIG"` (`scripts/session-context.sh:85-91`) on every one of those runs. Traced
against the function itself: `self_heal_git_hooks` (`scripts/lib/git-hooks.sh:189-211`) gates on
`recorded=$(jq -r '... .branch.prior_hooks_path != null ...')` and returns early at
`scripts/lib/git-hooks.sh:204` (`[ "$recorded" = "true" ] || return 0`) whenever
`prior_hooks_path` is `null`. Because Finding 1 established that `install_git_hooks` is never
called in production, `branch.prior_hooks_path` never gets recorded (stays `null`) for any real
objective — confirmed live on this repo's own `nazgul/config.json`
(`branch.prior_hooks_path: null` even with an active `branch.feature`, per Finding 1's dogfooding
evidence). So `self_heal_git_hooks` hits the line-204 early return on literally every session
bootstrap: the self-heal layer of the three-layer lifecycle (install / uninstall / self-heal) is
not merely untested against drift — given the current wiring it can never do anything but return 0,
on every single invocation, for the lifetime of any objective. This is not a bug in
`self_heal_git_hooks` itself (its drift-reassertion logic, tested in
`tests/test-git-hooks-wiring.sh:118-162`, is correct for the case where install DID run); it is a
second, independent symptom of Finding 1's root cause, and it closes the loop on why the drift
this function exists to catch is never observed in practice: there is nothing to drift from. No
separate finding record is warranted — this is folded into Finding 1's evidence and severity
rationale, not counted as a fourth finding.

---

## Finding 2 — Anchor 1 (worktree guard escape): CONFIRMED via reproduction — root cause is relative `core.hooksPath` resolving per-worktree-toplevel

- **severity**: high (currently dormant/unreachable because of Finding 1 — see Interaction note; would be live-exploitable the moment Finding 1 is fixed without also fixing this)
- **class**: bug
- **evidence**:
  - Empirical repro (scratch repo, git 2.48.1): a managed `pre-commit` hook that installs cleanly
    and correctly fires/blocks in the main worktree (`git rev-parse --git-path hooks` →
    `<main>/nazgul/.githooks`) silently does NOT fire at all when the same repo's commit is made
    from inside a `git worktree add`-created secondary worktree — exit code 0, no guard output. In
    the worktree, `git rev-parse --git-path hooks` resolves to `<worktree>/nazgul/.githooks`
    (relative to the invoking worktree's own toplevel, not the main worktree), and that path does
    not exist there, so git finds no hook and silently allows the action.
  - `scripts/lib/git-hooks.sh:126-127` (`install_git_hooks`) always materializes
    `nazgul/.githooks/` under `$project_root` (the main worktree root) only — it has no per-worktree
    installation step.
  - `scripts/lib/git-hooks.sh:143` sets `core.hooksPath` to the RELATIVE path
    `"$_GH_MANAGED_RELDIR"` (`nazgul/.githooks`), which is the config's own shared value across all
    worktrees of the repo (no `--worktree` scoping used) — combined with git's relative-hooksPath
    resolution being per-invoking-worktree-toplevel, this is the exact mechanism reproduced above.
  - `agents/implementer.md:113-114` ("cd into the worktree for ALL implementation work") confirms
    every task-level commit in parallel mode runs with cwd inside a secondary worktree — i.e.,
    exactly the reproduced escape condition — for every commit an implementer makes while a task is
    in progress.
  - Mitigating factor found: `agents/review-gate.md:522-524` explicitly instructs `cd
    <main_worktree_path>` before the `git merge --no-ff` step that the pre-merge-commit H2 guard
    actually cares about, and `agents/team-orchestrator.md:93` similarly says "Checkout feature
    branch in main worktree" before merging. So in the documented, intended flow the H2 guard's
    trigger point (the merge) does run from the main worktree, and the base-branch guard's escape
    is moot in the intended flow too (a task worktree's checked-out branch is always the task
    branch, never the base branch, so the guard would no-op even if it fired). But this correctness
    depends entirely on an LLM agent following a natural-language "cd first" instruction with no
    mechanical check — precisely the "trust the agent to follow the string" anti-pattern that
    FEAT-010 was built specifically to eliminate (see `[[project_command_parsing_arms_race_git_level]]`
    in session history: "enforce at the layer that knows the truth, not by parsing/trusting agent
    behavior"). A resumed-after-compaction agent, a race in team-orchestrator's parallel dispatch,
    or a stale cwd after a tool error would silently merge an unreviewed task with zero enforcement
    and zero error message — the failure mode is invisible, not a loud block.
- **failure scenario**: Once Finding 1 is fixed and the guards actually install, a task-worktree
  commit is safe under the *documented* protocol, but any deviation from "always cd to
  main_worktree_path before merging" (agent memory lapse, EnterWorktree/ExitWorktree state left
  stale after an error, a future parallel-dispatch code path that merges without the explicit cd)
  silently produces an unguarded merge — no exception, no log line, just success. `git worktree
  remove` afterward destroys the evidence of where the merge cwd was.
- **recommendation**: Do not rely on the agent-followed "cd first" convention alone. Either (a) make
  `merge_task_to_feature()` (`scripts/worktree-utils.sh:131-153`, already unused per Finding 1, but
  the fix point once wired) always invoke `git -C "$project_root" merge ...` explicitly with `-C`
  rather than relying on the caller's cwd — this at least makes the *library* function
  worktree-cwd-safe even if callers regress — or (b) additionally install the managed hooks under
  every task worktree at `create_task_worktree()` time (a small `nazgul/.githooks` symlink/copy per
  worktree, or set `core.hooksPath` with `--worktree` scoping via `extensions.worktreeConfig`) so
  the guard is structurally present regardless of which worktree a git action runs from. (b) is the
  more robust fix — it removes the escape rather than avoiding triggering it.

**Interaction with Finding 1**: because `install_git_hooks` is never called in production today,
`core.hooksPath` currently never points at the managed dir in EITHER the main worktree or any task
worktree — so this specific escape mechanism is not the active threat right now (Finding 1's total
non-installation is a strict superset). It is reported at high severity, not critical, because it
is real, reproduced, and root-caused, but currently masked by Finding 1; it must not be deprioritized
once Finding 1 ships, or the fix for Finding 1 alone would newly enable exactly this bypass for every
parallel-mode task commit.

---

## Finding 3 — Anchor 2 (chain-dispatch to pre-existing user hooks): mostly sound, two concrete gaps

- **severity**: medium
- **class**: bug / fragility
- **evidence (gap a — incomplete githooks(5) coverage)**:
  - `scripts/lib/git-hooks.sh:23-29` (`_GH_OTHER_HOOKS` array) lists 22 hook names (recounted:
    5 + 7 + 5 + 4 + 1 across its five source lines = 22) and its comment
    (`scripts/lib/git-hooks.sh:20-22`) claims "Every standard githooks(5) name Nazgul does not
    itself define."
  - `man githooks` on this machine (git 2.48.1) lists 28 client/server hook names total (verified:
    `man githooks | col -b | grep -E '^   [a-z][a-z0-9._-]*$'` enumerates all 28); of those, 2 are
    Nazgul's own (`pre-commit`, `pre-merge-commit`, in `_GH_OWN_HOOKS`) and the remaining 26 should
    all appear in `_GH_OTHER_HOOKS`. The array is missing exactly 4: `p4-changelist`,
    `p4-prepare-changelist`, `p4-post-changelist`, `p4-pre-submit` (22 present + 4 missing = 26,
    consistent; 22 + 2 own + 4 missing = 28, matching the man-page total).
  - Because `install_git_hooks` overwrites/repoints `core.hooksPath` to the managed dir wholesale
    (`scripts/lib/git-hooks.sh:143`) and only installs shims for names in `_GH_OWN_HOOKS ∪
    _GH_OTHER_HOOKS`, a repo that has a git-p4 hook configured under one of the four missing names
    before Nazgul installs would have that hook silently stop firing — no shim exists for it, so
    `_dispatch.sh` never gets a chance to forward to it, and it is not restored until
    `uninstall_git_hooks` runs (which per Finding 1 currently never happens).
- **evidence (gap b — interrupted-cycle drift loss)**:
  - `scripts/lib/git-hooks.sh:108-124` (`install_git_hooks`'s "record prior" block) only records
    `core.hooksPath` into `branch.prior_hooks_path` when that field reads as `null` — i.e., on the
    FIRST install of a cycle. If a previous cycle's `uninstall_git_hooks` never ran (crash, or per
    Finding 1, structurally never), `prior_hooks_path` is already non-null on the next
    `install_git_hooks` call, so the "record prior" step is skipped and the CURRENT live
    `core.hooksPath` (which may have been manually changed by the user in the interim, e.g. they
    installed/reconfigured husky) is silently discarded and overwritten back to the managed dir with
    no record of the newer value; a later `uninstall_git_hooks` restores the STALE original value
    from the earlier cycle, not the user's intervening change.
  - No test in `tests/test-git-hooks-wiring.sh` covers this "install → (crash, no uninstall) →
    install again with core.hooksPath having drifted in between" sequence; the suite's round-trip
    tests (`tests/test-git-hooks-wiring.sh:61-101`) all assume a clean single install/uninstall
    cycle.
- **evidence (things checked and cleared)**:
  - Double-run risk: not possible by construction — `core.hooksPath` is a single git config value,
    so git scans exactly one directory per hook name; there is no fan-out/duplication logic in
    `install_git_hooks` that could register two competing hook sources for the same name.
  - The "was unset" vs "never recorded" vs "real prior path" three-state handling in
    `uninstall_git_hooks` (`scripts/lib/git-hooks.sh:156-180`) is correctly distinguished (empty
    string sentinel vs `null` vs a real value), and `_dispatch.sh`'s fallback resolution
    (`scripts/git-hooks/_dispatch.sh:28-49`, using `git rev-parse --git-common-dir` when
    `prior_hooks_path` reads as the empty-string sentinel) correctly lands on the true previous
    default location. This part of the anchor is cleared — no bug found.
  - The trust-boundary check in `dispatch_prior_hook` (`scripts/git-hooks/_dispatch.sh:70-77`:
    exists, not-a-symlink, is-a-regular-file, executable, all checked before exec) is sound against
    a basic symlink-escape attempt.
- **failure scenario**: (a) a git-p4 user's Perforce-bridge hook silently stops running once Nazgul
  installs, with no error surfaced anywhere. (b) a user who reconfigures their own hooks manager
  mid-cycle (e.g., switches from husky to lefthook) while a Nazgul loop is interrupted/crashed loses
  that change the next time the loop resumes and re-installs, and gets the WRONG original value
  restored at eventual uninstall.
- **recommendation**: (a) extend `_GH_OTHER_HOOKS` with the four `p4-*` names (cheap, mechanical
  fix — add four entries to the array). (b) On each `install_git_hooks` call, compare the live
  `core.hooksPath` against the managed dir; if it differs from BOTH the managed dir AND the recorded
  `prior_hooks_path`, treat it as drift-since-last-cycle and either refuse to silently overwrite
  (surface a warning) or update the recorded value to the newly-observed one before repointing.

---

## Structural critique

1. **Duplicate/orphaned lifecycle implementation** (ties directly to Finding 1). `scripts/
   worktree-utils.sh` is a complete, idempotent, well-commented, and well-tested library
   (`create_feature_branch`, `setup_worktree_dir`, `create_task_worktree`, `merge_task_to_feature`,
   `cleanup_task_worktree`, `cleanup_all_worktrees`) that duplicates logic re-implemented ad hoc as
   copy-pasted prose across five separate blocks in `skills/start/SKILL.md`. This is the opposite of
   this codebase's own established pattern elsewhere (`skills/status/SKILL.md`, `skills/
   bootstrap-project/SKILL.md`, `agents/review-gate.md` all literally `source` their
   `scripts/lib/*.sh` helpers rather than re-deriving the logic in prose). Consolidation candidate:
   collapse the five prose blocks in `skills/start/SKILL.md` down to one shared reference that
   sources `worktree-utils.sh`, eliminating both the drift risk (five copies to keep in sync) and
   Finding 1 in the same change.
2. **Minor location inconsistency**: `scripts/worktree-utils.sh` lives directly under `scripts/`
   while every other lifecycle helper it depends on or parallels (`scripts/lib/git-hooks.sh`,
   `scripts/lib/parallel-batch.sh`, `scripts/lib/task-utils.sh`) lives under `scripts/lib/`. Low-severity
   but worth folding into any refactor of Finding 1 — moving it to `scripts/lib/worktree-utils.sh`
   would match the codebase's own convention and CLAUDE.md's documented directory structure (which
   already lists `scripts/worktree-utils.sh` — so this is a doc-and-code-agree-but-inconsistent-with-
   sibling-convention issue, not a doc mismatch).
3. **No removal candidates.** Both managed hooks (`pre-commit` base-branch guard, `pre-merge-commit`
   H2 verdict guard) and the generic-hook chain-dispatch design are appropriately scoped, not
   overbuilt — each hook is short, single-purpose, and degrades to allow on any ambiguity
   (config unreadable, jq missing, no candidates). The dispatcher's use of `GITHEAD_<sha>` instead of
   `GIT_REFLOG_ACTION` for merge-identity resolution (`scripts/git-hooks/pre-merge-commit:9-20`) is a
   deliberately hardened design already documented as a response to a specific spoofing vector — this
   is appropriately-built, not sprawl.

## Anchor coverage summary

Both anchors are root-caused, not cleared-without-evidence:

1. **Deferred worktree guard escape** — CONFIRMED (Finding 2), reproduced empirically, mechanism
   identified (relative `core.hooksPath` resolves per-invoking-worktree-toplevel; the managed hooks
   dir is only materialized under the main worktree). Currently dormant in practice only because of
   Finding 1.
2. **Chain-dispatch to pre-existing user hooks** — MOSTLY CLEARED, two concrete gaps found and
   reported as Finding 3 (incomplete `p4-*` hook coverage; interrupted-cycle drift loss). The core
   forwarding mechanism (trust boundary, argv/stdin/exit-code preservation, three-state prior-value
   handling) is sound.

## Coverage disclosure

Full read coverage of the declared file scope (`scripts/lib/git-hooks.sh`,
`scripts/git-hooks/_dispatch.sh`, `scripts/git-hooks/pre-commit`, `scripts/git-hooks/
pre-merge-commit`, `scripts/worktree-utils.sh`, `scripts/session-context.sh`,
`tests/test-git-hooks-wiring.sh`) plus the cross-cutting grep sweep across `skills/`, `agents/`,
`scripts/*.sh`, `templates/` needed to establish Finding 1's wiring claim, plus live inspection of
this project's own `nazgul/config.json` and `core.hooksPath`. `scripts/session-context.sh` is not a
standalone finding but is fully analyzed under Finding 1's "Self-heal interaction" subsection —
traced to its `SessionStart` wiring (`hooks/hooks.json:117,127`), its unconditional call to
`self_heal_git_hooks` (`scripts/session-context.sh:85-91`), and the exact early-return line
(`scripts/lib/git-hooks.sh:204`) that makes self-heal a permanent no-op under the current (unwired)
production state — that trace is this dimension's clearance note for that file, not a gap. One
empirical reproduction was run in an isolated scratch git repo (git 2.48.1) to confirm the
worktree-escape mechanism rather than relying on reading git's docs alone. No re-dispatch was
needed — single pass, no garbage/failed audit run to report. Not covered (out of declared scope,
noted for completeness): `hooks/hooks.json`'s other hook registrations and the Claude-side
`PreToolUse`/`PostToolUse` guards are dimension 3's territory, not re-audited here beyond the
interaction noted in Finding 2 and the `SessionStart` citation above.
