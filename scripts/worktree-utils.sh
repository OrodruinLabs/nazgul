#!/usr/bin/env bash
set -euo pipefail

# Nazgul Worktree Utilities — shared helpers for branch/worktree management
# Source this file: source "$(dirname "$0")/worktree-utils.sh"

# Requires: NAZGUL_DIR and CONFIG to be set by the caller

# ${BASH_SOURCE[0]} is bash-only. Under zsh (the default interactive shell on
# macOS) it is an unset-parameter diagnostic that zsh treats as non-fatal:
# _WU_DIR would silently resolve to the caller's $PWD, _WU_PLUGIN_ROOT and
# _WU_GIT_HOOKS_LIB (git-hooks.sh, install_git_hooks) and _WU_NAZGUL_ROOT_LIB
# (nazgul-root.sh, resolve_project_root) would all point at wrong paths, and
# this file would half-load with no error. Refuse loudly instead.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "FATAL: worktree-utils.sh must be sourced from bash (got: $(basename "${0:-unknown}"))." >&2
  echo "The managed git-hooks install (create_feature_branch -> install_git_hooks) cannot proceed under this shell." >&2
  return 1 2>/dev/null || exit 1
fi

_WU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WU_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_WU_DIR/.." && pwd)}"
_WU_GIT_HOOKS_LIB="$_WU_PLUGIN_ROOT/scripts/lib/git-hooks.sh"
# shellcheck source=./lib/git-hooks.sh
[ -f "$_WU_GIT_HOOKS_LIB" ] && source "$_WU_GIT_HOOKS_LIB"
_WU_NAZGUL_ROOT_LIB="$_WU_PLUGIN_ROOT/scripts/lib/nazgul-root.sh"
# shellcheck source=./lib/nazgul-root.sh
[ -f "$_WU_NAZGUL_ROOT_LIB" ] && source "$_WU_NAZGUL_ROOT_LIB"
# Optional: stacking (FEAT-027). Tolerate absence — non-stacking flows (the
# default) never require it, so a deployment missing this lib still works;
# create_feature_branch treats an undefined stack_available as "disabled".
_WU_STACK_UTILS_LIB="$_WU_PLUGIN_ROOT/scripts/lib/stack-utils.sh"
# shellcheck source=./lib/stack-utils.sh
[ -f "$_WU_STACK_UTILS_LIB" ] && source "$_WU_STACK_UTILS_LIB"

slugify_objective() {
  local input="$1"
  local slug
  slug=$(printf '%s' "$input" \
    | tr '\n\r\t' '   ' \
    | tr -s '[:space:]' ' ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' \
    | cut -c1-50)
  printf '%s' "${slug:-objective}"
}

