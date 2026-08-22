#!/usr/bin/env bash
set -euo pipefail

# Test: lean-comments-guard.sh blocks comment bloat and allows lean code.
TEST_NAME="test-lean-comments-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/lean-comments-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A project config with the guard enabled (default threshold 2).
mkdir -p "$TMP/proj/nazgul"
echo '{"guards":{"lean_comments":true,"max_consecutive_comment_lines":2}}' > "$TMP/proj/nazgul/config.json"
ENABLED_CONFIG="$TMP/proj/nazgul/config.json"

# --check exit code helper (does not depend on CLAUDE_PROJECT_DIR).
check_ec() {
  local file="$1" cfg="$2"
  NAZGUL_CONFIG="$cfg" bash "$GUARD" --check "$file" >/dev/null 2>&1
  echo $?
}
check_out() {
  local file="$1" cfg="$2"
  NAZGUL_CONFIG="$cfg" bash "$GUARD" --check "$file" 2>&1 || true
}

write_file() { printf '%s' "$2" > "$TMP/$1"; }

# BAD: a comment that justifies the line under it (rule d)
write_file bad_restate.cs 'public int Build(string method, List<string> requests) {
    // Pre-size to avoid resizes: prefix (~20) + method + per-token avg (~20) + suffix (~10).
    var sb = new StringBuilder(method.Length + requests.Count * 20 + 32);
    return sb.Length;
}
'
assert_exit_code "blocks restate/micro-opt comment" "$(check_ec "$TMP/bad_restate.cs" "$ENABLED_CONFIG")" 2
assert_contains "restate message" "$(check_out "$TMP/bad_restate.cs" "$ENABLED_CONFIG")" "NAZGUL LEAN-COMMENTS"

# BAD: banner / separator comment (rule c)
write_file bad_banner.cs 'public class Foo {
    // ── Helpers ──────────────
    void A() {}
}
'
assert_exit_code "blocks banner comment" "$(check_ec "$TMP/bad_banner.cs" "$ENABLED_CONFIG")" 2
assert_contains "banner message" "$(check_out "$TMP/bad_banner.cs" "$ENABLED_CONFIG")" "banner/separator"

# Also block an ASCII banner.
write_file bad_banner2.ts '// ============================
const x = 1;
'
assert_exit_code "blocks ascii banner comment" "$(check_ec "$TMP/bad_banner2.ts" "$ENABLED_CONFIG")" 2

# BAD: run of 3+ consecutive line comments (rule a)
write_file bad_run.ts 'function f() {
  // step one we do this
  // step two we do that
  // step three we finish
  return 1;
}
'
assert_exit_code "blocks 3+ comment run" "$(check_ec "$TMP/bad_run.ts" "$ENABLED_CONFIG")" 2
assert_contains "comment-run message" "$(check_out "$TMP/bad_run.ts" "$ENABLED_CONFIG")" "consecutive line comments"

# BAD: <remarks> on a private member (rule b)
write_file bad_remarks.cs 'public class V {
    /// <summary>Cache the venue token.</summary>
    /// <remarks>
    /// This caches the token so we avoid recomputing it on every call.
    /// </remarks>
    private string BuildToken() => _token;
}
'
assert_exit_code "blocks <remarks> on private member" "$(check_ec "$TMP/bad_remarks.cs" "$ENABLED_CONFIG")" 2
assert_contains "doc-on-nonpublic message" "$(check_out "$TMP/bad_remarks.cs" "$ENABLED_CONFIG")" "non-public/test member"

# BAD: multi-paragraph docstring on a private Python def (rule b)
write_file bad_doc.py 'def _helper(x):
    """Compute the thing.

    This paragraph explains way too much about the internals.
    """
    return x
'
assert_exit_code "blocks multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc.py" "$ENABLED_CONFIG")" 2

# GOOD: a documented API plus a single quirk note is lean
write_file good.cs 'public interface IVenue {
    /// <summary>One subscribe frame covering all requests, or null if the venue cannot batch this set.</summary>
    SubscribeFrame? BuildSubscribe(IReadOnlyList<Request> requests);
}

public class Pinger {
    async Task Ping() {
        var sb = new StringBuilder(64);
        // Binance closes above 5 inbound msgs/sec; 200 ms gives 5 msg/s with margin.
        await Task.Delay(200);
    }
}
'
assert_exit_code "allows public doc + quirk comment" "$(check_ec "$TMP/good.cs" "$ENABLED_CONFIG")" 0

