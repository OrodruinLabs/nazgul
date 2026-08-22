#!/usr/bin/env bash
set -euo pipefail

# Nazgul mechanized red-run capture (FEAT-028 / TRD §2, PRD AC3).
#
# Produces a task's `## Red-Run Evidence` block from reality instead of from the
# author's keyboard: the task's new/changed test files are copied into a DETACHED
# worktree at the manifest's Base SHA and run there under the task's own scoped
# filter. A test that passes without the change is vacuous, and saying so is this
# script's core job — not a warning.
#
# Usage: scripts/red-run.sh <TASK-ID> [--filter=<name>] [--project-root=<path>]
#                           [--copy=<path> ...]
#
# The filter defaults to the first `--filter=<name>` named in the manifest's
# `## Test Obligation` section. There is no full-suite mode: the ~300s per-task
# bar is a stated boundary, and a red run that blows it gets routed around.
#
# The runner is the PROJECT's own, resolved in one stated order: the live project
# root's `project.test_command`, else `tests/run-tests.sh` if the pre-change tree
# carries one, else a named refusal. A runner that resolves INSIDE this repository
# is run FROM the pre-change tree whatever spelling named it; one that resolves
# genuinely outside still runs, and the evidence block records that it did.
# The scoped filter is interpolated through
# `project.test_filter_template` — a literal `{filter}` substitution, never eval —
# because appending a flag Nazgul chose to a command the project chose is a guess
# whose failure modes are a fabricated red (flag rejected) and an unscoped full
# suite reported as a scoped one (flag ignored).
#
# The tests-root set is `project.test_roots` (default `["tests"]`), read through
# the SAME `_ttg_red_run_roots` the evidence gate uses. A second reader here is
# how trigger and satisfier drifted apart before: the gate would accept
# multi-root evidence this producer could not generate, pushing the operator back
# to hand-authoring the block ADR-019 exists to mechanize.
#
# The copy set defaults to the task's changed files under those roots MINUS the
# harness itself: copying a changed `tests/run-tests.sh` into the pre-change tree
# would run the new tests under the changed runner, which is the change being
# present — the exact vacuity this script exists to detect. `--copy=` (repeatable)
# pins the set explicitly and suppresses derivation entirely.
#
# The resolved command is SCREENED against scripts/lib/destructive-patterns.sh
# before it runs. This script executes `project.test_command` directly, so it
# never passes the PreToolUse Bash guard the way the old hardcoded invocation
# did; without the screen, every denylisted command would be reachable by writing
# it into nazgul/config.json and letting the loop trigger a red run.
#
# Exit codes:
#   0  RED confirmed — the evidence block was written
#   1  usage or environment error — nothing written
#   2  VACUOUS — the pre-change run PASSED (exit 0); nothing written
#   3  NOTHING MATCHED — the scoped filter matched no test file in the pre-change tree
#   4  the pre-change harness reported an internal coverage-accounting defect
#   5  REFUSED TO EXECUTE — the configured command is denylisted; nothing was run
#   6  INDETERMINATE — the runner exited non-zero but no failing test file could be
#      identified from its output; nothing written
#
# How a RUNNER's exit code is read — declared here, not inherited from the one
# harness this script was written against. Only 0 is universal: a pre-change run
# that passes is vacuous whatever produced it. 2 and 3 are `tests/run-tests.sh`'s
# own contract, read as its two "did not really run" states; another runner's 2
# or 3 is misreported but still fails CLOSED, writing nothing. Every other
# non-zero code is only a CANDIDATE red and has to earn it — the output must name
# a failing test file, or a failing case, or at least mention a copied test file
# by name. Failing all three is exit 6, never a red. The code that makes this
# load-bearing is pytest's 5 ("no tests were collected"): under the old reading it
# fell through to RED confirmed and an evidence block was written for a run in
# which nothing executed. ADR-024 decision 3 closed exactly this hazard for the
# filter flag ("a rejected flag makes the runner exit non-zero, which red-run
# reads as RED confirmed — a fabricated red"); the same hazard in the exit-code
# reading was not carried across at the time.

BEGIN_MARK="<!-- red-run.sh:begin — generated block, refreshed in place on re-capture -->"
END_MARK="<!-- red-run.sh:end -->"

die() {
  printf 'red-run: %s\n' "$@" >&2
  exit 1
}

# Hard failure with an explicit exit code — the two vacuity detectors are
# distinguishable mechanically, not only by their message.
die_code() {
  local code="$1"; shift
  printf 'red-run: %s\n' "$@" >&2
  exit "$code"
}

