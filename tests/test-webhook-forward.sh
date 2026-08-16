#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — the script under test always returns 0 (best-effort).

# Test: scripts/webhook-forward.sh — MF-032. Verifies custom header values
# containing spaces (e.g. "Authorization: Bearer abc 123") survive intact
# into the curl invocation as ONE argv token, via a PATH-shimmed mock `curl`
# that captures its argv verbatim (one entry per line) — NO network traffic.
TEST_NAME="test-webhook-forward"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

WEBHOOK_SCRIPT="$REPO_ROOT/scripts/webhook-forward.sh"

# Fake `curl` placed first on PATH. Captures argv (one per line, via
# NAZGUL_TEST_CURL_ARGV) and stdin (via NAZGUL_TEST_CURL_STDIN); never
# touches the network.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
write_fake_curl() {
  cat > "$FAKEBIN/curl" << 'EOF'
#!/usr/bin/env bash
: > "$NAZGUL_TEST_CURL_ARGV"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$NAZGUL_TEST_CURL_ARGV"
done
exit 0
EOF
  chmod +x "$FAKEBIN/curl"
}
write_fake_curl
export PATH="$FAKEBIN:$PATH"

# Safety gate: refuse to proceed unless PATH resolves to the fake curl.
resolved_curl=$(command -v curl)
if [ "$resolved_curl" != "$FAKEBIN/curl" ]; then
  _fail "PATH resolves to the fake curl (safety gate)" "expected: '$FAKEBIN/curl'" "  actual: '$resolved_curl'"
  rm -rf "$FAKEBIN"
  report_results
  exit 1
fi
_pass "PATH resolves to the fake curl (safety gate)"

# Runs webhook-forward.sh with the given event type, against a config with
# the given jq overrides applied on top of a minimal enabled webhook config.
run_webhook() {
  local event="$1"
  export NAZGUL_TEST_CURL_ARGV="$TEST_DIR/curl-argv.txt"
  : > "$NAZGUL_TEST_CURL_ARGV"
  CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$WEBHOOK_SCRIPT" "$event" >/dev/null 2>&1
}

# --- Test 1: MF-032 — a header value containing a space survives as ONE
# argv token, immediately following its own "-H" flag. ---
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]' \
  '.webhooks.headers = {"Authorization": "Bearer abc 123"}'
run_webhook "Stop"
ARGV_FILE="$NAZGUL_TEST_CURL_ARGV"
assert_file_exists "MF-032: fake curl captured argv" "$ARGV_FILE"
assert_file_contains "MF-032: header value with space is one intact argv line" "$ARGV_FILE" "Authorization: Bearer abc 123"
# The line immediately preceding the header value must be its own "-H" flag,
# proving they're paired as a single (-H, "key: value with space") pair
# rather than "Bearer"/"123" having been word-split into separate argv
# entries that could land anywhere (including being mistaken for another flag).
mapfile -t ARGV_LINES < "$ARGV_FILE"
LINE_BEFORE=""
for i in "${!ARGV_LINES[@]}"; do
  if [ "${ARGV_LINES[$i]}" = "Authorization: Bearer abc 123" ] && [ "$i" -gt 0 ]; then
    LINE_BEFORE="${ARGV_LINES[$((i - 1))]}"
    break
  fi
done
assert_eq "MF-032: header value is paired with its own -H flag" "$LINE_BEFORE" "-H"
teardown_temp_dir

# --- Test 2: multiple headers, one with a space, one without — both survive
# as intact, distinct argv tokens. ---
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]' \
  '.webhooks.headers = {"Authorization": "Bearer abc 123", "X-Nazgul-Source": "nazgul"}'
run_webhook "Stop"
assert_file_contains "MF-032: header-with-space intact (multi-header case)" "$NAZGUL_TEST_CURL_ARGV" "Authorization: Bearer abc 123"
assert_file_contains "MF-032: header-without-space intact (multi-header case)" "$NAZGUL_TEST_CURL_ARGV" "X-Nazgul-Source: nazgul"
teardown_temp_dir

# --- Test 3: no custom headers configured -> curl still invoked (payload
# posted), just without extra -H flags beyond Content-Type. ---
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]'
run_webhook "Stop"
assert_file_contains "no custom headers: curl still invoked" "$NAZGUL_TEST_CURL_ARGV" "Content-Type: application/json"
assert_file_contains "no custom headers: webhook URL present" "$NAZGUL_TEST_CURL_ARGV" "https://example.invalid/hook"
teardown_temp_dir

# --- Test 4: event not in the configured events list -> curl never invoked
# (argv file stays empty/absent). ---
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["PostCompact"]' \
  '.webhooks.headers = {"Authorization": "Bearer abc 123"}'
export NAZGUL_TEST_CURL_ARGV="$TEST_DIR/curl-argv-unused.txt"
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$WEBHOOK_SCRIPT" "Stop" >/dev/null 2>&1
assert_file_not_exists "event not configured: curl never invoked" "$NAZGUL_TEST_CURL_ARGV"
teardown_temp_dir

# --- Test 5 (TASK-007/D4): curl carries --connect-timeout 2 alongside the
# pre-existing --max-time 5 (attributed to 53cc7cb, FEAT-017); this does NOT
# fix the reported 16-24s stalls (those are Defect 1's CPU starvation), it
# only bounds the connect phase distinct from the overall wall-clock bound. ---
assert_flag_value() {
  local name="$1" file="$2" flag="$3" value="$4"
  mapfile -t lines < "$file"
  local found=0
  for i in "${!lines[@]}"; do
    if [ "${lines[$i]}" = "$flag" ] && [ "$((i + 1))" -lt "${#lines[@]}" ] && [ "${lines[$((i + 1))]}" = "$value" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 1 ]; then
    _pass "$name"
  else
    _fail "$name" "expected '$flag' immediately followed by '$value' in: $file"
  fi
}

setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]'
run_webhook "Stop"
assert_file_exists "TASK-007: fake curl captured argv" "$NAZGUL_TEST_CURL_ARGV"
assert_flag_value "TASK-007: --connect-timeout 2 present" "$NAZGUL_TEST_CURL_ARGV" "--connect-timeout" "2"
assert_flag_value "TASK-007: --max-time 5 unchanged (pre-existing bound)" "$NAZGUL_TEST_CURL_ARGV" "--max-time" "5"
teardown_temp_dir

# D4: fire-and-forget must NOT ship. Static check on the curl invocation
# block for subshell-backgrounding (`) &`), `disown`, PID-capture (`$!`), or
# a bare trailing `&` on the statement itself — the mechanical form of
# "asserted by the absence of those forms in the diff". The trailing-&
# check is end-of-line anchored, not a substring search, so "2>&1" (which
# is legitimate in this block) can't trip it.
CURL_BLOCK=$(awk '/^curl -s -X POST/,/WEBHOOK_URL.*\|\| true/' "$WEBHOOK_SCRIPT")
if [ -n "$CURL_BLOCK" ]; then
  _pass "TASK-007/D4: CURL_BLOCK extraction found the curl invocation (anchors matched)"
else
  _fail "TASK-007/D4: CURL_BLOCK extraction found the curl invocation (anchors matched)" "awk range matched zero lines — the checks below would trivially pass against an empty string"
fi
assert_not_contains "TASK-007/D4: curl invocation not subshell-backgrounded" "$CURL_BLOCK" ") &"
assert_not_contains "TASK-007/D4: curl invocation does not use disown" "$CURL_BLOCK" "disown"
assert_not_contains "TASK-007/D4: curl invocation does not capture a background PID" "$CURL_BLOCK" '$!'
if grep -qE '&[[:space:]]*$' <<<"$CURL_BLOCK"; then
  _fail "TASK-007/D4: curl invocation not bare-&-backgrounded" "found a bare trailing '&' as the last token of a line in: '${CURL_BLOCK:0:200}'"
else
  _pass "TASK-007/D4: curl invocation not bare-&-backgrounded"
fi

# --- Test 7 (RW-B, FEAT-031 rework): the payload is counted by the ONE shared
# parser, so it learns CANCELLED and reads frontmatter (a private grep did not). ---
curl_payload() {
  # jq -n pretty-prints, so the single -d argv token spans many captured lines:
  # take everything strictly between the "-d" flag and the next "--max-time".
  awk '$0 == "--max-time" { p = 0 } p == 1 { print } $0 == "-d" { p = 1 }' \
    "$NAZGUL_TEST_CURL_ARGV"
}

setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]'
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "READY"
run_webhook "Stop"
PAYLOAD=$(curl_payload) || PAYLOAD=""
if [ -n "$PAYLOAD" ]; then
  _pass "cancelled census: the curl payload was captured (anchor matched)"
else
  _fail "cancelled census: the curl payload was captured (anchor matched)" \
    "no argv token followed '-d' — the assertions below would be vacuous"
fi
assert_eq "cancelled census: frontmatter DONE is counted (shared parser, not a legacy grep)" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_done')" "1"
assert_eq "cancelled census: tasks_cancelled is reported" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_cancelled')" "1"
assert_eq "cancelled census: tasks_total unchanged in meaning" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_total')" "3"
teardown_temp_dir

# An all-terminal objective must reconcile: done + cancelled == total, so a
# downstream consumer never sees a completed objective as forever-incomplete.
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]'
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
run_webhook "Stop"
PAYLOAD=$(curl_payload) || PAYLOAD=""
assert_eq "cancelled census: done + cancelled == total for a completed objective" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_done + .tasks_cancelled == .tasks_total')" "true"
teardown_temp_dir

# Legacy list-item manifests must keep working — the shared parser is a
# superset of the grep it replaced, not a swap of one format for another.
setup_temp_dir
setup_nazgul_dir
create_config \
  '.webhooks.enabled = true' \
  '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["Stop"]'
create_task_file_legacy "TASK-001" "DONE"
create_task_file_legacy "TASK-002" "CANCELLED"
run_webhook "Stop"
PAYLOAD=$(curl_payload) || PAYLOAD=""
assert_eq "legacy format: DONE still counted" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_done')" "1"
assert_eq "legacy format: CANCELLED still counted" \
  "$(printf '%s' "$PAYLOAD" | jq -r '.tasks_cancelled')" "1"
teardown_temp_dir

rm -rf "$FAKEBIN"

# --- Test 6: bash -n / shellcheck sanity (project convention) ---
bash -n "$WEBHOOK_SCRIPT" 2>/dev/null && _pass "bash -n clean: webhook-forward.sh" || _fail "bash -n clean: webhook-forward.sh" "syntax error in $WEBHOOK_SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WEBHOOK_SCRIPT" 2>/dev/null && _pass "shellcheck clean: webhook-forward.sh" || _fail "shellcheck clean: webhook-forward.sh" "shellcheck found issues in $WEBHOOK_SCRIPT"
else
  _skip "shellcheck clean: webhook-forward.sh (shellcheck not installed, skipped)"
fi

report_results
