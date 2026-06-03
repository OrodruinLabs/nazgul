# `/nazgul:init --local` Flag Fix — Design

**Date:** 2026-04-16
**Status:** Approved (pending written review)
**Scope:** Fix silent drop of CLI flags in `/nazgul:init`, prevent the regression class across all skills, and add runtime transparency.

## Problem

Running `/nazgul:init --local` behaves as if the flag were never passed:

- `.gitignore` does not receive the `nazgul/` block (Step 2.5 skipped)
- `CLAUDE.md` gets the shared-mode Nazgul section appended (Step 5 not skipped)
- `nazgul/config.json` has no `install_mode: "local"` field
- The skill executes as though shared mode was selected

## Root Cause

`skills/init/SKILL.md` is missing the `## Arguments\n$ARGUMENTS` substitution block that every other argument-taking skill in this plugin uses (clean, patch, task, review, simplify, docs, start, reset, verify, context, metrics, board, bootstrap-project, gen-spec — 14 total). Without that block, Claude Code never materializes the user's CLI arguments into the skill's context window. Step-body text that says ``Check `$ARGUMENTS` for `--local` flag`` is read by the model as literal instruction prose referring to a variable that was never populated — so `LOCAL_MODE` defaults to `false` and every `if LOCAL_MODE=true` branch silently skips.

No existing test detects this:

- `test-frontmatter.sh` reads only YAML fields, not skill bodies.
- `test-skill-templates.sh` resolves `{{PARTIAL:name}}`, not `$ARGUMENTS`.
- `tests/e2e/test-init-skill.sh` runs `/nazgul:init` with no flags; its only assertion is `grep -q nazgul`. It never exercises `--local`, and the e2e workflow is manual-trigger only.
- Nothing reads skill bodies to enforce a substitution-block contract.

## Design

Three independent changes. No runtime behavior change outside `init`.

### Change 1 — Add the substitution block to `skills/init/SKILL.md`

Insert after the `## Examples` section and before `## Prerequisites Check`:

```markdown
## Arguments
$ARGUMENTS
```

This matches the placement and form used in `skills/clean/SKILL.md` and the 13 other skills that accept arguments. Fixes the reported bug on its own.

### Change 2 — Transparency guard in Step 0.5

Rewrite Step 0.5 in `skills/init/SKILL.md` so the model must emit the parsed decision before proceeding. Current text:

```text
### Step 0.5: Parse Arguments
1. Check `$ARGUMENTS` for `--local` flag
2. If `--local` is present, set a variable `LOCAL_MODE=true`
3. Both `--local` and `--force` can be combined
```

New text:

```text
### Step 0.5: Parse Arguments
1. Read the `## Arguments` block above. Note the literal string of arguments passed (may be empty).
2. Output to the user: "Parsed arguments: `<contents of Arguments block, or (none)>`. LOCAL_MODE = <true|false>. FORCE = <true|false>."
3. Set LOCAL_MODE=true iff the arguments contain the token `--local`. Otherwise LOCAL_MODE=false.
4. Set FORCE=true iff the arguments contain the token `--force`. Otherwise FORCE=false.
5. If the content read from the `## Arguments` block above (not this step's text) is literally the single token `$ARGUMENTS` with no other content, the substitution did not happen — STOP and report: "Skill argument substitution failed — this is a plugin bug. Do not proceed."
```

This makes silent-skip failures visible. The stop-if-literal check is a backstop against future regressions of Change 1.

### Change 3 — Regression test `tests/test-skill-arguments.sh`

New shell test. For each `skills/*/SKILL.md`:

1. Strip frontmatter (everything between first and second `---`, inclusive).
2. Count lines in the remaining body that contain `$ARGUMENTS`:
   - `total_refs` = lines matching `\$ARGUMENTS` anywhere
   - `substitution_lines` = lines whose trimmed content is exactly `$ARGUMENTS`
3. If `total_refs > 0` and `substitution_lines == 0`, the file is an offender.
4. Fail the test with the list of offending files and a pointer to this spec.

The test is picked up automatically by `tests/run-tests.sh` via its `test-*.sh` glob. Expected behavior:

- On current `main` (pre-fix): fails, listing `skills/init/SKILL.md`.
- After Change 1: passes.

## Testing Plan

**Unit:**
- `tests/test-skill-arguments.sh` passes after Change 1 lands; fails without it.
- Existing suite continues to pass (no other skill bodies change).

**Manual e2e (not automated — claude CLI cost):**
1. `mkdir /tmp/nazgul-local-test && cd /tmp/nazgul-local-test && git init && echo "# test" > README.md && git add . && git commit -m init`
2. Run `/nazgul:init --local --force`
3. Assert:
   - Output includes `Parsed arguments: --local --force. LOCAL_MODE = true. FORCE = true.`
   - `.gitignore` contains the `# Nazgul Framework (local mode)` block
   - `jq -r .install_mode nazgul/config.json` → `local`
   - `CLAUDE.md` does NOT contain the Nazgul section (or file does not exist if one wasn't there before)
   - Output includes `Skipping CLAUDE.md injection (local mode).`

## Out of Scope

- Repairing an already-initialized shared-mode project into local mode. A user hitting this bug on `main` must manually revert: `git checkout CLAUDE.md`, delete the `nazgul/` directory, re-run init after fix lands.
- Updating the e2e workflow to run on PRs or to cover `--local`. The unit test (Change 3) is the primary regression barrier; expanding e2e coverage is a separate concern.
- Validating `argument-hint` frontmatter usage. No skill in this repo uses it today.

## Risks

- Low. Change 1 is purely additive; Change 2 is prose-only with user-visible output (not a new behavior); Change 3 is a new file that only fails if a contract is broken.
- Change 2's "stop if literal" check depends on the model honoring the instruction. This is a backstop, not a primary defense — Change 3 is the primary defense.
