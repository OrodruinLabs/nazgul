#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.

# Test: scripts/lib/stack-utils.sh — FEAT-027 TASK-004 core (availability,
# tip/count against fixture registries, register idempotency, submit in both
# stacking modes + the stacking_unavailable fallback) PLUS TASK-005's
# continuation half (stack_reconcile, stack_detect_changes_requested, the
# ADR-018 exit-3/4/9 conflict/API doctrine, and rework-item filing). `gh` is a
# PATH-shim mock; NO network. `git push` is real, against a local bare "origin".
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
        ident="${1:-}"; shift || true
        json_fields=""; has_query=0
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) json_fields="$2"; shift 2 ;;
            -q|--jq) has_query=1; shift 2 ;;
            *) shift ;;
          esac
        done
        # `--json <fields> -q <query>` (used by _su_stacked_pr) extracts a
        # scalar server-side — keep returning the plain-URL legacy behavior.
        # Bare `--json <fields>` (stack_reconcile/stack_detect_changes_requested)
        # returns the raw JSON object.
        if [ -n "$json_fields" ] && [ "$has_query" -eq 0 ]; then
          if [ "${NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL:-0}" = "1" ]; then
            echo "gh pr view --json: simulated API failure" >&2
            exit "${NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL_EXIT:-1}"
          fi
          payload=""
          if [ -n "${NAZGUL_TEST_GH_PR_VIEW_JSON_MAP:-}" ] && [ -f "${NAZGUL_TEST_GH_PR_VIEW_JSON_MAP}" ]; then
            payload=$(awk -F'\t' -v k="$ident" '$1==k{print $2; exit}' "${NAZGUL_TEST_GH_PR_VIEW_JSON_MAP}")
          fi
          if [ -z "$payload" ]; then
            payload="${NAZGUL_TEST_GH_PR_VIEW_JSON:-}"
          fi
          if [ -z "$payload" ]; then
            payload='{"number":1,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}'
          fi
          printf '%s\n' "$payload"
          exit 0
        fi
        if [ "${NAZGUL_TEST_GH_PR_VIEW_FAIL:-0}" = "1" ]; then
          echo "gh pr view: simulated failure" >&2
          exit 1
        fi
        printf 'https://github.com/o/r/pull/%s\n' "$(printf '%s' "$ident" | tr '/' '-')"
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
      sync)
        if [ -n "${NAZGUL_TEST_GH_STACK_SYNC_LOG:-}" ]; then
          printf 'sync called\n' >> "$NAZGUL_TEST_GH_STACK_SYNC_LOG"
        fi
        if [ -n "${NAZGUL_TEST_GH_STACK_SYNC_STDERR:-}" ]; then
          echo "${NAZGUL_TEST_GH_STACK_SYNC_STDERR}" >&2
        fi
        exit_code="${NAZGUL_TEST_GH_STACK_SYNC_EXIT:-0}"
        if [ "$exit_code" != "0" ]; then
          exit "$exit_code"
        fi
        echo "Stack synced."
        exit 0 ;;
      checkout)
        pr="${1:-}"; shift || true
        if [ -n "${NAZGUL_TEST_GH_STACK_CHECKOUT_LOG:-}" ]; then
          printf 'checkout called: %s\n' "$pr" >> "$NAZGUL_TEST_GH_STACK_CHECKOUT_LOG"
        fi
        exit_code="${NAZGUL_TEST_GH_STACK_CHECKOUT_EXIT:-0}"
        if [ "$exit_code" != "0" ]; then
          echo "${NAZGUL_TEST_GH_STACK_CHECKOUT_STDERR:-gh stack checkout: simulated failure}" >&2
          exit "$exit_code"
        fi
        echo "Checked out stack."
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
# Symlink farm minus gh: on ubuntu runners gh lives in /usr/bin, so listing
# real bin dirs kept gh resolvable and this case passed for the wrong reason
# (real gh answering "no extension"). Farm construction mirrors test-stack-seam.
JQ_DIR=$(dirname "$(command -v jq)")
GIT_DIR=$(dirname "$(command -v git)")
NOGH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-nogh-XXXXXX")
for _d in "$JQ_DIR" "$GIT_DIR" /usr/bin /bin; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _b=$(basename "$_f")
    [ "$_b" = "gh" ] && continue
    [ -e "$NOGH_DIR/$_b" ] || ln -s "$_f" "$NOGH_DIR/$_b" 2>/dev/null || true
  done
done
NO_GH_PATH="$NOGH_DIR"

export PATH="$FAKEBIN:$PATH"

resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  teardown_temp_dir; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/stack-utils.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/heartbeat-triage.sh"

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

# =====================================================================
# stack_available — halt marker (TASK-005) is its OWN state, not "missing"
# (TASK-013): folding it into "missing" made every caller unable to say WHY it
# stopped, and made the halted branch of the heartbeat cap gate untestable.
# =====================================================================

HALTED_CONFIG="$TEST_DIR/nazgul/config-halted.json"
jq '.execution.stacking.enabled = true | .execution.stacking.halted = true | .execution.stacking.halt_reason = "conflict"' "$CONFIG" > "$HALTED_CONFIG"
assert_eq "stack_available: halted is its own state, distinct from missing tooling" \
  "$(stack_available "$HALTED_CONFIG")" "halted"
stack_available "$HALTED_CONFIG" >/dev/null; assert_exit_code "stack_available: halted returns 3" "$?" 3

# Unparseable config: NOT "disabled" (a corrupt config is not an opt-out).
INVALID_CONFIG="$TEST_DIR/nazgul/config-invalid.json"
printf '{ this is not json' > "$INVALID_CONFIG"
assert_eq "stack_available: unparseable config -> invalid, never 'disabled'" \
  "$(stack_available "$INVALID_CONFIG" 2>/dev/null)" "invalid"
stack_available "$INVALID_CONFIG" >/dev/null 2>&1; assert_exit_code "stack_available: invalid returns 4" "$?" 4
assert_contains "stack_available: unparseable config is loud on stderr" \
  "$(stack_available "$INVALID_CONFIG" 2>&1 >/dev/null)" "not parseable JSON"

# =====================================================================
# stack_reconcile / stack_detect_changes_requested — no-op when not "ready"
# =====================================================================

# _event_count <type> -> how many <type> events are on the bus. A MISSING
# events.jsonl prints "no-events-file", NEVER 0: "the bus recorded none of
# these" and "nothing ever wrote to the bus" are different answers, and every
# `... -> no events emitted` assertion below passes identically under both if
# they are collapsed — the whole suite's emit path could be broken and the
# zero-assertions would still be green (audit-tests.md, coverage honesty).
# Every such assertion truncates the file first, so the file exists by then.
_event_count() {
  local type="$1"
  [ -f "$EVENTS_FILE_PATH" ] || { echo "no-events-file"; return; }
  jq -s --arg t "$type" '[.[] | select(.event==$t)] | length' "$EVENTS_FILE_PATH" 2>/dev/null || echo "count-failed"
}

assert_eq "_event_count self-check: a MISSING events.jsonl is named, never reported as 0" \
  "$( EVENTS_FILE_PATH="$TEST_DIR/nazgul/logs/no-such-bus.jsonl"; _event_count stack_layer_merged )" \
  "no-events-file"

