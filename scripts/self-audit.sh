#!/usr/bin/env bash
set -euo pipefail

# scripts/self-audit.sh — the testable core of the self-audit post-loop gate
# (agents/self-audit.md, ADR-001). Mines in-repo signals plus best-effort
# transcript token cost for the current objective and appends one structured,
# append-only entry per finding to the configured backlog (nazgul/improvements.md).
# Never fails the run: every source degrades to a no-op/logged message when
# absent or unreadable — an unwritable backlog logs and exits 0, and each append
# degrades to a logged no-op. Never writes the completion marker — that is the
# calling agent's job.
#
# Every miner reports `scanned / skipped / checked / findings` on its own line
# and the run prints a total (RULES §1 rule 2, FEAT-028/ADR-019): a miner that
# looked and found nothing must be distinguishable from one that never looked.
# Skip reasons are a CLOSED list shared by all miners so the total is summable:
#   unreadable      — the item exists but could not be read
#   unclassifiable  — read, but carries no signal this miner can classify
#   not-applicable  — deliberately out of this miner's window or remit
#
# Two mechanisms keep the backlog from re-accumulating what it already holds:
# a (title, first line of evidence) dedupe seeded from the backlog on disk, and
# a per-file high-water mark for the line-oriented log windows, persisted to
# nazgul/self-audit-window.json so the next run starts after the last one. The
# snapshot miners (reviews, retries, transcripts, spawn ratio) compare current
# totals and are deliberately NOT windowed; the dedupe covers their repeats.
#
# Transcript attribution: the host records the dispatched role in
# `.message.attributionAgent`/`.attributionAgent`. Transcript FILENAMES are
# opaque ids matching no role pattern, so resolving the role from the filename
# compared every subagent against models.default.
#
# Transcript location: <CLAUDE_CONFIG_DIR or ~/.claude>/projects/<slug>, slug
# being PROJECT_ROOT with every non-alphanumeric char mapped to '-' (Claude
# Code's own encoding). NAZGUL_TRANSCRIPTS_DIR overrides for testability.
#
# Model comparison: a configured BARE alias (sonnet/haiku/opus) is a family pin
# and matches any resolved id of that family; a configured full model id stays
# an exact pin so version drift still reports.
#
# findings.jsonl record shape (producer: scripts/lib/raise-finding.sh, TASK-009):
#   {"ts","agent","unit","severity","category","title","detail","suggested_fix","evidence"}
# All fields except ts/agent/severity/title default gracefully when absent.
#
# Usage: self-audit.sh [nazgul_dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="${1:-$(resolve_nazgul_dir)}"
PROJECT_ROOT="$(cd "$NAZGUL_DIR/.." 2>/dev/null && pwd)" || PROJECT_ROOT="$(resolve_project_root)"
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

# Best-effort backlog init: under `set -euo pipefail` a bad self_audit.backlog_path
# or read-only FS would otherwise abort the run here (see the header contract).
if ! mkdir -p "$(dirname "$BACKLOG_PATH")" 2>/dev/null; then
  echo "self-audit: cannot create backlog dir for ${BACKLOG_PATH} — skipping (run not failed)" >&2
  exit 0
fi
if [ ! -f "$BACKLOG_PATH" ]; then
  if ! printf '# Improvements Backlog\n\nAppend-only findings surfaced by the self-audit post-loop gate.\nOne `##` section per finding; `Status` starts `open`.\n' \
      > "$BACKLOG_PATH" 2>/dev/null; then
    echo "self-audit: backlog ${BACKLOG_PATH} not writable — skipping (run not failed)" >&2
    exit 0
  fi
fi

RUN_SCANNED=0
RUN_UNREADABLE=0
RUN_UNCLASSIFIABLE=0
RUN_NOT_APPLICABLE=0
RUN_CHECKED=0
RUN_FINDINGS=0
RUN_SUPPRESSED=0

