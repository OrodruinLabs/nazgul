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
# shellcheck source=/dev/null
source "$_TTG_DIR/merge-provider.sh"

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
    # ADR-023 decision 3: the merge-closure edge. In the graph, NEVER unconditional —
    # ttg_validate_transition refuses it unless ttg_verify_merge_evidence validates.
    IMPLEMENTED_DONE)              return 0 ;;
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
    # ADR-022: CANCELLED is operator-declared "will never ship". Terminal like
    # DONE, so every non-terminal status reaches it and it has no out-edge.
    PLANNED_CANCELLED)             return 0 ;;
    READY_CANCELLED)               return 0 ;;
    IN_PROGRESS_CANCELLED)         return 0 ;;
    IMPLEMENTED_CANCELLED)         return 0 ;;
    IN_REVIEW_CANCELLED)           return 0 ;;
    APPROVED_CANCELLED)            return 0 ;;
    CHANGES_REQUESTED_CANCELLED)   return 0 ;;
    BLOCKED_CANCELLED)             return 0 ;;
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
  # ADR-022: a CANCELLED dependency satisfies in every granularity — it will never
  # ship, so waiting on it is waiting forever, and its `Depends on` record survives.
  case "$granularity" in
    group|feature)
      TTG_DEP_EXPECTED="IMPLEMENTED or later (review_gate.granularity=${granularity}) or CANCELLED"
      case "$dep_status" in
        IMPLEMENTED|IN_REVIEW|APPROVED|DONE|CANCELLED) return 0 ;;
      esac
      ;;
    *)
      if [ "$yolo" = "true" ]; then
        TTG_DEP_EXPECTED="APPROVED/DONE/CANCELLED"
        case "$dep_status" in DONE|APPROVED|CANCELLED) return 0 ;; esac
      else
        TTG_DEP_EXPECTED="DONE or CANCELLED"
        case "$dep_status" in DONE|CANCELLED) return 0 ;; esac
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

# Last red-run verdict: one of the closed block-reason vocabulary below, or
# verified/enumerated_na/not_applicable.
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

# Closed refusal vocabulary, asserted from this source in tests/test-red-run-evidence.sh:
# absent commented_out corrupt bad_na_token ref_unresolvable not_ancestor exit_zero roots_unresolved roots_undeterminable

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

