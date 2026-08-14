#!/usr/bin/env bash
set -uo pipefail

# Test: FEAT-030 (PRD AC3/AC4/AC5/AC6/AC8/AC10, ADR-021 Decision 2 and 4). The four
# agents that write a completion marker a later stop-hook gate reads must validate the
# value, write it, READ IT BACK from the same absolute path, and report both the path and
# the persisted value — a write nobody read back is not evidence of anything.
#
# Three families, and the second is the load-bearing one: MR-A asserts the shipped specs
# state the contract, MR-B EXTRACTS each spec's own recipe and runs it in a two-tree
# fixture (the wrong-cwd condition agents are actually dispatched into), and MR-C pins
# the tool grants ADR-021 Decision 4 recorded, in both directions.
TEST_NAME="test-marker-readback-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

CURRENT_FEAT_ID="FEAT-777"

# spec-relative-path | marker basename | reported prefix
SPEC_TABLE="agents/comment-verifier.md|.comments-verified|comment-verifier
agents/doc-verifier.md|.docs-verified|doc-verifier
agents/self-audit.md|.self-audited|self-audit
agents/learner.md|.distilled|learner"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nazgul-marker-readback-XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
MAIN_TREE="$TMP_ROOT/main"
TASK_WT="$TMP_ROOT/worktrees/TASK-004"

