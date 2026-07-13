#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly.

# Test: scripts/lib/connector-github.sh — the FEAT-012 GitHub PULL contract.
# `gh` is a PATH-shim mock reading a fixture issue DB + mutable label state; NO
# network. Covers pull_list filtering, pull_get normalization / data-only /
# body-cap / malformed-skip / hostile-content, pull_archive idempotency + map,
# health degrade, and the no-credential-written guarantee.
TEST_NAME="test-connector-github"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Retry with no back-off so gh-failure scenarios don't sleep.
export NAZGUL_CGH_RETRY_DELAY=0

# Fake `gh` placed first on PATH. Its dir is a colon-free mktemp (NOT under
# $TEST_DIR, whose name carries a literal ":" that would corrupt PATH parsing).
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
write_fake_gh() {
  cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh for connector tests. Effective labels = base labels (DB) + labels
# added via `issue edit`. Env switches inject auth/repo/failure/malformed states.
DB="${NAZGUL_TEST_GH_DB:-}"
LS="${NAZGUL_TEST_GH_LABELS:-}"
EC="${NAZGUL_TEST_GH_EDIT_COUNT:-}"
CM="${NAZGUL_TEST_GH_COMMENTS:-}"

sub="${1:-}"; shift || true
case "$sub" in
  auth)
    [ "${NAZGUL_TEST_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1 ;;
  repo)
    [ "${NAZGUL_TEST_GH_REPO:-ok}" = "ok" ] || exit 1
    printf '%s' '{"name":"nazgul"}'; exit 0 ;;
  issue)
    [ "${NAZGUL_TEST_GH_FAIL:-0}" = "1" ] && exit 1
    action="${1:-}"; shift || true
    case "$action" in
      list)
        state=""; label=""; limit=1000000
        while [ $# -gt 0 ]; do
          case "$1" in
            --state) state="${2:-}"; shift 2 || true ;;
            --label) label="${2:-}"; shift 2 || true ;;
            --limit) limit="${2:-1000000}"; shift 2 || true ;;
            --json)  shift 2 || true ;;
            *) shift || true ;;
          esac
        done
        jq -c --arg label "$label" --arg state "$state" --argjson limit "$limit" --slurpfile ls "$LS" '
          ($ls[0] // {}) as $sm
          | [ .[]
              | . as $iss
              | (($sm[($iss.number|tostring)] // []) | map({name:.})) as $added
              | ($iss.labels + $added) as $lbls
              | select((.state|ascii_downcase) == ($state|ascii_downcase))
              | select(any($lbls[]; .name == $label))
              | {number: $iss.number, labels: $lbls} ]
          | .[0:$limit]
        ' "$DB"
        ;;
      view)
        num="${1:-}"
        [ "${NAZGUL_TEST_GH_MALFORMED_VIEW:-0}" = "1" ] && { printf '%s' '{ this is : not json'; exit 0; }
        cmts='{}'; [ -n "$CM" ] && [ -f "$CM" ] && cmts=$(cat "$CM")
        jq -c --argjson n "$num" --arg ns "$num" --slurpfile ls "$LS" --argjson cm "$cmts" '
          ($ls[0] // {}) as $sm
          | (.[] | select(.number == $n)) as $iss
          | (($sm[$ns] // []) | map({name:.})) as $added
          | {title: $iss.title, body: $iss.body, labels: ($iss.labels + $added), comments: ($cm[$ns] // [])}
        ' "$DB"
        ;;
      edit)
        num="${1:-}"; shift || true
        add=""; rm_label=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --add-label)    add="${2:-}"; shift 2 || true ;;
            --remove-label) rm_label="${2:-}"; shift 2 || true ;;
            *) shift || true ;;
          esac
        done
        if [ -n "$EC" ]; then c=0; [ -f "$EC" ] && c=$(cat "$EC"); echo $((c + 1)) > "$EC"; fi
        cur='{}'; [ -f "$LS" ] && cur=$(cat "$LS")
        if [ -n "$add" ]; then
          cur=$(printf '%s' "$cur" | jq --arg n "$num" --arg l "$add" '.[$n] = ((.[$n] // []) + [$l] | unique)')
        fi
        if [ -n "$rm_label" ]; then
          cur=$(printf '%s' "$cur" | jq --arg n "$num" --arg l "$rm_label" '.[$n] = ((.[$n] // []) - [$l])')
        fi
        printf '%s' "$cur" > "$LS.tmp" && mv "$LS.tmp" "$LS"
        exit 0
        ;;
      comment)
        num="${1:-}"; shift || true
        body=""; edit_last=0
        while [ $# -gt 0 ]; do
          case "$1" in
            --body)      body="${2:-}"; shift 2 || true ;;
            --edit-last) edit_last=1; shift || true ;;
            *) shift || true ;;
          esac
        done
        [ -n "$CM" ] || exit 0
        cur='{}'; [ -f "$CM" ] && cur=$(cat "$CM")
        if [ "$edit_last" = "1" ]; then
          printf '%s' "$cur" | jq --arg n "$num" --arg b "$body" '
            .[$n] = ((.[$n] // []) | if length > 0 then (.[:-1] + [{body:$b}]) else [{body:$b}] end)
          ' > "$CM.tmp" && mv "$CM.tmp" "$CM"
        else
          printf '%s' "$cur" | jq --arg n "$num" --arg b "$body" '.[$n] = ((.[$n] // []) + [{body:$b}])' > "$CM.tmp" && mv "$CM.tmp" "$CM"
        fi
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$FAKEBIN/gh"
}

setup_temp_dir
setup_nazgul_dir
create_config
CONFIG="$TEST_DIR/nazgul/config.json"

SENTINEL="$TEST_DIR/injection-sentinel.flag"
# Hostile title/body: real shell metacharacters. If ANY path eval'd/expanded it,
# the $(...) or `...` would create $SENTINEL — which we assert never appears.
HOSTILE='inj $(touch '"$SENTINEL"') `touch '"$SENTINEL"'` ${IFS} ; rm -rf ./__nazgul_should_not_exist__'

export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
export NAZGUL_TEST_GH_EDIT_COUNT="$TEST_DIR/gh-edit-count.txt"
export NAZGUL_TEST_GH_COMMENTS="$TEST_DIR/gh-comments.json"

build_db() {
  jq -n --arg htitle "$HOSTILE" '[
    {number:42, state:"OPEN",   title:"Add feature X", body:"Please add X.", labels:[{name:"nazgul"},{name:"priority:high"},{name:"type:bug"}]},
    {number:43, state:"OPEN",   title:"already claimed", body:"y", labels:[{name:"nazgul"},{name:"nazgul-claimed"}]},
    {number:99, state:"OPEN",   title:"unlabeled",      body:"z", labels:[{name:"other"}]},
    {number:50, state:"CLOSED", title:"closed one",     body:"c", labels:[{name:"nazgul"}]},
    {number:60, state:"OPEN",   title:"huge body",      body:("A" * 100000), labels:[{name:"nazgul"}]},
    {number:61, state:"OPEN",   title:$htitle,          body:$htitle, labels:[{name:"nazgul"}]}
  ]' > "$NAZGUL_TEST_GH_DB"
}
build_db
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '0'  > "$NAZGUL_TEST_GH_EDIT_COUNT"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"

