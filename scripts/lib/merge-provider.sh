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
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# that own their own shell options. Nothing but path resolution runs at source
# time; the telemetry lib is sourced lazily, per call, inside a subshell.

[ -n "${_NAZGUL_MERGE_PROVIDER_SOURCED:-}" ] && return 0
_NAZGUL_MERGE_PROVIDER_SOURCED=1

_MERGE_PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# _mp_redact <text> -> token-shaped substrings replaced by ***. A diagnostic built
# from remote stderr is the one place a credential could reach a log (RULES.md §16).
_mp_redact() {
  printf '%s' "$1" | sed -E \
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
  local root="${1:-}" raw rc name host
  raw=$(_mp_detect_raw "$root"); rc=$?
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
  gh auth status >/dev/null 2>&1 || { printf '%s' "gh is not authenticated (run: gh auth login)"; return 1; }
  return 0
}

# lean-comments: allow-run — public seam contract; the two unusable states differ.
# merge_provider_health <project_root> -> "ready" / "unsupported_host" / "no_remote" /
# "provider_unavailable" (exit 0 / 2 / 3 / 4). "provider_unavailable" means an arm
# EXISTS but cannot run now (tool missing, unauthenticated) — deliberately distinct
# from having no arm at all, because the operator's remedy differs for each.
merge_provider_health() {
  local root="${1:-}" raw rc provider host why
  raw=$(_mp_detect_raw "$root"); rc=$?
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
# <diagnostic> -> the one normalised JSON object every pr_state path returns, built with
# jq --arg only. `merged` is THREE-valued on purpose: true/false only when the host
# answered, JSON null when it did not — a bare false would collapse "the host says not
# merged" into "we could not find out", the exact conflation this seam prevents.
_mp_result() {
  jq -cn \
    --arg provider "$1" --arg host "$2" --arg pr "$3" --arg result "$4" \
    --arg state "$5" --arg merged "$6" --arg merged_at "$7" \
    --arg merge_commit "$8" --arg diagnostic "$9" \
    '{
      provider: (if $provider == "" then null else $provider end),
      host: (if $host == "" then null else $host end),
      pr: (if $pr == "" then null else $pr end),
      result: $result,
      state: (if $state == "" then null else $state end),
      merged: (if $merged == "true" then true elif $merged == "false" then false else null end),
      merged_at: (if $merged_at == "" then null else $merged_at end),
      merge_commit: (if $merge_commit == "" then null else $merge_commit end),
      diagnostic: (if $diagnostic == "" then null else $diagnostic end)
    }'
}

# _mp_normalize_pr <pr> -> the bare PR number, empty + return 1 otherwise. An unchecked
# value could reach the host CLI as a flag (leading "-") or a branch name.
_mp_normalize_pr() {
  local pr="$1" n
  case "$pr" in
    ''|*[!0-9]*)
      case "$pr" in
        */pull/*)
          n="${pr##*/pull/}"
          n="${n%%/*}"
          n="${n%%\?*}"
          case "$n" in ''|*[!0-9]*) return 1 ;; esac
          printf '%s' "$n"
          return 0 ;;
        *) return 1 ;;
      esac ;;
    *) printf '%s' "$pr"; return 0 ;;
  esac
}

# lean-comments: allow-run — names both api_failure shapes, incl. the exit-0 one.
# _mp_github_pr_state <project_root> <host> <pr> -> the github arm's normalised result,
# asking exactly what stack_reconcile already asks (`gh pr view <pr> --json
# state,mergedAt,mergeCommit`). A non-zero gh exit, OR a zero exit whose payload has no
# parseable `state`, is `api_failure` — never a quietly not-merged `ok`.
_mp_github_pr_state() {
  local root="$1" host="$2" pr="$3" out rc state merged_at merge_commit merged why
  why=$(_mp_github_health) || {
    _mp_warn "provider_unavailable: github arm cannot run for PR $pr — $why"
    _mp_emit "$root" "merge_provider_unavailable" provider "github" host "$host" pr "$pr" reason "$why"
    _mp_result "github" "$host" "$pr" "provider_unavailable" "" "" "" "" "$why"
    return 4
  }
  out=$( (cd "$root" 2>/dev/null && gh pr view "$pr" --json state,mergedAt,mergeCommit) 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then
    why="gh pr view $pr failed (exit $rc): $(_mp_oneline "$out")"
    _mp_warn "api_failure: $why — this is NOT 'not merged'; no closure may be inferred from it"
    _mp_emit "$root" "merge_provider_api_failure" provider "github" host "$host" pr "$pr" exit_code "$rc" reason "$(_mp_oneline "$out")"
    _mp_result "github" "$host" "$pr" "api_failure" "" "" "" "" "$why"
    return 5
  fi
  state=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null) || state=""
  if [ -z "$state" ]; then
    why="gh pr view $pr returned no parseable state: $(_mp_oneline "$out")"
    _mp_warn "api_failure: $why — this is NOT 'not merged'"
    _mp_emit "$root" "merge_provider_api_failure" provider "github" host "$host" pr "$pr" exit_code "0" reason "unparseable response"
    _mp_result "github" "$host" "$pr" "api_failure" "" "" "" "" "$why"
    return 5
  fi
  merged_at=$(printf '%s' "$out" | jq -r '.mergedAt // empty' 2>/dev/null) || merged_at=""
  merge_commit=$(printf '%s' "$out" | jq -r '.mergeCommit.oid // empty' 2>/dev/null) || merge_commit=""
  if [ "$state" = "MERGED" ]; then merged="true"; else merged="false"; fi
  _mp_result "github" "$host" "$pr" "ok" "$state" "$merged" "$merged_at" "$merge_commit" ""
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
#   invalid_pr (6)           <pr> is not a PR number or .../pull/<n> URL
#
# Only `ok` may be read as merge state. The other five mean "could not look",
# and callers MUST NOT infer "not merged" from any of them — nor fall back to
# git ancestry, which post-squash reports every shipped commit as unshipped.
merge_provider_pr_state() {
  local root="${1:-}" pr_in="${2:-}" raw rc provider host pr why
  pr=$(_mp_normalize_pr "$pr_in") || {
    why="'${pr_in}' is not a PR number or a .../pull/<n> URL"
    _mp_warn "invalid_pr: $why"
    _mp_emit "$root" "merge_provider_invalid_pr" pr "$pr_in" project_root "$root"
    _mp_result "" "" "$pr_in" "invalid_pr" "" "" "" "" "$why"
    return 6
  }
  raw=$(_mp_detect_raw "$root"); rc=$?
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
