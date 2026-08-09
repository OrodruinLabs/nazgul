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

# Last dependency requirement in words, for the caller's diagnostic.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_DEP_EXPECTED=""

# Is one PLANNED -> READY dependency satisfied? Granularity-aware: `group`/`feature`
# park EVERY task at IMPLEMENTED until one aggregate board, so DONE is unsatisfiable there.
ttg_dependency_satisfied() {
  local nazgul_dir="$1" dep_status="$2" granularity yolo
  granularity=$(jq -r '.review_gate.granularity // "task"' \
    "$nazgul_dir/config.json" 2>/dev/null || echo "task")
  yolo=$(jq -r 'if .afk.yolo == true then "true" else "false" end' \
    "$nazgul_dir/config.json" 2>/dev/null || echo "false")
  case "$granularity" in
    group|feature)
      TTG_DEP_EXPECTED="IMPLEMENTED or later (review_gate.granularity=${granularity})"
      case "$dep_status" in
        IMPLEMENTED|IN_REVIEW|APPROVED|DONE) return 0 ;;
      esac
      ;;
    *)
      if [ "$yolo" = "true" ]; then
        TTG_DEP_EXPECTED="APPROVED/DONE"
        case "$dep_status" in DONE|APPROVED) return 0 ;; esac
      else
        TTG_DEP_EXPECTED="DONE"
        if [ "$dep_status" = "DONE" ]; then return 0; fi
      fi
      ;;
  esac
  return 1
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
  # Remediation is derived from the token list, never a second copy of it.
  echo "ttg_verify_red_run_evidence: capture it with scripts/red-run.sh, or declare an enumerated exemption: red-run: N/A — ${_TTG_RED_RUN_NA_TOKENS// /|}" >&2
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

