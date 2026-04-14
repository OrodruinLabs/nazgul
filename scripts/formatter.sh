#!/usr/bin/env bash
#
# formatter.sh — PostToolUse hook for automatic code formatting
#
# Fires on Edit/Write/MultiEdit tool use and formats the affected file
# using the appropriate formatter based on file extension.
#
# Opt-in: Only runs if nazgul/config.json → formatter.enabled is true
# or NAZGUL_FORMATTER_ENABLED=1 is set.
#
# Environment Variables:
#   NAZGUL_FORMATTER_ENABLED  - Set to "1" to enable (overrides config)
#   NAZGUL_FORMATTER_DISABLE  - Set to "1" to force-disable (overrides everything)
#   NAZGUL_FORMATTER_DEBUG    - Enable debug logging to stderr (default: "0")
#
# Hook Type: PostToolUse (matcher: Edit|Write|MultiEdit)
#   - Non-blocking: errors logged but don't fail the hook
#
# Exit codes:
#   0 - Always (non-blocking)

set -euo pipefail

debug_log() {
    if [[ "${NAZGUL_FORMATTER_DEBUG:-0}" == "1" ]]; then
        echo "[FORMATTER $(date -Iseconds)] $1" >&2
    fi
}

output_result() {
    local status="$1"
    local message="${2:-}"
    cat <<EOF
{"hookSpecificOutput": {"hookEventName": "PostToolUse", "status": "$status", "message": "$message", "timestamp": "$(date -Iseconds)"}}
EOF
    exit 0
}

# --- Check if enabled ---

if [[ "${NAZGUL_FORMATTER_DISABLE:-0}" == "1" ]]; then
    debug_log "Force-disabled (NAZGUL_FORMATTER_DISABLE=1)"
    output_result "disabled" "Force-disabled by env var"
fi

ENABLED="false"

# Check env var first
if [[ "${NAZGUL_FORMATTER_ENABLED:-0}" == "1" ]]; then
    ENABLED="true"
fi

# Check config.json
if [[ "$ENABLED" != "true" ]] && command -v jq &>/dev/null; then
    ENABLED=$(jq -r '.formatter.enabled // false' nazgul/config.json 2>/dev/null || echo "false")
fi

if [[ "$ENABLED" != "true" ]]; then
    debug_log "Not enabled (set formatter.enabled in config or NAZGUL_FORMATTER_ENABLED=1)"
    output_result "not_enabled" "Formatter not enabled"
fi

# --- Parse file path from stdin ---

INPUT=""
if [[ ! -t 0 ]]; then
    INPUT=$(cat)
fi

debug_log "Received input: ${INPUT:0:300}..."

FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_result.file_path // .file_path // .toolResult.file_path // .result.file_path // empty' 2>/dev/null || true)
    if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
        FILE_PATH=$(echo "$INPUT" | jq -r '.. | strings | select(test("^/.*\\.[a-zA-Z0-9]+$"))' 2>/dev/null | head -1 || true)
    fi
fi

# Fallback: grep for absolute paths
if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
    FILE_PATH=$(echo "$INPUT" | grep -oE '"/[^"]+\.[a-zA-Z0-9]+"' | head -1 | tr -d '"' || true)
fi

if [[ -z "$FILE_PATH" ]]; then
    debug_log "No file path found in input"
    output_result "no_file" "Could not extract file path"
fi

