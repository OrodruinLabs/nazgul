#!/usr/bin/env bash
# Nazgul git-hooks — install/uninstall/self-heal lifecycle for the managed
# `core.hooksPath` guards (pre-commit base-branch, pre-merge-commit H2
# parallel-unit verdict). Sourced by worktree-utils.sh (install/uninstall) and
# session-context.sh (self-heal).
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own strict-mode setting (mirrors parallel-batch.sh).

[ -n "${_NAZGUL_GIT_HOOKS_SOURCED:-}" ] && return 0
_NAZGUL_GIT_HOOKS_SOURCED=1

_GH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GH_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_GH_LIB_DIR/../.." && pwd)}"
_GH_TEMPLATES_DIR="$_GH_PLUGIN_ROOT/scripts/git-hooks"
_GH_MANAGED_RELDIR="nazgul/.githooks"

_GH_OWN_HOOKS=(pre-commit pre-merge-commit)

# Every standard githooks(5) name Nazgul does not itself define. Installed as
# pure dispatcher shims so a user's pre-existing hook of any of these names
# keeps running once `core.hooksPath` points only at the managed dir.
_GH_OTHER_HOOKS=(
  applypatch-msg pre-applypatch post-applypatch prepare-commit-msg commit-msg
  post-commit pre-rebase post-checkout post-merge pre-push pre-receive update
  post-receive post-update push-to-checkout pre-auto-gc post-rewrite
  sendemail-validate fsmonitor-watchman proc-receive post-index-change
  reference-transaction
)

_gh_enabled() {
  local config="$1"
  jq -r 'if .guards.git_hooks == false then "false" else "true" end' "$config" 2>/dev/null || echo "true"
}

# True only when jq is available AND the config parses as valid JSON. Every
# lifecycle function must gate on this before touching `core.hooksPath` —
# a malformed config or missing jq means we can't safely read/record the
# prior value, so the only safe move is a no-op.
_gh_config_readable() {
  local config="$1"
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$config" >/dev/null 2>&1
}

# Prints the live `core.hooksPath` for the repo, or "" if unset/unreadable.
_gh_current_hooks_path() {
  local project_root="$1"
  git -C "$project_root" config --get core.hooksPath 2>/dev/null || echo ""
}

# Dispatcher-shim body for a single hook name: forwards argv + stdin to any
# prior hook of the same name via `_dispatch.sh`, degrading to a silent allow
# when the repo root or dispatcher can't be resolved.
_gh_shim_content() {
  local hook_name="$1"
  cat <<SHIM
#!/usr/bin/env bash
set -euo pipefail

# Nazgul generic hook shim — passes through to a pre-existing user hook of
# this name (if any) via the chain-dispatcher; Nazgul does not define
# guard logic for '$hook_name' itself.

REPO_ROOT="\$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "\$REPO_ROOT" ] || exit 0

DISPATCH="\$(cd "\$(dirname "\$0")" && pwd)/_dispatch.sh"
[ -f "\$DISPATCH" ] || exit 0

export CLAUDE_PROJECT_DIR="\$REPO_ROOT"
# shellcheck source=/dev/null
source "\$DISPATCH"
dispatch_prior_hook $hook_name "\$@"
exit \$?
SHIM
}

# install_git_hooks <project_root> <config>
# No-op if `guards.git_hooks` is false. Otherwise, on the FIRST install of a
# cycle (`branch.prior_hooks_path` is `null` — absent or explicit-null both
# read that way in jq — meaning "not yet recorded"), records the live
# `core.hooksPath` into it — empty string means "recorded, and it was unset".
# A later install in the same cycle never overwrites an already-recorded
# value, even if `core.hooksPath` has since drifted externally. Installs the
# two guard templates + dispatcher + shims for every other standard hook name
# into `nazgul/.githooks/`, then points `core.hooksPath` at it. Safe to call
# repeatedly (idempotent).
install_git_hooks() {
  local project_root="${1:?install_git_hooks: project_root required}"
  local config="${2:?install_git_hooks: config required}"
  [ -f "$config" ] || return 0
  _gh_config_readable "$config" || return 0
  [ "$(_gh_enabled "$config")" = "true" ] || return 0

  # `.branch` present but not an object (hand-edited/corrupt config) can't be
  # safely read or written by any of the jq filters below (indexing a
  # scalar/array errors) — treat exactly like an unreadable config: no-op,
  # never touch core.hooksPath. Absent/null `.branch` is fine (jq auto-
  # vivifies it to an object on write).
  local branch_type
  branch_type=$(jq -r '.branch | type' "$config" 2>/dev/null) || return 0
  case "$branch_type" in
    object | null) : ;;
    *) return 0 ;;
  esac

  local not_recorded
  not_recorded=$(jq -r '(.branch // {}).prior_hooks_path == null' "$config" 2>/dev/null) || return 0
  if [ "$not_recorded" = "true" ]; then
    local current
    current=$(_gh_current_hooks_path "$project_root")
    local tmp
    tmp=$(mktemp)
    if jq --arg prior "$current" '.branch.prior_hooks_path = $prior' "$config" > "$tmp" && mv "$tmp" "$config"; then
      :
    else
      # Couldn't durably persist the prior value -> must not point
      # core.hooksPath anywhere; a later uninstall would have nothing to
      # restore and would clobber the user's real setting.
      rm -f "$tmp"
      return 0
    fi
  fi

  local managed_dir="$project_root/$_GH_MANAGED_RELDIR"
  mkdir -p "$managed_dir"

  cp "$_GH_TEMPLATES_DIR/_dispatch.sh" "$managed_dir/_dispatch.sh"
  chmod +x "$managed_dir/_dispatch.sh"

  local hook
  for hook in "${_GH_OWN_HOOKS[@]}"; do
    cp "$_GH_TEMPLATES_DIR/$hook" "$managed_dir/$hook"
    chmod +x "$managed_dir/$hook"
  done

  for hook in "${_GH_OTHER_HOOKS[@]}"; do
    _gh_shim_content "$hook" > "$managed_dir/$hook"
    chmod +x "$managed_dir/$hook"
  done

  git -C "$project_root" config core.hooksPath "$_GH_MANAGED_RELDIR"
}

