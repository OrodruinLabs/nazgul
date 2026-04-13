<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hydra-logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/hydra-logo-light.png">
    <img alt="Hydra Framework" src="assets/hydra-logo-light.png" width="400">
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

Hydra runs a complete autonomous SDLC pipeline — from scanning your codebase to shipping reviewed code — with 17 core agents plus project-specific reviewers.

## What Hydra Does

- **Auto-detects your project** — classifies it (greenfield, brownfield, bugfix, refactor, migration) and tailors the pipeline
- **Generates docs before code** — PRDs, TRDs, and ADRs so agents build with context
- **Multi-agent review board** — Architect, Security, Code Quality + project-specific reviewers must ALL approve every task
- **Fix-first review** — auto-fixes mechanical issues (dead code, style), only asks about risky changes (security, architecture)
- **Survives interruptions** — checkpoints, recovery pointers, session tracking, and hooks mean you can close your laptop and resume later

```mermaid
flowchart LR
  A["Objective"] --> B["Discovery"]
  B --> C["Docs"]
  C --> D["Plan"]
  D --> E["Implement"]
  E --> F["Review Board"]
  F -->|"approve"| G["Ship"]
  F -->|"reject"| E
```

## Install

```bash
git clone https://github.com/OrodruinLabs/ai-hydra-framework.git
claude --plugin-dir /path/to/ai-hydra-framework
```

To load automatically, add to `~/.zshrc` or `~/.bashrc`:
```bash
alias claude='claude --plugin-dir /path/to/ai-hydra-framework'
```

## Quick Start

> [!TIP]
> **3 commands to get started:**
> ```bash
> /hydra:init            # Set up Hydra for your project
> /hydra:start           # Start the autonomous loop
> /hydra:status          # Check progress anytime
> ```

Hydra auto-detects project state: active work resumes, existing docs trigger planning, fresh projects scan for TODOs/issues/failing tests. Override with `/hydra:start "specific objective"`.

> [!WARNING]
> **Autonomous mode** skips all permission prompts:
> ```bash
> claude --dangerously-skip-permissions
> /hydra:start --yolo --max 30
> ```

## Commands

| Command | Description |
|---------|-------------|
| `/hydra:init` | First-time setup: discovery, reviewer generation, runtime dirs |
| `/hydra:start` | Smart start/resume — auto-detects state, derives objective |
| `/hydra:status` | Check loop progress, task counts, reviewer board |
| `/hydra:pause` | Gracefully pause at next iteration boundary |
| `/hydra:task` | Task lifecycle: skip, unblock, add, prioritize, list |
| `/hydra:review` | Manually trigger review for a task |
| `/hydra:log` | View run history — iterations, commits, reviews |
| `/hydra:board` | Connect task tracking to GitHub Projects |
| `/hydra:docs` | View or regenerate project documents |
| `/hydra:enhance` | Research Claude Code releases, propose Hydra improvements |
| `/hydra:metrics` | View loop performance — velocity, approval rates, self-improvement reports |
| `/hydra:verify` | Human acceptance testing for completed tasks |
| `/hydra:help` | Quick reference for all commands and modes |
| `/hydra:bootstrap-project` | Generate a portable, Hydra-free bundle (docs + Claude subagents) |

See `/hydra:help` for the full command list and all flags.

### `/hydra:bootstrap-project`

Single-shot command that runs Hydra's pre-planning pipeline (discovery, doc-generator, reviewer-instantiation, optional designer) against any repo and emits a portable bundle — `./docs/`, `./docs/context/`, `./.claude/agents/`, and optional `./.claude/design-*` — with all Hydra references scrubbed. The output works anywhere Claude Code runs and does not require Hydra to be installed.

Usage: `/hydra:bootstrap-project [objective] [--yes] [--overwrite] [--dry-run] [--verbose]`. Refuses to run if `./hydra/` already exists (use `/hydra:start` for Hydra-managed loops).

## How It Works

Hydra runs a pipeline of specialized agents. Discovery scans your codebase and classifies the project. The Doc Generator creates foundational documents. The Planner decomposes your objective into dependency-ordered tasks. The Implementer builds each task (delegating to specialists like Frontend Dev, DevOps, or DB Migration as needed). A Review Board of 3-13 reviewers must unanimously approve each task before it advances — mechanical issues are auto-fixed, only risky changes require discussion. The loop continues until every task is done, then Post-Loop agents handle documentation, releases, and observability.

Agents can optionally self-rate their experience and file improvement reports, creating a feedback loop for plugin quality. Concurrent sessions are detected via filesystem locks to prevent state corruption.

See [Architecture](docs/ARCHITECTURE.md) for the full agent roster, pipeline details, and recovery system.

## Requirements

- `jq` — Required for JSON manipulation in hook scripts
- `git` — Required for commit tracking and state persistence
- Claude Code — Agent Teams is enabled automatically by `/hydra:init`

## Learn More

- [Architecture](docs/ARCHITECTURE.md) — Pipeline, agent roster, recovery, directory structure
- [Configuration](docs/CONFIGURATION.md) — Start flags, local mode, board sync
- [Safety & Rules](docs/SAFETY.md) — The 10 rules, guardrails, troubleshooting
- [Plugins](docs/PLUGINS.md) — Companion plugins, compatibility matrix, OpenClaw

## License

MIT
