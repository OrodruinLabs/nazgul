#!/usr/bin/env bash
# Nazgul merge-provider — the FEAT-031 (ADR-023) merge-OBSERVATION seam, sibling
# to the FEAT-009 inbox seam (`scripts/lib/inbox-provider.sh`). Three functions
# form the contract: detect the host from `git remote get-url`, ask that host's
# PR API for merge state, and report whether the detected arm is usable now.
# Callers never speak `gh`.
#
# WHY THE HOST'S PR API AND NEVER GIT ANCESTRY (ADR-023 decision 1 — do not
# "simplify" this into a `git merge-base --is-ancestor` check): after a
# server-side SQUASH merge, no SHA recorded in any manifest's `## Commits`
# section is an ancestor of the base branch. Ancestry therefore reports "not
# shipped" for work that demonstrably shipped — on a squash host the check is
# not merely weak, it is inverted. Ancestry may CORROBORATE a merge the API
# already confirmed; it is never a predicate, and this library does not consult
# it at all. Nor does this library ever fall back to it when the API is
# unreachable: an unreachable API is `api_failure`, a state of its own.
#
# THE DELIBERATE DEVIATION FROM inbox-provider.sh: degradation here is LOUD and
# NAMED, never an empty result. "no candidates" is a legitimate inbox state, so
# that seam degrades to empty; here an empty result is indistinguishable from
# "nothing to close", which is precisely the silence this seam was filed
# against. Every answer below is its own token — `ok` (the host answered) is
# never confused with `api_failure`/`provider_unavailable`/`unsupported_host`/
# `no_remote`/`invalid_pr` (could not look), and each carries a stderr
# diagnostic plus a telemetry record.
#
# Credentials come from the host CLI's own auth (`gh auth`) only — no token is
# read from, written to, or logged via config (RULES.md §16). Remote URLs and
# API responses are DATA: never `eval`'d, never shell-expanded, reaching `jq`
# only via --arg. Host stderr is redacted for token-shaped substrings before it
# is echoed or emitted.
#
# EVERY `gh` CALL HERE IS BOUNDED (TASK-048). This library is reached from the
# `IMPLEMENTED -> DONE` merge-evidence gate, which is the worst place in the state
# machine for an unbounded wait: the loop stops with no verdict, no event and no
# diagnostic, indistinguishable from a slow network. `scripts/lib/bounded-net.sh`
# supplies both halves — a duration bound and the prompt suppression `</dev/null`
# cannot do, since a credential helper reads /dev/tty and not stdin. A bound that
# fires is `api_failure` by the rule already stated above: it is emphatically NOT a
# quietly not-merged `ok`.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# that own their own shell options. Path resolution and bounded-net's
# non-interactive exports run at source time; the telemetry lib is sourced
# lazily, per call, inside a subshell.
#
# BECAUSE the caller owns those options, every assignment below whose command
# substitution can exit non-zero is written `x=$(...) || rc=$?` with `rc`
# pre-initialised — never `x=$(...); rc=$?`, which is a FAILING SIMPLE COMMAND
# under the caller's `set -e`. The substitutions that exit non-zero are exactly
# the named degradations (`no_remote`, `unsupported_host`, `api_failure`), so
# that form aborted the caller before `_mp_warn`, before `_mp_emit` and before
# the token reached stdout. A degradation that kills its caller before naming
# itself is not a named degradation — it is the silence this file was written
# against. The caller may still exit on the non-zero RETURN below (that is the
# documented contract, like `grep`'s), but it exits having been told why.

# RE-SOURCE GUARD: an ARRAY marker, not a scalar and not `declare -F` — bounded-net.sh's header
# carries the measurement, including the `export -f` shape that defeats `declare -F`.
[ "${_NZ_MERGE_PROVIDER_LOADED[1]:-}" = "loaded" ] && return 0
_NZ_MERGE_PROVIDER_LOADED=(0 loaded)

_MERGE_PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./bounded-net.sh
. "$_MERGE_PROVIDER_LIB_DIR/bounded-net.sh"

# _mp_warn <message...> -> one `merge-provider: ` stderr line. This is the PRIMARY
# signal; telemetry no-ops on an uninitialised tree, so it can never be the only one.
_mp_warn() {
  printf 'merge-provider: %s\n' "$*" >&2
}

