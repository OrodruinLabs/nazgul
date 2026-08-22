#!/usr/bin/env bash
set -euo pipefail

# scripts/stamp-plan-objective.sh — FEAT-031 (ADR-022/023): bind nazgul/plan.md's
# frontmatter `feat_id` to this objective, from config.feat_id and from nowhere else.
#
# WHY THIS EXISTS. `ttg_objective_roster` refuses to scope an objective by a plan whose
# frontmatter feat_id is absent or disagrees with config's — correct, and the last gate
# before DONE. But `templates/plan.md` ships the key as the literal placeholder
# `<FEAT-NNN>` and NOTHING substituted it: /nazgul:init copies the template verbatim
# (skills/init/SKILL.md), and the Planner — the only writer of the `## Tasks` roster —
# said nothing about the plan's own frontmatter. So `IMPLEMENTED -> DONE` by merge
# evidence was unreachable for every project except this repo, whose plan.md happens to
# be hand-written with a real id. This file is the missing producer.
#
# THE PRODUCER IS THE ROSTER'S WRITER, AND THAT IS NOT NEGOTIABLE POSITIONING. The
# frontmatter is a claim ABOUT the `## Tasks` roster below it, so only whoever wrote that
# roster can honestly make it. Two earlier-looking producers were rejected for that reason:
#   /nazgul:init            config.feat_id is still null there (create_feature_branch
#                           assigns it later), so init cannot know the value at all.
#   create_feature_branch   it assigns feat_id, but at that moment plan.md is either the
#                           untouched template with an EMPTY roster, or — on a second
#                           objective — already moved to nazgul/archive/ by the start
#                           skill. Stamping a roster written for another objective is the
#                           wrong-binding hazard the gate exists to catch.
#
# NEVER AUTOMATIC, AND NEVER A LOOP STEP. Nothing in the stop-hook or any other periodic
# path may call this. An unconditional copy of config.feat_id into whatever plan.md is on
# disk would make the gate's corroboration tautological — the predicate would be checking
# a value the machine had just written for it, which is fixing the gate under another name.
# It runs when a roster is written (the Planner, per agents/planner.md) or when an operator
# heals a pre-existing plan by hand, and it REFUSES to overwrite a real disagreeing id.
#
# THE VALUE IS NEVER RE-DERIVED. config.feat_id is the objective identity assigned once by
# create_feature_branch; recomputing it here (from objectives_history length, a branch name,
# anything) is how a plan gets bound to an off-by-one objective.
#
# WRITE-THEN-READ-BACK (ADR-021). "I wrote it" and "it is there" are different claims: the
# stamp is re-read from the same absolute path and a mismatch is a failure, not a warning.
#
# EVERY PARSER HERE IS THE GATE'S OWN, AND NONE IS RE-IMPLEMENTED. Both halves of the claim
# are read through scripts/lib/task-transition-guard.sh — ttg_plan_feat_id for the frontmatter
# value, ttg_objective_roster_ids for the roster that value is a claim ABOUT — so producer and
# predicate cannot drift on either half's bytes. Board 4 found the roster half duplicated here
# while this paragraph already claimed it was shared; a private copy is what it forbids.
#
# ACTIONS (closed set, one is always printed):
#   stamped        the plan declared nothing, or an unsubstituted <...> placeholder
#   already-bound  it already declared exactly this feat_id — no write
#   refused        it declares a DIFFERENT real objective, or a precondition failed
#
# EXIT: 0 stamped or already-bound; 1 refused; 3 usage/precondition error.
#
# Usage: scripts/stamp-plan-objective.sh [--project-root <path>]

ENTRY="stamp-plan-objective"

usage() {
  echo "Usage: scripts/stamp-plan-objective.sh [--project-root <path>]" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=./lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"

PROJECT_ROOT_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root=*) PROJECT_ROOT_ARG="${1#--project-root=}"; shift ;;
    --project-root)   [ "$#" -ge 2 ] || { usage; exit 3; }; PROJECT_ROOT_ARG="$2"; shift 2 ;;
    -h|--help)        usage; exit 3 ;;
    *)                echo "$ENTRY: unknown argument: $(printf '%s' "$1" | tr -d '\n' | cut -c1-120)" >&2; usage; exit 3 ;;
  esac
done

if [ -n "$PROJECT_ROOT_ARG" ]; then PROJECT_ROOT="$PROJECT_ROOT_ARG"; else PROJECT_ROOT="$(resolve_project_root)"; fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
  echo "$ENTRY: project root does not exist: ${PROJECT_ROOT_ARG:-<resolved>}" >&2; exit 3; }
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
PLAN="$NAZGUL_DIR/plan.md"

refuse() {
  echo "$ENTRY: refused — $1" >&2
  echo "$ENTRY: $PLAN action=refused feat_id=${FEAT_ID:-<unread>}"
  exit 1
}

if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ] || ! jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1; then
  echo "$ENTRY: no valid regular non-symlink Nazgul config at $CONFIG" >&2
  exit 3
fi

FEAT_ID=$(jq -r '.feat_id // empty' "$CONFIG" 2>/dev/null || true)
if [ -z "$FEAT_ID" ]; then
  refuse "$CONFIG names no feat_id — this objective has no identity yet, so there is nothing to bind the plan to. Run /nazgul:start (create_feature_branch assigns it) before planning."
fi
if ttg_plan_feat_placeholder "$FEAT_ID"; then
  refuse "$CONFIG's feat_id is itself the placeholder \"$FEAT_ID\" — binding a plan to a placeholder records a claim about no objective at all."
fi
if [ -L "$PLAN" ]; then
  refuse "$PLAN is a symlink — a stamp is a claim about the bytes the gate will read, and a link can be repointed between the two. Replace it with a regular file, then re-run."
