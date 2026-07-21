# Parallel Execution Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the conductor execution engine and give the sequential stop-hook loop a deterministic parallel-batch dispatch option (`execution.parallel`).

**Architecture:** One engine — the existing stop-hook loop — drives everything from the main session. A new pure-shell lib (`parallel-batch.sh`) computes dispatchable batches from task manifests + plan.md Wave Groups. The stop-hook emits a batch instruction when parallel mode is on; guards re-key from the conductor's `.session` marker + `graph.json` to `execution.parallel` + task manifests. All conductor files are deleted.

**Tech Stack:** Bash (POSIX-safe, `jq` for all JSON), Claude Code plugin (skills/agents/hooks), bash test harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-07-21-parallel-execution-collapse-design.md`

## Global Constraints

- Shell scripts use `set -euo pipefail` (sourced libs deliberately do NOT — they follow the idempotent-source-guard pattern of `conductor-graph.sh`). All variables quoted. `jq` for JSON, never sed/grep.
- All scripts must pass `bash -n` and `shellcheck`.
- Config schema bump is **v25 → v26** (v25 = FEAT-012 connectors).
- Sequential-mode behavior must be **byte-identical**: with `execution.parallel` absent/false, `stop-hook.sh` stderr output and exit codes must not change.
- Version bump: plugin.json `2.15.0` → `2.16.0`.
- Default branch is `main`. Kebab-case filenames.
- Run tests with `tests/run-tests.sh --filter=<name>`; full suite `tests/run-tests.sh`.
- Test conventions (see `tests/lib/setup.sh` + `tests/lib/assertions.sh`): `set -uo pipefail` (no `-e`), `setup_temp_dir`/`setup_nazgul_dir`/`setup_git_repo`, `create_config '<jq patch>'...`, `create_task_file TASK-NNN STATUS [deps]`, `create_task_file_with_commits TASK-NNN STATUS "sha"`, `teardown_temp_dir`, asserts `assert_eq`/`assert_contains`/`assert_exit_code`/`assert_file_exists`, `_pass`/`_fail`. `setup_temp_dir` exports `CLAUDE_PROJECT_DIR="$TEST_DIR"`.
- Task manifest fields (from `tests/lib/setup.sh` + `agents/planner.md`): `- **Status**:`, `- **Depends on**:`, `- **Group**:`, `- **Files modified**:` (comma-separated list), `## Commits` section with `- <sha>` lines. Read via `get_task_status <file> <default>` and `get_task_field <file> <field> <default>` from `scripts/lib/task-utils.sh`.
- Commit after every task with prefix `feat(parallel):`, `refactor(parallel):`, or `docs(parallel):` as appropriate, plus the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `scripts/lib/parallel-batch.sh` — batch selection + gates lib

**Files:**
- Create: `scripts/lib/parallel-batch.sh`
- Create: `tests/test-parallel-batch.sh`
- Reference (do not modify yet): `scripts/lib/conductor-graph.sh` (source of `compute_waves`), `scripts/lib/conductor-gates.sh` (source of gates/hard-stops)

**Interfaces:**
- Produces (later tasks rely on these exact names):
  - `compute_waves <tasks_dir>` → wave partition JSON `[{"wave":1,"units":[...]}, ...]`; excludes DONE; exit 1 + stderr on cycle/unknown dep. (Moved from conductor-graph.sh; the graph.json input branch is dropped — tasks-dir input only.)
  - `compute_dispatch_batch <tasks_dir> <plan_md> <max_parallel>` → `{"tasks":[...],"parallel":bool,"reason":"..."}`
  - `execution_parallel_enabled <config>` → prints `true`/`false` (default false)
  - `execution_max_parallel <config>` → prints int (default 3)
  - `execution_gate_stored <config> <gate>` / `execution_gate_effective <config> <gate> <mode>` / `execution_should_pause <config> <gate> <mode>` — gates are `approve_plan`, `approve_batch`, `approve_final_pr` under `.execution.gates`; `approve_plan` flips effective-true in `hitl` mode (same rule as the old `approve_graph`)
  - `execution_should_halt <nazgul_dir>` → machine-parseable hard-stop lines, rc 1 on halt (same `BLOCKED_TASK`/`SECURITY_REJECTION`/`*_AMBIGUOUS`/`*_UNREADABLE` lines as `conductor_should_halt`)

- [ ] **Step 1: Write the failing test**

Create `tests/test-parallel-batch.sh` (mark executable). Full content:

```bash
#!/usr/bin/env bash
set -uo pipefail
# Test: parallel-batch.sh — batch selection, gates, hard stops (spec §2)

TEST_NAME="test-parallel-batch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/parallel-batch.sh"

# Helper: manifest with Files modified + optional deps
make_task() { # id status deps files
  create_task_file "$1" "$2" "${3:-none}"
  printf -- '- **Files modified**: %s\n' "$4" >> "$TEST_DIR/nazgul/tasks/$1.md"
}

# Helper: plan.md with a Wave Groups section
make_plan_waves() { # lines...
  mkdir -p "$TEST_DIR/nazgul"
  { echo "# Plan"; echo; echo "## Wave Groups"; echo;
    for l in "$@"; do echo "$l"; done; echo; echo "## Other"; } \
    > "$TEST_DIR/nazgul/plan.md"
}

# --- 1: no candidates -> empty, sequential ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 DONE none "a.sh"
make_plan_waves "### Wave 1" "- TASK-001"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no candidates: empty tasks" "$(jq -r '.tasks|length' <<< "$OUT")" "0"
assert_eq "no candidates: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 2: single READY -> batch of one ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "a.sh"
make_plan_waves "### Wave 1" "- TASK-001"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "single: one task" "$(jq -r '.tasks[0]' <<< "$OUT")" "TASK-001"
assert_eq "single: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 3: dep gating — READY task with non-DONE dep is not a candidate ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 IN_PROGRESS none "a.sh"
make_task TASK-002 READY "TASK-001" "b.sh"
make_task TASK-003 READY none "c.sh"
make_plan_waves "### Wave 1" "- TASK-002, TASK-003 (independent)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "dep gate: only TASK-003" "$(jq -r '.tasks|join(",")' <<< "$OUT")" "TASK-003"
assert_eq "dep gate: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 4: happy path — 2 grouped candidates, disjoint scopes -> parallel ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh, src/a2.sh"
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002 (independent, no file overlap)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "happy: parallel true" "$(jq -r '.parallel' <<< "$OUT")" "true"
assert_eq "happy: both tasks in order" "$(jq -r '.tasks|join(",")' <<< "$OUT")" "TASK-001,TASK-002"
teardown_temp_dir

# --- 5: overlap -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh, src/shared.sh"
make_task TASK-002 READY none "src/shared.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "overlap: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
assert_eq "overlap: single task" "$(jq -r '.tasks|length' <<< "$OUT")" "1"
assert_contains "overlap: reason says overlap" "$OUT" "overlap"
teardown_temp_dir

# --- 6: missing Files modified -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY   # no Files modified
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no scope: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 7: no Wave Groups section -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
echo "# Plan (no waves)" > "$TEST_DIR/nazgul/plan.md"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no waves: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 8: candidates on DIFFERENT wave lines are never batched together ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001" "### Wave 2" "- TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "separate lines: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 9: max_parallel caps the batch ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
make_task TASK-003 READY none "src/c.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002, TASK-003 (independent)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 2)
assert_eq "cap: batch of 2" "$(jq -r '.tasks|length' <<< "$OUT")" "2"
assert_eq "cap: still parallel" "$(jq -r '.parallel' <<< "$OUT")" "true"
teardown_temp_dir

# --- 10: gates — defaults + hitl flip for approve_plan only ---
setup_temp_dir; setup_nazgul_dir; create_config
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "gate default: approve_batch false" "$(execution_gate_stored "$CONFIG" approve_batch)" "false"
assert_eq "gate hitl: approve_plan effective true" "$(execution_gate_effective "$CONFIG" approve_plan hitl)" "true"
assert_eq "gate hitl: approve_batch stays false" "$(execution_gate_effective "$CONFIG" approve_batch hitl)" "false"
assert_eq "parallel default: false" "$(execution_parallel_enabled "$CONFIG")" "false"
assert_eq "max_parallel default: 3" "$(execution_max_parallel "$CONFIG")" "3"
teardown_temp_dir

# --- 11: hard stops — BLOCKED task halts ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 BLOCKED
if OUT=$(execution_should_halt "$TEST_DIR/nazgul"); then
  _fail "hard stop: should return non-zero on BLOCKED"
else
  _pass "hard stop: non-zero on BLOCKED"
fi
assert_contains "hard stop: names task" "$OUT" "BLOCKED_TASK TASK-001"
teardown_temp_dir

# --- 12: compute_waves moved — Kahn layering works from tasks dir ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY
create_task_file TASK-002 READY "TASK-001"
WAVES=$(compute_waves "$TEST_DIR/nazgul/tasks")
assert_eq "waves: TASK-001 in wave 1" "$(jq -r '.[0].units[0]' <<< "$WAVES")" "TASK-001"
assert_eq "waves: TASK-002 in wave 2" "$(jq -r '.[1].units[0]' <<< "$WAVES")" "TASK-002"
teardown_temp_dir

print_summary
```

