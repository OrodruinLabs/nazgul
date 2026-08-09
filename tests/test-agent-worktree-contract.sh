#!/usr/bin/env bash
set -uo pipefail

# Test: the shipped agent worktree capability contract (FEAT-029 TASK-006, PRD AC7/AC8).
# The historical defect: agent prompts granted and instructed EnterWorktree/ExitWorktree,
# which a subagent session cannot perform, and then assumed the cwd that tool would have
# established. A prompt must not describe a contract the host does not honour for the
# caller it is written for, so the checks below are structural: no worktree-tool grant or
# mention in ANY shipped agent spec, every git command in the two task-worktree agents
# named with an explicit directory, and every shared reference in a touched file resolved
# from the plugin root against the real package tree.
TEST_NAME="test-agent-worktree-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-worktree-contract-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

frontmatter_of() {
  sed -n '2,/^---$/p' "$1" | sed '$d'
}

worktree_tool_grant() {
  frontmatter_of "$1" | grep -nE '^[[:space:]]*-[[:space:]]*(Enter|Exit)Worktree[[:space:]]*$' || true
}

worktree_mention() {
  grep -nE '(Enter|Exit)Worktree' "$1" || true
}

# Every command span a prompt tells an agent to run: inline backticked `git ...`
# spans plus git lines inside fenced blocks (fences may be list-indented).
git_spans() {
  grep -o '`git [^`]*`' "$1" | sed 's/^`//; s/`$//'
  awk '/^[[:space:]]*```/ { inb = !inb; next } inb && /(^|[ (=])git /' "$1"
}

undirected_git_spans() {
  git_spans "$1" | grep -v 'git -C ' || true
}

# A `cd` is only directory-explicit when it is joined to the command it serves;
# a standalone `cd` assumes a working directory that survives to the next call.
unjoined_cd_lines() {
  grep -n 'cd ' "$1" | grep -v '&&' || true
}

plugin_refs() {
  grep -o '${CLAUDE_PLUGIN_ROOT}/references/[A-Za-z0-9._-]*' "$1" || true
}

# Rewrite the qualified spelling away first, so what remains is genuinely unqualified
# rather than merely the tail of a qualified reference.
bare_refs() {
  sed 's|\${CLAUDE_PLUGIN_ROOT}/references/|__QUALIFIED__|g' "$1" \
    | grep -oE 'references/[A-Za-z0-9._/-]+' || true
}

# === AC7 part 1: no shipped agent spec grants, requests, or mentions the tools ===

AGENT_SCANNED=0
AGENT_CHECKED=0
AGENT_UNREADABLE=0
AGENT_FINDINGS=0
for agent_file in "$REPO_ROOT"/agents/*.md "$REPO_ROOT"/agents/templates/*.md; do
  AGENT_SCANNED=$((AGENT_SCANNED + 1))
  rel="${agent_file#"$REPO_ROOT/"}"
  if [ ! -r "$agent_file" ]; then
    AGENT_UNREADABLE=$((AGENT_UNREADABLE + 1))
    _fail "$rel is readable" "agent spec could not be read — not scanned"
    continue
  fi
  AGENT_CHECKED=$((AGENT_CHECKED + 1))
  grants=$(worktree_tool_grant "$agent_file")
  mentions=$(worktree_mention "$agent_file")
  if [ -n "$grants" ]; then
    AGENT_FINDINGS=$((AGENT_FINDINGS + 1))
    _fail "$rel grants no EnterWorktree/ExitWorktree tool" "$grants"
  else
    _pass "$rel grants no EnterWorktree/ExitWorktree tool"
  fi
  if [ -n "$mentions" ]; then
    AGENT_FINDINGS=$((AGENT_FINDINGS + 1))
    _fail "$rel instructs no EnterWorktree/ExitWorktree use" "$mentions"
  else
    _pass "$rel instructs no EnterWorktree/ExitWorktree use"
  fi
done

echo "  agent-scan: ${AGENT_SCANNED} scanned, $((AGENT_SCANNED - AGENT_CHECKED)) skipped (unreadable=${AGENT_UNREADABLE}), ${AGENT_CHECKED} checked, ${AGENT_FINDINGS} findings"
assert_eq "agent-scan: every scanned agent spec was actually checked" "$AGENT_CHECKED" "$AGENT_SCANNED"
if [ "$AGENT_SCANNED" -ge 20 ]; then
  _pass "agent-scan: the glob matched the shipped agent roster (>= 20 specs)"
else
  _fail "agent-scan: the glob matched the shipped agent roster (>= 20 specs)" "scanned only $AGENT_SCANNED"
fi

# === AC7 part 2: the two task-worktree agents name their directory every time ===

TASK_AGENTS="agents/implementer.md
agents/simplifier.md"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then
    _fail "$rel exists" "task-worktree agent spec is missing"
    continue
  fi

  span_count=$(git_spans "$f" | grep -c . || true)
  if [ "$span_count" -ge 5 ]; then
    _pass "$rel: the git-command scan found commands to check ($span_count spans)"
  else
    _fail "$rel: the git-command scan found commands to check ($span_count spans)" \
      "fewer than 5 git spans found — the scanner looked and found almost nothing, which is a scanner defect"
  fi

  assert_eq "$rel: every git command names its directory with -C" "$(undirected_git_spans "$f")" ""
  assert_eq "$rel: no cd is left standing alone" "$(unjoined_cd_lines "$f")" ""

  content=$(cat "$f")
  assert_contains "$rel: verifies the caller-supplied worktree instead of creating one" \
    "$content" 'git -C "<task_worktree>" rev-parse --show-toplevel'
  assert_not_contains "$rel: never creates a worktree itself" "$content" "git worktree add"
  assert_not_contains "$rel: never assumes a persistent cwd for a command" \
    "$content" "from the project root"
  assert_contains "$rel: states that the Bash cwd does not persist" "$content" "resets between calls"
done <<TASK_AGENT_LIST
$TASK_AGENTS
TASK_AGENT_LIST

# === AC8: every shared reference in a touched file resolves in the package tree ===

TOUCHED_FILES="agents/implementer.md
agents/simplifier.md
agents/review-gate.md
agents/team-orchestrator.md"

REF_SCANNED=0
REF_CHECKED=0
REF_MISSING_FILE=0
REF_FINDINGS=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then
    REF_MISSING_FILE=$((REF_MISSING_FILE + 1))
    _fail "$rel exists for reference resolution" "touched file is missing"
    continue
  fi

  unqualified=$(bare_refs "$f")
  if [ -n "$unqualified" ]; then
    _fail "$rel: every shared reference is plugin-root qualified" "$unqualified"
  else
    _pass "$rel: every shared reference is plugin-root qualified"
  fi

  refs=$(plugin_refs "$f")
  if [ -z "$refs" ]; then
    _fail "$rel: carries at least one plugin-root reference to resolve" \
      "no \${CLAUDE_PLUGIN_ROOT}/references/... reference found"
    continue
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    REF_SCANNED=$((REF_SCANNED + 1))
    target="$REPO_ROOT/references/${ref##*/references/}"
    REF_CHECKED=$((REF_CHECKED + 1))
    if [ -f "$target" ]; then
      _pass "$rel: $ref resolves in the package tree"
    else
      REF_FINDINGS=$((REF_FINDINGS + 1))
      _fail "$rel: $ref resolves in the package tree" "no such file: $target"
    fi
  done <<REF_LIST
