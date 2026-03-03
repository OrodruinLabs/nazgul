---
name: hydra-start
description: Start or resume a Hydra autonomous development loop. Use when user says "start hydra", "run hydra", "begin development", "resume the loop", or passes an objective for new work. Auto-detects project state — no arguments needed.
context: fork
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Start

## Examples
- `/hydra-start` — Auto-detect project state and resume or begin work
- `/hydra-start "add user authentication"` — Start a new objective
- `/hydra-start --afk --max 20` — Run autonomously for up to 20 iterations
- `/hydra-start --yolo` — Full autonomous mode with no permission prompts

## Arguments
$ARGUMENTS

## Current Project State
- Config: !`cat hydra/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Stored objective: !`jq -r '.objective // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Discovery: !`cat hydra/context/discovery-summary.md 2>/dev/null || echo "NOT_RUN"`
- Project spec: !`cat hydra/context/project-spec.md 2>/dev/null | head -3 || echo "NONE"`
- Classification: !`cat hydra/context/project-classification.md 2>/dev/null | head -5 || echo "NOT_CLASSIFIED"`
- Docs generated: !`ls hydra/docs/*.md 2>/dev/null | wc -l | tr -d ' '`
- Active tasks: !`grep -rl 'Status.*\(READY\|IN_PROGRESS\|IN_REVIEW\|IMPLEMENTED\|CHANGES_REQUESTED\)' hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Done tasks: !`grep -rl 'Status.*DONE' hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Total tasks: !`ls hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Active reviewers: !`ls .claude/agents/generated/ 2>/dev/null || echo "No reviewers generated"`
- Current plan: !`head -20 hydra/plan.md 2>/dev/null || echo "No plan yet"`
- Recovery Pointer: !`sed -n '/^## Recovery Pointer/,/^## /p' hydra/plan.md 2>/dev/null | head -7 || echo "none"`
- TODOs in codebase: !`grep -rn 'TODO\|FIXME\|HACK\|XXX' --include='*.ts' --include='*.js' --include='*.py' --include='*.rb' --include='*.go' --include='*.rs' --include='*.java' --include='*.md' . 2>/dev/null | head -10 || echo "none"`
- Test context: !`cat hydra/context/test-strategy.md 2>/dev/null | head -5 || echo "none"`

## Instructions

### Parse Arguments
- `$ARGUMENTS` may contain:
  - An objective string (optional — override for new work)
  - Flags: `--afk`, `--hitl`, `--max N`, `--yolo`, `--continue`
  - Or nothing at all (smart mode — this is the default)

### YOLO Mode Pre-flight (--yolo)
If `--yolo` flag is present:
1. Set `afk.enabled: true` and `afk.yolo: true` in config.json
2. Check if the current session was launched with `--dangerously-skip-permissions`:
   - Try running a quick Bash command — if no permission prompt fires, we're good
   - If permissions ARE being prompted, **STOP** and tell the user:
     ```
     YOLO mode requires --dangerously-skip-permissions. Restart with:
     claude --dangerously-skip-permissions
     Then re-run: /hydra-start --yolo --max N
     ```
3. Once confirmed, proceed with full autonomous mode — no pauses, no permission prompts, no human gates

### Model Selection

Read `hydra/config.json → models` to determine which model to assign each pipeline agent. When delegating via the Task tool, pass the `model` parameter:

| Pipeline Agent    | Config Key            | Default |
|-------------------|-----------------------|---------|
| Discovery         | `models.discovery`    | opus    |
| Doc Generator     | `models.docs`         | opus    |
| Planner           | `models.planning`     | opus    |
| Implementer       | `models.implementation` | sonnet |
| Review Gate       | `models.review`       | opus    |

If the `models` section is missing from config.json, use `"sonnet"` as the fallback for all agents.

### Smart State Detection

Evaluate the preprocessor data above. Work through this state machine top-to-bottom — take the FIRST state that matches:

---

#### STATE: NOT_INITIALIZED
**Detection:** Config shows "NOT_INITIALIZED"
**Action:** Tell the user: "Hydra not initialized. Run `/hydra-init` first."
**Stop here.**

---

#### STATE: ACTIVE_LOOP
**Detection:** Active tasks > 0 (any task with status READY, IN_PROGRESS, IN_REVIEW, IMPLEMENTED, or CHANGES_REQUESTED)
**Action:** Auto-resume the loop.
1. Tell the user: "Resuming: [stored objective]. [N] active tasks remaining."
2. Read `hydra/plan.md` → Recovery Pointer
3. Read the latest checkpoint in `hydra/checkpoints/`
4. Read the active task manifest
5. Update config.json: set mode from flags (afk/hitl), reset `current_iteration` to 0. If `current_iteration >= max_iterations`, ALSO reset `current_iteration` to 0 and bump `max_iterations` by its original value (e.g., 40 → 80) to allow the continued run to have a full iteration budget.
6. Delegate to the appropriate agent based on active task status:
   - READY/IN_PROGRESS → Implementer
   - IMPLEMENTED/IN_REVIEW → Review Gate
   - CHANGES_REQUESTED → Implementer (read consolidated feedback first)
   - BLOCKED → Show to user, ask what to do
7. The stop hook takes over from here.

---

#### STATE: OBJECTIVE_COMPLETE
**Detection:** Total tasks > 0 AND active tasks == 0 AND done tasks == total tasks
**Action:** All tasks are done.
1. Check if post-loop agents have already run (look for release notes, updated CHANGELOG, etc.)
2. If post-loop NOT run yet:
   - Tell user: "All [N] tasks complete. Running post-loop agents (documentation, release, observability)..."
   - Delegate to post-loop agents (documentation → release-manager → observability)
   - After post-loop: output HYDRA_COMPLETE
3. If post-loop already run:
   - Tell user: "Previous objective complete: [stored objective]. Starting objective derivation for next work..."
   - Fall through to FRESH state below to derive a new objective

---

#### STATE: DOCS_READY
**Detection:** Docs generated > 0 AND total tasks == 0
**Action:** Documents exist but no plan yet — run the planner.
1. Read stored objective from config.json
2. If objective exists: tell user "Docs ready. Running planner on existing documents..."
3. If no objective: read the PRD overview section as the objective, store it in config.json
4. Delegate to Planner agent
5. Review Plan (HITL mode: show plan for approval. AFK: continue.)
6. Delegate to Implementer
7. Stop hook takes over.

---

#### STATE: DISCOVERY_DONE
**Detection:** Discovery summary is NOT "NOT_RUN" AND docs generated == 0 AND total tasks == 0
**Action:** Discovery ran but no docs or plan yet.
1. Check if objective exists in config.json
2. If no objective: run **Objective Derivation** (see below)
3. Tell user: "Discovery complete. Generating documents, then planning..."
4. Delegate to Doc Generator agent. In HITL mode, pause for doc review.
5. Delegate to Planner agent. In HITL mode, pause for plan review.
6. Delegate to Implementer
7. Stop hook takes over.

---

#### STATE: FRESH
**Detection:** None of the above matched (config exists but discovery hasn't run)
**Action:** Fresh project — need discovery + everything.
1. Run **Objective Derivation** (see below) if no objective in config.json
2. Run Discovery agent (scans codebase, classifies project, generates reviewers)
3. Classify Project: In HITL mode, confirm classification with user.
4. Generate Documents: Delegate to Doc Generator. In HITL mode, pause for doc review.
5. Collect Context: Based on objective type, collect targeted context.
5.5. **Board Sync Prompt** (HITL mode only):
   - Check `hydra/context/project-profile.md` for "## GitHub Integration" section
   - If GitHub repo detected AND board not already enabled (`jq -r '.board.enabled' hydra/config.json` is `false`):
     - Ask user: "GitHub repo detected ([owner]/[repo]). Track tasks on GitHub Projects?"
     - Options:
       a. Yes, create a new project
       b. Yes, use an existing project (list them)
       c. Skip for now (can run `/hydra-board github` later)
     - If (a): run `gh project create --owner [owner] --title "Hydra: [repo]"`, then `bash scripts/board-sync-github.sh setup [number]`
     - If (b): let user pick, then `bash scripts/board-sync-github.sh setup [number]`
     - If (c): continue without board sync
   - In AFK mode: skip board prompt (user must run `/hydra-board` explicitly)
7. Delegate to Planner: Planner reads context + docs, decomposes into tasks.
8. Review Plan (HITL): Show plan for approval. AFK: continue.
9. Delegate to Implementer: Start working on the first READY task.
10. Stop hook takes over.

---

### Objective Derivation

When no objective exists in config.json and none was provided as an argument, Hydra derives one from project signals. The approach depends on whether this is a greenfield project.

#### Check: Is this a Greenfield Project?
If classification is `GREENFIELD` (from `hydra/context/project-classification.md`) OR the codebase has fewer than 10 source files:
→ Go to **Greenfield Stack Scaffolding** (below)

Otherwise → continue with signal scanning:

#### Step 1: Scan for signals (use the preprocessor data above + additional reads)
Gather signals in priority order:
1. **Project profile** — read `hydra/context/project-profile.md` for stated goals, purpose
2. **TODO/FIXME/HACK comments** — from the preprocessor TODOs data
3. **Failing tests** — run the project's test command (from config.json `project.test_command`) and capture failures
4. **README roadmap** — read the project's README.md for "roadmap", "planned features", "next steps" sections
5. **Recent git activity** — `git log --oneline -10` for patterns like "WIP:", "started:", incomplete work
6. **Open GitHub issues** — `gh issue list --limit 5 --state open` (if `gh` is available)

#### Step 2: Present or select
**HITL mode** — Present discovered signals as an interactive menu:
```
Hydra scanned your project and found potential work:

