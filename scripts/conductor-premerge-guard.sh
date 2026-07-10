#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Pre-Merge Guard — PreToolUse on Bash `git merge`.
# Enforces FEAT-009 H2: a unit branch is never merged into the feature branch
# without a recorded DONE + APPROVE verdict in graph.json — exactly how
# TASK-004 got merged unreviewed this session (the review-gate bypass).
# No-op unless a conductor run is active. Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$CMD" ] && CMD="$INPUT"
[ -z "$CMD" ] && exit 0
printf '%s' "$CMD" | grep -qE 'git[[:space:]]+merge' || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
GRAPH="$NAZGUL_DIR/conductor/graph.json"
SESSION_MARKER="$NAZGUL_DIR/conductor/.session"

# Scope: only during an active conductor run.
[ -f "$CONFIG" ] || exit 0
[ -f "$SESSION_MARKER" ] || exit 0
[ -f "$GRAPH" ] || exit 0
ENGINE=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
[ "$ENGINE" = "conductor" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .conductor.enforce.premerge_guard == null then "true" else (.conductor.enforce.premerge_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

# Identify EVERY unit actually being merged: the positional (non-flag) branch
# arguments of each `git merge` invocation, split on ;/&/&&/| so a compound or
# octopus command is evaluated segment-by-segment. Value-taking flags
# (-m/--message/-F/--file/-s/--strategy/-X/--strategy-option/--into-name) have
# their value token skipped so a unit-shaped string inside a commit message can
# never be mistaken for the actual merge target — matched as DATA (awk), never
# eval'd against the command string.
UNITS=$(printf '%s' "$CMD" | awk '
function reset_segment() {
  git_seen = 0; subcmd_seen = 0; not_relevant = 0
  skip_next = 0; skip_global_val = 0; end_of_opts = 0
}
function check_positional(t) {
  if (t !~ /feat\/[A-Za-z0-9_.-]+\/TASK-[0-9]+/) return
  match(t, /TASK-[0-9]+/)
  print substr(t, RSTART, RLENGTH)
}
function emit(t,   is_value_flag) {
  if (not_relevant) return
  if (skip_next) { skip_next = 0; return }
  if (skip_global_val) { skip_global_val = 0; return }
  if (!git_seen) {
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    if (t != "git") { not_relevant = 1; return }
    git_seen = 1; return
  }
  if (!subcmd_seen) {
    if (t ~ /^(-C|-c)$/) { skip_global_val = 1; return }
    if (t ~ /^--(git-dir|work-tree|exec-path|namespace)=/) return
    if (t ~ /^(-p|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs)$/) return
    if (t != "merge") { not_relevant = 1; return }
    subcmd_seen = 1; return
  }
  if (end_of_opts) { check_positional(t); return }
  if (t == "--") { end_of_opts = 1; return }
  is_value_flag = (t ~ /^(-m|--message|-F|--file|-s|--strategy|-X|--strategy-option|--into-name)$/)
  if (is_value_flag) { skip_next = 1; return }
  if (t ~ /^--(message|strategy|strategy-option|into-name|file)=/) return
  if (t ~ /^-/) return
  check_positional(t)
}
BEGIN { reset_segment(); tok = ""; in_sq = 0; in_dq = 0 }
{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (in_sq) {
      if (c == "'\''") in_sq = 0
      else tok = tok c
    } else if (in_dq) {
      if (c == "\\" && i < n) { i++; tok = tok substr($0, i, 1) }
      else if (c == "\"") in_dq = 0
      else tok = tok c
    } else if (c == "'\''") {
      in_sq = 1
    } else if (c == "\"") {
      in_dq = 1
    } else if (c == " " || c == "\t") {
      if (tok != "") { emit(tok); tok = "" }
    } else if (c == ";" || c == "|") {
      if (tok != "") { emit(tok); tok = "" }
      reset_segment()
    } else if (c == "&") {
      if (tok != "") { emit(tok); tok = "" }
      reset_segment()
    } else {
      tok = tok c
    }
  }
  if (in_sq || in_dq) {
    # quoted string spans the newline — keep accumulating
  } else {
    if (tok != "") { emit(tok); tok = "" }
    reset_segment()
  }
}
' | sort -u)

[ -n "$UNITS" ] || exit 0

DENIED=""
while IFS= read -r UNIT; do
  [ -z "$UNIT" ] && continue
  STATUS=$(jq -r --arg id "$UNIT" '.tasks[$id].status // ""' "$GRAPH" 2>/dev/null || echo "")
  VERDICT=$(jq -r --arg id "$UNIT" '.tasks[$id].verdict // ""' "$GRAPH" 2>/dev/null || echo "")
  if [ "$STATUS" != "DONE" ] || ! printf '%s' "$VERDICT" | grep -qiE '^APPROVE'; then
    DENIED="$DENIED $UNIT(status='${STATUS:-none}',verdict='${VERDICT:-none}')"
  fi
done <<< "$UNITS"

[ -z "$DENIED" ] && exit 0

echo "NAZGUL CONDUCTOR: Blocked — merge includes unit(s) with no recorded DONE+APPROVE verdict:$DENIED; this is the review-gate-bypass class of defect (FEAT-009 H2, agents/conductor.md Step 6)." >&2
exit 2
