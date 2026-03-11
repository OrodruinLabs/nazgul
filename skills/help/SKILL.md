---
name: hydra:help
description: Show Hydra quick reference — all commands, modes, and getting started guide. Use when user says "hydra help", "what commands", or needs orientation.
disable-model-invocation: true
allowed-tools: []
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Hydra Framework — Quick Reference

## Getting Started

| Command | Description |
|---------|-------------|
| `/hydra:init` | Set up Hydra for this project |
| `/hydra:init --local` | Set up without tracking files in git |
| `/hydra:init --force` | Reinitialize (archives current state) |

## Running

| Command | Description |
|---------|-------------|
| `/hydra:start` | Auto-detect state and continue work |
| `/hydra:start "objective"` | Start a specific objective |

**Flags for `/hydra:start`:** `--afk` (autonomous), `--yolo` (no reviews), `--hitl` (human-in-the-loop, default), `--max N` (iteration limit)

## Monitoring

| Command | Description |
|---------|-------------|
| `/hydra:status` | Loop progress, task counts, review board |
| `/hydra:log` | Iteration history, commits, reviews |
| `/hydra:task list` | List all tasks with status |

## Task Management

| Command | Description |
|---------|-------------|
| `/hydra:task add "desc"` | Add a new task |
| `/hydra:task skip <id>` | Skip a blocked task |
| `/hydra:task unblock <id>` | Unblock a task |
| `/hydra:task info <id>` | Show task details |
| `/hydra:task prioritize <id>` | Move task to top of queue |

## Control

| Command | Description |
|---------|-------------|
| `/hydra:pause` | Pause loop at next iteration boundary |
| `/hydra:reset` | Archive state and start fresh |
| `/hydra:review` | Manually trigger review for a task |
| `/hydra:clean` | Fully remove Hydra from this project |

## Advanced

| Command | Description |
|---------|-------------|
| `/hydra:discover` | Re-run codebase discovery |
| `/hydra:context` | Collect context for an objective type |
| `/hydra:simplify` | Post-loop cleanup pass |
| `/hydra:docs` | View or regenerate project documents |
| `/hydra:board` | Connect to GitHub Projects / Azure DevOps |
| `/hydra:gen-spec` | Interactively build a project specification |

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
9. Commit in AFK mode — every state transition gets a `hydra:` commit
10. HYDRA_COMPLETE means ALL tasks DONE and post-loop finished
