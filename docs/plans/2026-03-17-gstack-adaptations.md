# gstack Adaptations for Hydra — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Adapt the most valuable patterns from [garrytan/gstack](https://github.com/garrytan/gstack) into Hydra to improve review intelligence, testing rigor, skill maintainability, and self-improvement capabilities.

**Architecture:** Five independent enhancements, each self-contained. Fix-First Review upgrades the review-gate agent. E2E testing adds a `claude -p` test harness. Skill template generation adds a build step with CI freshness checks. Self-improvement mode adds a contributor logging system. Session tracking adds concurrent-session awareness to the session-context hook.

**Tech Stack:** Bash (POSIX), jq, Claude Code CLI (`claude -p`), GitHub Actions

---

## Analysis: What gstack Does Well That Hydra Should Adopt

| gstack Pattern | Hydra Gap | Priority | Effort |
|---|---|---|---|
| **Fix-First Review** — auto-fix mechanical issues, only ASK on risky ones | Review gate reports ALL findings equally; implementer must fix everything manually | P0 | M |
| **3-Tier Test Architecture** — static, E2E via `claude -p`, LLM-as-judge | Only shell script unit/integration tests; no E2E skill testing | P1 | L |
| **SKILL.md Template System** — `.tmpl` files + placeholder resolution + CI freshness | Skills are hand-edited; no drift detection between shared content | P1 | M |
| **Self-Improvement Mode** — agent self-rates experience, files field reports | No feedback loop on plugin quality from actual usage | P2 | S |
| **Session Tracking** — filesystem-based concurrent session detection | No awareness of concurrent Hydra sessions; potential state corruption | P2 | S |

---

### Task 1: Fix-First Review Heuristic in Review Gate

Adapt gstack's AUTO-FIX vs ASK classification so the review gate auto-applies mechanical fixes before asking about risky ones. This is the highest-impact change — it reduces review-implement round-trips.

**Files:**
- Modify: `agents/review-gate.md` — add fix-first classification logic after reviewer verdicts
- Modify: `agents/feedback-aggregator.md` — classify findings as AUTO-FIX or ASK
- Create: `references/fix-first-heuristic.md` — shared reference for classification rules
- Test: `tests/test-fix-first-classification.sh` — validate classification logic

**Step 1: Write the classification reference doc**

Create `references/fix-first-heuristic.md`:

```markdown
# Fix-First Review Heuristic

When consolidating reviewer feedback, classify each finding into one of two categories:

## AUTO-FIX (apply without asking)
- Dead code removal (unused imports, variables, functions)
- Missing error handling on internal calls (not API boundaries)
- Style violations (naming, formatting, whitespace)
- Stale comments that reference removed code
- Missing type annotations on internal functions
- Trivial N+1 query fixes (add `.select_related`/`.includes`)
- Import ordering
- Duplicate code that was just introduced in this task

## ASK (batch into single question to user/implementer)
- Security findings (any severity)
- Race conditions or concurrency issues
- Design/architecture decisions
- API contract changes
- Database schema changes
- Removal of functionality (even if reviewer says it's dead)
- Performance changes that alter algorithmic complexity
- Changes to public interfaces

## Classification Rules
1. Default to ASK if uncertain
2. Security findings are ALWAYS ASK, regardless of confidence
3. AUTO-FIX items must be independently correct (fixing one doesn't break another)
4. In AFK/YOLO mode: AUTO-FIX items are applied automatically; ASK items with severity < HIGH are applied, HIGH+ items BLOCK the task
5. In HITL mode: AUTO-FIX items are applied automatically; ASK items are presented to user
```

**Step 2: Write the failing test**

