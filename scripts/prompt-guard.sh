#!/usr/bin/env bash
set -euo pipefail

# Hydra Prompt Guard — validates user input in HITL mode
# Fires on UserPromptSubmit. Blocks accidental state-machine bypasses.
# Returns exit 2 to block the prompt, exit 0 to allow.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# If Hydra not initialized, allow all prompts
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Read the user's prompt from hook input
USER_PROMPT="${CLAUDE_HOOK_USER_PROMPT:-}"

# If no prompt content available, allow
if [ -z "$USER_PROMPT" ]; then
  exit 0
fi

# Block manual HYDRA_COMPLETE signals — only the review gate should emit this
if echo "$USER_PROMPT" | grep -q 'HYDRA_COMPLETE'; then
  echo "BLOCKED: HYDRA_COMPLETE can only be emitted by the review gate, not typed manually." >&2
  echo "Use /hydra:start to resume the loop or /hydra:status to check progress." >&2
  exit 2
fi

# Block direct task status manipulation via text
if echo "$USER_PROMPT" | grep -qE '(set.*status.*to|change.*status.*to|mark.*as).*(DONE|APPROVED|IN_REVIEW|IMPLEMENTED)'; then
  echo "BLOCKED: Task status changes must go through the proper state machine." >&2
  echo "Use /hydra:task to manage tasks or let the pipeline handle transitions." >&2
  exit 2
fi

# Allow everything else
exit 0