usage() {
  echo "Usage: scripts/red-run.sh <TASK-ID> [--filter=<name>] [--project-root=<path>] [--copy=<path> ...]"
}

# The value IS the argv, so correct argv handling is exactly why it does not
# help: `touch /tmp/x` needs no metacharacter to escape the project.
rr_screen_command() {
  local cmd="$1" ec=0
  dp_scan_command "$cmd" || ec=$?
  if [ "$ec" -eq 2 ]; then
    die_code 5 \
      "REFUSED TO EXECUTE — the command this project configured is on Nazgul's destructive-command denylist." \
      "Denylisted as: $DP_REASON" \
      "Command contained: $DP_PATTERN" \
      "Composed command: $cmd" \
      "It came from ${RUNNER_SOURCE:-the resolved runner} and red-run executes it directly, so it never reaches the PreToolUse Bash guard; relocating a denylisted command into nazgul/config.json would otherwise run it unguarded on any scripts/ or tests/ task." \
      "This is not a red run that failed — nothing was run at all."
  fi
  ec=0
  dp_scan_manifest_write "$cmd" || ec=$?
  if [ "$ec" -eq 2 ]; then
    die_code 5 \
      "REFUSED TO EXECUTE — the command this project configured writes a task manifest." \
      "Only scripts/task-transition.sh may write a manifest status (ADR-020), and a red-run runner has no business writing one at all." \
      "Composed command: $cmd" \
      "This is not a red run that failed — nothing was run at all."
  fi
}

# Implementation, not test input: never derived into the pre-change tree. Not extended
# per project — a resolved runner inside the copy set is reported below, never dropped.
RR_NEVER_COPY="tests/run-tests.sh
tests/lib/assertions.sh
tests/lib/setup.sh"

# The pre-configuration convention: the runner precedence order falls back to it,
# and the shipped filter template is the flag it has always accepted.
RR_LEGACY_RUNNER="tests/run-tests.sh"
RR_DEFAULT_FILTER_TEMPLATE="--filter={filter}"

TASK_ID=""
FILTER=""
PROJECT_ROOT=""
EXPLICIT_COPY=""
for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    --project-root=*) PROJECT_ROOT="${arg#--project-root=}" ;;
    --copy=*) EXPLICIT_COPY="${EXPLICIT_COPY}${arg#--copy=}
" ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown argument: $arg" ;;
    *)
      [ -z "$TASK_ID" ] || die "more than one task id given: '$TASK_ID' and '$arg'"
      TASK_ID="$arg"
      ;;
  esac
done

[ -n "$TASK_ID" ] || { usage >&2; die "no task id given"; }
[[ "$TASK_ID" =~ ^(TASK|PATCH)-[0-9]+$ ]] \
  || die "'$TASK_ID' is not a TASK-NNN / PATCH-NNN id"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/destructive-patterns.sh
source "$SCRIPT_DIR/lib/destructive-patterns.sh"

if [ -z "$PROJECT_ROOT" ]; then
  _RR_ROOT_LIB="$SCRIPT_DIR/lib/nazgul-root.sh"
  if [ -f "$_RR_ROOT_LIB" ]; then
    # shellcheck source=./lib/nazgul-root.sh
    source "$_RR_ROOT_LIB"
    PROJECT_ROOT="$(resolve_project_root)"
  else
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
fi
[ -d "$PROJECT_ROOT" ] || die "project root does not exist: $PROJECT_ROOT"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