write_fake_gh
export PATH="$FAKEBIN:$PATH"

# Safety gate: refuse to proceed unless PATH resolves to the fake gh.
resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  teardown_temp_dir; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/connector-github.sh"

# --- pull_list: open ∧ labeled ∧ ¬claimed only ---
list_out=$(connector_github_pull_list "$CONFIG")
assert_contains     "pull_list includes open+labeled+unclaimed issue 42" "$list_out" "42"
assert_not_contains "pull_list excludes claimed issue 43"                "$list_out" "43"
assert_not_contains "pull_list excludes unlabeled issue 99"              "$list_out" "99"
assert_not_contains "pull_list excludes closed issue 50"                 "$list_out" "50"

# --- pull_get: normalized shape + label-derived priority/type ---
get42=$(connector_github_pull_get "$CONFIG" 42)
get42_rc=$?
assert_exit_code "pull_get(42) succeeds" "$get42_rc" 0
assert_eq "pull_get(42) title"    "$(printf '%s' "$get42" | jq -r '.title')"    "Add feature X"
assert_eq "pull_get(42) body"     "$(printf '%s' "$get42" | jq -r '.body')"     "Please add X."
assert_eq "pull_get(42) priority" "$(printf '%s' "$get42" | jq -r '.priority')" "high"
assert_eq "pull_get(42) type"     "$(printf '%s' "$get42" | jq -r '.type')"     "bug"

# --- pull_get: body over max_body_bytes truncated to the cap (default 65536) ---
get60=$(connector_github_pull_get "$CONFIG" 60)
assert_eq "pull_get(60) body truncated to max_body_bytes" \
  "$(printf '%s' "$get60" | jq -r '.body | length')" "65536"

