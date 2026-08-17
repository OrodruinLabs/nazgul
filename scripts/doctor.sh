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
# The last stdout line is the TRD §6 coverage line; a check with nothing to
# inspect is reported through _doc_skip, not folded into the checked count.
#
# TASK-001 shipped the engine plus checks (b), (f), (g). TASK-002 added
# checks (a), (c), (d). TASK-003 added check (e). FEAT-027/TASK-009 adds
# checks (h), (i). FEAT-032/TASK-009 adds (k) messaging, (l) remote-control,
# and (m) sessions — all three read env, settings files, and lock files only,
# and NEVER connect to the messaging socket.

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

_DOC_SCANNED=0
_DOC_CHECKED=0
_DOC_FINDINGS=0
_DOC_SKIP_NA_CONFIG=0
_DOC_SKIP_NA_ENV=0
_DOC_SKIP_NO_CANDIDATES=0
_DOC_SKIP_UNREADABLE=0

_doc_emit() {
  local verdict="$1" check_id="$2" message="$3"
  printf '%s\t%s\t%s\n' "$verdict" "$check_id" "$message"
  _DOC_SCANNED=$((_DOC_SCANNED + 1))
  case "$verdict" in
    warn) _DOC_FINDINGS=$((_DOC_FINDINGS + 1)); if [ "$_DOC_WORST" -lt 1 ]; then _DOC_WORST=1; fi ;;
    fail) _DOC_FINDINGS=$((_DOC_FINDINGS + 1)); _DOC_WORST=2 ;;
  esac
}

_doc_report() {
  _DOC_CHECKED=$((_DOC_CHECKED + 1))
  _doc_emit "$@"
}

# _doc_skip <verdict> <check-id> <reason> <message> — a check with nothing to
# inspect. An unenumerated reason is announced and counted as CHECKED (TRD §6).
_doc_skip() {
  local verdict="$1" check_id="$2" reason="$3" message="$4"
  case "$reason" in
    not-applicable-config) _DOC_SKIP_NA_CONFIG=$((_DOC_SKIP_NA_CONFIG + 1)) ;;
    not-applicable-env)    _DOC_SKIP_NA_ENV=$((_DOC_SKIP_NA_ENV + 1)) ;;
    no-candidates)         _DOC_SKIP_NO_CANDIDATES=$((_DOC_SKIP_NO_CANDIDATES + 1)) ;;
    unreadable)            _DOC_SKIP_UNREADABLE=$((_DOC_SKIP_UNREADABLE + 1)) ;;
    *)
      printf 'doctor: INTERNAL — unenumerated skip reason "%s" on check %s; counted as checked\n' \
        "$reason" "$check_id" >&2
      _doc_report "$verdict" "$check_id" "$message"
      return 0
      ;;
  esac
  _doc_emit "$verdict" "$check_id" "$message"
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

# _doc_config_parses — 0 when nazgul/config.json is absent (nothing to
# contradict) or parses as JSON, 1 when it exists but does not. _doc_cfg cannot
# answer this: it swallows the parse error and returns the caller's default, so
# an unparseable config read as `.execution.stacking.enabled // false` came back
# "false" and both stacking checks reported a confident "Not applicable" for a
# config nobody could read (RULES §15 — never-looked reported as looked-and-
# found-nothing).
_doc_config_parses() {
  [ -f "$CONFIG" ] || return 0
  jq -e . "$CONFIG" >/dev/null 2>&1
}

