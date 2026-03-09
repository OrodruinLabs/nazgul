# External Board Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Sync Hydra's local task tracking to GitHub Projects V2, with a provider-pluggable architecture for future board providers.

**Architecture:** One-way push from Hydra to GitHub via `gh` CLI. A new `scripts/board-sync-github.sh` handles all GitHub API calls. The stop hook calls it on every iteration; the planner calls it when creating tasks. A new `/hydra:board` skill provides standalone setup/disconnect/status.

**Tech Stack:** Bash (`gh` CLI, `jq`), GitHub Projects V2 GraphQL API (via `gh project` commands)

**Design doc:** `docs/plans/2026-03-01-board-sync-design.md`

---

### Task 1: Add board section to config template

**Files:**
- Modify: `templates/config.json:135` (add board section before closing `}`)
- Modify: `tests/test-config-schema.sh:59-65` (add board schema assertions)

**Step 1: Write the failing test**

Add to `tests/test-config-schema.sh` before the `report_results` line (line 65):

```bash
# Nested: .board
val=$(jq -r '.board | type' "$CONFIG")
assert_eq "has .board object" "$val" "object"

# Board fields
assert_json_field "has .board.enabled" "$CONFIG" ".board.enabled" "false"
val=$(jq -r '.board.provider' "$CONFIG")
assert_eq "has .board.provider null" "$val" "null"
val=$(jq -r '.board.provider_config | type' "$CONFIG")
assert_eq "has .board.provider_config object" "$val" "object"
val=$(jq -r '.board.task_map | type' "$CONFIG")
assert_eq "has .board.task_map object" "$val" "object"
val=$(jq -r '.board.last_sync' "$CONFIG")
assert_eq "has .board.last_sync null" "$val" "null"
assert_json_field "has .board.sync_failures" "$CONFIG" ".board.sync_failures" "0"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-config-schema.sh`
Expected: FAIL — `.board` section doesn't exist yet

**Step 3: Add board section to config template**

Edit `templates/config.json`. After the closing `}` of the `notifications` section (line 135), add a comma and the board section:

```json
  "board": {
    "enabled": false,
    "provider": null,
    "provider_config": {},
    "task_map": {},
    "last_sync": null,
    "sync_failures": 0
  }
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-config-schema.sh`
Expected: ALL PASS

**Step 5: Run full test suite**

Run: `bash tests/run-tests.sh`
Expected: ALL PASS (no regressions)

**Step 6: Commit**

```bash
git add templates/config.json tests/test-config-schema.sh
git commit -m "feat(board): add board sync section to config template"
```

---

### Task 2: Create `scripts/board-sync-github.sh` — setup command

**Files:**
- Create: `scripts/board-sync-github.sh`
- Create: `tests/test-board-sync-github.sh`

**Step 1: Write the test file skeleton**

Create `tests/test-board-sync-github.sh`. Test the `setup` command in a mocked environment:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-board-sync-github"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCRIPT="$REPO_ROOT/scripts/board-sync-github.sh"

# Test: script exists and is executable
assert_file_exists "board-sync-github.sh exists" "$SCRIPT"

# Test: script passes shellcheck
SC_OUTPUT=$(shellcheck "$SCRIPT" 2>&1 || true)
assert_eq "passes shellcheck" "$(echo "$SC_OUTPUT" | grep -c 'error' || echo 0)" "0"

# Test: script passes bash -n syntax check
bash -n "$SCRIPT"
assert_eq "passes bash syntax check" "$?" "0"

# Test: shows usage on no args
OUTPUT=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "shows usage on no args" "$OUTPUT" "Usage:"

# Test: shows usage on unknown command
OUTPUT=$(bash "$SCRIPT" unknown 2>&1 || true)
assert_contains "shows usage on unknown command" "$OUTPUT" "Usage:"

report_results
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-board-sync-github.sh`
Expected: FAIL — script doesn't exist

**Step 3: Create the script with setup, status, disconnect, and usage**

Create `scripts/board-sync-github.sh` with:

```bash
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

get_board_config() {
  jq -r '.board // empty' "$CONFIG" 2>/dev/null
}

