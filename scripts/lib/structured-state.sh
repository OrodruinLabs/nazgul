#!/usr/bin/env bash
# Nazgul structured-state — single source of truth for reading machine-state
# (review verdicts, task status) from a canonical leading YAML frontmatter block.
# Sourced by review-evidence.sh and task-utils.sh.

VALID_VERDICTS="APPROVE CHANGES_REQUESTED"
VALID_STATUSES="PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED"

# read_frontmatter_field <file> <key> -> prints trimmed value; 0 if found & non-empty, else 1.
read_frontmatter_field() {
  local file="$1" key="$2" val
  [ -f "$file" ] || return 1
  [ "$(sed -n '1p' "$file" 2>/dev/null)" = "---" ] || return 1
  val=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file" 2>/dev/null \
        | grep -m1 -E "^${key}[[:space:]]*:" \
        | sed -E "s/^${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]+\$//")
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

# _in_list <value> <space-separated-list> -> 0 if present
_in_list() {
  local needle="$1" item
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