validate_copy_path() {
  local rel="$1" source parent
  rr_rel_under_roots "$rel" || die \
    "copy path must be repository-relative and under one of this project's test roots [$RR_ROOTS_LIST]: $rel"
  case "/$rel/" in
    */../*|*/./*) die "copy path must not contain '.' or '..' segments: $rel" ;;
  esac

  source="$PROJECT_ROOT/$rel"
  [ -f "$source" ] || return 0
  [ ! -L "$source" ] || die "copy path must not be a symlink: $rel"
  parent=$(cd "$(dirname "$source")" && pwd -P) || die "cannot resolve copy path parent: $rel"
  rr_dir_under_roots "$parent/" "$PROJECT_ROOT" || die \
    "copy path resolves outside this project's test roots [$RR_ROOTS_LIST]: $rel"
}

MANIFEST="$PROJECT_ROOT/nazgul/tasks/$TASK_ID.md"
[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"

command -v git >/dev/null 2>&1 || die "git is not available — a red run cannot be captured without it"
git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "$PROJECT_ROOT is not a git repository"

# Same `## Metadata` awk scoping the gate uses, so both read the one Base SHA.
BASE_SHA=$(awk '/^## Metadata/{f=1;next} /^## /{f=0} f' "$MANIFEST" \
  | grep -iE '^[[:space:]]*-[[:space:]]*\*\*Base SHA\*\*' | head -1 \
  | grep -oE '[0-9a-f]{7,64}' | head -1 || true)
[ -n "$BASE_SHA" ] || die \
  "$TASK_ID's manifest records no Base SHA under ## Metadata." \
  "There is no pre-change tree to run against — record it before capturing a red run."
git -C "$PROJECT_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null \
  || die "Base SHA $BASE_SHA does not resolve to a commit in $PROJECT_ROOT"
git -C "$PROJECT_ROOT" merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null \
  || die "Base SHA $BASE_SHA is not an ancestor of HEAD"

if [ -z "$FILTER" ]; then
  FILTER=$(awk '/^## Test Obligation/{f=1;next} /^## /{f=0} f' "$MANIFEST" \
    | grep -oE '\-\-filter=[A-Za-z0-9._/-]+' | head -1 | sed 's/^--filter=//' || true)
fi
[ -n "$FILTER" ] || die \
  "no scoped filter given and none found in $TASK_ID's ## Test Obligation section." \
  "Pass --filter=<name>; a full-suite red run is out of the per-task time budget."

# Config lives under the gitignored `nazgul/`, so it is read from the LIVE project
# root and never from the detached pre-change worktree, which has no copy of it.
RR_CONFIG="$PROJECT_ROOT/nazgul/config.json"

# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"
if ! _ttg_red_run_roots "$PROJECT_ROOT" "$PROJECT_ROOT/nazgul"; then
  die \
    "project.test_roots in $RR_CONFIG is $_TTG_ROOTS_DETAIL, so this project's test roots cannot be determined." \
    "The evidence gate fails closed on the same value, so a capture against a guessed root would write evidence that gate then rejects." \
    "This is not a red run that failed — nothing was run at all."
fi
RR_ROOTS="$_TTG_ROOTS_REL"
RR_ROOTS_LIST="$(_ttg_red_run_roots_list)"
[ -n "$RR_ROOTS" ] || die \
  "project.test_roots in $RR_CONFIG named no usable repository-relative root (source: $_TTG_ROOTS_SOURCE)." \
  "This is not a red run that failed — nothing was run at all."

RR_ROOT_PATHSPEC=()
while IFS= read -r _rr_root; do
  [ -n "$_rr_root" ] || continue
  RR_ROOT_PATHSPEC+=("$_rr_root/")
done <<EOF
$RR_ROOTS
EOF

rr_rel_under_roots() {
  local rel="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$rel" in "$root"/*) return 0 ;; esac
  done <<EOF
$RR_ROOTS
EOF
  return 1
}

# Containment for a resolved directory against every root under $2 — the live
# tree for the copy set, the scratch tree for the destination, one rule for both.
rr_dir_under_roots() {
  local candidate="$1" base="$2" root abs
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    abs=$(cd "$base/$root" 2>/dev/null && pwd -P) || continue
    case "$candidate" in "$abs"/*) return 0 ;; esac
  done <<EOF
$RR_ROOTS
EOF
  return 1
}

rr_cfg_kind() {
  local key="$1" out
  [ -f "$RR_CONFIG" ] || { echo absent; return 0; }
  out=$(jq -r --arg k "$key" '
    (if (.project | type) == "object" then .project else {} end) as $p
    | if ($p | has($k) | not) then "absent"
      elif $p[$k] == null then "absent"
      elif ($p[$k] | type) != "string" then "nonstring"
      elif ($p[$k] | length) == 0 then "empty"
      else "string" end' "$RR_CONFIG" 2>/dev/null) || out="unreadable"
  [ -n "$out" ] || out="unreadable"
  printf '%s' "$out"
}

rr_cfg_value() {
  jq -r --arg k "$1" '(if (.project | type) == "object" then .project else {} end)[$k]' \
    "$RR_CONFIG" 2>/dev/null || true
}

# The legacy convention is recognised by value, not by where it came from, so
# precedence order 2 and the shipped default filter template always agree.
rr_is_legacy_runner() {
  local first="${1:-}"
  case "$first" in
    bash|sh) first="${2:-}" ;;
  esac
  [ "${first#./}" = "$RR_LEGACY_RUNNER" ]
}

if [ -f "$RR_CONFIG" ]; then
  command -v jq >/dev/null 2>&1 || die \
    "$RR_CONFIG exists but jq is not available, so project.test_command cannot be read." \
    "Refusing to run a runner this project may not use. Install jq and re-capture."
fi

TEST_COMMAND=""
RUNNER_SOURCE=""
CMD_KIND=$(rr_cfg_kind test_command)
case "$CMD_KIND" in
  string)
    TEST_COMMAND=$(rr_cfg_value test_command)
    RUNNER_SOURCE="project.test_command"
    ;;
  absent) ;;
  *) die \
    "project.test_command in $RR_CONFIG is unusable ($CMD_KIND) — it must be a non-empty string." \
    "This is not a runner that failed: no runner could be determined at all." ;;
esac

RUNNER_ARGV=()
if [ -n "$TEST_COMMAND" ]; then
  read -r -a RUNNER_ARGV <<<"$TEST_COMMAND"
fi
[ "${#RUNNER_ARGV[@]}" -gt 0 ] || RUNNER_SOURCE=""

TPL_KIND=$(rr_cfg_kind test_filter_template)
FILTER_TEMPLATE=""
case "$TPL_KIND" in
  string) FILTER_TEMPLATE=$(rr_cfg_value test_filter_template) ;;
  absent)
    if [ "${#RUNNER_ARGV[@]}" -eq 0 ] || rr_is_legacy_runner "${RUNNER_ARGV[0]:-}" "${RUNNER_ARGV[1]:-}"; then
      FILTER_TEMPLATE="$RR_DEFAULT_FILTER_TEMPLATE"
    else
      die \
        "project.test_filter_template is not configured in $RR_CONFIG, and '$TEST_COMMAND' is not the $RR_LEGACY_RUNNER convention the shipped default describes." \
        "Refusing to append a scoping flag this project never declared: a flag the runner rejects would exit non-zero and be read as RED confirmed, and a flag it ignores would run the whole suite as if it were scoped." \
        "Set project.test_filter_template to the runner's own scoping form with a single {filter} placeholder (e.g. \"--filter {filter}\", \"-run {filter}\", \"-k {filter}\")."
    fi
    ;;
  *) die \
    "project.test_filter_template in $RR_CONFIG is unusable ($TPL_KIND) — it must be a non-empty string carrying one {filter} placeholder." \
    "This is not a runner that failed: the scoped run was never composed." ;;
esac

case "$FILTER_TEMPLATE" in
  *"{filter}"*) ;;
  *) die \
    "project.test_filter_template in $RR_CONFIG carries no {filter} placeholder: '$FILTER_TEMPLATE'." \
    "There is nowhere to put the scoped filter, and appending it blindly is the guess this template exists to replace." \
    "This is not a runner that failed: the scoped run was never composed." ;;
esac

FILTER_ARGV=()
read -r -a RR_TPL_TOKENS <<<"$FILTER_TEMPLATE"
for tok in "${RR_TPL_TOKENS[@]}"; do
  FILTER_ARGV+=("${tok//\{filter\}/$FILTER}")
done
[ "${#FILTER_ARGV[@]}" -gt 0 ] || die \
  "project.test_filter_template in $RR_CONFIG expands to no argument: '$FILTER_TEMPLATE'."

if [ -n "$EXPLICIT_COPY" ]; then
  TEST_FILES="$EXPLICIT_COPY"
  echo "red-run: copy set pinned by --copy; no derivation, no exclusions" >&2
else
  TEST_FILES=$( {
      git -C "$PROJECT_ROOT" diff --name-only "${BASE_SHA}..HEAD" -- "${RR_ROOT_PATHSPEC[@]}" 2>/dev/null || true
      git -C "$PROJECT_ROOT" diff --name-only HEAD -- "${RR_ROOT_PATHSPEC[@]}" 2>/dev/null || true
      git -C "$PROJECT_ROOT" ls-files --others --exclude-standard -- "${RR_ROOT_PATHSPEC[@]}" 2>/dev/null || true
    } | sort -u | grep -v '^$' || true)
fi

COPY_LIST=""
EXCLUDED=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  validate_copy_path "$rel"
  if [ -z "$EXPLICIT_COPY" ]; then
    case "
$RR_NEVER_COPY
" in
      *"
$rel
"*)
        echo "red-run: NOT copying $rel into the pre-change tree — it is test-harness infrastructure, not test input; copying it would run the new tests under changed support code" >&2
        EXCLUDED="${EXCLUDED}${rel} "
        continue
        ;;
    esac
  fi
  if [ ! -e "$PROJECT_ROOT/$rel" ] && [ ! -L "$PROJECT_ROOT/$rel" ]; then
    [ -n "$EXPLICIT_COPY" ] && die "--copy=$rel does not exist under $PROJECT_ROOT"
    continue
  fi
  if [ ! -f "$PROJECT_ROOT/$rel" ]; then
    [ -n "$EXPLICIT_COPY" ] && die "--copy=$rel exists under $PROJECT_ROOT but is not a regular file"
    continue
  fi
  COPY_LIST="${COPY_LIST}${rel}
"
done <<EOF
$TEST_FILES
EOF

[ -n "$COPY_LIST" ] || die \
  "$TASK_ID changes no copyable file under this project's test roots [$RR_ROOTS_LIST] (looked at ${BASE_SHA}..HEAD, the working tree, and untracked files)." \
  "There is nothing to red-run. If that is correct, record an enumerated N/A token instead." \
  "If the only changed test-tree file is the harness itself, pin the copy set with --copy=<path>."

SCRATCH_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-red-run-XXXXXX")
SCRATCH="$SCRATCH_PARENT/pre-change"
case "$SCRATCH" in
  "$PROJECT_ROOT"|"$PROJECT_ROOT"/*) die "refusing to build the scratch worktree inside the live tree" ;;
esac

rr_cleanup() {
  if [ -d "$SCRATCH" ]; then
    git -C "$PROJECT_ROOT" worktree remove --force "$SCRATCH" >/dev/null 2>&1 || rm -rf "$SCRATCH"
    git -C "$PROJECT_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$SCRATCH_PARENT" 2>/dev/null || true
}
trap rr_cleanup EXIT INT TERM

git -C "$PROJECT_ROOT" worktree add --detach --quiet "$SCRATCH" "$BASE_SHA" >/dev/null 2>&1 \
  || die "could not create a detached worktree at $BASE_SHA"
SCRATCH="$(cd "$SCRATCH" && pwd -P)"

COPIED=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  dest_dir="$SCRATCH/$(dirname "$rel")"
  mkdir -p "$dest_dir"
  dest_parent=$(cd "$dest_dir" && pwd -P) || die "cannot resolve scratch destination for $rel"
  rr_dir_under_roots "$dest_parent/" "$SCRATCH" || die \
    "scratch destination resolves outside the detached test roots [$RR_ROOTS_LIST]: $rel"
  cp "$PROJECT_ROOT/$rel" "$SCRATCH/$rel"
  COPIED=$((COPIED + 1))
done <<EOF
$COPY_LIST
EOF

if [ "${#RUNNER_ARGV[@]}" -eq 0 ]; then
  if [ -f "$SCRATCH/$RR_LEGACY_RUNNER" ]; then
    RUNNER_ARGV=("$RR_LEGACY_RUNNER")
    RUNNER_SOURCE="the $RR_LEGACY_RUNNER convention"
  else
    die \
      "no test runner could be determined for this project." \
      "project.test_command is not set in $RR_CONFIG, and the pre-change tree at $BASE_SHA has no $RR_LEGACY_RUNNER to fall back to." \
      "This is not a red run that failed — nothing was run at all. Set project.test_command, and project.test_filter_template beside it."
  fi
fi

RUNNER_BIN="${RUNNER_ARGV[0]}"
RUNNER_REL=""
RUNNER_NOTE=""

# The two rules that make a run a PRE-CHANGE run, applied to every runner that
# resolves inside this repository whatever spelling the config named it in.
rr_bind_pre_change_runner() {
  local rel="$1"
  case "/$rel/" in
    */../*|*/./*) die \
      "the runner named by $RUNNER_SOURCE escapes the pre-change tree: '$RUNNER_BIN' carries a '.' or '..' segment." \
      "Resolved from the detached worktree it would run a file from another tree — possibly the changed one, which is the vacuity this script exists to detect." \
      "This is not a red run that failed — nothing was run at all." ;;
  esac
  [ -f "$SCRATCH/$rel" ] || die \
    "the runner named by $RUNNER_SOURCE is absent from the pre-change tree: $BASE_SHA has no $rel." \
    "A runner that does not exist at the base commit cannot be run there; track it, or pin it into the copy set." \
    "This is not a red run that failed — nothing was run at all."
  # A tracked-but-not-executable runner is run under bash, as this script did
  # before the runner was configurable; the recorded command says which form ran.
  [ -x "$SCRATCH/$rel" ] || RUNNER_ARGV=(bash "${RUNNER_ARGV[@]}")
}

# Sets RUNNER_REL and returns 0 when an absolute path names a file inside this
# repository; 1 means it is genuinely elsewhere, which is the caller's to record.
rr_place_absolute_runner() {
  local abs="$1" dir rel
  case "$abs" in
    "$PROJECT_ROOT"/*)
      RUNNER_REL="${abs#"$PROJECT_ROOT"/}"
      return 0
      ;;
  esac
  # A prefix that does not match by string may still be the same directory
  # through a symlink, which TMPDIR is on macOS.
  dir=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P) || die \
    "the runner named by $RUNNER_SOURCE cannot be placed relative to the pre-change tree: '$abs' has no resolvable directory." \
    "Whether it names a file inside this repository, which must be run from the tree at $BASE_SHA, or a shared runner outside it cannot be decided — and guessing wrong runs the CHANGED runner while recording a pre-change red." \
    "This is not a red run that failed — nothing was run at all."
  case "$dir/" in
    "$PROJECT_ROOT"/*) ;;
    *) return 1 ;;
  esac
  rel="${dir#"$PROJECT_ROOT"}"
  rel="${rel#/}"
  if [ -n "$rel" ]; then
    RUNNER_REL="$rel/${abs##*/}"
  else
    RUNNER_REL="${abs##*/}"
  fi
  return 0
}

