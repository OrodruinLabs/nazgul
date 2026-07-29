# Teammate Teardown Enforcement + Orphaned-Team Sweep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mechanically enforce that Nazgul-dispatched Agent-Teams teammates are dismissed (shutdown_request) after their reports are consumed, and sweep dead-session team state from `~/.claude/teams/` + `~/.claude/tasks/`.

**Architecture:** New sourced lib `scripts/lib/team-teardown.sh` (detection + sweep, fail-open, jq-only). The stop-hook gains a per-iteration gate that detects undismissed teammates and injects a mandatory dismissal directive into the loop prompt (3-strike bound → `raise_finding` escalation). `session-context.sh` runs the orphan sweep at SessionStart. Spec: `docs/superpowers/specs/2026-07-24-team-teardown-design.md`.

**Tech Stack:** bash (POSIX-safe, `shellcheck`-clean), `jq`, existing test harness (`tests/lib/assertions.sh`, `tests/lib/setup.sh`).

## Global Constraints

- All scripts: `set -euo pipefail` for executables; sourced libs use the idempotent-source-guard pattern WITHOUT `set -euo pipefail` (mirror `scripts/lib/raise-finding.sh`).
- Quote all variables. `jq` for JSON — never sed/grep on JSON.
- Fail OPEN on anything ambiguous (unparseable config, missing dirs, unsafe names) — never deadlock the loop, never delete on ambiguity.
- Kill-switch reads use the explicit-false pattern: `jq -r 'if .guards.X == false then "false" else "true" end'` (NEVER `// true`, which false-coalesces an explicit `false`).
- Config schema bump v30 → v31, additive only, type-guard pattern from `migrate_29_to_30`.
- Default branch is `main`. Commit prefix style: `feat:`/`fix:`/`test:`/`docs:` conventional commits on a feature branch `feat/team-teardown` (create off `main` first; never commit to `main`).
- Path-safety: any name interpolated into a filesystem path is rejected if it contains `/` or `..` (mirror `teammate-idle-guard.sh:60-62`).
- `~/.claude/teams`, `~/.claude/tasks`, `~/.claude/projects` are overridable via env (`NAZGUL_TEAMS_DIR`, `NAZGUL_TEAM_TASKS_DIR`, `NAZGUL_PROJECTS_DIR`) so tests never touch the real home.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create the feature branch**

```bash
cd "/Users/josemejia/Documents/Software Development/ai-hydra-framework"
git checkout main && git pull && git checkout -b feat/team-teardown
```

Expected: `Switched to a new branch 'feat/team-teardown'`

---

### Task 1: Detection lib — `scripts/lib/team-teardown.sh` (detect + self-heal)

**Files:**
- Create: `scripts/lib/team-teardown.sh`
- Test: `tests/test-team-teardown.sh`

**Interfaces:**
- Produces: `tt_team_dir_for_manifest <manifest> <session_id>` → prints team dir path or returns 1; `tt_report_delivered <report_abs_path> <spawned_epoch>` → exit 0 iff delivered; `tt_detect_undismissed <nazgul_dir> <project_dir> <session_id>` → stdout one line per leaked teammate: `name<TAB>report_path<TAB>team_dir<TAB>blocks`, always exit 0. Env: `NAZGUL_TEAMS_DIR` (default `$HOME/.claude/teams`).
- Consumes: dispatch manifests `nazgul/dispatch/<name>.json` (fields `teammate`, `report_path`, `feat_id`, `spawned_at_epoch`, optional `team`, optional `teardown_blocks`), team configs `~/.claude/teams/<team>/config.json` (field `members[].name`).

- [ ] **Step 1: Write the failing tests**

Create `tests/test-team-teardown.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# Test: team-teardown.sh — teammate dismissal detection, self-heal, sweep
# (spec docs/superpowers/specs/2026-07-24-team-teardown-design.md)

TEST_NAME="test-team-teardown"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/team-teardown.sh"

# Helper: fake team dir with members. Usage: make_team <name> <member>...
make_team() {
  local team="$1"; shift
  mkdir -p "$TEST_DIR/teams/$team"
  local members="[]"
  local m
  for m in "$@"; do
    members=$(jq -c --arg n "$m" '. + [{name:$n, cwd:"'"$TEST_DIR"'"}]' <<< "$members")
  done
  jq -n --arg name "$team" --argjson m "$members" \
    '{name:$name, leadSessionId:"dead-lead-0000", members:([{name:"team-lead", cwd:"'"$TEST_DIR"'"}] + $m)}' \
    > "$TEST_DIR/teams/$team/config.json"
}

# Helper: dispatch manifest. Usage: make_manifest <name> <report_path> [team] [spawned_epoch]
make_manifest() {
  mkdir -p "$TEST_DIR/nazgul/dispatch"
  jq -n --arg t "$1" --arg rp "$2" --arg team "${3:-}" --argjson sae "${4:-0}" \
    '{teammate:$t, report_path:$rp, feat_id:"default", spawned_at_epoch:$sae, blocks:0}
     + (if $team != "" then {team:$team} else {} end)' \
    > "$TEST_DIR/nazgul/dispatch/$1.json"
}

export NAZGUL_TEAMS_DIR=""  # set per test after TEST_DIR exists

# --- 1: delivered + still a member -> emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_contains "leaked teammate emitted" "$OUT" "rv-code-TASK-001"
assert_eq "one leaked line" "$(printf '%s' "$OUT" | grep -c .)" "1"
teardown_temp_dir

# --- 2: delivered + member ABSENT -> manifest self-healed (deleted), nothing emitted ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001"   # no reviewer member
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "x" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "dismissed: nothing emitted" "$OUT" ""
assert_file_not_exists "dismissed: manifest self-healed" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 3: team dir gone (session-exit cleanup) -> manifest self-healed ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "gone-team"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "gone team: nothing emitted" "$OUT" ""
assert_file_not_exists "gone team: manifest deleted" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 4: report NOT delivered -> not leaked (idle guard's domain), manifest kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "undelivered: nothing emitted" "$OUT" ""
assert_file_exists "undelivered: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 5: report predates spawn -> treated as undelivered ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
echo "stale" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
FUTURE=$(( $(date +%s) + 3600 ))
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001" "$FUTURE"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "stale report: nothing emitted" "$OUT" ""
teardown_temp_dir

# --- 6: stale feat_id -> skipped, manifest kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.feat_id = "FEAT-002"'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "stale feat: nothing emitted" "$OUT" ""
assert_file_exists "stale feat: manifest kept" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
teardown_temp_dir

# --- 7: no team field -> implicit team session-<first 8 of session id> ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
make_team "session-sess1234" "impl-TASK-002"
make_manifest "impl-TASK-002" "nazgul/tasks/TASK-002.md"
mkdir -p "$TEST_DIR/nazgul/tasks"
echo "Status: IMPLEMENTED" > "$TEST_DIR/nazgul/tasks/TASK-002.md"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd-9999")
assert_contains "implicit team resolved" "$OUT" "impl-TASK-002"
teardown_temp_dir

# --- 8: unsafe teammate name in manifest -> skipped (fail open) ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
mkdir -p "$TEST_DIR/nazgul/dispatch"
jq -n '{teammate:"../evil", report_path:"r.md", feat_id:"default", spawned_at_epoch:0}' \
  > "$TEST_DIR/nazgul/dispatch/evil.json"
OUT=$(tt_detect_undismissed "$TEST_DIR/nazgul" "$TEST_DIR" "sess1234-abcd")
assert_eq "unsafe name: nothing emitted" "$OUT" ""
teardown_temp_dir

report_results
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
tests/run-tests.sh --filter=team-teardown
```

