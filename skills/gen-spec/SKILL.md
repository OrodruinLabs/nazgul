---
name: nazgul:gen-spec
description: Interactively build a project specification. Guides you through tiered questions — quick product overview first, optional deep-dive into user stories and success metrics. Outputs nazgul/context/project-spec.md.
context: fork
allowed-tools: Read, Write, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
  version: 1.2.1
---

# Nazgul Generate Project Spec

## Examples
- `/nazgul:gen-spec` — Start the interactive spec builder
- `/nazgul:gen-spec` (with existing spec) — Review and optionally replace or edit current spec

## Arguments
$ARGUMENTS

## Current State
- Existing spec: !`cat nazgul/context/project-spec.md 2>/dev/null | head -5 || echo "NONE"`
- Config: !`cat nazgul/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`

## Instructions

### Pre-flight
0. Load the `AskUserQuestion` tool (deferred by default): run `ToolSearch` with query `select:AskUserQuestion`. Do this BEFORE any step that uses `AskUserQuestion`.
1. Check if `nazgul/config.json` exists. If not, tell the user: "Nazgul not initialized. Run `/nazgul:init` first." and STOP.
2. Check if `nazgul/context/project-spec.md` already exists:
   - If yes: Show the current spec (first 20 lines), then use `AskUserQuestion`:
     - header: "Spec"
     - question: "A project spec already exists. What would you like to do?"
     - options:
       - "Replace" — "Start fresh with a new spec"
       - "Edit" — "Update specific sections of the existing spec"
       - "Keep" — "Keep the current spec as-is"
     - If "Keep": STOP.
     - If "Edit": Ask which sections to update, then update only those sections in-place.
     - If "Replace": Continue with Tier 1 below.

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

After collecting Tier 1 answers, write the initial `nazgul/context/project-spec.md` with Tier 1 content.

### Tier 2 Offer

After Tier 1, ask:

Use `AskUserQuestion`:
- header: "Depth"
- question: "Got the basics down. Want to go deeper with user stories, success metrics, and detailed feature descriptions?"
- options:
  - "Go deeper" — "Define user stories, success metrics, and feature details (~5 more minutes)"
  - "Done" — "Finalize the spec with what we have"

- **If Done:** Finalize the spec with Tier 1 content only. Update `nazgul/config.json` → set `project_spec` to `"interactive"`. DONE.
- **If Go deeper:** Continue to Tier 2.

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

Update `nazgul/context/project-spec.md` with Tier 2 sections. Update `nazgul/config.json` → set `project_spec` to `"interactive"`.

### Tier 3: Gray Area Discovery (Optional)

After Tier 2 (or Tier 1 if user declined Tier 2), offer:

> "Want me to analyze your features for implementation gray areas? I'll identify decisions that would change the outcome and ask about the ones you care about. (~3-5 minutes) (y/n)"

- **If no:** Continue to Output Format.
- **If yes:** Continue below.

#### Gray Area Analysis

For each core feature from Tier 1, identify gray areas based on domain type:

**Visual/UI features:**
- Layout and density (cards vs list, compact vs spacious)
- Interactions (click, hover, swipe, drag)
- Empty states and loading states
- Error presentation
- Responsive behavior

**APIs/CLIs:**
- Response format and structure
- Error handling and error codes
- Authentication and authorization model
- Rate limiting and pagination
- Versioning strategy

**Data systems:**
- Schema structure and relationships
- Validation rules and constraints
- Migration strategy (if existing data)
- Caching approach

**Infrastructure:**
- Environment setup (dev, staging, prod)
- Scaling approach
- Secret management
- Monitoring and alerting

#### Process

1. Analyze each feature and generate 3-5 specific gray areas (not generic categories)
2. Present them grouped by feature:

```
I found gray areas in your features. Select which ones you want to discuss:

Feature: User Authentication
  1. Session handling — single device or multi-device?
  2. Error responses — generic "invalid credentials" or specific field errors?
  3. Recovery flow — email reset, magic link, or both?

Feature: Dashboard
  4. Layout — cards with previews or dense table view?
  5. Real-time updates — polling, WebSocket, or manual refresh?

Select numbers to discuss (e.g., "1, 3, 4") or "all" or "skip":
```

3. For each selected gray area, ask one focused question and capture the decision
4. For unselected gray areas, document as "Claude's Discretion" — the planner can decide

#### In Auto/AFK Mode

Skip the interactive selection. Instead:
1. Analyze all features for gray areas
2. Make judgment calls for each, documenting reasoning
3. Write all decisions under `## Claude's Discretion` with rationale

#### Writing Decisions

Append to `nazgul/context/project-spec.md`:

```markdown
## Phase Decisions

### [Feature Name]
| Decision | Choice | Source |
|----------|--------|--------|
| Session handling | Multi-device with conflict resolution | User decision |
| Error responses | Specific field-level errors | User decision |
| Recovery flow | Email reset only for v1 | User decision |
| Layout density | Cards with previews | Claude's Discretion — more engaging for dashboard |

### Deferred Ideas
- [Feature suggested during discussion but out of scope — captured for future phases]
```

Update `nazgul/config.json` → set `project_spec` to `"interactive"`. DONE.

### Output Format

Write `nazgul/context/project-spec.md` using this structure:

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

## Phase Decisions
<!-- Tier 3 content — only present if user went deeper -->
### [Feature Name]
| Decision | Choice | Source |
|----------|--------|--------|
| [decision] | [choice] | [User decision / Claude's Discretion — reason] |

### Deferred Ideas
- [Item captured during discussion but out of scope]
```

### Final Output

After writing the spec, display a summary:

```
Project spec saved to nazgul/context/project-spec.md

Vision: [1-line summary]
Features: [count] core features defined
Depth: [Tier 1 only | Tier 1 + Tier 2 | Tier 1 + Tier 2 + Tier 3]
Phase decisions: [N] locked, [M] at Claude's discretion

This spec will be used by the Doc Generator to create a product-aware PRD.
Run /nazgul:start to begin development.
```
