#!/usr/bin/env bash
# Nazgul inbox-provider — the FEAT-009 objective-inbox seam. Three functions
# form the provider contract (list / get / archive); only the `file` provider
# ships, reading candidates from an on-disk inbox dir. Objective text is DATA:
# it is never `eval`'d and never shell-expanded — candidate content only ever
# reaches jq via --arg / --rawfile or the safe md parser below.
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into caller shells
# (heartbeat hook / start skill) that own their own shell options.

[ -n "${_NAZGUL_INBOX_PROVIDER_SOURCED:-}" ] && return 0
_NAZGUL_INBOX_PROVIDER_SOURCED=1

# inbox_provider <config_file> -> prints automation.heartbeat.inbox.provider,
# default "file" when the config is missing/unreadable or the key is unset.
inbox_provider() {
  local config="$1"
  [ -f "$config" ] || { echo "file"; return 0; }
  jq -r '.automation.heartbeat.inbox.provider // "file"' "$config" 2>/dev/null || echo "file"
}

# inbox_list <inbox_dir> -> one candidate id (filename) per line for each
# *.md/*.json directly in the inbox. The archive/ subdir is excluded because a
# shallow glob never descends into it. Zero output when the dir is absent/empty.
inbox_list() {
  local inbox_dir="$1" f name
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
  local inbox_dir="$1" id="$2"
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
  local inbox_dir="$1" id="$2"
  local src="$inbox_dir/$id" archive="$inbox_dir/archive"
  if [ ! -f "$src" ]; then
    [ -f "$archive/$id" ] && return 0
    return 1
  fi
  mkdir -p "$archive"
  mv -f "$src" "$archive/$id"
}
