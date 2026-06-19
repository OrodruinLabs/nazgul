---
name: nazgul:plan
description: Brainstorm a new idea/objective into a Nazgul spec and tasks, then optionally run it. Interactive design front-end — produces a per-idea spec and a ready-to-execute task plan.
argument-hint: "[\"idea or objective\"]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, ToolSearch
metadata:
  author: Jose Mejia
  version: 2.0.0
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

### Display Banner
```
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
1. Compute the next feature id: `FEAT-NNN` from `nazgul/config.json → objectives_history | length + 1` (matches `/nazgul:start`). Store in config: `objective` (a one-line statement of the idea), `feat_id`, `feat_display_id`.
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
