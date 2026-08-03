#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.

# Test: the stack registry's PRODUCER -> CONSUMER seam (FEAT-027 TASK-014,
# nazgul/reviews/AUDIT-FEAT-027/audit-tests.md, missing test #1).
#
# The "newest open layer" read is implemented three times — stack-utils.sh
# (stack_tip), session-context.sh (retyped inline), doctor.sh (retypes the whole
# precondition ladder) — and every existing consumer test feeds its reader a
# HAND-AUTHORED registry literal. Nothing pins the readers to the writer, so a
# producer format change ships green and breaks both readers in the field.
#
# So: this file builds the registry ONLY by calling the producers
# (stack_submit -> stack_register_layer; no `.stack.layers` literal is ever
# authored here), then points the real consumers at that same config and
# asserts they agree with stack_tip/stack_unmerged_count. The field-rename
# canary at the bottom is the red-capability proof — it renames a field the
# PRODUCER writes and asserts the agreement above stops holding, so those
# assertions cannot pass vacuously.
#
# `gh` is a PATH-shim mock; NO network. `git push` is real, against a local
# bare "origin".
TEST_NAME="test-stack-seam"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

DOCTOR="$REPO_ROOT/scripts/doctor.sh"
SESSION_CONTEXT="$REPO_ROOT/scripts/session-context.sh"

setup_temp_dir
setup_nazgul_dir
setup_git_repo
create_config '.guards.git_hooks = false' '.execution.stacking.enabled = true'
CONFIG="$TEST_DIR/nazgul/config.json"
PRISTINE="$TEST_DIR/registry-as-produced.json"
export NAZGUL_DIR="$TEST_DIR/nazgul"

DEFAULT_BRANCH=$(git -C "$TEST_DIR" branch --show-current)
git init -q --bare "$TEST_DIR/remote.git"
git -C "$TEST_DIR" remote add origin "$TEST_DIR/remote.git"
git -C "$TEST_DIR" push -q -u origin "$DEFAULT_BRANCH"

jq --arg b "$DEFAULT_BRANCH" '.branch.base = $b' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

# Fake `gh` first on PATH. Its dir is a colon-free mktemp (NOT under $TEST_DIR,
# whose name carries a literal ":" that would corrupt PATH parsing).
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-seam-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh for the seam test. Extension/auth/version state via env switches;
# `pr view` answers the two field shapes the code under test actually asks for:
# `--json url -q .url` (_su_stacked_pr) and `--json state -q .state` (doctor.sh).
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    case "${1:-}" in
      list)
        if [ "${NAZGUL_TEST_GH_STACK_EXT:-1}" != "0" ]; then
          printf 'gh stack\tgithub/gh-stack\t%s\n' "${NAZGUL_TEST_GH_STACK_VER-v0.1.0}"
        fi
        printf 'gh other-ext\tsome/other\tv1.0.0\n'
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  auth)
    case "${1:-}" in
      status) [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    action="${1:-}"; shift || true
    case "$action" in
      view)
        ident="${1:-}"; shift || true
        fields=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) fields="${2:-}"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$fields" in
          *url*) printf 'https://github.com/o/r/pull/%s\n' "$(printf '%s' "$ident" | tr -cd '0-9')" ;;
          *)     printf '%s\n' "${NAZGUL_TEST_GH_PR_STATE:-OPEN}" ;;
        esac
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stack)
    case "${1:-}" in
      submit) echo "Submitted stack."; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

# Saved before FAKEBIN is prepended: the one row of the availability table that
# needs `gh` genuinely absent (not merely shadowed) runs on this PATH.
JQ_DIR=$(dirname "$(command -v jq)")
GIT_DIR=$(dirname "$(command -v git)")
NO_GH_PATH="$JQ_DIR:$GIT_DIR:/usr/bin:/bin"

export PATH="$FAKEBIN:$PATH"
SEAM_PATH="$PATH"

resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  teardown_temp_dir; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

if (PATH="$NO_GH_PATH"; command -v gh >/dev/null 2>&1); then
  _fail "the no-gh PATH really has no gh (safety gate)" "gh is still resolvable on: $NO_GH_PATH"
else
  _pass "the no-gh PATH really has no gh (safety gate)"
fi

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/stack-utils.sh"

# =====================================================================
# Producer phase — the registry is built by CALLING stack_submit, which is
# the only writer path production ever uses. Nothing below authors a layer.
# =====================================================================

