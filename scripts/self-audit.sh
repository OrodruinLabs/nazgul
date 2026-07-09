#!/usr/bin/env bash
set -euo pipefail

# scripts/self-audit.sh — the testable core of the self-audit post-loop gate
# (agents/self-audit.md, ADR-001). Mines in-repo signals plus best-effort
# transcript token cost for the current objective and appends one structured,
# append-only entry per finding to the configured backlog (nazgul/improvements.md).
# Never fails the run: every source degrades to a no-op/logged message when
# absent or unreadable. Never writes the completion marker — that is the
# calling agent's job.
#
# findings.jsonl record shape (producer: scripts/lib/raise-finding.sh, TASK-009):
#   {"ts","agent","unit","severity","category","title","detail","suggested_fix","evidence"}
# All fields except ts/agent/severity/title default gracefully when absent.
#
# Usage: self-audit.sh [nazgul_dir]

NAZGUL_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul}"
PROJECT_ROOT="$(cd "$NAZGUL_DIR/.." 2>/dev/null && pwd)" || PROJECT_ROOT="$(pwd)"
CONFIG="$NAZGUL_DIR/config.json"

FEAT_ID="default"
BACKLOG_REL="nazgul/improvements.md"
if [ -f "$CONFIG" ]; then
  FEAT_ID=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null) || FEAT_ID="default"
  BACKLOG_REL=$(jq -r '.self_audit.backlog_path // "nazgul/improvements.md"' "$CONFIG" 2>/dev/null) \
    || BACKLOG_REL="nazgul/improvements.md"
fi
[ -n "$FEAT_ID" ] || FEAT_ID="default"
[ -n "$BACKLOG_REL" ] || BACKLOG_REL="nazgul/improvements.md"

case "$BACKLOG_REL" in
  /*) BACKLOG_PATH="$BACKLOG_REL" ;;
  *)  BACKLOG_PATH="$PROJECT_ROOT/$BACKLOG_REL" ;;
esac

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$BACKLOG_PATH")"
if [ ! -f "$BACKLOG_PATH" ]; then
  printf '# Improvements Backlog\n\nAppend-only findings surfaced by the self-audit post-loop gate.\nOne `##` section per finding; `Status` starts `open`.\n' \
    > "$BACKLOG_PATH"
fi

# _append_finding <severity> <leverage> <title> <evidence> <suggested_fix>
_append_finding() {
  {
    printf '\n## [%s] %s — %s\n' "$FEAT_ID" "$TS" "$3"
    printf -- '- **Severity/Leverage**: %s / %s\n' "$1" "$2"
    printf -- '- **Evidence**: %s\n' "$4"
    printf -- '- **Suggested fix**: %s\n' "$5"
    printf -- '- **Status**: open\n'
  } >> "$BACKLOG_PATH"
}

_mine_review_rejections() {
  local reviews_dir="$NAZGUL_DIR/reviews" unit_dir unit reviewer_file reviewer rejected
  [ -d "$reviews_dir" ] || return 0
  for unit_dir in "$reviews_dir"/*/; do
    [ -d "$unit_dir" ] || continue
    unit=$(basename "$unit_dir")
    for reviewer_file in "$unit_dir"*.md; do
      [ -f "$reviewer_file" ] || continue
      rejected=0
      if grep -qE '^verdict:[[:space:]]*CHANGES_REQUESTED[[:space:]]*$' "$reviewer_file" 2>/dev/null; then
        rejected=1
      elif grep -q 'REJECT' "$reviewer_file" 2>/dev/null; then
        rejected=1
      fi
      [ "$rejected" -eq 1 ] || continue
      reviewer=$(basename "$reviewer_file" .md)
      _append_finding "medium" "medium" \
        "Review rejection: ${unit}/${reviewer}" \
        "nazgul/reviews/${unit}/${reviewer}.md recorded a CHANGES_REQUESTED/REJECT verdict" \
        "Check nazgul/reviews/${unit}/consolidated-feedback.md for the recurring driver; consider /nazgul:learn if it repeats across tasks."
    done
  done
}

