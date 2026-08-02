#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.

# Test: scripts/lib/stack-utils.sh — FEAT-027 TASK-004 core (availability,
# tip/count against fixture registries, register idempotency, submit in both
# stacking modes + the stacking_unavailable fallback). `gh` is a PATH-shim
# mock; NO network. `git push` is real, against a local bare "origin".
TEST_NAME="test-stack-utils"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

setup_temp_dir
setup_nazgul_dir
setup_git_repo
create_config
CONFIG="$TEST_DIR/nazgul/config.json"
export NAZGUL_DIR="$TEST_DIR/nazgul"
EVENTS_FILE_PATH="$NAZGUL_DIR/logs/events.jsonl"

DEFAULT_BRANCH=$(git -C "$TEST_DIR" branch --show-current)

# Real local "origin" so `git push -u origin <branch>` in stack_submit is a
# real, non-networked git operation — only `gh` is mocked.
git init -q --bare "$TEST_DIR/remote.git"
git -C "$TEST_DIR" remote add origin "$TEST_DIR/remote.git"
git -C "$TEST_DIR" push -q -u origin "$DEFAULT_BRANCH"

# Fake `gh` placed first on PATH. Its dir is a colon-free mktemp (NOT under
# $TEST_DIR, whose name carries a literal ":" that would corrupt PATH parsing).
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh for stack-utils tests. Env switches inject extension/auth/failure
# states; NAZGUL_TEST_GH_*_LOG paths record what was invoked.
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    action="${1:-}"; shift || true
    case "$action" in
      list)
        if [ "${NAZGUL_TEST_GH_STACK_EXT:-1}" != "0" ]; then
          printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'
        fi
        printf 'gh other-ext\tsome/other\tv1.0.0\n'
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  auth)
    action="${1:-}"; shift || true
    case "$action" in
      status) [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    action="${1:-}"; shift || true
    case "$action" in
      create)
        base=""; head=""; title=""; body=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --base)  base="$2";  shift 2 ;;
            --head)  head="$2";  shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --body)  body="$2";  shift 2 ;;
            *) shift ;;
          esac
        done
        if [ "${NAZGUL_TEST_GH_PR_CREATE_FAIL:-0}" = "1" ]; then
          echo "gh pr create: simulated failure" >&2
          exit 1
        fi
        if [ -n "${NAZGUL_TEST_GH_PR_CREATE_LOG:-}" ]; then
          printf 'base=%s head=%s title=%s body=%s\n' "$base" "$head" "$title" "$body" >> "$NAZGUL_TEST_GH_PR_CREATE_LOG"
        fi
        printf 'https://github.com/o/r/pull/%s\n' "$(printf '%s' "$head" | tr '/' '-')"
        exit 0 ;;
      view)
        branch="${1:-}"
        if [ "${NAZGUL_TEST_GH_PR_VIEW_FAIL:-0}" = "1" ]; then
          echo "gh pr view: simulated failure" >&2
          exit 1
        fi
        printf 'https://github.com/o/r/pull/%s\n' "$(printf '%s' "$branch" | tr '/' '-')"
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stack)
    action="${1:-}"; shift || true
    case "$action" in
      submit)
        if [ -n "${NAZGUL_TEST_GH_STACK_SUBMIT_LOG:-}" ]; then
          printf 'submit called: %s\n' "$*" >> "$NAZGUL_TEST_GH_STACK_SUBMIT_LOG"
        fi
        exit_code="${NAZGUL_TEST_GH_STACK_SUBMIT_EXIT:-0}"
        if [ "$exit_code" != "0" ]; then
          echo "gh stack submit: simulated failure (exit $exit_code)" >&2
          exit "$exit_code"
        fi
        echo "Submitted stack."
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

# Save the pre-FAKEBIN PATH (still carrying jq/git) for the one test that
# needs `gh` genuinely absent (stack_available's `command -v gh` branch).
JQ_DIR=$(dirname "$(command -v jq)")
GIT_DIR=$(dirname "$(command -v git)")
NO_GH_PATH="$JQ_DIR:$GIT_DIR:/usr/bin:/bin"