Create `tests/test-fix-first-classification.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== Fix-First Classification Tests ==="

# Test 1: Classification reference exists and has required sections
test_classification_reference_exists() {
  local ref_file="$SCRIPT_DIR/../references/fix-first-heuristic.md"
  assert_file_exists "$ref_file"

  local content
  content=$(cat "$ref_file")
  assert_contains "$content" "AUTO-FIX"
  assert_contains "$content" "ASK"
  assert_contains "$content" "Classification Rules"
  assert_contains "$content" "Security findings are ALWAYS ASK"
}

# Test 2: Review gate references fix-first heuristic
test_review_gate_references_fix_first() {
  local gate_file="$SCRIPT_DIR/../agents/review-gate.md"
  local content
  content=$(cat "$gate_file")
  assert_contains "$content" "fix-first"
}

# Test 3: Feedback aggregator references fix-first heuristic
test_feedback_aggregator_references_fix_first() {
  local agg_file="$SCRIPT_DIR/../agents/feedback-aggregator.md"
  local content
  content=$(cat "$agg_file")
  assert_contains "$content" "AUTO-FIX"
  assert_contains "$content" "ASK"
}

run_test test_classification_reference_exists
run_test test_review_gate_references_fix_first
run_test test_feedback_aggregator_references_fix_first

echo ""
echo "Fix-First Classification: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

**Step 3: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=fix-first`
Expected: FAIL — reference file doesn't exist, agents don't reference fix-first

**Step 4: Update feedback-aggregator.md to classify findings**

Modify `agents/feedback-aggregator.md` — add a new section after the existing consolidation logic:

```markdown
## Fix-First Classification

After consolidating all reviewer findings, classify each finding using `references/fix-first-heuristic.md`:

### Output Format

Write the consolidated feedback to `hydra/reviews/[TASK-ID]/consolidated.md` with findings grouped:

#### AUTO-FIX Items
For each: file path, line range, what to change, which reviewer flagged it.
These will be applied automatically by the implementer without discussion.

#### ASK Items
For each: file path, description, severity, confidence, which reviewer flagged it, why it requires human/implementer judgment.
These will be batched into a single decision point.

Classify conservatively — when in doubt, mark as ASK.
```

**Step 5: Update review-gate.md to handle fix-first flow**

Add a new step between Step 3 (Determine Verdict) and Step 4 (Handle Results) in `agents/review-gate.md`:

```markdown
### Step 3.75: Fix-First Auto-Remediation

When verdict is CHANGES_REQUESTED and feedback-aggregator has classified findings:

1. Read `hydra/reviews/[TASK-ID]/consolidated.md`
2. Count AUTO-FIX vs ASK items
3. If AUTO-FIX items exist:
   a. Log: "Applying N auto-fix items from reviewer feedback"
   b. Set task back to IN_PROGRESS
   c. Delegate to implementer with ONLY the AUTO-FIX items
   d. After implementer completes: re-run pre-checks (tests, lint)
   e. If pre-checks pass AND no ASK items remain: re-submit for review (skip re-review, mark DONE)
   f. If pre-checks pass AND ASK items remain: present ASK items per mode (HITL → ask user, AFK → apply if < HIGH, YOLO → apply all non-security)
   g. If pre-checks fail: full retry cycle as normal
4. If only ASK items: proceed to Step 4 as normal (CHANGES_REQUESTED flow)

This reduces review round-trips by fixing obvious issues without re-entering the full review cycle.
```

**Step 6: Run test to verify it passes**

Run: `tests/run-tests.sh --filter=fix-first`
Expected: PASS

**Step 7: Commit**

```bash
git add references/fix-first-heuristic.md agents/review-gate.md agents/feedback-aggregator.md tests/test-fix-first-classification.sh
git commit -m "feat: add fix-first review heuristic — auto-fix mechanical issues, ask on risky ones"
```

---

### Task 2: E2E Skill Testing via `claude -p`

Adapt gstack's E2E test architecture to validate Hydra skills end-to-end by spawning `claude -p` subprocesses. This catches regressions that static tests miss.

