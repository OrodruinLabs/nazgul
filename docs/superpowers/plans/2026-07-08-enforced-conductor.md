# Enforced Conductor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Nazgul conductor engine's correct dispatch behavior *mechanically enforced* (hooks/guards) instead of hoped-for prose, so it can never fire-and-yield/orphan work units or re-dispatch completed ones — and reuse the sequential engine's proven Agent-Teams wave path.

**Architecture:** Five layers enforcing one invariant — **"completed = cached, never re-executed"** (a unit at IMPLEMENTED/DONE with a commit SHA is never re-implemented; the same guarantee the native Workflow runtime gets from result caching, which we get from guards). A new PreToolUse guard on the `Agent` tool blocks background/duplicate work-unit dispatch (the ceiling); a Write/Edit re-work guard blocks re-implementing a committed unit (the floor); `subagent-stop.sh` detects orphaned waves; `conductor-router.sh` routes parallel mutating waves to `team-orchestrator`; and `conductor-graph.sh` emits a wave-state digest to cut orientation cost. All guards no-op unless a conductor run is active. An additive `conductor.enforce` config (default on) provides a kill-switch.

**Why not rebuild on native dynamic Workflows:** investigated and rejected (see spec's "Dynamic Workflows investigation") — plugins can't ship workflows, workflows don't survive session exit (breaks Nazgul's cross-session recovery), no HITL mid-run, and the `Workflow` tool is main-session-only so the conductor-subagent can't invoke it. We adopt the patterns, not the runtime.

**Tech Stack:** POSIX bash (`set -euo pipefail`), `jq`, `git`, Claude Code plugin hooks, custom bash test harness (`tests/run-tests.sh` + `tests/lib/assertions.sh`).

## Global Constraints

- Shell: `#!/usr/bin/env bash`, `set -euo pipefail`, quote all variables. Sourced libs use an idempotent source guard instead of `set -e`.
- All JSON via `jq` (read-modify-write to a `mktemp` then `mv`). **No `eval`** on prompt text, unit text, commands, or any untrusted field — extract as data, match with fixed/greppable patterns only.
- Every new/changed script passes `bash -n` and `shellcheck` cleanly; register every new `scripts/**.sh` in `tests/test-shellcheck.sh`'s `SCRIPTS` array.
- Tests ship **with** the task; `tests/run-tests.sh` stays fully green.
- Guard exit codes: `0` = allow, `2` = deny (human-readable reason on stderr) — the Claude Code PreToolUse convention.
- **Zero regression to the sequential engine:** no task edits `scripts/stop-hook.sh` or sequential-only paths; every new guard no-ops unless `execution.engine == "conductor"` AND `nazgul/conductor/.session` exists.
- ONE additive schema bump **v19 → v20** (`migrate_19_to_20`), idempotent from any prior version.
- Git: branch `feat/conductor-enforcement` off `main`; PR to `main`; never commit to `main`. Commit prefix `feat(conductor):` / `test(conductor):` / `docs(conductor):`.
- Release: MINOR **2.9.0 → 2.10.0** (`.claude-plugin/plugin.json` + README badge + CHANGELOG).
- Reference spec: `docs/superpowers/specs/2026-07-08-conductor-enforcement-design.md`.

---

## File Structure

- `scripts/conductor-dispatch-guard.sh` — **new**. PreToolUse(`Agent`) ceiling guard (Layer 1).
- `scripts/conductor-rework-guard.sh` — **new**. PreToolUse(`Write|Edit|MultiEdit`) floor guard (Layer 2).
- `scripts/subagent-stop.sh` — **modify**. Add conductor orphan detection (Layer 3).
- `scripts/lib/conductor-router.sh` — **modify**. `route_backend` sends parallel-mutation → `team` (Layer 4).
- `scripts/lib/conductor-graph.sh` — **modify**. Add `graph_wave_digest()` (Layer 5).
- `scripts/migrate-config.sh` — **modify**. Add `migrate_19_to_20` (config).
- `templates/config.json` — **modify**. `schema_version → 20` + `conductor.enforce` block.
- `hooks/hooks.json` — **modify**. Register the two new guards.
- `agents/conductor.md` — **modify**. Step 0 writes `.session`; Step 5 emits `NAZGUL_UNIT:` + synchronous/team dispatch; Step 0/2 read the digest.
- `tests/test-conductor-dispatch-guard.sh`, `tests/test-conductor-rework-guard.sh`, `tests/test-conductor-orphan-detection.sh`, `tests/test-conductor-router.sh` (extend), `tests/test-conductor-graph.sh` (extend), `tests/test-migrate-config.sh` (extend), `tests/test-shellcheck.sh` (extend), `tests/test-rules-tiers.sh` (extend) — **new/modify**.
- `RULES.md`, `CLAUDE.md`, `docs/loop-engineering.md`, `CHANGELOG.md`, `README.md`, `.claude-plugin/plugin.json` — **modify** (docs/release).

