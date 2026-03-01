---
name: hydra-gen-spec
description: Interactively build a project specification. Guides you through tiered questions — quick product overview first, optional deep-dive into user stories and success metrics. Outputs hydra/context/project-spec.md.
context: fork
allowed-tools: Read, Write, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Generate Project Spec

## Examples
- `/hydra-gen-spec` — Start the interactive spec builder
- `/hydra-gen-spec` (with existing spec) — Review and optionally replace or edit current spec

## Arguments
$ARGUMENTS

## Current State
- Existing spec: !`cat hydra/context/project-spec.md 2>/dev/null | head -5 || echo "NONE"`
- Config: !`cat hydra/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`

## Instructions

### Pre-flight
1. Check if `hydra/config.json` exists. If not, tell the user: "Hydra not initialized. Run `/hydra-init` first." and STOP.
2. Check if `hydra/context/project-spec.md` already exists:
   - If yes: Show the current spec (first 20 lines) and ask: "A project spec already exists. Do you want to **replace** it with a new one, **edit** specific sections, or **keep** it as-is?"
   - If "keep": STOP.
   - If "edit": Ask which sections to update, then update only those sections in-place.
   - If "replace": Continue with Tier 1 below.

### Tier 1: Core Questions (~2 minutes)

Ask these 5 questions conversationally — adapt phrasing to feel natural, not like a form. Wait for the user's responses.

1. **What does this project do?** (1-2 sentences)
   - "In a sentence or two, what are you building?"
2. **Who is it for?** (target users/audience)
   - "Who will use this? Developers, end-users, internal team, etc.?"
3. **What are the 3-5 core features?**
   - "What are the main things it needs to do? List 3-5 features."
4. **What problem does it solve?**
   - "What problem does this solve, or why does it need to exist?"
5. **Any constraints or must-haves?** (optional)
   - "Any hard constraints? Deadlines, compliance, specific integrations, performance targets? (Skip if none.)"

After collecting Tier 1 answers, write the initial `hydra/context/project-spec.md` with Tier 1 content.

### Tier 2 Offer

After Tier 1, ask:

> "Got the basics down. Want to go deeper? I can help define user stories, success metrics, and detailed feature descriptions. Takes about 5 more minutes. (y/n)"

- **If no:** Finalize the spec with Tier 1 content only. Update `hydra/config.json` → set `project_spec` to `"interactive"`. DONE.
- **If yes:** Continue to Tier 2.

### Tier 2: Deep Dive (~5 minutes)

For each core feature listed in Tier 1:
1. **Brief description** — Expand on what this feature does
2. **Key user stories** — "As a [user], I want [X] so that [Y]" format
3. **Acceptance criteria** — What must be true for this feature to be complete

Then ask about:
4. **Success metrics / KPIs** — "How will you measure if this project succeeds?"
5. **Out-of-scope items** — "What is explicitly NOT part of this project?"
6. **Technical constraints** — "Any technical requirements? (specific APIs, protocols, libraries, performance SLAs)"
7. **Integrations** — "Does this need to integrate with any external services?"

Update `hydra/context/project-spec.md` with Tier 2 sections. Update `hydra/config.json` → set `project_spec` to `"interactive"`. DONE.

### Output Format

Write `hydra/context/project-spec.md` using this structure:

```markdown
# Project Specification

## Source
- **Method**: interactive
- **Imported from**: N/A
- **Created at**: [ISO timestamp]

## Vision
[What the project does, 1-3 sentences from Q1]

## Target Users
[Who this is for, from Q2]

## Core Features
1. [Feature name] — [brief description]
2. ...

## Problem Statement
[What problem it solves and why it matters, from Q4]

## Constraints
[Non-functional requirements, compliance, deadlines, integrations from Q5, or "None specified"]

## User Stories
<!-- Tier 2 content — only present if user went deeper -->
### [Feature Name]
- As a [user], I want [X] so that [Y]

## Success Metrics
<!-- Tier 2 content -->
- [Metric]: [target]

## Out of Scope
<!-- Tier 2 content -->
- [Item]
```

### Final Output

After writing the spec, display a summary:

```
Project spec saved to hydra/context/project-spec.md

Vision: [1-line summary]
Features: [count] core features defined
Depth: [Tier 1 only | Tier 1 + Tier 2]

This spec will be used by the Doc Generator to create a product-aware PRD.
Run /hydra-start to begin development.
```