# --- pull_get: hostile title/body stays inert DATA ---
get61=$(connector_github_pull_get "$CONFIG" 61)
assert_eq "pull_get(61) hostile title preserved literally" "$(printf '%s' "$get61" | jq -r '.title')" "$HOSTILE"
assert_eq "pull_get(61) hostile body preserved literally"  "$(printf '%s' "$get61" | jq -r '.body')"  "$HOSTILE"
assert_file_not_exists "no injected command executed (sentinel absent)" "$SENTINEL"

# --- pull_get: malformed gh JSON → skip (non-zero), no crash ---
export NAZGUL_TEST_GH_MALFORMED_VIEW=1
bad_out=$(connector_github_pull_get "$CONFIG" 42); bad_rc=$?
unset NAZGUL_TEST_GH_MALFORMED_VIEW
if [ "$bad_rc" -ne 0 ]; then
  _pass "pull_get returns non-zero on malformed gh JSON"
else
  _fail "pull_get returns non-zero on malformed gh JSON" "rc: $bad_rc" "out: $bad_out"
fi

# --- pull_archive: claim adds label + records map, idempotently ---
connector_github_pull_archive "$CONFIG" 42; arch_rc1=$?
assert_exit_code "pull_archive(42) first call succeeds" "$arch_rc1" 0
assert_eq "pull_archive records map[42]" "$(jq -r '.connectors.github.map | has("42")' "$CONFIG")" "true"
assert_eq "pull_archive added the claimed label to issue 42" \
  "$(jq -r '."42" | index("nazgul-claimed") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "pull_archive issued exactly one add-label" "$(cat "$NAZGUL_TEST_GH_EDIT_COUNT")" "1"

# Second call: already claimed → returns 0, no second add-label, no dup map key.
connector_github_pull_archive "$CONFIG" 42; arch_rc2=$?
assert_exit_code "pull_archive(42) second call idempotent (returns 0)" "$arch_rc2" 0
assert_eq "pull_archive did NOT re-issue add-label on already-claimed issue" "$(cat "$NAZGUL_TEST_GH_EDIT_COUNT")" "1"
assert_eq "pull_archive map still has a single entry for 42" \
  "$(jq -r '[.connectors.github.map | keys[] | select(. == "42")] | length' "$CONFIG")" "1"
# A claimed issue must never reappear in pull_list (no sync storm).
assert_not_contains "pull_list excludes the just-claimed issue 42" "$(connector_github_pull_list "$CONFIG")" "42"

# --- no credential / token is ever written to config in any path ---
assert_file_not_contains "config carries no ghp_ token"  "$CONFIG" "ghp_"
assert_file_not_contains "config carries no github_pat"  "$CONFIG" "github_pat"
assert_eq "connectors.github has no token field" "$(jq -r '.connectors.github | has("token")' "$CONFIG")" "false"

# --- health: degrade on unauth / unresolvable repo; ok when both pass ---
export NAZGUL_TEST_GH_AUTH=fail
if connector_github_health "$CONFIG"; then
  _fail "health returns non-zero when gh is unauthenticated" "expected non-zero"
else
  _pass "health returns non-zero when gh is unauthenticated"
fi
unset NAZGUL_TEST_GH_AUTH

export NAZGUL_TEST_GH_REPO=fail
if connector_github_health "$CONFIG"; then
  _fail "health returns non-zero when repo is unresolvable" "expected non-zero"
else
  _pass "health returns non-zero when repo is unresolvable"
fi
unset NAZGUL_TEST_GH_REPO

if connector_github_health "$CONFIG"; then
  _pass "health returns zero when gh authenticated + repo resolvable"
else
  _fail "health returns zero when gh authenticated + repo resolvable" "expected zero"
fi

# --- pull_list degrades to empty output on gh failure ---
export NAZGUL_TEST_GH_FAIL=1
assert_eq "pull_list degrades to empty on gh failure" "$(connector_github_pull_list "$CONFIG")" ""
unset NAZGUL_TEST_GH_FAIL

# --- PUSH side: push_status / push_pr — gated, idempotent, sync-loop guard ---
# Issue 43 is OPEN + carries both "nazgul" and "nazgul-claimed" (base DB labels),
# and is mapped local FEAT-012 -> 43. A correct push touches only the
# nazgul-status:* namespace / a marked PR comment and NEVER the claimed label,
# so pull_list must keep excluding 43 (no re-pull storm).