Expected: FAIL — `scripts/lib/team-teardown.sh: No such file or directory` (the `source` in the test aborts).

- [ ] **Step 3: Write the lib**

Create `scripts/lib/team-teardown.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/team-teardown.sh — Agent-Teams teammate teardown detection and
# orphaned-team sweep (spec docs/superpowers/specs/2026-07-24-team-teardown-design.md).
#
# Platform facts this lib is built on (CLI 2.1.218, verified 2026-07-24):
# - TeamCreate/TeamDelete were removed in v2.1.178; team config
#   (~/.claude/teams/<name>/) is auto-removed on NORMAL session exit only.
# - The only teardown primitive is a per-teammate SendMessage shutdown_request
#   sent by the lead; teammates never self-terminate — idle is terminal.
# - Hooks cannot shut teammates down, so enforcement is: detect (here) →
#   direct the lead (stop-hook prompt) → verify next iteration → escalate.
# - Deleting ~/.claude/teams/<name>/ + ~/.claude/tasks/<name>/ by hand is the
#   accepted orphan workaround, safe ONLY when the lead session is dead.
#
# Fail-open everywhere: ambiguity means "not leaked" / "not sweepable".
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own shell options (mirrors scripts/lib/raise-finding.sh).

[ -n "${_NAZGUL_TEAM_TEARDOWN_SOURCED:-}" ] && return 0
_NAZGUL_TEAM_TEARDOWN_SOURCED=1

NAZGUL_TEAMS_DIR="${NAZGUL_TEAMS_DIR:-$HOME/.claude/teams}"
NAZGUL_TEAM_TASKS_DIR="${NAZGUL_TEAM_TASKS_DIR:-$HOME/.claude/tasks}"
NAZGUL_PROJECTS_DIR="${NAZGUL_PROJECTS_DIR:-$HOME/.claude/projects}"

# tt_team_dir_for_manifest <manifest> <session_id>
# Prints the team dir this manifest's teammate belongs to. Manifest `team`
# field wins; empty falls back to the session's implicit team
# (session-<first 8 chars of session_id>). Returns 1 on unresolvable/unsafe.
tt_team_dir_for_manifest() {
  local manifest="$1" session_id="${2:-}" team
  team=$(jq -r '.team // ""' "$manifest" 2>/dev/null || echo "")
  if [ -z "$team" ] && [ -n "$session_id" ]; then
    team="session-${session_id:0:8}"
  fi
  case "$team" in ''|*/*|*..*) return 1 ;; esac
  printf '%s/%s' "$NAZGUL_TEAMS_DIR" "$team"
}

# tt_report_delivered <report_abs_path> <spawned_epoch>
# Exit 0 iff the report file exists, is non-empty, and its mtime is >= the
# spawn epoch (mirrors teammate-idle-guard.sh; stat failure -> delivered/open).
tt_report_delivered() {
  local report="$1" spawned="${2:-0}" mtime
  [ -s "$report" ] || return 1
  case "$spawned" in ''|*[!0-9]*) spawned=0 ;; esac
  mtime=$(stat -c %Y "$report" 2>/dev/null || stat -f %m "$report" 2>/dev/null || echo "")
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ "$mtime" -ge "$spawned" ]
}

# tt_detect_undismissed <nazgul_dir> <project_dir> <session_id>
# One line per teammate whose report is delivered but who is still a member of
# its team: name<TAB>report_path<TAB>team_dir<TAB>teardown_blocks
# Self-heals: a manifest whose team dir is gone (session-exit cleanup) or
# whose teammate is no longer a member (dismissal completed) is DELETED — it
# has served its purpose. Undelivered reports are the TeammateIdle guard's
# jurisdiction, not ours. Always returns 0.
tt_detect_undismissed() {
  local nazgul_dir="$1" project_dir="$2" session_id="${3:-}"
  local manifest name feat cur_feat team_dir report spawned blocks
  [ -d "$nazgul_dir/dispatch" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cur_feat=$(jq -r '.feat_id // "default"' "$nazgul_dir/config.json" 2>/dev/null || echo "default")
  for manifest in "$nazgul_dir/dispatch"/*.json; do
    [ -f "$manifest" ] || continue
    name=$(jq -r '.teammate // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$name" ] && continue
    case "$name" in */*|*..*) continue ;; esac
    feat=$(jq -r '.feat_id // ""' "$manifest" 2>/dev/null || echo "")
    [ -n "$feat" ] && [ "$feat" != "$cur_feat" ] && continue
    team_dir=$(tt_team_dir_for_manifest "$manifest" "$session_id") || continue
    if [ ! -f "$team_dir/config.json" ]; then
      rm -f "$manifest"
      continue
    fi
    if ! jq -e --arg n "$name" '[.members[]?.name] | index($n)' \
        "$team_dir/config.json" >/dev/null 2>&1; then
      rm -f "$manifest"
      continue
    fi
    report=$(jq -r '.report_path // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$report" ] && continue
    case "$report" in /*|*..*) continue ;; esac
    spawned=$(jq -r '.spawned_at_epoch // 0' "$manifest" 2>/dev/null || echo 0)
    tt_report_delivered "$project_dir/$report" "$spawned" || continue
    blocks=$(jq -r '.teardown_blocks // 0' "$manifest" 2>/dev/null || echo 0)
    case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$report" "$team_dir" "$blocks"
  done
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
tests/run-tests.sh --filter=team-teardown && shellcheck scripts/lib/team-teardown.sh tests/test-team-teardown.sh
```