# One disposition for both post-strip empties: in scope the named refusal, out of
# scope the announced skip. The caller names which state it saw.
_ttg_red_run_empty_payload() {
  local nazgul_dir="$1" task_id="$2" reason="$3" phrase="$4" manifest_text="$5" project_root="$6"
  if _ttg_red_run_in_scope "$manifest_text" "$project_root" "$nazgul_dir"; then
    _ttg_red_run_deny "$nazgul_dir" "$task_id" "$reason" \
      "## Red-Run Evidence ${phrase}, and this task's scope touches scripts/** or tests/**" || return 1
    return 0
  fi
  # shellcheck disable=SC2034  # read by scripts/stop-hook.sh, not within this file
  TTG_RED_RUN_REASON="not_applicable"
  echo "ttg_verify_red_run_evidence: ## Red-Run Evidence ${phrase}, and no scripts/** or tests/** path is in scope — red-run check not applicable, skipped" >&2
  return 0
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

# Usage: _ttg_section_emptiness <raw> <stripped> -> content | commented_out | absent.
# ONE stripper decides: what _ttg_strip_html_comments removed IS "inside a comment".
_ttg_section_emptiness() {
  if printf '%s' "$2" | grep -q '[^[:space:]]'; then
    printf 'content'
  elif printf '%s' "$1" | grep -q '[^[:space:]]'; then
    printf 'commented_out'
  else
    printf 'absent'
  fi
}

# The task id under `## Metadata`, or empty. Shared by every verifier that accepts an
# optional id argument, so the fallback derivation is one expression, not one per gate.
_ttg_manifest_task_id() {
  printf '%s' "$1" \
    | awk '/^## Metadata/{f=1;next} /^## /{f=0} f' \
    | grep -oE '(TASK|PATCH)-[0-9]+' | head -1 || true
}

# project.test_roots -> _TTG_ROOTS_REL (trigger prefixes), _TTG_ROOTS_RESOLVED
# ("rel<TAB>abs", containment) and the scan counters; 1 = set undeterminable.
_ttg_red_run_roots() {
  local project_root="$1" nazgul_dir="$2"
  local kind raw rel abs
  _TTG_ROOTS_REL=""
  _TTG_ROOTS_RESOLVED=""
  _TTG_ROOTS_DETAIL=""
  _TTG_ROOTS_SOURCE="default"
  _TTG_ROOTS_SCANNED=0
  _TTG_ROOTS_UNSAFE=0
  _TTG_ROOTS_UNRESOLVABLE=0
  _TTG_ROOTS_CHECKED=0

  if ! command -v jq >/dev/null 2>&1; then
    kind="jq-unavailable"
  elif [ ! -r "$nazgul_dir/config.json" ]; then
    kind="config-unreadable"
  else
    kind=$(jq -r '.project.test_roots
        | if . == null then "absent"
          elif type != "array" then "malformed"
          elif length == 0 then "empty"
          elif any(.[]; type != "string" or . == "") then "malformed"
          else "ok" end' "$nazgul_dir/config.json" 2>/dev/null) || kind="config-unparseable"
    [ -n "$kind" ] || kind="config-unparseable"
  fi

  case "$kind" in
    ok)
      _TTG_ROOTS_SOURCE="config"
      raw=$(jq -r '.project.test_roots[]' "$nazgul_dir/config.json" 2>/dev/null || true)
      ;;
    absent|jq-unavailable|config-unreadable|config-unparseable)
      _TTG_ROOTS_SOURCE="default:${kind}"
      raw="tests"
      ;;
    empty)
      _TTG_ROOTS_DETAIL="an empty array"
      _TTG_ROOTS_SOURCE="undeterminable"
      return 1
      ;;
    *)
      _TTG_ROOTS_DETAIL="not an array of non-empty repository-relative paths"
      _TTG_ROOTS_SOURCE="undeterminable"
      return 1
      ;;
  esac

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _TTG_ROOTS_SCANNED=$((_TTG_ROOTS_SCANNED + 1))
    rel="${rel#./}"
    rel="${rel%/}"
    case "$rel" in
      ""|/*)
        _TTG_ROOTS_UNSAFE=$((_TTG_ROOTS_UNSAFE + 1))
        continue
        ;;
    esac
    case "/$rel/" in
      */../*|*/./*)
        _TTG_ROOTS_UNSAFE=$((_TTG_ROOTS_UNSAFE + 1))
        continue
        ;;
    esac
    _TTG_ROOTS_REL="${_TTG_ROOTS_REL}${rel}
"
    if abs=$(cd "$project_root/$rel" 2>/dev/null && pwd -P) && [ -n "$abs" ]; then
      _TTG_ROOTS_RESOLVED="${_TTG_ROOTS_RESOLVED}${rel}	${abs}
"
      _TTG_ROOTS_CHECKED=$((_TTG_ROOTS_CHECKED + 1))
    else
      _TTG_ROOTS_UNRESOLVABLE=$((_TTG_ROOTS_UNRESOLVABLE + 1))
    fi
  done <<EOF
$raw
EOF
  # A set whose every entry was rejected has the same semantics as the empty set, so it
  # takes the `empty` arm: returning 0 here silently switched the tests/** trigger off.
  if [ -z "$_TTG_ROOTS_REL" ]; then
    _TTG_ROOTS_DETAIL="an array whose every entry (${_TTG_ROOTS_UNSAFE} of ${_TTG_ROOTS_SCANNED}) was rejected as an unsafe path"
    _TTG_ROOTS_SOURCE="undeterminable"
    return 1
  fi
  return 0
}

# The configured roots as one space-separated list, for diagnostics.
_ttg_red_run_roots_list() {
  printf '%s' "$_TTG_ROOTS_REL" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# A root set that quietly shrank to empty would re-create the unsatisfiable gate.
_ttg_red_run_roots_report() {
  printf 'ttg_verify_red_run_evidence: %s: tests-root scan: %d scanned, %d skipped (unsafe=%d, unresolvable=%d), %d checked, %d findings; source=%s; roots=[%s]\n' \
    "$1" "$_TTG_ROOTS_SCANNED" "$((_TTG_ROOTS_UNSAFE + _TTG_ROOTS_UNRESOLVABLE))" \
    "$_TTG_ROOTS_UNSAFE" "$_TTG_ROOTS_UNRESOLVABLE" "$_TTG_ROOTS_CHECKED" \
    "$((_TTG_ROOTS_UNSAFE + _TTG_ROOTS_UNRESOLVABLE))" "$_TTG_ROOTS_SOURCE" "$(_ttg_red_run_roots_list)" >&2
}

# A configured root is data, never a pattern: src/App.Tests/tests must not match src/AppXTests/tests.
_ttg_ere_escape() {
  printf '%s' "$1" | sed 's/[]$.^*+?|(){}\\[]/\\&/g'
}

# scripts/ plus every configured root, so trigger and satisfier read one set.
_ttg_red_run_scope_alternation() {
  local alt="scripts" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    alt="${alt}|$(_ttg_ere_escape "$rel")"
  done <<EOF
$_TTG_ROOTS_REL
EOF
  printf '%s' "$alt"
}

# A prohibition is not a declaration: "Must NOT touch scripts/" used to put a task
# into a scope it could never satisfy. Drops the label and its continuation.
_ttg_drop_prohibitions() {
  awk '
    {
      lab = $0
      sub(/^[[:space:]]*[-*+][[:space:]]*/, "", lab)
      sub(/^[[:space:]]+/, "", lab)
      gsub(/\*/, "", lab)
      low = tolower(lab)
      if (low ~ /^(must not|must never|do not|dont|never)[[:space:]]+(touch|modify|edit|change|alter|create|add)/ ||
          low ~ /^(out of scope|prohibited|forbidden|excluded)([[:space:]]|:|$)/) {
        skip = 1
        next
      }
      if ($0 ~ /^[[:space:]]*\*\*[^*]+\*\*/) skip = 0
      if (!skip) print
    }'
}

