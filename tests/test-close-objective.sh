#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.
#
# Test: scripts/close-objective.sh — FEAT-031 TASK-011, the objective closer
# (ADR-023). The host is a PATH-shim mock throughout: NO network, no credential,
# and no real PR is contacted from this suite.
#
# RESPONSE PROVENANCE — derived-from-captured, and named as such rather than passed
# off as either. The gh payload SHAPE below is the one tests/test-merge-provider.sh
# captured verbatim from the real producer (gh 2.80.0, 2025-09-23, `gh pr view <n>
# --json state,mergedAt,mergeCommit` against this repo's own PRs); only the
# `mergeCommit.oid` is substituted, with this fixture's OWN commit sha. That
# substitution is load-bearing, not cosmetic: the squash property this file exists to
# prove — an ancestry check FAILING for the recorded sha — is only real if both shas
# exist in the fixture repo, and a captured oid from another repository could not be
# an ancestor of anything here for the wrong reason. The unauthenticated and
# unsupported-host cases are SYNTHETIC: neither can be captured from a healthy
# authenticated GitHub host.
#
# Coverage population (RULES.md §15): the CLOSED skip-reason set is extracted from the
# closer itself, so a reason no scenario drives shows up as an unchecked scan entry
# rather than quietly ceasing to exist.
TEST_NAME="test-close-objective"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

CLOSER="$REPO_ROOT/scripts/close-objective.sh"

# Case 1, deliberately FIRST: at the Base SHA there is no closer at all, so the
# pre-change red reads as "no closure path existed", not as an error deeper in.
if [ ! -f "$CLOSER" ]; then
  _fail "the objective closer exists at scripts/close-objective.sh" \
    "no file at $CLOSER — no closure path exists, so nothing below can be checked"
  report_results
  exit 1
fi
if [ -x "$CLOSER" ]; then
  _pass "the objective closer is executable"
else
  _fail "the objective closer is executable" "$CLOSER is not +x"
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-close-objective-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

CLOSER_SRC=$(cat "$CLOSER")

# The closed skip-reason set, EXTRACTED from the closer in its documented order; the
# grammar check below then asserts the emitter agrees with it, slot for slot.
REASONS=$(printf '%s\n' "$CLOSER_SRC" | grep -oE '^#   [a-z][a-z-]+ ' | sed 's/^#   //; s/ *$//' | awk '!seen[$0]++')
CO_SCANNED=$(printf '%s\n' "$REASONS" | grep -c '[a-z]')
CO_CHECKED=0
CO_SKIP_UNDRIVEN=0
DRIVEN=""

_drove() {
  local r
  for r in "$@"; do
    case " $DRIVEN " in
      *" $r "*) ;;
      *) DRIVEN="$DRIVEN $r"; CO_CHECKED=$((CO_CHECKED + 1)) ;;
    esac
  done
}

# gh shim: the captured shape, case-selected by env, every call recorded so the
# CALL is asserted and not merely its parse.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-co-fakebin-XXXXXX")
GH_LOG="$FAKEBIN/gh-argv.log"
cat > "$FAKEBIN/gh" << 'GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NAZGUL_TEST_GH_LOG:-/dev/null}"
sub="${1:-}"; shift || true
case "$sub" in
  auth)
    [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0
    printf 'You are not logged into any GitHub hosts. To log in, run: gh auth login\n' >&2
    exit 1 ;;
  pr)
    [ "${1:-}" = "view" ] || exit 1
    case "${NAZGUL_TEST_GH_CASE:-merged}" in
      merged)
        printf '{"mergeCommit":{"oid":"%s"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED"}\n' \
          "${NAZGUL_TEST_MERGE_SHA:-}"
        exit 0 ;;
      open)
        printf '%s\n' '{"mergeCommit":null,"mergedAt":null,"state":"OPEN"}'
        exit 0 ;;
      no_commit)
        printf '%s\n' '{"mergeCommit":null,"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED"}'
        exit 0 ;;
      error)
        printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 999999. (repository.pullRequest)' >&2
        exit 1 ;;
    esac
    exit 1 ;;
esac
exit 1
GH_EOF
chmod +x "$FAKEBIN/gh"
export NAZGUL_TEST_GH_LOG="$GH_LOG"
ORIG_PATH="$PATH"

