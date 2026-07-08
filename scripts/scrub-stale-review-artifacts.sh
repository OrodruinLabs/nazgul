#!/usr/bin/env bash
set -euo pipefail

# scrub-stale-review-artifacts.sh — archive+clear a superseded objective's
# transient review/learning artifacts before /nazgul:plan starts a new one.
# Prevents stale nazgul/reviews/ verdicts and nazgul/learning/proposed-rules.md
# from a completed objective being read as current by the new one.
# Usage: scrub-stale-review-artifacts.sh --for-new-objective FEAT-ID [nazgul_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/task-utils.sh
source "$SCRIPT_DIR/lib/task-utils.sh"

FOR_FEAT_ID=""
NAZGUL_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --for-new-objective) FOR_FEAT_ID="$2"; shift 2 ;;
    *) NAZGUL_DIR="$1"; shift ;;
  esac
done

NAZGUL_DIR="${NAZGUL_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul}"

if [ -z "$FOR_FEAT_ID" ]; then
  echo "Usage: $0 --for-new-objective FEAT-ID [nazgul_dir]" >&2
  exit 1
fi

if [ ! -d "$NAZGUL_DIR" ]; then
  exit 0
fi

# Guard: never scrub while any task is open — that means an objective (the
# new one or, if called by mistake, an old one) still has live work in it.
OPEN_TASKS=0
if [ -d "$NAZGUL_DIR/tasks" ]; then
  for status in READY IN_PROGRESS IN_REVIEW IMPLEMENTED CHANGES_REQUESTED; do
    OPEN_TASKS=$((OPEN_TASKS + $(count_tasks_by_status "$NAZGUL_DIR/tasks" "$status")))
  done
fi
if [ "$OPEN_TASKS" -gt 0 ]; then
  echo "scrub-stale-review-artifacts: refusing — $OPEN_TASKS open task(s) found; an objective is still active." >&2
  exit 0
fi

STALE_REVIEWS=0
shopt -s nullglob
review_entries=("$NAZGUL_DIR"/reviews/*)
shopt -u nullglob
[ "${#review_entries[@]}" -gt 0 ] && STALE_REVIEWS=1

STALE_LEARNING=()
for rel in learning/proposed-rules.md learning/.distilled logs/.docs-verified; do
  [ -f "$NAZGUL_DIR/$rel" ] && STALE_LEARNING+=("$rel")
done

if [ "$STALE_REVIEWS" -eq 0 ] && [ "${#STALE_LEARNING[@]}" -eq 0 ]; then
  echo "scrub-stale-review-artifacts: nothing stale to scrub."
  exit 0
fi

ARCHIVE_DIR="$NAZGUL_DIR/archive/$(date -u +%Y-%m-%d-%H%M%S)-pre-${FOR_FEAT_ID}"
mkdir -p "$ARCHIVE_DIR"

if [ "$STALE_REVIEWS" -eq 1 ]; then
  mkdir -p "$ARCHIVE_DIR/reviews"
  mv "$NAZGUL_DIR"/reviews/* "$ARCHIVE_DIR/reviews/"
fi

if [ "${#STALE_LEARNING[@]}" -gt 0 ]; then
  for rel in "${STALE_LEARNING[@]}"; do
    mkdir -p "$ARCHIVE_DIR/$(dirname "$rel")"
    mv "$NAZGUL_DIR/$rel" "$ARCHIVE_DIR/$rel"
  done
fi

mkdir -p "$NAZGUL_DIR/reviews"

echo "scrub-stale-review-artifacts: archived stale artifacts to $ARCHIVE_DIR"
