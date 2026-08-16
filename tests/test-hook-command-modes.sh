#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.
#
# Test: every script hooks/hooks.json invokes DIRECTLY is executable. Those
# commands carry no interpreter prefix, so the executable bit is load-bearing:
# lose it and a hook stops firing silently. That regression happened inside
# FEAT-031 — scripts/pre-tool-guard.sh dropped 755 -> 644, disabling the
# destructive-command guard entirely, and the 109-file suite stayed green
# (issue #204).
#
# The population is derived from hooks/hooks.json itself, never authored: an
# authored list is what failed, and a newly registered hook is covered the day it
# is registered. The generic form ("assert every file's mode") is deliberately
# NOT built — tests/run-tests.sh invokes test files as `bash "$test_file"`, so
# their modes are genuinely cosmetic.
#
# Two arms, both required. FS is the working tree's mode, what a running plugin
# executes. INDEX is git's recorded mode, what a fresh clone receives: a file
# chmod'd locally but committed 644 passes FS and still ships broken.
TEST_NAME="test-hook-command-modes"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

# hm_commands <hooks.json> — every `command` string in the file, at any depth.
hm_commands() {
  jq -r '[.. | objects | select(has("command")) | .command] | .[]' "$1" 2>/dev/null
}

# hm_direct_target <command> — the plugin-root-relative path invoked directly, or
# nonzero when interpreted (`bash x.sh`) or not a plugin script: mode is moot there.
hm_direct_target() {
  local cmd="$1" head
  case "$cmd" in
    '"'*) head="${cmd#\"}"; head="${head%%\"*}" ;;
    *)    head="${cmd%%[[:space:]]*}" ;;
  esac
  case "$head" in
    bash|sh|/bin/sh|/bin/bash|zsh|env) return 1 ;;
  esac
  case "$head" in
    '${CLAUDE_PLUGIN_ROOT}/'*) printf '%s' "${head#\$\{CLAUDE_PLUGIN_ROOT\}/}" ;;
    *) return 1 ;;
  esac
}

if [ ! -r "$HOOKS_JSON" ]; then
  _fail "hooks/hooks.json is readable" "no file at $HOOKS_JSON — the population has no source"
  report_results
  exit $?
fi
if ! jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  _fail "hooks/hooks.json parses as JSON" "jq could not parse it — the population cannot be derived"
  report_results
  exit $?
fi

GIT_AVAILABLE=0
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 && GIT_AVAILABLE=1