fi
if [ ! -f "$PLAN" ]; then
  refuse "no regular file at $PLAN — the Planner writes the plan before it can be bound to $FEAT_ID."
fi

# lean-comments: allow-run — which of three causes is ESTABLISHED, and why that matters here.
# The frontmatter is a claim about the roster, so refuse to make it before one exists. This is
# what keeps the stamp out of create_feature_branch's empty-template moment. An empty roster
# has three causes and the refusal used to name ONE of them — the commented examples — on
# every path, including the two where it is provably not the cause. A refusal naming a cause
# it cannot establish is the defect class this objective exists to close, so the cause is
# derived here, through the gate's own section reader and id patterns rather than a private
# copy, and the three sentences say what ttg_objective_roster's three say.
ROSTER_IDS=$(ttg_objective_roster_ids "$PLAN")
if [ -z "$ROSTER_IDS" ]; then
  COMMENTED=$(_ttg_roster_section "$PLAN" | grep -coE "$_TTG_ROSTER_ID_RE" || true)
  PATCHES=$(_ttg_roster_section "$PLAN" | _ttg_strip_html_comments \
    | grep -oE "$_TTG_ROSTER_PATCH_RE" | LC_ALL=C sort -u | tr '\n' ' ' || true)
  if [ "${COMMENTED:-0}" -gt 0 ]; then
    refuse "$PLAN's ## Tasks section names task ids ONLY inside HTML comments — a comment is not a roster entry (templates/plan.md ships its examples that way), so there is no roster for the frontmatter to be a claim ABOUT. Write the roster first, then run this."
  fi
  if [ -n "${PATCHES// /}" ]; then
    refuse "$PLAN's ## Tasks section names ONLY patch ids (${PATCHES% }) — the frontmatter feat_id is a claim about the TASK-NNN manifests scripts/task-transition.sh resolves, and a patch record places none of them in $FEAT_ID's roster. Write the task roster first, then run this."
  fi
  refuse "$PLAN carries no ## Tasks roster yet — the frontmatter feat_id is a claim ABOUT that roster, so there is nothing to claim. Write the roster first, then run this."
fi
ROSTER_COUNT=$(printf '%s\n' "$ROSTER_IDS" | grep -c . || true)

DECLARED=$(ttg_plan_feat_id "$PLAN")
ACTION="stamped"
if [ "$DECLARED" = "$FEAT_ID" ]; then
  ACTION="already-bound"
elif [ -n "$DECLARED" ] && ! ttg_plan_feat_placeholder "$DECLARED"; then
  refuse "$PLAN already declares feat_id \"$DECLARED\", a real objective that is not $FEAT_ID. Overwriting it would scope $DECLARED's roster to $FEAT_ID — a wrong binding is worse than an absent one. Archive that objective's plan (see /nazgul:start's new-objective step) or fix $CONFIG, then re-run."
fi

if [ "$ACTION" = "stamped" ]; then
  # The operator healing a pre-existing plan by hand is the one caller who cannot see what
  # is being claimed, so name the roster before claiming it rather than only after.
  echo "$ENTRY: binding this roster to $FEAT_ID: $(printf '%s' "$ROSTER_IDS" | tr '\n' ' ')" >&2
  TMP=$(mktemp "$NAZGUL_DIR/.nazgul-plan.XXXXXX") || {
    echo "$ENTRY: cannot create a temp file beside $PLAN" >&2; exit 3; }
  trap 'rm -f "$TMP"' EXIT
  # The GNU-only --reference form of chmod fails on BSD/macOS, so the `|| chmod 644` fallback
  # it used to carry was the only branch ever taken here — silently re-moding the plan.
  MODE=$(_ttg_file_mode "$PLAN") || {
    echo "$ENTRY: cannot read $PLAN's mode, so a rewrite could only be installed under a guessed one; $PLAN is unchanged" >&2
    exit 3
  }
  if ! awk -v fid="$FEAT_ID" '
    NR==1 && /^---[[:space:]]*$/ { print; print "feat_id: " fid; fm=1; next }
    NR==1 { print "---"; print "feat_id: " fid; print "---"; print; next }
    fm && !closed && /^---[[:space:]]*$/ { closed=1; print; next }
    fm && !closed && /^feat_id:/ { next }
    { print }
  ' "$PLAN" > "$TMP"; then
    rm -f "$TMP"; echo "$ENTRY: rewrite of $PLAN failed; the file is unchanged" >&2; exit 3
  fi
  chmod "$MODE" "$TMP" || { echo "$ENTRY: cannot apply mode $MODE to the staged rewrite" >&2; exit 3; }
  mv "$TMP" "$PLAN"
  trap - EXIT
fi

PERSISTED=$(ttg_plan_feat_id "$PLAN")
if [ "$PERSISTED" != "$FEAT_ID" ]; then
  echo "$ENTRY: read-back FAILED — $PLAN persists feat_id \"$PERSISTED\", not \"$FEAT_ID\"; the stamp did not land" >&2
  echo "$ENTRY: $PLAN action=refused feat_id=$PERSISTED"
  exit 1
fi

if declare -F emit_event >/dev/null 2>&1 || source "$SCRIPT_DIR/lib/emit-event.sh" 2>/dev/null; then
  emit_event "plan_objective_stamped" action "$ACTION" feat_id "$FEAT_ID" \
    plan "$PLAN" roster_tasks "$ROSTER_COUNT" 2>/dev/null || true
fi

echo "$ENTRY: $PLAN action=$ACTION feat_id=$PERSISTED roster_tasks=$ROSTER_COUNT"