cleanup() {
  if [ -d "$MAIN_TREE" ]; then
    git -C "$MAIN_TREE" worktree remove --force "$TASK_WT" >/dev/null 2>&1 || true
    git -C "$MAIN_TREE" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

frontmatter_of() {
  sed -n '2,/^---$/p' "$1" | sed '$d'
}

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
# the tail of a rooted path (same move as tests/test-marker-write-tree-resolution.sh).
unrooted_in_bash_blocks() {
  bash_block_lines "$1" | sed 's|<main_worktree_path>/nazgul|__ROOTED__|g' | grep -n 'nazgul/' || true
}

unrooted_anywhere() {
  sed 's|<main_worktree_path>/nazgul|__ROOTED__|g' "$1" | grep -n -- "$2" || true
}

# === MR-A: the shipped specs state the contract ===

while IFS='|' read -r rel basename_marker prefix; do
  [ -n "$rel" ] || continue
  spec="$REPO_ROOT/$rel"

  if [ ! -f "$spec" ]; then
    _fail "MR-A0 $rel: the spec exists" "no such file: $spec"
    continue
  fi

  block="$(completion_protocol_block "$spec")"
  block_lines=$(printf '%s\n' "$block" | grep -c . || true)
  if [ "$block_lines" -ge 10 ]; then
    _pass "MR-A1 $rel: a completion-protocol bash block was extracted ($block_lines lines)"
  else
    _fail "MR-A1 $rel: a completion-protocol bash block was extracted ($block_lines lines)" \
      "fewer than 10 lines — extraction found almost nothing, so every assertion below would be vacuous"
    continue
  fi

  assert_contains "MR-A2 $rel: the recipe names the marker it is responsible for" \
    "$block" "$basename_marker"
  assert_contains "MR-A2 $rel: the marker path is rooted at <main_worktree_path>" \
    "$block" "MARKER=\"<main_worktree_path>/nazgul/"

  # Step 2 — validate before writing. The FEAT- shape test must precede the redirect,
  # and its failure branch must exit rather than fall through into the write.
  assert_contains "MR-A3 $rel: the value is shape-checked against FEAT- before any write" \
    "$block" "FEAT-*)"
  VALIDATE_AT=$(printf '%s\n' "$block" | grep -n 'FEAT-\*)' | head -1 | cut -d: -f1)
  WRITE_AT=$(printf '%s\n' "$block" | grep -n '> "\$MARKER"' | head -1 | cut -d: -f1)
  MKDIR_AT=$(printf '%s\n' "$block" | grep -n '^mkdir ' | head -1 | cut -d: -f1)
  if [ -n "$VALIDATE_AT" ] && [ -n "$WRITE_AT" ] && [ "$VALIDATE_AT" -lt "$WRITE_AT" ]; then
    _pass "MR-A3 $rel: the shape check sits before the write, not after it"
  else
    _fail "MR-A3 $rel: the shape check sits before the write, not after it" \
      "validate at line '${VALIDATE_AT:-none}', write at line '${WRITE_AT:-none}'"
  fi
  if [ -n "$VALIDATE_AT" ] && [ -n "$MKDIR_AT" ] && [ "$VALIDATE_AT" -lt "$MKDIR_AT" ]; then
    _pass "MR-A3 $rel: an invalid value creates no directory either"
  else
    _fail "MR-A3 $rel: an invalid value creates no directory either" \
      "validate at line '${VALIDATE_AT:-none}', mkdir at line '${MKDIR_AT:-none}'"
  fi

  # Step 4 — re-read the SAME path, then compare.
  assert_contains "MR-A4 $rel: the recipe re-reads the same absolute path it wrote" \
    "$block" 'PERSISTED=$(cat "$MARKER"'
  assert_contains "MR-A4 $rel: the re-read value is compared to the intended value" \
    "$block" '[ "$PERSISTED" != "$FEAT_ID" ]'

  # Step 5 — the report is the deliverable.
  assert_contains "MR-A5 $rel: the recipe prints the resolved absolute path" \
    "$block" "$prefix: marker path %s"
  assert_contains "MR-A5 $rel: the recipe prints the value actually persisted" \
    "$block" "$prefix: marker value %s"

  spec_text="$(cat "$spec")"
  assert_contains "MR-A5 $rel: the spec requires reporting both lines in the final message" \
    "$spec_text" "report both printed lines in your final message"

  # Step 6 — mismatch is FAILURE, and FAILURE is not authority.
  assert_contains "MR-A6 $rel: a read-back mismatch is reported as FAILURE" \
    "$block" "FAILURE - read-back mismatch"
  assert_contains "MR-A6 $rel: an invalid value is refused as FAILURE with no write" \
    "$block" "FAILURE - refusing to write"
  assert_contains "MR-A6 $rel: the spec forbids claiming a gate it cannot prove it wrote to" \
    "$spec_text" "do NOT claim"
  assert_contains "MR-A6 $rel: the spec names the authority boundary explicitly" \
    "$spec_text" "no authority over a gate you cannot prove you wrote to"

  # Step 1 — the resolution chain: brief, then config, then STOP.
  assert_contains "MR-A7 $rel: the caller supplies <main_worktree_path> in the brief" \
    "$spec_text" "supplies \`<main_worktree_path>\`"
  assert_contains "MR-A7 $rel: branch.main_worktree_path is the documented fallback" \
    "$spec_text" "branch.main_worktree_path"
  assert_contains "MR-A7 $rel: an unresolvable root STOPs rather than guessing" \
    "$spec_text" "STOP and report"
  assert_contains "MR-A7 $rel: the spec forbids deriving the root from the working directory" \
    "$spec_text" "never guess it from the working directory"

  # No bare relative runtime-state path survives anywhere it could be executed.
  PWD_ROOTED=$(bash_block_lines "$spec" | grep -nF '$(pwd)/nazgul' || true)
  assert_eq "MR-A8 $rel: no bash block roots runtime state at \$(pwd)/nazgul" "$PWD_ROOTED" ""
  UNROOTED=$(unrooted_in_bash_blocks "$spec")
  assert_eq "MR-A8 $rel: every nazgul/ path inside a bash block is rooted at <main_worktree_path>" \
    "$UNROOTED" ""
  BARE_CONFIG=$(unrooted_anywhere "$spec" 'nazgul/config.json')
  assert_eq "MR-A8 $rel: no bare nazgul/config.json anywhere in the spec" "$BARE_CONFIG" ""
  BARE_MARKER=$(unrooted_anywhere "$spec" "nazgul/[a-z]*/$basename_marker")
  assert_eq "MR-A8 $rel: no bare marker path anywhere in the spec" "$BARE_MARKER" ""
done <<SPEC_LIST
$SPEC_TABLE
SPEC_LIST

# The roster audit is the shared classifier for "operational path not rooted at
# <main_worktree_path>"; these four files must contribute none of its findings.
AUDIT="$REPO_ROOT/scripts/audit-agent-state-paths.sh"
if [ -x "$AUDIT" ]; then
  # Pinned, not derived: an exported scan root would aim this at another tree, and a
  # zero-finding result on a tree with no agents/ is the vacuous pass MR-A9 exists to deny.
  AUDIT_OUT="$(NAZGUL_AGENT_AUDIT_SCAN_ROOT="$REPO_ROOT" bash "$AUDIT" 2>/dev/null)"
  FOUR_FINDINGS=$(printf '%s\n' "$AUDIT_OUT" \
    | grep -E '^  agents/(comment-verifier|doc-verifier|self-audit|learner)\.md:' || true)
  AUDIT_CHECKED=$(printf '%s\n' "$AUDIT_OUT" | tail -1 \
    | sed -E 's/^.*\), ([0-9]+) checked.*/\1/')
  case "${AUDIT_CHECKED:-}" in ''|*[!0-9]*) AUDIT_CHECKED_N=0 ;; *) AUDIT_CHECKED_N="$AUDIT_CHECKED" ;; esac
  if [ "$AUDIT_CHECKED_N" -ge 4 ]; then
    _pass "MR-A9 floor: the audit actually reached the four specs ($AUDIT_CHECKED_N checked)"
  else
    _fail "MR-A9 floor: the audit actually reached the four specs" \
      "checked '$AUDIT_CHECKED' — a zero-finding result over a roster this small proves nothing"
  fi
  assert_eq "MR-A9: the roster audit reports no unrooted operational path in the four specs" \
    "$FOUR_FINDINGS" ""