NOTREADY_CONFIG="$TEST_DIR/nazgul/config-notready.json"
jq --arg br "feat/FEAT-900-x" '
  .execution.stacking.enabled = false
  | .stack.layers = [{feat_id:"FEAT-900", branch:$br, pr:"https://github.com/o/r/pull/900", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$NOTREADY_CONFIG"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$NOTREADY_CONFIG"; notready_reconcile_rc=$?
stack_detect_changes_requested "$NOTREADY_CONFIG"; notready_detect_rc=$?
assert_exit_code "stack_reconcile: disabled config -> no-op, returns 0" "$notready_reconcile_rc" 0
assert_exit_code "stack_detect_changes_requested: disabled config -> no-op, returns 0" "$notready_detect_rc" 0
assert_eq "stack_reconcile/detect: disabled -> layer untouched (still open)" \
  "$(jq -r '.stack.layers[0].state' "$NOTREADY_CONFIG")" "open"
assert_eq "stack_reconcile/detect: disabled -> no events emitted" \
  "$(_event_count stack_layer_merged)" "0"

# =====================================================================
# stack_reconcile — happy path: merged bottom layer, base advance, event
# =====================================================================

REC_CONFIG="$TEST_DIR/nazgul/config-reconcile.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [
      {feat_id:"FEAT-300", branch:"feat/FEAT-300-x", pr:"https://github.com/o/r/pull/300", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null},
      {feat_id:"FEAT-301", branch:"feat/FEAT-301-y", pr:"https://github.com/o/r/pull/301", base:"feat/FEAT-300-x", state:"open", opened_at:"2026-08-02T01:00:00Z", merged_at:null}
    ]
' "$CONFIG" > "$REC_CONFIG"

PR_VIEW_MAP="$TEST_DIR/pr-view-map.tsv"
printf 'https://github.com/o/r/pull/300\t{"number":300,"state":"MERGED","mergedAt":"2026-08-02T05:00:00Z"}\n' > "$PR_VIEW_MAP"
printf 'https://github.com/o/r/pull/301\t{"number":301,"state":"OPEN","mergedAt":null}\n' >> "$PR_VIEW_MAP"
export NAZGUL_TEST_GH_PR_VIEW_JSON_MAP="$PR_VIEW_MAP"

: > "$EVENTS_FILE_PATH"
SYNC_LOG="$TEST_DIR/sync-calls.log"
export NAZGUL_TEST_GH_STACK_SYNC_LOG="$SYNC_LOG"
stack_reconcile "$REC_CONFIG"; reconcile_rc=$?
assert_exit_code "stack_reconcile (happy path): returns 0" "$reconcile_rc" 0
assert_eq "stack_reconcile: merged layer marked state=merged" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-300") | .state' "$REC_CONFIG")" "merged"
assert_eq "stack_reconcile: merged layer merged_at from gh pr view" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-300") | .merged_at' "$REC_CONFIG")" "2026-08-02T05:00:00Z"
assert_eq "stack_reconcile: layer above advances base to the merged layer's OWN base" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-301") | .base' "$REC_CONFIG")" "main"
assert_eq "stack_reconcile: layer above stays open" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-301") | .state' "$REC_CONFIG")" "open"
assert_eq "stack_reconcile: gh stack sync invoked exactly once" \
  "$(wc -l < "$SYNC_LOG" | tr -d ' ')" "1"
assert_eq "stack_reconcile: emits stack_layer_merged exactly once" "$(_event_count stack_layer_merged)" "1"
assert_contains "stack_reconcile: stack_layer_merged event names the feat_id" \
  "$(cat "$EVENTS_FILE_PATH")" '"feat_id":"FEAT-300"'
assert_eq "stack_reconcile: no conflict/api-failure events on the happy path" \
  "$(_event_count stack_sync_conflict)$(_event_count stack_api_failure)" "00"

# Idempotency: second call sees only one still-open, unmerged layer -> no sync, no new events.
stack_reconcile "$REC_CONFIG"; reconcile_rc2=$?
assert_exit_code "stack_reconcile: idempotent second call returns 0" "$reconcile_rc2" 0
assert_eq "stack_reconcile: idempotent — gh stack sync NOT called again" \
  "$(wc -l < "$SYNC_LOG" | tr -d ' ')" "1"
assert_eq "stack_reconcile: idempotent — no additional stack_layer_merged event" \
  "$(_event_count stack_layer_merged)" "1"
unset NAZGUL_TEST_GH_STACK_SYNC_LOG NAZGUL_TEST_GH_PR_VIEW_JSON_MAP

# =====================================================================
# stack_reconcile — exit 4 / undocumented failure doctrine: bump, 3
# consecutive -> halt loudly, reset-on-success
# =====================================================================

API_CONFIG="$TEST_DIR/nazgul/config-api-fail.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [{feat_id:"FEAT-400", branch:"feat/FEAT-400-x", pr:"https://github.com/o/r/pull/400", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$API_CONFIG"

export NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL=1
: > "$EVENTS_FILE_PATH"
for expect in 1 2; do
  stack_reconcile "$API_CONFIG"; apirc=$?
  assert_exit_code "stack_reconcile: API-failure tick #$expect still returns 0 (loop unblocked)" "$apirc" 0
  assert_eq "stack_reconcile: api_failures bumped to $expect" \
    "$(jq -r '.execution.stacking.api_failures' "$API_CONFIG")" "$expect"
  assert_eq "stack_reconcile: not halted before 3 consecutive (#$expect)" \
    "$(jq -r '.execution.stacking.halted // false' "$API_CONFIG")" "false"
done
stack_reconcile "$API_CONFIG"; apirc3=$?
assert_exit_code "stack_reconcile: 3rd consecutive API failure still returns 0" "$apirc3" 0
assert_eq "stack_reconcile: halting ZEROES api_failures (the documented un-halt remediation must not re-break on the first failure after it)" \
  "$(jq -r '.execution.stacking.api_failures' "$API_CONFIG")" "0"
assert_eq "stack_reconcile: halting also clears the per-operation counters" \
  "$(jq -r '.execution.stacking.api_failures_by_op | length' "$API_CONFIG")" "0"
assert_eq "stack_reconcile: HALTED at 3 consecutive failures" \
  "$(jq -r '.execution.stacking.halted' "$API_CONFIG")" "true"
assert_eq "stack_reconcile: halt_reason names the API-failure path" \
  "$(jq -r '.execution.stacking.halt_reason' "$API_CONFIG")" "api_failures"
assert_eq "stack_reconcile: 3 stack_api_failure events emitted (loud, never silent)" \
  "$(_event_count stack_api_failure)" "3"

# A 4th call after halting is a no-op (stack_available now reports "halted").
stack_reconcile "$API_CONFIG"; apirc4=$?
assert_exit_code "stack_reconcile: post-halt call still returns 0" "$apirc4" 0
assert_eq "stack_reconcile: post-halt call does not bump the counter" \
  "$(jq -r '.execution.stacking.api_failures' "$API_CONFIG")" "0"
unset NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL

# reset-on-success: 2 failures then one success clears the counter to 0.
RESET_CONFIG="$TEST_DIR/nazgul/config-api-reset.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [{feat_id:"FEAT-401", branch:"feat/FEAT-401-x", pr:"https://github.com/o/r/pull/401", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$RESET_CONFIG"
export NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL=1
stack_reconcile "$RESET_CONFIG" >/dev/null
stack_reconcile "$RESET_CONFIG" >/dev/null
assert_eq "stack_reconcile (reset test): api_failures at 2 before the reset" \
  "$(jq -r '.execution.stacking.api_failures' "$RESET_CONFIG")" "2"
unset NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":401,"state":"OPEN","mergedAt":null}'
stack_reconcile "$RESET_CONFIG" >/dev/null
assert_eq "stack_reconcile: a subsequent success resets api_failures to 0" \
  "$(jq -r '.execution.stacking.api_failures' "$RESET_CONFIG")" "0"
assert_eq "stack_reconcile: reset — still not halted" \
  "$(jq -r '.execution.stacking.halted // false' "$RESET_CONFIG")" "false"
unset NAZGUL_TEST_GH_PR_VIEW_JSON

# =====================================================================
# stack_reconcile — overloaded exit 3 disambiguation + divergence-via-exit-0
# + undocumented exit 9 (ADR-018 binding adjustments)
# =====================================================================

_sync_doctrine_fixture() {
  local feat="$1" out="$TEST_DIR/nazgul/$1-config.json"
  jq --arg f "$feat" --arg pr "https://github.com/o/r/pull/$feat" --arg br "feat/$feat-x" '
    .execution.stacking.enabled = true
    | .stack.layers = [{feat_id: $f, branch: $br, pr: $pr, base: "main", state: "open", opened_at: "2026-08-02T00:00:00Z", merged_at: null}]
  ' "$CONFIG" > "$out" 2>/dev/null
  printf '%s\n' "$out"
}

# --- stale local tracking after `link` (exit 3, benign — NOT a conflict) ---
STALE_CONFIG=$(_sync_doctrine_fixture "FEAT-500")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":500,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=3
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="✗ local stack composition differs from remote"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$STALE_CONFIG" >/dev/null
assert_eq "stack_reconcile: overloaded exit 3 (stale tracking) — NOT halted" \
  "$(jq -r '.execution.stacking.halted // false' "$STALE_CONFIG")" "false"
assert_eq "stack_reconcile: stale tracking — no stack_sync_conflict event" \
  "$(_event_count stack_sync_conflict)" "0"
assert_file_not_exists "stack_reconcile: stale tracking — no conflict inbox item filed" \
  "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"

# --- genuine rebase conflict (exit 3, distinct message) ---
CONFLICT_CONFIG=$(_sync_doctrine_fixture "FEAT-501")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":501,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=3
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="Conflict detected rebasing onto main"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$CONFLICT_CONFIG" >/dev/null
assert_eq "stack_reconcile: genuine conflict (exit 3) — HALTED, never auto-resolved" \
  "$(jq -r '.execution.stacking.halted' "$CONFLICT_CONFIG")" "true"
assert_eq "stack_reconcile: genuine conflict — halt_reason" \
  "$(jq -r '.execution.stacking.halt_reason' "$CONFLICT_CONFIG")" "conflict"
assert_eq "stack_reconcile: genuine conflict — emits stack_sync_conflict" \
  "$(_event_count stack_sync_conflict)" "1"
assert_file_exists "stack_reconcile: genuine conflict — p1 inbox item filed" \
  "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"
assert_eq "stack_reconcile: conflict inbox item — priority 1" \
  "$(sed -n 's/^priority:[[:space:]]*//p' "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md" | head -1)" "1"
assert_eq "stack_reconcile: conflict inbox item — type stack-conflict" \
  "$(sed -n 's/^type:[[:space:]]*//p' "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md" | head -1)" "stack-conflict"

# --- silent-success divergence: exit 0, but stderr says it diverged/aborted.
# The fixture is now pasted VERBATIM from ADR-018:98-99 (glyphs, ellipsis and
# em-dash included). It used to be a from-memory reconstruction — glyphs
# dropped, em-dash flattened to a hyphen, ellipsis collapsed — of the probe's
# single most significant finding, which is exactly the string this doctrine
# stands on (audit-tests.md, fixture provenance). ---
ADR_DIVERGED_CLAUSE="⚠ Your local stack has diverged from the stack on GitHub ..."
ADR_ABORTED_CLAUSE="ℹ Sync aborted — no changes were made"
ADR_COMPOSITION_DIFFERS="✗ local stack composition differs from remote"

DIVERGE_CONFIG=$(_sync_doctrine_fixture "FEAT-502")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":502,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=0
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="$ADR_DIVERGED_CLAUSE $ADR_ABORTED_CLAUSE"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$DIVERGE_CONFIG" >/dev/null
assert_eq "stack_reconcile: divergence-via-exit-0 — HALTED despite exit 0 (never trust exit code alone)" \
  "$(jq -r '.execution.stacking.halted' "$DIVERGE_CONFIG")" "true"
assert_eq "stack_reconcile: divergence-via-exit-0 — emits stack_sync_conflict" \
  "$(_event_count stack_sync_conflict)" "1"

# --- Independent-trigger divergence cases (audit-tests.md missing test #2).
# The fixture above carries BOTH alternation branches of
# _su_classify_sync_result's first case, so deleting either one from the code
# left the suite green — the weakest of the five load-bearing behaviors. Each
# case below carries exactly ONE trigger, and each asserts the p1 inbox item
# (not just `halted`), because the filed item is what a human ever sees. The
# conflict item dedupes LIVE-only, so each case clears it first and a re-file
# is genuine, not a leftover. ---

_diverge_case() {
  # _diverge_case <feat_id> <sync_exit> <sync_stderr>
  rm -f "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"
  : > "$EVENTS_FILE_PATH"
  local cfg
  cfg=$(_sync_doctrine_fixture "$1")
  export NAZGUL_TEST_GH_PR_VIEW_JSON="{\"number\":${1#FEAT-},\"state\":\"MERGED\",\"mergedAt\":\"2026-08-02T06:00:00Z\"}"
  export NAZGUL_TEST_GH_STACK_SYNC_EXIT="$2"
  export NAZGUL_TEST_GH_STACK_SYNC_STDERR="$3"
  stack_reconcile "$cfg" >/dev/null 2>&1
  printf '%s\n' "$cfg"
}

_assert_conflict_filed() {
  # _assert_conflict_filed <label> <config> <body_fragment>
  local label="$1" cfg="$2" fragment="$3" item="$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"
  assert_eq "$label: HALTED" "$(jq -r '.execution.stacking.halted // false' "$cfg")" "true"
  assert_eq "$label: halt_reason is conflict" "$(jq -r '.execution.stacking.halt_reason' "$cfg")" "conflict"
  assert_eq "$label: emits stack_sync_conflict" "$(_event_count stack_sync_conflict)" "1"
  assert_file_exists "$label: p1 inbox item filed" "$item"
  assert_eq "$label: inbox item priority 1" \
    "$(sed -n 's/^priority:[[:space:]]*//p' "$item" 2>/dev/null | head -1)" "1"
  assert_eq "$label: inbox item type stack-conflict" \
    "$(sed -n 's/^type:[[:space:]]*//p' "$item" 2>/dev/null | head -1)" "stack-conflict"
  assert_contains "$label: inbox item quotes the vendor text that triggered it" \
    "$(cat "$item" 2>/dev/null)" "$fragment"
}

ONLY_DIVERGED_CONFIG=$(_diverge_case "FEAT-505" 0 "$ADR_DIVERGED_CLAUSE")
_assert_conflict_filed "divergence trigger A (exit 0, ONLY the diverged clause)" \
  "$ONLY_DIVERGED_CONFIG" "diverged from the stack on GitHub"

ONLY_ABORTED_CONFIG=$(_diverge_case "FEAT-506" 0 "$ADR_ABORTED_CLAUSE")
_assert_conflict_filed "divergence trigger B (exit 0, ONLY the Sync-aborted clause)" \
  "$ONLY_ABORTED_CONFIG" "Sync aborted"

# Exit 3 whose text carries BOTH the benign stale-tracking marker and the
# divergence one: divergence wins, per ADR-018's "regardless of exit code".
BOTH_TEXTS_CONFIG=$(_diverge_case "FEAT-507" 3 "$ADR_COMPOSITION_DIFFERS $ADR_DIVERGED_CLAUSE")
_assert_conflict_filed "divergence beats stale-tracking (exit 3, both texts present)" \
  "$BOTH_TEXTS_CONFIG" "diverged from the stack on GitHub"

# Exit 3 with NO stderr at all: the inner case's default arm. An unrecognized
# (or silent) failure on the documented conflict exit code must fail CLOSED —
# a mute tool is not a clean sync.
EMPTY_STDERR_CONFIG=$(_diverge_case "FEAT-508" 3 "")
assert_eq "exit 3 with EMPTY stderr: fails CLOSED as a conflict, never 'ok'" \
  "$(jq -r '.execution.stacking.halted // false' "$EMPTY_STDERR_CONFIG")" "true"
assert_file_exists "exit 3 with EMPTY stderr: p1 inbox item still filed" \
  "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"
rm -f "$TEST_DIR/nazgul/inbox/stack-sync-conflict.md"
: > "$EVENTS_FILE_PATH"

# --- undocumented exit 9 (observed on an auth failure) folds into API-failure ---
EXIT9_CONFIG=$(_sync_doctrine_fixture "FEAT-503")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":503,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=9
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="Stacked PRs are not enabled for this repository"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$EXIT9_CONFIG" >/dev/null
assert_eq "stack_reconcile: undocumented exit 9 — NOT treated as a conflict" \
  "$(jq -r '.execution.stacking.halted // false' "$EXIT9_CONFIG")" "false"
assert_eq "stack_reconcile: undocumented exit 9 — folds into api_failure (bumped to 1)" \
  "$(jq -r '.execution.stacking.api_failures' "$EXIT9_CONFIG")" "1"
assert_eq "stack_reconcile: undocumented exit 9 — emits stack_api_failure" \
  "$(_event_count stack_api_failure)" "1"
assert_contains "stack_reconcile: exit 9 event carries the raw exit code" \
  "$(cat "$EVENTS_FILE_PATH")" '"exit_code":9'

unset NAZGUL_TEST_GH_PR_VIEW_JSON NAZGUL_TEST_GH_STACK_SYNC_EXIT NAZGUL_TEST_GH_STACK_SYNC_STDERR

# =====================================================================
# stack_reconcile — remote-ahead layer import (ADR-018 binding adjustment #2:
# a clean sync must not be trusted to auto-import a remote-only layer;
# `_su_import_remote_layer` explicitly `gh stack checkout`s the PR the
# vendor's own "already contains #<N>" warning names)
# =====================================================================

# --- remote-ahead layer named in a clean sync's warning -> checked out + registered ---
REMOTE_CONFIG=$(_sync_doctrine_fixture "FEAT-504")
REMOTE_PR_VIEW_MAP="$TEST_DIR/pr-view-map-remote.tsv"
printf 'https://github.com/o/r/pull/FEAT-504\t{"number":504,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}\n' > "$REMOTE_PR_VIEW_MAP"
printf '12\t{"headRefName":"feat/FEAT-777-imported","baseRefName":"feat/FEAT-504-x","url":"https://github.com/o/r/pull/12"}\n' >> "$REMOTE_PR_VIEW_MAP"
export NAZGUL_TEST_GH_PR_VIEW_JSON_MAP="$REMOTE_PR_VIEW_MAP"
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=0
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="⚠ A stack on GitHub already contains #12, which is not in your local stack. Run 'gh stack checkout <pr>' to import the full stack"
CHECKOUT_LOG="$TEST_DIR/checkout-calls.log"
: > "$CHECKOUT_LOG"
export NAZGUL_TEST_GH_STACK_CHECKOUT_LOG="$CHECKOUT_LOG"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$REMOTE_CONFIG" >/dev/null
assert_eq "stack_reconcile: remote-ahead — gh stack checkout invoked for #12" \
  "$(cat "$CHECKOUT_LOG")" "checkout called: 12"
assert_eq "stack_reconcile: remote-ahead — registry gains the imported layer's branch" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="remote-pr-12") | .branch' "$REMOTE_CONFIG")" "feat/FEAT-777-imported"
assert_eq "stack_reconcile: remote-ahead — imported layer's base from gh pr view" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="remote-pr-12") | .base' "$REMOTE_CONFIG")" "feat/FEAT-504-x"
assert_eq "stack_reconcile: remote-ahead — imported layer starts open" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="remote-pr-12") | .state' "$REMOTE_CONFIG")" "open"
assert_eq "stack_reconcile: remote-ahead — registry pr field is the URL, same format stack_submit writes" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="remote-pr-12") | .pr' "$REMOTE_CONFIG")" "https://github.com/o/r/pull/12"
assert_eq "stack_reconcile: remote-ahead — emits stack_remote_layer_imported" \
  "$(_event_count stack_remote_layer_imported)" "1"
