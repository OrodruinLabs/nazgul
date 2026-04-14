---
name: nazgul:simplify
description: Run a cleanup and simplification pass on all files modified during a Nazgul loop. Use after a Nazgul loop completes to improve code clarity without changing functionality.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Nazgul Simplify

## Examples
- `/nazgul:simplify` — Run cleanup pass on all files modified during the last Nazgul loop

## Modified Files
- Git changes: !`git diff --name-only HEAD~10 2>/dev/null || echo "No recent changes"`
- Config: !`jq '.afk.commit_prefix // "feat:"' nazgul/config.json 2>/dev/null || echo "feat:"`

## Arguments
$ARGUMENTS

## Modes

Simplification runs in three modes:

### Manual Mode (`/nazgul:simplify`)
User-invoked post-loop cleanup. Runs on all files modified during the last Nazgul loop. This is what you get when you run the command directly.

### Per-Task Mode (review-gate Step 0)
Automatic. After each task reaches IMPLEMENTED, the simplifier agent reviews the task's changed files for reuse, quality, and efficiency — fixing issues before reviewers see the code. Reduces review round-trips.

Always runs. Not configurable — simplification is mandatory before review.

### Post-Loop Batch Mode (review-gate Step 5.0)
Automatic. After ALL tasks are DONE, a batch simplification pass runs across all files modified during the entire loop. Catches cross-task issues (duplicate utilities, inconsistent patterns) that per-task simplify can't see.

Config: `nazgul/config.json → simplify.post_loop` (default: `true`)

### Focus
All modes support an optional focus argument (e.g., `"performance"`, `"readability"`) to narrow the review scope.

Config: `nazgul/config.json → simplify.focus` (default: `null`)

## Instructions

Run a post-loop cleanup pass on files modified during the Nazgul loop.

### Process
1. Identify all files modified during the Nazgul loop:
   - Check git log for commits with the configured commit prefix
   - `git log --oneline --all --grep="$(jq -r '.afk.commit_prefix // "feat("' nazgul/config.json 2>/dev/null)" --name-only`
2. For each modified file:
   a. Read the file
   b. Look for simplification opportunities:
      - Unnecessary complexity
      - Duplicated code that could be extracted
      - Overly verbose patterns that have simpler equivalents
      - Dead code or unused imports
      - Inconsistent naming that doesn't match project conventions
   c. Apply simplifications
   d. Run tests after EACH simplification to verify no regressions
   e. If tests fail, revert the simplification
3. Report what was simplified and what was left alone

### Rules
- NON-DESTRUCTIVE: Run tests after every change
- No functional changes — only clarity and consistency improvements
- Match the project's existing style (read nazgul/context/style-conventions.md)
- If unsure whether a change is safe, skip it