(Check `tests/lib/assertions.sh` for the exact summary function name — existing tests end with the same call; mirror it exactly.)

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=parallel-batch`
Expected: FAIL — `parallel-batch.sh: No such file or directory`

- [ ] **Step 3: Write the lib**

Create `scripts/lib/parallel-batch.sh`. Structure (complete code):

```bash
#!/usr/bin/env bash
# Nazgul parallel-batch — deterministic batch selection, gates, and hard stops
# for the parallel dispatch option (execution.parallel). Replaces the deleted
# conductor engine's conductor-graph.sh (compute_waves) and conductor-gates.sh
# (gates + hard stops). Task manifests are the ONLY state source — there is no
# stored graph.
#
# Idempotent source guard; NOT `set -euo pipefail` (sourced into hook shells).

[ -n "${_NAZGUL_PARALLEL_BATCH_SOURCED:-}" ] && return 0
_NAZGUL_PARALLEL_BATCH_SOURCED=1

_PB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_PB_DIR/task-utils.sh"
```

Then, in order:

1. `_pb_task_map_from_dir` + `_pb_layer_waves` + `compute_waves` — copy `_cg_task_map_from_dir`, `_cg_layer_waves`, and `compute_waves` **verbatim** from `scripts/lib/conductor-graph.sh:43-136`, renaming the `_cg_` prefix to `_pb_` and deleting `compute_waves`' graph-json file branch (`elif [ -f "$input" ]` arm) — tasks-dir input only, error otherwise.

2. Gates — adapt from `scripts/lib/conductor-gates.sh:22-66`, re-keyed to `.execution`:

```bash
# execution_parallel_enabled <config> -> "true"/"false" (default false)
execution_parallel_enabled() {
  local config="$1" val
  [ -f "$config" ] || { echo "false"; return 0; }
  val=$(jq -r '.execution.parallel // false' "$config" 2>/dev/null)
  [ "$val" = "true" ] && { echo "true"; return 0; }
  echo "false"
}

# execution_max_parallel <config> -> int (default 3)
execution_max_parallel() {
  local config="$1"
  [ -f "$config" ] || { echo "3"; return 0; }
  jq -r '.execution.max_parallel // 3' "$config" 2>/dev/null || echo "3"
}

# execution_gate_stored <config> <gate> -> stored .execution.gates.<gate>
execution_gate_stored() {
  local config="$1" gate="$2" val
  [ -f "$config" ] || { echo "false"; return 0; }
  val=$(jq -r --arg g "$gate" '.execution.gates[$g] // false' "$config" 2>/dev/null)
  [ "$val" = "true" ] && { echo "true"; return 0; }
  echo "false"
}

# execution_gate_effective <config> <gate> <mode> — approve_plan flips true in
# hitl (same rule the conductor gave approve_graph); others equal stored value.
execution_gate_effective() {
  local config="$1" gate="$2" mode="$3"
  if [ "$gate" = "approve_plan" ] && [ "$mode" = "hitl" ]; then
    echo "true"; return 0
  fi
  execution_gate_stored "$config" "$gate"
}

