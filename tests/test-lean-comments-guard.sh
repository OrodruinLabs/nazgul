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

# --- BAD: comment restates code / micro-optimization noise (rule d) ----------
write_file bad_restate.cs 'public int Build(string method, List<string> requests) {
    // Pre-size to avoid resizes: prefix (~20) + method + per-token avg (~20) + suffix (~10).
    var sb = new StringBuilder(method.Length + requests.Count * 20 + 32);
    return sb.Length;
}
'
assert_exit_code "blocks restate/micro-opt comment" "$(check_ec "$TMP/bad_restate.cs" "$ENABLED_CONFIG")" 2
assert_contains "restate message" "$(check_out "$TMP/bad_restate.cs" "$ENABLED_CONFIG")" "NAZGUL LEAN-COMMENTS"

# --- BAD: banner / separator comment (rule c) --------------------------------
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

# --- BAD: run of 3+ consecutive line comments (rule a) -----------------------
write_file bad_run.ts 'function f() {
  // step one we do this
  // step two we do that
  // step three we finish
  return 1;
}
'
assert_exit_code "blocks 3+ comment run" "$(check_ec "$TMP/bad_run.ts" "$ENABLED_CONFIG")" 2
assert_contains "comment-run message" "$(check_out "$TMP/bad_run.ts" "$ENABLED_CONFIG")" "consecutive line comments"

# --- BAD: <remarks> on a private member (rule b) -----------------------------
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

# --- BAD: multi-paragraph docstring on a private Python def (rule b) ----------
write_file bad_doc.py 'def _helper(x):
    """Compute the thing.

    This paragraph explains way too much about the internals.
    """
    return x
'
assert_exit_code "blocks multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc.py" "$ENABLED_CONFIG")" 2

# --- GOOD: public interface doc, no comment, one-line venue quirk -------------
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

# --- ALLOWED: license header run is exempt -----------------------------------
write_file good_license.cs '// Copyright 2026 Orodruin Labs
// Licensed under the MIT License.
// SPDX-License-Identifier: MIT
namespace Foo {}
'
assert_exit_code "allows license header run" "$(check_ec "$TMP/good_license.cs" "$ENABLED_CONFIG")" 0

# --- ALLOWED: single-line docstring on a public Python def -------------------
write_file good.py 'def compute(x):
    """Return x doubled."""
    return x * 2
'
assert_exit_code "allows single-line public docstring" "$(check_ec "$TMP/good.py" "$ENABLED_CONFIG")" 0

# --- Opt-out: guards.lean_comments=false is a no-op --------------------------
echo '{"guards":{"lean_comments":false}}' > "$TMP/proj/nazgul/disabled.json"
assert_exit_code "no-op when lean_comments=false" "$(check_ec "$TMP/bad_banner.cs" "$TMP/proj/nazgul/disabled.json")" 0

# --- Tunable threshold: raising max allows a longer run ----------------------
echo '{"guards":{"lean_comments":true,"max_consecutive_comment_lines":5}}' > "$TMP/proj/nazgul/loose.json"
assert_exit_code "respects raised max_consecutive_comment_lines" "$(check_ec "$TMP/bad_run.ts" "$TMP/proj/nazgul/loose.json")" 0

# --- Non-source file is never inspected --------------------------------------
write_file notes.md '// a
// b
// c
// d
'
assert_exit_code "ignores non-source files" "$(check_ec "$TMP/notes.md" "$ENABLED_CONFIG")" 0

# --- Hook mode: Write JSON on stdin blocks a banner --------------------------
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

# === Review-driven regression coverage (PR #39 bot feedback) ==================

# --- BAD: triple-single-quote multi-paragraph docstring on private def --------
write_file bad_doc_sq.py "def _helper(x):
    '''Compute the thing.

    This second paragraph is bloat.
    '''
    return x
"
assert_exit_code "blocks ''' multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc_sq.py" "$ENABLED_CONFIG")" 2

# --- BAD: prefixed (r\"\"\") multi-paragraph docstring on private def ----------
write_file bad_doc_prefix.py 'def _helper(x):
    r"""Compute the thing.

    Second paragraph, still bloat.
    """
    return x
'
assert_exit_code "blocks prefixed multi-paragraph private docstring" "$(check_ec "$TMP/bad_doc_prefix.py" "$ENABLED_CONFIG")" 2

# --- ALLOWED: long SINGLE-paragraph /// summary on a private member -----------
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

# --- BAD: license keyword in a MID-FILE comment run is NOT exempt -------------
write_file bad_midfile_license.ts 'export function f() {
  return 1;
}
// this run mentions the MIT License but is not a header
// second line of the mid-file run
// third line of the mid-file run
const x = 2;
'
assert_exit_code "mid-file license-keyword run still blocks" "$(check_ec "$TMP/bad_midfile_license.ts" "$ENABLED_CONFIG")" 2

# --- ALLOWED: MultiEdit edits are evaluated independently ---------------------
# Two separate edits, each with <=2 comment lines, must NOT be joined into a
# phantom 3+ run.
ec=$(hook_ec '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.ts","edits":[{"new_string":"// one\n// two\nconst a=1;"},{"new_string":"// three\nconst b=2;"}]}}')
assert_exit_code "MultiEdit edits evaluated independently (no phantom run)" "$ec" 0

# --- BAD: a single MultiEdit edit that itself has a 3+ run still blocks -------
ec=$(hook_ec '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.ts","edits":[{"new_string":"const a=1;"},{"new_string":"// one\n// two\n// three\nconst b=2;"}]}}')
assert_exit_code "MultiEdit blocks a real in-edit run" "$ec" 2

report_results