# ALLOWED: license header run is exempt
write_file good_license.cs '// Copyright 2026 Orodruin Labs
// Licensed under the MIT License.
// SPDX-License-Identifier: MIT
namespace Foo {}
'
assert_exit_code "allows license header run" "$(check_ec "$TMP/good_license.cs" "$ENABLED_CONFIG")" 0

# ALLOWED: single-line docstring on a public Python def
write_file good.py 'def compute(x):
    """Return x doubled."""
    return x * 2
'
assert_exit_code "allows single-line public docstring" "$(check_ec "$TMP/good.py" "$ENABLED_CONFIG")" 0

# Opt-out must be a no-op even for a file with a real finding
echo '{"guards":{"lean_comments":false}}' > "$TMP/proj/nazgul/disabled.json"
assert_exit_code "no-op when lean_comments=false" "$(check_ec "$TMP/bad_banner.cs" "$TMP/proj/nazgul/disabled.json")" 0

# Tunable threshold: raising max allows a longer run
echo '{"guards":{"lean_comments":true,"max_consecutive_comment_lines":5}}' > "$TMP/proj/nazgul/loose.json"
assert_exit_code "respects raised max_consecutive_comment_lines" "$(check_ec "$TMP/bad_run.ts" "$TMP/proj/nazgul/loose.json")" 0

# Non-source file is never inspected
write_file notes.md '// a
// b
// c
// d
'
assert_exit_code "ignores non-source files" "$(check_ec "$TMP/notes.md" "$ENABLED_CONFIG")" 0

# Hook mode: Write JSON on stdin blocks a banner
hook_ec() {
  local json="$1"
  printf '%s' "$json" | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$GUARD" >/dev/null 2>&1
  echo $?
}
echo '{"guards":{"lean_comments":true,"max_consecutive_comment_lines":2}}' > "$ENABLED_CONFIG"
ec=$(hook_ec '{"tool_name":"Write","tool_input":{"file_path":"/x/Foo.cs","content":"class A {\n    // ── Helpers ──────────────\n    void B(){}\n}\n"}}')
assert_exit_code "hook blocks banner on Write" "$ec" 2

# Hook mode: Edit JSON with a clean one-line quirk comment is allowed.
ec=$(hook_ec '{"tool_name":"Edit","tool_input":{"file_path":"/x/a.ts","new_string":"// Binance closes above 5 msgs/sec; 200ms gives margin.\nawait delay(200);"}}')
assert_exit_code "hook allows quirk comment on Edit" "$ec" 0

# Hook mode: no project config => not a Nazgul project => allow.
ec=$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/Foo.cs","content":"// a\n// b\n// c\n"}}' \
  | CLAUDE_PROJECT_DIR="$TMP/nonexistent" bash "$GUARD" >/dev/null 2>&1; echo $?)
assert_exit_code "hook no-op without project config" "$ec" 0

# Review-driven regression coverage (PR #39 bot feedback)

# BAD: triple-single-quote multi-paragraph docstring on private def
write_file bad_doc_sq.py "def _helper(x):
    '''Compute the thing.

    This second paragraph is bloat.
    '''
    return x
"
assert_exit_code "blocks ''' multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc_sq.py" "$ENABLED_CONFIG")" 2

# BAD: prefixed (r\"\"\") multi-paragraph docstring on private def
write_file bad_doc_prefix.py 'def _helper(x):
    r"""Compute the thing.

    Second paragraph, still bloat.
    """
    return x
'
assert_exit_code "blocks prefixed multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc_prefix.py" "$ENABLED_CONFIG")" 2

# ALLOWED: long SINGLE-paragraph /// summary on a private member
# Regression: line count alone (former cnt>=6) must not flag a single paragraph.
write_file good_long_summary.cs 'public class V {
    /// <summary>
    /// Resolves the venue token from cache, refreshing it from the upstream
    /// identity provider when the cached copy is missing or has expired, and
    /// returns the bearer string ready to attach to an outbound request without
    /// any additional formatting required by the caller at the call site here.
    /// </summary>
    private string BuildToken() => _token;
}
'
assert_exit_code "allows long single-paragraph private summary" "$(check_ec "$TMP/good_long_summary.cs" "$ENABLED_CONFIG")" 0

# BAD: license keyword in a MID-FILE comment run is NOT exempt
write_file bad_midfile_license.ts 'export function f() {
  return 1;
}
// this run mentions the MIT License but is not a header
// second line of the mid-file run
// third line of the mid-file run
const x = 2;
'
assert_exit_code "mid-file license-keyword run still blocks" "$(check_ec "$TMP/bad_midfile_license.ts" "$ENABLED_CONFIG")" 2