PUSH_CONFIG="$TEST_DIR/nazgul/config-push.json"
jq '.connectors.github.enabled = true
    | .connectors.github.push.enabled = true
    | .connectors.github.map = {"43":"FEAT-012"}' "$CONFIG" > "$PUSH_CONFIG"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"

# --- push_status: single nazgul-status:* label upsert on the mapped issue ---
connector_github_push_status "$PUSH_CONFIG" "FEAT-012" "IN_PROGRESS"; ps_rc=$?
assert_exit_code "push_status(FEAT-012) succeeds" "$ps_rc" 0
assert_eq "push_status set nazgul-status:in-progress on mapped issue 43" \
  "$(jq -r '."43" | index("nazgul-status:in-progress") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "push_status wrote exactly one nazgul-status:* label" \
  "$(jq -r '[."43"[]? | select(startswith("nazgul-status:"))] | length' "$NAZGUL_TEST_GH_LABELS")" "1"

# --- push_status idempotent: re-push same status → no duplicate ---
connector_github_push_status "$PUSH_CONFIG" "FEAT-012" "IN_PROGRESS"
assert_eq "push_status re-push keeps a single nazgul-status:* label" \
  "$(jq -r '[."43"[]? | select(startswith("nazgul-status:"))] | length' "$NAZGUL_TEST_GH_LABELS")" "1"

# --- push_status update-in-place: new status replaces the stale marker ---
connector_github_push_status "$PUSH_CONFIG" "FEAT-012" "IMPLEMENTED"
assert_eq "push_status still a single nazgul-status:* label after a change" \
  "$(jq -r '[."43"[]? | select(startswith("nazgul-status:"))] | length' "$NAZGUL_TEST_GH_LABELS")" "1"
assert_eq "push_status update-in-place set nazgul-status:implemented" \
  "$(jq -r '."43" | index("nazgul-status:implemented") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "push_status removed the stale nazgul-status:in-progress" \
  "$(jq -r '."43" | index("nazgul-status:in-progress") == null' "$NAZGUL_TEST_GH_LABELS")" "true"

# --- sync-loop guard: claimed label never removed → pull_list still excludes 43 ---
assert_not_contains "push never removed claimed label: pull_list still excludes issue 43" \
  "$(connector_github_pull_list "$PUSH_CONFIG")" "43"

# --- push_pr: single nazgul-marked PR comment on the mapped issue ---
connector_github_push_pr "$PUSH_CONFIG" "FEAT-012" "https://github.com/o/r/pull/7"; pr_rc=$?
assert_exit_code "push_pr(FEAT-012) succeeds" "$pr_rc" 0
assert_eq "push_pr added exactly one nazgul-marked PR comment to issue 43" \
  "$(jq -r '[."43"[]? | select((.body // "") | contains("<!-- nazgul-pr -->"))] | length' "$NAZGUL_TEST_GH_COMMENTS")" "1"
assert_contains "push_pr comment carries the PR url" \
  "$(jq -r '."43"[0].body' "$NAZGUL_TEST_GH_COMMENTS")" "https://github.com/o/r/pull/7"

# --- push_pr idempotent: re-push edits in place, no duplicate comment ---
connector_github_push_pr "$PUSH_CONFIG" "FEAT-012" "https://github.com/o/r/pull/8"
assert_eq "push_pr re-push keeps a single PR comment (edit-in-place)" \
  "$(jq -r '."43" | length' "$NAZGUL_TEST_GH_COMMENTS")" "1"
assert_contains "push_pr edit-in-place updated the url" \
  "$(jq -r '."43"[0].body' "$NAZGUL_TEST_GH_COMMENTS")" "https://github.com/o/r/pull/8"

# --- push_pr rejects a non-URL argument safely (data-only, no mutation, no eval) ---
before_pr=$(cat "$NAZGUL_TEST_GH_COMMENTS")
connector_github_push_pr "$PUSH_CONFIG" "FEAT-012" 'not-a-url $(touch '"$SENTINEL"')'; nurl_rc=$?
assert_exit_code "push_pr non-URL arg returns 0 (safe ignore)" "$nurl_rc" 0
assert_eq "push_pr non-URL arg made no comment mutation" "$(cat "$NAZGUL_TEST_GH_COMMENTS")" "$before_pr"
assert_file_not_exists "push_pr non-URL arg did not execute injected command" "$SENTINEL"

# --- push gate: no-op when connectors.github.enabled=false ---
OFF_CONFIG="$TEST_DIR/nazgul/config-off.json"
jq '.connectors.github.enabled = false
    | .connectors.github.push.enabled = true
    | .connectors.github.map = {"43":"FEAT-012"}' "$CONFIG" > "$OFF_CONFIG"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"
