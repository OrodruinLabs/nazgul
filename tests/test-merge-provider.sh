#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.
#
# Test: scripts/lib/merge-provider.sh — FEAT-031 TASK-009, the host-agnostic
# merge-OBSERVATION seam (ADR-023). `gh` is a PATH-shim mock; NO network, no
# credential, no real PR is contacted from this suite.
#
# CAPTURED RESPONSE PROVENANCE — the shim below replays BYTES CAPTURED FROM THE
# REAL PRODUCER, not a shape written from the call site it serves. This is the
# discipline `nazgul/inbox/gh-response-shapes-are-fabricated-never-captured.md`
# (board #138) reports missing everywhere else in this suite; this file does not
# add to that debt.
#
#   tier:          captured
#   producer:      gh version 2.80.0 (2025-09-23)
#   captured:      2026-08-15, TASK-009, by the implementer, authenticated `gh auth`
#   recaptured:    2026-08-16, TASK-011 rework, with the two branch-name fields the
#                  objective-binding check needs.
#   recaptured:    2026-08-18, TASK-020, same producer and repo, with `url` — the field that
#                  makes the host's answer name the repository it is ABOUT. The OPEN payload
#                  is re-captured from PR 87 rather than 194 because 194 has since merged and
#                  a payload no PR still produces is authored, not captured.
#   captured-with: gh pr view 88     --repo github.com/OrodruinLabs/nazgul --json state,mergedAt,mergeCommit,headRefName,baseRefName,url  # merged
#                  gh pr view 87     --repo github.com/OrodruinLabs/nazgul --json state,mergedAt,mergeCommit,headRefName,baseRefName,url  # open
#                  gh pr view 999999 --repo github.com/OrodruinLabs/nazgul --json state,mergedAt,mergeCommit,headRefName,baseRefName,url  # error (exit 1)
#   source-repo:   OrodruinLabs/nazgul (this repo's own PRs — no third-party subject matter)
#   sha256:        ca2954997550da4adcd7a6f64b975e9924a415589b718e3e2910b0ec75d8536a  merged payload
#                  1f9dfa91c5d8c10b0c978aef873fd4458c5b5f65cb556589dab2230a2c633ced  open payload
#                  0cacbfff6ea53b1f26a7a3c2e79c2f85c5973ecbcd15e094611b3944a2d3476d  error stderr
#   consumers:     scripts/close-objective.sh AND ttg_verify_merge_evidence — the gate is
#                  reachable without the closer, so both are pinned below.
#   note:          PR 88's real headRefName is FEAT-030's branch, not this objective's.
#                  That is not incidental — it is the captured instance of the hazard the
#                  binding check exists for: a genuinely merged PR of a DIFFERENT
#                  objective. It is used as such below rather than being edited away.
#   not-captured:  the unauthenticated, unparseable-payload, malformed-ref, foreign-url,
#                  missing-url and leading-underscore-branch cases. `gh auth status` failing,
#                  a truncated body, a branch name no git ref could carry, a host answering
#                  about a repository it was not asked about, one omitting a field it was
#                  asked for, and a merged PR on `_wip/FEAT-042-thing` (a branch this repo
#                  never had) cannot be captured from a healthy authenticated host, so those
#                  six are SYNTHETIC and named as such rather than passed off as captured.
#                  A SEVENTH is added by PATCH-007: the payload the hostile-timeout wrapper
#                  prints. An attacker-authored process substituted for `timeout` has no real
#                  producer to capture from, so it is authored here and labelled at its site.
#                  The foreign url names `attacker/other-repo`, an invented repository, so no
#                  third-party subject matter enters the fixture set through the redirection
#                  cases; `_wip/FEAT-042-thing` is the false refusal PR #240 review finding
#                  #13 reported, held as data so the widened predicate has a subject.
#
# No tests/fixtures/ subdirectory is added: TASK-009's file scope is exactly this
# file and the library, and the manifest directs that the shape be declared in
# the test. The bytes above are byte-verbatim; the sha256 lines make that
# checkable against a re-capture.
TEST_NAME="test-merge-provider"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/merge-provider.sh"

# --- Case 1 (FIRST, deliberately): the seam exists and exposes its contract, so
# the pre-change red reads as "this seam did not exist". ---
if [ ! -f "$LIB" ]; then
  _fail "the merge-observation seam exists at scripts/lib/merge-provider.sh" \
    "no file at $LIB — the seam does not exist, so nothing below can be checked"
  report_results
  exit 1
fi

setup_temp_dir
setup_nazgul_dir
setup_git_repo
create_config
export NAZGUL_DIR="$TEST_DIR/nazgul"
EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
NZ_DIGEST_PROBE=$(digest_string probe || true)
assert_eq "the seam suite: the shared digest helper returns a 64-hex digest, so the config byte-identity check is not vacuous" \
  "${#NZ_DIGEST_PROBE}" "64"
record_file_digest CONFIG_BEFORE "$TEST_DIR/nazgul/config.json" "the seam suite: config.json before any case runs"

# shellcheck source=../scripts/lib/merge-provider.sh
source "$LIB"

for fn in merge_provider_detect merge_provider_pr_state merge_provider_health; do
  if declare -F "$fn" >/dev/null 2>&1; then
    _pass "the seam exposes $fn"
  else
    _fail "the seam exposes $fn" "not defined after sourcing $LIB"
  fi
done

# --- The result vocabulary is EXTRACTED from the library, not hand-listed, so a
# named result no case drives shows up as an unchecked scan entry. ---
mapfile -t VOCAB < <(grep -oE '^#   [a-z_]+ \([0-9]\)' "$LIB" | sed -E 's/^#   ([a-z_]+) \(([0-9])\)$/\1 \2/' | sort -u)
MP_SCANNED=${#VOCAB[@]}
MP_CHECKED=0
MP_SKIPPED=0
MP_SKIP_UNDRIVABLE=0
MP_FINDINGS=0

# --- gh shim: replays the captured bytes above (env switches select the case).
# Every invocation is recorded, so the CALL is asserted and not just its parse. ---
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-mp-fakebin-XXXXXX")
GH_LOG="$FAKEBIN/gh-argv.log"
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NAZGUL_TEST_GH_LOG:-/dev/null}"
sub="${1:-}"; shift || true
case "$sub" in
  auth)
    [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0
    printf 'You are not logged into any GitHub hosts. To log in, run: gh auth login\n' >&2
    exit 1 ;;
  pr)
    action="${1:-}"; shift || true
    [ "$action" = "view" ] || exit 1
    pinned=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --repo) pinned="${2:-}"; shift 2 ;; *) shift ;; esac
    done
    merged='{"baseRefName":"main","headRefName":"feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'
    foreign='{"baseRefName":"prototype","headRefName":"feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2019-10-04T16:01:04Z","state":"MERGED","url":"https://github.com/attacker/other-repo/pull/88"}'
    case "${NAZGUL_TEST_GH_PR_CASE:-merged}" in
      merged) printf '%s\n' "$merged"; exit 0 ;;
      open)   printf '%s\n' '{"baseRefName":"main","headRefName":"docs/doc-gate-design","mergeCommit":null,"mergedAt":null,"state":"OPEN","url":"https://github.com/OrodruinLabs/nazgul/pull/87"}'; exit 0 ;;
      badref) printf '%s\n' '{"baseRefName":"main","headRefName":"a branch; rm -rf /","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'; exit 0 ;;
      # Stands in for a redirection vector the seam does not enumerate: this shim answers
      # about the pinned repo when one is pinned and about the attacker's otherwise, which
      # is how real gh treats --repo against GH_REPO/GH_HOST/gh-resolved.
      redirected) if [ -n "$pinned" ]; then printf '%s\n' "$merged"; else printf '%s\n' "$foreign"; fi; exit 0 ;;
      foreignurl) printf '%s\n' "$foreign"; exit 0 ;;
      nourl)  printf '%s\n' '{"baseRefName":"main","headRefName":"feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED"}'; exit 0 ;;
      # SYNTHETIC: a leading underscore is a branch name git accepts and the old predicate did not.
      wipref) printf '%s\n' '{"baseRefName":"main","headRefName":"_wip/FEAT-042-thing","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'; exit 0 ;;
      error)  printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 999999. (repository.pullRequest)' >&2; exit 1 ;;
      # A host that never answers: the bound, not the host, is what ends this call.
      stall)  sleep 30; exit 0 ;;
      leaky)  printf 'HTTP 401: Bad credentials (token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)\n' >&2; exit 1 ;;
      garbage) printf '%s\n' 'not json at all'; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 1