# uninstall_git_hooks <project_root> <config>
# Restores the recorded prior `core.hooksPath` exactly — unsets it when the
# recorded value is the empty "was unset" sentinel, sets it back when it's a
# real path, and no-ops when it was never recorded (`null`/absent, meaning
# install never ran) — never treating jq failure, "never recorded", and
# "recorded as unset" as the same case. Re-arms the recorded field to `null`
# afterward ("not yet recorded" for the next cycle) — NOT empty string, which
# would mean "recorded, was unset" and poison the next install's presence
# gate. Leaves the managed dir's contents on disk (harmless once
# unreferenced).
uninstall_git_hooks() {
  local project_root="${1:?uninstall_git_hooks: project_root required}"
  local config="${2:?uninstall_git_hooks: config required}"
  [ -f "$config" ] || return 0
  _gh_config_readable "$config" || return 0

  # A non-object `.branch` (malformed/hand-edited config) reads as "never
  # recorded", same as absent/null — never touches core.hooksPath.
  local was_recorded
  was_recorded=$(jq -r 'if (.branch|type) == "object" then (.branch.prior_hooks_path != null) else false end' "$config" 2>/dev/null) || return 0
  [ "$was_recorded" = "true" ] || return 0

  local prior
  prior=$(jq -r '.branch.prior_hooks_path' "$config" 2>/dev/null) || return 0

  if [ -z "$prior" ]; then
    git -C "$project_root" config --unset core.hooksPath 2>/dev/null || true
  else
    git -C "$project_root" config core.hooksPath "$prior"
  fi

  local tmp
  tmp=$(mktemp)
  jq '.branch.prior_hooks_path = null' "$config" > "$tmp" && mv "$tmp" "$config"
}

# self_heal_git_hooks <project_root> <config>
# Re-asserts the managed `core.hooksPath` ONLY when a loop is actively
# tracked (`guards.git_hooks` true, `branch.feature` set, `branch.
# prior_hooks_path` has actually been recorded — i.e. non-null) AND the
# actual value has drifted from the managed dir. No-ops on an explicit
# `guards.git_hooks: false`, no active objective, or when already correct —
# never a blind overwrite.
self_heal_git_hooks() {
  local project_root="${1:?self_heal_git_hooks: project_root required}"
  local config="${2:?self_heal_git_hooks: config required}"
  [ -f "$config" ] || return 0
  _gh_config_readable "$config" || return 0
  [ "$(_gh_enabled "$config")" = "true" ] || return 0

  # A non-object `.branch` reads as "no feature" / "never recorded" here too
  # — same fail-safe treatment as uninstall_git_hooks.
  local feature
  feature=$(jq -r 'if (.branch|type) == "object" then (.branch.feature // "") else "" end' "$config" 2>/dev/null || echo "")
  [ -n "$feature" ] || return 0

  local recorded
  recorded=$(jq -r 'if (.branch|type) == "object" then (.branch.prior_hooks_path != null) else false end' "$config" 2>/dev/null || echo "false")
  [ "$recorded" = "true" ] || return 0

  local current
  current=$(_gh_current_hooks_path "$project_root")
  [ "$current" != "$_GH_MANAGED_RELDIR" ] || return 0

  git -C "$project_root" config core.hooksPath "$_GH_MANAGED_RELDIR"
}
