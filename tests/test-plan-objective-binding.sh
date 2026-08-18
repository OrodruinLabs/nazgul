#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.
#
# Test: the manifest->objective roster binding's PRODUCER (FEAT-031 RW-G).
#
# WHY THIS FILE EXISTS, AND WHY THE EXISTING TESTS DID NOT CATCH IT. The merge-evidence
# gate requires nazgul/plan.md's frontmatter feat_id to agree with config.feat_id. Every
# prior test built that plan BY HAND with a correct id — an authored denominator, which
# can only ever prove the predicate reads what the test wrote. The population that matters
# is the plan a real project is BORN with, and that one shipped an unsubstituted
# `<FEAT-NNN>` placeholder that no producer ever replaced, so `IMPLEMENTED -> DONE` was
# unreachable for every project except this repo, whose plan.md is hand-written.
#
# So the subject here is the SHIPPED templates/plan.md, copied verbatim exactly as
# skills/init/SKILL.md says init copies it, and the roster is written into it the way the
# Planner writes one. Nothing about the plan is authored to be correct.
#
# WHAT IS MECHANICAL AND WHAT IS NOT (RULES.md §21 tier language, stated rather than
# implied). The producer is scripts/stamp-plan-objective.sh, a script, and it is driven
# for real below — as is the whole route to DONE, through scripts/task-transition.sh with
# the real merge-provider seam over a PATH-shim `gh`. What CANNOT be enforced from here is
# that a dispatched Planner actually runs it on its turn; that assertion is labelled
# [advisory] and checks only that agents/planner.md instructs it.
TEST_NAME="test-plan-objective-binding"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

STAMPER="$REPO_ROOT/scripts/stamp-plan-objective.sh"
TEMPLATE="$REPO_ROOT/templates/plan.md"

# Deliberately first: at the Base SHA there is no producer at all, so the pre-change red
# reads as "nothing substitutes the placeholder", not as an error deeper in.
if [ ! -f "$STAMPER" ]; then
  _fail "a producer exists at scripts/stamp-plan-objective.sh" \
    "no file at $STAMPER — nothing substitutes templates/plan.md's feat_id placeholder"
  report_results
  exit 1
fi
if [ -x "$STAMPER" ]; then
  _pass "the producer is executable"
else
  _fail "the producer is executable" "$STAMPER is not +x"
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-plan-binding-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

TPL_FEAT=$(awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f && /^---[[:space:]]*$/ {exit} f && /^feat_id:/ {sub(/^feat_id:[[:space:]]*/, ""); print; exit}' "$TEMPLATE")
assert_eq "the shipped template declares its feat_id as an INERT placeholder, not a value" \
  "$TPL_FEAT" "<FEAT-NNN>"

# born_project <dir> <feat_id> [--roster] — a project built the way a real one is:
# templates/plan.md copied verbatim, then (optionally) a roster written into ## Tasks.
born_project() {
  local dir="$1" feat="$2" roster="${3:-}"
  mkdir -p "$dir/nazgul/tasks" "$dir/fakebin"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" remote add origin https://github.com/OrodruinLabs/nazgul.git
  echo seed > "$dir/seed"; git -C "$dir" add seed; git -C "$dir" commit -qm base
  cp "$TEMPLATE" "$dir/nazgul/plan.md"
  if [ "$roster" = "--roster" ]; then
    awk '/^## Tasks/ {print; print ""; print "### TASK-001: build the thing";
         print "- **Status**: IMPLEMENTED"; print "- **Manifest**: nazgul/tasks/TASK-001.md"; next}
         {print}' "$dir/nazgul/plan.md" > "$dir/nazgul/plan.md.new"
    mv "$dir/nazgul/plan.md.new" "$dir/nazgul/plan.md"
  fi
  jq -n --arg f "$feat" '{feat_id:$f, branch:{feature:"feat/\($f)-x", base:"main"},
    agents:{reviewers:["code-reviewer"]}, afk:{yolo:false}}' > "$dir/nazgul/config.json"
}

