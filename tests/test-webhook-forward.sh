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

rm -rf "$FAKEBIN"

# --- Test 5: bash -n / shellcheck sanity (project convention) ---
bash -n "$WEBHOOK_SCRIPT" 2>/dev/null && _pass "bash -n clean: webhook-forward.sh" || _fail "bash -n clean: webhook-forward.sh" "syntax error in $WEBHOOK_SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WEBHOOK_SCRIPT" 2>/dev/null && _pass "shellcheck clean: webhook-forward.sh" || _fail "shellcheck clean: webhook-forward.sh" "shellcheck found issues in $WEBHOOK_SCRIPT"
else
  _pass "shellcheck clean: webhook-forward.sh (shellcheck not installed, skipped)"
fi

report_results
