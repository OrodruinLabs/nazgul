---
name: "hydra:bootstrap-project"
description: "Generate a portable, Hydra-free project bundle (docs + Claude subagents) without installing Hydra. Runs the full pre-planning pipeline (discovery, doc-generator, reviewer-instantiation, optional designer) and emits output into standard paths (./docs/, ./docs/context/, ./.claude/agents/, ./.claude/)."
context: fork
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep, Agent"
---

# Bootstrap Project

<!-- Author: Jose Mejia · Version: 0.1.0 -->


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

Parse `$ARGUMENTS` structurally: split on whitespace, pull out known flags, and leave the rest as the free-form objective. This prevents false positives where an objective string contains a flag-like substring (e.g. "document the `--dry-run` workflow").

```bash
BOOTSTRAP_YES=false
BOOTSTRAP_OVERWRITE=false
BOOTSTRAP_DRY_RUN=false
BOOTSTRAP_VERBOSE=false
BOOTSTRAP_WIPE_SCRATCH=false
BOOTSTRAP_OBJECTIVE=""

# Disable pathname expansion during tokenization so an objective containing
# glob metachars (*, ?, [) doesn't expand to matching filenames. Re-enable
# afterwards so downstream code behaves normally.
set -f
# Intentionally NOT quoted: we want word-splitting so each token is processed.
# shellcheck disable=SC2086
set -- $ARGUMENTS
for tok in "$@"; do
  case "$tok" in
    --yes)           BOOTSTRAP_YES=true ;;
    --overwrite)     BOOTSTRAP_OVERWRITE=true ;;
    --dry-run)       BOOTSTRAP_DRY_RUN=true ;;
    --verbose)       BOOTSTRAP_VERBOSE=true ;;
    --wipe-scratch)  BOOTSTRAP_WIPE_SCRATCH=true ;;
    --*)             echo "warning: unknown flag: $tok" >&2 ;;
    *)               BOOTSTRAP_OBJECTIVE="${BOOTSTRAP_OBJECTIVE:+$BOOTSTRAP_OBJECTIVE }$tok" ;;
  esac
done
set +f
```

Run checks in order. If any returns non-zero, respect the contract (hard abort or prompt):

```bash
check_no_hydra_dir || exit $?

check_scratch_state; scratch_rc=$?
case $scratch_rc in
  0) ;;
  12)
    if [ "$BOOTSTRAP_WIPE_SCRATCH" = "true" ]; then
      rm -rf ./.bootstrap-scratch
    elif [ "$BOOTSTRAP_YES" = "true" ]; then
      echo "error: scratch exists, --yes in effect, cannot prompt; pass --wipe-scratch to force" >&2
      exit 12
    else
      # LLM prompt: ask the user to choose resume / wipe-and-restart / abort.
      # - "resume"          — keep ./.bootstrap-scratch and continue to Phase 2
      # - "wipe-and-restart"— rm -rf ./.bootstrap-scratch, then continue
      # - "abort"           — exit 12
      # The LLM implements the branch; do NOT auto-delete scratch here, or the
      # "resume" path becomes unreachable.
      echo "./.bootstrap-scratch/ exists from a prior run. Choose: resume / wipe-and-restart / abort"
      exit 12
    fi
    ;;
  *) exit "$scratch_rc" ;;
esac

check_docs_agents_empty; docs_rc=$?
case $docs_rc in
  0) ;;
  11)
    if [ "$BOOTSTRAP_OVERWRITE" = "true" ]; then
      # Actually clear the managed targets so relocation produces a clean
      # bundle instead of silently merging with stale files. Only remove
      # paths this skill owns — never the whole ./.claude/ tree (which may
      # hold unrelated user config).
      rm -rf ./docs ./.claude/agents
    elif [ "$BOOTSTRAP_YES" = "true" ]; then
      exit 11
    else
      # Interactive prompt: overwrite / abort. Default abort on empty reply.
      echo "Non-empty ./docs/ or ./.claude/agents/ detected. Abort? [Y/n]"
      # LLM: ask the user, proceed only on explicit "overwrite"
      exit 11
    fi
    ;;
  *) exit "$docs_rc" ;;
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

1. **If `$BOOTSTRAP_OBJECTIVE` (parsed in Phase 1) is non-empty**, use it as the objective. Write a minimal project-spec:

   ```bash
   if [ -n "$BOOTSTRAP_OBJECTIVE" ]; then
     cat > ./.bootstrap-scratch/context/project-spec.md <<SPEC
   # Project Specification

   ## Source
   - Method: argument
   - Created at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

   ## Vision
   $BOOTSTRAP_OBJECTIVE
   SPEC
   fi
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

Export STATE_ROOT and BUNDLE_MODE for all downstream renders:

```bash
export STATE_ROOT="./.bootstrap-scratch"
export BUNDLE_MODE="true"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/bootstrap-render.sh"
```

Render and invoke each pipeline agent. For each agent, the renderer produces a Hydra-free prompt pointed at the scratch tree; the LLM then executes the agent's instructions.

#### 3a. Discovery

Render the discovery prompt and invoke it:

```bash
render_agent_prompt "$CLAUDE_PLUGIN_ROOT/agents/discovery.md" "$STATE_ROOT" > "$STATE_ROOT/.discovery-prompt.md"
```

Then invoke the discovery agent via the `Agent` tool, passing the rendered prompt as the system/initial message. The agent writes to `$STATE_ROOT/context/{project-profile,project-classification,architecture-map,existing-docs}.md`.

After the agent returns, verify expected outputs exist:

```bash
for f in project-profile.md project-classification.md architecture-map.md; do
  test -f "$STATE_ROOT/context/$f" || {
    echo "error: discovery did not produce $f; preserving scratch for debugging" >&2
    exit 40
  }
done
```

#### 3b. Doc generation

```bash
render_agent_prompt "$CLAUDE_PLUGIN_ROOT/agents/doc-generator.md" "$STATE_ROOT" > "$STATE_ROOT/.docgen-prompt.md"
```

Invoke the doc-generator agent. It reads `$STATE_ROOT/context/` and writes to `$STATE_ROOT/docs/{PRD,TRD,ADR-*,test-plan,manifest}.md` (and `migration-plan.md` if classification=migration).

Verify:

```bash
for f in PRD.md TRD.md test-plan.md; do
  test -f "$STATE_ROOT/docs/$f" || {
    echo "error: doc-generator did not produce $f; preserving scratch" >&2
    exit 41
  }
done
```

#### 3c. Reviewer instantiation

The reviewer template at `agents/templates/reviewer-base.md` is rendered once per reviewer domain determined from `project-profile.md`. Available domain definitions live in `agents/templates/reviewer-domains.json` (existing structure: keys like `qa-reviewer`, `api-reviewer`, with per-domain `checklist` and `review_steps` arrays, plus `description`, `title`, `context_items`, `category`, `approved_criteria`, `rejected_criteria`). The JSON does NOT have a `keywords` field today, so domain selection goes via a two-step rule:

1. **Always include:** `qa-reviewer` and `code-reviewer` (baseline; assumed present in the JSON — if a key is missing, skip it with a warning and continue).
2. **Conditionally include** based on keyword scan of `project-profile.md`:
   - `api-reviewer` — if profile mentions `api`, `rest`, `graphql`, `endpoint`
   - `frontend-reviewer` — if profile mentions `react`, `vue`, `svelte`, `angular`, `next.js`, `nuxt`, `nextjs`
   - `security-reviewer` — always include when the profile mentions `auth`, `login`, `password`, `token`, `jwt`, `oauth`
   - `performance-reviewer` — if profile mentions `database`, `caching`, `redis`, `perf`

This mapping is hard-coded in `select_reviewer_domains` (see Step 2 below). Domains not defined in `reviewer-domains.json` are skipped.

For each selected domain, render the template with `BUNDLE_MODE=true`:

```bash
DOMAINS=$(select_reviewer_domains "$STATE_ROOT/context/project-profile.md" "$CLAUDE_PLUGIN_ROOT/agents/templates/reviewer-domains.json")

for domain in $DOMAINS; do
  out="$STATE_ROOT/agents/${domain}.md"
  BUNDLE_MODE=true render_template "$CLAUDE_PLUGIN_ROOT/agents/templates/reviewer-base.md" \
    | substitute_domain_vars "$domain" "$CLAUDE_PLUGIN_ROOT/agents/templates/reviewer-domains.json" \
    > "$out"
  test -s "$out" || { echo "error: reviewer $domain rendered empty" >&2; exit 42; }
done
```

#### 3d. Designer (conditional)

```bash
if grep -qiE 'react|vue|svelte|angular|swiftui|flutter' "$STATE_ROOT/context/project-profile.md"; then
  render_agent_prompt "$CLAUDE_PLUGIN_ROOT/agents/designer.md" "$STATE_ROOT" > "$STATE_ROOT/.designer-prompt.md"
  # Invoke designer agent. Writes to $STATE_ROOT/.claude/{design-tokens.json,design-system.md}.
fi
```

### Phase 4 — Transform, relocate, cleanup

Source the relocate helpers:

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/bootstrap-relocate.sh"
```

Run the transform:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/bootstrap-transform.sh" "$STATE_ROOT"
transform_rc=$?
case $transform_rc in
  0) ;;
  2) echo "error: transform usage error" >&2; exit 50 ;;
  3)
    echo "error: transform final assertion failed — see output above." >&2
    echo "       scratch preserved at $STATE_ROOT for debugging." >&2
    exit 51
    ;;
  *) echo "error: transform failed (exit $transform_rc)" >&2; exit 52 ;;
esac
```

If `--dry-run` was set (parsed in Phase 1), stop here. Report the scratch location to the user:

```bash
if [ "$BOOTSTRAP_DRY_RUN" = "true" ]; then
  echo "Dry-run complete. Review the bundle at $STATE_ROOT/ before re-running without --dry-run."
  exit 0
fi
```

Relocate atomically:

```bash
relocate_bundle "$STATE_ROOT" "." || exit $?
```

Append to `.gitignore` and clean up:

```bash
append_gitignore "."
cleanup_scratch "$STATE_ROOT"
```

### Phase 5 — Summary

```bash
count_md()   { find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
count_dir()  { find "$1" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

DOCS=$(count_md ./docs)
CTX=$(count_md ./docs/context)
AGENTS=$(count_md ./.claude/agents)
DESIGN=$(count_dir ./.claude)

cat <<SUMMARY
Bootstrap complete.

Generated:
  ./docs/            $DOCS documents (PRD, TRD, ADRs, test plan)
  ./docs/context/    $CTX context files
  ./.claude/agents/  $AGENTS reviewer agents
  ./.claude/         $DESIGN design-system files (if UI surface detected)

Next steps:
  - Review ./docs/PRD.md and ./docs/TRD.md
  - Commit the bundle:      git add docs/ .claude/ && git commit
  - Use the reviewers:      invoke them from Claude Code in this repo
SUMMARY
```
