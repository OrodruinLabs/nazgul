#!/usr/bin/env bash
# scripts/lib/team-teardown.sh — dead-session orphaned-team sweep
# (ADR-017: crash-only backstop; the per-iteration detect/direct/escalate
# gate this lib used to also provide was deleted in FEAT-026 — one-shot
# dispatch no longer leaves undismissed teammates behind).
#
# Platform facts this lib is built on (CLI 2.1.218, verified 2026-07-24):
# - TeamCreate/TeamDelete were removed in v2.1.178; team config
#   (~/.claude/teams/<name>/) is auto-removed on NORMAL session exit only.
# - Deleting ~/.claude/teams/<name>/ + ~/.claude/tasks/<name>/ by hand is the
#   accepted orphan workaround, safe ONLY when the lead session is dead.
#
# Fail-open everywhere: ambiguity means "not sweepable".
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own shell options (mirrors scripts/lib/raise-finding.sh).

# NO SENTINEL: the scalar `_NAZGUL_TEAM_TEARDOWN_SOURCED` that sat here made one exported variable
# enough to leave the dead-session sweep undefined — the 127-exit hazard nazgul-root.sh:40-49 measured.

NAZGUL_TEAMS_DIR="${NAZGUL_TEAMS_DIR:-$HOME/.claude/teams}"
NAZGUL_TEAM_TASKS_DIR="${NAZGUL_TEAM_TASKS_DIR:-$HOME/.claude/tasks}"
NAZGUL_PROJECTS_DIR="${NAZGUL_PROJECTS_DIR:-$HOME/.claude/projects}"

# tt_sweep_orphaned_teams <nazgul_dir> <project_dir> <current_session_id> <min_age_hours>
# Deletes team state (~/.claude/teams/<t> + ~/.claude/tasks/<t> + this
# project's dispatch manifests for its members) for teams that are BOTH
# attributable to <project_dir> (some member's cwd matches) AND provably dead:
# no session lock for the lead, no transcript for the lead fresher than
# <min_age_hours>, and not the current session. Prints one swept team name
# per line; appends one JSONL record per sweep to logs/team-sweep.jsonl.
# Conservative: ANY ambiguity -> skip. Always returns 0.
tt_sweep_orphaned_teams() {
  local nazgul_dir="$1" project_dir="$2" cur_sid="${3:-}" min_age_h="${4:-24}"
  local team_cfg team_dir team lead lead_safe alive t mt now min_age_s m
  local attributed m_cwd m_cwd_resolved cur_sid_team
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$NAZGUL_TEAMS_DIR" ] || return 0
  case "$min_age_h" in ''|*[!0-9]*) min_age_h=24 ;; esac
  [ "$min_age_h" -lt 1 ] 2>/dev/null && min_age_h=1
  min_age_s=$((min_age_h * 3600))
  now=$(date +%s)
  # Belt-and-braces: the current session's implicit team dir name
  # (session-<first 8 chars of the lead session id>, same derivation the
  # retired tt_team_dir_for_manifest() used) is excluded even if leadSessionId
  # in that team's config.json doesn't match cur_sid for any reason.
  cur_sid_team=""
  [ -n "$cur_sid" ] && cur_sid_team="session-${cur_sid:0:8}"
  # Physical resolution so macOS /tmp vs /private/tmp still attributes
  # correctly; fails open to the literal string if the path is inaccessible.
  project_dir=$(cd "$project_dir" 2>/dev/null && pwd -P || printf '%s' "$project_dir")
  for team_cfg in "$NAZGUL_TEAMS_DIR"/*/config.json; do
    [ -f "$team_cfg" ] || continue
    team_dir=$(dirname "$team_cfg")
    team=$(basename "$team_dir")
    case "$team" in ''|.|..|*/*) continue ;; esac
    attributed="false"
    while IFS= read -r m_cwd; do
      [ -n "$m_cwd" ] || continue
      m_cwd_resolved=$(cd "$m_cwd" 2>/dev/null && pwd -P || printf '%s' "$m_cwd")
      if [ "$m_cwd_resolved" = "$project_dir" ]; then
        attributed="true"
        break
      fi
    done <<< "$(jq -r '.members[]?.cwd // empty' "$team_cfg" 2>/dev/null || echo "")"
    [ "$attributed" = "true" ] || continue
    [ -n "$cur_sid_team" ] && [ "$team" = "$cur_sid_team" ] && continue
    lead=$(jq -r '.leadSessionId // ""' "$team_cfg" 2>/dev/null || echo "")
    [ -z "$lead" ] && continue
    [ -n "$cur_sid" ] && [ "$lead" = "$cur_sid" ] && continue
    # Lock liveness: check BOTH sanitized filename forms. session-tracker.sh's
    # _sanitize_session_id pipes through echo, so the trailing newline is
    # transliterated to a trailing "_" in real lock filenames (<id>_.lock);
    # tolerate both that quirk and any future fix that drops it.
    lead_safe=$(printf '%s' "$lead" | tr -c 'A-Za-z0-9_-' '_')
    if [ -f "$nazgul_dir/sessions/${lead_safe}.lock" ] || [ -f "$nazgul_dir/sessions/${lead_safe}_.lock" ]; then
      continue
    fi
    alive="false"
    for t in "$NAZGUL_PROJECTS_DIR"/*/"$lead".jsonl; do
      [ -f "$t" ] || continue
      mt=$(stat -c %Y "$t" 2>/dev/null || stat -f %m "$t" 2>/dev/null || echo "")
      case "$mt" in ''|*[!0-9]*) alive="true"; break ;; esac
      if [ $((now - mt)) -lt "$min_age_s" ]; then alive="true"; break; fi
    done
    [ "$alive" = "true" ] && continue
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      case "$m" in */*|*..*) continue ;; esac
      rm -f "$nazgul_dir/dispatch/${m}.json"
    done <<< "$(jq -r '.members[]?.name // ""' "$team_cfg" 2>/dev/null || echo "")"
    rm -rf "$team_dir"
    rm -rf "${NAZGUL_TEAM_TASKS_DIR:?}/${team}"
    mkdir -p "$nazgul_dir/logs" 2>/dev/null || true
    jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg team "$team" --arg lead "$lead" \
      '{ts:$ts, team:$team, lead:$lead, action:"swept", reason:"no_lock_no_fresh_transcript"}' \
      >> "$nazgul_dir/logs/team-sweep.jsonl" 2>/dev/null || true
    printf '%s\n' "$team"
  done
  return 0
}
