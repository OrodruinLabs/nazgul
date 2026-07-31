#!/usr/bin/env bash
set -euo pipefail

# Nazgul read-only preflight diagnostic (FEAT-025 / ADR-016). Runs each check
# as an independent function that reports through _doc_report, so one failing
# check never aborts the run under set -e. Emits one line per check to stdout:
#   <verdict>\t<check-id>\t<message>
# verdict is pass|warn|fail|note. "note" (check (g)) never affects the
# aggregate exit code. Aggregate exit: 0 all pass, 1 worst is warn, 2 worst is
# fail. Doctor never writes to nazgul/, git config, or anywhere under
# PROJECT_ROOT — its only fix path is the remediation text in each message.
#
# TASK-002/TASK-003 add checks (a)/(c)/(d)/(e) to this same file as additional
# check_* functions called from main() — this task ships the engine plus
# checks (b), (f), (g).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"

PROJECT_ROOT="$(resolve_project_root)"
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

_DOC_WORST=0

_doc_report() {
  local verdict="$1" check_id="$2" message="$3"
  printf '%s\t%s\t%s\n' "$verdict" "$check_id" "$message"
  case "$verdict" in
    warn) if [ "$_DOC_WORST" -lt 1 ]; then _DOC_WORST=1; fi ;;
    fail) _DOC_WORST=2 ;;
  esac
}

# _doc_cfg <jq-filter> <default> — reads nazgul/config.json, falling back to
# <default> when config is absent, unreadable, or the filter errors.
_doc_cfg() {
  local filter="$1" default="$2" out
  if [ ! -f "$CONFIG" ]; then
    printf '%s' "$default"
    return 0
  fi
  out="$(jq -r "$filter" "$CONFIG" 2>/dev/null)" || out=""
  if [ -z "$out" ] || [ "$out" = "null" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$out"
  fi
}

check_config_present() {
  if [ -f "$CONFIG" ] && [ -r "$CONFIG" ]; then
    _doc_report pass config-present "nazgul/config.json found at $CONFIG"
  else
    _doc_report warn config-present "No nazgul/config.json under $NAZGUL_DIR — this project has not run /nazgul:init yet. Every check below that does not require config still ran. Run /nazgul:init to initialize."
  fi
}

# (b) Dependencies: jq (hard requirement), gh (only when connectors.github or
# board sync is enabled), and gh auth status when gh is actually needed.
check_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    _doc_report fail dependencies "jq is not on PATH — jq is a hard runtime dependency for every Nazgul script. Install it (e.g. 'brew install jq') and re-run /nazgul:doctor."
    return 0
  fi

  local need_gh="false"
  if [ "$(_doc_cfg '.connectors.github.enabled // false' 'false')" = "true" ]; then
    need_gh="true"
  fi
  if [ "$(_doc_cfg '.board.enabled // false' 'false')" = "true" ]; then
    need_gh="true"
  fi

  if ! command -v gh >/dev/null 2>&1; then
    if [ "$need_gh" = "true" ]; then
      _doc_report warn dependencies "gh is not on PATH but connectors.github.enabled or board.enabled is true — install the GitHub CLI ('brew install gh') and run 'gh auth login'."
    else
      _doc_report pass dependencies "jq found; gh not found but not required (connectors.github.enabled and board.enabled are both false)."
    fi
    return 0
  fi

  if [ "$need_gh" != "true" ]; then
    _doc_report pass dependencies "jq and gh both found on PATH."
    return 0
  fi

  if gh auth status >/dev/null 2>&1; then
    _doc_report pass dependencies "jq and gh found; gh is authenticated."
  else
    _doc_report warn dependencies "gh is installed but not authenticated — run 'gh auth login' before using connectors.github or board sync."
  fi
}

# (f) Config-schema staleness: live schema_version vs the highest migrate_N_to_M
# target defined in migrate-config.sh, read as text (never sourced).
check_config_schema() {
  if [ ! -f "$CONFIG" ]; then
    _doc_report pass config-schema "No nazgul/config.json to check yet — run /nazgul:init first."
    return 0
  fi

  local live highest
  live="$(_doc_cfg '.schema_version // 1' '1')"
  case "$live" in ''|*[!0-9]*) live=1 ;; esac

  highest="$( { grep -oE 'migrate_[0-9]+_to_[0-9]+' "$SCRIPT_DIR/migrate-config.sh" 2>/dev/null || true; } \
    | sed -E 's/^migrate_[0-9]+_to_//' | sort -n | tail -1 )" || highest=""
  case "$highest" in ''|*[!0-9]*) highest="$live" ;; esac

  if [ "$live" -lt "$highest" ]; then
    _doc_report warn config-schema "nazgul/config.json schema_version $live is behind the latest migration target $highest — run scripts/migrate-config.sh to bring it current."
  else
    _doc_report pass config-schema "nazgul/config.json schema_version $live is current (latest migration target: $highest)."
  fi
}

# (g) Never-EOF stdin hazard: an unconditional advisory note, not a scored
# check — routed through _doc_report with verdict "note" so it shares the
# same output shape without touching the aggregate exit code.
check_stdin_hazard() {
  _doc_report note stdin-hazard "Hook scripts that read stdin via 'cat' without a bounded, non-tty-aware guard can block forever under a non-tty, never-EOF stdin (see nazgul/inbox/test-harness-stdin-hang-and-serial-runtime.md). Informational only; does not affect this run's exit code."
}

main() {
  check_config_present
  check_dependencies
  check_config_schema
  check_stdin_hazard
  exit "$_DOC_WORST"
}

main "$@"