# _mp_emit <project_root> <event_type> [k v ...] -> emit_event against <project_root>'s
# nazgul/ tree, resolved per CALL (ADR-021: a source-time root freezes EVENTS_FILE).
_mp_emit() {
  local root="$1" event="$2" nazgul_dir=""
  shift 2
  if [ -n "$root" ] && [ -f "$root/nazgul/config.json" ]; then
    nazgul_dir="$root/nazgul"
  elif [ -n "${NAZGUL_DIR:-}" ] && [ -f "${NAZGUL_DIR}/config.json" ]; then
    nazgul_dir="$NAZGUL_DIR"
  else
    return 0
  fi
  [ -f "$_MERGE_PROVIDER_LIB_DIR/emit-event.sh" ] || return 0
  (
    NAZGUL_DIR="$nazgul_dir"
    # shellcheck disable=SC2034  # read by emit_event, sourced just below
    EVENTS_FILE="$NAZGUL_DIR/logs/events.jsonl"
    # shellcheck source=./emit-event.sh
    . "$_MERGE_PROVIDER_LIB_DIR/emit-event.sh"
    emit_event "$event" "$@"
  ) >/dev/null 2>&1 || true
  return 0
}

# lean-comments: allow-run — the userinfo rule is the one a reader would drop as redundant.
# _mp_redact <text> -> token-shaped substrings replaced by ***. A diagnostic built
# from remote stderr is the one place a credential could reach a log (RULES.md §16).
# The userinfo rule is not about remote stderr: `--pr` is operator input that may be a
# `scheme://user:secret@host/...` URL, and an unnormalisable one is warned, emitted onto
# the bus, and returned as `.pr` — so a host-shaped token rule alone leaks basic-auth
# passwords and any non-`gh` PAT verbatim into nazgul/logs/events.jsonl.
_mp_redact() {
  printf '%s' "$1" | sed -E \
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1***@#g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]{8,}/***/g' \
    -e 's/github_pat_[A-Za-z0-9_]{8,}/***/g' \
    -e 's/(Bearer|token|Authorization:)[[:space:]]+[A-Za-z0-9._~+\/-]{8,}=*/\1 ***/gi'
}

# _mp_oneline <text> -> <text> collapsed to a single redacted line, bounded, so
# a diagnostic can never smuggle newlines into a log record.
_mp_oneline() {
  _mp_redact "$1" | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400
}

# _mp_remote_url <project_root> -> `origin`'s URL, else the first remote's; empty +
# return 1 when there is none. UNTRUSTED, for matching only — never eval'd.
_mp_remote_url() {
  local root="$1" url first
  [ -n "$root" ] || return 1
  url=$(git -C "$root" remote get-url origin 2>/dev/null) || url=""
  if [ -z "$url" ]; then
    first=$(git -C "$root" remote 2>/dev/null | head -n1) || first=""
    [ -n "$first" ] || return 1
    url=$(git -C "$root" remote get-url "$first" 2>/dev/null) || url=""
  fi
  [ -n "$url" ] || return 1
  printf '%s' "$url"
}

# _mp_url_host <url> -> lowercased host, empty when there is none. Pure parameter
# expansion; handles scheme://[user@]host[:port]/path and the scp-like form.
_mp_url_host() {
  local url="$1" rest authority
  rest="${url#*://}"
  authority="${rest%%/*}"
  authority="${authority##*@}"
  authority="${authority%%:*}"
  printf '%s' "$authority" | tr '[:upper:]' '[:lower:]'
}

# _mp_provider_for_host <host> -> the arm serving <host>, empty when none does. Only
# github.com is claimed — a GHE host is `unsupported_host`, never a silent assumption.
_mp_provider_for_host() {
  case "$1" in
    github.com|www.github.com) printf 'github' ;;
    *) printf '' ;;
  esac
}