connector_github_push_status "$OFF_CONFIG" "FEAT-012" "DONE"; goff_rc=$?
connector_github_push_pr "$OFF_CONFIG" "FEAT-012" "https://github.com/o/r/pull/9"
assert_exit_code "push_status no-op returns 0 when enabled=false" "$goff_rc" 0
assert_eq "push_status made no label mutation when enabled=false" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"
assert_eq "push_pr made no comment mutation when enabled=false" "$(cat "$NAZGUL_TEST_GH_COMMENTS")" "{}"

# --- push gate: no-op when push.enabled=false even under parent enabled=true ---
PUSHOFF_CONFIG="$TEST_DIR/nazgul/config-pushoff.json"
jq '.connectors.github.enabled = true
    | .connectors.github.push.enabled = false
    | .connectors.github.map = {"43":"FEAT-012"}' "$CONFIG" > "$PUSHOFF_CONFIG"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"
connector_github_push_status "$PUSHOFF_CONFIG" "FEAT-012" "DONE"
connector_github_push_pr "$PUSHOFF_CONFIG" "FEAT-012" "https://github.com/o/r/pull/9"
assert_eq "push_status no-op when push.enabled=false (parent enabled)" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"
assert_eq "push_pr no-op when push.enabled=false (parent enabled)" "$(cat "$NAZGUL_TEST_GH_COMMENTS")" "{}"

# --- INTEGRATION: full two-way cycle pull→claim→push must NOT re-pull (D-012-C) ---
# Fresh config + label state so issue 42 starts OPEN, labeled, unclaimed, unmapped.
INT_CONFIG="$TEST_DIR/nazgul/config-int.json"
jq '.connectors.github.enabled = true
    | .connectors.github.push.enabled = true
    | .connectors.github.map = {}' "$CONFIG" > "$INT_CONFIG"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"

assert_contains "cycle step 1: pull_list lists candidate 42" "$(connector_github_pull_list "$INT_CONFIG")" "42"
connector_github_pull_get "$INT_CONFIG" 42 >/dev/null; cyc_get_rc=$?
assert_exit_code "cycle step 2: pull_get(42) succeeds" "$cyc_get_rc" 0
connector_github_pull_archive "$INT_CONFIG" 42; cyc_arch_rc=$?
assert_exit_code "cycle step 3: pull_archive(42) claims + maps" "$cyc_arch_rc" 0
assert_eq "cycle: claimed label recorded for 42" \
  "$(jq -r '."42" | index("nazgul-claimed") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
# Bind the map stub to a local id (as objective creation would) so push can resolve.
jq '.connectors.github.map["42"] = "FEAT-INT"' "$INT_CONFIG" > "$INT_CONFIG.tmp" && mv "$INT_CONFIG.tmp" "$INT_CONFIG"

connector_github_push_status "$INT_CONFIG" "FEAT-INT" "IN_PROGRESS"; cyc_ps_rc=$?
assert_exit_code "cycle step 4: push_status succeeds" "$cyc_ps_rc" 0
connector_github_push_pr "$INT_CONFIG" "FEAT-INT" "https://github.com/o/r/pull/42"; cyc_pr_rc=$?
assert_exit_code "cycle step 5: push_pr succeeds" "$cyc_pr_rc" 0

# Headline invariant: after claim + both pushes, 42 is gone from pull_list.
assert_not_contains "cycle step 6: push provably cannot re-enter pull_list (issue 42 absent)" \
  "$(connector_github_pull_list "$INT_CONFIG")" "42"
assert_eq "cycle: claimed label still present after BOTH pushes" \
  "$(jq -r '."42" | index("nazgul-claimed") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "cycle: push only touched the nazgul-status namespace (single status label)" \
  "$(jq -r '[."42"[]? | select(startswith("nazgul-status:"))] | length' "$NAZGUL_TEST_GH_LABELS")" "1"

# --- storm guard: local map suppresses re-pull even if the remote claimed label is stripped ---
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
assert_not_contains "map entry alone suppresses re-pull of 42 (remote label lag/removal)" \
  "$(connector_github_pull_list "$INT_CONFIG")" "42"

