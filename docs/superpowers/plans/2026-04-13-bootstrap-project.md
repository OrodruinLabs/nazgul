# `/hydra:bootstrap-project` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single-shot skill `/hydra:bootstrap-project` that runs Hydra's pre-planning pipeline (discovery → doc-generator → reviewer-instantiation → designer) and emits a portable, Hydra-free bundle into `./docs/`, `./docs/context/`, `./.claude/agents/`, and `./.claude/`.

**Architecture:** The skill orchestrates Hydra's existing pipeline agents with their output redirected to `./.bootstrap-scratch/`. A pure-shell transform script scrubs any Hydra references from the output, then relocates files atomically into standard Claude Code paths. Source agents are invoked with pre-rendered prompts (path-substituted at invocation time) so existing pipeline behavior is preserved.

**Tech Stack:** bash (POSIX-safe, `set -euo pipefail`), `jq` for JSON, `yq`/`awk` for YAML frontmatter, Hydra's existing test harness (`tests/lib/assertions.sh`, `tests/lib/setup.sh`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-04-13-bootstrap-project-design.md`

---

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `skills/bootstrap-project/SKILL.md` | Entry point. Pre-flight → objective → pipeline → transform → relocate → cleanup. |
| `scripts/bootstrap-transform.sh` | Transform pass: path rewrites + frontmatter stripping + prose scrub + final assertion. |
| `scripts/lib/bootstrap-scrub-map.sh` | Centralized scrub rules (sourced by transform). |
| `scripts/lib/bootstrap-render.sh` | Agent-prompt renderer: path substitution + bundle-mode conditionals. |
| `scripts/lib/bootstrap-preflight.sh` | Pre-flight gate checks (pure functions, unit-testable). |
| `scripts/lib/bootstrap-relocate.sh` | Atomic staged relocation (pure functions, unit-testable). |
| `tests/test-bootstrap-transform.sh` | Layer 1: scrub-map fixture test. |
| `tests/test-bootstrap-preflight.sh` | Layer 2a: pre-flight gate unit tests. |
| `tests/test-bootstrap-relocate.sh` | Layer 2b: relocation atomicity tests. |
| `tests/test-bootstrap-project.sh` | Layer 2c: skill orchestration integration test (stubbed agents). |
| `tests/fixtures/bootstrap-transform/input/...` | Canned dirty scratch tree for transform tests. |
| `tests/fixtures/bootstrap-transform/expected/...` | Reference clean output tree. |
| `tests/e2e/test-bootstrap-project.sh` | Layer 3: real pipeline E2E (manual dispatch only). |
| `tests/e2e/fixtures/minimal-greenfield/.gitkeep` | Empty-project fixture. |
| `tests/e2e/fixtures/nextjs-brownfield/...` | Realistic Next.js fixture. |

**Modified files:**

| Path | Change |
|---|---|
| `agents/templates/reviewer-base.md` | Add `{{#bundle_mode}}...{{/bundle_mode}}` and `{{^bundle_mode}}...{{/bundle_mode}}` conditional blocks for identity prose. |
| `.github/workflows/test.yml` | New Layers 1 & 2 run on push/PR (picked up automatically by `tests/run-tests.sh`). |
| `.github/workflows/e2e-tests.yml` | Add Layer 3 E2E job on manual dispatch. |
| `README.md` | Add one-paragraph section documenting `/hydra:bootstrap-project`. |

**Explicitly NOT modified:**
- `agents/discovery.md`, `agents/doc-generator.md`, `agents/designer.md` — stay as-is. The renderer substitutes paths at invocation time.
- Any loop-phase agent or script.
- `templates/docs/*` source templates.

---

## Conventions

**Plugin root:** All scripts and the skill reference the plugin install root as `$CLAUDE_PLUGIN_ROOT`, following the existing pattern in `scripts/migrate-config.sh:9`:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
```

When the skill fragments in `SKILL.md` reference `$CLAUDE_PLUGIN_ROOT`, they rely on the Claude Code runtime populating that env var. For standalone shell execution (tests), the fallback above resolves to the repo root. Tests use the `REPO_ROOT` local computed from `$BASH_SOURCE[0]` (matching existing test patterns in `tests/lib/setup.sh`).

**v1 scope exclusions (documented in spec but deferred):**
- `--verbose` flag: declared in SKILL.md flag list, but its implementation (streaming agent output live vs. capturing) is left to the runtime default. Revisit if users ask for it.
- `./.bootstrap-scratch/bootstrap.log`: spec mentions a timestamped log file. v1 relies on stderr from each step and Claude Code's native transcript. Revisit after first real usage.
- Scrub-map allowlist mechanism: explicitly deferred per spec.

## Implementation Order

Phases:
1. **Scrub foundations** (Tasks 1-6) — transform script + tests, self-contained.
2. **Reviewer template bundle mode** (Task 7) — small template edit.
3. **Agent prompt renderer** (Task 8) — reusable helper.
4. **Pre-flight + relocate libraries** (Tasks 9-10) — unit-testable building blocks.
5. **Skill orchestration** (Tasks 11-14) — ties it all together.
6. **Integration test** (Task 15) — stubbed-agent run of the full skill.
7. **E2E + CI** (Tasks 16-18) — fixtures, workflow, docs.

Each task ends with a commit. Commit messages use Conventional Commits.

---

## Task 1: Scrub map data file

**Files:**
- Create: `scripts/lib/bootstrap-scrub-map.sh`

The scrub map is a pure-data bash file that declares associative arrays. Sourced by later tasks. No logic here — just declarations that downstream code consumes.

- [ ] **Step 1: Create the scrub-map file**

Create `scripts/lib/bootstrap-scrub-map.sh`:

```bash
#!/usr/bin/env bash
# Bootstrap scrub map — Hydra-token removal rules for /hydra:bootstrap-project.
# Sourced by scripts/bootstrap-transform.sh. No side effects on source.
#
# To add a new rule when the final assertion fires:
#   1. Classify the token (path vs prose)
#   2. Add to the appropriate array below
#   3. Update tests/fixtures/bootstrap-transform/{input,expected}/ accordingly
#   4. Re-run: tests/run-tests.sh --filter=bootstrap-transform

# Class 1 — Path rewrites. Applied longest-first via sort in transform.
# Format: "find|replace"  (replace may be "__DROP__" to mean "drop containing sentence/line")
BOOTSTRAP_SCRUB_PATH_RULES=(
  "hydra/docs/manifest.md|__DROP__"
  "hydra/docs/|docs/"
  "hydra/context/|docs/context/"
  "hydra/config.json|__DROP__"
  "hydra/plan.md|__DROP__"
  "hydra/tasks/|__DROP__"
  "hydra/checkpoints/|__DROP__"
  "hydra/reviews/|__DROP__"
  "hydra/logs/|__DROP__"
)

# Class 2 — Prose term rewrites (safety net). All map to __DROP__ (sentence removal).
# Match is whole-word, case-sensitive except where noted.
BOOTSTRAP_SCRUB_PROSE_RULES=(
  "Hydra pipeline|__DROP__"
  "Hydra loop|__DROP__"
  "the Hydra framework|__DROP__"
  "Hydra framework|__DROP__"
  "Hydra's review board|__DROP__"
  "Hydra|__DROP__"
  "HYDRA_[A-Z_]*|__DROP__"
)

# Class 4 — YAML frontmatter keys to remove from agent files.
BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE=(
  "hydra"
  "review-board"
  "loop-phase"
)

# Class 4 — description prefixes to strip (leading text only).
BOOTSTRAP_SCRUB_DESCRIPTION_PREFIXES=(
  "Pipeline:"
  "Post-loop:"
  "Specialist:"
)

# Files dropped entirely from the bundle (matched on basename).
BOOTSTRAP_SCRUB_DROP_FILES=(
  "manifest.md"
)
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/lib/bootstrap-scrub-map.sh`
Expected: exit 0, no output.

- [ ] **Step 3: Sanity-check sourcing**

Run:
```bash
bash -c 'source scripts/lib/bootstrap-scrub-map.sh && \
  echo "paths=${#BOOTSTRAP_SCRUB_PATH_RULES[@]}" && \
  echo "prose=${#BOOTSTRAP_SCRUB_PROSE_RULES[@]}" && \
  echo "frontmatter=${#BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE[@]}" && \
  echo "drops=${#BOOTSTRAP_SCRUB_DROP_FILES[@]}"'
```
Expected output:
```
paths=9
prose=7
frontmatter=3
drops=1
```

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/bootstrap-scrub-map.sh
git commit -m "feat(bootstrap): add scrub-map data file

Centralizes path, prose, and frontmatter removal rules for the
bootstrap-project transform pass. Pure data; no logic."
```

---

## Task 2: Transform script — path rewrites (Class 1)

**Files:**
- Create: `scripts/bootstrap-transform.sh`
- Create: `tests/test-bootstrap-transform.sh`
- Create: `tests/fixtures/bootstrap-transform/input/docs/PRD.md`
- Create: `tests/fixtures/bootstrap-transform/input/docs/TRD.md`
- Create: `tests/fixtures/bootstrap-transform/expected/docs/PRD.md`
- Create: `tests/fixtures/bootstrap-transform/expected/docs/TRD.md`

- [ ] **Step 1: Create input fixture with Hydra paths**

Create `tests/fixtures/bootstrap-transform/input/docs/PRD.md`:

```markdown
# PRD

## Overview
Build a widget system.

## References
- See hydra/context/project-profile.md for stack.
- Tasks tracked in hydra/tasks/ with status managed by the state machine.
- The build config lives in hydra/config.json.

## API
Endpoints write to the hydra/docs/ tree under hydra/docs/api/.
```

Create `tests/fixtures/bootstrap-transform/input/docs/TRD.md`:

```markdown
# TRD

Architecture uses standard layers. Data flow:
1. Ingest into hydra/context/raw.md
2. Process and write to hydra/docs/processed.md

No loop references here.
```

- [ ] **Step 2: Create expected output fixtures**

Create `tests/fixtures/bootstrap-transform/expected/docs/PRD.md`:

```markdown
# PRD

## Overview
Build a widget system.

## References
- See docs/context/project-profile.md for stack.

## API
Endpoints write to the docs/ tree under docs/api/.
```

Create `tests/fixtures/bootstrap-transform/expected/docs/TRD.md`:

```markdown
# TRD

Architecture uses standard layers. Data flow:
1. Ingest into docs/context/raw.md
2. Process and write to docs/processed.md

No loop references here.
```

(Note: the two `__DROP__` lines — `hydra/tasks/` and `hydra/config.json` — are removed entirely.)

- [ ] **Step 3: Write failing test**