# _mp_url_repo <url> -> lowercased "owner/repo", empty + return 1 when the URL names
# none. Handles scheme://[user@]host/owner/repo[...] and the scp-like host:owner/repo.
_mp_url_repo() {
  local url="$1" path owner rest repo
  case "$url" in
    *://*) path="${url#*://}"; path="${path#*/}" ;;
    *:*)   path="${url#*:}" ;;
    *)     path="$url" ;;
  esac
  path="${path%%\?*}"
  path="${path%%#*}"
  path="${path#/}"
  owner="${path%%/*}"
  rest="${path#*/}"
  repo="${rest%%/*}"
  repo="${repo%.git}"
  { [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$path" ]; } || return 1
  printf '%s' "$owner/$repo" | tr '[:upper:]' '[:lower:]'
}

# lean-comments: allow-run — where the line is drawn, and why a narrower one is a false refusal.
# _mp_ref_ok <ref> -> 0 iff <ref> is a name git itself would accept for a branch. Branch names are
# the only remote-authored strings this seam carries; one that fails this is DROPPED, never passed
# on. The line is git's own refname rule (check_refname_format with one level allowed), pinned in
# both directions against `git check-ref-format --branch` by the suite — NOT a narrower ASCII
# allowlist. A legal name refused here has its head_ref blanked, which the merge-evidence gate reads
# as `ok_no_head_ref` and refuses as `unverifiable`; that gate has no kill switch (RULES.md §2), so a
# false refusal leaves a genuinely merged objective with NO route to DONE, blaming the host for an
# answer it got right. `_hotfix/x`, `feat/a+b` and a UTF-8 name are branches git accepts and this
# seam now carries. What it still rejects: whitespace and control characters (which no one-line
# record could carry anyway), git's forbidden metacharacters `~ ^ : ? * [ \`, the forbidden sequences
# (`..`, `@{`, `//`, leading/trailing `/`, a leading dot on any component, a trailing `.` or
# `.lock`), and a bare `@`. Two rules are ours rather than git's, and both are about carrying the
# value rather than about git: the 255-byte ceiling, and a leading `-`, which any CLI it reaches
# could read as a flag — `git check-ref-format --branch` refuses that one too, so it is not a
# divergence.
_mp_ref_ok() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  [ "${#ref}" -le 255 ] || return 1
  case "$ref" in
    -*|/*|*/|@) return 1 ;;
    .*|*/.*) return 1 ;;
    *.|*.lock|*.lock/*) return 1 ;;
    *..*|*//*|*@\{*) return 1 ;;
    *[~^:?*'['\\]*) return 1 ;;
    *[[:cntrl:][:space:]]*) return 1 ;;
  esac
  return 0
}

# lean-comments: allow-run — the NAZGUL_MERGE_PROVIDER escape hatch is the one thing
# here a reader must not discover by accident.
# _mp_detect_raw <project_root> -> "<provider_or_state>\t<host>", returning 0/2/3 for
# detected/unsupported_host/no_remote. The SILENT half of merge_provider_detect, so a
# caller emitting its own contextual telemetry never double-records one fact.
# NAZGUL_MERGE_PROVIDER overrides detection when set (explicit operator/test
# designation); an unrecognised value is NOT defaulted — it reaches the refusal arm.
_mp_detect_raw() {
  local root="$1" url host provider
  if [ -n "${NAZGUL_MERGE_PROVIDER:-}" ]; then
    printf '%s\t%s' "$NAZGUL_MERGE_PROVIDER" ""
    [ "$NAZGUL_MERGE_PROVIDER" = "github" ] && return 0
    return 2
  fi
  url=$(_mp_remote_url "$root") || { printf '%s\t%s' "no_remote" ""; return 3; }
  host=$(_mp_url_host "$url")
  if [ -z "$host" ]; then
    printf '%s\t%s' "unsupported_host" ""
    return 2
  fi
  provider=$(_mp_provider_for_host "$host")
  if [ -z "$provider" ]; then
    printf '%s\t%s' "unsupported_host" "$host"
    return 2
  fi
  printf '%s\t%s' "$provider" "$host"
  return 0
}

# lean-comments: allow-run — public seam contract; callers depend on these exact tokens.
# merge_provider_detect <project_root> -> the provider name serving this repo's remote
# ("github"), or the NAMED degradation replacing it: "unsupported_host" (a remote
# exists, no arm serves its host) or "no_remote" (nothing to inspect). Exit 0 / 2 / 3,
# so "found github" and "could not find a provider" are never the same answer. Each
# degradation is loud on stderr and on the bus, and never falls back to git ancestry.
merge_provider_detect() {
  local root="${1:-}" raw name host rc=0
  raw=$(_mp_detect_raw "$root") || rc=$?
  name="${raw%%$'\t'*}"
  host="${raw#*$'\t'}"
  case "$rc" in
    0) printf '%s\n' "$name"; return 0 ;;
    2)
      _mp_warn "unsupported_host: no merge-state provider serves remote host '${host:-<none>}' — merge state cannot be verified here, and this seam never falls back to git ancestry"
      _mp_emit "$root" "merge_provider_unsupported_host" host "$host" project_root "$root"
      printf '%s\n' "unsupported_host"
      return 2 ;;
    *)
      _mp_warn "no_remote: no git remote is configured under '${root:-<empty>}' — there is no host to ask, which is NOT the same as 'not merged'"
      _mp_emit "$root" "merge_provider_no_remote" project_root "$root"
      printf '%s\n' "no_remote"
      return 3 ;;
  esac
}

# _mp_github_health -> 0 iff the github arm is usable now: `gh` installed and
# authenticated. Auth is `gh auth` only; no credential is read from config.
_mp_github_health() {
  command -v gh >/dev/null 2>&1 || { printf '%s' "gh is not installed"; return 1; }
  nz_bounded_run_q quick "gh auth status (merge-provider health)" gh auth status >/dev/null \
    || { printf '%s' "gh is not authenticated, or the check exceeded its bound (run: gh auth login)"; return 1; }
  return 0
}

# lean-comments: allow-run — public seam contract; the two unusable states differ.
# merge_provider_health <project_root> -> "ready" / "unsupported_host" / "no_remote" /
# "provider_unavailable" (exit 0 / 2 / 3 / 4). "provider_unavailable" means an arm
# EXISTS but cannot run now (tool missing, unauthenticated) — deliberately distinct
# from having no arm at all, because the operator's remedy differs for each.
merge_provider_health() {
  local root="${1:-}" raw provider host why rc=0
  raw=$(_mp_detect_raw "$root") || rc=$?
  provider="${raw%%$'\t'*}"
  host="${raw#*$'\t'}"
  if [ "$rc" -eq 3 ]; then
    _mp_warn "no_remote: no git remote is configured under '${root:-<empty>}'"
    _mp_emit "$root" "merge_provider_no_remote" project_root "$root"
    printf '%s\n' "no_remote"
    return 3
  fi
  if [ "$rc" -ne 0 ]; then
    _mp_warn "unsupported_host: no merge-state provider serves '${provider}'${host:+ (host ${host})}"
    _mp_emit "$root" "merge_provider_unsupported_host" host "$host" project_root "$root"
    printf '%s\n' "unsupported_host"
    return 2
  fi
  case "$provider" in
    github) why=$(_mp_github_health) || {
        _mp_warn "provider_unavailable: github arm cannot run — $why"
        _mp_emit "$root" "merge_provider_unavailable" provider "github" host "$host" reason "$why"
        printf '%s\n' "provider_unavailable"
        return 4
      } ;;
    *)
      _mp_warn "unsupported_host: no arm implements provider '$provider'"
      _mp_emit "$root" "merge_provider_unsupported_host" host "$host" provider "$provider" project_root "$root"
      printf '%s\n' "unsupported_host"
      return 2 ;;
  esac
  printf '%s\n' "ready"
  return 0
}

# lean-comments: allow-run — the three-valued `merged` is the seam's whole point.
# _mp_result <provider> <host> <pr> <result> <state> <merged> <merged_at> <merge_commit>
# <diagnostic> [head_ref] [base_ref] [repo] -> the one normalised JSON object every pr_state
# path returns, built with jq --arg only. `merged` is THREE-valued on purpose: true/false only
# when the host answered, JSON null when it did not — a bare false would collapse "the host
# says not merged" into "we could not find out", the exact conflation this seam prevents.
# `repo` is the repository the answer is ABOUT, because an answer about somebody else's repo
# used to be byte-identical to one about ours: local host, bare pr, diagnostic null.
_mp_result() {
  jq -cn \
    --arg provider "$1" --arg host "$2" --arg pr "$3" --arg result "$4" \
    --arg state "$5" --arg merged "$6" --arg merged_at "$7" \
    --arg merge_commit "$8" --arg diagnostic "$9" \
    --arg head_ref "${10:-}" --arg base_ref "${11:-}" --arg repo "${12:-}" \
    '{
      provider: (if $provider == "" then null else $provider end),
      host: (if $host == "" then null else $host end),
      repo: (if $repo == "" then null else $repo end),
      pr: (if $pr == "" then null else $pr end),
      result: $result,
      state: (if $state == "" then null else $state end),
      merged: (if $merged == "true" then true elif $merged == "false" then false else null end),
      merged_at: (if $merged_at == "" then null else $merged_at end),
      merge_commit: (if $merge_commit == "" then null else $merge_commit end),
      head_ref: (if $head_ref == "" then null else $head_ref end),
      base_ref: (if $base_ref == "" then null else $base_ref end),
      diagnostic: (if $diagnostic == "" then null else $diagnostic end)
    }'
}

# lean-comments: allow-run — the two accepted forms and why nothing between them is.
# _mp_normalize_pr <pr> -> "<number>\t<host>\t<owner/repo>", the last two empty for a
# bare number; empty + return 1 otherwise. An unchecked value could reach the host CLI as
# a flag (leading "-") or a branch name. A URL's host and repo are RETURNED rather than
# discarded, because a PR NUMBER is only meaningful against the repository it belongs to:
# without them "https://elsewhere.example/o/r/pull/9" resolves to 9 and gets asked of
# whatever `origin` points at, and the recorded evidence — local host, bare number — is
# internally consistent and gives an auditor no signal that a different repo was named.
# Exactly two forms are accepted, and a partial URL is NOT one of them: a schemeless
# "o/r/pull/9" carries no checkable host, and accepting it would reopen the same gap.
_mp_normalize_pr() {
  local pr="$1" n host repo
  case "$pr" in
    ''|*[!0-9]*) ;;
    *) printf '%s\t\t' "$pr"; return 0 ;;
  esac
  case "$pr" in *://*/pull/*) ;; *) return 1 ;; esac
  n="${pr##*/pull/}"
  n="${n%%/*}"
  n="${n%%\?*}"
  n="${n%%#*}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  host=$(_mp_url_host "$pr")
  repo=$(_mp_url_repo "$pr") || repo=""
  { [ -n "$host" ] && [ -n "$repo" ]; } || return 1
  printf '%s\t%s\t%s' "$n" "$host" "$repo"
}