# ALLOWED: two edits of <=2 comment lines each must not be joined into a
# phantom 3+ run.
ec=$(hook_ec '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.ts","edits":[{"new_string":"// one\n// two\nconst a=1;"},{"new_string":"// three\nconst b=2;"}]}}')
assert_exit_code "MultiEdit edits evaluated independently (no phantom run)" "$ec" 0

# BAD: a single MultiEdit edit that itself has a 3+ run still blocks
ec=$(hook_ec '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.ts","edits":[{"new_string":"const a=1;"},{"new_string":"// one\n// two\n// three\nconst b=2;"}]}}')
assert_exit_code "MultiEdit blocks a real in-edit run" "$ec" 2

# Shell coverage + coverage honesty (FEAT-028 TASK-012; TRD §5 row 1, §6).
# Every case above this line is C#/TS/Python — in a shell-first repository.

write_lines() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

BAD_SH="$TMP/body-run-6.sh"
GOOD_SH="$TMP/real-header-lib.sh"
write_lines "$BAD_SH" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  'resolve_batch() {' \
  '  # The batch is selected from READY tasks.' \
  '  # Dependencies must all be DONE.' \
  '  # File scopes must be disjoint.' \
  '  # Overlapping work waits for the next wave.' \
  '  # The configured parallel cap is never exceeded.' \
  '  # An empty batch is not dispatchable.' \
  '  return 0' \
  '}'
sed -n '1,46p' "$REPO_ROOT/scripts/lib/nazgul-root.sh" > "$GOOD_SH"

# A real PreToolUse Write envelope carrying the fixture's own bytes, so the
# write path is driven through the hook entry rather than a hand-built string.
write_envelope() {
  jq -n --arg p "$1" --rawfile c "$1" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'
}

assert_exit_code "shell: --check blocks a 6-line body comment run" "$(check_ec "$BAD_SH" "$ENABLED_CONFIG")" 2
assert_contains "shell: the finding names the run length" \
  "$(check_out "$BAD_SH" "$ENABLED_CONFIG")" "6 consecutive line comments"
assert_exit_code "shell: the write path blocks the same generated sample" "$(hook_ec "$(write_envelope "$BAD_SH")")" 2

assert_exit_code "shell: the live nazgul-root header passes --check" "$(check_ec "$GOOD_SH" "$ENABLED_CONFIG")" 0
assert_exit_code "shell: the live nazgul-root header passes the write path" \
  "$(hook_ec "$(write_envelope "$GOOD_SH")")" 0

# The header allowance covers ONE block, reached across the shebang and the
# `set`/`shopt` prologue this repo puts above its headers.
write_lines "$TMP/prologue_header.sh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  '# Header line one, past the prologue.' \
  '# Header line two.' \
  '# Header line three.' \
  '# Header line four.' \
  '' \
  'main() { printf "%s\n" "$1"; }'
assert_exit_code "shell: header block below set -euo pipefail is exempt" \
  "$(check_ec "$TMP/prologue_header.sh" "$ENABLED_CONFIG")" 0

write_lines "$TMP/second_block.sh" \
  '#!/usr/bin/env bash' \
  '# Header line one.' \
  '# Header line two.' \
  '' \
  '# Second block line one.' \
  '# Second block line two.' \
  '# Second block line three.' \
  'main() { return 0; }'
assert_exit_code "shell: a second pre-code comment block is body, not header" \
  "$(check_ec "$TMP/second_block.sh" "$ENABLED_CONFIG")" 2

write_lines "$TMP/banner.bash" \
  '#!/usr/bin/env bash' \
  '# Real header.' \
  '' \
  '# ---- Helpers ----------------' \
  'helper() { return 0; }'
assert_exit_code "shell: banner rule applies to .bash bodies" "$(check_ec "$TMP/banner.bash" "$ENABLED_CONFIG")" 2

# Extensionless bash (githooks(5) naming) is classified by shebang.
write_lines "$TMP/pre-commit" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'run() {' \
  '  # Body run line one.' \
  '  # Body run line two.' \
  '  # Body run line three.' \
  '  return 0' \
  '}'
assert_exit_code "shell: extensionless hook script is covered via its shebang" \
  "$(check_ec "$TMP/pre-commit" "$ENABLED_CONFIG")" 2

# The header allowance is shell-only: a python shebang gets no such exemption.
write_lines "$TMP/hdr.py" \
  '#!/usr/bin/env python3' \
  '# Header line one.' \
  '# Header line two.' \
  '# Header line three.' \
  'x = 1'
assert_exit_code "python behavior unchanged: no shell header allowance" \
  "$(check_ec "$TMP/hdr.py" "$ENABLED_CONFIG")" 2