_produce_layer() {
  # _produce_layer <feat_id> <branch>
  local feat="$1" branch="$2"
  git -C "$TEST_DIR" checkout -q "$DEFAULT_BRANCH"
  git -C "$TEST_DIR" checkout -q -b "$branch"
  printf '%s\n' "$feat" >> "$TEST_DIR/README.md"
  git -C "$TEST_DIR" commit -qam "$feat change"
  jq --arg f "$feat" --arg br "$branch" '
    .feat_id = $f
    | .branch.feature = $br
    | .objectives_history = ((.objectives_history // []) + [{feat_id: $f, objective: "seam fixture", started_at: "2026-08-03T00:00:00Z"}])
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  stack_submit "$CONFIG" "$TEST_DIR" "$feat PR" "seam body" >/dev/null
}

BRANCH_A="feat/FEAT-901-alpha"
BRANCH_B="feat/FEAT-902-beta"
_produce_layer "FEAT-901" "$BRANCH_A"; produce_a_rc=$?
_produce_layer "FEAT-902" "$BRANCH_B"; produce_b_rc=$?
cp "$CONFIG" "$PRISTINE"

assert_exit_code "producer: first stack_submit succeeded" "$produce_a_rc" 0
assert_exit_code "producer: second stack_submit succeeded" "$produce_b_rc" 0
assert_eq "producer: registry entries carry a producer-generated opened_at (nothing here was hand-authored)" \
  "$(jq -r '[.stack.layers[] | select(.opened_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length' "$CONFIG")" "2"
assert_eq "producer: the second layer's base is the first layer's branch (stack_tip fed stack_submit)" \
  "$(jq -r '.stack.layers[] | select(.feat_id=="FEAT-902") | .base' "$CONFIG")" "$BRANCH_A"

# The two numbers every consumer below must reproduce, read through the
# library's own accessors rather than restated as literals.
LIB_TIP=$(stack_tip "$CONFIG")
LIB_COUNT=$(stack_unmerged_count "$CONFIG")
assert_eq "producer: stack_tip returns the newest open layer" "$LIB_TIP" "$BRANCH_B"
assert_eq "producer: stack_unmerged_count sees both open layers" "$LIB_COUNT" "2"

# =====================================================================
# Consumer agreement — doctor.sh and session-context.sh, run against the very
# config the producers wrote
# =====================================================================

_verdict_for() {
  awk -F'\t' -v id="$2" '$2 == id { print $1; exit }' <<<"$1"
}

_message_for() {
  awk -F'\t' -v id="$2" '$2 == id { print $3; exit }' <<<"$1"
}

DOC_OUT=$("$DOCTOR" 2>&1)
assert_eq "seam: doctor's stack-registry verdict on a producer-built registry" \
  "$(_verdict_for "$DOC_OUT" "stack-registry")" "pass"
assert_contains "seam: doctor names the layer count the producers actually wrote" \
  "$(_message_for "$DOC_OUT" "stack-registry")" "All $LIB_COUNT open stack.layers[] entries"

SC_OUT=$(bash "$SESSION_CONTEXT" </dev/null 2>&1)
assert_contains "seam: session-context names the same tip stack_tip returns" "$SC_OUT" "tip: $LIB_TIP"
assert_contains "seam: session-context reports the same open count as stack_unmerged_count" \
  "$SC_OUT" "Stack: $LIB_COUNT open"
assert_contains "seam: session-context resolves the tip layer's PR (registered by stack_submit)" \
  "$SC_OUT" "PR #$(jq -r --arg b "$LIB_TIP" '.stack.layers[] | select(.branch==$b) | .pr' "$CONFIG" | tr -cd '0-9') open"

# =====================================================================
# Availability agreement table — for every state stack_available can report,
# doctor's `stacking` verdict must be the matching one.
#
# The audit specified "doctor pass IFF stack_available says ready". Taken
# literally that is false and SHOULD be: `disabled` is also a doctor pass — a
# "Not applicable" one. Collapsing the two passes is exactly the never-looked/
# looked-and-found-nothing conflation this feature exists to avoid, so the
# biconditional is asserted on the OPERATIONAL pass (the "all ready" message)
# and the not-applicable pass is pinned separately by its own fragment.
# =====================================================================

_seam_avail() {
  # _seam_avail <env-assignments> <path>
  # shellcheck disable=SC2086
  env $1 PATH="$2" bash -c 'source "$1"; stack_available "$2"' _ \
    "$REPO_ROOT/scripts/lib/stack-utils.sh" "$CONFIG" 2>/dev/null
}

_seam_doctor() {
  # _seam_doctor <env-assignments> <path>
  # shellcheck disable=SC2086
  env $1 PATH="$2" "$DOCTOR" 2>&1
}

while IFS='|' read -r label cfg_jq envs path_mode exp_avail exp_verdict fragment; do
  [ -n "$label" ] || continue
  cp "$PRISTINE" "$CONFIG"
  jq "$cfg_jq" "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  case "$path_mode" in
    nogh) row_path="$NO_GH_PATH" ;;
    *)    row_path="$SEAM_PATH" ;;
  esac

  row_avail=$(_seam_avail "$envs" "$row_path")
  row_out=$(_seam_doctor "$envs" "$row_path")
  row_verdict=$(_verdict_for "$row_out" "stacking")
  row_message=$(_message_for "$row_out" "stacking")

  assert_eq "availability table [$label]: stack_available reports the state the fixture set up" \
    "$row_avail" "$exp_avail"
  assert_eq "availability table [$label]: doctor's stacking verdict matches that state" \
    "$row_verdict" "$exp_verdict"
  assert_contains "availability table [$label]: doctor names the precondition, never a bare verdict" \
    "$row_message" "$fragment"

  row_op_pass="no"
  if [ "$row_verdict" = "pass" ]; then
    case "$row_message" in *"are all ready"*) row_op_pass="yes" ;; esac
  fi
  exp_op_pass="no"
  [ "$exp_avail" = "ready" ] && exp_op_pass="yes"
  assert_eq "availability table [$label]: doctor reports an OPERATIONAL pass iff stack_available says ready" \
    "$row_op_pass" "$exp_op_pass"

  assert_eq "availability table [$label]: the producer-built registry survived the row's config edit byte-for-byte" \
    "$(jq -Sc '.stack' "$CONFIG")" "$(jq -Sc '.stack' "$PRISTINE")"
