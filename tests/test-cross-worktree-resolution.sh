#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several assertions below deliberately capture a
# nonzero guard exit code via `|| ec=$?`.

# Test: FEAT-021's mandatory regression deliverable. Real `git worktree add`
# fixtures reproducing the live incident (2026-07-27): a guard invoked from a
# worktree session resolved `nazgul/` to the MAIN checkout and returned a
# confidently wrong answer. tests/lib/setup.sh's setup_temp_dir() hardcodes a
# single CLAUDE_PROJECT_DIR/nazgul/ pair, so no existing fixture can even
# represent "two different nazgul/ trees, one of which is the wrong answer."
TEST_NAME="test-cross-worktree-resolution"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/parallel-dispatch-guard.sh"
SESSION_CONTEXT="$REPO_ROOT/scripts/session-context.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

guard_ec() { # <cwd> <cpd|""> <unit>
  local cwd="$1" cpd="$2" unit="$3" ec=0
  (
    cd "$cwd" || exit 99
    if [ -n "$cpd" ]; then export CLAUDE_PROJECT_DIR="$cpd"; else unset CLAUDE_PROJECT_DIR; fi
    jq -n --arg u "$unit" '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:("NAZGUL_UNIT: " + $u)}}' \
      | bash "$GUARD" >/dev/null 2>&1
  ) || ec=$?
  echo "$ec"
}

guard_stderr() { # <cwd> <cpd|""> <unit>
  local cwd="$1" cpd="$2" unit="$3"
  (
    cd "$cwd" || exit 99
    if [ -n "$cpd" ]; then export CLAUDE_PROJECT_DIR="$cpd"; else unset CLAUDE_PROJECT_DIR; fi
    jq -n --arg u "$unit" '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:("NAZGUL_UNIT: " + $u)}}' \
      | bash "$GUARD" 2>&1 >/dev/null
  ) || true
}

# Reproduces the literal pre-FEAT-021 idiom every one of the 20 affected
# call sites used (scripts/parallel-dispatch-guard.sh, commit e0733c5, before
# scripts/lib/nazgul-root.sh existed): no git-toplevel awareness at all.
old_idiom_resolve() { # <cwd> <cpd|"">
  local cwd="$1" cpd="$2"
  (
    cd "$cwd" || exit 99
    if [ -n "$cpd" ]; then export CLAUDE_PROJECT_DIR="$cpd"; else unset CLAUDE_PROJECT_DIR; fi
    printf '%s/nazgul\n' "${CLAUDE_PROJECT_DIR:-$(pwd)}"
  )
}

# =====================================================================
# Primary fixture + sanity control + pre-fix demonstration
# =====================================================================
setup_temp_dir
setup_two_worktree_repo

# --- Primary (CLAUDE_PROJECT_DIR unset): the scenario ADR-008 confirms this
# objective's fix resolves — git-toplevel from the real cwd correctly finds
# the worktree's OWN nazgul/, reading TASK-007 as IN_PROGRESS (not the main
# checkout's DONE), so a legitimate re-dispatch is allowed.
assert_eq "primary (CLAUDE_PROJECT_DIR unset): worktree's own IN_PROGRESS task allows dispatch" \
  "$(guard_ec "$TWO_WT_WORKTREE" "" TASK-007)" "0"

# --- Primary (CLAUDE_PROJECT_DIR explicitly set, stale, to the main
# checkout): per the resolver's FINAL, amended contract (ADR-008, TASK-013 —
# "an explicit designation is never second-guessed"), an explicit
# CLAUDE_PROJECT_DIR wins UNCONDITIONALLY, even when it points at the wrong
# tree for this cwd. This is documented, intentional behavior, not a defect
# left open by this task: TASK-012 tried the opposite (git-toplevel checked
# first, silently overriding a valid explicit CLAUDE_PROJECT_DIR) and that
# was itself reverted as a regression. ADR-008's own "Correction to the
# first amendment's residual-risk claim" section states plainly that this
# scenario has "no operative mitigation" today and is deferred to a future
# objective-anchor (scope item 4). This assertion pins that CURRENT,
# intentional behavior — not the exit-0 outcome an earlier draft of this
# task's own acceptance criteria assumed before TASK-012/TASK-013 shipped;
# see this task's Implementation Log for the empirical trace.
assert_eq "primary (CLAUDE_PROJECT_DIR stale=main): explicit designation wins unconditionally, so main's DONE task still blocks (ADR-008 TASK-013 — intentional, not a defect)" \
  "$(guard_ec "$TWO_WT_WORKTREE" "$TWO_WT_MAIN" TASK-007)" "2"

