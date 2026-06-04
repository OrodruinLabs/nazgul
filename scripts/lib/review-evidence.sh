#!/usr/bin/env bash
# Nazgul shared review-evidence validation — sourced by task-state-guard.sh and stop-hook.sh.
# Single source of truth for what counts as complete review evidence (Constitution Rule 5).
# Canonical evidence is per-reviewer files: nazgul/reviews/<TASK-ID>/<reviewer>.md
# A consolidated summary.md is NOT evidence — it is a meta-file, excluded below.

# Meta-files in a review dir that are NOT reviewer verdicts.
# Usage: _is_review_meta_file <basename>
_is_review_meta_file() {
  case "$1" in
    test-failures.md|consolidated-feedback.md|simplify-report.md|summary.md) return 0 ;;
    *) return 1 ;;
  esac
}

# A file counts as APPROVED only when the verdict token appears on a verdict
# line ("## Verdict: APPROVED", "**Final Verdict: APPROVE**") or at the start
# of a line (e.g. "APPROVED — no blocking issues" under a Final Verdict header).
# Accepts the imperative/3rd-person forms reviewers naturally write —
# APPROVE / APPROVES / APPROVED — not just the past participle. The trailing
# word boundary keeps "approval denied" and the "approved" substring inside
# "UNAPPROVED" from matching. Prose mentions ("this pattern is approved
# elsewhere") don't count because they lack the verdict-line/line-start anchor.
# Case-insensitive.
# Usage: _has_approved_verdict <file>
_has_approved_verdict() {
  grep -qiE 'verdict[^[:alpha:]]*approve(d|s)?([^[:alpha:]]|$)' "$1" 2>/dev/null && return 0
  grep -qiE '^[[:space:]#>*`_-]*approve(d|s)?([^[:alpha:]]|$)' "$1" 2>/dev/null
}

# Validate review evidence for a task.
# Usage: validate_review_evidence <nazgul_dir> <task_id>
# Returns 0 and prints nothing if evidence is complete.
# Returns 1 and prints one machine-parseable line per problem:
#   NO_REVIEW_DIR             — reviews/<task_id>/ does not exist
#   NO_REVIEWERS_CONFIGURED   — config.json agents.reviewers is empty
#   MISSING <reviewer>        — no reviews/<task_id>/<reviewer>.md
#   UNAPPROVED <reviewer>     — file exists but lacks an APPROVED verdict
validate_review_evidence() {
  local nazgul_dir="$1" task_id="$2"
  local review_dir="$nazgul_dir/reviews/$task_id"
  local config="$nazgul_dir/config.json"
  local problems=0

  if [ ! -d "$review_dir" ]; then
    echo "NO_REVIEW_DIR"
    return 1
  fi

  local configured_reviewers=""
  if [ -f "$config" ]; then
    configured_reviewers=$(jq -r '.agents.reviewers // [] | .[]' "$config" 2>/dev/null || echo "")
  fi
  if [ -z "$configured_reviewers" ]; then
    echo "NO_REVIEWERS_CONFIGURED"
    return 1
  fi

  # Every configured reviewer must have an APPROVED file
  local reviewer
  while IFS= read -r reviewer; do
    [ -z "$reviewer" ] && continue
    if [ ! -f "$review_dir/${reviewer}.md" ]; then
      echo "MISSING $reviewer"
      problems=$((problems + 1))
    elif ! _has_approved_verdict "$review_dir/${reviewer}.md"; then
      echo "UNAPPROVED $reviewer"
      problems=$((problems + 1))
    fi
  done <<< "$configured_reviewers"

  # Any extra (non-roster, non-meta) reviewer file must also be APPROVED
  local rf base name
  for rf in "$review_dir"/*.md; do
    [ -f "$rf" ] || continue
    base=$(basename "$rf")
    if _is_review_meta_file "$base"; then
      continue
    fi
    name="${base%.md}"
    if ! grep -qxF "$name" <<< "$configured_reviewers"; then
      if ! _has_approved_verdict "$rf"; then
        echo "UNAPPROVED $name"
        problems=$((problems + 1))
      fi
    fi
  done

  [ "$problems" -eq 0 ]
}
