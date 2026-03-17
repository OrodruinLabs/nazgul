#!/usr/bin/env bash
# session-runner.sh — spawns claude -p for E2E skill testing
# Adapted from gstack's session-runner pattern
#
# Usage: source this file, then call run_skill_session and assert_output_contains

set -euo pipefail

run_skill_session() {
  local skill_command="$1"
  local timeout_seconds="${2:-60}"
  local output_file
  output_file=$(mktemp)

  echo "[e2e] Running: claude -p \"$skill_command\" (timeout: ${timeout_seconds}s)" >&2

  if timeout "$timeout_seconds" claude -p "$skill_command" \
    --output-format text \
    --max-turns 5 \
    > "$output_file" 2>&1; then
    echo "[e2e] Session completed successfully" >&2
  else
    local exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      echo "[e2e] Session timed out after ${timeout_seconds}s" >&2
    else
      echo "[e2e] Session exited with code $exit_code" >&2
    fi
  fi

  cat "$output_file"
  rm -f "$output_file"
}

assert_output_contains() {
  local output="$1"
  local expected="$2"
  local description="${3:-contains '$expected'}"

  if echo "$output" | grep -qF "$expected"; then
    echo "  PASS: $description"
    return 0
  else
    echo "  FAIL: $description"
    echo "  Expected to find: $expected"
    echo "  In output (first 500 chars): ${output:0:500}"
    return 1
  fi
}

assert_output_not_contains() {
  local output="$1"
  local unexpected="$2"
  local description="${3:-does not contain '$unexpected'}"

  if echo "$output" | grep -qF "$unexpected"; then
    echo "  FAIL: $description"
    echo "  Did not expect: $unexpected"
    return 1
  else
    echo "  PASS: $description"
    return 0
  fi
}