# _mp_api_host <host> -> the host as the API knows it. github.com and www.github.com are one
# host to GitHub and two strings to a comparison, and everything below compares.
_mp_api_host() {
  case "$1" in
    www.github.com) printf 'github.com' ;;
    *) printf '%s' "$1" ;;
  esac
}

# _mp_repo_spec <spec> -> "<host>\t<owner/repo>" for gh's `[HOST/]OWNER/REPO` repo spec or a
# repo URL; host empty when the spec names none, return 1 when it names no owner/repo at all.
_mp_repo_spec() {
  local spec="$1" host="" path owner repo
  case "$spec" in
    *://*) host=$(_mp_url_host "$spec"); path="${spec#*://}"; path="${path#*/}" ;;
    *)     path="$spec" ;;
  esac
  path="${path%%\?*}"
  path="${path%%#*}"
  path="${path#/}"
  path="${path%/}"
  case "$path" in */*/*) host="${path%%/*}"; path="${path#*/}" ;; esac
  owner="${path%%/*}"
  repo="${path#*/}"
  repo="${repo%%/*}"
  repo="${repo%.git}"
  { [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$path" ]; } || return 1
  printf '%s\t%s' "$(_mp_api_host "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')")" \
    "$(printf '%s' "$owner/$repo" | tr '[:upper:]' '[:lower:]')"
}

# lean-comments: allow-run — the three redirection vectors, and why the pin is not the answer.
# _mp_redirect_check <root> <host> <owner/repo> -> 0 when nothing outside this checkout names a
# different repository; otherwise the disagreement on stdout and return 1. `gh` resolves a
# `pr view` target from GH_REPO, from GH_HOST, and from `remote.<name>.gh-resolved` BEFORE it
# falls back to the checkout's own remote, and every one of those is writable by anything that
# can set an environment variable or one git-config key. The `--repo` pin below already
# outranks all three (measured, not assumed), so this check is not what makes the answer right
# — it is what stops a DISAGREEMENT from being resolved silently in either direction: an
# environment naming somebody else's repository is a refusal by its own name, never a
# preference quietly overridden and then reported exactly like a query that was never aimed
# elsewhere at all. A `gh-resolved` of `base` names this remote's own repo and is not a
# disagreement.
_mp_redirect_check() {
  local root="$1" want_host="$2" want_repo="$3" cfg spec spec_host spec_repo line key val
  if [ -n "${GH_REPO:-}" ]; then
    spec=$(_mp_repo_spec "$GH_REPO") || {
      printf 'GH_REPO is set to "%s", which names no owner/repo to compare against this checkout'"'"'s %s/%s' \
        "$(_mp_oneline "$GH_REPO")" "$want_host" "$want_repo"
      return 1
    }
    spec_host="${spec%%$'\t'*}"
    spec_repo="${spec#*$'\t'}"
    if [ "$spec_repo" != "$want_repo" ] || { [ -n "$spec_host" ] && [ "$spec_host" != "$want_host" ]; }; then
      printf 'GH_REPO names %s/%s but this checkout'"'"'s remote is %s/%s' \
        "$(_mp_oneline "${spec_host:-$want_host}")" "$(_mp_oneline "$spec_repo")" "$want_host" "$want_repo"
      return 1
    fi
  fi
  if [ -n "${GH_HOST:-}" ]; then
    spec_host=$(_mp_api_host "$(printf '%s' "$GH_HOST" | tr '[:upper:]' '[:lower:]')")
    if [ "$spec_host" != "$want_host" ]; then
      printf 'GH_HOST names %s but this checkout'"'"'s remote is on %s' \
        "$(_mp_oneline "$spec_host")" "$want_host"
      return 1
    fi
  fi
  cfg=$(git -C "$root" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null) || cfg=""
  [ -n "$cfg" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%% *}"
    val="${line#* }"
    { [ "$val" != "$line" ] && [ -n "$val" ] && [ "$val" != "base" ]; } || continue
    if ! spec=$(_mp_repo_spec "$val"); then
      printf 'git config %s is "%s", which names no owner/repo to compare against this checkout'"'"'s %s/%s' \
        "$(_mp_oneline "$key")" "$(_mp_oneline "$val")" "$want_host" "$want_repo"
      return 1
    fi
    spec_host="${spec%%$'\t'*}"
    spec_repo="${spec#*$'\t'}"
    if [ "$spec_repo" != "$want_repo" ] || { [ -n "$spec_host" ] && [ "$spec_host" != "$want_host" ]; }; then
      printf 'git config %s resolves this repository to %s/%s, not %s/%s' \
        "$(_mp_oneline "$key")" "$(_mp_oneline "${spec_host:-$want_host}")" "$(_mp_oneline "$spec_repo")" \
        "$want_host" "$want_repo"
      return 1
    fi
  done <<< "$cfg"
  return 0
}

# lean-comments: allow-run — names both api_failure shapes, incl. the exit-0 one.
# _mp_github_pr_state <project_root> <host> <pr> -> the github arm's normalised result,
# asking what stack_reconcile asks (`state,mergedAt,mergeCommit`) plus the head and base
# branch names, WITHOUT which a merged PR cannot be bound to any particular objective and
# every merged PR in the repo is equally good evidence for closing anything. A non-zero
# gh exit, OR a zero exit whose payload has no parseable `state`, is `api_failure` —
# never a quietly not-merged `ok`. The two branch names are the only remote-authored
# strings returned; both are shape-checked and dropped when they fail.
#
# WHICH REPOSITORY IS ASKED IS NOT AMBIENT. The target comes from this checkout's own remote
# and is passed as `--repo <host>/<owner>/<repo>`, which outranks GH_REPO, GH_HOST and
# `gh-resolved`; a disagreeing environment is `repo_mismatch` before the host is contacted,
# and a remote naming no owner/repo is `unbindable_repo` rather than a query aimed by whatever
# happened to be exported. `url` is then requested and its repository compared against the
# target, so the answer carries its own provenance instead of being trusted for having been
# asked — the one check that also covers a redirection vector this file does not enumerate.
_mp_github_pr_state() {
  local root="$1" host="$2" pr="$3" out err errfile state merged_at merge_commit merged why head_ref base_ref rc=0
  local remote_url remote_host remote_repo target url url_host url_repo
  remote_url=$(_mp_remote_url "$root") || remote_url=""
  remote_host=$(_mp_api_host "$(_mp_url_host "$remote_url")")
  remote_repo=$(_mp_url_repo "$remote_url") || remote_repo=""
  if [ -z "$remote_host" ] || [ -z "$remote_repo" ]; then
    why="this checkout's remote '$(_mp_oneline "${remote_url:-<none>}")' names no host/owner/repo, so PR $pr could only have been aimed by ambient environment rather than bound to this repository"
    _mp_warn "unbindable_repo: $why — this is NOT 'not merged'; no closure may be inferred from it"
    _mp_emit "$root" "merge_provider_unbindable_repo" provider "github" host "$host" pr "$pr" \
      remote "$(_mp_oneline "${remote_url:-<none>}")"
    _mp_result "github" "$host" "$pr" "unbindable_repo" "" "" "" "" "$why"
    return 8
  fi
  target="$remote_host/$remote_repo"
  if ! why=$(_mp_redirect_check "$root" "$remote_host" "$remote_repo"); then
    why="$why — PR $pr would have been asked of a repository this checkout does not name, and a genuine answer about that one recorded as if it were about this one"
    _mp_warn "repo_mismatch: $why"
    _mp_emit "$root" "merge_provider_repo_mismatch" provider "github" host "$remote_host" pr "$pr" \
      repo "$remote_repo" reason "$(_mp_oneline "$why")"
    _mp_result "github" "$remote_host" "$pr" "repo_mismatch" "" "" "" "" "$why" "" "" "$remote_repo"
    return 7
  fi
  why=$(_mp_github_health) || {
    _mp_warn "provider_unavailable: github arm cannot run for PR $pr — $why"
    _mp_emit "$root" "merge_provider_unavailable" provider "github" host "$host" pr "$pr" reason "$why"
    _mp_result "github" "$host" "$pr" "provider_unavailable" "" "" "" "" "$why"
    return 4
  }
  # lean-comments: allow-run — the split and the wrapper close two OPPOSITE failures.
  # stdout ONLY: `2>&1` folded bounded-net's degradation line into the payload, so on a host with
  # no GNU timeout a genuinely MERGED PR parsed as api_failure. The split keeps the payload clean;
  # nz_bounded_run_split keeps the diagnostic reachable, because a bound that fired kills gh before
  # it says anything and the exit code alone is not a reason.
  errfile=$(mktemp "${TMPDIR:-/tmp}/nazgul-mp-stderr-XXXXXX" 2>/dev/null) || errfile="/dev/null"
  out=$( (cd "$root" 2>/dev/null && NZ_BOUNDED_ROOT="$root" \
    nz_bounded_run_split net "gh pr view (merge state)" "$errfile" \
    gh pr view "$pr" --repo "$target" --json state,mergedAt,mergeCommit,headRefName,baseRefName,url) ) || rc=$?
  err=$(cat "$errfile" 2>/dev/null) || err=""
  [ "$errfile" = "/dev/null" ] || rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    why="gh pr view $pr failed (exit $rc): $(_mp_oneline "${err:-$out}")"
    _mp_warn "api_failure: $why — this is NOT 'not merged'; no closure may be inferred from it"
    _mp_emit "$root" "merge_provider_api_failure" provider "github" host "$host" pr "$pr" exit_code "$rc" reason "$(_mp_oneline "${err:-$out}")"
    _mp_result "github" "$host" "$pr" "api_failure" "" "" "" "" "$why"
    return 5
  fi
  state=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null) || state=""
  if [ -z "$state" ]; then
    why="gh pr view $pr returned no parseable state: $(_mp_oneline "${out:-$err}")"
    _mp_warn "api_failure: $why — this is NOT 'not merged'"
    _mp_emit "$root" "merge_provider_api_failure" provider "github" host "$host" pr "$pr" exit_code "0" reason "unparseable response"
    _mp_result "github" "$host" "$pr" "api_failure" "" "" "" "" "$why"
    return 5
  fi
  url=$(printf '%s' "$out" | jq -r '.url // empty' 2>/dev/null) || url=""
  url_host=$(_mp_api_host "$(_mp_url_host "$url")")
  url_repo=$(_mp_url_repo "$url") || url_repo=""
  if [ -z "$url_repo" ]; then
    why="gh pr view $pr returned no PR url, so its answer names no repository and cannot be shown to be about $target: $(_mp_oneline "$out")"
    _mp_warn "api_failure: $why — this is NOT 'not merged'"
    _mp_emit "$root" "merge_provider_api_failure" provider "github" host "$host" pr "$pr" exit_code "0" \
      reason "no url to certify which repository answered"
    _mp_result "github" "$host" "$pr" "api_failure" "" "" "" "" "$why"
    return 5
  fi
  if [ "$url_host" != "$remote_host" ] || [ "$url_repo" != "$remote_repo" ]; then
    why="the host answered about ${url_host}/${url_repo} when it was asked about ${target} — a genuine answer about the wrong repository is not evidence about this one"
    _mp_warn "repo_mismatch: $why"
    _mp_emit "$root" "merge_provider_repo_mismatch" provider "github" host "$remote_host" pr "$pr" \
      repo "$remote_repo" answered "$(_mp_oneline "$url_host/$url_repo")"
    _mp_result "github" "$remote_host" "$pr" "repo_mismatch" "" "" "" "" "$why" "" "" "$remote_repo"
    return 7
  fi
  merged_at=$(printf '%s' "$out" | jq -r '.mergedAt // empty' 2>/dev/null) || merged_at=""
  merge_commit=$(printf '%s' "$out" | jq -r '.mergeCommit.oid // empty' 2>/dev/null) || merge_commit=""
  head_ref=$(printf '%s' "$out" | jq -r '.headRefName // empty' 2>/dev/null) || head_ref=""
  base_ref=$(printf '%s' "$out" | jq -r '.baseRefName // empty' 2>/dev/null) || base_ref=""
  _mp_ref_ok "$head_ref" || head_ref=""
  _mp_ref_ok "$base_ref" || base_ref=""
  if [ "$state" = "MERGED" ]; then merged="true"; else merged="false"; fi
  _mp_result "github" "$host" "$pr" "ok" "$state" "$merged" "$merged_at" "$merge_commit" "" "$head_ref" "$base_ref" "$remote_repo"
  return 0
}