assert_eq "stack_reconcile: remote-ahead — NOT halted (benign, not a conflict)" \
  "$(jq -r '.execution.stacking.halted // false' "$REMOTE_CONFIG")" "false"
unset NAZGUL_TEST_GH_STACK_CHECKOUT_LOG NAZGUL_TEST_GH_PR_VIEW_JSON_MAP NAZGUL_TEST_GH_STACK_SYNC_STDERR

# --- checkout failure (exit 3, composition-differs flavor) -> loud, non-halting, retryable ---
CHECKOUT_FAIL_CONFIG=$(_sync_doctrine_fixture "FEAT-505")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":505,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=0
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="⚠ A stack on GitHub already contains #13, which is not in your local stack. Run 'gh stack checkout <pr>' to import the full stack"
export NAZGUL_TEST_GH_STACK_CHECKOUT_EXIT=3
export NAZGUL_TEST_GH_STACK_CHECKOUT_STDERR="✗ local stack composition differs from remote"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$CHECKOUT_FAIL_CONFIG" >/dev/null
assert_eq "stack_reconcile: remote-ahead checkout failure — NOT halted (benign/retryable, not a conflict)" \
  "$(jq -r '.execution.stacking.halted // false' "$CHECKOUT_FAIL_CONFIG")" "false"
