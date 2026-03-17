#!/usr/bin/env bash
set -euo pipefail

# file-improvement-report.sh — write a structured self-improvement report
# Usage: scripts/file-improvement-report.sh --task TASK-001 --agent implementer --rating 7 --summary "..." [--output-dir path]

TASK=""
AGENT=""
RATING=""
SUMMARY=""
OUTPUT_DIR="hydra/improvement-reports"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --rating) RATING="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$TASK" ] || [ -z "$AGENT" ] || [ -z "$RATING" ] || [ -z "$SUMMARY" ]; then
  echo "Usage: $0 --task TASK-NNN --agent NAME --rating N --summary 'text'" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILENAME="${OUTPUT_DIR}/${TIMESTAMP//[:.]/-}_${TASK}_${AGENT}.json"

jq -n \
  --arg task "$TASK" \
  --arg agent "$AGENT" \
  --argjson rating "$RATING" \
  --arg timestamp "$TIMESTAMP" \
  --arg summary "$SUMMARY" \
  '{task: $task, agent: $agent, rating: $rating, timestamp: $timestamp, summary: $summary, what_happened: "", repro_steps: [], what_would_make_it_a_10: ""}' \
  > "$FILENAME"

echo "Report filed: $FILENAME"