# _coverage <miner> <scanned> <unreadable> <unclassifiable> <not-applicable> <checked> <findings>
# One fixed-grammar line per miner; also accumulates the run total.
_coverage() {
  local miner="$1" scanned="$2" unread="$3" unclass="$4" na="$5" checked="$6" findings="$7"
  local skipped=$((unread + unclass + na))
  if [ "$scanned" -ne $((skipped + checked)) ]; then
    printf 'self-audit: INTERNAL — coverage accounting mismatch in %s: %d scanned != %d skipped + %d checked\n' \
      "$miner" "$scanned" "$skipped" "$checked" >&2
  fi
  printf 'self-audit/%s: %d scanned, %d skipped (unreadable=%d, unclassifiable=%d, not-applicable=%d), %d checked, %d findings\n' \
    "$miner" "$scanned" "$skipped" "$unread" "$unclass" "$na" "$checked" "$findings"
  RUN_SCANNED=$((RUN_SCANNED + scanned))
  RUN_UNREADABLE=$((RUN_UNREADABLE + unread))
  RUN_UNCLASSIFIABLE=$((RUN_UNCLASSIFIABLE + unclass))
  RUN_NOT_APPLICABLE=$((RUN_NOT_APPLICABLE + na))
  RUN_CHECKED=$((RUN_CHECKED + checked))
  RUN_FINDINGS=$((RUN_FINDINGS + findings))
}

_run_coverage() {
  local skipped=$((RUN_UNREADABLE + RUN_UNCLASSIFIABLE + RUN_NOT_APPLICABLE))
  if [ "$RUN_SCANNED" -ne $((skipped + RUN_CHECKED)) ]; then
    printf 'self-audit: INTERNAL — coverage accounting mismatch: %d scanned != %d skipped + %d checked\n' \
      "$RUN_SCANNED" "$skipped" "$RUN_CHECKED" >&2
  fi
  if [ "$RUN_CHECKED" -eq 0 ] && [ "$RUN_SCANNED" -gt 0 ]; then
    printf 'self-audit: NOTHING CHECKED — all %d candidate(s) skipped\n' "$RUN_SCANNED" >&2
  fi
  printf 'self-audit: %d scanned, %d skipped (unreadable=%d, unclassifiable=%d, not-applicable=%d), %d checked, %d findings\n' \
    "$RUN_SCANNED" "$skipped" "$RUN_UNREADABLE" "$RUN_UNCLASSIFIABLE" "$RUN_NOT_APPLICABLE" \
    "$RUN_CHECKED" "$RUN_FINDINGS"
  [ "$RUN_SUPPRESSED" -eq 0 ] || \
    printf 'self-audit: %d finding(s) suppressed as already present in the backlog (title + evidence)\n' \
      "$RUN_SUPPRESSED"
}

SEEN_FILE=""

# The backlog on disk IS the record of what was already appended, so the dedupe
# index is rebuilt from it rather than from state that could drift out of sync.
_init_dedupe() {
  SEEN_FILE=$(mktemp 2>/dev/null) || {
    SEEN_FILE=""
    echo "self-audit: mktemp failed — duplicate suppression disabled for this run (run not failed)" >&2
    return 0
  }
  awk '
    /^## \[/ { t=$0; sub(/^## \[[^]]*\] [^ ]+ — /, "", t); title=t; next }
    /^- \*\*Evidence\*\*: / && title != "" {
      e=$0; sub(/^- \*\*Evidence\*\*: /, "", e); print title "|" e; title=""
    }
  ' "$BACKLOG_PATH" >> "$SEEN_FILE" 2>/dev/null || true
}

# _append_finding <severity> <leverage> <title> <evidence> <suggested_fix>
# Returns 0 when an entry was appended, 1 when suppressed or unwritable.
_append_finding() {
  local key="${3%%$'\n'*}|${4%%$'\n'*}"
  if [ -n "$SEEN_FILE" ] && grep -qxF "$key" "$SEEN_FILE" 2>/dev/null; then
    RUN_SUPPRESSED=$((RUN_SUPPRESSED + 1))
    return 1
  fi
  {
    printf '\n## [%s] %s — %s\n' "$FEAT_ID" "$TS" "$3"
    printf -- '- **Severity/Leverage**: %s / %s\n' "$1" "$2"
    printf -- '- **Evidence**: %s\n' "$4"
    printf -- '- **Suggested fix**: %s\n' "$5"
    printf -- '- **Status**: open\n'
  } >> "$BACKLOG_PATH" 2>/dev/null || {
    echo "self-audit: append to ${BACKLOG_PATH} failed — skipping this finding (run not failed)" >&2
    return 1
  }
  [ -z "$SEEN_FILE" ] || printf '%s\n' "$key" >> "$SEEN_FILE" 2>/dev/null || true
  return 0
}