Expected: all 8 test groups PASS; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/team-teardown.sh tests/test-team-teardown.sh
git commit -m "feat: team-teardown lib — undismissed-teammate detection with manifest self-heal"
```

---

### Task 2: Config schema v31 — kill-switches

**Files:**
- Modify: `templates/config.json` (guards block + `schema_version`)
- Modify: `scripts/migrate-config.sh` (append `migrate_30_to_31` next to `migrate_29_to_30`)
- Test: `tests/test-team-teardown.sh` (append migration test)

**Interfaces:**
- Produces: config keys `guards.team_teardown` (bool, default `true`), `guards.team_sweep` (bool, default `true`), `guards.team_sweep_min_age_hours` (number, default `24`); `schema_version: 31`.

- [ ] **Step 1: Write the failing test** — append to `tests/test-team-teardown.sh` before `report_results`:

```bash
# --- 9: migration v30 -> v31 adds guards keys, preserves explicit values ---
setup_temp_dir; setup_nazgul_dir
create_config '.schema_version = 30 | .guards.team_sweep = false'
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/migrate-config.sh" >/dev/null 2>&1
assert_json_field "v31: schema bumped" "$TEST_DIR/nazgul/config.json" '.schema_version' "31"
assert_json_field "v31: team_teardown default true" "$TEST_DIR/nazgul/config.json" '.guards.team_teardown' "true"
assert_json_field "v31: explicit team_sweep=false preserved" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep' "false"
assert_json_field "v31: min_age default 24" "$TEST_DIR/nazgul/config.json" '.guards.team_sweep_min_age_hours' "24"
teardown_temp_dir
```

(If `assert_json_field`'s signature differs — check `tests/lib/assertions.sh:101` — adapt the call, not the assertion intent.)

- [ ] **Step 2: Run to verify it fails**

```bash
tests/run-tests.sh --filter=team-teardown
```

Expected: FAIL — schema stays 30 (no `migrate_30_to_31` exists; migrate-config no-ops when CURRENT == TARGET, so also bump the template in the next step for TARGET to become 31).

- [ ] **Step 3: Implement**

In `templates/config.json`: change `"schema_version": 30` → `"schema_version": 31`, and extend the guards block:

```json
  "guards": {
    "requireActiveTask": true,
    "lean_comments": true,
    "max_consecutive_comment_lines": 2,
    "git_hooks": true,
    "bash_write_reconciliation": true,
    "team_teardown": true,
    "team_sweep": true,
    "team_sweep_min_age_hours": 24
  }
```

In `scripts/migrate-config.sh`, append after `migrate_29_to_30()` (before the `# --- Run incremental migrations ---` marker):

```bash
migrate_30_to_31() {
  local tmp; tmp=$(mktemp)
  # Teammate teardown gate + orphaned-team sweep kill-switches
  # (spec 2026-07-24-team-teardown-design.md). Additive; explicit values
  # (incl. false) preserved. Same type-guard pattern as migrate_5_to_6.
  jq '
    .guards = ((if (.guards | type) == "object" then .guards else {} end)
      | .team_teardown = (if has("team_teardown") then .team_teardown else true end)
      | .team_sweep = (if has("team_sweep") then .team_sweep else true end)
      | .team_sweep_min_age_hours = (if has("team_sweep_min_age_hours") then .team_sweep_min_age_hours else 24 end))
    | .schema_version = 31
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v30→v31: added guards.team_teardown:true, guards.team_sweep:true, guards.team_sweep_min_age_hours:24 (teammate dismissal gate + dead-session team sweep; additive, explicit values preserved)"
}
```

- [ ] **Step 4: Run tests**

```bash
tests/run-tests.sh --filter=team-teardown && tests/run-tests.sh --filter=migrate
```

Expected: PASS (both the new test and all existing migration tests).

- [ ] **Step 5: Commit**

```bash
git add templates/config.json scripts/migrate-config.sh tests/test-team-teardown.sh
git commit -m "feat: config schema v31 — team_teardown/team_sweep guards"
```

---

### Task 3: Stop-hook teardown gate

**Files:**
- Modify: `scripts/stop-hook.sh` (new gate block after the bash-write reconciliation block ~line 200, one new line in the `CONTINUE_MSG` heredoc ~line 1283)
- Test: `tests/test-team-teardown.sh` (append)

**Interfaces:**
- Consumes: `tt_detect_undismissed` (Task 1), `raise_finding <severity> <category> <title> <detail> [fix] [evidence]` (`scripts/lib/raise-finding.sh`), `emit_event <type> key value...` (already sourced in stop-hook).
- Produces: `TEARDOWN_DIRECTIVE` shell var rendered into the loop prompt; `teardown_blocks`/`teardown_escalated` fields on dispatch manifests; `team_teardown` telemetry events.

- [ ] **Step 1: Write the failing tests** — append to `tests/test-team-teardown.sh` before `report_results`:

```bash
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
run_hook() { HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?; }

# Shared fixture for stop-hook gate tests: initialized nazgul + one leaked teammate
setup_gate_fixture() {  # $1 = extra create_config jq filter (optional)
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  create_config "${1:-.}"
  create_plan
  create_task_file TASK-001 READY none
  export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
  make_team "nazgul-review-TASK-001" "rv-code-TASK-001"
  make_manifest "rv-code-TASK-001" "nazgul/reviews/TASK-001/code.md" "nazgul-review-TASK-001"
  mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
  echo "verdict: APPROVE" > "$TEST_DIR/nazgul/reviews/TASK-001/code.md"
}

# --- 10: leaked teammate -> directive in loop prompt, blocks incremented ---
setup_gate_fixture
run_hook
assert_exit_code "gate: loop continues" "$HOOK_EC" 2
assert_contains "gate: directive injected" "$HOOK_OUTPUT" "TEAM TEARDOWN"
assert_contains "gate: names teammate" "$HOOK_OUTPUT" "rv-code-TASK-001"
assert_json_field "gate: blocks incremented" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" '.teardown_blocks' "1"
teardown_temp_dir

# --- 11: kill-switch guards.team_teardown=false -> no directive ---
setup_gate_fixture '.guards.team_teardown = false'
run_hook
assert_not_contains "kill-switch: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
teardown_temp_dir

# --- 12: 3 strikes -> escalation (finding raised once), directive stops ---
setup_gate_fixture
tmp=$(mktemp); jq '.teardown_blocks = 3' "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" > "$tmp" \
  && mv "$tmp" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json"
run_hook
assert_not_contains "escalated: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
assert_file_exists "escalated: finding raised" "$TEST_DIR/nazgul/logs/findings.jsonl"
assert_json_field "escalated: flag set" "$TEST_DIR/nazgul/dispatch/rv-code-TASK-001.json" '.teardown_escalated' "true"
FINDINGS_LINES=$(wc -l < "$TEST_DIR/nazgul/logs/findings.jsonl" | tr -d ' ')
run_hook   # second run must NOT raise a duplicate finding
assert_eq "escalated: finding raised once" "$(wc -l < "$TEST_DIR/nazgul/logs/findings.jsonl" | tr -d ' ')" "$FINDINGS_LINES"
teardown_temp_dir

# --- 13: nothing leaked -> no directive, clean prompt ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir; create_config '.'
create_plan; create_task_file TASK-001 READY none
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams"
run_hook
assert_not_contains "clean: no directive" "$HOOK_OUTPUT" "TEAM TEARDOWN"
teardown_temp_dir
```

Note: `create_task_file`/`create_plan`/`setup_git_repo` come from `tests/lib/setup.sh` (same usage as `tests/test-stop-hook.sh`). If `create_plan` requires arguments in the current helper, mirror `test-stop-hook.sh`'s usage exactly.

- [ ] **Step 2: Run to verify it fails**

```bash
tests/run-tests.sh --filter=team-teardown
```

Expected: tests 10–12 FAIL (no directive is produced yet); test 13 passes trivially.

- [ ] **Step 3: Implement in `scripts/stop-hook.sh`**

(a) Insert directly AFTER the bash-write reconciliation block (after its closing `fi`, currently ~line 201, before `count_tasks_and_find_active`):

```bash
# --- TEAM TEARDOWN GATE (spec 2026-07-24-team-teardown-design.md) ---
# Teammates whose report is delivered but who are still team members must be
# dismissed (SendMessage shutdown_request) before new work dispatches. Hooks
# cannot shut teammates down — this gate detects, directs the lead via the
# loop prompt, verifies next iteration (detection self-clears on dismissal),
# and escalates via raise_finding after 3 ignored directives. Fail-open.
# Kill-switch: guards.team_teardown (explicit false disables).
TEARDOWN_DIRECTIVE=""
TT_ENABLED=$(jq -r 'if .guards.team_teardown == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
if [ "$TT_ENABLED" = "true" ]; then
  source "$SCRIPT_DIR/lib/team-teardown.sh"
  TT_LEAKED=$(tt_detect_undismissed "$NAZGUL_DIR" "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$TT_LEAKED" ]; then
    TT_LIST=""
    while IFS=$'\t' read -r tt_name tt_report tt_team_dir tt_blocks; do
      [ -n "$tt_name" ] || continue
      tt_manifest="$NAZGUL_DIR/dispatch/${tt_name}.json"
      if [ "$tt_blocks" -ge 3 ] 2>/dev/null; then
        if [ "$(jq -r '.teardown_escalated // false' "$tt_manifest" 2>/dev/null)" != "true" ]; then
          source "$SCRIPT_DIR/lib/raise-finding.sh"
          raise_finding "medium" "process" \
            "teammate ${tt_name} not dismissed after 3 directives" \
            "Report ${tt_report} was delivered but the teammate stayed a member of $(basename "$tt_team_dir") for 3 iterations after dismissal directives. Manual shutdown_request needed." \
            "Investigate why the lead skips dismissal; send shutdown_request manually." \
            "$tt_manifest" || true
          tt_tmp=$(mktemp 2>/dev/null) || tt_tmp=""
          if [ -n "$tt_tmp" ] && jq '.teardown_escalated = true' "$tt_manifest" > "$tt_tmp" 2>/dev/null; then
            mv "$tt_tmp" "$tt_manifest" 2>/dev/null || rm -f "$tt_tmp"
          else rm -f "$tt_tmp"; fi
          emit_event "team_teardown" action "escalated" teammate "$tt_name"
        fi
        continue
      fi
      TT_LIST="${TT_LIST}  - ${tt_name} (report delivered: ${tt_report})"$'\n'
      tt_tmp=$(mktemp 2>/dev/null) || tt_tmp=""
      if [ -n "$tt_tmp" ] && jq --argjson b "$((tt_blocks + 1))" '.teardown_blocks = $b' "$tt_manifest" > "$tt_tmp" 2>/dev/null; then
        mv "$tt_tmp" "$tt_manifest" 2>/dev/null || rm -f "$tt_tmp"
      else rm -f "$tt_tmp"; fi
    done <<< "$TT_LEAKED"
    if [ -n "$TT_LIST" ]; then
      TEARDOWN_DIRECTIVE="TEAM TEARDOWN (mandatory, do this FIRST, before any new dispatch): these teammates delivered their reports and must be dismissed. For EACH: send it a SendMessage shutdown_request; after it approves, delete nazgul/dispatch/<name>.json (NEVER glob dispatch/*.json — other teams' manifests share that directory). If a teammate REJECTS shutdown it believes it has live work — leave its manifest and explain in your summary.
${TT_LIST%$'\n'}"
      emit_event "team_teardown" action "directive_injected" count:n "$(printf '%s\n' "$TT_LEAKED" | grep -c .)"
    fi
  fi
fi
```