# Scope is the union of declared paths and Base SHA..HEAD; diff failure degrades loudly to manifest-only.
_ttg_red_run_in_scope() {
  local manifest_text="$1" project_root="$2"
  local nazgul_dir="${3:-$project_root/nazgul}"
  local declared diff_out base_sha degrade="" alt

  if ! _ttg_red_run_roots "$project_root" "$nazgul_dir"; then
    echo "ttg_verify_red_run_evidence: red-run scope predicate could not determine the tests roots (project.test_roots is ${_TTG_ROOTS_DETAIL}) — failing closed, this task is treated as in scope" >&2
    return 0
  fi
  _ttg_red_run_roots_report "red-run scope predicate"
  alt=$(_ttg_red_run_scope_alternation)

  declared=$(printf '%s\n' "$manifest_text" \
    | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Files modified\*\*' || true)
  declared="${declared}
$(printf '%s' "$manifest_text" | awk '/^## File Scope/{f=1;next} /^## /{f=0} f' | _ttg_drop_prohibitions)"
  declared=$(printf '%s\n' "$declared" | _ttg_strip_html_comments)
  if printf '%s\n' "$declared" | grep -qE "(^|[^[:alnum:]_./-])(${alt})/"; then
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
    elif printf '%s\n' "$diff_out" | grep -qE "^(${alt})/"; then
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
  local payload test_path abs_path resolved_parent ref result_line exit_code na_token tok found
  local rel abs roots_list shaped contained

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
  if ! _ttg_red_run_roots "$project_root" "$nazgul_dir"; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "roots_undeterminable" \
      "red-run entry test path '${test_path}' cannot be judged: project.test_roots is ${_TTG_ROOTS_DETAIL}, so the tests-root set is undeterminable"; then
      return 1
    fi
    return 0
  fi
  roots_list=$(_ttg_red_run_roots_list)
  shaped=false
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$test_path" in
      "$rel"/*)
        shaped=true
        break
        ;;
    esac
  done <<EOF
$_TTG_ROOTS_REL
EOF
  if [ "$shaped" != true ]; then
    _ttg_red_run_roots_report "red-run entry path shape"
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry test path '${test_path}' must be repository-relative and under a configured tests root (${roots_list})"; then
      return 1
    fi
    return 0
  fi
  if [ "$_TTG_ROOTS_CHECKED" -eq 0 ]; then
    _ttg_red_run_roots_report "red-run entry containment"
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "roots_unresolved" \
      "red-run entry test path '${test_path}' cannot be contained: every configured tests root (${roots_list}) was skipped, so no root resolves under ${project_root}"; then
      return 1
    fi
    return 0
  fi
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
  resolved_parent=$(cd "$(dirname "$abs_path")" 2>/dev/null && pwd -P) || resolved_parent=""
  if [ -z "$resolved_parent" ]; then
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry test path '${test_path}' could not be resolved under any configured tests root (${roots_list})"; then
      return 1
    fi
    return 0
  fi
  contained=false
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="${rel#*	}"
    case "$resolved_parent/" in
      "$abs"/*)
        contained=true
        break
        ;;
    esac
  done <<EOF
$_TTG_ROOTS_RESOLVED
EOF
  if [ "$contained" != true ]; then
    _ttg_red_run_roots_report "red-run entry containment"
    if ! _ttg_red_run_deny "$nazgul_dir" "$task_id" "corrupt" \
      "red-run entry test path '${test_path}' resolves outside every configured tests root (${roots_list})"; then
      return 1
    fi
    return 0
  fi

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
# Seven dispositions, never one collapsed allow (RULES §15 / ADR-009 — weighed
# per guard, not inherited by proximity): section absent + in scope BLOCKs
# (a false deny costs one manifest edit; a false allow makes the whole charter
# decorative); section absent + out of scope ALLOWs and announces the skipped
# check; a section emptied ONLY by the comment strip BLOCKs as commented_out and
# one empty before it as absent; a section with unparseable content as corrupt;
# an entry whose ref, ancestry, or recorded exit code git can refute BLOCKs
# naming which check failed; an enumerated `N/A` token ALLOWs; a free-text
# `N/A` BLOCKs.
# Usage: ttg_verify_red_run_evidence <manifest_text> <project_root> [task_id]
ttg_verify_red_run_evidence() {
  local manifest_text="$1" project_root="$2" task_id="${3:-}"
  local nazgul_dir="${NAZGUL_DIR:-$project_root/nazgul}"
  local raw_section section commits entry="" line rc=0

  TTG_RED_RUN_REASON=""
  [ -n "$task_id" ] || task_id=$(_ttg_manifest_task_id "$manifest_text")
  [ -n "$task_id" ] || task_id="unknown"

  if ! printf '%s\n' "$manifest_text" | grep -q '^## Red-Run Evidence'; then
    if _ttg_red_run_in_scope "$manifest_text" "$project_root" "$nazgul_dir"; then
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
    case "$(_ttg_section_emptiness "$raw_section" "$section")" in
      commented_out)
        _ttg_red_run_empty_payload "$nazgul_dir" "$task_id" "commented_out" \
          "carries content only inside an HTML comment (a comment is not a record, so nothing was counted)" \
          "$manifest_text" "$project_root" || return 1
        return 0 ;;
      absent)
        _ttg_red_run_empty_payload "$nazgul_dir" "$task_id" "absent" \
          "section is present but empty" "$manifest_text" "$project_root" || return 1
        return 0 ;;
    esac
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

# lean-comments: allow-run — `head-ref` is the answer to "merged, but whose?"; a reader
# must not drop it back to five as a redundant field.
# The six facts a closure records, under `## Merge Evidence` and nowhere else. `recorded-by`
# is REQUIRED: without it a hand-typed block and a producer-written one are the same lines.
# `head-ref` is what binds the PR to THIS objective: without it a genuinely merged PR of
# ANY other objective is equally good evidence for closing any task on disk.
_TTG_MERGE_REQUIRED_FIELDS="host pr merged-at merge-commit head-ref recorded-by"

# Closed producer set for `recorded-by`. A value naming anything else is `malformed`.
_TTG_MERGE_PRODUCERS="scripts/close-objective.sh"

# Closed refusal vocabulary, never bucketed (RULES.md §15), asserted from this source in tests:
# absent commented_out truncated malformed unverifiable not_merged contradicted not_this_objective
# not_this_objectives_task

# Last merge verdict: one of the closed vocabulary above, or `verified`.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_REASON=""
# Corroboration outcome: corroborated | squash_signature | unavailable. Never a verdict.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_ANCESTRY=""
# Identity of the evidence that validated, for the caller's which-route diagnostic.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_ROUTE=""
# Base-branch containment outcome: ancestor_of_base | not_ancestor | unresolved |
# base_unresolvable | no_git. Only not_ancestor blocks.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_BASE_ANCESTRY=""
# The host's own answer for the last check: ok | not_merged | ok_no_head_ref |
# <merge-provider result>.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_HOST_RESULT=""
# The head branch the host reports for the PR, empty when it returned none usable.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_HOST_HEAD_REF=""
# The base branch the host reports for the PR. Reported, never gated on.
# shellcheck disable=SC2034  # read by callers, not within this file
TTG_MERGE_HOST_BASE_REF=""

# Deliberately NO kill switch (unlike guards.red_run_evidence, which only suppresses a block
# on the way IN to IMPLEMENTED): a switch on the last gate before DONE IS the bypass.
_ttg_merge_deny() {
  local nazgul_dir="$1" task_id="$2" reason="$3" detail="$4"
  TTG_MERGE_REASON="$reason"
  echo "ttg_verify_merge_evidence: ${detail} [reason: ${reason}]" >&2
  _ttg_emit_event "$nazgul_dir" "merge_evidence_missing" task_id "$task_id" reason "$reason"
  return 1
}

# One `- **key**: value` / `- key: value` field out of a section; empty when absent.
_ttg_merge_field() {
  printf '%s\n' "$2" \
    | grep -iE "^[[:space:]]*-[[:space:]]*(\*\*)?$1(\*\*)?:" \
    | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//' \
    | tr -d '`'
}

_ttg_merge_shape_ok() {
  local key="$1" value="$2"
  case "$key" in
    host)         [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ;;
    pr)           [[ "$value" =~ ^[0-9]+$ ]] ;;
    merged-at)    [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]] ;;
    merge-commit) [[ "$value" =~ ^[0-9a-fA-F]{7,64}$ ]] ;;
    head-ref)     _mp_ref_ok "$value" ;;
    recorded-by)  _ttg_merge_producer_ok "$value" ;;
    *) return 1 ;;
  esac
}

# `<producer>` or `<producer> (<detail>)` for one member of the closed producer set.
_ttg_merge_producer_ok() {
  local value="$1" producer
  for producer in $_TTG_MERGE_PRODUCERS; do
    case "$value" in
      "$producer") return 0 ;;
      "$producer ("*")") return 0 ;;
    esac
  done
  return 1
}

# lean-comments: allow-run — ADR-023 decision 1's rationale, kept where a reader would
# otherwise "fix" this into a predicate.
# CORROBORATION ONLY, never a predicate. After a server-side squash NO recorded SHA
# reaches the merge commit, so a FAILING check is the NORMAL case on a squash host: it is
# the expected squash signature, not an anomaly, and blocking on it would report "not
# shipped" for work that demonstrably shipped. Every path returns 0; the outcome lands in
# TTG_MERGE_ANCESTRY and never in the verdict.
_ttg_merge_ancestry() {
  local project_root="$1" merge_commit="$2" commits="$3" sha
  TTG_MERGE_ANCESTRY="unavailable"
  command -v git >/dev/null 2>&1 || return 0
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  TTG_MERGE_ANCESTRY="squash_signature"
  git -C "$project_root" cat-file -e "${merge_commit}^{commit}" 2>/dev/null || return 0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$project_root" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    if git -C "$project_root" merge-base --is-ancestor "$sha" "$merge_commit" 2>/dev/null; then
      TTG_MERGE_ANCESTRY="corroborated"
      return 0
    fi
  done < <(printf '%s' "$commits" | grep -oE '[0-9a-f]{7,64}' || true)
  return 0
}

# Timestamps and SHAs from two producers are compared as VALUES, not as bytes: the host
# may render the same instant with a fractional part or a numeric offset.
_ttg_merge_norm_ts() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/\.[0-9]+//; s/\+00:?00$/Z/'
}

# True iff two hex SHAs name the same commit — one abbreviation of the other counts,
# since a manifest may record a short form of the host's full oid.
_ttg_sha_agree() {
  local a b
  a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case "$a" in "$b"*) return 0 ;; esac
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

# lean-comments: allow-run — this is the answer to "the gate validates nothing"; a reader
# must not shorten it back into a shape check.
# Ask the HOST, because every field above is operator-writable text and a shape check on
# operator-writable text certifies whoever typed it. The manifest is only ever compared
# against merge_provider_pr_state's answer, and the three outcomes stay separate:
#   0  the host answered and says merged (TTG_MERGE_HOST_* carry its answer)
#   1  the host answered and says NOT merged
#   2  the host could not be asked, or answered unusably — NEVER read as "not merged"
# A merged PR whose head branch the host did not return lands in the third outcome, never
# the first: the seam drops a ref it cannot vouch for, and merge-provider.sh's own contract
# says a caller needing the binding must fail closed on null. A PR that cannot be SHOWN to
# be this objective's is not thereby this objective's.
_ttg_merge_host_state() {
  local project_root="$1" pr="$2" json="" result="" merged=""
  TTG_MERGE_HOST_RESULT="unavailable"
  TTG_MERGE_HOST_AT=""
  TTG_MERGE_HOST_COMMIT=""
  TTG_MERGE_HOST_HEAD_REF=""
  TTG_MERGE_HOST_BASE_REF=""
  declare -F merge_provider_pr_state >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  json=$(merge_provider_pr_state "$project_root" "$pr") || true
  [ -n "$json" ] || return 2
  result=$(printf '%s' "$json" | jq -r '.result // empty' 2>/dev/null) || result=""
  [ -n "$result" ] || return 2
  TTG_MERGE_HOST_RESULT="$result"
  [ "$result" = "ok" ] || return 2
  merged=$(printf '%s' "$json" | jq -r '.merged | tostring' 2>/dev/null) || merged=""
  TTG_MERGE_HOST_AT=$(printf '%s' "$json" | jq -r '.merged_at // empty' 2>/dev/null) || TTG_MERGE_HOST_AT=""
  TTG_MERGE_HOST_COMMIT=$(printf '%s' "$json" | jq -r '.merge_commit // empty' 2>/dev/null) || TTG_MERGE_HOST_COMMIT=""
  TTG_MERGE_HOST_HEAD_REF=$(printf '%s' "$json" | jq -r '.head_ref // empty' 2>/dev/null) || TTG_MERGE_HOST_HEAD_REF=""
  _mp_ref_ok "$TTG_MERGE_HOST_HEAD_REF" || TTG_MERGE_HOST_HEAD_REF=""
  TTG_MERGE_HOST_BASE_REF=$(printf '%s' "$json" | jq -r '.base_ref // empty' 2>/dev/null) || TTG_MERGE_HOST_BASE_REF=""
  _mp_ref_ok "$TTG_MERGE_HOST_BASE_REF" || TTG_MERGE_HOST_BASE_REF=""
  case "$merged" in
    false) TTG_MERGE_HOST_RESULT="not_merged"; return 1 ;;
    true)  ;;
    *)     TTG_MERGE_HOST_RESULT="ok_merged_unknown"; return 2 ;;
  esac
  if [ -z "$TTG_MERGE_HOST_HEAD_REF" ]; then
    TTG_MERGE_HOST_RESULT="ok_no_head_ref"
    return 2
  fi
  return 0
}

# The branches this objective may legitimately have shipped from. Under stacking the PR
# is opened from the layer's branch, which need not equal `branch.feature`.
ttg_objective_branches() {
  local nazgul_dir="$1" feat_id="$2"
  jq -r --arg f "$feat_id" '
    [ (.branch.feature // empty), (.stack.layers[]? | select(.feat_id == $f) | .branch // empty) ]
    | map(select(. != "")) | unique | .[]' "$nazgul_dir/config.json" 2>/dev/null || true
}

# lean-comments: allow-run — states what this check is and, more importantly, what it is not.
# _ttg_pr_history_owner <nazgul_dir> <pr> -> the feat_id config's OWN objectives_history
# attributes this PR number to, empty when it attributes it to nobody. Not an independent
# anchor — it is the same operator-writable file the branch set comes from — but a binding
# read out of a file that contradicts itself is not a binding, and this makes the one-key
# `.branch.feature` edit insufficient on its own.
_ttg_pr_history_owner() {
  local nazgul_dir="$1" pr="$2"
  case "$pr" in ''|*[!0-9]*) return 0 ;; esac
  jq -r --arg p "$pr" '
    [ .objectives_history[]? | select(((.pr // "") | tostring) | test("(^|/)" + $p + "$"))
      | .feat_id // empty ] | unique | .[]' "$nazgul_dir/config.json" 2>/dev/null | head -1 || true
}

# lean-comments: allow-run — the fail-closed reading is the finding this function closes.
# ttg_pr_bound <nazgul_dir> <feat_id> <head_ref> <pr_label> [base_ref] -> 0 iff the merged
# PR is THIS objective's PR, else the reason on stdout. THE one authority for that question:
# the merge-evidence gate and scripts/close-objective.sh both call it, because a binding
# enforced in the caller only leaves the gate — which is independently reachable through
# the sanctioned writer — admitting any merged PR in the repository. Fails closed on every
# ambiguity, including a host that returned no usable head branch: a PR that cannot be
# SHOWN to be ours is not thereby ours. `base_ref` is reported but never gated on — under
# stacking it is the previous layer, not `branch.base`.
ttg_pr_bound() {
  local nazgul_dir="$1" feat_id="$2" head_ref="$3" pr_label="$4" base_ref="${5:-}" want b owner into
  if [ -z "$feat_id" ]; then
    printf 'config.json names no feat_id, so no PR can be shown to belong to this objective'
    return 1
  fi
  if [ -z "$head_ref" ]; then
    printf 'the host returned no usable head branch for PR %s, so it cannot be shown to be %s'"'"'s PR — a merged PR of some other objective is real evidence about that objective, not licence to close this one' \
      "$pr_label" "$feat_id"
    return 1
  fi
  owner=$(_ttg_pr_history_owner "$nazgul_dir" "$pr_label")
  if [ -n "$owner" ] && [ "$owner" != "$feat_id" ]; then
    printf 'config.json'"'"'s own objectives_history records PR %s as %s'"'"'s PR, not %s'"'"'s — the objective identity and the PR registry in that file contradict each other, and no binding can be read out of a contradiction' \
      "$pr_label" "$owner" "$feat_id"
    return 1
  fi
  want=$(ttg_objective_branches "$nazgul_dir" "$feat_id")
  if [ -z "$want" ]; then
    printf 'neither branch.feature nor a stack.layers[] entry for %s names a branch, so there is nothing for PR %s'"'"'s head branch %s to be matched against' \
      "$feat_id" "$pr_label" "$head_ref"
    return 1
  fi
  while IFS= read -r b; do
    if [ "$b" = "$head_ref" ]; then return 0; fi
  done <<< "$want"
  # An absent base is the host not reporting one (or reporting an unusable one), not a
  # base named "<unknown>" — the diagnostic says which, since no predicate reads it.
  if [ -n "$base_ref" ]; then into=" (into $base_ref)"; else into=" (the host reported no usable base branch)"; fi
  printf 'PR %s was merged from %s%s, which is not %s'"'"'s branch (%s) — its merge is genuine, host-verified evidence about a DIFFERENT objective' \
    "$pr_label" "$head_ref" "$into" "$feat_id" \
    "$(printf '%s' "$want" | tr '\n' ' ')"
  return 1
}

# ttg_plan_feat_id <plan_file> -> the frontmatter feat_id, empty when none is declared. THE
# one parser: the producer writes and reads back through it, so it cannot drift from here.
ttg_plan_feat_id() {
  awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f && /^---[[:space:]]*$/ {exit} f && /^feat_id:/ {sub(/^feat_id:[[:space:]]*/, ""); gsub(/[]["'"'"'[:space:]]/, ""); print; exit}' "$1" 2>/dev/null
}

