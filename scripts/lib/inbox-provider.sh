#!/usr/bin/env bash
# Nazgul inbox-provider — the FEAT-009 objective-inbox seam. Three functions
# form the provider contract (list / get / archive). Each dispatches on
# inbox_provider(config): "file" (default, and any unknown value) reads candidates
# from an on-disk inbox dir; "github" lazily sources connector-github.sh and routes
# to its pull_list/get/archive. A github provider that is disabled or unhealthy
# degrades to a safe empty result (list nothing, get/archive return 1) so a
# misconfiguration never crashes the heartbeat. Objective text is DATA: it is never
# `eval`'d and never shell-expanded — candidate content only ever reaches jq via
# --arg / --rawfile or the safe md parser below.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# (heartbeat hook / start skill) that own their own shell options.

# RE-SOURCE GUARD: an ARRAY marker, not a scalar and not `declare -F` — bounded-net.sh's header
# carries the measurement, including the `export -f` shape that defeats `declare -F`.
[ "${_NZ_INBOX_PROVIDER_LOADED[1]:-}" = "loaded" ] && return 0
_NZ_INBOX_PROVIDER_LOADED=(0 loaded)

_INBOX_PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# inbox_provider <config_file> -> prints automation.heartbeat.inbox.provider,
# default "file" when the config is missing/unreadable or the key is unset.
inbox_provider() {
  local config="$1"
  [ -f "$config" ] || { echo "file"; return 0; }
  jq -r '.automation.heartbeat.inbox.provider // "file"' "$config" 2>/dev/null || echo "file"
}