# Resolve relative paths
if [[ "$FILE_PATH" != /* ]]; then
    HOOK_CWD=""
    if command -v jq &>/dev/null; then
        HOOK_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
    fi
    if [[ -n "$HOOK_CWD" && -d "$HOOK_CWD" ]]; then
        FILE_PATH="${HOOK_CWD}/${FILE_PATH}"
    fi
fi

if [[ ! -f "$FILE_PATH" ]]; then
    debug_log "File does not exist: $FILE_PATH"
    output_result "file_not_found" "File not found: $FILE_PATH"
fi

# --- Determine formatter ---

EXT="${FILE_PATH##*.}"
if [[ "$EXT" == "$FILE_PATH" ]]; then
    output_result "no_extension" "File has no extension"
fi
# lowercase
EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

debug_log "File: $FILE_PATH, Extension: $EXT"

FORMATTER_CMD=""
case "$EXT" in
    js|jsx|ts|tsx|html|css|json|yaml|yml|md)
        if command -v prettier &>/dev/null; then
            FORMATTER_CMD="prettier --write"
        elif command -v npx &>/dev/null; then
            FORMATTER_CMD="npx prettier --write"
        fi
        ;;
    py)
        if command -v ruff &>/dev/null; then
            FORMATTER_CMD="ruff format"
        elif command -v black &>/dev/null; then
            FORMATTER_CMD="black"
        fi
        ;;
    go)
        if command -v goimports &>/dev/null; then
            FORMATTER_CMD="goimports -w"
        elif command -v gofmt &>/dev/null; then
            FORMATTER_CMD="gofmt -w"
        fi
        ;;
    rs)
        if command -v rustfmt &>/dev/null; then
            FORMATTER_CMD="rustfmt"
        fi
        ;;
    sh|bash)
        if command -v shfmt &>/dev/null; then
            FORMATTER_CMD="shfmt -w"
        fi
        ;;
    tf|tfvars)
        if command -v terraform &>/dev/null; then
            FORMATTER_CMD="terraform fmt"
        fi
        ;;
    c|cpp|h|hpp|cc|cxx)
        if command -v clang-format &>/dev/null; then
            FORMATTER_CMD="clang-format -i"
        fi
        ;;
    java)
        if command -v google-java-format &>/dev/null; then
            FORMATTER_CMD="google-java-format -i"
        fi
        ;;
    kt|kts)
        if command -v ktlint &>/dev/null; then
            FORMATTER_CMD="ktlint -F"
        fi
        ;;
    cs)
        if command -v dotnet &>/dev/null; then
            FORMATTER_CMD="dotnet csharpier"
        fi
        ;;
    swift)
        if command -v swift-format &>/dev/null; then
            FORMATTER_CMD="swift-format format -i"
        fi
        ;;
    lua)
        if command -v stylua &>/dev/null; then
            FORMATTER_CMD="stylua"
        fi
        ;;
    rb)
        if command -v rubocop &>/dev/null; then
            FORMATTER_CMD="rubocop -A --fail-level=error"
        fi
        ;;
    ex|exs)
        if command -v mix &>/dev/null; then
            FORMATTER_CMD="mix format"
        fi
        ;;
    *)
        debug_log "No formatter for extension: $EXT"
        output_result "no_formatter" "No formatter for .$EXT"
        ;;
esac

if [[ -z "$FORMATTER_CMD" ]]; then
    debug_log "Formatter not installed for extension: $EXT"
    output_result "no_formatter" "Formatter not installed for .$EXT"
fi

debug_log "Using formatter: $FORMATTER_CMD"

# --- Execute formatter ---

FORMAT_EXIT=0
# Safe array execution to prevent command injection
IFS=' ' read -ra CMD_ARRAY <<< "$FORMATTER_CMD"
if command -v timeout &>/dev/null; then
    timeout 30 "${CMD_ARRAY[@]}" "$FILE_PATH" 2>&1 || FORMAT_EXIT=$?
elif command -v gtimeout &>/dev/null; then
    gtimeout 30 "${CMD_ARRAY[@]}" "$FILE_PATH" 2>&1 || FORMAT_EXIT=$?
else
    "${CMD_ARRAY[@]}" "$FILE_PATH" 2>&1 || FORMAT_EXIT=$?
fi

if [[ $FORMAT_EXIT -ne 0 ]]; then
    debug_log "Formatter failed (exit $FORMAT_EXIT)"
    output_result "format_error" "Formatter exit code $FORMAT_EXIT"
fi

debug_log "Formatted successfully: $FILE_PATH"
output_result "formatted" "Formatted with $FORMATTER_CMD"