# The one record every spelling shares for a runner that is genuinely outside the
# pre-change tree: $1 is what will execute, $2 is how the spelling found it.
rr_record_external_runner() {
  local ran="$1" found="$2"
  RUNNER_NOTE="; runner resolved OUTSIDE the pre-change tree: $found — a shared runner no commit of this repository pins, run as configured"
  echo "red-run: WARNING — the runner named by $RUNNER_SOURCE resolves outside $PROJECT_ROOT, so the pre-change run executes $ran as it is now; only the tree it runs against is at $BASE_SHA. Recorded in the evidence block as such." >&2
}

case "$RUNNER_BIN" in
  /*)
    if rr_place_absolute_runner "$RUNNER_BIN"; then
      RUNNER_ARGV[0]="./$RUNNER_REL"
      RUNNER_NOTE="; absolute runner normalised into the pre-change tree as ./$RUNNER_REL"
      rr_bind_pre_change_runner "$RUNNER_REL"
    else
      [ -x "$RUNNER_BIN" ] || die \
        "the runner named by $RUNNER_SOURCE is not an executable file: $RUNNER_BIN." \
        "This is not a red run that failed — nothing was run at all."
      rr_record_external_runner "$RUNNER_BIN" "$RUNNER_BIN"
    fi
    ;;
  */*)
    RUNNER_REL="${RUNNER_BIN#./}"
    rr_bind_pre_change_runner "$RUNNER_REL"
    ;;
  *)
    RUNNER_ABS=$(command -v "$RUNNER_BIN" 2>/dev/null) || RUNNER_ABS=""
    [ -n "$RUNNER_ABS" ] || die \
      "the runner named by $RUNNER_SOURCE is not on PATH: '$RUNNER_BIN' cannot be executed here." \
      "This is not a red run that failed — nothing was run at all."
    # A bare name that PATH resolves into this repository is the same hazard in a
    # third spelling: run the pre-change copy, not whatever PATH found live.
    case "$RUNNER_ABS" in
      /*)
        if rr_place_absolute_runner "$RUNNER_ABS"; then
          RUNNER_ARGV[0]="./$RUNNER_REL"
          RUNNER_NOTE="; PATH resolved '$RUNNER_BIN' inside this repository — normalised into the pre-change tree as ./$RUNNER_REL"
          rr_bind_pre_change_runner "$RUNNER_REL"
        else
          rr_record_external_runner "$RUNNER_ABS" "PATH resolved '$RUNNER_BIN' to $RUNNER_ABS"
        fi
        ;;
      *)
        rr_record_external_runner "$RUNNER_ABS" "'$RUNNER_BIN' resolved to the shell builtin '$RUNNER_ABS', not to any file"
        ;;
    esac
    ;;
esac

if [ -n "$RUNNER_REL" ]; then
  case "
$COPY_LIST
" in
    *"
$RUNNER_REL
"*) echo "red-run: WARNING — the copy set carries $RUNNER_REL, the resolved runner; the pre-change run will execute the CHANGED runner, so both a fabricated red and a vacuous green are possible. Pin the set with --copy= to exclude it." >&2 ;;
  esac
fi

RUN_CMD="${RUNNER_ARGV[*]} ${FILTER_ARGV[*]}"
rr_screen_command "$RUN_CMD"

OUT_FILE="$SCRATCH_PARENT/run.log"
STARTED=$(date +%s)
set +e
( cd "$SCRATCH" && "${RUNNER_ARGV[@]}" "${FILTER_ARGV[@]}" </dev/null ) >"$OUT_FILE" 2>&1
RUN_EC=$?
set -e
ELAPSED=$(( $(date +%s) - STARTED ))

RUN_TAIL=$(tail -n 25 "$OUT_FILE" || true)

if [ "$RUN_EC" -eq 0 ]; then
  die_code 2 \
    "VACUOUS TEST — the pre-change run PASSED." \
    "$RUN_CMD exited 0 against the tree at $BASE_SHA, where this task's" \
    "change does not exist. A test that passes without the change under test is evidence of nothing." \
    "No evidence block was written. Rewrite the test so it fails for the reason the change fixes." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
fi
if [ "$RUN_EC" -eq 2 ]; then
  die_code 3 \
    "NOTHING CHECKED — the scoped filter matched no test files in the pre-change tree." \
    "$RUN_CMD exited 2 at $BASE_SHA after $COPIED file(s) were copied in." \
    "This is not a red run: nothing ran. Check the filter spelling against the copied test file names." \
    "No evidence block was written." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
fi
if [ "$RUN_EC" -eq 3 ]; then
  die_code 4 \
    "the pre-change harness reported an internal coverage-accounting defect (exit 3)." \
    "Its own scanned/skipped/checked counts disagree, so its verdict cannot be trusted as a red run." \
    "No evidence block was written." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
fi

# A runner reports a failing test by BASENAME; the copy set holds the root it
# actually came from, so the recorded path is looked up rather than reconstructed.
rr_rel_for_name() {
  local name="$1" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "${rel##*/}" = "$name" ]; then
      printf '%s' "$rel"
      return 0
    fi
  done <<EOF
