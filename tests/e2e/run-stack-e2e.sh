#!/usr/bin/env bash
set -euo pipefail

# Live-GitHub E2E for FEAT-027 stacking: builds a real two-layer stack in a
# disposable scratch repo, merges the bottom layer via `gh stack merge`
# (plain `gh pr merge` is REJECTED for stacked layers — ADR-018 §4), verifies
# GitHub retargeted the upper PR server-side, then drives `stack_reconcile`
# and asserts the registry + events.jsonl reflect it. Exercises the REAL
# `scripts/lib/stack-utils.sh` functions, not a re-implementation.
#
# Costs real GitHub API calls and Actions minutes — runnable locally too.
#
# Env:
#   STACK_E2E_REPO  - existing "owner/name" repo to reuse (optional; skips
#                      create/delete of the repo, PRs still closed on exit)
#   STACK_E2E_OWNER - owner to create the disposable repo under when
#                      STACK_E2E_REPO is unset (defaults to the gh account)
#
# Skip-honestly doctrine: missing prerequisites (gh, jq, auth, gh-stack
# extension) FAIL LOUDLY with a named reason and a nonzero exit — never a
# vacuous pass, per RULES §1/§5.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAZGUL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "================================"
echo "  Nazgul Stack E2E Test"
echo "  WARNING: creates real branches"
echo "  and PRs against a live repo."
echo "================================"
echo ""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() {
  echo "--- $* ---"
}

command -v gh >/dev/null 2>&1 || fail "gh CLI not found — required for this E2E"
command -v jq >/dev/null 2>&1 || fail "jq not found — required for this E2E"
command -v git >/dev/null 2>&1 || fail "git not found — required for this E2E"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (gh auth status failed) — required for this E2E"
gh extension list 2>/dev/null | grep -q "github/gh-stack" || fail "gh-stack extension not installed (run: gh extension install github/gh-stack)"

WORKDIR=""
REPO_SLUG=""
CREATED_REPO=0
PR2_URL=""

