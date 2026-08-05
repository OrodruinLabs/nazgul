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
# The copy set defaults to the task's changed files under `tests/` MINUS the
# harness itself: copying a changed `tests/run-tests.sh` into the pre-change tree
# would run the new tests under the changed runner, which is the change being
# present — the exact vacuity this script exists to detect. `--copy=` (repeatable)
# pins the set explicitly and suppresses derivation entirely.
#
# Exit codes:
#   0  RED confirmed — the evidence block was written
#   1  usage or environment error — nothing written
#   2  VACUOUS — the pre-change run PASSED (exit 0); nothing written
#   3  NOTHING MATCHED — the scoped filter matched no test file in the pre-change tree
#   4  the pre-change harness reported an internal coverage-accounting defect

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

# Files under tests/ that are implementation, not test input: never copied into
# the pre-change tree by the derived set.
RR_NEVER_COPY="tests/run-tests.sh
tests/lib/assertions.sh
tests/lib/setup.sh"

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
  case "$rel" in
    tests/*) ;;
    *) die "copy path must be repository-relative and under tests/: $rel" ;;
  esac
  case "/$rel/" in
    */../*|*/./*) die "copy path must not contain '.' or '..' segments: $rel" ;;
  esac

  source="$PROJECT_ROOT/$rel"
  [ -f "$source" ] || return 0
  [ ! -L "$source" ] || die "copy path must not be a symlink: $rel"
  parent=$(cd "$(dirname "$source")" && pwd -P) || die "cannot resolve copy path parent: $rel"
  case "$parent/" in
    "$PROJECT_ROOT/tests/"*) ;;
    *) die "copy path resolves outside the repository tests/ tree: $rel" ;;
  esac
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

if [ -n "$EXPLICIT_COPY" ]; then
  TEST_FILES="$EXPLICIT_COPY"
  echo "red-run: copy set pinned by --copy; no derivation, no exclusions" >&2
else
  TEST_FILES=$( {
      git -C "$PROJECT_ROOT" diff --name-only "${BASE_SHA}..HEAD" -- tests/ 2>/dev/null || true
      git -C "$PROJECT_ROOT" diff --name-only HEAD -- tests/ 2>/dev/null || true
      git -C "$PROJECT_ROOT" ls-files --others --exclude-standard -- tests/ 2>/dev/null || true
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
  "$TASK_ID changes no copyable file under tests/ (looked at ${BASE_SHA}..HEAD, the working tree, and untracked files)." \
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
  case "$dest_parent/" in
    "$SCRATCH/tests/"*) ;;
    *) die "scratch destination resolves outside the detached tests/ tree: $rel" ;;
  esac
  cp "$PROJECT_ROOT/$rel" "$SCRATCH/$rel"
  COPIED=$((COPIED + 1))
done <<EOF
$COPY_LIST
EOF

[ -f "$SCRATCH/tests/run-tests.sh" ] || die \
  "the pre-change tree at $BASE_SHA has no tests/run-tests.sh — nothing can be run there"

OUT_FILE="$SCRATCH_PARENT/run.log"
STARTED=$(date +%s)
set +e
( cd "$SCRATCH" && bash tests/run-tests.sh --filter="$FILTER" </dev/null ) >"$OUT_FILE" 2>&1
RUN_EC=$?
set -e
ELAPSED=$(( $(date +%s) - STARTED ))

RUN_TAIL=$(tail -n 25 "$OUT_FILE" || true)

if [ "$RUN_EC" -eq 0 ]; then
  die_code 2 \
    "VACUOUS TEST — the pre-change run PASSED." \
    "tests/run-tests.sh --filter=$FILTER exited 0 against the tree at $BASE_SHA, where this task's" \
    "change does not exist. A test that passes without the change under test is evidence of nothing." \
    "No evidence block was written. Rewrite the test so it fails for the reason the change fixes." \
    "--- last lines of the pre-change run ---" \
    "$RUN_TAIL"
fi
if [ "$RUN_EC" -eq 2 ]; then
  die_code 3 \
    "NOTHING CHECKED — the scoped filter matched no test files in the pre-change tree." \
    "tests/run-tests.sh --filter=$FILTER exited 2 at $BASE_SHA after $COPIED file(s) were copied in." \
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
    if grep -qFx -e "tests/$name" <<<"$COPY_LIST"; then
      COPIED_FAILED_NAMES="${COPIED_FAILED_NAMES}${name}
"
    else
      echo "red-run: ignoring reported failure outside the copied test set: tests/$name" >&2
    fi
  done <<EOF
$FAILED_NAMES
EOF
  [ -n "$COPIED_FAILED_NAMES" ] || die \
    "the pre-change run exited $RUN_EC, but none of its reported failing test files belongs to the copied test set — refusing unrelated evidence"
  FAILED_NAMES="$COPIED_FAILED_NAMES"
else
  echo "red-run: the pre-change run exited $RUN_EC but named no failed test file — falling back to the copied files matching '$FILTER'" >&2
  FAILED_NAMES=$(printf '%s' "$COPY_LIST" | sed -E 's%^.*/%%' | grep -F -e "$FILTER" || true)
fi
[ -n "$FAILED_NAMES" ] || die \
  "the pre-change run exited $RUN_EC but no failing test file could be identified — refusing to write an entry naming nothing"

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
  rel_path="tests/$name"
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
- capture: \`tests/run-tests.sh --filter=${FILTER}\` in a detached worktree at \`${BASE_SHA}\`; ${COPIED} changed test file(s) copied in${CAPTURE_NOTE}; runner exit ${RUN_EC} in ${ELAPSED}s
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