# Validate one ordinary state-machine edge against the live manifest and every
# evidence gate. This is shared by the transactional writer and the
# Write/Edit/MultiEdit preflight diagnostic; neither caller may record authority
# merely because validation passed.
# Usage: ttg_validate_transition <nazgul_dir> <project_root> <task_id> <from> <to> <manifest_text>
ttg_validate_transition() {
  local nazgul_dir="$1" project_root="$2" task_id="$3" from="$4" to="$5" manifest_text="$6"
  local review_dir review_unit problems provenance_problems deps_lines deps_count deps_raw dep dep_file dep_status
  local -a deps
  local yolo_mode="false" task_pr_mode="false" require_provenance="true" needs_review=false

  if ! ttg_valid_transition "$from" "$to"; then
    echo "ttg_validate_transition: invalid state transition: ${from} -> ${to}" >&2
    return 1
  fi

  if { [ -e "$nazgul_dir/config.json" ] || [ -L "$nazgul_dir/config.json" ]; } \
    && { [ ! -f "$nazgul_dir/config.json" ] || [ -L "$nazgul_dir/config.json" ] \
      || ! jq -e 'type == "object"' "$nazgul_dir/config.json" >/dev/null 2>&1; }; then
    echo "ttg_validate_transition: config.json must be a valid regular non-symlink JSON object" >&2
    return 1
  fi

  if [ -f "$nazgul_dir/config.json" ]; then
    yolo_mode=$(jq -r 'if .afk.yolo == true then "true" else "false" end' \
      "$nazgul_dir/config.json" 2>/dev/null || echo "false")
    task_pr_mode=$(jq -r 'if .afk.task_pr == true then "true" else "false" end' \
      "$nazgul_dir/config.json" 2>/dev/null || echo "false")
    require_provenance=$(jq -r 'if .review_gate.require_provenance == false then "false" else "true" end' \
      "$nazgul_dir/config.json" 2>/dev/null || echo "true")
  fi

  if [ "$from" = "PLANNED" ] && [ "$to" = "READY" ]; then
    deps_lines=$(printf '%s\n' "$manifest_text" | grep -E '^\- \*\*Depends on\*\*:' || true)
    deps_count=$(printf '%s\n' "$deps_lines" | awk 'NF {n++} END {print n+0}')
    if [ "$deps_count" -ne 1 ]; then
      echo "ttg_validate_transition: READY requires exactly one explicit Depends on field" >&2
      return 1
    fi
    deps_raw=$(printf '%s\n' "$deps_lines" | sed 's/.*:[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$deps_raw" ] || {
      echo "ttg_validate_transition: READY requires Depends on: none or canonical task ids" >&2
      return 1
    }
    case "$deps_raw" in none|None|NONE) deps_raw="" ;; esac
    deps_raw="${deps_raw//,/ }"
    IFS=' ' read -r -a deps <<< "$deps_raw"
    # `Depends on: none` empties the array, and bash < 4.4 (/bin/bash 3.2) treats an
    # unguarded value expansion of an empty array as unbound, aborting under `set -u`.
    for dep in ${deps[@]+"${deps[@]}"}; do
      [[ "$dep" =~ ^TASK-[0-9]+$ ]] || {
        echo "ttg_validate_transition: READY dependency '${dep}' is not a canonical task id" >&2
        return 1
      }
      [ "$dep" != "$task_id" ] || {
        echo "ttg_validate_transition: READY dependency cannot reference the task itself" >&2
        return 1
      }
      dep_file=$(ttg_task_manifest_path "$nazgul_dir" "$dep") || {
        echo "ttg_validate_transition: READY dependency ${dep} has no canonical manifest" >&2
        return 1
      }
      dep_status=$(get_task_status "$dep_file" "")
      if ! ttg_dependency_satisfied "$nazgul_dir" "$dep_status"; then
        echo "ttg_validate_transition: READY dependency ${dep} is ${dep_status:-missing}, not ${TTG_DEP_EXPECTED}" >&2
        return 1
      fi
    done
  fi

  if [ "$from" = "IN_PROGRESS" ] && [ "$to" = "IMPLEMENTED" ]; then
    if ! ttg_verify_commit_evidence "$manifest_text" "$project_root"; then
      echo "ttg_validate_transition: IMPLEMENTED requires a verified commit SHA" >&2
      return 1
    fi
    if ! ttg_verify_red_run_evidence "$manifest_text" "$project_root" "$task_id"; then
      echo "ttg_validate_transition: IMPLEMENTED requires verified red-run evidence" >&2
      return 1
    fi
  fi

  if { [ "$from" = "IMPLEMENTED" ] || [ "$from" = "BLOCKED" ]; } && [ "$to" = "IN_REVIEW" ]; then
    review_unit=$(resolve_review_unit "$nazgul_dir" "$task_id")
    if ! review_dir=$(ttg_review_dir_path "$nazgul_dir" "$review_unit"); then
      echo "ttg_validate_transition: IN_REVIEW requires a canonical non-symlink review directory for ${review_unit}" >&2
      return 1
    fi
  fi

  # Two named repair classes may leave BLOCKED for IN_REVIEW: review-evidence
  # materialization and the ADR-020 typed reconciliation quarantine.
  if [ "$from" = "BLOCKED" ] && [ "$to" = "IN_REVIEW" ]; then
    # Anchored, so an already-repaired `reconciliation (repaired …)` cannot re-qualify.
    if ! printf '%s\n' "$manifest_text" | grep -qi '^\- \*\*Blocked reason\*\*:.*review evidence' \
      && ! printf '%s\n' "$manifest_text" | grep -qiE '^\- \*\*Blocked kind\*\*:[[:space:]]*reconciliation[[:space:]]*$'; then
      echo "ttg_validate_transition: BLOCKED -> IN_REVIEW is reserved for review-evidence repair and typed reconciliation repair" >&2
      return 1
    fi
  fi

  # Review-gate has two mutually exclusive completion routes. Preserve that
  # distinction here so the generic graph's IN_REVIEW endpoints cannot bypass
  # the mode-specific evidence gate.
  if [ "$from" = "IN_REVIEW" ]; then
    if [ "$yolo_mode" = "true" ] && [ "$task_pr_mode" = "true" ]; then
      if [ "$to" = "DONE" ]; then
        echo "ttg_validate_transition: YOLO task-PR review must reach APPROVED before DONE" >&2
        return 1
      fi
      [ "$to" = "APPROVED" ] && needs_review=true
    else
      if [ "$to" = "APPROVED" ]; then
        echo "ttg_validate_transition: APPROVED is reserved for YOLO task-PR review" >&2
        return 1
      fi
      [ "$to" = "DONE" ] && needs_review=true
    fi
  fi
  if [ "$from" = "APPROVED" ] && [ "$to" = "DONE" ] \
    && { [ "$yolo_mode" != "true" ] || [ "$task_pr_mode" != "true" ]; }; then
    echo "ttg_validate_transition: APPROVED -> DONE is reserved for YOLO task-PR completion" >&2
    return 1
  fi

  if [ "$needs_review" = "true" ]; then
    review_unit=$(resolve_review_unit "$nazgul_dir" "$task_id")
    if ! review_dir=$(ttg_review_dir_path "$nazgul_dir" "$review_unit"); then
      echo "ttg_validate_transition: ${to} requires a canonical non-symlink review directory for ${review_unit}" >&2
      return 1
    fi
    if ! ttg_review_evidence_paths_safe "$nazgul_dir" "$review_dir"; then
      echo "ttg_validate_transition: ${to} review evidence contains an unsafe name, symlink, or non-regular leaf" >&2
      return 1
    fi
    problems=$(ttg_verify_review_evidence "$nazgul_dir" "$task_id") || true
    if [ -n "$problems" ]; then
      echo "ttg_validate_transition: ${to} requires complete configured review evidence: ${problems}" >&2
      return 1
    fi
    if [ "$require_provenance" = "true" ]; then
      provenance_problems=$(validate_review_provenance "$nazgul_dir" "$review_unit") || true
      if [ -n "$provenance_problems" ]; then
        echo "ttg_validate_transition: ${to} failed the configured legacy-compatible review provenance validator: ${provenance_problems}" >&2
        return 1
      fi
    fi
  fi
  return 0
}