assert_eq "stack_reconcile: remote-ahead checkout failure — registry NOT updated for #13" \
  "$(jq -r '[.stack.layers[] | select(.feat_id=="remote-pr-13")] | length' "$CHECKOUT_FAIL_CONFIG")" "0"
assert_eq "stack_reconcile: remote-ahead checkout failure — emits stack_remote_layer_import_failed" \
  "$(_event_count stack_remote_layer_import_failed)" "1"
assert_contains "stack_reconcile: remote-ahead checkout failure — event carries the exit code" \
  "$(cat "$EVENTS_FILE_PATH")" '"exit_code":3'
unset NAZGUL_TEST_GH_PR_VIEW_JSON NAZGUL_TEST_GH_STACK_CHECKOUT_EXIT NAZGUL_TEST_GH_STACK_CHECKOUT_STDERR NAZGUL_TEST_GH_STACK_SYNC_STDERR

# --- no-drift: clean sync with no remote-ahead warning -> no checkout, no import event ---
NODRIFT_CONFIG=$(_sync_doctrine_fixture "FEAT-506")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":506,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=0
NODRIFT_CHECKOUT_LOG="$TEST_DIR/checkout-calls-nodrift.log"
: > "$NODRIFT_CHECKOUT_LOG"
export NAZGUL_TEST_GH_STACK_CHECKOUT_LOG="$NODRIFT_CHECKOUT_LOG"
: > "$EVENTS_FILE_PATH"
stack_reconcile "$NODRIFT_CONFIG" >/dev/null
assert_eq "stack_reconcile: no-drift sync — gh stack checkout never invoked" \
  "$(cat "$NODRIFT_CHECKOUT_LOG")" ""