# An Edit fragment carries no shebang, so it gets no header allowance either.
ec=$(hook_ec '{"tool_name":"Edit","tool_input":{"file_path":"/x/lib.sh","new_string":"# one\n# two\n# three\nrun_it"}}')
assert_exit_code "shell: a headerless Edit fragment is body text" "$ec" 2

# Named exception: an explicit annotation waives the run limit for THAT run.
write_lines "$TMP/waived.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'table() {' \
  '  # lean-comments: allow-run — captured verdict table, one row per reviewer' \
  '  # security  APPROVE  92' \
  '  # architect APPROVE  88' \
  '  # qa        APPROVE  85' \
  '  return 0' \
  '}'
assert_exit_code "shell: lean-comments allow-run waives that run" "$(check_ec "$TMP/waived.sh" "$ENABLED_CONFIG")" 0

write_lines "$TMP/waived_banner.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'table() {' \
  '  # lean-comments: allow-run — still not a licence to draw banners' \
  '  # ===========================' \
  '  return 0' \
  '}'
assert_exit_code "shell: the waiver does not cover the banner rule" \
  "$(check_ec "$TMP/waived_banner.sh" "$ENABLED_CONFIG")" 2

# A shellcheck directive is machine-required syntax, not narration.
write_lines "$TMP/directive.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  '# shellcheck source=./lib/emit-event.sh' \
  'source "$SCRIPT_DIR/lib/emit-event.sh"'
assert_exit_code "shell: a tool directive is not a restatement" "$(check_ec "$TMP/directive.sh" "$ENABLED_CONFIG")" 0

# Heredoc bodies are data. This repo's shell tests embed whole markdown
# manifests, and their `## Section` headings are not comment runs.
write_lines "$TMP/heredoc.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'cat > "$m" <<EOF' \
  '# TASK-001: Something' \
  '## Metadata' \
  '- **Status**: READY' \
  '## Commits' \
  '## Description' \
  'EOF'
assert_exit_code "shell: heredoc body is data, not a comment run" \
  "$(check_ec "$TMP/heredoc.sh" "$ENABLED_CONFIG")" 0

write_lines "$TMP/heredoc_then_run.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'cat > "$m" <<EOF' \
  '## Metadata' \
  'EOF' \
  '' \
  '# Body run line one.' \
  '# Body run line two.' \
  '# Body run line three.' \
  'run_it'
assert_exit_code "shell: the heredoc skip stops at its terminator" \
  "$(check_ec "$TMP/heredoc_then_run.sh" "$ENABLED_CONFIG")" 2

write_lines "$TMP/shift_not_heredoc.sh" \
  '#!/usr/bin/env bash' \
  '# Header.' \
  '' \
  'mask=$(( 1 << 3 ))' \
  'printf "%s" "the marker is << MARK here"' \
  '# Body run line one.' \
  '# Body run line two.' \
  '# Body run line three.' \
  'run_it'
assert_exit_code "shell: a << with no terminator does not swallow the file" \
  "$(check_ec "$TMP/shift_not_heredoc.sh" "$ENABLED_CONFIG")" 2

# Coverage honesty: the fixed-grammar line is the last line of stdout, and its
# own arithmetic is asserted here as well as by the emitter.
cov=$(NAZGUL_CONFIG="$ENABLED_CONFIG" bash "$GUARD" --check "$GOOD_SH" "$TMP/notes.md" "$TMP/no-such-file.sh" 2>/dev/null | tail -1)
assert_eq "coverage line grammar over a mixed candidate set" "$cov" \
  "lean-comments: 3 scanned, 2 skipped (unsupported-extension=1, unreadable=1), 1 checked, 0 findings"
cov_n=$(sed -E 's/^lean-comments: ([0-9]+) scanned.*/\1/' <<<"$cov")
cov_m=$(sed -E 's/.*, ([0-9]+) skipped .*/\1/' <<<"$cov")
cov_k=$(sed -E 's/.*, ([0-9]+) checked.*/\1/' <<<"$cov")
assert_eq "coverage line is self-consistent (N == M + K)" "$cov_n" "$((cov_m + cov_k))"

cov_bad=$( { NAZGUL_CONFIG="$ENABLED_CONFIG" bash "$GUARD" --check "$BAD_SH" 2>/dev/null || true; } | tail -1)
assert_eq "coverage line counts findings" "$cov_bad" \
  "lean-comments: 1 scanned, 0 skipped (unsupported-extension=0, unreadable=0), 1 checked, 1 findings"

