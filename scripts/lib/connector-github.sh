#!/usr/bin/env bash
# Nazgul GitHub connector — the FEAT-012 PULL half of the remote CONNECTOR
# contract (sibling to the FEAT-009 file inbox provider). Its functions select,
# normalize, and claim OPEN GitHub issues carrying the opt-in label. Remote
# issue title/body is DATA: it reaches jq only via --arg/--rawfile, is never
# eval'd or shell-expanded, and the body is byte-capped to bound memory against
# a hostile huge issue. Credentials come from `gh auth` only — no token is ever
# read from, written to, or logged via config.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# (heartbeat hook / inbox-provider seam) that own their own shell options.

[ -n "${_NAZGUL_CONNECTOR_GITHUB_SOURCED:-}" ] && return 0
_NAZGUL_CONNECTOR_GITHUB_SOURCED=1

# _cgh_cfg <config> <jq_path> <default> -> scalar config value, or <default> when
# the config is missing/unreadable or the key is null/absent. Fixed literal paths
# only; the returned value is treated purely as data by callers.
_cgh_cfg() {
  local config="$1" path="$2" default="$3" val
  [ -f "$config" ] || { printf '%s' "$default"; return 0; }
  val=$(jq -r "$path // empty" "$config" 2>/dev/null) || val=""
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# _cgh_gh_retry <cmd...> -> run a gh invocation with bounded retry; stdout passes
# through, every failure is swallowed. Returns non-zero after the last attempt so
# callers degrade instead of crashing. Delay is overridable to 0 to keep tests fast.
_cgh_gh_retry() {
  local attempts="${NAZGUL_CGH_RETRY_ATTEMPTS:-3}" delay="${NAZGUL_CGH_RETRY_DELAY:-1}" i
  for i in $(seq 1 "$attempts"); do
    if "$@" 2>/dev/null; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return 1
}

# _cgh_bump_pull_failures <config> -> bump connectors.github.pull_failures (tmp+mv);
# at >=5 auto-disable (enabled=false) + warn. Degrade-safe, always returns 0.
_cgh_bump_pull_failures() {
  local config="$1" current new tmp
  [ -f "$config" ] || return 0
  current=$(jq -r '.connectors.github.pull_failures // 0' "$config" 2>/dev/null) || current=0
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  new=$((current + 1))
  tmp="${config}.tmp.$$"
  if jq --argjson n "$new" '.connectors.github.pull_failures = $n' "$config" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$config" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"; return 0
  fi
  if [ "$new" -ge 5 ]; then
    printf 'connector-github: WARNING: 5 consecutive pull failures — disabling github connector\n' >&2
    tmp="${config}.tmp.$$"
    if jq '.connectors.github.enabled = false' "$config" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$config" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
}

# _cgh_reset_pull_failures <config> -> clear pull_failures to 0 after a good pull
# (no config write when already 0). Degrade-safe: always returns 0.
_cgh_reset_pull_failures() {
  local config="$1" current tmp
  [ -f "$config" ] || return 0
  current=$(jq -r '.connectors.github.pull_failures // 0' "$config" 2>/dev/null) || current=0
  [ "$current" = "0" ] && return 0
  tmp="${config}.tmp.$$"
  if jq '.connectors.github.pull_failures = 0' "$config" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$config" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# _cgh_map_put <config> <id> [feat_id] -> idempotently record the remote-issue# ↔
# local mapping via tmp+mv. Keyed by <id>, so a repeat claim never duplicates; a
# later real feat_id (3rd arg) upserts in place, else a null stub is created.
_cgh_map_put() {
  local config="$1" id="$2" feat="${3:-}" tmp
  [ -f "$config" ] || return 1
  tmp="${config}.tmp.$$"
  if [ -n "$feat" ]; then
    jq --arg id "$id" --arg f "$feat" '.connectors.github.map[$id] = $f' "$config" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
  else
    jq --arg id "$id" '.connectors.github.map[$id] = (.connectors.github.map[$id] // null)' "$config" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
  fi
}

# _cgh_push_enabled <config> -> 0 iff BOTH connectors.github.enabled and
# connectors.github.push.enabled are true. push.enabled defaults true, so it is
# only ever reached under the parent enabled that defaults false — the push gate
# is the conjunction, never push.enabled alone.
_cgh_push_enabled() {
  local config="$1" enabled push
  [ -f "$config" ] || return 1
  # `//` can't supply these defaults: it also fires on an explicit false. enabled
  # defaults false (absent/null -> off); push.enabled defaults true (only an
  # explicit false disables it) so the effective gate is their conjunction.
  enabled=$(jq -r 'if (.connectors.github.enabled == true) then "true" else "false" end' "$config" 2>/dev/null) || return 1
  push=$(jq -r 'if (.connectors.github.push.enabled == false) then "false" else "true" end' "$config" 2>/dev/null) || return 1
  [ "$enabled" = "true" ] || return 1
  [ "$push" = "true" ] || return 1
  return 0
}

# _cgh_map_resolve <config> <local_id> -> the mapped issue number for a local
# feat/task id (reverse of the issue#->feat map recorded by pull_archive), or
# empty when nothing is mapped. First match wins.
_cgh_map_resolve() {
  local config="$1" local_id="$2"
  [ -f "$config" ] || return 0
  jq -r --arg id "$local_id" '
    (.connectors.github.map // {}) | to_entries
    | map(select(.value == $id)) | .[0].key // empty
  ' "$config" 2>/dev/null || return 0
}

# connector_github_push_status <config> <local_id> <status> -> reflect a local
# task/objective status onto the MAPPED issue as a single nazgul-status:<status>
# label (removing any stale nazgul-status:* first), so re-pushing the same status
# never spams and a change updates in place. Only touches the nazgul-status:*
# namespace: the pull opt-in label and the claimed label are never removed, so a
# push can never make the issue re-enter pull_list. No-op (0) when the push gate
# is off, status is empty, or nothing is mapped; degrade-safe on gh failure.
connector_github_push_status() {
  local config="$1" local_id="$2" status="$3" issue want json
  _cgh_push_enabled "$config" || return 0
  [ -n "$status" ] || return 0
  issue=$(_cgh_map_resolve "$config" "$local_id")
  [ -n "$issue" ] || return 0

  want="nazgul-status:$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]' | tr '_ ' '--' | tr -cd 'a-z0-9:._-')"
  json=$(_cgh_gh_retry gh issue view "$issue" --json labels) || json=""
  if [ -n "$json" ]; then
    local old
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      [ "$old" = "$want" ] && continue
      _cgh_gh_retry gh issue edit "$issue" --remove-label "$old" || true
    done < <(printf '%s' "$json" | jq -r '.labels[]?.name | select(type == "string" and startswith("nazgul-status:"))' 2>/dev/null)
  fi
  _cgh_gh_retry gh issue edit "$issue" --add-label "$want" || return 1
}

# connector_github_push_pr <config> <local_id> <pr_url> -> upsert a single
# nazgul-marked PR-link comment on the MAPPED issue. pr_url is DATA: validated to
# be a plausible http(s) URL and only ever passed as a gh argv element, never
# eval'd. Idempotent via the marker — an existing marked comment is edited in
# place instead of duplicated. Never touches labels, so the claimed label stays.
# No-op (0) when the push gate is off, nothing is mapped, or pr_url is not a URL.
connector_github_push_pr() {
  local config="$1" local_id="$2" pr_url="$3" issue marker body json has
  _cgh_push_enabled "$config" || return 0
  case "$pr_url" in
    http://*|https://*) : ;;
    *) return 0 ;;
  esac
  issue=$(_cgh_map_resolve "$config" "$local_id")
  [ -n "$issue" ] || return 0

  marker="<!-- nazgul-pr -->"
  body="$marker
Nazgul PR: $pr_url"
  json=$(_cgh_gh_retry gh issue view "$issue" --json comments) || json=""
  has=$(printf '%s' "$json" | jq -r --arg m "$marker" '[.comments[]? | select((.body // "") | contains($m))] | length' 2>/dev/null) || has=0
  if [ "${has:-0}" -gt 0 ]; then
    _cgh_gh_retry gh issue comment "$issue" --edit-last --body "$body" || return 1
  else
    _cgh_gh_retry gh issue comment "$issue" --body "$body" || return 1
  fi
}

# connector_github_pull_list <config> -> one candidate issue number per line: OPEN,
# carrying pull.label, and NOT already handled (see the "handled" note at the filter).
connector_github_pull_list() {
  local config="$1" label claimed max_items json map_keys
  label=$(_cgh_cfg "$config" '.connectors.github.pull.label' 'nazgul')
  claimed=$(_cgh_cfg "$config" '.connectors.github.pull.claimed_label' 'nazgul-claimed')
  max_items=$(_cgh_cfg "$config" '.connectors.github.pull.max_items' '100')
  case "$max_items" in ''|*[!0-9]*) max_items=100 ;; esac
  [ "$max_items" -gt 0 ] || max_items=100
  json=$(_cgh_gh_retry gh issue list --state open --label "$label" --limit "$max_items" --json number,labels) || {
    _cgh_bump_pull_failures "$config"    # gh failure after retry -> degrade-safe counter bump, empty output
    return 0
  }
  _cgh_reset_pull_failures "$config"     # a good pull clears the consecutive-failure counter
  map_keys=$(jq -c '(.connectors.github.map // {}) | keys' "$config" 2>/dev/null) || map_keys='[]'
  case "$map_keys" in ''|null) map_keys='[]' ;; esac
  # "Handled" = claimed label present OR number is a map key; the local map keeps an
  # item suppressed even if the remote claimed label lags or was stripped (storm guard).
  printf '%s' "$json" | jq -r --arg claimed "$claimed" --argjson mapped "$map_keys" '
    .[]?
    | select(any(.labels[]?; .name == $claimed) | not)
    | (.number | tostring) as $n
    | select(($mapped | index($n)) == null)
    | .number
  ' 2>/dev/null || return 0
}

