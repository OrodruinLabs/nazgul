---
name: hydra:simplify
description: Run a cleanup and simplification pass on all files modified during a Hydra loop. Use after a Hydra loop completes to improve code clarity without changing functionality.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Simplify

## Examples
- `/hydra:simplify` — Run cleanup pass on all files modified during the last Hydra loop

## Modified Files
- Git changes: !`git diff --name-only HEAD~10 2>/dev/null || echo "No recent changes"`
- Config: !`jq '.afk.commit_prefix // "hydra:"' hydra/config.json 2>/dev/null || echo "hydra:"`

## Arguments
$ARGUMENTS

## Instructions

Run a post-loop cleanup pass on files modified during the Hydra loop.

### Process
1. Identify all files modified during the Hydra loop:
   - Check git log for commits with the hydra: prefix
   - `git log --oneline --all --grep="hydra:" --name-only`
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
- Match the project's existing style (read hydra/context/style-conventions.md)
- If unsure whether a change is safe, skip it