$COPY_LIST
EOF
  return 1
}

# Last rung of the identification ladder: a non-zero exit earns a red only if the
# output at least NAMES a copied test file, so "nothing ran" cannot read as red.
rr_names_mentioned_in_output() {
  local rel name
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    name="${rel##*/}"
    if grep -qF -e "$name" "$OUT_FILE"; then
      printf '%s\n' "$name"
    fi
  done <<EOF
$COPY_LIST
EOF
}

first_fail_for() {
  awk -v h="=== ${1} ===" '$0==h{f=1;next} /^=== /{f=0} f' "$OUT_FILE" \
    | grep -m1 -E '^[[:space:]]*FAIL:' || true
}

GLOBAL_FIRST_FAIL=$(grep -m1 -E '^[[:space:]]*FAIL:' "$OUT_FILE" || true)

FAILED_NAMES=$(awk '/^Failed test files:/{f=1;next} f && /^[[:space:]]*$/{f=0} f' "$OUT_FILE" \
  | sed -E 's/^[[:space:]]*-[[:space:]]*//' | grep -v '^$' || true)

if [ -n "$FAILED_NAMES" ]; then
  COPIED_FAILED_NAMES=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if rr_rel_for_name "$name" >/dev/null; then
      COPIED_FAILED_NAMES="${COPIED_FAILED_NAMES}${name}