export PATH="$FAKEBIN:$PATH"

resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  teardown_temp_dir; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/stack-utils.sh"

# =====================================================================
# stack_available — three distinct states, each pinned
# =====================================================================

assert_eq "stack_available: disabled by default config" "$(stack_available "$CONFIG")" "disabled"
stack_available "$CONFIG" >/dev/null; assert_exit_code "stack_available: disabled returns 1" "$?" 1

READY_CONFIG="$TEST_DIR/nazgul/config-ready.json"
jq '.execution.stacking.enabled = true' "$CONFIG" > "$READY_CONFIG"

assert_eq "stack_available: enabled + extension + authed -> ready" "$(stack_available "$READY_CONFIG")" "ready"
stack_available "$READY_CONFIG" >/dev/null; assert_exit_code "stack_available: ready returns 0" "$?" 0

export NAZGUL_TEST_GH_STACK_EXT=0
assert_eq "stack_available: enabled + extension NOT installed -> missing" "$(stack_available "$READY_CONFIG")" "missing"
stack_available "$READY_CONFIG" >/dev/null; assert_exit_code "stack_available: missing (no extension) returns 2" "$?" 2
unset NAZGUL_TEST_GH_STACK_EXT

export NAZGUL_TEST_GH_AUTH=fail
assert_eq "stack_available: enabled + extension installed but NOT authed -> missing" "$(stack_available "$READY_CONFIG")" "missing"
unset NAZGUL_TEST_GH_AUTH

out=$( (PATH="$NO_GH_PATH"; stack_available "$READY_CONFIG") 2>/dev/null)
assert_eq "stack_available: enabled but gh itself absent from PATH -> missing" "$out" "missing"

# =====================================================================
# stack_tip / stack_unmerged_count — fixture registries
# =====================================================================

EMPTY_REG="$TEST_DIR/nazgul/config-empty-reg.json"
jq '.branch.base = "main" | .stack.layers = []' "$CONFIG" > "$EMPTY_REG"
assert_eq "stack_tip: empty registry -> branch.base" "$(stack_tip "$EMPTY_REG")" "main"
assert_eq "stack_unmerged_count: empty registry -> 0" "$(stack_unmerged_count "$EMPTY_REG")" "0"

ONE_OPEN_REG="$TEST_DIR/nazgul/config-one-open-reg.json"
jq '.branch.base = "main" | .stack.layers = [
  {feat_id:"FEAT-001", branch:"feat/FEAT-001-x", pr:null, base:"main", state:"open", opened_at:"2026-08-01T00:00:00Z", merged_at:null}
]' "$CONFIG" > "$ONE_OPEN_REG"
assert_eq "stack_tip: one open layer -> its branch" "$(stack_tip "$ONE_OPEN_REG")" "feat/FEAT-001-x"
assert_eq "stack_unmerged_count: one open layer -> 1" "$(stack_unmerged_count "$ONE_OPEN_REG")" "1"

MIXED_REG="$TEST_DIR/nazgul/config-mixed-reg.json"
jq '.branch.base = "main" | .stack.layers = [
  {feat_id:"FEAT-001", branch:"feat/FEAT-001-x", pr:"https://x/1", base:"main", state:"merged", opened_at:"2026-08-01T00:00:00Z", merged_at:"2026-08-01T12:00:00Z"},
  {feat_id:"FEAT-002", branch:"feat/FEAT-002-y", pr:null, base:"feat/FEAT-001-x", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}
]' "$CONFIG" > "$MIXED_REG"
assert_eq "stack_tip: mixed open+merged -> the open branch (ignores merged)" "$(stack_tip "$MIXED_REG")" "feat/FEAT-002-y"
assert_eq "stack_unmerged_count: mixed open+merged -> 1" "$(stack_unmerged_count "$MIXED_REG")" "1"