# Resolve a task id to a regular, non-symlink manifest below the canonical
# runtime task directory. Callers supply an ID, never an arbitrary path.
# Usage: ttg_task_manifest_path <nazgul_dir> <task_id>
ttg_task_manifest_path() {
  local nazgul_dir="$1" task_id="$2" nazgul_real tasks_real file parent_real
  [[ "$task_id" =~ ^TASK-[0-9]+$ ]] || return 1
  [ -d "$nazgul_dir" ] && [ ! -L "$nazgul_dir" ] || return 1
  [ -d "$nazgul_dir/tasks" ] && [ ! -L "$nazgul_dir/tasks" ] || return 1
  nazgul_real=$(cd "$nazgul_dir" 2>/dev/null && pwd -P) || return 1
  tasks_real=$(cd "$nazgul_dir/tasks" 2>/dev/null && pwd -P) || return 1
  [ "$tasks_real" = "$nazgul_real/tasks" ] || return 1
  file="$tasks_real/$task_id.md"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  parent_real=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || return 1
  [ "$parent_real" = "$tasks_real" ] || return 1
  printf '%s\n' "$file"
}

# Resolve one runtime subdirectory without following a nazgul/, locks/, logs/,
# or reviews/ symlink. Writers may request creation; readers never do.
_ttg_runtime_dir_path() {
  local nazgul_dir="$1" name="$2" create="${3:-false}" nazgul_real path real
  case "$name" in locks|logs|reviews) ;; *) return 1 ;; esac
  [ -d "$nazgul_dir" ] && [ ! -L "$nazgul_dir" ] || return 1
  nazgul_real=$(cd "$nazgul_dir" 2>/dev/null && pwd -P) || return 1
  path="$nazgul_real/$name"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    [ "$create" = "true" ] || return 1
    mkdir "$path" 2>/dev/null || return 1
  fi
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  real=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$path" ] || return 1
  printf '%s\n' "$real"
}

