# Design — `/hydra:bootstrap-project`: Portable, Hydra-Free Project Bundle Generator

**Date:** 2026-04-13
**Status:** Implemented (PR #9) — plan at `docs/superpowers/plans/2026-04-13-bootstrap-project.md`
**Author:** Jose Mejia (brainstormed with Claude)

## Summary

Add a new skill `/hydra:bootstrap-project` that runs Hydra's existing pre-planning pipeline (discovery → classification → documentation → reviewer instantiation → designer) against a target project and emits a portable, Hydra-free bundle into generic paths (`./docs/`, `./docs/context/`, `./.claude/agents/`, `./.claude/`). The resulting bundle contains no Hydra references and does not require Hydra to be installed in the target project.

The skill is strictly single-shot: no state machine, no checkpoints, no loop machinery. It refuses to run if `./hydra/` already exists to prevent conflict with active Hydra projects.

## Goals

- Reuse Hydra's mature pipeline (discovery, doc-generator, reviewer-template, designer) unchanged in behavior.
- Produce a self-contained bundle (docs, context files, Claude subagents, optional design system) in standard Claude Code / project-local paths.
- Zero Hydra references in bundle output — enforced by a blocking post-transform assertion.
- No duplication of agent or template source files. Single source of truth remains Hydra's `agents/` and `templates/`.
- Fail closed: either the bundle lands complete, or the target project is untouched.

## Non-goals

- Not a replacement for `/hydra:init` or `/hydra:start`. This skill emits a one-shot bundle and exits.
- Not a generator for loop machinery (planner, implementer, review-gate, hooks, scripts) — those are Hydra-specific by design.
- Not a migration tool for existing Hydra projects.
- No quality assertions on the prose of generated docs — that is a model-output property, covered only via smoke-level E2E checks.

## User story

> As a developer who wants Hydra-style project documentation and Claude subagents in a repo, but without installing Hydra or carrying its loop machinery, I run `/hydra:bootstrap-project` from a Hydra-equipped workspace against my target project and get a clean bundle (`./docs/`, `./.claude/agents/`) that works anywhere Claude Code runs.

## Architecture

```text
/hydra:bootstrap-project (skill)
 ├─ 1. Pre-flight gate
 │    - abort if ./hydra/ exists
 │    - if ./docs/ or ./.claude/agents/ non-empty: prompt (overwrite/abort) or abort non-interactively
 │    - offer to resume/wipe if ./.bootstrap-scratch/ exists from prior crash
 │    - warn (non-blocking) if git working tree is dirty
 ├─ 2. Objective collection
 │    - if $ARGUMENTS non-empty → use as objective
 │    - else → condensed gen-spec Tier 1 flow (5 questions); optional Tier 2
 │    - write to ./.bootstrap-scratch/context/project-spec.md
 ├─ 3. Pipeline execution (STATE_ROOT=./.bootstrap-scratch)
 │    ├─ discovery agent       → profile, classification, architecture-map, existing-docs
 │    ├─ doc-generator agent   → PRD, TRD, ADR-*, test-plan, (migration-plan)
 │    ├─ reviewer-instantiation (bundle mode) → project-specific reviewer .md files
 │    └─ designer agent (conditional) → design-tokens.json, design-system.md
 ├─ 4. Transform pass (scripts/bootstrap-transform.sh)
 │    - path rewrites (primary)
 │    - frontmatter stripping (primary)
 │    - prose scrub (safety net)
 │    - blocking assertion: no /[Hh]ydra|HYDRA/ tokens remain
 ├─ 5. Relocate files (staged; atomic all-or-nothing)
 ├─ 6. Cleanup ./.bootstrap-scratch/ (best-effort)
 └─ 7. Print summary + next-steps message
```

### Key architectural properties

- **Single-shot, synchronous.** No state machine, no checkpoints. Runs top-to-bottom and exits.
- **Reuses Hydra's pipeline agents.** Discovery, doc-generator, designer, reviewer-template are invoked unchanged except for a `STATE_ROOT` environment variable controlling output paths.
- **One transform layer.** All un-Hydra-ing logic lives in `scripts/bootstrap-transform.sh` with a fixture-based regression test.
- **Scratch dir is invisible.** `./.bootstrap-scratch/` is created, used, and deleted within a single run.
- **Atomicity.** Either the full bundle lands, or `./docs/` and `./.claude/` are untouched. Enforced by staged relocation.

## Components

### New components

| Component | Location | Responsibility |
|---|---|---|
| `hydra:bootstrap-project` skill | `skills/bootstrap-project/SKILL.md` | Entry point. Orchestrates pre-flight → objective → pipeline → transform → relocate → cleanup. Lives under the Hydra plugin namespace because it's invoked via the Hydra plugin; the *output* bundle is Hydra-free. |
| Transform script | `scripts/bootstrap-transform.sh` | Pure shell. Reads scratch tree, applies scrub-map, writes to final tree. Idempotent, deterministic, testable. |
| Scrub map | `scripts/lib/bootstrap-scrub-map.sh` | Centralized string and path replacement rules. Sourced by transform script. Single file to audit when Hydra adds new terms. |
| Fixture test | `tests/test-bootstrap-transform.sh` | Feeds canned scratch inputs into transform, asserts exact output against `tests/fixtures/bootstrap-transform/expected/`. Locks scrub behavior against regression. |
| Integration test | `tests/test-bootstrap-project.sh` | Exercises skill orchestration (pre-flight, atomicity, `--dry-run`, `.gitignore` append) with stubbed agent outputs. |
| E2E tests | `tests/e2e/test-bootstrap-project.sh` | Manual-trigger only. Runs against `tests/e2e/fixtures/minimal-greenfield/` and `tests/e2e/fixtures/nextjs-brownfield/`. |

### Existing components requiring minimal change

| Component | Change |
|---|---|
| `agents/discovery.md` | Read `STATE_ROOT` env var (default `hydra/`) for output location. |
| `agents/doc-generator.md` | Read `STATE_ROOT` for inputs (`$STATE_ROOT/context/`) and outputs (`$STATE_ROOT/docs/`). |
| `agents/designer.md` | Read `STATE_ROOT` for outputs. |
| `agents/templates/` reviewer template | Accept a `BUNDLE_MODE` flag. When true, emit Hydra-free identity/purpose prose (no mention of review board, review-gate, or loop). |

### Components explicitly untouched

- `planner.md`, `implementer.md`, `review-gate.md`, `team-orchestrator.md`, `feedback-aggregator.md`, `debugger.md` — loop-phase agents; not part of the bundle.
- Loop scripts: `stop-hook.sh`, `pre-compact.sh`, `session-context.sh`, etc.
- `templates/docs/*` source templates — remain generic. Any Hydra-specific content introduced downstream is caught by the post-transform assertion.

## Data flow (step-by-step)

### Step 0 — Invocation

```text
user: /hydra:bootstrap-project
      /hydra:bootstrap-project "Add Stripe billing to existing app"
```

Flags:
- `--yes` — non-interactive; accept defaults, abort on ambiguous prompts.
- `--overwrite` — force overwrite of non-empty `./docs/` or `./.claude/agents/`.
- `--dry-run` — run pipeline and transform into scratch; skip relocation and cleanup.
- `--verbose` — stream agent output live instead of capturing to log.

### Step 1 — Pre-flight gate

- `./hydra/` exists → hard abort. Message: *"This project is already Hydra-initialized. `bootstrap-project` is for generating a portable, Hydra-free bundle. Use `/hydra:start` instead, or remove `./hydra/` first."*
- `./docs/` or `./.claude/agents/` non-empty → interactive prompt: `overwrite / abort`. Non-interactive default: abort. `--overwrite` forces. (A "merge" mode is deliberately excluded from v1 — mixing a newly-generated bundle with stale existing files risks inconsistency, e.g., a new TRD next to an old PRD; revisit if users request it.)
- `./.bootstrap-scratch/` exists (prior crash) → prompt: `resume / wipe-and-restart / abort`. Default: wipe-and-restart.
- Git working tree dirty → print warning, continue.

### Step 2 — Objective collection

- If `$ARGUMENTS` is non-empty, treat as objective string.
- Else, run condensed Tier 1 gen-spec flow (5 questions: what, who, features, problem, constraints).
- Offer Tier 2 (user stories, success metrics, out-of-scope, integrations).
- Write spec to `./.bootstrap-scratch/context/project-spec.md`.

### Step 3 — Pipeline execution

Export `STATE_ROOT=./.bootstrap-scratch`, then invoke in sequence:

1. **Discovery** → `$STATE_ROOT/context/{project-profile,project-classification,architecture-map,existing-docs}.md`
2. **Doc generator** → `$STATE_ROOT/docs/{PRD,TRD,ADR-*,test-plan,manifest}.md` and `$STATE_ROOT/docs/migration-plan.md` if classification = migration
3. **Reviewer instantiation** (with `BUNDLE_MODE=true`) → `$STATE_ROOT/agents/*.md` tailored to the stack detected in `project-profile.md`
4. **Designer** (conditional on UI surface) → `$STATE_ROOT/.claude/design-tokens.json`, `$STATE_ROOT/.claude/design-system.md`

If any step fails (non-zero exit, missing expected outputs), the skill stops immediately, preserves scratch, and reports the step name and scratch location.

### Step 4 — Transform pass

`scripts/bootstrap-transform.sh` walks every `.md` and `.json` file in scratch and applies:

1. **Path rewrites** (Class 1, primary)
2. **Frontmatter stripping** (Class 4, primary)
3. **Prose term rewrites and sentence removal** (Classes 2 & 3, safety net only — bundle-mode reviewer template should leave little to scrub)
4. **Blocking assertion**: `grep -riE '[Hh]ydra|HYDRA' <scratch>` must return zero matches (excluding the scrub-map allowlist, empty in v1). Failure prints matching file + line + suggested scrub-map diff.

### Step 5 — Relocate (atomic)

Dry-run all planned writes first. If any would fail (permissions, read-only mount), abort before any real write.

```text
$STATE_ROOT/docs/PRD.md                → ./docs/PRD.md
$STATE_ROOT/docs/TRD.md                → ./docs/TRD.md
$STATE_ROOT/docs/ADR-*.md              → ./docs/ADR-*.md
$STATE_ROOT/docs/test-plan.md          → ./docs/test-plan.md
$STATE_ROOT/docs/migration-plan.md     → ./docs/migration-plan.md   (if present)
$STATE_ROOT/context/*.md               → ./docs/context/*.md
$STATE_ROOT/agents/*.md                → ./.claude/agents/*.md
$STATE_ROOT/.claude/design-tokens.json → ./.claude/design-tokens.json
$STATE_ROOT/.claude/design-system.md   → ./.claude/design-system.md
```

`manifest.md` is dropped — Hydra-internal index, not part of the portable bundle.

### Step 6 — Cleanup

- `rm -rf ./.bootstrap-scratch/` (failure is non-fatal, logged as warning).
- Append `.bootstrap-scratch/` to `.gitignore` if not already present.

### Step 7 — Summary

Print bundle contents (file counts per directory) and next-steps guidance (review PRD/TRD, commit, use reviewers with Claude Code).

## Transform rules (scrub map)

Applied in order:

### Class 1 — Path rewrites (primary; exact, longest-first match)

| Find | Replace |
|---|---|
| `hydra/docs/manifest.md` | *(drop sentence/line)* |
| `hydra/docs/` | `docs/` |
| `hydra/context/` | `docs/context/` |
| `hydra/config.json` | *(drop sentence)* |
| `hydra/plan.md` | *(drop sentence)* |
| `hydra/tasks/` | *(drop sentence)* |
| `hydra/checkpoints/` | *(drop sentence)* |

### Class 2 — Prose term rewrites (safety net; whole-word)

Triggered only if bundle-mode reviewer template leaks terms. Each triggers sentence-level removal:
- `Hydra pipeline`
- `Hydra loop`
- `the Hydra framework`
- `Hydra` (standalone)
- `HYDRA_*` env vars

### Class 3 — Sentence / line removal

For each line matching a removal-list token, remove the containing sentence (ends at `.`, `?`, `!`, or blank line). If the paragraph collapses to empty, drop it. For list items (`-`, `1.`), drop the whole item; if the list empties, the heading above is left as "None." or removed based on scrub-map config.

### Class 4 — Frontmatter stripping (primary; agent files only)

Parse YAML frontmatter and:
- **Keep:** `name`, `description`, `tools`, `allowed-tools`, `maxTurns`, `model`
- **Remove:** `hydra:*` keys, `review-board:*`, `loop-phase:*`, any key starting with `hydra_`
- **Rewrite `description`:** strip leading `Pipeline:` / `Post-loop:` / `Specialist:` prefixes

### Final assertion (backstop)

After all classes run, `grep -riE '[Hh]ydra|HYDRA'` on scratch must return zero matches. Failure is blocking and prints:
- Offending file + line
- Suggested diff for `scripts/lib/bootstrap-scrub-map.sh`

### Fixture test

`tests/fixtures/bootstrap-transform/` holds:
- `input/` — canned scratch tree with realistic agent + doc outputs, including one intentionally-dirty `legacy-reviewer.md` to exercise the safety net
- `expected/` — exact post-transform reference tree

Test diffs `actual/` vs `expected/`. Scrub-map changes require fixture updates, forcing visible PR review.

### v1 exclusions

- **Allowlist mechanism** — deferred. If a target project is legitimately named `hydra-*`, user handles manually. Revisit if it happens in practice.

## Error handling

### Five failure surfaces

1. **Pre-flight failures** — hard abort or interactive prompt; nothing written.
2. **Agent failures** (mid-pipeline) — stop, preserve scratch for debugging, print step name + scratch path. No files land in `./docs/` or `./.claude/`.
3. **Transform failures** — scrub processing error or final assertion trips. Stop, preserve scratch, name offending file(s), suggest scrub-map diff.
4. **Relocation failures** — dry-run write check fails, or mid-relocation failure. Stop, preserve scratch, name failed path. No partial bundle.
5. **Cleanup failures** — best-effort; logged as warnings. Bundle is already in place.

### Atomicity guarantee

The skill makes exactly one promise: either `./docs/` and `./.claude/` receive a complete bundle, or they are untouched. Enforced by staged-then-committed relocation.

### Debugging aids

- `./.bootstrap-scratch/bootstrap.log` — timestamps, step boundaries, agent exit codes.
- `--verbose` — live agent output.
- `--dry-run` — run pipeline + transform into scratch; skip relocation and cleanup; user can inspect bundle before committing.

## Testing strategy

### Layer 1 — Unit: scrub map & frontmatter stripping

`tests/test-bootstrap-transform.sh` against `tests/fixtures/bootstrap-transform/{input,expected}/`.

Covers:
- Class 1 path rewrites
- Class 4 frontmatter stripping
- Classes 2 & 3 safety-net prose scrubbing
- Final assertion firing on dirty input
- `manifest.md` dropped

### Layer 2 — Integration: orchestration

`tests/test-bootstrap-project.sh` with stubbed agent outputs.

Covers:
- Pre-flight gate (abort when `./hydra/` exists)
- Pre-flight prompt (non-empty `./docs/` — both `--yes --overwrite` and default-abort paths)
- Dirty-git warning (non-blocking)
- Scratch preservation on simulated agent failure
- Atomicity on simulated mid-relocation failure
- `--dry-run` skips relocation and cleanup
- `.gitignore` append of `.bootstrap-scratch/`

### Layer 3 — E2E: real pipeline

`tests/e2e/test-bootstrap-project.sh`, manual-trigger only, costs money.

Fixtures in `tests/e2e/fixtures/`:
- `minimal-greenfield/` — empty repo, produces greenfield bundle
- `nextjs-brownfield/` — realistic Next.js app, produces tailored bundle with stack-specific reviewers

Asserts: expected output files exist, no `/[Hh]ydra|HYDRA/` remains, reviewer frontmatter is valid YAML.

### CI integration

- Layers 1 + 2 → `.github/workflows/test.yml` (every push/PR).
- Layer 3 → `.github/workflows/e2e-tests.yml` (manual dispatch).
- Skill-docs freshness check (`.github/workflows/skill-docs.yml`) picks up the new skill automatically.

### Explicitly not tested

- Prose quality of generated docs (model-output property, covered only by E2E smoke checks).
- Long-term correctness of reviewer template's bundle-mode — manual spot-check on template changes.

## Open questions (none blocking implementation)

- Whether to add a `/hydra:bootstrap-project --update` mode later that refreshes docs/agents in-place after source changes. Not v1.
- Whether to surface a machine-readable summary (JSON) in addition to the human message. Not v1.

## Acceptance criteria

1. `/hydra:bootstrap-project` is discoverable as a skill and invokable from any repo.
2. Running in a clean repo produces a complete bundle in `./docs/`, `./docs/context/`, `./.claude/agents/`, and `./.claude/` (if UI surface detected).
3. No output file contains any `/[Hh]ydra|HYDRA/` token (verified by the blocking assertion).
4. Running in a Hydra-initialized repo (with `./hydra/` present) aborts with the documented message.
5. Interrupting mid-run leaves `./.bootstrap-scratch/` intact and `./docs/` + `./.claude/` untouched.
6. Layer 1 and Layer 2 tests pass in CI.
7. Layer 3 E2E tests pass on manual dispatch against both fixture projects.
