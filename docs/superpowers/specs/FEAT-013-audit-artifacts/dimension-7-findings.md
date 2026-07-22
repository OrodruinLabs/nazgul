# FEAT-013 Dimension 7 Findings — Test Suite Forensics

**Task:** TASK-007 · **Scope:** `tests/run-tests.sh`, all 66 `tests/test-*.sh`, `tests/lib/`
(`assertions.sh`, `setup.sh`), `tests/fixtures/`, `tests/e2e/` (read-only, not executed —
costs money). Secondary: `.github/workflows/test.yml`, `e2e-tests.yml`, `skill-docs.yml`.
Cross-referenced against production scripts (`scripts/*.sh`, `scripts/lib/*.sh`), `templates/`,
and live `nazgul/tasks/*.md` / `agents/planner.md` to judge realism of test fixtures.

**Coverage disclosure (bounding strategy, explicitly disclosed per honesty rules):**
- **Deep-read (full file):** `tests/run-tests.sh`, `tests/lib/setup.sh`, `tests/lib/assertions.sh`,
  `tests/test-task-state-guard.sh` (1256 lines), `tests/test-stop-hook.sh` (1021 lines, grep-swept
  for format usage + structurally sampled), `tests/test-task-utils.sh`, `tests/test-teammate-idle-guard.sh`,
  `tests/test-heartbeat-hard-stops.sh`, `tests/test-json-validation.sh`, `tests/test-skill-arguments.sh`,
  `tests/test-session-tracker.sh`, `tests/test-shellcheck.sh`, `tests/test-frontmatter.sh`,
  `tests/test-reviewer-readonly.sh`, `scripts/teammate-idle-guard.sh`, `scripts/task-state-guard.sh`,
  `scripts/lib/task-utils.sh`, `scripts/parallel-dispatch-guard.sh`, `scripts/parallel-rework-guard.sh`.
- **Grep/structural sweep (not full read):** the remaining ~50 `test-*.sh` files — searched for
  `create_task_file` usage, frontmatter/canonical-status construction, corrupt-input/malformed-JSON
  handling, and assertion density (assert/`_pass`/`_fail` call counts) to locate outlier files
  (very low assertion count, hardcoded file lists) worth a full read. Files that surfaced as outliers
  (`test-shellcheck.sh`) got a full read; files with unremarkable assertion density and no anchor-hits
  did not.
- **Not read:** `tests/e2e/*` bodies beyond directory listing and `run-e2e.sh` header (explicitly
  out of execution scope — "NEVER run tests/e2e: costs money" — and de-prioritized for reading time
  since e2e is CI-gated separately and manual-trigger-only, lower marginal audit value for this pass).
  `tests/fixtures/bootstrap-transform/` contents not read (fixture data, not test logic).
- **Executed:** `tests/run-tests.sh` (full suite) was run once, unmodified — see Runtime Observation
  below. No plugin source file was modified; no commit was made; the one write is this artifact.

---

## Runtime Observation

`bash tests/run-tests.sh` → **66 files run, 66 passed, 0 failed. All tests passed.**

This is stated plainly because it is the central fact this dimension has to reconcile with the
findings below: the suite is fully green, and still exercises a materially unrealistic shape of
its most safety-critical fixtures (F-1) and has real fail-open branches with zero coverage (F-2,
F-3). A green suite is not proof of the properties it appears to certify — which is exactly the
audit question this dimension exists to answer.

---

## Known Anchors — Root Cause Summary

| # | Anchor | Verdict |
|---|--------|---------|
| 1 | Unrealistic-input tests (raw-envelope-lesson repeats) | **ROOT-CAUSED** — see F-1 |
| 2 | Fail-open branches with zero coverage | **ROOT-CAUSED** — see F-2, F-3, F-4 |
| 3 | Vacuous asserts | **ROOT-CAUSED** — see F-5, F-6 |

---

## Findings Register

