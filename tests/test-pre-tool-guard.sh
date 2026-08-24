#!/usr/bin/env bash
set -euo pipefail

# Test: pre-tool-guard.sh blocks dangerous commands and allows safe ones
TEST_NAME="test-pre-tool-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/pre-tool-guard.sh"

# Every command this suite exercises the guard with, recorded as it happens so
# the differential harness at the bottom of this file (AC1) can replay the full
# set against the pre-fix guard without a hand-maintained duplicate list. A NUL-
# delimited FILE, not an array: get_exit_code/get_exit_code_json are called as
# `x=$(...)`, which runs the function body in a subshell — an array append there
# would vanish when the subshell exits, but a file write persists. NUL (never
# valid inside a bash string) safely delimits records even when $cmd itself
# contains embedded real newlines (the multi-line test cases below).
EXERCISED_LOG="$(mktemp -t pre-tool-guard-exercised.XXXXXX)"
trap 'rm -f "$EXERCISED_LOG"' EXIT
_record_exercised() {
  printf '%s\x1f%s\0' "$1" "$2" >> "$EXERCISED_LOG"
}

run_guard() {
  local cmd="$1"
  local output
  _record_exercised raw "$cmd"
  output=$(echo "$cmd" | bash "$GUARD" 2>&1) || true
  echo "$output"
}