**Files:**
- Create: `tests/e2e/run-e2e.sh` — E2E test runner
- Create: `tests/e2e/test-status-skill.sh` — E2E test for `/hydra:status`
- Create: `tests/e2e/test-init-skill.sh` — E2E test for `/hydra:init`
- Create: `tests/e2e/lib/session-runner.sh` — Bash wrapper around `claude -p`
- Modify: `.github/workflows/skill-docs.yml` — add E2E test job (manual trigger only, costs money)

**Step 1: Write the session runner library**

Create `tests/e2e/lib/session-runner.sh`:

```bash
#!/usr/bin/env bash
# Session runner — spawns claude -p for E2E skill testing
# Adapted from gstack's session-runner pattern
#
# Usage: run_skill_session "/hydra:status" 30 output_var

set -euo pipefail

run_skill_session() {
  local skill_command="$1"
  local timeout_seconds="${2:-60}"
  local output_file
  output_file=$(mktemp)

  echo "[e2e] Running: claude -p \"$skill_command\" (timeout: ${timeout_seconds}s)"

  if timeout "$timeout_seconds" claude -p "$skill_command" \
    --output-format text \
    --max-turns 5 \
    > "$output_file" 2>&1; then
    echo "[e2e] Session completed successfully"
  else
    local exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      echo "[e2e] Session timed out after ${timeout_seconds}s"
    else
      echo "[e2e] Session exited with code $exit_code"
    fi
  fi

  cat "$output_file"
  rm -f "$output_file"
}

# Assert output contains expected string
assert_output_contains() {
  local output="$1"
  local expected="$2"
  local description="${3:-}"

  if echo "$output" | grep -q "$expected"; then
    echo "  PASS: $description"
    return 0
  else
    echo "  FAIL: $description"
    echo "  Expected to find: $expected"
    echo "  In output: $(echo "$output" | head -20)"
    return 1
  fi
}
```

**Step 2: Write E2E test for /hydra:status**

Create `tests/e2e/test-status-skill.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/session-runner.sh"

echo "=== E2E: /hydra:status ==="

# Setup: create a minimal hydra runtime dir
TEMP_PROJECT=$(mktemp -d)
trap 'rm -rf "$TEMP_PROJECT"' EXIT

cd "$TEMP_PROJECT"
git init -q
mkdir -p hydra/tasks hydra/checkpoints

# Create minimal config
cat > hydra/config.json <<'CONF'
{
  "schema_version": 5,
  "mode": "hitl",
  "objective": "E2E test objective",
  "max_iterations": 10,
  "current_iteration": 3,
  "agents": { "reviewers": ["code-reviewer"] }
}
CONF

# Create minimal plan
cat > hydra/plan.md <<'PLAN'
# Plan
## Recovery Pointer
- **Current Task:** TASK-001
- **Last Action:** Testing
## Tasks
- TASK-001: Test task [IN_PROGRESS]
PLAN

# Run the skill
OUTPUT=$(run_skill_session "/hydra:status" 45)

# Validate output contains expected elements
PASSED=0
FAILED=0

assert_output_contains "$OUTPUT" "HYDRA" "Shows Hydra branding" && ((PASSED++)) || ((FAILED++))
assert_output_contains "$OUTPUT" "iteration" "Shows iteration info" && ((PASSED++)) || ((FAILED++))

echo ""
echo "E2E /hydra:status: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

**Step 3: Write the E2E runner**

Create `tests/e2e/run-e2e.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "================================"
echo "  Hydra E2E Test Suite"
echo "  WARNING: These tests call"
echo "  claude -p and cost money."
echo "================================"
echo ""

# Verify claude CLI is available
if ! command -v claude &>/dev/null; then
  echo "SKIP: claude CLI not found. E2E tests require Claude Code."
  exit 0
fi

TOTAL=0
PASSED=0
FAILED=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  TOTAL=$((TOTAL + 1))
  name=$(basename "$test_file" .sh)
  echo "--- $name ---"
  if bash "$test_file"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "================================"