# --- Sanity control: same fixture, cwd = the MAIN checkout itself, env
# unset — still correctly blocks on ITS OWN DONE task. Proves the fix reads
# whichever worktree it's actually in, not "always allow".
assert_eq "sanity control: cwd=main checkout still correctly blocks its own DONE task" \
  "$(guard_ec "$TWO_WT_MAIN" "" TASK-007)" "2"

# --- Pre-fix demonstration (AC 2a): a permanent, automated assertion that
# the pre-FEAT-021 idiom is load-bearing — it genuinely selects the wrong
# tree for this exact fixture, reproducing the live incident's reported
# symptom verbatim ("TASK-007 already DONE"). Uses the stale-CLAUDE_PROJECT_DIR
# scenario, since that is the one input on which the OLD idiom and a
# hypothetical "just use $(pwd)" idiom diverge from correctness; run from
# cwd=worktree, unset would trivially resolve correctly via $(pwd) alone
# and not demonstrate anything.
OLD_RESOLVED_DIR=$(old_idiom_resolve "$TWO_WT_WORKTREE" "$TWO_WT_MAIN")
assert_eq "pre-fix idiom (stale CLAUDE_PROJECT_DIR) resolves to the MAIN checkout's nazgul/, not the worktree's" \
  "$OLD_RESOLVED_DIR" "$TWO_WT_MAIN/nazgul"
OLD_STATUS=$(get_task_status "$OLD_RESOLVED_DIR/tasks/TASK-007.md" "")
assert_eq "pre-fix idiom demonstrably selects the MAIN checkout's DONE task, not the worktree's IN_PROGRESS one (AC 2a)" \
  "$OLD_STATUS" "DONE"

# =====================================================================
# Discriminating case (review round 1, architect + code-reviewer): every
# assertion above pins cwd exactly at a git-toplevel ($TWO_WT_WORKTREE or
# $TWO_WT_MAIN), where $(pwd) and `git rev-parse --show-toplevel` are
# IDENTICAL — so the pre-fix idiom and the shipped resolver return the same
# answer on every input tested so far and none of it regression-tests
# git-toplevel awareness itself. This section adds the one input where they
# genuinely diverge: cwd NESTED inside the worktree, CLAUDE_PROJECT_DIR
# unset. Routed through the real resolve_project_root() and the real guard
# — not the old_idiom_resolve() shim, which stays reserved for AC 2a above.
# =====================================================================
DEEP_SUBDIR="$TWO_WT_WORKTREE/src/deep/nested"
mkdir -p "$DEEP_SUBDIR"
_saved_test_dir="$TEST_DIR"
TEST_DIR="$TWO_WT_WORKTREE"
create_task_file TASK-101 DONE
TEST_DIR="$_saved_test_dir"

# macOS resolves /var -> /private/var on `git rev-parse --show-toplevel`
# (physical) but bash's logical `cd && pwd` does not — so RESOLVED_FROM_SUBDIR
# (git-backed) is compared against `pwd -P` (physical), while
# OLD_RESOLVED_FROM_SUBDIR (plain `$(pwd)`, matching old_idiom_resolve's own
# idiom) is compared against plain `pwd`, matching each side's own idiom.
TWO_WT_WORKTREE_PHYSICAL=$(cd "$TWO_WT_WORKTREE" && pwd -P)
DEEP_SUBDIR_LOGICAL=$(cd "$DEEP_SUBDIR" && pwd)

RESOLVED_FROM_SUBDIR=$(cd "$DEEP_SUBDIR" && unset CLAUDE_PROJECT_DIR && source "$REPO_ROOT/scripts/lib/nazgul-root.sh" && resolve_project_root)
assert_eq "discriminating case: resolve_project_root() from a nested subdir (CLAUDE_PROJECT_DIR unset) follows git-toplevel to the worktree root, not \$(pwd)" \
  "$RESOLVED_FROM_SUBDIR" "$TWO_WT_WORKTREE_PHYSICAL"

