#!/usr/bin/env bash
set -euo pipefail

# Nazgul headless smoke (FEAT-028 / TRD §7, PRD AC8).
#
# Two scenarios over the TRUE entry paths — a `claude -p "/nazgul:heartbeat"`
# tick and a bounded AFK loop dry-run — because unit stubs structurally cannot
# see hook ordering or session identity (the S5 heartbeat self-block was
# invisible to a green suite for exactly that reason).
#
# Costs money and minutes: manual/nightly only (.github/workflows/smoke.yml).
# NEVER in test.yml, never in the per-task loop, never a task-transition gate.
# Every scenario builds its own scratch project under $TMPDIR and refuses to run
# against this repository's own nazgul/ state.
#
# Usage: tests/smoke/run-smoke.sh [--filter=<scenario>] [--inbox-dir=<dir>]
#                                 [--timeout=<seconds>] [--keep]
#
# Exit codes:
#   0  every scenario that ran passed
#   1  at least one scenario reported a finding
#   2  NOTHING CHECKED — the filter matched no scenario, or the claude CLI is
#      absent so no scenario could run (a smoke that verified nothing is not a
#      pass; the workflow that installs the CLI must hear about it)
#   3  internal coverage-accounting defect (scanned != skipped + checked)

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
# Conditional: sourcing this file from a test that already loaded the library
# would re-zero TESTS_RUN/TESTS_FAILED and erase that test's verdict.
if ! declare -F _pass >/dev/null 2>&1; then
  # shellcheck source=../lib/assertions.sh
  source "$REPO_ROOT/tests/lib/assertions.sh"
fi

SMOKE_SCENARIOS="heartbeat loop"

_smoke_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

_smoke_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"
  fi
}