EOF
chmod +x "$FAKEBIN/gh"
export NAZGUL_TEST_GH_LOG="$GH_LOG"
ORIG_PATH="$PATH"
export PATH="$FAKEBIN:$ORIG_PATH"

# Every tool the library needs EXCEPT gh, by symlink, so the "not installed"
# branch does not depend on where this machine keeps its binaries.
NOGH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-mp-nogh-XXXXXX")
for _tool in git jq sed awk tr cut cat head date mkdir flock uname; do
  _bin=$(PATH="$ORIG_PATH" command -v "$_tool" 2>/dev/null) || continue
  ln -sf "$_bin" "$NOGH_DIR/$_tool"
done

git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"

# _drive <pr> -> merge_provider_pr_state into MP_OUT / MP_ERR / MP_RC. One driver
# for every scenario, so a property proven on one path gates the others.
_drive() {
  MP_OUT=$(merge_provider_pr_state "$TEST_DIR" "$1" 2>"$FAKEBIN/err"); MP_RC=$?
  MP_ERR=$(cat "$FAKEBIN/err")
}

_field() { printf '%s' "$MP_OUT" | jq -r "$1" 2>/dev/null; }

# _observe <token> <expected_exit> — records that a documented result was driven
# and asserts the exit code the library's own doc block promises for it.
_observe() {
  local token="$1" want="$2"
  MP_CHECKED=$((MP_CHECKED + 1))
  if [ "$(_field '.result')" = "$token" ]; then
    _pass "result token '$token' is returned by its scenario"
  else
    _fail "result token '$token' is returned by its scenario" "got '$(_field '.result')'"
  fi
  if [ "$MP_RC" = "$want" ]; then
    _pass "result '$token' exits $want, as its own documented contract says"
  else
    _fail "result '$token' exits $want, as its own documented contract says" "got $MP_RC"
  fi
}

_want_exit() { local t="$1" v; for v in ${VOCAB[@]+"${VOCAB[@]}"}; do case "$v" in "$t "*) printf '%s' "${v##* }"; return 0 ;; esac; done; printf '%s' "?"; }

# --- ok / MERGED: the captured merged payload, normalised. ---
: > "$GH_LOG"
NAZGUL_TEST_GH_PR_CASE=merged _drive 88
_observe ok "$(_want_exit ok)"
assert_eq "merged PR: state is the host's own answer" "$(_field '.state')" "MERGED"
assert_eq "merged PR: merged is true" "$(_field '.merged')" "true"
assert_eq "merged PR: merged_at is normalised from mergedAt" "$(_field '.merged_at')" "2026-08-14T23:16:50Z"
assert_eq "merged PR: merge_commit is normalised from mergeCommit.oid" \
  "$(_field '.merge_commit')" "d6f7582f7d9ee8f74706ea02202d15dd5bc83146"
assert_eq "merged PR: the provider is named in the result" "$(_field '.provider')" "github"
assert_contains "the seam asks the host the merge-state question AND which branches, by PR" \
  "$(cat "$GH_LOG")" "pr view 88 --repo github.com/orodruinlabs/nazgul --json state,mergedAt,mergeCommit,headRefName,baseRefName,url"
assert_eq "and the record names the repository the answer is ABOUT, not just the host" \
  "$(_field '.repo')" "orodruinlabs/nazgul"
assert_eq "merged PR: the head branch is carried, so a caller can bind the PR to an objective" \
  "$(_field '.head_ref')" "feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr"
assert_eq "merged PR: the base branch is carried too" "$(_field '.base_ref')" "main"

# TWO consumers, and the gate is the one that blocks — it is reachable through
# task-transition.sh without the closer, so a head_ref only the closer reads defends one side.
MP_GATE_SRC=$(cat "$REPO_ROOT/scripts/lib/task-transition-guard.sh")
assert_contains "the merge-evidence gate consumes head_ref, not the closer alone" \
  "$MP_GATE_SRC" "jq -r '.head_ref // empty'"
assert_contains "the gate binds the head branch through the shared predicate" \
  "$MP_GATE_SRC" "ttg_pr_bound"

# A host-authored branch name no git ref could carry is DROPPED, so a caller needing the
# binding fails closed rather than matching attacker-chosen text. (SYNTHETIC.)
NAZGUL_TEST_GH_PR_CASE=badref _drive 88
assert_eq "a head branch that is not ref-shaped is dropped, not carried" "$(_field '.head_ref')" "null"
assert_eq "dropping an unusable ref does not turn the answer into a failure" "$(_field '.result')" "ok"

# --- ok / OPEN: "looked and found NOT merged" — merged is false, not null. ---
NAZGUL_TEST_GH_PR_CASE=open _drive 87
assert_eq "open PR: the query succeeded, so the result is still 'ok'" "$(_field '.result')" "ok"
assert_eq "open PR: state is OPEN" "$(_field '.state')" "OPEN"
assert_eq "open PR: merged is FALSE — the host was asked and said no" "$(_field '.merged')" "false"
assert_eq "open PR: merged_at is null" "$(_field '.merged_at')" "null"
assert_eq "open PR: merge_commit is null" "$(_field '.merge_commit')" "null"
assert_eq "open PR: the head branch is still carried — it is not merge state" \
  "$(_field '.head_ref')" "docs/doc-gate-design"

# --- api_failure: the single most important property. A host that did not
# answer must NEVER read as an unmerged PR. ---
NAZGUL_TEST_GH_PR_CASE=error _drive 999999
_observe api_failure "$(_want_exit api_failure)"
assert_eq "api failure: merged is NULL, never false — 'could not look' is not 'not merged'" \
  "$(_field '.merged')" "null"
assert_eq "api failure: state is null, never a fabricated OPEN" "$(_field '.state')" "null"
assert_contains "api failure: the diagnostic quotes the host's real error text" \
  "$(_field '.diagnostic')" "Could not resolve to a PullRequest"
