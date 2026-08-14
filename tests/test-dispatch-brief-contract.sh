#!/usr/bin/env bash
set -uo pipefail

# Caller side of the FEAT-030 input contract. tests/test-agent-worktree-contract.sh
# and tests/test-agent-state-path-contract.sh scan agents/** — the party that must
# OBEY the contract. Nothing scanned the party that must SUPPLY it, and a two-party
# contract with one party enforced is how a fleet of STOPping agents shipped green.
TEST_NAME="test-dispatch-brief-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# Env-injectable so the dogfood fixtures and the forced all-skip run below drive
# the real detector over a synthetic tree instead of a hand-copied duplicate.
SCAN_ROOT="${NAZGUL_DISPATCH_SCAN_ROOT:-$REPO_ROOT}"

# The window a reader — or a model composing the prompt — treats as one
# instruction: the dispatch line plus the 8 lines either side of it.
BRIEF_WINDOW=8
BRIEF_TOKEN='<main_worktree_path>'
# The one accepted indirection. Not a loophole: _brief_var_is_rooted below refuses
# the reference in a file that does not itself define it with the token.
BRIEF_VAR='${DISPATCH_BRIEF}'

# Derived from the shipped roster, never hand-listed, and always read from
# REPO_ROOT — a synthetic SCAN_ROOT carries no roster of its own.
_contract_agent_names() {
  local f
  for f in "$REPO_ROOT"/agents/*.md "$REPO_ROOT"/agents/templates/*.md; do
    [ -f "$f" ] || continue
    grep -q '^## Input contract' "$f" || continue
    basename "$f" .md
  done | grep -v '^reviewer-base$' | sort -u
}

AGENT_ALT=$(_contract_agent_names | paste -sd'|' -)
if [ -z "$AGENT_ALT" ]; then
  _fail "the contract-bearing agent roster is non-empty" \
    "no agents/**.md declares '## Input contract' — a broken enumerator, not a clean roster"
  report_results
  exit 1
fi

# A dispatch VERB adjacent to a contract-bearing agent name, or a nazgul: routing
# token naming one. Case-insensitive — specs write `implementer` AND `Implementer`.
SITE_RE="(Spawn|Dispatch|Delegate to|Dispatching)( ONE| the| a| an| to)?( new| post-loop)? [\`\"']?(nazgul:)?($AGENT_ALT)\\b"
SITE_RE="$SITE_RE|subagent_type[:= ]+\"?nazgul:($AGENT_ALT|<[a-z-]+>)"
SITE_RE="$SITE_RE|\\(nazgul:($AGENT_ALT)\\)"

mapfile -t CANDIDATE_FILES < <(cd "$SCAN_ROOT" && {
  find scripts -type f -name '*.sh'
  find skills agents templates -type f -name '*.md'
} 2>/dev/null | sort -u)

DB_SCANNED=${#CANDIDATE_FILES[@]}
DB_CHECKED=0
DB_SKIP_NO_SITE=0
DB_SKIP_UNREADABLE=0
DB_FINDINGS=0
FINDING_LINES=""

# _brief_var_is_rooted <file> — true when the file assigns DISPATCH_BRIEF a value
# that actually carries the token, so the reference resolves to a real brief.
_brief_var_is_rooted() {
  awk '/^[[:space:]]*DISPATCH_BRIEF=/{f=1} f&&/<main_worktree_path>/{print "y"; exit}' "$1" \
    | grep -q y
}

# _check_file <repo-relative path> — appends findings, updates the tallies.
_check_file() {
  local rel="$1" full="$SCAN_ROOT/$1"
  if [ ! -r "$full" ]; then
    DB_SKIP_UNREADABLE=$((DB_SKIP_UNREADABLE + 1))
    return 0
  fi
  local sites
  sites=$(grep -niE "$SITE_RE" "$full" 2>/dev/null | cut -d: -f1)
  if [ -z "$sites" ]; then
    DB_SKIP_NO_SITE=$((DB_SKIP_NO_SITE + 1))
    return 0
  fi
  DB_CHECKED=$((DB_CHECKED + 1))
  local var_ok=1
  if grep -qF "$BRIEF_VAR" "$full" 2>/dev/null && ! _brief_var_is_rooted "$full"; then
    var_ok=0
    DB_FINDINGS=$((DB_FINDINGS + 1))
    FINDING_LINES="${FINDING_LINES}${rel}: references ${BRIEF_VAR} but defines no DISPATCH_BRIEF containing ${BRIEF_TOKEN}"$'\n'
  fi
  local total lineno lo hi window text
  total=$(wc -l < "$full" | tr -d ' ')
  for lineno in $sites; do
    lo=$((lineno - BRIEF_WINDOW)); [ "$lo" -lt 1 ] && lo=1
    hi=$((lineno + BRIEF_WINDOW)); [ "$hi" -gt "$total" ] && hi="$total"
    window=$(sed -n "${lo},${hi}p" "$full")
    case "$window" in
      *"$BRIEF_TOKEN"*) continue ;;
    esac
    if [ "$var_ok" = "1" ]; then
      case "$window" in
        *"$BRIEF_VAR"*) continue ;;
      esac
    fi
    text=$(sed -n "${lineno}p" "$full" | sed 's/^[[:space:]]*//' | cut -c1-90)
    DB_FINDINGS=$((DB_FINDINGS + 1))
    FINDING_LINES="${FINDING_LINES}${rel}:${lineno}: dispatch site names no ${BRIEF_TOKEN} — ${text}"$'\n'
  done
}