"
    else
      echo "red-run: ignoring reported failure outside the copied test set: $name" >&2
    fi
  done <<EOF
$FAILED_NAMES
EOF
  [ -n "$COPIED_FAILED_NAMES" ] || die_code 6 \
    "INDETERMINATE RESULT — the pre-change run exited $RUN_EC, but none of its reported failing test files belongs to the copied test set." \
    "Refusing unrelated evidence. No evidence block was written." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
  FAILED_NAMES="$COPIED_FAILED_NAMES"
elif [ -n "$GLOBAL_FIRST_FAIL" ]; then
  echo "red-run: the pre-change run exited $RUN_EC and reported a failing case but named no failed test file — falling back to the copied files matching '$FILTER'" >&2
  FAILED_NAMES=$(printf '%s' "$COPY_LIST" | sed -E 's%^.*/%%' | grep -F -e "$FILTER" || true)
else
  FAILED_NAMES=$(rr_names_mentioned_in_output)
  [ -n "$FAILED_NAMES" ] || die_code 6 \
    "INDETERMINATE RESULT — the runner exited $RUN_EC, but nothing identifiable ran." \
    "$RUN_CMD named no failing test file, no failing case, and not one of the ${COPIED} copied test file(s) by name." \
    "A non-zero exit alone is not a red: pytest exits 5 when it collects NO tests, go test exits 2 on a build failure, and a rejected flag exits non-zero too." \
    "Writing an entry here would record a red for a run in which nothing executed. No evidence block was written." \
    "If the runner really did fail this task's test, make it name the file or the case; see docs/CONFIGURATION.md for the exit-code contract." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
  echo "red-run: the pre-change run named no failing case; identifying the red from the copied test file(s) its output names" >&2