---

## Task 0: Feasibility gate — plugin PreToolUse(`Agent`) fires for a *subagent's* dispatch

**Why first:** Layer 1 assumes a plugin-level PreToolUse `Agent` hook fires for a dispatch made *by a subagent* (the conductor), not just the main session. The main-session case + subagent Write/Edit case are already proven; this confirms the exact remaining inference. If it fails, STOP and escalate the design to SubagentStop-based enforcement.

**Files:**
- Create: `tests/e2e/probe-agent-hook.md` (recorded procedure + result)
- Create (temporary, throwaway): a logging hook + settings entry as described below

**Interfaces:**
- Produces: a recorded PASS/FAIL that gates Tasks 1–8.

- [ ] **Step 1: Branch setup**

```bash
git checkout main && git pull --ff-only 2>/dev/null || true
git checkout -b feat/conductor-enforcement
```

- [ ] **Step 2: Write a throwaway logging hook**

```bash
cat > /tmp/probe-agent-hook.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
LOG=/tmp/probe-agent-hook.log
INPUT=""; [ ! -t 0 ] && INPUT=$(cat 2>/dev/null || true)
printf 'FIRED tool=%s bg=%s type=%s\n' \
  "$(printf '%s' "$INPUT" | jq -r '.tool_name // "?"' 2>/dev/null)" \
  "$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // "?"' 2>/dev/null)" \
  "$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // "?"' 2>/dev/null)" >> "$LOG"
exit 0
EOF
chmod +x /tmp/probe-agent-hook.sh
: > /tmp/probe-agent-hook.log
```

- [ ] **Step 3: Register it as a project PreToolUse(`Agent`) hook** in `.claude/settings.local.json` (preserve existing `permissions`; add a `hooks` block with matcher `"Agent"` → `/tmp/probe-agent-hook.sh`).

- [ ] **Step 4: Trigger a NESTED dispatch** — in a Claude Code session, dispatch a parent subagent (`general-purpose`) whose only instruction is to itself dispatch one trivial child subagent (any type) with `run_in_background:false` and then reply "done".

- [ ] **Step 5: Verify the hook logged the CHILD dispatch (made by the parent subagent)**

Run: `cat /tmp/probe-agent-hook.log`
Expected: at least TWO `FIRED tool=Agent …` lines — one for the parent dispatch (from main) and one for the child dispatch (from inside the parent subagent). The second line proves plugin PreToolUse fires for a subagent's `Agent` call.

- [ ] **Step 6: Record result + remove the probe hook**

Write the outcome to `tests/e2e/probe-agent-hook.md` (PASS/FAIL, the log lines). Restore `.claude/settings.local.json` to permissions-only. If FAIL: STOP, do not build Layers 1–2 as designed; escalate to SubagentStop enforcement and revise the spec.

- [ ] **Step 7: Commit**

```bash
git add tests/e2e/probe-agent-hook.md
git commit -m "test(conductor): record Agent-hook-in-subagent feasibility gate (Task 0)"
```

---

## Task 1: Config schema v19→v20 — `conductor.enforce` block + migration

**Files:**
- Modify: `scripts/migrate-config.sh` (add `migrate_19_to_20` after `migrate_18_to_19`, ~line 394)
- Modify: `templates/config.json` (`schema_version` → 20; add `conductor.enforce`)
- Modify: `tests/test-migrate-config.sh` (add v19→v20 case)

**Interfaces:**
- Produces: config path `.conductor.enforce.dispatch_guard` (bool, default `true`), `.conductor.enforce.rework_guard` (bool, default `true`). Consumed by Tasks 3 and 5.

- [ ] **Step 1: Write the failing migration test** — append to `tests/test-migrate-config.sh`:

```bash
# --- v19 -> v20: conductor.enforce (additive, default true) ---
TMPDIR_V20=$(mktemp -d)
cp "$REPO_ROOT/templates/config.json" "$TMPDIR_V20/config.json"
# simulate a v19 config lacking the new block
jq '.schema_version = 19 | del(.conductor.enforce)' "$TMPDIR_V20/config.json" > "$TMPDIR_V20/c.tmp" && mv "$TMPDIR_V20/c.tmp" "$TMPDIR_V20/config.json"
mkdir -p "$TMPDIR_V20/nazgul"; mv "$TMPDIR_V20/config.json" "$TMPDIR_V20/nazgul/config.json"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/scripts/migrate-config.sh" "$TMPDIR_V20/nazgul" >/dev/null 2>&1 || true
assert_json_field "$TMPDIR_V20/nazgul/config.json" ".schema_version" "20"
assert_json_field "$TMPDIR_V20/nazgul/config.json" ".conductor.enforce.dispatch_guard" "true"
assert_json_field "$TMPDIR_V20/nazgul/config.json" ".conductor.enforce.rework_guard" "true"
rm -rf "$TMPDIR_V20"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=migrate-config`
Expected: FAIL — template still at 19 / no migration function.