create_feature_branch() {
  local objective="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"
  local slug
  slug=$(slugify_objective "$objective")
  # Identity reuse (Objective Identity rule): a feat_id already in config is
  # authoritative — /nazgul:plan or a prior start path assigned it, and specs
  # (objectives/FEAT-NNN-spec.md) are keyed to it. Derive a fresh id ONLY when
  # config has none; recomputing on reuse would rename the branch and prefix
  # to a wrong, off-by-one id.
  local feat_id display_id commit_prefix branch_component
  feat_id=$(jq -r '.feat_id // ""' "$config")
  if [ -n "$feat_id" ] && [ "$feat_id" != "null" ]; then
    display_id=$(jq -r '.feat_display_id // ""' "$config")
    { [ -n "$display_id" ] && [ "$display_id" != "null" ]; } || display_id="$feat_id"
    commit_prefix=$(jq -r '.afk.commit_prefix // ""' "$config")
    { [ -n "$commit_prefix" ] && [ "$commit_prefix" != "null" ]; } || commit_prefix="feat(${display_id}):"
    branch_component="${display_id#\#}"
  else
    local feat_num
    feat_num=$(jq '(.objectives_history // [] | length) + 1' "$config")
    feat_id="FEAT-$(printf '%03d' "$feat_num")"
    # Check for board issue number
    local board_issue
    board_issue=$(jq -r '.board.current_issue // ""' "$config")
    if [ -n "$board_issue" ] && [ "$board_issue" != "null" ]; then
      display_id="#${board_issue}"
      branch_component="$board_issue"
    else
      display_id="$feat_id"
      branch_component="$feat_id"
    fi
    commit_prefix="feat(${display_id}):"
  fi

  local branch_name="feat/${branch_component}-${slug}"
  local main_worktree_path
  main_worktree_path=$(cd "$project_root" && pwd)

  # Stack-aware base selection (FEAT-027 TASK-006, ADR-018). Prior behavior
  # captured whatever branch happened to be checked out with no assertion it
  # was the intended base — the accidental-stacking hazard the spec's
  # Purpose section calls out. stack_available is undefined when
  # stack-utils.sh wasn't sourced (missing lib) — treated the same as
  # "disabled".
  local stack_state="disabled"
  if declare -F stack_available >/dev/null 2>&1; then
    stack_state=$(stack_available "$config") || true
  fi

  local base_branch
  if [ "$stack_state" = "ready" ]; then
    # Stacking on and ready: base is the explicit stack tip, never whatever
    # is checked out — create from this ref below, not current HEAD. A tip the
    # registry cannot answer for is a refusal, not a fallback.
    if ! base_branch=$(stack_tip "$config"); then
      echo "ERROR: create_feature_branch: stack_tip refused to answer (see the stack-utils diagnostic above) — refusing to branch from a guessed base." >&2
      return 1
    fi
  else
    # Disabled, or enabled but unusable (tooling missing, halted, or an
    # unparseable config): fail closed to today's non-stacking contract. Assert
    # reality matches intent instead of trusting whatever is checked out — this
    # is the hazard fix, and it ships for ALL users regardless of the stacking
    # opt-in.
    #
    # The degradation is announced on stderr FIRST and unconditionally. It used
    # to be an emit_event alone, which no-ops whenever NAZGUL_DIR is unset (the
    # normal case at this function's skill call site) — and when the checkout
    # already matched the base, the branch was created against `main` with the
    # registry still recording open layers and nothing said at all.
    case "$stack_state" in
      missing|halted|invalid)
        echo "WARNING: create_feature_branch: execution.stacking is enabled but unusable (stack_available: $stack_state) — this objective's branch is being created against '$(jq -r '.branch.base // "main"' "$config" 2>/dev/null)' as an ORDINARY (unstacked) branch. Run /nazgul:doctor to see which precondition failed." >&2
        if declare -F _su_emit >/dev/null 2>&1; then
          _su_emit "stop_gate" reason "stacking_unavailable" state "$stack_state" phase "create_feature_branch" feat_id "$feat_id"
        elif declare -F emit_event >/dev/null 2>&1; then
          emit_event "stop_gate" reason "stacking_unavailable" state "$stack_state" phase "create_feature_branch" feat_id "$feat_id"
        fi
        ;;
    esac
    base_branch=$(jq -r '.branch.base // "main"' "$config" 2>/dev/null) || base_branch="main"
    local current_branch
    current_branch=$(git -C "$project_root" branch --show-current 2>/dev/null || echo "")
    if [ "$current_branch" != "$base_branch" ]; then
      echo "ERROR: create_feature_branch: checked out on '$current_branch', expected base '$base_branch' — refusing to branch from a stray checkout (accidental-stacking hazard). Run 'git checkout $base_branch' first, or enable stacking via '/nazgul:start --stack'." >&2
      return 1
    fi
  fi

  # Config must record OBSERVED state, not intended state (ADR-009): verify
  # the ref name, the checkout, and the branch's existence before writing
  # anything, and fail loudly (non-zero) on any of the three.
  if ! git -C "$project_root" check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: create_feature_branch: '$branch_name' is not a valid git branch name" >&2
    return 1
  fi
  if ! git -C "$project_root" checkout -b "$branch_name" "$base_branch" 2>/dev/null; then
    echo "ERROR: create_feature_branch: 'git checkout -b $branch_name $base_branch' failed (invalid ref name, already exists, or base ref missing)" >&2
    return 1
  fi
  if ! git -C "$project_root" rev-parse --verify --quiet "$branch_name" >/dev/null; then
    echo "ERROR: create_feature_branch: branch '$branch_name' does not exist after checkout" >&2
    return 1
  fi

  # The config write is the FOURTH verification step, and it fails loudly like
  # the three above it. Previously unchecked (PR #74 review): a failed
  # `jq … && mv` left the branch created and checked out on disk while
  # config.json recorded nothing, and the function still returned success —
  # config inconsistent with observed state, with nothing emitted. Worse, the
  # state was unrecoverable: every retry then died at `checkout -b` with
  # "invalid ref name or already exists", so a transient write failure bricked
  # branch setup for the objective until a human deleted the branch.
  #
  # On failure we roll back to the pre-call state. That is safe here and only
  # here: the branch passed check-ref-format, was created by THIS call's
  # `checkout -b` (which only succeeds on an unclaimed name), and was verified
  # to exist — so it is provably fresh, carries no commits beyond
  # "$base_branch", and nothing has run between its creation and this write.
  # Rollback commands are best-effort; if one fails we say so rather than
  # failing harder inside an already-failing path.
  #
  # Idiom copied from scripts/lib/git-hooks.sh:116, which already guards the
  # same `jq … && mv` shape for the same reason.
  #
  # The temp file is COLOCATED with $config, not left to `mktemp`'s default
  # (PR #74 review). A bare `mktemp` uses $TMPDIR, which is not guaranteed to
  # share a filesystem with $config — on Linux CI /tmp is frequently tmpfs and
  # in containers a separate mount. Across filesystems `mv` is not an atomic
  # rename(2); it degrades to copy-then-unlink, so a failure partway through
  # can leave $config PARTIALLY WRITTEN. That would break the rollback
  # contract below (which promises $config is untouched on failure) and, worse,
  # a corrupt config now fails the pre-merge guard closed — blocking every
  # merge in the repo. Colocating makes the mv a same-directory rename, which
  # POSIX guarantees atomic. Note this also moves the failure point: on an
  # unwritable config dir `mktemp` now fails instead of `mv`, so its result is
  # checked and routed through the same rollback.
  #
  # Stacking-ready only: a byte-identical backup taken BEFORE this write, so
  # that if the LATER stack_register_layer call (below) fails after this
  # write has already committed, we can restore config to its pre-call state
  # rather than leave a branch/base recorded with no matching registry entry.
  # Registry is written only AFTER this write commits (not before) — see the
  # note at the registry-write call site for why that ordering was chosen.
  #
  # BOTH the mktemp and the cp are checked. An unchecked cp (PR #81 audit) could
  # leave an EMPTY backup file that the registry-failure path below would then
  # `mv` over config.json and report as a successful restore — a corrupt config
  # that fails the pre-merge guard closed and blocks every merge in the repo,
  # which is the exact hazard the colocation note above exists to prevent. No
  # usable backup means no safe unwind, so we refuse before the branch has any
  # config state to unwind.
  local config_backup=""
  if [ "$stack_state" = "ready" ]; then
    config_backup=$(mktemp "$(dirname "$config")/.nazgul-config-backup.XXXXXX" 2>/dev/null) || config_backup=""
    if [ -z "$config_backup" ] || ! cp "$config" "$config_backup" 2>/dev/null; then
      echo "ERROR: create_feature_branch: could not take a byte-identical backup of '$config' after branch '$branch_name' was created — without it a later registry failure could not be unwound safely, so rolling back to '$base_branch' now" >&2
      [ -n "$config_backup" ] && rm -f "$config_backup"
      git -C "$project_root" checkout "$base_branch" >/dev/null 2>&1 \
        || echo "ERROR: create_feature_branch: rollback checkout to '$base_branch' also failed — branch '$branch_name' left on disk, config unchanged" >&2
      git -C "$project_root" branch -D "$branch_name" >/dev/null 2>&1 \
        || echo "ERROR: create_feature_branch: rollback delete of '$branch_name' failed — remove it manually before retrying" >&2
      return 1
    fi
  fi
  local tmp
  tmp=$(mktemp "$(dirname "$config")/.nazgul-config.XXXXXX" 2>/dev/null) || {
    echo "ERROR: create_feature_branch: cannot create a temp file beside '$config' after branch '$branch_name' was created — rolling back to '$base_branch'" >&2
    rm -f "$config_backup"
    git -C "$project_root" checkout "$base_branch" >/dev/null 2>&1 \
      || echo "ERROR: create_feature_branch: rollback checkout to '$base_branch' also failed — branch '$branch_name' left on disk, config unchanged" >&2
    git -C "$project_root" branch -D "$branch_name" >/dev/null 2>&1 \
      || echo "ERROR: create_feature_branch: rollback delete of '$branch_name' failed — remove it manually before retrying" >&2
    return 1
  }
  if jq \
      --arg feat "$branch_name" \
      --arg base "$base_branch" \
      --arg mwp "$main_worktree_path" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      --arg fid "$feat_id" \
      --arg did "$display_id" \
      --arg prefix "$commit_prefix" \
      '.branch.feature = $feat | .branch.base = $base | .branch.main_worktree_path = $mwp | .branch.created_at = $ts | .feat_id = $fid | .feat_display_id = $did | .afk.commit_prefix = $prefix' \
      "$config" > "$tmp" && mv "$tmp" "$config"; then
    :
  else
    rm -f "$tmp" "$config_backup"
    echo "ERROR: create_feature_branch: config write failed after branch '$branch_name' was created — rolling back to '$base_branch' so the retry is not blocked by a branch nothing recorded" >&2
    git -C "$project_root" checkout "$base_branch" >/dev/null 2>&1 \
      || echo "ERROR: create_feature_branch: rollback checkout to '$base_branch' also failed — branch '$branch_name' left on disk, config unchanged" >&2
    git -C "$project_root" branch -D "$branch_name" >/dev/null 2>&1 \
      || echo "ERROR: create_feature_branch: rollback delete of '$branch_name' failed — remove it manually before retrying" >&2
    return 1
  fi

  # Stacking-ready only, and only AFTER the write above commits: registering
  # the layer before the branch/base config write would risk an entry that
  # outlives a subsequent rollback (config restored, registry left stale) —
  # stack-utils.sh is the SOLE writer of stack.layers[], so this file cannot
  # reach in and unwind an entry itself, only redo the write it owns
  # (config.json as a whole). Writing registry last means the ONLY failure
  # left to handle is its own: roll back both the branch and this config
  # write via the pre-write backup captured above.
  if [ "$stack_state" = "ready" ]; then
    if ! declare -F stack_register_layer >/dev/null 2>&1 || ! stack_register_layer "$config" "$feat_id" "$branch_name" "$base_branch"; then
      echo "ERROR: create_feature_branch: stack_register_layer failed after config committed for '$branch_name' — rolling back branch and config to '$base_branch' so config never claims a layer the registry doesn't have" >&2
      if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
        mv "$config_backup" "$config" 2>/dev/null \
          || echo "ERROR: create_feature_branch: restoring config from backup also failed — '$config' may still reference '$branch_name', which is about to be deleted; inspect '$config' manually" >&2
      else
        echo "ERROR: create_feature_branch: no config backup available to restore — '$config' may still reference '$branch_name', which is about to be deleted; inspect '$config' manually" >&2
      fi
      git -C "$project_root" checkout "$base_branch" >/dev/null 2>&1 \
        || echo "ERROR: create_feature_branch: rollback checkout to '$base_branch' also failed — branch '$branch_name' left on disk" >&2
      git -C "$project_root" branch -D "$branch_name" >/dev/null 2>&1 \
        || echo "ERROR: create_feature_branch: rollback delete of '$branch_name' failed — remove it manually before retrying" >&2
      return 1
    fi
    rm -f "$config_backup"
  fi

  if declare -F install_git_hooks >/dev/null 2>&1; then
    install_git_hooks "$project_root" "$config" || true
  else
    # The header guard above now makes non-bash sourcing fail loudly before
    # this function is even defined, so the only way install_git_hooks can
    # still be undefined here is a deployment that never shipped
    # scripts/lib/git-hooks.sh. guards.git_hooks=false is NOT this branch —
    # that skip lives inside install_git_hooks itself. Warn by name instead
    # of skipping silently, so the install is verifiable, not best-effort.
    local git_hooks_guard
    git_hooks_guard=$(jq -r '(.guards.git_hooks // true)' "$config" 2>/dev/null || echo "true")
    if [ "$git_hooks_guard" != "false" ]; then
      echo "WARNING: create_feature_branch: install_git_hooks is undefined (scripts/lib/git-hooks.sh was not sourced) — the managed core.hooksPath install did NOT run." >&2
    fi
  fi

  echo "$branch_name"
}