fi
[ -n "$FAILED_NAMES" ] || die_code 6 \
  "INDETERMINATE RESULT — the pre-change run exited $RUN_EC but no failing test file could be identified." \
  "Refusing to write an entry naming nothing. No evidence block was written."

ENTRIES=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  stem="${name%.sh}"
  fail_line=$(first_fail_for "$stem")
  [ -n "$fail_line" ] || fail_line="$GLOBAL_FIRST_FAIL"
  if [ -n "$fail_line" ]; then
    case_name=$(printf '%s' "$fail_line" | sed -E 's/^[[:space:]]*FAIL:[[:space:]]*//')
    result_detail="\"FAIL: ${case_name}\""
  else
    case_name="(no FAIL: line reported)"
    result_detail="the file exited non-zero without naming a case"
  fi
  rel_path=$(rr_rel_for_name "$name") || die \
    "the pre-change run named $name, which is not in the copied test set — refusing to record a path this capture did not produce"
  if [ ! -f "$PROJECT_ROOT/$rel_path" ]; then
    echo "red-run: WARNING — $rel_path does not exist in the live tree; the evidence gate will reject this entry" >&2
  fi
  ENTRIES="${ENTRIES}- red-run: ${rel_path} :: case \"${case_name}\"
  - pre-change-ref: ${BASE_SHA}
  - result: FAILED (exit ${RUN_EC}) — ${result_detail}
  - captured-by: scripts/red-run.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
