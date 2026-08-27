#!/usr/bin/env bash
# Nazgul shared manifest-write primitive (FEAT-036 / ADR-031).
#
# ONE transactional replacement of ONE task manifest: acquire the per-task lock,
# snapshot the live bytes, compare-and-swap the snapshot against them, run the
# caller's producer over the SNAPSHOT, compare-and-swap again, install by atomic
# rename, re-read the installed bytes and run the caller's verify predicate.
#
# It knows locks, snapshots, hashes, renames and read-backs. It knows NOTHING
# about statuses, evidence sections, or the state machine — that separation is
# what keeps scripts/task-transition.sh the sole STATUS authority while sharing
# mechanics with red-run.sh, stop-hook.sh and close-objective.sh (ADR-031).
#
# The lock serializes COOPERATING Nazgul writers. An uncooperative raw filesystem
# write is outside the protocol; no portable Bash makes a rename conditional.
#
# Reentrancy: the mkdir lock is NOT reentrant. `nz_manifest_write` acquires;
# `nz_manifest_write_locked` assumes the caller already holds it. A locked caller
# that reaches for the outer form deadlocks on its own lock.
#
# No top-level side effects. NOT `set -euo pipefail` — this file is SOURCED into
# caller shells and must not alter their options. It must NOT source
# task-transition-guard.sh: that library sources this one.

_NZ_MW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=task-utils.sh
source "$_NZ_MW_DIR/task-utils.sh"
# shellcheck source=sha256.sh
source "$_NZ_MW_DIR/sha256.sh"

# Same body as review-provenance.sh's `_rp_nonce`, not a call to it: that review
# library sits ABOVE this one in the source graph, and a cycle aborts under zsh.
_nz_nonce() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Every refusal names its cause on stderr so two failures can be told apart
# without parsing prose. Usage: _nz_mw_fail <cause> <message>
_nz_mw_fail() {
  printf 'nz_manifest_write: %s (cause: %s)\n' "$2" "$1" >&2
  return 1
}

# Age in whole seconds of a path's mtime. Non-zero when no stat(1) dialect on
# this host can answer, and callers must then fail closed.
_nz_mtime_age_seconds() {
  local path="$1" mtime="" now=""
  mtime=$(stat -f '%m' "$path" 2>/dev/null) || mtime=""
  if [ -z "$mtime" ]; then
    mtime=$(stat -c '%Y' "$path" 2>/dev/null) || mtime=""
  fi
  [ -n "$mtime" ] || return 1
  now=$(date +%s 2>/dev/null) || now=""
  [ -n "$now" ] || return 1
  case "${mtime}${now}" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - mtime))"
}

# Per-task callers pass attempts=1, so an unreclaimable lock wedges every later
# transition for that task until a human runs rmdir.
_NZ_LOCK_ORPHAN_GRACE_SECONDS=30

# Published into the variable NAMED by the caller, so task-transition-guard.sh's
# `_ttg_acquire_lock` alias still publishes TTG_LOCK_TOKEN at the same instant.
_nz_publish_lock_token() {
  printf -v "$1" '%s' "$2"
}

