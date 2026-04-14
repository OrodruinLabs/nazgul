#!/usr/bin/env bash
# Nazgul shared task utilities — sourced by scripts that read/write task manifests.
# Eliminates duplication of get_task_status(), set_task_status(), and task counting.

# Extract status from a task manifest file.
# Supports four formats:
#   1. List-item:    - **Status**: X
#   2. ATX inline:   ## Status: X
#   3. ATX block:    ## Status\n X  (value on next line)
#   4. YAML front:   status: X     (inside --- fenced YAML frontmatter)
# Usage: get_task_status <file> [default]
get_task_status() {
  local result
  # Try inline formats first (colon on same line)
  result=$(grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$1" 2>/dev/null | sed 's/.*:[[:space:]]*//')
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  # Try block format: ## Status (no colon), value on next line
  result=$(awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (/^[A-Z_]+$/) print; exit}' "$1" 2>/dev/null)
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  # Try YAML frontmatter: status: VALUE (between --- fences)
  result=$(awk '/^---$/{fm++; next} fm==1 && /^status:/{gsub(/^status:[[:space:]]*/, ""); print; exit}' "$1" 2>/dev/null)
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi
  echo "${2:-}"
}

# Update status in a task manifest file.
# Handles all four formats (list-item, ATX inline, ATX block, YAML frontmatter).
# Usage: set_task_status <file> <old_status> <new_status>
set_task_status() {
  local file="$1" old_status="$2" new_status="$3"
  if grep -q '^## Status:' "$file" 2>/dev/null; then
    # ATX inline: ## Status: X
    sed -i.bak "s/^## Status:[[:space:]]*${old_status}/## Status: ${new_status}/" "$file" && rm -f "${file}.bak"
  elif grep -q '^\- \*\*Status\*\*:' "$file" 2>/dev/null; then
    # List-item: - **Status**: X
    sed -i.bak "s/^\(- \*\*Status\*\*:\)[[:space:]]*${old_status}/\1 ${new_status}/" "$file" && rm -f "${file}.bak"
  elif grep -q '^## Status' "$file" 2>/dev/null; then
    # ATX block: ## Status\nX — convert to inline format
    awk -v old="$old_status" -v new="$new_status" '
      /^## Status[[:space:]]*$/ { print "## Status: " new; getline; next }
      { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  elif awk '/^---$/{fm++; next} fm==1 && /^status:/{found=1; exit} END{exit !found}' "$file" 2>/dev/null; then
    # YAML frontmatter: status: X
    sed -i.bak "s/^status:[[:space:]]*${old_status}/status: ${new_status}/" "$file" && rm -f "${file}.bak"
  fi
}

# Count tasks with a given status in a tasks directory.
# Usage: count_tasks_by_status <tasks_dir> <status>
count_tasks_by_status() {
  local tasks_dir="$1" status="$2" count=0
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "$status" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Find the first task with IN_PROGRESS status. Returns task ID or empty string.
# Usage: get_active_task <tasks_dir>
get_active_task() {
  local tasks_dir="$1"
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "IN_PROGRESS" ]; then
      basename "$f" .md
      return
    fi
  done
  echo ""
}
