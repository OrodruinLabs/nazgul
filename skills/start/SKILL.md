---
name: nazgul:start
description: Start or resume a Nazgul autonomous development loop. Use when user says "start nazgul", "run nazgul", "begin development", "resume the loop", or passes an objective for new work. Auto-detects project state — no arguments needed.
argument-hint: "[\"objective\"] [--afk|--yolo|--hitl] [--max N] [--task-pr] [--parallel]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, ToolSearch
metadata:
  author: Jose Mejia
---

# Nazgul Start

## Examples
- `/nazgul:start` — Auto-detect project state and resume or begin work
- `/nazgul:start "add user authentication"` — Start a new objective
- `/nazgul:start --afk --max 20` — Run autonomously for up to 20 iterations
- `/nazgul:start --yolo` — Full autonomous mode with no permission prompts
- `/nazgul:start --yolo --task-pr` — YOLO mode with stacked per-task PRs
- `/nazgul:start --parallel` — Opt into stop-hook parallel batch dispatch (default: sequential); composes with any mode flag, e.g. `--parallel --afk`. `--conductor` is a deprecated alias for `--parallel`.

## Arguments
$ARGUMENTS

## Current Project State
- Config: !`cat nazgul/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Stored objective: !`jq -r '.objective // "none"' nazgul/config.json 2>/dev/null || echo "none"`
- Discovery: !`cat nazgul/context/discovery-summary.md 2>/dev/null || echo "NOT_RUN"`
- Project spec: !`cat nazgul/context/project-spec.md 2>/dev/null | head -3 || echo "NONE"`
- Classification: !`cat nazgul/context/project-classification.md 2>/dev/null | head -5 || echo "NOT_CLASSIFIED"`
- Docs generated: !`ls nazgul/docs/*.md 2>/dev/null | wc -l | tr -d ' '`
- Active tasks: !`grep -rl 'Status.*\(READY\|IN_PROGRESS\|IN_REVIEW\|IMPLEMENTED\|CHANGES_REQUESTED\)' nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Done tasks: !`grep -rl 'Status.*DONE' nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Total tasks: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Active reviewers: !`ls .claude/agents/generated/ 2>/dev/null || echo "No reviewers generated"`
- Current plan: !`head -20 nazgul/plan.md 2>/dev/null || echo "No plan yet"`
- Recovery Pointer: !`sed -n '/^## Recovery Pointer/,/^## /p' nazgul/plan.md 2>/dev/null | head -7 || echo "none"`
- TODOs in codebase: !`grep -rn 'TODO\|FIXME\|HACK\|XXX' --include='*.ts' --include='*.js' --include='*.py' --include='*.rb' --include='*.go' --include='*.rs' --include='*.java' --include='*.md' . 2>/dev/null | head -10 || echo "none"`
- Test context: !`cat nazgul/context/test-strategy.md 2>/dev/null | head -5 || echo "none"`

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, spawning indicators, and display patterns defined there.

### Parse Arguments
- `$ARGUMENTS` may contain:
  - An objective string (optional — override for new work)
  - Flags: `--afk`, `--hitl`, `--max N`, `--yolo`, `--task-pr`, `--continue`, `--parallel` (`--conductor` is a deprecated alias for `--parallel`)
  - Or nothing at all (smart mode — this is the default)

### YOLO Mode Pre-flight (--yolo)
Runs after **Apply Flags** / before Smart State Detection. The `afk.enabled`/`afk.yolo`/`afk.task_pr` config writes are already done by Apply Flags — do not repeat them here.

If `--yolo` was passed (mode is now `afk` + `afk.yolo` true via Apply Flags), verify the session is in a non-prompting permission mode. There is no API to read the active mode, so **probe** it:
- Try running a quick Bash command — if no permission prompt fires, we're good. (This holds under either `--permission-mode auto` OR `--dangerously-skip-permissions`; both skip routine prompts.)
- If permissions ARE being prompted, **STOP** and tell the user:
  ```text
  YOLO needs a non-prompting permission mode. Restart with ONE of:
    claude --permission-mode auto          # recommended — autonomous, but a background
                                           # safety classifier still blocks dangerous actions
                                           # (curl|bash, force-push to main, prod deploys, …)
    claude --dangerously-skip-permissions  # blunt bypass — no safety checks; isolated VM/container only
  Then re-run: /nazgul:start --yolo --max N
  ```
  Prefer `--permission-mode auto` (requires Claude Code v2.1.83+ and Opus 4.6+/Sonnet 4.6); fall back to `--dangerously-skip-permissions` only in a throwaway sandbox.
- Once confirmed, proceed with full autonomous mode — no pauses, no human gates. (Under `auto`, the classifier may still block a genuinely dangerous action — surface that to the user rather than retrying blindly.)

### Model Selection

Read `nazgul/config.json → models` to determine which model to assign each pipeline agent. When delegating via the Agent tool, pass the `model` parameter:

| Pipeline Agent    | Config Key            | Default |
|-------------------|-----------------------|---------|
| Discovery         | `models.discovery`    | sonnet  |
| Doc Generator     | `models.docs`         | sonnet  |
| Planner           | `models.planning`     | opus    |
| Implementer       | `models.implementation` | sonnet |
| Review Gate       | `models.review_orchestrator` | sonnet |

If the `models` section is missing from config.json, use `"sonnet"` as the fallback for all agents.

**Fast Mode:** If `models.fast_mode_implementation` is `true`, implementation and specialist agents use fast mode for ~2.5x speed improvement. This trades higher token cost for faster iteration cycles — useful for large objectives with many tasks.

### Session Naming

When launching Nazgul, use session naming for identification:
- Launch with: `claude -n "nazgul-<feat_display_id>"` (e.g., `claude -n "nazgul-FEAT-003"`)
- Agent Teams sessions are auto-named by the team-orchestrator: `nazgul-impl-TASK-NNN`, `nazgul-review-TASK-NNN`

### Apply Flags (MANDATORY — runs on every path, before state detection)
Persist the CLI flags to config via the tested helper, so every mode-gated branch below reads a correct `config.mode`:
```bash
[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "$ARGUMENTS"
```
This sets `mode` (`--yolo`/`--afk` → `afk`, `--hitl` → `hitl`), `afk.enabled`, `afk.yolo`, `afk.task_pr`, `max_iterations` (`--max N`, positive integer), and `execution.parallel` (`--parallel` → `true`; `--conductor` is a deprecated alias for `--parallel`; absent leaves it at its default `false`). `--hitl` wins if combined with `--afk`/`--yolo`; `--parallel` is orthogonal to mode and composes with any of them. Do NOT separately hand-edit these fields from flags anywhere else in this skill — this helper is the single source of truth.

### Resolve Run Mode (MANDATORY — before state detection)
**Pre-load:** run `ToolSearch` with query `select:AskUserQuestion` (the prompt tool is deferred by default).

**YOLO confirmation gate (shared):** YOLO must NEVER reach execution without an interactive YES. Whenever a path resolves to YOLO via a flag or `default_mode` (NOT via the user actively selecting "YOLO" in the null→ask menu — that selection IS the consent), fire this gate:
- `AskUserQuestion` header "YOLO", question "Run this objective in YOLO — no permission prompts, auto-commit?", options:
  - "Yes — full autonomous, no prompts" → proceed in YOLO (mode already applied as `--yolo`).
  - "No — switch to HITL" → apply HITL explicitly: `[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--hitl"`

Determine the run mode:
1. If `$ARGUMENTS` contained an explicit mode flag, Apply Flags already set the mode:
   - `--afk` or `--hitl` → mode is applied — **skip the rest of this section**.
   - `--yolo` → mode is now `afk` + `afk.yolo`, BUT you must still fire the **YOLO confirmation gate** above. On No, it re-applies HITL via the helper. Then continue past this section.
2. Otherwise (no explicit mode flag) read `nazgul/config.json → default_mode`:
   - `"hitl"` → apply with no prompt: `[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--hitl"`
   - `"afk"` → apply with no prompt: `[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--afk"`
   - `"yolo"` → apply it (`[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--yolo"`), then fire the **YOLO confirmation gate** above. On No, it re-applies HITL via the helper.
   - `null`/unset → **ask**: `AskUserQuestion` header "Mode", question "How should Nazgul run this objective?", options:
     - "HITL — review each step" → `--hitl`
     - "AFK — autonomous, pauses on risky decisions" → `--afk`
     - "YOLO — fully autonomous, no permission prompts" → `--yolo`
     The user selecting "YOLO" here IS the consent — do NOT fire the confirmation gate again. Apply the choice via `[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--<choice>"`. Then ask "Save this as your default mode?" — on Yes, write it using `jq --arg` (store the bare mode — `hitl`, `afk`, or `yolo` — never the `--hitl` flag form):
     `jq --arg m "<hitl|afk|yolo>" '.default_mode=$m' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json`
3. Non-interactive fallback: if `AskUserQuestion` is unavailable and `default_mode` is null, default to **HITL** and print a note. Never default to YOLO.
   - If a path resolves to YOLO (explicit `--yolo`, or `default_mode: "yolo"`) but `AskUserQuestion` is unavailable to collect the confirmation, do NOT run YOLO. Force HITL: `[ -f nazgul/config.json ] && "${CLAUDE_PLUGIN_ROOT}/scripts/apply-start-flags.sh" nazgul/config.json "--hitl"`, and print a note that interactive YOLO consent could not be collected. (YOLO never runs without an interactive YES.)

### Parallel Option (after Resolve Run Mode)

Read `nazgul/config.json → execution.parallel` (set by `--parallel`; `--conductor` is a
deprecated alias). No dispatch decision happens here — the stop-hook computes parallel
batches itself via `compute_dispatch_batch` (scripts/lib/parallel-batch.sh). Every state
below runs its "Delegate to Implementer / Stop hook takes over" step exactly as written
in BOTH modes; when a parallel batch is eligible the stop-hook's continuation message
carries a `DELEGATE (PARALLEL BATCH ...)` instruction instead of the single-task one.
Follow that instruction exactly: all batch Agent dispatches in ONE message, each prompt
carrying its `NAZGUL_UNIT: <task id>` line, one worktree per task, sequential merges,
then the batch's review-gates in one message.

Parallel batch dispatch only fires when `review_gate.granularity` is `"task"`. The
project template ships granularity `"group"`, so `--parallel` on a default config stays
fully sequential — this is intentional and pinned by test. Users who want batching should
set `review_gate.granularity: "task"`; with `"group"`/`"feature"` granularity the loop
stays sequential with aggregate reviews regardless of `execution.parallel`.

### Reset Loop Counters (MANDATORY)

Loop counters are **per-run state, not objective state**. A stale counter left over from a previous run will silently brick the loop: the stop hook hits its max-iteration or consecutive-failure gate on the very first iteration and exits 0 (allows the stop) instead of re-dispatching — so the loop "never continues" even though READY tasks exist. The same applies to the cost-governor accumulator `budget.spent_usd` — a stale value would trip the budget ceiling immediately.

Clearing `paused` here is also mandatory: the pause flag is **sticky** (the stop hook leaves it `true` on every Stop so a pause holds), so a previously-paused loop will exit 0 on its first iteration unless `/nazgul:start` clears it. Resuming the loop IS the explicit consent to un-pause.

**Before delegating to any agent, reset the counters and clear the pause flag.** The `[ -f ... ]` guard makes this a safe no-op in the NOT_INITIALIZED case (no `nazgul/config.json` yet), so the command is always safe to run regardless of ordering:

```bash
[ -f nazgul/config.json ] && \
  jq '.current_iteration = 0 | .safety.consecutive_failures = 0 | .safety._prev_done_count = 0
      | .paused = false
      | .budget = (if (.budget | type) == "object" then .budget else {} end) | .budget.spent_usd = 0' \
    nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
```

This applies to **every** loop-starting path (ACTIVE_LOOP, DOCS_READY, DISCOVERY_DONE, FRESH, New Objective Override). Do not skip it for those states.

### Objective Identity (use existing or assign)

Every branch-setup path below that needs a feature id MUST follow this rule instead of unconditionally recomputing one. The objective identity (`feat_id`, `feat_display_id`, `afk.commit_prefix`, and the `objectives_history` entry) is assigned exactly **once per objective**, at objective-creation time.

- **If `config.feat_id` is already set** (e.g. `/nazgul:plan` created this objective up front, or a prior start path already assigned it): **reuse it.** Do NOT recompute the id, do NOT overwrite `feat_id`/`feat_display_id`/`afk.commit_prefix`, and do NOT append to `objectives_history` — all of that was done at creation time. Just proceed to create the git branch/worktree using the existing `feat_id`/`feat_display_id`/`afk.commit_prefix`. (Recomputing here would assign the wrong id — e.g. FEAT-002 when plan made FEAT-001 — and orphan the `objectives/FEAT-001-spec.md` the doc-generator reads.)
- **Only when `config.feat_id` is null** do you assign identity: compute `FEAT-NNN` from `objectives_history.length + 1` (if board connected, prefer issue number as display_id), set `feat_id` + `feat_display_id` + `afk.commit_prefix` to `feat(<display_id>):`, and append the objective to `objectives_history` — exactly once.

### Branch Setup via `create_feature_branch` (shared by every branch-setup site below)

Every "Branch Setup" step referenced from a state below follows this same sequence — it replaces the old inline `git checkout -b`/config-write prose with the existing, already-correct `scripts/worktree-utils.sh` library (MF-034: this is what actually activates the managed git-hooks install, which the prose never did):

1. `source scripts/worktree-utils.sh` then call `create_feature_branch "$OBJECTIVE" "$(pwd)" nazgul/config.json`. This performs the full branch-setup (captures `branch.base`, stores `branch.main_worktree_path`, slugifies, `git checkout -b`, sets `feat_id`/`feat_display_id`/`afk.commit_prefix`) and calls `install_git_hooks` internally — the managed `core.hooksPath` and `branch.prior_hooks_path` are now set as a direct consequence of this one call. The helper is identity-reuse-safe per the **Objective Identity** rule above: an already-set `config.feat_id` (and its display id/commit prefix) is reused verbatim for the branch name and config fields; a fresh `FEAT-NNN` is derived from `objectives_history.length + 1` only when `feat_id` is null.
2. History append, per **Objective Identity (use existing or assign)** above:
   - Reuse case (`feat_id` was already set): do NOT append to `objectives_history` — already done at original assignment time.
   - Assign case (`feat_id` was null before step 1): append `{feat_id, objective, started_at}` to `objectives_history` exactly once.
3. `setup_worktree_dir "$(pwd)" nazgul/config.json` to create the worktree dir and store its path in config.

### Smart State Detection

Evaluate the preprocessor data above. Work through this state machine top-to-bottom — take the FIRST state that matches:

---

#### STATE: NOT_INITIALIZED
**Detection:** Config shows "NOT_INITIALIZED"
**Action:** Tell the user: "Nazgul not initialized. Run `/nazgul:init` first."
**Stop here.**

---

#### STATE: ACTIVE_LOOP
**Detection:** Active tasks > 0 (any task with status READY, IN_PROGRESS, IN_REVIEW, IMPLEMENTED, or CHANGES_REQUESTED)
**Action:** Auto-resume the loop.
1. Tell the user: "Resuming: [stored objective]. [N] active tasks remaining."
2. Read `nazgul/plan.md` → Recovery Pointer
3. Read the latest checkpoint in `nazgul/checkpoints/`
4. Read the active task manifest
5. **Branch Verification:** Read `nazgul/config.json → branch.feature`.
   - If set: verify current branch matches, `git checkout <feature>` if not on it
   - If null (pre-v3 project): create feature branch now via the shared helper (see **Branch Setup via `create_feature_branch`** below).
6. Mode was already applied from flags by the **Apply Flags** step above; do not re-derive it here. (Loop counters were already reset by the mandatory **Reset Loop Counters** step above.)
7. Delegate to the appropriate agent based on active task status:
   - READY/IN_PROGRESS → Implementer
   - IMPLEMENTED/IN_REVIEW → Review Gate
   - CHANGES_REQUESTED → Implementer (read consolidated feedback first)
   - BLOCKED → Show to user, ask what to do
8. The stop hook takes over from here.

---

#### STATE: OBJECTIVE_COMPLETE
**Detection:** Total tasks > 0 AND active tasks == 0 AND done tasks == total tasks
**Action:** All tasks are done.
1. VERIFY FROM DISK first: re-read every task manifest
   (`grep -H -E '(^\- \*\*Status\*\*:|^## Status:)' nazgul/tasks/TASK-*.md`). If any task is not
   DONE, this state was mis-detected — report the actual statuses and route to
   the appropriate state instead. Never emit NAZGUL_COMPLETE, and never write
   DONE entries to plan.md, based on remembered transitions: status writes can
   be blocked by guards, so claims must come from reads that happened after the
   last write.
2. Check if post-loop agents have already run (look for release notes, updated CHANGELOG, etc.)
3. If post-loop NOT run yet:
   - Tell user: "All [N] tasks complete. Running post-loop agents (documentation, release, observability)..."
   - Delegate to post-loop agents (documentation → release-manager → observability)
   - **Verify generated docs (cross-check — MANDATORY gate).** If
     `nazgul/config.json` has `.docs.verify_post_loop` true (or absent — default true),
     dispatch the doc-verifier agent (Agent tool, `subagent_type: "nazgul:doc-verifier"`).
     It cross-checks `nazgul/docs/*.md` and the current-objective entries in `CHANGELOG.md`
     against source: every event type, config key, command/skill name, named script, and
     schema version in the docs must exist in the codebase. On a clean pass it records
     completion by writing the feat_id to `nazgul/logs/.docs-verified`. The stop hook
     **gates loop completion** on this marker: until it matches the current `feat_id`,
     NAZGUL_COMPLETE is withheld (a bounded backstop of 3 attempts prevents an unwritable
     marker from deadlocking an unattended loop). If the verifier itself errors, it is
     non-fatal — log it; the gate's attempt backstop lets the loop complete. To skip
     verification set `docs.verify_post_loop: false` in `nazgul/config.json` (clean no-op).
   - **Auto-distill learnings (proposes only — MANDATORY gate).** If
     `nazgul/config.json` has `.learning.enabled` AND `.learning.auto_distill_post_loop`
     both true, dispatch the learner agent (Agent tool, `subagent_type: "nazgul:learner"`).
     It mines this objective's review/diagnosis artifacts and writes candidate rules to
     `nazgul/learning/proposed-rules.md` for the user to review later via `/nazgul:learn`.
     It NEVER approves or edits the rules registry. The stop hook **gates loop
     completion** on this: when all tasks are DONE but the learner hasn't run for this
     objective, it blocks the stop with a DELEGATE instruction. The learner records
     completion by writing the objective id to `nazgul/learning/.distilled`; until that
     marker matches, the loop will not reach NAZGUL_COMPLETE (a bounded backstop
     prevents an unwritable marker from looping forever). If the learner itself errors,
     it is non-fatal — log it; the gate's attempt backstop lets the loop complete.
   - After post-loop:
     a. Read `nazgul/config.json → branch.feature` and `branch.base`
     b. If feature branch exists:
        - Push the feature branch: `git push -u origin <feature-branch>`
        - Create PR: `gh pr create --base <base-branch> --head <feature-branch> --title "<objective> (<feat_display_id>)" --body "<task summary>"`
        - Clean up all worktrees: `source scripts/worktree-utils.sh` then `cleanup_all_worktrees "$(pwd)" nazgul/config.json` — removes every task worktree plus the worktree parent dir, and uninstalls the managed git hooks (restoring the recorded prior `core.hooksPath`) when this objective actually installed them.
     c. Output NAZGUL_COMPLETE
4. If post-loop already run:
   - Tell user: "Previous objective complete: [stored objective]. Starting objective derivation for next work..."
   - Fall through to FRESH state below to derive a new objective

---

#### STATE: DOCS_READY
**Detection:** Docs generated > 0 AND total tasks == 0
**Action:** Documents exist but no plan yet — regenerate documents from current context, then run the planner.
1. Read stored objective from config.json
2. If no objective: read the PRD overview section as the objective, store it in config.json
3. **Branch Setup** (if `branch.feature` is null): follow **Branch Setup via `create_feature_branch`** above.
4. Tell user: "Regenerating documents from current context before planning..."
5. Delegate to Doc Generator agent (regenerates all docs to reflect current objective and context)
6. In HITL mode, pause for doc review.
7. Tell user: "Docs ready. Running planner..."
8. Delegate to Planner agent
9. Review Plan (HITL mode: show plan for approval. AFK: continue.)
10. Delegate to Implementer.
11. Stop hook takes over.

---

#### STATE: DISCOVERY_DONE
**Detection:** Discovery summary is NOT "NOT_RUN" AND docs generated == 0 AND total tasks == 0
**Action:** Discovery ran but no docs or plan yet.
1. Check if objective exists in config.json
2. If no objective: run **Objective Derivation** (see below)
3. **Branch Setup:** follow **Branch Setup via `create_feature_branch`** above.
4. Tell user: "Discovery complete. Generating documents, then planning..."
5. Delegate to Doc Generator agent. In HITL mode, pause for doc review.
6. Delegate to Planner agent. In HITL mode, pause for plan review.
7. Delegate to Implementer.
8. Stop hook takes over.

---

#### STATE: FRESH
**Detection:** None of the above matched (config exists but discovery hasn't run)
**Action:** Fresh project — need discovery + everything.
1. Run **Objective Derivation** (see below) if no objective in config.json
2. **Branch Setup:** follow **Branch Setup via `create_feature_branch`** above (worktree dir is created as a sibling of the project root, e.g. `../<project>-worktrees/`).
3. Run Discovery agent (scans codebase, classifies project, generates reviewers)
4. Classify Project: In HITL mode, confirm classification with user.
5. Generate Documents: Delegate to Doc Generator. In HITL mode, pause for doc review.
6. Collect Context: Based on objective type, collect targeted context.
6.5. **Board Sync Prompt** (HITL mode only):
   - Check `nazgul/context/project-profile.md` for "## GitHub Integration" section
   - If GitHub repo detected AND board not already enabled (`jq -r '.board.enabled' nazgul/config.json` is `false`):
     - Ask user: "GitHub repo detected ([owner]/[repo]). Track tasks on GitHub Projects?"
     - Options:
       a. Yes, create a new project
       b. Yes, use an existing project (list them)
       c. Skip for now (can run `/nazgul:board github` later)
     - If (a): run `gh project create --owner [owner] --title "Nazgul: [repo]"`, then `bash scripts/board-sync-github.sh setup [number]`
     - If (b): let user pick, then `bash scripts/board-sync-github.sh setup [number]`
     - If (c): continue without board sync
   - In AFK mode: skip board prompt (user must run `/nazgul:board` explicitly)
8. Delegate to Planner: Planner reads context + docs, decomposes into tasks.
9. Review Plan (HITL): Show plan for approval. AFK: continue.
10. Delegate to Implementer: start working on the first READY task.
11. Stop hook takes over.

---

### Objective Derivation

When no objective exists in config.json and none was provided as an argument, Nazgul derives one from project signals. The approach depends on whether this is a greenfield project.

#### Check: Is this a Greenfield Project?
If classification is `GREENFIELD` (from `nazgul/context/project-classification.md`) OR the codebase has fewer than 10 source files:
→ Go to **Greenfield Stack Scaffolding** (below)

Otherwise → continue with signal scanning:

#### Step 1: Scan for signals (use the preprocessor data above + additional reads)
Gather signals in priority order:
1. **Project profile** — read `nazgul/context/project-profile.md` for stated goals, purpose
2. **TODO/FIXME/HACK comments** — from the preprocessor TODOs data
3. **Failing tests** — run the project's test command (from config.json `project.test_command`) and capture failures
4. **README roadmap** — read the project's README.md for "roadmap", "planned features", "next steps" sections
5. **Recent git activity** — `git log --oneline -10` for patterns like "WIP:", "started:", incomplete work
6. **Open GitHub issues** — `gh issue list --limit 5 --state open` (if `gh` is available)

#### Step 2: Present or select
**HITL mode** — Present discovered signals as an interactive menu:
```
Nazgul scanned your project and found potential work:

1. [signal description] (source: TODOs in src/payments/)
2. [signal description] (source: 2 failing tests in auth.test.ts)
3. [signal description] (source: GitHub issue #12)
4. Something else — tell me what you want to build

Which objective should I pursue?
```
Wait for user selection. If user picks "something else", use their input.

**AFK mode** — Auto-select the highest-priority signal:
- Priority: failing tests > TODOs with urgency keywords (FIXME, HACK) > open issues > WIP commits > general TODOs
- If zero signals found: error — "No objective could be derived from project context. Run `/nazgul:start 'your objective'` to specify one."

#### Step 3: Store
Write the derived/selected objective to config.json:
```json
{
  "objective": "[the derived objective]",
  "objective_set_at": "[ISO 8601 timestamp]"
}
```
Do NOT append to `objectives_history` here — the single per-objective append is owned by the **Objective Identity (use existing or assign)** rule and happens at branch setup (only when `config.feat_id` is null). Appending here too would double-append.

---

### Greenfield Stack Scaffolding

For greenfield projects, Nazgul first checks for a project spec (see Step 0 in `references/greenfield-scaffolding.md`), then runs an interactive stack selection, tool pre-flight check, and configuration workflow. Consult `references/greenfield-scaffolding.md` for the full process including project spec detection, stack selection menus, AFK defaults, tool configuration steps, infrastructure scaffolding, and config storage.

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
     b. Cancel and resume current work (/nazgul:start)
     ```
   - In AFK mode with active tasks: auto-archive and start new
   - If no active tasks: proceed directly
2. **Archive old work** (if applicable):
   - Create `nazgul/archive/[YYYY-MM-DD-HHMMSS]/` directory
   - Move: plan.md, tasks/, reviews/, docs/, checkpoints/ into archive
   - Keep: config.json (will be updated), context/ (still valid for same project)
   - Update the PREVIOUS objective's `objectives_history` entry with `completed_at` and `plan_archived_to`
   - **Clear the old objective identity so the new objective gets a fresh one:** set `branch.feature`, `feat_id`, and `feat_display_id` to null in config.json. (If you skip this, the idempotent Objective Identity rule would REUSE the previous objective's id for the new objective.)
3. **Store new objective** in config.json: set `objective`, `objective_set_at`. Do NOT append to `objectives_history` here — the single per-objective append is owned by the **Objective Identity (use existing or assign)** rule and fires at branch setup now that `feat_id` was cleared in step 2.
4. **Proceed with FRESH state pipeline** (discovery if stale → docs → plan → implement)

---

### `--continue` Flag (backward compatibility)

If `--continue` is present, behave exactly as ACTIVE_LOOP state (loop counters are reset by the mandatory **Reset Loop Counters** step).
If no active tasks found: "Nothing to continue. Run `/nazgul:start` to auto-detect what to do."

---

### Wave-Based Execution

Superseded: parallel execution is now the stop-hook's `execution.parallel` batch
dispatch (see "Parallel Option" above). The `parallelism.*` config keys are inert.

---

### AFK Mode Notes
- `afk.enabled` is `true` (set by the Apply Flags step — do not set it here)
- Auto-commit on every state transition with dynamic prefix from config (e.g., `feat(FEAT-003):` or `feat(#42):`)
- Security rejections → BLOCKED (requires human review later)
- No pauses for human review

### YOLO Mode Notes
- Everything in AFK mode, PLUS:
- Zero permission prompts — all tool calls execute immediately
- **All reviewers still run** — the full review gate executes for every task
- **Default: Feature-level PR** — tasks merge into feature branch (same as hitl/afk), single PR created at objective completion
- **Optional: `--task-pr`** — enables stacked per-task PRs targeting feature branch (legacy behavior)
- **Worktree isolation** — each task gets its own worktree at `<worktree_dir>/TASK-NNN` with branch `feat/<display_id>/TASK-NNN`
- Tests, lint, security guards fully active
- Requires launching Claude Code with `--dangerously-skip-permissions`