# --- DEGRADATION: pull_failures increments, auto-disables at 5, resets on success ---
FAIL_CONFIG="$TEST_DIR/nazgul/config-fail.json"
jq '.connectors.github.enabled = true | .connectors.github.pull_failures = 0' "$CONFIG" > "$FAIL_CONFIG"
export NAZGUL_TEST_GH_FAIL=1
for expect in 1 2 3 4; do
  out=$(connector_github_pull_list "$FAIL_CONFIG"); rc=$?
  assert_exit_code "degrade: pull_list returns 0 (never blocks) on gh failure #$expect" "$rc" 0
  assert_eq "degrade: pull_list emits nothing on gh failure #$expect" "$out" ""
  assert_eq "degrade: pull_failures incremented to $expect" \
    "$(jq -r '.connectors.github.pull_failures' "$FAIL_CONFIG")" "$expect"
  assert_eq "degrade: connector still enabled before threshold (#$expect)" \
    "$(jq -r '.connectors.github.enabled' "$FAIL_CONFIG")" "true"
done
connector_github_pull_list "$FAIL_CONFIG" >/dev/null; rc5=$?
assert_exit_code "degrade: 5th failure still returns 0 (loop unblocked)" "$rc5" 0
assert_eq "degrade: pull_failures reached 5" "$(jq -r '.connectors.github.pull_failures' "$FAIL_CONFIG")" "5"
assert_eq "degrade: connector AUTO-DISABLED at 5 consecutive failures" \
  "$(jq -r '.connectors.github.enabled' "$FAIL_CONFIG")" "false"
unset NAZGUL_TEST_GH_FAIL

# A subsequent successful pull resets the counter to 0.
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
connector_github_pull_list "$FAIL_CONFIG" >/dev/null; rc_ok=$?
assert_exit_code "degrade: successful pull after failures returns 0" "$rc_ok" 0
assert_eq "degrade: successful pull resets pull_failures to 0" \
  "$(jq -r '.connectors.github.pull_failures' "$FAIL_CONFIG")" "0"

# --- pull_get degrades to non-zero on gh IO failure (T3 regression guard) ---
export NAZGUL_TEST_GH_FAIL=1
connector_github_pull_get "$FAIL_CONFIG" 42 >/dev/null; pg_fail_rc=$?
if [ "$pg_fail_rc" -ne 0 ]; then
  _pass "pull_get returns non-zero on gh IO failure"
else
  _fail "pull_get returns non-zero on gh IO failure" "rc: $pg_fail_rc"
fi
unset NAZGUL_TEST_GH_FAIL

# --- push under gh failure: no crash, no mutation, degrade-safe return ---
GHFAIL_PUSH="$TEST_DIR/nazgul/config-ghfail-push.json"
jq '.connectors.github.enabled = true
    | .connectors.github.push.enabled = true
    | .connectors.github.map = {"43":"FEAT-012"}' "$CONFIG" > "$GHFAIL_PUSH"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"
export NAZGUL_TEST_GH_FAIL=1
connector_github_push_status "$GHFAIL_PUSH" "FEAT-012" "IN_PROGRESS"; psf_rc=$?
connector_github_push_pr "$GHFAIL_PUSH" "FEAT-012" "https://github.com/o/r/pull/7"; prf_rc=$?
unset NAZGUL_TEST_GH_FAIL
assert_eq "push_status under gh failure made no label mutation" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"
assert_eq "push_pr under gh failure made no comment mutation" "$(cat "$NAZGUL_TEST_GH_COMMENTS")" "{}"
# Non-zero return is fine (caller ignores it); the contract is "no crash, no mutation".
_pass "push under gh failure returned without crashing (ps=$psf_rc pr=$prf_rc)"

# --- push to an UNMAPPED local_id is a safe no-op (no gh mutation) ---
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"
connector_github_push_status "$GHFAIL_PUSH" "FEAT-NOPE" "IN_PROGRESS"; unmapped_ps=$?
connector_github_push_pr "$GHFAIL_PUSH" "FEAT-NOPE" "https://github.com/o/r/pull/1"; unmapped_pr=$?
assert_exit_code "push_status unmapped local_id returns 0 (no-op)" "$unmapped_ps" 0
assert_exit_code "push_pr unmapped local_id returns 0 (no-op)" "$unmapped_pr" 0
assert_eq "push_status unmapped local_id made no label mutation" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"
assert_eq "push_pr unmapped local_id made no comment mutation" "$(cat "$NAZGUL_TEST_GH_COMMENTS")" "{}"

# --- push_status with an empty status arg is a safe no-op ---
connector_github_push_status "$GHFAIL_PUSH" "FEAT-012" ""; empty_ps=$?
assert_exit_code "push_status empty status returns 0 (no-op)" "$empty_ps" 0
assert_eq "push_status empty status made no label mutation" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"