done << 'ROWS'
disabled|.execution.stacking.enabled = false||gh|disabled|pass|Not applicable
ready|.||gh|ready|pass|are all ready
halted|.execution.stacking.halted = true||gh|halted|warn|stacking is halted
missing-ext|.|NAZGUL_TEST_GH_STACK_EXT=0|gh|missing|warn|gh extension install github/gh-stack
unauthed|.|NAZGUL_TEST_GH_AUTH=fail|gh|missing|warn|gh auth login
missing-gh|.||nogh|missing|warn|gh is not on PATH
ROWS

# The seventh state: a config that does not parse at all. It cannot ride the
# table (the row's own jq edit would fail), and it is the one state where
# doctor must FAIL rather than warn.
cp "$PRISTINE" "$CONFIG"
printf '{ "execution": { "stacking": ' > "$CONFIG"
INVALID_AVAIL=$(_seam_avail "" "$SEAM_PATH")
INVALID_OUT=$(_seam_doctor "" "$SEAM_PATH")
assert_eq "availability table [invalid]: stack_available reports invalid, never 'disabled'" "$INVALID_AVAIL" "invalid"
assert_eq "availability table [invalid]: doctor FAILS on stacking" \
  "$(_verdict_for "$INVALID_OUT" "stacking")" "fail"
assert_eq "availability table [invalid]: doctor FAILS on stack-registry too" \
  "$(_verdict_for "$INVALID_OUT" "stack-registry")" "fail"
cp "$PRISTINE" "$CONFIG"

# =====================================================================
# Red-capability canary. Every assertion above would also pass against a
# consumer that read some OTHER field, or none at all. These two mutations
# rename a field the producer writes and assert the agreement stops holding —
# which is the thing the audit asked this file to guarantee: "MUST break when
# a producer's registry format changes".
# =====================================================================

jq '.stack.layers = [.stack.layers[] | {feat_id, head_branch: .branch, pr, base, state, opened_at, merged_at}]' \
  "$PRISTINE" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
CANARY_SC=$(bash "$SESSION_CONTEXT" </dev/null 2>&1)
assert_not_contains "canary: rename the layer's 'branch' field and session-context can no longer name the tip" \
  "$CANARY_SC" "tip: $LIB_TIP"
CANARY_TIP=$(stack_tip "$CONFIG")
assert_eq "canary: rename 'branch' and stack_tip falls back to branch.base — producer and reader are coupled through that name" \
  "$CANARY_TIP" "$DEFAULT_BRANCH"

jq '.stack.layers = [.stack.layers[] | {feat_id, branch, pr, base, status: .state, opened_at, merged_at}]' \
  "$PRISTINE" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
CANARY_DOC=$("$DOCTOR" 2>&1)
assert_not_contains "canary: rename the layer's 'state' field and doctor stops reporting the producer's layer count" \
  "$(_message_for "$CANARY_DOC" "stack-registry")" "All $LIB_COUNT open stack.layers[] entries"
assert_eq "canary: rename 'state' and stack_unmerged_count sees zero open layers (the cap would go vacuous)" \
  "$(stack_unmerged_count "$CONFIG")" "0"

# Restore and re-assert: the canary failures above are caused by the rename,
# not by anything the canary section did to the fixture on its way through.
cp "$PRISTINE" "$CONFIG"
RESTORED_SC=$(bash "$SESSION_CONTEXT" </dev/null 2>&1)
assert_contains "canary: restoring the producer's field names restores the agreement" "$RESTORED_SC" "tip: $LIB_TIP"

teardown_temp_dir
rm -rf "$FAKEBIN"
report_results