# Payload SHAPE captured verbatim from the real producer by tests/test-merge-provider.sh;
# only mergedAt/mergeCommit/headRefName are fixture-controlled, so no network is contacted.
born_gh_shim() {
  local dir="$1" head="$2"
  cat > "$dir/fakebin/gh" <<GH
#!/usr/bin/env bash
case "\${1:-}" in
  auth) exit 0 ;;
  pr) [ "\${2:-}" = view ] || exit 1
      printf '%s\n' '{"baseRefName":"main","headRefName":"$head","mergeCommit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},"mergedAt":"2026-08-15T12:00:00Z","state":"MERGED"}'
      exit 0 ;;
esac
exit 1
GH
  chmod +x "$dir/fakebin/gh"
}

born_manifest() {
  local dir="$1" head="$2" base
  base=$(git -C "$dir" rev-parse HEAD)
  cat > "$dir/nazgul/tasks/TASK-001.md" <<M
---
status: IMPLEMENTED
---
# TASK-001

## Metadata
- **ID**: TASK-001
- **Base SHA**: $base

## Commits
$base

## Merge Evidence
- **host**: github.com
- **pr**: 88
- **merged-at**: 2026-08-15T12:00:00Z
- **merge-commit**: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
- **head-ref**: $head
- **recorded-by**: scripts/close-objective.sh (host API, ok)
M
}

roster_of() { # <project dir> -> the gate's own answer, stdout+stderr merged
  ( source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
    ttg_objective_roster "$1/nazgul" ) 2>&1
}

# Case 1 | the placeholder cannot survive into a passing roster. Born from the shipped
# template, planned, never stamped: refuse, and name the un-run producer, not a rival id.
P1="$SCRATCH/unstamped"
born_project "$P1" FEAT-030 --roster
R1=$(roster_of "$P1"); R1_EC=$?
assert_exit_code "template-born + planned + unstamped: the roster gate REFUSES" "$R1_EC" 1
assert_contains "the refusal names the unsubstituted placeholder, not a rival objective" \
  "$R1" "unsubstituted placeholder"
assert_not_contains "and does not misreport an un-run producer as a disagreement" \
  "$R1" "the roster and the objective disagree"
assert_contains "the refusal names the producer that fixes it, by path" \
  "$R1" "scripts/stamp-plan-objective.sh"

# Case 2 | a template-born project reaches DONE once the producer runs. Driven, not
# reasoned about: the sole sanctioned writer and the real seam over a PATH-shim gh.
born_gh_shim "$P1" "feat/FEAT-030-x"
born_manifest "$P1" "feat/FEAT-030-x"
STAMP_OUT=$(bash "$STAMPER" --project-root "$P1" 2>&1); STAMP_EC=$?
assert_exit_code "the producer stamps a planned template-born plan" "$STAMP_EC" 0
assert_contains "the producer reports the action it took" "$STAMP_OUT" "action=stamped"
assert_contains "the producer reports the value it re-read from disk, not the one it sent" \
  "$STAMP_OUT" "feat_id=FEAT-030"
assert_file_contains "the placeholder is gone from the plan on disk" \
  "$P1/nazgul/plan.md" "feat_id: FEAT-030"
assert_file_not_contains "and no placeholder line survives beside it" \
  "$P1/nazgul/plan.md" "feat_id: <FEAT-NNN>"

TRANS_OUT=$(PATH="$P1/fakebin:$PATH" CLAUDE_PROJECT_DIR="$P1" \
  bash "$REPO_ROOT/scripts/task-transition.sh" transition TASK-001 IMPLEMENTED DONE 2>&1); TRANS_EC=$?
