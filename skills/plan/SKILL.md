---
name: nazgul:plan
description: Brainstorm a new idea/objective into a Nazgul spec and tasks, then optionally run it. Interactive design front-end — produces a per-idea spec and a ready-to-execute task plan.
argument-hint: "[\"idea or objective\"]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, ToolSearch
metadata:
  author: Jose Mejia
  version: 2.0.1
---

# Nazgul Plan

## Examples
- `/nazgul:plan` — brainstorm a new idea interactively, then generate spec + tasks
- `/nazgul:plan "add OAuth login"` — seed the brainstorm with an idea
- After it finishes: `/nazgul:start` runs the generated tasks (asks which mode)

## Arguments
$ARGUMENTS

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`
- Discovery: !`test -f nazgul/context/discovery-summary.md && echo "done" || echo "NOT_RUN"`
- Existing objectives: !`ls nazgul/context/objectives/*-spec.md 2>/dev/null | wc -l | tr -d ' '`
- Open tasks: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`

## Instructions

Format all output per `references/ui-brand.md`.

**Pre-load:** run `ToolSearch` with query `select:AskUserQuestion` (deferred tool) before any step that prompts.

### Pre-flight
1. If `nazgul/config.json` is missing: "Nazgul not initialized. Run `/nazgul:init` first." and STOP.
2. If `$ARGUMENTS` (the `## Arguments` value) is the bare literal `$ARGUMENTS`, STOP: "Skill argument substitution failed — plugin bug, do not proceed."
3. If an objective is already active — `nazgul/config.json → objective` is non-null AND any task in `nazgul/tasks/TASK-*.md` has status READY / IN_PROGRESS / IN_REVIEW / IMPLEMENTED / CHANGES_REQUESTED — STOP and tell the user: "An objective is already active with open tasks. Finish it (`/nazgul:start`), or archive with `/nazgul:reset`, before planning a new idea." Do NOT overwrite objective identity or append to `objectives_history` while a loop is active.

### Display Banner
```text
─── ◈ NAZGUL ▸ PLAN ────────────────────────────────────
```

### Step 1: Brainstorm the idea
Run an interactive design dialogue (one focused question at a time, or batched with `AskUserQuestion`). Seed from the `$ARGUMENTS` idea if provided. Cover:
- **Purpose** — what problem does this idea solve, and for whom?
- **Scope & constraints** — what's in, what's explicitly out, hard constraints.
- **Success criteria** — how do we know it's done/working?
- **Objective type** — feature / bugfix / refactor / greenfield / migration (Nazgul's types).
Don't over-ask; once you can state the idea crisply, confirm your understanding back to the user and get a yes before writing anything.

### Step 2: Write the per-idea spec
1. Own the objective identity (mirror what `/nazgul:start`'s Objective Derivation stores). Order matters:
   - **First** compute the feature id from the CURRENT history: `FEAT-NNN` where `NNN = ((.objectives_history // []) | length) + 1`, formatted `FEAT-%03d` (so the first idea is `FEAT-001`). Use `(.objectives_history // [])` to tolerate a missing or non-array field. Set `feat_display_id` to the same value (or the board issue id if a board is connected). Do this BEFORE appending to `objectives_history`, so the array length still reflects prior objectives.
   - **Then** write ALL of these to `nazgul/config.json` in ONE jq update (tmp + mv), so config is never left partially written:
     - `.objective` = the one-line objective statement
     - `.feat_id` = the computed `FEAT-NNN`
     - `.feat_display_id` = same (or board issue id)
     - `.afk.commit_prefix` = `"feat(<feat_display_id>):"`
     - append to `.objectives_history`: `{ feat_id, objective, started_at }` where `started_at` = `date -u +%Y-%m-%dT%H:%M:%SZ` — type-guard the field before `+` so a missing or non-array value never errors:

   ```bash
   jq --arg id "$FEAT_ID" --arg obj "$OBJECTIVE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.objective=$obj | .feat_id=$id | .feat_display_id=$id
      | .afk.commit_prefix=("feat(" + $id + "):")
      | .objectives_history = ((if (.objectives_history | type) == "array" then .objectives_history else [] end) + [{feat_id:$id, objective:$obj, started_at:$ts}])' \
     nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
   ```
   (If a board is connected and you use an issue id as `feat_display_id`, set `.feat_display_id` and the `commit_prefix` from that instead.)
2. Create `nazgul/context/objectives/` if missing. Write `nazgul/context/objectives/<feat_id>-spec.md` with: title, the objective statement, purpose, scope (in/out), constraints, success criteria, and an objective-type line. This is the per-idea spec the doc-generator reads as PRIMARY for this objective.
3. Show the spec and get the user's approval before generating tasks (HITL checkpoint). On changes, revise and re-confirm.

### Step 3: Generate tasks (reuse the pipeline)
1. If `nazgul/context/discovery-summary.md` is absent, dispatch `nazgul:discovery` (Task tool) to profile the project.
2. Dispatch `nazgul:doc-generator` (Task tool) — it reads the per-idea spec as PRIMARY and produces feature-scoped docs.
3. Dispatch `nazgul:planner` (Task tool) — it decomposes the objective into `nazgul/tasks/TASK-*.md`.
4. If any of these fail, report the failure and STOP (do not offer to run a broken plan).
5. Show the generated task list (ids + titles) for the user to review.

### Step 4: Offer to run
Ask with `AskUserQuestion`: "Spec + N tasks ready. Start now?"
- **Yes** → invoke `/nazgul:start` (it will resolve the run mode — flag / your `default_mode` / a prompt).
- **No** → end with a Next Up block: "Tasks ready. Run `/nazgul:start` when you want to execute."
