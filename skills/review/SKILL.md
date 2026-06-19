---
name: nazgul:review
description: Manually trigger a review cycle for a specific task or the current IN_REVIEW task. Use when asked to review a task, run reviewers, or check review status.
context: fork
allowed-tools: Read, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 2.0.1
---

# Nazgul Review

## Examples
- `/nazgul:review` — Review the current IN_REVIEW task
- `/nazgul:review TASK-003` — Review a specific task by ID
- `/nazgul:review --materialize TASK-003` — Repair a task stuck without per-reviewer evidence: re-run the full board, write genuine reviewer files
- `/nazgul:review --materialize --all` — Repair every task whose evidence is missing or incomplete

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null || echo "No config"`
- Active reviewers: !`jq -r '.agents.reviewers // [] | join(", ")' nazgul/config.json 2>/dev/null || echo "none"`
- Plan: !`head -20 nazgul/plan.md 2>/dev/null || echo "No plan"`

## Arguments
$ARGUMENTS

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, review verdicts, spawning indicators, and display patterns defined there.

### If a task ID is provided in arguments:
1. Read the task manifest at `nazgul/tasks/[TASK-ID].md`
2. Verify the task is in IMPLEMENTED or IN_REVIEW status (unless `--materialize` is present — see repair mode below)
3. Delegate to the Review Gate agent for that task

### If no task ID provided:
1. Scan `nazgul/tasks/` for any task with status IMPLEMENTED or IN_REVIEW
2. If found, delegate to the Review Gate for that task
3. If none found, report that no tasks are ready for review

### If --materialize is in arguments (repair mode):

Repair mode exists for tasks deadlocked by missing per-reviewer evidence
(e.g., a run that wrote a consolidated summary.md instead of
`nazgul/reviews/[TASK-ID]/<reviewer>.md` files). It re-earns evidence by
running genuine reviews — it NEVER converts summary.md claims into reviewer
files.

1. **Select targets:**
   - With a TASK-ID: that task only.
   - With `--all`: every task in `nazgul/tasks/` whose status is DONE,
     APPROVED, IMPLEMENTED, IN_REVIEW, or BLOCKED with a review-evidence
     Blocked reason, and where any configured reviewer
     (`jq -r '.agents.reviewers[]' nazgul/config.json`) lacks an APPROVED
     `nazgul/reviews/[TASK-ID]/<reviewer>.md`. Including IMPLEMENTED is by
     design: the deadlock parks tasks there; a task awaiting first review
     simply gets its first review. Including evidence-BLOCKED tasks matters
     most: those are exactly what the stop hook's escalation creates.
     Display the matched list before dispatch.
2. **Accept any post-implementation status** — IMPLEMENTED, IN_REVIEW, DONE,
   APPROVED, or BLOCKED (when the Blocked reason mentions review evidence).
   If BLOCKED for another reason, skip and report.
3. **Reconstruct the diff if missing:** if `nazgul/reviews/[TASK-ID]/diff.patch`
   does not exist, rebuild it from the commit SHA(s) in the task manifest's
   `## Commits` section: `git show <sha> > nazgul/reviews/[TASK-ID]/diff.patch`
   (append multiple SHAs with `>>`). If the manifest has no commits, set the
   task BLOCKED with reason `cannot materialize reviews — no commit SHA in
   manifest` and report.
4. **Dispatch the FULL configured reviewer board** over the diff via the Review
   Gate agent — each reviewer writes its own
   `nazgul/reviews/[TASK-ID]/<reviewer>.md`.
5. **On all APPROVED:** walk the legal state path for the current mode: first
   reach IN_REVIEW (IMPLEMENTED → IN_REVIEW, or BLOCKED → IN_REVIEW — legal
   because the reviewer files now exist), then if `afk.yolo` is true in
   `nazgul/config.json`: IN_REVIEW → APPROVED; otherwise IN_REVIEW → DONE.
   (Tasks already DONE that pass
   validation need no walk.) Then clear the escalation bookkeeping: remove the
   task's key from `.safety._review_reset_counts` in `nazgul/config.json`
   (jq + temp-file write), and remove any `review evidence missing` Blocked
   reason line from the manifest.
6. **On rejection:** normal CHANGES_REQUESTED flow — repair runs get no lower
   bar. A genuine rejection is signal, not friction.

### Review Process
1. The Review Gate runs pre-checks (tests, lint)
2. Each reviewer evaluates the changed files
3. Reviews are written to `nazgul/reviews/[TASK-ID]/`
4. Consolidated feedback (if rejection) written to `nazgul/reviews/[TASK-ID]/consolidated-feedback.md`
5. Display the verdict and any blocking issues