echo "E2E Results: $PASSED/$TOTAL passed"
[ "$FAILED" -eq 0 ]
```

**Step 4: Run test to verify it fails (no claude in CI)**

Run: `bash tests/e2e/run-e2e.sh`
Expected: Either runs locally if `claude` is available, or SKIPs gracefully

**Step 5: Add CI workflow for E2E (manual trigger)**

Modify `.github/workflows/skill-docs.yml` or create `.github/workflows/e2e-tests.yml`:

```yaml
name: E2E Skill Tests
on:
  workflow_dispatch:
    inputs:
      test_filter:
        description: 'Test file filter (e.g., status)'
        required: false
        default: ''

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code
      - name: Run E2E tests
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: bash tests/e2e/run-e2e.sh
```

**Step 6: Commit**

```bash
git add tests/e2e/ .github/workflows/e2e-tests.yml
git commit -m "feat: add E2E skill test harness via claude -p"
```

---

### Task 3: SKILL.md Template System with CI Freshness

Adapt gstack's `.tmpl` + placeholder resolution pattern so shared content across Hydra skills stays in sync, with CI to catch drift.

**Files:**
- Create: `scripts/gen-skill-docs.sh` — template processor (Bash + sed)
- Create: `templates/skill-partials/preamble.md` — shared preamble partial
- Create: `templates/skill-partials/recovery-protocol.md` — shared recovery protocol partial
- Modify: `.github/workflows/skill-docs.yml` — add freshness check
- Test: `tests/test-skill-templates.sh` — validate partials exist and are referenced

**Step 1: Write the failing test**

Create `tests/test-skill-templates.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== Skill Template Tests ==="

# Test 1: Template processor exists and is executable
test_gen_skill_docs_exists() {
  local script="$SCRIPT_DIR/../scripts/gen-skill-docs.sh"
  assert_file_exists "$script"
  [ -x "$script" ] || { echo "FAIL: gen-skill-docs.sh not executable"; return 1; }
}

# Test 2: Preamble partial exists
test_preamble_partial_exists() {
  assert_file_exists "$SCRIPT_DIR/../templates/skill-partials/preamble.md"
}

# Test 3: Recovery protocol partial exists
test_recovery_partial_exists() {
  assert_file_exists "$SCRIPT_DIR/../templates/skill-partials/recovery-protocol.md"
}

# Test 4: Gen script produces valid output (dry run)
test_gen_dry_run() {
  local script="$SCRIPT_DIR/../scripts/gen-skill-docs.sh"
  local output
  output=$("$script" --dry-run 2>&1) || true
  # Should not error out
  assert_contains "$output" "partial"
}

run_test test_gen_skill_docs_exists
run_test test_preamble_partial_exists
run_test test_recovery_partial_exists
run_test test_gen_dry_run

echo ""
echo "Skill Templates: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

**Step 2: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=skill-template`
Expected: FAIL — files don't exist yet

**Step 3: Create the shared partials**

Create `templates/skill-partials/preamble.md` — extract the common preamble shared across skills (recovery protocol reference, output formatting reference, session context):

```markdown
## Standard Preamble

### Output Formatting
Format ALL user-facing output per `references/ui-brand.md`:
- Stage banners: `─── ◈ HYDRA ▸ STAGE_NAME ─────────────────────────────`
- Status symbols: ◆ active, ◇ pending, ✦ complete, ✗ failed, ⚠ warning
- Never use emoji — only the defined symbols

### Recovery Protocol
Follow RULES.md Section 4 (Recovery Protocol). Read files 1-4 in the specified order before doing ANY work. Never rely on conversational memory — files are truth.
```

Create `templates/skill-partials/recovery-protocol.md`:

```markdown
## Recovery Protocol

1. Read `hydra/config.json` — mode, iteration, objective, agents
2. Read `hydra/plan.md` — Recovery Pointer (current task, last action, next action)
3. Read active task manifest if one exists
4. Read latest checkpoint if recovering from interruption