execution_should_pause() {
  [ "$(execution_gate_effective "$1" "$2" "$3")" = "true" ]
}
```

3. Hard stops — copy `_cgate_blocked_tasks` and `_cgate_security_rejections` **verbatim** from `scripts/lib/conductor-gates.sh:74-132` with `_pb_` prefix (they already read only manifests + reviews dir — no graph dependency), then:

```bash
# execution_should_halt <nazgul_dir> — UNCONDITIONAL hard stops: any BLOCKED
# task, any non-APPROVE security verdict. Not routable-around by any gate or
# mode, including yolo. Ambiguity fails closed.
execution_should_halt() {
  local nazgul_dir="$1" problems=0
  _pb_blocked_tasks "$nazgul_dir/tasks" || problems=1
  _pb_security_rejections "$nazgul_dir" || problems=1
  [ "$problems" -eq 0 ]
}
```

Note: `_cgate_security_rejections` calls `read_verdict` — that comes from `task-utils.sh` (verify with `grep -n "read_verdict" scripts/lib/task-utils.sh`; if it lives in `review-evidence.sh` instead, source that too).

4. `compute_dispatch_batch` (new — complete code):

```bash
# compute_dispatch_batch <tasks_dir> <plan_md> <max_parallel>
# -> {"tasks": [...], "parallel": bool, "reason": "..."}
# Deterministic batch selection (spec §2). Every doubt falls back to a batch of
# one (proven sequential behavior). A multi-task batch requires: >=2 candidates
# (READY, all deps DONE) listed TOGETHER on one plan.md Wave Groups line, with
# pairwise-disjoint "Files modified" scopes, capped at max_parallel.
compute_dispatch_batch() {
  local tasks_dir="$1" plan_md="$2" max_parallel="$3"
  case "$max_parallel" in ''|*[!0-9]*|0) max_parallel=3 ;; esac

  local file id status deps_raw d ok
  local -a candidates=()
  for file in "$tasks_dir"/TASK-*.md; do
    [ -f "$file" ] || continue
    id=$(basename "$file" .md)
    status=$(get_task_status "$file" "PLANNED")
    [ "$status" = "READY" ] || continue
    deps_raw=$(get_task_field "$file" "Depends on" "none")
    deps_raw="${deps_raw//,/ }"
    ok=1
    for d in $deps_raw; do
      case "$d" in none|None|NONE|"") continue ;; esac
      [ -f "$tasks_dir/$d.md" ] || { ok=0; break; }
      [ "$(get_task_status "$tasks_dir/$d.md" "PLANNED")" = "DONE" ] || { ok=0; break; }
    done
    [ "$ok" -eq 1 ] && candidates+=("$id")
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    jq -n '{tasks: [], parallel: false, reason: "no dispatchable tasks"}'
    return 0
  fi

  _pb_single_result() {
    jq -n --arg t "${candidates[0]}" --arg r "$1" \
      '{tasks: [$t], parallel: false, reason: $r}'
  }

  if [ "${#candidates[@]}" -eq 1 ]; then
    _pb_single_result "single candidate"; return 0
  fi
  if [ ! -f "$plan_md" ] || ! grep -q '^## Wave Groups' "$plan_md"; then
    _pb_single_result "no Wave Groups section in plan.md"; return 0
  fi

  # First Wave Groups bullet line naming >=2 candidates together wins.
  # Membership test via case over a padded string — POSIX-safe, no arrays-in-arrays.
  local cand_padded=" ${candidates[*]} " line lid
  local -a batch=()
  while IFS= read -r line; do
    batch=()
    for lid in $(printf '%s' "$line" | grep -oE 'TASK-[0-9]+'); do
      case "$cand_padded" in
        *" $lid "*) batch+=("$lid") ;;
      esac
    done
    [ "${#batch[@]}" -ge 2 ] && break
    batch=()
  done < <(sed -n '/^## Wave Groups/,/^## [^#]/p' "$plan_md" | grep -E '^- ')

  if [ "${#batch[@]}" -lt 2 ]; then
    _pb_single_result "no wave line groups >=2 ready tasks"; return 0
  fi

  # Cap at max_parallel, keep line order.
  if [ "${#batch[@]}" -gt "$max_parallel" ]; then
    batch=("${batch[@]:0:$max_parallel}")
  fi

  # Pairwise-disjoint "Files modified" scopes; missing/empty scope -> fallback.
  local m files all=""
  for m in "${batch[@]}"; do
    files=$(get_task_field "$tasks_dir/$m.md" "Files modified" "")
    if [ -z "$files" ]; then
      _pb_single_result "missing file scope for $m"; return 0
    fi
    all+="${files//,/$'\n'}"$'\n'
  done
  local dup
  dup=$(printf '%s\n' "$all" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' | sort | uniq -d | head -1)
  if [ -n "$dup" ]; then
    _pb_single_result "file scope overlap: $dup"; return 0
  fi

  printf '%s\n' "${batch[@]}" | jq -R . | jq -s \
    '{tasks: ., parallel: true, reason: "wave group, disjoint scopes"}'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/run-tests.sh --filter=parallel-batch`
Expected: PASS (all 12 sections). Also run `bash -n scripts/lib/parallel-batch.sh && shellcheck scripts/lib/parallel-batch.sh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/parallel-batch.sh tests/test-parallel-batch.sh
git commit -m "feat(parallel): parallel-batch lib — batch selection, gates, hard stops"
```

---

### Task 2: Config surface — migration v25→v26, template, start flags

**Files:**
- Modify: `scripts/migrate-config.sh` (append `migrate_25_to_26` after `migrate_24_to_25`, `scripts/migrate-config.sh:525`)
- Modify: `templates/config.json` (execution/conductor sections ~lines 75-92; heartbeat auto_start ~line 101; models.conductor ~line 218; `schema_version` line 2)
- Modify: `scripts/apply-start-flags.sh` (flag parsing ~lines 10-56)
- Modify: `scripts/heartbeat.sh` (auto_start engine mapping ~lines 98-116)
- Test: `tests/test-migrate-config.sh`, `tests/test-start-flags.sh`, `tests/test-config-schema.sh` (extend existing)

**Interfaces:**
- Produces: config keys `execution.parallel` (bool), `execution.max_parallel` (int), `execution.gates.{approve_plan,approve_batch,approve_final_pr}` (bools), `execution.enforce.{dispatch_guard,rework_guard,premerge_guard}` (bools, default true). `.execution.engine`, `.conductor.*`, `.models.conductor`, and `.automation.heartbeat.auto_start.engine` no longer exist post-migration (`auto_start.parallel` bool replaces the last).
- Consumes: nothing from Task 1.

- [ ] **Step 1: Write failing migration tests**

Append to `tests/test-migrate-config.sh` (follow its existing per-case pattern — read the file's first case and mirror setup/assert style):

```bash
# --- v25 -> v26: conductor collapse -> execution.parallel ---
setup_temp_dir; setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" << 'EOF'
{"schema_version": 25,
 "execution": {"engine": "conductor"},
 "conductor": {"gates": {"approve_graph": true, "approve_each_wave": false, "approve_final_pr": true},
               "max_parallel": 5,
               "enforce": {"dispatch_guard": false, "rework_guard": true, "premerge_guard": true}},
 "automation": {"heartbeat": {"auto_start": {"mode": "yolo", "engine": "conductor"}}},
 "models": {"conductor": "sonnet"}}
EOF
mkdir -p "$TEST_DIR/nazgul/conductor"; echo '{}' > "$TEST_DIR/nazgul/conductor/graph.json"
run_migration   # use this test file's existing helper that invokes migrate-config.sh
CFG="$TEST_DIR/nazgul/config.json"
assert_eq "v26: parallel seeded from engine" "$(jq -r '.execution.parallel' "$CFG")" "true"
assert_eq "v26: max_parallel carried" "$(jq -r '.execution.max_parallel' "$CFG")" "5"
assert_eq "v26: approve_plan from approve_graph" "$(jq -r '.execution.gates.approve_plan' "$CFG")" "true"
assert_eq "v26: approve_batch from approve_each_wave" "$(jq -r '.execution.gates.approve_batch' "$CFG")" "false"
assert_eq "v26: explicit enforce false preserved" "$(jq -r '.execution.enforce.dispatch_guard' "$CFG")" "false"
assert_eq "v26: engine key deleted" "$(jq -r '.execution | has("engine")' "$CFG")" "false"
assert_eq "v26: conductor section deleted" "$(jq -r 'has("conductor")' "$CFG")" "false"
assert_eq "v26: models.conductor deleted" "$(jq -r '.models | has("conductor")' "$CFG")" "false"
assert_eq "v26: auto_start.parallel true" "$(jq -r '.automation.heartbeat.auto_start.parallel' "$CFG")" "true"
assert_eq "v26: auto_start.engine deleted" "$(jq -r '.automation.heartbeat.auto_start | has("engine")' "$CFG")" "false"
if [ -d "$TEST_DIR/nazgul/conductor" ]; then _fail "v26: nazgul/conductor removed"; else _pass "v26: nazgul/conductor removed"; fi
teardown_temp_dir

# --- v25 -> v26: sequential config stays sequential ---
setup_temp_dir; setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" << 'EOF'
{"schema_version": 25, "execution": {"engine": "sequential"}, "conductor": {"max_parallel": 3}}
EOF
run_migration
assert_eq "v26 seq: parallel false" "$(jq -r '.execution.parallel' "$TEST_DIR/nazgul/config.json")" "false"
teardown_temp_dir
```

- [ ] **Step 2: Run to verify failure**

Run: `tests/run-tests.sh --filter=migrate-config`
Expected: FAIL — no `migrate_25_to_26` function (`ERROR: Missing migration function`).

- [ ] **Step 3: Implement `migrate_25_to_26`**

Append after `migrate_24_to_25` in `scripts/migrate-config.sh`. **`//` in jq treats explicit `false` as absent — every default-true key MUST use `has()` checks, never `//`:**

```bash
migrate_25_to_26() {
  local tmp; tmp=$(mktemp)
  # Parallel Execution Collapse: conductor engine removed; one engine with an
  # execution.parallel option. Seeds execution.* from conductor.* (explicit
  # values incl. false preserved via has()), then deletes .execution.engine,
  # .conductor, .models.conductor, and auto_start.engine. Also removes the
  # nazgul/conductor runtime dir (graph.json was a mirror of task manifests).
  jq '
    . as $root
    | ($root.conductor // {}) as $c
    | ($c.gates // {}) as $cg
    | ($c.enforce // {}) as $ce
    | .execution = ((if (.execution | type) == "object" then .execution else {} end)
      | .parallel = (if has("parallel") then .parallel
                     else (($root.execution.engine // "sequential") == "conductor") end)
      | .max_parallel = (if has("max_parallel") then .max_parallel
                         else (if ($c | has("max_parallel")) then $c.max_parallel else 3 end) end)
      | .gates = ((if (.gates | type) == "object" then .gates else {} end)
          | .approve_plan = (if has("approve_plan") then .approve_plan
                             else (if ($cg | has("approve_graph")) then $cg.approve_graph else false end) end)
          | .approve_batch = (if has("approve_batch") then .approve_batch
                              else (if ($cg | has("approve_each_wave")) then $cg.approve_each_wave else false end) end)
          | .approve_final_pr = (if has("approve_final_pr") then .approve_final_pr
                                 else (if ($cg | has("approve_final_pr")) then $cg.approve_final_pr else false end) end))
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .dispatch_guard = (if has("dispatch_guard") then .dispatch_guard
                               else (if ($ce | has("dispatch_guard")) then $ce.dispatch_guard else true end) end)
          | .rework_guard = (if has("rework_guard") then .rework_guard
                             else (if ($ce | has("rework_guard")) then $ce.rework_guard else true end) end)
          | .premerge_guard = (if has("premerge_guard") then .premerge_guard
                               else (if ($ce | has("premerge_guard")) then $ce.premerge_guard else true end) end))
      | del(.engine))
    | del(.conductor)
    | (if (.models | type) == "object" then .models |= del(.conductor) else . end)
    | (if (.automation.heartbeat.auto_start | type) == "object"
       then .automation.heartbeat.auto_start |=
         ((.parallel = (if has("parallel") then .parallel else ((.engine // "conductor") == "conductor") end))
          | del(.engine))
       else . end)
    | .schema_version = 26
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  rm -rf "$(dirname "$CONFIG")/conductor"
  log_migration "v25→v26: conductor engine collapsed — execution.parallel/max_parallel/gates{approve_plan,approve_batch,approve_final_pr}/enforce{dispatch,rework,premerge} seeded from conductor.* (explicit values incl. false preserved); deleted execution.engine, conductor.*, models.conductor, auto_start.engine (→auto_start.parallel); removed nazgul/conductor dir"
}
```

- [ ] **Step 4: Update `templates/config.json`**

- `"schema_version": 25` → `26`.
- Replace the `"execution"` and `"conductor"` blocks (template lines ~75-92) with:

```json
  "execution": {
    "parallel": false,
    "max_parallel": 3,
    "gates": {
      "approve_plan": false,
      "approve_batch": false,
      "approve_final_pr": false
    },
    "enforce": {
      "dispatch_guard": true,
      "rework_guard": true,
      "premerge_guard": true
    }
  },
```

- In `automation.heartbeat.auto_start`: `"engine": "conductor"` → `"parallel": true`.
- In `models`: delete the `"conductor": "sonnet",` line.

- [ ] **Step 5: Update `scripts/apply-start-flags.sh`**

Replace the conductor flag plumbing (`scripts/apply-start-flags.sh:10,23,54-56`):

```bash
yolo=false; afk=false; hitl=false; task_pr=false; parallel=false
...
    --parallel) parallel=true ;;
    --conductor) parallel=true; echo "Nazgul: --conductor is deprecated; treating as --parallel." >&2 ;;
...
# --parallel is orthogonal to mode (an operator can pair it with --afk/--hitl/--yolo)
[ "$parallel" = true ] && jqp="$jqp | .execution.parallel=true"
```

- [ ] **Step 6: Update `scripts/heartbeat.sh` auto-start mapping**

At `scripts/heartbeat.sh:98-116`, replace the engine read + flag:

```bash
    local mode par mode_flag=""
    ...
    par=$(jq -r '.automation.heartbeat.auto_start.parallel // true' "$CONFIG" 2>/dev/null || echo "true")
    ...
    local par_flag=""
    [ "$par" = "true" ] && par_flag="--parallel"
    ...
    (cd "$PROJECT_ROOT" && claude -p "/nazgul:start \"$safe_objective\" $mode_flag $par_flag")
```

(Also update the comment block at lines 91-92 to say `auto_start.{mode,parallel}` default `yolo`/`true`.)

- [ ] **Step 7: Update flag + schema tests**

- `tests/test-start-flags.sh`: find the `--conductor` case(s) (`grep -n conductor tests/test-start-flags.sh`); change assertions from `.execution.engine == "conductor"` to `.execution.parallel == true`, and add a `--parallel` case asserting the same.
- `tests/test-config-schema.sh`: update any assertions on `execution.engine` / `conductor.*` keys to the new `execution.*` keys (`grep -n 'conductor\|engine' tests/test-config-schema.sh`).

- [ ] **Step 8: Run and verify**

Run: `tests/run-tests.sh --filter=migrate-config && tests/run-tests.sh --filter=start-flags && tests/run-tests.sh --filter=config-schema`
Expected: PASS. Also `bash -n` + `shellcheck` on the three modified scripts.

- [ ] **Step 9: Commit**

```bash
git add scripts/migrate-config.sh templates/config.json scripts/apply-start-flags.sh scripts/heartbeat.sh tests/test-migrate-config.sh tests/test-start-flags.sh tests/test-config-schema.sh
git commit -m "feat(parallel): config schema v26 — execution.parallel replaces conductor engine"
```

---

### Task 3: Stop-hook parallel branch

**Files:**
- Modify: `scripts/stop-hook.sh` (source line ~17; config-read area ~line 49; pre-CONTINUE ~line 1087; DISPATCH_INSTR block lines 1110-1127)
- Test: `tests/test-stop-hook-parallel.sh` (create; model on `tests/test-granularity-gate.sh`, which drives the real stop-hook via `run_hook`)

**Interfaces:**
- Consumes from Task 1: `compute_dispatch_batch`, `execution_should_halt`, `execution_should_pause`, `execution_parallel_enabled`, `execution_max_parallel`.
- Produces: the stderr instruction contract for parallel batches — the strings `DELEGATE (PARALLEL BATCH` and `NAZGUL_UNIT:` that Task 6's skill text references.

- [ ] **Step 1: Write failing tests**

Create `tests/test-stop-hook-parallel.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
TEST_NAME="test-stop-hook-parallel"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
run_hook() { HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?; }

make_parallel_pair() {
  create_task_file TASK-001 READY
  printf -- '- **Files modified**: src/a.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
  create_task_file TASK-002 READY
  printf -- '- **Files modified**: src/b.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
  cat > "$TEST_DIR/nazgul/plan.md" << 'EOF'
# Plan

## Recovery Pointer
- test

## Wave Groups

### Wave 1
- TASK-001, TASK-002 (independent, no file overlap)
EOF
}

# --- 1: parallel on + eligible pair -> batch instruction, exit 2 ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.max_parallel = 3' '.mode = "afk"'
make_parallel_pair
run_hook
assert_exit_code "parallel: blocks stop" "$HOOK_EC" 2
assert_contains "parallel: batch instruction" "$HOOK_OUTPUT" "DELEGATE (PARALLEL BATCH"
assert_contains "parallel: both tasks named" "$HOOK_OUTPUT" "TASK-002"
assert_contains "parallel: NAZGUL_UNIT contract" "$HOOK_OUTPUT" "NAZGUL_UNIT"
assert_contains "parallel: worktree isolation" "$HOOK_OUTPUT" "worktree"
teardown_temp_dir

# --- 2: parallel off -> sequential instruction byte-identical (regression) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "afk"'
make_parallel_pair
run_hook
assert_exit_code "sequential: blocks stop" "$HOOK_EC" 2
assert_contains "sequential: single-task delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001."
if printf '%s' "$HOOK_OUTPUT" | grep -q "PARALLEL BATCH"; then
  _fail "sequential: no batch instruction"
else
  _pass "sequential: no batch instruction"
fi
teardown_temp_dir

# --- 3: parallel on + BLOCKED task -> hard stop, exit 0 ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"'
make_parallel_pair
create_task_file TASK-003 BLOCKED
run_hook
assert_exit_code "hard stop: allows stop" "$HOOK_EC" 0
assert_contains "hard stop: names blocked task" "$HOOK_OUTPUT" "BLOCKED_TASK TASK-003"
teardown_temp_dir

# --- 4: parallel on + approve_batch gate -> instruction carries the gate ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.gates.approve_batch = true' '.mode = "afk"'
make_parallel_pair
run_hook
assert_exit_code "gate: still blocks stop" "$HOOK_EC" 2
assert_contains "gate: approval demanded before dispatch" "$HOOK_OUTPUT" "GATE approve_batch"
teardown_temp_dir

# --- 5: parallel on but overlap -> falls back to sequential instruction ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"'
create_task_file TASK-001 READY
printf -- '- **Files modified**: src/shared.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
create_task_file TASK-002 READY
printf -- '- **Files modified**: src/shared.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
cat > "$TEST_DIR/nazgul/plan.md" << 'EOF'
# Plan

## Wave Groups

### Wave 1
- TASK-001, TASK-002
EOF
run_hook
assert_exit_code "overlap: blocks stop" "$HOOK_EC" 2
assert_contains "overlap: sequential delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent"
teardown_temp_dir

print_summary
```

(Adjust `create_config` patches if `create_config` requires them as separate args — mirror `test-granularity-gate.sh:22-27`. If the hook requires more fixture files to reach the CONTINUE section — e.g. a checkpoint dir — copy whatever `test-granularity-gate.sh`'s setup provides.)

- [ ] **Step 2: Run to verify failure**

Run: `tests/run-tests.sh --filter=stop-hook-parallel`
Expected: cases 1, 3, 4 FAIL (no parallel branch yet); cases 2 and 5's sequential assertions pass.

- [ ] **Step 3: Implement the stop-hook branch**

Three edits to `scripts/stop-hook.sh`:

**(a)** After the existing `source` lines (line ~17): `source "$SCRIPT_DIR/lib/parallel-batch.sh"`

**(b)** After the GRANULARITY read (~line 50):

```bash
# Parallel dispatch option (execution.parallel — Parallel Execution Collapse).
EXEC_PARALLEL=$(execution_parallel_enabled "$CONFIG")
```

**(c)** Immediately before the `# --- CONTINUE LOOP ---` marker (~line 1087), the hard-stop check (parallel mode only — sequential path byte-identical):

```bash
# Parallel-mode hard stops: any BLOCKED task or non-APPROVE security verdict
# halts the loop for a human. UNCONDITIONAL — overrides every gate and mode,
# including yolo. (Sequential mode keeps its existing BLOCKED-skip behavior.)
if [ "$EXEC_PARALLEL" = "true" ]; then
  if ! HALT_LINES=$(execution_should_halt "$NAZGUL_DIR"); then
    echo "Nazgul: parallel hard stop — halting for human review:" >&2
    printf '%s\n' "$HALT_LINES" >&2
    exit 0
  fi
fi
```

**(d)** Immediately after the existing `DISPATCH_INSTR` if/elif chain closes (line ~1127), the batch override:

```bash
# Parallel batch override: only for a fresh READY dispatch in task granularity.
# compute_dispatch_batch falls back to a single task on any doubt, in which
# case the sequential DISPATCH_INSTR above stands unchanged.
if [ "$EXEC_PARALLEL" = "true" ] && [ "$GRANULARITY" = "task" ] \
   && [ "$ACTIVE_STATUS" = "READY" ]; then
  EXEC_MAX_PARALLEL=$(execution_max_parallel "$CONFIG")
  BATCH_JSON=$(compute_dispatch_batch "$NAZGUL_DIR/tasks" "$PLAN" "$EXEC_MAX_PARALLEL" 2>/dev/null \
    || echo '{"tasks":[],"parallel":false}')
  if [ "$(jq -r '.parallel' <<< "$BATCH_JSON")" = "true" ]; then
    BATCH_TASKS=$(jq -r '.tasks | join(", ")' <<< "$BATCH_JSON")
    BATCH_COUNT=$(jq -r '.tasks | length' <<< "$BATCH_JSON")
    DISPATCH_INSTR="DELEGATE (PARALLEL BATCH of ${BATCH_COUNT}): ${BATCH_TASKS}.
0. Crash recovery first: if a batch task already has a worktree/branch feat/<display_id>/<id> left by an interrupted batch — a branch WITH commits is resumed (merge it per step 2, skip re-implementing), a dirty/commit-less one is removed (git worktree remove --force, delete the branch) before dispatching. Deterministic rule, no judgment.
1. Dispatch ONE implementer agent (nazgul:implementer) PER task — ALL Agent calls in a SINGLE message so they run concurrently. Each prompt gets ONLY its task id, its manifest path nazgul/tasks/<id>.md, its file scope, and the line 'NAZGUL_UNIT: <id>'. Each implementer works in its OWN git worktree (branch feat/<display_id>/<id> off the feature branch) and commits there — NEVER in the shared working tree.
2. WAIT for every implementer to return. Then merge each task branch into the feature branch sequentially (git merge --no-ff). On conflict: git merge --abort, set that task CHANGES_REQUESTED with a note, keep its branch for inspection — never force-merge.
3. Record each merged task's commit SHA under its manifest's ## Commits and set Status: IMPLEMENTED.
4. Dispatch ONE review-gate agent (nazgul:review-gate) PER merged task — all in a single message — each prompt carrying 'NAZGUL_UNIT: <id>'.
Do not start any task outside this batch until every batch task reaches a terminal state."
    if execution_should_pause "$CONFIG" approve_batch "$MODE"; then
      DISPATCH_INSTR="GATE approve_batch: present this batch to the human and WAIT for explicit approval BEFORE dispatching anything.
${DISPATCH_INSTR}"
    fi
  fi
fi
```

- [ ] **Step 4: Run and verify**

Run: `tests/run-tests.sh --filter=stop-hook-parallel`
Expected: PASS (all 5). Then run the neighboring stop-hook-driven suites to prove sequential regression: `tests/run-tests.sh --filter=granularity-gate` — PASS unchanged. `bash -n scripts/stop-hook.sh && shellcheck scripts/stop-hook.sh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/stop-hook.sh tests/test-stop-hook-parallel.sh
git commit -m "feat(parallel): stop-hook batch dispatch branch + parallel-mode hard stops"
```

---

### Task 4: Guards — rename + re-key to manifests

**Files:**
- Create: `scripts/parallel-dispatch-guard.sh` (from `scripts/conductor-dispatch-guard.sh`)
- Create: `scripts/parallel-rework-guard.sh` (from `scripts/conductor-rework-guard.sh`)
- Delete: `scripts/conductor-dispatch-guard.sh`, `scripts/conductor-rework-guard.sh` (via `git mv` then edit)
- Modify: `hooks/hooks.json` (lines ~83 and ~93 — the two guard command paths)
- Create: `tests/test-parallel-dispatch-guard.sh`, `tests/test-parallel-rework-guard.sh` (adapted from `tests/test-conductor-dispatch-guard.sh` / `tests/test-conductor-rework-guard.sh`)
- Delete: `tests/test-conductor-dispatch-guard.sh`, `tests/test-conductor-rework-guard.sh`

**Interfaces:**
- Consumes: `execution.parallel`, `execution.enforce.{dispatch_guard,rework_guard}` (Task 2); manifest fields `Status`, `Files modified`, `## Commits`; the `NAZGUL_UNIT: TASK-NNN` prompt contract (Task 3).
- Activation triple for BOTH guards (replaces config+`.session`+engine): `nazgul/config.json` exists AND `execution.parallel == true`. No `.session` marker, no `graph.json`.

- [ ] **Step 1: `git mv` + write failing tests**

```bash
git mv scripts/conductor-dispatch-guard.sh scripts/parallel-dispatch-guard.sh
git mv scripts/conductor-rework-guard.sh scripts/parallel-rework-guard.sh
git mv tests/test-conductor-dispatch-guard.sh tests/test-parallel-dispatch-guard.sh
git mv tests/test-conductor-rework-guard.sh tests/test-parallel-rework-guard.sh
```

Rewrite the two test files' fixtures: wherever they wrote `graph.json` + `.session`, instead `create_config '.execution.parallel = true'` and create task manifests. Key cases to keep/port (read the originals first — preserve every behavioral case that still applies):

Dispatch guard (`tests/test-parallel-dispatch-guard.sh`):
- no-op when `execution.parallel` false (was: no `.session`)
- no-op when `.execution.enforce.dispatch_guard = false`
- blocks (exit 2) re-dispatch of implementer for a task at IMPLEMENTED — fixture: `create_task_file_with_commits TASK-001 IMPLEMENTED "abc1234"`, input JSON `{"tool_name":"Agent","tool_input":{"subagent_type":"nazgul:implementer","prompt":"...NAZGUL_UNIT: TASK-001..."}}`
- blocks review-gate re-dispatch for a DONE task; ALLOWS review-gate for an IMPLEMENTED task
- allows dispatch with no `NAZGUL_UNIT` line for a non-work-unit agent; allows unknown task id
- **deleted behavior:** the old Rule-1 case (blocking `run_in_background=true`) must now ASSERT ALLOW — background/concurrent dispatch from the main session is the intended mechanism

Rework guard (`tests/test-parallel-rework-guard.sh`):
- no-op when parallel false / kill-switch false
- blocks (exit 2) Write to a file listed in `- **Files modified**:` of a DONE task that has a `## Commits` SHA
- allows the same Write when the file is ALSO uniquely in an IN_PROGRESS (commit-less) task's `Files modified` (cross-cutting exemption)
- fails closed (blocks) when TWO active tasks claim the file
- allows files not owned by any committed task

Run: `tests/run-tests.sh --filter=parallel-dispatch-guard` → FAIL (guards still read graph.json/.session).

- [ ] **Step 2: Rewrite `scripts/parallel-dispatch-guard.sh`**

Keep the input-parsing head (lines 8-11 of the original). Replace the scope/rules body:

```bash
NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
TASKS_DIR="$NAZGUL_DIR/tasks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scope: only when the parallel dispatch option is on.
[ -f "$CONFIG" ] || exit 0
PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG" 2>/dev/null || echo "false")
[ "$PARALLEL" = "true" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.dispatch_guard == null then "true" else (.execution.enforce.dispatch_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0
SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

is_work_unit() {
  case "$1" in
    *implementer*|*review-gate*|*team-orchestrator*) return 0 ;;
    *) return 1 ;;
  esac
}

# Never re-dispatch a completed unit. Prompt carries `NAZGUL_UNIT: TASK-NNN`
# (grepped as data — never eval'd). Status source is the task manifest —
# canonical state, no stored graph. An IMPLEMENTED unit still legitimately
# needs its review-gate dispatch; only a DONE unit's review is wasted work.
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
if [ -n "$UNIT" ] && [ -f "$TASKS_DIR/$UNIT.md" ] && is_work_unit "$SUBAGENT"; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/task-utils.sh"
  STATUS=$(get_task_status "$TASKS_DIR/$UNIT.md" "")
  BLOCK=""
  case "$SUBAGENT" in
    *review-gate*) case "$STATUS" in DONE) BLOCK=1 ;; esac ;;
    *)             case "$STATUS" in IMPLEMENTED|DONE) BLOCK=1 ;; esac ;;
  esac
  if [ -n "$BLOCK" ]; then
    echo "NAZGUL PARALLEL: Blocked — $UNIT already $STATUS; re-dispatch is wasted work." >&2
    exit 2
  fi
fi
exit 0
```

(Note: Rule 1 — the `run_in_background` block — is gone by design. Update the header comment to say the guard enforces the no-re-dispatch contract for the parallel dispatch option.)

- [ ] **Step 3: Rewrite `scripts/parallel-rework-guard.sh`**

Keep the input parsing and the `/private` path-normalization block (`conductor-rework-guard.sh:29-49`) verbatim. Replace activation (config exists + `.execution.parallel == true` + kill-switch `.execution.enforce.rework_guard`, same pattern as Step 2) and replace the graph.json ownership scan with a manifest scan:

```bash
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/task-utils.sh"

# _scope_has <manifest> <abs> <rel> -> 0 iff Files modified contains the file
# (exact match against repo-relative or absolute form; no suffix matching —
# see the false-positive note in the original conductor-rework-guard).
_scope_has() {
  local mf="$1" abs="$2" rel="$3" files f
  files=$(get_task_field "$mf" "Files modified" "")
  [ -n "$files" ] || return 1
  IFS=',' read -ra _arr <<< "$files"
  for f in "${_arr[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [ "$f" = "$abs" ] || [ "$f" = "$rel" ] && return 0
  done
  return 1
}

_has_commit() { grep -A5 '^## Commits' "$1" 2>/dev/null | grep -qE '\b[0-9a-f]{7,40}\b'; }

OWNER=""
for tf in "$TASKS_DIR"/TASK-*.md; do
  [ -f "$tf" ] || continue
  st=$(get_task_status "$tf" "")
  case "$st" in DONE|IMPLEMENTED) ;; *) continue ;; esac
  _has_commit "$tf" || continue
  if _scope_has "$tf" "$FP" "$REL"; then OWNER=$(basename "$tf" .md); break; fi
done

if [ -n "$OWNER" ]; then
  # Cross-cutting exemption: file ALSO uniquely in a commit-less IN_PROGRESS
  # task's scope -> legitimate cross-cutting edit. Zero or 2+ matches fail
  # closed (no caller-identity binding — same rule as the conductor guard).
  CURRENT_COUNT=0
  for tf in "$TASKS_DIR"/TASK-*.md; do
    [ -f "$tf" ] || continue
    st=$(get_task_status "$tf" "")
    [ "$st" = "IN_PROGRESS" ] || continue
    _has_commit "$tf" && continue
    _scope_has "$tf" "$FP" "$REL" && CURRENT_COUNT=$((CURRENT_COUNT + 1))
  done
  [ "$CURRENT_COUNT" = "1" ] && exit 0
  echo "NAZGUL PARALLEL: Blocked — $FILE_PATH belongs to $OWNER, already implemented and committed; re-work blocked." >&2
  exit 2
fi
exit 0
```

- [ ] **Step 4: Update `hooks/hooks.json`**

Change the two command paths (lines ~83, ~93): `conductor-rework-guard.sh` → `parallel-rework-guard.sh`, `conductor-dispatch-guard.sh` → `parallel-dispatch-guard.sh`. Run `tests/run-tests.sh --filter=hooks-schema` to confirm the hooks file still validates.

- [ ] **Step 5: Run and verify**

Run: `tests/run-tests.sh --filter=parallel-dispatch-guard && tests/run-tests.sh --filter=parallel-rework-guard && tests/run-tests.sh --filter=hooks-schema`
Expected: PASS. `bash -n` + `shellcheck` both guards.

- [ ] **Step 6: Commit**

```bash
git add -A scripts/parallel-*.sh hooks/hooks.json tests/test-parallel-*guard*.sh
git commit -m "feat(parallel): guards re-keyed to execution.parallel + task manifests"
```

---

### Task 5: subagent-stop cleanup + pre-merge git hook re-key

**Files:**
- Modify: `scripts/subagent-stop.sh` (delete lines 128-159 `_detect_conductor_orphan` + its dispatch case at 157-159)
- Modify: `scripts/git-hooks/pre-merge-commit` (activation + verdict source)
- Test: `tests/test-conductor-orphan-detection.sh` (delete), `tests/test-git-hooks-premerge.sh` (update)

**Interfaces:**
- Consumes: `execution.parallel`, `execution.enforce.premerge_guard` (Task 2); manifest `## Commits` + `Status`.

- [ ] **Step 1: Delete the orphan detector**

In `scripts/subagent-stop.sh`, remove `_detect_conductor_orphan` (lines 129-155) and the `case "$AGENT" in *conductor*)` block (157-159). The `.resume-needed` breadcrumb has no writer left (it never had a reader). Delete `tests/test-conductor-orphan-detection.sh` (`git rm`).

- [ ] **Step 2: Re-key `scripts/git-hooks/pre-merge-commit`**

- Line ~29: delete the `GRAPH=` variable.
- Lines ~54-55: replace the engine check with:

```bash
PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG" 2>/dev/null || echo "false")
[ "$PARALLEL" = "true" ] || _dispatch_and_exit
```

- Line ~60: kill-switch key `.conductor.enforce.premerge_guard` → `.execution.enforce.premerge_guard`.
- Lines ~70-92 (unit mapping): replace the graph.json commit lookup with a manifest scan — a candidate merge SHA maps to the task whose `## Commits` section lists it; block unless that task's `Status` is `DONE`:

```bash
# Map the candidate SHA to a task manifest via its ## Commits section. A merge
# of a task branch whose task is not DONE (review not approved) is blocked.
UNIT_ID=""
for tf in "$REPO_ROOT/nazgul/tasks"/TASK-*.md; do
  [ -f "$tf" ] || continue
  if grep -A10 '^## Commits' "$tf" 2>/dev/null | grep -q "$CANDIDATE_SHA"; then
    UNIT_ID=$(basename "$tf" .md); break
  fi
done
[ -n "$UNIT_ID" ] || _dispatch_and_exit   # not a tracked task commit — allow
STATUS=$(grep -E '^\- \*\*Status\*\*:' "$REPO_ROOT/nazgul/tasks/$UNIT_ID.md" | head -1 | sed 's/^.*: *//' | tr -d ' ')
if [ "$STATUS" != "DONE" ]; then
  echo "NAZGUL GUARD: Blocked — merge includes $UNIT_ID (status='${STATUS:-none}'), which is not DONE; the review board has not approved it." >&2
  exit 1
fi
```

(Read the original's candidate-SHA derivation first (`scripts/git-hooks/pre-merge-commit:62-70`) and keep it — only the mapping + verdict source change. Git hooks can't source plugin libs — they run standalone in target repos — hence raw grep here instead of `get_task_status`.)

- [ ] **Step 3: Update `tests/test-git-hooks-premerge.sh`**

Rewrite fixtures: config gets `.execution.parallel = true` (+ `.execution.enforce.premerge_guard`), state comes from task manifests with `## Commits` + `Status` instead of graph.json. Keep the cases: blocks non-DONE unit merge; allows DONE; kill-switch disables; non-parallel config no-ops; untracked SHA allowed.

- [ ] **Step 4: Run and verify**

Run: `tests/run-tests.sh --filter=git-hooks-premerge && tests/run-tests.sh --filter=subagent` (if a subagent-stop test exists; else skip) — PASS. `bash -n` + `shellcheck` both scripts.

- [ ] **Step 5: Commit**

```bash
git add -A scripts/subagent-stop.sh scripts/git-hooks/pre-merge-commit tests/
git commit -m "refactor(parallel): drop orphan detector; premerge guard reads manifests"
```

---

### Task 6: Skills — start + status

**Files:**
- Modify: `skills/start/SKILL.md` ("Engine Selection" section ~line 122; "Wave-Based Execution" section ~lines 409-445; ACTIVE_LOOP step 7 ~line 183; other conductor dispatch mentions at ~261, ~281, ~315; flags list wherever `--conductor` is documented)
- Modify: `skills/status/SKILL.md` (conductor/graph.json reporting — `grep -n conductor skills/status/SKILL.md`)
- Test: `tests/test-skill-docs.sh` / `scripts/gen-skill-docs.sh` freshness (run `tests/run-tests.sh --filter=skill` and regenerate templates if the repo uses `{{PARTIAL}}` templates for these skills)

- [ ] **Step 1: Replace "Engine Selection" in `skills/start/SKILL.md`**

Delete the whole `### Engine Selection (MANDATORY — after Resolve Run Mode)` section. In its place:

```markdown
### Parallel Option (after Resolve Run Mode)

Read `nazgul/config.json → execution.parallel` (set by `--parallel`; `--conductor` is a
deprecated alias). No dispatch decision happens here — the stop-hook computes parallel
batches itself via `compute_dispatch_batch` (scripts/lib/parallel-batch.sh). Every state
below runs its "Delegate to Implementer / Stop hook takes over" step exactly as written
in BOTH modes; when a parallel batch is eligible the stop-hook's continuation message
carries a `DELEGATE (PARALLEL BATCH ...)` instruction instead of the single-task one.
Follow that instruction exactly: all batch Agent dispatches in ONE message, each prompt
carrying its `NAZGUL_UNIT: <task id>` line, one worktree per task, sequential merges,
then the batch's review-gates in one message.
```

- [ ] **Step 2: Remove the conductor dispatch forks**

At `skills/start/SKILL.md` ~lines 183, 261, 281, 315: delete the "if `execution.engine == "conductor"`, dispatch the conductor agent and stop" sentences — those steps now unconditionally read "delegate to the appropriate agent based on task status; the stop hook takes over."

- [ ] **Step 3: Delete the legacy "Wave-Based Execution" section**

Delete the whole `### Wave-Based Execution` section (~lines 409-445 — the old Agent-Teams path keyed on `parallelism.wave_execution`). It is superseded by the stop-hook batch mechanism; leaving it would ship two competing parallel paths. In its place put a two-line pointer:

```markdown
### Wave-Based Execution

Superseded: parallel execution is now the stop-hook's `execution.parallel` batch
dispatch (see "Parallel Option" above). The `parallelism.*` config keys are inert.
```

- [ ] **Step 4: Update flags docs + `skills/status/SKILL.md`**

- Wherever start's flag list documents `--conductor`, replace with `--parallel` (keep `--conductor` listed as deprecated alias).
- `skills/status/SKILL.md`: replace conductor-engine status reporting (graph.json digest, wave progress) with: read `execution.parallel`; when true, show the current dispatchable batch by calling `compute_dispatch_batch` and the wave layout via `compute_waves` — both from `scripts/lib/parallel-batch.sh`.

- [ ] **Step 5: Verify + commit**

Run: `tests/run-tests.sh --filter=skill && tests/run-tests.sh --filter=frontmatter`
Expected: PASS (regenerate via `scripts/gen-skill-docs.sh` first if these skills are template-generated — check for `{{PARTIAL` markers).

```bash
git add skills/start/SKILL.md skills/status/SKILL.md
git commit -m "feat(parallel): start/status skills — parallel option replaces engine fork"
```

---

### Task 7: Delete the conductor + full reference sweep

**Files:**
- Delete: `agents/conductor.md`, `scripts/lib/conductor-graph.sh`, `scripts/lib/conductor-gates.sh`, `scripts/lib/conductor-router.sh`
- Delete: `tests/test-conductor-contract.sh`, `tests/test-conductor-gates.sh`, `tests/test-conductor-recovery.sh`, `tests/test-conductor-router.sh`, `tests/test-conductor-waves.sh`, `tests/test-status-conductor.sh`
- Modify: every remaining referrer found by the sweep (expected: `RULES.md` §11/§16 + rules legend ~lines 235, 278; `CLAUDE.md` directory tree + Key Concepts + Key Files; `templates/CLAUDE.md.template`; `references/` docs if any; `agents/planner.md` "loop orchestrator" note; `skills/heartbeat/SKILL.md`; `skills/help/SKILL.md`; `README.md`)

- [ ] **Step 1: Delete files**

```bash
git rm agents/conductor.md scripts/lib/conductor-graph.sh scripts/lib/conductor-gates.sh scripts/lib/conductor-router.sh
git rm tests/test-conductor-contract.sh tests/test-conductor-gates.sh tests/test-conductor-recovery.sh tests/test-conductor-router.sh tests/test-conductor-waves.sh tests/test-status-conductor.sh
```

(Before deleting `test-conductor-waves.sh` and `test-conductor-gates.sh`, confirm Task 1's `test-parallel-batch.sh` ported their still-relevant cases — waves layering, cycle rejection, gate defaults/hitl-flip, hard stops. Port any missing case now, into `tests/test-parallel-batch.sh`.)

- [ ] **Step 2: Sweep**

```bash
grep -rn --exclude-dir=.git --exclude-dir=docs -i 'conductor' . | grep -v 'deprecated alias' | grep -v parallel-
```

Fix every hit (docs/ specs+decision-logs are historical — leave them). Expected fixes: RULES.md (rewrite §11's wave-parallelism rule to reference `compute_dispatch_batch` + `execution.max_parallel`, now `[enforced]` via the stop-hook rather than `[advisory]`; drop conductor rows from the rules table), CLAUDE.md (directory tree: remove conductor entries, add `parallel-batch.sh` + renamed guards; "One pipeline, two engines" concept → "One engine, optional parallel dispatch"; Key Files: drop `nazgul/conductor/graph.json`; commands: `--conductor` → `--parallel (deprecated alias: --conductor)`), `templates/CLAUDE.md.template` (same concept text), `skills/heartbeat/SKILL.md` + `skills/help/SKILL.md` flag/engine mentions, `agents/planner.md` (Wave Groups note: "read by the stop-hook's compute_dispatch_batch"), README.

- [ ] **Step 3: Full suite**

Run: `tests/run-tests.sh`
Expected: ALL PASS, zero references to deleted files. Also `shellcheck scripts/*.sh scripts/lib/*.sh`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(parallel): delete conductor engine (agent, libs, tests) + reference sweep"
```

---

### Task 8: Docs, decision log, release

**Files:**
- Modify: `CHANGELOG.md` (new 2.16.0 section), `.claude-plugin/plugin.json` (version), `README.md` (if version badge)
- Create: `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md`

- [ ] **Step 1: Decision log (the ADR)**

Create `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md` — content: the platform finding (nested subagents are not re-engageable drivers; background-by-default since CC v2.1.198; completion notifications re-engage only the main session; sources: code.claude.com/docs sub-agents/hooks/workflows/agent-teams pages), the four ranked alternatives (main-session+stop-hook, Workflow tool, Agent Teams, watchdog) with the reasons Workflow (not crash-durable, not plugin-launchable) and Agent Teams (no teammate resumption) lost, and the decision: one engine, `execution.parallel`, conductor deleted. End with: "Do not reintroduce a background-subagent driver unless the platform documents parent re-engagement on child completion." Link the spec at `docs/superpowers/specs/2026-07-21-parallel-execution-collapse-design.md`.

- [ ] **Step 2: CHANGELOG + version**

- `.claude-plugin/plugin.json`: `"version": "2.15.0"` → `"2.16.0"`.
- `CHANGELOG.md` (mirror existing section format): 2.16.0 — "Parallel Execution Collapse: conductor engine removed; `execution.parallel` batch dispatch in the sequential loop (config schema v26 migrates conductor configs automatically; `--conductor` is now a deprecated alias for `--parallel`); guards re-keyed to task manifests; in-flight conductor runs resume from task manifests via the ordinary loop."

- [ ] **Step 3: Final verification**

Run: `tests/run-tests.sh` — ALL PASS.
Run: `for f in scripts/*.sh scripts/lib/*.sh scripts/git-hooks/pre-merge-commit; do bash -n "$f" || echo "SYNTAX $f"; done` — no output.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md .claude-plugin/plugin.json README.md docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md
git commit -m "docs(parallel): decision log, changelog, v2.16.0"
```
