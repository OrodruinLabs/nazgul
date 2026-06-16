#!/usr/bin/env bash
# Nazgul structured-state — single source of truth for reading machine-state
# (review verdicts, task status) from a canonical leading YAML frontmatter block.
# Sourced by review-evidence.sh and task-utils.sh.

VALID_VERDICTS="APPROVE CHANGES_REQUESTED"
VALID_STATUSES="PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED"

# read_frontmatter_field <file> <key> -> prints trimmed value; 0 if found & non-empty, else 1.
# <key> must be a literal field name: it is interpolated into grep/sed patterns.
read_frontmatter_field() {
  local file="$1" key="$2" val first
  [ -f "$file" ] || return 1
  # First line must be the frontmatter fence; tolerate a CRLF trailing \r.
  first=$(sed -n '1p' "$file" 2>/dev/null); first="${first%$'\r'}"
  [ "$first" = "---" ] || return 1
  val=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file" 2>/dev/null \
        | grep -m1 -E "^${key}[[:space:]]*:" \
        | sed -E "s/^${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]+\$//")
  val="${val%$'\r'}"                 # strip trailing CR from CRLF files
  val="${val#\"}"; val="${val%\"}"   # strip one pair of surrounding double quotes
  val="${val#\'}"; val="${val%\'}"   # strip one pair of surrounding single quotes
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

# _in_list <value> <space-separated-list> -> 0 if present
_in_list() {
  local needle="$1" item IFS=' '
  for item in $2; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# read_verdict <file> -> APPROVE|CHANGES_REQUESTED (0) | INVALID (2) | NONE (1)
read_verdict() {
  local file="$1" v
  if ! v=$(read_frontmatter_field "$file" verdict); then
    echo "NONE"; return 1
  fi
  if _in_list "$v" "$VALID_VERDICTS"; then
    echo "$v"; return 0
  fi
  echo "INVALID"; return 2
}

# read_task_status <file> -> STATUS (0) | INVALID (2) | "" (1, no status frontmatter)
read_task_status() {
  local file="$1" s
  if ! s=$(read_frontmatter_field "$file" status); then
    return 1
  fi
  if _in_list "$s" "$VALID_STATUSES"; then
    echo "$s"; return 0
  fi
  echo "INVALID"; return 2
}