# connector_github_pull_get <config> <id> -> normalized {title,body,priority,type}
# JSON for the issue. title/body are DATA (jq --arg/--rawfile only); body is
# byte-capped at pull.max_body_bytes (default 65536). priority/type derive from
# "priority:"/"type:" labels or default null. Malformed/absent gh JSON -> return 1.
connector_github_pull_get() {
  local config="$1" id="$2"
  local max_body gh_tmp body_tmp bytes title priority type rc
  max_body=$(_cgh_cfg "$config" '.connectors.github.pull.max_body_bytes' '65536')
  case "$max_body" in ''|*[!0-9]*) max_body=65536 ;; esac
  [ "$max_body" -gt 0 ] || max_body=65536

  gh_tmp=$(mktemp) || return 1
  if ! _cgh_gh_retry gh issue view "$id" --json title,body,labels > "$gh_tmp"; then
    rm -f "$gh_tmp"
    return 1
  fi
  if ! jq -e 'type == "object"' "$gh_tmp" >/dev/null 2>&1; then
    rm -f "$gh_tmp"
    return 1
  fi

  body_tmp=$(mktemp) || { rm -f "$gh_tmp"; return 1; }
  if ! jq -j '.body // ""' "$gh_tmp" > "$body_tmp" 2>/dev/null; then
    rm -f "$gh_tmp" "$body_tmp"
    return 1
  fi
  bytes=$(wc -c < "$body_tmp")
  bytes=${bytes//[[:space:]]/}
  if [ "${bytes:-0}" -gt "$max_body" ]; then
    if ! { head -c "$max_body" "$body_tmp" > "$body_tmp.cap" 2>/dev/null && mv "$body_tmp.cap" "$body_tmp"; }; then
      rm -f "$gh_tmp" "$body_tmp" "$body_tmp.cap"
      return 1
    fi
  fi

  title=$(jq -r '.title // ""' "$gh_tmp" 2>/dev/null) || title=""
  priority=$(jq -r '[.labels[]?.name | select(type == "string" and startswith("priority:")) | ltrimstr("priority:")][0] // ""' "$gh_tmp" 2>/dev/null) || priority=""
  type=$(jq -r '[.labels[]?.name | select(type == "string" and startswith("type:")) | ltrimstr("type:")][0] // ""' "$gh_tmp" 2>/dev/null) || type=""

  jq -n \
    --arg title "$title" \
    --rawfile body "$body_tmp" \
    --arg priority "$priority" \
    --arg type "$type" \
    '{
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      priority: (if $priority == "" then null else $priority end),
      type: (if $type == "" then null else $type end)
    }'
  rc=$?
  rm -f "$gh_tmp" "$body_tmp"
  return "$rc"
}