1. [signal description] (source: TODOs in src/payments/)
2. [signal description] (source: 2 failing tests in auth.test.ts)
3. [signal description] (source: GitHub issue #12)
4. Something else — tell me what you want to build

Which objective should I pursue?
```
Wait for user selection. If user picks "something else", use their input.

**AFK mode** — Auto-select the highest-priority signal:
- Priority: failing tests > TODOs with urgency keywords (FIXME, HACK) > open issues > WIP commits > general TODOs
- If zero signals found: error — "No objective could be derived from project context. Run `/hydra-start 'your objective'` to specify one."

#### Step 3: Store
Write the derived/selected objective to config.json:
```json
{
  "objective": "[the derived objective]",
  "objective_set_at": "[ISO 8601 timestamp]"
}
```
Append to `objectives_history` array.

---

### Greenfield Stack Scaffolding

For greenfield projects, Hydra first checks for a project spec (see Step 0 in `references/greenfield-scaffolding.md`), then runs an interactive stack selection, tool pre-flight check, and configuration workflow. Consult `references/greenfield-scaffolding.md` for the full process including project spec detection, stack selection menus, AFK defaults, tool configuration steps, infrastructure scaffolding, and config storage.

For the tool detection commands table (check commands and install commands per platform), see `references/tool-preflight.md`.

---

### New Objective Override (argument provided)

When the user explicitly passes an objective string in `$ARGUMENTS`:

1. **Check for existing active work:**
   - If active tasks exist, warn in HITL mode:
     ```
     You have an active objective: "[stored objective]" with [N] tasks remaining.
     Options:
     a. Archive it and start the new objective
     b. Cancel and resume current work (/hydra-start)
     ```
   - In AFK mode with active tasks: auto-archive and start new
   - If no active tasks: proceed directly
2. **Archive old work** (if applicable):
   - Create `hydra/archive/[YYYY-MM-DD-HHMMSS]/` directory
   - Move: plan.md, tasks/, reviews/, docs/, checkpoints/ into archive
   - Keep: config.json (will be updated), context/ (still valid for same project)
   - Update `objectives_history` in config.json with `completed_at` and `plan_archived_to`
3. **Store new objective** in config.json: set `objective`, `objective_set_at`, append to `objectives_history`
4. **Proceed with FRESH state pipeline** (discovery if stale → docs → plan → implement)

---

### `--continue` Flag (backward compatibility)

If `--continue` is present, behave exactly as ACTIVE_LOOP state. Also reset `current_iteration` to 0 if it has reached `max_iterations`.
If no active tasks found: "Nothing to continue. Run `/hydra-start` to auto-detect what to do."

---

### AFK Mode Notes
- Set `afk.enabled: true` in config
- Auto-commit on every state transition with `hydra:` prefix
- Security rejections → BLOCKED (requires human review later)
- No pauses for human review

### YOLO Mode Notes
- Everything in AFK mode, PLUS:
- Zero permission prompts — all tool calls execute immediately
- **All reviewers still run** — the full review gate executes for every task
- **Deferred merge** — after reviewers approve, task → APPROVED + stacked PR created; DONE only when PR merged
- **Branch stacking** — each task gets `hydra/TASK-NNN` branch based on previous task's branch
- Loop continues immediately after APPROVED — doesn't wait for PR merge
- Tests, lint, security guards fully active
- Requires launching Claude Code with `--dangerously-skip-permissions`
