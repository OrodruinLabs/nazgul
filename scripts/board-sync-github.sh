#!/usr/bin/env bash
set -euo pipefail

# board-sync-github.sh — GitHub Projects V2 provider for Nazgul board sync
# Usage: board-sync-github.sh <command> [args]
#
# Commands:
#   setup <project-number>    Connect to project, create fields, store IDs
#   create-issue <task-file>  Create GitHub Issue + add to project
#   sync-task <task-file>     Update issue status/labels from task manifest
#   sync-all                  Full sync of all nazgul/tasks/TASK-*.md
#   archive-all <project-num> Archive all existing items (--clean)
#   disconnect                Remove board config from config.json
#   status                    Show connection info + last sync

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
# shellcheck source=./lib/task-utils.sh
source "$SCRIPT_DIR/lib/task-utils.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# --- Helpers ---

log_info()  { echo "board-sync: $*" >&2; }
log_warn()  { echo "board-sync: WARNING: $*" >&2; }
log_error() { echo "board-sync: ERROR: $*" >&2; }

check_prereqs() {
  if [ ! -f "$CONFIG" ]; then
    log_error "Nazgul not initialized (nazgul/config.json not found)"
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    log_error "gh CLI not installed. Install: https://cli.github.com/"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq not installed"
    exit 1
  fi
}

get_repo_info() {
  gh repo view --json owner,name 2>/dev/null || {
    log_error "Not a GitHub repository or gh not authenticated"
    exit 1
  }
}

update_config() {
  local jq_filter="$1"
  shift
  jq "$jq_filter" "$@" "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
}

gh_with_retry() {
  local attempts=3 delay=1
  for i in $(seq 1 "$attempts"); do
    if "$@" 2>/dev/null; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return 1
}

increment_sync_failures() {
  local current
  current=$(jq -r '.board.sync_failures // 0' "$CONFIG")
  local new_count=$((current + 1))
  update_config --argjson n "$new_count" '.board.sync_failures = $n'
  if [ "$new_count" -ge 5 ]; then
    log_warn "5 consecutive sync failures — disabling board sync"
    update_config '.board.enabled = false'
  fi
}

reset_sync_failures() {
  jq '.board.sync_failures = 0 | .board.last_sync = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"
}

# --- Manifest parsing (seam S2: planner -> board-sync, TRD §3) ---

# Lines under `## <section>`, up to the next `## ` heading.
extract_section() {
  awk -v want="## $2" '$0==want{f=1;next} /^## /{f=0} f' "$1"
}

