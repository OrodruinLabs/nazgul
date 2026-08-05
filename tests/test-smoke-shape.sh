#!/usr/bin/env bash
set -euo pipefail

# Test: the headless smoke's SHAPE — the half that is cheap enough for the normal
# suite (FEAT-028 / TASK-016, TRD §7). It validates the workflow's triggers and
# posture, that the runner is syntactically sound, and that the scratch fixture a
# scenario builds is well-formed. It NEVER invokes claude — asserted here with a
# PATH-shadowing stub, not merely intended.
TEST_NAME="test-smoke-shape"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

WORKFLOW="$REPO_ROOT/.github/workflows/smoke.yml"
RUNNER="$REPO_ROOT/tests/smoke/run-smoke.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-smoke-shape-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

# Six stages, each either checked or skipped for a named tool-absence reason.
STAGES="workflow-yaml-parse workflow-triggers loop-boundary runner-syntax runner-shellcheck fixture-wellformedness"
SS_SCANNED=$(printf '%s' "$STAGES" | wc -w | tr -d ' ')
SS_CHECKED=0
SS_SKIP_PYYAML=0
SS_SKIP_SHELLCHECK=0

assert_file_exists "smoke.yml exists" "$WORKFLOW"
assert_file_exists "run-smoke.sh exists" "$RUNNER"
if [ ! -f "$WORKFLOW" ] || [ ! -f "$RUNNER" ]; then
  echo "$TEST_NAME: NOTHING CHECKED — the smoke workflow and/or runner is absent; no stage could run" >&2
  report_results || true
  printf '%s: %d scanned, %d skipped (pyyaml-absent=0, shellcheck-absent=0, no-smoke-artifacts=%d), 0 checked, %d findings\n' \
    "$TEST_NAME" "$SS_SCANNED" "$SS_SCANNED" "$SS_SCANNED" "$TESTS_FAILED"
  exit "$NOTHING_CHECKED_EXIT"
fi