# connector_github_map_local_id <config> <issue_id> <local_id> -> MF-038
# write-back: upsert the map entry with a REAL local id once one is known
# (called from scripts/heartbeat.sh after its auto-started session's feat_id
# resolves), so _cgh_map_resolve can match it. Thin public wrapper around
# _cgh_map_put's 3-arg real-value path; pull_archive's own 2-arg stub call
# below is unchanged (FEAT-012 pull-side contract stays as-is).
connector_github_map_local_id() {
  _cgh_map_put "$1" "$2" "$3"
}

# connector_github_pull_archive <config> <id> -> claim the issue: add
# pull.claimed_label and record the map stub. Idempotent — an already-claimed
# issue skips the add-label (still records the map) and returns 0.
connector_github_pull_archive() {
  local config="$1" id="$2" claimed json
  claimed=$(_cgh_cfg "$config" '.connectors.github.pull.claimed_label' 'nazgul-claimed')

  json=$(_cgh_gh_retry gh issue view "$id" --json number,labels) || json=""
  if [ -n "$json" ] && printf '%s' "$json" | jq -e --arg c "$claimed" 'any(.labels[]?; .name == $c)' >/dev/null 2>&1; then
    _cgh_map_put "$config" "$id"
    return 0
  fi

  _cgh_gh_retry gh issue edit "$id" --add-label "$claimed" || return 1
  _cgh_map_put "$config" "$id"
}

# connector_github_health <config> -> 0 when gh is installed, authenticated, and
# the repo resolves; non-zero otherwise so callers degrade. <config> is accepted
# for contract symmetry; the probe is gh-only (no config read).
connector_github_health() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  _cgh_gh_retry gh repo view --json name >/dev/null 2>&1 || return 1
  return 0
}