$refs
REF_LIST
done <<TOUCHED_LIST
$TOUCHED_FILES
TOUCHED_LIST

echo "  reference-scan: ${REF_SCANNED} scanned, $((REF_SCANNED - REF_CHECKED)) skipped (missing-file=${REF_MISSING_FILE}), ${REF_CHECKED} checked, ${REF_FINDINGS} findings"
if [ "$REF_SCANNED" -ge 4 ]; then
  _pass "reference-scan: at least one reference per touched file was resolved"
else
  _fail "reference-scan: at least one reference per touched file was resolved" "scanned only $REF_SCANNED"
fi

# === Controls: each scanner reports a real defect, and clears a clean file ===

cat > "$WORK/bad-grant.md" <<'BAD_GRANT'
---
name: bad-grant
tools:
  - Bash
  - EnterWorktree
  - ExitWorktree
maxTurns: 10
---
Use `EnterWorktree` to enter the task worktree.
BAD_GRANT

assert_contains "control: a granted worktree tool is reported" \
  "$(worktree_tool_grant "$WORK/bad-grant.md")" "EnterWorktree"
assert_contains "control: an instructed worktree tool is reported" \
  "$(worktree_mention "$WORK/bad-grant.md")" "EnterWorktree"

cat > "$WORK/bad-git.md" <<'BAD_GIT'
---
name: bad-git
maxTurns: 10
---
Run `git diff --name-only HEAD` after you cd into the worktree.

```bash
git commit -am "fix"
```
BAD_GIT

BAD_GIT_SPANS=$(undirected_git_spans "$WORK/bad-git.md")
assert_contains "control: a bare inline git command is reported" "$BAD_GIT_SPANS" "git diff --name-only"
assert_contains "control: a bare fenced git command is reported" "$BAD_GIT_SPANS" "git commit -am"
assert_contains "control: a standalone cd is reported" \
  "$(unjoined_cd_lines "$WORK/bad-git.md")" "cd into the worktree"

cat > "$WORK/bad-ref.md" <<'BAD_REF'
---
name: bad-ref
maxTurns: 10
---
Format output per `references/ui-brand.md` and classify per
`${CLAUDE_PLUGIN_ROOT}/references/does-not-exist.md`.
BAD_REF

assert_contains "control: an unqualified shared reference is reported" \
  "$(bare_refs "$WORK/bad-ref.md")" "references/ui-brand.md"
BAD_REF_TARGET=$(plugin_refs "$WORK/bad-ref.md")
assert_contains "control: the unresolvable reference is extracted for resolution" \
  "$BAD_REF_TARGET" "does-not-exist.md"
assert_file_not_exists "control: the extracted reference does not resolve" \
  "$REPO_ROOT/references/${BAD_REF_TARGET##*/references/}"

cat > "$WORK/good.md" <<'GOOD'
---
name: good
tools:
  - Bash
maxTurns: 10
---
Format output per `${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md`.
Confirm with `git -C "<task_worktree>" rev-parse --show-toplevel`, then run
`(cd "<task_worktree>" && <test_command>)`.
GOOD

assert_eq "control: a compliant spec reports no tool grant" "$(worktree_tool_grant "$WORK/good.md")" ""
assert_eq "control: a compliant spec reports no tool mention" "$(worktree_mention "$WORK/good.md")" ""
assert_eq "control: a compliant spec reports no undirected git command" \
  "$(undirected_git_spans "$WORK/good.md")" ""
assert_eq "control: a compliant spec reports no standalone cd" "$(unjoined_cd_lines "$WORK/good.md")" ""
assert_eq "control: a compliant spec reports no unqualified reference" "$(bare_refs "$WORK/good.md")" ""

report_results