# A review unit is one safe path segment, and its directory is a real child of
# canonical nazgul/reviews. Task metadata/config may choose the unit, but may
# never turn evidence lookup into path traversal or a symlink escape.
ttg_review_dir_path() {
  local nazgul_dir="$1" unit="$2" reviews dir parent
  if [[ ! "$unit" =~ ^(TASK-[0-9]+|GROUP-[0-9]+|FEATURE-[A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    return 1
  fi
  reviews=$(_ttg_runtime_dir_path "$nazgul_dir" reviews false) || return 1
  dir="$reviews/$unit"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  parent=$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = "$reviews" ] || return 1
  printf '%s\n' "$dir"
}

ttg_review_evidence_paths_safe() {
  local nazgul_dir="$1" review_dir="$2" reviewer leaf logs receipts
  while IFS= read -r reviewer; do
    [ -n "$reviewer" ] || continue
    [[ "$reviewer" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  done < <(jq -r '.agents.reviewers // [] | .[]' "$nazgul_dir/config.json" 2>/dev/null)

  for leaf in "$review_dir"/*.md "$review_dir/.dispatch.json" "$review_dir/diff.patch"; do
    if [ -e "$leaf" ] || [ -L "$leaf" ]; then
      [ -f "$leaf" ] && [ ! -L "$leaf" ] || return 1
    fi
  done

  logs=$(_ttg_runtime_dir_path "$nazgul_dir" logs false) || return 0
  receipts="$logs/review-receipts.jsonl"
  if [ -e "$receipts" ] || [ -L "$receipts" ]; then
    [ -f "$receipts" ] && [ ! -L "$receipts" ] || return 1
  fi
  return 0
}

# Age in whole seconds of a path's mtime. Non-zero when no stat(1) dialect on
# this host can answer, and callers must then fail closed.
_ttg_mtime_age_seconds() {
  local path="$1" mtime="" now=""
  mtime=$(stat -f '%m' "$path" 2>/dev/null) || mtime=""
  if [ -z "$mtime" ]; then
    mtime=$(stat -c '%Y' "$path" 2>/dev/null) || mtime=""
  fi
  [ -n "$mtime" ] || return 1
  now=$(date +%s 2>/dev/null) || now=""
  [ -n "$now" ] || return 1
  case "${mtime}${now}" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - mtime))"
}

# Per-task callers pass attempts=1, so an unreclaimable lock wedges every later
# transition for that task until a human runs rmdir.
_TTG_LOCK_ORPHAN_GRACE_SECONDS=30

# mkdir locks are portable to Bash 3.2 and work across separate command
# processes. Ownership lives in a tokenized owner filename, which makes stale
# reclamation ABA-safe. A dead owner is reclaimable; a live or malformed one
# fails closed; an ownerless directory — a writer killed between its mkdir and
# its owner write — is reclaimable only after the grace period above and only
# through rmdir, which refuses a directory that has since gained an owner.
_ttg_acquire_lock() {
  local lock="$1" attempts="${2:-1}" delay="${3:-0.02}"
  local n=0 owner="" owner_pid="" owner_token="" owner_file="" owner_leaf="" token="" lock_age=""
  local -a owner_files
  TTG_LOCK_TOKEN=""
  token=$(_rp_nonce) || token=""
  [ -n "$token" ] || return 1
  while [ "$n" -lt "$attempts" ]; do
    if { [ -e "$lock" ] || [ -L "$lock" ]; } \
      && { [ ! -d "$lock" ] || [ -L "$lock" ]; }; then
      return 1
    fi
    if mkdir "$lock" 2>/dev/null; then
      owner_file="$lock/owner.$$.${token}"
      # Published before the write so a signal in this window still reaches the
      # caller's release trap with the directory this call created.
      TTG_LOCK_TOKEN="$token"
      if ! printf '%s %s\n' "$$" "$token" > "$owner_file"; then
        TTG_LOCK_TOKEN=""
        rmdir "$lock" 2>/dev/null || true
        return 1
      fi
      owner_files=("$lock"/owner.*)
      if [ "${#owner_files[@]}" -eq 1 ] && [ "${owner_files[0]}" = "$owner_file" ]; then
        return 0
      fi
      # A grace reclaim took the directory mid-claim and the owner file above
      # landed in a successor's lock; withdraw rather than co-own it.
      TTG_LOCK_TOKEN=""
      rm -f "$owner_file" 2>/dev/null || true
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    fi

    owner=""
    owner_files=("$lock"/owner.*)
    if [ "${#owner_files[@]}" -eq 1 ] \
      && [ ! -e "${owner_files[0]}" ] && [ ! -L "${owner_files[0]}" ]; then
      lock_age=$(_ttg_mtime_age_seconds "$lock") || lock_age=""
      if [ -n "$lock_age" ] && [ "$lock_age" -ge "$_TTG_LOCK_ORPHAN_GRACE_SECONDS" ] \
        && rmdir "$lock" 2>/dev/null; then
        continue
      fi
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    fi
    [ "${#owner_files[@]}" -eq 1 ] || {
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    }
    owner_file="${owner_files[0]}"
    [ -f "$owner_file" ] && [ ! -L "$owner_file" ] \
      && IFS= read -r owner < "$owner_file" || true
    owner_pid=${owner%% *}
    owner_token=${owner#* }
    owner_leaf=${owner_file##*/}
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] \
      && [[ "$owner_token" =~ ^[0-9a-f]+$ ]] \
      && [ "$owner_leaf" = "owner.${owner_pid}.${owner_token}" ] \
      && ! kill -0 "$owner_pid" 2>/dev/null; then
      if rm "$owner_file" 2>/dev/null && rmdir "$lock" 2>/dev/null; then
        continue
      fi
    fi
    n=$((n + 1))
    [ "$n" -lt "$attempts" ] && sleep "$delay"
  done
  return 1
}

_ttg_release_lock() {
  local lock="$1" token="$2" owner="" owner_file=""
  owner_file="$lock/owner.$$.${token}"
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  if [ ! -e "$owner_file" ] && [ ! -L "$owner_file" ]; then
    # Claimed but never owned: clear it rather than waiting out the orphan
    # grace. rmdir refuses a directory holding anyone else's owner file.
    rmdir "$lock" 2>/dev/null
    return
  fi
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] \
    && IFS= read -r owner < "$owner_file" || true
  [ "$owner" = "$$ $token" ] || return 1
  rm "$owner_file" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null
}

# Delegate: one mode probe for the whole codebase (scripts/lib/task-utils.sh).
_ttg_file_mode() {
  nz_file_mode "$1"
}

# Under the per-task lock, update one ordinary task status from a staged source
# snapshot, recheck immediately before atomic rename, verify the target on disk,
# and only then append authority metadata. A failure before the final mv leaves
# the manifest untouched; a post-write ledger/event failure is loud and is
# intentionally left for reconciliation to quarantine. This serializes Nazgul
# transition writers; arbitrary uncooperative filesystem mutation is outside
# the lock protocol and cannot be made into an OS-level conditional rename by
# portable Bash.
# Usage: ttg_apply_transition <nazgul_dir> <project_root> <task_id> <from> <to> [blocked_reason]
_ttg_apply_transition_locked() {
  local nazgul_dir="$1" project_root="$2" task_id="$3" from="$4" to="$5" reason="${6:-}"
  local file live manifest tmp reason_tmp before_hash current_hash after_hash original_mode

  file=$(ttg_task_manifest_path "$nazgul_dir" "$task_id") || {
    echo "ttg_apply_transition: no regular task manifest for ${task_id} under ${nazgul_dir}/tasks" >&2
    return 1
  }

  tmp=$(mktemp "$(dirname "$file")/.${task_id}.transition.XXXXXX") || {
    echo "ttg_apply_transition: could not create a colocated transition file for ${task_id}" >&2
    return 1
  }
  original_mode=$(_ttg_file_mode "$file") || {
    rm -f "$tmp"
    echo "ttg_apply_transition: could not read ${task_id} file mode" >&2
    return 1
  }
  if ! cp "$file" "$tmp"; then
    rm -f "$tmp"
    echo "ttg_apply_transition: could not stage ${task_id}" >&2
    return 1
  fi

  # The staged bytes are the validation snapshot. Confirm the source still
  # matches them before parsing, and compare it again immediately before mv.
  before_hash=$(_rp_sha256 < "$tmp") || {
    rm -f "$tmp"
    echo "ttg_apply_transition: no SHA-256 implementation available for snapshot comparison" >&2
    return 1
  }
  current_hash=$(_rp_sha256 < "$file") || current_hash=""
  if [ -z "$current_hash" ] || [ "$current_hash" != "$before_hash" ]; then
    rm -f "$tmp"
    echo "ttg_apply_transition: ${task_id} changed while its transition was staged; concurrent content preserved" >&2
    return 1
  fi

  live=$(get_task_status "$tmp" "")
  if [ "$live" != "$from" ]; then
    rm -f "$tmp"
    echo "ttg_apply_transition: stale source for ${task_id}: expected ${from}, found ${live:-missing}" >&2
    return 1
  fi
  manifest=$(cat "$tmp")
  ttg_validate_transition "$nazgul_dir" "$project_root" "$task_id" "$from" "$to" "$manifest" \
    || { rm -f "$tmp"; return 1; }

  set_task_status "$tmp" "$from" "$to"
  if [ "$(get_task_status "$tmp" "")" != "$to" ]; then
    rm -f "$tmp" "${tmp}.tmp" "${tmp}.bak"
    echo "ttg_apply_transition: staged status rewrite did not reach ${to}" >&2
    return 1
  fi

  if [ "$to" = "BLOCKED" ] && [ -n "$reason" ]; then
    reason_tmp="${tmp}.reason"
    if grep -q '^\- \*\*Blocked reason\*\*:' "$tmp" 2>/dev/null; then
      TTG_BLOCK_REASON="$reason" awk \
        '/^\- \*\*Blocked reason\*\*:/ { print "- **Blocked reason**: " ENVIRON["TTG_BLOCK_REASON"]; next } { print }' \
        "$tmp" > "$reason_tmp" || { rm -f "$tmp" "$reason_tmp"; return 1; }
    else
      { cat "$tmp"; printf '\n- **Blocked reason**: %s\n' "$reason"; } > "$reason_tmp" \
        || { rm -f "$tmp" "$reason_tmp"; return 1; }
    fi
    mv "$reason_tmp" "$tmp" || { rm -f "$tmp" "$reason_tmp"; return 1; }
  fi

  if ! chmod "$original_mode" "$tmp"; then
    rm -f "$tmp" "${tmp}.tmp" "${tmp}.bak" "${tmp}.reason"
    echo "ttg_apply_transition: could not preserve ${task_id} file mode" >&2
    return 1
  fi

  current_hash=$(_rp_sha256 < "$file") || current_hash=""
  if [ -z "$current_hash" ] || [ "$current_hash" != "$before_hash" ]; then
    rm -f "$tmp" "${tmp}.tmp" "${tmp}.bak" "${tmp}.reason"
    echo "ttg_apply_transition: ${task_id} changed while its transition was staged; concurrent content preserved" >&2
    return 1
  fi

  mv "$tmp" "$file" || {
    rm -f "$tmp"
    echo "ttg_apply_transition: atomic manifest replace failed for ${task_id}" >&2
    return 1
  }
  if [ "$(get_task_status "$file" "")" != "$to" ]; then
    echo "ttg_apply_transition: ${task_id} write completed but disk verification did not find ${to}" >&2
    return 1
  fi
  after_hash=$(_rp_sha256 < "$file") || after_hash=""
  if [ -z "$after_hash" ]; then
    echo "ttg_apply_transition: ${task_id} reached ${to}, but its completed bytes could not be hashed; reconciliation will quarantine it" >&2
    return 1
  fi
  if ! ttg_log_transition "$nazgul_dir" "$task_id" "$from" "$to" "$before_hash" "$after_hash"; then
    echo "ttg_apply_transition: ${task_id} reached ${to}, but its completed-transition record failed; reconciliation will quarantine it" >&2
    return 1
  fi
  _ttg_emit_event "$nazgul_dir" "task_transition" task_id "$task_id" from "$from" to "$to"
  return 0
}

ttg_apply_transition() {
  local nazgul_dir="$1" task_id="$3" lock_root lock
  [[ "$task_id" =~ ^TASK-[0-9]+$ ]] || {
    echo "ttg_apply_transition: task id must match TASK-[0-9]+" >&2
    return 1
  }
  if [ ! -f "$nazgul_dir/config.json" ] || [ -L "$nazgul_dir/config.json" ] \
    || ! jq -e 'type == "object"' "$nazgul_dir/config.json" >/dev/null 2>&1; then
    echo "ttg_apply_transition: config.json must be a valid regular non-symlink JSON object" >&2
    return 1
  fi
  lock_root=$(_ttg_runtime_dir_path "$nazgul_dir" locks true) || {
    echo "ttg_apply_transition: locks/ is not a canonical runtime directory" >&2
    return 1
  }
  _ttg_runtime_dir_path "$nazgul_dir" logs true >/dev/null || {
    echo "ttg_apply_transition: logs/ is not a canonical runtime directory" >&2
    return 1
  }
  lock="$lock_root/task-transition-${task_id}.lock"
  (
    # Keyed on the token _ttg_acquire_lock publishes before it writes its owner
    # file, so no signal window can skip the release.
    TTG_LOCK_TOKEN=""
    trap '[ -z "${TTG_LOCK_TOKEN:-}" ] || _ttg_release_lock "$lock" "$TTG_LOCK_TOKEN" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! _ttg_acquire_lock "$lock" 1; then
      echo "ttg_apply_transition: another transition already holds the ${task_id} lock" >&2
      exit 1
    fi
    _ttg_apply_transition_locked "$@"
  )
}

# Append one completed entry to the guarded-transition ledger. Callers invoke
# this only after verifying the target status on disk. Trim to the newest 500
# lines so the runtime ledger remains bounded.
# Usage: ttg_log_transition <nazgul_dir> <task_id> <from> <to>
ttg_log_transition() {
  local nazgul_dir="$1" task_id="$2" from="$3" to="$4"
  local before_hash="${5:-}" after_hash="${6:-}"
  local logs ledger lock
  logs=$(_ttg_runtime_dir_path "$nazgul_dir" logs true) || {
    echo "ttg_log_transition: logs/ is not a canonical runtime directory" >&2
    return 1
  }
  ledger="$logs/guarded-transitions.jsonl"
  lock="$logs/.guarded-transitions.lock"
  if { [ -e "$ledger" ] || [ -L "$ledger" ]; } \
    && { [ ! -f "$ledger" ] || [ -L "$ledger" ]; }; then
    echo "ttg_log_transition: ledger is not a regular non-symlink file" >&2
    return 1
  fi
  (
    local tmp line ledger_mode=""
    TTG_LOCK_TOKEN=""
    trap 'rm -f "${tmp:-}" 2>/dev/null || true; [ -z "${TTG_LOCK_TOKEN:-}" ] || _ttg_release_lock "$lock" "$TTG_LOCK_TOKEN" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! _ttg_acquire_lock "$lock" 200 0.01; then
      echo "ttg_log_transition: timed out waiting for the completed-transition ledger lock" >&2
      exit 1
    fi
    tmp=$(mktemp "$logs/.guarded-transitions.XXXXXX") || return 1
    line=$(jq -nc --arg t "$task_id" --arg f "$from" --arg to "$to" \
      --arg before "$before_hash" --arg after "$after_hash" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id:$t, from:$f, to:$to, timestamp:$ts}
       + (if $before == "" then {} else {before_sha256:$before} end)
       + (if $after == "" then {} else {after_sha256:$after} end)') || return 1
    if [ -f "$ledger" ]; then
      tail -n 499 "$ledger" > "$tmp" || return 1
    else
      : > "$tmp" || return 1
    fi
    printf '%s\n' "$line" >> "$tmp" || return 1
    if [ -f "$ledger" ]; then
      ledger_mode=$(_ttg_file_mode "$ledger") || return 1
      chmod "$ledger_mode" "$tmp" || return 1
    fi
    mv "$tmp" "$ledger" || return 1
    tmp=""
  )
}

# True iff the ledger records a completed transition for the requested task and
# time window. The preferred five-argument form matches the exact edge.
# Five-argument form matches the exact completed edge. The four-argument form
# remains temporarily compatible for callers being migrated in the next task.
# Usage: ttg_transition_is_guarded <nazgul_dir> <task_id> [<from>] <to> <since_ts>
ttg_transition_is_guarded() {
  local nazgul_dir="$1" task_id="$2" from="" to since_ts
  if [ "$#" -eq 5 ]; then
    from="$3"; to="$4"; since_ts="$5"
  else
    to="$3"; since_ts="$4"
  fi
  local logs ledger
  logs=$(_ttg_runtime_dir_path "$nazgul_dir" logs false) || return 1
  ledger="$logs/guarded-transitions.jsonl"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 1
  jq -e --arg t "$task_id" --arg f "$from" --arg to "$to" --arg since "$since_ts" \
    'select(.task_id == $t and .to == $to and .timestamp >= $since and ($f == "" or .from == $f))' \
    "$ledger" >/dev/null 2>&1
}

# True iff completed ledger edges chain <from> to <to> since <since_ts>: one
# iteration spans several edges, so authority is a path, not a single entry.
ttg_transition_chain_is_guarded() {
  local nazgul_dir="$1" task_id="$2" from="$3" to="$4" since_ts="$5"
  local logs ledger
  logs=$(_ttg_runtime_dir_path "$nazgul_dir" logs false) || return 1
  ledger="$logs/guarded-transitions.jsonl"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 1
  jq -e -s --arg t "$task_id" --arg from "$from" --arg to "$to" --arg since "$since_ts" \
    '(map(select(.task_id == $t and .timestamp >= $since))
      | reduce .[] as $e ($from; if $e.from == . then $e.to else . end)) == $to' \
    "$ledger" >/dev/null 2>&1
}