# ttg_plan_feat_placeholder <value> -> 0 iff the value is an unsubstituted <...> placeholder.
ttg_plan_feat_placeholder() {
  case "$1" in "<"*">") return 0 ;; *) return 1 ;; esac
}

# lean-comments: allow-run — RULES.md §15's two-answers distinction, at the guard it binds.
# ttg_objective_roster <nazgul_dir> -> the task ids this objective's own nazgul/plan.md
# lists under `## Tasks`, one per line; non-zero with the reason on stdout when membership
# cannot be established AT ALL. "the roster does not list it" and "there is no readable
# roster" are different answers, and neither may degrade into an unscoped one.
ttg_objective_roster() {
  local nazgul_dir="$1" plan="$1/plan.md" feat_id plan_feat ids
  feat_id=$(jq -r '.feat_id // empty' "$nazgul_dir/config.json" 2>/dev/null) || feat_id=""
  if [ -z "$feat_id" ]; then
    printf 'config.json names no feat_id, so no objective owns any manifest'
    return 1
  fi
  if [ ! -f "$plan" ] || [ -L "$plan" ]; then
    printf 'no regular non-symlink %s, so which manifests belong to %s is unknowable' "$plan" "$feat_id"
    return 1
  fi
  plan_feat=$(ttg_plan_feat_id "$plan")
  # "declares nothing" and "declares someone else" are different facts: templates/plan.md
  # carried no frontmatter for 31 objectives, so the first is un-migrated, not foreign.
  if [ -z "$plan_feat" ]; then
    printf '%s declares no frontmatter feat_id, so it cannot corroborate that its roster is %s'"'"'s — run scripts/stamp-plan-objective.sh to add a leading "---\nfeat_id: %s\n---" block to that file' \
      "$plan" "$feat_id" "$feat_id"
    return 1
  fi
  # An unsubstituted templates/plan.md placeholder is not a rival claim — it is a producer
  # that never ran, and saying "disagree" sent operators to reconcile two real objectives.
  if ttg_plan_feat_placeholder "$plan_feat"; then
    printf '%s still carries templates/plan.md'"'"'s unsubstituted placeholder feat_id "%s" — no producer ever bound this plan to an objective, so its roster scopes nothing; run scripts/stamp-plan-objective.sh to bind it to %s' \
      "$plan" "$plan_feat" "$feat_id"
    return 1
  fi
  if [ "$plan_feat" != "$feat_id" ]; then
    printf '%s declares feat_id "%s" but config names "%s" — the roster and the objective disagree, so neither can scope the other' \
      "$plan" "$plan_feat" "$feat_id"
    return 1
  fi
  # templates/plan.md documents its roster format with COMMENTED example entries, so an
  # unplanned plan used to yield a one-id roster: TASK-001, a task nobody ever wrote.
  local section commented
  section=$(awk '/^## Tasks/{f=1;next} f && /^## /{exit} f' "$plan")
  ids=$(printf '%s\n' "$section" | _ttg_strip_html_comments | grep -oE '(TASK|PATCH)-[0-9]+' | LC_ALL=C sort -u)
  if [ -z "$ids" ]; then
    commented=$(printf '%s\n' "$section" | grep -coE '(TASK|PATCH)-[0-9]+' || true)
    if [ "${commented:-0}" -gt 0 ]; then
      printf '%s'"'"'s ## Tasks section names task ids ONLY inside HTML comments — those are templates/plan.md'"'"'s example entries, not a roster, so no manifest can be shown to belong to %s' \
        "$plan" "$feat_id"
      return 1
    fi
    printf '%s carries no ## Tasks roster to read, so no manifest can be shown to belong to %s' "$plan" "$feat_id"
    return 1
  fi
  printf '%s\n' "$ids"
}