_mine_guard_blocks() {
  local logs_dir="$NAZGUL_DIR/logs" f line ev count=0 detail=""
  [ -d "$logs_dir" ] || return 0
  for f in "$logs_dir"/*.jsonl; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "findings.jsonl" ] && continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue
      ev=$(printf '%s' "$line" | jq -r 'select(.event == "blocked") | (.task_id // "unknown") + ":" + (.reason // "unspecified")' 2>/dev/null) || ev=""
      [ -n "$ev" ] || continue
      count=$((count + 1))
      detail="${detail}${detail:+, }${ev}"
    done < "$f"
  done
  [ "$count" -gt 0 ] || return 0
  _append_finding "medium" "low" \
    "${count} loop-blocked event(s) recorded in nazgul/logs/" \
    "nazgul/logs/*.jsonl \"blocked\" events: ${detail}" \
    "Review recurring block reasons; if one dominates, consider a targeted fix or a learned rule."
}

_mine_todo_delta() {
  [ -d "$PROJECT_ROOT/.git" ] || return 0
  local base_ref="" diff_ref="" added files
  base_ref=$(jq -r '.branch.base // empty' "$CONFIG" 2>/dev/null) || base_ref=""
  if [ -n "$base_ref" ] && git -C "$PROJECT_ROOT" rev-parse --verify -q "$base_ref" >/dev/null 2>&1; then
    diff_ref="$base_ref"
  elif git -C "$PROJECT_ROOT" rev-parse --verify -q "HEAD~1" >/dev/null 2>&1; then
    diff_ref="HEAD~1"
  else
    return 0
  fi
  added=$(git -C "$PROJECT_ROOT" diff "${diff_ref}...HEAD" -- . 2>/dev/null \
    | grep -cE '^\+[^+].*(TODO|FIXME)' 2>/dev/null) || added=0
  case "$added" in ''|*[!0-9]*) added=0 ;; esac
  [ "$added" -gt 0 ] || return 0
  files=$(git -C "$PROJECT_ROOT" diff --name-only "${diff_ref}...HEAD" -- . 2>/dev/null \
    | grep -v '^nazgul/' | tr '\n' ',' | sed 's/,$//') || files=""
  _append_finding "low" "low" \
    "TODO/FIXME delta: ${added} new marker(s) since ${diff_ref}" \
    "git diff ${diff_ref}...HEAD shows ${added} new TODO/FIXME line(s) in: ${files:-<no changed files>}" \
    "Review the new TODO/FIXME markers; convert into tracked tasks or resolve before the next objective."
}

_mine_task_retries() {
  local tasks_dir="$NAZGUL_DIR/tasks" f n id
  [ -d "$tasks_dir" ] || return 0
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    n=$(grep -E '^\-[[:space:]]*\*\*Retry count\*\*:' "$f" 2>/dev/null | head -1 | sed -E 's#.*:[[:space:]]*([0-9]+)/.*#\1#') || n=""
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt 0 ] || continue
    id=$(basename "$f" .md)
    _append_finding "medium" "medium" \
      "${id} required ${n} retry attempt(s)" \
      "nazgul/tasks/${id}.md — Retry count: ${n}" \
      "Read nazgul/reviews/${id}/consolidated-feedback.md for the recurring rejection driver."
  done
}

# _expected_model_for <subagent-name> -> the configured model tier it should
# have dispatched at, per nazgul/config.json -> models (heuristic name match).
_expected_model_for() {
  local name="$1" override
  case "$name" in
    *review-gate*)
      jq -r '.models.review_orchestrator // .models.review // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *reviewer*)
      override=$(jq -r --arg n "$name" '.models.review_by_reviewer[$n] // empty' "$CONFIG" 2>/dev/null) || override=""
      if [ -n "$override" ]; then
        printf '%s\n' "$override"
      else
        jq -r '.models.review_default // .models.review // "haiku"' "$CONFIG" 2>/dev/null || echo "haiku"
      fi ;;
    *conductor*)
      jq -r '.models.conductor // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *planner*|*planning*)
      jq -r '.models.planning // "opus"' "$CONFIG" 2>/dev/null || echo "opus" ;;
    *discovery*)
      jq -r '.models.discovery // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *doc-generator*|*docs*)
      jq -r '.models.docs // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *implementer*)
      jq -r '.models.implementation // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *designer*|*frontend-dev*|*mobile-dev*|*devops*|*cicd*|*db-migration*|*debugger*)
      jq -r '.models.specialists // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *learner*|*doc-verifier*|*comment-verifier*|*documentation*|*release-manager*|*observability*|*self-audit*)
      jq -r '.models.post_loop // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
    *)
      jq -r '.models.default // "sonnet"' "$CONFIG" 2>/dev/null || echo "sonnet" ;;
  esac
}

# _transcripts_dir -> the host session-transcript root for this project.
# NAZGUL_TRANSCRIPTS_DIR overrides for testability; otherwise
# ~/.claude/projects/<slug>, where <slug> is PROJECT_ROOT with '/' -> '-'
# (Claude Code's own project-directory encoding).
_transcripts_dir() {
  if [ -n "${NAZGUL_TRANSCRIPTS_DIR:-}" ]; then
    printf '%s\n' "$NAZGUL_TRANSCRIPTS_DIR"
    return 0
  fi
  printf '%s\n' "${HOME:-}/.claude/projects/$(printf '%s' "$PROJECT_ROOT" | tr '/' '-')"
}

_mine_token_cost() {
  local dir files=() f name expected actual
  dir=$(_transcripts_dir)
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "self-audit: cost data unavailable (transcript dir not found: ${dir:-unset})"
    return 0
  fi
  shopt -s nullglob
  files=("$dir"/*/subagents/*.jsonl)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    echo "self-audit: cost data unavailable (no subagent transcripts under ${dir})"
    return 0
  fi
  for f in "${files[@]}"; do
    name=$(basename "$f" .jsonl)
    expected=$(_expected_model_for "$name") || expected=""
    actual=$(jq -r 'select(.message.model != null) | .message.model' "$f" 2>/dev/null | tail -1) || actual=""
    [ -n "$actual" ] || continue
    [ -n "$expected" ] || continue
    [ "$actual" = "$expected" ] && continue
    _append_finding "high" "high" \
      "Model-tier drift: ${name} ran on ${actual} (expected ${expected})" \
      "${f} shows message.model=\"${actual}\"; nazgul/config.json models resolve ${name} to \"${expected}\"" \
      "Pin the dispatch call site for ${name} to model=\"${expected}\" (or update the models config if the higher tier is intentional)."
  done
}

_ingest_findings_jsonl() {
  local f="$NAZGUL_DIR/logs/findings.jsonl" line seen_file key
  local severity category title detail fix evidence agent unit ev
  [ -f "$f" ] || return 0
  seen_file=$(mktemp)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue
    title=$(printf '%s' "$line" | jq -r '.title // "untitled finding"' 2>/dev/null) || title="untitled finding"
    detail=$(printf '%s' "$line" | jq -r '.detail // ""' 2>/dev/null) || detail=""
    key="${title}|${detail}"
    if grep -qxF "$key" "$seen_file" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$key" >> "$seen_file"
    severity=$(printf '%s' "$line" | jq -r '.severity // "medium"' 2>/dev/null) || severity="medium"
    category=$(printf '%s' "$line" | jq -r '.category // "general"' 2>/dev/null) || category="general"
    fix=$(printf '%s' "$line" | jq -r '.suggested_fix // "(none provided)"' 2>/dev/null) || fix="(none provided)"
    evidence=$(printf '%s' "$line" | jq -r '.evidence // ""' 2>/dev/null) || evidence=""
    agent=$(printf '%s' "$line" | jq -r '.agent // "unknown"' 2>/dev/null) || agent="unknown"
    unit=$(printf '%s' "$line" | jq -r '.unit // ""' 2>/dev/null) || unit=""
    ev="raised by ${agent}${unit:+ (unit: ${unit})}: ${detail}${evidence:+ | evidence: ${evidence}}"
    _append_finding "$severity" "$category" "$title" "$ev" "$fix"
  done < "$f"
  rm -f "$seen_file"
}

_mine_review_rejections || true
_mine_guard_blocks || true
_mine_todo_delta || true
_mine_task_retries || true
_mine_token_cost || true
_ingest_findings_jsonl || true

echo "self-audit: mining complete for ${FEAT_ID}; backlog at ${BACKLOG_PATH}"
exit 0