# _doc_registry_shape — "ok" / "malformed", mirroring _su_registry_state()
# (scripts/lib/stack-utils.sh). Duplicated read-only for the same reason the
# stacking precondition ladder is (ADR-018): doctor must be able to name the
# condition, and must not depend on sourcing runtime libs.
_doc_registry_shape() {
  local shape
  shape="$(jq -r '
    if (.stack | type) == "null" then "ok"
    elif (.stack | type) != "object" then "malformed"
    elif (.stack.layers | type) == "null" then "ok"
    elif (.stack.layers | type) != "array" then "malformed"
    elif ([.stack.layers[] | select(type != "object")] | length) > 0 then "malformed"
    else "ok" end' "$CONFIG" 2>/dev/null)" || shape="ok"
  [ -n "$shape" ] || shape="ok"
  printf '%s' "$shape"
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
    _doc_skip pass plugin-version not-applicable-config "Not applicable — install_mode is not 'local' and $PROJECT_ROOT is not a plugin repo (no .claude-plugin/plugin.json)."
    return 0
  fi

  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    _doc_skip pass plugin-version not-applicable-env "Not applicable — CLAUDE_PLUGIN_ROOT is unset, so there is no active plugin instance to compare against (e.g. running under a test harness)."
    return 0
  fi

  local active_json="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
  local repo_json="$PROJECT_ROOT/.claude-plugin/plugin.json"
  local active_version repo_version
  active_version="$(_doc_json_field "$active_json" '.version // ""')"
  repo_version="$(_doc_json_field "$repo_json" '.version // ""')"

  if [ -z "$active_version" ] || [ -z "$repo_version" ]; then
    _doc_skip pass plugin-version unreadable "Not applicable — could not read a .version field from $active_json or $repo_json."
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
    _doc_skip pass git-hooks not-applicable-config "Not applicable — guards.git_hooks is false."
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
    _doc_skip pass config-schema not-applicable-config "No nazgul/config.json to check yet — run /nazgul:init first."
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
    # CLAUDE_PROJECT_DIR must be the PROJECT ROOT — one level above nazgul/.
    # NAZGUL_DIR conventionally names the nazgul/ dir itself, so suggesting
    # the same value verbatim would resolve to <root>/nazgul/nazgul.
    local suggested_root="${_DOC_OPERATOR_NAZGUL_DIR%/}"
    case "$suggested_root" in
      */nazgul) suggested_root="${suggested_root%/nazgul}" ;;
    esac
    [ -n "$suggested_root" ] || suggested_root="<project-root>"
    _doc_report warn nazgul-dir-env "NAZGUL_DIR is set ('$_DOC_OPERATOR_NAZGUL_DIR') but scripts/lib/nazgul-root.sh never reads it — it has NO effect on resolution. CLAUDE_PROJECT_DIR is the one seam that actually isolates nazgul/ resolution, and it must be the PROJECT ROOT (one level above nazgul/): use 'CLAUDE_PROJECT_DIR=$suggested_root ...' instead of 'NAZGUL_DIR=$_DOC_OPERATOR_NAZGUL_DIR ...'."
  else
    _doc_report pass nazgul-dir-env "NAZGUL_DIR is not set. CLAUDE_PROJECT_DIR is the one environment variable that redirects nazgul/ resolution."
  fi
}

# (g) Never-EOF stdin hazard: an unconditional advisory note, not a scored
# check — routed through _doc_report with verdict "note" so it shares the
# same output shape without touching the aggregate exit code.
check_stdin_hazard() {
  _doc_report note stdin-hazard "Hook scripts that read stdin via 'cat' without a bounded, non-tty-aware guard can block forever under a non-tty, never-EOF stdin. When running such scripts (or the test harness) outside a real hook context, redirect stdin: 'script < /dev/null'. Informational only; does not affect this run's exit code."
}

# The gh-stack release ADR-018's probe characterized, and whose exact message
# strings scripts/lib/stack-utils.sh matches on. The pin lives in source, not in
# nazgul/config.json, because doctor never writes state (ADR-016): the canary is
# a comparison and a message, not a recorded baseline.
_DOC_GH_STACK_PINNED="0.1.0"

# _doc_gh_stack_version <extension-list-text> -> the version on the
# github/gh-stack row, leading "v" stripped, or "" when that row carries no
# version-shaped token. `gh extension list` has no --json flag (ADR-018 §1), and
# the version already rides the same plain-text table check (h) greps for
# presence, so the canary costs no extra process and no extra failure mode. The
# scan is right-to-left over the row's fields rather than a fixed column: gh
# appends its own trailing columns (e.g. an upgrade notice) on some versions.
_doc_gh_stack_version() {
  local ver
  ver=$(awk '/github\/gh-stack/ { for (i = NF; i >= 1; i--) if ($i ~ /^v?[0-9]+\.[0-9]+/) { print $i; exit } exit }' <<<"$1")
  printf '%s' "${ver#v}"
}