**Files are truth.** Never assume state from conversation context.
```

**Step 4: Write the template processor**

Create `scripts/gen-skill-docs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# gen-skill-docs.sh — resolves {{PARTIAL:name}} placeholders in SKILL.md.tmpl files
# Usage:
#   scripts/gen-skill-docs.sh              # Generate all SKILL.md from .tmpl
#   scripts/gen-skill-docs.sh --dry-run    # Show what would change without writing
#   scripts/gen-skill-docs.sh --check      # Exit 1 if any SKILL.md is stale

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTIALS_DIR="$ROOT_DIR/templates/skill-partials"
DRY_RUN=false
CHECK_MODE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check) CHECK_MODE=true ;;
  esac
done

STALE=0

# Find all .tmpl files
while IFS= read -r tmpl_file; do
  [ -f "$tmpl_file" ] || continue
  target="${tmpl_file%.tmpl}"
  result=$(cat "$tmpl_file")

  # Replace {{PARTIAL:name}} with contents of templates/skill-partials/name.md
  while [[ "$result" =~ \{\{PARTIAL:([a-zA-Z0-9_-]+)\}\} ]]; do
    partial_name="${BASH_REMATCH[1]}"
    partial_file="$PARTIALS_DIR/${partial_name}.md"
    if [ -f "$partial_file" ]; then
      partial_content=$(cat "$partial_file")
      result="${result//\{\{PARTIAL:$partial_name\}\}/$partial_content}"
    else
      echo "WARNING: partial not found: $partial_file"
      break
    fi
  done

  if $CHECK_MODE; then
    if [ -f "$target" ]; then
      if ! diff -q <(echo "$result") "$target" >/dev/null 2>&1; then
        echo "STALE: $target (regenerate with scripts/gen-skill-docs.sh)"
        STALE=$((STALE + 1))
      fi
    else
      echo "MISSING: $target"
      STALE=$((STALE + 1))
    fi
  elif $DRY_RUN; then
    echo "Would generate: $target from $tmpl_file (partials resolved)"
  else
    echo "$result" > "$target"
    echo "Generated: $target"
  fi
done < <(find "$ROOT_DIR/skills" -name "SKILL.md.tmpl" 2>/dev/null)

if $CHECK_MODE && [ "$STALE" -gt 0 ]; then
  echo ""
  echo "$STALE stale SKILL.md file(s) detected. Run: scripts/gen-skill-docs.sh"
  exit 1
fi