cleanup() {
  local rc=$?
  step "Cleanup"
  if [ -n "$PR2_URL" ]; then
    gh pr close "$PR2_URL" --delete-branch >/dev/null 2>&1 \
      || echo "WARNING: could not close PR $PR2_URL — close it manually if it is still open." >&2
  fi
  if [ "$CREATED_REPO" -eq 1 ] && [ -n "$REPO_SLUG" ]; then
    if gh repo delete "$REPO_SLUG" --yes >/dev/null 2>&1; then
      echo "Deleted scratch repo $REPO_SLUG"
    else
      echo "WARNING: could not delete scratch repo $REPO_SLUG (likely missing delete_repo scope on the authenticated token)." >&2
      echo "Manual cleanup required: gh auth refresh -h github.com -s delete_repo && gh repo delete $REPO_SLUG --yes" >&2
    fi
  fi
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT

WORKDIR=$(mktemp -d) || fail "could not create a scratch working directory"
export NAZGUL_DIR="$WORKDIR"
CONFIG="$NAZGUL_DIR/config.json"

# shellcheck source=../../scripts/lib/stack-utils.sh
source "$NAZGUL_ROOT/scripts/lib/stack-utils.sh"

REPO_SLUG="${STACK_E2E_REPO:-}"
if [ -n "$REPO_SLUG" ]; then
  step "Using caller-supplied scratch repo: $REPO_SLUG"
else
  owner="${STACK_E2E_OWNER:-}"
  [ -n "$owner" ] || owner=$(gh api user -q '.login' 2>/dev/null) || owner=""
  [ -n "$owner" ] || fail "could not determine a GitHub owner (set STACK_E2E_OWNER, or ensure 'gh api user' works)"
  repo_name="nazgul-e2e-stack-$(date +%s)-$$"
  REPO_SLUG="$owner/$repo_name"
  step "Creating scratch repo $REPO_SLUG"
  gh repo create "$REPO_SLUG" --private --add-readme >/dev/null 2>&1 || fail "gh repo create $REPO_SLUG failed"
  CREATED_REPO=1
fi

REPO_DIR="$WORKDIR/repo"
step "Cloning $REPO_SLUG"
gh repo clone "$REPO_SLUG" "$REPO_DIR" >/dev/null 2>&1 || fail "gh repo clone $REPO_SLUG failed"
git -C "$REPO_DIR" config user.email "nazgul-e2e@example.com"
git -C "$REPO_DIR" config user.name "Nazgul Stack E2E"

TRUNK=$(gh repo view "$REPO_SLUG" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null) || TRUNK=""
[ -n "$TRUNK" ] && [ "$TRUNK" != "null" ] || fail "could not determine the default branch of $REPO_SLUG"
git -C "$REPO_DIR" checkout "$TRUNK" >/dev/null 2>&1 || fail "could not check out trunk branch '$TRUNK'"

jq -n --arg base "$TRUNK" \
  '{execution: {stacking: {enabled: true}}, branch: {base: $base, feature: null}, feat_id: null, stack: {layers: []}}' \
  > "$CONFIG" || fail "could not write scratch config.json"

FEAT1="E2E-STACK-1-$$"
BRANCH1="stack-e2e-layer1-$$"
FEAT2="E2E-STACK-2-$$"
BRANCH2="stack-e2e-layer2-$$"

step "Building layer 1 ($BRANCH1, base $TRUNK)"
git -C "$REPO_DIR" checkout -b "$BRANCH1" "$TRUNK" >/dev/null 2>&1 || fail "could not create branch $BRANCH1"
echo "layer 1" > "$REPO_DIR/layer1.txt"
git -C "$REPO_DIR" add layer1.txt
git -C "$REPO_DIR" commit -q -m "layer1: add layer1.txt" || fail "commit for layer1 failed"
jq --arg br "$BRANCH1" --arg f "$FEAT1" '.branch.feature = $br | .feat_id = $f' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

PR1_URL=$(stack_submit "$CONFIG" "$REPO_DIR" "E2E layer 1" "E2E stack test layer 1") || fail "stack_submit failed for layer 1"
[ -n "$PR1_URL" ] || fail "stack_submit for layer 1 returned no PR URL"
layer1_state=$(jq -r --arg f "$FEAT1" '[.stack.layers[]? | select(.feat_id == $f)][0].state // empty' "$CONFIG")
[ "$layer1_state" = "open" ] || fail "layer1 not registered as open after stack_submit (got '$layer1_state')"

BASE2=$(stack_tip "$CONFIG")
[ "$BASE2" = "$BRANCH1" ] || fail "stack_tip after layer1 submit expected '$BRANCH1', got '$BASE2'"

step "Building layer 2 ($BRANCH2, base $BASE2)"
git -C "$REPO_DIR" checkout -b "$BRANCH2" "$BASE2" >/dev/null 2>&1 || fail "could not create branch $BRANCH2"
echo "layer 2" > "$REPO_DIR/layer2.txt"
git -C "$REPO_DIR" add layer2.txt
git -C "$REPO_DIR" commit -q -m "layer2: add layer2.txt" || fail "commit for layer2 failed"
stack_register_layer "$CONFIG" "$FEAT2" "$BRANCH2" "$BASE2" || fail "stack_register_layer failed for layer 2"
jq --arg br "$BRANCH2" --arg f "$FEAT2" '.branch.feature = $br | .feat_id = $f' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

PR2_URL=$(stack_submit "$CONFIG" "$REPO_DIR" "E2E layer 2" "E2E stack test layer 2") || fail "stack_submit failed for layer 2"
[ -n "$PR2_URL" ] || fail "stack_submit for layer 2 returned no PR URL"

PR1_NUM=$(printf '%s' "$PR1_URL" | grep -o '[0-9]\+$') || fail "could not parse a PR number from $PR1_URL"

step "Merging bottom layer (PR #$PR1_NUM) via gh stack merge"
gh stack merge "$PR1_NUM" --yes --squash || fail "gh stack merge $PR1_NUM failed"

step "Verifying GitHub retargeted layer 2's PR to $TRUNK"
retargeted=""
attempt=1
while [ "$attempt" -le 5 ]; do
  retargeted=$(gh pr view "$PR2_URL" --json baseRefName -q '.baseRefName' 2>/dev/null) || retargeted=""
  [ "$retargeted" = "$TRUNK" ] && break
  sleep 3
  attempt=$((attempt + 1))
done
[ "$retargeted" = "$TRUNK" ] || fail "expected layer2 PR baseRefName to retarget to '$TRUNK' after the bottom merge, got '$retargeted'"

step "Running stack_reconcile"
stack_reconcile "$CONFIG" || fail "stack_reconcile returned nonzero"

halted=$(jq -r '.execution.stacking.halted // false' "$CONFIG")
[ "$halted" = "false" ] || fail "stack_reconcile unexpectedly halted stacking: $(jq -r '.execution.stacking.halt_reason // "unknown"' "$CONFIG")"

layer1_state=$(jq -r --arg f "$FEAT1" '[.stack.layers[]? | select(.feat_id == $f)][0].state // empty' "$CONFIG")
[ "$layer1_state" = "merged" ] || fail "stack_reconcile did not mark layer1 merged (state='$layer1_state')"

layer2_base=$(jq -r --arg f "$FEAT2" '[.stack.layers[]? | select(.feat_id == $f)][0].base // empty' "$CONFIG")
[ "$layer2_base" = "$TRUNK" ] || fail "stack_reconcile did not advance layer2's base to '$TRUNK' (got '$layer2_base')"

EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"
[ -f "$EVENTS_FILE" ] || fail "no events.jsonl was written by stack_reconcile"
merged_event=$(jq -c --arg f "$FEAT1" 'select(.event == "stack_layer_merged" and .feat_id == $f)' "$EVENTS_FILE" 2>/dev/null | head -1)
[ -n "$merged_event" ] || fail "no stack_layer_merged event found in events.jsonl for feat_id=$FEAT1"

echo ""
echo "PASS: two-layer stack E2E — layer1 merged via gh stack merge, layer2"
echo "PASS: retargeted server-side to '$TRUNK', stack_reconcile advanced the"
echo "PASS: registry and emitted stack_layer_merged."