# --- pull_list honors pull.max_items (--limit): a >limit backlog is capped ---
jq -n '[ range(201;206) | {number:., state:"OPEN", title:("t"+(.|tostring)), body:"b", labels:[{name:"nazgul"}]} ]' > "$NAZGUL_TEST_GH_DB"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
LIMIT_CONFIG="$TEST_DIR/nazgul/config-limit.json"
jq '.connectors.github.pull.max_items = 2' "$CONFIG" > "$LIMIT_CONFIG"
limit_out=$(connector_github_pull_list "$LIMIT_CONFIG")
limit_count=$(printf '%s' "$limit_out" | grep -c '^[0-9]')
assert_eq "pull_list honors max_items limit (returns at most 2 of 5)" "$limit_count" "2"
build_db  # restore fixtures

# --- HEARTBEAT WIRING (TASK-008): provider=github tick pulls + auto-starts an issue ---
# Runtime pull caller is scripts/heartbeat.sh; auto-start captured via NAZGUL_HEARTBEAT_START_CMD.
teardown_temp_dir
setup_temp_dir
setup_nazgul_dir
create_config \
  '.automation.heartbeat.enabled = true' \
  '.automation.heartbeat.inbox.provider = "github"' \
  '.connectors.github.enabled = true'
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
export NAZGUL_TEST_GH_COMMENTS="$TEST_DIR/gh-comments.json"
export NAZGUL_TEST_GH_EDIT_COUNT="$TEST_DIR/gh-edit-count.txt"
jq -n '[{number:77, state:"OPEN", title:"FEAT-777 pull me", body:"do it", labels:[{name:"nazgul"},{name:"priority:1"}]}]' > "$NAZGUL_TEST_GH_DB"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"; echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"; echo '0' > "$NAZGUL_TEST_GH_EDIT_COUNT"

HB_CAP="$TEST_DIR/hb-start.txt"
cat > "$TEST_DIR/fake-start.sh" << EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$HB_CAP"
EOF
chmod +x "$TEST_DIR/fake-start.sh"

rc=0
NAZGUL_HEARTBEAT_START_CMD="$TEST_DIR/fake-start.sh" CLAUDE_PROJECT_DIR="$TEST_DIR" \
  bash "$REPO_ROOT/scripts/heartbeat.sh" >/dev/null 2>&1 || rc=$?
assert_exit_code "heartbeat(github): tick exits 0" "$rc" 0
assert_file_exists "heartbeat(github): a labeled remote issue was auto-started" "$HB_CAP"
assert_contains "heartbeat(github): auto-start objective is the pulled issue title" \
  "$(cat "$HB_CAP" 2>/dev/null || echo "")" "FEAT-777 pull me"
assert_eq "heartbeat(github): the pulled issue was claimed (nazgul-claimed added)" \
  "$(jq -r '."77" | index("nazgul-claimed") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
