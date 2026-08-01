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
# TASK-001 shipped the engine plus checks (b), (f), (g). TASK-002 added
# checks (a), (c), (d). This task (TASK-003) adds check (e).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/nazgul-root.sh
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=lib/git-hooks.sh
source "$SCRIPT_DIR/lib/git-hooks.sh"

# Captured before this script's own NAZGUL_DIR assignment below shadows it —
# check (e) needs to know what the OPERATOR's environment held, not what
# doctor.sh's own local variable of the same conventional name becomes.
_DOC_OPERATOR_NAZGUL_DIR="${NAZGUL_DIR:-}"

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

# _doc_json_field <file> <jq-filter> — reads an arbitrary JSON file, printing
# "" when the file is absent, unreadable, or the filter errors or resolves
# to null. Same graceful-degradation contract as _doc_cfg, for files other
# than nazgul/config.json (namely plugin.json).
_doc_json_field() {
  local file="$1" filter="$2" out
  if [ ! -f "$file" ]; then
    printf ''
    return 0
  fi
  out="$(jq -r "$filter" "$file" 2>/dev/null)" || out=""
  if [ "$out" = "null" ]; then
    out=""
  fi
  printf '%s' "$out"
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

# (a) Cache-vs-repo version trap: compares the ACTIVE plugin's
# plugin.json version ($CLAUDE_PLUGIN_ROOT) against this checkout's own —
# only when the project is plugin-repo-shaped (install_mode local, or this
# cwd IS a plugin repo). A documented workaround (ADR-016 Decision 2): no
# platform API exists for live-vs-installed version comparison. Detection
# uses CLAUDE_PLUGIN_ROOT only; the cache path appears in remediation text.
check_plugin_version() {
  local install_mode plugin_repo_here="false"
  install_mode="$(_doc_cfg '.install_mode // ""' '')"
  if [ -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ]; then
    plugin_repo_here="true"
  fi

  if [ "$install_mode" != "local" ] && [ "$plugin_repo_here" != "true" ]; then
    _doc_report pass plugin-version "Not applicable — install_mode is not 'local' and $PROJECT_ROOT is not a plugin repo (no .claude-plugin/plugin.json)."
    return 0
  fi

  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    _doc_report pass plugin-version "Not applicable — CLAUDE_PLUGIN_ROOT is unset, so there is no active plugin instance to compare against (e.g. running under a test harness)."
    return 0
  fi

  local active_json="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
  local repo_json="$PROJECT_ROOT/.claude-plugin/plugin.json"
  local active_version repo_version
  active_version="$(_doc_json_field "$active_json" '.version // ""')"
  repo_version="$(_doc_json_field "$repo_json" '.version // ""')"

  if [ -z "$active_version" ] || [ -z "$repo_version" ]; then
    _doc_report pass plugin-version "Not applicable — could not read a .version field from $active_json or $repo_json."
    return 0
  fi

  if [ "$active_version" = "$repo_version" ]; then
    _doc_report pass plugin-version "Active plugin version ($active_version, from CLAUDE_PLUGIN_ROOT) matches the local checkout ($repo_version)."
  else
    _doc_report warn plugin-version "Active plugin ($active_version, loaded via CLAUDE_PLUGIN_ROOT) differs from the local checkout ($repo_version). This comparison is a documented workaround, not a platform API — no platform API exists for live-vs-installed plugin version comparison. Cached plugin versions persist roughly 14 days under ~/.claude/plugins/cache/<org>/<plugin>/<version>/ — reload this session (or restart Claude Code) so repo edits are actually live before assuming they are."
  fi
}

# (c) Git hooks actually installed: only when guards.git_hooks is true,
# core.hooksPath must point at the managed dir and both guard hooks must
# exist there. Reports drift; never writes core.hooksPath (ADR-016
# Decision 1) — reuses git-hooks.sh's own constants/read so the two never
# disagree on what "managed" means.
check_git_hooks() {
  if [ "$(_doc_cfg '.guards.git_hooks // false' 'false')" != "true" ]; then
    _doc_report pass git-hooks "Not applicable — guards.git_hooks is false."
    return 0
  fi

  local current
  current="$(_gh_current_hooks_path "$PROJECT_ROOT")"

  if [ "$current" != "$_GH_MANAGED_RELDIR" ]; then
    _doc_report warn git-hooks "core.hooksPath is '${current:-<unset>}', not the Nazgul-managed '$_GH_MANAGED_RELDIR' — the guard hooks are NOT active. A new session's SessionStart self-heal re-asserts it, or run: git -C $PROJECT_ROOT config core.hooksPath $_GH_MANAGED_RELDIR"
    return 0
  fi

  local missing="" hook
  for hook in "${_GH_OWN_HOOKS[@]}"; do
    if [ ! -f "$PROJECT_ROOT/$_GH_MANAGED_RELDIR/$hook" ]; then
      missing="$missing $hook"
    fi
  done

  if [ -n "$missing" ]; then
    _doc_report warn git-hooks "core.hooksPath is correctly '$_GH_MANAGED_RELDIR' but is missing guard hook(s):$missing — re-run the git-hooks install (a new session's SessionStart self-heal re-asserts it)."
  else
    _doc_report pass git-hooks "core.hooksPath is '$_GH_MANAGED_RELDIR' and both guard hooks (${_GH_OWN_HOOKS[*]}) are present."
  fi
}

# _doc_detect_shell — best-effort, never fatal: prefers $BASH_VERSION, falls
# back to `ps -p $$ -o comm=`, then $SHELL. NAZGUL_TEST_SHELL_NAME lets tests
# simulate a non-bash invocation deterministically — a real non-bash
# interpreter can't run this script's array syntax far enough to reach this
# check, so it can't be exercised by literally invoking under one. Real
# invocations never set it.
_doc_detect_shell() {
  if [ -n "${NAZGUL_TEST_SHELL_NAME:-}" ]; then
    printf '%s' "$NAZGUL_TEST_SHELL_NAME"
    return 0
  fi
  if [ -n "${BASH_VERSION:-}" ]; then
    printf '%s' "bash"
    return 0
  fi
  local comm
  comm="$(ps -p $$ -o comm= 2>/dev/null)" || comm=""
  comm="${comm##*/}"
  if [ -n "$comm" ]; then
    printf '%s' "$comm"
    return 0
  fi
  printf '%s' "${SHELL##*/}"
}

# (d) bash-vs-zsh hazard: whenever doctor itself is not running under bash,
# warn — scripts/worktree-utils.sh's managed-hooks install silently no-ops
# when sourced from a non-bash shell. Inherently approximate (TRD Risks
# row 4): fails toward warn-with-caveat, never a hard fail.
check_invoking_shell() {
  local shell_name
  shell_name="$(_doc_detect_shell)"
  if [ "$shell_name" = "bash" ]; then
    _doc_report pass invoking-shell "Doctor is running under bash."
  else
    _doc_report warn invoking-shell "Detected a non-bash invoking shell ('$shell_name', best-effort detection). scripts/worktree-utils.sh's managed-hooks install silently no-ops when sourced from a non-bash shell — wrap it: bash -c 'source scripts/worktree-utils.sh; install_git_hooks ...'"
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

# (e) NAZGUL_DIR footgun (ADR-016 Decision 3, option (b) — documentation
# only, no override is honored): scripts/lib/nazgul-root.sh never reads
# NAZGUL_DIR; only CLAUDE_PROJECT_DIR redirects resolution. Warns when
# NAZGUL_DIR is set in the live environment — a strong signal the operator
# is about to repeat the FEAT-024/TASK-008 leak.
check_nazgul_dir_env() {
  if [ -n "$_DOC_OPERATOR_NAZGUL_DIR" ]; then
    _doc_report warn nazgul-dir-env "NAZGUL_DIR is set ('$_DOC_OPERATOR_NAZGUL_DIR') but scripts/lib/nazgul-root.sh never reads it — it has NO effect on resolution. CLAUDE_PROJECT_DIR is the one seam that actually isolates nazgul/ resolution: use 'CLAUDE_PROJECT_DIR=$_DOC_OPERATOR_NAZGUL_DIR ...' instead of 'NAZGUL_DIR=$_DOC_OPERATOR_NAZGUL_DIR ...'."
  else
    _doc_report pass nazgul-dir-env "NAZGUL_DIR is not set. CLAUDE_PROJECT_DIR is the one environment variable that redirects nazgul/ resolution."
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
  check_plugin_version
  check_dependencies
  check_git_hooks
  check_invoking_shell
  check_nazgul_dir_env
  check_config_schema
  check_stdin_hazard
  exit "$_DOC_WORST"
}

main "$@"
