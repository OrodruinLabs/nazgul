#!/usr/bin/env bash
set -euo pipefail

# Hydra Config Migration — upgrades project config to latest schema version
# Called by session-context.sh on every session start.
# Usage: migrate-config.sh [hydra_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HYDRA_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra}"
CONFIG="$HYDRA_DIR/config.json"
TEMPLATE="$PLUGIN_ROOT/templates/config.json"

# Nothing to migrate if no project config or no template
if [ ! -f "$CONFIG" ]; then
  exit 0
fi
if [ ! -f "$TEMPLATE" ]; then
  exit 0
fi

CURRENT_VERSION=$(jq -r '.schema_version // 1' "$CONFIG")
TARGET_VERSION=$(jq -r '.schema_version // 1' "$TEMPLATE")

# Already up to date
if [ "$CURRENT_VERSION" -ge "$TARGET_VERSION" ]; then
  exit 0
fi

# Create log directory
LOG_DIR="$HYDRA_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/migrations.log"

log_migration() {
  printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$LOG_FILE"
}

# Backup before migration
BACKUP="$CONFIG.v${CURRENT_VERSION}.bak"
cp "$CONFIG" "$BACKUP"
log_migration "Backup created: $BACKUP"

# --- Migration functions (incremental) ---

migrate_1_to_2() {
  local tmp
  tmp=$(mktemp)

  # Add schema_version field
  jq '.schema_version = 2' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  # Add models section only if not already present
  if [ "$(jq 'has("models")' "$CONFIG")" = "false" ]; then
    tmp=$(mktemp)
    jq '.models = {
      "planning": "opus",
      "discovery": "opus",
      "docs": "opus",
      "review": "opus",
      "implementation": "sonnet",
      "specialists": "sonnet",
      "post_loop": "sonnet",
      "default": "sonnet"
    }' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi

  log_migration "Migrated 1 -> 2: added schema_version, ensured models section"
}

# --- Run incremental migrations ---

VERSION="$CURRENT_VERSION"
while [ "$VERSION" -lt "$TARGET_VERSION" ]; do
  NEXT=$((VERSION + 1))
  FUNC="migrate_${VERSION}_to_${NEXT}"
  if type "$FUNC" >/dev/null 2>&1; then
    "$FUNC"
    log_migration "Migration $VERSION -> $NEXT complete"
  else
    log_migration "ERROR: No migration function for $VERSION -> $NEXT"
    echo "ERROR: Missing migration function ${FUNC}" >&2
    exit 1
  fi
  VERSION="$NEXT"
done

log_migration "Config migrated from v${CURRENT_VERSION} to v${TARGET_VERSION}"
echo "Hydra config migrated from v${CURRENT_VERSION} to v${TARGET_VERSION}."