else
  _fail "MR-A9: the roster audit entry point is executable" "not executable: $AUDIT"
fi

# === MR-B: each spec's OWN recipe, run from the wrong tree ===

# Fixture: a main checkout holding the whole runtime state, plus a real sibling task
# worktree holding none of it — the shape post-loop agents are dispatched into.
mkdir -p "$MAIN_TREE"
git -C "$MAIN_TREE" init -q
git -C "$MAIN_TREE" config user.email "test@nazgul.dev"
git -C "$MAIN_TREE" config user.name "Nazgul Test"
printf 'nazgul/\n' > "$MAIN_TREE/.gitignore"
mkdir -p "$MAIN_TREE/agents"
printf 'placeholder\n' > "$MAIN_TREE/agents/.gitkeep"
git -C "$MAIN_TREE" add .gitignore agents/.gitkeep
git -C "$MAIN_TREE" commit -q -m "initial"

mkdir -p "$MAIN_TREE/nazgul/logs" "$MAIN_TREE/nazgul/learning"
write_config() {
  if [ -n "$2" ]; then
    jq -n --arg feat "$2" --arg main "$1" \
      '{schema_version:36, feat_id:$feat, branch:{feature:"feat/FEAT-777-x", base:"main", main_worktree_path:$main}}' \
      > "$1/nazgul/config.json"
  else
    jq -n --arg main "$1" \
      '{schema_version:36, branch:{main_worktree_path:$main}}' > "$1/nazgul/config.json"
  fi
}
write_config "$MAIN_TREE" "$CURRENT_FEAT_ID"

mkdir -p "$TMP_ROOT/worktrees"
git -C "$MAIN_TREE" worktree add -q "$TASK_WT" -b feat/FEAT-777/TASK-004

assert_dir_not_exists "MR-B0: the task worktree carries no nazgul/ at all (gitignored, as in this repo)" \
  "$TASK_WT/nazgul"

RUN_OUT=""
RUN_ERR=""
RUN_RC=0

# run_recipe <spec-file> <root> — runs the spec's own block from the task worktree with
# CLAUDE_PROJECT_DIR unset. Not a command substitution: an rc captured in one dies with it.
run_recipe() {
  local recipe="$TMP_ROOT/recipe.sh"
  completion_protocol_block "$1" | sed "s|<main_worktree_path>|$2|g" > "$recipe"
  (
    cd "$TASK_WT" || exit 99
    unset CLAUDE_PROJECT_DIR
    bash "$recipe"
  ) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  RUN_RC=$?
  RUN_OUT="$(cat "$TMP_ROOT/out")"
  RUN_ERR="$(cat "$TMP_ROOT/err")"
}

# marker_path_of <spec-file> <root> — the absolute path the spec's own recipe targets.
marker_path_of() {
  completion_protocol_block "$1" | sed -n 's|^MARKER="\(.*\)"$|\1|p' | head -1 \
    | sed "s|<main_worktree_path>|$2|"
}