WINDOW_FILE="$NAZGUL_DIR/self-audit-window.json"
WINDOW_JSON='{}'

_init_window() {
  [ -f "$WINDOW_FILE" ] || return 0
  WINDOW_JSON=$(jq -c 'if type == "object" then . else {} end' "$WINDOW_FILE" 2>/dev/null) || WINDOW_JSON='{}'
  [ -n "$WINDOW_JSON" ] || WINDOW_JSON='{}'
}

# _window_mark <miner> <file-key> -> lines of that file already mined.
_window_mark() {
  local m
  m=$(printf '%s' "$WINDOW_JSON" | jq -r --arg m "$1" --arg f "$2" '.[$m][$f] // 0' 2>/dev/null) || m=0
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# _window_set <miner> <file-key> <lines> — held in memory until _persist_window.
_window_set() {
  local next
  next=$(printf '%s' "$WINDOW_JSON" \
    | jq -c --arg m "$1" --arg f "$2" --argjson n "$3" '.[$m] = ((.[$m] // {}) + {($f): $n})' 2>/dev/null) || return 0
  [ -n "$next" ] || return 0
  WINDOW_JSON="$next"
}

_persist_window() {
  printf '%s\n' "$WINDOW_JSON" > "$WINDOW_FILE" 2>/dev/null || \
    echo "self-audit: cannot persist ${WINDOW_FILE} — the next run will re-mine this window (run not failed)" >&2
}

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _review_verdict <file> -> the recorded verdict token, upper-cased, or empty.
# `grep -a` is mandatory: BSD grep reports NO match in a NUL-bearing verdict file.
_review_verdict() {
  local raw
  raw=$(grep -aoEi '^[[:space:]]*\**verdict\**:[[:space:]]*[A-Za-z_]+' "$1" 2>/dev/null | head -1) || raw=""
  [ -n "$raw" ] || return 0
  printf '%s' "${raw##*:}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

# The verdict is the ONLY rejection signal. A prose word match used to fire on
# `- **REJECT**: none.`, the line a lane writes when it has no rejections.
_mine_review_rejections() {
  local reviews_dir="$NAZGUL_DIR/reviews" unit_dir unit reviewer_file reviewer verdict
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  if [ ! -d "$reviews_dir" ]; then
    _coverage "review-rejections" 0 0 0 0 0 0
    return 0
  fi
  for unit_dir in "$reviews_dir"/*/; do
    [ -d "$unit_dir" ] || continue
    unit=$(basename "$unit_dir")
    for reviewer_file in "$unit_dir"*.md; do
      [ -e "$reviewer_file" ] || continue
      scanned=$((scanned + 1))
      reviewer=$(basename "$reviewer_file" .md)
      if [ "$reviewer" = "consolidated-feedback" ]; then
        na=$((na + 1))
        continue
      fi
      if [ ! -f "$reviewer_file" ] || [ ! -r "$reviewer_file" ]; then
        unread=$((unread + 1))
        continue
      fi
      verdict=$(_review_verdict "$reviewer_file")
      if [ -z "$verdict" ]; then
        unclass=$((unclass + 1))
        continue
      fi
      checked=$((checked + 1))
      case "$verdict" in
        CHANGES_REQUESTED|CHANGESREQUESTED|REJECT|REJECTED) ;;
        *) continue ;;
      esac
      if _append_finding "medium" "medium" \
        "Review rejection: ${unit}/${reviewer}" \
        "nazgul/reviews/${unit}/${reviewer}.md recorded verdict ${verdict}" \
        "Check nazgul/reviews/${unit}/consolidated-feedback.md for the recurring driver; consider /nazgul:learn if it repeats across tasks."; then
        findings=$((findings + 1))
      fi
    done
  done
  _coverage "review-rejections" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

# _log_lines <file> -> newline count, which is exactly what `while read` consumes.
_log_lines() {
  local n
  n=$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]') || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

_mine_guard_blocks() {
  local logs_dir="$NAZGUL_DIR/logs" f key line ev lineno mark total detail="" blocked=0
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  if [ ! -d "$logs_dir" ]; then
    _coverage "guard-blocks" 0 0 0 0 0 0
    return 0
  fi
  for f in "$logs_dir"/*.jsonl; do
    [ -e "$f" ] || continue
    key=$(basename "$f")
    total=$(_log_lines "$f")
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      scanned=$((scanned + 1))
      unread=$((unread + 1))
      continue
    fi
    if [ "$key" = "findings.jsonl" ]; then
      scanned=$((scanned + total))
      na=$((na + total))
      continue
    fi
    mark=$(_window_mark "guard_blocks" "$key")
    if [ "$mark" -gt "$total" ]; then
      echo "self-audit: ${key} is shorter than the recorded mark (${mark} > ${total}) — re-mining it from the start"
      mark=0
    fi
    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      scanned=$((scanned + 1))
      if [ "$lineno" -le "$mark" ] || [ -z "$line" ]; then
        na=$((na + 1))
        continue
      fi
      if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        unclass=$((unclass + 1))
        continue
      fi
      checked=$((checked + 1))
      ev=$(printf '%s' "$line" | jq -r 'select(.event == "blocked") | (.task_id // "unknown") + ":" + (.reason // "unspecified")' 2>/dev/null) || ev=""
      [ -n "$ev" ] || continue
      blocked=$((blocked + 1))
      detail="${detail}${detail:+, }${ev}"
    done < "$f"
    _window_set "guard_blocks" "$key" "$lineno"
  done
  if [ "$blocked" -gt 0 ]; then
    if _append_finding "medium" "low" \
      "${blocked} loop-blocked event(s) recorded in nazgul/logs/" \
      "nazgul/logs/*.jsonl \"blocked\" events: ${detail}" \
      "Review recurring block reasons; if one dominates, consider a targeted fix or a learned rule."; then
      findings=1
    fi
  fi
  _coverage "guard-blocks" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

# MF-047 heuristic (RULES.md §17 Layer 2, advisory not proof): flags M < N,
# fewer dispatch manifests than logged spawns. Cumulative, so never windowed.
_mine_teammate_spawn_discrepancy() {
  local logs_dir="$NAZGUL_DIR/logs" dispatch_dir="$NAZGUL_DIR/dispatch"
  local f line skip_n spawned=0 manifests=0
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  if [ ! -d "$logs_dir" ]; then
    _coverage "teammate-spawns" 0 0 0 0 0 0
    return 0
  fi
  for f in "$logs_dir"/*.jsonl; do
    [ -e "$f" ] || continue
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      scanned=$((scanned + 1))
      unread=$((unread + 1))
      continue
    fi
    if [ "$(basename "$f")" = "findings.jsonl" ]; then
      skip_n=$(_log_lines "$f")
      scanned=$((scanned + skip_n))
      na=$((na + skip_n))
      continue
    fi
    while IFS= read -r line; do
      scanned=$((scanned + 1))
      if [ -z "$line" ]; then
        na=$((na + 1))
        continue
      fi
      if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        unclass=$((unclass + 1))
        continue
      fi
      checked=$((checked + 1))
      if printf '%s' "$line" | jq -e 'select(.event == "teammate_spawned")' >/dev/null 2>&1; then
        spawned=$((spawned + 1))
      fi
    done < "$f"
  done
  if [ "$spawned" -gt 0 ]; then
    if [ -d "$dispatch_dir" ]; then
      for f in "$dispatch_dir"/*.json; do
        [ -f "$f" ] || continue
        manifests=$((manifests + 1))
      done
    fi
    if [ "$manifests" -lt "$spawned" ]; then
      if _append_finding "medium" "medium" \
        "Teammate spawn/manifest discrepancy: ${spawned} logged spawn(s), ${manifests} dispatch manifest(s)" \
        "nazgul/logs/*.jsonl records ${spawned} teammate_spawned event(s); nazgul/dispatch/*.json currently has ${manifests} manifest(s) — fewer than logged spawns" \
        "Confirm whether the missing manifest(s) reflect legitimate post-teardown cleanup or a dispatcher that skipped Layer 2 of the Teammate Report Contract (RULES.md §17); a skipped manifest means teammate-idle-guard.sh never enforced that teammate's report at all."; then
        findings=1
      fi
    fi
  fi
  _coverage "teammate-spawns" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

_mine_todo_delta() {
  local base_ref="" diff_ref="" added files findings=0
  if [ ! -d "$PROJECT_ROOT/.git" ]; then
    _coverage "todo-delta" 1 0 0 1 0 0
    return 0
  fi
  base_ref=$(jq -r '.branch.base // empty' "$CONFIG" 2>/dev/null) || base_ref=""
  if [ -n "$base_ref" ] && git -C "$PROJECT_ROOT" rev-parse --verify -q "$base_ref" >/dev/null 2>&1; then
    diff_ref="$base_ref"
  elif git -C "$PROJECT_ROOT" rev-parse --verify -q "HEAD~1" >/dev/null 2>&1; then
    diff_ref="HEAD~1"
  else
    _coverage "todo-delta" 1 0 1 0 0 0
    return 0
  fi
  added=$(git -C "$PROJECT_ROOT" diff "${diff_ref}...HEAD" -- . 2>/dev/null \
    | grep -acE '^\+[^+].*(TODO|FIXME)' 2>/dev/null) || added=0
  case "$added" in ''|*[!0-9]*) added=0 ;; esac
  if [ "$added" -gt 0 ]; then
    files=$(git -C "$PROJECT_ROOT" diff --name-only "${diff_ref}...HEAD" -- . 2>/dev/null \
      | grep -v '^nazgul/' | tr '\n' ',' | sed 's/,$//') || files=""
    if _append_finding "low" "low" \
      "TODO/FIXME delta: ${added} new marker(s) since ${diff_ref}" \
      "git diff ${diff_ref}...HEAD shows ${added} new TODO/FIXME line(s) in: ${files:-<no changed files>}" \
      "Review the new TODO/FIXME markers; convert into tracked tasks or resolve before the next objective."; then
      findings=1
    fi
  fi
  _coverage "todo-delta" 1 0 0 0 1 "$findings"
}

_mine_task_retries() {
  local tasks_dir="$NAZGUL_DIR/tasks" f n id
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  if [ ! -d "$tasks_dir" ]; then
    _coverage "task-retries" 0 0 0 0 0 0
    return 0
  fi
  for f in "$tasks_dir"/TASK-*.md; do
    [ -e "$f" ] || continue
    scanned=$((scanned + 1))
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      unread=$((unread + 1))
      continue
    fi
    n=$(grep -aE '^\-[[:space:]]*\*\*Retry count\*\*:' "$f" 2>/dev/null | head -1 | sed -E 's#.*:[[:space:]]*([0-9]+)/.*#\1#') || n=""
    case "$n" in ''|*[!0-9]*) unclass=$((unclass + 1)); continue ;; esac
    checked=$((checked + 1))
    [ "$n" -gt 0 ] || continue
    id=$(basename "$f" .md)
    if _append_finding "medium" "medium" \
      "${id} required ${n} retry attempt(s)" \
      "nazgul/tasks/${id}.md — Retry count: ${n}" \
      "Read nazgul/reviews/${id}/consolidated-feedback.md for the recurring rejection driver."; then
      findings=$((findings + 1))
    fi
  done
  _coverage "task-retries" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

# _expected_model_for <agent-role> -> the configured model tier it should
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
    *feedback-aggregator*)
      # review-gate dispatches feedback-aggregator on the reviewer-default chain,
      # NOT models.default — otherwise every haiku one reads as tier drift.
      jq -r '.models.review_default // .models.review // "haiku"' "$CONFIG" 2>/dev/null || echo "haiku" ;;
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

# _transcripts_dir -> the host session-transcript root (see the header contract).
_transcripts_dir() {
  if [ -n "${NAZGUL_TRANSCRIPTS_DIR:-}" ]; then
    printf '%s\n' "$NAZGUL_TRANSCRIPTS_DIR"
    return 0
  fi
  local base slug expected base_slug
  base="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  slug=$(printf '%s' "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9]/-/g')
  expected="$base/projects/$slug"
  if [ -d "$expected" ]; then
    printf '%s\n' "$expected"
    return 0
  fi
  base_slug=$(basename "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9]/-/g')
  # Trust the basename-glob drift fallback only on EXACTLY ONE match: several
  # projects can share a leaf slug, and picking one could mine an unrelated one.
  local matches=() d
  for d in "$base/projects/"*"$base_slug"; do
    [ -d "$d" ] && matches+=("$d")
  done
  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  printf '%s\n' "$expected"
}

# _attribution_role <transcript> -> the host-recorded agent role, normalized
# (see the attribution note in the header contract).
_attribution_role() {
  local raw
  raw=$(jq -r 'select((.message.attributionAgent // .attributionAgent // "") != "")
               | (.message.attributionAgent // .attributionAgent)' "$1" 2>/dev/null | head -1) || raw=""
  [ -n "$raw" ] || return 0
  while [ "${raw#nazgul:}" != "$raw" ]; do raw="${raw#nazgul:}"; done
  raw="${raw#nazgul-}"
  # Closed list of generic harness agent types: they name no Nazgul role, so
  # they are reported unclassifiable rather than guessed at.
  case "$(_lower "$raw")" in
    general-purpose|general_purpose|'general purpose'|explore|plan|output-style-setup|statusline-setup) return 0 ;;
  esac
  printf '%s' "$raw"
}

# _model_family <model> -> sonnet|haiku|opus, empty when the string names none.
_model_family() {
  case "$(_lower "$1")" in
    *sonnet*) printf 'sonnet' ;;
    *haiku*)  printf 'haiku' ;;
    *opus*)   printf 'opus' ;;
    *)        printf '' ;;
  esac
}

# _models_agree <expected> <actual> — bare alias means family pin, full model id
# means exact pin (see the header contract).
_models_agree() {
  local expected="$1" actual="$2" fam
  [ "$expected" != "$actual" ] || return 0
  case "$(_lower "$expected")" in
    sonnet|haiku|opus) ;;
    *) return 1 ;;
  esac
  fam=$(_model_family "$actual")
  [ -n "$fam" ] && [ "$fam" = "$(_lower "$expected")" ]
}

_mine_token_cost() {
  local dir f name expected actual newest
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  dir=$(_transcripts_dir)
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "self-audit: cost data unavailable (transcript dir not found: ${dir:-unset})"
    _coverage "token-cost" 0 0 0 0 0 0
    return 0
  fi
  # Newest session dir only: the root accumulates one dir per session across ALL
  # objectives, and `|| true` keeps the failing glob from aborting under pipefail.
  newest=$(ls -dt "$dir"/*/ 2>/dev/null | head -1) || true
  if [ -z "$newest" ]; then
    echo "self-audit: cost data unavailable (no session dirs under ${dir})"
    _coverage "token-cost" 0 0 0 0 0 0
    return 0
  fi
  shopt -s nullglob
  for f in "${newest}subagents"/*.jsonl; do
    scanned=$((scanned + 1))
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      unread=$((unread + 1))
      continue
    fi
    name=$(_attribution_role "$f")
    if [ -z "$name" ]; then
      unclass=$((unclass + 1))
      continue
    fi
    actual=$(jq -r 'select(.message.model != null) | .message.model' "$f" 2>/dev/null | tail -1) || actual=""
    expected=$(_expected_model_for "$name") || expected=""
    if [ -z "$actual" ] || [ -z "$expected" ]; then
      unclass=$((unclass + 1))
      continue
    fi
    checked=$((checked + 1))
    _models_agree "$expected" "$actual" && continue
    if _append_finding "high" "high" \
      "Model-tier drift: ${name} ran on ${actual} (expected ${expected})" \
      "${f} shows message.model=\"${actual}\" attributed to \"${name}\"; nazgul/config.json models resolve ${name} to \"${expected}\"" \
      "Pin the dispatch call site for ${name} to model=\"${expected}\" (or update the models config if the other tier is intentional)."; then
      findings=$((findings + 1))
    fi
  done
  shopt -u nullglob
  [ "$scanned" -gt 0 ] || echo "self-audit: cost data unavailable (no subagent transcripts under ${newest})"
  _coverage "token-cost" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

_ingest_findings_jsonl() {
  local f="$NAZGUL_DIR/logs/findings.jsonl" key line lineno mark total dkey
  local severity category title detail fix evidence agent unit ev
  local scanned=0 unread=0 unclass=0 na=0 checked=0 findings=0
  if [ ! -f "$f" ]; then
    _coverage "findings-jsonl" 0 0 0 0 0 0
    return 0
  fi
  key=$(basename "$f")
  total=$(_log_lines "$f")
  if [ ! -r "$f" ]; then
    _coverage "findings-jsonl" "$total" "$total" 0 0 0 0
    return 0
  fi
  mark=$(_window_mark "findings_jsonl" "$key")
  if [ "$mark" -gt "$total" ]; then
    echo "self-audit: ${key} is shorter than the recorded mark (${mark} > ${total}) — re-mining it from the start"
    mark=0
  fi
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    scanned=$((scanned + 1))
    if [ "$lineno" -le "$mark" ] || [ -z "$line" ]; then
      na=$((na + 1))
      continue
    fi
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      unclass=$((unclass + 1))
      continue
    fi
    checked=$((checked + 1))
    title=$(printf '%s' "$line" | jq -r '.title // "untitled finding"' 2>/dev/null) || title="untitled finding"
    detail=$(printf '%s' "$line" | jq -r '.detail // ""' 2>/dev/null) || detail=""
    # One finding raised by two agents is still one finding, and its evidence
    # names the raiser — so producer records dedupe on (title, detail) instead.
    dkey="findings.jsonl|${title%%$'\n'*}|${detail%%$'\n'*}"
    if [ -n "$SEEN_FILE" ] && grep -qxF "$dkey" "$SEEN_FILE" 2>/dev/null; then
      RUN_SUPPRESSED=$((RUN_SUPPRESSED + 1))
      continue
    fi
    [ -z "$SEEN_FILE" ] || printf '%s\n' "$dkey" >> "$SEEN_FILE" 2>/dev/null || true
    severity=$(printf '%s' "$line" | jq -r '.severity // "medium"' 2>/dev/null) || severity="medium"
    category=$(printf '%s' "$line" | jq -r '.category // "general"' 2>/dev/null) || category="general"
    fix=$(printf '%s' "$line" | jq -r '.suggested_fix // "(none provided)"' 2>/dev/null) || fix="(none provided)"
    evidence=$(printf '%s' "$line" | jq -r '.evidence // ""' 2>/dev/null) || evidence=""
    agent=$(printf '%s' "$line" | jq -r '.agent // "unknown"' 2>/dev/null) || agent="unknown"
    unit=$(printf '%s' "$line" | jq -r '.unit // ""' 2>/dev/null) || unit=""
    # `category` is a taxonomy tag (reliability/observability/cost/…), NOT a
    # leverage signal, so it goes in the evidence line and leverage reads "n/a".
    ev="[${category}] raised by ${agent}${unit:+ (unit: ${unit})}: ${detail}${evidence:+ | evidence: ${evidence}}"
    if _append_finding "$severity" "n/a" "$title" "$ev" "$fix"; then
      findings=$((findings + 1))
    fi
  done < "$f"
  _window_set "findings_jsonl" "$key" "$lineno"
  _coverage "findings-jsonl" "$scanned" "$unread" "$unclass" "$na" "$checked" "$findings"
}

# Guarded so tests can `source` this file (e.g. to call _transcripts_dir
# directly) without triggering the full mining pipeline or its `exit 0`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _init_dedupe
  _init_window
  _mine_review_rejections || true
  _mine_guard_blocks || true
  _mine_teammate_spawn_discrepancy || true
  _mine_todo_delta || true
  _mine_task_retries || true
  _mine_token_cost || true
  _ingest_findings_jsonl || true
  _persist_window
  [ -z "$SEEN_FILE" ] || rm -f "$SEEN_FILE"
  _run_coverage

  echo "self-audit: mining complete for ${FEAT_ID}; backlog at ${BACKLOG_PATH}"
  exit 0
fi
