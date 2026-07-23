#!/usr/bin/env bash
# Nazgul shared review-evidence validation — sourced by task-state-guard.sh and stop-hook.sh.
# Single source of truth for what counts as complete review evidence (Constitution Rule 5).
# Canonical evidence is per-reviewer files: nazgul/reviews/<UNIT-ID>/<reviewer>.md,
# where <UNIT-ID> is resolve_review_unit()'s output — the task id in `task`
# granularity, GROUP-<n>/FEATURE-<feat_id> in group/feature granularity.
# A consolidated summary.md is NOT evidence — it is a meta-file, excluded below.

# Source structured-state for canonical verdict reading, review-provenance so
# every sourcer (stop-hook, task-state-guard) transitively gains
# validate_review_provenance and the dispatch-manifest reader, and task-utils
# for get_task_field (resolve_review_unit's Group/Wave fallback chain) — makes
# this file self-contained regardless of what order a caller sources its libs.
_NAZGUL_RE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_NAZGUL_RE_DIR/structured-state.sh"
# shellcheck source=/dev/null
source "$_NAZGUL_RE_DIR/review-provenance.sh"
# shellcheck source=/dev/null
source "$_NAZGUL_RE_DIR/task-utils.sh"

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

# _re_reconstruct_pretoken_text <file> [--revert-resolution] -> prints a
# reconstruction of <file>'s content suitable for hashing against TASK-002's
# receipt (LR-001 / ADR-005 Decision 4).
#
# (no flag): strips any `review_token:` line INSIDE the frontmatter block,
# everything else byte-for-byte unchanged. Undoes the ONE edit
# agents/review-gate.md Step 2 item 4 makes when persisting a reviewer's raw
# return: inserting `review_token: $TOKEN` into the frontmatter block the
# REVIEWER authored. A file with no leading frontmatter fence (legacy
# format, never had a token inserted) passes through unmodified. Only a line
# strictly inside the frontmatter region is ever dropped — a body line that
# happens to start with `review_token:` is left alone, so injected body
# content can't hide from the hash it's supposed to be part of.
#
# --revert-resolution: ADDITIONALLY and DETERMINISTICALLY undoes a disclosed
# "review-gate resolution note" edit — review-gate is documented
# (nazgul/reviews/TASK-002/{architect,code,security}-reviewer.md, the
# 2026-07-23 live board; see TASK-009 Implementation Log) to legitimately
# overwrite a resolved reviewer's `verdict:` field from CHANGES_REQUESTED to
# APPROVE during Step 3/3.6/3.75 resolution (auto-fix applied, adversarial
# cross-check refuted, confidence-threshold downgrade) — the ONLY sanctioned
# flip direction — while inserting a disclosure directly below the
# frontmatter and preserving the reviewer's findings/narrative 100%
# verbatim below THAT. Because the flip direction is fixed, the reversal is
# DETERMINISTIC, not brute-forced: this mode requires BOTH (a) the
# persisted `verdict:` is currently exactly `APPROVE`, reverted to
# `verdict: CHANGES_REQUESTED`; and (b) the canonical, marker-delimited
# note — a blank line, then a line starting EXACTLY with
# `> **review-gate resolution note:**` (the literal string every real
# instance of this note opens with; not just the phrase appearing anywhere
# in a blockquote), then the rest of that contiguous `>`-line block, then a
# blank line — collapsed back to the single blank line that separates
# frontmatter from narrative in every reviewer's own unedited return
# (verified byte-for-byte against nazgul/reviews/TASK-002/qa-reviewer.md,
# which has no note, vs. its note-bearing siblings). Returns 1 (no output)
# if --revert-resolution is requested but either condition is not met —
# callers must NEVER revert a verdict without BOTH the exact prior value
# AND a genuine, canonically-delimited note backing it (an undisclosed
# verdict flip, or a flip lacking the precise marker, is exactly the
# FEAT-016/TASK-005 fabrication shape and must never be tolerated).
_re_reconstruct_pretoken_text() {
  local file="$1" revert="false"
  [ "${2:-}" = "--revert-resolution" ] && revert="true"
  [ -f "$file" ] || return 1
  awk -v revert="$revert" '
    { lines[NR] = $0 }
    END {
      n = NR
      # Build the full candidate output into out[] first — nothing is
      # printed until we know whether --revert-resolution actually applies.
      # (A prior version printed the frontmatter incrementally as it went,
      # so a call that failed still emitted partial output before its
      # non-zero exit — violating the documented "returns 1, no output"
      # contract; caught by a test asserting the empty-output case,
      # TASK-009 Implementation Log.)
      if (n < 1 || lines[1] !~ /^---[[:space:]]*$/) {
        if (revert == "true") exit 1
        for (j = 1; j <= n; j++) print lines[j]
        exit 0
      }
      m = 0
      verdict_idx = 0
      out[++m] = lines[1]
      i = 2
      while (i <= n && lines[i] !~ /^---[[:space:]]*$/) {
        if (lines[i] !~ /^review_token[[:space:]]*:/) {
          out[++m] = lines[i]
          if (lines[i] ~ /^verdict[[:space:]]*:/) verdict_idx = m
        }
        i++
      }
      if (i <= n) { out[++m] = lines[i]; i++ }   # closing fence
      if (revert == "true") {
        # (a) current verdict must be exactly APPROVE — the only sanctioned
        # flip target — before a reversal is even meaningful.
        if (verdict_idx == 0 || out[verdict_idx] !~ /^verdict[[:space:]]*:[[:space:]]*APPROVE[[:space:]]*$/) exit 1
        # (b) canonical marker-delimited note, immediately after the blank
        # line that follows the frontmatter fence.
        if (i <= n && lines[i] == "" && (i + 1) <= n && lines[i + 1] ~ /^> \*\*review-gate resolution note:\*\*/) {
          k = i + 1
          while (k <= n && lines[k] ~ /^>/) k++
          if (k <= n && lines[k] == "") {
            out[verdict_idx] = "verdict: CHANGES_REQUESTED"
            out[++m] = ""
            for (j = k + 1; j <= n; j++) out[++m] = lines[j]
            for (j = 1; j <= m; j++) print out[j]
            exit 0
          }
        }
        exit 1
      }
      for (j = i; j <= n; j++) out[++m] = lines[j]
      for (j = 1; j <= m; j++) print out[j]
    }
  ' "$file"
}