Create `tests/test-bootstrap-transform.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-transform"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

TRANSFORM="$REPO_ROOT/scripts/bootstrap-transform.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/bootstrap-transform"

# Working copy of input (transform mutates in place)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-transform-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp -R "$FIXTURE_DIR/input/." "$WORK/"

# Run transform
if ! bash "$TRANSFORM" "$WORK" 2>"$WORK/.err"; then
  _fail "transform exits 0" "$(cat "$WORK/.err")"
  report_results
  exit 1
fi
_pass "transform exits 0"

# Diff actual vs expected (ignore the .err file and any hidden dirs)
DIFF_OUTPUT=$(diff -r \
  --exclude='.err' \
  "$FIXTURE_DIR/expected" "$WORK" 2>&1 || true)

if [ -z "$DIFF_OUTPUT" ]; then
  _pass "output matches expected"
else
  _fail "output matches expected" "diff:" "$DIFF_OUTPUT"
fi

report_results
```

- [ ] **Step 4: Make it executable and run to verify it fails**

Run:
```bash
chmod +x tests/test-bootstrap-transform.sh
bash tests/test-bootstrap-transform.sh
```
Expected: FAIL — transform script does not exist yet. Exit code nonzero.

- [ ] **Step 5: Implement transform script with path rewrites only**

Create `scripts/bootstrap-transform.sh`:

```bash
#!/usr/bin/env bash
# bootstrap-transform.sh — Scrub Hydra references from a scratch tree.
# Usage: bootstrap-transform.sh <scratch-root>
#
# Applies rules from scripts/lib/bootstrap-scrub-map.sh in order:
#   Class 1 — path rewrites (this task)
#   Class 4 — frontmatter stripping (Task 3)
#   Classes 2 & 3 — prose scrub safety net (Task 4)
#   Final assertion — no remaining Hydra tokens (Task 5)
#
# Transform mutates the scratch tree in place. Drops files listed in
# BOOTSTRAP_SCRUB_DROP_FILES.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/bootstrap-scrub-map.sh
source "$SCRIPT_DIR/lib/bootstrap-scrub-map.sh"

SCRATCH="${1:-}"
if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH" ]; then
  echo "usage: bootstrap-transform.sh <scratch-root>" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Class 1 — path rewrites
# -----------------------------------------------------------------------------

# Sort rules by find-length descending so longest matches first.
_sort_rules_longest_first() {
  local -a rules=("$@")
  for rule in "${rules[@]}"; do
    local find="${rule%%|*}"
    printf '%d\t%s\n' "${#find}" "$rule"
  done | sort -rn -k1,1 | cut -f2-
}

apply_path_rules() {
  local file="$1"
  local sorted
  mapfile -t sorted < <(_sort_rules_longest_first "${BOOTSTRAP_SCRUB_PATH_RULES[@]}")

  for rule in "${sorted[@]}"; do
    local find="${rule%%|*}"
    local repl="${rule#*|}"
    if [ "$repl" = "__DROP__" ]; then
      # Delete whole line containing the token (Task 4 refines this to sentence-level).
      # For now, deleting the line is sufficient for path tokens that stand alone.
      sed -i.bak "/$(printf '%s' "$find" | sed 's/[\/&.]/\\&/g')/d" "$file"
    else
      # Literal replacement. Escape forward slashes for sed.
      local find_esc repl_esc
      find_esc=$(printf '%s' "$find" | sed 's/[\/&.]/\\&/g')
      repl_esc=$(printf '%s' "$repl" | sed 's/[\/&]/\\&/g')
      sed -i.bak "s/$find_esc/$repl_esc/g" "$file"
    fi
    rm -f "${file}.bak"
  done
}

# -----------------------------------------------------------------------------
# Main walk
# -----------------------------------------------------------------------------

# Drop files first
for basename in "${BOOTSTRAP_SCRUB_DROP_FILES[@]}"; do
  while IFS= read -r path; do
    rm -f "$path"
  done < <(find "$SCRATCH" -type f -name "$basename")
done

# Apply rules per file
while IFS= read -r file; do
  apply_path_rules "$file"
done < <(find "$SCRATCH" -type f \( -name '*.md' -o -name '*.json' \))

exit 0
```

- [ ] **Step 6: Make it executable and run the test**

Run:
```bash
chmod +x scripts/bootstrap-transform.sh
bash tests/test-bootstrap-transform.sh
```
Expected: PASS — both assertions ("transform exits 0", "output matches expected").

Note on `sed -i`: macOS and GNU differ on the empty-string suffix form. The `.bak`-then-delete pattern is portable.

- [ ] **Step 7: Shellcheck**

Run: `shellcheck scripts/bootstrap-transform.sh scripts/lib/bootstrap-scrub-map.sh`
Expected: no errors (warnings acceptable if documented).

- [ ] **Step 8: Commit**

```bash
git add scripts/bootstrap-transform.sh tests/test-bootstrap-transform.sh \
  tests/fixtures/bootstrap-transform/input tests/fixtures/bootstrap-transform/expected
git commit -m "feat(bootstrap): add transform script with path rewrites

Implements Class 1 (path rewrites) of the bootstrap scrub map. Drops
files listed in BOOTSTRAP_SCRUB_DROP_FILES. Fixture-based regression
test at tests/test-bootstrap-transform.sh."
```

---

## Task 3: Frontmatter stripping (Class 4)

**Files:**
- Modify: `scripts/bootstrap-transform.sh`
- Create: `tests/fixtures/bootstrap-transform/input/agents/legacy-reviewer.md`
- Create: `tests/fixtures/bootstrap-transform/expected/agents/legacy-reviewer.md`

- [ ] **Step 1: Add agent fixture with dirty frontmatter**

Create `tests/fixtures/bootstrap-transform/input/agents/legacy-reviewer.md`:

```markdown
---
name: legacy-reviewer
description: "Pipeline: code quality reviewer for Python."
tools:
  - Read
  - Grep
allowed-tools: Read, Grep
maxTurns: 30
hydra:
  phase: review
  priority: high
review-board:
  enabled: true
loop-phase: review
hydra_config_key: some-value
model: claude-sonnet
---

# Legacy Reviewer

Review Python code for style and correctness.
```

- [ ] **Step 2: Add expected output for agent fixture**

Create `tests/fixtures/bootstrap-transform/expected/agents/legacy-reviewer.md`:

```markdown
---
name: legacy-reviewer
description: code quality reviewer for Python.
tools:
  - Read
  - Grep
allowed-tools: Read, Grep
maxTurns: 30
model: claude-sonnet
---

# Legacy Reviewer

Review Python code for style and correctness.
```

Expected transforms:
- `hydra:`, `review-board:`, `loop-phase:`, `hydra_config_key:` keys and their values removed.
- `description` prefix `Pipeline:` stripped; surrounding quotes removed (normalized).
- Order of remaining kept keys preserved.

- [ ] **Step 3: Extend test to expect the agent pass**

The existing diff-based test already covers the new files — the fixture addition alone should produce a failing test. Run:

```bash
bash tests/test-bootstrap-transform.sh
```
Expected: FAIL — `diff` reports mismatch under `agents/`.

- [ ] **Step 4: Implement frontmatter stripping**

Add to `scripts/bootstrap-transform.sh` BEFORE the `# Main walk` section:

```bash
# -----------------------------------------------------------------------------
# Class 4 — frontmatter stripping (agent files only)
# -----------------------------------------------------------------------------

# Is this file an agent (has YAML frontmatter starting at line 1)?
_is_agent_file() {
  local file="$1"
  head -1 "$file" 2>/dev/null | grep -qx -- '---'
}

# Parse, filter, and rewrite YAML frontmatter in place.
# Simple line-oriented parser: handles block keys (list values indented) by
# treating any line with no leading whitespace as a new top-level key.
strip_frontmatter() {
  local file="$1"
  _is_agent_file "$file" || return 0

  local tmp
  tmp=$(mktemp)

  awk '
    BEGIN { in_fm=0; skipping_block=0; emitted_open=0 }
    NR==1 && /^---$/ { in_fm=1; print; emitted_open=1; next }
    in_fm && /^---$/ { in_fm=0; skipping_block=0; print; next }
    in_fm {
      # Top-level key? (no leading whitespace, contains colon)
      if (match($0, /^[A-Za-z_][A-Za-z0-9_.-]*:/)) {
        key = substr($0, 1, RLENGTH-1)
        # Ask shell wrapper below
        if (key ~ /^hydra_/ || key == "hydra" || key == "review-board" || key == "loop-phase") {
          skipping_block=1
          next
        }
        skipping_block=0

        if (key == "description") {
          # Rewrite inline value, then print
          rest = substr($0, RLENGTH+1)
          sub(/^[ \t]*/, "", rest)
          # Strip surrounding quotes
          if ((rest ~ /^".*"$/) || (rest ~ /^'\''.*'\''$/)) {
            rest = substr(rest, 2, length(rest)-2)
          }
          # Strip known prefixes
          sub(/^Pipeline:[ \t]*/, "", rest)
          sub(/^Post-loop:[ \t]*/, "", rest)
          sub(/^Specialist:[ \t]*/, "", rest)
          print "description: " rest
          next
        }
        print
        next
      }
      # Continuation of previous key (indented). Print only if not skipping.
      if (skipping_block == 0) { print }
      next
    }
    # Outside frontmatter — pass through
    { print }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}
```

Then modify the main walk to call frontmatter stripping before path rules:

```bash
# Apply rules per file
while IFS= read -r file; do
  strip_frontmatter "$file"
  apply_path_rules "$file"
done < <(find "$SCRATCH" -type f \( -name '*.md' -o -name '*.json' \))
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: PASS — both path-rule and frontmatter fixtures match.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck scripts/bootstrap-transform.sh`
Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap-transform.sh \
  tests/fixtures/bootstrap-transform/input/agents \
  tests/fixtures/bootstrap-transform/expected/agents
git commit -m "feat(bootstrap): add YAML frontmatter stripping to transform

Implements Class 4: removes hydra*, review-board, loop-phase keys
from agent frontmatter and strips Pipeline/Post-loop/Specialist
prefixes from description fields."
```

---

## Task 4: Prose scrub safety net (Classes 2 & 3)

**Files:**
- Modify: `scripts/bootstrap-transform.sh`
- Create: `tests/fixtures/bootstrap-transform/input/agents/dirty-prose-reviewer.md`
- Create: `tests/fixtures/bootstrap-transform/expected/agents/dirty-prose-reviewer.md`

- [ ] **Step 1: Add dirty-prose fixture**

Create `tests/fixtures/bootstrap-transform/input/agents/dirty-prose-reviewer.md`:

```markdown
---
name: dirty-prose-reviewer
description: A reviewer with legacy prose.
tools:
  - Read