### F-1 — `create_task_file()` fixture helper writes a status format production stopped emitting; 16 test files (259 call sites) build task manifests the loop/guards never actually receive from the planner

- **Severity:** critical
- **Class:** test-gap
- **Evidence:**
  - `tests/lib/setup.sh:52-72` (`create_task_file`) writes **only** the legacy list-item format:
    `- **Status**: ${status}` with no `---`/YAML frontmatter fence at all.
  - `agents/planner.md:86` — the planner's own spec: *"Each new `TASK-NNN.md` MUST begin with a
    `---` / `status: PLANNED` / `---` YAML frontmatter block — this is the canonical task status
    read by the hooks."*
  - Empirically confirmed against the live repo: `grep -l '^status:' nazgul/tasks/*.md | wc -l` →
    **11/11** real task manifests in this repo use canonical frontmatter; `grep -L '^status:'` →
    **0**. Production (including this very plugin's own dogfooded task files) writes zero
    list-item-only manifests.
  - `scripts/lib/task-utils.sh:16-23` (`get_task_status`) makes frontmatter authoritative:
    canonical `status:` frontmatter is checked **first** and returned immediately when present;
    the list-item scan is reached only via fallthrough when frontmatter is absent (`fm_rc==1`).
  - Call-site count via `grep -c "create_task_file" tests/test-*.sh` (files with ≥1 hit): 
    `test-stop-hook.sh` **89**, `test-task-state-guard.sh` **67**, `test-pre-compact.sh` 15,
    `test-review-provenance-gate.sh` 13, `test-task-utils.sh` 11, `test-comment-verifier-gate.sh` 10,
    `test-granularity-gate.sh` 9, `test-doc-verifier-gate.sh` 9, `test-parallel-batch.sh` 8,
    `test-stop-hook-parallel.sh` 6, `test-session-context.sh` 6, `test-parallel-dispatch-guard.sh` 6,
    `test-hygiene.sh` 5, `test-heartbeat-hard-stops.sh` 3, `test-parallel-rework-guard.sh` 1,
    `test-heartbeat-log.sh` 1 — **259 call sites across 16 files**, all constructing manifests in
    the format `get_task_status` treats as the *fallback*, not the format it treats as canonical.
  - `tests/test-task-state-guard.sh` additionally builds the **write-side** input via
    `make_write_input`/`make_edit_input` (lines 17-37), which also hardcode the legacy
    `- **Status**: X` shape. Of ~76 assertions in that file, only **3** (`make_frontmatter_write_input`,
    line 772, plus Tests 75-76 at lines 1205-1246) construct both the on-disk file *and* the
    Write/Edit content in canonical frontmatter form — everything else round-trips the guard's
    legacy-format branch on both sides.
  - `tests/test-stop-hook.sh`: `grep -n "^status:\|frontmatter" tests/test-stop-hook.sh` → **zero
    matches**. The loop engine's own integration tests (89 task-fixture constructions) never once
    build a canonical-frontmatter task file, despite `scripts/stop-hook.sh:13` sourcing
    `task-utils.sh` and calling `get_task_status`/`get_task_field` at 13 call sites
    (`scripts/stop-hook.sh:173,198,324,337,349,383,385,398,401,440,671,701`).
  - By contrast, `tests/test-task-utils.sh:126-154` **does** unit-test the frontmatter branch of
    `get_task_status`/`set_task_status` directly (not via `create_task_file`) — so the shared
    *library function* is well covered in isolation. The gap is specifically at the
    *integration* layer: whether the loop engine, the state guard, and the parallel-batch selector
    behave correctly when handed the manifest shape production actually produces.
  - **This is not hypothetical** — it already happened once. `tests/test-task-state-guard.sh:1205-1246`
    (Tests 75-76) are regression tests explicitly added for a real production bug: multi-line
    `Edit old_string` spanning the frontmatter fence crashed `scripts/task-state-guard.sh`'s awk
    reconstruction (BSD awk rejects literal newlines via `-v`; fixed by routing through `ENVIRON`
    — see `scripts/task-state-guard.sh:372-373` comment, and session memory
    `project_task_state_guard_awk_multiline_bug.md`). That bug lived in a code path only a
    frontmatter-shaped multi-line edit can trigger — exactly the shape the other 40+ list-item-only
    tests in the same file never construct. The bug shipped to production and was caught by a human,
    not by the pre-existing green suite; tests 75-76 were added *after the fact* as a fix
    verification, not discovered by the fixture's own coverage.
- **Failure scenario:** A future change to `scripts/stop-hook.sh`, `scripts/task-state-guard.sh`,
  or `scripts/lib/parallel-batch.sh` that is correct for list-item-format manifests but subtly wrong
  for canonical-frontmatter manifests (parsing order, multi-line reconstruction, CRLF handling,
  a regex anchored to `^---$` that doesn't survive a BOM or trailing whitespace, etc.) will pass
  all 259 `create_task_file`-based assertions and still be broken against every real task file this
  plugin creates for itself and for every project it manages. This is precisely the class of bug
  the pre-tool-guard raw-envelope incident named in this task's anchor already taught the codebase
  to watch for (`tests/test-pre-tool-guard.sh:29-34` now explicitly documents and tests the
  envelope-vs-raw-command distinction) — that lesson was applied to one guard and not generalized
  to the shared task-fixture helper the rest of the suite depends on.
- **Recommendation:** Change `create_task_file()` in `tests/lib/setup.sh:52-72` to emit canonical
  YAML frontmatter (`---\nstatus: ${status}\n---\n# ...` with the remaining fields as list-items,
  matching `templates/task-manifest.md`) as the default, single source of truth for "what a task
  manifest looks like" in tests. Because `get_task_status` already prefers frontmatter
  transparently, this is a low-risk, high-leverage fix: the 259 existing call sites gain
  canonical-format coverage with zero per-call-site changes. Keep one dedicated
  `create_task_file_legacy()` (rename the current behavior) for the handful of tests that
  specifically exist to prove the legacy-format fallback still works (backward compatibility with
  manifests from before the frontmatter migration) — that fallback is a real, intentional feature
  and deserves its own explicit, minority coverage rather than being the accidental default for
  the whole suite.

### F-2 — `parallel-dispatch-guard.sh` and `parallel-rework-guard.sh` fail OPEN (guard fully disabled) on a corrupt/unreadable `config.json`, with zero test coverage of that path — silently defeats the exact double-dispatch protection these guards exist for

- **Severity:** high
- **Class:** fragility
- **Evidence:**
  - `scripts/parallel-dispatch-guard.sh:22-23`:
    ```
    PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG" 2>/dev/null || echo "false")
    [ "$PARALLEL" = "true" ] || exit 0
    ```
  - `scripts/parallel-rework-guard.sh:21-22` — byte-identical pattern.
  - If `config.json` is corrupt, truncated (e.g. a torn write during a concurrent parallel wave —
    a scenario this very guard exists to defend against), or transiently unreadable, `jq` fails,
    the `|| echo "false"` fallback fires, `PARALLEL` becomes `"false"` regardless of the file's
    actual (or last-good) `execution.parallel` value, and the guard exits 0 (no-op) on line 23 —
    even though the loop may currently be mid-parallel-wave with `execution.parallel: true` on
    disk moments earlier. This is a fail-*open* on a guard whose entire purpose (per its own header
    comment, `scripts/parallel-dispatch-guard.sh:4-5`) is "the no-re-dispatch contract... a work
    unit already IMPLEMENTED/DONE is never re-dispatched" — i.e. it silently re-enables exactly the
    double-dispatch failure mode recorded in session memory
    (`project_conductor_dispatch_defect_and_workflow_verdict.md`: "FEAT-007 conductor
    fire-and-yield/double-dispatch bug").
  - Coverage check: `grep -c "corrupt\|malformed\|not json\|invalid json\|printf 'not"
    tests/test-parallel-dispatch-guard.sh tests/test-parallel-rework-guard.sh` → **0 matches in
    both files**. Neither test file constructs a corrupt/unparseable `config.json` while
    `execution.parallel` should be `true`; both only ever exercise the well-formed-JSON,
    explicit-true/false/absent-key paths.
- **Failure scenario:** During an `execution.parallel: true` run, a config write races with a
  guard invocation (e.g. `/nazgul:config` or a heartbeat tick rewriting `config.json` at the same
  moment a teammate's Agent-tool call fires `parallel-dispatch-guard.sh`) and the guard reads a
  half-written/corrupt file. Instead of failing closed (denying, or at minimum falling back to the
  last-known-good `execution.parallel` state), it silently treats the run as non-parallel and
  allows a re-dispatch of an already-IMPLEMENTED/DONE work unit — the exact bug class this guard
  was built to prevent, undetectable by the current suite because that input shape is never
  constructed.
- **Recommendation:** On `jq` parse failure, fail closed (deny/exit 2 with a clear "config
  unreadable, cannot verify parallel-dispatch safety" message) rather than silently treating it as
  "parallel mode is off." Add a test in both `test-parallel-dispatch-guard.sh` and
  `test-parallel-rework-guard.sh` that writes `printf 'not json' > config.json` with a task already
  IMPLEMENTED/committed and asserts the guard does NOT silently allow.

### F-3 — `teammate-idle-guard.sh`'s two path-traversal fail-open branches (`unsafe teammate name`, `unsafe report_path`) have zero test coverage

- **Severity:** medium
- **Class:** test-gap
- **Evidence:** `scripts/teammate-idle-guard.sh:59-62`:
  ```
  case "$NAME" in
    */*|*..*) log_event "allow" "unsafe teammate name"; exit 0 ;;
  esac
  ```
  and `scripts/teammate-idle-guard.sh:84-88`:
  ```
  case "$REPORT_PATH" in
    /*|*..*) log_event "allow" "unsafe report_path"; exit 0 ;;
  esac
  ```
  Both are explicitly documented fail-open (comments at lines 59 and 84-85 say so directly — this
  is intentional, not a hidden mistake, per this task's honesty rules I'm not treating "intentional
  fail-open" itself as a bug). `tests/test-teammate-idle-guard.sh` has 19 assertions (Tests 1-13 +
  18-19; note the file's own numbering jumps from 13 to 18, see F-6) covering malformed payload,
  nameless payload, no-manifest, stale feat_id, kill-switch, no-nazgul-dir, corrupt manifest,
  non-numeric `.blocks`, and mktemp failure — a genuinely solid fail-open sweep overall — but never
  constructs a payload with `from` containing `/` or `..`, nor a dispatch manifest with a
  `report_path` containing a leading `/` or a `..` segment. Confirmed via full read of the test
  file: no test name or payload references traversal/unsafe path/absolute path.
- **Failure scenario:** These are the two branches most directly load-bearing for security
  (path-injection into a write path derived from hook-controlled input,
  `$DISPATCH_DIR/$NAME.json` and `$PROJECT_DIR/$REPORT_PATH`). If a future refactor of the `case`
  pattern (e.g. someone "simplifies" `*/*|*..*` to `*/*` and drops the `..` check, or vice versa)
  silently weakens the traversal guard, no test fails — the change looks green.
- **Recommendation:** Add two assertions: a payload with `from` = `"../../etc"` or `"foo/bar"`
  must fail-open-allow (exit 0) via `log_event "allow" "unsafe teammate name"` rather than proceed
  to a manifest lookup; a dispatch manifest with `report_path` = `"/etc/passwd"` or
  `"../outside.md"` must similarly fail-open-allow rather than resolve `REPORT_ABS` and check it.
  (This locks in *current* behavior as a regression test — it does not itself argue the fail-open
  choice is wrong; that's a design question outside this dimension's brief per the honesty rules on
  scope.)

### F-4 — `test-teammate-idle-guard.sh`'s own MTIME-fallback branch (`scripts/teammate-idle-guard.sh:96-98`, best-effort stat) is untested for the "stat fails on both GNU and BSD forms" case

- **Severity:** low
- **Class:** test-gap
- **Evidence:** `scripts/teammate-idle-guard.sh:96`:
  `MTIME=$(stat -c %Y "$REPORT_ABS" 2>/dev/null || stat -f %m "$REPORT_ABS" 2>/dev/null || echo "")`
  — comment at line 92 acknowledges "on stat failure existence+non-empty wins (open)." No test
  forces both `stat` invocations to fail (e.g. by deleting the file between the `[ -s "$REPORT_ABS" ]`
  check and the `stat` call — a TOCTOU-shaped scenario) to confirm the documented fallback (treat as
  delivered) actually fires rather than the script crashing on an unset `$MTIME` under `set -euo
  pipefail` in the subsequent `case`/`[ -z ... ]` checks. Low severity because both `stat` forms
  covering GNU and BSD make the fully-failed case rare in practice (would need a filesystem/toolchain
  neither Linux nor macOS ships), but it is a real zero-coverage fail-open path in scope for this
  anchor.
- **Failure scenario:** On some cross-platform CI runner where neither `stat` flavor exists (or the
  file is removed by a racing process between the `-s` test and the `stat` call), the fallback
  path's correctness is unverified — a regression here would silently start treating always-recent
  or always-stale reports incorrectly and nothing would catch it.
- **Recommendation:** Low priority; note for backlog rather than block on. If addressed, mock both
  `stat` forms failing (e.g. `PATH` shadow) and assert the guard still exits 0 without crashing.

### F-5 — `test-shellcheck.sh`'s hardcoded `SCRIPTS` array is stale: 20 of 49 shell scripts (41%) — including two production-critical shared libraries and one active guard — receive zero `bash -n`/shellcheck verification from the test whose entire stated purpose is exactly that

- **Severity:** medium
- **Class:** test-gap
- **Evidence:** `tests/test-shellcheck.sh:12-45` hardcodes a 32-entry `SCRIPTS` array. Actual
  inventory: `ls scripts/*.sh | wc -l` → 30, `ls scripts/lib/*.sh | wc -l` → 19 (49 total shell
  scripts in `scripts/`). Diffing the array against the real inventory, these 20 are **absent**:
  `scripts/apply-start-flags.sh`, `scripts/board-sync-github.sh`, `scripts/bootstrap-transform.sh`,
  `scripts/file-improvement-report.sh`, `scripts/formatter.sh`, `scripts/gen-skill-docs.sh`,
  `scripts/notify.sh`, **`scripts/prompt-guard.sh`**, `scripts/webhook-forward.sh`,
  `scripts/worktree-utils.sh`, `scripts/lib/bootstrap-preflight.sh`,
  `scripts/lib/bootstrap-relocate.sh`, `scripts/lib/bootstrap-render.sh`,
  `scripts/lib/bootstrap-scrub-map.sh`, `scripts/lib/git-utils.sh`, `scripts/lib/learned-rules.sh`,
  `scripts/lib/review-evidence.sh`, `scripts/lib/session-tracker.sh`,
  **`scripts/lib/structured-state.sh`**, **`scripts/lib/task-utils.sh`**.
  The three bolded are the highest-consequence omissions: `prompt-guard.sh` is one of the five
  active PreToolUse/UserPromptSubmit guards (in dimension 3's scope, but its syntax/lint hygiene is
  this test's job and it's silently skipped); `task-utils.sh` and `structured-state.sh` are the
  shared status-parsing libraries sourced by `stop-hook.sh`, `task-state-guard.sh`,
  `pre-compact.sh`, `post-compact.sh`, `session-context.sh`, and every heartbeat/parallel-batch
  script — i.e. the single most load-bearing shell code in the plugin, per F-1 above — and it has
  never once been run through `bash -n` or `shellcheck` by this suite.
- **Failure scenario:** A syntax error or a new shellcheck-flagged unsafe pattern (unquoted
  expansion, unintentional word-splitting, etc.) introduced into `task-utils.sh` or
  `structured-state.sh` — the files everything else in this findings register traces back to —
  would not fail this test, because this test never looks at those files. The test's name and
  header comment ("Test: All shell scripts pass bash -n and shellcheck") over-promises relative to
  what it actually checks; a reader trusting the test name would reasonably but incorrectly
  believe 100% of `scripts/` is syntax-and-lint-verified.
- **Recommendation:** Replace the hardcoded `SCRIPTS` array with a `find scripts -name '*.sh'`
  glob (excluding `scripts/git-hooks/` extensionless files if needed, or globbing those
  separately as already done) so new scripts are covered by construction instead of requiring a
  human to remember to add them to a list. This is the same maintenance-hazard shape as F-1's
  fixture-drift, applied to a different test file.

### F-6 — `test-shellcheck.sh`'s "shellcheck not installed" branch reports 32 fake PASSes instead of skipping, and the suite's assertion-count outlier sweep surfaces a numbering gap in `test-teammate-idle-guard.sh` consistent with dead/removed test cases

- **Severity:** low
- **Class:** fragility / docs-drift
- **Evidence:**
  - `tests/test-shellcheck.sh:79-85`: when `shellcheck` is not on `PATH` (and not at the
    `/tmp/shellcheck-v0.10.0/shellcheck` fallback location), the script prints
    `"SKIP: shellcheck not found"` to stdout but then loops over all 32 `SCRIPTS` entries calling
    `_pass "$name shellcheck (skipped — not installed)"` — i.e. it counts 32 assertions as PASSED
    that never ran shellcheck at all. `report_results` (`tests/lib/assertions.sh:142-153`) has no
    way to distinguish a real pass from this synthetic one; `tests/run-tests.sh`'s summary line
    would report the file as fully green either way. This is the textbook "test that passes
    regardless of behavior" shape named in this dimension's anchor #3, though its blast radius is
    narrowed by the fact CI (`.github/workflows/test.yml:15`) does install shellcheck — so in CI
    this branch is dead code; it only fires for a contributor running `tests/run-tests.sh` locally
    without `brew install shellcheck`, silently telling them the plugin passed lint when it was
    never checked.
  - Separately, while reading `tests/test-teammate-idle-guard.sh` for F-3/F-4, its inline test
    numbering jumps from `# 13. corrupt manifest...` (line 104) directly to `# 18. non-numeric
    .blocks...` (line 117) — tests 14-17 do not exist in the file. This isn't itself a vacuous
    assert, but it's the kind of drift (renumbering after a refactor, or tests quietly deleted)
    that erodes confidence in a test file being a complete, intentional record rather than an
    accretion — worth a cleanup pass so the numbering is trustworthy documentation again.
- **Failure scenario:** A contributor or CI runner without shellcheck installed sees "66/66 files
  passed" and reasonably concludes lint is clean; it wasn't checked. Low severity because the
  primary CI path (the one gating merges to `main`) does install shellcheck and is unaffected.
- **Recommendation:** Change the "not installed" branch to either (a) hard-fail with an actionable
  message so local runs can't silently skip lint, or (b) explicitly report these as SKIPPED in the
  summary rather than PASSED (would require a small `assertions.sh` extension — a `_skip()`
  counted separately from `_pass()`). For the numbering gap, either renumber sequentially or add a
  one-line comment noting tests 14-17 were retired and why, so a future reader doesn't wonder if
  they're looking at a truncated file.

---

## Structural Critique

- **Fixture-drift is the suite's dominant systemic risk, not any single test.** F-1 (task-manifest
  format) and F-5 (shellcheck script inventory) are the same underlying disease: a hardcoded
  snapshot of "what the input/target looks like" embedded in test infrastructure, which production
  moved past without the test infrastructure being updated in lockstep. Both are single-point fixes
  (one helper function, one glob pattern) with disproportionate leverage — fixing `create_task_file`
  alone would upgrade the realism of 259 call sites across 16 files without touching those files.
  This is a stronger argument for periodic "does the test fixture still match a real production
  artifact" audits than for any one-off patch.
- **The suite's honesty about its own limits is inconsistent.** `tests/test-reviewer-readonly.sh:28-32`
  explicitly documents its generated-reviewer loop as "best-effort... runs when generated reviewers
  exist" (gitignored, absent in CI) — a good model of disclosed partial coverage. `test-shellcheck.sh`'s
  skip-as-pass (F-6) is the opposite pattern: same shape (a check that can't fully run in some
  environments) handled by silently inflating the pass count instead of disclosing the gap. The
  fix pattern from the good example (`test-reviewer-readonly.sh`) should be applied to the bad one.
- **Assertion-count sampling as a triage heuristic worked well and is cheap.** Sorting all 66 files
  by `assert_*`/`_pass`/`_fail` call count surfaced both real outliers in this pass
  (`test-shellcheck.sh`'s stale array) and false positives that turned out fine on inspection
  (`test-heartbeat-hard-stops.sh`, `test-json-validation.sh`, `test-skill-arguments.sh` — all low
  raw assertion counts but legitimately parameterized/dynamic loops). Worth keeping as a standing
  lightweight lint (`grep -c` per file, flag anything under some threshold for periodic human
  review) rather than a one-time audit artifact.
- **Two-tier severity of "green suite, real gap" is present at both the unit and integration
  layers.** `task-utils.sh`'s frontmatter-handling functions are well unit-tested in isolation
  (`test-task-utils.sh:126-154`); the gap is that nothing above that layer (the loop engine, the
  state guard's write-content parsing) is integration-tested against the same shape. A codebase can
  have excellent unit coverage of a primitive and still have its actual callers under-verified — the
  audit needs to check both layers separately, which is what surfaced F-1.
- **CI gating is minimal but not misleading.** `.github/workflows/test.yml` runs the full
  `tests/run-tests.sh` (all 66 files, no filter) on every push/PR to `main` and installs
  `shellcheck` first — so F-6's fake-pass branch is CI-dead-code, and the suite's headline claim
  ("all tests pass gates merges") is true as far as it goes. The gap this dimension found is not
  "CI is lying about what it runs" — it's "what the suite runs is a narrower and less realistic
  slice of production behavior than its size (66 files, hundreds of assertions) suggests."
  `e2e-tests.yml`/`skill-docs.yml` were read only at the header level (manual-trigger and
  freshness-check respectively per `CLAUDE.md`) — no anomaly surfaced there worth a finding within
  this dimension's time budget; a full e2e-workflow read is better spent by whichever dimension
  owns CI/workflow configuration end-to-end if that's not already covered elsewhere in the sweep.

---

## Summary

- **6 findings:** 1 critical (F-1), 1 high (F-2), 2 medium (F-3, F-5), 2 low (F-4, F-6).
- **All 3 anchors root-caused** with direct `file:line` evidence (no anchor cleared without
  finding — all three had real, evidenced instances).
- **Both lenses covered:** reliability (F-1, F-2, F-3, F-4 — coverage gaps that let real bug classes
  through, one with a documented historical incident as proof) and structural critique (F-5, F-6,
  plus the dedicated Structural Critique section — harness design, fixture maintenance, CI gating
  posture).
- **Verification status intentionally omitted** from each finding above — per TRD Finding Record
  Shape and this task's brief, CONFIRMED/PLAUSIBLE assignment is TASK-010's (adversarial
  verification) job, not self-assigned here.