"
done <<EOF
$FAILED_NAMES
EOF

CAPTURE_NOTE=""
[ -n "$EXCLUDED" ] && CAPTURE_NOTE="; NOT copied (harness, not test input): ${EXCLUDED% }"
[ -n "$EXPLICIT_COPY" ] && CAPTURE_NOTE="; copy set pinned by --copy"

BLOCK="${BEGIN_MARK}
- capture: \`${RUN_CMD}\` in a detached worktree at \`${BASE_SHA}\`; ${COPIED} changed test file(s) copied in${CAPTURE_NOTE}${RUNNER_NOTE}; runner exit ${RUN_EC} in ${ELAPSED}s
${ENTRIES}${END_MARK}"

# In-place file write, never `mv`/`cp` over a manifest: the bash-write
# reconciliation pass reads manifests as state, and rightly flags a swap.
rr_write_block() {
  local has_section=0 has_marker=0 skipping=0 inserted=0 out="" line
  if grep -q '^## Red-Run Evidence' "$MANIFEST"; then has_section=1; fi
  if grep -qF "$BEGIN_MARK" "$MANIFEST"; then has_marker=1; fi

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$has_marker" -eq 1 ]; then
      if [ "$line" = "$BEGIN_MARK" ]; then
        out="${out}${BLOCK}
"
        skipping=1
        inserted=1
        continue
      fi
      if [ "$skipping" -eq 1 ]; then
        [ "$line" = "$END_MARK" ] && skipping=0
        continue
      fi
    fi
    out="${out}${line}
"
    if [ "$has_marker" -eq 0 ] && [ "$has_section" -eq 1 ] && [ "$inserted" -eq 0 ]; then
      case "$line" in
        "## Red-Run Evidence"*)
          out="${out}${BLOCK}
"
          inserted=1
          ;;
      esac
    fi
  done < "$MANIFEST"

  if [ "$inserted" -eq 0 ]; then
    out="${out}
## Red-Run Evidence
${BLOCK}
"
  fi
  printf '%s' "$out" > "$MANIFEST"
}

rr_write_block

echo "red-run: RED confirmed for $TASK_ID — filter '$FILTER' exited $RUN_EC at $BASE_SHA in ${ELAPSED}s"
echo "red-run: ${COPIED} changed test file(s) copied into the pre-change worktree; evidence written to $MANIFEST"
exit 0