allowed-tools: Read
maxTurns: 30
---

# Dirty Prose Reviewer

You are a code reviewer spawned by the Hydra pipeline. Your job is to check code quality.

The Hydra loop will run you once per task. You must report findings clearly.

Set HYDRA_DEBUG=1 to enable verbose output.

## Rules
- Follow project style.
- Do not merge directly.
- Verify each change against the Hydra framework standards.
```

(Description is kept Hydra-free: Class 2 prose rules target body prose, not YAML frontmatter values. If a frontmatter description contained "Hydra," Class 4 description-prefix stripping wouldn't catch it — the final assertion would fire, prompting a scrub-map addition.)

- [ ] **Step 2: Add expected output**

Create `tests/fixtures/bootstrap-transform/expected/agents/dirty-prose-reviewer.md`:

```markdown
---
name: dirty-prose-reviewer
description: A reviewer with legacy prose.
tools:
  - Read
allowed-tools: Read
maxTurns: 30
---

# Dirty Prose Reviewer

Your job is to check code quality.

You must report findings clearly.

## Rules
- Follow project style.
- Do not merge directly.
```

Expected transforms:
- Sentence containing "Hydra pipeline" removed (first sentence of paragraph).
- Sentence with "Hydra loop" removed.
- Line with `HYDRA_DEBUG` removed.
- List item with "Hydra framework" removed.
- `description` field stays unchanged (clean in both input and expected).

- [ ] **Step 3: Run test, verify it fails**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: FAIL — diff shows unscrubbed Hydra prose.

- [ ] **Step 4: Implement prose scrub**

Add to `scripts/bootstrap-transform.sh` AFTER `apply_path_rules` and BEFORE the main walk:

```bash
# -----------------------------------------------------------------------------
# Classes 2 & 3 — prose term rewrites + sentence/line removal
# -----------------------------------------------------------------------------

