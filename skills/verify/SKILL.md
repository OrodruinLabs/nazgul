---
name: hydra:verify
description: "Human acceptance testing — structured verification that work actually works. Run standalone or integrated in HITL review cycle."
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Verify

## Examples
- `/hydra:verify` — Verify all completed tasks that haven't been verified yet
- `/hydra:verify TASK-003` — Verify a specific completed task

## Arguments
$ARGUMENTS

## Current State
- Config: !`cat hydra/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`
- Completed unverified tasks: !`for f in hydra/tasks/TASK-*.md; do status=$(grep -m1 'Status' "$f" 2>/dev/null | sed 's/.*: *//'); id=$(basename "$f" .md); if [ "$status" = "DONE" ] && [ ! -f "hydra/tasks/$id/verification.md" ]; then echo "$id"; fi; done 2>/dev/null || echo "none"`

## Instructions

### Pre-flight
1. Check if `hydra/config.json` exists. If not: "Hydra not initialized. Run `/hydra:init` first." and STOP.
2. Parse `$ARGUMENTS`:
   - If a task ID provided → verify that specific task
   - If no arguments → find all DONE tasks without `verification.md` and verify them in sequence

### Display Banner
```
─── ◈ HYDRA ▸ VERIFYING ─────────────────────────────────
```

### Step 1: Load Task Context

For each task being verified:
1. Read the task manifest at `hydra/tasks/TASK-NNN.md`
2. Verify status is DONE (or APPROVED in YOLO mode). If not: "TASK-NNN is not complete (status: [status]). Only completed tasks can be verified."
3. Read the implementation log section for what was built
4. Read acceptance criteria for what should be true
5. Check for review results in `hydra/reviews/TASK-NNN/`

### Step 2: Automated Pre-Checks (Levels 1-3)

Run automated verification using patterns from `references/verification-patterns.md`:

**Level 1 — Exists:**
- Check all files listed in the task's `File Scope → Creates` actually exist
- Check all files in `File Scope → Modifies` were actually modified (git diff)

**Level 2 — Substantive:**
- Run stub detection patterns on created/modified files
- Check substantive size heuristics
- Flag any files with TODO/FIXME/placeholder patterns

**Level 3 — Wired:**
- Check that new files are imported/referenced somewhere
- Check that modified files still have valid connections

Report pre-check results:
```
Automated Pre-Checks
─────────────────────────────────────
  ✦ Level 1 (Exists):      4/4 files present
  ⚠ Level 2 (Substantive): 3/4 pass (1 stub detected in src/utils/helper.ts)
  ✦ Level 3 (Wired):       4/4 connected

1 issue found — included in verification walkthrough below.
```

### Step 3: Extract Testable Deliverables

From the task manifest, extract user-observable outcomes:
1. Read acceptance criteria checkboxes
2. Read implementation log for what was built
3. Convert to testable deliverables — things a human can verify by looking/clicking/using

Focus on outcomes, not implementation:
- Good: "Login form accepts email and password, redirects to dashboard on success"
- Bad: "useAuth hook returns user object with correct fields"

### Step 4: Conversational Walkthrough (Level 4)

Present each deliverable one at a time:

```
┌─── ◈ CHECKPOINT: Verification Required ──────────────┐
│                                                       │
│  TASK-003: User Authentication                        │
│  Test 1 of 4                                          │
│                                                       │
│  Expected: Login form accepts email and password.     │
│  On valid credentials, redirects to /dashboard.       │
│  On invalid credentials, shows error message.         │
│                                                       │
│  → Type "yes" if it works, or describe what's wrong   │
└───────────────────────────────────────────────────────┘
```

Handle responses:
- "yes" / "y" / "pass" / empty → Mark as PASS, move to next
- Anything else → Log as issue with user's description, mark FAIL, continue to next

### Step 5: Record Results

Write `hydra/tasks/TASK-NNN/verification.md` (create directory if needed):

```markdown
# Verification: TASK-NNN

## Summary
- **Verified at**: [ISO 8601 timestamp]
- **Verified by**: human (via /hydra:verify)
- **Result**: [ALL_PASS | ISSUES_FOUND]

## Pre-Checks
- Level 1 (Exists): [N/N pass]
- Level 2 (Substantive): [N/N pass]
- Level 3 (Wired): [N/N pass]

## Deliverable Results
| # | Deliverable | Result | Notes |
|---|-------------|--------|-------|
| 1 | [description] | ✦ PASS | — |
| 2 | [description] | ✗ FAIL | [user's description of issue] |

## Issues
### Issue 1: [description from user]
- **Deliverable**: #2
- **Pre-check findings**: [any related automated findings]
```

### Step 6: Handle Issues

If any issues found:
1. For each issue, create a new task:
   - `hydra/tasks/TASK-MMM.md` with status READY
   - Description references the original task and the specific issue
   - Link: `- **Traces to**: TASK-NNN verification issue #N`
2. Report:
```
─── ◈ HYDRA ▸ VERIFYING ─────────────────────────────────

TASK-003: 3/4 deliverables passed, 1 issue found

  ✦ Login form renders correctly
  ✦ Valid credentials redirect to dashboard
  ✗ Invalid credentials — error message not shown
  ✦ Session persists after refresh

Fix task created: TASK-008 (fix error message display)

─── ◈ NEXT ─────────────────────────────────────────────
  /hydra:start to implement fixes
────────────────────────────────────────────────────────
```

If all pass:
```
─── ◈ HYDRA ▸ VERIFYING ─────────────────────────────────

✦ TASK-003: All 4 deliverables verified

─── ◈ NEXT ─────────────────────────────────────────────
  /hydra:verify to check more tasks
  /hydra:start to continue
────────────────────────────────────────────────────────
```

### Error Handling
- If task not found: "Task TASK-NNN not found."
- If task not complete: "TASK-NNN is not complete (status: [status]). Complete it first."
- If no tasks to verify: "All completed tasks have been verified. Nothing to do."
