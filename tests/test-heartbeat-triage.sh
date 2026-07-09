#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes explicitly

# Test: heartbeat-triage.sh — deterministic priority/age/filename selection
TEST_NAME="test-heartbeat-triage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/heartbeat-triage.sh"

run_pick() {
  PICK_OUT=$(heartbeat_pick "$1" 2>/dev/null) && PICK_EC=0 || PICK_EC=$?
}

mkcand() {
  # mkcand <inbox> <filename> <priority-json-or-empty> <body>
  local inbox="$1" name="$2" pri="$3" body="$4"
  if [ -n "$pri" ]; then
    jq -n --arg t "$name" --arg b "$body" --argjson p "$pri" \
      '{title:$t, body:$b, priority:$p, type:"feature"}' > "$inbox/$name"
  else
    jq -n --arg t "$name" --arg b "$body" \
      '{title:$t, body:$b, type:"feature"}' > "$inbox/$name"
  fi
}

# --- Test 1: explicit priority ascending — lowest number wins ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" a.json 3 "third"
mkcand "$INBOX" b.json 1 "first"
mkcand "$INBOX" c.json 2 "second"
run_pick "$INBOX"
assert_exit_code "priority: exit 0 with a winner" "$PICK_EC" 0
assert_eq "priority: lowest number wins" "$PICK_OUT" "b.json"
teardown_temp_dir

# --- Test 2: missing priority sorts last ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" with-pri.json 5 "has priority"
mkcand "$INBOX" no-pri.json "" "no priority field"
run_pick "$INBOX"
assert_exit_code "missing priority: exit 0 with a winner" "$PICK_EC" 0
assert_eq "missing priority: explicit priority beats missing" "$PICK_OUT" "with-pri.json"
teardown_temp_dir

# --- Test 3: equal priority -> oldest mtime wins ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" old.json 2 "older"
mkcand "$INBOX" new.json 2 "newer"
touch -t 202001010000 "$INBOX/old.json"
touch -t 202601010000 "$INBOX/new.json"
run_pick "$INBOX"
assert_exit_code "age: exit 0 with a winner" "$PICK_EC" 0
assert_eq "age: oldest mtime wins on priority tie" "$PICK_OUT" "old.json"
teardown_temp_dir

# --- Test 4: equal priority + equal mtime -> lowest filename wins ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" bbb.json 2 "b"
mkcand "$INBOX" aaa.json 2 "a"
touch -t 202301010000 "$INBOX/bbb.json"
touch -t 202301010000 "$INBOX/aaa.json"
run_pick "$INBOX"
assert_exit_code "filename: exit 0 with a winner" "$PICK_EC" 0
assert_eq "filename: lowest filename wins on full tie" "$PICK_OUT" "aaa.json"
teardown_temp_dir

# --- Test 5: deterministic — repeated pick over same fixture matches ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" a.json 3 "third"
mkcand "$INBOX" b.json 1 "first"
mkcand "$INBOX" c.json 2 "second"
run_pick "$INBOX"; FIRST="$PICK_OUT"; FIRST_EC="$PICK_EC"
assert_exit_code "deterministic: first pick exit 0" "$FIRST_EC" 0
run_pick "$INBOX"
assert_exit_code "deterministic: repeated pick exit 0" "$PICK_EC" 0
assert_eq "deterministic: repeated pick matches" "$PICK_OUT" "$FIRST"
teardown_temp_dir

# --- Test 6: empty / absent inbox -> non-zero, no output ("nothing actionable") ---
setup_temp_dir
EMPTY="$TEST_DIR/nazgul/inbox"; mkdir -p "$EMPTY"
run_pick "$EMPTY"
assert_exit_code "empty: non-zero exit" "$PICK_EC" 1
assert_eq "empty: no output" "$PICK_OUT" ""
run_pick "$TEST_DIR/nazgul/nope"
assert_exit_code "absent: non-zero exit" "$PICK_EC" 1
assert_eq "absent: no output" "$PICK_OUT" ""
teardown_temp_dir

# --- Test 7: metacharacter title/body carried as DATA (no expansion, no eval) ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
DANGER='$(touch SENTINEL_PWNED); `echo owned`; ; rm -rf /'
mkcand "$INBOX" danger.json 1 "$DANGER"
mkcand "$INBOX" other.json 9 "harmless"
run_pick "$INBOX"
assert_exit_code "metachar: exit 0 with a winner" "$PICK_EC" 0
assert_eq "metachar: dangerous candidate is selected verbatim" "$PICK_OUT" "danger.json"
assert_file_not_exists "metachar: no eval side effect in inbox" "$INBOX/SENTINEL_PWNED"
assert_file_not_exists "metachar: no eval side effect in cwd" "$SCRIPT_DIR/SENTINEL_PWNED"
teardown_temp_dir

# --- Test 8: non-numeric priority string sorts last (tonumber? // null fallback) ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" numeric-pri.json 2 "numeric priority"
mkcand "$INBOX" bad-pri.json '"abc"' "non-numeric priority"
run_pick "$INBOX"
assert_exit_code "non-numeric priority: exit 0 with a winner" "$PICK_EC" 0
assert_eq "non-numeric priority: numeric priority wins over non-numeric" "$PICK_OUT" "numeric-pri.json"
teardown_temp_dir

# --- Test 9: path-traversal id guard rejects ids containing a path separator ---
setup_temp_dir
INBOX="$TEST_DIR/nazgul/inbox"; mkdir -p "$INBOX"
mkcand "$INBOX" good.json 1 "safe candidate"
_ORIG_INBOX_LIST=$(declare -f inbox_list)
inbox_list() { printf '%s\n' "../evil.json" "sub/dir.json" 'back\slash.json' "good.json"; }
run_pick "$INBOX"
eval "$_ORIG_INBOX_LIST"
assert_exit_code "traversal: safe candidate still wins, exit 0" "$PICK_EC" 0
assert_eq "traversal: path-separator ids skipped, safe id selected" "$PICK_OUT" "good.json"

inbox_list() { printf '%s\n' "../evil.json" "sub/dir.json"; }
run_pick "$INBOX"
eval "$_ORIG_INBOX_LIST"
assert_exit_code "traversal: all-malicious inbox is nothing actionable" "$PICK_EC" 1
assert_eq "traversal: all-malicious inbox has no output" "$PICK_OUT" ""
teardown_temp_dir

report_results