OLD_RESOLVED_FROM_SUBDIR="$(old_idiom_resolve "$DEEP_SUBDIR" "")"
assert_eq "discriminating case: the pre-fix idiom from the same nested subdir resolves to the nonexistent <subdir>/nazgul instead" \
  "$OLD_RESOLVED_FROM_SUBDIR" "$DEEP_SUBDIR_LOGICAL/nazgul"

assert_eq "discriminating case, through the real guard: dispatch from a nested subdir still correctly blocks the worktree's own DONE TASK-101" \
  "$(guard_ec "$DEEP_SUBDIR" "" TASK-101)" "2"

# =====================================================================
# Carried-forward item 1 (TASK-001 architect review, confidence 85): the
# REAL create_task_worktree() shape — a SIBLING directory, no own nazgul/.
# Proves the TASK-001 <-> TASK-008 dependency rather than assuming it.
# =====================================================================
SIBLING_ROOT="$(dirname "$TWO_WT_MAIN")/main-worktrees"
SIBLING_DIR="$SIBLING_ROOT/TASK-007"
mkdir -p "$SIBLING_ROOT"
git -C "$TWO_WT_MAIN" worktree add -q "$SIBLING_DIR" -b sibling-task-007

SIBLING_UNSET=$(cd "$SIBLING_DIR" && unset CLAUDE_PROJECT_DIR && source "$REPO_ROOT/scripts/lib/nazgul-root.sh" && resolve_project_root)
if [ "$SIBLING_UNSET" != "$TWO_WT_MAIN" ]; then
  _pass "sibling task-worktree shape, CLAUDE_PROJECT_DIR unset: resolution does NOT find the main checkout (no marker anywhere to guide it)"
else
  _fail "sibling task-worktree shape, CLAUDE_PROJECT_DIR unset: resolution does NOT find the main checkout" "resolved to the main checkout unexpectedly: $SIBLING_UNSET"
fi

SIBLING_EXPORTED=$(cd "$SIBLING_DIR" && export CLAUDE_PROJECT_DIR="$TWO_WT_MAIN" && source "$REPO_ROOT/scripts/lib/nazgul-root.sh" && resolve_project_root)
assert_eq "sibling task-worktree shape, CLAUDE_PROJECT_DIR correctly exported: resolves to the main checkout" \
  "$SIBLING_EXPORTED" "$TWO_WT_MAIN"

git -C "$TWO_WT_MAIN" worktree remove --force "$SIBLING_DIR" 2>/dev/null || true
git -C "$TWO_WT_MAIN" worktree prune 2>/dev/null || true

# =====================================================================
# AC 4 spot check: session-context.sh / stop-hook.sh read the WORKTREE's
# own plan.md/config.json, not the main checkout's. The main checkout
# deliberately gets NO plan.md at all, so any write there would prove a
# resolution defect on its own.
# =====================================================================
jq '.current_iteration = 42' "$TWO_WT_WORKTREE/nazgul/config.json" > "$TWO_WT_WORKTREE/nazgul/config.json.tmp" \
  && mv "$TWO_WT_WORKTREE/nazgul/config.json.tmp" "$TWO_WT_WORKTREE/nazgul/config.json"
jq '.current_iteration = 99' "$TWO_WT_MAIN/nazgul/config.json" > "$TWO_WT_MAIN/nazgul/config.json.tmp" \
  && mv "$TWO_WT_MAIN/nazgul/config.json.tmp" "$TWO_WT_MAIN/nazgul/config.json"

TEST_DIR="$TWO_WT_WORKTREE"
create_plan
create_task_file TASK-100 READY
TEST_DIR="$(dirname "$TWO_WT_MAIN")"

SC_OUT=$(cd "$TWO_WT_WORKTREE" && unset CLAUDE_PROJECT_DIR && bash "$SESSION_CONTEXT" 2>&1)
assert_contains "session-context.sh reads the worktree's own iteration, not the main checkout's" "$SC_OUT" "42/40"
assert_not_contains "session-context.sh does not surface the main checkout's iteration" "$SC_OUT" "99/40"

SC_OUT_SUBDIR=$(cd "$DEEP_SUBDIR" && unset CLAUDE_PROJECT_DIR && bash "$SESSION_CONTEXT" 2>&1)
assert_contains "discriminating case: session-context.sh from a nested subdir still reads the worktree's own iteration via git-toplevel" \
  "$SC_OUT_SUBDIR" "42/40"

