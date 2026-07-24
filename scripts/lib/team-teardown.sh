#!/usr/bin/env bash
# scripts/lib/team-teardown.sh — Agent-Teams teammate teardown detection and
# orphaned-team sweep (spec docs/superpowers/specs/2026-07-24-team-teardown-design.md).
#
# Platform facts this lib is built on (CLI 2.1.218, verified 2026-07-24):
# - TeamCreate/TeamDelete were removed in v2.1.178; team config
#   (~/.claude/teams/<name>/) is auto-removed on NORMAL session exit only.
# - The only teardown primitive is a per-teammate SendMessage shutdown_request
#   sent by the lead; teammates never self-terminate — idle is terminal.
# - Hooks cannot shut teammates down, so enforcement is: detect (here) →
#   direct the lead (stop-hook prompt) → verify next iteration → escalate.
# - Deleting ~/.claude/teams/<name>/ + ~/.claude/tasks/<name>/ by hand is the
#   accepted orphan workaround, safe ONLY when the lead session is dead.
#
# Fail-open everywhere: ambiguity means "not leaked" / "not sweepable".
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own shell options (mirrors scripts/lib/raise-finding.sh).

[ -n "${_NAZGUL_TEAM_TEARDOWN_SOURCED:-}" ] && return 0
_NAZGUL_TEAM_TEARDOWN_SOURCED=1

NAZGUL_TEAMS_DIR="${NAZGUL_TEAMS_DIR:-$HOME/.claude/teams}"
NAZGUL_TEAM_TASKS_DIR="${NAZGUL_TEAM_TASKS_DIR:-$HOME/.claude/tasks}"
NAZGUL_PROJECTS_DIR="${NAZGUL_PROJECTS_DIR:-$HOME/.claude/projects}"

# tt_team_dir_for_manifest <manifest> <session_id>
# Prints the team dir this manifest's teammate belongs to. Manifest `team`
# field wins; empty falls back to the session's implicit team
# (session-<first 8 chars of session_id>). Returns 1 on unresolvable/unsafe.
tt_team_dir_for_manifest() {
  local manifest="$1" session_id="${2:-}" team
  team=$(jq -r '.team // ""' "$manifest" 2>/dev/null || echo "")
  if [ -z "$team" ] && [ -n "$session_id" ]; then
    team="session-${session_id:0:8}"
  fi
  case "$team" in ''|*/*|*..*) return 1 ;; esac
  printf '%s/%s' "$NAZGUL_TEAMS_DIR" "$team"
}

# tt_report_delivered <report_abs_path> <spawned_epoch>
# Exit 0 iff the report file exists, is non-empty, and its mtime is >= the
# spawn epoch (mirrors teammate-idle-guard.sh; stat failure -> delivered/open).
tt_report_delivered() {
  local report="$1" spawned="${2:-0}" mtime
  [ -s "$report" ] || return 1
  case "$spawned" in ''|*[!0-9]*) spawned=0 ;; esac
  mtime=$(stat -c %Y "$report" 2>/dev/null || stat -f %m "$report" 2>/dev/null || echo "")
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ "$mtime" -ge "$spawned" ]
}

# tt_detect_undismissed <nazgul_dir> <project_dir> <session_id>
# One line per teammate whose report is delivered but who is still a member of
# its team: name<TAB>report_path<TAB>team_dir<TAB>teardown_blocks
# Self-heals: a manifest whose team dir is gone (session-exit cleanup) or
# whose teammate is no longer a member (dismissal completed) is DELETED — it
# has served its purpose. Undelivered reports are the TeammateIdle guard's
# jurisdiction, not ours. Always returns 0.
tt_detect_undismissed() {
  local nazgul_dir="$1" project_dir="$2" session_id="${3:-}"
  local manifest name feat cur_feat team_dir report spawned blocks
  [ -d "$nazgul_dir/dispatch" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cur_feat=$(jq -r '.feat_id // "default"' "$nazgul_dir/config.json" 2>/dev/null || echo "default")
  for manifest in "$nazgul_dir/dispatch"/*.json; do
    [ -f "$manifest" ] || continue
    name=$(jq -r '.teammate // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$name" ] && continue
    case "$name" in */*|*..*) continue ;; esac
    feat=$(jq -r '.feat_id // ""' "$manifest" 2>/dev/null || echo "")
    [ -n "$feat" ] && [ "$feat" != "$cur_feat" ] && continue
    team_dir=$(tt_team_dir_for_manifest "$manifest" "$session_id") || continue
    if [ ! -f "$team_dir/config.json" ]; then
      rm -f "$manifest"
      continue
    fi
    if ! jq -e --arg n "$name" '[.members[]?.name] | index($n)' \
        "$team_dir/config.json" >/dev/null 2>&1; then
      rm -f "$manifest"
      continue
    fi
    report=$(jq -r '.report_path // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$report" ] && continue
    case "$report" in /*|*..*) continue ;; esac
    spawned=$(jq -r '.spawned_at_epoch // 0' "$manifest" 2>/dev/null || echo 0)
    tt_report_delivered "$project_dir/$report" "$spawned" || continue
    blocks=$(jq -r '.teardown_blocks // 0' "$manifest" 2>/dev/null || echo 0)
    case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$report" "$team_dir" "$blocks"
  done
  return 0
}
