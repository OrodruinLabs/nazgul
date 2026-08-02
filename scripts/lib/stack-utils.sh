#!/usr/bin/env bash
# Nazgul stack-utils — the SOLE writer of `stack.layers[]` (FEAT-027) and the
# only home of `gh stack` invocation. GitHub owns retarget/rebase mechanics
# (gh-stack CLI extension); Nazgul owns only the registry and policy gates.
# Every empirical finding below is binding per nazgul/docs/ADR-018-gh-stack-primitive.md
# (TASK-001) — this wrapper must not infer tool state from a `gh stack`
# subcommand's own exit code where the ADR found that ambiguous.
#
# gh-stack exit-code contract (vendor README + ADR-018 empirical findings):
#   0 success | 1 generic error | 2 not in a stack / stack not found |
#   3 rebase conflict (ALSO reused for stale-local-tracking after `link` —
#     disambiguate by stderr text, never by code alone) | 4 GitHub API failure |
#   5 invalid args/flags | 6 disambiguation required | 7 rebase in progress |
#   8 stack locked by another process | 9 UNDOCUMENTED — observed on `submit`
#     during an auth failure, misreported as "stacked PRs not enabled".
#
# Idempotent source guard; NOT `set -euo pipefail` (sourced into caller shells
# that own their own shell options).

[ -n "${_NAZGUL_STACK_UTILS_SOURCED:-}" ] && return 0
_NAZGUL_STACK_UTILS_SOURCED=1

_SU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./nazgul-root.sh
source "$_SU_DIR/nazgul-root.sh"
# shellcheck source=./emit-event.sh
source "$_SU_DIR/emit-event.sh"

# stack_available <config> -> prints one of "disabled" / "ready" / "missing"
# to stdout (exit 1/0/2 respectively). THREE-STATE per RULES §15: "disabled"
# means execution.stacking.enabled is not true; "missing" means enabled but
# the tooling isn't usable (gh absent, gh-stack extension not installed, or
# gh not authed) — callers fail CLOSED on "missing", never silently degrade.
# Per ADR-018 binding adjustment #1: presence is checked via `gh extension
# list` text, NEVER by invoking `gh stack` itself — an absent extension makes
# `gh stack <anything>` fail with generic gh CLI routing noise
# (`unknown command "stack" for "gh"`, exit 1) indistinguishable from a typo.
stack_available() {
  local config="$1" enabled
  [ -f "$config" ] || { printf 'disabled\n'; return 1; }
  enabled=$(jq -r 'if (.execution.stacking.enabled == true) then "true" else "false" end' "$config" 2>/dev/null) || enabled="false"
  if [ "$enabled" != "true" ]; then
    printf 'disabled\n'
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'missing\n'
    return 2
  fi
  if ! gh extension list 2>/dev/null | grep -q "github/gh-stack"; then
    printf 'missing\n'
    return 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'missing\n'
    return 2
  fi
  printf 'ready\n'
  return 0
}

# stack_tip <config> -> branch of the newest `state:"open"` layer in
# `stack.layers[]` (by `opened_at`), else `branch.base` (default "main").
stack_tip() {
  local config="$1" base tip
  base=$(jq -r '.branch.base // "main"' "$config" 2>/dev/null) || base="main"
  [ -f "$config" ] || { printf '%s\n' "$base"; return 0; }
  tip=$(jq -r '[.stack.layers[]? | select(.state == "open")] | sort_by(.opened_at) | last | .branch // empty' "$config" 2>/dev/null)
  if [ -n "$tip" ] && [ "$tip" != "null" ]; then
    printf '%s\n' "$tip"
  else
    printf '%s\n' "$base"
  fi
}

# stack_unmerged_count <config> -> count of `state:"open"` layers.
stack_unmerged_count() {
  local config="$1"
  [ -f "$config" ] || { printf '0\n'; return 0; }
  jq -r '[.stack.layers[]? | select(.state == "open")] | length' "$config" 2>/dev/null || printf '0\n'
}

# stack_register_layer <config> <feat_id> <branch> <base> [pr] -> upsert a
# `stack.layers[]` entry {feat_id, branch, pr, base, state:"open",
# opened_at, merged_at:null}, atomic tmp+mv write. Idempotent per feat_id: a
# repeat call updates branch/base/pr in place (preserving opened_at) rather
# than appending a duplicate. pr defaults to null when omitted/empty, and an
# existing pr is preserved on update unless a non-empty one is supplied.
stack_register_layer() {
  local config="$1" feat_id="$2" branch="$3" base="$4" pr="${5:-}" tmp exists
  [ -f "$config" ] || return 1
  [ -n "$feat_id" ] && [ -n "$branch" ] || return 1
  exists=$(jq -r --arg f "$feat_id" '[.stack.layers[]? | select(.feat_id == $f)] | length' "$config" 2>/dev/null) || exists=0
  tmp="${config}.tmp.$$"
  if [ "${exists:-0}" -gt 0 ]; then
    jq --arg f "$feat_id" --arg br "$branch" --arg b "$base" --arg pr "$pr" '
      .stack.layers = (.stack.layers | map(
        if .feat_id == $f then
          .branch = $br | .base = $b | .state = "open" | .merged_at = null
          | .pr = (if ($pr | length) > 0 then $pr else .pr end)
        else . end
      ))
    ' "$config" > "$tmp" 2>/dev/null && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
  else
    jq --arg f "$feat_id" --arg br "$branch" --arg b "$base" --arg pr "$pr" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
      .stack = ((if (.stack | type) == "object" then .stack else {} end)
        | .layers = ((.layers // []) + [{
            feat_id: $f, branch: $br,
            pr: (if ($pr | length) > 0 then $pr else null end),
            base: $b, state: "open", opened_at: $ts, merged_at: null
          }]))
    ' "$config" > "$tmp" 2>/dev/null && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
  fi
}

