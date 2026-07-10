#!/usr/bin/env bash
# scripts/lib/raise-finding.sh — the FEAT-009 finding-raise channel, PRODUCER
# side (spec item 9). Any sub-session sources this and calls raise_finding to
# surface an in-the-moment improvement candidate that survives it exiting.
# Consumed by scripts/self-audit.sh (TASK-001), which ingests
# nazgul/logs/findings.jsonl into the improvements backlog.
#
# Record is built DATA-ONLY via jq --arg (no eval, no string interpolation
# into a command). Every field value also has embedded newlines/CRs
# neutralized to a space before storage — in addition to jq's escaping — so a
# later markdown-backlog render can never have its `##`-section structure
# broken by a raw newline smuggled into a stored value.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own shell options (mirrors scripts/lib/inbox-provider.sh).

[ -n "${_NAZGUL_RAISE_FINDING_SOURCED:-}" ] && return 0
_NAZGUL_RAISE_FINDING_SOURCED=1

if command -v flock >/dev/null 2>&1; then _RF_HAS_FLOCK=1; else _RF_HAS_FLOCK=0; fi

_rf_neutralize() {
  local v="$1"
  v="${v//$'\r'/ }"
  v="${v//$'\n'/ }"
  printf '%s' "$v"
}

# raise_finding <severity> <category> <title> <detail> [suggested_fix] [evidence]
# -> append one JSON line to $NAZGUL_DIR/logs/findings.jsonl (falls back to
# $CLAUDE_PROJECT_DIR/nazgul, then ./nazgul, when NAZGUL_DIR is unset).
# ts is UTC now; agent/unit come from $NAZGUL_AGENT/$NAZGUL_UNIT (empty when unset).
raise_finding() {
  # Argc guard FIRST: this is sourced into caller shells that may run `set -u`,
  # where expanding an unset $1..$4 would raise "unbound variable" and abort the
  # CALLER. Fail with a usage message and a nonzero return instead — never let a
  # mis-call take down the sub-session that raised the finding.
  if [ "$#" -lt 4 ]; then
    printf 'raise_finding: need >=4 args: <severity> <category> <title> <detail> [suggested_fix] [evidence]\n' >&2
    return 2
  fi
  local severity="$1" category="$2" title="$3" detail="$4"
  local suggested_fix="${5:-}" evidence="${6:-}"
  local nazgul_dir="${NAZGUL_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul}"
  local findings_file="$nazgul_dir/logs/findings.jsonl"
  mkdir -p "$nazgul_dir/logs"

  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  severity=$(_rf_neutralize "$severity")
  category=$(_rf_neutralize "$category")
  title=$(_rf_neutralize "$title")
  detail=$(_rf_neutralize "$detail")
  suggested_fix=$(_rf_neutralize "$suggested_fix")
  evidence=$(_rf_neutralize "$evidence")

  local record
  record=$(jq -cn \
    --arg ts "$ts" \
    --arg agent "${NAZGUL_AGENT:-}" \
    --arg unit "${NAZGUL_UNIT:-}" \
    --arg severity "$severity" \
    --arg category "$category" \
    --arg title "$title" \
    --arg detail "$detail" \
    --arg suggested_fix "$suggested_fix" \
    --arg evidence "$evidence" \
    '{ts:$ts, agent:$agent, unit:$unit, severity:$severity, category:$category,
      title:$title, detail:$detail, suggested_fix:$suggested_fix, evidence:$evidence}')

  local lockfile="${findings_file}.lock"
  if [ "$_RF_HAS_FLOCK" = "1" ]; then
    ( flock -x 200; printf '%s\n' "$record" >> "$findings_file" ) 200>"$lockfile"
  else
    printf '%s\n' "$record" >> "$findings_file"
  fi
}
