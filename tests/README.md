# Nazgul Integration Tests

## Running Tests

```bash
# Run the full suite
tests/run-tests.sh

# Run a single test file by filter
tests/run-tests.sh --filter=pre-tool-guard
tests/run-tests.sh --filter=stop-hook
tests/run-tests.sh --filter=json
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Every checked file passed |
| `1` | At least one checked file failed |
| `2` | **NOTHING CHECKED** — the filter matched no file, or no test file was discovered |
| `3` | Internal coverage-accounting defect (`scanned != skipped + checked`) |

Exit `2` exists so a mistyped `--filter` is distinguishable from a real test failure. A zero-match run
never prints "All tests passed."; it prints `run-tests: NOTHING CHECKED — ...` on stderr instead.

## Coverage Line

Every run ends with one fixed-grammar, greppable line on stdout (the coverage-honesty contract — a run
must report what it did NOT look at, not only what it found):

```text
run-tests: <N> scanned, <M> skipped (filtered-out=<count>, unreadable=<count>), <K> checked, <F> findings
```

Skip reasons are a closed list — `filtered-out`, `unreadable`. The runner asserts `N == M + K` itself and
exits `3` on a mismatch, because a summary that does not add up is a defect in the emitter.

The runner is one of seven entry points bound by this contract. The registry lives in `RULES.md` §15 —
not in a per-objective TRD, which is archived out from under the citation when its objective completes —
and `tests/test-coverage-honesty.sh` drives every enumerated entry point under a forced all-skip input
and FAILS if one was never driven. `scripts/self-audit.sh` was enrolled by FEAT-029/TASK-012; it emits a
line per miner plus a run total, and its total is not the last line of stdout (a completion notice
follows), so grep for `^self-audit: [0-9]+ scanned` rather than tailing. Add a new checking entry point
to the RULES.md list and to that test in the same change.

## Test Files

The runner discovers **98** root `test-*.sh` files — derive the current number with
`ls tests/test-*.sh | wc -l` rather than trusting this line, and update it when it drifts. The count was
93 at FEAT-028; FEAT-029 added the five adversarial suites listed below. The FEAT-028 retroactive audit
covered 118 files when shared helpers, E2E files, and fixtures were included; see
`docs/test-audit-2026-08.md` for that point-in-time, one-verdict-per-file ledger (it is dated and is not
retro-edited as the suite grows).

| Area | Coverage |
|------|----------|
| Harness + assertion reality | Zero-match/no-file runs, skip accounting, grep-error handling, red-run evidence gate/tool |
| Scratch-state dogfooding | Guards receive generated shell, hook, Git, and session state in temporary projects; Nazgul runtime snapshots are not committed |
| State/review loop | Task transitions, review evidence/provenance, dispatch granularity, stop-hook state machine |
| Config + docs | Terminal schema v36, migration chain, frontmatter, JSON, template freshness, RULES consistency |
| Paid validation | Manual skill E2E, GitHub stack E2E, and manual/nightly true-entry smoke in scratch projects |

### Adversarial suites added by FEAT-029

| File | What it drives adversarially |
|------|------------------------------|
| `test-task-transition-command.sh` | The transactional writer: stale preauthorization, a failed compare-and-swap, exact-edge ledger records, and the refusal of every non-adjacent edge |
| `test-task-reconciliation-repair.sh` | The typed quarantine and `repair`: valid repair, incomplete evidence, a wrong or untyped blocker kind, corrupt quarantine metadata, and the absence of any `READY`/implementer route. Also fails if a direct-status-write instruction or `sed -i` reappears in `agents/review-gate.md` or `skills/task/SKILL.md` |
| `test-agent-worktree-contract.sh` | The full 23-spec agent roster, not the diff: no `EnterWorktree`/`ExitWorktree` grant or body mention survives anywhere, every git command carries `-C`, and an agent handed no worktree stops instead of creating one |
| `test-doc-generator-contract.sh` | The artifact-claim ledger parsed out of the prompt AS RENDERED by the real producer, with framework neutrality pinned negatively (the contract must name no build command) |
| `test-reference-paths.sh` | Every `agents/*.md`, `agents/templates/*.md`, and `skills/*/SKILL.md` citation resolved against a staged package tree built from `git ls-files`, so a git-ignored or working-tree-only file cannot pass for a packaged one |

Two existing suites carry FEAT-029 work rather than new files: `test-pre-tool-guard.sh` feeds the
observed `sed`/Python/Perl/Ruby/awk/`cp`/`mv`/redirect manifest-write forms (plus legitimate reads and
every spelling of the transition CLI) to the closed Bash policy, and `test-parallel-dispatch-guard.sh`
feeds real Agent hook JSON envelopes for named, background, missing, and foreground reviewer calls.

**Known scope gap, reported not fixed.** `skills/start/references/greenfield-scaffolding.md` is not a
`SKILL.md` and is matched by no `SCAN_GLOBS` entry, so `test-reference-paths.sh` makes no claim about
its citations — genuinely unscanned, not vacuously passing. Its one reference was qualified by hand in
FEAT-029/TASK-012; adding the glob was outside that task's declared file scope.

## Red-Run Evidence

For a task that changes `scripts/**` or `tests/**`, capture the scoped pre-change failure after the
implementation commit and before marking the task IMPLEMENTED:

```bash
scripts/red-run.sh TASK-017 --filter=assertion-vacuity --copy=tests/test-assertion-vacuity.sh
```

The tool creates a detached worktree at the task's recorded Base SHA, copies only the named changed
test input, runs the normal harness, and writes the parseable evidence block into the task manifest.
Exit `2` means the test passed without the change and is therefore vacuous; exit `3` means the filter
checked nothing. `guards.red_run_evidence: false` suppresses the IMPLEMENTED block only, not detection
or the `red_run_missing` event.

## Prerequisites

- `jq` — required for JSON tests and script integration tests
- `git` — required for script integration tests (creates temp repos)
- `shellcheck` (optional) — for shell script linting tests; falls back to skip

## Test Library

- `tests/lib/assertions.sh` — `assert_eq`, `assert_contains`, `assert_file_exists`, `assert_json_field`, etc.
- `tests/lib/setup.sh` — `setup_temp_dir`, `setup_git_repo`, `setup_nazgul_dir`, `create_config`, `create_task_file`, `create_plan`

## Manual Test Procedures

These features require an authenticated Claude Code CLI and cannot be tested with shell scripts alone.
An interactive CLI may use the user's stored Claude subscription/OAuth login, so a local session does
not require `ANTHROPIC_API_KEY`. The headless GitHub workflows are separate: `e2e-tests.yml` and
`smoke.yml` explicitly require the repository secret `ANTHROPIC_API_KEY` and spend API money.

### 1. Bootstrap Test (`/nazgul:init`)

1. Open a fresh Claude Code session in this repo
2. Run `/nazgul:init`
3. Verify:
   - `nazgul/config.json` created (not the template — runtime copy)
   - `nazgul/plan.md` created
   - `nazgul/context/` has 5 context files (project-profile, architecture-map, style-conventions, security-surface, test-strategy)
   - At least 3 reviewer agents generated in `.claude/agents/generated/`
   - Discovery status in plan.md is checked off

### 2. Pipeline Test (`/nazgul:start`)

1. After `/nazgul:init`, run `/nazgul:start "Add a hello-world endpoint to README"`
2. Verify:
   - Objective set in `nazgul/config.json`
   - Documents generated in `nazgul/docs/` (at least TRD)
   - Tasks created in `nazgul/tasks/`
   - Plan.md updated with task index
   - Loop begins (stop hook blocks stop, agent continues working)

### 3. Recovery Test

1. During an active loop, close the Claude Code session
2. Reopen and run `/nazgul:start`
3. Verify:
   - Session context hook outputs current state
   - Recovery Pointer in plan.md is accurate
   - Agent resumes from correct task without re-planning

### 4. Parallel Review Test

Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` environment variable.

1. Run a loop that reaches IN_REVIEW status
2. Verify review-gate spawns multiple reviewer subagents
3. Verify feedback-aggregator consolidates reviews
4. Verify all reviewers must approve before DONE