while IFS='|' read -r rel basename_marker prefix; do
  [ -n "$rel" ] || continue
  spec="$REPO_ROOT/$rel"
  [ -f "$spec" ] || continue

  MARKER="$(marker_path_of "$spec" "$MAIN_TREE")"
  if [ -z "$MARKER" ]; then
    _fail "MR-B1 $rel: the recipe declares a MARKER path" "no MARKER= line in the extracted block"
    continue
  fi
  rm -rf "$MARKER" "$TASK_WT/nazgul"

  # B1 — the happy path: a valid value, written and proved.
  run_recipe "$spec" "$MAIN_TREE"
  assert_eq "MR-B1 $rel: a valid feat_id completes the sequence (exit 0)" "$RUN_RC" "0"
  assert_dir_not_exists "MR-B1 $rel: nothing is created in the task worktree it was dispatched into" \
    "$TASK_WT/nazgul"
  assert_file_contains "MR-B1 $rel: the marker in the main tree holds the current objective" \
    "$MARKER" "$CURRENT_FEAT_ID"
  assert_contains "MR-B1 $rel: the run reports the RESOLVED ABSOLUTE path" \
    "$RUN_OUT" "$prefix: marker path $MARKER"
  assert_contains "MR-B1 $rel: the run reports the value actually persisted" \
    "$RUN_OUT" "$prefix: marker value $CURRENT_FEAT_ID"

  # B2 — PRD AC6: the jq read fails, so the value is empty. No write at all, and the
  # 1-byte empty marker the baseline left behind is never created.
  NOCONF="$TMP_ROOT/noconfig"
  rm -rf "$NOCONF"
  mkdir -p "$NOCONF"
  run_recipe "$spec" "$NOCONF"
  if [ "$RUN_RC" -ne 0 ]; then
    _pass "MR-B2 $rel: an unreadable config is a reported failure, not a silent success"
  else
    _fail "MR-B2 $rel: an unreadable config is a reported failure, not a silent success" \
      "exit 0 with stdout '$RUN_OUT'"
  fi
  assert_contains "MR-B2 $rel: the refusal is reported as FAILURE" "$RUN_ERR" "FAILURE"
  assert_dir_not_exists "MR-B2 $rel: an invalid value creates no state tree at all" "$NOCONF/nazgul"
  assert_dir_not_exists "MR-B2 $rel: and none in the task worktree either" "$TASK_WT/nazgul"

  # B3 — feat_id readable but not FEAT- shaped. "default" is what the old `// "default"`
  # fallback produced, and the gate compares against .feat_id, so it proves nothing.
  BADID="$TMP_ROOT/badid"
  rm -rf "$BADID"
  mkdir -p "$BADID/nazgul"
  jq -n '{schema_version:36, feat_id:"default"}' > "$BADID/nazgul/config.json"
  run_recipe "$spec" "$BADID"
  if [ "$RUN_RC" -ne 0 ]; then
    _pass "MR-B3 $rel: a non-FEAT- value is a reported failure"
  else
    _fail "MR-B3 $rel: a non-FEAT- value is a reported failure" "exit 0 with stdout '$RUN_OUT'"
  fi
  assert_contains "MR-B3 $rel: the refusal names the value it refused" "$RUN_ERR" "default"
  BAD_MARKER="$(marker_path_of "$spec" "$BADID")"
  assert_file_not_exists "MR-B3 $rel: no marker file is created for an invalid value" "$BAD_MARKER"

  # B4 — the write reports success and the value is still not there. Only the read-back
  # can catch this, which is the whole point of ADR-021 Decision 2.
  LOSTW="$TMP_ROOT/lostwrite"
  rm -rf "$LOSTW"
  mkdir -p "$LOSTW/nazgul"
  write_config "$LOSTW" "$CURRENT_FEAT_ID"
  LOST_MARKER="$(marker_path_of "$spec" "$LOSTW")"
  mkdir -p "$(dirname "$LOST_MARKER")"
  ln -s /dev/null "$LOST_MARKER"
  run_recipe "$spec" "$LOSTW"
  if [ "$RUN_RC" -ne 0 ]; then
    _pass "MR-B4 $rel: a write that did not land is caught by the read-back"
  else
    _fail "MR-B4 $rel: a write that did not land is caught by the read-back" \
      "exit 0 with stdout '$RUN_OUT'"
  fi
  assert_contains "MR-B4 $rel: the mismatch is reported as FAILURE" "$RUN_ERR" "FAILURE"
  assert_contains "MR-B4 $rel: the mismatch names the path it could not prove" \
    "$RUN_ERR" "$LOST_MARKER"
  assert_not_contains "MR-B4 $rel: no success line claims a persisted value" \
    "$RUN_OUT" "$prefix: marker value $CURRENT_FEAT_ID"

  # B5 — marker path is a directory: neither write nor read can succeed. Exit != 0 alone
  # would also hold for a dead-on-redirect recipe, so assert the read-back's own sentinel.
  UNREAD="$TMP_ROOT/unreadable"
  rm -rf "$UNREAD"
  mkdir -p "$UNREAD/nazgul"
  write_config "$UNREAD" "$CURRENT_FEAT_ID"
  UNREAD_MARKER="$(marker_path_of "$spec" "$UNREAD")"
  mkdir -p "$UNREAD_MARKER"
  run_recipe "$spec" "$UNREAD"
  if [ "$RUN_RC" -ne 0 ]; then
    _pass "MR-B5 $rel: an unreadable marker is a reported failure"
  else
    _fail "MR-B5 $rel: an unreadable marker is a reported failure" "exit 0 with stdout '$RUN_OUT'"
  fi
  assert_contains "MR-B5 $rel: the unreadable case is reported as FAILURE" "$RUN_ERR" "FAILURE"
  assert_contains "MR-B5 $rel: the read-back RAN and reported its unreadable sentinel" \
    "$RUN_ERR" 'read "<unreadable>"'

  # B5b — the case B4 and B5 both miss: the write LANDS and only the read fails. This is
  # the read-back path in isolation, with no write-side failure to hide behind.
  WONLY="$TMP_ROOT/writeonly"
  rm -rf "$WONLY"
  mkdir -p "$WONLY/nazgul"
  write_config "$WONLY" "$CURRENT_FEAT_ID"
  WONLY_MARKER="$(marker_path_of "$spec" "$WONLY")"
  mkdir -p "$(dirname "$WONLY_MARKER")"
  : > "$WONLY_MARKER"
  chmod 0200 "$WONLY_MARKER"
  if [ -r "$WONLY_MARKER" ]; then
    # Running as root (or on a filesystem ignoring the mode bit): the condition could not
    # be established, which is a named skip, never a quiet pass.
    _skip "MR-B5b $rel: a write-only marker is still unreadable to this process" \
      "the process can read a 0200 file — likely root; the read-back path cannot be isolated here"
  else
    run_recipe "$spec" "$WONLY"
    if [ "$RUN_RC" -ne 0 ]; then
      _pass "MR-B5b $rel: a write that landed but cannot be read back is still a failure"
    else
      _fail "MR-B5b $rel: a write that landed but cannot be read back is still a failure" \
        "exit 0 with stdout '$RUN_OUT'"
    fi
    assert_contains "MR-B5b $rel: the unreadable read-back is reported as FAILURE" \
      "$RUN_ERR" "FAILURE"
    assert_contains "MR-B5b $rel: the failure names the sentinel the read-back produced" \
      "$RUN_ERR" 'read "<unreadable>"'
    assert_not_contains "MR-B5b $rel: no success line claims a persisted value" \
      "$RUN_OUT" "$prefix: marker value $CURRENT_FEAT_ID"
  fi
  chmod 0600 "$WONLY_MARKER" 2>/dev/null || true