# _su_write_history <config> <feat_id> <pr_url> -> set the `.pr` field of the
# matching `objectives_history[]` entry (already appended at objective
# creation, per skills/start/SKILL.md's Objective Identity rule). No-op when
# either arg is empty; atomic tmp+mv write.
_su_write_history() {
  local config="$1" feat_id="$2" pr_url="$3" tmp
  [ -n "$feat_id" ] && [ -n "$pr_url" ] || return 0
  tmp="${config}.tmp.$$"
  jq --arg f "$feat_id" --arg pr "$pr_url" '
    .objectives_history = ((.objectives_history // []) | map(
      if .feat_id == $f then .pr = $pr else . end
    ))
  ' "$config" > "$tmp" 2>/dev/null && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

# _su_push_branch <project_root> <branch> -> `git push -u origin <branch>`,
# non-interactive; stderr surfaced on failure.
_su_push_branch() {
  local project_root="$1" branch="$2" out rc
  out=$(git -C "$project_root" push -u origin "$branch" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    printf 'stack-utils: push of %s to origin failed: %s\n' "$branch" "$out" >&2
    return 1
  fi
  return 0
}

# _su_plain_pr <base> <branch> <title> <body> -> today's behavior, mechanized:
# `gh pr create` against the recorded base, non-interactive (all flags
# explicit). Prints the created PR URL.
_su_plain_pr() {
  local base="$1" branch="$2" title="$3" body="$4" out rc
  out=$(gh pr create --base "$base" --head "$branch" --title "$title" --body "$body" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    printf 'stack-utils: gh pr create failed for %s -> %s: %s\n' "$branch" "$base" "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | tail -1
}

# _su_stacked_pr <branch> -> `gh stack submit --auto --open` (non-interactive
# per ADR-018: --auto skips the interactive editor, --open marks the PR ready
# for review) then reads the branch's PR URL via `gh pr view`. Prints the URL.
_su_stacked_pr() {
  local branch="$1" out rc pr_url
  out=$(gh stack submit --auto --open 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    printf 'stack-utils: gh stack submit failed for %s (exit %s): %s\n' "$branch" "$rc" "$out" >&2
    return 1
  fi
  pr_url=$(gh pr view "$branch" --json url -q '.url' 2>/dev/null)
  if [ -z "$pr_url" ] || [ "$pr_url" = "null" ]; then
    printf 'stack-utils: gh stack submit succeeded but no PR URL found for %s\n' "$branch" >&2
    return 1
  fi
  printf '%s\n' "$pr_url"
}

# stack_submit <config> <project_root> <title> <body> -> push the current
# feature branch, open its PR, and write the PR URL to both `stack.layers[]`
# (when stacking is enabled and ready) and `objectives_history[].pr` for the
# CURRENT feat's entry — in BOTH modes. Prints the created PR URL.
#
# disabled       -> plain `gh pr create` against `branch.base` (today's
#                    behavior, now mechanized) + history write.
# ready          -> `gh stack submit` PR, base = the layer's own recorded
#                    registry base (falling back to `stack_tip` when this
#                    feat has no registry entry yet) + registry `pr` update
#                    + history write.
# missing        -> fail-closed: same plain PR as `disabled`, PLUS a loud
#                    `stop_gate reason:stacking_unavailable` event — never a
#                    silent fallback.
stack_submit() {
  local config="$1" project_root="$2" title="$3" body="$4"
  [ -f "$config" ] || return 1
  local branch base feat_id avail pr_url
  branch=$(jq -r '.branch.feature // empty' "$config" 2>/dev/null)
  base=$(jq -r '.branch.base // "main"' "$config" 2>/dev/null)
  feat_id=$(jq -r '.feat_id // empty' "$config" 2>/dev/null)
  if [ -z "$branch" ]; then
    printf 'stack-utils: stack_submit: no branch.feature in config\n' >&2
    return 1
  fi

  _su_push_branch "$project_root" "$branch" || return 1

  avail=$(stack_available "$config")
  case "$avail" in
    ready)
      local layer_base
      layer_base=$(jq -r --arg f "$feat_id" '[.stack.layers[]? | select(.feat_id == $f)][0].base // empty' "$config" 2>/dev/null)
      [ -n "$layer_base" ] || layer_base=$(stack_tip "$config")
      pr_url=$(_su_stacked_pr "$branch") || return 1
      stack_register_layer "$config" "$feat_id" "$branch" "$layer_base" "$pr_url" || return 1
      ;;
    missing)
      pr_url=$(_su_plain_pr "$base" "$branch" "$title" "$body") || return 1
      emit_event "stop_gate" reason "stacking_unavailable" feat_id "$feat_id" branch "$branch"
      ;;
    *)
      pr_url=$(_su_plain_pr "$base" "$branch" "$title" "$body") || return 1
      ;;
  esac

  _su_write_history "$config" "$feat_id" "$pr_url"
  printf '%s\n' "$pr_url"
}
