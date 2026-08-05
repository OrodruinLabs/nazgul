#!/usr/bin/env bash
# Nazgul shared task-transition/evidence library (MF-022 Bundle 2, ADR-003
# Decision 2). Sourced by BOTH scripts/task-state-guard.sh (PreToolUse gate)
# and scripts/stop-hook.sh (stop-hook-time reconciliation), so a transition
# accepted by one call site is provably accepted by the other — no second
# implementation to drift out of sync.

_TTG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TTG_DIR/task-utils.sh"
# shellcheck source=/dev/null
source "$_TTG_DIR/review-evidence.sh"
# shellcheck source=/dev/null
source "$_TTG_DIR/emit-event.sh"

# Constitution Article III state machine — single source of truth for both
# call sites (was previously duplicated as a local function in
# task-state-guard.sh only).
# Usage: ttg_valid_transition <from> <to>
ttg_valid_transition() {
  local from="$1" to="$2"
  case "${from}_${to}" in
    PLANNED_READY)                 return 0 ;;
    PLANNED_BLOCKED)               return 0 ;;
    READY_BLOCKED)                 return 0 ;;
    READY_IN_PROGRESS)             return 0 ;;
    IN_PROGRESS_IMPLEMENTED)       return 0 ;;
    IN_PROGRESS_BLOCKED)           return 0 ;;
    IMPLEMENTED_BLOCKED)           return 0 ;;
    IMPLEMENTED_IN_REVIEW)         return 0 ;;
    IN_REVIEW_DONE)                return 0 ;;
    IN_REVIEW_APPROVED)            return 0 ;;
    IN_REVIEW_CHANGES_REQUESTED)   return 0 ;;
    IN_REVIEW_BLOCKED)             return 0 ;;
    APPROVED_DONE)                 return 0 ;;
    APPROVED_BLOCKED)              return 0 ;;
    CHANGES_REQUESTED_IN_PROGRESS) return 0 ;;
    CHANGES_REQUESTED_BLOCKED)     return 0 ;;
    # BLOCKED exits: READY via /nazgul:task unblock; IN_REVIEW via
    # /nazgul:review --materialize (still requires a review directory).
    BLOCKED_READY)                 return 0 ;;
    BLOCKED_IN_REVIEW)             return 0 ;;
    *) return 1 ;;
  esac
}