# ttg_id_in_roster <roster> <task_id> -> 0 iff the id is one of the roster's own lines.
ttg_id_in_roster() {
  local id
  { [ -n "$1" ] && [ -n "$2" ]; } || return 1
  while IFS= read -r id; do
    if [ "$id" = "$2" ]; then return 0; fi
  done <<< "$1"
  return 1
}

# lean-comments: allow-run — the sibling of ttg_pr_bound's rationale, one granularity down.
# ttg_task_in_objective <nazgul_dir> <task_id> -> 0 iff this objective's roster lists the
# task, else the reason on stdout. THE one authority for that question: the merge-evidence
# gate and scripts/close-objective.sh both call it, because a binding enforced in the caller
# only leaves the gate — independently reachable through the sanctioned writer — admitting
# any manifest on disk once this objective's PR genuinely merges, since the block the closer
# writes into a roster manifest is valid evidence copied verbatim into a stranded one.
ttg_task_in_objective() {
  local nazgul_dir="$1" task_id="$2" roster
  if ! roster=$(ttg_objective_roster "$nazgul_dir"); then
    printf 'membership was never established: %s' "$roster"
    return 1
  fi
  ttg_id_in_roster "$roster" "$task_id" && return 0
  printf '%s is not listed in the ## Tasks roster of %s/plan.md — a manifest absent from this objective'"'"'s roster belongs to a different one, and this objective'"'"'s merge does not close it' \
    "${task_id:-<unnamed>}" "$nazgul_dir"
  return 1
}

