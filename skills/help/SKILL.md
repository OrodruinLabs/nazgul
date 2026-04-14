---
name: nazgul:help
description: Show Nazgul quick reference — all commands, modes, and getting started guide. Use when user says "nazgul help", "what commands", or needs orientation.
disable-model-invocation: true
allowed-tools: []
metadata:
  author: Jose Mejia
  version: 1.2.1
---

# Nazgul Framework — Quick Reference

## Getting Started

| Command | Description |
|---------|-------------|
| `/nazgul:init` | Set up Nazgul for this project |
| `/nazgul:init --local` | Set up without tracking files in git |
| `/nazgul:init --force` | Reinitialize (archives current state) |

## Running

| Command | Description |
|---------|-------------|
| `/nazgul:start` | Auto-detect state and continue work |
| `/nazgul:start "objective"` | Start a specific objective |

**Flags for `/nazgul:start`:** `--afk` (autonomous), `--yolo` (no reviews), `--hitl` (human-in-the-loop, default), `--max N` (iteration limit)

## Monitoring

| Command | Description |
|---------|-------------|
| `/nazgul:status` | Loop progress, task counts, review board |
| `/nazgul:log` | Iteration history, commits, reviews |
| `/nazgul:task list` | List all tasks with status |

## Task Management

| Command | Description |
|---------|-------------|
| `/nazgul:task add "desc"` | Add a new task |
| `/nazgul:task skip <id>` | Skip a blocked task |
| `/nazgul:task unblock <id>` | Unblock a task |
| `/nazgul:task info <id>` | Show task details |
| `/nazgul:task prioritize <id>` | Move task to top of queue |

## Control

| Command | Description |
|---------|-------------|
| `/nazgul:pause` | Pause loop at next iteration boundary |
| `/nazgul:reset` | Archive state and start fresh |
| `/nazgul:review` | Manually trigger review for a task |
| `/nazgul:clean` | Fully remove Nazgul from this project |

## Advanced

| Command | Description |
|---------|-------------|
| `/nazgul:discover` | Re-run codebase discovery |
| `/nazgul:context` | Collect context for an objective type |
| `/nazgul:simplify` | Post-loop cleanup pass |
| `/nazgul:docs` | View or regenerate project documents |
| `/nazgul:board` | Connect to GitHub Projects / Azure DevOps |
| `/nazgul:config` | View and change settings (models, formatter, notifications) |
| `/nazgul:gen-spec` | Interactively build a project specification |

## Modes

| Mode | Description |
|------|-------------|
| `hitl` | **Human-in-the-loop** (default) — confirms before major actions |
| `afk` | **Autonomous** — runs unattended, commits per iteration |
| `yolo` | **Full auto** — no reviews, no confirmations, maximum speed |

## The 10 Rules

1. Always read `plan.md` first — the Recovery Pointer tells you where you are
2. Files are truth, context is ephemeral — write state to disk immediately
3. Follow existing patterns exactly — read before implementing
4. Tests are mandatory — run after every change
5. Never skip the review gate — ALL reviewers must approve
6. Address ALL blocking feedback — fix every REJECT item
7. One task at a time — unless using parallel Agent Teams
8. Update Recovery Pointer on every state change
9. Commit in AFK mode — every state transition gets a `nazgul:` commit
10. NAZGUL_COMPLETE means ALL tasks DONE and post-loop finished