assert_contains "api failure: the degradation is loud on stderr, not only on the bus" \
  "$MP_ERR" "api_failure"
assert_contains "api failure: stderr says explicitly that this is not 'not merged'" \
  "$MP_ERR" "NOT 'not merged'"
assert_file_contains "api failure: a telemetry record is written" \
  "$EVENTS" '"event":"merge_provider_api_failure"'

# --- api_failure, second shape: a zero exit whose payload does not parse. A
# successful invocation is not a successful ANSWER. ---
NAZGUL_TEST_GH_PR_CASE=garbage _drive 88
assert_eq "unparseable payload on exit 0 is api_failure, not ok" "$(_field '.result')" "api_failure"
assert_eq "unparseable payload: merged is null" "$(_field '.merged')" "null"

# lean-comments: allow-run — names the host class this defends and why the suite could not see it.
# THE STOCK-macOS PATH (PATCH-007 item 1). GNU `timeout` is absent by default there, so
# bounded-net names its missing bound on stderr during an OTHERWISE SUCCESSFUL call. A `2>&1`
# capture folded that line into the payload, `.state` parsed empty, and a genuinely MERGED PR
# came back `api_failure` at a gate with NO kill switch — /nazgul:complete closing zero tasks on
# the default host. This suite never set NAZGUL_TIMEOUT_CMD, so the default host was the untested one.
export NAZGUL_TIMEOUT_CMD=""
NAZGUL_TEST_GH_PR_CASE=merged _drive 88
assert_eq "no timeout binary: a MERGED PR is still ok — a degradation line is not the payload" \
  "$(_field '.result')" "ok"
assert_eq "no timeout binary: merged is true, so the closure the operator earned is admitted" \
  "$(_field '.merged')" "true"
assert_eq "no timeout binary: the merge commit survives the capture intact" \
  "$(_field '.merge_commit')" "d6f7582f7d9ee8f74706ea02202d15dd5bc83146"
assert_not_contains "the result never carries bounded-net's own line as if the host had said it" \
  "$MP_OUT" "unbounded_no_timeout_binary"
assert_contains "and the missing bound is still LOUD on the caller's real stderr, not silenced" \
  "$MP_ERR" "unbounded_no_timeout_binary"
unset NAZGUL_TIMEOUT_CMD

# lean-comments: allow-run — why neither defence this seam already has covers this one.
# THE SUBSTITUTED-EVIDENCE PATH (PATCH-007 item 2). NAZGUL_TIMEOUT_CMD is EXECUTED as the wrapper
# around `gh pr view`, so an ambient value could hand this seam an attacker-authored MERGED
# payload while the real host refused to answer. The `--repo` pinning and the url
# self-certification are both DOWNSTREAM of that process and never see it. SYNTHETIC: an
# attacker-authored wrapper has no real producer to be captured from.
cat > "$FAKEBIN/hostile-timeout" << 'HOSTILE'
#!/usr/bin/env bash
printf '%s\n' '{"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},"headRefName":"attacker/branch","baseRefName":"main","url":"https://github.com/OrodruinLabs/nazgul/pull/88"}'
exit 0
HOSTILE
chmod +x "$FAKEBIN/hostile-timeout"
export NAZGUL_TIMEOUT_CMD="$FAKEBIN/hostile-timeout"
NAZGUL_TEST_GH_PR_CASE=error _drive 999999
assert_eq "a substituted timeout process cannot turn a refusing host into 'ok'" \
  "$(_field '.result')" "api_failure"
assert_eq "and it yields no merge state at all" "$(_field '.merged')" "null"
assert_not_contains "no attacker-authored merge commit reaches the result" "$MP_OUT" "deadbeef"
assert_not_contains "nor an attacker-authored head branch, which is what binds a PR to an objective" \
  "$MP_OUT" "attacker/branch"
assert_contains "the refused override is named on stderr rather than ignored quietly" \
  "$MP_ERR" "refused_timeout_cmd_override"
unset NAZGUL_TIMEOUT_CMD

# lean-comments: allow-run — a named degradation whose name never reaches the record is the
# doctrine this file's own header states, turned against it.
# THE FIRED-BOUND RECORD (PATCH-008 item 8). Splitting the COMMAND's stderr into $errfile sent
# bounded-net's own diagnostics to fd 9, so on 124/137 neither $err nor $out carried the
# `bound_exceeded` line: the diagnostic ended at "gh pr view 88 failed (exit 124): " and the
# merge_provider_api_failure event carried an EMPTY reason. The operator's stderr had it; the
# record a later refusal is read back from did not.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  : > "$EVENTS"
  MP_T0=$(date +%s)
  NAZGUL_TEST_GH_PR_CASE=stall NAZGUL_NET_TIMEOUT=1 _drive 88
  MP_BOUND_ELAPSED=$(( $(date +%s) - MP_T0 ))
  assert_eq "a fired bound is api_failure — a timeout is never an answer about a PR" \
    "$(_field '.result')" "api_failure"
  if [ "$MP_BOUND_ELAPSED" -le 15 ]; then
    _pass "the bound genuinely fired rather than the stub returning (${MP_BOUND_ELAPSED}s against a 30s stall)"
  else
    _fail "the bound genuinely fired" "took ${MP_BOUND_ELAPSED}s — nothing below is about a fired bound"
  fi
  assert_contains "the fired bound NAMES itself in the diagnostic the caller records and prints" \
    "$(_field '.diagnostic')" "bound_exceeded"
  assert_contains "and on the bus, where an empty reason is indistinguishable from a silent host" \
    "$(jq -r 'select(.event == "merge_provider_api_failure") | .reason' "$EVENTS" | tail -1)" "bound_exceeded"
  assert_contains "while still reaching the operator's real stderr, which is where it always went" \
    "$MP_ERR" "bound_exceeded"
else
  _skip "the fired-bound record (neither timeout nor gtimeout is on this host, so no bound can fire)"
fi

# --- provider_unavailable: an arm exists but cannot run. Distinct from both
# api_failure (it ran and failed) and unsupported_host (there is no arm). ---
NAZGUL_TEST_GH_AUTH=fail NAZGUL_TEST_GH_PR_CASE=merged _drive 88
_observe provider_unavailable "$(_want_exit provider_unavailable)"
assert_eq "unauthenticated host: merged is null, never false" "$(_field '.merged')" "null"
assert_contains "unauthenticated host: the diagnostic names auth as the cause" \
  "$(_field '.diagnostic')" "not authenticated"
assert_file_contains "unauthenticated host: a telemetry record is written" \
  "$EVENTS" '"event":"merge_provider_unavailable"'

PATH="$NOGH_DIR"; export PATH
NAZGUL_TEST_GH_PR_CASE=merged _drive 88
NOGH_HEALTH=$(merge_provider_health "$TEST_DIR" 2>/dev/null)
PATH="$FAKEBIN:$ORIG_PATH"; export PATH
assert_eq "gh absent from PATH is provider_unavailable, not api_failure" \
  "$(_field '.result')" "provider_unavailable"
assert_contains "gh absent: the diagnostic names the missing tool" "$(_field '.diagnostic')" "not installed"
assert_eq "gh absent: health reports provider_unavailable" "$NOGH_HEALTH" "provider_unavailable"