# (h) Stacking tooling: only when execution.stacking.enabled is true. Checks
# the SAME preconditions stack_available() (scripts/lib/stack-utils.sh) gates
# on, in the same order, so doctor and production code never disagree on what
# "available" means — duplicated read-only per ADR-018 rather than sourced,
# so this check can name exactly which precondition failed (stack_available
# only returns a collapsed "missing"). Extension presence is detected via
# `gh extension list` text (ADR-018 binding adjustment #1) — `gh stack` is
# never invoked to probe, since an absent extension produces indistinguishable
# generic gh CLI routing noise.
check_stacking() {
  if ! _doc_config_parses; then
    _doc_report fail stacking "nazgul/config.json exists but is not parseable JSON — stacking state cannot be read at all. This is NOT the same as 'stacking is off': stack_available() reports 'invalid' and every stacking caller fails closed. Repair the JSON (jq . nazgul/config.json shows the parse error), then re-run /nazgul:doctor."
    return 0
  fi

  if [ "$(_doc_cfg '.execution.stacking.enabled // false' 'false')" != "true" ]; then
    _doc_skip pass stacking not-applicable-config "Not applicable — execution.stacking.enabled is false."
    return 0
  fi

  if [ "$(_doc_cfg '.execution.stacking.halted // false' 'false')" = "true" ]; then
    local halt_reason halt_failures
    halt_reason="$(_doc_cfg '.execution.stacking.halt_reason // "unknown"' 'unknown')"
    halt_failures="$(_doc_cfg '.execution.stacking.api_failures // 0' '0')"
    _doc_report warn stacking "execution.stacking.enabled is true but stacking is halted (reason: $halt_reason) — resolve the underlying sync conflict, then clear execution.stacking.halted in nazgul/config.json to resume. Also confirm execution.stacking.api_failures is 0 (currently $halt_failures) and execution.stacking.api_failures_by_op is empty before resuming: a non-zero counter re-halts on the very next API hiccup."
    return 0
  fi

  local api_failures
  api_failures="$(_doc_cfg '.execution.stacking.api_failures // 0' '0')"
  case "$api_failures" in ''|*[!0-9]*) api_failures=0 ;; esac
  if [ "$api_failures" -ge 1 ]; then
    _doc_report warn stacking "execution.stacking.api_failures is $api_failures (of 3 consecutive before stacking halts) — GitHub API calls are failing. Check 'gh auth status' and the PRs named in nazgul/config.json stack.layers[]; a successful reconcile tick resets the counter."
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _doc_report warn stacking "execution.stacking.enabled is true but gh is not on PATH — install the GitHub CLI ('brew install gh') and run 'gh auth login'."
    return 0
  fi

  # Captured, not piped into `grep -q` — same SIGPIPE-under-pipefail hazard
  # fixed in stack_available() (doctor.sh runs under `set -euo pipefail`), which
  # would report an installed extension as missing on a fraction of runs.
  local ext_list
  ext_list=$(gh extension list 2>/dev/null) || ext_list=""
  case "$ext_list" in
    *"github/gh-stack"*) : ;;
    *)
      _doc_report warn stacking "execution.stacking.enabled is true but the gh-stack extension is not installed — run 'gh extension install github/gh-stack'."
      return 0 ;;
  esac

  if ! gh auth status >/dev/null 2>&1; then
    _doc_report warn stacking "execution.stacking.enabled is true but gh is not authenticated — run 'gh auth login'."
    return 0
  fi

  local gh_stack_ver
  gh_stack_ver="$(_doc_gh_stack_version "$ext_list")"
  if [ -z "$gh_stack_ver" ]; then
    _doc_report note stacking "execution.stacking.enabled is true; gh, the gh-stack extension, and gh auth are all present — but 'gh extension list' reported no version for github/gh-stack, so the vendor-drift canary could NOT run. Nazgul's sync classifier (_su_classify_sync_result, scripts/lib/stack-utils.sh) matches gh-stack v$_DOC_GH_STACK_PINNED's exact message strings; check 'gh stack --version' by hand (ADR-018 §4)."
    return 0
  fi
  if [ "$gh_stack_ver" != "$_DOC_GH_STACK_PINNED" ]; then
    _doc_report warn stacking "gh-stack v$gh_stack_ver is installed but ADR-018 pinned v$_DOC_GH_STACK_PINNED — the conflict doctrine is coupled to that release's exact message strings ('diverged from the stack on GitHub' / 'Sync aborted' / 'local stack composition differs from remote'), matched as text in _su_classify_sync_result (scripts/lib/stack-utils.sh). A reword reclassifies a real divergence as a clean sync and RESETS the three-strikes counter, with no other signal anywhere. Re-probe the new release against ADR-018 §4 and update the fixtures in tests/test-stack-utils.sh before trusting unattended stacking."
    return 0
  fi

  _doc_report pass stacking "execution.stacking.enabled is true; gh, the gh-stack extension, and gh auth are all ready (gh-stack v$gh_stack_ver, the release ADR-018 pins)."
}