assert_exit_code "a template-born project reaches DONE through the merge-evidence route" "$TRANS_EC" 0
assert_contains "and the accepted route is named on stderr" "$TRANS_OUT" "merge-evidence route"
assert_eq "DONE is what is on disk, not merely what was reported" \
  "$(sed -n '2p' "$P1/nazgul/tasks/TASK-001.md")" "status: DONE"

# Case 3 | idempotence: a second run is not a second binding.
STAMP2=$(bash "$STAMPER" --project-root "$P1" 2>&1); STAMP2_EC=$?
assert_exit_code "re-running the producer succeeds" "$STAMP2_EC" 0
assert_contains "re-running reports already-bound rather than stamping again" \
  "$STAMP2" "action=already-bound"

# Case 4 | the producer refuses what it must not overwrite. A wrong binding is worse than
# an absent one: it scopes the roster to the wrong objective.
P2="$SCRATCH/foreign"
born_project "$P2" FEAT-031 --roster
sed -i.bak 's/^feat_id: <FEAT-NNN>/feat_id: FEAT-030/' "$P2/nazgul/plan.md" && rm -f "$P2/nazgul/plan.md.bak"
BEFORE=$(cat "$P2/nazgul/plan.md")
FOREIGN=$(bash "$STAMPER" --project-root "$P2" 2>&1); FOREIGN_EC=$?
assert_exit_code "the producer REFUSES a plan bound to a different real objective" "$FOREIGN_EC" 1
assert_contains "and names both ids rather than silently picking one" "$FOREIGN" "FEAT-030"
assert_eq "a refused stamp leaves the plan byte-identical" "$(cat "$P2/nazgul/plan.md")" "$BEFORE"

# Case 5 | an unplanned plan has no roster to claim. The template documents its format with
# COMMENTED examples, so this used to yield a one-id roster: a task nobody ever wrote.
P3="$SCRATCH/unplanned"
born_project "$P3" FEAT-030
R3=$(roster_of "$P3"); R3_EC=$?
assert_exit_code "template-born + never planned: the roster gate refuses" "$R3_EC" 1
assert_not_contains "an unplanned plan yields NO roster member at all" "$R3" "TASK-001"
UNPLANNED=$(bash "$STAMPER" --project-root "$P3" 2>&1); UNPLANNED_EC=$?
assert_exit_code "the producer refuses to bind a plan with no roster" "$UNPLANNED_EC" 1
assert_contains "and says why: the frontmatter is a claim ABOUT the roster" \
  "$UNPLANNED" "no ## Tasks roster"

# Bind by hand so the placeholder is no longer what refuses and the roster fact is isolated:
# "found only documentation" is its own answer, distinct from "found none".
sed -i.bak 's/^feat_id: <FEAT-NNN>/feat_id: FEAT-030/' "$P3/nazgul/plan.md" && rm -f "$P3/nazgul/plan.md.bak"
R3B=$(roster_of "$P3"); R3B_EC=$?
assert_exit_code "an unplanned plan whose frontmatter DOES agree still refuses" "$R3B_EC" 1
assert_contains "a roster of only commented examples gets its own sentence" \
  "$R3B" "ONLY inside HTML comments"
assert_not_contains "and no commented example id is returned as a roster member" \
  "$R3B" "TASK-001"

# Case 6 | the producer never invents the value.
P4="$SCRATCH/noident"
born_project "$P4" FEAT-030 --roster
jq 'del(.feat_id)' "$P4/nazgul/config.json" > "$P4/nazgul/c.tmp" && mv "$P4/nazgul/c.tmp" "$P4/nazgul/config.json"
NOID=$(bash "$STAMPER" --project-root "$P4" 2>&1); NOID_EC=$?
assert_exit_code "with no config.feat_id the producer refuses rather than derives one" "$NOID_EC" 1
assert_contains "and says the objective has no identity yet" "$NOID" "names no feat_id"
assert_file_contains "the plan keeps its placeholder rather than a guessed id" \
  "$P4/nazgul/plan.md" "feat_id: <FEAT-NNN>"