for rel in ${CANDIDATE_FILES[@]+"${CANDIDATE_FILES[@]}"}; do
  _check_file "$rel"
done

if [ -n "$FINDING_LINES" ]; then
  printf '%s' "$FINDING_LINES" | while IFS= read -r l; do echo "  FINDING: $l"; done
fi

if [ "$DB_FINDINGS" -eq 0 ]; then
  _pass "R1: every dispatch of a contract-bearing agent names <main_worktree_path> ($DB_CHECKED file(s) checked)"
else
  _fail "R1: every dispatch of a contract-bearing agent names <main_worktree_path>" \
    "$DB_FINDINGS dispatch site(s) supply no runtime-state root — each one STOPs the agent it dispatches"
fi

# Dogfood — a detector that can only ever pass is evidence of nothing. Skipped under
# an injected SCAN_ROOT: the fixtures re-enter this file and would recurse forever.
if [ -n "${NAZGUL_DISPATCH_SCAN_ROOT:-}" ]; then
  _skip "dogfood fixtures (inner run under an injected scan root)"
else
# D1: a synthetic dispatch site with no root anywhere must be FOUND.
DOG=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-dispatch-dogfood-XXXXXX")
trap 'rm -rf "$DOG"' EXIT
mkdir -p "$DOG/scripts" "$DOG/skills/fake" "$DOG/agents" "$DOG/templates"
cat > "$DOG/skills/fake/SKILL.md" <<'FIXTURE'
# Fake skill

### Step 1
Dispatch the planner agent with the Agent tool and wait for its return.
FIXTURE
DOG_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1)
DOG_RC=$?
assert_contains "D1: a synthetic rootless dispatch site is FOUND" \
  "$DOG_OUT" "skills/fake/SKILL.md:4: dispatch site names no <main_worktree_path>"
assert_exit_code "D1: a found violation is a blocking failure" "$DOG_RC" 1
assert_contains "D1: the coverage line counts the synthetic site's file as checked" \
  "$DOG_OUT" "$TEST_NAME: 1 scanned, 0 skipped (no-dispatch-site=0, unreadable=0), 1 checked, 1 findings"

# D2: the SAME site, with the brief in its window, satisfies the detector — so D1
# proves the predicate, not merely that the fixture tree differs from the repo.
cat > "$DOG/skills/fake/SKILL.md" <<'FIXTURE'
# Fake skill