# For each prose rule, if it matches in the file body, delete the containing
# sentence or list item. "Sentence" is defined as: content up to next sentence
# terminator (. ? !) on the same line, OR the whole line if it ends without one.
apply_prose_rules() {
  local file="$1"
  local tmp
  tmp=$(mktemp)

  # Build a single extended-regex OR of all prose patterns
  local patterns=()
  for rule in "${BOOTSTRAP_SCRUB_PROSE_RULES[@]}"; do
    patterns+=("${rule%%|*}")
  done
  local joined
  joined=$(printf '%s|' "${patterns[@]}")
  joined="${joined%|}"

  # Skip frontmatter (between leading ---). Process only body.
  # Then for each body line, if it matches the pattern:
  #   - If a list item (leading - or digits.), delete whole line
  #   - Else, delete only the containing sentence (split by . ? !)
  awk -v pat="$joined" '
    BEGIN { in_fm=0; fm_seen=0 }
    NR==1 && /^---$/ { in_fm=1; fm_seen=1; print; next }
    in_fm && /^---$/ { in_fm=0; print; next }
    in_fm { print; next }
    {
      line = $0
      if (match(line, pat)) {
        # Is it a list item?
        if (line ~ /^[ \t]*([-*]|[0-9]+\.)[ \t]/) {
          next
        }
        # Sentence-level removal. Split on terminators, drop offending sentence.
        n = split(line, sentences, /(?<=[.?!])[ \t]+/)
        out = ""
        for (i = 1; i <= n; i++) {
          if (sentences[i] !~ pat) {
            if (out == "") out = sentences[i]
            else out = out " " sentences[i]
          }
        }
        # If nothing left, drop line entirely
        if (out ~ /^[ \t]*$/) next
        print out
        next
      }
      print
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}
```

**Awk lookbehind compatibility:** `(?<=[.?!])` is a POSIX-extended PCRE-ism that gawk supports but mawk/BSD-awk may not. To stay portable, replace the split with a simpler loop:

Replace the sentence-split block with:

```bash
        # Tokenize by walking characters and splitting at . ? ! followed by space.
        out = ""
        buf = ""
        L = length(line)
        for (j = 1; j <= L; j++) {
          c = substr(line, j, 1)
          buf = buf c
          # End of sentence: terminator followed by space or EOL
          nextc = (j < L) ? substr(line, j+1, 1) : ""
          if ((c == "." || c == "?" || c == "!") && (nextc == " " || nextc == "\t" || nextc == "")) {
            if (buf !~ pat) {
              out = (out == "") ? buf : out buf
            }
            buf = ""
          }
        }
        if (buf != "" && buf !~ pat) {
          out = (out == "") ? buf : out buf
        }
        if (out ~ /^[ \t]*$/) next
        # Trim leading spaces carried over from dropped preceding sentence
        sub(/^[ \t]+/, "", out)
        print out
        next
```

Add the call into the main walk, after frontmatter, before paths:

```bash
  strip_frontmatter "$file"
  apply_prose_rules "$file"
  apply_path_rules "$file"
```

- [ ] **Step 5: Run the test**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: PASS.

If expected output doesn't match exactly (whitespace, collapsed paragraphs), adjust the fixture's `expected/` to match the actual scrubber behavior — the fixture is documentation of what the transform does, and small whitespace-quirk differences (e.g., an extra blank line after a dropped sentence) are acceptable. Document any such quirks as comments in the fixture.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck scripts/bootstrap-transform.sh`
Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap-transform.sh tests/fixtures/bootstrap-transform
git commit -m "feat(bootstrap): add prose scrub safety net to transform

Implements Classes 2 & 3: sentence-level removal for Hydra prose
tokens in body text; full-line removal for list items. Skips YAML
frontmatter blocks. Safety net only — bundle-mode reviewer template
should leave little for this pass to do."
```

---

## Task 5: Final assertion (blocking)

**Files:**
- Modify: `scripts/bootstrap-transform.sh`
- Create: `tests/fixtures/bootstrap-transform/input/agents/unscrubbable.md.SKIP`
- Modify: `tests/test-bootstrap-transform.sh`

- [ ] **Step 1: Add a separate unit test for the assertion**

The fixture-diff test proves clean inputs produce clean outputs. The assertion test proves dirty inputs *fail loudly*. These are different concerns.

Append to `tests/test-bootstrap-transform.sh` (before `report_results`):

```bash
# ---------------------------------------------------------------------
# Assertion test: if a Hydra token survives all rules, transform must fail
# ---------------------------------------------------------------------
ASSERT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-assert-XXXXXX")
trap 'rm -rf "$WORK" "$ASSERT_WORK"' EXIT
mkdir -p "$ASSERT_WORK/docs"
cat > "$ASSERT_WORK/docs/evil.md" <<'EVIL'
# Doc
This file uses HYDRA in uppercase intentionally.
EVIL

ASSERT_OUTPUT=$(bash "$TRANSFORM" "$ASSERT_WORK" 2>&1 || true)
ASSERT_EC=$?
# Bash: $? after `|| true` is 0; capture via explicit exit
ASSERT_EC=$(bash "$TRANSFORM" "$ASSERT_WORK" >/dev/null 2>&1; echo $?)

assert_exit_code "assertion fires on residual Hydra token" "$ASSERT_EC" 3
assert_contains "error message names file" "$ASSERT_OUTPUT" "evil.md"
assert_contains "error message suggests scrub-map edit" "$ASSERT_OUTPUT" "scripts/lib/bootstrap-scrub-map.sh"

report_results
```

(Decision: exit code 3 specifically for the assertion failure, distinct from exit 1 for other transform errors and exit 2 for usage.)

- [ ] **Step 2: Run the test, verify new assertions fail**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: the new "assertion fires..." test FAILS because we haven't implemented the assertion yet.

- [ ] **Step 3: Implement the assertion in the transform script**

At the END of `scripts/bootstrap-transform.sh` (before `exit 0`):

```bash
# -----------------------------------------------------------------------------
# Final assertion — no residual Hydra tokens
# -----------------------------------------------------------------------------

# -i is portable; -E is portable; -r recursive; -n with line numbers
ASSERT_MATCHES=$(grep -rinE '[Hh]ydra|HYDRA' "$SCRATCH" 2>/dev/null || true)

if [ -n "$ASSERT_MATCHES" ]; then
  {
    echo "bootstrap-transform: residual Hydra tokens found after scrub pass:"
    echo ""
    echo "$ASSERT_MATCHES" | sed 's/^/  /'
    echo ""
    echo "Fix: add a rule to scripts/lib/bootstrap-scrub-map.sh covering the"
    echo "matched token, then re-run. Suggested shape:"
    echo ""
    echo "  BOOTSTRAP_SCRUB_PROSE_RULES+=(\"<your-token>|__DROP__\")"
    echo ""
    echo "After adding the rule, update the fixture so the regression test"
    echo "locks the new behavior: tests/fixtures/bootstrap-transform/."
  } >&2
  exit 3
fi

exit 0
```

- [ ] **Step 4: Run the test to verify pass**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: all tests PASS, including the new assertion tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-transform.sh tests/test-bootstrap-transform.sh
git commit -m "feat(bootstrap): add blocking final assertion

Transform exits 3 if any Hydra token survives the scrub pass.
Error message names matching files/lines and suggests a scrub-map
patch. Backstop for future Hydra additions that slip past Classes 1-4."
```

---

## Task 6: End-to-end transform run against realistic scratch tree

**Files:**
- Expand: `tests/fixtures/bootstrap-transform/input/` with realistic per-section examples

This task consolidates the fixture so future task implementations can trust it.

- [ ] **Step 1: Add context and design fixtures**

Create `tests/fixtures/bootstrap-transform/input/context/project-profile.md`:

```markdown
# Project Profile

Stack: Python 3.12, FastAPI.
```

Create `tests/fixtures/bootstrap-transform/expected/context/project-profile.md`:

```markdown
# Project Profile

Stack: Python 3.12, FastAPI.
```

(Same — clean input, no transform needed, verifies walker doesn't mangle clean files.)

Create `tests/fixtures/bootstrap-transform/input/docs/manifest.md`:

```markdown
# Document Manifest

| Doc | Status |
|-----|--------|
| PRD | done |
```

(No expected file — `manifest.md` is dropped.)

- [ ] **Step 2: Run the test**

Run: `bash tests/test-bootstrap-transform.sh`
Expected: PASS. The diff test verifies `manifest.md` is NOT in the output and the clean context file is preserved unchanged.

- [ ] **Step 3: Add regression check for manifest drop**

Append to `tests/test-bootstrap-transform.sh` (before `report_results`, in the existing `$WORK`-scoped block, not the assertion block):

```bash
assert_file_not_exists "manifest.md dropped from bundle" "$WORK/docs/manifest.md"
```

Run: `bash tests/test-bootstrap-transform.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/bootstrap-transform tests/test-bootstrap-transform.sh
git commit -m "test(bootstrap): expand transform fixture coverage

Adds clean-file passthrough case and explicit manifest.md drop
assertion. The fixture now exercises every rule class end to end."
```

---

## Task 7: Reviewer template bundle mode

**Files:**
- Modify: `agents/templates/reviewer-base.md`

- [ ] **Step 1: Read the existing template**

Run: `cat agents/templates/reviewer-base.md`

The template uses `{{placeholder}}` substitution with no conditional syntax today. We'll add conditional blocks using a convention understood by the render helper (Task 8): `{{#bundle_mode}}...{{/bundle_mode}}` for "only when BUNDLE_MODE=true" and `{{^bundle_mode}}...{{/bundle_mode}}` for the inverse.

- [ ] **Step 2: Edit the template**

Modify `agents/templates/reviewer-base.md` in three places:

**(a) The `hooks:` block references `hydra/reviews/` — wrap it so bundle mode drops it:**

Replace:
```yaml
hooks:
  SubagentStop:
    - hooks:
        - type: prompt
          prompt: "A reviewer subagent is trying to stop. Check if it has written its review file to hydra/reviews/[TASK-ID]/[reviewer-name].md (inside a per-task subdirectory, NOT flat in hydra/reviews/). The file must contain a Final Verdict (APPROVED or CHANGES_REQUESTED). If no review file was written in the correct location, block and instruct the reviewer to create the hydra/reviews/[TASK-ID]/ directory and write its review there. $ARGUMENTS"
```

With:
```yaml
{{^bundle_mode}}
hooks:
  SubagentStop:
    - hooks:
        - type: prompt
          prompt: "A reviewer subagent is trying to stop. Check if it has written its review file to hydra/reviews/[TASK-ID]/[reviewer-name].md (inside a per-task subdirectory, NOT flat in hydra/reviews/). The file must contain a Final Verdict (APPROVED or CHANGES_REQUESTED). If no review file was written in the correct location, block and instruct the reviewer to create the hydra/reviews/[TASK-ID]/ directory and write its review there. $ARGUMENTS"
{{/bundle_mode}}
```

**(b) Step "Read `hydra/reviews/[TASK-ID]/diff.patch`" is Hydra-specific. Wrap it:**

Replace:
```markdown
## How to Review
1. Read `hydra/reviews/[TASK-ID]/diff.patch` FIRST — focus on what specifically changed
2. For each changed hunk, read the surrounding context in the full file if needed
{{review_steps}}
```

With:
```markdown
## How to Review
{{^bundle_mode}}
1. Read `hydra/reviews/[TASK-ID]/diff.patch` FIRST — focus on what specifically changed
2. For each changed hunk, read the surrounding context in the full file if needed
{{/bundle_mode}}
{{#bundle_mode}}
1. Identify the changed files and diff from the current conversation or user request
2. Read each changed file in full if its diff is small; focus on the diff hunk otherwise
{{/bundle_mode}}
{{review_steps}}
```

**(c) Final output instructions reference `hydra/reviews/`. Wrap them:**

Replace:
```markdown
Write your review to `hydra/reviews/[TASK-ID]/{{reviewer_name}}.md`.
Create the directory `hydra/reviews/[TASK-ID]/` first if it doesn't exist.
```

With:
```markdown
{{^bundle_mode}}
Write your review to `hydra/reviews/[TASK-ID]/{{reviewer_name}}.md`.
Create the directory `hydra/reviews/[TASK-ID]/` first if it doesn't exist.
{{/bundle_mode}}
{{#bundle_mode}}
Return your review inline as your final message. Structure the output as shown above.
{{/bundle_mode}}
```

- [ ] **Step 3: Verify the template still renders for Hydra mode**

The Hydra pipeline doesn't know about `{{#bundle_mode}}` — it uses only `{{placeholder}}` substitution. The new tags will appear literally in rendered output unless the renderer strips them.

Add a temporary safety: since no existing Hydra code substitutes bundle_mode, the `{{#bundle_mode}}` lines will currently leak into generated reviewer files. This is acceptable only if the existing reviewer-render logic is updated.

Check where the template is consumed today. Run:

```bash
grep -rn "reviewer-base.md\|reviewer_name\|{{" agents/ scripts/ skills/ | head -40
```

Look at the file(s) that invoke the template. Task 8 (the render helper) will be the canonical consumer for bundle mode; the existing Hydra consumer must also handle the new syntax — or, if it doesn't substitute bundle_mode, it must default to the NON-bundle branch.

The simplest safe rule: **both renderers (Hydra's and bootstrap's) strip `{{#bundle_mode}}...{{/bundle_mode}}` blocks by default (bundle_mode=false), and keep `{{^bundle_mode}}...{{/bundle_mode}}` blocks by default.** Hydra's existing renderer needs one small patch to do this.

If Hydra's existing renderer is a shell/python script, add these two `sed` passes just before variable substitution:

```bash
# Strip bundle-mode blocks (keep inverse-mode content)
sed -i.bak -e '/{{#bundle_mode}}/,/{{\/bundle_mode}}/d' \
           -e '/{{\^bundle_mode}}/d' -e '/{{\/bundle_mode}}/d' \
           "$rendered_template"
```

If the consumer is an agent (LLM) that directly reads the template, document the convention in a new comment at the top of `reviewer-base.md`:

```markdown
<!--
Template conventions:
  {{placeholder}}             — substitute at render
  {{#bundle_mode}}...{{/bundle_mode}}  — keep only when bundle_mode=true
  {{^bundle_mode}}...{{/bundle_mode}}  — keep only when bundle_mode is absent/false

Renderers MUST strip whichever branch does not apply. Default is bundle_mode=false.
-->
```

Add that comment block at the top of `reviewer-base.md` (before the `---` frontmatter line). Note: frontmatter must still be first non-comment content — HTML comments before `---` are OK for Markdown consumers but may break YAML-frontmatter parsers that require `---` at line 1. Verify:

Run:
```bash
head -5 agents/templates/reviewer-base.md
```

If this breaks an existing test or parser, move the comment block INSIDE the template body after the frontmatter closing `---`.

- [ ] **Step 4: Run the existing test suite**

Run: `tests/run-tests.sh`
Expected: all tests pass. If the frontmatter test (`test-frontmatter.sh`) fails due to the comment-before-frontmatter issue, move the comment and re-run.

- [ ] **Step 5: Commit**

```bash
git add agents/templates/reviewer-base.md
git commit -m "feat(reviewer-template): add bundle_mode conditional blocks

Adds {{#bundle_mode}}...{{/bundle_mode}} and {{^bundle_mode}}... blocks
so the same template source serves both the Hydra loop and the
portable bootstrap bundle. Renderers default bundle_mode=false."
```

---

## Task 8: Agent prompt renderer

**Files:**
- Create: `scripts/lib/bootstrap-render.sh`
- Create: `tests/test-bootstrap-render.sh`

- [ ] **Step 1: Write failing test**

Create `tests/test-bootstrap-render.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-render"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-render.sh
source "$REPO_ROOT/scripts/lib/bootstrap-render.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-render-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- Path substitution ---
cat > "$WORK/in.md" <<'IN'
Read hydra/context/foo.md and write to hydra/docs/bar.md.
Config lives in hydra/config.json.
IN

render_agent_prompt "$WORK/in.md" ".bootstrap-scratch" > "$WORK/out.md"

assert_file_contains "path replaced: hydra/context/" "$WORK/out.md" ".bootstrap-scratch/context/foo.md"
assert_file_contains "path replaced: hydra/docs/"    "$WORK/out.md" ".bootstrap-scratch/docs/bar.md"
assert_file_contains "path replaced: hydra/config"   "$WORK/out.md" ".bootstrap-scratch/config.json"

# --- Bundle-mode conditional stripping ---
cat > "$WORK/tmpl.md" <<'TMPL'
Before.
{{^bundle_mode}}
This is the Hydra branch.
{{/bundle_mode}}
{{#bundle_mode}}
This is the bundle branch.
{{/bundle_mode}}
After.
TMPL

# Default (bundle_mode=false) — keep inverse, drop positive
render_template "$WORK/tmpl.md" > "$WORK/tmpl-default.md"
assert_file_contains "default keeps inverse" "$WORK/tmpl-default.md" "Hydra branch"
assert_file_not_contains "default drops positive" "$WORK/tmpl-default.md" "bundle branch"

# Bundle mode on — drop inverse, keep positive
BUNDLE_MODE=true render_template "$WORK/tmpl.md" > "$WORK/tmpl-bundle.md"
assert_file_not_contains "bundle drops inverse" "$WORK/tmpl-bundle.md" "Hydra branch"
assert_file_contains "bundle keeps positive" "$WORK/tmpl-bundle.md" "bundle branch"

report_results
```

- [ ] **Step 2: Run test, verify failure**

Run: `chmod +x tests/test-bootstrap-render.sh && bash tests/test-bootstrap-render.sh`
Expected: FAIL — source file doesn't exist.

- [ ] **Step 3: Implement the renderer**

Create `scripts/lib/bootstrap-render.sh`:

```bash
#!/usr/bin/env bash
# bootstrap-render.sh — Helpers for rendering agent prompts in bundle mode.
# Sourced by the bootstrap-project skill and tested by tests/test-bootstrap-render.sh.

# render_template <file>
#   Strip {{#bundle_mode}}/{{^bundle_mode}} conditional blocks based on
#   BUNDLE_MODE env var (empty or "false" = disabled; any other value = enabled).
render_template() {
  local file="$1"
  local bundle_on="false"
  case "${BUNDLE_MODE:-}" in
    ""|false|False|FALSE|0) bundle_on="false" ;;
    *) bundle_on="true" ;;
  esac

  awk -v on="$bundle_on" '
    /{{#bundle_mode}}/  { in_pos=1; next }
    /{{\/bundle_mode}}/ { in_pos=0; in_inv=0; next }
    /{{\^bundle_mode}}/ { in_inv=1; next }
    in_pos { if (on == "true") print; next }
    in_inv { if (on == "false") print; next }
    { print }
  ' "$file"
}

# render_agent_prompt <agent-file> <state-root>
#   Render an agent prompt for pipeline execution: substitute hydra/ path
#   prefixes with <state-root>/. Does NOT apply bundle_mode; use render_template
#   directly when that's needed.
render_agent_prompt() {
  local file="$1"
  local state_root="$2"
  # Strip any trailing slash from state_root
  state_root="${state_root%/}"

  # Replace `hydra/` with `<state_root>/` everywhere. Word-boundary not needed;
  # hydra/ is a path-level prefix that doesn't appear outside paths.
  local sr_esc
  sr_esc=$(printf '%s' "$state_root" | sed 's/[\/&]/\\&/g')
  sed "s/hydra\//$sr_esc\//g" "$file"
}
```

- [ ] **Step 4: Run the test, verify pass**

Run: `bash tests/test-bootstrap-render.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck scripts/lib/bootstrap-render.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/bootstrap-render.sh tests/test-bootstrap-render.sh
git commit -m "feat(bootstrap): add agent prompt renderer

render_template strips {{#bundle_mode}} / {{^bundle_mode}} conditional
blocks based on BUNDLE_MODE env var. render_agent_prompt substitutes
hydra/ path prefixes with a given STATE_ROOT so source agents can be
invoked unchanged against a scratch tree."
```

---

## Task 9: Pre-flight gate library

**Files:**
- Create: `scripts/lib/bootstrap-preflight.sh`
- Create: `tests/test-bootstrap-preflight.sh`

- [ ] **Step 1: Write failing test**

Create `tests/test-bootstrap-preflight.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-preflight"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-preflight.sh
source "$REPO_ROOT/scripts/lib/bootstrap-preflight.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-preflight-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- check_no_hydra_dir ---
mkdir -p "$WORK/with-hydra/hydra"
mkdir -p "$WORK/clean"

(cd "$WORK/clean" && check_no_hydra_dir) && _pass "clean: no hydra dir" || _fail "clean: no hydra dir"

set +e
(cd "$WORK/with-hydra" && check_no_hydra_dir >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "hydra dir present: exit 10" "$ec" 10

# --- check_docs_agents_empty ---
mkdir -p "$WORK/empty"
(cd "$WORK/empty" && check_docs_agents_empty) && _pass "empty: passes" || _fail "empty: passes"

mkdir -p "$WORK/has-docs/docs"
touch "$WORK/has-docs/docs/PRD.md"
set +e
(cd "$WORK/has-docs" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "docs non-empty: exit 11" "$ec" 11

mkdir -p "$WORK/has-agents/.claude/agents"
touch "$WORK/has-agents/.claude/agents/reviewer.md"
set +e
(cd "$WORK/has-agents" && check_docs_agents_empty >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "agents non-empty: exit 11" "$ec" 11

# --- check_scratch_state ---
mkdir -p "$WORK/no-scratch"
(cd "$WORK/no-scratch" && check_scratch_state) && _pass "no scratch: passes" || _fail "no scratch: passes"

mkdir -p "$WORK/with-scratch/.bootstrap-scratch"
set +e
(cd "$WORK/with-scratch" && check_scratch_state >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "scratch exists: exit 12" "$ec" 12

# --- check_git_clean (non-blocking; returns 0 but sets warning flag) ---
cd "$WORK/clean"
git init -q
BOOTSTRAP_GIT_WARNING=""
check_git_clean
assert_eq "clean git: no warning" "$BOOTSTRAP_GIT_WARNING" ""

touch "$WORK/clean/dirty.txt"
BOOTSTRAP_GIT_WARNING=""
check_git_clean
assert_contains "dirty git: warning set" "$BOOTSTRAP_GIT_WARNING" "uncommitted"

cd "$REPO_ROOT"
report_results
```

- [ ] **Step 2: Run test, verify failure**

Run: `chmod +x tests/test-bootstrap-preflight.sh && bash tests/test-bootstrap-preflight.sh`
Expected: FAIL — source file doesn't exist.

- [ ] **Step 3: Implement the preflight library**

Create `scripts/lib/bootstrap-preflight.sh`:

```bash
#!/usr/bin/env bash
# bootstrap-preflight.sh — Pre-flight gate checks for /hydra:bootstrap-project.
# Pure functions; each returns a distinct non-zero exit code so the skill can
# branch cleanly. All operate relative to the current working directory.
#
# Exit codes:
#   10 — ./hydra/ exists (hard abort)
#   11 — ./docs/ or ./.claude/agents/ is non-empty (prompt or abort)
#   12 — ./.bootstrap-scratch/ exists from prior run (prompt)
#   0  — check passed

BOOTSTRAP_GIT_WARNING=""

check_no_hydra_dir() {
  if [ -d "./hydra" ]; then
    echo "error: ./hydra/ exists. This project is already Hydra-initialized." >&2
    echo "       /hydra:bootstrap-project generates a portable, Hydra-free bundle." >&2
    echo "       Use /hydra:start instead, or remove ./hydra/ first." >&2
    return 10
  fi
  return 0
}

check_docs_agents_empty() {
  local blocker=""
  if [ -d "./docs" ] && [ -n "$(ls -A ./docs 2>/dev/null)" ]; then
    blocker="./docs"
  elif [ -d "./.claude/agents" ] && [ -n "$(ls -A ./.claude/agents 2>/dev/null)" ]; then
    blocker="./.claude/agents"
  fi

  if [ -n "$blocker" ]; then
    echo "error: $blocker is not empty." >&2
    echo "       Re-run with --overwrite to replace existing contents." >&2
    return 11
  fi
  return 0
}

check_scratch_state() {
  if [ -d "./.bootstrap-scratch" ]; then
    echo "error: ./.bootstrap-scratch/ exists from a prior run." >&2
    echo "       Remove it or pass --wipe-scratch to start fresh." >&2
    return 12
  fi
  return 0
}

check_git_clean() {
  BOOTSTRAP_GIT_WARNING=""
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  local changes
  changes=$(git status --porcelain 2>/dev/null)
  if [ -n "$changes" ]; then
    BOOTSTRAP_GIT_WARNING="warning: git working tree has uncommitted changes; continuing"
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify pass**

Run: `bash tests/test-bootstrap-preflight.sh`
Expected: all tests PASS.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck scripts/lib/bootstrap-preflight.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/bootstrap-preflight.sh tests/test-bootstrap-preflight.sh
git commit -m "feat(bootstrap): add pre-flight gate library

Pure-function checks returning distinct exit codes per condition.
Covered: ./hydra/ existence, ./docs/ and ./.claude/agents/ emptiness,
./.bootstrap-scratch/ presence, git working-tree cleanliness."
```

---

## Task 10: Atomic relocation library

**Files:**
- Create: `scripts/lib/bootstrap-relocate.sh`
- Create: `tests/test-bootstrap-relocate.sh`

- [ ] **Step 1: Write failing test**

Create `tests/test-bootstrap-relocate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-relocate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# shellcheck source=../scripts/lib/bootstrap-relocate.sh
source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"

# --- Happy path: complete relocation succeeds ---
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-relocate-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SCRATCH="$WORK/.bootstrap-scratch"
mkdir -p "$SCRATCH/docs" "$SCRATCH/context" "$SCRATCH/agents" "$SCRATCH/.claude"
echo "PRD" > "$SCRATCH/docs/PRD.md"
echo "TRD" > "$SCRATCH/docs/TRD.md"
echo "profile" > "$SCRATCH/context/project-profile.md"
echo "reviewer" > "$SCRATCH/agents/code-reviewer.md"
echo '{"colors":{}}' > "$SCRATCH/.claude/design-tokens.json"

cd "$WORK"
relocate_bundle "$SCRATCH" "$WORK"

assert_file_exists "PRD relocated"        "$WORK/docs/PRD.md"
assert_file_exists "TRD relocated"        "$WORK/docs/TRD.md"
assert_file_exists "context relocated"    "$WORK/docs/context/project-profile.md"
assert_file_exists "agents relocated"     "$WORK/.claude/agents/code-reviewer.md"
assert_file_exists "design relocated"     "$WORK/.claude/design-tokens.json"

# --- Atomicity: simulate mid-run failure by making one target read-only ---
WORK2=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-relocate2-XXXXXX")
trap 'rm -rf "$WORK" "$WORK2"' EXIT
SCRATCH2="$WORK2/.bootstrap-scratch"
mkdir -p "$SCRATCH2/docs" "$SCRATCH2/agents"
echo "PRD" > "$SCRATCH2/docs/PRD.md"
echo "reviewer" > "$SCRATCH2/agents/code-reviewer.md"

# Pre-create .claude/agents as a read-only directory — relocate must pre-check
# and abort before touching ./docs/
mkdir -p "$WORK2/.claude/agents"
chmod 555 "$WORK2/.claude/agents"

set +e
(cd "$WORK2" && relocate_bundle "$SCRATCH2" "$WORK2" >/dev/null 2>&1)
ec=$?
set -e
chmod 755 "$WORK2/.claude/agents"

assert_exit_code "relocate fails on unwritable target" "$ec" 20
assert_file_not_exists "PRD NOT relocated (atomic)" "$WORK2/docs/PRD.md"

report_results
```

- [ ] **Step 2: Run test, verify failure**

Run: `chmod +x tests/test-bootstrap-relocate.sh && bash tests/test-bootstrap-relocate.sh`
Expected: FAIL — source doesn't exist.

- [ ] **Step 3: Implement the relocation library**

Create `scripts/lib/bootstrap-relocate.sh`:

```bash
#!/usr/bin/env bash
# bootstrap-relocate.sh — Atomic, staged file relocation from scratch to final.
#
# Exit codes:
#   20 — dry-run check failed (target would not be writable)
#   21 — write failed mid-run (should not happen after dry-run passes)
#   0  — success

# relocate_bundle <scratch-root> <project-root>
#   Moves files from scratch/{docs,context,agents,.claude} into project root
#   under ./docs/, ./docs/context/, ./.claude/agents/, ./.claude/.
#
# Atomicity: runs a dry-run feasibility pass first (checks every target dir is
# writable). Only if all pass does it perform the actual moves. If a real move
# fails after dry-run passed, exits 21 with loud error (should be rare — only
# under racy conditions like concurrent chmod).
relocate_bundle() {
  local scratch="$1"
  local project="$2"

  # Build the move list as "src|dst" pairs
  local -a moves=()

  # Docs
  if [ -d "$scratch/docs" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/docs/$base")
    done < <(find "$scratch/docs" -maxdepth 1 -type f -name '*.md')
  fi

  # Context
  if [ -d "$scratch/context" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/docs/context/$base")
    done < <(find "$scratch/context" -maxdepth 1 -type f -name '*.md')
  fi

  # Agents
  if [ -d "$scratch/agents" ]; then
    while IFS= read -r src; do
      local base
      base=$(basename "$src")
      moves+=("$src|$project/.claude/agents/$base")
    done < <(find "$scratch/agents" -maxdepth 1 -type f -name '*.md')
  fi

  # Design system
  for f in design-tokens.json design-system.md; do
    if [ -f "$scratch/.claude/$f" ]; then
      moves+=("$scratch/.claude/$f|$project/.claude/$f")
    fi
  done

  # --- Dry-run: ensure every target dir can be created and written ---
  local -A checked_dirs=()
  local pair src dst dst_dir
  for pair in "${moves[@]}"; do
    dst="${pair#*|}"
    dst_dir=$(dirname "$dst")
    if [ -z "${checked_dirs[$dst_dir]:-}" ]; then
      if ! mkdir -p "$dst_dir" 2>/dev/null; then
        echo "error: cannot create target directory: $dst_dir" >&2
        return 20
      fi
      if [ ! -w "$dst_dir" ]; then
        echo "error: target directory is not writable: $dst_dir" >&2
        return 20
      fi
      checked_dirs["$dst_dir"]=1
    fi
  done

  # --- Real moves ---
  for pair in "${moves[@]}"; do
    src="${pair%|*}"
    dst="${pair#*|}"
    if ! mv "$src" "$dst" 2>/dev/null; then
      echo "error: failed to move $src -> $dst" >&2
      return 21
    fi
  done

  return 0
}

# append_gitignore <project-root>
#   Idempotently appends .bootstrap-scratch/ to .gitignore. Non-fatal on failure.
append_gitignore() {
  local project="$1"
  local gitignore="$project/.gitignore"
  local entry=".bootstrap-scratch/"

  if [ -f "$gitignore" ] && grep -qxF "$entry" "$gitignore"; then
    return 0
  fi
  if ! printf '\n%s\n' "$entry" >> "$gitignore" 2>/dev/null; then
    echo "warning: could not append $entry to .gitignore" >&2
    return 0
  fi
  return 0
}

# cleanup_scratch <scratch-root>
#   Removes the scratch dir. Non-fatal on failure.
cleanup_scratch() {
  local scratch="$1"
  if ! rm -rf "$scratch" 2>/dev/null; then
    echo "warning: could not remove $scratch" >&2
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify pass**

Run: `bash tests/test-bootstrap-relocate.sh`
Expected: all tests PASS.

Note: the chmod-based read-only test may behave differently on different filesystems. If the test is flaky, replace the read-only mechanism with a target that's a *file* where a directory is needed (e.g., `touch "$WORK2/.claude"`), which is uniformly non-writable-as-dir.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck scripts/lib/bootstrap-relocate.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/bootstrap-relocate.sh tests/test-bootstrap-relocate.sh
git commit -m "feat(bootstrap): add atomic relocation library

Dry-runs target-dir writability before any real move so failures
surface before the first byte changes. Provides cleanup_scratch and
append_gitignore helpers. Distinct exit codes per failure mode."
```

---

## Task 11: SKILL.md skeleton with pre-flight gate

**Files:**
- Create: `skills/bootstrap-project/SKILL.md`

- [ ] **Step 1: Examine an existing skill for structure reference**

Run: `cat skills/init/SKILL.md | head -80`

Skills are YAML-frontmatter + markdown prompt. The frontmatter declares `name`, `description`, `allowed-tools`, and optionally `context: fork`, `agent`, etc. The body is the LLM-facing instructions.

- [ ] **Step 2: Create the skill file — preflight-only skeleton**

Create `skills/bootstrap-project/SKILL.md`:

```markdown
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

*(Implemented in Task 12.)*

### Phase 3 — Pipeline execution

*(Implemented in Task 13.)*

### Phase 4 — Transform, relocate, cleanup

*(Implemented in Task 14.)*

### Phase 5 — Summary

*(Implemented in Task 14.)*
```

> **Conventions note:** The SKILL.md is read by Claude Code as both a shell-style reference and an LLM prompt. The bash fragments in Phase 1 are executed when the skill runs; prose between them tells the LLM what to do for interactive prompts. The skeleton leaves Phases 2-5 as placeholder markers that Tasks 12-14 will fill with real logic.

- [ ] **Step 3: Verify skill frontmatter is valid**

Run: `bash tests/test-frontmatter.sh`
Expected: PASS. If this test validates all skill frontmatter, the new skill must conform.

- [ ] **Step 4: Verify skill is discoverable by listing installed skills**

Hydra ships a skill listing mechanism; the test suite exercises it via `tests/test-skill-templates.sh`:

Run: `bash tests/test-skill-templates.sh`
Expected: PASS. If the new skill is picked up with no errors, the frontmatter is correct.

- [ ] **Step 5: Commit**

```bash
git add skills/bootstrap-project/SKILL.md
git commit -m "feat(bootstrap): add skill skeleton with pre-flight gate

Initial SKILL.md for /hydra:bootstrap-project. Phase 1 (pre-flight)
wired to scripts/lib/bootstrap-preflight.sh. Phases 2-5 are
placeholders filled in by subsequent tasks."
```

---

## Task 12: Objective collection in the skill

**Files:**
- Modify: `skills/bootstrap-project/SKILL.md`

- [ ] **Step 1: Locate the objective-collection logic in gen-spec**

Run: `sed -n '34,75p' skills/gen-spec/SKILL.md`

This shows the Tier 1 questions and Tier 2 offer. Bootstrap-project uses the same 5 Tier 1 questions, condensed.

- [ ] **Step 2: Replace the Phase 2 placeholder**

In `skills/bootstrap-project/SKILL.md`, replace the Phase 2 placeholder block with:

```markdown
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
```

- [ ] **Step 3: Manual smoke test — argument path**

Since this phase is mostly LLM-driven prose, a full automated test is not practical at this layer (covered by Task 15's integration test). A quick manual verification is sufficient:

Run:
```bash
# This won't exercise the full skill (no Agent subprocess), but validates the bash fragments are syntactically sound
bash -n skills/bootstrap-project/SKILL.md 2>&1 | grep -v "^$" || echo "(no output from bash -n)"
```

`bash -n` can't be run directly on a markdown file. Instead, extract bash fragments and check them. A quick way:

```bash
awk '/^```bash$/,/^```$/' skills/bootstrap-project/SKILL.md | grep -v '^```' | bash -n
```

Expected: no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add skills/bootstrap-project/SKILL.md
git commit -m "feat(bootstrap): implement objective collection phase

Uses \$ARGUMENTS when provided, else runs a condensed Tier 1/Tier 2
interactive spec flow mirroring /hydra:gen-spec. Writes to
./.bootstrap-scratch/context/project-spec.md before proceeding."
```

---

## Task 13: Pipeline execution in the skill

**Files:**
- Modify: `skills/bootstrap-project/SKILL.md`

- [ ] **Step 1: Replace the Phase 3 placeholder**

In `skills/bootstrap-project/SKILL.md`, replace the Phase 3 placeholder with:

```markdown
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
```

- [ ] **Step 2: Add `select_reviewer_domains` and `substitute_domain_vars` helpers**

Append to `scripts/lib/bootstrap-render.sh`:

```bash
# select_reviewer_domains <project-profile.md> <reviewer-domains.json>
#   Outputs one domain name per line. Baseline domains always included;
#   additional domains conditionally included based on profile keyword match.
#   Skips names not present in the JSON (emits a warning to stderr).
select_reviewer_domains() {
  local profile="$1"
  local domains_json="$2"
  [ -f "$profile" ] && [ -f "$domains_json" ] || return 0

  # Baseline
  local -a candidates=("code-reviewer" "qa-reviewer")

  # Conditional adds by keyword presence
  if grep -qiE '\b(api|rest|graphql|endpoint)\b' "$profile"; then
    candidates+=("api-reviewer")
  fi
  if grep -qiE '\b(react|vue|svelte|angular|next\.js|nextjs|nuxt)\b' "$profile"; then
    candidates+=("frontend-reviewer")
  fi
  if grep -qiE '\b(auth|login|password|token|jwt|oauth)\b' "$profile"; then
    candidates+=("security-reviewer")
  fi
  if grep -qiE '\b(database|caching|redis|perf)\b' "$profile"; then
    candidates+=("performance-reviewer")
  fi

  # Filter to keys actually present in the JSON
  local d
  for d in "${candidates[@]}"; do
    if jq -e --arg d "$d" '.[$d]' "$domains_json" >/dev/null 2>&1; then
      echo "$d"
    else
      echo "warning: domain '$d' not in reviewer-domains.json — skipping" >&2
    fi
  done
}

# substitute_domain_vars <domain> <reviewer-domains.json>
#   Reads template from stdin, writes substituted template to stdout.
#   Handles that checklist / review_steps are JSON arrays (joined to markdown lists).
substitute_domain_vars() {
  local domain="$1"
  local json="$2"
  [ -f "$json" ] || { cat; return; }

  local name title desc cat checklist review_steps approved rejected ctx
  name="$domain"
  title=$(jq -r --arg d "$domain" '.[$d].title // $d' "$json")
  desc=$(jq -r --arg d "$domain" '.[$d].description // ""' "$json")
  cat=$(jq -r --arg d "$domain" '.[$d].category // "general"' "$json")
  # Array → "- item1\n- item2\n..."
  checklist=$(jq -r --arg d "$domain" '
    (.[$d].checklist // []) | map("- " + .) | join("\n")
  ' "$json")
  # Numbered list starting at 3 (the template hard-codes steps 1 and 2)
  review_steps=$(jq -r --arg d "$domain" '
    (.[$d].review_steps // []) | to_entries | map("\(.key + 3). \(.value)") | join("\n")
  ' "$json")
  approved=$(jq -r --arg d "$domain" '.[$d].approved_criteria // "no blocking issues"' "$json")
  rejected=$(jq -r --arg d "$domain" '.[$d].rejected_criteria // "blocking issues found"' "$json")
  ctx=$(jq -r --arg d "$domain" '.[$d].context_items // ""' "$json")

  # Use python/awk-style substitution because sed handles multiline values awkwardly.
  # Write template to a temp file so we can substitute via awk.
  local tpl
  tpl=$(mktemp)
  cat > "$tpl"

  awk -v name="$name" -v title="$title" -v desc="$desc" -v cat="$cat" \
      -v checklist="$checklist" -v review_steps="$review_steps" \
      -v approved="$approved" -v rejected="$rejected" -v ctx="$ctx" '
    {
      gsub(/\{\{reviewer_name\}\}/, name)
      gsub(/\{\{title\}\}/, title)
      gsub(/\{\{description\}\}/, desc)
      gsub(/\{\{category\}\}/, cat)
      gsub(/\{\{checklist\}\}/, checklist)
      gsub(/\{\{review_steps\}\}/, review_steps)
      gsub(/\{\{approved_criteria\}\}/, approved)
      gsub(/\{\{rejected_criteria\}\}/, rejected)
      gsub(/\{\{context_items\}\}/, ctx)
      print
    }
  ' "$tpl"

  rm -f "$tpl"
}
```

- [ ] **Step 3: Add focused render tests for the new helpers**

Append to `tests/test-bootstrap-render.sh` (before `report_results`):

```bash
# --- select_reviewer_domains ---
cat > "$WORK/profile.md" <<'PROF'
Stack: Next.js (React), TypeScript, Tailwind, PostgreSQL. Uses JWT auth.
PROF
cat > "$WORK/domains.json" <<'DOM'
{
  "code-reviewer": {"title": "Code", "description": "d", "checklist": [], "review_steps": []},
  "qa-reviewer": {"title": "QA", "description": "d", "checklist": [], "review_steps": []},
  "frontend-reviewer": {"title": "Frontend", "description": "d", "checklist": [], "review_steps": []},
  "security-reviewer": {"title": "Security", "description": "d", "checklist": [], "review_steps": []}
}
DOM

mapfile -t SELECTED < <(select_reviewer_domains "$WORK/profile.md" "$WORK/domains.json")
assert_contains "baseline: code-reviewer"    "${SELECTED[*]}" "code-reviewer"
assert_contains "baseline: qa-reviewer"      "${SELECTED[*]}" "qa-reviewer"
assert_contains "frontend detected (nextjs)" "${SELECTED[*]}" "frontend-reviewer"
assert_contains "security detected (jwt)"    "${SELECTED[*]}" "security-reviewer"
assert_not_contains "no api-reviewer"        "${SELECTED[*]}" "api-reviewer"

# --- substitute_domain_vars ---
cat > "$WORK/tpl.md" <<'TPL'
name: {{reviewer_name}}
title: {{title}} Reviewer
description: {{description}}
## Checklist
{{checklist}}
## Steps
1. a
2. b
{{review_steps}}
TPL

OUT=$(cat "$WORK/tpl.md" | substitute_domain_vars "code-reviewer" "$WORK/domains.json")
assert_contains "name substituted" "$OUT" "name: code-reviewer"
assert_contains "title substituted" "$OUT" "title: Code Reviewer"
assert_not_contains "no placeholder leak" "$OUT" "{{"

report_results
```

Run: `bash tests/test-bootstrap-render.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add skills/bootstrap-project/SKILL.md scripts/lib/bootstrap-render.sh tests/test-bootstrap-render.sh
git commit -m "feat(bootstrap): implement pipeline execution phase

Wires discovery, doc-generator, reviewer-instantiation, and designer
into the skill. Adds detect_reviewer_domains and substitute_domain_vars
helpers. All agents invoked with rendered (Hydra-free path) prompts;
reviewer template rendered with BUNDLE_MODE=true."
```

---

## Task 14: Transform, relocate, cleanup, summary

**Files:**
- Modify: `skills/bootstrap-project/SKILL.md`

- [ ] **Step 1: Replace the Phase 4 and Phase 5 placeholders**

In `skills/bootstrap-project/SKILL.md`, replace both placeholders with:

```markdown
### Phase 4 — Transform, relocate, cleanup

Source the relocate helpers:

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/bootstrap-relocate.sh"
```

Run the transform:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/bootstrap-transform.sh" "$STATE_ROOT"
case $? in
  0) ;;
  2) echo "error: transform usage error" >&2; exit 50 ;;
  3)
    echo "error: transform final assertion failed — see output above." >&2
    echo "       scratch preserved at $STATE_ROOT for debugging." >&2
    exit 51
    ;;
  *) echo "error: transform failed (exit $?)" >&2; exit 52 ;;
