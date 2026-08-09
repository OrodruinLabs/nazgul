#!/usr/bin/env bash
set -uo pipefail

# Test: FEAT-030 RED-1 (PRD AC1/AC3/AC4/AC10). Two trees, one of which is the wrong
# answer: tests/lib/setup.sh's setup_temp_dir() hardcodes a single
# CLAUDE_PROJECT_DIR/nazgul/ pair and cannot represent that, so this file builds its
# own `git init` + `git worktree add` fixture with nazgul/ gitignored exactly as in
# this repo. MW-1..MW-4 pin the wrong-tree mechanism and stay green forever; MW-5..MW-7
# assert the shipped comment-verifier spec is <main_worktree_path>-rooted and are red
# at c44add2e.
TEST_NAME="test-marker-write-tree-resolution"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SPEC="$REPO_ROOT/agents/comment-verifier.md"
PRIOR_FEAT_ID="FEAT-776"
CURRENT_FEAT_ID="FEAT-777"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-marker-tree-XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
MAIN_TREE="$TMP_ROOT/main"
TASK_WT="$TMP_ROOT/worktrees/TASK-001"

cleanup() {
  if [ -d "$MAIN_TREE" ]; then
    git -C "$MAIN_TREE" worktree remove --force "$TASK_WT" >/dev/null 2>&1 || true
    git -C "$MAIN_TREE" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

marker_bytes() { wc -c < "$1" | tr -d ' '; }

reset_main_marker() {
  printf '%s\n' "$PRIOR_FEAT_ID" > "$MAIN_TREE/nazgul/logs/.comments-verified"
}

# Fixture: a main checkout holding the whole runtime state, plus a real sibling task
# worktree holding none of it — the create_task_worktree() shape agents are dispatched into.
mkdir -p "$MAIN_TREE"
git -C "$MAIN_TREE" init -q
git -C "$MAIN_TREE" config user.email "test@nazgul.dev"
git -C "$MAIN_TREE" config user.name "Nazgul Test"
printf 'nazgul/\n' > "$MAIN_TREE/.gitignore"
mkdir -p "$MAIN_TREE/agents"
printf 'placeholder\n' > "$MAIN_TREE/agents/.gitkeep"
git -C "$MAIN_TREE" add .gitignore agents/.gitkeep
git -C "$MAIN_TREE" commit -q -m "initial"

mkdir -p "$MAIN_TREE/nazgul/logs"
jq -n --arg feat "$CURRENT_FEAT_ID" --arg main "$MAIN_TREE" \
  '{schema_version:36, feat_id:$feat, branch:{feature:"feat/FEAT-777-x", base:"main", main_worktree_path:$main}, docs:{verify_comments:true}}' \
  > "$MAIN_TREE/nazgul/config.json"
reset_main_marker

mkdir -p "$TMP_ROOT/worktrees"
git -C "$MAIN_TREE" worktree add -q "$TASK_WT" -b feat/FEAT-777/TASK-001

assert_dir_not_exists "fixture: the task worktree carries no nazgul/ at all (nazgul/ is gitignored, exactly as in this repo)" \
  "$TASK_WT/nazgul"
assert_file_exists "fixture: the main checkout holds the only marker, and it holds a PRIOR objective's id" \
  "$MAIN_TREE/nazgul/logs/.comments-verified"

# The literal recipe agents/comment-verifier.md:137-139 shipped at c44add2e, kept here as
# fixture text: the hazard must stay pinned after the roster stops spelling it this way.
BASELINE_RECIPE="$TMP_ROOT/baseline-recipe.sh"
cat > "$BASELINE_RECIPE" <<'BASELINE_EOF'
mkdir -p nazgul/logs
FEAT_ID=$(jq -r '.feat_id // "default"' nazgul/config.json)
echo "$FEAT_ID" > nazgul/logs/.comments-verified
BASELINE_EOF

# MW-1..MW-4 — the wrong-tree mechanism, run from the task worktree with
# CLAUDE_PROJECT_DIR unset, which is the exact dispatch condition.
BASELINE_EC=0
(
  cd "$TASK_WT" || exit 99
  unset CLAUDE_PROJECT_DIR
  bash "$BASELINE_RECIPE"
) >/dev/null 2>&1 || BASELINE_EC=$?

assert_eq "MW-1: the baseline recipe reports success (exit 0) despite writing into a tree nobody reads" \
  "$BASELINE_EC" "0"

assert_file_exists "MW-2: the marker landed OUTSIDE the main worktree, under the task worktree" \
  "$TASK_WT/nazgul/logs/.comments-verified"

WRONG_TREE_MARKER=""
WRONG_TREE_BYTES="<absent>"
if [ -f "$TASK_WT/nazgul/logs/.comments-verified" ]; then
  WRONG_TREE_MARKER=$(cat "$TASK_WT/nazgul/logs/.comments-verified")
  WRONG_TREE_BYTES=$(marker_bytes "$TASK_WT/nazgul/logs/.comments-verified")
fi
assert_eq "MW-3: the wrong-tree marker is 1 byte" "$WRONG_TREE_BYTES" "1"
assert_eq "MW-3: that byte is a bare newline — the value is empty" "$WRONG_TREE_MARKER" ""

# jq's `// "default"` never applies: the open failure goes to stderr, the substitution
# captures stdout, and the redirect still succeeds.
if [ "$WRONG_TREE_MARKER" = "default" ]; then
  _fail "MW-3: the wrong-tree value is NOT the string 'default'" \
    "a stale \"default\" marker is a different bug (PRD AC6) than the one this file pins"
else
  _pass "MW-3: the wrong-tree value is NOT the string 'default'"
fi

MAIN_MARKER_AFTER=$(cat "$MAIN_TREE/nazgul/logs/.comments-verified")
assert_eq "MW-4: the main checkout's marker still holds the PRIOR objective's id" \
  "$MAIN_MARKER_AFTER" "$PRIOR_FEAT_ID"
assert_eq "MW-4: the main checkout's marker is byte-for-byte untouched" \
  "$(marker_bytes "$MAIN_TREE/nazgul/logs/.comments-verified")" "9"
if [ "$MAIN_MARKER_AFTER" = "$CURRENT_FEAT_ID" ]; then
  _fail "MW-4: the gate consequently does NOT consider the objective verified" \
    "the main marker reads '$MAIN_MARKER_AFTER', which the gate would accept as verified"
else
  _pass "MW-4: the gate consequently does NOT consider the objective verified"
fi

# MW-5 — structural assertions over the SHIPPED spec, not over the diff.
bash_block_lines() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; next }
    /^[[:space:]]*```/ { inb = 0; next }
    inb { print }
  ' "$1"
}

completion_protocol_block() {
  awk '
    /^## Completion protocol/ { insec = 1; next }
    /^## / { insec = 0 }
    insec && /^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; next }
    insec && inb && /^[[:space:]]*```/ { inb = 0; next }
    insec && inb { print }
  ' "$1"
}

