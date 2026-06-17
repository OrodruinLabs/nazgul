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

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--max abc" >/dev/null
assert_eq "non-numeric --max ignored" "$(jq -r .max_iterations "$TMP/c.json")" "40"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--max 0" >/dev/null
assert_eq "--max 0 ignored (can't brick loop)" "$(jq -r .max_iterations "$TMP/c.json")" "40"

mkcfg "$base"; bash "$APPLY" "$TMP/c.json" "--hitl --yolo" >/dev/null
assert_eq "--hitl wins over --yolo" "$(jq -r .mode "$TMP/c.json")" "hitl"

out=$(bash "$APPLY" "$TMP/none.json" "--yolo" 2>/dev/null || true)
assert_eq "missing config → hitl"  "$out" "hitl"

report_results