esac
```

If `--dry-run`, stop here. Report the scratch location to the user:

```bash
if echo "$ARGUMENTS" | grep -q -- '--dry-run'; then
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
```

- [ ] **Step 2: Quick syntax check of extracted bash fragments**

Run:
```bash
awk '/^```bash$/,/^```$/' skills/bootstrap-project/SKILL.md | grep -v '^```' > /tmp/fragments.sh
bash -n /tmp/fragments.sh
```
Expected: no syntax errors reported. (Cross-fragment references like `$STATE_ROOT` may be flagged as unset, which is OK for `bash -n`.)

- [ ] **Step 3: Commit**

```bash
git add skills/bootstrap-project/SKILL.md
git commit -m "feat(bootstrap): complete skill with transform, relocate, summary

Phases 4-5: invokes bootstrap-transform.sh, honors --dry-run,
atomically relocates via relocate_bundle, appends .gitignore,
cleans up scratch, prints summary."
```

---

## Task 15: Orchestration integration test (stubbed agents)

**Files:**
- Create: `tests/test-bootstrap-project.sh`

- [ ] **Step 1: Write the integration test**

This test exercises the pre-flight, transform, relocate, and summary phases of the skill by pre-populating `./.bootstrap-scratch/` with fake agent outputs. It bypasses the actual Agent invocation (which requires the LLM) but covers all deterministic orchestration.

Create `tests/test-bootstrap-project.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-project"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