# _re_unit_has_any_receipt <nazgul_dir> <unit> -> 0 iff
# nazgul/logs/review-receipts.jsonl has AT LEAST ONE entry for this unit
# (any reviewer). Used to distinguish "capture wasn't active for this board"
# (e.g. the board predates TASK-002, or ran in an environment where the
# SubagentStop hook never fires) from "this one reviewer's receipt was
# suppressed" — a missing receipt only counts as suspicious in the LATTER
# case (see _re_receipt_matches). A per-file existence check alone cannot
# make this distinction and would either (a) fail closed unconditionally,
# which retroactively RECEIPT_MISMATCHes every already-DONE task in every
# project that predates this feature — confirmed live: as of TASK-009,
# THIS repo's own nazgul/logs/review-receipts.jsonl does not exist anywhere
# on disk despite 6 tasks already DONE with full review boards — or
# (b) degrade to allow on any missing file, which a compromised gate could
# trivially exploit by deleting the whole receipts log. Per-unit scoping is
# the narrow middle ground: a project/board with zero captures anywhere gets
# a pass (nothing to compare against, expected and common), while a board
# where SIBLING reviewers captured normally but one specific reviewer's
# entry is conspicuously absent is exactly the targeted-suppression shape
# and still fails closed.
_re_unit_has_any_receipt() {
  local nazgul_dir="$1" unit="$2"
  local receipts_file="$nazgul_dir/logs/review-receipts.jsonl"
  [ -f "$receipts_file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local any
  any=$(jq -rs --arg u "$unit" 'any(.[]; .unit == $u)' "$receipts_file" 2>/dev/null)
  [ "$any" = "true" ]
}

# _re_receipt_matches <nazgul_dir> <unit> <reviewer> -> 0 iff
# reviews/<unit>/<reviewer>.md is consistent with the MOST RECENT
# independently-captured receipt for (unit, reviewer) in
# nazgul/logs/review-receipts.jsonl — TASK-002's SubagentStop-hook capture,
# a hook that fires outside the review-gate orchestrator's own dispatch turn
# and that a fabricated or rewritten VERDICT (the FEAT-016/TASK-005 shape)
# cannot retroactively alter, since it was already written before the gate
# persists its verdict. HONEST TIER, matching review-provenance.sh's own
# disclosure for the same limitation: this is tamper-EVIDENCE, not
# tamper-AUTHENTICATION — review-gate has ordinary Bash access to
# nazgul/logs/ and could in principle suppress or forge a receipts-file
# entry outright; nothing here cryptographically prevents that. What this
# DOES guarantee is that a receipt, once genuinely captured, cannot be
# retroactively made to match arbitrary rewritten content — a hash
# collision can't be forged (LR-001 / ADR-005 Decision 4, Option 2).
#
# Two candidate reconstructions are tried, in order:
#   1. Token-stripped, verdict AS PERSISTED (_re_reconstruct_pretoken_text,
#      no flag) — the common case: no gate-side editorial resolution at all.
#   2. ONLY when the persisted verdict is currently APPROVE and a
#      canonically-delimited resolution note is structurally present
#      (_re_reconstruct_pretoken_text --revert-resolution): the note removed
#      and the verdict DETERMINISTICALLY reverted CHANGES_REQUESTED (the
#      only sanctioned flip direction — never a brute-forced enum). Content
#      tampering is still caught unconditionally regardless of which
#      candidate is tried: candidate 2 only ever changes the verdict LINE
#      and removes the note block, never any byte of the narrative — so a
#      rewritten body still fails both. Candidate 2 is gated on both the
#      exact prior verdict AND the exact marker specifically so an
#      UNDISCLOSED verdict flip (no note, or a flip in any other direction)
#      is never tolerated — that is indistinguishable from the FEAT-016/
#      TASK-005 fabrication shape and must always be caught by candidate 1
#      failing with no candidate 2 attempted.
#
#   HONEST RESIDUAL LIMITATION (disclosed, not fixed by this mechanism): a
#   verdict flip with an intact, UNTAMPERED narrative but a FAKE resolution
#   note (a note that opens with the exact marker but describes a
#   resolution that never genuinely happened) matches candidate 2 — this is
#   hash-undetectable BY DESIGN, since content integrity is exactly what the
#   hash verifies, not the truth of a disclosure. The preserved-verbatim
#   narrative remains the auditor's signal in that case (a human or a
#   downstream process can still read the note and the findings it claims
#   to resolve); whether a given resolution claim was legitimate is a
#   policy/audit question this content-hash mechanism was never designed to
#   answer, not a gap introduced here.
#
# Both candidates read through a bash command substitution before hashing
# (`$(...)` strips trailing newlines identically to subagent-stop.sh's
# `final_text=$(jq -rs ...)` on the capture side).
#
# Returns 1 (mismatch) when: jq or a sha256 tool is unavailable (a check
# that cannot run must never be silently treated as passed); a receipt
# exists for (unit, reviewer) but neither candidate's hash matches it
# (content tampering — always checked whenever a comparable receipt
# exists, with no exception); or no receipt exists for (unit, reviewer)
# specifically WHILE the unit has at least one OTHER reviewer's receipt on
# record (_re_unit_has_any_receipt) — the targeted-suppression shape.
# Returns 0 (treated as gate-satisfying, not a mismatch) when no receipt
# exists for (unit, reviewer) AND the unit has no receipts at all — capture
# was never active for this board; see _re_unit_has_any_receipt.
_re_receipt_matches() {
  local nazgul_dir="$1" unit="$2" reviewer="$3"
  local file="$nazgul_dir/reviews/$unit/${reviewer}.md"
  local receipts_file="$nazgul_dir/logs/review-receipts.jsonl"

  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local receipt_hash=""
  if [ -f "$receipts_file" ]; then
    receipt_hash=$(jq -rs --arg u "$unit" --arg r "$reviewer" \
      '[ .[] | select(.unit == $u and .reviewer == $r) ] | last | .hash // empty' \
      "$receipts_file" 2>/dev/null)
  fi

  if [ -z "$receipt_hash" ]; then
    # No receipt for this exact (unit, reviewer). Gate-satisfying (not a
    # mismatch) only when NOTHING was captured for this unit at all.
    _re_unit_has_any_receipt "$nazgul_dir" "$unit" && return 1
    return 0
  fi

  # Candidate (i): as-persisted verdict, token stripped.
  local content recomputed
  content=$(_re_reconstruct_pretoken_text "$file") || return 1
  recomputed=$(printf '%s' "$content" | _rp_sha256) || return 1
  [ "$recomputed" = "$receipt_hash" ] && return 0

  # Candidate (ii): resolution-reverted — deterministic, single attempt.
  local reverted rev_hash
  reverted=$(_re_reconstruct_pretoken_text "$file" --revert-resolution) || return 1
  [ -n "$reverted" ] || return 1
  rev_hash=$(printf '%s' "$reverted" | _rp_sha256) || return 1
  [ "$rev_hash" = "$receipt_hash" ]
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
# read via jq; a missing OR unparseable config degrades the critical list to the
# default (fail closed), while a well-formed empty critical_reviewers list is
# honored as empty.
# Usage: _re_is_authorized_unverified <nazgul_dir> <review_dir> <reviewer>
_re_is_authorized_unverified() {
  local nazgul_dir="$1" review_dir="$2" reviewer="$3"
  local file="$review_dir/${reviewer}.md"
  [ -f "$file" ] || return 1
  [ "$(read_verdict "$file" 2>/dev/null)" = "UNVERIFIED" ] || return 1
  [ "$reviewer" = "security-reviewer" ] && return 1

  local config="$nazgul_dir/config.json" allow="true" critical="" crit_json
  if [ -f "$config" ]; then
    # `// true` would false-coalesce an explicit false back to true (jq treats
    # false like null); test the key by identity so an explicit false is honored.
    allow=$(jq -r 'if .review_gate.allow_unverified_nonblocking == false then "false" else "true" end' "$config" 2>/dev/null || echo "true")
    # Capture jq's status directly — a trailing `| tr` masks a parse error and
    # leaves critical empty (fail OPEN). Parse error ⇒ default list; valid [] stays empty.
    if crit_json=$(jq -r '.review_gate.critical_reviewers // ["security-reviewer","architect-reviewer"] | .[]' "$config" 2>/dev/null); then
      critical="${crit_json//$'\n'/ }"
    else
      critical="security-reviewer architect-reviewer"
    fi
  else
    critical="security-reviewer architect-reviewer"
  fi
  critical="${critical% }"

  [ "$allow" = "false" ] && return 1
  _in_list "$reviewer" "$critical" && return 1
  return 0
}

# Resolve which nazgul/reviews/ subdirectory holds a task's review evidence,
# aware of review_gate.granularity (MF-013, ADR-004 Decision 1). This is the
# ONE shared derivation every evidence/dispatch-readiness call site must use —
# do not add a second independent re-derivation anywhere (stop-hook.sh's
# AGGREGATE_REVIEW_READY block and subagent-stop.sh's coverage recorder both
# call this instead of computing their own answer).
#
# Usage: resolve_review_unit <nazgul_dir> <task_id>
# Prints one of:
#   <task_id>            — granularity is "task" (default), or an absent/
#                           unreadable config, or a missing task manifest —
#                           the safe, zero-behavior-change fallback.
#   GROUP-<n>             — granularity "group": the task manifest's Group
#                           field, falling back to Wave, falling back to "1" —
#                           the IDENTICAL fallback chain stop-hook.sh's
#                           AGGREGATE_REVIEW_READY block already uses.
#   FEATURE-<feat_id>     — granularity "feature": config.json's top-level
#                           feat_id.
# Degrades to <task_id> on any ambiguity (missing task file, unreadable/absent
# config, empty/null feat_id) — never fails open on a genuine evidence check;
# it just falls back to the one mode where task_id IS the review unit.
resolve_review_unit() {
  local nazgul_dir="$1" task_id="$2"
  local config="$nazgul_dir/config.json"
  local task_file="$nazgul_dir/tasks/${task_id}.md"
  local granularity="task"

  if [ -f "$config" ]; then
    granularity=$(jq -r '.review_gate.granularity // "task"' "$config" 2>/dev/null)
  fi
  case "$granularity" in
    task|group|feature) ;;
    *) granularity="task" ;;
  esac

  case "$granularity" in
    group)
      if [ ! -f "$task_file" ]; then
        echo "$task_id"
        return 0
      fi
      local group
      group=$(get_task_field "$task_file" "Group" "$(get_task_field "$task_file" "Wave" "1")")
      echo "GROUP-${group}"
      ;;
    feature)
      local feat_id=""
      if [ -f "$config" ]; then
        feat_id=$(jq -r '.feat_id // empty' "$config" 2>/dev/null)
      fi
      if [ -z "$feat_id" ]; then
        echo "$task_id"
        return 0
      fi
      echo "FEATURE-${feat_id}"
      ;;
    *)
      echo "$task_id"
      ;;
  esac
}

