#!/usr/bin/env bash
set -euo pipefail

# Nazgul Pre-Tool Guard — blocks destructive bash commands
# Exit 0 = allow command
# Exit 2 = block command (reason on stderr)

# The command being executed is passed via stdin or $ARGUMENTS
INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  INPUT=$(cat 2>/dev/null || echo "")
fi

# If no input, allow
if [ -z "$INPUT" ]; then
  exit 0
fi

# Destructive patterns to block
check_pattern() {
  local pattern="$1"
  local reason="$2"
  if echo "$INPUT" | grep -qiE "$pattern"; then
    echo "NAZGUL SAFETY: Blocked — $reason" >&2
    echo "Command contained: $pattern" >&2
    exit 2
  fi
}

# Filesystem destruction
check_pattern 'rm\s+-rf\s+/' "Recursive delete of root filesystem"
check_pattern 'rm\s+-rf\s+~' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\$HOME' "Recursive delete of home directory"
check_pattern 'rm\s+-rf\s+\.\s*$' "Recursive delete of current directory"

# Database destruction
check_pattern 'DROP\s+TABLE' "SQL table drop"
check_pattern 'DROP\s+DATABASE' "SQL database drop"
check_pattern 'TRUNCATE' "SQL table truncation"

# Git force push to protected branches
check_pattern 'git\s+push\s+.*--force.*\s+(main|master)' "Force push to main/master branch"
check_pattern 'git\s+push\s+-f\s+.*\s+(main|master)' "Force push to main/master branch"

# Fork bombs and system destruction
check_pattern ':\(\)\{' "Fork bomb"
check_pattern 'chmod\s+-R\s+777' "Recursive permission change to 777"
check_pattern 'mkfs\.' "Filesystem format"
check_pattern 'dd\s+if=.*of=/dev/' "Direct disk write"

# Piped execution from internet
check_pattern 'curl\s+.*\|\s*(ba)?sh' "Piped internet execution (curl | sh)"
check_pattern 'wget\s+.*\|\s*(ba)?sh' "Piped internet execution (wget | sh)"
check_pattern 'curl\s+.*\|\s*sudo' "Piped internet execution with sudo"

# Task manifest status protection — prevent bypassing Write/Edit hooks
check_pattern 'sed.*nazgul/tasks/TASK-.*Status' "Direct sed on task manifest status (use Write/Edit tools)"
check_pattern 'echo.*Status.*nazgul/tasks/TASK-' "Direct echo to task manifest (use Write/Edit tools)"
check_pattern 'printf.*Status.*nazgul/tasks/TASK-' "Direct printf to task manifest (use Write/Edit tools)"
check_pattern 'cat.*>.*nazgul/tasks/TASK-' "Direct cat redirect to task manifest (use Write/Edit tools)"
check_pattern 'tee.*nazgul/tasks/TASK-' "Direct tee to task manifest (use Write/Edit tools)"

# All checks passed
exit 0
