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
#   recaptured:    2026-08-16, TASK-011 rework, same producer and repo, with the two new
#                  fields the objective-binding check needs; the bytes below are the
#                  re-capture, so the sha256 lines for the two payloads changed with it.
#   captured-with: gh pr view 88     --json state,mergedAt,mergeCommit,headRefName,baseRefName  # merged
#                  gh pr view 194    --json state,mergedAt,mergeCommit,headRefName,baseRefName  # open
#                  gh pr view 999999 --json state,mergedAt,mergeCommit,headRefName,baseRefName  # error (exit 1)
#   source-repo:   OrodruinLabs/nazgul (this repo's own PRs — no third-party subject matter)
#   sha256:        fe905b27b767c4a1d5bb062a85c7a7554aedb7daa7b64a8c37a19b74e7268fd6  merged payload
#                  922e914161ecc04ae741ea54f5788e1dffca5f438357ecb8646805a5e43be849  open payload
#                  0cacbfff6ea53b1f26a7a3c2e79c2f85c5973ecbcd15e094611b3944a2d3476d  error stderr
#   note:          PR 88's real headRefName is FEAT-030's branch, not this objective's.
#                  That is not incidental — it is the captured instance of the hazard the
#                  binding check exists for: a genuinely merged PR of a DIFFERENT
#                  objective. It is used as such below rather than being edited away.
#   not-captured:  the unauthenticated, unparseable-payload, and malformed-ref cases.
#                  `gh auth status` failing, a truncated body, and a host returning a
#                  branch name no git ref could carry cannot be captured from a healthy
#                  authenticated host, so those three are SYNTHETIC and are named as
#                  such rather than passed off as captured.
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
CONFIG_BEFORE=$(shasum -a 256 < "$TEST_DIR/nazgul/config.json" | awk '{print $1}')

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
    case "${NAZGUL_TEST_GH_PR_CASE:-merged}" in
      merged) printf '%s\n' '{"baseRefName":"main","headRefName":"feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED"}'; exit 0 ;;
      open)   printf '%s\n' '{"baseRefName":"main","headRefName":"docs/granularity-decoupling-spec","mergeCommit":null,"mergedAt":null,"state":"OPEN"}'; exit 0 ;;
      badref) printf '%s\n' '{"baseRefName":"main","headRefName":"a branch; rm -rf /","mergeCommit":{"oid":"d6f7582f7d9ee8f74706ea02202d15dd5bc83146"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED"}'; exit 0 ;;
      error)  printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 999999. (repository.pullRequest)' >&2; exit 1 ;;
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
  "$(cat "$GH_LOG")" "pr view 88 --json state,mergedAt,mergeCommit,headRefName,baseRefName"
assert_eq "merged PR: the head branch is carried, so a caller can bind the PR to an objective" \
  "$(_field '.head_ref')" "feat/FEAT-030-worktree-relative-runtime-state-path-resolution-pr"
assert_eq "merged PR: the base branch is carried too" "$(_field '.base_ref')" "main"

# A host-authored branch name no git ref could carry is DROPPED, so a caller needing the
# binding fails closed rather than matching attacker-chosen text. (SYNTHETIC.)
NAZGUL_TEST_GH_PR_CASE=badref _drive 88
assert_eq "a head branch that is not ref-shaped is dropped, not carried" "$(_field '.head_ref')" "null"
assert_eq "dropping an unusable ref does not turn the answer into a failure" "$(_field '.result')" "ok"

# --- ok / OPEN: "looked and found NOT merged" — merged is false, not null. ---
NAZGUL_TEST_GH_PR_CASE=open _drive 194
assert_eq "open PR: the query succeeded, so the result is still 'ok'" "$(_field '.result')" "ok"
assert_eq "open PR: state is OPEN" "$(_field '.state')" "OPEN"
assert_eq "open PR: merged is FALSE — the host was asked and said no" "$(_field '.merged')" "false"
assert_eq "open PR: merged_at is null" "$(_field '.merged_at')" "null"
assert_eq "open PR: merge_commit is null" "$(_field '.merge_commit')" "null"
assert_eq "open PR: the head branch is still carried — it is not merge state" \
  "$(_field '.head_ref')" "docs/granularity-decoupling-spec"

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
CONFIG_AFTER=$(shasum -a 256 < "$TEST_DIR/nazgul/config.json" | awk '{print $1}')
assert_eq "the seam never writes config.json at all — no credential surface to add one to" \
  "$CONFIG_AFTER" "$CONFIG_BEFORE"

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