# Build a reusable function that simulates the skill's orchestration bash
# (everything except the Agent tool invocations, which we replace with
# pre-populated fake scratch trees).
simulate_bootstrap() {
  local project="$1"
  local scratch="$project/.bootstrap-scratch"

  # Pre-flight (in-process)
  (cd "$project" && source "$REPO_ROOT/scripts/lib/bootstrap-preflight.sh" && \
    check_no_hydra_dir && check_scratch_state && check_docs_agents_empty && check_git_clean) || return $?

  # Stubbed pipeline — write canonical outputs to scratch
  mkdir -p "$scratch/docs" "$scratch/context" "$scratch/agents" "$scratch/.claude"
  cat > "$scratch/docs/PRD.md" <<'PRD'
# PRD
See hydra/context/project-profile.md for stack info.
PRD
  cat > "$scratch/docs/TRD.md" <<'TRD'
# TRD
Architecture docs.
TRD
  cat > "$scratch/docs/test-plan.md" <<'TP'
# Test Plan
TP
  cat > "$scratch/docs/manifest.md" <<'MAN'
# Manifest
MAN
  cat > "$scratch/context/project-profile.md" <<'PROF'
# Profile
Stack: Python.
PROF
  cat > "$scratch/agents/code-reviewer.md" <<'AG'
---
name: code-reviewer
description: "Pipeline: reviewer"
tools:
  - Read
allowed-tools: Read
maxTurns: 30
hydra:
  phase: review
---

# Code Reviewer
Review the code.
AG

  # Transform
  bash "$REPO_ROOT/scripts/bootstrap-transform.sh" "$scratch" || return $?

  # Relocate
  source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"
  (cd "$project" && relocate_bundle "$scratch" "$project") || return $?
  (cd "$project" && append_gitignore "$project")
  (cd "$project" && cleanup_scratch "$scratch")
}