# lean-comments: allow-run — public seam contract; the test parses this vocabulary.
# merge_provider_pr_state <project_root> <pr> -> one JSON object on stdout,
# always, carrying the normalised {state, merged_at, merge_commit} plus the
# named `result` that says whether the host was actually asked:
#
#   ok (0)                   the host answered; state/merged are its answer
#   unsupported_host (2)     no arm serves this remote's host
#   no_remote (3)            no remote to derive a host from
#   provider_unavailable (4) an arm exists but cannot run now (tool/auth)
#   api_failure (5)          the host was asked and did not usefully answer
#   invalid_pr (6)           <pr> is neither a PR number nor a scheme://host/
#                            owner/repo/pull/<n> URL naming THIS repo's remote
#   repo_mismatch (7)        something other than this checkout named the repository:
#                            GH_REPO, GH_HOST or a remote's gh-resolved disagrees with
#                            it, or the host answered about a different repo than the
#                            one it was asked about
#   unbindable_repo (8)      this checkout's remote names no owner/repo, so nothing
#                            could bind the query to THIS repository
#
# `repo_mismatch` is the newest member and the reason the others could be trusted at all:
# `gh pr view` resolves its target from the environment before the checkout, so a bare PR
# number used to return a genuine `ok`/`merged: true` about whatever repository an exported
# GH_REPO named, in a record byte-identical to the honest one. It is a NAMED refusal, in
# both directions: the seam neither prefers the environment nor silently prefers the
# checkout, because "we looked somewhere else" must not print like "we looked here".
#
# On `ok` the object also carries `head_ref`/`base_ref` — the branch the PR
# merged FROM and INTO. They exist so a caller can bind the PR to a particular
# objective: without them every merged PR in the repository is equally good
# evidence for closing any task, which is a genuine, host-verified answer to a
# question nobody asked. Either is null when the host did not return a
# ref-shaped name; a caller that needs the binding must fail closed on null.
#
# Only `ok` may be read as merge state. The other five mean "could not look",
# and callers MUST NOT infer "not merged" from any of them — nor fall back to
# git ancestry, which post-squash reports every shipped commit as unshipped.
#
# <pr> is treated as untrusted operator input on every path: it can carry
# credentials in its userinfo, so it is redacted before it is warned, emitted,
# or returned, and once normalisation succeeds only the bare number is used.
merge_provider_pr_state() {
  local root="${1:-}" pr_in="${2:-}" raw provider host pr why pr_shown rest rc=0
  local url_host url_repo remote_url remote_host remote_repo
  pr_shown=$(_mp_oneline "$pr_in")
  raw=$(_mp_normalize_pr "$pr_in") || {
    why="'${pr_shown}' is not a PR number or a scheme://host/owner/repo/pull/<n> URL"
    _mp_warn "invalid_pr: $why"
    _mp_emit "$root" "merge_provider_invalid_pr" pr "$pr_shown" project_root "$root"
    _mp_result "" "" "$pr_shown" "invalid_pr" "" "" "" "" "$why"
    return 6
  }
  pr="${raw%%$'\t'*}"
  rest="${raw#*$'\t'}"
  url_host="${rest%%$'\t'*}"
  url_repo="${rest#*$'\t'}"
  rc=0
  raw=$(_mp_detect_raw "$root") || rc=$?
  provider="${raw%%$'\t'*}"
  host="${raw#*$'\t'}"
  if [ "$rc" -eq 3 ]; then
    why="no git remote is configured under '${root:-<empty>}'"
    _mp_warn "no_remote: $why — no host to ask about PR $pr"
    _mp_emit "$root" "merge_provider_no_remote" pr "$pr" project_root "$root"
    _mp_result "" "" "$pr" "no_remote" "" "" "" "" "$why"
    return 3
  fi
  if [ "$rc" -ne 0 ]; then
    why="no merge-state provider serves host '${host:-<none>}'"
    _mp_warn "unsupported_host: $why — PR $pr cannot be verified here"
    _mp_emit "$root" "merge_provider_unsupported_host" pr "$pr" host "$host" project_root "$root"
    _mp_result "" "$host" "$pr" "unsupported_host" "" "" "" "" "$why"
    return 2
  fi
  if [ -n "$url_host" ]; then
    remote_url=$(_mp_remote_url "$root") || remote_url=""
    # Both sides as the API knows them, as _mp_github_pr_state already does: _mp_provider_for_host
    # admits www.github.com, so a raw comparison refuses a URL naming this very repository.
    remote_host=$(_mp_api_host "$(_mp_url_host "$remote_url")")
    remote_repo=$(_mp_url_repo "$remote_url") || remote_repo=""
    url_host=$(_mp_api_host "$url_host")
    if [ -z "$remote_repo" ] || [ "$url_host" != "$remote_host" ] || [ "$url_repo" != "$remote_repo" ]; then
      why="the PR URL names ${url_host}/${url_repo}, but this project's remote is ${remote_host:-<none>}/${remote_repo:-<none>} — PR ${pr} would have been asked of the wrong repository, and the answer recorded as if it were about this one"
      _mp_warn "invalid_pr: $why"
      _mp_emit "$root" "merge_provider_invalid_pr" pr "$pr" url_host "$url_host" \
        url_repo "$url_repo" remote_host "$remote_host" remote_repo "$remote_repo" project_root "$root"
      _mp_result "" "$remote_host" "$pr" "invalid_pr" "" "" "" "" "$why"
      return 6
    fi
  fi
  case "$provider" in
    github) _mp_github_pr_state "$root" "$host" "$pr" ;;
    *)
      why="no arm implements provider '$provider'"
      _mp_warn "unsupported_host: $why — PR $pr cannot be verified here"
      _mp_emit "$root" "merge_provider_unsupported_host" pr "$pr" provider "$provider" host "$host" project_root "$root"
      _mp_result "$provider" "$host" "$pr" "unsupported_host" "" "" "" "" "$why"
      return 2 ;;
  esac
}
