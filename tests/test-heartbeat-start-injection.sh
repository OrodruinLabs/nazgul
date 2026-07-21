#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e; assertions check return codes/content explicitly

# Test: heartbeat.sh _hb_start's REAL default branch must not let an embedded
# `"` or a real newline in the objective break out into apply-start-flags.sh's
# flag scan.
TEST_NAME="test-heartbeat-start-injection"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Fake `claude` placed first on PATH: records argv instead of launching a real
# loop, so the REAL default _hb_start branch (no NAZGUL_HEARTBEAT_START_CMD)
# can be exercised safely. Uses its own colon-free mktemp dir, NOT a path under
# $TEST_DIR — $TEST_DIR's name contains a literal ":" (setup_temp_dir's
# "nazgul:test-XXXXXX" pattern), which corrupts PATH parsing (":" is the PATH
# separator) and would silently fall through to the REAL claude binary.
write_fake_claude() {
  FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
  cat > "$FAKEBIN/claude" << 'EOF'
#!/usr/bin/env bash
# _hb_start invokes exactly `claude -p "<prompt>"` (2 argv elements). Capture
# each positionally, NOT newline-joined — the prompt itself may legitimately
# contain embedded newlines, which a `printf '%s\n' "$@"` dump would make
# indistinguishable from the argv separator.
printf '%s' "$1" > "$NAZGUL_TEST_CLAUDE_ARGV.flag"
printf '%s' "$2" > "$NAZGUL_TEST_CLAUDE_ARGV.prompt"
EOF
  chmod +x "$FAKEBIN/claude"
}

# Reproduces apply-start-flags.sh's own quoted-span strip (scripts/apply-start-flags.sh:13).
strip_quoted_spans() {
  printf '%s' "$1" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g'
}

# Reproduces apply-start-flags.sh's own flag classification loop (lines 17-25).
scan_has_flag() {
  local scan="$1" needle="$2" tok
  for tok in $scan; do
    [ "$tok" = "$needle" ] && return 0
  done
  return 1
}