# _fixture <name> [remote] — a project whose recorded feature sha is provably NOT an
# ancestor of the base tip. Sets FX, FEAT_SHA, MERGE_SHA.
_fixture() {
  local name="$1" remote="${2:-https://github.com/OrodruinLabs/nazgul.git}" base
  FX="$SCRATCH/$name"
  mkdir -p "$FX/nazgul/tasks" "$FX/nazgul/logs"
  jq '.review_gate.granularity = "task" | .telemetry.bus_enabled = true' \
    "$REPO_ROOT/templates/config.json" > "$FX/nazgul/config.json"
  git -C "$FX" init -q
  git -C "$FX" config user.email "test@nazgul.dev"
  git -C "$FX" config user.name "Nazgul Test"
  printf 'base\n' > "$FX/base.txt"
  git -C "$FX" add -A && git -C "$FX" commit -q -m "base"
  base=$(git -C "$FX" rev-parse --abbrev-ref HEAD)
  git -C "$FX" checkout -q -b feature-side
  printf 'feature\n' > "$FX/feature.txt"
  git -C "$FX" add -A && git -C "$FX" commit -q -m "feature work"
  FEAT_SHA=$(git -C "$FX" rev-parse HEAD)
  git -C "$FX" checkout -q "$base"
  printf 'squashed\n' > "$FX/squashed.txt"
  git -C "$FX" add -A && git -C "$FX" commit -q -m "squashed feature work (#88)"
  MERGE_SHA=$(git -C "$FX" rev-parse HEAD)
  git -C "$FX" remote add origin "$remote"
  export NAZGUL_TEST_MERGE_SHA="$MERGE_SHA"
}

# _manifest <id> <status> [with_commits] — a pre-FEAT-031-shaped manifest: canonical
# frontmatter, no `## Merge Evidence` section anywhere.
_manifest() {
  local id="$1" status="$2" with_commits="${3:-yes}"
  {
    printf -- '---\nstatus: %s\n---\n' "$status"
    printf '# %s: stranded by an external merge\n\n' "$id"
    printf -- '- **Depends on**: none\n- **Group**: 1\n- **Retry count**: 0/3\n\n'
    [ "$with_commits" = "yes" ] && printf '## Commits\n%s\n\n' "$FEAT_SHA"
    printf '## Implementation Log\nshipped, then merged outside the loop.\n'
  } > "$FX/nazgul/tasks/${id}.md"
}

# _run <project_root> <pr> — CO_OUT / CO_ERR / CO_RC / CO_LINE.
_run() {
  CO_OUT=$(PATH="$FAKEBIN:$ORIG_PATH" bash "$CLOSER" --pr "$2" --project-root "$1" 2>"$SCRATCH/co.err")
  CO_RC=$?
  CO_ERR=$(cat "$SCRATCH/co.err")
  CO_LINE=$(printf '%s' "$CO_OUT" | tail -1)
}

