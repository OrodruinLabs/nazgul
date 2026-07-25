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
  case "$team" in ''|.|*..*|*[!A-Za-z0-9._-]*) return 1 ;; esac
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
# Self-heals CONSERVATIVELY: a manifest is deleted only when deletion is
# unambiguous — (a) team dir gone AND the manifest carries an explicit `team`
# field (the implicit session-<id8> fallback is too unreliable to justify a
# destructive action), or (b) teammate no longer a member of its team AND its
# report was actually delivered (a completed dismissal implies a consumed
# report on disk). Anything ambiguous — implicit-team fallback with the team
# dir gone, a non-array `.members`, or an absent member whose report was
# never delivered — fails open and keeps the manifest; undelivered reports
# remain the TeammateIdle guard's jurisdiction, not ours. Always returns 0.
tt_detect_undismissed() {
  local nazgul_dir="$1" project_dir="$2" session_id="${3:-}"
  local manifest name feat cur_feat explicit_team team_dir members_type
  local report spawned delivered blocks members_json
  [ -d "$nazgul_dir/dispatch" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cur_feat=$(jq -r '.feat_id // "default"' "$nazgul_dir/config.json" 2>/dev/null || echo "default")
  for manifest in "$nazgul_dir/dispatch"/*.json; do
    [ -f "$manifest" ] || continue
    name=$(jq -r '.teammate // ""' "$manifest" 2>/dev/null || echo "")
    [ -z "$name" ] && continue
    case "$name" in *..*|*[!A-Za-z0-9._-]*) continue ;; esac
    feat=$(jq -r '.feat_id // ""' "$manifest" 2>/dev/null || echo "")
    [ -n "$feat" ] && [ "$feat" != "$cur_feat" ] && continue
    explicit_team=$(jq -r '.team // ""' "$manifest" 2>/dev/null || echo "")
    team_dir=$(tt_team_dir_for_manifest "$manifest" "$session_id") || continue
    if [ ! -f "$team_dir/config.json" ]; then
      # Only delete when the manifest names its team explicitly. The implicit
      # session-<id8> fallback can resolve to a nonexistent or wrong team dir
      # (generated fallback session ids, concurrent sessions), and deleting a
      # LIVE teammate's manifest on that guess would silently disable the
      # TeammateIdle guard for it. No explicit team on record -> keep.
      [ -n "$explicit_team" ] && rm -f "$manifest"
      continue
    fi
    members_type=$(jq -r '(.members|type)' "$team_dir/config.json" 2>/dev/null) || members_type=""
    if [ "$members_type" != "array" ]; then
      continue   # members shape ambiguous (or jq failed) → fail open, keep manifest
    fi
    members_json=$(jq -c '[.members[]?.name]' "$team_dir/config.json" 2>/dev/null) || members_json=""
    if [ -z "$members_json" ]; then
      continue   # config exists but unparseable → ambiguous → fail open, keep manifest
    fi
    # Report delivered-ness is needed by BOTH branches below: to decide
    # whether an absent member's manifest is safe to self-heal, and (as
    # before) to decide whether a still-present member's manifest has leaked.
    report=$(jq -r '.report_path // ""' "$manifest" 2>/dev/null || echo "")
    delivered="false"
    case "$report" in
      ''|/*|*..*|*$'\t'*|*$'\n'*|*$'\r'*) : ;;  # empty or unsafe path → treated as not delivered
      *)
        spawned=$(jq -r '.spawned_at_epoch // 0' "$manifest" 2>/dev/null || echo 0)
        tt_report_delivered "$project_dir/$report" "$spawned" && delivered="true"
        ;;
    esac
    if ! jq -e --arg n "$name" 'index($n)' <<< "$members_json" >/dev/null 2>&1; then
      # Member absent = dismissal completed IFF the report was actually
      # delivered (a completed dismissal implies a consumed report on disk).
      # Absent + report NOT delivered → the teammate may still be live and
      # the TeammateIdle guard owns it → keep. Unsafe/missing report → keep.
      [ "$delivered" = "true" ] && rm -f "$manifest"
      continue
    fi
    [ "$delivered" = "true" ] || continue
    blocks=$(jq -r '.teardown_blocks // 0' "$manifest" 2>/dev/null || echo 0)
    case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$report" "$team_dir" "$blocks"
  done
  return 0
}

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
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$NAZGUL_TEAMS_DIR" ] || return 0
  case "$min_age_h" in ''|*[!0-9]*) min_age_h=24 ;; esac
  min_age_s=$((min_age_h * 3600))
  now=$(date +%s)
  for team_cfg in "$NAZGUL_TEAMS_DIR"/*/config.json; do
    [ -f "$team_cfg" ] || continue
    team_dir=$(dirname "$team_cfg")
    team=$(basename "$team_dir")
    case "$team" in ''|.|..|*/*) continue ;; esac
    jq -e --arg d "$project_dir" '[.members[]?.cwd == $d] | any' \
      "$team_cfg" >/dev/null 2>&1 || continue
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
      '{ts:$ts, team:$team, lead:$lead, action:"swept"}' \
      >> "$nazgul_dir/logs/team-sweep.jsonl" 2>/dev/null || true
    printf '%s\n' "$team"
  done
  return 0
}