(cd "$TWO_WT_WORKTREE" && unset CLAUDE_PROJECT_DIR && bash "$STOP_HOOK" </dev/null >/dev/null 2>&1) || true

assert_file_exists "stop-hook.sh wrote a checkpoint into the WORKTREE's own nazgul/" \
  "$TWO_WT_WORKTREE/nazgul/checkpoints/iteration-043.json"
assert_file_contains "stop-hook.sh updated the WORKTREE's own plan.md Recovery Pointer (active IN_PROGRESS task is the worktree's own TASK-007)" \
  "$TWO_WT_WORKTREE/nazgul/plan.md" "TASK-007"
assert_file_not_exists "stop-hook.sh never created a plan.md in the MAIN checkout" \
  "$TWO_WT_MAIN/nazgul/plan.md"
MAIN_CHECKPOINT_COUNT=$(find "$TWO_WT_MAIN/nazgul/checkpoints" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "stop-hook.sh never wrote a checkpoint into the MAIN checkout" "$MAIN_CHECKPOINT_COUNT" "0"

teardown_two_worktree_repo
teardown_temp_dir

# =====================================================================
# Ambiguity fail-open (AC 3) vs. fail-CLOSED corrupt-config (MF-053) — two
# separately-pinned postures in the same file, so neither can silently
# absorb the other's coverage.
# =====================================================================
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
create_config '.execution.parallel = true'
create_task_file_with_commits TASK-002 DONE "abc1234"

# Break resolution integrity: nazgul/tasks becomes a symlink pointing
# OUTSIDE nazgul/ — a real task manifest still exists at the far end (so a
# naive "just check the file exists" reading would happily block), but the
# guard cannot confirm TASKS_DIR is really a child of the resolved NAZGUL_DIR.
EXTERNAL_TASKS="$TEST_DIR/external-tasks"
mkdir -p "$EXTERNAL_TASKS"
cp "$TEST_DIR/nazgul/tasks/TASK-002.md" "$EXTERNAL_TASKS/TASK-002.md"
rm -rf "$TEST_DIR/nazgul/tasks"
ln -s "$EXTERNAL_TASKS" "$TEST_DIR/nazgul/tasks"

AMBIG_EC=0
jq -n '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-002"}}' \
  | bash "$GUARD" >/dev/null 2>&1 || AMBIG_EC=$?
assert_eq "ambiguity fail-open: unconfirmed tasks-dir resolution ALLOWS dispatch (exit 0)" "$AMBIG_EC" "0"

AMBIG_STDERR=$(jq -n '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-002"}}' \
  | bash "$GUARD" 2>&1 >/dev/null || true)
assert_contains "ambiguity fail-open: exact stderr string is observable" "$AMBIG_STDERR" \
  "NAZGUL PARALLEL: Allowed — TASK-002 failed the tasks-dir resolution-integrity check (not an objective-identity check); failing open per PRD AC 3."

EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
jq -n '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-002"}}' \
  | bash "$GUARD" >/dev/null 2>&1 || true
assert_file_exists "ambiguity fail-open: telemetry event file written" "$EVENTS_FILE"
assert_eq "ambiguity fail-open: telemetry event type is dispatch_guard_resolution_unconfirmed" \
  "$(tail -1 "$EVENTS_FILE" | jq -r '.event')" "dispatch_guard_resolution_unconfirmed"
assert_eq "ambiguity fail-open: telemetry event names the unit" \
  "$(tail -1 "$EVENTS_FILE" | jq -r '.unit')" "TASK-002"
teardown_temp_dir

# --- Fail-CLOSED not weakened: a corrupt config.json in this same file
# still blocks a DONE re-dispatch (MF-053) — the ambiguity fail-open above
# must not have loosened this separate, pre-existing posture.
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
create_config '.execution.parallel = true'
create_task_file_with_commits TASK-002 DONE "abc1234"
printf 'not json' > "$TEST_DIR/nazgul/config.json"
CORRUPT_EC=0
jq -n '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-002"}}' \
  | bash "$GUARD" >/dev/null 2>&1 || CORRUPT_EC=$?
assert_eq "fail-CLOSED (corrupt config) still blocks — distinct posture from the ambiguity fail-open above" "$CORRUPT_EC" "2"
teardown_temp_dir

report_results
exit $?
