---
name: hydra-context
description: Collect targeted codebase context for a specific objective type. Use before planning to deeply understand the code that will be affected.
context: fork
allowed-tools: Read, Write, Bash, Glob, Grep, LS
---

# Hydra Context Collection

## Current Project
- Profile: !`head -20 hydra/context/project-profile.md 2>/dev/null || echo "No profile — run /hydra-init first"`
- Architecture: !`head -20 hydra/context/architecture-map.md 2>/dev/null || echo "No architecture map"`

## Arguments
$ARGUMENTS

## Instructions

Collect targeted context based on the objective type. Write results to `hydra/context/`.

### For Refactors
1. Identify ALL files in the refactor scope (use grep, glob)
2. Map their imports/exports to find the full dependency tree
3. Find ALL tests that cover these files
4. Find ALL callers of functions/classes being refactored
5. Check git blame for recent changes
6. Read the actual code of every file in scope
7. Document current behavior that must be preserved
8. Write findings to `hydra/context/refactor-scope.md`

### For Bug Fixes
1. Trace the code path from entry point to error
2. Find related tests (passing and failing)
3. Check git log for recent changes to affected files
4. Write findings to `hydra/context/bugfix-scope.md`

### For New Features
1. Find the most similar existing feature in the codebase
2. Map its implementation pattern (routes, handlers, services, models, tests)
3. Identify the extension points where the new feature integrates
4. Document the pattern to follow
5. Write findings to `hydra/context/feature-scope.md`

### For Greenfield
1. If project exists, scan for existing conventions
2. If starting fresh, establish conventions based on tech stack
3. Write findings to `hydra/context/greenfield-scope.md`

### Every context collection MUST produce:
- A scope file listing every file that will be read or modified
- A "pattern reference" section showing how similar things are done
- A "risks" section identifying what could break
- A "test impact" section listing tests that must pass