(b) In the `CONTINUE_MSG` heredoc (~line 1283), add ONE line between the `${ACTIVE_LINE}` line and the `$AGGREGATE_MARKER` line:

```
$([ -n "$TEARDOWN_DIRECTIVE" ] && echo "$TEARDOWN_DIRECTIVE" || true)
```

- [ ] **Step 4: Run tests**

```bash
tests/run-tests.sh --filter=team-teardown && tests/run-tests.sh --filter=stop-hook && shellcheck scripts/stop-hook.sh
```

Expected: new tests PASS; ALL existing stop-hook tests still PASS (the gate must not disturb them — if any fail, the gate is misplaced or leaks state); shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/stop-hook.sh tests/test-team-teardown.sh
git commit -m "feat: stop-hook team-teardown gate — directive injection, 3-strike escalation"
```

---

### Task 4: Orphaned-team sweep (lib + SessionStart)

**Files:**
- Modify: `scripts/lib/team-teardown.sh` (append `tt_sweep_orphaned_teams`)
- Modify: `scripts/session-context.sh` (sweep call after session registration, ~line 29)
- Test: `tests/test-team-teardown.sh` (append)

**Interfaces:**
- Produces: `tt_sweep_orphaned_teams <nazgul_dir> <project_dir> <current_session_id> <min_age_hours>` → deletes dead attributable team state; prints one swept team name per line; appends JSONL to `<nazgul_dir>/logs/team-sweep.jsonl`. Env: `NAZGUL_TEAMS_DIR`, `NAZGUL_TEAM_TASKS_DIR`, `NAZGUL_PROJECTS_DIR`.
- Consumes: session locks `<nazgul_dir>/sessions/<sanitized-id>.lock` (sanitization: `tr -c 'A-Za-z0-9_-' '_'` — mirror `scripts/lib/session-tracker.sh:5`), transcripts `~/.claude/projects/*/<sessionId>.jsonl`.

- [ ] **Step 1: Write the failing tests** — append before `report_results`:

```bash
# Helper: team owned by a given lead session, attributed to TEST_DIR
make_owned_team() {  # <team> <leadSessionId>
  mkdir -p "$TEST_DIR/teams/$1" "$TEST_DIR/team-tasks/$1"
  jq -n --arg name "$1" --arg lead "$2" --arg cwd "$TEST_DIR" \
    '{name:$name, leadSessionId:$lead, members:[{name:"team-lead", cwd:$cwd}]}' \
    > "$TEST_DIR/teams/$1/config.json"
  touch "$TEST_DIR/team-tasks/$1/tasks.json"
}

export NAZGUL_TEAM_TASKS_DIR=""  # set per test
export NAZGUL_PROJECTS_DIR=""

# --- 14: dead + attributed -> swept (both dirs), logged ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "old-team" "dead-lead-1111"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_contains "sweep: reported" "$OUT" "old-team"
assert_dir_not_exists "sweep: team dir gone" "$TEST_DIR/teams/old-team"
assert_dir_not_exists "sweep: tasks dir gone" "$TEST_DIR/team-tasks/old-team"
assert_file_exists "sweep: logged" "$TEST_DIR/nazgul/logs/team-sweep.jsonl"
teardown_temp_dir

# --- 15: live session lock -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "live-team" "live-lead-2222"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{}' > "$TEST_DIR/nazgul/sessions/live-lead-2222.lock"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "lock: team kept" "$TEST_DIR/teams/live-team"
teardown_temp_dir

# --- 16: fresh transcript -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "fresh-team" "fresh-lead-3333"
mkdir -p "$TEST_DIR/projects/proj-a"
echo '{}' > "$TEST_DIR/projects/proj-a/fresh-lead-3333.jsonl"   # mtime = now
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "fresh transcript: team kept" "$TEST_DIR/teams/fresh-team"
teardown_temp_dir

# --- 17: foreign cwd -> never touched ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
mkdir -p "$TEST_DIR/teams/foreign-team"
jq -n '{name:"foreign-team", leadSessionId:"dead-lead-4444", members:[{name:"team-lead", cwd:"/somewhere/else"}]}' \
  > "$TEST_DIR/teams/foreign-team/config.json"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "foreign: kept" "$TEST_DIR/teams/foreign-team"
teardown_temp_dir

# --- 18: current session's own team -> never touched ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
make_owned_team "my-team" "current-sess"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "own team: kept" "$TEST_DIR/teams/my-team"
teardown_temp_dir

# --- 19: no leadSessionId (ambiguous) -> kept ---
setup_temp_dir; setup_nazgul_dir; create_config '.'
export NAZGUL_TEAMS_DIR="$TEST_DIR/teams" NAZGUL_TEAM_TASKS_DIR="$TEST_DIR/team-tasks" NAZGUL_PROJECTS_DIR="$TEST_DIR/projects"
mkdir -p "$TEST_DIR/teams/odd-team"
jq -n --arg cwd "$TEST_DIR" '{name:"odd-team", members:[{name:"team-lead", cwd:$cwd}]}' \
  > "$TEST_DIR/teams/odd-team/config.json"
OUT=$(tt_sweep_orphaned_teams "$TEST_DIR/nazgul" "$TEST_DIR" "current-sess" 24)
assert_dir_exists "ambiguous: kept" "$TEST_DIR/teams/odd-team"
teardown_temp_dir
```

- [ ] **Step 2: Run to verify it fails**

```bash
tests/run-tests.sh --filter=team-teardown
```

Expected: FAIL — `tt_sweep_orphaned_teams: command not found`.

- [ ] **Step 3: Implement** — append to `scripts/lib/team-teardown.sh`:

```bash
# tt_sweep_orphaned_teams <nazgul_dir> <project_dir> <current_session_id> <min_age_hours>
# Deletes team state (~/.claude/teams/<t> + ~/.claude/tasks/<t> + this
# project's dispatch manifests for its members) for teams that are BOTH
# attributable to <project_dir> (some member's cwd matches) AND provably dead:
# no session lock for the lead, no transcript for the lead fresher than
# <min_age_hours>, and not the current session. Prints one swept team name
# per line; appends one JSONL record per sweep to logs/team-sweep.jsonl.
# Conservative: ANY ambiguity -> skip. Always returns 0.
tt_sweep_orphaned_teams() {
  local nazgul_dir="$1" project_dir="$2" cur_sid="${3:-}" min_age_h="${4:-24}"
  local team_cfg team_dir team lead lead_safe alive t mt now min_age_s m
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$NAZGUL_TEAMS_DIR" ] || return 0
  case "$min_age_h" in ''|*[!0-9]*) min_age_h=24 ;; esac
  min_age_s=$((min_age_h * 3600))
  now=$(date +%s)
  for team_cfg in "$NAZGUL_TEAMS_DIR"/*/config.json; do
    [ -f "$team_cfg" ] || continue
    team_dir=$(dirname "$team_cfg")
    team=$(basename "$team_dir")
    case "$team" in ''|.|..|*/*) continue ;; esac
    jq -e --arg d "$project_dir" '[.members[]?.cwd == $d] | any' \
      "$team_cfg" >/dev/null 2>&1 || continue
    lead=$(jq -r '.leadSessionId // ""' "$team_cfg" 2>/dev/null || echo "")
    [ -z "$lead" ] && continue
    [ -n "$cur_sid" ] && [ "$lead" = "$cur_sid" ] && continue
    lead_safe=$(printf '%s' "$lead" | tr -c 'A-Za-z0-9_-' '_')
    [ -f "$nazgul_dir/sessions/${lead_safe}.lock" ] && continue
    alive="false"
    for t in "$NAZGUL_PROJECTS_DIR"/*/"$lead".jsonl; do
      [ -f "$t" ] || continue
      mt=$(stat -c %Y "$t" 2>/dev/null || stat -f %m "$t" 2>/dev/null || echo "")
      case "$mt" in ''|*[!0-9]*) alive="true"; break ;; esac
      if [ $((now - mt)) -lt "$min_age_s" ]; then alive="true"; break; fi
    done
    [ "$alive" = "true" ] && continue
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      case "$m" in */*|*..*) continue ;; esac
      rm -f "$nazgul_dir/dispatch/${m}.json"
    done <<< "$(jq -r '.members[]?.name // ""' "$team_cfg" 2>/dev/null || echo "")"
    rm -rf "$team_dir"
    rm -rf "${NAZGUL_TEAM_TASKS_DIR:?}/${team}"
    mkdir -p "$nazgul_dir/logs" 2>/dev/null || true
    jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg team "$team" --arg lead "$lead" \
      '{ts:$ts, team:$team, lead:$lead, action:"swept"}' \
      >> "$nazgul_dir/logs/team-sweep.jsonl" 2>/dev/null || true
    printf '%s\n' "$team"
  done
  return 0
}
```

Then in `scripts/session-context.sh`, after the session-registration block (after the `CONCURRENT_WARNING` assignment, ~line 29) insert:

```bash
# Orphaned-team sweep (spec 2026-07-24) — dead-session Agent-Teams state
# attributable to THIS project. Kill-switch: guards.team_sweep.
TT_SWEEP_NOTICE=""
TT_SWEEP_ENABLED=$(jq -r 'if .guards.team_sweep == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")
if [ "$TT_SWEEP_ENABLED" = "true" ]; then
  source "$SCRIPT_DIR/lib/team-teardown.sh"
  TT_MIN_AGE=$(jq -r '.guards.team_sweep_min_age_hours // 24' "$CONFIG" 2>/dev/null || echo 24)
  TT_SWEPT=$(tt_sweep_orphaned_teams "$NAZGUL_DIR" "${CLAUDE_PROJECT_DIR:-$(pwd)}" "$SESSION_ID" "$TT_MIN_AGE" 2>/dev/null || true)
  [ -n "$TT_SWEPT" ] && TT_SWEEP_NOTICE="Swept orphaned team state (dead sessions): $(printf '%s' "$TT_SWEPT" | tr '\n' ' ')"
fi
```

and add this line into the script's final context output (the block that prints the session context to stdout — place it adjacent to the existing `CONCURRENT_WARNING` rendering, same conditional style):

```
$([ -n "$TT_SWEEP_NOTICE" ] && echo "$TT_SWEEP_NOTICE" || true)
```

- [ ] **Step 4: Run tests**

```bash
tests/run-tests.sh --filter=team-teardown && tests/run-tests.sh --filter=session-context && shellcheck scripts/lib/team-teardown.sh scripts/session-context.sh
```

Expected: all PASS; existing session-context tests undisturbed; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/team-teardown.sh scripts/session-context.sh tests/test-team-teardown.sh
git commit -m "feat: orphaned-team sweep — dead-session team state reaped at SessionStart"
```

---

### Task 5: `/nazgul:clean --teams` and `--teams --all`

**Files:**
- Modify: `skills/clean/SKILL.md`

**Interfaces:**
- Consumes: `tt_sweep_orphaned_teams` (Task 4) via `bash -c 'source …'`.

- [ ] **Step 1: Add the flag docs** — in `skills/clean/SKILL.md`, extend the `## Examples` section:

```markdown
- `/nazgul:clean --teams` — Sweep dead-session Agent-Teams state for THIS project only (does not uninstall Nazgul)
- `/nazgul:clean --teams --all` — Also list dead teams from OTHER projects and ask per team before deleting
```

- [ ] **Step 2: Add the teams mode** — insert a new step after "Step 2: Parse Arguments" (renumber nothing; use a lettered step to avoid churn):

```markdown
### Step 2b: Teams-Only Mode (`--teams`)

If `$ARGUMENTS` contains `--teams`, do ONLY this step, then stop (no uninstall):

1. Sweep this project's dead teams:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/team-teardown.sh"; \
     tt_sweep_orphaned_teams "$(pwd)/nazgul" "$(pwd)" "${CLAUDE_SESSION_ID:-}" \
       "$(jq -r ".guards.team_sweep_min_age_hours // 24" nazgul/config.json 2>/dev/null || echo 24)"'
   ```
   Report each swept team name; report "no dead teams for this project" when the output is empty.
2. If `--all` is ALSO present: list every remaining team in `~/.claude/teams/` whose `config.json` `leadSessionId` has no transcript in `~/.claude/projects/*/<id>.jsonl` modified in the last 24 hours. For each such FOREIGN team (any member `cwd` outside this project), show its name, member cwds, and creation date, then use `AskUserQuestion` per team: Delete / Keep. On Delete:
   ```bash
   rm -rf ~/.claude/teams/<team> ~/.claude/tasks/<team>
   ```
   NEVER delete a foreign team without an explicit per-team answer. Never touch a team whose lead transcript is fresh.
3. Stop here — `--teams` never proceeds to the uninstall flow.
```

