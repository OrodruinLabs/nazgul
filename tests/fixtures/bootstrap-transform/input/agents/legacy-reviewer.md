---
name: legacy-reviewer
description: "Pipeline: code quality reviewer for Python."
tools:
  - Read
  - Grep
allowed-tools: Read, Grep
maxTurns: 30
nazgul:
  phase: review
  priority: high
review-board:
  enabled: true
loop-phase: review
nazgul_config_key: some-value
model: claude-sonnet
---

# Legacy Reviewer

Review Python code for style and correctness.