# (i) Registry-vs-GitHub drift: only when stacking is enabled and
# `stack.layers[]` has open entries. A layer's registry state is "open" but
# GitHub's PR is MERGED/CLOSED -> warn (drift). No recorded PR, or the PR
# state can't be read from GitHub -> note, never a false pass (RULES §15:
# looked-and-found-none vs never-looked).
check_stack_registry() {
  if ! _doc_config_parses; then
    _doc_report fail stack-registry "nazgul/config.json exists but is not parseable JSON — the stack.layers[] registry cannot be read, so drift cannot be assessed (and 'no drift found' would be a lie). Repair the JSON, then re-run /nazgul:doctor."
    return 0
  fi

  if [ "$(_doc_registry_shape)" = "malformed" ]; then
    _doc_report warn stack-registry "stack.layers[] is CORRUPT — it is not an array of objects. The stack-utils readers (stack_tip, stack_unmerged_count, stack_reconcile, stack_detect_changes_requested) now refuse it rather than reporting an empty stack, so branch creation and the unmerged cap are blocked until it is repaired by hand in nazgul/config.json."
    return 0
  fi

  local open_count enabled
  enabled="$(_doc_cfg '.execution.stacking.enabled // false' 'false')"
  open_count="$(_doc_cfg '[.stack.layers[]? | select(.state == "open")] | length' '0')"
  case "$open_count" in ''|*[!0-9]*) open_count=0 ;; esac

  if [ "$enabled" != "true" ]; then
    if [ "$open_count" -gt 0 ]; then
      _doc_report warn stack-registry "execution.stacking.enabled is false but stack.layers[] still holds $open_count open entry/entries — nothing reconciles them while stacking is off, and re-enabling stacking counts them against max_unmerged immediately. Merge or close their PRs, or clear the entries, before re-enabling."
      return 0
    fi
    _doc_skip pass stack-registry not-applicable-config "Not applicable — execution.stacking.enabled is false and stack.layers[] has no open entries."
    return 0
  fi

  if [ "$open_count" -eq 0 ]; then
    _doc_skip pass stack-registry no-candidates "Not applicable — stack.layers[] has no open entries."
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _doc_skip note stack-registry unreadable "gh is not on PATH — cannot verify $open_count open stack.layers[] entries against GitHub. Install gh (and run 'gh auth login') then re-run /nazgul:doctor."
    return 0
  fi

  local feat_id pr state drifted="" abandoned="" unreadable=0
  while IFS=$'\t' read -r feat_id pr; do
    [ -n "$feat_id" ] || continue
    if [ -z "$pr" ] || [ "$pr" = "null" ]; then
      abandoned="$abandoned $feat_id"
      continue
    fi
    state="$(gh pr view "$pr" --json state -q '.state' 2>/dev/null)" || state=""
    if [ -z "$state" ]; then
      unreadable=$((unreadable + 1))
      continue
    fi
    case "$state" in
      MERGED|CLOSED) drifted="$drifted $feat_id($state)" ;;
    esac
  done < <(jq -r '.stack.layers[]? | select(.state == "open") | [.feat_id, (.pr // "")] | @tsv' "$CONFIG" 2>/dev/null)

  if [ -n "$drifted" ]; then
    _doc_report warn stack-registry "Registry says open but GitHub disagrees for:$drifted — run a heartbeat tick (or /nazgul:start) to reconcile the stack registry."
    return 0
  fi

  # A PR-less open layer is not "drift we could not assess" — it is the
  # ABANDONED-LAYER condition, and it is terminal without a human:
  # create_feature_branch registers a layer with pr unset, stack_reconcile skips
  # PR-less layers, so an objective that never reached stack_submit leaves an
  # entry no code path can ever close. Each one counts against max_unmerged
  # forever and stack_tip keeps handing it out as the base for the next
  # objective. Named warn, never a note.
  if [ -n "$abandoned" ]; then
    _doc_report warn stack-registry "Abandoned layer(s) — open in stack.layers[] with no recorded PR:$abandoned. These were registered at branch creation and never submitted, so nothing can ever mark them merged: they count against execution.stacking.max_unmerged permanently and stack_tip returns them as the base for the next objective. Submit their PRs (/nazgul:start on that objective) or remove the entries from nazgul/config.json by hand."
    return 0
  fi

  if [ "$unreadable" -gt 0 ]; then
    _doc_report note stack-registry "$unreadable of $open_count open stack.layers[] entries record a PR whose state could not be read from GitHub — registry drift cannot be assessed for them."
    return 0
  fi

  _doc_report pass stack-registry "All $open_count open stack.layers[] entries match GitHub's PR state."
}