# Capture the guard's exit code explicitly via `|| ec=$?` so a non-zero (blocked)
# exit is "tested" and never aborts the function under `set -e`/`inherit_errexit`.
get_exit_code() {
  local cmd="$1" ec=0
  _record_exercised raw "$cmd"
  echo "$cmd" | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# Production path: the hook receives a JSON envelope {tool_input:{command:...}}
# on stdin (not the raw command). The guard must extract .tool_input.command
# before tokenizing — otherwise the whole command is one JSON-quoted string.
get_exit_code_json() {
  local cmd="$1" ec=0
  _record_exercised json "$cmd"
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# --- Safe commands (should exit 0) ---
for safe_cmd in \
  "ls -la" \
  "git status" \
  "npm install" \
  "rm file.txt" \
  "curl https://example.com" \
  "node server.js" \
  "python3 script.py"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "safe: '$safe_cmd'" "$ec" 0
done

# --- Filesystem destruction (should exit 2) ---
for bad_cmd in \
  "rm -rf /" \
  "rm -rf ~" \
  'rm -rf $HOME' \
  "rm -rf . "; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-027: rm -rf precision — anchored root/home patterns must still block
# every genuine destructive form (both boundary variants: whitespace, `;`, `&`) ---
for bad_cmd in \
  "rm -rf /" \
  "rm -rf /;" \
  "rm -rf / &&" \
  "rm -rf //" \
  "rm -rf /root" \
  "rm -rf /root/" \
  "rm -rf ~" \
  "rm -rf ~/" \
  'rm -rf $HOME' \
  'rm -rf $HOME/'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-027: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-027 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-027: rm -rf precision — legitimate absolute/relative-path deletions
# must NOT be over-matched by the root/home block (the false-positive fix;
# trailing-slash whole-dir forms block above, real subpaths stay allowed) ---
for safe_cmd in \
  "rm -rf /tmp/x" \
  "rm -rf ./build" \
  "rm -rf ~/tmp" \
  "rm -rf /root/subdir" \
  'rm -rf $HOME/scratch' \
  "rm -rf /tmp/build-cache"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed MF-027: '$safe_cmd'" "$ec" 0
done

# --- Database destruction (should exit 2) ---
for bad_cmd in \
  "psql -c 'DROP TABLE users'" \
  "mysql -e 'DROP DATABASE mydb'" \
  "sqlite3 db.sqlite 'TRUNCATE TABLE users'"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-029: additional DB-CLI invocation shapes (different clients/quoting) must
# still block, confirming the anchor isn't over-fit to the three literal strings above ---
for bad_cmd in \
  'psql -c "DROP TABLE accounts"' \
  'mysqldump --host=db -e "DROP DATABASE staging"' \
  'sqlcmd -Q "TRUNCATE TABLE dbo.orders"' \
  'redis-cli -x "TRUNCATE someset"' \
  "psql -c 'DROP TABLE \"accounts\"'" \
  "mysql -e 'DROP TABLE \`users\`'" \
  'sqlcmd -Q "TRUNCATE TABLE [dbo].[orders]"'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-029: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-029 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-029 B-1..B-4: DB-CLI token boundary — path-prefixed, subshell, piped, and
# quoted invocations are still DB-CLI invocations and must block (PR #71 bot findings) ---
for bad_cmd in \
  '/usr/bin/psql -c "DROP TABLE users"' \
  '$(psql -c "DROP TABLE users")' \
  'cat plan.sql | psql -c "DROP TABLE users"' \
  '"psql" -c "DROP TABLE users"'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-029 boundary: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-029 boundary for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# Hyphen is deliberately NOT a token boundary: a hyphenated compound naming a client
# (wrapper script, file slug) is not that client, while redis-cli still matches as a
# listed token. Prose keyword mention alongside such a name must stay allowed.
ec=$(get_exit_code 'echo "see my-psql-notes.txt for the DROP TABLE cleanup plan"')
assert_exit_code "allowed MF-029 FP-7: hyphenated compound naming a client is not an invocation" "$ec" 0

# --- MF-029: evidence-derived false positives — quoted prose naming the SQL
# keywords with no DB-CLI invocation token anywhere in the command must be
# allowed (LR-005; observed live false positives during FEAT-018/019 dogfooding) ---

# FP-1: python3 heredoc prose (the FEAT-018 wiki-ingest case)
ec=$(get_exit_code "$(printf 'python3 <<EOF\nThis note explains the TRUNCATE prose fix for FEAT-018\nEOF')")
assert_exit_code "allowed MF-029 FP-1: python3 heredoc prose (no DB-CLI token)" "$ec" 0

# FP-2: jq string argument naming the keywords (the FEAT-019 objective-store self-block case)
ec=$(get_exit_code 'jq -n --arg msg "block DROP TABLE and TRUNCATE keywords" "$msg"')
assert_exit_code "allowed MF-029 FP-2: jq argument naming keywords" "$ec" 0

# FP-3: git commit -m prose message
ec=$(get_exit_code 'git commit -m "fix: anchor DROP TABLE and TRUNCATE guard rules (LR-005)"')
assert_exit_code "allowed MF-029 FP-3: git commit -m prose" "$ec" 0

# FP-4: grep search-pattern argument naming a keyword
ec=$(get_exit_code 'grep -rn "DROP TABLE" scripts/pre-tool-guard.sh')
assert_exit_code "allowed MF-029 FP-4: grep pattern argument" "$ec" 0

# FP-5: file path / code comment containing a keyword, no DB-CLI invocation
ec=$(get_exit_code 'echo "// TODO: handle TRUNCATE edge case in parser.py"')
assert_exit_code "allowed MF-029 FP-5: file path/comment mentioning keyword" "$ec" 0

# FP-6: production JSON-envelope path — same commit-message prose as FP-3, wrapped
# per the real PreToolUse hook contract
ec=$(get_exit_code_json 'git commit -m "fix: anchor DROP TABLE and TRUNCATE guard rules (LR-005)"')
assert_exit_code "allowed MF-029 FP-6: JSON envelope commit-message prose" "$ec" 0

# --- MF-029: whole-command AND regression — the DB-CLI token and the destructive
# statement no longer need to share a ;/&&/||/|-delimited segment, so realistic
# bypasses that split the two across segments or lines must still block ---

# Block S-1: multi-statement SQL inside one quoted -c argument (the `;` inside the
# quotes used to split the DB-CLI token from the keyword into separate segments)
ec=$(get_exit_code 'psql -c "SELECT 1; DROP TABLE users;"')
assert_exit_code "blocked MF-029 S-1: multi-statement quoted -c arg" "$ec" 2

# Block S-2: heredoc invocation — the DB-CLI token and the destructive statement
# land on separate lines, which the old segment-scoped check treated as isolated
ec=$(get_exit_code "$(printf 'psql -h host -d mydb <<SQL\nDROP TABLE users;\nSQL')")
assert_exit_code "blocked MF-029 S-2: heredoc invocation across lines" "$ec" 2

# Block S-3 (deliberate over-block, safe direction): a DB-CLI invocation and an
# unrelated keyword mention in a LATER, independent segment of the same compound
# command now also blocks, since the token and the keyword are only required to
# appear anywhere in $CMD, not in the same segment. This is the documented tradeoff
# of dropping segment-scoping (see the comment above check_sql_destructive()) —
# pinned here as a known, accepted limitation (documented at scripts/pre-tool-guard.sh:54-65).
ec=$(get_exit_code 'psql -c "select 1"; echo "please DROP TABLE users"')
assert_exit_code "blocked MF-029 S-3: cross-segment token+keyword (accepted over-block)" "$ec" 2

# --- Git force push (should exit 2) ---
for bad_cmd in \
  "git push --force origin main" \
  "git push -f origin master"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-028: force-push order independence — all four flag/branch orderings
# must block, since real usage puts the flag before OR after the branch ---
for bad_cmd in \
  "git push --force origin main" \
  "git push -f origin main" \
  "git push origin main --force" \
  "git push origin main -f" \
  "git push origin master --force" \
  "git push origin master -f"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-028: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-028 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-028: no false-positive — force-push to a non-protected branch, or a
# plain push to main with no force flag, must both be allowed ---
for safe_cmd in \
  "git push origin feature-branch --force" \
  "git push origin main"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed MF-028: '$safe_cmd'" "$ec" 0
done

# --- TASK-031: every force-push separator spelling keeps the verdict it has
# today, so replacing the splitter cannot be a silent behaviour change. ---
for bad_cmd in \
  "git push --force origin main; echo done" \
  "echo start; git push --force origin main" \
  "git push --force origin main && echo ok" \
  "git push --force origin main || echo failed" \
  "git status | grep ahead && git push -f origin master" \
  "git push --force origin main | tee push.log" \
  "git push --force main" \
  "git push -f master"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked TASK-031: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason TASK-031 for '$bad_cmd'" "$output" "Force push to main/master branch"
done

# Each of these DOES satisfy all three predicates when read as one string, so a
# separator that stopped splitting would over-block it. Allow proves it split.
for safe_cmd in \
  "git push --force feature/x | grep main" \
  "git push --force feature/x; grep main" \
  "git push --force feature/x || echo main" \
  "git push --force feature/x && echo main"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed TASK-031 (separator participates): '$safe_cmd'" "$ec" 0
done

# Anchoring rather than splitting: `main` here is a path fragment or quoted
# prose, so no segment ever names it as a branch word (LR-005).
for safe_cmd in \
  "git push --force feature/x" \
  "git push origin release/main-line --force" \
  "echo 'do not git push --force to main'"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed TASK-031 (anchored, not substring): '$safe_cmd'" "$ec" 0
done

# The exact string CodeRabbit named. It is allowed, and correctly so: `;main` is
# a separate command word, not a push target — blocking it would be the defect.
ec=$(get_exit_code "git push --force;main")
assert_exit_code "allowed TASK-031: 'git push --force;main' (;main is its own command)" "$ec" 0

# TASK-031 AC3: the reported "BSD/macOS sed writes a literal n" mechanism is FALSE
# on this host — it writes a real newline. But `\n` there is undefined by POSIX.
FP_REAL_SED="$(command -v sed)"
FP_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fp-sed-XXXXXX")
cat > "$FP_STUB_DIR/sed" <<EOF
#!/usr/bin/env bash

# A sed that does not honour the undefined \`\n\` replacement escape, and
# substitutes the literal character \`n\` instead.
fp_args=()
for fp_a in "\$@"; do fp_args+=("\${fp_a//\\\\n/n}"); done
exec "$FP_REAL_SED" "\${fp_args[@]}"
EOF
chmod +x "$FP_STUB_DIR/sed"
FP_COMPOUND="git push --force origin main; echo done"

# Controls first: an uninstalled stub, or a host sed that already merged, would
# let every assertion below pass while measuring nothing (the TASK-030 class).
FP_REAL_LINES=$(printf '%s\n' "$FP_COMPOUND" | sed -E 's/(\&\&|\|\||;|\|)/\n/g' | wc -l | tr -d ' ')
FP_STUB_LINES=$(PATH="$FP_STUB_DIR:$PATH"; printf '%s\n' "$FP_COMPOUND" | sed -E 's/(\&\&|\|\||;|\|)/\n/g' | wc -l | tr -d ' ')
assert_eq "control TASK-031: this host's sed DOES emit a newline (2 segments)" "$FP_REAL_LINES" "2"
assert_eq "control TASK-031: the stub sed is in effect and merges to 1 segment" "$FP_STUB_LINES" "1"

fp_guard_probe() {
  # "<exit>\x1f<stderr>" with $1 prepended to PATH. Deliberately not
  # _record_exercised: the differential replay runs with the ambient PATH.
  local pathdir="$1" cmd="$2" ec=0 out
  out=$(PATH="$pathdir:$PATH"; echo "$cmd" | bash "$GUARD" 2>&1 >/dev/null) || ec=$?
  printf '%s\x1f%s' "$ec" "$out"
}

FP_RES=$(fp_guard_probe "$FP_STUB_DIR" "$FP_COMPOUND")
FP_EC="${FP_RES%%$'\x1f'*}"; FP_OUT="${FP_RES#*$'\x1f'}"
assert_exit_code "TASK-031: compound force-push still BLOCKS under a non-conforming sed" "$FP_EC" 2
assert_contains "TASK-031: and blocks for the force-push reason, not an incidental failure" "$FP_OUT" "Force push to main/master branch"

FP_RES=$(fp_guard_probe "$FP_STUB_DIR" "git push --force feature/x")
FP_EC="${FP_RES%%$'\x1f'*}"
assert_exit_code "TASK-031: the same stub does not turn an allowed push into a block" "$FP_EC" 0
rm -rf "$FP_STUB_DIR"

# --- Dangerous system commands (should exit 2) ---
for bad_cmd in \
  ':(){:|:&};:' \
  "chmod -R 777 /var"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- Task manifest write protection: BLOCK cases (should exit 2) ---
# Block R1: echo with >> redirect into manifest
ec=$(get_exit_code 'echo "Status: IN_PROGRESS" >> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Block R1: echo >> manifest" "$ec" 2
output=$(run_guard 'echo "Status: IN_PROGRESS" >> nazgul/tasks/TASK-001.md')
assert_contains "reason Block R1" "$output" "NAZGUL SAFETY"

# Block R2: echo with > redirect into manifest
ec=$(get_exit_code 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Block R2: echo > manifest" "$ec" 2
output=$(run_guard 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_contains "reason Block R2" "$output" "NAZGUL SAFETY"

# Block R3: printf with >> redirect into manifest
ec=$(get_exit_code 'printf "Status: DONE\n" >> nazgul/tasks/TASK-002.md')
assert_exit_code "blocked Block R3: printf >> manifest" "$ec" 2
output=$(run_guard 'printf "Status: DONE\n" >> nazgul/tasks/TASK-002.md')
assert_contains "reason Block R3" "$output" "NAZGUL SAFETY"

# Block R4: tee into manifest (now the structural tee rule, not a text pattern)
ec=$(get_exit_code 'tee nazgul/tasks/TASK-003.md')
assert_exit_code "blocked Block R4: tee manifest" "$ec" 2
output=$(run_guard 'tee nazgul/tasks/TASK-003.md')
assert_contains "reason Block R4" "$output" "NAZGUL SAFETY"

# Allow R5 (TASK-004 declared loosening): the retired text rule blocked read-only
# sed inspection while missing `sed -i` — an over-block AND an under-block.
ec=$(get_exit_code 'sed -n p nazgul/tasks/TASK-001.md | grep Status')
assert_exit_code "allowed R5: sed -n p manifest | grep Status (read-only inspection)" "$ec" 0

# --- Task manifest write protection: ALLOW cases (false-positives now fixed) ---
# Allow FP-1: echo + mention of manifest path, no redirect into manifest
ec=$(get_exit_code 'echo "Status: IN_PROGRESS"; grep nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-1: echo Status + grep manifest (no redirect)" "$ec" 0

# Allow FP-2: printf + cat manifest (no redirect into manifest)
ec=$(get_exit_code 'printf "Current Status: DONE\n"; cat nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-2: printf Status + cat manifest (no redirect)" "$ec" 0

# Allow FP-3: echo mentioning manifest path, no redirect
ec=$(get_exit_code 'echo "Checking Status of nazgul/tasks/TASK-001.md..."')
assert_exit_code "allowed Allow FP-3: echo mentioning manifest path (no redirect)" "$ec" 0

# Allow FP-4: grep only, no echo/printf at all
ec=$(get_exit_code 'grep "Status" nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-4: grep Status in manifest (read-only)" "$ec" 0

# --- D: echo/printf redirect: false-positive fixes (quoted > is data, not redirect) ---
# Allow D-FP-1: > is DATA inside double quotes — must not block
ec=$(get_exit_code 'echo "> nazgul/tasks/TASK-001.md"')
assert_exit_code "allowed D-FP-1: echo with > inside double quotes (data, not redirect)" "$ec" 0

# Allow D-FP-2: >> is DATA inside single quotes — must not block
ec=$(get_exit_code "printf '%s' '>> nazgul/tasks/TASK-001.md'")
assert_exit_code "allowed D-FP-2: printf with >> inside single quotes (data, not redirect)" "$ec" 0

# --- D: echo/printf redirect: false-negative fixes (quoted/./target must block) ---
# Block D-FN-1: real redirect with double-quoted target path
ec=$(get_exit_code 'echo foo > "nazgul/tasks/TASK-001.md"')
assert_exit_code "blocked D-FN-1: echo foo > \"nazgul/tasks/TASK-001.md\" (quoted target)" "$ec" 2
output=$(run_guard 'echo foo > "nazgul/tasks/TASK-001.md"')
assert_contains "reason D-FN-1" "$output" "NAZGUL SAFETY"

# Block D-FN-2: real redirect with ./nazgul/ prefixed target
ec=$(get_exit_code 'echo foo > ./nazgul/tasks/TASK-001.md')
assert_exit_code "blocked D-FN-2: echo foo > ./nazgul/tasks/TASK-001.md (./ prefix)" "$ec" 2
output=$(run_guard 'echo foo > ./nazgul/tasks/TASK-001.md')
assert_contains "reason D-FN-2" "$output" "NAZGUL SAFETY"

# --- Category 3: >| and >>| noclobber-override redirects (should exit 2) ---
# Block G-1: >| noclobber-override redirect to manifest
ec=$(get_exit_code 'echo foo >| nazgul/tasks/TASK-001.md')
assert_exit_code "blocked G-1: echo foo >| nazgul/tasks/TASK-001.md (noclobber >|)" "$ec" 2
output=$(run_guard 'echo foo >| nazgul/tasks/TASK-001.md')
assert_contains "reason G-1" "$output" "NAZGUL SAFETY"

# Block G-2: >>| noclobber-override append redirect to manifest
ec=$(get_exit_code 'echo foo >>| nazgul/tasks/TASK-001.md')
assert_exit_code "blocked G-2: echo foo >>| nazgul/tasks/TASK-001.md (noclobber >>|)" "$ec" 2
output=$(run_guard 'echo foo >>| nazgul/tasks/TASK-001.md')
assert_contains "reason G-2" "$output" "NAZGUL SAFETY"

# --- Category 1: compound echo — non-echo/printf segments are ignored (allow regression) ---
# Allow H-1: grep with manifest path piped to head (no echo/printf, no redirect)
ec=$(get_exit_code 'grep Status scripts/foo.sh | head')
assert_exit_code "allowed H-1: grep manifest | head (no echo/printf)" "$ec" 0

# Allow H-2: echo in compound with no redirect into manifest
ec=$(get_exit_code 'echo "checking"; grep Status scripts/foo.sh')
assert_exit_code "allowed H-2: echo checking; grep (no redirect into manifest)" "$ec" 0

# --- Category 4: full-word redirect-target resolution (leading redirect + split fragments) ---
# Block I-1: leading redirect before the command word (> target echo ok)
ec=$(get_exit_code '> nazgul/tasks/TASK-001.md echo ok')
assert_exit_code "blocked I-1: > nazgul/tasks/TASK-001.md echo ok (leading redirect)" "$ec" 2
output=$(run_guard '> nazgul/tasks/TASK-001.md echo ok')
assert_contains "reason I-1" "$output" "NAZGUL SAFETY"

# Block I-2: target split across adjacent quoted + unquoted fragments
ec=$(get_exit_code 'echo ok > "nazgul/tasks/"TASK-001.md')
assert_exit_code "blocked I-2: echo ok > \"nazgul/tasks/\"TASK-001.md (split target)" "$ec" 2
output=$(run_guard 'echo ok > "nazgul/tasks/"TASK-001.md')
assert_contains "reason I-2" "$output" "NAZGUL SAFETY"

# Allow I-3: leading redirect to a NON-manifest target (no false-positive)
ec=$(get_exit_code '> /tmp/out.log echo ok')
assert_exit_code "allowed I-3: > /tmp/out.log echo ok (non-manifest target)" "$ec" 0

# Allow I-4: split fragments that do NOT form a manifest path
ec=$(get_exit_code 'echo ok > "/tmp/"out.log')
assert_exit_code "allowed I-4: echo ok > \"/tmp/\"out.log (non-manifest split target)" "$ec" 0

# --- Category 5: production JSON-envelope path (regression for command extraction) ---
# Block J-1: JSON envelope with a real echo>manifest must fire (prod hook contract)
ec=$(get_exit_code_json 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked J-1: JSON envelope echo > manifest (production path)" "$ec" 2

# Allow J-2: JSON envelope read-only echo of a manifest path (no redirect)
ec=$(get_exit_code_json 'echo "checking nazgul/tasks/TASK-001.md"')
assert_exit_code "allowed J-2: JSON envelope read-only echo (production path)" "$ec" 0

# --- Category 6: & redirects (2>&1, &>) and multi-line segment reset ---
# Block K-1: fd-dup 2>&1 before a real > into manifest (the & must not eat the redirect)
ec=$(get_exit_code 'echo foo 2>&1 > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked K-1: echo foo 2>&1 > manifest" "$ec" 2

# Block K-2: &> combined stdout+stderr redirect into manifest
ec=$(get_exit_code 'echo foo &> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked K-2: echo foo &> manifest" "$ec" 2

# Allow K-3: 2>&1 with no manifest redirect (no false-positive)
ec=$(get_exit_code 'echo foo 2>&1')
assert_exit_code "allowed K-3: echo foo 2>&1 (no manifest redirect)" "$ec" 0

# Block K-4: multi-line — a non-echo segment then echo > manifest (per-line reset)
ec=$(get_exit_code "$(printf 'ls x\necho b > nazgul/tasks/TASK-001.md')")
assert_exit_code "blocked K-4: multiline ls; then echo > manifest" "$ec" 2

# Allow K-5: multi-line echos with no manifest redirect
ec=$(get_exit_code "$(printf 'echo a\necho b')")
assert_exit_code "allowed K-5: multiline echos, no redirect" "$ec" 0

# --- Category 7: backslash-escaped quotes inside double-quoted spans ---
# Block L-1: an escaped \" inside the echoed string must not desync in_dq and hide
# the redirect (the > into the manifest must still be detected).
ec=$(get_exit_code 'echo "foo\"bar" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked L-1: echo \"foo\\\"bar\" > manifest (escaped quote)" "$ec" 2

# Allow L-2: escaped quote, no redirect → no false-positive
ec=$(get_exit_code 'echo "foo\"bar baz"')
assert_exit_code "allowed L-2: echo \"foo\\\"bar baz\" (escaped quote, no redirect)" "$ec" 0

# --- Category 8: fd-numbered and leading redirects ---
# Block N-1: a leading 2>&1 must not steal the command word from a later echo
ec=$(get_exit_code '2>&1 echo foo > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-1: leading 2>&1 then echo > manifest" "$ec" 2

# Block N-2: a leading fd redirect (1>file) before echo
ec=$(get_exit_code '1>/tmp/x echo foo > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-2: leading 1>/tmp/x then echo > manifest" "$ec" 2

# Block N-3: echo with a fd-numbered redirect (1>) directly into a manifest
ec=$(get_exit_code 'echo foo 1> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-3: echo foo 1> manifest (fd-numbered redirect)" "$ec" 2

# Allow N-4: leading fd redirect to a non-manifest target, no manifest write
ec=$(get_exit_code '2>/tmp/e echo foo')
assert_exit_code "allowed N-4: 2>/tmp/e echo foo (no manifest target)" "$ec" 0

# --- Category 9: leading VAR=value env assignments ---
# Block O-1: a leading assignment must not steal the command word from echo
ec=$(get_exit_code 'FOO=1 echo ok > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked O-1: FOO=1 echo ok > manifest (leading env assignment)" "$ec" 2

# Block O-2: multiple leading assignments then echo
ec=$(get_exit_code 'A=1 B=2 echo ok > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked O-2: A=1 B=2 echo ok > manifest" "$ec" 2

# --- Category 10: single-quote atomicity (a > inside single quotes is DATA) ---
# Allow P-1: the >> lives inside single quotes → not a redirect → no manifest write.
# (Regression guard: confirms in_sq toggles correctly via the '\'' shell-escape idiom.)
ec=$(get_exit_code "printf '%s' '>> nazgul/tasks/TASK-001.md'")
assert_exit_code "allowed P-1: printf '%s' '>> manifest' (redirect is single-quoted data)" "$ec" 0

# Block P-2: a real redirect AFTER a single-quoted span still blocks (sq closes properly).
ec=$(get_exit_code "echo 'hi there' > nazgul/tasks/TASK-001.md")
assert_exit_code "blocked P-2: echo 'hi there' > manifest (real redirect after sq span)" "$ec" 2

# --- Category 11: fd_target_pending must not leak across a segment separator ---
# Block Q-1: an fd-dup (>&) as the last token of segment 1 leaves fd_target_pending
# set; reset_segment() must clear it so the echo in segment 2 still registers and the
# manifest write blocks. (Defensive — the minimal valid-shell trigger is a syntax error.)
ec=$(get_exit_code 'echo x >& ; echo y > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Q-1: fd-dup before ';' does not swallow next segment's echo" "$ec" 2

# --- Category 12: MF-022 funnel — mv/cp targeting a task manifest (secondary,
# defense-in-depth layer; the structural fix is the stop-hook reconciliation) ---
# Block R-1: mv forging a manifest into place
ec=$(get_exit_code 'mv fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-1: mv fake.md nazgul/tasks/TASK-005.md (manifest funnel)" "$ec" 2
output=$(run_guard 'mv fake.md nazgul/tasks/TASK-005.md')
assert_contains "reason R-1" "$output" "NAZGUL SAFETY"

# Block R-2: cp forging a manifest into place
ec=$(get_exit_code 'cp fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-2: cp fake.md nazgul/tasks/TASK-005.md (manifest funnel)" "$ec" 2
output=$(run_guard 'cp fake.md nazgul/tasks/TASK-005.md')
assert_contains "reason R-2" "$output" "NAZGUL SAFETY"

# Block R-3: mv with a flag before the source (flag must not be mistaken for the target)
ec=$(get_exit_code 'mv -f fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-3: mv -f fake.md nazgul/tasks/TASK-005.md" "$ec" 2

# Block R-4: ./ prefixed manifest target
ec=$(get_exit_code 'cp fake.md ./nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-4: cp fake.md ./nazgul/tasks/TASK-005.md (./ prefix)" "$ec" 2

# Allow R-5: cp READING from a manifest (manifest is the source, not the target)
ec=$(get_exit_code 'cp nazgul/tasks/TASK-005.md /tmp/backup.md')
assert_exit_code "allowed R-5: cp nazgul/tasks/TASK-005.md /tmp/backup.md (manifest is source)" "$ec" 0

# Allow R-6: mv/cp with no manifest path anywhere
ec=$(get_exit_code 'mv src.txt /tmp/dest.txt')
assert_exit_code "allowed R-6: mv src.txt /tmp/dest.txt (no manifest involved)" "$ec" 0

# Allow R-7: mv reading from a manifest to a non-manifest destination
ec=$(get_exit_code 'mv nazgul/tasks/TASK-005.md /tmp/archived-005.md')
assert_exit_code "allowed R-7: mv nazgul/tasks/TASK-005.md /tmp/archived-005.md (manifest is source)" "$ec" 0

# --- Category 13 (FEAT-029/TASK-004, AC5): closed writer policy. Every mutation
# form the field report reproduced, in bare/quoted/./-prefixed/absolute/glob form.
for writer_cmd in \
  "sed -i 's/READY/DONE/' nazgul/tasks/TASK-001.md" \
  "sed -i '' -e 's/READY/DONE/' nazgul/tasks/TASK-001.md" \
  "sed -i.bak 's/a/b/' /Users/dev/proj/nazgul/tasks/TASK-001.md" \
  "sed -E -i 's/a/b/' \"nazgul/tasks/TASK-001.md\"" \
  "sed -i 's/a/b/' ./nazgul/tasks/TASK-001.md" \
  "sed -i 's/a/b/' nazgul/tasks/TASK-*.md" \
  "perl -pi -e 's/READY/DONE/' nazgul/tasks/TASK-001.md" \
  "perl -i.bak -pe 's/a/b/' nazgul/tasks/TASK-001.md" \
  "ruby -e 'File.write(\"nazgul/tasks/TASK-001.md\", \"x\")'" \
  "ruby -i -pe 'gsub(/READY/, \"DONE\")' nazgul/tasks/TASK-001.md" \
  "python3 -c \"from pathlib import Path; Path('nazgul/tasks/TASK-001.md').write_text('x')\"" \
  "python -c 'open(\"nazgul/tasks/TASK-001.md\", \"w\").write(\"x\")'" \
  "awk '{print > \"nazgul/tasks/TASK-001.md\"}' input.md" \
  "gawk -i inplace '{gsub(/READY/, \"DONE\")}1' nazgul/tasks/TASK-001.md" \
  "cat staged.md > nazgul/tasks/TASK-001.md" \
  "cat staged.md | tee -a nazgul/tasks/TASK-001.md" \
  "install -m 644 forged.md nazgul/tasks/TASK-005.md" \
  "ln -sf forged.md nazgul/tasks/TASK-005.md" \
  "bash -c \"sed -i 's/a/b/' nazgul/tasks/TASK-001.md\"" \
  "sh -c 'echo DONE > nazgul/tasks/TASK-001.md'"; do
  ec=$(get_exit_code "$writer_cmd")
  assert_exit_code "blocked S-writer: '$writer_cmd'" "$ec" 2
done

# S-heredoc: an interpreter fed its program on later lines — the body its own
# delimiter closes is charged to it, so a write there is still the signal.
ec=$(get_exit_code "$(printf 'python3 - <<PY\nfrom pathlib import Path\nPath("nazgul/tasks/TASK-001.md").write_text("x")\nPY')")
assert_exit_code "blocked S-heredoc: python3 heredoc writing a manifest" "$ec" 2

# S-heredoc-arg: the manifest is an operand of the heredoc-fed interpreter.
ec=$(get_exit_code "$(printf 'python3 - nazgul/tasks/TASK-001.md <<PY\nimport sys\nPY')")
assert_exit_code "blocked S-heredoc-arg: manifest operand of a heredoc-fed interpreter" "$ec" 2

# S-heredoc-scope: heredoc evidence belongs to the command that opened it, so an
# unrelated read-only manifest command outside that body must not be blocked.
ec=$(get_exit_code "$(printf "python3 - <<'PY'\nprint(\"ok\")\nPY\ngrep Status nazgul/tasks/TASK-001.md")")
assert_exit_code "allowed S-heredoc-scope: prose heredoc then an unrelated grep" "$ec" 0
ec=$(get_exit_code "$(printf "grep Status nazgul/tasks/TASK-001.md\npython3 - <<'PY'\nprint(\"ok\")\nPY")")
assert_exit_code "allowed S-heredoc-scope-2: grep then an unrelated prose heredoc" "$ec" 0

# S-wrapped (PATCH-003): the parser classifies the first command word of a
# segment, so a writer reached through a wrapper or a substitution used to pass.
for wrapped_cmd in \
  "env sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env FOO=1 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "command sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "nohup sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "nice -n 10 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env cp forged.md nazgul/tasks/TASK-001.md" \
  "echo x | xargs sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "echo \"\$(sed -i 's/a/b/' nazgul/tasks/TASK-001.md)\"" \
  "echo \$(cp forged.md nazgul/tasks/TASK-001.md)" \
  "RESULT=\"\$(sed -i 's/a/b/' nazgul/tasks/TASK-001.md)\"" \
  "echo \"\`sed -i 's/a/b/' nazgul/tasks/TASK-001.md\`\"" \
  "( sed -i 's/a/b/' nazgul/tasks/TASK-001.md )" \
  "eval \"sed -i 's/a/b/' nazgul/tasks/TASK-001.md\""; do
  ec=$(get_exit_code "$wrapped_cmd")
  assert_exit_code "blocked S-wrapped: '$wrapped_cmd'" "$ec" 2
done

# S-wrapopt (PATCH-005): a wrapper option that TAKES an argument used to donate
# that argument to cmd_word, losing the writer behind it. See PATCH-005 Group A.
for wrapopt_cmd in \
  "sudo sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -u root sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -g wheel sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -p 'pw:' sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -C 3 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo --user=root sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo --user root sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -- sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -knu root sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -h sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo --host=h sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo --host h sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -a type sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "doas sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "doas -u root sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env -u FOO sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env -C /tmp sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --unset=FOO sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --unset FOO sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env -i sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env -- sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --block-signal sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --default-signal sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --ignore-signal sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "env --block-signal=INT sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "nice sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "nice -n 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "nice -n5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "ionice sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "ionice -c 2 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "ionice -c2 -n 4 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "ionice -p 1 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout -s KILL 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout -k 1 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout --signal=KILL 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "timeout --signal KILL 5 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "stdbuf -o0 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "stdbuf -o 0 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "stdbuf -i L -o L sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -n 1 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -I{} sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -I {} sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -P 4 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -d , sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -E EOF sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -L 1 sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -a /tmp/f sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -i sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -e sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "xargs -i{} sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "exec -a name sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "time -o /tmp/t sed -i 's/a/b/' nazgul/tasks/TASK-001.md" \
  "sudo -u root env -u FOO nice -n 5 cp forged.md nazgul/tasks/TASK-001.md" \
  "sudo -u root -- sed -i 's/a/b/' nazgul/tasks/TASK-001.md"; do
  ec=$(get_exit_code "$wrapopt_cmd")
  assert_exit_code "blocked S-wrapopt: '$wrapopt_cmd'" "$ec" 2
done

# Consuming one word too many would misclassify a wrapped READ just as badly, so
# the same option forms must still allow read-only wrapped commands.
for wrapopt_ro in \
  "sudo -u root cat nazgul/tasks/TASK-001.md" \
  "env -u FOO grep Status nazgul/tasks/TASK-001.md" \
  "timeout -s KILL 5 cat nazgul/tasks/TASK-001.md" \
  "xargs -I {} grep Status nazgul/tasks/TASK-001.md" \
  "sudo -u root cp nazgul/tasks/TASK-001.md /tmp/backup.md" \
  "env -C /tmp \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh\" transition TASK-004 READY IN_PROGRESS"; do
  ec=$(get_exit_code "$wrapopt_ro")
  assert_exit_code "allowed S-wrapopt-readonly: '$wrapopt_ro'" "$ec" 0
done

# S-continued: an escaped newline does not end the command, so the segment must
# not be reset there and lose the writer that owns the operand below.
ec=$(get_exit_code "$(printf "sed -i 's/a/b/' \\\\\n  nazgul/tasks/TASK-001.md")")
assert_exit_code "blocked S-continued: sed -i with the manifest on a continued line" "$ec" 2
ec=$(get_exit_code "$(printf "cp forged.md \\\\\n  nazgul/tasks/TASK-001.md")")
assert_exit_code "blocked S-continued-2: cp with the manifest on a continued line" "$ec" 2

# The wrapper look-through must not turn read-only wrapped commands into writers.
for wrapped_ro in \
  "env grep Status nazgul/tasks/TASK-001.md" \
  "timeout 5 cat nazgul/tasks/TASK-001.md" \
  "sudo cp nazgul/tasks/TASK-001.md /tmp/backup.md" \
  "env \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh\" transition TASK-004 READY IN_PROGRESS" \
  "echo \"\$(grep Status nazgul/tasks/TASK-001.md)\"" \
  "diff <(cat nazgul/tasks/TASK-001.md) /tmp/other.md"; do
  ec=$(get_exit_code "$wrapped_ro")
  assert_exit_code "allowed S-wrapped-readonly: '$wrapped_ro'" "$ec" 0
done

# S-json: the production envelope path must deny a writer too — the guard
# tokenizes .tool_input.command, never the JSON wrapper.
ec=$(get_exit_code_json "sed -i 's/READY/DONE/' nazgul/tasks/TASK-001.md")
assert_exit_code "blocked S-json: JSON envelope sed -i on a manifest" "$ec" 2

output=$(run_guard "sed -i 's/READY/DONE/' nazgul/tasks/TASK-001.md")
assert_contains "reason S-writer names the sanctioned route" "$output" "NAZGUL SAFETY"

# --- AC5 second half: read-only inspection and the sanctioned transition command
# must remain usable, or the policy wedges the loop it is meant to protect. ---
for readonly_cmd in \
  "grep 'Status' nazgul/tasks/TASK-001.md" \
  "grep -H -E '(^- \*\*Status\*\*:|^## Status:)' nazgul/tasks/TASK-*.md" \
  "cat nazgul/tasks/TASK-001.md" \
  "sed -n '1,20p' nazgul/tasks/TASK-001.md" \
  "awk '/Status/ {print}' nazgul/tasks/TASK-001.md" \
  "awk -F: '{print \$1}' nazgul/tasks/TASK-001.md" \
  "head -5 nazgul/tasks/TASK-001.md && wc -l nazgul/tasks/TASK-001.md" \
  "diff nazgul/tasks/TASK-001.md /tmp/other.md" \
  "ls nazgul/tasks/TASK-*.md" \
  "cp nazgul/tasks/TASK-001.md /tmp/backup.md" \
  "scripts/task-transition.sh transition TASK-004 READY IN_PROGRESS" \
  "\"\${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh\" transition TASK-004 IN_PROGRESS IMPLEMENTED" \
  "bash scripts/task-transition.sh transition TASK-004 IN_REVIEW BLOCKED --reason 'merge conflict'" \
  "\"\${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh\" repair TASK-004" \
  "sed -i 's/a/b/' /tmp/notes.md" \
  "python3 script.py"; do
  ec=$(get_exit_code "$readonly_cmd")
  assert_exit_code "allowed S-readonly: '$readonly_cmd'" "$ec" 0
done

# --- AC5 blast radius: patch manifests and per-task subdirectories are NOT task
# manifests and stay writable (the strict TASK-NNN.md matcher, not a prefix). ---
for outside_cmd in \
  "sed -i '' -e 's/a/b/' nazgul/tasks/patches/PATCH-001.md" \
  "mv forged.md nazgul/tasks/patches/PATCH-001.md" \
  "cp report.md nazgul/tasks/TASK-005/verification.md" \
  "echo notes > nazgul/tasks/TASK-005-delegation.md"; do
  ec=$(get_exit_code "$outside_cmd")
  assert_exit_code "allowed S-outside: '$outside_cmd'" "$ec" 0
done

# --- AC5 deliberate over-blocks: an interpreter carrying a manifest path inside
# its program text is denied even when that program only reads it. ---
for overblock_cmd in \
  "python3 -c \"print(open('nazgul/tasks/TASK-001.md').read())\"" \
  "bash -c 'grep Status nazgul/tasks/TASK-001.md'"; do
  ec=$(get_exit_code "$overblock_cmd")
  assert_exit_code "blocked S-overblock (deliberate): '$overblock_cmd'" "$ec" 2
done

# --- TASK-003 (Defect 1a): fork-free `[[ =~ ]]` matching must be verdict-
# preserving, not just faster — plan.md V1/C1 pins the three ways a naive
# `echo|grep` -> `[[ =~ ]]` swap diverges, and both directions of the
# check_pattern line-safety requirement. ---

# V1-pin (a): \s -> [[:space:]] must still match runs of multiple spaces, not
# just a single \s+ occurrence (GNU-only \s is undefined in POSIX regcomp).
ec=$(get_exit_code 'rm  -rf   /')
assert_exit_code "blocked V1-a: rm  -rf   / (multiple spaces, [[:space:]]+ pin)" "$ec" 2
output=$(run_guard 'rm  -rf   /')
assert_contains "reason V1-a" "$output" "NAZGUL SAFETY"

# V1-pin (b): case-insensitivity must survive the swap via scoped nocasematch.
ec=$(get_exit_code 'mysql -e "drop table users"')
assert_exit_code "blocked V1-b: lowercase mysql -e drop table users (nocasematch pin)" "$ec" 2
output=$(run_guard 'mysql -e "drop table users"')
assert_contains "reason V1-b" "$output" "NAZGUL SAFETY"

# V1-pin (c): grep's line-oriented semantics must be preserved — a $-anchored
# check_pattern rule still fires on an interior line of a multi-line command
# (the guard blocks this today; a whole-string swap would fail open).
ec=$(get_exit_code "$(printf 'echo hi\nrm -rf .\necho bye')")
assert_exit_code "blocked V1-c: multiline command, rm -rf . on interior line" "$ec" 2

# C1 over-block pin (d): a `.*`-bearing check_pattern rule must NOT span lines.
# dd if= on one line and an unrelated of=/dev/ mention on a much later line
# must not block (a naive whole-string swap would span the newline).
ec=$(get_exit_code "$(printf 'dd if=/tmp/disk.img bs=4M\necho step one\necho step two\necho mentions of=/dev/zero in passing')")
assert_exit_code "allowed C1-d: dd if= and of=/dev/ on unrelated lines (no over-block)" "$ec" 0

# C1 over-block pin (e): same direction as (d) for the curl|sh rule.
ec=$(get_exit_code "$(printf 'curl -sL https://example.com/install.sh -o /tmp/install.sh\necho done downloading\ncat /tmp/install.sh | sh')")
assert_exit_code "allowed C1-e: curl and | sh on unrelated lines (no over-block)" "$ec" 0

# C1 item 4 pin: check_sql_destructive keeps WHOLE-COMMAND matching (never
# line-iterated, per FEAT-019). A DB-CLI token starting one line and a DROP
# TABLE keyword starting a different line must still block, proving the
# anchors' bracket negations tolerate an embedded newline under regexec.
ec=$(get_exit_code "$(printf 'psql\nDROP TABLE users;')")
assert_exit_code "blocked C1-sql: DB-CLI token and DROP TABLE on separate lines" "$ec" 2
output=$(run_guard "$(printf 'psql\nDROP TABLE users;')")
assert_contains "reason C1-sql" "$output" "NAZGUL SAFETY"

# --- RW-B (security Finding 3): the extracted denylist must fail CLOSED — a
# PreToolUse hook blocks only on exit 2, so an unloadable library allowed all. ---
DP_ABSENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-dp-absent-XXXXXX")
mkdir -p "$DP_ABSENT_DIR/lib"
cp "$GUARD" "$DP_ABSENT_DIR/pre-tool-guard.sh"
cp "$(dirname "$GUARD")/lib/read-hook-payload.sh" "$DP_ABSENT_DIR/lib/"
cp "$(dirname "$GUARD")/lib/nazgul-root.sh" "$DP_ABSENT_DIR/lib/"
cp "$(dirname "$GUARD")/lib/emit-event.sh" "$DP_ABSENT_DIR/lib/"
DESTRUCTIVE_CMD="rm -rf /"

dp_probe() {
  # Echoes "<exit_code>\x1f<combined output>" for the COPIED guard. Deliberately
  # not _record_exercised: this probes the load path, not a verdict.
  local ec=0 out
  out=$(echo "$DESTRUCTIVE_CMD" | bash "$DP_ABSENT_DIR/pre-tool-guard.sh" 2>&1) || ec=$?
  printf '%s\x1f%s' "$ec" "$out"
}

# Case 1: library missing entirely (partial install / scripts/lib not synced).
rm -f "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
DP_RES=$(dp_probe)
DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
assert_exit_code "denylist missing: guard fails CLOSED (exit 2), never allows" "$DP_EC" 2
assert_contains "denylist missing: diagnostic names the missing authority" "$DP_OUT" "lib/destructive-patterns.sh"
assert_contains "denylist missing: diagnostic is a NAZGUL SAFETY block" "$DP_OUT" "NAZGUL SAFETY"
assert_contains "denylist missing: diagnostic states which failure occurred" "$DP_OUT" "file is missing"

# Case 2: library present but unreadable (mode 000). Skipped under a uid that
# ignores the permission bits, since the probe would then be vacuous.
cp "$REPO_ROOT/scripts/lib/destructive-patterns.sh" "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
chmod 000 "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
if [ -r "$DP_ABSENT_DIR/lib/destructive-patterns.sh" ]; then
  _skip "denylist unreadable: guard fails CLOSED (running as a uid that bypasses mode 000)"
else
  DP_RES=$(dp_probe)
  DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
  assert_exit_code "denylist unreadable: guard fails CLOSED (exit 2)" "$DP_EC" 2
  assert_contains "denylist unreadable: diagnostic names the authority" "$DP_OUT" "lib/destructive-patterns.sh"
fi
chmod 644 "$DP_ABSENT_DIR/lib/destructive-patterns.sh"

# Case 3: library loads but defines nothing (truncated/renamed API). Sourcing
# succeeds, so only a post-source definition check catches this.
printf '#!/usr/bin/env bash\n# truncated\n' > "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
DP_RES=$(dp_probe)
DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
assert_exit_code "denylist defines no screen: guard fails CLOSED (exit 2)" "$DP_EC" 2
assert_contains "denylist defines no screen: diagnostic names dp_scan_command" "$DP_OUT" "dp_scan_command"

# Case 4 (S-4): a library that does not PARSE. `bash -n` establishes this as its
# own fact, so the diagnostic names the real cause instead of "could not be sourced".
printf '#!/usr/bin/env bash\ndp_scan_command() {\n  if [ 1\n}\n' > "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
DP_RES=$(dp_probe)
DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
assert_exit_code "denylist syntax error: guard fails CLOSED (exit 2)" "$DP_EC" 2
assert_contains "denylist syntax error: diagnostic is a NAZGUL SAFETY block" "$DP_OUT" "NAZGUL SAFETY"
# bash prints its own "syntax error near..." to the same stream, so the guard's
# OWN sentence is what is asserted — the bare token would pass either way.
assert_contains "denylist syntax error: the guard's own diagnostic names the parse failure" "$DP_OUT" "screen unavailable: file has a syntax error"

# Case 5 (S-4): a library that parses, defines both screens, and whose LAST top-level
# statement returns non-zero. `source` reports that status; the library is not broken.
cp "$REPO_ROOT/scripts/lib/destructive-patterns.sh" "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
printf '\nfalse\n' >> "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
DP_RES=$(dp_probe)
DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
assert_exit_code "denylist returns non-zero on load: still blocks the destructive control (exit 2)" "$DP_EC" 2
assert_not_contains "denylist returns non-zero on load: block is the pattern verdict, not a load failure" "$DP_OUT" "screen unavailable"
assert_contains "denylist returns non-zero on load: the benign non-zero is reported, not silent" "$DP_OUT" "returned 1 on load"
DP_NZ_EC=0
echo "ls -la" | bash "$DP_ABSENT_DIR/pre-tool-guard.sh" >/dev/null 2>&1 || DP_NZ_EC=$?
assert_exit_code "denylist returns non-zero on load: a benign command is still allowed" "$DP_NZ_EC" 0

# Control: with the real library restored, the SAME copied guard blocks for the
# ordinary reason and allows a benign command — proving the three cases above
# measure the load path, not a permanently-broken copy.
cp "$REPO_ROOT/scripts/lib/destructive-patterns.sh" "$DP_ABSENT_DIR/lib/destructive-patterns.sh"
DP_RES=$(dp_probe)
DP_EC="${DP_RES%%$'\x1f'*}"; DP_OUT="${DP_RES#*$'\x1f'}"
assert_exit_code "control: restored library still blocks rm -rf /" "$DP_EC" 2
assert_not_contains "control: block is the pattern verdict, not a load failure" "$DP_OUT" "screen unavailable"
DP_CTRL_EC=0
echo "ls -la" | bash "$DP_ABSENT_DIR/pre-tool-guard.sh" >/dev/null 2>&1 || DP_CTRL_EC=$?
assert_exit_code "control: restored library allows a benign command" "$DP_CTRL_EC" 0
rm -rf "$DP_ABSENT_DIR"

# --- RHP (board-13 security Finding 1): same five facts as the denylist above for the
# stdin reader, plus the route the denylist cannot have — an exported re-source sentinel. ---
RHP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-rhp-XXXXXX")
mkdir -p "$RHP_DIR/lib"
cp "$GUARD" "$RHP_DIR/pre-tool-guard.sh"
for _lib in read-hook-payload nazgul-root emit-event destructive-patterns; do
  cp "$REPO_ROOT/scripts/lib/$_lib.sh" "$RHP_DIR/lib/"
done
RHP_REAL="$REPO_ROOT/scripts/lib/read-hook-payload.sh"

rhp_probe() {
  # Echoes "<exit>\x1f<combined output>"; $1, when set, is exported into the guard's
  # environment, which is the whole point of the sentinel case.
  local ec=0 out
  if [ -n "${1:-}" ]; then
    out=$(echo "$DESTRUCTIVE_CMD" | env "$1" bash "$RHP_DIR/pre-tool-guard.sh" 2>&1) || ec=$?
  else
    out=$(echo "$DESTRUCTIVE_CMD" | bash "$RHP_DIR/pre-tool-guard.sh" 2>&1) || ec=$?
  fi
  printf '%s\x1f%s' "$ec" "$out"
}

# Case 1: reader missing entirely.
rm -f "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "reader missing: guard fails CLOSED (exit 2), never allows" "$RHP_EC" 2
assert_contains "reader missing: diagnostic names the missing authority" "$RHP_OUT" "lib/read-hook-payload.sh"
assert_contains "reader missing: diagnostic states which failure occurred" "$RHP_OUT" "file is missing"

# Case 2: reader present but unreadable (mode 000).
cp "$RHP_REAL" "$RHP_DIR/lib/read-hook-payload.sh"
chmod 000 "$RHP_DIR/lib/read-hook-payload.sh"
if [ -r "$RHP_DIR/lib/read-hook-payload.sh" ]; then
  _skip "reader unreadable: guard fails CLOSED (running as a uid that bypasses mode 000)"
else
  RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
  assert_exit_code "reader unreadable: guard fails CLOSED (exit 2)" "$RHP_EC" 2
  assert_contains "reader unreadable: diagnostic names the authority" "$RHP_OUT" "lib/read-hook-payload.sh"
fi
chmod 644 "$RHP_DIR/lib/read-hook-payload.sh"

# Case 3: reader loads but defines nothing. Sourcing succeeds, so only a
# post-source definition check catches this — the measured 127-as-ALLOW route.
printf '#!/usr/bin/env bash\n# truncated\n' > "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "reader defines nothing: guard fails CLOSED (exit 2), not 127" "$RHP_EC" 2
assert_contains "reader defines nothing: diagnostic names read_hook_payload" "$RHP_OUT" "read_hook_payload"

# Case 3b: the reporter alone missing. Both API members are asked as separate facts,
# because a hook that reads a payload it cannot then REPORT on is still half-loaded.
{ cat "$RHP_REAL"; printf '\nunset -f hook_payload_timeout_report\n'; } > "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "reader without its reporter: guard fails CLOSED (exit 2)" "$RHP_EC" 2
assert_contains "reader without its reporter: diagnostic names hook_payload_timeout_report" "$RHP_OUT" "hook_payload_timeout_report"

# Case 4 (THE sharp one): the reader used to open with an env-settable re-source
# sentinel above every definition, so one exported variable made the load a no-op.
printf '%s\n%s\n' '[ -n "${_NAZGUL_READ_HOOK_PAYLOAD_SOURCED:-}" ] && return 0' '_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1' \
  > "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe "_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1"); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "sentinel-shaped reader + exported sentinel: guard fails CLOSED (exit 2), not 127" "$RHP_EC" 2
assert_contains "sentinel-shaped reader + exported sentinel: diagnostic names the undefined API" "$RHP_OUT" "read_hook_payload"

# Case 5: a reader that does not PARSE, established as its own fact by `bash -n`.
printf '#!/usr/bin/env bash\nread_hook_payload() {\n  if [ 1\n}\n' > "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "reader syntax error: guard fails CLOSED (exit 2)" "$RHP_EC" 2
assert_contains "reader syntax error: the guard's own diagnostic names the parse failure" "$RHP_OUT" "reader unavailable: file has a syntax error"

# Control: the SHIPPED reader restored. The block is the pattern verdict, and a
# benign command is still allowed — so the five cases measure the load path.
cp "$RHP_REAL" "$RHP_DIR/lib/read-hook-payload.sh"
RHP_RES=$(rhp_probe); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "control: shipped reader still blocks rm -rf /" "$RHP_EC" 2
assert_not_contains "control: block is the pattern verdict, not a load failure" "$RHP_OUT" "reader unavailable"
RHP_CTRL_EC=0
echo "ls -la" | bash "$RHP_DIR/pre-tool-guard.sh" >/dev/null 2>&1 || RHP_CTRL_EC=$?
assert_exit_code "control: shipped reader allows a benign command" "$RHP_CTRL_EC" 0

# Control 2: the SHIPPED reader with the old sentinel name exported. It must be inert
# — the guard screens exactly as it does with a clean environment, on both verdicts.
RHP_RES=$(rhp_probe "_NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1"); RHP_EC="${RHP_RES%%$'\x1f'*}"; RHP_OUT="${RHP_RES#*$'\x1f'}"
assert_exit_code "exported sentinel against the shipped reader: still blocks rm -rf /" "$RHP_EC" 2
assert_not_contains "exported sentinel against the shipped reader: block is the pattern verdict" "$RHP_OUT" "reader unavailable"
RHP_SPOOF_EC=0
echo "ls -la" | env _NAZGUL_READ_HOOK_PAYLOAD_SOURCED=1 bash "$RHP_DIR/pre-tool-guard.sh" >/dev/null 2>&1 || RHP_SPOOF_EC=$?
assert_exit_code "exported sentinel against the shipped reader: a benign command is still allowed" "$RHP_SPOOF_EC" 0
rm -rf "$RHP_DIR"

# --- AC1: differential verdict harness. Every command string this suite has
# exercised the guard with (recorded above via _record_exercised, including
# the six pins just above) is replayed against BOTH the pre-fix guard, pinned
# to the Wave-1 Base SHA (the manifest's own documented common ancestor, and
# since this task is a single commit on top of it, genuinely the pre-fix file
# forever — `git show HEAD:...` would collapse to a self-comparison the
# instant the fix is committed, since HEAD then IS the post-fix blob) and the
# guard in the working tree. Non-manifest cases must still be byte-identical in
# exit code AND stderr; manifest cases are classified below, never skipped. ---
# Re-pinned when PR #74 (FEAT-022) was SQUASH-merged to main. The prior pin,
# 5483d70a1c2bd11c4bdaee813369bb7c5afacc5c, was a commit on the FEAT-022
# BRANCH; a squash merge replaces that history with one commit, so the old SHA
# is no longer an ancestor of main and a fresh CI clone cannot resolve it —
# the reachability pre-check below would have failed loudly on every run.
# 6f0be16 is main's squash commit for FEAT-022 and carries a byte-identical
# scripts/pre-tool-guard.sh (verified: both blobs hash to
# e982558df84076e6863ddb75dbaec4fbeedb53a4), so the differential baseline is
# unchanged in content — only its address is.
PRE_FIX_BASE_SHA="6f0be16e20151693ce9de9bf6326bbf10dc12bb9"
GUARD_OLD="$(mktemp -t pre-tool-guard-old.XXXXXX)"
trap 'rm -f "$EXERCISED_LOG" "$GUARD_OLD"' EXIT

# actions/checkout@v4 defaults to a shallow depth-1 clone, so the pinned
# ancestor above may not be present in CI even though it always is on a full
# local clone. Never let that fall through to a silent skip: try a bounded
# deepen, and if the SHA is still unreachable, fail loud and name the fix —
# skipping only the differential replay below, not the rest of this file.
BASE_SHA_REACHABLE=1
if ! git -C "$REPO_ROOT" cat-file -e "${PRE_FIX_BASE_SHA}^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --deepen=50 2>/dev/null || true
  if ! git -C "$REPO_ROOT" cat-file -e "${PRE_FIX_BASE_SHA}^{commit}" 2>/dev/null; then
    BASE_SHA_REACHABLE=0
  fi
fi
if [ "$BASE_SHA_REACHABLE" -eq 1 ]; then
  git -C "$REPO_ROOT" show "$PRE_FIX_BASE_SHA":scripts/pre-tool-guard.sh > "$GUARD_OLD"
fi

MANIFEST_DIFFED=0
IDENTITY_DIFFED=0

# TASK-004 owns the manifest-policy verdicts, so those are no longer identity-
# comparable — classify them instead of skipping them (see the counters below).
_is_manifest_case() {
  case "$1" in
    *nazgul/tasks/TASK-*) return 0 ;;
  esac
  return 1
}

# The complete list of verdicts TASK-004 is permitted to LOOSEN. Anything else
# may only stay the same or tighten; a silent loosening is a failure.
_is_declared_loosening() {
  case "$1" in
    # Read-only inspection the retired `sed.*TASK-.*Status` text rule over-blocked.
    'sed -n p nazgul/tasks/TASK-001.md | grep Status') return 0 ;;
    # Non-manifest artifacts the old TASK-[^space]*.md matcher swept in; the strict
    # TASK-NNN.md matcher (task-state-guard.sh) leaves both writable by design.
    'cp report.md nazgul/tasks/TASK-005/verification.md') return 0 ;;
    'echo notes > nazgul/tasks/TASK-005-delegation.md') return 0 ;;
  esac
  return 1
}

diff_verdict() {
  local mode="$1" cmd="$2"
  local old_ec=0 new_ec=0 old_err new_err
  if [ "$mode" = "json" ]; then
    old_err=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD_OLD" 2>&1 >/dev/null) || old_ec=$?
    new_err=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" 2>&1 >/dev/null) || new_ec=$?
  else
    old_err=$(echo "$cmd" | bash "$GUARD_OLD" 2>&1 >/dev/null) || old_ec=$?
    new_err=$(echo "$cmd" | bash "$GUARD" 2>&1 >/dev/null) || new_ec=$?
  fi
  if _is_manifest_case "$cmd"; then
    MANIFEST_DIFFED=$((MANIFEST_DIFFED + 1))
    if _is_declared_loosening "$cmd"; then
      if [ "$old_ec" -eq 2 ] && [ "$new_ec" -eq 0 ]; then
        _pass "manifest policy [$mode] declared loosening 2->0: ${cmd:0:80}"
      else
        _fail "manifest policy [$mode] declared loosening 2->0: ${cmd:0:80}" \
          "old exit=$old_ec  new exit=$new_ec"
      fi
    elif [ "$new_ec" -ge "$old_ec" ]; then
      _pass "manifest policy [$mode] $old_ec->$new_ec (not loosened): ${cmd:0:80}"
    else
      _fail "manifest policy [$mode] loosened without a declaration: ${cmd:0:80}" \
        "old exit=$old_ec  new exit=$new_ec" \
        "add it to _is_declared_loosening only if the loosening is intended"
    fi
    return
  fi
  IDENTITY_DIFFED=$((IDENTITY_DIFFED + 1))
  if [ "$old_ec" = "$new_ec" ] && [ "$old_err" = "$new_err" ]; then
    _pass "differential [$mode] exit=$new_ec: ${cmd:0:80}"
  else
    _fail "differential [$mode]: ${cmd:0:80}" \
      "old exit=$old_ec  new exit=$new_ec" \
      "old stderr: ${old_err:0:200}" \
      "new stderr: ${new_err:0:200}"
  fi
}

# Floor assertion: if _record_exercised ever silently stopped firing (mktemp
# failure, a refactor changing how run_guard/get_exit_code* are called), this
# loop would iterate zero times and report_results would still print a clean
# "0/0 passed" — a silent shrink, not a failure. Assert the recorded count by a
# known-good floor, not by trusting the loop to run at all.
EXERCISED_COUNT=$(tr -dc '\0' < "$EXERCISED_LOG" | wc -c | tr -d ' ')
if [ "$EXERCISED_COUNT" -ge 200 ]; then
  _pass "differential harness recorded >=200 commands (got $EXERCISED_COUNT)"
else
  _fail "differential harness recorded >=200 commands" "got $EXERCISED_COUNT"
fi

# No dedup (associative arrays are bash 4+ only, and this must also pass under
# /bin/bash 3.2.57): a command exercised twice by the suite above is simply
# diffed twice. Redundant, not incorrect.
if [ "$BASE_SHA_REACHABLE" -eq 1 ]; then
  while IFS= read -r -d '' _rec; do
    _mode="${_rec%%$'\x1f'*}"
    _cmd="${_rec#*$'\x1f'}"
    diff_verdict "$_mode" "$_cmd"
  done < "$EXERCISED_LOG"
  echo "  differential: ${IDENTITY_DIFFED} identity-compared, ${MANIFEST_DIFFED} manifest-policy-compared"
  # Both paths must actually run: a classifier that swallowed every case, or a
  # suite that lost its manifest cases, would otherwise report a clean pass.
  if [ "$IDENTITY_DIFFED" -ge 100 ]; then
    _pass "differential identity path checked >=100 commands (got $IDENTITY_DIFFED)"
  else
    _fail "differential identity path checked >=100 commands" "got $IDENTITY_DIFFED"
  fi
  if [ "$MANIFEST_DIFFED" -ge 60 ]; then
    _pass "differential manifest-policy path checked >=60 commands (got $MANIFEST_DIFFED)"
  else
    _fail "differential manifest-policy path checked >=60 commands" "got $MANIFEST_DIFFED"
  fi
else
  _fail "differential harness baseline unreachable" \
    "pinned pre-fix SHA $PRE_FIX_BASE_SHA is not reachable in this checkout" \
    "(even after 'git fetch --deepen=50') — likely a shallow CI clone" \
    "(actions/checkout@v4 defaults to fetch-depth: 1)" \
    "fix: set fetch-depth: 0 on the checkout step in .github/workflows/test.yml" \
    "the $EXERCISED_COUNT-command differential replay was SKIPPED; all other assertions in this file still ran"
fi

# PATCH-007 item 12 — `_dp_ci_match` cleared `nocasematch` unconditionally instead of restoring
# the caller's, contradicting its own header, in a lib sourced into three entry points.
DP_LIB="$REPO_ROOT/scripts/lib/destructive-patterns.sh"
DP_KEPT=$(bash -c ". '$DP_LIB'; shopt -s nocasematch; _dp_ci_match 'rm -rf /' 'rm\s+-rf\s+/' >/dev/null 2>&1; shopt -q nocasematch && echo on || echo off")
assert_eq "destructive-patterns: a caller that had nocasematch ON keeps it" "$DP_KEPT" "on"
DP_OFF=$(bash -c ". '$DP_LIB'; shopt -u nocasematch; _dp_ci_match 'rm -rf /' 'rm\s+-rf\s+/' >/dev/null 2>&1; shopt -q nocasematch && echo on || echo off")
assert_eq "destructive-patterns: a caller that had it OFF still gets it back off" "$DP_OFF" "off"

report_results
