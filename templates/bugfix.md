# Bugfix Objective

## Objective
<!-- Describe the bug. Include reproduction steps if known. -->

## Bug Description
- **Expected behavior**: <!-- What should happen -->
- **Actual behavior**: <!-- What actually happens -->
- **Reproduction steps**:
  1. <!-- Step 1 -->
  2. <!-- Step 2 -->
- **Error messages**: <!-- Paste any errors -->
- **Environment**: <!-- OS, browser, version, etc. -->

## Requirements
- [ ] Bug is reproduced with a failing test
- [ ] Root cause is identified and documented
- [ ] Fix addresses root cause, not symptoms
- [ ] Regression test prevents recurrence
- [ ] No unrelated changes included

## Acceptance Criteria
- [ ] <!-- The specific behavior that confirms the fix -->
- [ ] Regression test passes
- [ ] All existing tests still pass

## Pattern Reference
<!-- Filled by Planner -->
- Affected file(s): <!-- path:line -->
- Related test(s): <!-- path:line -->
- Similar past fix: <!-- path:line or git commit -->

## Context Collection Notes
The Planner should:
1. Trace the code path from entry point to error
2. Find related tests (passing and failing)
3. Check git log for recent changes to affected files
4. Document findings in hydra/context/bugfix-scope.md

## Root Cause Analysis
<!-- Filled during investigation -->
- **Root cause**:
- **Why it wasn't caught**:
- **Files affected**:

## Out of Scope
<!-- Bug fix only — no feature additions, no refactoring -->
-

## Constraints
- Minimal change set — fix the bug, nothing more