# newest-open selection: two open layers, newer opened_at wins
TWO_OPEN_REG="$TEST_DIR/nazgul/config-two-open-reg.json"
jq '.branch.base = "main" | .stack.layers = [
  {feat_id:"FEAT-001", branch:"feat/FEAT-001-x", pr:null, base:"main", state:"open", opened_at:"2026-08-01T00:00:00Z", merged_at:null},
  {feat_id:"FEAT-002", branch:"feat/FEAT-002-y", pr:null, base:"feat/FEAT-001-x", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}
]' "$CONFIG" > "$TWO_OPEN_REG"
assert_eq "stack_tip: two open layers -> newest by opened_at" "$(stack_tip "$TWO_OPEN_REG")" "feat/FEAT-002-y"
assert_eq "stack_unmerged_count: two open layers -> 2" "$(stack_unmerged_count "$TWO_OPEN_REG")" "2"

# =====================================================================
# stack_register_layer — exact shape, atomic, idempotent per feat_id
# =====================================================================

REG_CONFIG="$TEST_DIR/nazgul/config-register.json"
jq '.stack.layers = []' "$CONFIG" > "$REG_CONFIG"

stack_register_layer "$REG_CONFIG" "FEAT-100" "feat/FEAT-100-x" "main"; reg_rc1=$?
assert_exit_code "stack_register_layer: first call succeeds" "$reg_rc1" 0
assert_eq "stack_register_layer: exactly one entry after first call" \
  "$(jq '.stack.layers | length' "$REG_CONFIG")" "1"
assert_eq "stack_register_layer: feat_id" "$(jq -r '.stack.layers[0].feat_id' "$REG_CONFIG")" "FEAT-100"
assert_eq "stack_register_layer: branch" "$(jq -r '.stack.layers[0].branch' "$REG_CONFIG")" "feat/FEAT-100-x"
assert_eq "stack_register_layer: base" "$(jq -r '.stack.layers[0].base' "$REG_CONFIG")" "main"
assert_eq "stack_register_layer: state open" "$(jq -r '.stack.layers[0].state' "$REG_CONFIG")" "open"
assert_eq "stack_register_layer: pr null when omitted" "$(jq -r '.stack.layers[0].pr' "$REG_CONFIG")" "null"
assert_eq "stack_register_layer: merged_at null" "$(jq -r '.stack.layers[0].merged_at' "$REG_CONFIG")" "null"
assert_eq "stack_register_layer: opened_at present (non-empty)" \
  "$(jq -r '.stack.layers[0].opened_at | length > 0' "$REG_CONFIG")" "true"
FIRST_OPENED_AT=$(jq -r '.stack.layers[0].opened_at' "$REG_CONFIG")

# Re-register: same feat_id, new branch/base/pr -> updates in place, no dup, opened_at preserved
stack_register_layer "$REG_CONFIG" "FEAT-100" "feat/FEAT-100-x" "main" "https://github.com/o/r/pull/1"; reg_rc2=$?
assert_exit_code "stack_register_layer: re-register succeeds" "$reg_rc2" 0
assert_eq "stack_register_layer: idempotent — still exactly one entry" \
  "$(jq '.stack.layers | length' "$REG_CONFIG")" "1"
assert_eq "stack_register_layer: pr updated on re-register" \
  "$(jq -r '.stack.layers[0].pr' "$REG_CONFIG")" "https://github.com/o/r/pull/1"
assert_eq "stack_register_layer: opened_at preserved across re-register" \
  "$(jq -r '.stack.layers[0].opened_at' "$REG_CONFIG")" "$FIRST_OPENED_AT"

# Re-register with empty pr -> existing pr preserved, not clobbered to null
stack_register_layer "$REG_CONFIG" "FEAT-100" "feat/FEAT-100-x" "main"
assert_eq "stack_register_layer: empty pr arg preserves existing pr" \
  "$(jq -r '.stack.layers[0].pr' "$REG_CONFIG")" "https://github.com/o/r/pull/1"

