---
name: hydra-discover
description: Scan the codebase to build a project profile and generate tailored reviewer agents. Use when setting up Hydra for a new project, after major codebase changes, or when reviewer agents need updating.
context: fork
agent: discovery
allowed-tools: Bash, Read, Write, Glob, Grep, LS
metadata:
  author: Hydra Framework
  version: 1.0.0
---

# Hydra Discovery

## Examples
- `/hydra-discover` — Scan codebase and generate project profile + reviewer agents
- `/hydra-discover` (re-run) — Backs up existing context before rescanning

## Current Project
- Root: !`pwd`
- File count: !`find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './venv/*' -not -path './__pycache__/*' | wc -l`
- Languages: !`find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './venv/*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -10`
- Package files: !`ls -1 package.json requirements.txt Cargo.toml go.mod pyproject.toml Gemfile pom.xml build.gradle 2>/dev/null || echo "None found"`
- Config files: !`ls -1 .eslintrc* .prettierrc* tsconfig.json .editorconfig Makefile Dockerfile docker-compose* .github/workflows/*.yml 2>/dev/null || echo "None found"`
- Git status: !`git log --oneline -5 2>/dev/null || echo "Not a git repo"`

## Instructions

$ARGUMENTS

Run the full discovery process as specified in your agent definition (`agents/discovery.md`).

1. Scan the codebase deeply — read actual files, not just file names
2. Write all 5 context files to `hydra/context/`
3. Generate tailored reviewer agents in `.claude/agents/generated/`
4. Write discovery summary to `hydra/context/discovery-summary.md`
5. Update `hydra/config.json` with project metadata

If this is a re-run, back up existing context files first:
```bash
if [ -d hydra/context ]; then
  cp -r hydra/context "hydra/context.backup.$(date +%Y%m%d%H%M%S)"
fi
```

After completion, report:
- Number of files scanned
- Key findings
- Which reviewer agents were generated
- Any warnings or gaps