# --- unsupported_host: a remote exists, no arm serves it. The filed p1 second
# arm (Azure DevOps) is exactly this case today. ---
git -C "$TEST_DIR" remote set-url origin "https://dev.azure.com/org/proj/_git/repo"
_drive 88
_observe unsupported_host "$(_want_exit unsupported_host)"
assert_eq "unsupported host: merged is null" "$(_field '.merged')" "null"
assert_eq "unsupported host: the host is still reported, so the operator knows what was seen" \
  "$(_field '.host')" "dev.azure.com"
assert_contains "unsupported host: stderr says the seam will not fall back to git ancestry" \
  "$(merge_provider_detect "$TEST_DIR" 2>&1 >/dev/null)" "never falls back to git ancestry"
assert_file_contains "unsupported host: a telemetry record is written" \
  "$EVENTS" '"event":"merge_provider_unsupported_host"'
DETECT_OUT=$(merge_provider_detect "$TEST_DIR" 2>/dev/null); DETECT_RC=$?
assert_eq "detect on an unsupported host names the state on stdout" "$DETECT_OUT" "unsupported_host"
assert_exit_code "detect on an unsupported host exits 2, never 0" "$DETECT_RC" 2

# --- The dispatcher refuses an UNKNOWN provider explicitly rather than
# defaulting to the one arm that happens to exist. ---
UNKNOWN_OUT=$(NAZGUL_MERGE_PROVIDER=gitlab merge_provider_pr_state "$TEST_DIR" 88 2>/dev/null)
UNKNOWN_RC=$?
assert_eq "an unknown provider is refused by name, never silently routed to github" \
  "$(printf '%s' "$UNKNOWN_OUT" | jq -r '.result')" "unsupported_host"
assert_exit_code "an unknown provider exits 2, never 0" "$UNKNOWN_RC" 2
assert_eq "an unknown provider yields no merge state at all" \
  "$(printf '%s' "$UNKNOWN_OUT" | jq -r '.merged')" "null"

# --- no_remote: nothing to derive a host from. Distinct from unsupported_host. ---
git -C "$TEST_DIR" remote remove origin
_drive 88
_observe no_remote "$(_want_exit no_remote)"
assert_eq "no remote: merged is null" "$(_field '.merged')" "null"
assert_file_contains "no remote: a telemetry record is written" \
  "$EVENTS" '"event":"merge_provider_no_remote"'
NOREMOTE_OUT=$(merge_provider_detect "$TEST_DIR" 2>/dev/null); NOREMOTE_RC=$?
assert_eq "detect with no remote names no_remote" "$NOREMOTE_OUT" "no_remote"
assert_exit_code "detect with no remote exits 3, distinct from unsupported_host's 2" "$NOREMOTE_RC" 3
git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"

# --- invalid_pr: an id that could be read as a flag never reaches the host. ---
: > "$GH_LOG"
_drive "-x"
_observe invalid_pr "$(_want_exit invalid_pr)"
assert_eq "an unusable PR id is refused before the host is contacted" "$(cat "$GH_LOG")" ""
_drive "https://github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "a PR URL naming THIS repo is normalised to its number rather than refused" \
  "$(_field '.result')" "ok"
assert_eq "a PR URL records the normalised number" "$(_field '.pr')" "88"

# lean-comments: allow-run — why an internally consistent record can still be the wrong one.
# A `.../pull/N` URL from ANY host used to resolve to N locally: host and repo were
# discarded and the number asked of whatever `origin` points at, while the recorded
# evidence — local host, bare number — stayed internally consistent and gave an auditor
# no signal that a different repository had been named.
: > "$GH_LOG"
_drive "https://evil.example/o/r/pull/9"
assert_eq "a PR URL from another HOST is refused, not silently resolved locally" \
  "$(_field '.result')" "invalid_pr"
assert_eq "a PR URL from another host never reaches the host CLI" "$(cat "$GH_LOG")" ""
assert_contains "the refusal names both the URL's repo and this project's own" \
  "$(_field '.diagnostic')" "evil.example/o/r"
assert_contains "the refusal names what the local remote actually is" \
  "$(_field '.diagnostic')" "github.com/orodruinlabs/nazgul"
_drive "https://github.com/someone-else/other-repo/pull/9"
assert_eq "a PR URL on the right host but ANOTHER repo is refused too" \
  "$(_field '.result')" "invalid_pr"
_drive "o/r/pull/9"
assert_eq "a schemeless pseudo-URL carries no checkable host, so it is refused" \
  "$(_field '.result')" "invalid_pr"

# lean-comments: allow-run — the false refusal this block measures, and why it was not a mismatch.
# `_mp_provider_for_host` admits github.com AND www.github.com as one provider, so an alias URL
# passes provider selection and used to be refused HERE by a raw string comparison — recorded as
# `invalid_pr` with a diagnostic asserting the PR "would have been asked of the wrong repository",
# a specific and false statement about a URL naming this very repository. A false refusal on the
# merge path refuses a LEGITIMATE closure, and the operator's only remaining route is the forgery
# route ADR-023 removed. Both sides now pass through `_mp_api_host`, as _mp_github_pr_state does.
assert_eq "the gh on PATH is this suite's shim, so every case below drives captured bytes" \
  "$(command -v gh)" "$FAKEBIN/gh"

: > "$GH_LOG"
_drive "https://www.github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "a www.github.com PR URL names THIS repo's host and is ADMITTED, not refused" \
  "$(_field '.result')" "ok"
assert_exit_code "and the admitted alias exits 0, not invalid_pr's 6" "$MP_RC" 0
assert_eq "the admitted alias carries no diagnostic — there was no difference to report" \
  "$(_field '.diagnostic')" "null"
assert_not_contains "and stderr never claims the wrong repository would have been asked" \
  "$MP_ERR" "would have been asked of the wrong repository"
assert_contains "the alias reaches the provider arm, pinned to the API's spelling of the host" \
  "$(cat "$GH_LOG")" "pr view 88 --repo github.com/orodruinlabs/nazgul"

# A de-authenticated environment would make the REAL gh answer provider_unavailable, so an `ok`
# here proves the shim above answered rather than a host this suite must never contact.
mkdir -p "$FAKEBIN/empty-gh-config"
GH_CONFIG_DIR="$FAKEBIN/empty-gh-config" _drive "https://www.github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "de-authenticated, the answer is still the shim's — no real gh is being reached" \
  "$(_field '.result')" "ok"

# The reverse pairing is the same fact: which side carries the alias must not decide the outcome.
: > "$GH_LOG"
git -C "$TEST_DIR" remote set-url origin "https://www.github.com/OrodruinLabs/nazgul.git"
_drive "https://github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "the reverse pairing — alias REMOTE, canonical URL — is admitted too" \
  "$(_field '.result')" "ok"
assert_contains "and it is pinned to the same API host, not to the alias" \
  "$(cat "$GH_LOG")" "pr view 88 --repo github.com/orodruinlabs/nazgul"
git -C "$TEST_DIR" remote set-url origin "https://github.com/OrodruinLabs/nazgul.git"

