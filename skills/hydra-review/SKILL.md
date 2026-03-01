---
name: hydra-review
description: Manually trigger a review cycle for a specific task or the current IN_REVIEW task. Use when asked to review a task, run reviewers, or check review status.
context: fork
allowed-tools: Read, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Review

## Examples
- `/hydra-review` — Review the current IN_REVIEW task
- `/hydra-review TASK-003` — Review a specific task by ID

## Current State
- Config: !`cat hydra/config.json 2>/dev/null || echo "No config"`
- Active reviewers: !`jq -r '.agents.reviewers // [] | join(", ")' hydra/config.json 2>/dev/null || echo "none"`
- Plan: !`head -20 hydra/plan.md 2>/dev/null || echo "No plan"`

## Arguments
$ARGUMENTS

## Instructions

### If a task ID is provided in arguments:
1. Read the task manifest at `hydra/tasks/[TASK-ID].md`
2. Verify the task is in IMPLEMENTED or IN_REVIEW status
3. Delegate to the Review Gate agent for that task

### If no task ID provided:
1. Scan `hydra/tasks/` for any task with status IMPLEMENTED or IN_REVIEW
2. If found, delegate to the Review Gate for that task
3. If none found, report that no tasks are ready for review

### Review Process
1. The Review Gate runs pre-checks (tests, lint)
2. Each reviewer evaluates the changed files
3. Reviews are written to `hydra/reviews/[TASK-ID]/`
4. Consolidated feedback (if rejection) written to `hydra/reviews/[TASK-ID]/consolidated-feedback.md`
5. Display the verdict and any blocking issues