- [ ] **Step 3: Bump the template** — in `templates/config.json` set `"schema_version": 20` and add under `"conductor"`:

```json
"enforce": { "dispatch_guard": true, "rework_guard": true }
```

- [ ] **Step 4: Add `migrate_19_to_20`** to `scripts/migrate-config.sh` (mirror `migrate_18_to_19`'s additive-clamp pattern):

```bash
migrate_19_to_20() {
  local tmp; tmp=$(mktemp)
  # Conductor enforcement toggles. ADDITIVE — set when absent, explicit values (incl. false) preserved.
  jq '
    .conductor = ((if (.conductor | type) == "object" then .conductor else {} end)
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .dispatch_guard = (if has("dispatch_guard") then .dispatch_guard else true end)
          | .rework_guard = (if has("rework_guard") then .rework_guard else true end)))
    | .schema_version = 20
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v19→v20: added conductor.enforce.{dispatch_guard,rework_guard} (default true)"
}
```
(The existing `while VERSION < TARGET` dispatch loop at ~line 417 picks this up automatically.)

- [ ] **Step 5: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=migrate-config`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/migrate-config.sh templates/config.json tests/test-migrate-config.sh
git commit -m "feat(conductor): add conductor.enforce config + migrate_19_to_20 (v19→v20)"
```

---

## Task 2: Layer 1 — `conductor-dispatch-guard.sh` (PreToolUse ceiling)

**Files:**
- Create: `scripts/conductor-dispatch-guard.sh`
- Modify: `hooks/hooks.json` (new `PreToolUse` matcher `"Agent"`)
- Modify: `tests/test-shellcheck.sh` (register the new script)
- Test: `tests/test-conductor-dispatch-guard.sh`

**Interfaces:**
- Consumes: config `.execution.engine`, `.conductor.enforce.dispatch_guard` (Task 1); `nazgul/conductor/.session` marker (written by Task 6); `nazgul/conductor/graph.json` (`.tasks[id].status`, `.commit_sha`); the `NAZGUL_UNIT: TASK-NNN` prompt marker (emitted by Task 6).
- Produces: exit 2 (deny) on a background work-unit dispatch or a re-dispatch of an `IMPLEMENTED`/`DONE` unit; exit 0 otherwise.

- [ ] **Step 1: Write the failing test** — `tests/test-conductor-dispatch-guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-dispatch-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/conductor-dispatch-guard.sh"

# Build an isolated conductor-run fixture.
setup() {
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor"
  jq -n '{schema_version:20,execution:{engine:"conductor"},conductor:{enforce:{dispatch_guard:true}}}' > "$WORK/nazgul/config.json"
  : > "$WORK/nazgul/conductor/.session"
  jq -n '{tasks:{"TASK-001":{status:"READY"},"TASK-002":{status:"DONE",commit_sha:"abc1234"}}}' > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }

# helper: build the Agent PreToolUse envelope and return the guard's exit code
guard_ec() { # <subagent_type> <run_in_background> <prompt>
  local ec=0
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup
# 1. background implementer dispatch -> DENY (exit 2)
assert_eq "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "2" "background implementer denied"
# 2. synchronous first dispatch of a READY unit -> ALLOW (exit 0)
assert_eq "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-001")" "0" "sync first dispatch allowed"
# 3. re-dispatch of a DONE unit -> DENY (exit 2)
assert_eq "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2" "re-dispatch of DONE unit denied"
# 4. non-work-unit background dispatch (e.g. general-purpose) -> ALLOW
assert_eq "$(guard_ec "general-purpose" true "helper")" "0" "non-unit background allowed"
teardown

# 5. off-conductor: engine=sequential -> ALLOW everything (no-op)
setup; jq '.execution.engine="sequential"' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0" "sequential engine no-op"
teardown

# 6. no .session marker -> ALLOW (no-op)
setup; rm -f "$WORK/nazgul/conductor/.session"
assert_eq "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0" "no session marker no-op"
teardown

report_results
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=conductor-dispatch-guard`
Expected: FAIL — guard script does not exist.

- [ ] **Step 3: Write `scripts/conductor-dispatch-guard.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Dispatch Guard — PreToolUse on the Agent tool.
# Enforces agents/conductor.md Step 5: conductor work units dispatch SYNCHRONOUSLY,
# and a completed unit is never re-dispatched. No-op unless a conductor run is active.
# Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
GRAPH="$NAZGUL_DIR/conductor/graph.json"
SESSION_MARKER="$NAZGUL_DIR/conductor/.session"

# Scope: only during an active conductor run.
[ -f "$CONFIG" ] || exit 0
[ -f "$SESSION_MARKER" ] || exit 0
ENGINE=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
[ "$ENGINE" = "conductor" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .conductor.enforce.dispatch_guard == null then "true" else (.conductor.enforce.dispatch_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

# Only the Agent tool.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
BG=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo "false")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

is_work_unit() {
  case "$1" in
    *implementer*|*review-gate*|*team-orchestrator*) return 0 ;;
    *) return 1 ;;
  esac
}

# Rule 1: work units must be synchronous.
if [ "$BG" = "true" ] && is_work_unit "$SUBAGENT"; then
  echo "NAZGUL CONDUCTOR: Blocked — work-unit dispatch ($SUBAGENT) must be synchronous, not run_in_background (agents/conductor.md Step 5)." >&2
  exit 2
fi

# Rule 2: never re-dispatch a completed unit. Prompt carries `NAZGUL_UNIT: TASK-NNN` (grepped as data — never eval'd).
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
if [ -n "$UNIT" ] && [ -f "$GRAPH" ] && is_work_unit "$SUBAGENT"; then
  STATUS=$(jq -r --arg id "$UNIT" '.tasks[$id].status // ""' "$GRAPH" 2>/dev/null || echo "")
  case "$STATUS" in
    IMPLEMENTED|DONE)
      SHA=$(jq -r --arg id "$UNIT" '.tasks[$id].commit_sha // "?"' "$GRAPH" 2>/dev/null || echo "?")
      echo "NAZGUL CONDUCTOR: Blocked — $UNIT already $STATUS at $SHA; re-dispatch is wasted work (agents/conductor.md Step 5)." >&2
      exit 2 ;;
  esac
fi

exit 0
```

- [ ] **Step 4: Register the hook** — in `hooks/hooks.json`, add a new object to the `PreToolUse` array:

```json
{
  "matcher": "Agent",
  "hooks": [
    { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/conductor-dispatch-guard.sh\"", "timeout": 10 }
  ]
}
```

- [ ] **Step 5: Register in shellcheck test** — add `"scripts/conductor-dispatch-guard.sh"` to the `SCRIPTS` array in `tests/test-shellcheck.sh`.

- [ ] **Step 6: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=conductor-dispatch-guard && bash tests/run-tests.sh --filter=shellcheck`
Expected: PASS both. Also `bash -n scripts/conductor-dispatch-guard.sh` clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/conductor-dispatch-guard.sh hooks/hooks.json tests/test-conductor-dispatch-guard.sh tests/test-shellcheck.sh
git commit -m "feat(conductor): PreToolUse Agent guard — block background/duplicate work-unit dispatch (Layer 1)"
```

---

## Task 3: Layer 2 — `conductor-rework-guard.sh` (PreToolUse floor)

**Files:**
- Create: `scripts/conductor-rework-guard.sh`
- Modify: `hooks/hooks.json` (add to the `Write|Edit|MultiEdit` matcher's hooks)
- Modify: `tests/test-shellcheck.sh`
- Test: `tests/test-conductor-rework-guard.sh`

**Interfaces:**
- Consumes: config `.execution.engine`, `.conductor.enforce.rework_guard`; `.session` marker; `graph.json` (`.tasks[id].file_scope[]`, `.tasks[id].status`, `.tasks[id].commit_sha`); the edited file path from `tool_input.file_path`.
- Produces: exit 2 when an edit targets a file in the `file_scope` of a unit already `IMPLEMENTED`/`DONE` with a commit SHA; else exit 0.

- [ ] **Step 1: Write the failing test** — `tests/test-conductor-rework-guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-rework-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/conductor-rework-guard.sh"

setup() {
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor"
  jq -n '{schema_version:20,execution:{engine:"conductor"},conductor:{enforce:{rework_guard:true}}}' > "$WORK/nazgul/config.json"
  : > "$WORK/nazgul/conductor/.session"
  jq -n '{tasks:{
    "TASK-001":{status:"DONE",commit_sha:"abc1234",file_scope:["scripts/lib/inbox-provider.sh"]},
    "TASK-002":{status:"READY",file_scope:["scripts/heartbeat.sh"]}
  }}' > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }

guard_ec() { # <file_path>
  local ec=0
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup
# edit a file owned by a DONE+committed unit -> DENY
assert_eq "$(guard_ec "scripts/lib/inbox-provider.sh")" "2" "rework of committed unit denied"
# edit a file owned by a READY (uncommitted) unit -> ALLOW
assert_eq "$(guard_ec "scripts/heartbeat.sh")" "0" "first write of ready unit allowed"
# edit an unrelated file -> ALLOW
assert_eq "$(guard_ec "docs/README.md")" "0" "out-of-scope file allowed"
teardown

# off-conductor -> ALLOW
setup; jq '.execution.engine="sequential"' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "$(guard_ec "scripts/lib/inbox-provider.sh")" "0" "sequential engine no-op"
teardown

report_results
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=conductor-rework-guard`
Expected: FAIL — guard missing.

- [ ] **Step 3: Write `scripts/conductor-rework-guard.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Re-work Guard — PreToolUse on Write|Edit|MultiEdit.
# Blocks re-implementing a unit whose work is already committed. No-op unless a
# conductor run is active. Exit 0 = allow, exit 2 = deny.

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
GRAPH="$NAZGUL_DIR/conductor/graph.json"
SESSION_MARKER="$NAZGUL_DIR/conductor/.session"

[ -f "$CONFIG" ] || exit 0
[ -f "$SESSION_MARKER" ] || exit 0
[ -f "$GRAPH" ] || exit 0
ENGINE=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
[ "$ENGINE" = "conductor" ] || exit 0
ENFORCE=$(jq -r 'if .conductor.enforce.rework_guard == null then "true" else (.conductor.enforce.rework_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0
# Normalise to a repo-relative path (strip project dir prefix if present).
REL="${FILE_PATH#"$NAZGUL_DIR%/nazgul"/}"; REL="${FILE_PATH##*/ai-hydra-framework/}"

# Find a committed unit that owns this file.
OWNER=$(jq -r --arg f "$FILE_PATH" --arg r "$REL" '
  .tasks | to_entries[]
  | select((.value.status=="DONE" or .value.status=="IMPLEMENTED") and (.value.commit_sha // "") != "")
  | select((.value.file_scope // []) | any(. == $f or . == $r or ($f | endswith(.))))
  | .key' "$GRAPH" 2>/dev/null | head -1 || true)

if [ -n "$OWNER" ]; then
  SHA=$(jq -r --arg id "$OWNER" '.tasks[$id].commit_sha // "?"' "$GRAPH" 2>/dev/null || echo "?")
  echo "NAZGUL CONDUCTOR: Blocked — $FILE_PATH belongs to $OWNER, already implemented at $SHA; re-work blocked (agents/conductor.md Step 5)." >&2
  exit 2
fi
exit 0
```

- [ ] **Step 4: Register the hook** — in `hooks/hooks.json`, append to the `"Write|Edit|MultiEdit"` matcher's `hooks` array:

```json
{ "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/conductor-rework-guard.sh\"", "timeout": 10 }
```

- [ ] **Step 5: Register in shellcheck test** — add `"scripts/conductor-rework-guard.sh"` to `tests/test-shellcheck.sh`.

- [ ] **Step 6: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=conductor-rework-guard && bash tests/run-tests.sh --filter=shellcheck`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/conductor-rework-guard.sh hooks/hooks.json tests/test-conductor-rework-guard.sh tests/test-shellcheck.sh
git commit -m "feat(conductor): PreToolUse Write/Edit re-work guard — block re-implementing a committed unit (Layer 2)"
```

---

## Task 4: Layer 3 — orphan detection in `subagent-stop.sh`

**Files:**
- Modify: `scripts/subagent-stop.sh` (add a `_detect_conductor_orphan` function + dispatch for `*conductor*`)
- Test: `tests/test-conductor-orphan-detection.sh`

**Interfaces:**
- Consumes: SubagentStop payload agent identity (already extracted as `$AGENT`); `graph.json` (`.tasks[*].status`, `.dispatched` marker if present); `emit_event` from `lib/emit-event.sh`.
- Produces: writes `nazgul/conductor/.resume-needed` (JSON: `{wave, units}`) and emits `conductor_orphan_detected` when the conductor stops with a wave that has dispatched-but-not-terminal units. Never blocks.

- [ ] **Step 1: Write the failing test** — `tests/test-conductor-orphan-detection.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-orphan-detection"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
HOOK="$REPO_ROOT/scripts/subagent-stop.sh"

setup() { # <graph_json>
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor" "$WORK/nazgul/logs"
  jq -n '{schema_version:20,execution:{engine:"conductor"},telemetry:{bus_enabled:true}}' > "$WORK/nazgul/config.json"
  echo "$1" > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }
fire() { jq -n '{subagent_type:"nazgul:conductor"}' | bash "$HOOK" >/dev/null 2>&1 || true; }

# incomplete wave: a unit dispatched but not terminal -> .resume-needed written
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"IN_PROGRESS","wave":1,"dispatched":true},"TASK-002":{"status":"DONE","wave":1}}}'
fire
assert_file_exists "$WORK/nazgul/conductor/.resume-needed" "orphan marker written on incomplete wave"
teardown

# complete wave -> no marker
setup '{"current_wave":1,"tasks":{"TASK-001":{"status":"DONE","wave":1},"TASK-002":{"status":"DONE","wave":1}}}'
fire
assert_file_not_exists "$WORK/nazgul/conductor/.resume-needed" "no marker when wave complete"
teardown

report_results
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=conductor-orphan-detection`
Expected: FAIL — no orphan logic yet.

- [ ] **Step 3: Add the detector to `scripts/subagent-stop.sh`** — before the final `exit 0`, add the function and a dispatch on the conductor agent:

```bash
# Conductor orphan detector: if the conductor stops with a wave that has units
# dispatched but not terminal, record a resume marker + emit a loud event.
_detect_conductor_orphan() {
  command -v jq >/dev/null 2>&1 || return 0
  local graph="$NAZGUL_DIR/conductor/graph.json"
  [ -f "$graph" ] || return 0
  local engine
  engine=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
  [ "$engine" = "conductor" ] || return 0

  # Units that were dispatched but never reached a terminal state (DONE/BLOCKED).
  local incomplete
  incomplete=$(jq -rc '
    [ .tasks | to_entries[]
      | select((.value.dispatched // false) == true)
      | select((.value.status // "") as $s | ($s != "DONE" and $s != "BLOCKED"))
      | .key ]' "$graph" 2>/dev/null || echo "[]")
  [ -n "$incomplete" ] && [ "$incomplete" != "[]" ] || return 0

  local wave
  wave=$(jq -r '.current_wave // "?"' "$graph" 2>/dev/null || echo "?")
  jq -n --argjson units "$incomplete" --arg wave "$wave" \
    '{wave:$wave, units:$units, reason:"conductor stopped with incomplete wave"}' \
    > "$NAZGUL_DIR/conductor/.resume-needed" 2>/dev/null || true
  emit_event "conductor_orphan_detected" wave "$wave"
}

case "$AGENT" in
  *conductor*) _detect_conductor_orphan || true ;;
esac
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=conductor-orphan-detection`
Expected: PASS.

- [ ] **Step 5: Register + shellcheck** (subagent-stop.sh already registered) — run `shellcheck scripts/subagent-stop.sh` clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/subagent-stop.sh tests/test-conductor-orphan-detection.sh
git commit -m "feat(conductor): SubagentStop orphan detection — resume marker + event on incomplete wave (Layer 3)"
```

---

## Task 5: Layer 4 — route parallel mutation waves to `team-orchestrator`

**Files:**
- Modify: `scripts/lib/conductor-router.sh` (`route_backend`)
- Modify: `tests/test-conductor-router.sh` (add mutation-parallel → team assertions)
- Modify: `agents/conductor.md` (Step 4/5 dispatch language)

**Interfaces:**
- Consumes: `route_backend <kind> <isolation> [parallel]` — a new third arg indicating the batch is a parallel group.
- Produces: `"team"` for a parallel mutating batch; `"worktree"` only for a lone mutating unit; `"subagent"` for review/other.

- [ ] **Step 1: Write the failing test** — append to `tests/test-conductor-router.sh`:

```bash
# --- Layer 4: parallel mutation routes to team, single mutation to worktree ---
source "$REPO_ROOT/scripts/lib/conductor-router.sh"
assert_eq "$(route_backend implement mutation parallel)" "team" "parallel mutation -> team"
assert_eq "$(route_backend implement mutation single)"   "worktree" "single mutation -> worktree"
assert_eq "$(route_backend review "" parallel)"          "subagent" "review always subagent"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=conductor-router`
Expected: FAIL — `route_backend` ignores a third arg.

- [ ] **Step 3: Update `route_backend`** in `scripts/lib/conductor-router.sh`:

```bash
route_backend() {
  local kind="$1" isolation="${2:-}" group="${3:-single}"
  if [ "$kind" = "review" ]; then
    echo "subagent"
    return 0
  fi
  case "$isolation" in
    mutation)
      # Parallel mutating batch -> Agent Teams (managed lifecycle, the sequential
      # engine's proven wave path). A lone mutating unit -> a single worktree.
      if [ "$group" = "parallel" ]; then echo "team"; else echo "worktree"; fi ;;
    coordination) echo "team" ;;
    *)            echo "subagent" ;;
  esac
}
```
(Also update `route_unit`/`route_wave` callers at ~line 94 to pass `parallel` when the batch has >1 unit — inspect and thread the arg; keep single-unit callers passing `single`.)

- [ ] **Step 4: Update `agents/conductor.md` Step 5** — in the `subagent`/`worktree` bullet, add: for a parallel mutating batch the routed backend is now `team`; dispatch the batch via `team-orchestrator`'s "Spawning an Implementation Team" protocol (which does `git worktree add` per teammate and manages spawn→monitor→collect→cleanup), and wait for it to report every teammate's outcome before reviews. Keep the same-message synchronous rule for any residual `subagent`/`worktree` batch.

- [ ] **Step 5: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=conductor-router`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/conductor-router.sh tests/test-conductor-router.sh agents/conductor.md
git commit -m "feat(conductor): route parallel mutation waves to team-orchestrator (Layer 4)"
```

---

## Task 6: `.session` marker + `NAZGUL_UNIT` contract + digest read in `agents/conductor.md`; Layer 5 digest

**Files:**
- Modify: `scripts/lib/conductor-graph.sh` (add `graph_wave_digest()`)
- Modify: `tests/test-conductor-graph.sh` (digest test)
- Modify: `agents/conductor.md` (Step 0 writes `.session` + reads digest; Step 5 emits `NAZGUL_UNIT:`)

**Interfaces:**
- Consumes: `graph.json`.
- Produces: `graph_wave_digest <graph_file>` prints a compact one-object JSON `{current_wave, next_unit, units:{ID:{status,sha}}, hard_stop}`. Consumed by the conductor at turn start.

- [ ] **Step 1: Write the failing test** — append to `tests/test-conductor-graph.sh`:

```bash
# --- Layer 5: wave-state digest ---
DG=$(mktemp -d)
jq -n '{current_wave:2,tasks:{"TASK-001":{status:"DONE",commit_sha:"aaa111",wave:1},"TASK-003":{status:"READY",wave:2}}}' > "$DG/graph.json"
DIGEST=$(graph_wave_digest "$DG/graph.json")
assert_eq "$(printf '%s' "$DIGEST" | jq -r '.current_wave')" "2" "digest current_wave"
assert_eq "$(printf '%s' "$DIGEST" | jq -r '.units["TASK-001"].sha')" "aaa111" "digest carries sha"
assert_eq "$(printf '%s' "$DIGEST" | jq -r '.units["TASK-001"] | has("body")')" "false" "digest holds no file bodies (graph-only)"
rm -rf "$DG"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/run-tests.sh --filter=conductor-graph`
Expected: FAIL — `graph_wave_digest` undefined.

- [ ] **Step 3: Add `graph_wave_digest()`** to `scripts/lib/conductor-graph.sh`:

```bash
# graph_wave_digest <graph_file> -> compact per-turn orientation digest.
# Graph-only: ids/status/sha/wave + the next actionable unit. Never file bodies.
graph_wave_digest() {
  local graph_file="$1"
  [ -f "$graph_file" ] || { echo '{}'; return 0; }
  jq -c '{
    current_wave: (.current_wave // null),
    next_unit: ( [ .tasks | to_entries[] | select((.value.status // "") as $s | ($s != "DONE" and $s != "BLOCKED")) ] | sort_by(.value.wave // 9999) | (.[0].key // null) ),
    units: ( .tasks | map_values({status: (.status // "PLANNED"), sha: (.commit_sha // null), wave: (.wave // null)}) )
  }' "$graph_file" 2>/dev/null || echo '{}'
}
```

- [ ] **Step 4: Wire the conductor prose** — in `agents/conductor.md`:
  - **Step 0:** after locating `NAZGUL_DIR`, write the session marker: `printf '%s' "$RUN_ID" > "$NAZGUL_DIR/conductor/.session"` (and note it is removed at Step 9 completion). Read `graph_wave_digest "$NAZGUL_DIR/conductor/graph.json"` for orientation before falling back to full re-derivation.
  - **Step 5:** every implementer/review dispatch prompt MUST include a line `NAZGUL_UNIT: TASK-NNN` (the Layer 1 + Layer 3 contract).
  - **Step 9 (completion):** `rm -f "$NAZGUL_DIR/conductor/.session"` so the guards no-op once the run ends.

- [ ] **Step 5: Add a prose-contract assertion** — append to `tests/test-conductor-graph.sh` (or a small `tests/test-conductor-contract.sh`): assert `agents/conductor.md` contains `NAZGUL_UNIT: TASK` and `conductor/.session`:

```bash
assert_file_contains "$REPO_ROOT/agents/conductor.md" "NAZGUL_UNIT: TASK" "Step 5 emits the unit marker contract"
assert_file_contains "$REPO_ROOT/agents/conductor.md" "conductor/.session" "Step 0 writes the session marker"
```

- [ ] **Step 6: Run tests, verify pass**

Run: `bash tests/run-tests.sh --filter=conductor-graph`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/conductor-graph.sh agents/conductor.md tests/test-conductor-graph.sh
git commit -m "feat(conductor): session marker + NAZGUL_UNIT contract + wave-state digest (Layer 5)"
```

---

## Task 7: Docs, honest enforcement tiers, and release 2.9.0 → 2.10.0

**Files:**
- Modify: `RULES.md` (Conductor-enforcement section)
- Modify: `tests/test-rules-tiers.sh` (assert the new tier tags)
- Modify: `CLAUDE.md` (directory-structure + roster: the two new guards)
- Modify: `docs/loop-engineering.md` (enforced-dispatch description)
- Modify: `CHANGELOG.md`, `README.md`, `.claude-plugin/plugin.json` (version bump)

**Interfaces:** none (documentation + release).

- [ ] **Step 1: Write the failing tier test** — append to `tests/test-rules-tiers.sh` assertions that `RULES.md` contains a conductor-enforcement section with `[enforced]` tags for the dispatch + re-work guards and `[hook-driven]` for orphan detection; bump any advisory-count ceiling the test asserts. Run it to confirm FAIL.

- [ ] **Step 2: Add the `RULES.md` section** — a new numbered section "Conductor Enforcement" with tier-tagged bullets: dispatch guard `[enforced]` (`conductor-dispatch-guard.sh`, fails closed), re-work guard `[enforced]` (`conductor-rework-guard.sh`), orphan detection `[hook-driven]` (`subagent-stop.sh`), team routing `[hook-driven]`, digest `[advisory]`. Cross-reference the two unconditional hard stops.

- [ ] **Step 3: Update `CLAUDE.md`** — add `scripts/conductor-dispatch-guard.sh` and `scripts/conductor-rework-guard.sh` to the directory-structure block with one-line descriptions.

- [ ] **Step 4: Update `docs/loop-engineering.md`** — describe that conductor dispatch is now mechanically enforced (synchronous, no re-dispatch, "completed = cached, never re-executed") and that parallel mutating waves use team-orchestrator. Add a short subsection contrasting Nazgul's durable conductor with native dynamic Workflows: recommend Workflows for one-off single-session fan-outs (audits, migrations, `/deep-research`-style research), and state why the conductor isn't built on them (no cross-session recovery, no HITL, main-session-only tool, not plugin-shippable). Note the deferred "Review Board robustness" follow-up (unverified ≠ refuted; adversarial cross-check) as future work, not part of this release.

- [ ] **Step 5: Version bump** — `.claude-plugin/plugin.json` `version` → `2.10.0`; README version badge → `2.10.0`; add a `CHANGELOG.md` `## 2.10.0` section summarizing the five layers + config bump.

- [ ] **Step 6: Full suite + lint**

Run: `bash tests/run-tests.sh`
Expected: ALL green (incl. `test-rules-tiers`, `test-shellcheck`). Then `shellcheck scripts/conductor-*.sh` clean.

- [ ] **Step 7: Commit + open PR**

```bash
git add RULES.md CLAUDE.md docs/loop-engineering.md CHANGELOG.md README.md .claude-plugin/plugin.json tests/test-rules-tiers.sh
git commit -m "docs(conductor): enforcement tiers + roster + release 2.10.0"
git push -u origin feat/conductor-enforcement
gh pr create --base main --head feat/conductor-enforcement \
  --title "Enforced Conductor — mechanical dispatch guards (v2.10.0)" \
  --body "Fixes the FEAT-007 conductor double-dispatch/orphan defect with five mechanical enforcement layers. See docs/superpowers/specs/2026-07-08-conductor-enforcement-design.md."
```

---

## Self-Review

**Spec coverage:** L1 ceiling → Task 2; L2 floor → Task 3; L3 detection → Task 4; L4 routing → Task 5; L5 digest → Task 6; `NAZGUL_UNIT` contract + `.session` marker → Task 6; `conductor.enforce` config + v19→v20 → Task 1; feasibility gate → Task 0; docs/tiers/release → Task 7. All spec sections mapped.

**Placeholder scan:** guard scripts, migration, digest, router change, and orphan detector are given as complete code; tests are complete. Task 5 Step 3 and Task 6 Step 4 include a "thread the arg / edit the prose" instruction with the exact target — acceptable (prose + caller wiring the implementer inspects in-file), not a code placeholder.

**Type consistency:** `route_backend` third arg (`group`: `parallel|single`) consistent between Task 5 test and impl; `NAZGUL_UNIT: TASK-NNN` marker string identical in Task 2 guard, Task 6 prose, and tests; `.resume-needed`, `.session`, `graph.json` `.tasks[id].{status,commit_sha,file_scope,dispatched,wave}` field names consistent across Tasks 2/3/4/6; `conductor.enforce.{dispatch_guard,rework_guard}` consistent across Tasks 1/2/3.

**Open risk carried from spec:** Task 0 gates everything; if it fails, Tasks 2–3 escalate to SubagentStop enforcement.
