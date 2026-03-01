#!/usr/bin/env bash
set -euo pipefail

# board-sync-github.sh — GitHub Projects V2 provider for Hydra board sync
# Usage: board-sync-github.sh <command> [args]
#
# Commands:
#   setup <project-number>    Connect to project, create fields, store IDs
#   create-issue <task-file>  Create GitHub Issue + add to project
#   sync-task <task-file>     Update issue status/labels from task manifest
#   sync-all                  Full sync of all hydra/tasks/TASK-*.md
#   archive-all <project-num> Archive all existing items (--clean)
#   disconnect                Remove board config from config.json
#   status                    Show connection info + last sync

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# --- Helpers ---

log_info()  { echo "board-sync: $*" >&2; }
log_warn()  { echo "board-sync: WARNING: $*" >&2; }
log_error() { echo "board-sync: ERROR: $*" >&2; }

check_prereqs() {
  if [ ! -f "$CONFIG" ]; then
    log_error "Hydra not initialized (hydra/config.json not found)"
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

  local hydra_status_field_json task_id_field_json group_field_json
  hydra_status_field_json=$(gh project field-create "$project_number" \
    --owner "$owner" \
    --name "Hydra Status" \
    --data-type "SINGLE_SELECT" \
    --single-select-options "PLANNED,READY,IN_PROGRESS,IMPLEMENTED,IN_REVIEW,CHANGES_REQUESTED,DONE,BLOCKED" \
    --format json 2>/dev/null) || {
    hydra_status_field_json=$(gh project field-list "$project_number" --owner "$owner" --format json --jq '.fields[] | select(.name == "Hydra Status")' 2>/dev/null) || {
      log_error "Failed to create or find 'Hydra Status' field"
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

  local hydra_status_id task_id_field_id group_field_id
  hydra_status_id=$(echo "$hydra_status_field_json" | jq -r '.id')
  task_id_field_id=$(echo "$task_id_field_json" | jq -r '.id')
  group_field_id=$(echo "$group_field_json" | jq -r '.id')

  # Get option IDs for Hydra Status single-select
  log_info "Fetching status option IDs..."
  local fields_json status_options
  fields_json=$(gh project field-list "$project_number" --owner "$owner" --format json 2>/dev/null)
  status_options=$(echo "$fields_json" | jq -r --arg fid "$hydra_status_id" '.fields[] | select(.id == $fid) | .options // []')

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
  for label in "hydra" "hydra:planned" "hydra:ready" "hydra:in-progress" "hydra:implemented" "hydra:in-review" "hydra:changes-requested" "hydra:done" "hydra:blocked"; do
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
    --arg hsid "$hydra_status_id" \
    --arg tid "$task_id_field_id" \
    --arg gid "$group_field_id" \
    --argjson soids "$status_option_ids" \
    '{
      owner: $owner,
      repo: $repo,
      project_number: $pn,
      project_id: $pid,
      field_ids: {
        hydra_status: $hsid,
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
  task_id=$(grep -m1 '^\- \*\*ID\*\*:' "$task_file" | sed 's/.*: //')
  local raw_title
  raw_title=$(head -1 "$task_file" | sed 's/^# //')
  # Ensure title follows spec format: TASK-001: [Title]
  if echo "$raw_title" | grep -q "^${task_id}"; then
    title="$raw_title"
  else
    title="${task_id}: ${raw_title}"
  fi
  status=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" | sed 's/.*:[[:space:]]*//')
  group=$(grep -m1 '^\- \*\*Group\*\*:' "$task_file" | sed 's/.*: //' || echo "0")

  # Extract description and acceptance criteria for issue body
  local body criteria issue_body
  body=$(awk '/^## Description$/,/^## /' "$task_file" | sed '1d;$d' | head -20)
  criteria=$(awk '/^## Acceptance Criteria$/,/^## /' "$task_file" | sed '1d;$d' | head -10)
  issue_body=$(printf "%s\n\n## Acceptance Criteria\n%s\n\n---\n*Managed by Hydra*" "$body" "$criteria")

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
    --label "hydra,hydra:${status_label}") || {
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
  local project_id hydra_status_field_id task_id_field_id group_field_id status_option_id
  project_id=$(jq -r '.board.provider_config.project_id' "$CONFIG")
  hydra_status_field_id=$(jq -r '.board.provider_config.field_ids.hydra_status' "$CONFIG")
  task_id_field_id=$(jq -r '.board.provider_config.field_ids.task_id' "$CONFIG")
  group_field_id=$(jq -r '.board.provider_config.field_ids.group' "$CONFIG")
  status_option_id=$(jq -r --arg s "$status" '.board.provider_config.status_option_ids[$s] // empty' "$CONFIG")

  # Set Hydra Status
  if [ -n "$status_option_id" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$hydra_status_field_id" \
      --single-select-option-id "$status_option_id" 2>/dev/null || log_warn "Failed to set Hydra Status on $task_id"
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
  task_id=$(grep -m1 '^\- \*\*ID\*\*:' "$task_file" | sed 's/.*: //')
  status=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" | sed 's/.*:[[:space:]]*//')

  # Check if we have a mapping for this task
  local issue_number item_id
  issue_number=$(jq -r --arg tid "$task_id" '.board.task_map[$tid].issue_number // empty' "$CONFIG")
  item_id=$(jq -r --arg tid "$task_id" '.board.task_map[$tid].item_id // empty' "$CONFIG")

  if [ -z "$issue_number" ] || [ -z "$item_id" ]; then
    cmd_create_issue "$task_file"
    return $?
  fi

  local owner repo project_id hydra_status_field_id status_option_id
  owner=$(jq -r '.board.provider_config.owner' "$CONFIG")
  repo=$(jq -r '.board.provider_config.repo' "$CONFIG")
  project_id=$(jq -r '.board.provider_config.project_id' "$CONFIG")
  hydra_status_field_id=$(jq -r '.board.provider_config.field_ids.hydra_status' "$CONFIG")
  status_option_id=$(jq -r --arg s "$status" '.board.provider_config.status_option_ids[$s] // empty' "$CONFIG")

  # Update Hydra Status field on project item
  if [ -n "$status_option_id" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$hydra_status_field_id" \
      --single-select-option-id "$status_option_id" 2>/dev/null || {
      # Check if issue was deleted externally — recreate if so
      if ! gh issue view "$issue_number" --repo "$owner/$repo" --json number >/dev/null 2>&1; then
        log_warn "$task_id issue #$issue_number deleted externally — recreating"
        update_config --arg tid "$task_id" 'del(.board.task_map[$tid])'
        cmd_create_issue "$task_file"
        return $?
      fi
      log_warn "Failed to update Hydra Status for $task_id"
      increment_sync_failures
      return 1
    }
  fi

  # Update labels — remove old hydra:* status labels, add new one
  local status_label
  status_label=$(echo "$status" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  for old_label in "hydra:planned" "hydra:ready" "hydra:in-progress" "hydra:implemented" "hydra:in-review" "hydra:changes-requested" "hydra:done" "hydra:blocked"; do
    gh issue edit "$issue_number" --repo "$owner/$repo" --remove-label "$old_label" 2>/dev/null || true
  done

  gh issue edit "$issue_number" --repo "$owner/$repo" --add-label "hydra:${status_label}" 2>/dev/null || true

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
  local count=0

  if [ -d "$HYDRA_DIR/tasks" ]; then
    for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      cmd_sync_task "$task_file" || true
      count=$((count + 1))
    done
  fi

  log_info "Full sync complete: $count tasks synced"
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

  # Clean stale hydra labels
  local repo
  repo=$(echo "$repo_info" | jq -r '.name')
  for label in "hydra:planned" "hydra:ready" "hydra:in-progress" "hydra:implemented" "hydra:in-review" "hydra:changes-requested" "hydra:done" "hydra:blocked"; do
    gh label delete "$label" --repo "$owner/$repo" --yes 2>/dev/null || true
  done
  log_info "Cleaned stale hydra labels"
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
    echo "Hydra not initialized" >&2
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