# Runs one full malicious-title scenario end to end: crafts an inbox
# candidate, drives the REAL default _hb_start path via a fake claude on
# PATH, and asserts the injected flags never survive apply-start-flags.sh's
# quoted-span strip (locally reproduced and via the real script).
run_injection_scenario() {
  local label="$1" title="$2"

  setup_temp_dir
  setup_nazgul_dir
  create_config '.automation.heartbeat.enabled = true'
  mkdir -p "$TEST_DIR/nazgul/inbox"
  jq -n --arg t "$title" '{title:$t, body:"do the thing", priority:1}' \
    > "$TEST_DIR/nazgul/inbox/cand.json"
  write_fake_claude
  export PATH="$FAKEBIN:$PATH"
  export NAZGUL_TEST_CLAUDE_ARGV="$TEST_DIR/claude-argv.txt"
  unset NAZGUL_HEARTBEAT_START_CMD 2>/dev/null || true

  # Safety gate: refuse to proceed unless PATH actually resolves to the fake
  # claude — never risk falling through to a real `claude -p` launch.
  local resolved_claude
  resolved_claude=$(command -v claude)
  if [ "$resolved_claude" != "$FAKEBIN/claude" ]; then
    _fail "[$label] PATH resolves to the fake claude (safety gate)" \
      "expected: '$FAKEBIN/claude'" "  actual: '$resolved_claude'"
    teardown_temp_dir
    rm -rf "$FAKEBIN"
    report_results
    exit 1
  fi
  _pass "[$label] PATH resolves to the fake claude (safety gate)"

  bash "$REPO_ROOT/scripts/heartbeat.sh"

  assert_file_exists "[$label] malicious tick: fake claude was invoked" "$NAZGUL_TEST_CLAUDE_ARGV.prompt"
  assert_eq "[$label] captured -p flag argv" "$(cat "$NAZGUL_TEST_CLAUDE_ARGV.flag")" "-p"

  local startcmd argstr scan maxnum
  startcmd=$(cat "$NAZGUL_TEST_CLAUDE_ARGV.prompt")
  assert_contains "[$label] captured command targets /nazgul:start" "$startcmd" "/nazgul:start"

  argstr="${startcmd#/nazgul:start }"
  scan=$(strip_quoted_spans "$argstr")

  if scan_has_flag "$scan" "--max"; then
    assert_eq "[$label] injected --max does not survive as a bare flag token" "found" "not found"
  else
    assert_eq "[$label] injected --max does not survive as a bare flag token" "not found" "not found"
  fi

  if scan_has_flag "$scan" "--afk"; then
    assert_eq "[$label] injected --afk does not survive as a bare flag token" "found" "not found"
  else
    assert_eq "[$label] injected --afk does not survive as a bare flag token" "not found" "not found"
  fi

  maxnum=$(printf '%s\n' "$scan" | grep -oE -- '--max[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  assert_eq "[$label] no numeric --max value extractable from the post-strip scan" "$maxnum" ""

  # End-to-end through the real downstream consumer: max_iterations must
  # survive unchanged, proving the injection is inert for the actual
  # config-mutating path.
  local cfg="$TEST_DIR/downstream-config.json"
  cp "$REPO_ROOT/templates/config.json" "$cfg"
  jq '.max_iterations = 40' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  bash "$REPO_ROOT/scripts/apply-start-flags.sh" "$cfg" "$argstr" >/dev/null
  assert_eq "[$label] downstream apply-start-flags.sh: max_iterations unaffected by injection" \
    "$(jq -r .max_iterations "$cfg")" "40"

  unset NAZGUL_TEST_CLAUDE_ARGV
  teardown_temp_dir
  rm -rf "$FAKEBIN"
}

run_injection_scenario "quote-breakout" 'evil" --max 999999 --afk "x'
run_injection_scenario "newline-breakout" $'evil\n--max 999999 --afk x'

# --- auto_start.{mode,parallel} must actually be read, not hardcoded ---
run_auto_start_scenario() {
  local label="$1" mode="$2" parallel="$3" expect_present="$4" expect_absent="$5"

  setup_temp_dir
  setup_nazgul_dir
  create_config ".automation.heartbeat.enabled = true | .automation.heartbeat.auto_start.mode = \"$mode\" | .automation.heartbeat.auto_start.parallel = $parallel"
  mkdir -p "$TEST_DIR/nazgul/inbox"
  jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
  write_fake_claude
  export PATH="$FAKEBIN:$PATH"
  export NAZGUL_TEST_CLAUDE_ARGV="$TEST_DIR/claude-argv.txt"
  unset NAZGUL_HEARTBEAT_START_CMD 2>/dev/null || true

  local resolved_claude
  resolved_claude=$(command -v claude)
  if [ "$resolved_claude" != "$FAKEBIN/claude" ]; then
    _fail "[$label] PATH resolves to the fake claude (safety gate)" \
      "expected: '$FAKEBIN/claude'" "  actual: '$resolved_claude'"
    teardown_temp_dir
    rm -rf "$FAKEBIN"
    report_results
    exit 1
  fi

  bash "$REPO_ROOT/scripts/heartbeat.sh"
  local startcmd
  startcmd=$(cat "$NAZGUL_TEST_CLAUDE_ARGV.prompt")
  # Not assert_contains: its grep -qF chokes on a needle starting with "--"
  # (grep parses it as an unrecognized option). Plain case-pattern match instead.
  case "$startcmd" in
    *"$expect_present"*) assert_eq "[$label] $expect_present present" "found" "found" ;;
    *) assert_eq "[$label] $expect_present present" "not found" "found" ;;
  esac
  case "$startcmd" in
    *"$expect_absent"*) assert_eq "[$label] $expect_absent absent" "found" "not found" ;;
    *) assert_eq "[$label] $expect_absent absent" "not found" "not found" ;;
  esac

  unset NAZGUL_TEST_CLAUDE_ARGV
  teardown_temp_dir
  rm -rf "$FAKEBIN"
}

run_auto_start_scenario "default mode/parallel" "yolo" "true" "--yolo" "--afk"
run_auto_start_scenario "mode=afk" "afk" "true" "--afk" "--yolo"
run_auto_start_scenario "mode=hitl" "hitl" "false" "--hitl" "--parallel"
run_auto_start_scenario "parallel=false omits --parallel" "yolo" "false" "--yolo" "--parallel"

# --- auto_start.parallel=false must NOT be silently treated as absent (the
# `//` footgun: jq's // substitutes on false, not just null/missing) ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true | .automation.heartbeat.auto_start.mode = "yolo" | .automation.heartbeat.auto_start.parallel = false'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
write_fake_claude
export PATH="$FAKEBIN:$PATH"
export NAZGUL_TEST_CLAUDE_ARGV="$TEST_DIR/claude-argv.txt"
unset NAZGUL_HEARTBEAT_START_CMD 2>/dev/null || true
resolved_claude=$(command -v claude)
if [ "$resolved_claude" != "$FAKEBIN/claude" ]; then
  _fail "[explicit parallel=false] PATH resolves to the fake claude (safety gate)" \
    "expected: '$FAKEBIN/claude'" "  actual: '$resolved_claude'"
  teardown_temp_dir
  rm -rf "$FAKEBIN"
  report_results
  exit 1
fi
bash "$REPO_ROOT/scripts/heartbeat.sh"
startcmd=$(cat "$NAZGUL_TEST_CLAUDE_ARGV.prompt")
case "$startcmd" in
  *"--parallel"*) assert_eq "[explicit parallel=false] --parallel absent (opt-out honored, not silently defaulted true)" "found" "not found" ;;
  *) assert_eq "[explicit parallel=false] --parallel absent (opt-out honored, not silently defaulted true)" "not found" "not found" ;;
esac
unset NAZGUL_TEST_CLAUDE_ARGV
teardown_temp_dir
rm -rf "$FAKEBIN"

report_results