# Opposite-outcome fixtures: normalising is not relaxing. Exactly one alias maps; a host that
# merely CONTAINS it is a different host, and the repository half is untouched.
: > "$GH_LOG"
_drive "https://www.github.com.evil.example/OrodruinLabs/nazgul/pull/88"
assert_eq "a host that only contains the alias is still a different host, and is refused" \
  "$(_field '.result')" "invalid_pr"
assert_exit_code "and that refusal keeps invalid_pr's exit code" "$MP_RC" 6
assert_contains "its diagnostic still names the host the URL actually gave" \
  "$(_field '.diagnostic')" "www.github.com.evil.example/orodruinlabs/nazgul"
assert_contains "and still names this project's own remote" \
  "$(_field '.diagnostic')" "github.com/orodruinlabs/nazgul"
assert_eq "a genuinely different host still never reaches the host CLI" "$(cat "$GH_LOG")" ""

_drive "https://www.github.com/someone-else/other-repo/pull/9"
assert_eq "the alias host with ANOTHER repo is still refused — the repo half is untouched" \
  "$(_field '.result')" "invalid_pr"
assert_contains "and its diagnostic names the repository that disagreed" \
  "$(_field '.diagnostic')" "someone-else/other-repo"
assert_eq "the alias grants nothing to a foreign repo: the host is never contacted" \
  "$(cat "$GH_LOG")" ""

# An unresolvable remote keeps its own outcome on both paths: invalid_pr when a URL was given
# (nothing to compare it against), unbindable_repo for a bare number.
git -C "$TEST_DIR" remote set-url origin "https://github.com/"
_drive "https://www.github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "an unresolvable remote still refuses a URL, alias or not" "$(_field '.result')" "invalid_pr"
assert_contains "and says the remote named none, rather than inventing one" \
  "$(_field '.diagnostic')" "github.com/<none>"
_drive 88
assert_eq "and a bare number against it is still unbindable_repo, not invalid_pr" \
  "$(_field '.result')" "unbindable_repo"
git -C "$TEST_DIR" remote set-url origin "https://github.com/OrodruinLabs/nazgul.git"

# no_remote is decided before this comparison and is unchanged by it.
git -C "$TEST_DIR" remote remove origin
_drive "https://www.github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "with no remote at all the answer is still no_remote, never the URL refusal" \
  "$(_field '.result')" "no_remote"
assert_exit_code "and no_remote keeps its own exit code" "$MP_RC" 3
git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"

# A credential can only realistically arrive through --pr, and that was the one path
# that echoed its input raw into stderr and the event bus.
: > "$EVENTS"
_drive "https://user:ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB@github.com/OrodruinLabs/nazgul/pull/88"
assert_eq "a credential-bearing PR URL still resolves to its number" "$(_field '.pr')" "88"
assert_not_contains "a credential in --pr never reaches stderr" "$MP_ERR" "ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
assert_not_contains "a credential in --pr never reaches the result JSON" "$MP_OUT" "ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
assert_not_contains "a credential in --pr never reaches the event bus" \
  "$(cat "$EVENTS" 2>/dev/null)" "ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
_drive "https://user:ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC@github.com/o/r/notapr"
assert_eq "an unnormalisable credential-bearing --pr is invalid_pr" "$(_field '.result')" "invalid_pr"
assert_not_contains "the unnormalisable value is REDACTED where it is echoed back" \
  "$MP_OUT" "ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
assert_not_contains "the unnormalisable value is redacted on stderr too" \
  "$MP_ERR" "ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
assert_not_contains "the unnormalisable value is redacted on the bus too" \
  "$(cat "$EVENTS" 2>/dev/null)" "ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

# lean-comments: allow-run — why the cases above did not already cover this one.
# Every credential above is `gh`-token-SHAPED, so the token rules caught them and the
# userinfo went unexamined. A basic-auth password, a GitLab `glpat-`, or an Azure DevOps
# PAT matches no token rule at all, and the invalid_pr path echoes its input to stderr,
# onto the bus, and back as `.pr` — three copies of a live secret.
: > "$EVENTS"
_drive "https://svc-account:hunter2-not-token-shaped@github.com/o/r/notapr"
assert_eq "a non-token-shaped credential in --pr is still invalid_pr" "$(_field '.result')" "invalid_pr"
assert_not_contains "URL userinfo is stripped from the echoed value" \
  "$MP_OUT" "hunter2-not-token-shaped"
assert_not_contains "URL userinfo is stripped on stderr" "$MP_ERR" "hunter2-not-token-shaped"
assert_not_contains "URL userinfo is stripped on the event bus" \
  "$(cat "$EVENTS" 2>/dev/null)" "hunter2-not-token-shaped"
assert_contains "the redaction is visible where the userinfo was, not a silent truncation" \
  "$(_field '.pr')" "https://***@github.com/o/r/notapr"

# lean-comments: allow-run — the finding this block exists for, and why a shape check is not it.
# THE REDIRECTION CLASS (board 6, SEC-1). `gh pr view` resolves its target from GH_REPO, from
# GH_HOST and from a remote's `gh-resolved` BEFORE the checkout's own remote, so a bare PR
# number returned a genuine `ok`/`merged: true` about whatever repository the environment
# named — in a record byte-identical to the honest one, which is the last gate before DONE
# answering truthfully about somebody else's repository. Every case below sets the vector for
# real and drives the real function; none of them asserts the shape of an argument.
: > "$GH_LOG"
: > "$EVENTS"
GH_REPO=someone-else/their-repo _drive 88
_observe repo_mismatch "$(_want_exit repo_mismatch)"
assert_eq "GH_REPO redirection: no merge state at all comes back" "$(_field '.merged')" "null"
assert_eq "GH_REPO redirection: the host is never contacted" "$(cat "$GH_LOG")" ""
assert_contains "the refusal names the repository the environment asked for" \
  "$(_field '.diagnostic')" "someone-else/their-repo"
assert_contains "and the one this checkout actually names" \
  "$(_field '.diagnostic')" "github.com/orodruinlabs/nazgul"
assert_contains "the refusal is loud on stderr, not only on the bus" "$MP_ERR" "repo_mismatch"
assert_file_contains "and a telemetry record names the disagreement" \
  "$EVENTS" '"event":"merge_provider_repo_mismatch"'

: > "$GH_LOG"
GH_HOST=ghe.example.com _drive 88
assert_eq "GH_HOST is its own vector, not a variant of GH_REPO" "$(_field '.result')" "repo_mismatch"
assert_contains "and its refusal names the host, which is what disagreed" \
  "$(_field '.diagnostic')" "ghe.example.com"
assert_eq "GH_HOST redirection: the host is never contacted either" "$(cat "$GH_LOG")" ""

: > "$GH_LOG"
git -C "$TEST_DIR" config --local remote.origin.gh-resolved someone-else/their-repo
_drive 88
assert_eq "a gh-resolved git config is the third vector — persistent, and no env var at all" \
  "$(_field '.result')" "repo_mismatch"
assert_contains "and its refusal names the config key, so the operator knows what to unset" \
  "$(_field '.diagnostic')" "remote.origin.gh-resolved"
assert_eq "gh-resolved redirection: the host is never contacted either" "$(cat "$GH_LOG")" ""
git -C "$TEST_DIR" config --local remote.origin.gh-resolved base
_drive 88
assert_eq "gh-resolved 'base' names this remote's OWN repo and is not a disagreement" \
  "$(_field '.result')" "ok"
