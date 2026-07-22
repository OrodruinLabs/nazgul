# Teammate Report Contract + TeammateIdle Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a teammate agent's report a mechanically-enforced file deliverable so the lead never has to nudge an idle teammate for its results.

**Architecture:** Three backstopping layers: (1) a prompt-contract partial naming an explicit report file path in every teammate dispatch, (2) a per-teammate dispatch manifest (`nazgul/dispatch/<name>.json`) recording the expected deliverable, (3) a new `TeammateIdle` hook guard that blocks idling (≤3 times, then fail-open) while the report file is missing. Completion signal becomes "idle notification + report file on disk"; SendMessage is optional courtesy.

**Tech Stack:** Bash (POSIX-safe, `set -euo pipefail`), `jq`, Claude Code hooks (`TeammateIdle` event), existing Nazgul test harness (`tests/lib/assertions.sh`, `tests/lib/setup.sh`).

**Spec:** `docs/superpowers/specs/2026-07-22-teammate-report-contract-design.md`

## Global Constraints

- Release: MINOR, v2.16.0 → **v2.17.0** (plugin.json + README badge + CHANGELOG all bumped in this PR)
- Config schema: v26 → **v27** (template `schema_version`, `migrate-config.sh` `migrate_26_to_27`)
- Kill-switch key: `execution.enforce.teammate_report_guard` (default `true`; explicit `false` disables; absent = enabled)
- Guard exit codes: `0` = allow idle, `2` = block (reason on stderr) — same convention as all Nazgul PreToolUse guards
- Guard fails **OPEN** on unparseable payload / missing name / no manifest / stale `feat_id` (deliberate inversion of the PreToolUse guards' fail-closed rule — blocking on garbage strands teammates; documented in spec Error handling)
- Block backstop: at most **3** blocks per teammate manifest, then allow + escalation log line
- All shell must pass `bash -n` and `shellcheck`; quote all variables; `jq` for JSON (never sed/grep on JSON)
- All work on branch `feat/teammate-report-contract`, PR to `main`, never commit to `main` directly
- Default branch is `main` in all references
- Spec + plan files (`docs/superpowers/**`) stay **uncommitted** (user preference — do not `git add` them)

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/teammate-idle-guard.sh` | Create | TeammateIdle hook: telemetry + report-file enforcement |
| `tests/test-teammate-idle-guard.sh` | Create | Unit tests for the guard |
| `hooks/hooks.json` | Modify | Wire `TeammateIdle` event |
| `templates/config.json` | Modify | `enforce.teammate_report_guard: true`, `schema_version: 27` |
| `scripts/migrate-config.sh` | Modify | `migrate_26_to_27` |
| `tests/test-migrate-config.sh` | Modify | v27 migration assertions |
| `templates/skill-partials/report-contract.md` | Create | Canonical report-contract prompt text |
| `agents/team-orchestrator.md` | Modify | Explicit dispatch-manifest lifecycle, inline contract |
| `scripts/stop-hook.sh` | Modify | Report-contract line in parallel-batch `DISPATCH_INSTR` |
| `tests/test-stop-hook-parallel-batch.sh` (or nearest existing stop-hook parallel test) | Modify | Assert contract line present in batch dispatch text |
| `RULES.md` | Modify | New §"Teammate Report Contract"; fix stale §3.9 claim |
| `CHANGELOG.md`, `.claude-plugin/plugin.json`, `README.md` | Modify | v2.17.0 release notes + version bump |

---

### Task 1: TeammateIdle guard script

**Files:**
- Create: `scripts/teammate-idle-guard.sh`
- Test: `tests/test-teammate-idle-guard.sh`

**Interfaces:**
- Consumes: hook payload JSON on stdin (fields observed live: `type`, `from`, `timestamp`, `idleReason`, optional `summary`; hook payloads may instead carry `teammate_name`/`name`/`agent_id` — resolver tries all)
- Consumes: `nazgul/dispatch/<name>.json` manifest: `{teammate, report_path, feat_id, spawned_at, spawned_at_epoch, blocks, delivered?}`
- Consumes: `nazgul/config.json` → `.execution.enforce.teammate_report_guard`, `.feat_id`
- Produces: exit 0/2; updated manifest (`blocks` increment or `delivered: true`); append-only `nazgul/logs/teammate-idle.jsonl`

- [ ] **Step 1: Write the failing test**

Create `tests/test-teammate-idle-guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-teammate-idle-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/teammate-idle-guard.sh"

setup() {
  setup_temp_dir
  mkdir -p "$TEST_DIR/nazgul/dispatch" "$TEST_DIR/nazgul/logs" "$TEST_DIR/nazgul/reviews/TASK-001"
  create_config '.feat_id = "FEAT-013"'
}
teardown() { teardown_temp_dir; }

# helper: write a dispatch manifest
# usage: make_manifest <name> <report_path> <feat_id> <blocks>
make_manifest() {
  jq -n --arg t "$1" --arg rp "$2" --arg f "$3" --argjson b "$4" \
    --arg sa "2026-07-22T00:00:00Z" --argjson sae 0 \
    '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:$b}' \
    > "$TEST_DIR/nazgul/dispatch/$1.json"
}

# helper: run guard with a payload naming teammate $1; echo exit code
guard_ec() {
  local ec=0
  jq -n --arg n "$1" '{type:"idle_notification", from:$n, idleReason:"available"}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup

# 1. report file present and non-empty -> ALLOW, manifest marked delivered
make_manifest "rev-a" "nazgul/reviews/TASK-001/rev-a.md" "FEAT-013" 0
echo "# review: APPROVED" > "$TEST_DIR/nazgul/reviews/TASK-001/rev-a.md"
assert_eq "report present allowed" "$(guard_ec rev-a)" "0"
assert_eq "manifest marked delivered" \
  "$(jq -r '.delivered' "$TEST_DIR/nazgul/dispatch/rev-a.json")" "true"

# 2. report missing -> BLOCK (exit 2), blocks incremented, reason names path
make_manifest "rev-b" "nazgul/reviews/TASK-001/rev-b.md" "FEAT-013" 0
assert_eq "report missing blocked" "$(guard_ec rev-b)" "2"
assert_eq "blocks incremented" \
  "$(jq -r '.blocks' "$TEST_DIR/nazgul/dispatch/rev-b.json")" "1"
ERR=$(jq -n '{from:"rev-b"}' | bash "$GUARD" 2>&1 >/dev/null || true)
assert_contains "reason names report path" "$ERR" "nazgul/reviews/TASK-001/rev-b.md"

# 3. empty report file counts as missing -> BLOCK
make_manifest "rev-empty" "nazgul/reviews/TASK-001/rev-empty.md" "FEAT-013" 0
: > "$TEST_DIR/nazgul/reviews/TASK-001/rev-empty.md"
assert_eq "empty report blocked" "$(guard_ec rev-empty)" "2"

# 4. blocks already at 3 -> ALLOW (backstop) + escalation logged
make_manifest "rev-c" "nazgul/reviews/TASK-001/rev-c.md" "FEAT-013" 3
assert_eq "backstop after 3 blocks allows" "$(guard_ec rev-c)" "0"
assert_contains "escalation logged" \
  "$(cat "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")" "escalation"

# 5. malformed payload -> ALLOW (fail open)
EC=0; printf 'not json at all' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "malformed payload allowed" "$EC" "0"

# 6. payload with no resolvable name -> ALLOW
EC=0; jq -n '{type:"idle_notification"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "nameless payload allowed" "$EC" "0"

# 7. foreign teammate (no manifest) -> ALLOW
assert_eq "no manifest allowed" "$(guard_ec unknown-teammate)" "0"

# 8. stale feat_id -> ALLOW even though report missing
make_manifest "rev-old" "nazgul/reviews/TASK-001/rev-old.md" "FEAT-001" 0
assert_eq "stale feat_id allowed" "$(guard_ec rev-old)" "0"

# 9. kill-switch off -> ALLOW even though report missing
create_config '.feat_id = "FEAT-013"' '.execution.enforce.teammate_report_guard = false'
make_manifest "rev-d" "nazgul/reviews/TASK-001/rev-d.md" "FEAT-013" 0
assert_eq "kill-switch disables guard" "$(guard_ec rev-d)" "0"
create_config '.feat_id = "FEAT-013"'

# 10. every invocation appends telemetry (count lines grew)
LINES_BEFORE=$(wc -l < "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
guard_ec rev-a >/dev/null
LINES_AFTER=$(wc -l < "$TEST_DIR/nazgul/logs/teammate-idle.jsonl")
assert_eq "telemetry appended" "$((LINES_AFTER > LINES_BEFORE))" "1"

# 11. alternate payload field names resolve (teammate_name)
make_manifest "rev-e" "nazgul/reviews/TASK-001/rev-e.md" "FEAT-013" 0
EC=0; jq -n '{teammate_name:"rev-e"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "teammate_name field resolves (blocks: missing report)" "$EC" "2"

# 12. no nazgul dir at all -> ALLOW (not a Nazgul project)
rm -rf "$TEST_DIR/nazgul"
EC=0; jq -n '{from:"rev-a"}' | bash "$GUARD" >/dev/null 2>&1 || EC=$?
assert_eq "no nazgul dir allowed" "$EC" "0"

teardown
report_results
```

Note: check `tests/lib/assertions.sh` for the results function name — the
existing suite ends with `report_results` (see `tests/test-migrate-config.sh`
last line). If assertions.sh names it differently, match the existing name.

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test-teammate-idle-guard.sh && tests/run-tests.sh --filter=teammate-idle-guard`
Expected: FAIL — guard script does not exist yet (`bash: .../teammate-idle-guard.sh: No such file`).

- [ ] **Step 3: Write the guard**

Create `scripts/teammate-idle-guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Nazgul Teammate Idle Guard — TeammateIdle hook.
# Enforces the teammate report contract: a Nazgul-dispatched teammate may not
# go idle while its expected report file (recorded in nazgul/dispatch/<name>.json
# by the dispatcher) is missing or empty. Blocks at most 3 times per teammate,
# then fails open with an escalation log line — never deadlocks a team.
# Deliberately fails OPEN on unparseable payloads / unknown teammates (the
# TeammateIdle payload schema is not fully documented; blocking on garbage
# would strand teammates). Exit 0 = allow idle. Exit 2 = block (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
NAZGUL_DIR="$PROJECT_DIR/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
DISPATCH_DIR="$NAZGUL_DIR/dispatch"
LOG_DIR="$NAZGUL_DIR/logs"
LOG_FILE="$LOG_DIR/teammate-idle.jsonl"

# Not a Nazgul project → allow.
[ -f "$CONFIG" ] || exit 0

# Telemetry first: append the raw payload (compacted) regardless of outcome.
# Doubles as ongoing TeammateIdle schema discovery. Never fails the guard.
log_event() { # <status> [detail]
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg st "$1" \
    --arg detail "${2:-}" --argjson payload "$PAYLOAD_JSON" \
    '{ts:$ts, status:$st, detail:$detail, payload:$payload}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Parse payload; unparseable → fail open (log with payload as a string).
if PAYLOAD_JSON=$(printf '%s' "$INPUT" | jq -c '.' 2>/dev/null); then :; else
  PAYLOAD_JSON=$(jq -cn --arg raw "$INPUT" '{unparseable:$raw}')
  log_event "allow" "unparseable payload"
  exit 0
fi

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.teammate_report_guard == null then "true" else (.execution.enforce.teammate_report_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
if [ "$ENFORCE" = "false" ]; then
  log_event "allow" "kill-switch off"
  exit 0
fi

# Resolve teammate name — the payload schema is not fully documented, so try
# every plausible field. No name → fail open.
NAME=$(printf '%s' "$PAYLOAD_JSON" | jq -r '.teammate_name // .teammate // .from // .name // .agent_id // ""' 2>/dev/null || echo "")
if [ -z "$NAME" ]; then
  log_event "allow" "no teammate name in payload"
  exit 0
fi

# Manifest lookup — no manifest means not a Nazgul-dispatched teammate.
MANIFEST="$DISPATCH_DIR/$NAME.json"
if [ ! -f "$MANIFEST" ]; then
  log_event "allow" "no dispatch manifest for $NAME"
  exit 0
fi

# Stale manifest (different objective) → allow.
CUR_FEAT=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")
MAN_FEAT=$(jq -r '.feat_id // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ -n "$MAN_FEAT" ] && [ "$MAN_FEAT" != "$CUR_FEAT" ]; then
  log_event "allow" "stale feat_id $MAN_FEAT (current $CUR_FEAT)"
  exit 0
fi

REPORT_PATH=$(jq -r '.report_path // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ -z "$REPORT_PATH" ]; then
  log_event "allow" "manifest has no report_path"
  exit 0
fi
REPORT_ABS="$PROJECT_DIR/$REPORT_PATH"

# Delivered: file exists and is non-empty. mtime >= spawned_at_epoch is checked
# best-effort (BSD/GNU stat); on stat failure existence+non-empty wins (open).
if [ -s "$REPORT_ABS" ]; then
  SPAWNED_EPOCH=$(jq -r '.spawned_at_epoch // 0' "$MANIFEST" 2>/dev/null || echo 0)
  case "$SPAWNED_EPOCH" in ''|*[!0-9]*) SPAWNED_EPOCH=0 ;; esac
  MTIME=$(stat -f %m "$REPORT_ABS" 2>/dev/null || stat -c %Y "$REPORT_ABS" 2>/dev/null || echo "")
  if [ -z "$MTIME" ] || [ "$MTIME" -ge "$SPAWNED_EPOCH" ]; then
    tmp=$(mktemp)
    jq '.delivered = true' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
    log_event "allow" "report delivered at $REPORT_PATH"
    exit 0
  fi
  # File predates spawn: treat as missing (falls through to block/backstop).
fi

# Report missing: block up to 3 times, then fail open with escalation.
BLOCKS=$(jq -r '.blocks // 0' "$MANIFEST" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge 3 ]; then
  log_event "allow" "escalation: $NAME idled 3x without report at $REPORT_PATH — giving up (manual nudge required)"
  exit 0
fi
tmp=$(mktemp)
jq '.blocks = ((.blocks // 0) + 1)' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
log_event "block" "report missing at $REPORT_PATH (block $((BLOCKS + 1))/3)"
echo "NAZGUL TEAMMATE REPORT CONTRACT: Your report at ${REPORT_PATH} was not written — your final plain text is invisible to the parent. Write your full report to ${REPORT_PATH} now, then idle." >&2
exit 2
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/teammate-idle-guard.sh && tests/run-tests.sh --filter=teammate-idle-guard`
Expected: PASS, all 12+ assertions green.

- [ ] **Step 5: Lint**

Run: `bash -n scripts/teammate-idle-guard.sh && shellcheck scripts/teammate-idle-guard.sh tests/test-teammate-idle-guard.sh`
Expected: no errors (shellcheck info-level SC1091 for sourced libs is acceptable — matches existing suite).

- [ ] **Step 6: Commit**

```bash
git checkout -b feat/teammate-report-contract
git add scripts/teammate-idle-guard.sh tests/test-teammate-idle-guard.sh
git commit -m "feat(teammate-guard): TeammateIdle guard enforcing the report-file contract"
```

---

### Task 2: Hook wiring + config schema v27

**Files:**
- Modify: `hooks/hooks.json` (after the `SubagentStop` block, ~line 176)
- Modify: `templates/config.json` (`.execution.enforce`, `.schema_version`)
- Modify: `scripts/migrate-config.sh` (add `migrate_26_to_27` after `migrate_25_to_26`, ~line 570)
- Test: `tests/test-migrate-config.sh` (append before `report_results`)

**Interfaces:**
- Consumes: `scripts/teammate-idle-guard.sh` from Task 1
- Produces: `execution.enforce.teammate_report_guard` config key (read by Task 1's guard); schema v27

- [ ] **Step 1: Write the failing migration test**

Append to `tests/test-migrate-config.sh` immediately before the final `report_results` line:

```bash
# --- v26 -> v27: teammate_report_guard added (additive, default true) ---
NAZGUL_DIR=$(setup_nazgul_dir "v26-to-27")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{"schema_version": 26, "execution": {"parallel": true, "enforce": {"dispatch_guard": false}}}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
CFG="$NAZGUL_DIR/config.json"
assert_json_field "v27: schema_version reaches 27" "$CFG" ".schema_version" "27"
assert_eq "v27: teammate_report_guard defaults true" \
  "$(jq -r '.execution.enforce.teammate_report_guard' "$CFG")" "true"
assert_eq "v27: explicit dispatch_guard false preserved" \
  "$(jq -r '.execution.enforce.dispatch_guard' "$CFG")" "false"

# --- v26 -> v27: explicit false preserved ---
NAZGUL_DIR=$(setup_nazgul_dir "v26-to-27-explicit-false")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{"schema_version": 26, "execution": {"enforce": {"teammate_report_guard": false}}}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>/dev/null) || true
CFG="$NAZGUL_DIR/config.json"
assert_eq "v27: explicit teammate_report_guard false preserved" \
  "$(jq -r '.execution.enforce.teammate_report_guard' "$CFG")" "false"

# --- v26 -> v27: non-object execution/enforce clamps instead of erroring ---
NAZGUL_DIR=$(setup_nazgul_dir "v26-to-27-garbage")
cat > "$NAZGUL_DIR/config.json" << 'EOF'
{"schema_version": 26, "execution": "garbage"}
EOF
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$MIGRATE" "$NAZGUL_DIR" 2>&1); MIG_EC=$?
CFG="$NAZGUL_DIR/config.json"
assert_exit_code "v27 garbage execution: migrator exits 0" "$MIG_EC" 0
assert_eq "v27 garbage execution: guard defaults true" \
  "$(jq -r '.execution.enforce.teammate_report_guard' "$CFG")" "true"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=migrate-config`
Expected: FAIL — v27 assertions fail (template still 26, no `migrate_26_to_27`; migrator reports "already up to date" so schema stays 26).

- [ ] **Step 3: Implement config + migration**

`templates/config.json` — two edits:
- `"schema_version": 26` → `"schema_version": 27`
- In `.execution.enforce`, after `"premerge_guard": true` add `"teammate_report_guard": true`:

```json
  "enforce": {
    "dispatch_guard": true,
    "rework_guard": true,
    "premerge_guard": true,
    "teammate_report_guard": true
  }
```

`scripts/migrate-config.sh` — add after `migrate_25_to_26` (before the `# --- Run incremental migrations ---` section):

```bash
migrate_26_to_27() {
  local tmp; tmp=$(mktemp)
  # Teammate Report Contract: additive kill-switch for the TeammateIdle guard.
  # Explicit values (incl. false) preserved; non-object execution/enforce clamped.
  jq '
    .execution = ((if (.execution | type) == "object" then .execution else {} end)
      | .enforce = ((if (.enforce | type) == "object" then .enforce else {} end)
          | .teammate_report_guard = (if has("teammate_report_guard") then .teammate_report_guard else true end)))
    | .schema_version = 27
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  log_migration "v26→v27: added execution.enforce.teammate_report_guard:true (additive; explicit false preserved) — TeammateIdle report-contract guard kill-switch"
}
```

`hooks/hooks.json` — add after the `SubagentStop` block (keep `UserPromptSubmit` last):

```json
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/teammate-idle-guard.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
```

Also update the top-level `"description"` field to append `, teammate report contract enforcement`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/run-tests.sh --filter=migrate-config && jq empty hooks/hooks.json && jq empty templates/config.json`
Expected: migration test PASS; both `jq empty` calls silent (valid JSON).

- [ ] **Step 5: Run the full suite (wiring can break other config-reading tests)**

Run: `tests/run-tests.sh`
Expected: all PASS. If any test asserts on the hooks.json event list or template key set, update it to include the new entries.

- [ ] **Step 6: Commit**

```bash
git add hooks/hooks.json templates/config.json scripts/migrate-config.sh tests/test-migrate-config.sh
git commit -m "feat(teammate-guard): wire TeammateIdle hook + config schema v27 kill-switch"
```

---

### Task 3: Report-contract partial + dispatcher spec updates

**Files:**
- Create: `templates/skill-partials/report-contract.md`
- Modify: `agents/team-orchestrator.md` (steps 4–7 of review team, 6–9 of impl team, Inter-Agent Communication section; also delete the duplicated `### Discovery` line at :107)
- Modify: `scripts/stop-hook.sh:1164-1170` (parallel-batch `DISPATCH_INSTR`)
- Test: existing stop-hook parallel-batch test (find with `grep -rln "DELEGATE (PARALLEL BATCH" tests/`)

**Interfaces:**
- Consumes: manifest schema from Task 1 (`{teammate, report_path, feat_id, spawned_at, spawned_at_epoch, blocks}`)
- Produces: dispatch prompts that name a report path; manifests the Task 1 guard reads

- [ ] **Step 1: Create the canonical partial**

Create `templates/skill-partials/report-contract.md`:

```markdown
## Report Contract (teammate dispatch)

Include this block verbatim at the END of every teammate prompt, substituting `<REPORT_PATH>`:

> REPORT CONTRACT: Your final plain text is NOT delivered to anyone. Your LAST
> action MUST be writing your complete report to `<REPORT_PATH>` (create parent
> directories if needed). Do not idle before that file exists. Optionally, you
> may ALSO SendMessage a one-line completion summary to your team lead — but
> the file is the deliverable, the message is courtesy.

Before spawning the teammate, write its dispatch manifest so the TeammateIdle
guard can enforce the contract:

```bash
mkdir -p nazgul/dispatch
jq -n --arg t "<teammate-session-name>" --arg rp "<REPORT_PATH>" \
  --arg f "$(jq -r '.feat_id // "default"' nazgul/config.json)" \
  --arg sa "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson sae "$(date +%s)" \
  '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:0}' \
  > "nazgul/dispatch/<teammate-session-name>.json"
```

Completion signal = idle notification + report file on disk. Read the report
from the file; never wait for a message. Delete `nazgul/dispatch/*.json` at
team teardown.
```

- [ ] **Step 2: Rewrite team-orchestrator.md completion semantics**

In `agents/team-orchestrator.md`:

(a) Review-team section — replace steps 4–7:

```markdown
4. For each reviewer teammate, BEFORE spawning: write its dispatch manifest per
   the Report Contract (`templates/skill-partials/report-contract.md`) with
   `report_path: nazgul/reviews/[TASK-ID]/[reviewer-name].md`.
5. Spawn a team with one teammate per reviewer:
   - Team name: `nazgul-review-[TASK-ID]`
   - Session naming: name each teammate session as `nazgul-[reviewer-name]-[TASK-ID]` using the `-n` flag — the dispatch manifest filename MUST match this session name exactly
   - Each teammate gets: their agent definition, the diff file path (`nazgul/reviews/[TASK-ID]/diff.patch`), the file list, relevant context paths
   - Instruct each teammate: "Read diff.patch FIRST to understand what changed, then read full files only for additional context"
   - END each teammate prompt with the Report Contract block, `<REPORT_PATH>` = `nazgul/reviews/[TASK-ID]/[reviewer-name].md`
6. Completion signal = idle notification + report file on disk. When a teammate
   idles, read its report file. A teammate idling without its file is blocked
   automatically by the TeammateIdle guard (≤3 times); if it still arrives
   file-less (guard escalated), nudge it once via SendMessage, then mark the
   review UNVERIFIED if it never lands.
7. Clean up the team AND delete `nazgul/dispatch/*.json` manifests for this team.
```

(b) Implementation-team section — same treatment for steps 6–10: manifest before
spawn with `report_path` = the task manifest `nazgul/tasks/TASK-NNN.md` (the
implementer's deliverable is its Status/Commits update there — no separate
report file); append the Report Contract block with that path; completion =
idle + manifest shows IMPLEMENTED/BLOCKED with commit SHA; cleanup deletes
dispatch manifests.

(c) Replace the `## Inter-Agent Communication` paragraph's last line
("Prefer SendMessage over file-based coordination…") with:

```markdown
SendMessage is for coordination signals only (merge results, conflict alerts,
wave completion). It is NEVER the delivery channel for a report — reports are
files, per the Report Contract. Final plain text of a teammate is delivered to
no one; do not rely on it.
```

(d) Delete the stray duplicated line 107 (`### Discovery: ONLY for large codebases (500+ files)` appears twice).

- [ ] **Step 3: Add the contract line to the stop-hook batch dispatch**

In `scripts/stop-hook.sh`, inside `DISPATCH_INSTR` (line 1166, step 1 of the
batch instructions), append to the end of the step-1 sentence, after
"NEVER in the shared working tree.":

```
 If dispatching implementers as TEAMMATES (not foreground Agent calls): first write nazgul/dispatch/<session-name>.json per templates/skill-partials/report-contract.md with report_path nazgul/tasks/<id>.md, and END each prompt with the Report Contract block — a teammate's final text is delivered to NO ONE.
```

(One line, no newline inside the shell string — keep the heredoc-safe single-line form used by the surrounding text.)

- [ ] **Step 4: Extend the stop-hook batch test**

Find the existing parallel-batch dispatch-text test: `grep -rln "PARALLEL BATCH" tests/`. In that test file, after the existing assertion that the batch text contains "DELEGATE (PARALLEL BATCH", add:

```bash
assert_contains "batch dispatch carries report contract" "$OUTPUT" "Report Contract"
```

(Adapt variable name to whatever the surrounding assertions capture the stop-hook stderr into — match the neighboring assertion exactly.)

- [ ] **Step 5: Run tests + lint**

Run: `bash -n scripts/stop-hook.sh && shellcheck scripts/stop-hook.sh && tests/run-tests.sh`
Expected: all PASS (stop-hook tests see the new contract line; nothing else changed behaviorally).

- [ ] **Step 6: Commit**

```bash
git add templates/skill-partials/report-contract.md agents/team-orchestrator.md scripts/stop-hook.sh tests/
git commit -m "feat(teammate-guard): report-contract partial + dispatcher lifecycle in team-orchestrator and batch dispatch"
```

---

### Task 4: Docs + release (RULES.md, CHANGELOG, version v2.17.0)

**Files:**
- Modify: `RULES.md` (new section after §12/§13 area covering parallel guards; fix §3.9)
- Modify: `CHANGELOG.md` (new `[2.17.0]` section at top)
- Modify: `.claude-plugin/plugin.json` (`"version": "2.17.0"`)
- Modify: `README.md:13` (badge `version-2.17.0-blue`)

**Interfaces:**
- Consumes: everything shipped in Tasks 1–3 (names must match exactly: `teammate-idle-guard.sh`, `execution.enforce.teammate_report_guard`, `nazgul/dispatch/<name>.json`, `nazgul/logs/teammate-idle.jsonl`, `templates/skill-partials/report-contract.md`)

- [ ] **Step 1: RULES.md — new section**

Add a new numbered top-level section (next free number after the existing last section — check `grep -n "^## " RULES.md | tail -3`):

```markdown
## §N. Teammate Report Contract

In Agent Teams mode a teammate's final plain text is delivered to NO ONE —
SendMessage is the only live channel, and nothing platform-side forces a
teammate to use it. Nazgul therefore defines a teammate's deliverable as a
FILE, enforced in three layers:

1. **Prompt contract** `[advisory]` — every teammate dispatch ends with the
   Report Contract block (`templates/skill-partials/report-contract.md`)
   naming an explicit `report_path`.
2. **Dispatch manifest** `[advisory]` — before spawning, the dispatcher writes
   `nazgul/dispatch/<session-name>.json` (`teammate`, `report_path`, `feat_id`,
   `spawned_at`, `spawned_at_epoch`, `blocks`). Deleted at team teardown.
3. **TeammateIdle guard** `[enforced]` — `scripts/teammate-idle-guard.sh`
   blocks a manifest-registered teammate from idling while its `report_path`
   is missing/empty (exit 2 with the fix instruction), at most 3 times per
   teammate, then fails open with an escalation line in
   `nazgul/logs/teammate-idle.jsonl` (which also records every raw payload as
   schema telemetry). Fails OPEN on unparseable payloads, unknown teammates,
   and stale `feat_id` — a deliberate inversion of the PreToolUse guards'
   fail-closed rule, because blocking on garbage strands live teammates.
   Kill-switch: `execution.enforce.teammate_report_guard` (default `true`).

Completion signal = idle notification + report file on disk. SendMessage is
coordination-only courtesy, never the report channel.
```

- [ ] **Step 2: RULES.md — fix the stale §3.9 claim**

In §3.9, replace the final sentence:

Old: `Subagent **dispatch** itself cannot be pre-gated (no PreToolUse matcher for the Task tool), so completion-gate enforcement is the available mechanism.`

New: `Subagent dispatch CAN now be pre-gated — a PreToolUse matcher on the Agent tool exists and is in production use by parallel-dispatch-guard.sh (§12) — but granularity enforcement deliberately remains at the completion gate: the wrong-scope review is only knowable after the review ran.`

- [ ] **Step 3: CHANGELOG + version bump**

`CHANGELOG.md` — insert at top (below the header lines, above `## [2.16.0]`):

```markdown
## [2.17.0] - 2026-07-22

### Added
- **Teammate Report Contract (3 layers).** In Agent Teams mode a teammate's
  final text is delivered to no one, so teammates finished work then idled
  without reporting, forcing a manual nudge per agent. Now: every teammate
  dispatch ends with a Report Contract block naming an explicit report file
  (`templates/skill-partials/report-contract.md`); dispatchers register the
  expected deliverable in `nazgul/dispatch/<session-name>.json`; and a new
  `TeammateIdle` hook guard (`scripts/teammate-idle-guard.sh`) blocks a
  registered teammate from idling while its report file is missing — bounded
  (≤3 blocks then fail-open escalation), fail-open on unknown payloads, and
  kill-switchable via `execution.enforce.teammate_report_guard` (config
  schema v26 → v27, additive). Completion signal is now idle notification +
  report file on disk; SendMessage is coordination-only courtesy.
- Telemetry: every TeammateIdle payload is appended to
  `nazgul/logs/teammate-idle.jsonl` (ongoing payload-schema discovery).

### Changed
- `agents/team-orchestrator.md`: explicit dispatch-manifest lifecycle
  (manifest before spawn → contract block in prompt → idle+file = complete →
  teardown deletes manifests); "signal completion to the caller" vagueness
  removed.
- `scripts/stop-hook.sh` parallel-batch dispatch: carries the Report Contract
  instruction for teammate-dispatched implementers.
- RULES.md §3.9: corrected the stale claim that subagent dispatch cannot be
  pre-gated (the PreToolUse `Agent` matcher exists and is in use).
```

`.claude-plugin/plugin.json`: `"version": "2.16.0"` → `"version": "2.17.0"`.
`README.md:13`: `version-2.16.0-blue` → `version-2.17.0-blue`.

- [ ] **Step 4: Full suite + docs freshness**

Run: `tests/run-tests.sh && ./scripts/gen-skill-docs.sh --check 2>/dev/null || true`
Expected: all tests PASS. (gen-skill-docs check only matters if a SKILL.md.tmpl references the new partial — none do in this plan; the partial is agent/dispatcher-facing.)

- [ ] **Step 5: Commit**

```bash
git add RULES.md CHANGELOG.md .claude-plugin/plugin.json README.md
git commit -m "docs(teammate-guard): RULES §Teammate Report Contract, §3.9 correction, v2.17.0"
```

---

### Task 5: PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin feat/teammate-report-contract
gh pr create --base main --title "Teammate Report Contract: file-deliverable reports + TeammateIdle guard (v2.17.0)" --body "$(cat <<'EOF'
## Summary
- Teammate final text is delivered to no one in Agent Teams mode → teammates idled without reporting, needing a manual nudge each (observed live in FEAT-012 post-loop and reproduced twice during design research).
- Fix: 3-layer Teammate Report Contract — prompt contract block naming a report file, per-teammate dispatch manifest (nazgul/dispatch/<name>.json), and a new TeammateIdle hook guard that blocks idle while the report file is missing (≤3 blocks, fail-open, kill-switch execution.enforce.teammate_report_guard, schema v26→v27).
- Completion signal = idle notification + report file on disk; SendMessage demoted to coordination-only courtesy.

## Test plan
- [ ] tests/run-tests.sh — new test-teammate-idle-guard.sh (12 cases) + v27 migration cases + batch-dispatch contract-line assertion
- [ ] bash -n + shellcheck clean on new/modified scripts

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR opens against `main`; branch protection requires the user's approving review (BLOCKED/REVIEW_REQUIRED until then is normal, not CI failure).

- [ ] **Step 2: After user approves + merge — tag**

```bash
git checkout main && git pull && git tag v2.17.0 && git push origin v2.17.0
```