assert_eq "stack_reconcile: no-drift sync — no remote-layer-imported event" \
  "$(_event_count stack_remote_layer_imported)" "0"
unset NAZGUL_TEST_GH_STACK_CHECKOUT_LOG NAZGUL_TEST_GH_PR_VIEW_JSON NAZGUL_TEST_GH_STACK_SYNC_EXIT

# =====================================================================
# stack_detect_changes_requested — rework filing: idempotency, priority,
# archive-aware dedup, body size cap
# =====================================================================

REWORK_CONFIG="$TEST_DIR/nazgul/config-rework.json"
jq '
  .execution.stacking.enabled = true
  | .execution.stacking.rework_priority = 1
  | .stack.layers = [{feat_id:"FEAT-600", branch:"feat/FEAT-600-x", pr:"https://github.com/o/r/pull/600", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$REWORK_CONFIG"
INBOX_DIR="$TEST_DIR/nazgul/inbox"

export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":600,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_1","state":"CHANGES_REQUESTED","body":"please fix the null check"}]}'
: > "$EVENTS_FILE_PATH"
stack_detect_changes_requested "$REWORK_CONFIG"; detect_rc=$?
assert_exit_code "stack_detect_changes_requested: returns 0" "$detect_rc" 0
REWORK_FILE="$INBOX_DIR/stack-rework-pr600-REVIEW_1.md"
assert_file_exists "stack_detect_changes_requested: files exactly the expected candidate" "$REWORK_FILE"
assert_eq "rework item: priority (rework_priority)" \
  "$(sed -n 's/^priority:[[:space:]]*//p' "$REWORK_FILE" | head -1)" "1"
assert_eq "rework item: type stack-rework" \
  "$(sed -n 's/^type:[[:space:]]*//p' "$REWORK_FILE" | head -1)" "stack-rework"
assert_eq "rework item: branch: frontmatter" \
  "$(sed -n 's/^branch:[[:space:]]*//p' "$REWORK_FILE" | head -1)" "feat/FEAT-600-x"
assert_eq "rework item: pr: frontmatter" \
  "$(sed -n 's/^pr:[[:space:]]*//p' "$REWORK_FILE" | head -1)" "https://github.com/o/r/pull/600"
assert_contains "rework item: body carries the review content (data, not instructions)" \
  "$(cat "$REWORK_FILE")" "please fix the null check"
assert_eq "stack_detect_changes_requested: emits stack_rework_filed exactly once" \
  "$(_event_count stack_rework_filed)" "1"
assert_contains "stack_rework_filed event: names the review id" \
  "$(cat "$EVENTS_FILE_PATH")" '"review_id":"REVIEW_1"'

# Idempotency: same PR + review id, second call files nothing new.
stack_detect_changes_requested "$REWORK_CONFIG"; detect_rc2=$?
assert_exit_code "stack_detect_changes_requested: idempotent second call returns 0" "$detect_rc2" 0
assert_eq "stack_detect_changes_requested: idempotent — no second stack_rework_filed event" \
  "$(_event_count stack_rework_filed)" "1"

# Archive-aware dedup: once claimed (archived), re-detecting the SAME PR+review never re-files it.
mkdir -p "$INBOX_DIR/archive"
mv "$REWORK_FILE" "$INBOX_DIR/archive/stack-rework-pr600-REVIEW_1.md"
: > "$EVENTS_FILE_PATH"
stack_detect_changes_requested "$REWORK_CONFIG" >/dev/null
assert_file_not_exists "stack_detect_changes_requested: archived item is NOT re-filed to the inbox" "$REWORK_FILE"
assert_eq "stack_detect_changes_requested: archive-aware dedup — no event on a re-detect" \
  "$(_event_count stack_rework_filed)" "0"

