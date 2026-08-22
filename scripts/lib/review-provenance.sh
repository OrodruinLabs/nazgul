#!/usr/bin/env bash
# Nazgul review-provenance — UNIFIED dispatch manifest, sourced by review-gate
# tooling and the stop-hook DONE gate. Defines ONE schema shared by Gap A
# (attestation) and Gap C (reviewer selection):
#
#   nazgul/reviews/<unit_id>/.dispatch.json
#   {
#     unit, feat_id, iteration, nonce, diff_hash, token, created_at,
#     reviewers: [{name, resolved}],   # full roster considered for dispatch
#     selected:  [name, ...],          # roster actually dispatched
#     skipped:   [{name, reason}, ...] # roster authorized-skipped, with why
#   }
#
# HONEST TIER: this is tamper-EVIDENCE + diff-staleness detection, NOT
# authentication. The stop-hook verifier and the orchestrator share the same
# filesystem, and the token derivation below is public — a determined actor
# with shell access could forge one. Its value is catching the common
# ACCIDENTAL cases: a completion that never ran the review-gate code path
# (no manifest), or a review left stale after the diff changed underneath it.
#
# Idempotent source guard mirrors structured-state.sh. No top-level side
# effects. NOT `set -euo pipefail` — this file is SOURCED into hook shells
# (task-state-guard.sh, stop-hook.sh) and must not alter their options.

[ -n "${_NAZGUL_REVIEW_PROVENANCE_SOURCED:-}" ] && return 0
_NAZGUL_REVIEW_PROVENANCE_SOURCED=1

_NAZGUL_RP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_NAZGUL_RP_DIR/structured-state.sh"
# shellcheck source=/dev/null
source "$_NAZGUL_RP_DIR/review-file-class.sh"

_rp_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

_rp_nonce() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# compute_review_token <nonce> <diff_hash> <unit_id> -> prints the first 16
# hex chars of sha256(nonce \0 diff_hash \0 unit_id); 0 on success. Degrades
# to allow (prints nothing, returns 1) if no sha256 tool is available.
compute_review_token() {
  local nonce="$1" diff_hash="$2" unit_id="$3" full
  full=$(printf '%s\0%s\0%s' "$nonce" "$diff_hash" "$unit_id" | _rp_sha256) || return 1
  [ -n "$full" ] || return 1
  printf '%s\n' "${full:0:16}"
}

# write_dispatch_manifest <nazgul_dir> <unit_id> <diff_path> <feat_id> <iteration>
#   [--selected "<space-list>"] [--skipped "<name:reason;...>"] [--] <reviewer...>
# Writes nazgul/reviews/<unit_id>/.dispatch.json (see header for schema) and
# prints the derived token on success. `selected` defaults to the full
# roster, `skipped` to []. Returns 1 (no output, no file written) if no
# sha256 tool is available.
write_dispatch_manifest() {
  local nazgul_dir="$1" unit_id="$2" diff_path="$3" feat_id="$4" iteration="$5"
  shift 5

  local selected_raw="" skipped_raw=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --selected) selected_raw="$2"; shift 2 ;;
      --skipped)  skipped_raw="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local roster=("$@")

  local project_root review_dir
  project_root="$(dirname "$nazgul_dir")"
  review_dir="$nazgul_dir/reviews/$unit_id"
  mkdir -p "$review_dir" || return 1

  local nonce; nonce=$(_rp_nonce) || return 1

  local diff_hash
  if [ -n "$diff_path" ] && [ -f "$diff_path" ]; then
    diff_hash=$(_rp_sha256 < "$diff_path") || return 1
  else
    diff_hash=$(printf '' | _rp_sha256) || return 1
  fi

  local token; token=$(compute_review_token "$nonce" "$diff_hash" "$unit_id") || return 1

  local selected_list=()
  if [ -n "$selected_raw" ]; then
    read -ra selected_list <<< "$selected_raw"
  else
    selected_list=(${roster[@]+"${roster[@]}"})
  fi

  local reviewer_objs=() name resolved
  for name in ${roster[@]+"${roster[@]}"}; do
    resolved="false"
    [ -f "$project_root/.claude/agents/generated/${name}.md" ] && resolved="true"
    reviewer_objs+=("$(jq -n --arg n "$name" --argjson r "$resolved" '{name:$n, resolved:$r}')")
  done
  local reviewers_json="[]"
  [ "${#reviewer_objs[@]}" -gt 0 ] && reviewers_json=$(printf '%s\n' "${reviewer_objs[@]}" | jq -s '.')

  local selected_json="[]"
  [ "${#selected_list[@]}" -gt 0 ] && selected_json=$(printf '%s\n' "${selected_list[@]}" | jq -R . | jq -s .)

  local skipped_json="[]"
  if [ -n "$skipped_raw" ]; then
    local entries=() entry sname sreason skip_objs=()
    IFS=';' read -ra entries <<< "$skipped_raw"
    for entry in ${entries[@]+"${entries[@]}"}; do
      [ -z "$entry" ] && continue
      sname="${entry%%:*}"
      sreason="${entry#*:}"
      skip_objs+=("$(jq -n --arg n "$sname" --arg r "$sreason" '{name:$n, reason:$r}')")
    done
    [ "${#skip_objs[@]}" -gt 0 ] && skipped_json=$(printf '%s\n' "${skip_objs[@]}" | jq -s '.')
  fi

  local created_at; created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local manifest="$review_dir/.dispatch.json"
  local tmp; tmp=$(mktemp) || return 1
  if ! jq -n \
    --arg unit "$unit_id" \
    --arg feat_id "$feat_id" \
    --arg iteration "$iteration" \
    --arg nonce "$nonce" \
    --arg diff_hash "$diff_hash" \
    --arg token "$token" \
    --arg created_at "$created_at" \
    --argjson reviewers "$reviewers_json" \
    --argjson selected "$selected_json" \
    --argjson skipped "$skipped_json" \
    '{
      unit: $unit,
      feat_id: $feat_id,
      iteration: ($iteration | tonumber? // $iteration),
      nonce: $nonce,
      diff_hash: $diff_hash,
      token: $token,
      created_at: $created_at,
      reviewers: $reviewers,
      selected: $selected,
      skipped: $skipped
    }' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$manifest" || return 1

  printf '%s\n' "$token"
}