workflow_has_push_pr_trigger() {
  awk '
    /^[^[:space:]#]/ { in_on=0 }
    /^on:[[:space:]]*/ {
      rest=$0
      sub(/^on:[[:space:]]*/, "", rest)
      if (rest == "") in_on=1
      else if (rest ~ /(^|[^[:alnum:]_])(push|pull_request)([^[:alnum:]_]|$)/) found=1
      next
    }
    in_on && /^[[:space:]]+(push|pull_request)[[:space:]]*:/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

INLINE_TRIGGER="$SCRATCH/inline-trigger.yaml"
printf 'on: [workflow_dispatch, push]\n' > "$INLINE_TRIGGER"
if workflow_has_push_pr_trigger "$INLINE_TRIGGER"; then
  _pass "workflow trigger scanner detects inline push triggers in .yaml files"
else
  _fail "workflow trigger scanner detects inline push triggers in .yaml files"
fi

SAFE_TRIGGER="$SCRATCH/manual-trigger.yaml"
printf 'on: [workflow_dispatch]\n' > "$SAFE_TRIGGER"
if workflow_has_push_pr_trigger "$SAFE_TRIGGER"; then
  _fail "workflow trigger scanner does not flag a safe inline manual trigger"
else
  _pass "workflow trigger scanner does not flag a safe inline manual trigger"
fi

# --- Stage: workflow-yaml-parse (needs PyYAML; skipped by name when absent) ---
if python3 -c 'import yaml' 2>/dev/null; then
  SS_CHECKED=$((SS_CHECKED + 1))
  TRIGGERS=$(python3 - "$WORKFLOW" <<'PY' 2>/dev/null || echo "PARSE_ERROR"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves the bare key `on` to the boolean True (YAML 1.1 tags).
on = d.get("on", d.get(True))
print(" ".join(sorted(on)) if isinstance(on, dict) else "NOT_A_MAPPING")
PY
)
  assert_eq "smoke.yml parses as YAML and triggers on exactly workflow_dispatch + schedule" \
    "$TRIGGERS" "schedule workflow_dispatch"
else
  SS_SKIP_PYYAML=$((SS_SKIP_PYYAML + 1))
  echo "  SKIP: workflow-yaml-parse (PyYAML not importable — the YAML was not parsed)"
fi

# --- Stage: workflow-triggers (parser-independent; always runs) ---
SS_CHECKED=$((SS_CHECKED + 1))
WF=$(cat "$WORKFLOW")
assert_contains "smoke.yml declares workflow_dispatch" "$WF" "workflow_dispatch:"
assert_contains "smoke.yml declares a nightly schedule" "$WF" "cron:"
# The whole posture: a push/pull_request trigger would put a paid claude -p run
# on every commit. Match the trigger form (`  push:`), not the word.
if workflow_has_push_pr_trigger "$WORKFLOW"; then
  _fail "smoke.yml never triggers on push or pull_request" "found a push/pull_request trigger key"
else
  _pass "smoke.yml never triggers on push or pull_request"
fi
assert_contains "smoke.yml is timeout-bounded" "$WF" "timeout-minutes:"
assert_contains "smoke.yml prevents overlapping paid runs" "$WF" "concurrency:"
assert_contains "smoke.yml keeps the active run instead of cancelling it" "$WF" "cancel-in-progress: false"
assert_contains "scheduled smoke is gated to the official repository" "$WF" "github.repository == 'OrodruinLabs/nazgul'"
assert_contains "smoke.yml uses the ANTHROPIC_API_KEY secret" "$WF" "secrets.ANTHROPIC_API_KEY"
assert_contains "smoke.yml checks the API key before paid setup" "$WF" 'if [ -z "$ANTHROPIC_API_KEY" ]'
assert_contains "smoke.yml installs a pinned Claude Code CLI" "$WF" "npm install -g @anthropic-ai/claude-code@2.1.222"
assert_contains "smoke.yml runs the smoke runner" "$WF" "tests/smoke/run-smoke.sh"
# `-e`, because assert_contains's grep reads a leading `--` needle as options.
if grep -qF -e '--inbox-dir=' "$WORKFLOW"; then
  _pass "smoke.yml points the runner at an inbox dir so a failure files a p1 item"
else
  _fail "smoke.yml points the runner at an inbox dir so a failure files a p1 item" "no --inbox-dir= argument"
fi

# --- Stage: loop-boundary — no push/PR-triggered workflow may run the smoke ---
SS_CHECKED=$((SS_CHECKED + 1))
LEAKED=""
WF_SCANNED=0
for wf in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  [ "$wf" = "$WORKFLOW" ] && continue
  WF_SCANNED=$((WF_SCANNED + 1))
  if workflow_has_push_pr_trigger "$wf" && grep -q 'tests/smoke' "$wf"; then
    LEAKED="$LEAKED $(basename "$wf")"
  fi
done
if [ "$WF_SCANNED" -eq 0 ]; then
  _fail "the loop-boundary scan found other workflows to check" "no sibling workflow files under .github/workflows"
elif [ -z "$LEAKED" ]; then
  _pass "no push/pull_request workflow runs the smoke ($WF_SCANNED sibling workflows scanned)"
else
  _fail "no push/pull_request workflow runs the smoke" "leaked into:$LEAKED"
fi

# --- Stage: runner-syntax ---
SS_CHECKED=$((SS_CHECKED + 1))
if bash -n "$RUNNER" 2>/dev/null; then
  _pass "run-smoke.sh passes bash -n"
else
  _fail "run-smoke.sh passes bash -n" "syntax error detected"
fi

# --- Stage: runner-shellcheck (skipped by name when the tool is absent) ---
SHELLCHECK_BIN=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK_BIN="shellcheck"
elif [ -x "${SHELLCHECK_FALLBACK_BIN:-/tmp/shellcheck-v0.10.0/shellcheck}" ]; then
  SHELLCHECK_BIN="${SHELLCHECK_FALLBACK_BIN:-/tmp/shellcheck-v0.10.0/shellcheck}"
fi
if [ -n "$SHELLCHECK_BIN" ]; then
  SS_CHECKED=$((SS_CHECKED + 1))
  if "$SHELLCHECK_BIN" -S warning "$RUNNER" 2>/dev/null; then
    _pass "run-smoke.sh passes shellcheck"
  else
    _fail "run-smoke.sh passes shellcheck" "shellcheck warnings found"
  fi
else
  SS_SKIP_SHELLCHECK=$((SS_SKIP_SHELLCHECK + 1))
  echo "  SKIP: runner-shellcheck (shellcheck not installed — run-smoke.sh was not linted)"
fi

# --- Stage: fixture-wellformedness ---
# A `claude` stub shadows PATH below: reaching the real CLI would leave a marker file.
SS_CHECKED=$((SS_CHECKED + 1))
STUB_DIR="$SCRATCH/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "$SCRATCH/claude-invocations.log"
exit 1
STUB
chmod +x "$STUB_DIR/claude"

RUN_BEFORE_SOURCE=$TESTS_RUN
FAILED_BEFORE_SOURCE=$TESTS_FAILED
# shellcheck source=smoke/run-smoke.sh
NAZGUL_SMOKE_SOURCE_ONLY=1 source "$RUNNER"
assert_eq "sourcing run-smoke.sh does not re-zero this test's assertion count" "$TESTS_RUN" "$RUN_BEFORE_SOURCE"
assert_eq "sourcing run-smoke.sh does not erase this test's failures" "$TESTS_FAILED" "$FAILED_BEFORE_SOURCE"

PROJ="$SCRATCH/project"
PATH="$STUB_DIR:$PATH" smoke_scratch_project "$PROJ" '.mode = "afk"' '.automation.heartbeat.enabled = true'

assert_file_not_exists "the shape test never invokes claude" "$SCRATCH/claude-invocations.log"

CFG="$PROJ/nazgul/config.json"
if jq -e . "$CFG" >/dev/null 2>&1; then
  _pass "the scratch project's config.json is valid JSON"
else
  _fail "the scratch project's config.json is valid JSON" "jq could not parse $CFG"
fi
assert_eq "the scratch config carries the shipped schema_version" \
  "$(jq -r '.schema_version' "$CFG")" "$(jq -r '.schema_version' "$REPO_ROOT/templates/config.json")"
assert_eq "per-scenario jq overrides are applied" "$(jq -r '.automation.heartbeat.enabled' "$CFG")" "true"
assert_eq "the scratch project is a real git repo" "$(git -C "$PROJ" rev-parse --is-inside-work-tree 2>/dev/null)" "true"

INBOX_ITEM=$(find "$PROJ/nazgul/inbox" -maxdepth 1 -type f -name '*.md' | sed -n '1p')
assert_eq "the scratch project has exactly one live inbox candidate" \
  "$(find "$PROJ/nazgul/inbox" -maxdepth 1 -type f \( -name '*.md' -o -name '*.json' \) | wc -l | tr -d ' ')" "1"
# Parsed by the real consumer, not by a grep written to match the fixture.
source "$REPO_ROOT/scripts/lib/inbox-provider.sh"
ITEM_JSON=$(inbox_get "$PROJ/nazgul/inbox" "$(basename "$INBOX_ITEM")" 2>/dev/null || echo '{}')
assert_eq "the inbox candidate parses through inbox_get with a title" \
  "$(printf '%s' "$ITEM_JSON" | jq -r '.title | if . == null then "null" else "present" end')" "present"
assert_eq "the inbox candidate carries a priority triage can rank" \
  "$(printf '%s' "$ITEM_JSON" | jq -r '.priority // "null"')" "2"

if grep -q '^## Recovery Pointer' "$PROJ/nazgul/plan.md"; then
  _pass "the scratch project's plan.md has a Recovery Pointer"
else
  _fail "the scratch project's plan.md has a Recovery Pointer" "no '## Recovery Pointer' heading"
fi
assert_file_exists "the plugin's scripts/ is reachable from the scratch project" "$PROJ/scripts/heartbeat.sh"
assert_contains "the scratch inbox seed identifies the runner as its source" \
  "$(cat "$INBOX_ITEM")" 'source: "tests/smoke/run-smoke.sh"'

# The never-touches-this-repo boundary, driven rather than asserted from prose.
BOUNDARY_RC=0
smoke_scratch_project "$REPO_ROOT/.smoke-boundary-probe" >/dev/null 2>&1 || BOUNDARY_RC=$?
assert_exit_code "smoke_scratch_project refuses a destination inside this repository" "$BOUNDARY_RC" 1
assert_dir_not_exists "the refused probe leaves no destination directory behind" "$REPO_ROOT/.smoke-boundary-probe"

FILED=$(smoke_file_failure_item "$SCRATCH/inbox" "heartbeat" "smoke shape self-check")
assert_contains "a smoke failure files a priority-1 inbox item" "$(cat "$FILED")" "priority: 1"
assert_contains "the filed item is typed for triage" "$(cat "$FILED")" "type: smoke-failure"

SS_SKIPPED=$((SS_SKIP_PYYAML + SS_SKIP_SHELLCHECK))
if [ "$SS_SCANNED" -ne $((SS_SKIPPED + SS_CHECKED)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $SS_SCANNED scanned != $SS_SKIPPED skipped + $SS_CHECKED checked" >&2
  _fail "coverage accounting adds up (N == M + K)" "$SS_SCANNED != $SS_SKIPPED + $SS_CHECKED"
fi
if [ "$SS_CHECKED" -eq 0 ]; then
  echo "$TEST_NAME: NOTHING CHECKED — all $SS_SCANNED stages skipped" >&2
  _fail "at least one smoke-shape stage ran" "all $SS_SCANNED stages skipped"
fi

RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (pyyaml-absent=%d, shellcheck-absent=%d, no-smoke-artifacts=0), %d checked, %d findings\n' \
  "$TEST_NAME" "$SS_SCANNED" "$SS_SKIPPED" "$SS_SKIP_PYYAML" "$SS_SKIP_SHELLCHECK" "$SS_CHECKED" "$TESTS_FAILED"
exit "$RC"