### Step 1
Dispatch brief: <main_worktree_path> = /abs/path/to/project. Nazgul config: /abs/path/to/project/nazgul/config.json.
Dispatch the planner agent with the Agent tool and wait for its return.
FIXTURE
DOG2_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1)
DOG2_RC=$?
assert_not_contains "D2: rooting that same site satisfies the detector" \
  "$DOG2_OUT" "dispatch site names no <main_worktree_path>"
assert_exit_code "D2: a rooted roster passes" "$DOG2_RC" 0

# D3: the brief 9 lines away is OUT of the window — the boundary is a decision,
# not an accident, and a detector whose window silently grew would pass this too.
{ printf '# Fake skill\n\nDispatch brief: <main_worktree_path> = /abs/path/to/project.\n'
  for _ in 1 2 3 4 5 6 7 8; do printf 'filler\n'; done
  printf 'Dispatch the planner agent with the Agent tool.\n'
} > "$DOG/skills/fake/SKILL.md"
DOG3_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1)
assert_contains "D3: a brief outside the window does not count as supplied" \
  "$DOG3_OUT" "dispatch site names no <main_worktree_path>"

# D4: the ${DISPATCH_BRIEF} indirection is resolved, not trusted — a file that
# references it without defining it is a finding, not an accepted supply form.
mkdir -p "$DOG/scripts"
cat > "$DOG/skills/fake/SKILL.md" <<'FIXTURE'
# Fake skill
FIXTURE
cat > "$DOG/scripts/fake.sh" <<'FIXTURE'
#!/usr/bin/env bash
MSG="DELEGATE: Spawn implementer agent (nazgul:implementer). ${DISPATCH_BRIEF}"
echo "$MSG"
FIXTURE
DOG4_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1)
assert_contains "D4: an undefined \${DISPATCH_BRIEF} reference is refused" \
  "$DOG4_OUT" "scripts/fake.sh: references \${DISPATCH_BRIEF} but defines no DISPATCH_BRIEF"
printf 'DISPATCH_BRIEF="Dispatch brief: <main_worktree_path> = /x."\n' >> "$DOG/scripts/fake.sh"
DOG5_OUT=$(NAZGUL_DISPATCH_SCAN_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1)
DOG5_RC=$?
assert_not_contains "D4: defining it with the token accepts the same reference" \
  "$DOG5_OUT" "defines no DISPATCH_BRIEF"
assert_exit_code "D4: the resolved indirection passes" "$DOG5_RC" 0
fi

# Blocking disposition (RULES.md §15): zero candidates is a broken enumerator, not
# a clean tree. No bus write — a test file never touches runtime state.
DB_SKIPPED=$((DB_SKIP_NO_SITE + DB_SKIP_UNREADABLE))
if [ "$DB_SCANNED" -ne $((DB_SKIPPED + DB_CHECKED)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $DB_SCANNED scanned != $DB_SKIPPED skipped + $DB_CHECKED checked" >&2
  _fail "coverage accounting adds up (N == M + K)" "$DB_SCANNED != $DB_SKIPPED + $DB_CHECKED"
fi
if [ "$DB_CHECKED" -eq 0 ]; then
  if [ "$DB_SCANNED" -eq 0 ]; then
    echo "$TEST_NAME: NOTHING CHECKED — no dispatch-bearing files discovered under $SCAN_ROOT" >&2
    _fail "the enumerator found at least one candidate file" \
      "zero candidates under $SCAN_ROOT — a broken enumerator, not a clean tree"
  else
    echo "$TEST_NAME: NOTHING CHECKED — all $DB_SCANNED candidates skipped" >&2
    _fail "at least one discovered file held a dispatch site to check" \
      "all $DB_SCANNED candidates skipped"
  fi
fi

RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (no-dispatch-site=%d, unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$DB_SCANNED" "$DB_SKIPPED" "$DB_SKIP_NO_SITE" "$DB_SKIP_UNREADABLE" \
  "$DB_CHECKED" "$DB_FINDINGS"
exit "$RC"
