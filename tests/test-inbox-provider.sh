#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes explicitly

# Test: inbox-provider.sh — file provider list/get/archive over nazgul/inbox/
TEST_NAME="test-inbox-provider"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/inbox-provider.sh"

seed_inbox() {
  # Writes a mixed .md + .json inbox plus a decoy in archive/.
  local inbox="$1"
  mkdir -p "$inbox/archive"
  cat > "$inbox/first.md" << 'EOF'
---
title: Ship the heartbeat
priority: high
type: feature
---
Wire the automation heartbeat into the start skill.

Second paragraph of body.
EOF
  cat > "$inbox/second.json" << 'EOF'
{
  "title": "Fix the flaky test",
  "body": "The conductor test is flaky under load.",
  "priority": "medium",
  "type": "bugfix"
}
EOF
  cat > "$inbox/no-meta.md" << 'EOF'
---
title: Bare objective
---
Just a body, no priority or type.
EOF
  # A decoy already in archive/ must never be listed.
  echo '{"title":"old"}' > "$inbox/archive/old.json"
}

# --- Test 1: list counts mixed .md + .json, excludes archive/ ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
COUNT=$(inbox_list "$INBOX" | wc -l | tr -d ' ')
assert_eq "list: counts 3 mixed-format candidates" "$COUNT" "3"
assert_not_contains "list: excludes archive/ entries" "$(inbox_list "$INBOX")" "old.json"
assert_contains "list: includes the .md candidate" "$(inbox_list "$INBOX")" "first.md"
assert_contains "list: includes the .json candidate" "$(inbox_list "$INBOX")" "second.json"
teardown_temp_dir

# --- Test 2: get parses .md frontmatter + body ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
MD_JSON=$(inbox_get "$INBOX" first.md)
assert_eq "get md: title" "$(echo "$MD_JSON" | jq -r '.title')" "Ship the heartbeat"
assert_eq "get md: priority" "$(echo "$MD_JSON" | jq -r '.priority')" "high"
assert_eq "get md: type" "$(echo "$MD_JSON" | jq -r '.type')" "feature"
assert_contains "get md: body carries markdown text" "$(echo "$MD_JSON" | jq -r '.body')" "Wire the automation heartbeat"
teardown_temp_dir

# --- Test 3: get parses .json candidate ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
JSON_JSON=$(inbox_get "$INBOX" second.json)
assert_eq "get json: title" "$(echo "$JSON_JSON" | jq -r '.title')" "Fix the flaky test"
assert_eq "get json: priority" "$(echo "$JSON_JSON" | jq -r '.priority')" "medium"
assert_eq "get json: type" "$(echo "$JSON_JSON" | jq -r '.type')" "bugfix"
assert_eq "get json: body" "$(echo "$JSON_JSON" | jq -r '.body')" "The conductor test is flaky under load."
teardown_temp_dir

# --- Test 4: missing priority/type default to null ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
BARE=$(inbox_get "$INBOX" no-meta.md)
assert_eq "get md: missing priority is null" "$(echo "$BARE" | jq -r '.priority')" "null"
assert_eq "get md: missing type is null" "$(echo "$BARE" | jq -r '.type')" "null"
assert_eq "get md: title still parsed" "$(echo "$BARE" | jq -r '.title')" "Bare objective"
teardown_temp_dir

# --- Test 5: empty / absent inbox -> zero candidates ---
setup_temp_dir
EMPTY="$TEST_DIR/nazgul/inbox"
mkdir -p "$EMPTY"
assert_eq "list: empty inbox yields zero" "$(inbox_list "$EMPTY" | wc -l | tr -d ' ')" "0"
assert_eq "list: absent inbox yields zero" "$(inbox_list "$TEST_DIR/nazgul/nope" | wc -l | tr -d ' ')" "0"
teardown_temp_dir