update_config() {
  local jq_filter="$1"
  jq "$jq_filter" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
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
  update_config '.board.sync_failures = 0 | .board.last_sync = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))'
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

  log_info "Setting up board sync: $owner/$repo → project #$project_number"

  # Get project ID
  local project_id
  project_id=$(gh project view "$project_number" --owner "$owner" --format json --jq '.id' 2>/dev/null) || {
    log_error "Project #$project_number not found for owner $owner"
    exit 1
  }

  log_info "Project ID: $project_id"

  # Create custom fields
  log_info "Creating custom fields..."

  local hydra_status_field_json task_id_field_json group_field_json
  hydra_status_field_json=$(gh project field-create "$project_number" \
    --owner "$owner" \
    --name "Hydra Status" \
    --data-type "SINGLE_SELECT" \
    --single-select-options "PLANNED,READY,IN_PROGRESS,IMPLEMENTED,IN_REVIEW,CHANGES_REQUESTED,DONE,BLOCKED" \
    --format json 2>/dev/null) || {
    # Field might already exist — try to find it
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

  log_info "Setup complete. Board sync enabled for $owner/$repo → project #$project_number"
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

  local owner repo task_id title description status group
  owner=$(jq -r '.board.provider_config.owner' "$CONFIG")
  repo=$(jq -r '.board.provider_config.repo' "$CONFIG")
  task_id=$(grep -m1 '^\- \*\*ID\*\*:' "$task_file" | sed 's/.*: //')
  title=$(head -1 "$task_file" | sed 's/^# //')
  status=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" | sed 's/.*: //')
  group=$(grep -m1 '^\- \*\*Group\*\*:' "$task_file" | sed 's/.*: //' || echo "0")

  # Extract description and acceptance criteria for issue body
  local body
  body=$(awk '/^## Description$/,/^## /' "$task_file" | head -20)
  local criteria
  criteria=$(awk '/^## Acceptance Criteria$/,/^## /' "$task_file" | head -10)
  local issue_body
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
  issue_url=$(gh issue create \
    --repo "$owner/$repo" \
    --title "$title" \
    --body "$issue_body" \
    --label "hydra,hydra:${status_label}" 2>/dev/null) || {
    log_warn "Failed to create issue for $task_id"
    increment_sync_failures
    return 1
  }

  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  log_info "Created issue #$issue_number for $task_id"

  # Add issue to project
  local project_number item_id
  project_number=$(jq -r '.board.provider_config.project_number' "$CONFIG")

  item_id=$(gh project item-add "$project_number" \
    --owner "$owner" \
    --url "$issue_url" \
    --format json --jq '.id' 2>/dev/null) || {
    log_warn "Failed to add issue #$issue_number to project"
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

  # Set Task ID
  gh project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$task_id_field_id" \
    --text "$task_id" 2>/dev/null || log_warn "Failed to set Task ID on $task_id"

  # Set Group
  if [ "$group" != "0" ] && [ -n "$group" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$group_field_id" \
      --number "$group" 2>/dev/null || log_warn "Failed to set Group on $task_id"
  fi

  # Store mapping
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
    # No mapping — create the issue first
    cmd_create_issue "$task_file"
    return $?
  fi

  local owner repo project_id hydra_status_field_id status_option_id
  owner=$(jq -r '.board.provider_config.owner' "$CONFIG")
  repo=$(jq -r '.board.provider_config.repo' "$CONFIG")
  project_id=$(jq -r '.board.provider_config.project_id' "$CONFIG")
  hydra_status_field_id=$(jq -r '.board.provider_config.field_ids.hydra_status' "$CONFIG")
  status_option_id=$(jq -r --arg s "$status" '.board.provider_config.status_option_ids[$s] // empty' "$CONFIG")

  # Update Hydra Status field
  if [ -n "$status_option_id" ]; then
    gh project item-edit \
      --id "$item_id" \
      --project-id "$project_id" \
      --field-id "$hydra_status_field_id" \
      --single-select-option-id "$status_option_id" 2>/dev/null || {
      log_warn "Failed to update Hydra Status for $task_id"
      increment_sync_failures
      return 1
    }
  fi

  # Update labels — remove old hydra:* status labels, add new one
  local status_label
  status_label=$(echo "$status" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  # Remove all hydra status labels
  for old_label in "hydra:planned" "hydra:ready" "hydra:in-progress" "hydra:implemented" "hydra:in-review" "hydra:changes-requested" "hydra:done" "hydra:blocked"; do
    gh issue edit "$issue_number" --repo "$owner/$repo" --remove-label "$old_label" 2>/dev/null || true
  done

  # Add current status label
  gh issue edit "$issue_number" --repo "$owner/$repo" --add-label "hydra:${status_label}" 2>/dev/null || true

  # Handle terminal states
  if [ "$status" = "DONE" ]; then
    gh issue close "$issue_number" --repo "$owner/$repo" 2>/dev/null || true
    log_info "$task_id → DONE (issue #$issue_number closed)"
  elif [ "$status" = "BLOCKED" ]; then
    local blocked_reason
    blocked_reason=$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "Unknown reason")
    gh issue comment "$issue_number" --repo "$owner/$repo" \
      --body "**BLOCKED**: $blocked_reason" 2>/dev/null || true
    log_info "$task_id → BLOCKED (issue #$issue_number commented)"
  else
    # Reopen if was previously closed
    gh issue reopen "$issue_number" --repo "$owner/$repo" 2>/dev/null || true
    log_info "$task_id → $status (issue #$issue_number updated)"
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

  # Get project ID
  local project_id
  project_id=$(gh project view "$project_number" --owner "$owner" --format json --jq '.id' 2>/dev/null) || {
    log_error "Project #$project_number not found"
    exit 1
  }

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

  update_config '
    .board.enabled = false |
    .board.provider = null |
    .board.provider_config = {} |
    .board.task_map = {} |
    .board.last_sync = null |
    .board.sync_failures = 0
  '

  log_info "Board sync disconnected"
}

cmd_status() {
  check_prereqs

  local enabled provider last_sync failures
  enabled=$(jq -r '.board.enabled // false' "$CONFIG")
  provider=$(jq -r '.board.provider // "none"' "$CONFIG")
  last_sync=$(jq -r '.board.last_sync // "never"' "$CONFIG")
  failures=$(jq -r '.board.sync_failures // 0' "$CONFIG")

  echo "Board Sync Status"
  echo "═══════════════════════════════"
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
    echo "─────────────────────────────"
    echo "Repo:       $owner/$repo"
    echo "Project:    #$project_number"
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
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/test-board-sync-github.sh`
Expected: ALL PASS (exists, shellcheck, syntax, usage messages)

**Step 5: Make script executable**

```bash
chmod +x scripts/board-sync-github.sh
```

**Step 6: Run full test suite**

Run: `bash tests/run-tests.sh`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add scripts/board-sync-github.sh tests/test-board-sync-github.sh
git commit -m "feat(board): add GitHub Projects sync script with full provider interface"
```

---

### Task 3: Create `/hydra:board` skill

**Files:**
- Create: `skills/hydra:board/SKILL.md`
- Modify: `tests/test-frontmatter.sh` (should auto-detect new skill)

**Step 1: Write a test to verify the skill has valid frontmatter**

The existing `tests/test-frontmatter.sh` auto-scans `skills/*/SKILL.md`, so we just need to verify it catches the new skill. Run it first to see current state.

Run: `bash tests/test-frontmatter.sh`
Expected: PASS (baseline)

**Step 2: Create the skill file**

Create `skills/hydra:board/SKILL.md`:

```markdown
---
name: hydra-board
description: Connect Hydra task tracking to an external project board (GitHub Projects, Azure DevOps, etc). Use when user says "connect to github projects", "set up board", "track on github", or "hydra board".
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Board

## Examples
- `/hydra:board github` — Connect to GitHub Projects
- `/hydra:board github --clean` — Take over existing project (archive items first)
- `/hydra:board disconnect` — Remove board sync
- `/hydra:board status` — Show current board connection

## Arguments
$ARGUMENTS

## Current State
- Hydra initialized: !`[ -f hydra/config.json ] && echo "YES" || echo "NO"`
- Board enabled: !`jq -r '.board.enabled // false' hydra/config.json 2>/dev/null || echo "false"`
- Board provider: !`jq -r '.board.provider // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Last sync: !`jq -r '.board.last_sync // "never"' hydra/config.json 2>/dev/null || echo "never"`
- Sync failures: !`jq -r '.board.sync_failures // 0' hydra/config.json 2>/dev/null || echo "0"`
- GitHub repo: !`gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "NOT_DETECTED"`
- GitHub auth scopes: !`gh auth status 2>&1 | grep -oE 'project' || echo "NO_PROJECT_SCOPE"`
- Existing projects: !`gh project list --format json --jq '.projects[] | "\(.number): \(.title)"' 2>/dev/null | head -5 || echo "NONE"`
- Mapped tasks: !`jq -r '.board.task_map | length' hydra/config.json 2>/dev/null || echo "0"`

## Instructions

### Step 0: Parse Arguments

Parse `$ARGUMENTS` for:
- Provider name: `github`, `ado`, `trello` (first positional arg)
- Subcommand: `disconnect`, `status` (if no provider)
- Flags: `--clean` (archive existing items before setup)

### Step 1: Route by Command

#### If `disconnect`:
1. Run: `bash scripts/board-sync-github.sh disconnect`
2. Show: "Board sync disconnected."
3. STOP.

#### If `status`:
1. Run: `bash scripts/board-sync-github.sh status`
2. STOP.

#### If provider is `github`:
Continue to Step 2.

#### If provider is unsupported:
Show: "Provider '[name]' not yet supported. Available: github"
STOP.

#### If no arguments:
Show usage examples and current board state.
STOP.

### Step 2: Prerequisites Check

1. Check Hydra initialized (use preprocessor data above)
2. If NOT initialized: "Run `/hydra:init` first." — STOP
3. Check GitHub repo detected (use preprocessor data above)
4. If NOT detected: "Not a GitHub repository or `gh` not authenticated." — STOP
5. Check project scope (use preprocessor data above)
6. If NO_PROJECT_SCOPE: "Missing `project` scope. Run: `gh auth refresh -s project`" — STOP

### Step 3: Project Selection

Using the preprocessor "Existing projects" data:

1. If projects exist, present options:
   ```
   Existing GitHub Projects found:
   1. #[num]: [title]
   2. #[num]: [title]
   3. Create a new project

   Which project should Hydra use?
   ```

2. If no projects exist, ask:
   ```
   No existing GitHub Projects found. Create one?
   Project name (default: "Hydra: [repo-name]"):
   ```

3. If user picks "Create new":
   - Run: `gh project create --owner [owner] --title "[name]" --format json`
   - Extract project number

4. If user picks existing + `--clean` flag:
   - Show: "This will archive [N] items on project '[title]'. Continue?"
   - If confirmed: run `bash scripts/board-sync-github.sh archive-all [project-number]`

### Step 4: Run Setup

Run: `bash scripts/board-sync-github.sh setup [project-number]`

### Step 5: Initial Sync

If tasks already exist in `hydra/tasks/`:
1. Show: "Found [N] existing tasks. Syncing to board..."
2. Run: `bash scripts/board-sync-github.sh sync-all`
3. Show: "Synced [N] tasks to GitHub Projects."

### Step 6: Summary

Show:
```
Board sync enabled!
═══════════════════════════════
Provider:   GitHub Projects V2
Repo:       [owner]/[repo]
Project:    #[number] — [title]
Tasks:      [N] synced
URL:        https://github.com/orgs/[owner]/projects/[number]

Tasks will auto-sync to the board on every state transition.
Run `/hydra:board status` to check sync health.
Run `/hydra:board disconnect` to remove sync.
```
```

**Step 3: Run frontmatter test to verify new skill is valid**

Run: `bash tests/test-frontmatter.sh`
Expected: ALL PASS (includes hydra-board)

**Step 4: Run full test suite**

Run: `bash tests/run-tests.sh`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add skills/hydra:board/SKILL.md
git commit -m "feat(board): add /hydra:board skill for external board sync setup"
```

---

### Task 4: Integrate board sync into stop hook

**Files:**
- Modify: `scripts/stop-hook.sh:339-341` (add board sync after recovery pointer, before checkpoint rotation)
- Modify: `tests/test-stop-hook.sh` (add board sync test)

**Step 1: Read the test file to understand current test patterns**

Read: `tests/test-stop-hook.sh` — understand how the stop hook is tested to follow the same pattern.

**Step 2: Write the failing test**

Add a test to `tests/test-stop-hook.sh` that verifies the stop hook contains board sync logic:

```bash
# Test: stop hook has board sync section
assert_file_contains "has board sync section" "$SCRIPT" "BOARD SYNC"
assert_file_contains "has board.enabled check" "$SCRIPT" "board.enabled"
assert_file_contains "calls board-sync script" "$SCRIPT" "board-sync"
```

**Step 3: Run test to verify it fails**

Run: `bash tests/test-stop-hook.sh`
Expected: FAIL — board sync not in stop hook yet

**Step 4: Add board sync to stop hook**

Edit `scripts/stop-hook.sh`. After line 339 (end of Recovery Pointer update) and before line 341 (Checkpoint rotation comment), insert:

```bash

# --- BOARD SYNC — push status changes to external board ---
BOARD_ENABLED=$(jq -r '.board.enabled // false' "$CONFIG")
if [ "$BOARD_ENABLED" = "true" ]; then
  BOARD_PROVIDER=$(jq -r '.board.provider // ""' "$CONFIG")
  BOARD_SCRIPT="$SCRIPT_DIR/board-sync-${BOARD_PROVIDER}.sh"
  if [ -f "$BOARD_SCRIPT" ]; then
    if [ -d "$HYDRA_DIR/tasks" ]; then
      for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
        [ -f "$task_file" ] || continue
        bash "$BOARD_SCRIPT" sync-task "$task_file" 2>/dev/null || true
      done
    fi
  fi
fi
```

Note: We also need to add `SCRIPT_DIR` near the top of the file. Check if it exists. If not, add after `PROJECT_ROOT` (line 11):
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
```

**Step 5: Run test to verify it passes**

Run: `bash tests/test-stop-hook.sh`
Expected: PASS

**Step 6: Run full test suite**

Run: `bash tests/run-tests.sh`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add scripts/stop-hook.sh tests/test-stop-hook.sh
git commit -m "feat(board): integrate board sync into stop hook for automatic state push"
```

---

### Task 5: Add GitHub detection to discovery agent

**Files:**
- Modify: `agents/discovery.md:522-523` (add Step 6.5 between Step 6 and Step 7)

**Step 1: Read the discovery agent to identify exact insertion point**

Read: `agents/discovery.md:519-530` — confirm the boundary between Step 6 (reviewer generation) and Step 7 (summary).

**Step 2: Add GitHub detection step**

Edit `agents/discovery.md`. After the `---` separator on line 521 (end of Step 6) and before `## Step 7: Write Discovery Summary` on line 523, insert:

```markdown
## Step 6.5: GitHub Capability Detection

Detect whether this project is hosted on GitHub and whether the `gh` CLI is available with the required `project` scope. This is passive detection — no user prompts, just store what is found.

### Detection Steps

1. **Check for `gh` CLI**: `command -v gh`
2. **Check GitHub repo**: `gh repo view --json owner,name 2>/dev/null`
3. **Check auth scopes**: `gh auth status 2>&1` — look for `project` in the scopes list
4. **Check existing projects**: `gh project list --format json 2>/dev/null` — count projects

### Output

Append to `hydra/context/project-profile.md`:

```markdown
## GitHub Integration
- **GitHub repo**: [owner/repo or "Not detected"]
- **gh CLI**: [installed or "Not installed"]
- **project scope**: [present or "Not present — run: gh auth refresh -s project"]
- **Existing projects**: [count] projects found
```

### Update config.json

No config changes — this is informational only. The `/hydra:start` skill reads this from context to decide whether to prompt for board sync.

---
```

**Step 3: Verify the agent file is still valid markdown**

Read the modified file, confirm the step numbering flows correctly (6 → 6.5 → 7 → 8).

**Step 4: Commit**

```bash
git add agents/discovery.md
git commit -m "feat(board): add GitHub capability detection to discovery agent"
```

---

### Task 6: Add board sync prompt to `/hydra:start`

**Files:**
- Modify: `skills/hydra:start/SKILL.md:151-155` (add Step 5.5 in FRESH state, after "Collect Context" and before "Delegate to Planner")

**Step 1: Read the insertion point**

Read: `skills/hydra:start/SKILL.md:144-156` — the FRESH state flow.

**Step 2: Add board sync prompt**

Edit `skills/hydra:start/SKILL.md`. Between step 5 ("Collect Context", line 151) and step 6 ("Delegate to Planner", line 152), insert a new step:

```markdown
5.5. **Board Sync Prompt** (HITL mode only):
   - Check `hydra/context/project-profile.md` for "## GitHub Integration" section
   - If GitHub repo detected AND board not already enabled (`jq -r '.board.enabled' hydra/config.json` is `false`):
     - Ask user: "GitHub repo detected ([owner]/[repo]). Track tasks on GitHub Projects?"
     - Options:
       a. Yes, create a new project
       b. Yes, use an existing project (list them)
       c. Skip for now (can run `/hydra:board github` later)
     - If (a): run `gh project create --owner [owner] --title "Hydra: [repo]"`, then `bash scripts/board-sync-github.sh setup [number]`
     - If (b): let user pick, then `bash scripts/board-sync-github.sh setup [number]`
     - If (c): continue without board sync
   - In AFK mode: skip board prompt (user must run `/hydra:board` explicitly)
```

Renumber steps 6-9 to 7-10.

**Step 3: Verify step numbering is consistent**

Read the modified FRESH state section and confirm steps flow: 1, 2, 3, 4, 5, 5.5, 6, 7, 8, 9, 10.

**Step 4: Commit**

```bash
git add skills/hydra:start/SKILL.md
git commit -m "feat(board): add GitHub Projects prompt to /hydra:start flow"
```

---

### Task 7: Add board sync to planner agent

**Files:**
- Modify: `agents/planner.md:86-91` (add board sync call after task manifest writing)

**Step 1: Read the planner output section**

Read: `agents/planner.md:78-97`

**Step 2: Add board sync instruction**

Edit `agents/planner.md`. After line 86 ("Write individual task manifests to `hydra/tasks/TASK-NNN.md` using the task manifest template."), add:

```markdown

After writing each task manifest, if board sync is enabled, create the corresponding GitHub Issue:

```bash
if [ "$(jq -r '.board.enabled // false' hydra/config.json)" = "true" ]; then
  PROVIDER=$(jq -r '.board.provider' hydra/config.json)
  bash "scripts/board-sync-${PROVIDER}.sh" create-issue "hydra/tasks/TASK-NNN.md"
fi
```

This creates the GitHub Issue with status PLANNED and adds it to the project board. Sync failures are non-blocking — they log a warning but do not interrupt planning.
```

**Step 3: Commit**

```bash
git add agents/planner.md
git commit -m "feat(board): add board sync delegation to planner agent"
```

---

### Task 8: Add board status to `/hydra:status`

**Files:**
- Modify: `skills/hydra:status/SKILL.md` (add board section to preprocessor data and report format)

**Step 1: Read current hydra-status skill**

Read: `skills/hydra:status/SKILL.md`

**Step 2: Add board status to preprocessor data**

Edit `skills/hydra:status/SKILL.md`. After line 30 (Latest checkpoint), add:

```markdown
- Board enabled: !`jq -r '.board.enabled // false' hydra/config.json 2>/dev/null || echo "false"`
- Board provider: !`jq -r '.board.provider // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Board last sync: !`jq -r '.board.last_sync // "never"' hydra/config.json 2>/dev/null || echo "never"`
- Board failures: !`jq -r '.board.sync_failures // 0' hydra/config.json 2>/dev/null || echo "0"`
- Board tasks mapped: !`jq -r '.board.task_map | length' hydra/config.json 2>/dev/null || echo "0"`
```

**Step 3: Add board section to report format**

Edit `skills/hydra:status/SKILL.md`. After the "Git" section in the report format template (after line 78), add:

```markdown
Board Sync
─────────────────────────────────────
Enabled:     [yes/no]
Provider:    [github/none]
Last sync:   [timestamp]
Tasks mapped: [N]
Failures:    [N]
```

**Step 4: Commit**

```bash
git add skills/hydra:status/SKILL.md
git commit -m "feat(board): add board sync status to /hydra:status report"
```

---

### Task 9: Register test in run-tests.sh and run full suite

**Files:**
- Modify: `tests/run-tests.sh` (add test-board-sync-github.sh)

**Step 1: Read run-tests.sh to see registration pattern**

Read: `tests/run-tests.sh`

**Step 2: Add new test to the runner**

If `run-tests.sh` auto-discovers test files via glob, no change needed. If it lists tests explicitly, add `test-board-sync-github.sh` to the list.

**Step 3: Run full test suite**

Run: `bash tests/run-tests.sh`
Expected: ALL PASS

**Step 4: Commit (if changes needed)**

```bash
git add tests/run-tests.sh
git commit -m "test(board): register board sync test in test runner"
```

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Config schema | `templates/config.json`, `tests/test-config-schema.sh` |
| 2 | Sync script | `scripts/board-sync-github.sh`, `tests/test-board-sync-github.sh` |
| 3 | Skill | `skills/hydra:board/SKILL.md` |
| 4 | Stop hook integration | `scripts/stop-hook.sh`, `tests/test-stop-hook.sh` |
| 5 | Discovery detection | `agents/discovery.md` |
| 6 | Start prompt | `skills/hydra:start/SKILL.md` |
| 7 | Planner integration | `agents/planner.md` |
| 8 | Status display | `skills/hydra:status/SKILL.md` |
| 9 | Test runner | `tests/run-tests.sh` |