done <<SPEC_LIST_B
$SPEC_TABLE
SPEC_LIST_B

# === MR-C: the AC8 tool-grant pin, asserted in BOTH directions ===

# ADR-021 Decision 4: these agents keep their current toolsets. Adding Write to the three
# read-only verifiers and stripping it from the learner are both drifts from the record.
NO_WRITE_AGENTS="agents/comment-verifier.md
agents/doc-verifier.md
agents/self-audit.md"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  fm="$(frontmatter_of "$REPO_ROOT/$rel")"
  assert_not_contains "MR-C1 $rel: holds no Write grant (ADR-021 Decision 4)" "$fm" "  - Write"
  assert_contains "MR-C1 $rel: still holds the Bash grant its marker recipe needs" "$fm" "  - Bash"
done <<NO_WRITE_LIST
$NO_WRITE_AGENTS
NO_WRITE_LIST

LEARNER_FM="$(frontmatter_of "$REPO_ROOT/agents/learner.md")"
assert_contains "MR-C2 agents/learner.md: RETAINS the Write grant it holds at baseline" \
  "$LEARNER_FM" "  - Write"
assert_contains "MR-C2 agents/learner.md: still holds the Bash grant its marker recipe needs" \
  "$LEARNER_FM" "  - Bash"

# Control: the pin is a real matcher, not one that can only pass. A frontmatter that DOES
# grant Write must be seen as granting it.
CONTROL="$TMP_ROOT/control-agent.md"
printf -- '---\nname: control\ntools:\n  - Read\n  - Write\nmaxTurns: 5\n---\nbody\n' > "$CONTROL"
CONTROL_FM="$(frontmatter_of "$CONTROL")"
assert_contains "MR-C3 control: the grant matcher detects a Write grant when one is present" \
  "$CONTROL_FM" "  - Write"

report_results
exit $?
