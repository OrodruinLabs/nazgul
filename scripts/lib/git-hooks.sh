#!/usr/bin/env bash
# Nazgul git-hooks — install/uninstall/self-heal lifecycle for the managed
# `core.hooksPath` guards (pre-commit base-branch, pre-merge-commit H2
# conductor verdict). Sourced by worktree-utils.sh (install/uninstall) and
# session-context.sh (self-heal).
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller
# shells that own their own strict-mode setting (mirrors conductor-gates.sh).

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
  sendemail-validate fsmonitor-watchman push-to-mirror reference-transaction
)

_gh_enabled() {
  local config="$1"
  jq -r 'if .guards.git_hooks == false then "false" else "true" end' "$config" 2>/dev/null || echo "true"
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
  [ "$(_gh_enabled "$config")" = "true" ] || return 0

  local not_recorded
  not_recorded=$(jq -r '(.branch // {}).prior_hooks_path == null' "$config" 2>/dev/null || echo "true")
  if [ "$not_recorded" = "true" ]; then
    local current
    current=$(_gh_current_hooks_path "$project_root")
    local tmp
    tmp=$(mktemp)
    jq --arg prior "$current" '.branch.prior_hooks_path = $prior' "$config" > "$tmp" && mv "$tmp" "$config"
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
# recorded value is the empty "was unset" sentinel, otherwise sets it back.
# Re-arms the recorded field to `null` afterward ("not yet recorded" for the
# next cycle) — NOT empty string, which would mean "recorded, was unset" and
# poison the next install's presence gate. Leaves the managed dir's contents
# on disk (harmless once unreferenced).
uninstall_git_hooks() {
  local project_root="${1:?uninstall_git_hooks: project_root required}"
  local config="${2:?uninstall_git_hooks: config required}"
  [ -f "$config" ] || return 0

  local prior
  prior=$(jq -r '.branch.prior_hooks_path // ""' "$config" 2>/dev/null || echo "")

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
  [ "$(_gh_enabled "$config")" = "true" ] || return 0

  local feature
  feature=$(jq -r '.branch.feature // ""' "$config" 2>/dev/null || echo "")
  [ -n "$feature" ] || return 0

  local recorded
  recorded=$(jq -r '(.branch // {}).prior_hooks_path != null' "$config" 2>/dev/null || echo "false")
  [ "$recorded" = "true" ] || return 0

  local current
  current=$(_gh_current_hooks_path "$project_root")
  [ "$current" != "$_GH_MANAGED_RELDIR" ] || return 0

  git -C "$project_root" config core.hooksPath "$_GH_MANAGED_RELDIR"
}