# Rewrite the rooted spelling away first, so what remains is genuinely bare rather than
# the tail of a rooted path.
unrooted_in_bash_blocks() {
  bash_block_lines "$1" | sed 's|<main_worktree_path>/nazgul/|__ROOTED__|g' | grep -n 'nazgul/' || true
}

unrooted_anywhere() {
  sed 's|<main_worktree_path>/nazgul/|__ROOTED__|g' "$1" | grep -n -- "$2" || true
}

SPEC_BASH_BLOCKS=$(bash_block_lines "$SPEC")
COMPLETION_BLOCK=$(completion_protocol_block "$SPEC")

assert_contains "MW-5: the completion-protocol bash block is extractable from the shipped spec" \
  "$COMPLETION_BLOCK" ".comments-verified"

PWD_ROOTED=$(printf '%s\n' "$SPEC_BASH_BLOCKS" | grep -nF '$(pwd)/nazgul' || true)
assert_eq "MW-5: no bash block roots runtime state at \$(pwd)/nazgul" "$PWD_ROOTED" ""

UNROOTED=$(unrooted_in_bash_blocks "$SPEC")
assert_eq "MW-5: every nazgul/ path inside a bash block is rooted at <main_worktree_path>/" \
  "$UNROOTED" ""

assert_contains "MW-5: the completion protocol writes the marker under <main_worktree_path>" \
  "$COMPLETION_BLOCK" '<main_worktree_path>/nazgul/logs/.comments-verified'
assert_contains "MW-5: the completion protocol reads feat_id from <main_worktree_path>'s config" \
  "$COMPLETION_BLOCK" '<main_worktree_path>/nazgul/config.json'
assert_contains "MW-5: the coverage_vacuous emission takes NAZGUL_DIR from <main_worktree_path>" \
  "$SPEC_BASH_BLOCKS" 'NAZGUL_DIR="<main_worktree_path>/nazgul"'

BARE_CONFIG=$(unrooted_anywhere "$SPEC" 'nazgul/config.json')
assert_eq "MW-5: no bare nazgul/config.json anywhere in the spec — every state read names its tree" \
  "$BARE_CONFIG" ""
BARE_LOGS=$(unrooted_anywhere "$SPEC" 'nazgul/logs/')
assert_eq "MW-5: no bare nazgul/logs/ anywhere in the spec — every state write names its tree" \
  "$BARE_LOGS" ""

# MW-6 — the SHIPPED completion recipe, extracted and executed from the same wrong cwd.
# MW-5 proves the text changed; this proves the text works.
rm -rf "$TASK_WT/nazgul"
reset_main_marker

SHIPPED_RECIPE="$TMP_ROOT/shipped-completion-recipe.sh"
printf '%s\n' "$COMPLETION_BLOCK" | sed "s|<main_worktree_path>|$MAIN_TREE|g" > "$SHIPPED_RECIPE"

SHIPPED_EC=0
(
  cd "$TASK_WT" || exit 99
  unset CLAUDE_PROJECT_DIR
  bash "$SHIPPED_RECIPE"
) >/dev/null 2>&1 || SHIPPED_EC=$?

assert_eq "MW-6: the shipped completion recipe exits 0 when run from a task worktree" "$SHIPPED_EC" "0"
assert_dir_not_exists "MW-6: it creates no nazgul/ tree in the task worktree" "$TASK_WT/nazgul"
assert_file_contains "MW-6: it writes the CURRENT objective's id into the main checkout's marker" \
  "$MAIN_TREE/nazgul/logs/.comments-verified" "$CURRENT_FEAT_ID"

# MW-7 — the input contract that makes <main_worktree_path> resolvable: caller-supplied,
# config fallback, then STOP. Never guessed from cwd.
SPEC_TEXT=$(cat "$SPEC")
assert_contains "MW-7: the spec states the caller supplies <main_worktree_path>" \
  "$SPEC_TEXT" "supplies \`<main_worktree_path>\`"
assert_contains "MW-7: the spec names branch.main_worktree_path as the fallback read" \
  "$SPEC_TEXT" "branch.main_worktree_path"
assert_contains "MW-7: the spec STOPs rather than guessing from cwd when neither resolves" \
  "$SPEC_TEXT" "STOP and report"
assert_contains "MW-7: the spec forbids deriving the root from the working directory" \
  "$SPEC_TEXT" "never guess it from the working directory"

report_results
exit $?