# Real commit-SHA verification (MF-026, tightened FEAT-023/TASK-006 — Defect 5,
# hardened TASK-006 attempt 2 — security B1). Scopes evidence to the
# manifest's `## Commits` section, using the identical awk boundary
# expression as scripts/git-hooks/pre-merge-commit's commits_verify() (that
# hook runs standalone in target repos and cannot source this file, so keep
# the two textually identical rather than sharing code — ADR-013). A
# candidate must both resolve to a real commit AND be a strict descendant of
# the manifest's own `## Metadata` -> Base SHA; the Base SHA itself does not
# count as forward progress.
#
# "Base SHA label absent" and "Base SHA label present but unresolvable" are
# distinct states, not one degrade path (a present-but-corrupt value is a
# stronger trouble signal than an absent field, per CLAUDE.md's guard-must-
# know-why rule): absent degrades to existence-only (plan.md C5, genuine
# pre-convention manifests); present-but-unresolvable is a malformed
# manifest and fails CLOSED. Each state announces itself on stderr with
# distinct text. The fail-CLOSED-on-ambiguity rule (ADR-003 Decision 3) still
# governs everything else: unavailable git, non-repo project_root, and no
# resolvable candidate in `## Commits` all deny.
# Usage: ttg_verify_commit_evidence <manifest_text> <project_root>
ttg_verify_commit_evidence() {
  local manifest_text="$1" project_root="$2" sha base_sha base_sha_line commits_section
  command -v git >/dev/null 2>&1 || return 1
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 1

  base_sha_line=$(printf '%s' "$manifest_text" \
    | awk '/^## Metadata/{f=1;next} /^## /{f=0} f' \
    | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Base SHA\*\*' | head -1 || true)
  base_sha=$(printf '%s' "$base_sha_line" | grep -oE '[0-9a-f]{7,64}' | head -1 || true)
  if [ -n "$base_sha" ] && ! git -C "$project_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    base_sha=""
  fi

  if [ -n "$base_sha_line" ] && [ -z "$base_sha" ]; then
    echo "ttg_verify_commit_evidence: Base SHA label present but its value does not resolve to a real commit — manifest treated as corrupt, rejecting" >&2
    return 1
  fi
  [ -n "$base_sha" ] || echo "ttg_verify_commit_evidence: no Base SHA label in manifest — forward-progress check skipped, degrading to existence-only" >&2

  commits_section=$(printf '%s' "$manifest_text" | awk '/^## Commits/{f=1;next} /^## /{f=0} f')
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$project_root" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    [ -n "$base_sha" ] || return 0
    [ "$(git -C "$project_root" rev-parse "$sha")" = "$(git -C "$project_root" rev-parse "$base_sha")" ] && continue
    git -C "$project_root" merge-base --is-ancestor "$base_sha" "$sha" 2>/dev/null && return 0
  done < <(printf '%s' "$commits_section" | grep -oE '[0-9a-f]{7,64}' || true)
  return 1
}

# Closed, enumerated exemption list (FEAT-023/TASK-004 precedent: never a
# pattern guess — an open-ended excuse field is an allow-everything field).
_TTG_RED_RUN_NA_TOKENS="docs-only comment-only revert fixture-capture-only"

# Last red-run verdict: six block reasons or verified/enumerated_na/not_applicable.
# shellcheck disable=SC2034  # read by scripts/stop-hook.sh, not within this file
TTG_RED_RUN_REASON=""

# Resolve event paths per call because task-state-guard sources this before deriving NAZGUL_DIR.
_ttg_emit_event() {
  local nazgul_dir="$1"; shift
  declare -F emit_event >/dev/null 2>&1 || return 0
  [ -n "$nazgul_dir" ] || return 0
  # shellcheck disable=SC2030,SC2034  # both are read by emit_event, sourced above
  ( NAZGUL_DIR="$nazgul_dir"; EVENTS_FILE="$nazgul_dir/logs/events.jsonl"; emit_event "$@" ) || true
}

# Emit a distinct red-run diagnostic/event; the kill switch suppresses only the block.
_ttg_red_run_deny() {
  local nazgul_dir="$1" task_id="$2" reason="$3" detail="$4" enabled
  TTG_RED_RUN_REASON="$reason"
  echo "ttg_verify_red_run_evidence: ${detail} [reason: ${reason}]" >&2
  _ttg_emit_event "$nazgul_dir" "red_run_missing" task_id "$task_id" reason "$reason"
  enabled=$(jq -r 'if .guards.red_run_evidence == false then "false" else "true" end' \
    "$nazgul_dir/config.json" 2>/dev/null || echo "true")
  if [ "$enabled" = "false" ]; then
    echo "ttg_verify_red_run_evidence: block suppressed by guards.red_run_evidence: false — the diagnostic and the red_run_missing event still fired" >&2
    return 0
  fi
  return 1
}

_ttg_strip_html_comments() {
  awk '
    {
      line=$0; out=""
      while (length(line) > 0) {
        if (comment) {
          end=index(line, "-->")
          if (!end) { line=""; break }
          line=substr(line, end + 3); comment=0; continue
        }
        start=index(line, "<!--")
        if (!start) { out=out line; line=""; break }
        out=out substr(line, 1, start - 1)
        line=substr(line, start + 4)
        end=index(line, "-->")
        if (end) { line=substr(line, end + 3); continue }
        comment=1; line=""
      }
      if (out ~ /[^[:space:]]/) print out
    }'
}

# Scope is the union of declared paths and Base SHA..HEAD; diff failure degrades loudly to manifest-only.
_ttg_red_run_in_scope() {
  local manifest_text="$1" project_root="$2"
  local declared diff_out base_sha degrade=""

  declared=$(printf '%s\n' "$manifest_text" \
    | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Files modified\*\*' || true)
  declared="${declared}
$(printf '%s' "$manifest_text" | awk '/^## File Scope/{f=1;next} /^## /{f=0} f')"
  declared=$(printf '%s\n' "$declared" | _ttg_strip_html_comments)
  if printf '%s\n' "$declared" | grep -qE '(^|[^[:alnum:]_./-])(scripts|tests)/'; then
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    degrade="git unavailable"
  elif ! git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
    degrade="project root is not a git repository"
  else
    base_sha=$(printf '%s' "$manifest_text" \
      | awk '/^## Metadata/{f=1;next} /^## /{f=0} f' \
      | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Base SHA\*\*' | head -1 \
      | grep -oE '[0-9a-f]{7,64}' | head -1 || true)
    if [ -z "$base_sha" ]; then
      degrade="no Base SHA in the manifest"
    elif ! git -C "$project_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
      degrade="Base SHA ${base_sha} does not resolve"
    elif ! diff_out=$(git -C "$project_root" diff --name-only "${base_sha}..HEAD" 2>/dev/null); then
      degrade="git diff ${base_sha}..HEAD failed"
    elif printf '%s\n' "$diff_out" | grep -qE '^(scripts|tests)/'; then
      return 0
    fi
  fi

  if [ -n "$degrade" ]; then
    echo "ttg_verify_red_run_evidence: red-run scope predicate degraded to manifest-only (${degrade})" >&2
  fi
  return 1
}

# Check one entry's referential integrity; QA owns whether the recorded failure is meaningful.
_ttg_red_run_check_entry() {
  local entry="$1" project_root="$2" nazgul_dir="$3" task_id="$4" commits="$5"
  local payload test_path abs_path tests_root resolved_parent ref result_line exit_code na_token tok found

  payload=$(printf '%s\n' "$entry" | head -1 \
    | sed -E 's/^[[:space:]]*-[[:space:]]*(\*\*)?red-run(\*\*)?:[[:space:]]*//')

  if printf '%s' "$payload" | grep -qE '^N/A([[:space:]]|$)'; then
    na_token=$(printf '%s' "$payload" \
      | sed -E 's%^N/A[[:space:]]*(—|--|-|:)?[[:space:]]*%%; s%[[:space:]]+$%%' | tr -d '`')
    found=false
    for tok in $_TTG_RED_RUN_NA_TOKENS; do
      if [ "$na_token" = "$tok" ]; then
        found=true
        break
      fi
    done
    if [ "$found" = true ]; then
      TTG_RED_RUN_REASON="enumerated_na"
      echo "ttg_verify_red_run_evidence: entry declares N/A — ${na_token} (enumerated exemption, recorded)" >&2
      return 0
    fi
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "bad_na_token" \
      "red-run: N/A — '${na_token}' is not in the closed exemption list (${_TTG_RED_RUN_NA_TOKENS// /, })"; then
      return 1
    fi
    return 0
  fi

  test_path=$(printf '%s' "$payload" | awk '{print $1}' | tr -d '`')
  case "$test_path" in
    tests/*) ;;
    *)
      if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
        "red-run entry test path '${test_path}' must be repository-relative and under tests/"; then
        return 1
      fi
      return 0
      ;;
  esac
  case "/$test_path/" in
    */../*|*/./*)
      if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
        "red-run entry test path '${test_path}' must not contain '.' or '..' segments"; then
        return 1
      fi
      return 0
      ;;
  esac
  abs_path="$project_root/$test_path"
  if [ ! -f "$abs_path" ] || [ -L "$abs_path" ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry names test path '${test_path}', which is not an existing regular non-symlink file"; then
      return 1
    fi
    return 0
  fi
  tests_root=$(cd "$project_root/tests" 2>/dev/null && pwd -P) || tests_root=""
  resolved_parent=$(cd "$(dirname "$abs_path")" 2>/dev/null && pwd -P) || resolved_parent=""
  if [ -z "$tests_root" ] || [ -z "$resolved_parent" ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry test path '${test_path}' could not be resolved under the repository tests/ tree"; then
      return 1
    fi
    return 0
  fi
  case "$resolved_parent/" in
    "$tests_root/"*) ;;
    *)
      if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
        "red-run entry test path '${test_path}' resolves outside the repository tests/ tree"; then
        return 1
      fi
      return 0
      ;;
  esac

  ref=$(printf '%s\n' "$entry" \
    | grep -iE '^[[:space:]]*-?[[:space:]]*(\*\*)?pre-change-ref(\*\*)?:' | head -1 \
    | grep -oE '[0-9a-f]{7,64}' | head -1 || true)
  if [ -z "$ref" ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry for ${test_path} carries no pre-change-ref"; then
      return 1
    fi
    return 0
  fi
  if ! command -v git >/dev/null 2>&1 \
    || ! git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 \
    || ! git -C "$project_root" cat-file -e "${ref}^{commit}" 2>/dev/null; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "ref_unresolvable" \
      "red-run pre-change-ref '${ref}' does not resolve to a real commit (or git is unavailable here — fail closed)"; then
      return 1
    fi
    return 0
  fi

  found=false
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$project_root" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    if git -C "$project_root" merge-base --is-ancestor "$ref" "$sha" 2>/dev/null; then
      found=true
      break
    fi
  done < <(printf '%s' "$commits" | grep -oE '[0-9a-f]{7,64}' || true)
  if [ "$found" != true ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "not_ancestor" \
      "red-run pre-change-ref '${ref}' is not an ancestor of any SHA recorded under ## Commits"; then
      return 1
    fi
    return 0
  fi

  result_line=$(printf '%s\n' "$entry" \
    | grep -iE '^[[:space:]]*-?[[:space:]]*(\*\*)?result(\*\*)?:' | head -1 || true)
  exit_code=$(printf '%s' "$result_line" \
    | grep -oiE 'exit[[:space:]]+[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$result_line" ] || [ -z "$exit_code" ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry for ${test_path} records no 'result: ... (exit <n>)'"; then
      return 1
    fi
    return 0
  fi
  if [ "$exit_code" -eq 0 ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "exit_zero" \
      "red-run entry for ${test_path} records exit 0 — a test that passed against the pre-change tree is not a red run"; then
      return 1
    fi
    return 0
  fi

  TTG_RED_RUN_REASON="verified"
  return 0
}

# Red-run evidence verification (FEAT-028/TASK-002, PRD AC1/AC2, TRD §1),
# shaped deliberately like ttg_verify_commit_evidence above so the two read
# alike: same awk section boundary, same per-state honesty, same referential-
# integrity-not-semantics split.
#
# The `## Red-Run Evidence` heading IS the enforcement boundary — a `red-run:`
# token anywhere else in the manifest is invisible here, exactly as a hex token
# outside `## Commits` is invisible to the commit gate.
#
# Six dispositions, never one collapsed allow (RULES §15 / ADR-009 — weighed
# per guard, not inherited by proximity): section absent + in scope BLOCKs
# (a false deny costs one manifest edit; a false allow makes the whole charter
# decorative); section absent + out of scope ALLOWs and announces the skipped
# check; a comment-only template section is treated as logically absent; a
# non-comment section with no parseable entry BLOCKs as corrupt;
# an entry whose ref, ancestry, or recorded exit code git can refute BLOCKs
# naming which check failed; an enumerated `N/A` token ALLOWs; a free-text
# `N/A` BLOCKs.
# Usage: ttg_verify_red_run_evidence <manifest_text> <project_root> [task_id]
ttg_verify_red_run_evidence() {
  local manifest_text="$1" project_root="$2" task_id="${3:-}"
  local nazgul_dir="${NAZGUL_DIR:-$project_root/nazgul}"
  local raw_section section commits entry="" line rc=0

  TTG_RED_RUN_REASON=""
  if [ -z "$task_id" ]; then
    task_id=$(printf '%s' "$manifest_text" \
      | awk '/^## Metadata/{f=1;next} /^## /{f=0} f' \
      | grep -oE '(TASK|PATCH)-[0-9]+' | head -1 || true)
  fi
  [ -n "$task_id" ] || task_id="unknown"

  if ! printf '%s\n' "$manifest_text" | grep -q '^## Red-Run Evidence'; then
    if _ttg_red_run_in_scope "$manifest_text" "$project_root"; then
      if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "absent" \
        "no ## Red-Run Evidence section, but this task's scope touches scripts/** or tests/**"; then
        return 1
      fi
      return 0
    fi
    # shellcheck disable=SC2034  # read by scripts/stop-hook.sh, not within this file
    TTG_RED_RUN_REASON="not_applicable"
    echo "ttg_verify_red_run_evidence: no ## Red-Run Evidence section and no scripts/** or tests/** path in scope — red-run check not applicable, skipped" >&2
    return 0
  fi

  raw_section=$(printf '%s' "$manifest_text" | awk '/^## Red-Run Evidence/{f=1;next} /^## /{f=0} f')
  section=$(printf '%s\n' "$raw_section" | _ttg_strip_html_comments)
  if ! printf '%s\n' "$section" | grep -qE '^[[:space:]]*-[[:space:]]*(\*\*)?red-run(\*\*)?:'; then
    if ! printf '%s' "$section" | grep -q '[^[:space:]]'; then
      if _ttg_red_run_in_scope "$manifest_text" "$project_root"; then
        if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "absent" \
          "## Red-Run Evidence contains only template commentary, but this task's scope touches scripts/** or tests/**"; then
          return 1
        fi
        return 0
      fi
      # shellcheck disable=SC2034  # read by scripts/stop-hook.sh, not within this file
      TTG_RED_RUN_REASON="not_applicable"
      echo "ttg_verify_red_run_evidence: ## Red-Run Evidence contains only template commentary and no scripts/** or tests/** path is in scope — red-run check not applicable, skipped" >&2
      return 0
    fi
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "## Red-Run Evidence section is present but carries no parseable 'red-run:' entry"; then
      return 1
    fi
    return 0
  fi

  commits=$(printf '%s' "$manifest_text" | awk '/^## Commits/{f=1;next} /^## /{f=0} f')
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]*(\*\*)?red-run(\*\*)?:' \
      || [ "$line" = "__TTG_END_OF_SECTION__" ]; then
      if [ -n "$entry" ]; then
        if ! _ttg_red_run_check_entry "$entry" "$project_root" "$nazgul_dir" "$task_id" "$commits"; then
          rc=1
          break
        fi
      fi
      entry="$line"
    elif [ -n "$entry" ]; then
      entry="${entry}
${line}"
    fi
  done < <(printf '%s\n__TTG_END_OF_SECTION__\n' "$section")
  return "$rc"
}

# Thin pass-through to review-evidence.sh's validate_review_evidence so both
# call sites exercise the identical review-gate evidence check (Constitution
# Rule 5) through this one library.
# Usage: ttg_verify_review_evidence <nazgul_dir> <task_id>
ttg_verify_review_evidence() {
  validate_review_evidence "$1" "$2"
}

# Append one entry to the guarded-transition ledger. Called only after a
# transition has passed ttg_valid_transition() and all evidence gates on the
# PreToolUse path — the stop-hook reconciliation pass reads this ledger to
# tell a legitimate Write/Edit/MultiEdit-mediated transition apart from a
# Bash-write bypass (MF-022). Trimmed to the newest 500 lines so the ledger
# never grows unbounded across a long-running loop.
# Usage: ttg_log_transition <nazgul_dir> <task_id> <from> <to>
ttg_log_transition() {
  local nazgul_dir="$1" task_id="$2" from="$3" to="$4"
  local ledger="$nazgul_dir/logs/guarded-transitions.jsonl"
  mkdir -p "$nazgul_dir/logs"
  jq -nc --arg t "$task_id" --arg f "$from" --arg to "$to" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id:$t, from:$f, to:$to, timestamp:$ts}' >> "$ledger" 2>/dev/null || true
  tail -n 500 "$ledger" > "${ledger}.tmp" 2>/dev/null && mv "${ledger}.tmp" "$ledger" || true
}

# True iff the ledger records a guarded transition landing on `to` for
# task_id at or after since_ts. Matches on the endpoint only (not the exact
# from->to pair) so a legitimate multi-hop sequence within one agent turn
# (e.g. IN_PROGRESS->IMPLEMENTED->IN_REVIEW, two separate guarded calls) isn't
# mistaken for a bypass — the reconciliation pass's recompute-and-compare
# check (MF-022): a live status is only trusted if some guarded call landed
# on it since the last checkpoint.
# Usage: ttg_transition_is_guarded <nazgul_dir> <task_id> <to> <since_ts>
ttg_transition_is_guarded() {
  local nazgul_dir="$1" task_id="$2" to="$3" since_ts="$4"
  local ledger="$nazgul_dir/logs/guarded-transitions.jsonl"
  [ -f "$ledger" ] || return 1
  jq -e --arg t "$task_id" --arg to "$to" --arg since "$since_ts" \
    'select(.task_id == $t and .to == $to and .timestamp >= $since)' \
    "$ledger" >/dev/null 2>&1
}