# Case 7 | [advisory] the Planner is instructed to run it. A prompt contract cannot be
# enforced inside a model's turn (RULES.md §21); that the spec SAYS it is checkable.
PLANNER=$(cat "$REPO_ROOT/agents/planner.md")
assert_contains "[advisory] agents/planner.md instructs the Planner to run the producer" \
  "$PLANNER" "scripts/stamp-plan-objective.sh"
assert_contains "[advisory] and tells it the value comes from config.feat_id" \
  "$PLANNER" "config.feat_id"
assert_contains "[advisory] and forbids re-deriving the id" "$PLANNER" "never re-derive it"
INIT=$(cat "$REPO_ROOT/skills/init/SKILL.md")
assert_contains "[advisory] skills/init/SKILL.md says the placeholder is inert at init time" \
  "$INIT" "verbatim, placeholder and all"

# Case 8 | ONE roster parser, not two. Board 4 found the producer and the predicate each
# carrying the same three-stage pipeline while the producer's header claimed it was shared.
ROSTER_AWK='/^## Tasks/{f=1;next} f && /^## /{exit} f'
ROSTER_PIPE='grep -oE "$_TTG_ROSTER_ID_RE" | LC_ALL=C sort -u'

roster_parser_sites() { grep -rlF -- "$ROSTER_AWK" "$1" 2>/dev/null | LC_ALL=C sort; }
roster_pipe_sites()   { grep -rlF -- "$ROSTER_PIPE" "$1" 2>/dev/null | LC_ALL=C sort; }

SITES=$(roster_parser_sites "$REPO_ROOT/scripts")
assert_eq "the ## Tasks section extractor exists in exactly one file under scripts/" \
  "$(printf '%s\n' "$SITES" | grep -c . || true)" "1"
assert_contains "and that file is the shared library, not the producer" \
  "$SITES" "scripts/lib/task-transition-guard.sh"
PIPE_SITES=$(roster_pipe_sites "$REPO_ROOT/scripts")
assert_eq "the roster id pipeline likewise exists in exactly one file under scripts/" \
  "$(printf '%s\n' "$PIPE_SITES" | grep -c . || true)" "1"

# The denominator above is only worth anything if a private copy would actually raise it,
# so make one and check the same predicate reports two rather than trusting that it would.
MUT="$SCRATCH/mutant"; mkdir -p "$MUT/lib"
cp "$REPO_ROOT/scripts/lib/task-transition-guard.sh" "$MUT/lib/"
{ cat "$STAMPER"; printf '%s\n' "PRIVATE=\$(awk '$ROSTER_AWK' \"\$PLAN\" | $ROSTER_PIPE)"; } > "$MUT/stamp.sh"
assert_eq "[mutation] a private copy in the producer makes the extractor check report 2" \
  "$(roster_parser_sites "$MUT" | grep -c . || true)" "2"
assert_eq "[mutation] and makes the pipeline check report 2" \
  "$(roster_pipe_sites "$MUT" | grep -c . || true)" "2"

assert_file_contains "the producer reaches the roster through the shared function" \
  "$STAMPER" "ttg_objective_roster_ids "
assert_file_contains "and so does the gate's own predicate" \
  "$REPO_ROOT/scripts/lib/task-transition-guard.sh" "ids=\$(ttg_objective_roster_ids \"\$plan\")"

# Case 8b | input built to separate the two parsers if they ever diverge: a commented id, a
# duplicate, a PATCH id no producer writes and no gate can ask about, an id past the heading.
P5="$SCRATCH/tricky"
born_project "$P5" FEAT-042
awk '/^## Tasks/ {print; print "";
     print "<!-- ### TASK-900: commented example, not a member -->";
     print "### TASK-001: real"; print "### TASK-002: real"; print "### TASK-002: duplicate";
     print "- PATCH-007 named inline"; print ""; print "## Wave Groups";
     print "### TASK-800: below the terminating heading"; next} {print}' \
  "$P5/nazgul/plan.md" > "$P5/nazgul/plan.new" && mv "$P5/nazgul/plan.new" "$P5/nazgul/plan.md"