- [ ] **Step 3: Verify skill docs freshness** (the CI check `skill-docs.yml` must not flag this file; `clean` has no `.tmpl`, but run the checker to be sure)

```bash
scripts/gen-skill-docs.sh --check
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add skills/clean/SKILL.md
git commit -m "feat: /nazgul:clean --teams — dead-team sweep, --all interactive foreign cleanup"
```

---

### Task 6: Doc/template repairs (post-2.1.178 reality + dismissal contract)

**Files:**
- Modify: `templates/skill-partials/report-contract.md`
- Modify: `agents/team-orchestrator.md`
- Modify: `scripts/stop-hook.sh` (dispatch prompt text at ~line 1240 — text only, inside the `DISPATCH_INSTR` heredoc for the parallel batch)
- Modify: `RULES.md`, `CLAUDE.md`

- [ ] **Step 1: report-contract.md** — two changes:

(a) In the manifest snippet, add the `team` field (record the team name when the teammate is spawned into a NAMED team; empty/omitted means the session's implicit team):

```bash
mkdir -p nazgul/dispatch
jq -n --arg t "<teammate-session-name>" --arg rp "<REPORT_PATH>" \
  --arg team "<team-name-or-empty>" \
  --arg f "$(jq -r '.feat_id // "default"' nazgul/config.json)" \
  --arg sa "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson sae "$(date +%s)" \
  '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:0}
   + (if $team != "" then {team:$team} else {} end)' \
  > "nazgul/dispatch/<teammate-session-name>.json"
```

(b) Append a new paragraph after the existing teardown paragraph:

```markdown
Dismissal (mandatory): after you consume a teammate's report, send that
teammate a SendMessage shutdown_request. Once it approves, delete its
`nazgul/dispatch/<session-name>.json`. Teammates never terminate on their
own — an undismissed teammate idles forever, and the stop-hook's teardown
gate will block new dispatches until it is dismissed. `TeamCreate`/
`TeamDelete` no longer exist (removed in Claude Code v2.1.178); per-teammate
shutdown_request is the only teardown primitive, and team state is otherwise
removed only on normal session exit.
```

- [ ] **Step 2: team-orchestrator.md** — replace step 9 of "Spawning a Review Team" and steps 10–11 of "Spawning an Implementation Team" (the "Clean up the team AND delete ONLY..." steps) with:

```markdown
9. Dismiss each teammate THIS team spawned as soon as its report is consumed:
   send it a SendMessage shutdown_request (teammates never exit on their own;
   TeamCreate/TeamDelete no longer exist as of Claude Code v2.1.178). After a
   teammate approves shutdown, delete ONLY its
   `nazgul/dispatch/<session-name>.json` manifest (the exact session names
   from step 7) — never glob `nazgul/dispatch/*.json`, which would also
   delete other concurrently active teams' manifests and silently disable
   their TeammateIdle enforcement. If a teammate rejects shutdown, it
   believes it has live work — check its report before re-requesting. The
   stop-hook's team-teardown gate (guards.team_teardown) independently
   detects undismissed teammates and blocks new dispatches until they are
   dismissed.
```

(Adapt the leading number to each list's position; keep both lists' surrounding steps untouched.)

- [ ] **Step 3: stop-hook.sh dispatch text** — in the `DISPATCH_INSTR` parallel-batch heredoc (~line 1240), extend the teammate branch of step 1. After the sentence ending `— a teammate's final text is delivered to NO ONE.` append:

```
After consuming each teammate's manifest update, send that teammate a SendMessage shutdown_request and, once approved, delete its nazgul/dispatch/<session-name>.json — teammates are never left idling.
```

- [ ] **Step 4: RULES.md** — append a new numbered section after the current last `## ` section (run `grep -n '^## ' RULES.md | tail -1` for the number; call it `§N Teammate Teardown & Team Sweep`):

```markdown
## §N Teammate Teardown & Team Sweep

Agent-Teams teammates never terminate on their own; idle is their terminal
state until dismissed. `TeamCreate`/`TeamDelete` do not exist (removed in
Claude Code v2.1.178) — per-teammate `SendMessage` shutdown_request is the
only teardown primitive, and team config state is removed only on normal
session exit.

1. **Dismissal is part of consuming a report.** Whoever dispatched a teammate
   MUST send it a shutdown_request after its report is consumed, then delete
   its `nazgul/dispatch/<session-name>.json` (never glob the directory).
2. **The stop-hook enforces this** (`guards.team_teardown`, default true): a
   teammate with a delivered report still present in its team's members list
   triggers a mandatory TEAM TEARDOWN directive before new work dispatches.
   After 3 ignored directives it fails open with a raise_finding escalation —
   the loop never deadlocks on dismissal.
3. **Manifests self-heal.** A dispatch manifest whose team is gone or whose
   teammate is no longer a member is deleted automatically by the detector.
4. **Dead-session team state is swept** (`guards.team_sweep`, default true):
   at SessionStart, teams attributable to this project (member cwd match)
   whose lead session is provably dead (no session lock AND no transcript
   fresher than `guards.team_sweep_min_age_hours`, default 24) are deleted
   from `~/.claude/teams/` and `~/.claude/tasks/`, logged to
   `nazgul/logs/team-sweep.jsonl`. Foreign projects' teams are only ever
   deleted interactively via `/nazgul:clean --teams --all`. Any ambiguity
   fails open: the team is kept.
```

- [ ] **Step 5: CLAUDE.md** — in the directory-structure listing under `scripts/lib/`, add:

```
│       ├── team-teardown.sh         # Teammate dismissal detection + dead-session team sweep
```

and in Key Concepts, after the "One engine, optional parallel dispatch." paragraph, add:

```markdown
**Teammates are dismissed, never abandoned.** Agent-Teams teammates idle forever unless the lead sends a `shutdown_request` — so consuming a teammate's report and dismissing it are one motion. The stop-hook's teardown gate (`guards.team_teardown`) detects undismissed teammates (delivered report + still a team member) and blocks new dispatch until they're dismissed; SessionStart sweeps team state left by dead sessions (`guards.team_sweep`). See RULES.md §N (Teammate Teardown & Team Sweep).
```

(Substitute the actual section number chosen in Step 4 for both `§N` references.)

- [ ] **Step 6: Verify + commit**

```bash
scripts/gen-skill-docs.sh --check && bash -n scripts/stop-hook.sh && tests/run-tests.sh --filter=stop-hook
git add templates/skill-partials/report-contract.md agents/team-orchestrator.md scripts/stop-hook.sh RULES.md CLAUDE.md
git commit -m "docs: post-2.1.178 team lifecycle — dismissal contract, teardown gate, sweep rules"
```

---

### Task 7: Release chores + full verification

**Files:**
- Modify: `.claude-plugin/plugin.json` (version `2.21.0` → `2.22.0`)
- Modify: `README.md` (version badge `2.21.0` → `2.22.0`)
- Modify: `CHANGELOG.md` (new section at top)

- [ ] **Step 1: Bump versions**

In `.claude-plugin/plugin.json`: `"version": "2.22.0"`. In `README.md`: update the version badge string the same way (grep for `2.21.0`).

- [ ] **Step 2: CHANGELOG entry** — add at top, matching the existing entry style:

```markdown
## [2.22.0] - 2026-07-24

### Added
- **FEAT-018 Teammate Teardown & Team Sweep** — Agent-Teams teammates are now
  dismissed instead of left idling forever:
  - `scripts/lib/team-teardown.sh`: undismissed-teammate detection (delivered
    report + still a team member) with dispatch-manifest self-heal, and a
    dead-session orphaned-team sweep for `~/.claude/teams/` + `~/.claude/tasks/`.
  - Stop-hook TEAM TEARDOWN gate: mandatory dismissal directive before new
    dispatch, 3-strike fail-open escalation via `raise_finding`
    (`guards.team_teardown`, default true; config schema v31).
  - SessionStart sweep (`guards.team_sweep`, default true;
    `guards.team_sweep_min_age_hours`, default 24) + `/nazgul:clean --teams`
    (`--all` for interactive foreign-team cleanup).
  - Report Contract: manifests record their `team`; dismissal
    (shutdown_request after report consumption) is now part of the contract.
  - Docs updated for the post-v2.1.178 platform (TeamCreate/TeamDelete
    removed; per-teammate shutdown_request is the only teardown primitive).
```

- [ ] **Step 3: Full verification**

```bash
tests/run-tests.sh
shellcheck scripts/lib/team-teardown.sh scripts/stop-hook.sh scripts/session-context.sh scripts/migrate-config.sh
scripts/gen-skill-docs.sh --check
```

Expected: full suite PASS (all ~66 files), shellcheck clean, skill docs fresh. Do not claim completion without this output.

- [ ] **Step 4: Commit + PR**

```bash
git add .claude-plugin/plugin.json README.md CHANGELOG.md
git commit -m "chore: release v2.22.0 — teammate teardown enforcement + team sweep"
git push -u origin feat/team-teardown
gh pr create --base main --title "FEAT-018: Teammate Teardown Enforcement + Orphaned-Team Sweep (v2.22.0)" --body "$(cat <<'EOF'
## Summary
- Stop-hook TEAM TEARDOWN gate: teammates with delivered reports must be dismissed (shutdown_request) before new work dispatches; 3-strike fail-open escalation (guards.team_teardown, schema v31)
- Dead-session orphaned-team sweep at SessionStart + /nazgul:clean --teams [--all] (guards.team_sweep)
- Dispatch manifests record their team; detector self-heals manifests for dismissed teammates
- Docs/templates repaired for post-2.1.178 Agent Teams (TeamCreate/TeamDelete removed)

Spec: docs/superpowers/specs/2026-07-24-team-teardown-design.md (local, uncommitted by convention)

## Test plan
- [ ] tests/run-tests.sh fully green (incl. new tests/test-team-teardown.sh: detection, self-heal, gate, escalation, sweep, migration)
- [ ] shellcheck clean on all touched scripts

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Manual validation (main session only — after the PR is up)

These need a live Agent-Teams session and interactive judgment; they are NOT executor tasks.

1. **Spike (spec §4.3):** this session's implicit team (`session-94d0ed8b`) still holds five idle Nazgul teammates. Send `shutdown_request` to one (e.g. `rv-code-TASK-011`), wait for approval, then diff `~/.claude/teams/session-94d0ed8b/config.json` — record whether the member entry disappears. Update the header comment of `scripts/lib/team-teardown.sh` and the `reference_claude_code_platform_facts` memory with the observed behavior. (The detector is correct either way: membership-observable → detection self-clears on dismissal; not observable → the lead's manifest deletion clears it.)
2. Dismiss the remaining four idle teammates the same way.
3. Run `/nazgul:clean --teams --all` and interactively dispose of the four foreign dead teams (`backlog-wave1`, `dod-prod`, `pr-fix-round3` from Strumtry; `session-2a9bc199` from TaxGuardian).
4. Watch the first real parallel/review run after merge for `team_teardown` telemetry events (`nazgul/logs/events.jsonl`) and confirm no directive loops.
