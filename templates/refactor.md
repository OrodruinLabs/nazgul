# Refactor Objective

## Objective
<!-- Describe what to refactor and why. What's the target architecture? -->

## Current State
<!-- Brief description of current architecture/structure being refactored -->

## Target State
<!-- What the code should look like after refactoring -->

## Requirements
- [ ] All existing behavior preserved (no functional changes)
- [ ] All existing tests continue to pass
- [ ] New tests added for any extracted modules/functions
- [ ] No regressions in performance

## Acceptance Criteria
- [ ] <!-- Specific structural change — "Module X extracted to Y" -->
- [ ] <!-- Specific structural change -->
- [ ] All tests pass before AND after each refactoring step

## Pattern Reference
<!-- Filled by Planner -->
- Current implementation: <!-- path:line -->
- Target pattern example: <!-- path:line (if exists elsewhere in codebase) -->
- All callers of refactored code: <!-- paths -->
- All tests covering refactored code: <!-- paths -->

## Context Collection Notes (CRITICAL)
The Planner MUST run FULL context collection before planning a refactor:
1. Identify ALL files in the refactor scope
2. Map their imports/exports to find the FULL dependency tree
3. Find ALL tests that cover these files
4. Find ALL callers of functions/classes being refactored
5. Check git blame for recent changes
6. Read the actual code of EVERY file in scope
7. Document current behavior that MUST be preserved
8. Write findings to nazgul/context/refactor-scope.md

**WARNING**: Skipping context collection on a refactor will cause broken dependencies, missing test updates, and reviewer rejections. The Planner must map the full blast radius.

## Out of Scope
- No new features
- No behavior changes
- No dependency upgrades (unless directly required by the refactor)

## Rollback Plan
<!-- How to revert if the refactor goes wrong -->
-

## Constraints
-