# lean-comments: allow-run — the closed problem vocabulary this function's callers parse.
# validate_review_provenance <nazgul_dir> <unit_id> -> 0 silently if valid;
# else 1 with one machine-parseable line per problem:
#   NO_DISPATCH_MANIFEST  — subject files present, no .dispatch.json
#   TOKEN_MISMATCH <name> — subject file's review_token != manifest token
#   TOKEN_MISSING <name>  — subject file present, carries no review_token
#   DIFF_HASH_STALE       — diff.patch hash != manifest diff_hash
#   NOTHING_CHECKED       — a board WAS dispatched for this unit and the classifier read
#                           none of the dir's .md files as a subject (K>0 floor, RULES §15)
#   COVERAGE_ACCOUNTING_DEFECT — the subject-file pass's N == M + K identity broke
# Degrades to allow: no subject files yet, or a legacy review (no manifest and
# no subject file carries any review_token:). Reviewers listed in the manifest's
# skipped[] are exempt from TOKEN_MISSING/TOKEN_MISMATCH.
validate_review_provenance() {
  local nazgul_dir="$1" unit_id="$2"
  local review_dir="$nazgul_dir/reviews/$unit_id"
  local manifest="$review_dir/.dispatch.json"

  [ -d "$review_dir" ] || return 0

  # lean-comments: allow-run — this is the widening that could make a tamper-evidence gate
  # permissive, so its boundary is stated where it is applied. A subject is whatever
  # review_classify_unit_file (review-file-class.sh) calls a verdict, and NOT ONE NAME MORE:
  # the same classifier decides which files review-evidence.sh reads as approvals, so the set
  # whose token must match is exactly the set that can approve a task. A `superseded` archive
  # or a `non-seat` board document cannot grant approval, so demanding a token from it only
  # blocks honest work; a `seat`/`extra-seat` file still must carry the dispatch token, which
  # is what catches a planted or stale verdict. When no roster can be read there is no seat
  # vocabulary to narrow BY, and the classifier answers `unnarrowed` — checked, never skipped,
  # because a derivation that fails must widen what is examined, never what is ignored.
  local config="$nazgul_dir/config.json" configured_reviewers="" seat_suffixes=""
  [ -f "$config" ] && configured_reviewers=$(jq -r '.agents.reviewers // [] | .[]' "$config" 2>/dev/null || echo "")
  seat_suffixes=$(_re_seat_suffixes "$configured_reviewers")

  local subject_files=() rf base klass
  local scanned=0 skip_artifact=0 skip_nonseat=0 skip_superseded=0
  for rf in "$review_dir"/*.md; do
    [ -f "$rf" ] || continue
    scanned=$((scanned + 1))
    base=$(basename "$rf")
    klass=$(review_classify_unit_file "$base" "$configured_reviewers" "$review_dir" "$seat_suffixes")
    case "$klass" in
      artifact)   skip_artifact=$((skip_artifact + 1)); continue ;;
      non-seat)   skip_nonseat=$((skip_nonseat + 1)); continue ;;
      superseded) skip_superseded=$((skip_superseded + 1)); continue ;;
    esac
    subject_files+=("$rf")
  done

  local checked=${#subject_files[@]}
  local skipped=$((skip_artifact + skip_nonseat + skip_superseded))
  local problems=0

  if [ "$checked" -gt 0 ] && [ ! -f "$manifest" ]; then
    local rf2 has_any_token=0
    for rf2 in "${subject_files[@]}"; do
      if read_frontmatter_field "$rf2" review_token >/dev/null 2>&1; then
        has_any_token=1
        break
      fi
    done
    if [ "$has_any_token" -eq 1 ]; then
      echo "NO_DISPATCH_MANIFEST"
      problems=$((problems + 1))
    fi
  elif [ "$checked" -gt 0 ]; then
    local manifest_token skipped_names
    manifest_token=$(jq -r '.token // empty' "$manifest" 2>/dev/null)
    skipped_names=$(jq -r '.skipped[]?.name // empty' "$manifest" 2>/dev/null)

    local name file_token rf3
    for rf3 in "${subject_files[@]}"; do
      name=$(basename "$rf3" .md)
      if grep -qxF "$name" <<< "$skipped_names"; then
        continue
      fi
      if file_token=$(read_frontmatter_field "$rf3" review_token); then
        if [ "$file_token" != "$manifest_token" ]; then
          echo "TOKEN_MISMATCH $name"
          problems=$((problems + 1))
        fi
      else
        echo "TOKEN_MISSING $name"
        problems=$((problems + 1))
      fi
    done

    local manifest_diff_hash diff_path current_hash
    manifest_diff_hash=$(jq -r '.diff_hash // empty' "$manifest" 2>/dev/null)
    diff_path="$review_dir/diff.patch"
    if [ -n "$manifest_diff_hash" ]; then
      if [ -f "$diff_path" ]; then
        current_hash=$(_rp_sha256 < "$diff_path") || current_hash=""
      else
        current_hash=$(printf '' | _rp_sha256) || current_hash=""
      fi
      if [ -n "$current_hash" ] && [ "$current_hash" != "$manifest_diff_hash" ]; then
        echo "DIFF_HASH_STALE"
        problems=$((problems + 1))
      fi
    fi
  elif [ "$scanned" -gt 0 ] && [ -f "$manifest" ]; then
    # lean-comments: allow-run — the K>0 floor, and the one place this gate's ambiguous case
    # is decided rather than inherited (RULES.md §15). "Candidates present, none read" is two
    # different states, and .dispatch.json is what tells them apart: WITHOUT a manifest no
    # board was ever dispatched here, so an all-paperwork dir is the ordinary pre-review state
    # this validator has always allowed; WITH one, a board ran and yet not one file reads as a
    # verdict — the exact shape of a classifier that stopped matching, which must never be
    # reported as a clean review directory. So the floor blocks only in the second state.
    echo "NOTHING_CHECKED"
    problems=$((problems + 1))
  fi

  if [ "$scanned" -ne $((skipped + checked)) ]; then
    echo "COVERAGE_ACCOUNTING_DEFECT"
    problems=$((problems + 1))
  fi

  local floor_note=""
  if [ "$scanned" -gt 0 ] && [ "$checked" -eq 0 ]; then
    if [ -f "$manifest" ]; then
      floor_note="NOTHING CHECKED — all ${scanned} candidate(s) skipped after a board was dispatched"
    else
      floor_note="nothing to check — all ${scanned} candidate(s) skipped, no dispatch manifest (pre-review)"
    fi
  fi
  review_emit_class_coverage "review-provenance/subject-files" \
    "$scanned" "$skip_artifact" "$skip_nonseat" "$skip_superseded" "$checked" "$problems" \
    "$unit_id" "$seat_suffixes" "$floor_note"

  [ "$problems" -eq 0 ]
}