# Positive-only base containment: a merge commit that does not resolve locally stays
# non-blocking, but one that DOES resolve must sit on the base. Only not_ancestor blocks.
_ttg_merge_base_ancestry() {
  local project_root="$1" nazgul_dir="$2" merge_commit="$3" base ref resolved=false
  TTG_MERGE_BASE_ANCESTRY="no_git"
  command -v git >/dev/null 2>&1 || return 0
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  TTG_MERGE_BASE_ANCESTRY="unresolved"
  git -C "$project_root" cat-file -e "${merge_commit}^{commit}" 2>/dev/null || return 0
  base=$(jq -r '.branch.base // empty' "$nazgul_dir/config.json" 2>/dev/null || true)
  [ -n "$base" ] || base="main"
  TTG_MERGE_BASE_ANCESTRY="base_unresolvable"
  for ref in "$base" "origin/$base"; do
    git -C "$project_root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || continue
    resolved=true
    if git -C "$project_root" merge-base --is-ancestor "$merge_commit" "$ref" 2>/dev/null; then
      TTG_MERGE_BASE_ANCESTRY="ancestor_of_base"
      return 0
    fi
  done
  [ "$resolved" = "true" ] && TTG_MERGE_BASE_ANCESTRY="not_ancestor"
  return 0
}