# A second, distinct feat_id appends rather than overwriting
stack_register_layer "$REG_CONFIG" "FEAT-101" "feat/FEAT-101-y" "feat/FEAT-100-x"
assert_eq "stack_register_layer: distinct feat_id appends a second entry" \
  "$(jq '.stack.layers | length' "$REG_CONFIG")" "2"

# =====================================================================
# stack_submit — disabled mode: plain PR, history write, no registry touch
# =====================================================================

BR_DISABLED="feat/FEAT-200-disabled"
git -C "$TEST_DIR" checkout -q -b "$BR_DISABLED"
echo "disabled-mode change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "disabled-mode change"

SUB_DISABLED="$TEST_DIR/nazgul/config-submit-disabled.json"
jq --arg feat "$BR_DISABLED" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = false
  | .branch.feature = $feat | .branch.base = $base
  | .feat_id = "FEAT-200"
  | .objectives_history = [{feat_id:"FEAT-200", objective:"disabled mode test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = []
' "$CONFIG" > "$SUB_DISABLED"

pr_url_disabled=$(stack_submit "$SUB_DISABLED" "$TEST_DIR" "Disabled mode PR" "body text"); submit_disabled_rc=$?
assert_exit_code "stack_submit (disabled): succeeds" "$submit_disabled_rc" 0
assert_eq "stack_submit (disabled): PR URL derives from head branch" \
  "$pr_url_disabled" "https://github.com/o/r/pull/feat-FEAT-200-disabled"
assert_eq "stack_submit (disabled): objectives_history[].pr written" \
  "$(jq -r '.objectives_history[0].pr' "$SUB_DISABLED")" "$pr_url_disabled"
assert_eq "stack_submit (disabled): registry untouched (no layer entry)" \
  "$(jq '.stack.layers | length' "$SUB_DISABLED")" "0"
assert_eq "stack_submit (disabled): pushed branch exists on origin" \
  "$(git -C "$TEST_DIR" ls-remote origin "$BR_DISABLED" | wc -l | tr -d ' ')" "1"

# =====================================================================
# stack_submit — ready mode: stacked PR, registry pr field, history write
# =====================================================================

BR_READY="feat/FEAT-201-ready"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_READY"
echo "ready-mode change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "ready-mode change"

SUB_READY="$TEST_DIR/nazgul/config-submit-ready.json"
jq --arg feat "$BR_READY" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base
  | .feat_id = "FEAT-201"
  | .objectives_history = [{feat_id:"FEAT-201", objective:"ready mode test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = [{feat_id:"FEAT-201", branch:$feat, pr:null, base:"feat/FEAT-200-disabled", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$SUB_READY"

STACK_SUBMIT_LOG="$TEST_DIR/stack-submit-calls.log"
export NAZGUL_TEST_GH_STACK_SUBMIT_LOG="$STACK_SUBMIT_LOG"
pr_url_ready=$(stack_submit "$SUB_READY" "$TEST_DIR" "Ready mode PR" "body text"); submit_ready_rc=$?
unset NAZGUL_TEST_GH_STACK_SUBMIT_LOG
assert_exit_code "stack_submit (ready): succeeds" "$submit_ready_rc" 0
assert_file_exists "stack_submit (ready): gh stack submit was actually invoked" "$STACK_SUBMIT_LOG"
assert_eq "stack_submit (ready): gh stack submit --auto --open" \
  "$(cat "$STACK_SUBMIT_LOG" 2>/dev/null)" "submit called: --auto --open"
assert_eq "stack_submit (ready): PR URL from gh pr view" \
  "$pr_url_ready" "https://github.com/o/r/pull/feat-FEAT-201-ready"
assert_eq "stack_submit (ready): registry pr field updated" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-201") | .pr' "$SUB_READY")" "$pr_url_ready"
assert_eq "stack_submit (ready): registry base preserved (the layer's OWN recorded base, not stack_tip)" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-201") | .base' "$SUB_READY")" "feat/FEAT-200-disabled"
assert_eq "stack_submit (ready): registry still exactly one entry for this feat_id (idempotent)" \
  "$(jq '[.stack.layers[] | select(.feat_id=="FEAT-201")] | length' "$SUB_READY")" "1"
assert_eq "stack_submit (ready): objectives_history[].pr written" \
  "$(jq -r '.objectives_history[0].pr' "$SUB_READY")" "$pr_url_ready"

# Ready mode with NO pre-existing registry entry for this feat_id -> base falls
# back to stack_tip (the newest open layer, here FEAT-201's branch).
BR_READY2="feat/FEAT-202-ready-noreg"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_READY2"
echo "ready-mode change 2" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "ready-mode change 2"

SUB_READY2="$TEST_DIR/nazgul/config-submit-ready2.json"
jq --arg feat "$BR_READY2" --arg base "$DEFAULT_BRANCH" --arg tipbr "$BR_READY" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base
  | .feat_id = "FEAT-202"
  | .objectives_history = [{feat_id:"FEAT-202", objective:"ready mode 2 test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = [{feat_id:"FEAT-201", branch:$tipbr, pr:"https://github.com/o/r/pull/prior", base:"feat/FEAT-200-disabled", state:"open", opened_at:"2026-08-02T01:00:00Z", merged_at:null}]
' "$CONFIG" > "$SUB_READY2"

pr_url_ready2=$(stack_submit "$SUB_READY2" "$TEST_DIR" "Ready mode 2 PR" "body text"); submit_ready2_rc=$?
assert_exit_code "stack_submit (ready, no prior registry entry): succeeds" "$submit_ready2_rc" 0
assert_eq "stack_submit (ready, no prior registry entry): PR URL from gh pr view" \
  "$pr_url_ready2" "https://github.com/o/r/pull/feat-FEAT-202-ready-noreg"
assert_eq "stack_submit (ready, no prior entry): registers a NEW entry using stack_tip as base" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-202") | .base' "$SUB_READY2")" "$BR_READY"
assert_eq "stack_submit (ready, no prior entry): registry now has both layers" \
  "$(jq '.stack.layers | length' "$SUB_READY2")" "2"

# =====================================================================
# stack_submit — enabled but tooling missing: fail-closed fallback + stop_gate
# =====================================================================

BR_MISSING="feat/FEAT-203-missing"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_MISSING"
echo "missing-tooling change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "missing-tooling change"

SUB_MISSING="$TEST_DIR/nazgul/config-submit-missing.json"
jq --arg feat "$BR_MISSING" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base
  | .feat_id = "FEAT-203"
  | .objectives_history = [{feat_id:"FEAT-203", objective:"missing tooling test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = []
' "$CONFIG" > "$SUB_MISSING"

: > "$EVENTS_FILE_PATH"
export NAZGUL_TEST_GH_STACK_EXT=0
pr_url_missing=$(stack_submit "$SUB_MISSING" "$TEST_DIR" "Missing tooling PR" "body text"); submit_missing_rc=$?
unset NAZGUL_TEST_GH_STACK_EXT
assert_exit_code "stack_submit (missing tooling): still succeeds (fail-closed fallback)" "$submit_missing_rc" 0
assert_eq "stack_submit (missing tooling): falls back to plain PR against branch.base" \
  "$pr_url_missing" "https://github.com/o/r/pull/feat-FEAT-203-missing"
assert_eq "stack_submit (missing tooling): registry NOT touched (no layer entry)" \
  "$(jq '.stack.layers | length' "$SUB_MISSING")" "0"
assert_eq "stack_submit (missing tooling): objectives_history[].pr still written" \
  "$(jq -r '.objectives_history[0].pr' "$SUB_MISSING")" "$pr_url_missing"
assert_contains "stack_submit (missing tooling): emits stop_gate reason:stacking_unavailable, loud never silent" \
  "$(cat "$EVENTS_FILE_PATH" 2>/dev/null)" '"reason":"stacking_unavailable"'
assert_contains "stack_submit (missing tooling): stop_gate event names the branch" \
  "$(cat "$EVENTS_FILE_PATH" 2>/dev/null)" "$BR_MISSING"

# =====================================================================
# stack_submit — loud failure paths (no writes on failure)
# =====================================================================

BR_PUSHFAIL="feat/FEAT-204-pushfail"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_PUSHFAIL"
# Deliberately do NOT commit — but that's fine for push; instead point origin
# at an unreachable path so the push itself fails.
SUB_PUSHFAIL="$TEST_DIR/nazgul/config-submit-pushfail.json"
jq --arg feat "$BR_PUSHFAIL" --arg base "$DEFAULT_BRANCH" '
  .branch.feature = $feat | .branch.base = $base | .feat_id = "FEAT-204"
  | .objectives_history = [{feat_id:"FEAT-204", objective:"push fail test", started_at:"2026-08-02T00:00:00Z"}]
' "$CONFIG" > "$SUB_PUSHFAIL"
BOGUS_ROOT="$TEST_DIR/no-such-project-root"
push_err=$(stack_submit "$SUB_PUSHFAIL" "$BOGUS_ROOT" "Push fail PR" "body" 2>&1 >/dev/null); push_fail_rc=$?
assert_exit_code "stack_submit: returns non-zero when push fails" "$push_fail_rc" 1
assert_contains "stack_submit: push failure is loud (stderr)" "$push_err" "push"
assert_eq "stack_submit: no objectives_history write on push failure" \
  "$(jq -r '.objectives_history[0].pr // "null"' "$SUB_PUSHFAIL")" "null"

export NAZGUL_TEST_GH_PR_CREATE_FAIL=1
BR_PRFAIL="feat/FEAT-205-prfail"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_PRFAIL"
echo "pr-fail change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "pr-fail change"
SUB_PRFAIL="$TEST_DIR/nazgul/config-submit-prfail.json"
jq --arg feat "$BR_PRFAIL" --arg base "$DEFAULT_BRANCH" '
  .branch.feature = $feat | .branch.base = $base | .feat_id = "FEAT-205"
  | .objectives_history = [{feat_id:"FEAT-205", objective:"pr create fail test", started_at:"2026-08-02T00:00:00Z"}]
' "$CONFIG" > "$SUB_PRFAIL"
stack_submit "$SUB_PRFAIL" "$TEST_DIR" "PR fail" "body" >/dev/null 2>&1; prfail_rc=$?
unset NAZGUL_TEST_GH_PR_CREATE_FAIL
assert_exit_code "stack_submit: returns non-zero when gh pr create fails" "$prfail_rc" 1
assert_eq "stack_submit: no objectives_history write when PR creation fails" \
  "$(jq -r '.objectives_history[0].pr // "null"' "$SUB_PRFAIL")" "null"

export NAZGUL_TEST_GH_STACK_SUBMIT_EXIT=1
BR_STACKFAIL="feat/FEAT-206-stackfail"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_STACKFAIL"
echo "stack-fail change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "stack-fail change"
SUB_STACKFAIL="$TEST_DIR/nazgul/config-submit-stackfail.json"
jq --arg feat "$BR_STACKFAIL" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base | .feat_id = "FEAT-206"
  | .objectives_history = [{feat_id:"FEAT-206", objective:"stack submit fail test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = []
' "$CONFIG" > "$SUB_STACKFAIL"
stack_submit "$SUB_STACKFAIL" "$TEST_DIR" "Stack submit fail" "body" >/dev/null 2>&1; stackfail_rc=$?
unset NAZGUL_TEST_GH_STACK_SUBMIT_EXIT
assert_exit_code "stack_submit: returns non-zero when gh stack submit fails (ready mode)" "$stackfail_rc" 1
assert_eq "stack_submit: no registry write when gh stack submit fails" \
  "$(jq '.stack.layers | length' "$SUB_STACKFAIL")" "0"

teardown_temp_dir
rm -rf "$FAKEBIN"
report_results
