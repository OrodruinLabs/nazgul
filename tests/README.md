# Hydra Integration Tests

## Running Tests

```bash
# Run the full suite
tests/run-tests.sh

# Run a single test file by filter
tests/run-tests.sh --filter=pre-tool-guard
tests/run-tests.sh --filter=stop-hook
tests/run-tests.sh --filter=json
```

## Test Files

| File | Description | Cases |
|------|-------------|-------|
| `test-json-validation.sh` | All JSON files parse with `jq empty` | 5 |
| `test-frontmatter.sh` | Agent/skill markdown YAML frontmatter validation | ~38 files |
| `test-config-schema.sh` | Config template required fields | 15 |
| `test-hooks-schema.sh` | Hook wiring, matchers, script references | 8 |
| `test-shellcheck.sh` | `bash -n` + `shellcheck -S warning` on all scripts | 8 |
| `test-pre-tool-guard.sh` | Dangerous command blocking | 18 |
| `test-session-context.sh` | Context output, compaction counter | 10 |
| `test-pre-compact.sh` | Checkpoint creation, recovery stdout | 8 |
| `test-stop-hook.sh` | Full state machine: exits, loops, mutations | 22 |

## Prerequisites

- `jq` — required for JSON tests and script integration tests
- `git` — required for script integration tests (creates temp repos)
- `shellcheck` (optional) — for shell script linting tests; falls back to skip

## Test Library

- `tests/lib/assertions.sh` — `assert_eq`, `assert_contains`, `assert_file_exists`, `assert_json_field`, etc.
- `tests/lib/setup.sh` — `setup_temp_dir`, `setup_git_repo`, `setup_hydra_dir`, `create_config`, `create_task_file`, `create_plan`

## Manual Test Procedures

These features require runtime Claude Code and cannot be tested with shell scripts alone.

### 1. Bootstrap Test (`/hydra:init`)

1. Open a fresh Claude Code session in this repo
2. Run `/hydra:init`
3. Verify:
   - `hydra/config.json` created (not the template — runtime copy)
   - `hydra/plan.md` created
   - `hydra/context/` has 5 context files (project-profile, architecture-map, style-conventions, security-surface, test-strategy)
   - At least 3 reviewer agents generated in `.claude/agents/generated/`
   - Discovery status in plan.md is checked off

### 2. Pipeline Test (`/hydra:start`)

1. After `/hydra:init`, run `/hydra:start "Add a hello-world endpoint to README"`
2. Verify:
   - Objective set in `hydra/config.json`
   - Documents generated in `hydra/docs/` (at least TRD)
   - Tasks created in `hydra/tasks/`
   - Plan.md updated with task index
   - Loop begins (stop hook blocks stop, agent continues working)

### 3. Recovery Test

1. During an active loop, close the Claude Code session
2. Reopen and run `/hydra:start`
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
