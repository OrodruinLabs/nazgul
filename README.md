<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/nazgul-logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/nazgul-logo-light.png">
    <img alt="Nazgul Framework" src="assets/nazgul-logo-light.png" width="400">
  </picture>
</p>

<p align="center">
  <strong>Multi-agent autonomous development loop for Claude Code</strong><br>
  Discovery &bull; Planning &bull; Implementation &bull; Review &bull; Repeat
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.2.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/Claude_Code-Plugin-7c3aed?style=flat-square" alt="Claude Code Plugin">
  <img src="https://img.shields.io/badge/agents-17-orange?style=flat-square" alt="Agents">
</p>

<br>

---

Nazgul runs a complete autonomous SDLC pipeline — from scanning your codebase to shipping reviewed code — with 17 core agents plus project-specific reviewers.

## What Nazgul Does

- **Auto-detects your project** — classifies it (greenfield, brownfield, bugfix, refactor, migration) and tailors the pipeline
- **Generates docs before code** — PRDs, TRDs, and ADRs so agents build with context
- **Multi-agent review board** — Architect, Security, Code Quality + project-specific reviewers must ALL approve every task
- **Fix-first review** — auto-fixes mechanical issues (dead code, style), only asks about risky changes (security, architecture)
- **Survives interruptions** — checkpoints, recovery pointers, session tracking, and hooks mean you can close your laptop and resume later

## Install

**From the Orodruin Labs marketplace** (recommended):
```bash
/plugin marketplace add OrodruinLabs/nazgul
/plugin install nazgul
```

**Direct install from GitHub:**
```bash
/plugin install nazgul@github:OrodruinLabs/nazgul
```

**Manual install** (for development or pinning a specific version):
```bash
git clone https://github.com/OrodruinLabs/nazgul.git ~/.claude/plugins/nazgul
```

## Quick Start

> [!TIP]
> **3 commands to get started:**
> ```bash
> /nazgul:init            # Set up Nazgul for your project
> /nazgul:start           # Start the autonomous loop
> /nazgul:status          # Check progress anytime
> ```

Nazgul auto-detects project state: active work resumes, existing docs trigger planning, fresh projects scan for TODOs/issues/failing tests. Override with `/nazgul:start "specific objective"`.

> [!WARNING]
> **Autonomous mode** skips all permission prompts:
> ```bash
> claude --dangerously-skip-permissions
> /nazgul:start --yolo --max 30
> ```

## Commands

| Command | Description |
|---------|-------------|
| `/nazgul:init` | First-time setup: discovery, reviewer generation, runtime dirs |
| `/nazgul:start` | Smart start/resume — auto-detects state, derives objective |
| `/nazgul:status` | Check loop progress, task counts, reviewer board |
| `/nazgul:pause` | Gracefully pause at next iteration boundary |
| `/nazgul:task` | Task lifecycle: skip, unblock, add, prioritize, list |
| `/nazgul:review` | Manually trigger review for a task |
| `/nazgul:log` | View run history — iterations, commits, reviews |
| `/nazgul:board` | Connect task tracking to GitHub Projects |
| `/nazgul:docs` | View or regenerate project documents |
| `/nazgul:enhance` | Research Claude Code releases, propose Nazgul improvements |
| `/nazgul:metrics` | View loop performance — velocity, approval rates, self-improvement reports |
| `/nazgul:verify` | Human acceptance testing for completed tasks |
| `/nazgul:help` | Quick reference for all commands and modes |
| `/nazgul:bootstrap-project` | Generate a portable, Nazgul-free bundle (docs + Claude subagents) |

See `/nazgul:help` for the full command list and all flags.

### `/nazgul:bootstrap-project`

Single-shot command that runs Nazgul's pre-planning pipeline (discovery, doc-generator, reviewer-instantiation, optional designer) against any repo and emits a portable bundle — `./docs/`, `./docs/context/`, `./.claude/agents/`, and optional `./.claude/design-*` — with all Nazgul references scrubbed. The output works anywhere Claude Code runs and does not require Nazgul to be installed.

Usage: `/nazgul:bootstrap-project [objective] [--yes] [--overwrite] [--dry-run] [--wipe-scratch] [--resume-scratch]`. Refuses to run if `./nazgul/` already exists (use `/nazgul:start` for Nazgul-managed loops).

## How It Works

Nazgul runs a pipeline of specialized agents. Discovery scans your codebase and classifies the project. The Doc Generator creates foundational documents. The Planner decomposes your objective into dependency-ordered tasks. The Implementer builds each task (delegating to specialists like Frontend Dev, DevOps, or DB Migration as needed). A Review Board of 3-13 reviewers must unanimously approve each task before it advances — mechanical issues are auto-fixed, only risky changes require discussion. The loop continues until every task is done, then Post-Loop agents handle documentation, releases, and observability.

Agents can optionally self-rate their experience and file improvement reports, creating a feedback loop for plugin quality. Concurrent sessions are detected via filesystem locks to prevent state corruption.

See [Architecture](docs/ARCHITECTURE.md) for the full agent roster, pipeline details, and recovery system.

## Requirements

- `jq` — Required for JSON manipulation in hook scripts
- `git` — Required for commit tracking and state persistence
- Claude Code — Agent Teams is enabled automatically by `/nazgul:init`

## Learn More

- [Architecture](docs/ARCHITECTURE.md) — Pipeline, agent roster, recovery, directory structure
- [Configuration](docs/CONFIGURATION.md) — Start flags, local mode, board sync
- [Safety & Rules](docs/SAFETY.md) — The 10 rules, guardrails, troubleshooting
- [Plugins](docs/PLUGINS.md) — Companion plugins, compatibility matrix, OpenClaw

## License

MIT