HB_LOG=$(ls -1 "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | tail -1)
assert_eq "heartbeat(github): decision recorded as started" \
  "$(tail -1 "$HB_LOG" | jq -r '.decision')" "started"

# --- HEARTBEAT WIRING: an unhealthy github connector degrades to a clean skip ---
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
rm -f "$HB_CAP"
rc=0
NAZGUL_TEST_GH_AUTH=fail NAZGUL_HEARTBEAT_START_CMD="$TEST_DIR/fake-start.sh" CLAUDE_PROJECT_DIR="$TEST_DIR" \
  bash "$REPO_ROOT/scripts/heartbeat.sh" >/dev/null 2>&1 || rc=$?
assert_exit_code "heartbeat(github): unhealthy connector still exits 0 (no crash)" "$rc" 0
assert_file_not_exists "heartbeat(github): unhealthy connector auto-started nothing" "$HB_CAP"
HB_LOG=$(ls -1 "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | tail -1)
assert_eq "heartbeat(github): unhealthy connector degrades to nothing_actionable" \
  "$(tail -1 "$HB_LOG" | jq -r '.decision')" "nothing_actionable"

# --- STOP-HOOK WIRING (TASK-008): push-on-transition fires push_status/push_pr ---
# Runtime push caller is scripts/stop-hook.sh: changed status pushes once, unchanged is skipped.
teardown_temp_dir
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.connectors.github.enabled = true' \
  '.connectors.github.push.enabled = true' \
  '.connectors.github.map = {"43":"TASK-101"}'
WIRE_CFG="$TEST_DIR/nazgul/config.json"
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
export NAZGUL_TEST_GH_COMMENTS="$TEST_DIR/gh-comments.json"
export NAZGUL_TEST_GH_EDIT_COUNT="$TEST_DIR/gh-edit-count.txt"
jq -n '[{number:43, state:"OPEN", title:"mapped", body:"b", labels:[{name:"nazgul"},{name:"nazgul-claimed"}]}]' > "$NAZGUL_TEST_GH_DB"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"; echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"; echo '0' > "$NAZGUL_TEST_GH_EDIT_COUNT"

# A manifest with an ID field (mirrors board-sync's `- **ID**:` read) and a PR URL.
cat > "$TEST_DIR/nazgul/tasks/TASK-101.md" << 'TASK_EOF'
# TASK-101: wiring probe

- **ID**: TASK-101
- **Status**: IMPLEMENTED
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3
- **PR**: https://github.com/o/r/pull/101

## Commits
- abc1234
TASK_EOF

echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>&1 || true
assert_eq "stop-hook: push_status set nazgul-status:implemented on mapped issue 43" \
  "$(jq -r '."43" | index("nazgul-status:implemented") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "stop-hook: per-task push cache records the pushed status" \
  "$(jq -r '.connectors.github._last_pushed_status["TASK-101"] // ""' "$WIRE_CFG")" "IMPLEMENTED"
assert_eq "stop-hook: push_pr added a nazgul-marked PR comment to issue 43" \
  "$(jq -r '[."43"[]? | select((.body // "") | contains("<!-- nazgul-pr -->"))] | length' "$NAZGUL_TEST_GH_COMMENTS")" "1"

# Idempotency: a second iteration with an unchanged status must NOT re-push.
LABELS_BEFORE=$(cat "$NAZGUL_TEST_GH_LABELS")
echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>&1 || true
assert_eq "stop-hook: unchanged status is NOT re-pushed (labels stable)" \
  "$(cat "$NAZGUL_TEST_GH_LABELS")" "$LABELS_BEFORE"

# A gh push failure must not break the loop or mutate remote state.
echo '{}' > "$NAZGUL_TEST_GH_LABELS"
jq '.connectors.github._last_pushed_status = {}' "$WIRE_CFG" > "$WIRE_CFG.tmp" && mv "$WIRE_CFG.tmp" "$WIRE_CFG"
rc=0
echo '{}' | NAZGUL_TEST_GH_FAIL=1 CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>&1 || rc=$?
_pass "stop-hook: completed despite a gh push failure (rc=$rc, loop unbroken)"
assert_eq "stop-hook: gh push failure left no label mutation" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"

# --- STOP-HOOK WIRING (TASK-008): a status change with NO PR URL must NOT call push_pr ---
# Bidirectional proof of "PR push only when a PR URL exists": status pushes, push_pr stays silent.
teardown_temp_dir
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.connectors.github.enabled = true' \
  '.connectors.github.push.enabled = true' \
  '.connectors.github.map = {"44":"TASK-102"}'
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
export NAZGUL_TEST_GH_COMMENTS="$TEST_DIR/gh-comments.json"
export NAZGUL_TEST_GH_EDIT_COUNT="$TEST_DIR/gh-edit-count.txt"
jq -n '[{number:44, state:"OPEN", title:"mapped", body:"b", labels:[{name:"nazgul"},{name:"nazgul-claimed"}]}]' > "$NAZGUL_TEST_GH_DB"
echo '{}' > "$NAZGUL_TEST_GH_LABELS"; echo '{}' > "$NAZGUL_TEST_GH_COMMENTS"; echo '0' > "$NAZGUL_TEST_GH_EDIT_COUNT"

# A manifest with a status change but deliberately NO `- **PR**:` line.
cat > "$TEST_DIR/nazgul/tasks/TASK-102.md" << 'TASK_EOF'
# TASK-102: wiring probe (no PR URL)

- **ID**: TASK-102
- **Status**: IMPLEMENTED
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3

## Commits
- abc1234
TASK_EOF

echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>&1 || true
assert_eq "stop-hook: push_status set nazgul-status:implemented on mapped issue 44 (status still pushes)" \
  "$(jq -r '."44" | index("nazgul-status:implemented") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_eq "stop-hook: missing PR URL prevents push_pr call (0 nazgul-pr comments on issue 44)" \
  "$(jq -r '[."44"[]? | select((.body // "") | contains("<!-- nazgul-pr -->"))] | length' "$NAZGUL_TEST_GH_COMMENTS")" "0"

teardown_temp_dir
rm -rf "$FAKEBIN"
report_results
