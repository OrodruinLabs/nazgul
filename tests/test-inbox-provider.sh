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

report_results
