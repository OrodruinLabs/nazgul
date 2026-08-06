#!/usr/bin/env bash
set -euo pipefail

# Transactional task-state writer (ADR-020). Under a per-task lock, a successful
# invocation validates one staged snapshot, rechecks the source immediately
# before an atomic rename, verifies the target on disk, and only then records
# transition authority. The lock serializes authoritative transition writers;
# it is not claimed to make an unrelated raw filesystem write transactional.

usage() {
  echo "Usage: scripts/task-transition.sh transition TASK-NNN FROM TO [--reason TEXT|--reason=TEXT]" >&2
}

[ "$#" -ge 4 ] || { usage; exit 1; }
[ "$1" = "transition" ] || { usage; exit 1; }
TASK_ID="$2"
FROM_STATUS="$3"
TO_STATUS="$4"
shift 4

REASON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason=*) REASON="${1#--reason=}"; shift ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; echo "task-transition: --reason requires a value" >&2; exit 1; }
      REASON="$2"
      shift 2
      ;;
    *) usage; echo "task-transition: unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$REASON" in
  *$'\n'*|*$'\r'*)
    echo "task-transition: --reason must be one line" >&2
    exit 1
    ;;
esac
if [ -n "$REASON" ] && [ "$TO_STATUS" != "BLOCKED" ]; then
  echo "task-transition: --reason is only valid when TO is BLOCKED" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-transition-guard.sh
source "$SCRIPT_DIR/lib/task-transition-guard.sh"

PROJECT_ROOT="$(resolve_project_root)"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
  echo "task-transition: project root does not exist" >&2
  exit 1
}
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
[ -f "$NAZGUL_DIR/config.json" ] && [ ! -L "$NAZGUL_DIR/config.json" ] \
  && jq -e 'type == "object"' "$NAZGUL_DIR/config.json" >/dev/null 2>&1 || {
  echo "task-transition: no valid regular non-symlink Nazgul config at $NAZGUL_DIR/config.json" >&2
  exit 1
}

if ! ttg_apply_transition "$NAZGUL_DIR" "$PROJECT_ROOT" \
  "$TASK_ID" "$FROM_STATUS" "$TO_STATUS" "$REASON"; then
  echo "task-transition: ${TASK_ID} did not complete ${FROM_STATUS} -> ${TO_STATUS}" >&2
  exit 1
fi

echo "task-transition: ${TASK_ID} ${FROM_STATUS} -> ${TO_STATUS} completed and recorded"