# (k)/(l)/(m) messaging, Remote Control, session collisions — env/settings reads
# ONLY, never a socket connect (RULES §22; doctor is allowlisted read-only).

# Prints "VAR (source); " for each feature-flag killer that is set.
_doc_flag_killers() {
  local v f proot
  proot="$PROJECT_ROOT"
  for v in CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_TELEMETRY DO_NOT_TRACK DISABLE_GROWTHBOOK; do
    [ -n "$(printenv "$v" 2>/dev/null || true)" ] && printf '%s (shell env); ' "$v"
  done
  for f in "${HOME:-}/.claude/settings.json" "$proot/.claude/settings.json" "$proot/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    for v in CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_TELEMETRY DO_NOT_TRACK DISABLE_GROWTHBOOK; do
      jq -e --arg v "$v" '(.env // {}) | has($v)' "$f" >/dev/null 2>&1 && printf '%s (env map in %s); ' "$v" "$f"
    done
  done
  # A killer-less run leaves the last && list false; without this the caller's
  # `killers=$(_doc_flag_killers)` fails and set -e aborts the whole diagnostic.
  return 0
}

# Prints "<value> from <file>" for the highest-precedence readable setting, or "".
_doc_effective_inbound() {
  local f v proot
  proot="$PROJECT_ROOT"
  for f in "$proot/.claude/settings.local.json" "$proot/.claude/settings.json" "${HOME:-}/.claude/settings.json"; do
    [ -f "$f" ] || continue
    v=$(jq -r '.crossSessionInbound // empty' "$f" 2>/dev/null || true)
    [ -n "$v" ] && { printf '%s from %s' "$v" "$f"; return 0; }
  done
  return 0
}