# --- Test 6: provider selected by config, default file ---
setup_temp_dir
setup_nazgul_dir
create_config
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "provider: default is file" "$(inbox_provider "$CONFIG")" "file"
assert_eq "provider: missing config defaults file" "$(inbox_provider "$TEST_DIR/nazgul/none.json")" "file"
teardown_temp_dir

# --- Test 7: archive MOVES (not deletes) into archive/ ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
inbox_archive "$INBOX" first.md
EC=$?
assert_exit_code "archive: returns success" "$EC" 0
assert_file_not_exists "archive: source removed from active inbox" "$INBOX/first.md"
assert_file_exists "archive: candidate moved into archive/" "$INBOX/archive/first.md"
assert_not_contains "archive: no longer listed" "$(inbox_list "$INBOX")" "first.md"
# Re-running on an already-archived candidate is a no-op success (crash-safe).
inbox_archive "$INBOX" first.md
assert_exit_code "archive: re-run is idempotent success" "$?" 0
assert_file_exists "archive: still present after re-run" "$INBOX/archive/first.md"
teardown_temp_dir

# --- Test 7.5: the file-provider path never sources the github connector ---
# All tests above ran the file provider (default/unset); the connector must stay
# untouched so existing projects have zero github surface.
assert_eq "file provider: connector never sourced" "${_NAZGUL_CONNECTOR_GITHUB_SOURCED:-unset}" "unset"

# ============================================================================
# GitHub-provider dispatch (provider="github"). `gh` is a PATH-shim mock reading
# a fixture issue DB + mutable label state (NO network), mirroring the pattern in
# tests/test-connector-github.sh. FAKEBIN is a colon-free mktemp dir so PATH parses.
# ============================================================================
export NAZGUL_CGH_RETRY_DELAY=0
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'GH_EOF'
#!/usr/bin/env bash
# Mock gh for inbox-provider dispatch tests. Effective labels = base (DB) + labels
# added via `issue edit`. Env switches inject auth/repo/failure states.
DB="${NAZGUL_TEST_GH_DB:-}"
LS="${NAZGUL_TEST_GH_LABELS:-}"
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
        cur='{}'; [ -f "$LS" ] && cur=$(cat "$LS")
        [ -n "$add" ] && cur=$(printf '%s' "$cur" | jq --arg n "$num" --arg l "$add" '.[$n] = ((.[$n] // []) + [$l] | unique)')
        printf '%s' "$cur" > "$LS.tmp" && mv "$LS.tmp" "$LS"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH_EOF
chmod +x "$FAKEBIN/gh"

seed_gh_db() {
  # Two open+labeled issues: 42 unclaimed (priority:high/type:bug), 43 already claimed.
  jq -n '[
    {number:42, state:"OPEN", title:"Add feature X", body:"Please add X.", labels:[{name:"nazgul"},{name:"priority:high"},{name:"type:bug"}]},
    {number:43, state:"OPEN", title:"already claimed", body:"y", labels:[{name:"nazgul"},{name:"nazgul-claimed"}]}
  ]' > "$NAZGUL_TEST_GH_DB"
  echo '{}' > "$NAZGUL_TEST_GH_LABELS"
}

BASE_PATH="$PATH"
export PATH="$FAKEBIN:$PATH"

# Safety gate: refuse to proceed unless PATH resolves to the fake gh.
resolved_gh=$(command -v gh)
if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
  _fail "PATH resolves to the fake gh (safety gate)" "expected: '$FAKEBIN/gh'" "  actual: '$resolved_gh'"
  export PATH="$BASE_PATH"; rm -rf "$FAKEBIN"; report_results; exit 1
fi
_pass "PATH resolves to the fake gh (safety gate)"

# --- Test 8: provider="github" routes list/get/archive to the connector ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.inbox.provider = "github"' '.connectors.github.enabled = true'
INBOX="$TEST_DIR/nazgul/inbox"
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
seed_gh_db

GH_LIST=$(inbox_list "$INBOX")
assert_contains     "github list: routes to connector (unclaimed issue 42 lists)" "$GH_LIST" "42"
assert_not_contains "github list: excludes the claimed issue 43"                  "$GH_LIST" "43"