HM_SCANNED=0; HM_CHECKED=0; HM_SKIPPED=0; HM_FINDINGS=0
HM_INTERPRETED=0; HM_NOT_PLUGIN=0; HM_ABSENT=0; HM_ALREADY=0
HM_TARGETS=""

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  HM_SCANNED=$((HM_SCANNED + 1))
  target=$(hm_direct_target "$cmd") || {
    HM_SKIPPED=$((HM_SKIPPED + 1))
    case "$cmd" in
      bash*|sh*|/bin/*|zsh*|env*) HM_INTERPRETED=$((HM_INTERPRETED + 1)) ;;
      *) HM_NOT_PLUGIN=$((HM_NOT_PLUGIN + 1)) ;;
    esac
    _skip "hook-mode: '$cmd' is not a direct plugin-script invocation — mode not load-bearing"
    continue
  }
  # Two commands can name one script (webhook-forward.sh runs for `stop` and for
  # `compact`); the second entry is scanned and accounted, not silently dropped.
  case $'\n'"$HM_TARGETS" in
    *$'\n'"$target"$'\n'*)
      HM_SKIPPED=$((HM_SKIPPED + 1)); HM_ALREADY=$((HM_ALREADY + 1)); continue ;;
  esac
  HM_TARGETS="${HM_TARGETS}${target}"$'\n'

  if [ ! -e "$REPO_ROOT/$target" ]; then
    HM_SKIPPED=$((HM_SKIPPED + 1)); HM_ABSENT=$((HM_ABSENT + 1)); HM_FINDINGS=$((HM_FINDINGS + 1))
    _fail "hook-mode [$target]: the registered script exists" \
      "hooks/hooks.json invokes it and there is no file at $REPO_ROOT/$target"
    continue
  fi

  HM_CHECKED=$((HM_CHECKED + 1))
  if [ -x "$REPO_ROOT/$target" ]; then
    _pass "hook-mode [$target]: executable in the working tree"
  else
    HM_FINDINGS=$((HM_FINDINGS + 1))
    _fail "hook-mode [$target]: executable in the working tree" \
      "hooks/hooks.json invokes it with no interpreter prefix, so a non-executable mode disables the hook silently" \
      "  fix: chmod +x $target"
  fi

  if [ "$GIT_AVAILABLE" -ne 1 ]; then
    _skip "hook-mode [$target]: not a git checkout — the committed mode was not checked"
    continue
  fi
  INDEX_MODE=$(git -C "$REPO_ROOT" ls-files -s -- "$target" 2>/dev/null | awk '{print $1}')
  if [ -z "$INDEX_MODE" ]; then
    _skip "hook-mode [$target]: untracked — the committed mode was not checked"
  elif [ "$INDEX_MODE" = "100755" ]; then
    _pass "hook-mode [$target]: committed executable (a fresh clone receives 100755)"
  else
    HM_FINDINGS=$((HM_FINDINGS + 1))
    _fail "hook-mode [$target]: committed executable (a fresh clone receives 100755)" \
      "git records mode $INDEX_MODE — the working tree may be executable while every clone is not" \
      "  fix: git update-index --chmod=+x $target"
  fi
done < <(hm_commands "$HOOKS_JSON")

echo "  hook-mode-scan: ${HM_SCANNED} scanned, ${HM_SKIPPED} skipped (interpreted=${HM_INTERPRETED}, not-a-plugin-script=${HM_NOT_PLUGIN}, already-checked=${HM_ALREADY}, absent=${HM_ABSENT}), ${HM_CHECKED} checked, ${HM_FINDINGS} findings"
assert_eq "hook-mode-scan: coverage accounting adds up (N == M + K)" \
  "$HM_SCANNED" "$((HM_SKIPPED + HM_CHECKED))"

# K > 0 floor: a hooks.json that parses to zero direct invocations is NOTHING
# CHECKED, not a clean run. The floor sits well under the registered set.
HOOK_FLOOR="${NAZGUL_HOOK_COMMAND_FLOOR:-10}"
if [ "$HM_CHECKED" -ge "$HOOK_FLOOR" ]; then
  _pass "hook-mode-scan: the population came from hooks.json and is non-empty ($HM_CHECKED >= $HOOK_FLOOR)"
else
  _fail "hook-mode-scan: the population came from hooks.json and is non-empty" \
    "only $HM_CHECKED direct invocation(s) derived from $HM_SCANNED command(s) — a broken extractor, not an empty hooks.json"
fi

# The two live cases the FEAT-031 regression ran through. If either stops being
# derived, the scan has stopped looking where the miss actually happened.
for known in scripts/pre-tool-guard.sh scripts/stop-hook.sh; do
  assert_contains "hook-mode-scan: the population still reaches $known" "$HM_TARGETS" "$known"
done

# The predicate, dogfooded against a hooks.json dirty by construction. The
# shipped set is clean, so a check exercised only against it can only pass.
HM_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-hook-modes-XXXXXX")
mkdir -p "$HM_SCRATCH/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HM_SCRATCH/scripts/dropped-bit.sh"
chmod 644 "$HM_SCRATCH/scripts/dropped-bit.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HM_SCRATCH/scripts/kept-bit.sh"
chmod 755 "$HM_SCRATCH/scripts/kept-bit.sh"
DOGFOOD_HITS=0; DOGFOOD_MISSES=0
for pair in "dropped-bit.sh:1" "kept-bit.sh:0"; do
  f="${pair%%:*}"; want="${pair##*:}"
  got=0; [ -x "$HM_SCRATCH/scripts/$f" ] || got=1
  if [ "$got" = "$want" ]; then DOGFOOD_HITS=$((DOGFOOD_HITS + 1)); else DOGFOOD_MISSES=$((DOGFOOD_MISSES + 1)); fi
done
assert_eq "dogfood: the -x predicate separates a 644 script from a 755 one" "$DOGFOOD_MISSES" "0"
assert_eq "dogfood: both synthetic modes were classified" "$DOGFOOD_HITS" "2"

# The extractor, dogfooded: a registered-but-missing script is a FINDING, and an
# interpreted command is a SKIP with a reason — the two must not collapse.
cat > "$HM_SCRATCH/hooks.json" <<'DIRTY'
{"hooks":{"PreToolUse":[{"hooks":[
  {"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/scripts/kept-bit.sh\""},
  {"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/scripts/kept-bit.sh\""},
  {"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/scripts/never-shipped.sh\""}
]}]}}
DIRTY
D_DIRECT=0; D_SKIP=0; D_ABSENT=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if t=$(hm_direct_target "$cmd"); then
    D_DIRECT=$((D_DIRECT + 1))
    [ -e "$HM_SCRATCH/$t" ] || D_ABSENT=$((D_ABSENT + 1))
  else
    D_SKIP=$((D_SKIP + 1))
  fi
done < <(hm_commands "$HM_SCRATCH/hooks.json")
assert_eq "dogfood: an interpreted command is skipped, not checked" "$D_SKIP" "1"
assert_eq "dogfood: both direct invocations are derived" "$D_DIRECT" "2"
assert_eq "dogfood: a registered-but-missing script is not silently absent" "$D_ABSENT" "1"
rm -rf "$HM_SCRATCH"

report_results