# (k) Messaging eligibility. Three states, never two: a socket that is not
# exported HERE is UNDETERMINED, never a claim that messaging is unavailable.
check_messaging() {
  local killers inbound note nc_note
  killers=$(_doc_flag_killers)
  if [ -n "$killers" ]; then
    _doc_report warn messaging "Cross-session messaging is OFF: feature-flag evaluation is disabled by ${killers}unset the variable at its named source to enable."
    return 0
  fi
  inbound=$(_doc_effective_inbound)
  note=""; [ -n "$inbound" ] && note=" crossSessionInbound: ${inbound} (project/local refuse outranks every other source)."
  command -v nc >/dev/null 2>&1 && nc_note=" nc: present." || nc_note=" nc: absent (the only stock socket poster — informational; nothing shipped posts)."
  if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
    _doc_report pass messaging "Messaging available in this context: socket env exported.${note}${nc_note}"
  else
    _doc_report note messaging "Messaging UNDETERMINED in this context: CLAUDE_CODE_MESSAGING_SOCKET is not exported here — legitimate in the pre-flag-fetch window or outside a hook/Bash context; NOT a claim that messaging is unavailable.${note}${nc_note}"
  fi
}

# (l) Remote Control eligibility. Auth type is never probed here, so every
# verdict points at 'claude doctor' as the authoritative check.
check_remote_control() {
  local killers causes v f proot
  killers=$(_doc_flag_killers)
  if [ -n "$killers" ]; then
    _doc_report warn remote-control "Remote Control is unavailable: feature-flag evaluation is disabled by ${killers}see 'claude doctor' for the authoritative check name."
    return 0
  fi
  causes=""
  [ -n "${ANTHROPIC_BASE_URL:-}" ] && causes="custom ANTHROPIC_BASE_URL (non-first-party routing); "
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
    [ -n "$(printenv "$v" 2>/dev/null || true)" ] && causes="${causes}${v} set (provider routing); "
  done
  proot="$PROJECT_ROOT"
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" "${HOME:-}/.claude/settings.json" "$proot/.claude/settings.json"; do
    [ -f "$f" ] || continue
    if jq -e '.disableRemoteControl == true' "$f" >/dev/null 2>&1; then
      causes="${causes}disableRemoteControl in ${f}; "
    fi
  done
  if [ -n "$causes" ]; then
    _doc_report warn remote-control "Remote Control likely unavailable: ${causes}auth type not probed — run 'claude doctor' for the authoritative check."
  else
    _doc_report pass remote-control "No Remote Control blockers found in env/settings (auth type not probed — 'claude doctor' is authoritative)."
  fi
}