# Merge-evidence verification (ADR-023 decision 3), third verifier in the established shape.
# Usage: ttg_verify_merge_evidence <manifest_text> <project_root> [task_id]
ttg_verify_merge_evidence() {
  local manifest_text="$1" project_root="$2" task_id="${3:-}"
  local nazgul_dir="${NAZGUL_DIR:-$project_root/nazgul}"
  local raw_section section key value missing="" bad="" commits phrase
  local host pr merge_commit merged_at head_ref feat_id bind_why roster_why host_rc=0

  TTG_MERGE_REASON=""
  TTG_MERGE_ANCESTRY=""
  TTG_MERGE_ROUTE=""
  TTG_MERGE_BASE_ANCESTRY=""
  TTG_MERGE_HOST_RESULT=""
  TTG_MERGE_HOST_HEAD_REF=""
  TTG_MERGE_HOST_BASE_REF=""
  [ -n "$task_id" ] || task_id=$(_ttg_manifest_task_id "$manifest_text")
  [ -n "$task_id" ] || task_id="unknown"

  if ! printf '%s\n' "$manifest_text" | grep -q '^## Merge Evidence'; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "absent" \
      "no ## Merge Evidence section — that heading is the enforcement boundary, so merge fields recorded anywhere else in the manifest are not evidence"
    return 1
  fi

  raw_section=$(printf '%s' "$manifest_text" | awk '/^## Merge Evidence/{f=1;next} /^## /{f=0} f')
  section=$(printf '%s\n' "$raw_section" | _ttg_strip_html_comments)
  case "$(_ttg_section_emptiness "$raw_section" "$section")" in
    commented_out)
      _ttg_merge_deny "$nazgul_dir" "$task_id" "commented_out" \
        "## Merge Evidence carries content only inside an HTML comment — present, but a comment is not a record, so nothing was counted"
      return 1 ;;
    absent)
      _ttg_merge_deny "$nazgul_dir" "$task_id" "absent" \
        "## Merge Evidence section is present but empty"
      return 1 ;;
  esac

  for key in $_TTG_MERGE_REQUIRED_FIELDS; do
    value=$(_ttg_merge_field "$key" "$section")
    if [ -z "$value" ]; then
      missing="${missing}${missing:+, }${key}"
    elif ! _ttg_merge_shape_ok "$key" "$value"; then
      bad="${bad}${bad:+, }${key}='${value}'"
    fi
  done
  if [ -n "$missing" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "truncated" \
      "## Merge Evidence is missing required field(s) ${missing} — a closure records all of: ${_TTG_MERGE_REQUIRED_FIELDS// /, }"
    return 1
  fi
  if [ -n "$bad" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "malformed" \
      "## Merge Evidence field(s) present but unusable: ${bad}"
    return 1
  fi

  host=$(_ttg_merge_field host "$section")
  pr=$(_ttg_merge_field pr "$section")
  merged_at=$(_ttg_merge_field merged-at "$section")
  merge_commit=$(_ttg_merge_field merge-commit "$section")
  head_ref=$(_ttg_merge_field head-ref "$section")

  _ttg_merge_host_state "$project_root" "$pr" || host_rc=$?
  if [ "$host_rc" -eq 1 ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "not_merged" \
      "the host ANSWERED for PR ${pr} and reports it is not merged — the manifest's ## Merge Evidence says otherwise"
    return 1
  fi
  if [ "$TTG_MERGE_HOST_RESULT" = "ok_no_head_ref" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "unverifiable" \
      "the host reports PR ${pr} merged but returned no usable head branch, so the PR cannot be bound to an objective — a merge nobody can attribute never admits a closure"
    return 1
  fi
  if [ "$host_rc" -ne 0 ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "unverifiable" \
      "PR ${pr} could not be verified against ${host} [merge-provider: ${TTG_MERGE_HOST_RESULT}] — this is NOT 'not merged', and an unreachable host never admits a closure"
    return 1
  fi
  if [ -z "$TTG_MERGE_HOST_AT" ] || [ -z "$TTG_MERGE_HOST_COMMIT" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "unverifiable" \
      "the host reports PR ${pr} merged but returned no merged-at/merge-commit to compare the manifest against — nothing outside the manifest corroborates it"
    return 1
  fi
  if [ "$(_ttg_merge_norm_ts "$merged_at")" != "$(_ttg_merge_norm_ts "$TTG_MERGE_HOST_AT")" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "contradicted" \
      "## Merge Evidence records merged-at=${merged_at} but ${host} reports ${TTG_MERGE_HOST_AT} for PR ${pr}"
    return 1
  fi
  if ! _ttg_sha_agree "$merge_commit" "$TTG_MERGE_HOST_COMMIT"; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "contradicted" \
      "## Merge Evidence records merge-commit=${merge_commit} but ${host} reports ${TTG_MERGE_HOST_COMMIT} for PR ${pr}"
    return 1
  fi

  if [ "$head_ref" != "$TTG_MERGE_HOST_HEAD_REF" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "contradicted" \
      "## Merge Evidence records head-ref=${head_ref} but ${host} reports PR ${pr} was merged from ${TTG_MERGE_HOST_HEAD_REF}"
    return 1
  fi
  feat_id=$(jq -r '.feat_id // empty' "$nazgul_dir/config.json" 2>/dev/null) || feat_id=""
  if ! bind_why=$(ttg_pr_bound "$nazgul_dir" "$feat_id" "$TTG_MERGE_HOST_HEAD_REF" "$pr" "$TTG_MERGE_HOST_BASE_REF"); then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "not_this_objective" \
      "the host confirms PR ${pr} merged, but it is not this objective's PR — ${bind_why}"
    return 1
  fi

  if ! roster_why=$(ttg_task_in_objective "$nazgul_dir" "$task_id"); then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "not_this_objectives_task" \
      "PR ${pr} is this objective's genuinely merged PR, but ${task_id} is not this objective's task — ${roster_why}"
    return 1
  fi

  _ttg_merge_base_ancestry "$project_root" "$nazgul_dir" "$merge_commit"
  if [ "$TTG_MERGE_BASE_ANCESTRY" = "not_ancestor" ]; then
    _ttg_merge_deny "$nazgul_dir" "$task_id" "contradicted" \
      "merge-commit ${merge_commit} resolves in local history but is not contained in the base branch — a merge commit that exists here must sit on the base"
    return 1
  fi

  commits=$(printf '%s' "$manifest_text" | awk '/^## Commits/{f=1;next} /^## /{f=0} f')
  _ttg_merge_ancestry "$project_root" "$merge_commit" "$commits"
  case "$TTG_MERGE_ANCESTRY" in
    corroborated) phrase="a recorded ## Commits SHA corroborates it" ;;
    squash_signature) phrase="no recorded ## Commits SHA reaches it — the expected squash signature, recorded and non-blocking" ;;
    *) phrase="not checkable here (no git repository at the project root) — corroboration only, non-blocking" ;;
  esac

  TTG_MERGE_REASON="verified"
  TTG_MERGE_ROUTE="host=${host} pr=${pr} merged-at=${merged_at} merge-commit=${merge_commit} head-ref=${head_ref} recorded-by=$(_ttg_merge_field recorded-by "$section") host-state=${TTG_MERGE_HOST_RESULT} base=${TTG_MERGE_BASE_ANCESTRY} ancestry=${TTG_MERGE_ANCESTRY}"
  echo "ttg_verify_merge_evidence: verified against the host — ${TTG_MERGE_ROUTE}; ${phrase}" >&2
  return 0
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
  local review_problem=""
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

  # ADR-022: CANCELLED must not become a second exit from the ADR-020 quarantine.
  # Anchored like the check above, so an already-repaired kind cannot be caught by it.
  if [ "$from" = "BLOCKED" ] && [ "$to" = "CANCELLED" ]; then
    if printf '%s\n' "$manifest_text" | grep -qiE '^\- \*\*Blocked kind\*\*:[[:space:]]*reconciliation[[:space:]]*$'; then
      echo "ttg_validate_transition: BLOCKED -> CANCELLED is refused for a typed reconciliation quarantine — its only sanctioned exit is scripts/task-transition.sh repair" >&2
      return 1
    fi
  fi

  # ADR-023 decision 3: the merge-closure route. The edge is in the graph, but the
  # evidence is what admits it — an unconditional edge here would be a second forgery route.
  if [ "$from" = "IMPLEMENTED" ] && [ "$to" = "DONE" ]; then
    if ! ttg_verify_merge_evidence "$manifest_text" "$project_root" "$task_id"; then
      echo "ttg_validate_transition: IMPLEMENTED -> DONE requires verified merge evidence under ## Merge Evidence (${_TTG_MERGE_REQUIRED_FIELDS// /, }); none validated [reason: ${TTG_MERGE_REASON}]" >&2
      return 1
    fi
    echo "ttg_validate_transition: DONE via the merge-evidence route (${TTG_MERGE_ROUTE}) — no review board was consulted for this edge" >&2
    return 0
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
      review_problem="${to} requires a canonical non-symlink review directory for ${review_unit}"
    elif ! ttg_review_evidence_paths_safe "$nazgul_dir" "$review_dir"; then
      review_problem="${to} review evidence contains an unsafe name, symlink, or non-regular leaf"
    else
      problems=$(ttg_verify_review_evidence "$nazgul_dir" "$task_id") || true
      if [ -n "$problems" ]; then
        review_problem="${to} requires complete configured review evidence: ${problems}"
      elif [ "$require_provenance" = "true" ]; then
        provenance_problems=$(validate_review_provenance "$nazgul_dir" "$review_unit") || true
        if [ -n "$provenance_problems" ]; then
          review_problem="${to} failed the configured legacy-compatible review provenance validator: ${provenance_problems}"
        fi
      fi
    fi

    if [ -z "$review_problem" ]; then
      echo "ttg_validate_transition: ${to} via the review-evidence route (${review_unit}, all configured verdicts present)" >&2
      return 0
    fi
    echo "ttg_validate_transition: ${review_problem}" >&2
    # ADR-023: merge evidence is an ALTERNATIVE to the review route for DONE, never a
    # bypass of it — one of the two must validate, and the accepted one is always named.
    if [ "$to" = "DONE" ]; then
      if ttg_verify_merge_evidence "$manifest_text" "$project_root" "$task_id"; then
        echo "ttg_validate_transition: DONE via the merge-evidence route (${TTG_MERGE_ROUTE}); the review-evidence route did not validate" >&2
        return 0
      fi
      echo "ttg_validate_transition: DONE requires ONE of the review-evidence route or the merge-evidence route to validate; neither did (merge evidence [reason: ${TTG_MERGE_REASON}])" >&2
    fi
    return 1
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
# lines so the runtime ledger remains bounded. <writer> attributes an out-of-command edge.
# Usage: ttg_log_transition <nazgul_dir> <task_id> <from> <to> [before] [after] [writer]
ttg_log_transition() {
  local nazgul_dir="$1" task_id="$2" from="$3" to="$4"
  local before_hash="${5:-}" after_hash="${6:-}" writer="${7:-}"
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
      --arg before "$before_hash" --arg after "$after_hash" --arg writer "$writer" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task_id:$t, from:$f, to:$to, timestamp:$ts}
       + (if $before == "" then {} else {before_sha256:$before} end)
       + (if $after == "" then {} else {after_sha256:$after} end)
       + (if $writer == "" then {} else {writer:$writer} end)') || return 1
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