# smoke_scratch_project <dest> [jq-override ...] -> git repo + generated nazgul/ +
# a config DERIVED from templates/config.json + plugin symlinks. <dest> inside this repo is refused.
smoke_scratch_project() {
  local dest="$1"; shift
  local resolved parent candidate d override
  parent=$(dirname "$dest")
  if [ -d "$parent" ]; then
    candidate="$(cd "$parent" && pwd)/$(basename "$dest")"
    case "$candidate/" in
      "$REPO_ROOT"/*)
        printf 'run-smoke: refusing to build a scratch project inside %s\n' "$REPO_ROOT" >&2
        return 1
        ;;
    esac
  fi
  mkdir -p "$dest"
  resolved="$(cd "$dest" && pwd)"
  case "$resolved/" in
    "$REPO_ROOT"/*)
      printf 'run-smoke: refusing to build a scratch project inside %s\n' "$REPO_ROOT" >&2
      return 1
      ;;
  esac

  git -C "$resolved" init -q
  git -C "$resolved" config user.email "smoke@nazgul.dev"
  git -C "$resolved" config user.name "Nazgul Smoke"
  printf '# smoke scratch project\n' > "$resolved/README.md"
  git -C "$resolved" add README.md
  git -C "$resolved" commit -q -m "initial commit"

  mkdir -p "$resolved/nazgul/logs" "$resolved/nazgul/checkpoints" "$resolved/nazgul/sessions" \
    "$resolved/nazgul/tasks" "$resolved/nazgul/reviews" "$resolved/nazgul/inbox/archive" "$resolved/.smoke"
  cat > "$resolved/nazgul/plan.md" <<'PLAN'
---
feat_id: SMOKE-000
---
# Plan — headless smoke scratch project

## Objective

This project exists only for one bounded smoke run.

## Tasks

| ID | Title | Depends on | Wave | Status |
|----|-------|-----------|------|--------|
| (none yet — the loop plans its own) | | | | |

## Recovery Pointer

- **Current iteration**: 0
- **Current Task:** none
- **Next Action:** plan the objective named in `nazgul/config.json`.
PLAN
  cat > "$resolved/nazgul/inbox/0001-smoke-objective.md" <<'INBOX'
---
title: "Add a LICENSE file naming the MIT license"
priority: 2
type: feature
source: "tests/smoke/run-smoke.sh"
---

## What

Add a top-level `LICENSE` file containing the MIT license text.
INBOX
  cp "$REPO_ROOT/templates/config.json" "$resolved/nazgul/config.json"
  for override in "$@"; do
    jq "$override" "$resolved/nazgul/config.json" > "$resolved/nazgul/config.json.tmp" \
      && mv "$resolved/nazgul/config.json.tmp" "$resolved/nazgul/config.json"
  done

  for d in scripts skills agents hooks templates references; do
    ln -s "$REPO_ROOT/$d" "$resolved/$d"
  done
}

# smoke_file_failure_item <inbox_dir> <scenario> <detail> -> file the p1 failure item.
# Frontmatter keys are the ones inbox-provider.sh parses; p1 so triage picks it first.
smoke_file_failure_item() {
  local inbox_dir="$1" scenario="$2" detail="$3" stamp file
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  file="$inbox_dir/smoke-failure-${scenario}-${stamp}.md"
  mkdir -p "$inbox_dir" || return 1
  {
    printf -- '---\n'
    printf 'title: Headless smoke failed — scenario %s\n' "$scenario"
    printf 'priority: 1\n'
    printf 'type: smoke-failure\n'
    printf 'source: tests/smoke/run-smoke.sh\n'
    printf -- '---\n'
    printf '%s\n' "$detail"
  } > "$file" || return 1
  printf '%s\n' "$file"
}

# _smoke_claude <project_dir> <prompt> <max_turns> <timeout_s> <out_file> -> one headless
# session FROM <project_dir>. A timeout/nonzero exit is a fact the assertions judge, not an abort.
_smoke_claude() {
  local dir="$1" prompt="$2" turns="$3" secs="$4" out="$5" tcmd rc=0
  tcmd=$(_smoke_timeout_cmd)
  printf '[smoke] claude -p "%s" (cwd=%s, max-turns=%s, timeout=%ss)\n' "$prompt" "$dir" "$turns" "$secs" >&2
  if [ -z "$tcmd" ]; then
    printf '[smoke] WARNING: no timeout/gtimeout on PATH — running unbounded\n' >&2
    (cd "$dir" && claude -p "$prompt" --output-format text --max-turns "$turns") > "$out" 2>&1 || rc=$?
  else
    (cd "$dir" && "$tcmd" "$secs" claude -p "$prompt" --output-format text --max-turns "$turns") > "$out" 2>&1 || rc=$?
  fi
  printf '%s' "$rc"
}

# Scenario A — heartbeat tick on the true entry path.
scenario_heartbeat() {
  local proj="$1" timeout_s="$2" out heartbeat_rc records rec decision reason session_active archived live starts
  smoke_scratch_project "$proj" \
    '.mode = "afk"' \
    '.automation.heartbeat.enabled = true' \
    '.objective = null' || return 1

  # The tick's auto-start is redirected to a recording stub: a smoke run must
  # observe the DECISION, never launch a real objective.
  cat > "$proj/.smoke/start-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/start-invocations.log"
STUB
  chmod +x "$proj/.smoke/start-stub.sh"

  out="$proj/.smoke/heartbeat-session.log"
  heartbeat_rc=$(NAZGUL_HEARTBEAT_START_CMD="$proj/.smoke/start-stub.sh" \
    _smoke_claude "$proj" "/nazgul:heartbeat" 8 "$timeout_s" "$out")
  assert_exit_code "A: claude heartbeat session exits successfully" "$heartbeat_rc" 0

  records=$(cat "$proj"/nazgul/logs/heartbeat-*.jsonl 2>/dev/null | grep -c '[^[:space:]]' || true)
  assert_eq "A: exactly one decision record appended" "${records:-0}" "1"
  if [ "${records:-0}" -eq 0 ]; then
    _fail "A: the tick produced a decision record to inspect" "no nazgul/logs/heartbeat-*.jsonl content; session log: $out"
    return 0
  fi

  rec=$(cat "$proj"/nazgul/logs/heartbeat-*.jsonl 2>/dev/null | grep '[^[:space:]]' | tail -1)
  decision=$(printf '%s' "$rec" | jq -r '.decision // ""' 2>/dev/null || echo "")
  reason=$(printf '%s' "$rec" | jq -r '.reason // ""' 2>/dev/null || echo "")
  session_active=$(printf '%s' "$rec" | jq -r '.session_active // false' 2>/dev/null || echo "")

  # The S5 defect class: the tick counting its OWN session lock and skipping itself.
  if [ "$decision" = "skipped" ] && [ "$reason" = "active_session" ]; then
    _fail "A: the tick did not self-block on its own session lock (S5)" "decision=$decision reason=$reason record=$rec"
  else
    _pass "A: the tick did not self-block on its own session lock (S5)"
  fi
  assert_eq "A: the tick's own session is not counted as active" "$session_active" "false"

  archived=$(find "$proj/nazgul/inbox/archive" -maxdepth 1 -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null | wc -l | tr -d ' ')
  live=$(find "$proj/nazgul/inbox" -maxdepth 1 -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "A: the claimed item is archived exactly once" "$archived" "1"
  assert_eq "A: no candidate is left live in the inbox" "$live" "0"

  starts=$(grep -c '[^[:space:]]' "$proj/.smoke/start-invocations.log" 2>/dev/null || true)
  assert_eq "A: the auto-start was invoked exactly once" "${starts:-0}" "1"
}

# Scenario B — bounded loop dry-run over the real hook chain.
scenario_loop() {
  local proj="$1" timeout_s="$2" out loop_rc objective checkpoints first_cp session_mtime cp_mtime
  local first_stop_hook events gate_rc gate_events_before gate_events_after
  objective="Add a LICENSE file naming the MIT license"
  smoke_scratch_project "$proj" \
    '.mode = "afk"' \
    '.afk.enabled = true' \
    '.max_iterations = 2' \
    '.current_iteration = 0' || return 1
  jq --arg obj "$objective" '.objective = $obj' "$proj/nazgul/config.json" > "$proj/nazgul/config.json.tmp" \
    && mv "$proj/nazgul/config.json.tmp" "$proj/nazgul/config.json"

  out="$proj/.smoke/loop-session.log"
  loop_rc=$(_smoke_claude "$proj" "/nazgul:start \"$objective\" --afk --max 2" 25 "$timeout_s" "$out")
  assert_exit_code "B: claude bounded-loop session exits successfully" "$loop_rc" 0

  assert_file_exists "B: SessionStart injection persisted the session id" "$proj/nazgul/.session_id"
  if [ -n "$(find "$proj/nazgul/sessions" -maxdepth 1 -name '*.lock' 2>/dev/null)" ]; then
    _pass "B: SessionStart registered a session lock"
  else
    _fail "B: SessionStart registered a session lock" "no nazgul/sessions/*.lock after the run"
  fi

  checkpoints=$(find "$proj/nazgul/checkpoints" -maxdepth 1 -name 'iteration-*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${checkpoints:-0}" -ge 1 ]; then
    _pass "B: the stop-hook ran and wrote a checkpoint"
  else
    _fail "B: the stop-hook ran and wrote a checkpoint" "no nazgul/checkpoints/iteration-*.json; session log: $out"
  fi

  if grep -q '^## Recovery Pointer' "$proj/nazgul/plan.md" 2>/dev/null &&
     awk '/^## Recovery Pointer/{f=1;next} f&&/[^[:space:]]/{found=1;exit} END{exit !found}' "$proj/nazgul/plan.md"; then
    _pass "B: the Recovery Pointer is present and non-empty"
  else
    _fail "B: the Recovery Pointer is present and non-empty" "nazgul/plan.md has no readable Recovery Pointer body"
  fi

  # Ordering is judged against hooks/hooks.json itself, not a copy of it here.
  first_stop_hook=$(jq -r '[.hooks.Stop[].hooks[].command] | first' "$REPO_ROOT/hooks/hooks.json" 2>/dev/null || echo "")
  assert_contains "B: hooks.json declares stop-hook.sh first in the Stop chain" "$first_stop_hook" "stop-hook.sh"
  first_cp=$(find "$proj/nazgul/checkpoints" -maxdepth 1 -type f -name 'iteration-*.json' \
    -print 2>/dev/null | sort | sed -n '1p' || true)
  if [ -f "$proj/nazgul/.session_id" ] && [ -n "$first_cp" ]; then
    session_mtime=$(_smoke_mtime "$proj/nazgul/.session_id")
    cp_mtime=$(_smoke_mtime "$first_cp")
    if [ "$session_mtime" -le "$cp_mtime" ]; then
      _pass "B: observed order matches the declared lifecycle (SessionStart before the Stop chain)"
    else
      _fail "B: observed order matches the declared lifecycle (SessionStart before the Stop chain)" \
        "session id written at $session_mtime, checkpoint at $cp_mtime"
    fi
  else
    echo "  SKIP: B: lifecycle ordering — no session id and checkpoint pair to compare (not checked)"
  fi

  # Only afk_timeout / in_flight_hold / in_flight_stale emit stop_gate (RULES §5). A live session
  # cannot be made to hit one on demand, so the real hook is driven against the state it produced.
  events="$proj/nazgul/logs/events.jsonl"
  gate_events_before=$(grep -c '"stop_gate"' "$events" 2>/dev/null || true)
  jq '.afk.timeout_minutes = 0 | .objective_set_at = "2000-01-01T00:00:00Z"' "$proj/nazgul/config.json" \
    > "$proj/nazgul/config.json.tmp" && mv "$proj/nazgul/config.json.tmp" "$proj/nazgul/config.json"
  gate_rc=0
  (cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$REPO_ROOT/scripts/stop-hook.sh" </dev/null >/dev/null 2>&1) || gate_rc=$?
  gate_events_after=$(grep -c '"stop_gate"' "$events" 2>/dev/null || true)
  if [ "${gate_events_after:-0}" -gt "${gate_events_before:-0}" ]; then
    _pass "B: the AFK gate stop emitted stop_gate rather than exiting bare"
  else
    _fail "B: the AFK gate stop emitted stop_gate rather than exiting bare" \
      "stop-hook exited $gate_rc with no new stop_gate event in $events"
  fi
}

if [ -n "${NAZGUL_SMOKE_SOURCE_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

FILTER=""
INBOX_DIR=""
TIMEOUT_S=600
KEEP=false
for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    --inbox-dir=*) INBOX_DIR="${arg#--inbox-dir=}" ;;
    --timeout=*) TIMEOUT_S="${arg#--timeout=}" ;;
    --keep) KEEP=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "================================"
echo "  Nazgul Headless Smoke"
echo "  WARNING: runs claude -p against"
echo "  scratch projects and costs money."
echo "================================"
echo ""

SCANNED=0
CHECKED=0
SKIP_FILTERED=0
SKIP_NO_CLI=0
FINDINGS=0
CLAUDE_PRESENT=true
command -v claude >/dev/null 2>&1 || CLAUDE_PRESENT=false

SCRATCH_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-smoke-XXXXXX")
cleanup() { [ "$KEEP" = "true" ] || rm -rf "$SCRATCH_ROOT"; }
trap cleanup EXIT

for scenario in $SMOKE_SCENARIOS; do
  SCANNED=$((SCANNED + 1))
  if [ -n "$FILTER" ] && ! grep -qF -e "$FILTER" <<<"$scenario"; then
    SKIP_FILTERED=$((SKIP_FILTERED + 1))
    continue
  fi
  if [ "$CLAUDE_PRESENT" != "true" ]; then
    SKIP_NO_CLI=$((SKIP_NO_CLI + 1))
    echo "  SKIP: $scenario (claude CLI not on PATH — not checked)"
    continue
  fi

  CHECKED=$((CHECKED + 1))
  echo "--- scenario: $scenario ---"
  BEFORE_FAILED=$TESTS_FAILED
  RC=0
  "scenario_$scenario" "$SCRATCH_ROOT/$scenario" "$TIMEOUT_S" || RC=$?
  if [ "$RC" -ne 0 ]; then
    _fail "$scenario: the scenario ran to completion" "scenario driver exited $RC"
  fi
  SCENARIO_FINDINGS=$((TESTS_FAILED - BEFORE_FAILED))
  FINDINGS=$((FINDINGS + SCENARIO_FINDINGS))
  if [ "$SCENARIO_FINDINGS" -gt 0 ] && [ -n "$INBOX_DIR" ]; then
    ITEM=$(smoke_file_failure_item "$INBOX_DIR" "$scenario" \
      "Scenario '$scenario' reported $SCENARIO_FINDINGS finding(s) in tests/smoke/run-smoke.sh. Re-run with --keep and inspect the scratch project's nazgul/ state.") || ITEM=""
    [ -n "$ITEM" ] && echo "  filed p1 inbox item: $ITEM"
  fi
  echo ""
done

SKIPPED=$((SKIP_FILTERED + SKIP_NO_CLI))
emit_coverage_line() {
  printf 'run-smoke: %d scanned, %d skipped (filtered-out=%d, no-claude-cli=%d), %d checked, %d findings\n' \
    "$SCANNED" "$SKIPPED" "$SKIP_FILTERED" "$SKIP_NO_CLI" "$CHECKED" "$FINDINGS"
}

echo "================================"
report_results || true

if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  echo "run-smoke: INTERNAL — coverage accounting mismatch: $SCANNED scanned != $SKIPPED skipped + $CHECKED checked" >&2
  emit_coverage_line
  exit 3
fi

if [ "$CHECKED" -eq 0 ]; then
  if [ "$SKIP_NO_CLI" -gt 0 ]; then
    echo "run-smoke: NOTHING CHECKED — claude CLI absent; no entry path was exercised" >&2
  elif [ -n "$FILTER" ]; then
    echo "run-smoke: NOTHING CHECKED — no scenario matched filter '$FILTER'" >&2
  else
    echo "run-smoke: NOTHING CHECKED — no scenarios are registered" >&2
  fi
  emit_coverage_line
  exit 2
fi

emit_coverage_line
[ "$FINDINGS" -eq 0 ]