# heartbeat_pick honors rework_priority (1) over a pre-existing priority-2 fixture.
# Clean slate: earlier scenarios in this file left their own p1 candidates
# (e.g. stack-sync-conflict.md) in this same inbox dir.
rm -f "$INBOX_DIR"/*.md
cat > "$INBOX_DIR/other-lower-priority-item.md" << 'MDEOF'
---
title: Some other lower-priority item
priority: 2
type: generic
---
Unrelated body text.
MDEOF
PICK2_CONFIG="$TEST_DIR/nazgul/config-pick2.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [{feat_id:"FEAT-601", branch:"feat/FEAT-601-x", pr:"https://github.com/o/r/pull/601", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$PICK2_CONFIG"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":601,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_2","state":"CHANGES_REQUESTED","body":"another fix needed"}]}'
stack_detect_changes_requested "$PICK2_CONFIG" >/dev/null
assert_eq "heartbeat_pick: priority-1 rework item outranks the priority-2 fixture" \
  "$(heartbeat_pick "$INBOX_DIR")" "stack-rework-pr601-REVIEW_2.md"

# Body size cap: a long review body is clamped to connectors.github.pull.max_body_bytes.
CAP_CONFIG="$TEST_DIR/nazgul/config-cap.json"
jq '
  .execution.stacking.enabled = true
  | .connectors.github.pull.max_body_bytes = 50
  | .stack.layers = [{feat_id:"FEAT-602", branch:"feat/FEAT-602-x", pr:"https://github.com/o/r/pull/602", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$CAP_CONFIG"
LONG_BODY=$(printf 'A%.0s' $(seq 1 200))
export NAZGUL_TEST_GH_PR_VIEW_JSON="{\"number\":602,\"reviewDecision\":\"CHANGES_REQUESTED\",\"reviews\":[{\"id\":\"REVIEW_3\",\"state\":\"CHANGES_REQUESTED\",\"body\":\"$LONG_BODY\"}]}"
stack_detect_changes_requested "$CAP_CONFIG" >/dev/null
CAP_FILE="$INBOX_DIR/stack-rework-pr602-REVIEW_3.md"
assert_file_exists "body cap: rework item filed" "$CAP_FILE"
CAP_BODY_TEXT=$(awk 'BEGIN{fence=0} /^---$/{fence++; next} fence>=2{print}' "$CAP_FILE")
assert_eq "body cap: review body clamped to max_body_bytes (50 'A's, not 200)" \
  "$(printf '%s' "$CAP_BODY_TEXT" | grep -o 'A' | wc -l | tr -d ' ')" "50"

unset NAZGUL_TEST_GH_PR_VIEW_JSON

# =====================================================================
# TASK-013 — audit remediation. Every assertion below was written against the
# PRE-FIX tree first and observed to FAIL there (red-run evidence in
# nazgul/tasks/TASK-013.md).
# =====================================================================

# --- Extension detection must not depend on pipeline timing. `gh extension
# list | grep -q` lets grep exit at the first match, so gh takes SIGPIPE on its
# remaining output and, under a caller's `set -o pipefail` (scripts/heartbeat.sh
# and scripts/doctor.sh both set it), the pipeline reports 141 — an INSTALLED
# extension read as "missing", silently un-stacking the run. This mock makes the
# race deterministic by delaying the line after the match. ---
SLOWBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-slowgh-XXXXXX")
cat > "$SLOWBIN/gh" << 'SLOWEOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    [ "${1:-}" = "list" ] || exit 1
    printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'
    sleep 0.3
    printf 'gh other-ext\tsome/other\tv1.0.0\n'
    exit 0 ;;
  auth) [ "${1:-}" = "status" ] && exit 0; exit 1 ;;
esac
exit 1
SLOWEOF
chmod +x "$SLOWBIN/gh"
SIGPIPE_CONFIG="$TEST_DIR/nazgul/config-sigpipe.json"
jq '.execution.stacking.enabled = true' "$CONFIG" > "$SIGPIPE_CONFIG"
sigpipe_result=$(set -o pipefail; PATH="$SLOWBIN:$PATH" stack_available "$SIGPIPE_CONFIG" 2>/dev/null)
assert_eq "stack_available: an installed extension stays 'ready' under pipefail even when gh is slow to finish writing" \
  "$sigpipe_result" "ready"
rm -rf "$SLOWBIN"

# --- Registry honesty: a malformed stack.layers[] is refused by every reader,
# never reported as an empty stack (RULES §15). ---
MALFORMED_REG="$TEST_DIR/nazgul/config-malformed-reg.json"
jq '.branch.base = "main" | .execution.stacking.enabled = true | .stack.layers = "not-an-array"' "$CONFIG" > "$MALFORMED_REG"

tip_out=$(stack_tip "$MALFORMED_REG" 2>/dev/null); tip_rc=$?
assert_exit_code "stack_tip: malformed registry returns non-zero" "$tip_rc" 2
assert_eq "stack_tip: malformed registry prints NO branch (never a silent fallback to branch.base)" "$tip_out" ""
assert_contains "stack_tip: malformed registry is loud on stderr" \
  "$(stack_tip "$MALFORMED_REG" 2>&1 >/dev/null)" "malformed"

count_out=$(stack_unmerged_count "$MALFORMED_REG" 2>/dev/null); count_rc=$?
assert_exit_code "stack_unmerged_count: malformed registry returns non-zero" "$count_rc" 2
assert_eq "stack_unmerged_count: malformed registry prints NO count (a vacuous cap is worse than none)" "$count_out" ""

stack_reconcile "$MALFORMED_REG" >/dev/null 2>&1; mal_rec_rc=$?
assert_exit_code "stack_reconcile: malformed registry returns non-zero, never a silent no-op" "$mal_rec_rc" 1
stack_detect_changes_requested "$MALFORMED_REG" >/dev/null 2>&1; mal_det_rc=$?
assert_exit_code "stack_detect_changes_requested: malformed registry returns non-zero" "$mal_det_rc" 1

# Non-object layer entries are malformed too (not just a non-array .stack.layers).
MALFORMED_ENTRY_REG="$TEST_DIR/nazgul/config-malformed-entry.json"
jq '.branch.base = "main" | .stack.layers = ["FEAT-001"]' "$CONFIG" > "$MALFORMED_ENTRY_REG"
stack_tip "$MALFORMED_ENTRY_REG" >/dev/null 2>&1
assert_exit_code "stack_tip: a non-object layer entry is malformed too" "$?" 2

# --- Duplicate feat_id: first match only, and named on stderr. ---
DUP_CONFIG="$TEST_DIR/nazgul/config-dup-featid.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [
      {feat_id:"FEAT-800", branch:"feat/FEAT-800-a", pr:"https://github.com/o/r/pull/800", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null},
      {feat_id:"FEAT-800", branch:"feat/FEAT-800-b", pr:"https://github.com/o/r/pull/800", base:"main", state:"open", opened_at:"2026-08-02T01:00:00Z", merged_at:null}
    ]
' "$CONFIG" > "$DUP_CONFIG"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":800,"state":"MERGED","mergedAt":"2026-08-02T09:00:00Z"}'
dup_err=$(stack_reconcile "$DUP_CONFIG" 2>&1 >/dev/null)
assert_contains "duplicate feat_id: reconcile names the duplication on stderr" "$dup_err" "registry entries share feat_id"
assert_eq "duplicate feat_id: exactly ONE entry marked merged (first match), not a blanket rewrite" \
  "$(jq '[.stack.layers[] | select(.state == "merged")] | length' "$DUP_CONFIG")" "1"
assert_eq "duplicate feat_id: the FIRST entry is the one marked" \
  "$(jq -r '.stack.layers[0].state' "$DUP_CONFIG")" "merged"
unset NAZGUL_TEST_GH_PR_VIEW_JSON

# --- _su_halt_stacking: a halt it could not persist is a LOUD failure, never
# a silent success after announcing the halt. ---
halt_err=$(_su_halt_stacking "$TEST_DIR/nazgul/definitely-not-here.json" "conflict" 2>&1); halt_rc=$?
assert_exit_code "_su_halt_stacking: unwritable target returns non-zero" "$halt_rc" 1
assert_contains "_su_halt_stacking: unwritable target says the halt did NOT persist" "$halt_err" "NOT persisted"

# --- Per-operation counter scoping: one broken PR alongside a healthy one used
# to reset-then-bump forever, so the three-strikes halt was UNREACHABLE. ---
SCOPE_CONFIG="$TEST_DIR/nazgul/config-counter-scope.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [
      {feat_id:"FEAT-810", branch:"feat/FEAT-810-ok", pr:"https://github.com/o/r/pull/810", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null},
      {feat_id:"FEAT-811", branch:"feat/FEAT-811-broken", pr:"https://github.com/o/r/pull/811", base:"main", state:"open", opened_at:"2026-08-02T01:00:00Z", merged_at:null}
    ]
' "$CONFIG" > "$SCOPE_CONFIG"
SCOPE_MAP="$TEST_DIR/pr-view-map-scope.tsv"
printf 'https://github.com/o/r/pull/810\t{"number":810,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}\n' > "$SCOPE_MAP"
export NAZGUL_TEST_GH_PR_VIEW_JSON_MAP="$SCOPE_MAP"
export NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL=1
for _i in 1 2 3; do stack_detect_changes_requested "$SCOPE_CONFIG" >/dev/null 2>&1; done
unset NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL NAZGUL_TEST_GH_PR_VIEW_JSON_MAP
assert_eq "counter scoping: a healthy layer no longer resets the broken layer's count away — 3 ticks HALT" \
  "$(jq -r '.execution.stacking.halted // false' "$SCOPE_CONFIG")" "true"

# One tick bumps at most ONCE per operation, even with several failing layers.
ONEBUMP_CONFIG="$TEST_DIR/nazgul/config-one-bump.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [
      {feat_id:"FEAT-820", branch:"feat/FEAT-820-a", pr:"https://github.com/o/r/pull/820", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null},
      {feat_id:"FEAT-821", branch:"feat/FEAT-821-b", pr:"https://github.com/o/r/pull/821", base:"main", state:"open", opened_at:"2026-08-02T01:00:00Z", merged_at:null}
    ]
' "$CONFIG" > "$ONEBUMP_CONFIG"
export NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL=1
stack_detect_changes_requested "$ONEBUMP_CONFIG" >/dev/null 2>&1
unset NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL
assert_eq "counter scoping: two failing layers in ONE tick bump the detect counter exactly once" \
  "$(jq -r '.execution.stacking.api_failures_by_op.detect' "$ONEBUMP_CONFIG")" "1"

# The legacy scalar is a migration seed, NOT a per-key fallback: reconcile has
# already failed twice (mirrored into api_failures), and detect's FIRST failure
# must start at 1 rather than inheriting reconcile's 2 and halting on strike 3.
LEAK_CONFIG="$TEST_DIR/nazgul/config-counter-leak.json"
jq '
  .execution.stacking.enabled = true
  | .execution.stacking.api_failures_by_op = {reconcile: 2}
  | .execution.stacking.api_failures = 2
' "$CONFIG" > "$LEAK_CONFIG"
_su_bump_api_failures "$LEAK_CONFIG" "detect" >/dev/null 2>&1
assert_eq "counter scoping: an operation's first failure does not inherit another operation's count" \
  "$(jq -r '.execution.stacking.api_failures_by_op.detect' "$LEAK_CONFIG")" "1"
assert_eq "counter scoping: reconcile's own count is untouched by detect's bump" \
  "$(jq -r '.execution.stacking.api_failures_by_op.reconcile' "$LEAK_CONFIG")" "2"
assert_eq "counter scoping: detect's first failure does not trip the three-strikes halt" \
  "$(jq -r '.execution.stacking.halted // false' "$LEAK_CONFIG")" "false"

# --- needs_sync: a cascade interrupted by a conflict is retried on the next
# ready tick instead of being forgotten. ---
NEEDSYNC_CONFIG=$(_sync_doctrine_fixture "FEAT-830")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":830,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=3
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="Conflict detected rebasing onto main"
NEEDSYNC_LOG="$TEST_DIR/sync-calls-needsync.log"
: > "$NEEDSYNC_LOG"
export NAZGUL_TEST_GH_STACK_SYNC_LOG="$NEEDSYNC_LOG"
stack_reconcile "$NEEDSYNC_CONFIG" >/dev/null 2>&1
assert_eq "needs_sync: a conflicted cascade records the debt" \
  "$(jq -r '.execution.stacking.needs_sync' "$NEEDSYNC_CONFIG")" "true"
# Human clears the halt; nothing new merged this tick, but the cascade still owes work.
jq '.execution.stacking.halted = false' "$NEEDSYNC_CONFIG" > "$NEEDSYNC_CONFIG.tmp" && mv "$NEEDSYNC_CONFIG.tmp" "$NEEDSYNC_CONFIG"
unset NAZGUL_TEST_GH_STACK_SYNC_EXIT NAZGUL_TEST_GH_STACK_SYNC_STDERR
stack_reconcile "$NEEDSYNC_CONFIG" >/dev/null 2>&1
assert_eq "needs_sync: the next ready tick retries the deferred gh stack sync" \
  "$(wc -l < "$NEEDSYNC_LOG" | tr -d ' ')" "2"
assert_eq "needs_sync: a clean cascade clears the marker" \
  "$(jq -r '.execution.stacking.needs_sync' "$NEEDSYNC_CONFIG")" "false"
unset NAZGUL_TEST_GH_STACK_SYNC_LOG NAZGUL_TEST_GH_PR_VIEW_JSON

# --- Conflict inbox: an ARCHIVED first conflict must not suppress the NEXT one. ---
rm -f "$INBOX_DIR/stack-sync-conflict.md"
mkdir -p "$INBOX_DIR/archive"
: > "$INBOX_DIR/archive/stack-sync-conflict.md"
CONFLICT2_CONFIG=$(_sync_doctrine_fixture "FEAT-840")
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":840,"state":"MERGED","mergedAt":"2026-08-02T06:00:00Z"}'
export NAZGUL_TEST_GH_STACK_SYNC_EXIT=3
export NAZGUL_TEST_GH_STACK_SYNC_STDERR="Conflict detected rebasing onto main"
stack_reconcile "$CONFLICT2_CONFIG" >/dev/null 2>&1
assert_file_exists "conflict inbox: a SECOND conflict is filed even though the first is archived" \
  "$INBOX_DIR/stack-sync-conflict.md"
assert_contains "conflict inbox: body names the api_failures counter the remediation must also clear" \
  "$(cat "$INBOX_DIR/stack-sync-conflict.md")" "api_failures"
unset NAZGUL_TEST_GH_PR_VIEW_JSON NAZGUL_TEST_GH_STACK_SYNC_EXIT NAZGUL_TEST_GH_STACK_SYNC_STDERR
rm -f "$INBOX_DIR/archive/stack-sync-conflict.md" "$INBOX_DIR/stack-sync-conflict.md"

# --- Rework filing that FAILS to write is loud (a dropped p1 was silent). ---
if [ "$(id -u)" -ne 0 ]; then
  RO_INBOX_CONFIG="$TEST_DIR/nazgul-roinbox/config.json"
  mkdir -p "$TEST_DIR/nazgul-roinbox/inbox"
  jq '
    .execution.stacking.enabled = true
    | .stack.layers = [{feat_id:"FEAT-850", branch:"feat/FEAT-850-x", pr:"https://github.com/o/r/pull/850", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
  ' "$CONFIG" > "$RO_INBOX_CONFIG"
  export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":850,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_9","state":"CHANGES_REQUESTED","body":"fix it"}]}'
  chmod 500 "$TEST_DIR/nazgul-roinbox/inbox"
  : > "$EVENTS_FILE_PATH"
  ro_err=$(stack_detect_changes_requested "$RO_INBOX_CONFIG" 2>&1 >/dev/null)
  chmod 700 "$TEST_DIR/nazgul-roinbox/inbox"
  assert_contains "dropped p1: an unwritable inbox is named on stderr, never silently dropped" "$ro_err" "DROPPED"
  assert_eq "dropped p1: emits stack_rework_file_failed" "$(_event_count stack_rework_file_failed)" "1"
  unset NAZGUL_TEST_GH_PR_VIEW_JSON
else
  _skip "dropped p1 inbox-write failure (skipped: running as root, chmod 500 does not deny)"
fi

# --- The fail-closed contract at the REAL call site: NAZGUL_DIR unset. The
# stacking_unavailable signal used to be an emit_event alone, which no-ops
# without NAZGUL_DIR — the exact environment skills/start/SKILL.md and
# agents/review-gate.md invoke stack_submit in. ---
BR_NODIR="feat/FEAT-860-nodir"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_NODIR"
echo "nodir change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "nodir change"
SUB_NODIR="$TEST_DIR/nazgul/config-submit-nodir.json"
jq --arg feat "$BR_NODIR" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base | .feat_id = "FEAT-860"
  | .objectives_history = [{feat_id:"FEAT-860", objective:"nazgul-dir-unset test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = []
' "$CONFIG" > "$SUB_NODIR"
: > "$EVENTS_FILE_PATH"
NODIR_ERR=$(
  unset NAZGUL_DIR EVENTS_FILE
  export CLAUDE_PROJECT_DIR="$TEST_DIR"
  export NAZGUL_TEST_GH_STACK_EXT=0
  # Re-source in the subshell so emit-event.sh's module-level EVENTS_FILE is
  # recomputed from an UNSET NAZGUL_DIR — exactly as it resolves in production.
  unset _NAZGUL_STACK_UTILS_SOURCED
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/stack-utils.sh"
  stack_submit "$SUB_NODIR" "$TEST_DIR" "No-NAZGUL_DIR PR" "body" 2>&1 >/dev/null
)
assert_contains "NAZGUL_DIR unset: the degradation is announced on stderr, not only on the event bus" \
  "$NODIR_ERR" "fail-closed fallback"
assert_contains "NAZGUL_DIR unset: stack_submit still records the stop_gate event (root resolved on demand)" \
  "$(cat "$EVENTS_FILE_PATH" 2>/dev/null)" '"reason":"stacking_unavailable"'

# --- PR created, registry write failed: name the PR and the exact recovery. ---
BR_REGFAIL="feat/FEAT-861-regfail"
git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
git -C "$TEST_DIR" checkout -q -b "$BR_REGFAIL"
echo "regfail change" >> "$TEST_DIR/README.md"
git -C "$TEST_DIR" commit -qam "regfail change"
SUB_REGFAIL="$TEST_DIR/nazgul/config-submit-regfail.json"
jq --arg feat "$BR_REGFAIL" --arg base "$DEFAULT_BRANCH" '
  .execution.stacking.enabled = true
  | .branch.feature = $feat | .branch.base = $base | .feat_id = "FEAT-861"
  | .objectives_history = [{feat_id:"FEAT-861", objective:"register-after-pr test", started_at:"2026-08-02T00:00:00Z"}]
  | .stack.layers = []
' "$CONFIG" > "$SUB_REGFAIL"
REGFAIL_ERR=$(
  stack_register_layer() { return 1; }
  stack_submit "$SUB_REGFAIL" "$TEST_DIR" "Register fail PR" "body" 2>&1 >/dev/null
)
assert_contains "PR-then-register failure: names the PR that DOES exist" "$REGFAIL_ERR" "WAS CREATED"
assert_contains "PR-then-register failure: prints the exact recovery command" "$REGFAIL_ERR" "stack_register_layer"

# --- _su_write_history with no matching entry: a map over zero matches used to
# return success, so the caller's warning could never fire. ---
NOHIST_CONFIG="$TEST_DIR/nazgul/config-nohistory.json"
jq '.objectives_history = [{feat_id:"FEAT-OTHER", objective:"unrelated", started_at:"2026-08-02T00:00:00Z"}]' "$CONFIG" > "$NOHIST_CONFIG"
hist_err=$(_su_write_history "$NOHIST_CONFIG" "FEAT-870" "https://github.com/o/r/pull/870" 2>&1); hist_rc=$?
assert_exit_code "_su_write_history: zero matches is a failure, not a silent success" "$hist_rc" 1
assert_contains "_su_write_history: zero matches names the feat_id and the PR" "$hist_err" "FEAT-870"

# lean-comments: allow-run — names the host class this defends and why the suite could not see it.
# PATCH-007 item 15 — the stock-macOS host: a degradation line is not a payload.
# GNU `timeout` is absent from stock macOS by default, so bounded-net names its missing bound on
# stderr during an OTHERWISE SUCCESSFUL call. Capturing `2>&1` folded that line into the JSON, so
# every `jq` parse here came back empty: `stack_reconcile` read a MERGED layer as unmerged (no
# stack_layer_merged, no base advance, no sync) and `stack_detect_changes_requested` never saw a
# CHANGES_REQUESTED review, which is the SOLE trigger for the p1 rework item the feature promises.
# This suite never set NAZGUL_TIMEOUT_CMD, so the default host was the untested one.
export NAZGUL_TIMEOUT_CMD=""

NOBIN_REC="$TEST_DIR/nazgul/config-nobin-reconcile.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [{feat_id:"FEAT-900", branch:"feat/FEAT-900-x", pr:"https://github.com/o/r/pull/900", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$NOBIN_REC"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":900,"state":"MERGED","mergedAt":"2026-08-02T05:00:00Z"}'
: > "$EVENTS_FILE_PATH"
NOBIN_REC_ERR=$(stack_reconcile "$NOBIN_REC" 2>&1 >/dev/null); nobin_rec_rc=$?
assert_exit_code "no timeout binary: stack_reconcile returns 0" "$nobin_rec_rc" 0
assert_eq "no timeout binary: a MERGED layer is still seen as merged — a degradation line is not the payload" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-900") | .state' "$NOBIN_REC")" "merged"
assert_eq "no timeout binary: mergedAt survives the capture intact" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-900") | .merged_at' "$NOBIN_REC")" "2026-08-02T05:00:00Z"
assert_eq "no timeout binary: the merge is recorded on the bus, not silently skipped" \
  "$(_event_count stack_layer_merged)" "1"
assert_contains "no timeout binary: and the missing bound is still LOUD on the caller's real stderr" \
  "$NOBIN_REC_ERR" "unbounded_no_timeout_binary"
unset NAZGUL_TEST_GH_PR_VIEW_JSON

NOBIN_REW="$TEST_DIR/nazgul/config-nobin-rework.json"
jq '
  .execution.stacking.enabled = true
  | .execution.stacking.rework_priority = 1
  | .stack.layers = [{feat_id:"FEAT-901", branch:"feat/FEAT-901-x", pr:"https://github.com/o/r/pull/901", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$NOBIN_REW"
export NAZGUL_TEST_GH_PR_VIEW_JSON='{"number":901,"reviewDecision":"CHANGES_REQUESTED","reviews":[{"id":"REVIEW_901","state":"CHANGES_REQUESTED","body":"stock-host rework body"}]}'
: > "$EVENTS_FILE_PATH"
stack_detect_changes_requested "$NOBIN_REW" >/dev/null 2>&1
assert_file_exists "no timeout binary: the p1 rework item the feature promises is still filed" \
  "$TEST_DIR/nazgul/inbox/stack-rework-pr901-REVIEW_901.md"
assert_eq "no timeout binary: stack_rework_filed emitted exactly once" \
  "$(_event_count stack_rework_filed)" "1"
unset NAZGUL_TEST_GH_PR_VIEW_JSON

# A failure must still quote the HOST's error text, not lose it to the split capture.
# A fresh config: $NOBIN_REC's only layer is now merged, so it would ask the host nothing.
NOBIN_FAIL="$TEST_DIR/nazgul/config-nobin-apifail.json"
jq '
  .execution.stacking.enabled = true
  | .stack.layers = [{feat_id:"FEAT-902", branch:"feat/FEAT-902-x", pr:"https://github.com/o/r/pull/902", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$CONFIG" > "$NOBIN_FAIL"
export NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL=1
NOBIN_FAIL_ERR=$(stack_reconcile "$NOBIN_FAIL" 2>&1 >/dev/null)
assert_contains "no timeout binary: an API failure still quotes the host's own error text" \
  "$NOBIN_FAIL_ERR" "simulated API failure"
unset NAZGUL_TEST_GH_PR_VIEW_JSON_FAIL
unset NAZGUL_TIMEOUT_CMD

teardown_temp_dir
rm -rf "$FAKEBIN" "$NOGH_DIR"
report_results