# --- Happy path ---
setup_temp_dir
setup_git_repo

simulate_bootstrap "$TEST_DIR"
happy_ec=$?
assert_exit_code "happy path exit 0" "$happy_ec" 0

assert_file_exists "PRD landed"     "$TEST_DIR/docs/PRD.md"
assert_file_exists "TRD landed"     "$TEST_DIR/docs/TRD.md"
assert_file_exists "test-plan"      "$TEST_DIR/docs/test-plan.md"
assert_file_exists "profile landed" "$TEST_DIR/docs/context/project-profile.md"
assert_file_exists "reviewer"       "$TEST_DIR/.claude/agents/code-reviewer.md"

assert_file_not_exists "manifest dropped"           "$TEST_DIR/docs/manifest.md"
assert_file_not_exists "scratch cleaned up"         "$TEST_DIR/.bootstrap-scratch"
assert_file_not_contains "PRD has no hydra/ path"   "$TEST_DIR/docs/PRD.md" "hydra/"
assert_file_not_contains "reviewer has no hydra fm" "$TEST_DIR/.claude/agents/code-reviewer.md" "hydra:"
assert_file_contains "gitignore appended"           "$TEST_DIR/.gitignore" ".bootstrap-scratch/"

teardown_temp_dir

# --- Pre-flight: aborts if ./hydra/ exists ---
setup_temp_dir
setup_git_repo
mkdir -p "$TEST_DIR/hydra"
set +e
simulate_bootstrap "$TEST_DIR" >/dev/null 2>&1
ec=$?
set -e
assert_exit_code "aborts on ./hydra/" "$ec" 10
assert_file_not_exists "docs NOT created" "$TEST_DIR/docs/PRD.md"
teardown_temp_dir

# --- Atomicity: simulated mid-relocation failure leaves docs untouched ---
setup_temp_dir
setup_git_repo

# Make ./.claude/agents a regular file so mkdir -p fails during relocate
# (this triggers the dry-run check in relocate_bundle)
mkdir -p "$TEST_DIR/.claude"
touch "$TEST_DIR/.claude/agents"

# Pre-populate scratch (bypass pre-flight since we're testing mid-run)
SCRATCH="$TEST_DIR/.bootstrap-scratch"
mkdir -p "$SCRATCH/docs" "$SCRATCH/agents"
echo "PRD" > "$SCRATCH/docs/PRD.md"
echo "reviewer" > "$SCRATCH/agents/r.md"

source "$REPO_ROOT/scripts/lib/bootstrap-relocate.sh"
set +e
(cd "$TEST_DIR" && relocate_bundle "$SCRATCH" "$TEST_DIR" >/dev/null 2>&1)
ec=$?
set -e
assert_exit_code "relocate aborts pre-first-write" "$ec" 20
assert_file_not_exists "docs/PRD NOT created" "$TEST_DIR/docs/PRD.md"
teardown_temp_dir

report_results
```

- [ ] **Step 2: Run the test**

Run: `chmod +x tests/test-bootstrap-project.sh && bash tests/test-bootstrap-project.sh`
Expected: all assertions PASS.

- [ ] **Step 3: Run the full suite to confirm no regressions**

Run: `tests/run-tests.sh`
Expected: all 20+ test files pass (18 existing + bootstrap ones).

- [ ] **Step 4: Commit**

```bash
git add tests/test-bootstrap-project.sh
git commit -m "test(bootstrap): add orchestration integration test

Stubs agent outputs and drives the full transform/relocate/cleanup
pipeline end-to-end. Covers happy path, pre-flight abort on ./hydra/,
and atomicity under a simulated mid-relocation failure."
```

---

## Task 16: E2E fixtures + test (manual dispatch)

**Files:**
- Create: `tests/e2e/fixtures/minimal-greenfield/.gitkeep`
- Create: `tests/e2e/fixtures/minimal-greenfield/README.md`
- Create: `tests/e2e/fixtures/nextjs-brownfield/package.json`
- Create: `tests/e2e/fixtures/nextjs-brownfield/app/page.tsx`
- Create: `tests/e2e/fixtures/nextjs-brownfield/README.md`
- Create: `tests/e2e/test-bootstrap-project.sh`

- [ ] **Step 1: Build minimal greenfield fixture**

Create `tests/e2e/fixtures/minimal-greenfield/README.md`:

```markdown
# Minimal Greenfield Fixture