# _grammar <label> — the §15 line with this entry point's domain nouns, N == M + K
# asserted, and the extracted reasons present IN ORDER and summing to M.
_grammar() {
  local label="$1" reason_re="" r first=1 sum=0 tok
  for r in $REASONS; do
    if [ "$first" = "1" ]; then reason_re="$r=([0-9]+)"; first=0
    else reason_re="$reason_re, $r=([0-9]+)"; fi
  done
  CO_N=""; CO_M=""; CO_K=""; CO_F=""
  if ! printf '%s' "$CO_LINE" \
    | grep -qE "^close-objective: ([0-9]+) scanned, ([0-9]+) skipped \($reason_re\), ([0-9]+) closed, ([0-9]+) refused\$"; then
    _fail "$label: terminal line matches the §15 grammar with this entry point's nouns" "got: '$CO_LINE'"
    return 1
  fi
  _pass "$label: terminal line matches the §15 grammar with this entry point's nouns"
  CO_N=$(printf '%s' "$CO_LINE" | sed -E 's/^[^:]*: ([0-9]+) scanned.*/\1/')
  CO_M=$(printf '%s' "$CO_LINE" | sed -E 's/^.* ([0-9]+) skipped \(.*/\1/')
  CO_K=$(printf '%s' "$CO_LINE" | sed -E 's/^.*\), ([0-9]+) closed.*/\1/')
  CO_F=$(printf '%s' "$CO_LINE" | sed -E 's/^.*, ([0-9]+) refused$/\1/')
  assert_eq "$label: the emitter's own N == M + K holds" "$CO_N" "$((CO_M + CO_K))"
  for tok in $(printf '%s' "$CO_LINE" | sed -E 's/^.*\(([^)]*)\).*/\1/' | tr ',' ' '); do
    case "$tok" in *=*) sum=$((sum + ${tok##*=})) ;; esac
  done
  assert_eq "$label: the enumerated skip reasons account for all M" "$sum" "$CO_M"
  return 0
}

# _reason <label> <reason> <expected-count>
_reason() {
  local got
  got=$(printf '%s' "$CO_LINE" | sed -E "s/^.*[(,] ?$2=([0-9]+).*/\1/")
  assert_eq "$1: $2=$3" "$got" "$3"
}

# Scenario A — the squash-merged objective. That the recorded sha is NOT an ancestor
# is asserted here, so this can never degrade into a fast-forward case passing wrongly.
_fixture squash
if git -C "$FX" merge-base --is-ancestor "$FEAT_SHA" "$MERGE_SHA" 2>/dev/null; then
  _fail "the squash fixture genuinely squashes" \
    "the recorded sha IS an ancestor of the merge commit — this fixture proves nothing about squash"
else
  _pass "the squash fixture genuinely squashes (recorded sha is NOT an ancestor of the merge commit)"
fi
_manifest TASK-001 IMPLEMENTED
_manifest TASK-002 IN_REVIEW
_manifest TASK-003 DONE
_manifest TASK-004 READY
ln -s "$FX/nazgul/tasks/TASK-001.md" "$FX/nazgul/tasks/TASK-900.md"

: > "$GH_LOG"
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "squash close: exit 0 — tasks closed, nothing refused" "$CO_RC" 0
_grammar "squash close"
_reason "squash close" "already-terminal" 1
_reason "squash close" "not-closable-status" 1
_reason "squash close" "unreadable" 1
_reason "squash close" "not-merged" 0
assert_eq "squash close: both closable tasks closed" "$CO_K" "2"
assert_eq "squash close: nothing refused" "$CO_F" "0"
_drove already-terminal not-closable-status unreadable

assert_contains "squash close: the host is asked the merge-state question, by PR" \
  "$(cat "$GH_LOG")" "pr view 88 --json state,mergedAt,mergeCommit"
assert_eq "squash close: IMPLEMENTED -> DONE landed on disk" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-001.md")" "DONE"
assert_eq "squash close: IN_REVIEW -> DONE landed on disk, with no review directory anywhere" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-002.md")" "DONE"
assert_dir_not_exists "squash close: no review directory was fabricated" "$FX/nazgul/reviews/TASK-001"

assert_contains "squash close: the failed ancestry check is reported as the squash signature" \
  "$CO_OUT" "squash-signature=2"
assert_contains "squash close: the report says outright that ancestry is never a predicate" \
  "$CO_OUT" "never a predicate"

MANIFEST_1=$(cat "$FX/nazgul/tasks/TASK-001.md")
assert_contains "squash close: ## Merge Evidence was written from the API response" \
  "$MANIFEST_1" "## Merge Evidence"
assert_contains "squash close: the recorded host is the host's own" "$MANIFEST_1" "- **host**: github.com"
assert_contains "squash close: the recorded pr is the pr asked about" "$MANIFEST_1" "- **pr**: 88"
assert_contains "squash close: merged-at comes from the API response" \
  "$MANIFEST_1" "- **merged-at**: 2026-08-14T23:16:50Z"
assert_contains "squash close: merge-commit comes from the API response" \
  "$MANIFEST_1" "- **merge-commit**: $MERGE_SHA"
assert_contains "squash close: the evidence names its producer" \
  "$MANIFEST_1" "- **recorded-by**: scripts/close-objective.sh"
assert_eq "squash close: exactly one status line survives in the frontmatter" \
  "$(printf '%s\n' "$MANIFEST_1" | grep -c '^status: ')" "1"
assert_contains "squash close: the pre-existing body is preserved, not rewritten" \
  "$MANIFEST_1" "shipped, then merged outside the loop."

# The closure is legitimate only because the SOLE SANCTIONED WRITER performed it; the
# completed-transition ledger is that proof, not the manifest's new status.
LEDGER="$FX/nazgul/logs/guarded-transitions.jsonl"
assert_file_exists "squash close: the sanctioned writer recorded a completed transition" "$LEDGER"
assert_eq "squash close: the recorded edge is IMPLEMENTED -> DONE for TASK-001" \
  "$(jq -r 'select(.task_id == "TASK-001") | "\(.from)->\(.to)"' "$LEDGER" | tail -1)" "IMPLEMENTED->DONE"
assert_eq "squash close: the recorded edge is IN_REVIEW -> DONE for TASK-002" \
  "$(jq -r 'select(.task_id == "TASK-002") | "\(.from)->\(.to)"' "$LEDGER" | tail -1)" "IN_REVIEW->DONE"
assert_file_contains "squash close: each closure reaches the bus" \
  "$FX/nazgul/logs/events.jsonl" '"event":"close_objective_closed"'

# Scenario A2 — re-running is idempotent: nothing left to close is NOT a silent
# success, and the evidence section is replaced rather than duplicated.
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "re-run: nothing left to close is NOTHING CHECKED, not a clean pass" "$CO_RC" 2
_grammar "re-run"
_reason "re-run" "already-terminal" 3
assert_contains "re-run: the nothing-checked signal is loud" "$CO_ERR" "NOTHING CHECKED"
assert_eq "re-run: the evidence section was not duplicated" \
  "$(grep -c '^## Merge Evidence' "$FX/nazgul/tasks/TASK-001.md")" "1"

# Scenario B — a stranded pre-objective manifest: no `## Merge Evidence`, no
# `## Commits` at all. AC20's real input, closed or refused BY NAME, never crashed on.
_fixture stranded
_manifest TASK-007 IMPLEMENTED no
NAZGUL_TEST_GH_CASE=merged _run "$FX" 91
assert_exit_code "stranded manifest: closed, not crashed on" "$CO_RC" 0
_grammar "stranded manifest"
assert_eq "stranded manifest: it closed" "$CO_K" "1"
assert_eq "stranded manifest: reached DONE" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-007.md")" "DONE"
assert_contains "stranded manifest: evidence was written from the API response" \
  "$(cat "$FX/nazgul/tasks/TASK-007.md")" "- **merge-commit**: $MERGE_SHA"

# Scenario B2 — a stale MID-FILE evidence section is replaced in place, with the
# sections after it intact: a rerun after a re-merge must not append a second record.
_fixture restale
{
  printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-008: closed once against a stale record\n\n'
  printf '## Merge Evidence\n- **host**: github.com\n- **pr**: 1\n'
  printf -- '- **merged-at**: 2020-01-01T00:00:00Z\n- **merge-commit**: deadbeefdeadbeef\n\n'
  printf '## Implementation Log\nthe section after the evidence must survive.\n'
} > "$FX/nazgul/tasks/TASK-008.md"
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "stale evidence: closed against the fresh API answer" "$CO_RC" 0
RESTALE=$(cat "$FX/nazgul/tasks/TASK-008.md")
assert_eq "stale evidence: exactly one evidence section survives" \
  "$(printf '%s\n' "$RESTALE" | grep -c '^## Merge Evidence')" "1"
assert_not_contains "stale evidence: the stale merge commit is gone" "$RESTALE" "deadbeefdeadbeef"
assert_contains "stale evidence: the fresh merge commit replaced it" "$RESTALE" "- **merge-commit**: $MERGE_SHA"
assert_contains "stale evidence: the section after it is intact" \
  "$RESTALE" "the section after the evidence must survive."

# Scenario C — an unrecognised host closes NOTHING, by name, on stderr and on the bus.
# Never a silent no-op, and never a fallback to git ancestry.
_fixture badhost "https://git.example.invalid/acme/thing.git"
_manifest TASK-011 IMPLEMENTED
: > "$GH_LOG"
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "unsupported host: nothing closed is a nonzero exit" "$CO_RC" 2
_grammar "unsupported host"
_reason "unsupported host" "merge-unverifiable" 1
assert_eq "unsupported host: nothing was closed" "$CO_K" "0"
assert_contains "unsupported host: the diagnostic names the condition" "$CO_ERR" "unsupported_host"
assert_contains "unsupported host: the closer names its own refusal to close" \
  "$CO_ERR" "close-objective: no closure for PR 88 [merge-unverifiable]"
assert_file_contains "unsupported host: a telemetry record is written by the closer itself" \
  "$FX/nazgul/logs/events.jsonl" '"event":"close_objective_blocked"'
assert_eq "unsupported host: the task is untouched at IMPLEMENTED" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-011.md")" "IMPLEMENTED"
assert_not_contains "unsupported host: no evidence was written on an unverified merge" \
  "$(cat "$FX/nazgul/tasks/TASK-011.md")" "## Merge Evidence"
assert_eq "unsupported host: the host CLI was never invoked" "$(cat "$GH_LOG")" ""
_drove merge-unverifiable

# Scenario D — "could not look" is a DIFFERENT skip reason from "not merged". This is
# the single property the whole seam exists to preserve.
_fixture notmerged
_manifest TASK-021 IMPLEMENTED
NAZGUL_TEST_GH_CASE=open _run "$FX" 194
assert_exit_code "open PR: nothing closed" "$CO_RC" 2
_grammar "open PR"
_reason "open PR" "not-merged" 1
_reason "open PR" "merge-unverifiable" 0
assert_contains "open PR: the diagnostic says the host ANSWERED" \
  "$CO_ERR" "the host ANSWERED and reports PR 194 is not merged"
_drove not-merged

_fixture apifail
_manifest TASK-031 IMPLEMENTED
NAZGUL_TEST_GH_CASE=error _run "$FX" 999999
assert_exit_code "api failure: nothing closed" "$CO_RC" 2
_grammar "api failure"
_reason "api failure" "merge-unverifiable" 1
_reason "api failure" "not-merged" 0
assert_contains "api failure: the closer says explicitly this is not 'not merged'" \
  "$CO_ERR" "this is NOT 'not merged'"
assert_eq "api failure: the task is untouched" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-031.md")" "IMPLEMENTED"

_fixture unauth
_manifest TASK-041 IMPLEMENTED
NAZGUL_TEST_GH_AUTH=no NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
_grammar "unauthenticated host"
_reason "unauthenticated host" "merge-unverifiable" 1
assert_contains "unauthenticated host: the remedy is named" "$CO_ERR" "gh auth login"

# Scenario E — the host says MERGED but its answer cannot BE evidence. A partial
# answer must not become a partial manifest section the gate then rejects.
_fixture nocommit
_manifest TASK-051 IMPLEMENTED
NAZGUL_TEST_GH_CASE=no_commit _run "$FX" 88
assert_exit_code "unusable answer: nothing closed" "$CO_RC" 2
_grammar "unusable answer"
_reason "unusable answer" "merge-unverifiable" 1
assert_contains "unusable answer: the diagnostic names the unusable field" \
  "$CO_ERR" "not usable as evidence: merge-commit="
assert_not_contains "unusable answer: no partial evidence section was written" \
  "$(cat "$FX/nazgul/tasks/TASK-051.md")" "## Merge Evidence"

# Scenario F — a refusal is a REPORTED outcome, typed, never a crash. A regular file
# where nazgul/locks/ must be a directory makes the sanctioned writer refuse.
_fixture refused
_manifest TASK-061 IMPLEMENTED
printf 'not a directory\n' > "$FX/nazgul/locks"
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "transition refused: a refusal exits nonzero, having crashed on nothing" "$CO_RC" 1
_grammar "transition refused"
_reason "transition refused" "transition-refused" 1
assert_eq "transition refused: it is counted as a refusal, not only as a skip" "$CO_F" "1"
assert_contains "transition refused: the refusal record is TYPED and names the task" \
  "$CO_ERR" "REFUSED TASK-061 [reason: transition-refused]"
assert_file_contains "transition refused: the refusal reaches the bus" \
  "$FX/nazgul/logs/events.jsonl" '"event":"close_objective_refused"'
assert_eq "transition refused: the task stayed where it was" \
  "$(get_task_status "$FX/nazgul/tasks/TASK-061.md")" "IMPLEMENTED"
assert_contains "transition refused: the closer never claims a clean close-out" \
  "$CO_ERR" "NOTHING CHECKED"
_drove transition-refused

# Scenario G — an unwritable manifest is a named refusal, not a traceback.
_fixture unwritable
_manifest TASK-071 IMPLEMENTED
if [ "$(id -u)" = "0" ]; then
  CO_SKIP_UNDRIVEN=$((CO_SKIP_UNDRIVEN + 1))
  _skip "evidence-write-failed (running as root — a read-only directory is not enforced)"
else
  chmod 555 "$FX/nazgul/tasks"
  NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
  chmod 755 "$FX/nazgul/tasks"
  assert_exit_code "unwritable manifest: a refusal exits nonzero" "$CO_RC" 1
  _grammar "unwritable manifest"
  _reason "unwritable manifest" "evidence-write-failed" 1
  assert_contains "unwritable manifest: the refusal is TYPED and names the task" \
    "$CO_ERR" "REFUSED TASK-071 [reason: evidence-write-failed]"
  assert_eq "unwritable manifest: the task stayed where it was" \
    "$(get_task_status "$FX/nazgul/tasks/TASK-071.md")" "IMPLEMENTED"
  _drove evidence-write-failed
fi

# Scenario H — usage and precondition errors are their own exit class.
UO=$(bash "$CLOSER" --project-root "$SCRATCH" 2>&1)
assert_exit_code "no --pr is a usage error" "$?" 3
assert_contains "no --pr says what is missing" "$UO" "--pr is required"
UO=$(bash "$CLOSER" --pr 1 --project-root "$SCRATCH/definitely-not-here" 2>&1)
assert_exit_code "a missing project root is a precondition error" "$?" 3
mkdir -p "$SCRATCH/nonazgul"
UO=$(bash "$CLOSER" --pr 1 --project-root "$SCRATCH/nonazgul" 2>&1)
assert_exit_code "a tree with no Nazgul config is a precondition error" "$?" 3
assert_contains "a tree with no Nazgul config says so" "$UO" "no valid regular non-symlink Nazgul config"

# Scenario I — no task manifests at all is its OWN nothing-checked wording.
_fixture emptytasks
NAZGUL_TEST_GH_CASE=merged _run "$FX" 88
assert_exit_code "no manifests: nothing checked" "$CO_RC" 2
_grammar "no manifests"
assert_eq "no manifests: zero scanned" "$CO_N" "0"
assert_contains "no manifests: named as its own condition, not as an all-skip run" \
  "$CO_ERR" "NOTHING CHECKED — no task manifests discovered"

# The constraint the whole objective rests on: this script is a CALLER of the sole
# sanctioned writer, never a writer. Asserted against its source, not its behaviour.
assert_contains "the closer routes its status changes through the sanctioned command" \
  "$CLOSER_SRC" 'bash "$SCRIPT_DIR/task-transition.sh" \'
assert_not_contains "the closer never calls the raw status writer" "$CLOSER_SRC" "set_task_status"
assert_not_contains "the closer never calls the transition primitive behind the command" \
  "$CLOSER_SRC" "ttg_apply_transition"
assert_not_contains "the closer never performs frontmatter surgery" "$CLOSER_SRC" "sed -i"
assert_eq "the sanctioned command is invoked from exactly one place" \
  "$(printf '%s\n' "$CLOSER_SRC" | grep -c 'bash "\$SCRIPT_DIR/task-transition.sh"')" "1"

# API first, ancestry NEVER: no executable line may consult git ancestry — the phrase
# survives only in the header that explains why it must not.
ANCESTRY_USES=$(printf '%s\n' "$CLOSER_SRC" | grep -cE '^[^#]*merge-base')
assert_eq "the closer never runs git merge-base on any executable line" "$ANCESTRY_USES" "0"
assert_contains "the why-ancestry-is-only-corroboration rationale lives where a reader will see it" \
  "$CLOSER_SRC" "API FIRST, ANCESTRY NEVER"

# §15 enrolment lands in the same change as the entry point it binds.
RULES=$(cat "$REPO_ROOT/RULES.md")
assert_contains "RULES.md §15 registers the closer as a bound entry point" \
  "$RULES" "scripts/close-objective.sh"
assert_contains "RULES.md §15 corrects the registry count to ten" "$RULES" "Ten entry points are bound"
assert_contains "tests/test-coverage-honesty.sh enumerates the closer" \
  "$(cat "$REPO_ROOT/tests/test-coverage-honesty.sh")" "close-objective"

CO_SKIPPED=$CO_SKIP_UNDRIVEN
if [ "$CO_SCANNED" -eq 0 ]; then
  _fail "the closer declares a countable skip-reason set this test can scan" \
    "zero reasons extracted from $CLOSER — a broken extractor, not an emitter without reasons"
fi
if [ "$CO_SCANNED" -ne $((CO_SKIPPED + CO_CHECKED)) ]; then
  CO_SKIP_UNDRIVEN=$((CO_SCANNED - CO_CHECKED))
  CO_SKIPPED=$CO_SKIP_UNDRIVEN
  _fail "every closed skip reason is driven by a scenario (N == M + K)" \
    "$CO_SCANNED scanned, $CO_CHECKED checked — driven:$DRIVEN"
fi

rm -rf "$FAKEBIN"

RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (undriven=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$CO_SCANNED" "$CO_SKIPPED" "$CO_SKIP_UNDRIVEN" "$CO_CHECKED" "$TESTS_FAILED"
exit "$RC"