TRICKY=$(bash "$STAMPER" --project-root "$P5" 2>&1); TRICKY_EC=$?
assert_exit_code "the producer stamps the tricky roster" "$TRICKY_EC" 0
assert_contains "the producer counts exactly the two real ids" "$TRICKY" "roster_tasks=2"
GATE_IDS=$(roster_of "$P5")
assert_eq "the gate returns the identical id set, so producer and predicate agree" \
  "$(printf '%s' "$GATE_IDS" | tr '\n' ' ')" "TASK-001 TASK-002"
assert_not_contains "neither parser admits a commented example" "$GATE_IDS" "TASK-900"
assert_not_contains "nor an id below the terminating heading" "$GATE_IDS" "TASK-800"
assert_not_contains "nor a patch id: an arm no producer can reach was removed, not left dead" \
  "$GATE_IDS" "PATCH-007"
assert_not_contains "and the producer agrees, so the two did not diverge on the removal" \
  "$TRICKY" "PATCH-007"

# Case 9 | the file mode is READ or the write is refused — never guessed. chmod --reference
# is a GNU extension, so on this repo's stated platform its fallback was the only branch.
assert_eq "chmod --reference appears nowhere under scripts/" \
  "$(grep -rlF -- 'chmod --reference' "$REPO_ROOT/scripts" 2>/dev/null | grep -c . || true)" "0"

P6="$SCRATCH/mode"
born_project "$P6" FEAT-043 --roster
chmod 600 "$P6/nazgul/plan.md"
MODE_OUT=$(bash "$STAMPER" --project-root "$P6" 2>&1); MODE_EC=$?
assert_exit_code "the producer stamps a plan whose mode is not the fallback literal" "$MODE_EC" 0
assert_contains "and reports the stamp it took" "$MODE_OUT" "action=stamped"
assert_eq "and the plan keeps its own mode rather than being normalised to 644" \
  "$( ( source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"; _ttg_file_mode "$P6/nazgul/plan.md" ) )" "600"

MODE_ERR=$( ( source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
              _ttg_file_mode "$SCRATCH/does-not-exist" ) 2>&1 >/dev/null )
MODE_VAL=$( ( source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
              _ttg_file_mode "$SCRATCH/does-not-exist" ) 2>/dev/null ); MODE_RC=$?
assert_exit_code "_ttg_file_mode fails on a mode it cannot read" "$MODE_RC" 1
assert_eq "and yields no value at all, rather than a default" "$MODE_VAL" ""
assert_contains "and says which file it could not read" "$MODE_ERR" "does-not-exist"

# Drive the producer's own failure path: a stat that answers nothing must stop the write,
# not install a rewrite under a literal mode.
P7="$SCRATCH/nostat"
born_project "$P7" FEAT-044 --roster
printf '#!/bin/sh\nexit 1\n' > "$P7/fakebin/stat"; chmod +x "$P7/fakebin/stat"
PLAN_BEFORE=$(cat "$P7/nazgul/plan.md")
NOSTAT=$(PATH="$P7/fakebin:$PATH" bash "$STAMPER" --project-root "$P7" 2>&1); NOSTAT_EC=$?
assert_exit_code "an unreadable mode stops the producer at its precondition exit" "$NOSTAT_EC" 3
assert_contains "the producer says it refused rather than guessing a mode" "$NOSTAT" "cannot read"
assert_not_contains "and never names a substituted default" "$NOSTAT" "644"
assert_eq "the plan is byte-identical after the refusal" "$(cat "$P7/nazgul/plan.md")" "$PLAN_BEFORE"
assert_eq "and no staged rewrite is left beside it" \
  "$(find "$P7/nazgul" -maxdepth 1 -name '.nazgul-plan.*' | grep -c . || true)" "0"

report_results