git -C "$TEST_DIR" config --local --unset remote.origin.gh-resolved

# The refusal is a DISAGREEMENT check, not a ban: an environment naming this very repository
# is not redirection, and refusing it would make the seam unusable inside `gh` workflows.
GH_REPO=OrodruinLabs/nazgul _drive 88
assert_eq "GH_REPO naming THIS repository is not a mismatch" "$(_field '.result')" "ok"
GH_REPO=github.com/OrodruinLabs/nazgul _drive 88
assert_eq "nor is gh's HOST/OWNER/REPO spelling of the same repository" "$(_field '.result')" "ok"

# A redirection vector is operator-writable text like --pr, so it can carry a credential in its
# userinfo — and the refusal echoes it to stderr, onto the bus, and back as `.diagnostic`.
: > "$EVENTS"
GH_REPO="https://svc-account:hunter2-not-token-shaped@github.com/notarepo" _drive 88
assert_eq "an unparseable GH_REPO is a mismatch, not a silently ignored value" \
  "$(_field '.result')" "repo_mismatch"
assert_not_contains "and its userinfo never reaches the result JSON" \
  "$MP_OUT" "hunter2-not-token-shaped"
assert_not_contains "nor stderr" "$MP_ERR" "hunter2-not-token-shaped"
assert_not_contains "nor the event bus" "$(cat "$EVENTS" 2>/dev/null)" "hunter2-not-token-shaped"
assert_contains "the redaction is visible where the userinfo was" "$(_field '.diagnostic')" "***@github.com"

# lean-comments: allow-run — the residual this pair measures, rather than asserting the class.
# The named refusal above covers the three vectors this seam enumerates. The `--repo` pin is
# the layer that covers the ones it does not: it outranks GH_REPO, GH_HOST and gh-resolved
# against real gh (measured), so the shim answers about the pinned repository when one is
# pinned. The second case is the backstop for a host that answers about the wrong repository
# anyway — checked from the answer's own url, not from having asked politely.
: > "$GH_LOG"
NAZGUL_TEST_GH_PR_CASE=redirected _drive 88
assert_eq "an unenumerated redirection vector is still defeated by the --repo pin alone" \
  "$(_field '.result')" "ok"
assert_eq "and the answer is about this repository, not the redirected one" \
  "$(_field '.merged_at')" "2026-08-14T23:16:50Z"
assert_contains "the pin is what carried it: the repository is named in the call" \
  "$(cat "$GH_LOG")" "--repo github.com/orodruinlabs/nazgul"

NAZGUL_TEST_GH_PR_CASE=foreignurl _drive 88
assert_eq "a host answering about a repo it was not asked about is refused by name" \
  "$(_field '.result')" "repo_mismatch"
assert_eq "and that refusal yields no merge state, however genuine the answer was" \
  "$(_field '.merged')" "null"
assert_contains "the refusal names the repository that actually answered" \
  "$(_field '.diagnostic')" "attacker/other-repo"

# A response with no url names no repository, so it cannot be shown to be about ours. That is
# "asked and did not usefully answer", which already has a name — it is not a new one.
NAZGUL_TEST_GH_PR_CASE=nourl _drive 88
assert_eq "an answer carrying no url is api_failure, never a trusted ok" \
  "$(_field '.result')" "api_failure"
assert_eq "and it yields no merge state" "$(_field '.merged')" "null"
assert_contains "the diagnostic says which fact was missing" "$(_field '.diagnostic')" "no PR url"

# --- unbindable_repo: a remote naming no owner/repo cannot pin anything, so the query could
# only have been aimed by ambient environment. Refused rather than asked. ---
: > "$GH_LOG"
git -C "$TEST_DIR" remote set-url origin "https://github.com/"
_drive 88
_observe unbindable_repo "$(_want_exit unbindable_repo)"
assert_eq "unbindable remote: merged is null" "$(_field '.merged')" "null"
assert_eq "unbindable remote: the host is never contacted" "$(cat "$GH_LOG")" ""
assert_file_contains "unbindable remote: a telemetry record is written" \
  "$EVENTS" '"event":"merge_provider_unbindable_repo"'
git -C "$TEST_DIR" remote set-url origin "https://github.com/OrodruinLabs/nazgul.git"