# _inbox_resolve_config <inbox_dir> -> the nazgul/config.json governing this inbox,
# found by walking up from <inbox_dir> (path-only; the dir need not exist). Empty
# + return 1 when none is found, so the caller degrades to the "file" default.
_inbox_resolve_config() {
  local dir="$1"
  case "$dir" in /*) : ;; *) dir="$(pwd)/$dir" ;; esac
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/nazgul/config.json" ]; then
      printf '%s' "$dir/nazgul/config.json"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Every connector function this seam calls. Derived from the call sites below, so a new
# call cannot outrun the readiness probe that is supposed to cover it.
_INBOX_CONNECTOR_API="connector_github_health connector_github_pull_list connector_github_pull_get connector_github_pull_archive"

# lean-comments: allow-run — the probe's subject changed, and that IS the fix.
# _inbox_require_connector -> lazily source the GitHub connector (only ever called on the github
# branch, so the file provider never touches it) and answer whether its API is USABLE. It used to
# answer a different question — "has an ambient scalar been set?" — so one exported
# _NAZGUL_CONNECTOR_GITHUB_SOURCED returned 0 having loaded nothing and the next line's
# connector_github_health exited 127, which `|| return 1` reported as "not ready". Sourcing is
# attempted FIRST and unconditionally, because a source both loads the file and overwrites a
# hostile `export -f`; the probe then names every function this file calls, so a single exported
# function cannot answer for the rest of the API.
_inbox_require_connector() {
  local lib="$_INBOX_PROVIDER_LIB_DIR/connector-github.sh" fn
  if [ -f "$lib" ]; then
    # shellcheck source=connector-github.sh
    . "$lib" || true
  fi
  for fn in $_INBOX_CONNECTOR_API; do
    declare -F "$fn" >/dev/null 2>&1 || return 1
  done
  return 0
}

# _inbox_github_ready <config> -> 0 iff the github connector is usable: config
# present, connector sourced, connectors.github.enabled==true, and health passes.
# Any miss -> return 1 so a misconfiguration degrades to a safe empty result
# rather than crashing the heartbeat.
_inbox_github_ready() {
  local config="$1" enabled
  [ -n "$config" ] && [ -f "$config" ] || return 1
  _inbox_require_connector || return 1
  enabled=$(jq -r 'if (.connectors.github.enabled == true) then "true" else "false" end' "$config" 2>/dev/null) || return 1
  [ "$enabled" = "true" ] || return 1
  connector_github_health "$config" || return 1
}

# inbox_list <inbox_dir> -> one candidate id (filename) per line for each
# *.md/*.json directly in the inbox. The archive/ subdir is excluded because a
# shallow glob never descends into it. Zero output when the dir is absent/empty.
inbox_list() {
  local inbox_dir="$1" f name config
  config=$(_inbox_resolve_config "$inbox_dir")
  if [ "$(inbox_provider "$config")" = "github" ]; then
    _inbox_github_ready "$config" || return 0
    connector_github_pull_list "$config"
    return
  fi
  [ -d "$inbox_dir" ] || return 0
  for f in "$inbox_dir"/*.md "$inbox_dir"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    printf '%s\n' "$name"
  done
}

# _inbox_md_frontmatter <file> -> prints the YAML frontmatter lines (between the
# leading `---` fences), empty when the file has no frontmatter. Data-only.
_inbox_md_frontmatter() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm==1 && $0=="---" { exit }
    infm==1 { print }
  ' "$1"
}

# _inbox_md_body <file> -> prints the markdown body (everything after the
# closing frontmatter fence, or the whole file when there is no frontmatter),
# with leading blank lines stripped. Data-only.
_inbox_md_body() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm==1 && $0=="---" { infm=2; next }
    infm==1 { next }
    { print }
  ' "$1" | sed -e '/./,$!d'
}

# _inbox_yaml_val <frontmatter> <key> -> prints the scalar value for <key>,
# surrounding single/double quotes stripped, empty when absent. <key> is always
# a fixed literal (title/priority/type); the value is treated purely as data.
_inbox_yaml_val() {
  printf '%s\n' "$1" \
    | sed -n "s/^$2:[[:space:]]*//p" \
    | head -n1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# inbox_get <inbox_dir> <id> -> emit the candidate as normalized JSON
# {title, body, priority, type}. JSON candidates are parsed with jq; .md
# candidates are parsed as YAML-frontmatter + markdown body. Missing priority
# and type default to null. Returns 1 when the candidate does not exist.
inbox_get() {
  local inbox_dir="$1" id="$2" config
  config=$(_inbox_resolve_config "$inbox_dir")
  if [ "$(inbox_provider "$config")" = "github" ]; then
    _inbox_github_ready "$config" || return 1
    connector_github_pull_get "$config" "$id"
    return
  fi
  local file="$inbox_dir/$id"
  [ -f "$file" ] || return 1
  case "$id" in
    *.json)
      jq -c '{
        title: (.title // null),
        body: (.body // null),
        priority: (.priority // null),
        type: (.type // null)
      }' "$file" 2>/dev/null
      ;;
    *.md)
      local fm body title priority type
      fm=$(_inbox_md_frontmatter "$file")
      body=$(_inbox_md_body "$file")
      title=$(_inbox_yaml_val "$fm" title)
      priority=$(_inbox_yaml_val "$fm" priority)
      type=$(_inbox_yaml_val "$fm" type)
      jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg priority "$priority" \
        --arg type "$type" \
        '{
          title: (if $title == "" then null else $title end),
          body: (if $body == "" then null else $body end),
          priority: (if $priority == "" then null else $priority end),
          type: (if $type == "" then null else $type end)
        }'
      ;;
    *)
      return 1
      ;;
  esac
}

# inbox_archive <inbox_dir> <id> -> atomically move the candidate into
# <inbox_dir>/archive/ (mkdir -p, then a single mv). Crash-safe and
# re-runnable: a candidate already in archive/ returns 0, a missing one
# with no archived copy returns 1.
inbox_archive() {
  local inbox_dir="$1" id="$2" config
  config=$(_inbox_resolve_config "$inbox_dir")
  if [ "$(inbox_provider "$config")" = "github" ]; then
    _inbox_github_ready "$config" || return 1
    connector_github_pull_archive "$config" "$id"
    return
  fi
  local src="$inbox_dir/$id" archive="$inbox_dir/archive"
  if [ ! -f "$src" ]; then
    [ -f "$archive/$id" ] && return 0
    return 1
  fi
  mkdir -p "$archive"
  mv -f "$src" "$archive/$id"
}
