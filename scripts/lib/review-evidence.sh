#!/usr/bin/env bash
# Nazgul shared review-evidence validation — sourced by task-state-guard.sh and stop-hook.sh.
# Single source of truth for what counts as complete review evidence (Constitution Rule 5).
# Canonical evidence is per-reviewer files: nazgul/reviews/<TASK-ID>/<reviewer>.md
# A consolidated summary.md is NOT evidence — it is a meta-file, excluded below.

# Source structured-state for canonical verdict reading, and review-provenance
# so every sourcer (stop-hook, task-state-guard) transitively gains
# validate_review_provenance and the dispatch-manifest reader.
_NAZGUL_RE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_NAZGUL_RE_DIR/structured-state.sh"
# shellcheck source=/dev/null
source "$_NAZGUL_RE_DIR/review-provenance.sh"

# Meta-files in a review dir that are NOT reviewer verdicts.
# Usage: _is_review_meta_file <basename>
_is_review_meta_file() {
  case "$1" in
    test-failures.md|consolidated-feedback.md|simplify-report.md|summary.md) return 0 ;;
    *) return 1 ;;
  esac
}

# A file counts as APPROVED via the canonical structured verdict block first:
# a leading YAML frontmatter `verdict: APPROVE` reads deterministically as
# approved; `verdict: CHANGES_REQUESTED` as not approved; a malformed/off-enum
# `verdict:` value fails LOUDLY (not approved) rather than being silently
# mis-read. Files with NO frontmatter fall back to the legacy regex so in-flight
# and historical reviews keep working: the token must appear on a verdict line
# ("## Verdict: APPROVED", "**Final Verdict: APPROVED**") or at the start of a
# line (e.g. "APPROVED — no blocking issues" under a Final Verdict header).
# Accepts the imperative/3rd-person forms reviewers naturally write —
# APPROVE / APPROVES / APPROVED — not just the past participle. The trailing
# word boundary keeps "approval denied" and the "approved" substring inside
# "UNAPPROVED" from matching. Prose mentions ("this pattern is approved
# elsewhere") don't count because they lack the verdict-line/line-start anchor.
# Case-insensitive. VERDICT-ONLY: confidence is handled by the review-gate agent.
# Usage: _has_approved_verdict <file>
_has_approved_verdict() {
  local file="$1" v rc
  v=$(read_verdict "$file") && rc=0 || rc=$?   # capture rc without tripping set -e
  if [ "$rc" -eq 0 ]; then
    [ "$v" = "APPROVE" ] && return 0
    return 1   # CHANGES_REQUESTED / SKIPPED / UNVERIFIED — any non-APPROVE verdict is not approved
  fi
  if [ "$rc" -eq 2 ]; then
    return 1   # INVALID block — fail loud (not approved)
  fi
  # rc==1 (NONE): legacy regex fallback for files with no frontmatter
  grep -qiE 'verdict[^[:alpha:]]*approve(d|s)?([^[:alpha:]]|$)' "$file" 2>/dev/null && return 0
  grep -qiE '^[[:space:]#>*`_-]*approve(d|s)?([^[:alpha:]]|$)' "$file" 2>/dev/null
}

# _re_diff_files <diff_path> -> one changed path per line (from `diff --git
# a/X b/X` header lines; both the a/ and b/ side, covering renames). Prints
# nothing if the file is missing or has no such headers.
_re_diff_files() {
  local diff_path="$1"
  [ -f "$diff_path" ] || return 0
  awk '
    /^diff --git a\// {
      line = $0
      sub(/^diff --git a\//, "", line)
      idx = index(line, " b/")
      if (idx > 0) {
        print substr(line, 1, idx - 1)
        print substr(line, idx + 3)
      }
    }
  ' "$diff_path" | sort -u
}

# HONEST TIER: recomputation binds a skip claim to the diff and the configured
# selection policy on disk, not to who wrote the manifest — a determined actor
# with shell access could still reconstruct a diff that legitimately reproduces
# a given skip. Its value is closing the CHEAP forge (naming a reviewer in
# skipped[] with no diff to back it up), not authenticating the writer.
#
# _re_manifest_authentic <nazgul_dir> <review_dir> -> 0 iff review_dir's
# .dispatch.json skipped[] name-set is reproducible by re-running the
# deterministic selector against the unit's CURRENT diff.patch. When
# review_gate.conditional_dispatch is not `true`, no skip is ever legitimate,
# so this requires skipped[] to be empty. Assumes the manifest exists.
_re_manifest_authentic() {
  local nazgul_dir="$1" review_dir="$2"
  local manifest="$review_dir/.dispatch.json"

  local claimed
  claimed=$(jq -r '.skipped[]?.name // empty' "$manifest" 2>/dev/null | tr '\n' ' ')
  claimed="${claimed% }"

  local config="$nazgul_dir/config.json" conditional="false"
  [ -f "$config" ] && conditional=$(jq -r '.review_gate.conditional_dispatch // false' "$config" 2>/dev/null)
  if [ "$conditional" != "true" ]; then
    [ -z "$claimed" ]
    return $?
  fi

  local roster=""
  [ -f "$config" ] && roster=$(jq -r '.agents.reviewers // [] | .[]' "$config" 2>/dev/null | tr '\n' ' ')
  roster="${roster% }"

  local files=""
  files=$(_re_diff_files "$review_dir/diff.patch" | tr '\n' ' ')
  files="${files% }"

  local rs="$_NAZGUL_RE_DIR/reviewer-selection.sh"
  [ -f "$rs" ] || return 1
  bash "$rs" verify --files "$files" --reviewers "$roster" --claimed-skipped "$claimed"
}