# Validate review evidence for a task.
# Usage: validate_review_evidence <nazgul_dir> <task_id>
# Returns 0 and prints nothing if evidence is complete.
# Returns 1 and prints one machine-parseable line per problem:
#   NO_REVIEW_DIR             — reviews/<unit>/ does not exist
#   NO_REVIEWERS_CONFIGURED   — config.json agents.reviewers is empty
#   MISSING <reviewer>        — no reviews/<unit>/<reviewer>.md
#   UNAPPROVED <reviewer>     — file exists but lacks an APPROVED verdict
#   RECEIPT_MISMATCH <reviewer> — review_gate.receipt_hash_enforcement is not
#                             `false` (default true) and a dispatched
#                             reviewer's persisted APPROVE/CHANGES_REQUESTED
#                             verdict fails _re_receipt_matches against
#                             nazgul/logs/review-receipts.jsonl: content (the
#                             narrative/findings) never matches, but a
#                             DISCLOSED verdict-only resolution (a
#                             structurally-recognized "review-gate resolution
#                             note" — see _re_reconstruct_pretoken_text
#                             --strip-note) is tolerated, since review-gate is
#                             documented to legitimately flip ONLY the
#                             verdict field during Step 3/3.6/3.75
#                             resolution. A missing receipt is flagged only
#                             when the unit has at least one OTHER reviewer's
#                             receipt on record (_re_unit_has_any_receipt) —
#                             a unit with zero captures anywhere (predates
#                             TASK-002, or ran where the capture hook never
#                             fires) is never flagged for that reason alone.
#                             Never emitted for SKIPPED/UNVERIFIED files
#                             (orchestrator-authored stubs, never
#                             independently captured) or when the kill
#                             switch is `false`.
# <unit> is resolve_review_unit(nazgul_dir, task_id): task_id unchanged in
# "task" granularity (the common case), or the task's GROUP-<n>/FEATURE-<feat_id>
# in "group"/"feature" granularity (MF-013) — the single resolution point every
# caller (task-state-guard.sh, stop-hook.sh) inherits with no call-site change.
# A reviewer authorized-skipped via the dispatch manifest (see
# _re_is_authorized_skipped) is exempt from both MISSING and UNAPPROVED. A
# non-critical reviewer whose file reads verdict: UNVERIFIED with the
# allow_unverified_nonblocking toggle on (see _re_is_authorized_unverified) is
# likewise exempt from UNAPPROVED; a critical reviewer's UNVERIFIED still blocks.
validate_review_evidence() {
  local nazgul_dir="$1" task_id="$2"
  local unit
  unit=$(resolve_review_unit "$nazgul_dir" "$task_id")
  local review_dir="$nazgul_dir/reviews/$unit"
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

  # ADR-005 Decision 4 / LR-001: receipt-hash content gate kill switch. Read
  # by identity, not `//` — `//` treats jq's `false` like `null`, which would
  # silently coalesce an explicit `false` back to `true`.
  local receipt_enforced="true"
  if [ -f "$config" ]; then
    receipt_enforced=$(jq -r 'if .review_gate.receipt_hash_enforcement == false then "false" else "true" end' "$config" 2>/dev/null || echo "true")
  fi

  # Every configured reviewer must have an APPROVED file
  local reviewer
  while IFS= read -r reviewer; do
    [ -z "$reviewer" ] && continue
    local rf="$review_dir/${reviewer}.md"
    if [ ! -f "$rf" ]; then
      _re_is_authorized_skipped "$nazgul_dir" "$review_dir" "$reviewer" && continue
      echo "MISSING $reviewer"
      problems=$((problems + 1))
      continue
    fi
    if ! _has_approved_verdict "$rf"; then
      _re_is_authorized_skipped "$nazgul_dir" "$review_dir" "$reviewer" && continue
      _re_is_authorized_unverified "$nazgul_dir" "$review_dir" "$reviewer" && continue
      echo "UNAPPROVED $reviewer"
      problems=$((problems + 1))
    fi
    # Receipt-hash check: only for a verdict that came from an actual
    # dispatched-reviewer return (APPROVE/APPROVED/CHANGES_REQUESTED).
    # SKIPPED/UNVERIFIED stubs are orchestrator-authored, never captured by
    # TASK-002's SubagentStop hook, and are already exempted above via
    # `continue` (authorized-skipped/authorized-unverified) or otherwise
    # never match this case — so they never need or get a receipt.
    if [ "$receipt_enforced" = "true" ]; then
      case "$(read_verdict "$rf" 2>/dev/null)" in
        APPROVE|APPROVED|CHANGES_REQUESTED)
          if ! _re_receipt_matches "$nazgul_dir" "$unit" "$reviewer"; then
            echo "RECEIPT_MISMATCH $reviewer"
            problems=$((problems + 1))
          fi
          ;;
      esac
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