setup_worktree_dir() {
  local project_root="${1:-$(resolve_project_root)}"
  local config="${2:-$CONFIG}"
  local project_name
  project_name=$(basename "$project_root")
  local worktree_dir
  worktree_dir="$(dirname "$project_root")/${project_name}-worktrees"

  mkdir -p "$worktree_dir"

  # Colocated temp so `mv` is a same-filesystem atomic rename, not a
  # cross-FS copy-then-unlink that could leave $config partially written
  # (PR #74 review). Same reasoning as create_feature_branch above.
  local tmp
  tmp=$(mktemp "$(dirname "$config")/.nazgul-config.XXXXXX" 2>/dev/null) || {
    echo "ERROR: setup_worktree_dir: cannot create a temp file beside '$config'; worktree dir '$worktree_dir' exists on disk but was NOT recorded in config" >&2
    return 1
  }
  jq --arg wd "$worktree_dir" '.branch.worktree_dir = $wd' "$config" > "$tmp" && mv "$tmp" "$config"

  echo "$worktree_dir"
}

create_task_worktree() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local feature_branch
  feature_branch=$(jq -r '.branch.feature // ""' "$config")
  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")

  if [ -z "$feature_branch" ] || [ -z "$worktree_dir" ]; then
    echo "ERROR: feature branch or worktree_dir not configured" >&2
    return 1
  fi

  local task_dir="${worktree_dir}/${task_id}"
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  git -C "$project_root" worktree add "$task_dir" -b "$task_branch" "$feature_branch" 2>/dev/null

  # ADR-008 Option 2: export the MAIN checkout, not $task_dir. nazgul/ is
  # gitignored and per-worktree, so a task worktree never carries its own
  # nazgul/config.json — pointing CLAUDE_PROJECT_DIR at $task_dir would fail
  # resolve_project_root()'s marker validation and could clobber an
  # already-correct value.
  #
  # STATUS: no live caller exercises this. create_task_worktree() has no
  # production caller (real path is the EnterWorktree tool or a raw
  # `git worktree add` — agents/implementer.md:113); the only return channel
  # is `echo "$task_dir"`, so every real caller captures via $(...), and that
  # subshell discards the export before it reaches the caller. Correctly
  # targeted and ready if a future direct (non-subshell) caller is wired up —
  # such a caller would then keep this export for the rest of its own
  # process, including any later unrelated resolve_project_root() calls in
  # that same shell.
  export CLAUDE_PROJECT_DIR="$project_root"

  # Apply sparse checkout if configured
  local sparse_paths
  sparse_paths=$(jq -r '.branch.sparse_paths // empty' "$config" 2>/dev/null || true)
  if [ -n "$sparse_paths" ] && [ "$sparse_paths" != "null" ]; then
    git -C "$task_dir" sparse-checkout init --cone 2>/dev/null || true
    # Read sparse_paths array and set cone patterns
    local paths
    paths=$(jq -r '.branch.sparse_paths[]' "$config" 2>/dev/null || true)
    if [ -n "$paths" ]; then
      echo "$paths" | git -C "$task_dir" sparse-checkout set --stdin 2>/dev/null || true
    fi
  fi

  # Colocated temp — same atomicity reasoning as above (PR #74 review).
  local tmp
  tmp=$(mktemp "$(dirname "$config")/.nazgul-config.XXXXXX" 2>/dev/null) || {
    echo "ERROR: create_task_worktree: cannot create a temp file beside '$config'; task branch '$task_branch' NOT recorded" >&2
    return 1
  }
  jq --arg lb "$task_branch" '.branch.last_task_branch = $lb' "$config" > "$tmp" && mv "$tmp" "$config"

  echo "$task_dir"
}

