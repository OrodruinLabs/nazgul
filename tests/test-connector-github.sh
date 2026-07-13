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
        state=""; label=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --state) state="${2:-}"; shift 2 || true ;;
            --label) label="${2:-}"; shift 2 || true ;;
            --json)  shift 2 || true ;;
            *) shift || true ;;
          esac
        done
        jq -c --arg label "$label" --arg state "$state" --slurpfile ls "$LS" '
          ($ls[0] // {}) as $sm
          | [ .[]
              | . as $iss
              | (($sm[($iss.number|tostring)] // []) | map({name:.})) as $added
              | ($iss.labels + $added) as $lbls
              | select((.state|ascii_downcase) == ($state|ascii_downcase))
              | select(any($lbls[]; .name == $label))
              | {number: $iss.number, labels: $lbls} ]
        ' "$DB"
        ;;
      view)
        num="${1:-}"
        [ "${NAZGUL_TEST_GH_MALFORMED_VIEW:-0}" = "1" ] && { printf '%s' '{ this is : not json'; exit 0; }
        jq -c --argjson n "$num" --arg ns "$num" --slurpfile ls "$LS" '
          ($ls[0] // {}) as $sm
          | (.[] | select(.number == $n)) as $iss
          | (($sm[$ns] // []) | map({name:.})) as $added
          | {title: $iss.title, body: $iss.body, labels: ($iss.labels + $added)}
        ' "$DB"
        ;;
      edit)
        num="${1:-}"; shift || true
        add=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --add-label) add="${2:-}"; shift 2 || true ;;
            *) shift || true ;;
          esac
        done
        if [ -n "$EC" ]; then c=0; [ -f "$EC" ] && c=$(cat "$EC"); echo $((c + 1)) > "$EC"; fi
        cur='{}'; [ -f "$LS" ] && cur=$(cat "$LS")
        printf '%s' "$cur" | jq --arg n "$num" --arg l "$add" '.[$n] = ((.[$n] // []) + [$l] | unique)' > "$LS.tmp" && mv "$LS.tmp" "$LS"
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

teardown_temp_dir
rm -rf "$FAKEBIN"
report_results