GH_GET=$(inbox_get "$INBOX" 42)
GH_GET_RC=$?
assert_exit_code "github get: routes to connector (returns 0)" "$GH_GET_RC" 0
assert_eq "github get: title via connector"    "$(echo "$GH_GET" | jq -r '.title')"    "Add feature X"
assert_eq "github get: body via connector"     "$(echo "$GH_GET" | jq -r '.body')"     "Please add X."
assert_eq "github get: priority via connector" "$(echo "$GH_GET" | jq -r '.priority')" "high"
assert_eq "github get: type via connector"     "$(echo "$GH_GET" | jq -r '.type')"     "bug"

inbox_archive "$INBOX" 42
GH_ARCH_RC=$?
assert_exit_code "github archive: routes to connector (returns 0)" "$GH_ARCH_RC" 0
assert_eq "github archive: connector added the claimed label to issue 42" \
  "$(jq -r '."42" | index("nazgul-claimed") != null' "$NAZGUL_TEST_GH_LABELS")" "true"
assert_not_contains "github archive: the just-claimed issue 42 no longer lists" "$(inbox_list "$INBOX")" "42"
teardown_temp_dir

# --- Test 9: provider="github" but connector unhealthy → safe degrade ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.inbox.provider = "github"' '.connectors.github.enabled = true'
INBOX="$TEST_DIR/nazgul/inbox"
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
seed_gh_db
export NAZGUL_TEST_GH_AUTH=fail
assert_eq "github degrade (unhealthy): list yields nothing" "$(inbox_list "$INBOX")" ""
inbox_get "$INBOX" 42 >/dev/null 2>&1
assert_exit_code "github degrade (unhealthy): get returns 1" "$?" 1
inbox_archive "$INBOX" 42 >/dev/null 2>&1
assert_exit_code "github degrade (unhealthy): archive returns 1" "$?" 1
assert_eq "github degrade (unhealthy): no label mutation" "$(cat "$NAZGUL_TEST_GH_LABELS")" "{}"
unset NAZGUL_TEST_GH_AUTH
teardown_temp_dir

# --- Test 10: provider="github" but connectors.github.enabled=false → safe degrade ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.inbox.provider = "github"' '.connectors.github.enabled = false'
INBOX="$TEST_DIR/nazgul/inbox"
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
seed_gh_db
assert_eq "github degrade (enabled=false): list yields nothing" "$(inbox_list "$INBOX")" ""
inbox_get "$INBOX" 42 >/dev/null 2>&1
assert_exit_code "github degrade (enabled=false): get returns 1" "$?" 1
inbox_archive "$INBOX" 42 >/dev/null 2>&1
assert_exit_code "github degrade (enabled=false): archive returns 1" "$?" 1
teardown_temp_dir

# --- Test 11: {title,body,priority,type} shape parity between file and github get ---
setup_temp_dir
setup_nazgul_dir
INBOX="$TEST_DIR/nazgul/inbox"
seed_inbox "$INBOX"
# No config yet -> file provider. Capture the file-get shape first.
FILE_SHAPE=$(inbox_get "$INBOX" second.json | jq -cS 'keys')
create_config '.automation.heartbeat.inbox.provider = "github"' '.connectors.github.enabled = true'
export NAZGUL_TEST_GH_DB="$TEST_DIR/gh-db.json"
export NAZGUL_TEST_GH_LABELS="$TEST_DIR/gh-labels.json"
seed_gh_db
GH_SHAPE=$(inbox_get "$INBOX" 42 | jq -cS 'keys')
assert_eq "shape parity: file get exposes {title,body,priority,type}" "$FILE_SHAPE" '["body","priority","title","type"]'
assert_eq "shape parity: github get shape matches file get" "$GH_SHAPE" "$FILE_SHAPE"
teardown_temp_dir

export PATH="$BASE_PATH"
rm -rf "$FAKEBIN"

report_results