merge_task_to_feature() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local feature_branch
  feature_branch=$(jq -r '.branch.feature // ""' "$config")
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  git -C "$project_root" checkout "$feature_branch"
  local commit_prefix
  commit_prefix=$(jq -r '.afk.commit_prefix // "feat:"' "$config")
  if ! git -C "$project_root" merge --no-ff -m "${commit_prefix} merge ${task_id}" "$task_branch" 2>/dev/null; then
    git -C "$project_root" merge --abort 2>/dev/null || true
    return 1
  fi
  return 0
}

cleanup_task_worktree() {
  local task_id="$1"
  local project_root="${2:-$(resolve_project_root)}"
  local config="${3:-$CONFIG}"

  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")
  local task_dir="${worktree_dir}/${task_id}"
  local feat_display
  feat_display=$(jq -r '.feat_display_id // "FEAT-000"' "$config")
  local board_issue
  board_issue=$(jq -r '.board.current_issue // ""' "$config")
  local feat_ref="${board_issue:-$feat_display}"
  local task_branch="feat/${feat_ref}/${task_id}"

  if [ -d "$task_dir" ]; then
    git -C "$project_root" worktree remove "$task_dir" --force 2>/dev/null || true
  fi
  git -C "$project_root" branch -D "$task_branch" 2>/dev/null || true
}

cleanup_all_worktrees() {
  local project_root="${1:-$(resolve_project_root)}"
  local config="${2:-$CONFIG}"

  local worktree_dir
  worktree_dir=$(jq -r '.branch.worktree_dir // ""' "$config")

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    # Remove all task worktrees
    for task_dir in "$worktree_dir"/TASK-*; do
      [ -d "$task_dir" ] || continue
      local task_id
      task_id=$(basename "$task_dir")
      cleanup_task_worktree "$task_id" "$project_root" "$config"
    done

    # Remove the parent worktree directory if empty
    rmdir "$worktree_dir" 2>/dev/null || true
  fi

  # uninstall_git_hooks unconditionally restores core.hooksPath — only call it
  # when this objective actually installed (prior_hooks_path recorded), so a
  # repo/objective that never installed can't have its hooksPath touched.
  if declare -F uninstall_git_hooks >/dev/null 2>&1 && [ -f "$config" ]; then
    local hooks_installed
    hooks_installed=$(jq -r '(.branch // {}).prior_hooks_path != null' "$config" 2>/dev/null || echo "false")
    if [ "$hooks_installed" = "true" ]; then
      uninstall_git_hooks "$project_root" "$config" || true
    fi
  fi
}