# A reviewer counts as authorized-skipped (gate-satisfying despite no APPROVED
# verdict) when reviews/<unit>/.dispatch.json exists, lists it in skipped[],
# AND that skip is reproducible from the current diff (_re_manifest_authentic
# — trust by reproduction, not by origin; see its header for the honest-tier
# caveat). security-reviewer is never honored here, even if listed (defense
# in depth — the selector must never skip it, but the gate also refuses to
# trust it). With no manifest present this always fails, preserving the
# legacy contract.
# Usage: _re_is_authorized_skipped <nazgul_dir> <review_dir> <reviewer>
_re_is_authorized_skipped() {
  local nazgul_dir="$1" review_dir="$2" reviewer="$3"
  local manifest="$review_dir/.dispatch.json"
  [ -f "$manifest" ] || return 1
  [ "$reviewer" = "security-reviewer" ] && return 1
  jq -r '.skipped[]?.name // empty' "$manifest" 2>/dev/null | grep -qxF "$reviewer" || return 1
  _re_manifest_authentic "$nazgul_dir" "$review_dir"
}

# A reviewer counts as authorized-unverified (gate-satisfying despite no APPROVED
# verdict) when its file reads verdict: UNVERIFIED — meaning it could not assess,
# distinct from CHANGES_REQUESTED — AND UNVERIFIED is honored non-blocking for
# this reviewer. It is honored ONLY for a non-critical reviewer:
# review_gate.allow_unverified_nonblocking must not be false (default true when
# absent), and the reviewer must not be in review_gate.critical_reviewers
# (default ["security-reviewer","architect-reviewer"] when absent). A critical
# reviewer's terminal UNVERIFIED fails closed. security-reviewer is never honored
# here regardless of the configured critical list (defense in depth). Config is
# read via jq; a missing config degrades to the defaults.
# Usage: _re_is_authorized_unverified <nazgul_dir> <review_dir> <reviewer>
_re_is_authorized_unverified() {
  local nazgul_dir="$1" review_dir="$2" reviewer="$3"
  local file="$review_dir/${reviewer}.md"
  [ -f "$file" ] || return 1
  [ "$(read_verdict "$file" 2>/dev/null)" = "UNVERIFIED" ] || return 1
  [ "$reviewer" = "security-reviewer" ] && return 1

  local config="$nazgul_dir/config.json" allow="true" critical=""
  if [ -f "$config" ]; then
    # `// true` would false-coalesce an explicit false back to true (jq treats
    # false like null); test the key by identity so an explicit false is honored.
    allow=$(jq -r 'if .review_gate.allow_unverified_nonblocking == false then "false" else "true" end' "$config" 2>/dev/null || echo "true")
    critical=$(jq -r '.review_gate.critical_reviewers // ["security-reviewer","architect-reviewer"] | .[]' "$config" 2>/dev/null | tr '\n' ' ')
  else
    critical="security-reviewer architect-reviewer"
  fi
  critical="${critical% }"

  [ "$allow" = "false" ] && return 1
  _in_list "$reviewer" "$critical" && return 1
  return 0
}

# Validate review evidence for a task.
# Usage: validate_review_evidence <nazgul_dir> <task_id>
# Returns 0 and prints nothing if evidence is complete.
# Returns 1 and prints one machine-parseable line per problem:
#   NO_REVIEW_DIR             — reviews/<task_id>/ does not exist
#   NO_REVIEWERS_CONFIGURED   — config.json agents.reviewers is empty
#   MISSING <reviewer>        — no reviews/<task_id>/<reviewer>.md
#   UNAPPROVED <reviewer>     — file exists but lacks an APPROVED verdict
# A reviewer authorized-skipped via the dispatch manifest (see
# _re_is_authorized_skipped) is exempt from both MISSING and UNAPPROVED. A
# non-critical reviewer whose file reads verdict: UNVERIFIED with the
# allow_unverified_nonblocking toggle on (see _re_is_authorized_unverified) is
# likewise exempt from UNAPPROVED; a critical reviewer's UNVERIFIED still blocks.
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
      _re_is_authorized_skipped "$nazgul_dir" "$review_dir" "$reviewer" && continue
      echo "MISSING $reviewer"
      problems=$((problems + 1))
    elif ! _has_approved_verdict "$review_dir/${reviewer}.md"; then
      _re_is_authorized_skipped "$nazgul_dir" "$review_dir" "$reviewer" && continue
      _re_is_authorized_unverified "$nazgul_dir" "$review_dir" "$reviewer" && continue
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
        _re_is_authorized_unverified "$nazgul_dir" "$review_dir" "$name" && continue
        echo "UNAPPROVED $name"
        problems=$((problems + 1))
      fi
    fi
  done

  [ "$problems" -eq 0 ]
}
