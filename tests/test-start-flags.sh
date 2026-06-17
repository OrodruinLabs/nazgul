#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-start-flags"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
APPLY="$REPO_ROOT/scripts/apply-start-flags.sh"
echo "=== $TEST_NAME ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkcfg(){ printf '%s' "$1" > "$TMP/c.json"; }
base='{"mode":"hitl","afk":{"enabled":false,"yolo":false,"task_pr":false},"max_iterations":40}'

mkcfg "$base"; out=$(bash "$APPLY" "$TMP/c.json" "--yolo")
assert_eq "--yolo mode=afk"        "$(jq -r .mode "$TMP/c.json")" "afk"
assert_eq "--yolo afk.enabled"     "$(jq -r .afk.enabled "$TMP/c.json")" "true"
assert_eq "--yolo afk.yolo"        "$(jq -r .afk.yolo "$TMP/c.json")" "true"
assert_eq "--yolo prints mode"     "$out" "afk"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--afk" >/dev/null
assert_eq "--afk mode=afk"         "$(jq -r .mode "$TMP/c.json")" "afk"
assert_eq "--afk not yolo"         "$(jq -r .afk.yolo "$TMP/c.json")" "false"

mkcfg "$(echo "$base" | jq '.mode="afk"|.afk.enabled=true')"; bash "$APPLY" "$TMP/c.json" "--hitl" >/dev/null
assert_eq "--hitl mode=hitl"       "$(jq -r .mode "$TMP/c.json")" "hitl"
assert_eq "--hitl afk.enabled off" "$(jq -r .afk.enabled "$TMP/c.json")" "false"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--afk --max 20" >/dev/null
assert_eq "--max 20"               "$(jq -r .max_iterations "$TMP/c.json")" "20"
assert_eq "--afk --max mode"       "$(jq -r .mode "$TMP/c.json")" "afk"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--afk --task-pr" >/dev/null
assert_eq "--afk --task-pr"        "$(jq -r .afk.task_pr "$TMP/c.json")" "true"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--yolo --task-pr" >/dev/null
assert_eq "--yolo --task-pr yolo"  "$(jq -r .afk.yolo "$TMP/c.json")" "true"
assert_eq "--yolo --task-pr taskpr" "$(jq -r .afk.task_pr "$TMP/c.json")" "true"

mkcfg "$(echo "$base" | jq '.mode="afk"')"; bash "$APPLY" "$TMP/c.json" '"add auth"' >/dev/null
assert_eq "no mode flag → mode unchanged" "$(jq -r .mode "$TMP/c.json")" "afk"

# A flag token INSIDE the quoted objective must NOT be parsed as a flag
mkcfg "$base"; bash "$APPLY" "$TMP/c.json" '"fix the --yolo bug"' >/dev/null
assert_eq "--yolo inside objective ignored (mode unchanged)" "$(jq -r .mode "$TMP/c.json")" "hitl"
assert_eq "--yolo inside objective: afk.yolo stays false" "$(jq -r .afk.yolo "$TMP/c.json")" "false"
# ...but a real flag OUTSIDE the quoted objective still applies
mkcfg "$base"; bash "$APPLY" "$TMP/c.json" '"fix the --yolo bug" --afk' >/dev/null
assert_eq "real flag outside quotes still applies" "$(jq -r .mode "$TMP/c.json")" "afk"
# Single-quoted objective is also stripped before flag-scanning
mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "'refactor the --yolo handler'" >/dev/null
assert_eq "--yolo inside single-quoted objective ignored" "$(jq -r .mode "$TMP/c.json")" "hitl"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--max abc" >/dev/null
assert_eq "non-numeric --max ignored" "$(jq -r .max_iterations "$TMP/c.json")" "40"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--max 0" >/dev/null
assert_eq "--max 0 ignored (can't brick loop)" "$(jq -r .max_iterations "$TMP/c.json")" "40"

mkcfg "$(echo "$base" | jq '.afk.yolo=true|.afk.task_pr=true')"; bash "$APPLY" "$TMP/c.json" "--hitl --yolo" >/dev/null
assert_eq "--hitl wins over --yolo (mode)" "$(jq -r .mode "$TMP/c.json")" "hitl"
assert_eq "--hitl --yolo clears afk.yolo" "$(jq -r .afk.yolo "$TMP/c.json")" "false"
assert_eq "--hitl --yolo clears afk.task_pr" "$(jq -r .afk.task_pr "$TMP/c.json")" "false"

out=$(bash "$APPLY" "$TMP/none.json" "--yolo" 2>/dev/null || true)
assert_eq "missing config → hitl"  "$out" "hitl"

# Switching modes CLEARS stale autonomous sub-flags (the runtime gates on them).
prioryolo='{"mode":"afk","afk":{"enabled":true,"yolo":true,"task_pr":true},"max_iterations":40}'
mkcfg "$prioryolo"; bash "$APPLY" "$TMP/c.json" "--afk" >/dev/null
assert_eq "--afk after yolo clears afk.yolo"     "$(jq -r .afk.yolo "$TMP/c.json")" "false"
assert_eq "--afk after yolo clears afk.task_pr"  "$(jq -r .afk.task_pr "$TMP/c.json")" "false"
mkcfg "$prioryolo"; bash "$APPLY" "$TMP/c.json" "--hitl" >/dev/null
assert_eq "--hitl after yolo clears afk.yolo"    "$(jq -r .afk.yolo "$TMP/c.json")" "false"
assert_eq "--hitl after yolo clears afk.task_pr" "$(jq -r .afk.task_pr "$TMP/c.json")" "false"
# ...but a no-mode-flag resume PRESERVES the sub-flags (don't clobber a running yolo loop)
mkcfg "$prioryolo"; bash "$APPLY" "$TMP/c.json" '"keep going"' >/dev/null
assert_eq "no-flag resume preserves afk.yolo"    "$(jq -r .afk.yolo "$TMP/c.json")" "true"
assert_eq "no-flag resume preserves mode"        "$(jq -r .mode "$TMP/c.json")" "afk"

report_results