# (m) Shared-working-tree collision among LIVE session locks — the #195 hazard,
# read from the pid/toplevel fields scripts/lib/session-tracker.sh records.
check_sessions() {
  local sessions_dir="$NAZGUL_DIR/sessions" f lp dup
  if [ ! -d "$sessions_dir" ] || ! ls "$sessions_dir"/*.lock >/dev/null 2>&1; then
    _doc_skip pass sessions no-candidates "Not applicable — no session locks under nazgul/sessions/, so there is nothing to check."
    return 0
  fi
  dup=$(
    for f in "$sessions_dir"/*.lock; do
      [ -f "$f" ] || continue
      lp=$(jq -r '.pid // ""' "$f" 2>/dev/null)
      if [ -n "$lp" ] && printf '%s' "$lp" | grep -qE '^[0-9]+$' && ! kill -0 "$lp" 2>/dev/null; then continue; fi
      jq -r '.toplevel // ""' "$f" 2>/dev/null
    done | grep -v '^$' | sort | uniq -d | head -1
  )
  if [ -n "$dup" ]; then
    _doc_report warn sessions "Multiple live Nazgul sessions share one working tree ($dup) — the #195 shared-checkout hazard. Give each concurrent loop its own worktree."
  else
    _doc_report pass sessions "No shared-working-tree collision among live session locks."
  fi
}

_DOC_CHECK_IDS="config-present plugin-version dependencies git-hooks invoking-shell nazgul-dir-env config-schema stacking stack-registry stdin-hazard messaging remote-control sessions"
_DOC_ONLY=""

# _doc_run <check-id> <function> — runs the check unless --only excluded it.
_doc_run() {
  if [ -n "$_DOC_ONLY" ]; then
    case ",$_DOC_ONLY," in
      *",$1,"*) : ;;
      *) return 0 ;;
    esac
  fi
  "$2"
}

# Coverage line, always the last line of stdout (TRD §6). Doctor has NO bus path:
# events.jsonl is under nazgul/, and zero-write outranks the event.
_doc_emit_coverage_line() {
  local skipped=$((_DOC_SKIP_NA_CONFIG + _DOC_SKIP_NA_ENV + _DOC_SKIP_NO_CANDIDATES + _DOC_SKIP_UNREADABLE))
  if [ "$_DOC_SCANNED" -ne $((skipped + _DOC_CHECKED)) ]; then
    printf 'doctor: INTERNAL — coverage accounting mismatch: %d scanned != %d skipped + %d checked\n' \
      "$_DOC_SCANNED" "$skipped" "$_DOC_CHECKED" >&2
  fi
  if [ "$_DOC_CHECKED" -eq 0 ] && [ "$_DOC_SCANNED" -gt 0 ]; then
    printf 'doctor: NOTHING CHECKED — all %d candidates skipped\n' "$_DOC_SCANNED" >&2
  fi
  printf 'doctor: %d scanned, %d skipped (not-applicable-config=%d, not-applicable-env=%d, no-candidates=%d, unreadable=%d), %d checked, %d findings\n' \
    "$_DOC_SCANNED" "$skipped" "$_DOC_SKIP_NA_CONFIG" "$_DOC_SKIP_NA_ENV" \
    "$_DOC_SKIP_NO_CANDIDATES" "$_DOC_SKIP_UNREADABLE" "$_DOC_CHECKED" "$_DOC_FINDINGS"
}

# --only exists so the all-skipped path is reachable at all: with every check
# selected at least one always inspects something.
_doc_parse_args() {
  local arg id found only_seen="false"
  for arg in "$@"; do
    case "$arg" in
      --only=*) _DOC_ONLY="${arg#--only=}"; only_seen="true" ;;
      -h|--help)
        echo "Usage: doctor.sh [--only=<check-id>[,<check-id>...]]"
        echo "Checks: $_DOC_CHECK_IDS"
        exit 0
        ;;
      *)
        echo "doctor: unknown argument: $arg" >&2
        echo "Usage: doctor.sh [--only=<check-id>[,<check-id>...]]" >&2
        exit 1
        ;;
    esac
  done
  [ "$only_seen" = "true" ] || return 0
  case ",$_DOC_ONLY," in
    *,,*)
      echo "doctor: --only requires one or more non-empty check ids. Known checks: $_DOC_CHECK_IDS" >&2
      exit 1
      ;;
  esac
  # A typo in --only would otherwise select nothing and report a confident
  # zero-finding run: the vacuous green this whole contract exists to abolish.
  for id in ${_DOC_ONLY//,/ }; do
    found="false"
    for arg in $_DOC_CHECK_IDS; do
      [ "$id" = "$arg" ] && found="true"
    done
    if [ "$found" != "true" ]; then
      echo "doctor: --only names unknown check '$id'. Known checks: $_DOC_CHECK_IDS" >&2
      exit 1
    fi
  done
}

main() {
  _doc_parse_args "$@"
  _doc_run config-present check_config_present
  _doc_run plugin-version check_plugin_version
  _doc_run dependencies check_dependencies
  _doc_run git-hooks check_git_hooks
  _doc_run invoking-shell check_invoking_shell
  _doc_run nazgul-dir-env check_nazgul_dir_env
  _doc_run config-schema check_config_schema
  _doc_run stacking check_stacking
  _doc_run stack-registry check_stack_registry
  _doc_run stdin-hazard check_stdin_hazard
  _doc_run messaging check_messaging
  _doc_run remote-control check_remote_control
  _doc_run sessions check_sessions
  _doc_emit_coverage_line
  exit "$_DOC_WORST"
}

main "$@"