if $DRY_RUN || $CHECK_MODE; then
  echo "Partials available in $PARTIALS_DIR:"
  ls "$PARTIALS_DIR"/*.md 2>/dev/null | while read -r f; do echo "  - $(basename "$f" .md)"; done
fi
```

**Step 5: Run test to verify it passes**

Run: `tests/run-tests.sh --filter=skill-template`
Expected: PASS

**Step 6: Add CI freshness check**

Create/update `.github/workflows/skill-docs.yml`:

```yaml
name: Skill Docs Freshness
on:
  pull_request:
    paths:
      - 'skills/**'
      - 'templates/skill-partials/**'
      - 'scripts/gen-skill-docs.sh'

jobs:
  freshness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check SKILL.md freshness
        run: |
          chmod +x scripts/gen-skill-docs.sh
          scripts/gen-skill-docs.sh --check
```

**Step 7: Commit**

```bash
git add scripts/gen-skill-docs.sh templates/skill-partials/ tests/test-skill-templates.sh .github/workflows/skill-docs.yml
git commit -m "feat: add skill template system with partial resolution and CI freshness"
```

---

### Task 4: Self-Improvement Mode (Contributor Logging)

Adapt gstack's contributor mode so Hydra agents can self-rate and file improvement reports during loop execution.

**Files:**
- Create: `references/self-improvement.md` — self-rating protocol
- Create: `scripts/file-improvement-report.sh` — write structured report to disk
- Modify: `agents/implementer.md` — add optional self-rating at task completion
- Test: `tests/test-self-improvement.sh` — validate report structure

**Step 1: Write the failing test**

Create `tests/test-self-improvement.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== Self-Improvement Tests ==="

# Test 1: Reference doc exists
test_self_improvement_reference_exists() {
  assert_file_exists "$SCRIPT_DIR/../references/self-improvement.md"
}

# Test 2: Report script exists and is executable
test_report_script_exists() {
  local script="$SCRIPT_DIR/../scripts/file-improvement-report.sh"
  assert_file_exists "$script"
  [ -x "$script" ] || { echo "FAIL: not executable"; return 1; }
}

# Test 3: Report script produces valid JSON
test_report_script_output() {
  local script="$SCRIPT_DIR/../scripts/file-improvement-report.sh"
  setup_temp_dir
  local output_dir="$TEMP_DIR/reports"
  mkdir -p "$output_dir"

  "$script" \
    --task "TASK-001" \
    --agent "implementer" \
    --rating 7 \
    --summary "Test report" \
    --output-dir "$output_dir" 2>/dev/null

  local report_file
  report_file=$(ls "$output_dir"/*.json 2>/dev/null | head -1)
  [ -n "$report_file" ] || { echo "FAIL: no report file created"; return 1; }

  # Validate JSON structure
  jq -e '.task' "$report_file" >/dev/null || { echo "FAIL: missing .task field"; return 1; }
  jq -e '.rating' "$report_file" >/dev/null || { echo "FAIL: missing .rating field"; return 1; }
  jq -e '.agent' "$report_file" >/dev/null || { echo "FAIL: missing .agent field"; return 1; }
}

run_test test_self_improvement_reference_exists
run_test test_report_script_exists
run_test test_report_script_output

echo ""
echo "Self-Improvement: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

**Step 2: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=self-improvement`
Expected: FAIL

**Step 3: Create the reference doc**

Create `references/self-improvement.md`:

```markdown
# Self-Improvement Mode

Adapted from gstack's contributor mode. When enabled, agents rate their own experience and file improvement reports.

## When to File a Report

At the end of each task implementation, the implementer rates the experience 0-10:

- **9-10:** Everything worked perfectly, no report needed
- **7-8:** Minor friction, file report only if the fix is obvious
- **5-6:** Significant friction, file report with details
- **0-4:** Major blocker or failure, always file report

**Calibration bar:** Only file if the issue is as consequential as a missing safety guard or a skill that gives wrong instructions. Don't file for one-off weirdness.

## Report Structure

```json
{
  "task": "TASK-NNN",
  "agent": "implementer|review-gate|planner",
  "rating": 7,
  "timestamp": "2026-03-17T10:30:00Z",
  "summary": "One sentence",
  "what_happened": "Description of the friction point",
  "repro_steps": ["step 1", "step 2"],
  "what_would_make_it_a_10": "Specific improvement suggestion"
}
```

## Report Storage

Reports are written to `hydra/improvement-reports/` in the project runtime directory. The `/hydra:metrics` skill aggregates these for trend analysis.

## Opt-In

Self-improvement mode is enabled via `hydra/config.json`:
```json
{ "self_improvement": { "enabled": true, "threshold": 7 } }
```

Only agents with ratings below the threshold file reports.
```

**Step 4: Create the report script**

Create `scripts/file-improvement-report.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# file-improvement-report.sh — write a structured self-improvement report
# Usage: scripts/file-improvement-report.sh --task TASK-001 --agent implementer --rating 7 --summary "..." [--output-dir path]

TASK=""
AGENT=""
RATING=""
SUMMARY=""
OUTPUT_DIR="hydra/improvement-reports"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --rating) RATING="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$TASK" ] || [ -z "$AGENT" ] || [ -z "$RATING" ] || [ -z "$SUMMARY" ]; then
  echo "Usage: $0 --task TASK-NNN --agent NAME --rating N --summary 'text'" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILENAME="${OUTPUT_DIR}/${TIMESTAMP//[:.]/-}_${TASK}_${AGENT}.json"

jq -n \
  --arg task "$TASK" \
  --arg agent "$AGENT" \
  --argjson rating "$RATING" \
  --arg timestamp "$TIMESTAMP" \
  --arg summary "$SUMMARY" \
  '{task: $task, agent: $agent, rating: $rating, timestamp: $timestamp, summary: $summary, what_happened: "", repro_steps: [], what_would_make_it_a_10: ""}' \
  > "$FILENAME"

echo "Report filed: $FILENAME"
```

**Step 5: Make script executable and run tests**

```bash
chmod +x scripts/file-improvement-report.sh
```

Run: `tests/run-tests.sh --filter=self-improvement`
Expected: PASS

**Step 6: Commit**

```bash
git add references/self-improvement.md scripts/file-improvement-report.sh tests/test-self-improvement.sh
git commit -m "feat: add self-improvement mode — agents self-rate and file improvement reports"
```

---

### Task 5: Concurrent Session Tracking

Adapt gstack's filesystem-based session tracking so Hydra detects when multiple sessions target the same project, preventing state corruption.

**Files:**
- Modify: `scripts/session-context.sh` — add session lock file management
- Create: `scripts/lib/session-tracker.sh` — shared session tracking functions
- Modify: `scripts/stop-hook.sh` — clean up session lock on exit
- Test: `tests/test-session-tracker.sh` — validate lock creation/cleanup/detection

**Step 1: Write the failing test**

Create `tests/test-session-tracker.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== Session Tracker Tests ==="

# Source the tracker
source "$SCRIPT_DIR/../scripts/lib/session-tracker.sh"

# Test 1: Register creates a lock file
test_register_session() {
  setup_temp_dir
  local sessions_dir="$TEMP_DIR/sessions"

  register_session "test-session-1" "$sessions_dir"
  local count
  count=$(ls "$sessions_dir"/*.lock 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$count" "1"
}

# Test 2: Detect concurrent sessions
test_detect_concurrent() {
  setup_temp_dir
  local sessions_dir="$TEMP_DIR/sessions"

  register_session "session-a" "$sessions_dir"
  register_session "session-b" "$sessions_dir"

  local count
  count=$(count_active_sessions "$sessions_dir")
  assert_eq "$count" "2"
}

# Test 3: Unregister removes lock file
test_unregister_session() {
  setup_temp_dir
  local sessions_dir="$TEMP_DIR/sessions"

  register_session "session-x" "$sessions_dir"
  unregister_session "session-x" "$sessions_dir"

  local count
  count=$(count_active_sessions "$sessions_dir")
  assert_eq "$count" "0"
}

# Test 4: Stale sessions (older than 2 hours) are cleaned up
test_stale_cleanup() {
  setup_temp_dir
  local sessions_dir="$TEMP_DIR/sessions"
  mkdir -p "$sessions_dir"

  # Create a fake stale lock
  echo '{"pid": 99999, "started": "2026-03-17T01:00:00Z"}' > "$sessions_dir/stale.lock"
  # Backdate it
  touch -t 202603170100 "$sessions_dir/stale.lock"

  cleanup_stale_sessions "$sessions_dir" 7200

  local count
  count=$(ls "$sessions_dir"/*.lock 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$count" "0"
}

run_test test_register_session
run_test test_detect_concurrent
run_test test_unregister_session
run_test test_stale_cleanup

echo ""
echo "Session Tracker: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

**Step 2: Run test to verify it fails**

Run: `tests/run-tests.sh --filter=session-tracker`
Expected: FAIL — lib/session-tracker.sh doesn't exist

**Step 3: Write the session tracker library**

Create `scripts/lib/session-tracker.sh`:

```bash
#!/usr/bin/env bash
# session-tracker.sh — filesystem-based concurrent session detection
# Adapted from gstack's session tracking pattern

register_session() {
  local session_id="$1"
  local sessions_dir="${2:-hydra/sessions}"
  mkdir -p "$sessions_dir"

  jq -n \
    --arg pid "$$" \
    --arg session "$session_id" \
    --arg started "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{pid: $pid, session: $session, started: $started}' \
    > "$sessions_dir/${session_id}.lock"
}

unregister_session() {
  local session_id="$1"
  local sessions_dir="${2:-hydra/sessions}"
  rm -f "$sessions_dir/${session_id}.lock"
}

count_active_sessions() {
  local sessions_dir="${1:-hydra/sessions}"
  local count=0
  if [ -d "$sessions_dir" ]; then
    count=$(ls "$sessions_dir"/*.lock 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "$count"
}

cleanup_stale_sessions() {
  local sessions_dir="${1:-hydra/sessions}"
  local max_age_seconds="${2:-7200}"  # 2 hours default

  [ -d "$sessions_dir" ] || return 0

  local now
  now=$(date +%s)

  for lock_file in "$sessions_dir"/*.lock; do
    [ -f "$lock_file" ] || continue
    local file_age
    file_age=$(stat -f %m "$lock_file" 2>/dev/null || stat -c %Y "$lock_file" 2>/dev/null || echo 0)
    local age=$((now - file_age))
    if [ "$age" -gt "$max_age_seconds" ]; then
      rm -f "$lock_file"
    fi
  done
}

is_concurrent_session_warning() {
  local sessions_dir="${1:-hydra/sessions}"
  local count
  count=$(count_active_sessions "$sessions_dir")
  if [ "$count" -gt 1 ]; then
    echo "⚠ WARNING: $count concurrent Hydra sessions detected. State corruption risk."
    return 0
  fi
  return 1
}
```

**Step 4: Run test to verify it passes**

Run: `tests/run-tests.sh --filter=session-tracker`
Expected: PASS

**Step 5: Integrate into session-context.sh and stop-hook.sh**

Add to `scripts/session-context.sh` near the top (after sourcing):
```bash
# Session tracking
source "$(dirname "$0")/lib/session-tracker.sh"
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)-$$}"
register_session "$SESSION_ID" "hydra/sessions"
cleanup_stale_sessions "hydra/sessions"
if is_concurrent_session_warning "hydra/sessions"; then
  echo "⚠ Multiple Hydra sessions active. Proceed with caution."
fi
```

Add to `scripts/stop-hook.sh` cleanup section:
```bash
# Clean up session lock
source "$(dirname "$0")/lib/session-tracker.sh"
unregister_session "${CLAUDE_SESSION_ID:-unknown}" "hydra/sessions"
```

**Step 6: Run all tests**

Run: `tests/run-tests.sh`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add scripts/lib/session-tracker.sh scripts/session-context.sh scripts/stop-hook.sh tests/test-session-tracker.sh
git commit -m "feat: add concurrent session tracking — detect and warn on multiple active sessions"
```

---

## Summary

| Task | What It Adapts from gstack | Impact |
|---|---|---|
| 1. Fix-First Review | AUTO-FIX vs ASK classification | Fewer review round-trips, faster loop completion |
| 2. E2E Skill Tests | `claude -p` test harness | Catch skill regressions that static tests miss |
| 3. Skill Templates | `.tmpl` + placeholder resolution + CI | Prevent skill doc drift, enforce shared content |
| 4. Self-Improvement | Contributor mode / field reports | Continuous plugin quality feedback loop |
| 5. Session Tracking | Filesystem session locks | Prevent state corruption from concurrent usage |

**Patterns explicitly NOT adopted (and why):**
- **Headless browser** — Hydra is a dev loop, not a QA tool; no browser testing needed
- **Greptile integration** — Hydra has its own review board; external review triage is out of scope
- **Retro/analytics** — `/hydra:metrics` already covers this; gstack's `/retro` is git-log-focused which is a different use case
- **Design consultation** — Hydra already has a designer agent + frontend-dev specialist