Empty project used for E2E bootstrap-project tests. Represents a
pre-code greenfield repo.
```

Create `tests/e2e/fixtures/minimal-greenfield/.gitkeep` (empty file).

- [ ] **Step 2: Build Next.js brownfield fixture**

Create `tests/e2e/fixtures/nextjs-brownfield/package.json`:

```json
{
  "name": "nextjs-brownfield-fixture",
  "version": "0.1.0",
  "private": true,
  "dependencies": {
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "@types/react": "^19.0.0"
  }
}
```

Create `tests/e2e/fixtures/nextjs-brownfield/app/page.tsx`:

```tsx
export default function Home() {
  return <main>Hello</main>;
}
```

Create `tests/e2e/fixtures/nextjs-brownfield/README.md`:

```markdown
# Next.js Brownfield Fixture

Realistic Next.js 15 + React 19 app used for E2E bootstrap-project
tests. Represents a mid-sized frontend repo.
```

- [ ] **Step 3: Write the E2E test**

Create `tests/e2e/test-bootstrap-project.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="e2e-bootstrap-project"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/assertions.sh"

echo "=== $TEST_NAME ==="

command -v claude >/dev/null 2>&1 || {
  echo "SKIP: claude CLI not available"
  exit 0
}

run_fixture() {
  local fixture_name="$1"
  local min_expected_files="$2"
  local fixture_src="$SCRIPT_DIR/fixtures/$fixture_name"
  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-bootstrap-$fixture_name-XXXXXX")
  trap 'rm -rf "$work"' RETURN
  cp -R "$fixture_src/." "$work/"
  (cd "$work" && git init -q && git add -A && git -c user.email=e2e@test -c user.name=e2e commit -q -m init)

  echo ""
  echo "--- running /hydra:bootstrap-project against $fixture_name ---"

  (cd "$work" && claude -p "/hydra:bootstrap-project \"A demo app for e2e validation\" --yes --overwrite" 2>&1) || {
    _fail "$fixture_name: skill invocation exit 0"
    return 1
  }
  _pass "$fixture_name: skill invocation exit 0"

  # Bundle checks
  local got_docs
  got_docs=$(find "$work/docs" -maxdepth 2 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$got_docs" -ge "$min_expected_files" ]; then
    _pass "$fixture_name: >=$min_expected_files docs produced (got $got_docs)"
  else
    _fail "$fixture_name: too few docs" "expected >=$min_expected_files, got $got_docs"
  fi

  # No Hydra tokens anywhere in bundle
  local leaks
  leaks=$(grep -rinE '[Hh]ydra|HYDRA' "$work/docs" "$work/.claude" 2>/dev/null || true)
  if [ -z "$leaks" ]; then
    _pass "$fixture_name: no Hydra tokens leaked"
  else
    _fail "$fixture_name: Hydra tokens leaked" "$leaks"
  fi

  # Reviewer frontmatter is valid YAML
  local bad_fm=0
  while IFS= read -r f; do
    if ! awk 'BEGIN{state=0} /^---$/{state++; if(state==2){exit 0}} END{exit state==2?0:1}' "$f"; then
      bad_fm=$((bad_fm+1))
    fi
  done < <(find "$work/.claude/agents" -type f -name '*.md' 2>/dev/null)
  if [ "$bad_fm" -eq 0 ]; then
    _pass "$fixture_name: all reviewer frontmatter valid"
  else
    _fail "$fixture_name: $bad_fm reviewer(s) with bad frontmatter"
  fi
}

run_fixture "minimal-greenfield" 3    # PRD + TRD + test-plan at minimum
run_fixture "nextjs-brownfield"   4   # + at least one ADR

report_results
```

- [ ] **Step 4: Verify it runs (skipped or full depending on env)**

Run: `chmod +x tests/e2e/test-bootstrap-project.sh && bash tests/e2e/test-bootstrap-project.sh`

Expected behavior:
- If `claude` CLI is not installed: exits 0 with "SKIP" message.
- If it IS installed: runs both fixtures end-to-end (costs money — each fixture invokes Claude). For local development, the SKIP path is the default.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/fixtures tests/e2e/test-bootstrap-project.sh
git commit -m "test(bootstrap): add E2E test with greenfield + brownfield fixtures

Manual-dispatch E2E test that invokes /hydra:bootstrap-project via
'claude -p' against two fixture repos. Asserts minimum doc counts,
zero Hydra-token leakage, and valid reviewer YAML frontmatter.
Skips gracefully if claude CLI isn't present."
```

---

## Task 17: CI integration

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `.github/workflows/e2e-tests.yml`

- [ ] **Step 1: Inspect the existing workflows**

Run: `cat .github/workflows/test.yml .github/workflows/e2e-tests.yml`

Look at: how tests are invoked, what Ubuntu version, what shell, any prerequisites (jq install, etc.).

- [ ] **Step 2: Verify test.yml picks up new tests automatically**

`tests/run-tests.sh` iterates `test-*.sh`, so the new bootstrap tests are picked up without any workflow edit. The only risk is missing prerequisites (e.g., `jq`).

Open `.github/workflows/test.yml` and confirm a `jq` install step exists. If not, add:

```yaml
      - name: Install prerequisites
        run: sudo apt-get update && sudo apt-get install -y jq shellcheck
```

(Skip if already present.)

- [ ] **Step 3: Add E2E job entry**

Open `.github/workflows/e2e-tests.yml`. Find the job matrix or step list that invokes `tests/e2e/run-e2e.sh` (or individual `test-*-skill.sh` scripts). Add bootstrap-project:

If the workflow uses a matrix of test names:

```yaml
        test:
          - test-init-skill.sh
          - test-status-skill.sh
          - test-bootstrap-project.sh    # new
```

Otherwise add a step:

```yaml
      - name: Run bootstrap-project E2E
        run: bash tests/e2e/test-bootstrap-project.sh
```

- [ ] **Step 4: Run the tests locally to verify nothing regresses**

Run: `tests/run-tests.sh && bash tests/e2e/test-bootstrap-project.sh`
Expected: all pass (E2E may SKIP if no `claude` CLI).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/test.yml .github/workflows/e2e-tests.yml
git commit -m "ci: wire bootstrap-project tests into CI

Layer 1 and Layer 2 tests run automatically via tests/run-tests.sh.
Layer 3 E2E added to the manual-dispatch e2e-tests.yml workflow."
```

---

## Task 18: Documentation update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

Run: `grep -n '^#\|^##' README.md | head -30`

Find the section that documents available skills (likely "Skills" or "Commands" or similar).

- [ ] **Step 2: Add a subsection for `/hydra:bootstrap-project`**

Add this subsection in the skills list (place it near `/hydra:init` or `/hydra:gen-spec`):

```markdown
### `/hydra:bootstrap-project`

Generate a portable, Hydra-free project bundle — project docs (PRD, TRD, ADRs, test plan, optional migration plan) plus tailored Claude subagents — into standard paths (`./docs/`, `./docs/context/`, `./.claude/agents/`, `./.claude/`). The output works in any repo with Claude Code, without requiring Hydra to be installed.

- Usage: `/hydra:bootstrap-project [objective] [--yes] [--overwrite] [--dry-run] [--verbose]`
- Refuses to run if `./hydra/` already exists (use `/hydra:start` for Hydra-managed loops).
- Single-shot: no state machine, no loop machinery. Runs discovery → doc-generator → reviewer-instantiation → optional designer, transforms the output to strip Hydra references, and relocates atomically.
```

- [ ] **Step 3: Verify skill-docs freshness check still passes**

Run: `bash tests/test-skill-templates.sh`
Expected: PASS. This test validates that all skills are documented consistently.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document /hydra:bootstrap-project in README

One-paragraph entry in the skills list covering what it does, when
to use it, and how it differs from /hydra:start."
```

---

## Final Verification

- [ ] **Step 1: Run full test suite**

Run: `tests/run-tests.sh`
Expected: all tests pass (18 existing + 5 new bootstrap tests = 23+ files).

- [ ] **Step 2: Run shellcheck across new scripts**

Run:
```bash
shellcheck scripts/bootstrap-transform.sh \
           scripts/lib/bootstrap-scrub-map.sh \
           scripts/lib/bootstrap-render.sh \
           scripts/lib/bootstrap-preflight.sh \
           scripts/lib/bootstrap-relocate.sh
```
Expected: no errors.

- [ ] **Step 3: Verify skill is discoverable**

Run: `bash tests/test-frontmatter.sh && bash tests/test-skill-templates.sh`
Expected: both pass.

- [ ] **Step 4: Manual dry-run in a scratch directory** (optional but recommended)

```bash
WORK=$(mktemp -d)
cd "$WORK" && git init -q && echo "test" > README.md && git add README.md && git commit -q -m init
# Invoke the skill via claude -p (if available):
claude -p "/hydra:bootstrap-project \"sandbox manual test\" --dry-run --yes"
# Inspect $WORK/.bootstrap-scratch/
find "$WORK/.bootstrap-scratch" -type f | sort
# Verify no hydra tokens
grep -rinE '[Hh]ydra|HYDRA' "$WORK/.bootstrap-scratch" && echo "LEAK" || echo "CLEAN"
rm -rf "$WORK"
```

Expected: `CLEAN` printed, reasonable file count in scratch.

---

## Acceptance Criteria (from spec §Acceptance Criteria)

| # | Criterion | Verified by |
|---|---|---|
| 1 | `/hydra:bootstrap-project` is discoverable as a skill | Task 11 Step 4 (`test-skill-templates.sh`) |
| 2 | Running in a clean repo produces a complete bundle | Task 15 happy-path + Task 16 E2E |
| 3 | No output file contains any `/[Hh]ydra|HYDRA/` token | Task 5 final assertion + Task 15 `assert_file_not_contains` + Task 16 leak check |
| 4 | Running in a Hydra-initialized repo aborts with documented message | Task 9 `check_no_hydra_dir` + Task 15 pre-flight-abort assertion |
| 5 | Interrupting mid-run leaves scratch intact, `./docs/` + `./.claude/` untouched | Task 10 atomicity + Task 15 atomicity assertion |
| 6 | Layer 1 and Layer 2 tests pass in CI | Task 17 Step 2 |
| 7 | Layer 3 E2E tests pass on manual dispatch | Task 17 Step 3 |
