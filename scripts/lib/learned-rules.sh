#!/usr/bin/env bash
set -euo pipefail
# Nazgul learned-rules — registry parser + scoped selector for the autolearning
# feature. Single source of truth for reading the learned-rules registry.
#
# Usage:
#   learned-rules.sh select --agent <name> --files "<space-list>" [--doc <path>]
#   learned-rules.sh parse   [--doc <path>]
#   learned-rules.sh next-id [--doc <path>]
#   learned-rules.sh bump-hits <LR-NNN> [--doc <path>]
#   learned-rules.sh fingerprint <text>
#
# Registry format: each rule is
#   ## LR-NNN: <title>
#   - **Status**: active|retired
#   - **Scope-Agents**: a, b   (or *)
#   - **Scope-Globs**: glob, glob   (or **)
#   - **Hits**: N
#   - **Added**: YYYY-MM-DD
#   - **Evidence**: TASK-..., ...
#   <body until next "## " heading>

DEFAULT_DOC="nazgul/learning/learned-rules.md"

# _rule_meta <doc> -> TSV: id \t status \t agents \t globs \t hits \t title
# (metadata only — no body, so no newline-in-field hazard)
_rule_meta() {
  local doc="$1"
  [ -f "$doc" ] || return 0
  awk '
    function flush() {
      if (id != "")
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, status, agents, globs, hits, title
      id=""; status=""; agents=""; globs=""; hits=""; title=""
    }
    /^## LR-/ {
      flush()
      line=$0; sub(/^## /, "", line)          # "LR-007: title"
      id=line; sub(/:.*/, "", id)             # "LR-007"
      title=line; sub(/^LR-[0-9]+:[[:space:]]*/, "", title)
      next
    }
    /^- \*\*/ {
      key=$0; sub(/^- \*\*/, "", key); sub(/\*\*.*/, "", key)
      val=$0; sub(/^- \*\*[^*]+\*\*:[[:space:]]*/, "", val)
      if (key=="Status") status=val
      else if (key=="Scope-Agents") agents=val
      else if (key=="Scope-Globs") globs=val
      else if (key=="Hits") hits=val
    }
    END { flush() }
  ' "$doc"
}

# _trim <string>
_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

cmd_next_id() {
  local doc="$1" max=0 n id
  if [ -f "$doc" ]; then
    while IFS=$'\t' read -r id _; do
      n=${id#LR-}; n=$((10#$n))
      [ "$n" -gt "$max" ] && max=$n
    done < <(_rule_meta "$doc")
  fi
  printf 'LR-%03d\n' "$((max + 1))"
}

cmd_fingerprint() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ //; s/ $//' \
    | cksum | awk '{print $1}'
}

# cmd_parse <doc> -> one compact JSON object per rule, per line.
cmd_parse() {
  local doc="$1" id status agents globs hits title
  _rule_meta "$doc" | while IFS=$'\t' read -r id status agents globs hits title; do
    jq -nc \
      --arg id "$id" --arg status "$status" --arg hits "$hits" --arg title "$title" \
      --arg agents "$agents" --arg globs "$globs" '
      def splitlist: if . == "" then [] else (split(",") | map(gsub("^\\s+|\\s+$";""))) end;
      { id: $id, status: $status, title: $title,
        hits: ($hits | if . == "" then 0 else tonumber end),
        agents: ($agents | splitlist),
        globs:  ($globs  | splitlist) }'
  done
}

# _agent_in_scope <agents-csv> <agent>  -> 0 if agent listed or "*"
_agent_in_scope() {
  local csv="$1" agent="$2" a arr
  IFS=',' read -ra arr <<< "$csv"
  for a in "${arr[@]}"; do
    a=$(_trim "$a")
    [ "$a" = "*" ] && return 0
    [ "$a" = "$agent" ] && return 0
  done
  return 1
}

# _glob_in_scope <globs-csv> <files-space-list>  -> 0 if any glob matches any file
_glob_in_scope() {
  local csv="$1" files="$2" g f garr farr
  IFS=',' read -ra garr <<< "$csv"
  IFS=' ' read -ra farr <<< "$files"
  for g in "${garr[@]}"; do
    g=$(_trim "$g")
    [ "$g" = "**" ] && return 0
    for f in "${farr[@]}"; do
      # $g is intentionally unquoted HERE so it acts as a case glob pattern
      case "$f" in $g) return 0 ;; esac
    done
  done
  return 1
}

# _rule_block <doc> <id>  -> raw markdown block for that rule (heading..next "## ")
_rule_block() {
  local doc="$1" id="$2"
  awk -v target="$id" '
    /^## LR-/ {
      cur=$0; sub(/^## /, "", cur); sub(/:.*/, "", cur)
      printing = (cur == target)
    }
    printing { print }
  ' "$doc"
}

# cmd_select <doc> <agent> <files>
cmd_select() {
  local doc="$1" agent="$2" files="$3"
  [ -f "$doc" ] || return 0
  local matches="" id status agents globs hits title
  while IFS=$'\t' read -r id status agents globs hits title; do
    [ "$status" = "active" ] || continue
    _agent_in_scope "$agents" "$agent" || continue
    _glob_in_scope "$globs" "$files" || continue
    matches="$matches $id"
  done < <(_rule_meta "$doc")

  matches=$(_trim "$matches")
  [ -n "$matches" ] || return 0

  printf '## Learned Rules (cite any you apply, by LR number)\n\n'
  local m
  for m in $matches; do
    _rule_block "$doc" "$m"
    printf '\n'
  done
}

# cmd_bump_hits <doc> <id> -> increment that rule's Hits line in place (no-op if absent)
cmd_bump_hits() {
  local doc="$1" id="$2" tmp
  [ -f "$doc" ] || return 0
  tmp=$(mktemp)
  awk -v target="$id" '
    /^## LR-/ { cur=$0; sub(/^## /, "", cur); sub(/:.*/, "", cur) }
    cur==target && /^- \*\*Hits\*\*:/ {
      n=$0; sub(/.*:[[:space:]]*/, "", n); n=n+1
      print "- **Hits**: " n; next
    }
    { print }
  ' "$doc" > "$tmp" && mv "$tmp" "$doc"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    next-id)
      local doc="$DEFAULT_DOC"
      [ "${1:-}" = "--doc" ] && doc="$2"
      cmd_next_id "$doc" ;;
    fingerprint)
      cmd_fingerprint "${1:-}" ;;
    parse)
      local doc="$DEFAULT_DOC"
      [ "${1:-}" = "--doc" ] && doc="$2"
      cmd_parse "$doc" ;;
    select)
      local doc="$DEFAULT_DOC" agent="" files=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --agent) agent="$2"; shift 2 ;;
          --files) files="$2"; shift 2 ;;
          --doc)   doc="$2";   shift 2 ;;
          *) shift ;;
        esac
      done
      cmd_select "$doc" "$agent" "$files" ;;
    bump-hits)
      local id="${1:-}" doc="$DEFAULT_DOC"
      shift || true
      [ "${1:-}" = "--doc" ] && doc="$2"
      cmd_bump_hits "$doc" "$id" ;;
    *)
      echo "usage: learned-rules.sh {select|parse|next-id|bump-hits|fingerprint} ..." >&2
      exit 2 ;;
  esac
}

main "$@"
