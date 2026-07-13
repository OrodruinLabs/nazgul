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

# connector_github_pull_list <config> -> one candidate id (issue number) per line
# for each OPEN issue carrying pull.label (default "nazgul") and NOT carrying
# pull.claimed_label (default "nazgul-claimed"). Zero output on any gh failure.
connector_github_pull_list() {
  local config="$1" label claimed json
  label=$(_cgh_cfg "$config" '.connectors.github.pull.label' 'nazgul')
  claimed=$(_cgh_cfg "$config" '.connectors.github.pull.claimed_label' 'nazgul-claimed')
  json=$(_cgh_gh_retry gh issue list --state open --label "$label" --json number,labels) || return 0
  printf '%s' "$json" | jq -r --arg claimed "$claimed" '
    .[]? | select(any(.labels[]?; .name == $claimed) | not) | .number
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
    head -c "$max_body" "$body_tmp" > "$body_tmp.cap" 2>/dev/null && mv "$body_tmp.cap" "$body_tmp"
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