# The first of the named sections that is non-blank; rc 1 when none is.
first_section() {
  local file="$1"; shift
  local name body
  for name in "$@"; do
    body=$(extract_section "$file" "$name")
    if [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$body"
      return 0
    fi
  done
  return 1
}

# Prose lines that are neither frontmatter nor bookkeeping — the last resort for
# a manifest whose section headings this script does not know.
manifest_body_fallback() {
  awk '
    NR==1 && /^---[[:space:]]*$/ {fm=1; next}
    fm && /^---[[:space:]]*$/ {fm=0; next}
    fm {next}
    /^# /{next}
    /^## (Metadata|Commits|Red-Run Evidence|Review Results|Implementation Log)[[:space:]]*$/{skip=1; next}
    /^## /{skip=0}
    skip{next}
    /^<!--/{next}
    /^- \*\*[^*]+\*\*:/{next}
    NF
  ' "$1"
}

manifest_meta_lines() {
  local key
  for key in "Depends on" "Traces to" "Files modified"; do
    grep -m1 -E "^- \*\*${key}\*\*:" "$1" || true
  done
}

# The `- **ID**:` field, else the H1's leading id token, else the filename stem.
manifest_task_id() {
  local id
  id=$(grep -m1 -E '^- \*\*ID\*\*:' "$1" | sed -E 's/^- \*\*ID\*\*:[[:space:]]*//') || id=""
  if [ -z "$id" ]; then
    id=$(grep -m1 -oE '^# (TASK|PATCH)-[0-9]+' "$1" | sed 's/^# //') || id=""
  fi
  [ -n "$id" ] || id=$(basename "$1" .md)
  printf '%s\n' "$id"
}

# H1 title + the manifest's prose, rendered for a human reading the issue.
manifest_issue_body() {
  local task_file="$1"
  local body criteria meta issue_body
  body=$(first_section "$task_file" "Description" "Objective" "Summary" "Context" | sed -n '1,40p') || body=""
  if [ -z "$body" ]; then
    body=$(manifest_body_fallback "$task_file" | sed -n '1,30p') || body=""
  fi
  criteria=$(first_section "$task_file" "Acceptance Criteria" "Acceptance criteria" "Success Criteria" "Subtasks" | sed -n '1,20p') || criteria=""
  meta=$(manifest_meta_lines "$task_file") || meta=""

  issue_body="${body:-_this manifest carries no prose section this script could read_}"
  issue_body="${issue_body}"$'\n\n'"## Acceptance Criteria"$'\n'"${criteria:-_none recorded in the manifest_}"
  if [ -n "$meta" ]; then
    issue_body="${issue_body}"$'\n\n'"$meta"
  fi
  printf '%s\n\n---\n*Managed by Nazgul*\n' "$issue_body"
}

# --- Commands ---

cmd_setup() {
  local project_number="${1:-}"
  if [ -z "$project_number" ]; then
    log_error "Usage: board-sync-github.sh setup <project-number>"
    exit 1
  fi

  check_prereqs

  local repo_info owner repo
  repo_info=$(get_repo_info)
  owner=$(echo "$repo_info" | jq -r '.owner.login')
  repo=$(echo "$repo_info" | jq -r '.name')

  log_info "Setting up board sync: $owner/$repo -> project #$project_number"

  # Get project ID
  local project_id
  project_id=$(gh project view "$project_number" --owner "$owner" --format json --jq '.id' 2>/dev/null) || {
    log_error "Project #$project_number not found for owner $owner"
    exit 1
  }

  log_info "Project ID: $project_id"

  # Create custom fields (or find existing ones)
  log_info "Creating custom fields..."

  local nazgul_status_field_json task_id_field_json group_field_json
  nazgul_status_field_json=$(gh project field-create "$project_number" \
    --owner "$owner" \
    --name "Nazgul Status" \
    --data-type "SINGLE_SELECT" \
    --single-select-options "PLANNED,READY,IN_PROGRESS,IMPLEMENTED,IN_REVIEW,CHANGES_REQUESTED,DONE,BLOCKED" \
    --format json 2>/dev/null) || {
    nazgul_status_field_json=$(gh project field-list "$project_number" --owner "$owner" --format json --jq '.fields[] | select(.name == "Nazgul Status")' 2>/dev/null) || {
      log_error "Failed to create or find 'Nazgul Status' field"
      exit 1
    }
  }

  task_id_field_json=$(gh project field-create "$project_number" \
    --owner "$owner" \
    --name "Task ID" \
    --data-type "TEXT" \
    --format json 2>/dev/null) || {
    task_id_field_json=$(gh project field-list "$project_number" --owner "$owner" --format json --jq '.fields[] | select(.name == "Task ID")' 2>/dev/null) || {
      log_error "Failed to create or find 'Task ID' field"
      exit 1
    }
  }

  group_field_json=$(gh project field-create "$project_number" \
    --owner "$owner" \
    --name "Group" \
    --data-type "NUMBER" \
    --format json 2>/dev/null) || {
    group_field_json=$(gh project field-list "$project_number" --owner "$owner" --format json --jq '.fields[] | select(.name == "Group")' 2>/dev/null) || {
      log_error "Failed to create or find 'Group' field"
      exit 1
    }
  }

  local nazgul_status_id task_id_field_id group_field_id
  nazgul_status_id=$(echo "$nazgul_status_field_json" | jq -r '.id')
  task_id_field_id=$(echo "$task_id_field_json" | jq -r '.id')
  group_field_id=$(echo "$group_field_json" | jq -r '.id')

  # Get option IDs for Nazgul Status single-select
  log_info "Fetching status option IDs..."
  local fields_json status_options
  fields_json=$(gh project field-list "$project_number" --owner "$owner" --format json 2>/dev/null)
  status_options=$(echo "$fields_json" | jq -r --arg fid "$nazgul_status_id" '.fields[] | select(.id == $fid) | .options // []')

  # Build status_option_ids map
  local status_option_ids="{}"
  for status_name in PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED; do
    local option_id
    option_id=$(echo "$status_options" | jq -r --arg name "$status_name" '.[] | select(.name == $name) | .id // empty')
    if [ -n "$option_id" ]; then
      status_option_ids=$(echo "$status_option_ids" | jq --arg k "$status_name" --arg v "$option_id" '. + {($k): $v}')
    else
      log_warn "Status option '$status_name' not found in field"
    fi
  done

  # Create labels
  log_info "Creating labels..."
  for label in "nazgul" "nazgul:planned" "nazgul:ready" "nazgul:in-progress" "nazgul:implemented" "nazgul:in-review" "nazgul:changes-requested" "nazgul:done" "nazgul:blocked"; do
    gh label create "$label" --repo "$owner/$repo" --force 2>/dev/null || true
  done

  # Store config
  log_info "Storing board configuration..."
  local provider_config
  provider_config=$(jq -n \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --argjson pn "$project_number" \
    --arg pid "$project_id" \
    --arg hsid "$nazgul_status_id" \
    --arg tid "$task_id_field_id" \
    --arg gid "$group_field_id" \
    --argjson soids "$status_option_ids" \
    '{
      owner: $owner,
      repo: $repo,
      project_number: $pn,
      project_id: $pid,
      field_ids: {
        nazgul_status: $hsid,
        task_id: $tid,
        group: $gid
      },
      status_option_ids: $soids,
      labels_created: true
    }')

  update_config --argjson pc "$provider_config" '
    .board.enabled = true |
    .board.provider = "github" |
    .board.provider_config = $pc |
    .board.sync_failures = 0
  '

  reset_sync_failures

  log_info "Setup complete. Board sync enabled for $owner/$repo -> project #$project_number"
}

cmd_create_issue() {
  local task_file="${1:-}"
  if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
    log_error "Usage: board-sync-github.sh create-issue <task-file>"
    exit 1
  fi

  check_prereqs

  local enabled
  enabled=$(jq -r '.board.enabled // false' "$CONFIG")
  if [ "$enabled" != "true" ]; then
    return 0
  fi

  local owner repo task_id title status group
  owner=$(jq -r '.board.provider_config.owner' "$CONFIG")
  repo=$(jq -r '.board.provider_config.repo' "$CONFIG")
  task_id=$(manifest_task_id "$task_file")
  local raw_title
  raw_title=$(grep -m1 '^# ' "$task_file" | sed 's/^# //') || raw_title=""
  [ -n "$raw_title" ] || raw_title=$(basename "$task_file" .md)
  # Ensure title follows spec format: TASK-001: [Title]
  if echo "$raw_title" | grep -q "^${task_id}"; then
    title="$raw_title"
  else
    title="${task_id}: ${raw_title}"
  fi
  status=$(get_task_status "$task_file" "PLANNED")
  group=$(grep -m1 -E '(^\- \*\*Group\*\*:|^## Group:)' "$task_file" | sed 's/.*:[[:space:]]*//' || echo "0")

  local issue_body
  issue_body=$(manifest_issue_body "$task_file")

  # Check if issue already exists in task_map
  local existing
  existing=$(jq -r --arg tid "$task_id" '.board.task_map[$tid].issue_number // empty' "$CONFIG")
  if [ -n "$existing" ]; then
    log_info "$task_id already has issue #$existing — skipping create"
    return 0
  fi

  # Create the issue
  local status_label
  status_label=$(echo "$status" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  local issue_url issue_number
  issue_url=$(gh_with_retry gh issue create \
    --repo "$owner/$repo" \
    --title "$title" \
    --body "$issue_body" \
    --label "nazgul,nazgul:${status_label}") || {
    log_warn "Failed to create issue for $task_id (after 3 retries)"
    increment_sync_failures
    return 1
  }

  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  log_info "Created issue #$issue_number for $task_id"

  # Add issue to project
  local project_number item_id
  project_number=$(jq -r '.board.provider_config.project_number' "$CONFIG")

  item_id=$(gh_with_retry gh project item-add "$project_number" \
    --owner "$owner" \
    --url "$issue_url" \
    --format json --jq '.id') || {
    log_warn "Failed to add issue #$issue_number to project (after 3 retries)"
    increment_sync_failures
    return 1
  }

  log_info "Added issue #$issue_number to project as item $item_id"

  # Set custom fields on the project item
  local project_id nazgul_status_field_id task_id_field_id group_field_id status_option_id
  project_id=$(jq -r '.board.provider_config.project_id' "$CONFIG")
  nazgul_status_field_id=$(jq -r '.board.provider_config.field_ids.nazgul_status' "$CONFIG")
  task_id_field_id=$(jq -r '.board.provider_config.field_ids.task_id' "$CONFIG")
  group_field_id=$(jq -r '.board.provider_config.field_ids.group' "$CONFIG")
  status_option_id=$(jq -r --arg s "$status" '.board.provider_config.status_option_ids[$s] // empty' "$CONFIG")

  # Set Nazgul Status
  if [ -n "$status_option_id" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$nazgul_status_field_id" \
      --single-select-option-id "$status_option_id" 2>/dev/null || log_warn "Failed to set Nazgul Status on $task_id"
  fi

  # Set Task ID text field
  gh project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$task_id_field_id" \
    --text "$task_id" 2>/dev/null || log_warn "Failed to set Task ID on $task_id"

  # Set Group number field
  if [ "$group" != "0" ] && [ -n "$group" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$group_field_id" \
      --number "$group" 2>/dev/null || log_warn "Failed to set Group on $task_id"
  fi

  # Store mapping in config
  update_config --arg tid "$task_id" --argjson inum "$issue_number" --arg iid "$item_id" '
    .board.task_map[$tid] = {issue_number: $inum, item_id: $iid}
  '

  reset_sync_failures
}

cmd_sync_task() {
  local task_file="${1:-}"
  if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
    log_error "Usage: board-sync-github.sh sync-task <task-file>"
    exit 1
  fi

  check_prereqs

  local enabled
  enabled=$(jq -r '.board.enabled // false' "$CONFIG")
  if [ "$enabled" != "true" ]; then
    return 0
  fi

  local task_id status
  task_id=$(manifest_task_id "$task_file")
  status=$(get_task_status "$task_file" "PLANNED")

  # Check if we have a mapping for this task
  local issue_number item_id
  issue_number=$(jq -r --arg tid "$task_id" '.board.task_map[$tid].issue_number // empty' "$CONFIG")
  item_id=$(jq -r --arg tid "$task_id" '.board.task_map[$tid].item_id // empty' "$CONFIG")

  if [ -z "$issue_number" ] || [ -z "$item_id" ]; then
    cmd_create_issue "$task_file"
    return $?
  fi

  local owner repo project_id nazgul_status_field_id status_option_id
  owner=$(jq -r '.board.provider_config.owner' "$CONFIG")
  repo=$(jq -r '.board.provider_config.repo' "$CONFIG")
  project_id=$(jq -r '.board.provider_config.project_id' "$CONFIG")
  nazgul_status_field_id=$(jq -r '.board.provider_config.field_ids.nazgul_status' "$CONFIG")
  status_option_id=$(jq -r --arg s "$status" '.board.provider_config.status_option_ids[$s] // empty' "$CONFIG")

  # Update Nazgul Status field on project item
  if [ -n "$status_option_id" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$nazgul_status_field_id" \
      --single-select-option-id "$status_option_id" 2>/dev/null || {
      # Check if issue was deleted externally — recreate if so
      if ! gh issue view "$issue_number" --repo "$owner/$repo" --json number >/dev/null 2>&1; then
        log_warn "$task_id issue #$issue_number deleted externally — recreating"
        update_config --arg tid "$task_id" 'del(.board.task_map[$tid])'
        cmd_create_issue "$task_file"
        return $?
      fi
      log_warn "Failed to update Nazgul Status for $task_id"
      increment_sync_failures
      return 1
    }
  fi

  # Update labels — remove old nazgul:* status labels, add new one
  local status_label
  status_label=$(echo "$status" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  for old_label in "nazgul:planned" "nazgul:ready" "nazgul:in-progress" "nazgul:implemented" "nazgul:in-review" "nazgul:changes-requested" "nazgul:done" "nazgul:blocked"; do
    gh issue edit "$issue_number" --repo "$owner/$repo" --remove-label "$old_label" 2>/dev/null || true
  done

  gh issue edit "$issue_number" --repo "$owner/$repo" --add-label "nazgul:${status_label}" 2>/dev/null || true

  # Handle terminal states
  if [ "$status" = "DONE" ]; then
    gh issue close "$issue_number" --repo "$owner/$repo" 2>/dev/null || true
    log_info "$task_id -> DONE (issue #$issue_number closed)"
  elif [ "$status" = "BLOCKED" ]; then
    local blocked_reason
    blocked_reason=$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "Unknown reason")
    gh issue comment "$issue_number" --repo "$owner/$repo" \
      --body "**BLOCKED**: $blocked_reason" 2>/dev/null || true
    log_info "$task_id -> BLOCKED (issue #$issue_number commented)"
  else
    gh issue reopen "$issue_number" --repo "$owner/$repo" 2>/dev/null || true
    log_info "$task_id -> $status (issue #$issue_number updated)"
  fi

  reset_sync_failures
}

cmd_sync_all() {
  check_prereqs

  local enabled
  enabled=$(jq -r '.board.enabled // false' "$CONFIG")
  if [ "$enabled" != "true" ]; then
    log_warn "Board sync not enabled"
    return 0
  fi

  log_info "Full sync starting..."
  local count=0 synced=0 failed=0

  if [ -d "$NAZGUL_DIR/tasks" ]; then
    for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      count=$((count + 1))
      if cmd_sync_task "$task_file"; then
        synced=$((synced + 1))
      else
        failed=$((failed + 1))
      fi
    done
  fi

  if [ "$count" -eq 0 ]; then
    log_warn "Full sync found NO task manifests under $NAZGUL_DIR/tasks — nothing was synced"
  elif [ "$synced" -eq 0 ]; then
    log_warn "Full sync FAILED: 0 of $count tasks synced ($failed failed)"
  else
    log_info "Full sync complete: $synced of $count tasks synced ($failed failed)"
  fi
}

cmd_archive_all() {
  local project_number="${1:-}"
  if [ -z "$project_number" ]; then
    log_error "Usage: board-sync-github.sh archive-all <project-number>"
    exit 1
  fi

  check_prereqs

  local repo_info owner
  repo_info=$(get_repo_info)
  owner=$(echo "$repo_info" | jq -r '.owner.login')

  # List all items
  local items
  items=$(gh project item-list "$project_number" --owner "$owner" --format json --jq '.items[].id' 2>/dev/null) || {
    log_info "No items found to archive"
    return 0
  }

  local count=0
  while IFS= read -r item_id; do
    [ -n "$item_id" ] || continue
    gh project item-archive "$project_number" --owner "$owner" --id "$item_id" 2>/dev/null || true
    count=$((count + 1))
  done <<< "$items"

  log_info "Archived $count items from project #$project_number"

  # Clean stale nazgul labels
  local repo
  repo=$(echo "$repo_info" | jq -r '.name')
  for label in "nazgul:planned" "nazgul:ready" "nazgul:in-progress" "nazgul:implemented" "nazgul:in-review" "nazgul:changes-requested" "nazgul:done" "nazgul:blocked"; do
    gh label delete "$label" --repo "$owner/$repo" --yes 2>/dev/null || true
  done
  log_info "Cleaned stale nazgul labels"
}

cmd_disconnect() {
  check_prereqs

  jq '
    .board.enabled = false |
    .board.provider = null |
    .board.provider_config = {} |
    .board.task_map = {} |
    .board.last_sync = null |
    .board.sync_failures = 0
  ' "$CONFIG" > "${CONFIG}.tmp.$$" && mv "${CONFIG}.tmp.$$" "$CONFIG"

  log_info "Board sync disconnected"
}

cmd_status() {
  if [ ! -f "$CONFIG" ]; then
    echo "Nazgul not initialized" >&2
    exit 1
  fi

  local enabled provider last_sync failures
  enabled=$(jq -r '.board.enabled // false' "$CONFIG")
  provider=$(jq -r '.board.provider // "none"' "$CONFIG")
  last_sync=$(jq -r '.board.last_sync // "never"' "$CONFIG")
  failures=$(jq -r '.board.sync_failures // 0' "$CONFIG")

  echo "Board Sync Status"
  echo "================================="
  echo "Enabled:    $enabled"
  echo "Provider:   $provider"
  echo "Last sync:  $last_sync"
  echo "Failures:   $failures"

  if [ "$provider" = "github" ]; then
    local owner repo project_number task_count
    owner=$(jq -r '.board.provider_config.owner // "?"' "$CONFIG")
    repo=$(jq -r '.board.provider_config.repo // "?"' "$CONFIG")
    project_number=$(jq -r '.board.provider_config.project_number // "?"' "$CONFIG")
    task_count=$(jq -r '.board.task_map | length' "$CONFIG")
    echo ""
    echo "GitHub Config"
    echo "---------------------------------"
    echo "Repo:         $owner/$repo"
    echo "Project:      #$project_number"
    echo "Tasks mapped: $task_count"
  fi
}

# --- Main ---

usage() {
  echo "Usage: board-sync-github.sh <command> [args]" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  setup <project-number>     Connect to project, create fields" >&2
  echo "  create-issue <task-file>   Create GitHub Issue for a task" >&2
  echo "  sync-task <task-file>      Sync task status to GitHub" >&2
  echo "  sync-all                   Full sync all tasks" >&2
  echo "  archive-all <project-num>  Archive all items on project" >&2
  echo "  disconnect                 Remove board sync config" >&2
  echo "  status                     Show board sync status" >&2
  exit 1
}

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  setup)        cmd_setup "$@" ;;
  create-issue) cmd_create_issue "$@" ;;
  sync-task)    cmd_sync_task "$@" ;;
  sync-all)     cmd_sync_all ;;
  archive-all)  cmd_archive_all "$@" ;;
  disconnect)   cmd_disconnect ;;
  status)       cmd_status ;;
  *)            usage ;;
esac