# --- Every named result is DISTINCT. This is the property the whole seam
# exists for: six answers, six tokens, six exit codes, no collapsing. ---
DISTINCT=$(printf '%s\n' ${VOCAB[@]+"${VOCAB[@]}"} | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
DISTINCT_CODES=$(printf '%s\n' ${VOCAB[@]+"${VOCAB[@]}"} | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
assert_eq "the documented result vocabulary has no duplicate tokens" "$DISTINCT" "$MP_SCANNED"
assert_eq "every documented result has its own exit code" "$DISTINCT_CODES" "$MP_SCANNED"

# --- No credential ever reaches stdout or stderr. ---
NAZGUL_TEST_GH_PR_CASE=leaky _drive 88
assert_not_contains "a token-shaped string in host stderr never reaches the result JSON" \
  "$MP_OUT" "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
assert_not_contains "a token-shaped string in host stderr never reaches our stderr" \
  "$MP_ERR" "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
assert_contains "the redaction is visible, not a silent truncation" "$(_field '.diagnostic')" "***"
assert_not_contains "no token-shaped string is written to the event bus" \
  "$(cat "$EVENTS" 2>/dev/null)" "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
assert_file_unchanged "the seam never writes config.json at all — no credential surface to add one to" \
  "$TEST_DIR/nazgul/config.json" "$CONFIG_BEFORE"

# lean-comments: allow-run — why every existing caller was accidentally safe, and why an exit code cannot see this.
# THE ERREXIT-CALLER CLASS (PR #240 review, finding #3). `raw=$(_mp_detect_raw "$root"); rc=$?` is a
# FAILING SIMPLE COMMAND under the caller's own `set -e`, on exactly the two paths this seam exists to
# NAME: `_mp_detect_raw` returns 2 and 3 by design. The caller therefore died at the assignment —
# before `_mp_warn`, before `_mp_emit`, before the token reached stdout — which is the silence
# RULES.md §16 was written against, produced by the file written against it. Both live callers wrap
# the seam in `$( ) || true`, which puts its whole body in bash's errexit-IGNORED context and is why
# the defect was latent rather than visible; the caller below consumes the seam's stdout through a
# PROCESS SUBSTITUTION, which does not inherit that context, so the seam runs with errexit armed
# exactly as it would inside /nazgul:doctor (`set -euo pipefail`, and the seam's next consumer).
# An exit-code assertion cannot discharge this: the caller exited 3 before the fix and the seam
# returns 3 after it. What changed is that the name, the stderr line and the event now EXIST.
_errexit_drive() {
  ERRX_OUT=$(bash -c '
    set -euo pipefail
    source "$1"; shift
    while IFS= read -r line; do printf "TOKEN:%s\n" "$line"; done < <("$@")
    printf "SURVIVED\n"
  ' _ "$LIB" "$@" 2>"$FAKEBIN/errx"); ERRX_RC=$?
  ERRX_ERR=$(cat "$FAKEBIN/errx")
}

# _errexit_case <label> <stdout-substring> <stderr-name> <event> <fn> <args...>. The answer owed to
# stdout and the name owed to stderr differ in shape (a JSON object vs a token), so both are given.
_errexit_case() {
  local label="$1" want_out="$2" want_err="$3" event="$4"
  shift 4
  : > "$EVENTS"
  _errexit_drive "$@"
  assert_exit_code "errexit caller: $label — the caller survives to its next command" "$ERRX_RC" 0
  assert_contains "errexit caller: $label — and actually reaches it" "$ERRX_OUT" "SURVIVED"
  assert_contains "errexit caller: $label — having read the seam's answer through the substitution" \
    "$ERRX_OUT" "TOKEN:"
  assert_contains "errexit caller: $label — and that answer names the degradation" "$ERRX_OUT" "$want_out"
  assert_contains "errexit caller: $label — the _mp_warn line reached stderr too" "$ERRX_ERR" "$want_err"
  assert_file_contains "errexit caller: $label — and the telemetry record reached the bus" "$EVENTS" "\"event\":\"$event\""
}

git -C "$TEST_DIR" remote remove origin
_errexit_case "detect / no_remote" "TOKEN:no_remote" "no_remote:" "merge_provider_no_remote" merge_provider_detect "$TEST_DIR"
_errexit_case "health / no_remote" "TOKEN:no_remote" "no_remote:" "merge_provider_no_remote" merge_provider_health "$TEST_DIR"
_errexit_case "pr_state / no_remote" '"result":"no_remote"' "no_remote:" "merge_provider_no_remote" merge_provider_pr_state "$TEST_DIR" 88

git -C "$TEST_DIR" remote add origin "https://dev.azure.com/org/proj/_git/repo"
_errexit_case "detect / unsupported_host" "TOKEN:unsupported_host" "unsupported_host:" "merge_provider_unsupported_host" merge_provider_detect "$TEST_DIR"
_errexit_case "health / unsupported_host" "TOKEN:unsupported_host" "unsupported_host:" "merge_provider_unsupported_host" merge_provider_health "$TEST_DIR"
_errexit_case "pr_state / unsupported_host" '"result":"unsupported_host"' "unsupported_host:" "merge_provider_unsupported_host" merge_provider_pr_state "$TEST_DIR" 88

# The gh-invocation assignment inside _mp_github_pr_state is the SAME class, included deliberately:
# once the detect sites are immune an errexit caller REACHES it and dies before `api_failure` is said.
git -C "$TEST_DIR" remote set-url origin "https://github.com/OrodruinLabs/nazgul.git"
: > "$GH_LOG"
NAZGUL_TEST_GH_PR_CASE=error _errexit_case "pr_state / api_failure" '"result":"api_failure"' \
  "api_failure:" "merge_provider_api_failure" merge_provider_pr_state "$TEST_DIR" 999999
assert_contains "errexit caller: the sub-shell drove THIS suite's gh shim, never a real host" \
  "$(cat "$GH_LOG")" "pr view 999999 --repo github.com/orodruinlabs/nazgul"

# The same caller on the path that SUCCEEDS: the fix must not have turned a good answer into a
# degradation, so the shape that used to abort is driven once more with nothing to degrade about.
NAZGUL_TEST_GH_PR_CASE=merged _errexit_drive merge_provider_pr_state "$TEST_DIR" 88
assert_exit_code "errexit caller: the ok path still exits 0 for the caller" "$ERRX_RC" 0
assert_contains "errexit caller: the ok path still returns the host's answer" "$ERRX_OUT" '"result":"ok"'
assert_eq "errexit caller: an ok answer stays silent on stderr — only degradations are loud" "$ERRX_ERR" ""

# lean-comments: allow-run — where the line is drawn, why it is git's, and what it still refuses.
# THE FALSE-REFUSAL CLASS (PR #240 review, finding #13). `_mp_ref_ok` was a narrow ASCII allowlist
# that merely OVERLAPPED git's rules: it refused a leading `_`, any `+` and every non-ASCII byte —
# all names git itself accepts. Each refusal blanks `head_ref`, which `_ttg_merge_host_state` reads
# as `ok_no_head_ref` and the merge-evidence gate refuses as `unverifiable`; that gate has no kill
# switch (RULES.md §2), so a genuinely merged objective on such a branch had NO route to DONE, and
# the diagnostic blamed the host for an answer it got right. The line is now git's own refname rule,
# pinned in BOTH directions against `git check-ref-format --branch` below — accept-only would be a
# worse validator than the false refusal it replaces, so every row asserts the oracle's answer too.
_ref_oracle() { git -C "$TEST_DIR" check-ref-format --branch "$1" >/dev/null 2>&1; }
REF_ROWS=0
_ref_row() {
  local want="$1" ref="$2" oracle mine shown
  shown=$(printf '%q' "$ref")
  REF_ROWS=$((REF_ROWS + 1))
  if _ref_oracle "$ref"; then oracle="accept"; else oracle="reject"; fi
  if _mp_ref_ok "$ref"; then mine="accept"; else mine="reject"; fi
  assert_eq "oracle: git itself ${want}s $shown" "$oracle" "$want"
  assert_eq "_mp_ref_ok ${want}s $shown, exactly as git does" "$mine" "$want"
}

_ref_row accept "_hotfix/x"
_ref_row accept "feat/a+b"
_ref_row accept "feat/ünïcode"
_ref_row accept "main"
_ref_row accept "feat/a.b"
_ref_row accept "release/1.0.0"
_ref_row accept "+plus"
_ref_row accept "a_b"
_ref_row reject "feat/a..b"
_ref_row reject "feat/a b"
_ref_row reject "-dash"
_ref_row reject "x.lock"
_ref_row reject ".leading"
_ref_row reject "feat/x/"
_ref_row reject "/lead"
_ref_row reject "a//b"
_ref_row reject "trail."
_ref_row reject 'a@{b'
_ref_row reject "a~b"
_ref_row reject "a^b"
_ref_row reject "a:b"
_ref_row reject "a?b"
_ref_row reject "a*b"
_ref_row reject "a[b"
_ref_row reject 'a\b'
_ref_row reject "a.lock/b"
_ref_row reject "a/.b"
_ref_row reject "a/b.lock"
if [ "$REF_ROWS" -lt 9 ]; then
  _fail "the ref-shape table is actually populated" "only $REF_ROWS rows — a table nothing drives pins nothing"
fi

# What it still refuses, each with the reason it is refused FOR — asserted against the rule, not the
# oracle: `--branch` expands shorthands (it reads `@` as HEAD) and takes no view on a byte ceiling.
_ref_refuses() {
  if _mp_ref_ok "$2"; then
    _fail "_mp_ref_ok still refuses $1" "accepted $(printf '%q' "$2")"
  else
    _pass "_mp_ref_ok still refuses $1"
  fi
}
_ref_admits() {
  if _mp_ref_ok "$2"; then _pass "_mp_ref_ok admits $1"; else _fail "_mp_ref_ok admits $1" "rejected $(printf '%q' "$2")"; fi
}
_ref_refuses "the empty string — the host returned no name to bind a PR to" ""
_ref_refuses "a bare @, which is HEAD's shorthand and not a branch git would create" "@"
_ref_refuses "an embedded newline, which no one-line ## Merge Evidence record could carry" $'a\nb'
_ref_refuses "a DEL control character" $'a\177b'
_ref_refuses "256 bytes — one past the ceiling this seam keeps" "$(printf 'a%.0s' $(seq 1 256))"
_ref_admits "255 bytes — the ceiling itself, so the bound is not the false refusal" "$(printf 'a%.0s' $(seq 1 255))"

# The predicate is what the seam actually uses: the same branch name now survives the round trip.
: > "$GH_LOG"
NAZGUL_TEST_GH_PR_CASE=wipref _drive 88
assert_eq "a merged PR on a leading-underscore branch keeps its head_ref instead of being blanked" \
  "$(_field '.head_ref')" "_wip/FEAT-042-thing"
assert_eq "and that answer is still the host's own ok/merged" "$(_field '.merged')" "true"
assert_contains "and it really was the shim that answered, not a real host" \
  "$(cat "$GH_LOG")" "pr view 88 --repo github.com/orodruinlabs/nazgul"

# lean-comments: allow-run — why the predicate alone is not evidence, and what this drives instead.
# THE CONSEQUENCE CHAIN (AC3). A widened predicate with no downstream drive is a unit-test change
# with no evidence it reached the refusal it exists to close, so the merge-evidence gate itself is
# driven here — READ-ONLY; task-transition-guard.sh is TASK-042's file and is sourced, never edited.
# Its fixture is a tree of its own so this suite's config.json stays byte-identical, and the host
# answer comes from the same PATH shim above rather than from a stubbed seam function.
AC3_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-mp-ac3-XXXXXX")
git -C "$AC3_DIR" init -q >/dev/null 2>&1
git -C "$AC3_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"
mkdir -p "$AC3_DIR/nazgul/logs"
jq -n '{feat_id:"FEAT-042", branch:{feature:"_wip/FEAT-042-thing", base:"main"}}' > "$AC3_DIR/nazgul/config.json"
printf -- '---\nfeat_id: FEAT-042\n---\n# Plan — FEAT-042\n\n## Tasks\n\n- TASK-050\n' > "$AC3_DIR/nazgul/plan.md"
cat > "$AC3_DIR/manifest.md" <<'AC3_MANIFEST'
---
status: IMPLEMENTED
---
# TASK-050

## Commits

## Merge Evidence
- **host**: github.com
- **pr**: 88
- **merged-at**: 2026-08-14T23:16:50Z
- **merge-commit**: d6f7582f7d9ee8f74706ea02202d15dd5bc83146
- **head-ref**: _wip/FEAT-042-thing
- **recorded-by**: scripts/close-objective.sh (host API, ok)

## Description
closure fixture
AC3_MANIFEST
AC3_ERR="$FAKEBIN/ac3-err"
AC3_OUT=$(NAZGUL_TEST_GH_PR_CASE=wipref NAZGUL_DIR="$AC3_DIR/nazgul" bash -c '
  set -uo pipefail
  source "$1" || exit 90
  source "$2" || exit 91
  ec=0
  ttg_verify_merge_evidence "$(cat "$3")" "$4" TASK-050 >/dev/null 2>"$5" || ec=$?
  printf "%s|%s|%s\n" "$ec" "$TTG_MERGE_REASON" "$TTG_MERGE_HOST_RESULT"
' _ "$LIB" "$REPO_ROOT/scripts/lib/task-transition-guard.sh" "$AC3_DIR/manifest.md" "$AC3_DIR" "$AC3_ERR")
AC3_EC="${AC3_OUT%%|*}"
AC3_REST="${AC3_OUT#*|}"
AC3_REASON="${AC3_REST%%|*}"
AC3_HOST_RESULT="${AC3_REST##*|}"
AC3_STDERR=$(cat "$AC3_ERR" 2>/dev/null || true)
assert_eq "the gate no longer answers 'unverifiable' for a merged PR on a git-legal _-prefixed branch" \
  "$AC3_REASON" "verified"
assert_exit_code "and it admits the closure it used to refuse" "$AC3_EC" 0
assert_eq "the seam handed the gate a usable head branch, not ok_no_head_ref" "$AC3_HOST_RESULT" "ok"
assert_not_contains "and the gate never claims the host returned no usable head branch" \
  "$AC3_STDERR" "no usable head branch"
assert_contains "the verified route names the branch that used to be dropped" \
  "$AC3_STDERR" "head-ref=_wip/FEAT-042-thing"
rm -rf "$AC3_DIR"

# --- The seam never consults git ancestry, on any path. Post-squash, ancestry
# reports every shipped commit as unshipped, so a fallback would be inverted. ---
ANCESTRY_HITS=$(grep -vE '^[[:space:]]*#' "$LIB" | grep -cE 'merge-base|--is-ancestor|rev-list --ancestry' || true)
assert_eq "the library invokes no git-ancestry check on any code path" "$ANCESTRY_HITS" "0"
assert_file_contains "the why-not-ancestry rationale is recorded where a future reader will see it" \
  "$LIB" "NEVER GIT ANCESTRY"

# --- Sourced-library hygiene: no `set -e`, idempotent, caller's options intact. ---
if grep -qE '^[[:space:]]*set -[a-z]*e' "$LIB"; then
  _fail "the sourced library does not set -e" "a set -e would alter the caller's shell options"
else
  _pass "the sourced library does not set -e"
fi
HYGIENE_OUT=$(bash -c '
  set +u
  source "$1" || exit 9
  source "$1" || exit 9
  case "$-" in *e*) exit 7 ;; esac
  case "$-" in *u*) exit 8 ;; esac
  exit 0' _ "$LIB" 2>&1); HYGIENE_RC=$?
assert_exit_code "re-sourcing is idempotent and leaves the caller's shell options untouched" "$HYGIENE_RC" 0
[ "$HYGIENE_RC" -eq 0 ] || printf '        source diagnostics: %s\n' "$HYGIENE_OUT"

MP_SKIPPED=$MP_SKIP_UNDRIVABLE
if [ "$MP_SCANNED" -eq 0 ]; then
  _fail "the library declares a named result vocabulary this test can scan" \
    "zero tokens extracted from $LIB — a broken extractor, not a library without results"
fi
if [ "$MP_SCANNED" -ne $((MP_SKIPPED + MP_CHECKED)) ]; then
  MP_SKIP_UNDRIVABLE=$((MP_SCANNED - MP_CHECKED))
  MP_SKIPPED=$MP_SKIP_UNDRIVABLE
  _fail "every documented result token is driven by a scenario (N == M + K)" \
    "$MP_SCANNED scanned, $MP_CHECKED checked — $MP_SKIPPED documented result(s) no case drives"
fi

teardown_temp_dir
rm -rf "$FAKEBIN" "$NOGH_DIR"

RC=0
report_results || RC=1
MP_FINDINGS=$TESTS_FAILED
printf '%s: %d scanned, %d skipped (undrivable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$MP_SCANNED" "$MP_SKIPPED" "$MP_SKIP_UNDRIVABLE" "$MP_CHECKED" "$MP_FINDINGS"
exit "$RC"
