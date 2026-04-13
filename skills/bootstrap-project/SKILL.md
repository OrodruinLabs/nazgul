---
name: hydra:bootstrap-project
description: Generate a portable, Hydra-free project bundle (docs + Claude subagents) without installing Hydra. Runs the full pre-planning pipeline (discovery, doc-generator, reviewer-instantiation, optional designer) and emits output into standard paths (./docs/, ./docs/context/, ./.claude/agents/, ./.claude/).
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent
metadata:
  author: Jose Mejia
  version: 0.1.0
---

# Bootstrap Project

## Examples
- `/hydra:bootstrap-project` — Interactive: ask for objective, then run full pipeline
- `/hydra:bootstrap-project "Add Stripe billing to existing app"` — Use given objective
- `/hydra:bootstrap-project --dry-run` — Run pipeline and transform into scratch without relocating
- `/hydra:bootstrap-project --yes --overwrite` — Non-interactive, overwrite existing ./docs or ./.claude/agents

## Arguments
$ARGUMENTS

## Flags
- `--yes` — Non-interactive; abort on ambiguous prompts.
- `--overwrite` — Force overwrite of non-empty `./docs/` or `./.claude/agents/`.
- `--dry-run` — Run pipeline and transform into scratch; skip relocation and cleanup.
- `--verbose` — Stream agent output live.
- `--wipe-scratch` — Delete any existing `./.bootstrap-scratch/` before starting.

## Instructions

### Phase 1 — Pre-flight gate

Source the preflight helpers:

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/bootstrap-preflight.sh"
```

Run checks in order. If any returns non-zero, respect the contract (hard abort or prompt):

```bash
check_no_hydra_dir || exit $?
check_scratch_state
case $? in
  0) ;;
  12)
    if echo "$ARGUMENTS" | grep -q -- '--wipe-scratch'; then
      rm -rf ./.bootstrap-scratch
    elif echo "$ARGUMENTS" | grep -q -- '--yes'; then
      echo "error: scratch exists, --yes in effect, cannot prompt; pass --wipe-scratch to force" >&2
      exit 12
    else
      # Ask the user (LLM prompt): resume / wipe-and-restart / abort
      # Conventional response handling: default to wipe-and-restart.
      rm -rf ./.bootstrap-scratch
    fi
    ;;
  *) exit $? ;;
esac

check_docs_agents_empty
case $? in
  0) ;;
  11)
    if echo "$ARGUMENTS" | grep -q -- '--overwrite'; then
      true  # proceed
    elif echo "$ARGUMENTS" | grep -q -- '--yes'; then
      exit 11
    else
      # Interactive prompt: overwrite / abort. Default abort on empty reply.
      echo "Non-empty ./docs/ or ./.claude/agents/ detected. Abort? [Y/n]"
      # LLM: ask the user, proceed only on explicit "overwrite"
      exit 11
    fi
    ;;
esac

check_git_clean
if [ -n "${BOOTSTRAP_GIT_WARNING:-}" ]; then
  echo "$BOOTSTRAP_GIT_WARNING" >&2
fi
```

### Phase 2 — Objective collection

Create the scratch tree:

```bash
mkdir -p ./.bootstrap-scratch/context ./.bootstrap-scratch/docs ./.bootstrap-scratch/agents ./.bootstrap-scratch/.claude
```

Determine the objective source:

1. **If `$ARGUMENTS` contains a non-flag, non-empty string**, use it as the objective. Write a minimal project-spec:

   ```bash
   cat > ./.bootstrap-scratch/context/project-spec.md <<SPEC
   # Project Specification

   ## Source
   - Method: argument
   - Created at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

   ## Vision
   $OBJECTIVE
   SPEC
   ```

2. **Otherwise**, run the condensed Tier 1 interactive flow. Ask these 5 questions one at a time, phrased naturally, and wait for each answer:

   1. *"In a sentence or two, what are you building?"*
   2. *"Who will use this?"*
   3. *"What are the 3-5 core features?"*
   4. *"What problem does this solve?"*
   5. *"Any hard constraints? (Skip if none.)"*

   After collecting answers, write `./.bootstrap-scratch/context/project-spec.md` with the standard sections (`## Vision`, `## Target Users`, `## Core Features`, `## Problem Statement`, `## Constraints`).

3. **After Tier 1, offer Tier 2**: *"Got the basics. Want to go deeper on user stories and success metrics? (~5 more minutes) (y/n)"*
   - If yes, ask per-feature user stories and success metrics, append to the spec.
   - If no, finalize with Tier 1 content only.

Verify the file exists before proceeding:

```bash
test -f ./.bootstrap-scratch/context/project-spec.md || { echo "error: project-spec.md not written" >&2; exit 30; }
```

### Phase 3 — Pipeline execution

*(Implemented in Task 13.)*

### Phase 4 — Transform, relocate, cleanup

*(Implemented in Task 14.)*

### Phase 5 — Summary

*(Implemented in Task 14.)*