# NOTHING CHECKED: everything skipped must never read as a clean run.
VAC="$TMP/vac"
mkdir -p "$VAC/nazgul"
printf '%s\n' '{"guards":{"lean_comments":true,"max_consecutive_comment_lines":2}}' > "$VAC/nazgul/config.json"
VAC_EVENTS="$VAC/nazgul/logs/events.jsonl"
vac_err=$(CLAUDE_PROJECT_DIR="$VAC" bash "$GUARD" --check "$TMP/notes.md" 2>&1 >/dev/null || true)
vac_ec=$(CLAUDE_PROJECT_DIR="$VAC" bash "$GUARD" --check "$TMP/notes.md" >/dev/null 2>&1; echo $?)
assert_contains "nothing-checked signal on stderr" "$vac_err" "NOTHING CHECKED — all 1 candidates skipped"
assert_exit_code "advisory: nothing-checked leaves the exit code unchanged" "$vac_ec" 0
assert_file_exists "coverage_vacuous event was written" "$VAC_EVENTS"
vac_ev=$(jq -c 'select(.event=="coverage_vacuous")' "$VAC_EVENTS" 2>/dev/null | tail -1)
assert_contains "event names the entry point" "$vac_ev" '"entry_point":"lean-comments"'
assert_contains "event carries the scanned count" "$vac_ev" '"scanned":1'
assert_contains "event carries the skipped count" "$vac_ev" '"skipped":1'

vac_before=$(grep -c 'coverage_vacuous' "$VAC_EVENTS" || true)
CLAUDE_PROJECT_DIR="$VAC" bash "$GUARD" --check "$GOOD_SH" >/dev/null 2>&1 || true
vac_after=$(grep -c 'coverage_vacuous' "$VAC_EVENTS" || true)
assert_eq "no vacuity event when a file was actually checked" "$vac_after" "$vac_before"

# A run that checks nothing because it was given nothing is not vacuous.
empty_cov=$(NAZGUL_CONFIG="$ENABLED_CONFIG" bash "$GUARD" --check 2>/dev/null | tail -1)
assert_eq "empty candidate set reports zeroes, not a vacuity claim" "$empty_cov" \
  "lean-comments: 0 scanned, 0 skipped (unsupported-extension=0, unreadable=0), 0 checked, 0 findings"

# board-5 CR-1: the hook read the payload's first line through `printf | head -1`,
# so past the pipe buffer SIGPIPE aborted this always-blocking gate silently (#230).
SMALL_SUBJ="$TMP/sigpipe-small.sh"
LARGE_SUBJ="$TMP/sigpipe-large.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' '# ============================================' \
    '# Helpers' '# ============================================' 'x=1'
} > "$SMALL_SUBJ"
cp "$SMALL_SUBJ" "$LARGE_SUBJ"
i=0
while [ "$i" -lt 6000 ]; do
  printf 'echo padding line %s\n' "$i" >> "$LARGE_SUBJ"
  i=$((i + 1))
done

LARGE_BYTES=$(wc -c < "$LARGE_SUBJ" | tr -d ' ')
assert_eq "the large subject really outruns the 64 KiB pipe buffer" \
  "$([ "$LARGE_BYTES" -gt 65536 ] && echo yes || echo no)" "yes"

SMALL_EC=$(hook_ec "$(write_envelope "$SMALL_SUBJ")")
LARGE_EC=$(hook_ec "$(write_envelope "$LARGE_SUBJ")")
assert_exit_code "hook blocks the small payload" "$SMALL_EC" 2
assert_exit_code "hook reaches the same verdict on the >64 KiB payload" "$LARGE_EC" 2
assert_eq "identical bloat reaches an identical verdict at both sizes" "$LARGE_EC" "$SMALL_EC"
assert_not_contains "no path exits 141 (SIGPIPE under pipefail)" "$SMALL_EC $LARGE_EC" "141"

# A gate that aborts leaves no message, so the diagnostic is the other half of the pin.
LARGE_ERR=$(printf '%s' "$(write_envelope "$LARGE_SUBJ")" \
  | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$GUARD" 2>&1 >/dev/null || true)
assert_contains "the large payload still produces the finding" "$LARGE_ERR" "banner/separator"

CLEAN_LARGE="$TMP/sigpipe-large-clean.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' > "$CLEAN_LARGE"
i=0
while [ "$i" -lt 6000 ]; do
  printf 'echo clean line %s\n' "$i" >> "$CLEAN_LARGE"
  i=$((i + 1))
done
assert_exit_code "a clean >64 KiB payload is allowed, not aborted" \
  "$(hook_ec "$(write_envelope "$CLEAN_LARGE")")" 0

report_results