# lean-comments: allow-run — the moved lock's ownership contract; trimming it drops the ABA argument.
# mkdir locks are portable to Bash 3.2 and work across separate command
# processes. Ownership lives in a tokenized owner filename, which makes stale
# reclamation ABA-safe. A dead owner is reclaimable; a live or malformed one
# fails closed; an ownerless directory — a writer killed between its mkdir and
# its owner write — is reclaimable only after the grace period above and only
# through rmdir, which refuses a directory that has since gained an owner.
# Usage: _nz_acquire_lock <lock> [attempts] [delay] [token_var]
_nz_acquire_lock() {
  local lock="$1" attempts="${2:-1}" delay="${3:-0.02}" token_var="${4:-NZ_LOCK_TOKEN}"
  local n=0 owner="" owner_pid="" owner_token="" owner_file="" owner_leaf="" token="" lock_age=""
  local -a owner_files
  [[ "$token_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _nz_publish_lock_token "$token_var" ""
  token=$(_nz_nonce) || token=""
  [ -n "$token" ] || return 1
  while [ "$n" -lt "$attempts" ]; do
    if { [ -e "$lock" ] || [ -L "$lock" ]; } \
      && { [ ! -d "$lock" ] || [ -L "$lock" ]; }; then
      return 1
    fi
    if mkdir "$lock" 2>/dev/null; then
      owner_file="$lock/owner.$$.${token}"
      # Published before the write so a signal in this window still reaches the
      # caller's release trap with the directory this call created.
      _nz_publish_lock_token "$token_var" "$token"
      if ! printf '%s %s\n' "$$" "$token" > "$owner_file"; then
        _nz_publish_lock_token "$token_var" ""
        rmdir "$lock" 2>/dev/null || true
        return 1
      fi
      owner_files=("$lock"/owner.*)
      if [ "${#owner_files[@]}" -eq 1 ] && [ "${owner_files[0]}" = "$owner_file" ]; then
        return 0
      fi
      # A grace reclaim took the directory mid-claim and the owner file above
      # landed in a successor's lock; withdraw rather than co-own it.
      _nz_publish_lock_token "$token_var" ""
      rm -f "$owner_file" 2>/dev/null || true
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    fi

    owner=""
    owner_files=("$lock"/owner.*)
    if [ "${#owner_files[@]}" -eq 1 ] \
      && [ ! -e "${owner_files[0]}" ] && [ ! -L "${owner_files[0]}" ]; then
      lock_age=$(_nz_mtime_age_seconds "$lock") || lock_age=""
      if [ -n "$lock_age" ] && [ "$lock_age" -ge "$_NZ_LOCK_ORPHAN_GRACE_SECONDS" ] \
        && rmdir "$lock" 2>/dev/null; then
        continue
      fi
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    fi
    [ "${#owner_files[@]}" -eq 1 ] || {
      n=$((n + 1))
      [ "$n" -lt "$attempts" ] && sleep "$delay"
      continue
    }
    owner_file="${owner_files[0]}"
    [ -f "$owner_file" ] && [ ! -L "$owner_file" ] \
      && IFS= read -r owner < "$owner_file" || true
    owner_pid=${owner%% *}
    owner_token=${owner#* }
    owner_leaf=${owner_file##*/}
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] \
      && [[ "$owner_token" =~ ^[0-9a-f]+$ ]] \
      && [ "$owner_leaf" = "owner.${owner_pid}.${owner_token}" ] \
      && ! kill -0 "$owner_pid" 2>/dev/null; then
      if rm "$owner_file" 2>/dev/null && rmdir "$lock" 2>/dev/null; then
        continue
      fi
    fi
    n=$((n + 1))
    [ "$n" -lt "$attempts" ] && sleep "$delay"
  done
  return 1
}

# Usage: _nz_release_lock <lock> <token>
_nz_release_lock() {
  local lock="$1" token="$2" owner="" owner_file=""
  owner_file="$lock/owner.$$.${token}"
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  if [ ! -e "$owner_file" ] && [ ! -L "$owner_file" ]; then
    # Claimed but never owned: clear it rather than waiting out the orphan
    # grace. rmdir refuses a directory holding anyone else's owner file.
    rmdir "$lock" 2>/dev/null
    return
  fi
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] \
    && IFS= read -r owner < "$owner_file" || true
  [ "$owner" = "$$ $token" ] || return 1
  rm "$owner_file" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null
}

# The SINGLE source of a task's lock path — two writers on two lock paths pass a naive
# interleaving test by luck. Usage: nz_manifest_lock_path <state_root> <task_id> [create]
nz_manifest_lock_path() {
  local state_root="${1:-}" task_id="${2:-}" create="${3:-true}" root_real path real
  [[ "$task_id" =~ ^(TASK|PATCH)-[0-9]+$ ]] \
    || _nz_mw_fail bad_arguments "task id must match TASK-[0-9]+ or PATCH-[0-9]+, got '${task_id}'" || return 1
  { [ -d "$state_root" ] && [ ! -L "$state_root" ]; } \
    || _nz_mw_fail state_root_unusable "${state_root:-<unnamed>} is not a regular non-symlink directory" || return 1
  root_real=$(cd "$state_root" 2>/dev/null && pwd -P) || root_real=""
  [ -n "$root_real" ] \
    || _nz_mw_fail state_root_unusable "could not resolve ${state_root}" || return 1
  path="$root_real/locks"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    [ "$create" = "true" ] \
      || _nz_mw_fail locks_dir_unusable "${path} does not exist and creation was not requested" || return 1
    mkdir "$path" 2>/dev/null \
      || _nz_mw_fail locks_dir_unusable "could not create ${path}" || return 1
  fi
  { [ -d "$path" ] && [ ! -L "$path" ]; } \
    || _nz_mw_fail locks_dir_unusable "${path} is not a regular non-symlink directory" || return 1
  real=$(cd "$path" 2>/dev/null && pwd -P) || real=""
  [ "$real" = "$path" ] \
    || _nz_mw_fail locks_dir_unusable "${path} does not resolve to itself" || return 1
  printf '%s\n' "$real/task-transition-${task_id}.lock"
}

# lean-comments: allow-run — the refusal rule, and why the address space has two shapes.
# A symlink destination is refused by its own name: a write through one installs over
# whatever it aims at (PATCH-005). Usage: _nz_manifest_path <state_root> <task_id>
# Two manifest shapes, because /nazgul:patch writes PATCH-NNN under tasks/patches/ and a
# primitive that cannot address it leaves that route with no locked, atomic, read-back
# install — which is how red-run lost the capability entirely rather than routing it.
# The patches/ level gets the SAME discipline as tasks/: regular, non-symlink, resolving
# to itself, with the final parent re-checked so no component can escape.
_nz_manifest_path() {
  local state_root="${1:-}" task_id="${2:-}" root_real tasks_real file parent_real dir_real
  [[ "$task_id" =~ ^(TASK|PATCH)-[0-9]+$ ]] \
    || _nz_mw_fail bad_arguments "task id must match TASK-[0-9]+ or PATCH-[0-9]+, got '${task_id}'" || return 1
  { [ -d "$state_root" ] && [ ! -L "$state_root" ]; } \
    || _nz_mw_fail state_root_unusable "${state_root:-<unnamed>} is not a regular non-symlink directory" || return 1
  root_real=$(cd "$state_root" 2>/dev/null && pwd -P) || root_real=""
  [ -n "$root_real" ] \
    || _nz_mw_fail state_root_unusable "could not resolve ${state_root}" || return 1
  { [ -d "$root_real/tasks" ] && [ ! -L "$root_real/tasks" ]; } \
    || _nz_mw_fail tasks_dir_unusable "${root_real}/tasks is not a regular non-symlink directory" || return 1
  tasks_real=$(cd "$root_real/tasks" 2>/dev/null && pwd -P) || tasks_real=""
  [ "$tasks_real" = "$root_real/tasks" ] \
    || _nz_mw_fail tasks_dir_unusable "${root_real}/tasks does not resolve to itself" || return 1
  dir_real="$tasks_real"
  if [[ "$task_id" == PATCH-* ]]; then
    { [ -d "$tasks_real/patches" ] && [ ! -L "$tasks_real/patches" ]; } \
      || _nz_mw_fail tasks_dir_unusable "${tasks_real}/patches is not a regular non-symlink directory" || return 1
    dir_real=$(cd "$tasks_real/patches" 2>/dev/null && pwd -P) || dir_real=""
    [ "$dir_real" = "$tasks_real/patches" ] \
      || _nz_mw_fail tasks_dir_unusable "${tasks_real}/patches does not resolve to itself" || return 1
  fi
  file="$dir_real/$task_id.md"
  [ ! -L "$file" ] \
    || _nz_mw_fail symlink_destination "refusing to write ${file}: it is a symlink" || return 1
  [ -f "$file" ] \
    || _nz_mw_fail no_manifest "no regular task manifest for ${task_id} under ${dir_real}" || return 1
  parent_real=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || parent_real=""
  [ "$parent_real" = "$dir_real" ] \
    || _nz_mw_fail symlink_destination "refusing to write ${file}: its parent escapes ${dir_real}" || return 1
  printf '%s\n' "$file"
}

# Default read-back predicate: non-empty, and still parses to a status the state
# machine knows. Usage: _nz_default_verify <manifest-path>
_nz_default_verify() {
  local file="$1" status
  [ -s "$file" ] || {
    printf 'nz_manifest_write: installed manifest %s is empty\n' "$file" >&2
    return 1
  }
  status=$(get_task_status "$file" "") || status=""
  _in_list "$status" "$VALID_STATUSES" && return 0
  printf 'nz_manifest_write: installed manifest %s parses to %s, which is not a valid status\n' \
    "$file" "${status:-<missing>}" >&2
  return 1
}

# lean-comments: allow-run — why cleanup is registered rather than trapped here
# The two colocated temp files in flight, published so the lock wrapper's SUBSHELL trap can
# reclaim them. A `trap … EXIT` set here instead would run in the CALLER's shell and silently
# replace whatever trap that caller had already installed, so the cleanup is registered where a
# trap already exists rather than by adding a second one that fights the first.
_NZ_MW_SNAPSHOT=""
_NZ_MW_STAGE=""
_NZ_MW_ROLLBACK=""
# shellcheck disable=SC2034  # published for the SOURCING shell: 1 iff the new bytes are the
# manifest on disk, 0 otherwise. It is the machine-readable form of the verify_failed (rolled
# back, file unchanged) vs verify_failed_unrestored (file HOLDS the rejected bytes) split, so a
# caller need not parse stderr to know whether anything landed. NO ADOPTER READS IT YET —
# stated rather than implied, because a published signal with no consumer is a claim, not a
# contract.
NZ_MW_INSTALLED=0
NZ_MW_BEFORE_HASH=""

_nz_mw_cleanup() {
  [ -z "${_NZ_MW_SNAPSHOT:-}" ] || rm -f "$_NZ_MW_SNAPSHOT"
  [ -z "${_NZ_MW_STAGE:-}" ] || rm -f "$_NZ_MW_STAGE"
  # A caller that must PRESERVE the pre-write bytes past a refusal clears _NZ_MW_ROLLBACK
  # first — that is how verify_failed_unrestored keeps the only good copy on disk.
  [ -z "${_NZ_MW_ROLLBACK:-}" ] || rm -f "$_NZ_MW_ROLLBACK"
  _NZ_MW_SNAPSHOT=""
  _NZ_MW_STAGE=""
  _NZ_MW_ROLLBACK=""
}

# Steps 2-7 of the protocol. ASSUMES THE CALLER ALREADY HOLDS THE LOCK.
# Usage: nz_manifest_write_locked <state_root> <task_id> [--verify <fn>] -- <producer…>
nz_manifest_write_locked() {
  local state_root="${1:-}" task_id="${2:-}"
  local verify_fn="_nz_default_verify" file mode snapshot stage before_hash current_hash rollback
  [ "$#" -ge 2 ] \
    || _nz_mw_fail bad_arguments "usage: nz_manifest_write_locked <state_root> <task_id> [--verify <fn>] -- <producer…>" || return 1
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verify)
        [ "$#" -ge 2 ] || _nz_mw_fail bad_arguments "--verify needs a function name" || return 1
        verify_fn="$2"; shift 2 ;;
      --verify=*) verify_fn="${1#--verify=}"; shift ;;
      --) shift; break ;;
      *) _nz_mw_fail bad_arguments "unexpected argument '${1}'; the producer must follow a '--' separator" || return 1 ;;
    esac
  done
  [ "$#" -ge 1 ] || _nz_mw_fail bad_arguments "no producer command was given after '--'" || return 1
  # A verify predicate is a shell FUNCTION named by the caller: never eval'd from
  # config, never sourced from a path under nazgul/.
  { [[ "$verify_fn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "$verify_fn" >/dev/null 2>&1; } \
    || _nz_mw_fail verify_not_a_function "--verify '${verify_fn}' is not a defined shell function" || return 1

  file=$(_nz_manifest_path "$state_root" "$task_id") || return 1
  mode=$(nz_file_mode "$file") \
    || _nz_mw_fail mode_unreadable "no stat dialect on this host could read the mode of ${file}" || return 1
  # mktemp, never a predictable sibling: a predictable name can be pre-created as a
  # symlink, and the redirection then installs over whatever it aims at (PATCH-005).
  NZ_MW_INSTALLED=0
  NZ_MW_BEFORE_HASH=""
  snapshot=$(mktemp "${file%/*}/.${task_id}.snapshot.XXXXXX") \
    || _nz_mw_fail stage_failed "could not create a colocated snapshot beside ${file}" || return 1
  _NZ_MW_SNAPSHOT="$snapshot"
  stage=$(mktemp "${file%/*}/.${task_id}.stage.XXXXXX") || {
    _nz_mw_cleanup
    _nz_mw_fail stage_failed "could not create a colocated staging file beside ${file}"
    return 1
  }
  _NZ_MW_STAGE="$stage"
  # lean-comments: allow-run — why there are TWO pre-write copies and not one
  # The snapshot is handed to the PRODUCER, and both shipped status producers write to it
  # in place (set_task_status "$snapshot" ...). The rollback below therefore cannot restore
  # from it: it would install the producer's mutated bytes and call them "pre-write content"
  # (confirmed, PR #293 round 2). The rollback copy is never passed to anyone, so it still
  # holds the manifest exactly as it was read. Two copies is the cost of a producer contract
  # this library cannot enforce on callers it does not own.
  rollback=$(mktemp "${file%/*}/.${task_id}.rollback.XXXXXX") || {
    _nz_mw_cleanup
    _nz_mw_fail stage_failed "could not create a colocated rollback copy beside ${file}"
    return 1
  }
  _NZ_MW_ROLLBACK="$rollback"
  if ! cp "$file" "$snapshot"; then
    _nz_mw_cleanup
    _nz_mw_fail stage_failed "could not snapshot ${task_id}"
    return 1
  fi
  # The SECOND pre-write copy, taken from the same source in the same critical section.
  # This one is never handed to the producer, so it stays byte-identical to what was read.
  if ! cp "$file" "$rollback"; then
    _nz_mw_cleanup
    _nz_mw_fail stage_failed "could not take the rollback copy of ${task_id}"
    return 1
  fi

  before_hash=$(nz_sha256 < "$snapshot") || before_hash=""
  # lean-comments: allow-run — why the snapshot outlives the rename
  # Published so the producer does not hash the same unmodified bytes a second time. The
  # ledger records this value as before_sha256, and two independent computations of one
  # number are two things that can disagree — including silently, if the two hash helpers
  # are ever changed apart. One computation, one authority.
  # shellcheck disable=SC2034  # published for the SOURCING shell, not read within this file:
  # task-transition-guard.sh:2089 reads it into _TTG_STAGED_BEFORE_HASH. Publishing the hash the
  # primitive already computed is what removes the second source of truth for the ledger's
  # before_sha256 (PR #293 finding 13) — a recomputation could diverge silently if the two hash
  # helpers were ever changed independently.
  NZ_MW_BEFORE_HASH="$before_hash"
  if [ -z "$before_hash" ]; then
    _nz_mw_cleanup
    _nz_mw_fail digest_unavailable "no SHA-256 implementation available for snapshot comparison"
    return 1
  fi
  current_hash=$(nz_sha256 < "$file") || current_hash=""
  if [ -z "$current_hash" ] || [ "$current_hash" != "$before_hash" ]; then
    _nz_mw_cleanup
    _nz_mw_fail cas_mismatch_snapshot "${task_id} changed while its snapshot was taken; concurrent content preserved"
    return 1
  fi

  # The producer reads the SNAPSHOT, never the live file: that is what puts the
  # read-modify-write inside the compare-and-swap rather than merely before it.
  if ! "$@" "$snapshot" > "$stage"; then
    _nz_mw_cleanup
    _nz_mw_fail producer_failed "the producer for ${task_id} returned non-zero; ${file} is unchanged"
    return 1
  fi
  if [ ! -s "$stage" ]; then
    _nz_mw_cleanup
    _nz_mw_fail producer_empty "the producer for ${task_id} produced no output; ${file} is unchanged"
    return 1
  fi

  current_hash=$(nz_sha256 < "$file") || current_hash=""
  if [ -z "$current_hash" ] || [ "$current_hash" != "$before_hash" ]; then
    _nz_mw_cleanup
    _nz_mw_fail cas_mismatch_install "${task_id} changed while its replacement was produced; concurrent content preserved"
    return 1
  fi

  if ! chmod "$mode" "$stage"; then
    _nz_mw_cleanup
    _nz_mw_fail mode_preserve_failed "could not preserve the ${mode} mode of ${file}"
    return 1
  fi
  if ! mv "$stage" "$file"; then
    _nz_mw_cleanup
    _nz_mw_fail install_failed "atomic manifest replace failed for ${task_id}"
    return 1
  fi
  _NZ_MW_STAGE=""
  NZ_MW_INSTALLED=1

  # lean-comments: allow-run — why the read-back is fatal, and why the snapshot outlives it.
  # A failing read-back is a loud non-zero, never a warning: nz_rewrite_file returns 0
  # on a no-op, which is how a caller could once print `recorded` over an unchanged record.
  #
  # The snapshot is kept until AFTER this read-back, because `verify_failed` was the one
  # cause that fired on the far side of the rename and so the one refusal that CHANGED the
  # manifest — while every adopter's diagnostic said a refused write leaves the file
  # untouched. Two of the three said it in those words. Rather than teach three callers to
  # special-case one cause, the ROLLBACK makes the sentence true: a refused write never
  # leaves changed bytes on disk. The restore is the same atomic rename, so it cannot tear.
  if ! "$verify_fn" "$file"; then
    # The rollback carries the file's ORIGINAL mode: mktemp creates at 0600, and renaming
    # that over a 0644 manifest silently downgrades it (confirmed, PR #293 round 2). Mode
    # preservation has its own named refusal on the forward path; the restore owes the same.
    if chmod "$mode" "$rollback" 2>/dev/null && mv "$rollback" "$file"; then
      _NZ_MW_ROLLBACK=""
      # shellcheck disable=SC2034  # same published signal as at the top of this file
      NZ_MW_INSTALLED=0
      _nz_mw_fail verify_failed "${task_id} was written but ${verify_fn} rejected the installed bytes; the write was ROLLED BACK and ${file} holds its pre-write content, at its original ${mode} mode"
      return 1
    fi
    # lean-comments: allow-run — why the hash is published rather than recomputed
    # The restore itself failed, so the rejected bytes ARE the manifest. This is the only
    # state in which a refusal leaves the file changed, and it gets its own cause name so no
    # caller can report it with the sentence that fits every other refusal.
    # DO NOT clean up here. The rejected bytes ARE the manifest, and this copy is the only
    # surviving one of the good content — deleting it makes the human read this message
    # demands impossible for every adopter except close-objective.sh, which keeps its own.
    # The path is NAMED so the recovery is mechanical rather than a hunt.
    _NZ_MW_ROLLBACK=""
    _nz_mw_cleanup
    _nz_mw_fail verify_failed_unrestored "${task_id} was written, ${verify_fn} rejected the installed bytes, AND the rollback to its pre-write content FAILED; ${file} holds bytes a read-back declared bad. Its PRE-WRITE content is preserved at ${rollback} — read both before transitioning anything on this task"
    return 1
  fi
  _nz_mw_cleanup
  return 0
}

# Run <command…> under the per-task lock, for a caller needing several writes in ONE
# critical section. Usage: nz_manifest_with_lock <state_root> <task_id> <command…>
nz_manifest_with_lock() {
  local state_root="${1:-}" task_id="${2:-}" lock
  [ "$#" -ge 3 ] \
    || _nz_mw_fail bad_arguments "usage: nz_manifest_with_lock <state_root> <task_id> <command…>" || return 1
  shift 2
  lock=$(nz_manifest_lock_path "$state_root" "$task_id") || return 1
  (
    # Keyed on the token _nz_acquire_lock publishes before it writes its owner
    # file, so no signal window can skip the release.
    NZ_LOCK_TOKEN=""
    trap '_nz_mw_cleanup; [ -z "${NZ_LOCK_TOKEN:-}" ] || _nz_release_lock "$lock" "$NZ_LOCK_TOKEN" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # lean-comments: allow-run — why this retries instead of trying once
    # One attempt turned TRANSIENT contention into a silently skipped state change. Every
    # stop-hook status install and field upsert contends on the same per-task lock
    # task-transition.sh holds for the duration of a transition, so a transition merely
    # IN FLIGHT when the Stop hook ran made the reconciliation quarantine, the git-conflict
    # block and both review-gate demotion ladders simply not happen — each reported once and
    # then dropped. ttg_log_transition already uses 200 x 0.01s for its far less
    # consequential LEDGER lock; the manifest lock owed at least as much. ~2s bounded, so a
    # genuinely held lock still fails closed rather than hanging the hook.
    if ! _nz_acquire_lock "$lock" "${NZ_MW_LOCK_ATTEMPTS:-200}" "${NZ_MW_LOCK_DELAY:-0.01}"; then
      _nz_mw_fail lock_unavailable "another transition already holds the ${task_id} lock (still held after ${NZ_MW_LOCK_ATTEMPTS:-200} attempts)"
      exit 1
    fi
    "$@"
  )
}

# Outer form: acquire the lock, then run steps 2-7 through the inner form.
# Usage: nz_manifest_write <state_root> <task_id> [--verify <fn>] -- <producer…>
nz_manifest_write() {
  [ "$#" -ge 2 ] \
    || _nz_mw_fail bad_arguments "usage: nz_manifest_write <state_root> <task_id> [--verify <fn>] -- <producer…>" || return 1
  nz_manifest_with_lock "$1" "$2" nz_manifest_write_locked "$@"
}
