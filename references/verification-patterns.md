# Verification Patterns Reference

Generic verification patterns for detecting stubs, verifying wiring, and checking implementation substance. Used by `/hydra:verify` and reviewer agents.

---

## Core Principle

**Existence does not equal Implementation.**

Every artifact must pass through four verification levels before it can be considered complete:

| Level | Name | Description | Automatable |
|-------|------|-------------|-------------|
| 1 | **Exists** | File is present at the expected path | Yes |
| 2 | **Substantive** | Contains real implementation, not placeholders or stubs | Yes |
| 3 | **Wired** | Connected to the rest of the system (imported, routed, configured) | Yes |
| 4 | **Functional** | Actually works when invoked by a human | No |

Levels 1-3 can be verified programmatically. Level 4 requires human judgment and is flagged for manual verification when appropriate.

---

## Universal Stub Detection

Framework-agnostic patterns that identify incomplete implementations.

### Comment-Based Stubs

```bash
grep -E "(TODO|FIXME|XXX|HACK|PLACEHOLDER)" "$file"
```

Presence of these markers indicates acknowledged incomplete work.

### Empty Implementations

```bash
grep -E "return null|return undefined|return \{\}|return \[\]|pass$" "$file"
```

Functions that return empty or null values without any logic are likely stubs.

### Not-Implemented Markers

```bash
grep -E "raise NotImplementedError|throw.*not.?implemented" "$file" -i
```

Explicit declarations that functionality has not been built.

### Placeholder Text

```bash
grep -E "lorem ipsum|placeholder|coming soon|under construction" "$file" -i
```

Content placeholders left in place of real copy or data.

### Hardcoded Test Data

```bash
grep -E "\"test.*@.*\"|'test.*@.*'" "$file"
```

Hardcoded test emails or similar fake data embedded in production code.

---

## Wiring Verification Patterns

Patterns that confirm artifacts are connected to the rest of the system.

### Module A to Module B

Imports resolve AND are actually used. An import that appears only on the import line (count = 1) is dead code.

```bash
# Check that an imported symbol appears more than once in the file
symbol="MyComponent"
count=$(grep -c "$symbol" "$file" 2>/dev/null || echo 0)
[ "$count" -le 1 ] && echo "UNWIRED: $symbol imported but never used in $file"
```

### Handler to Data Layer

A route handler or controller should contain data operations (queries, reads, writes) and use the result in its response. A handler that returns static data is a stub.

```bash
# Handler should have data access AND response construction
grep -E "(find|query|select|insert|update|delete|save|fetch)" "$file"
grep -E "(res\.|response\.|return |render)" "$file"
```

### Config to Usage

A configuration key must be both defined in config and consumed in application code.

```bash
# Config key defined
grep -E "DATABASE_URL|API_KEY|PORT" config_file
# Config key consumed
grep -rE "DATABASE_URL|API_KEY|PORT" src/
```

### Form to Handler

A form's submit handler must exist AND contain real logic beyond just `preventDefault`.

```bash
# Check that onSubmit/handleSubmit has more than just event handling boilerplate
grep -A 10 "onSubmit\|handleSubmit" "$file" | grep -v "preventDefault" | grep -E "\w"
```

### State to Render

State variables must appear in the template, JSX, or render output. State that is set but never rendered is orphaned.

```bash
# Find state declarations and check they appear in render/return
state_var="count"
grep -c "$state_var" "$file"  # Should appear in both state init AND template
```

---

## Substantive Size Heuristics

Minimum line counts that indicate real implementation rather than boilerplate. These are lower bounds — files below these thresholds are flagged for review, not automatically failed.

| Artifact Type | Minimum Lines |
|---------------|---------------|
| Route handler | 10 |
| Component | 15 |
| Database model | 5 fields |
| Test file | 20 |
| Utility function | 5 |
| Config file | 3 entries |

These heuristics are starting points. Discovery may adjust thresholds based on the project's stack and conventions.

---

## Automated Verification Script Pattern

A reusable function that checks all three automatable verification levels:

```bash
check_artifact() {
  local file="$1"
  local min_lines="$2"
  local required_pattern="$3"

  # Level 1: Exists
  [ ! -f "$file" ] && echo "MISSING: $file" && return 1

  # Level 2: Substantive
  local lines=$(wc -l < "$file")
  local stubs=$(grep -c -E "TODO|FIXME|placeholder|not implemented" "$file" 2>/dev/null || echo 0)
  [ "$lines" -lt "$min_lines" ] && echo "THIN: $file ($lines lines)"
  [ "$stubs" -gt 0 ] && echo "STUBS: $file ($stubs stub patterns)"

  # Level 3: Wired (pattern present)
  local has_pattern=$(grep -c -E "$required_pattern" "$file" 2>/dev/null || echo 0)
  [ "$has_pattern" -eq 0 ] && echo "UNWIRED: $file (missing: $required_pattern)"

  echo "OK: $file"
}
```

### Usage Examples

```bash
# Verify a route handler is substantive and wired to the data layer
check_artifact "src/routes/users.ts" 10 "(find|query|select|insert)"

# Verify a React component is substantive and uses state or props
check_artifact "src/components/Dashboard.tsx" 15 "(useState|useEffect|props)"

# Verify a test file is substantive and has actual assertions
check_artifact "tests/users.test.ts" 20 "(expect|assert|should)"

# Verify a config file has real entries
check_artifact ".env.example" 3 "="
```

---

## Human Verification Triggers

These aspects cannot be verified programmatically. When any of the following apply, the review gate should flag the task for manual human verification:

- **Visual appearance** — Layout, spacing, color, typography correctness
- **User flow completion** — Multi-step workflows that require real interaction
- **Real-time behavior** — WebSocket connections, Server-Sent Events, live updates
- **External service integration** — Third-party API calls, OAuth flows, payment processing
- **Error message clarity** — Whether error messages make sense to end users
- **Performance feel** — Perceived responsiveness, animation smoothness, load times

When a task involves any of these, the reviewer should add a `HUMAN_VERIFY` flag to the review output with a description of what needs manual checking.

---

## Discovery-Generated Patterns

This reference provides the generic, framework-agnostic core of verification patterns.

At runtime, Discovery analyzes the project's detected stack and generates project-specific verification patterns into:

```
hydra/context/verification-patterns.md
```

Project-specific patterns may include:

- Framework-specific stub detection (e.g., Django `pass` in views, Express empty middleware)
- Stack-specific wiring checks (e.g., Redux action-to-reducer wiring, Next.js page-to-API routes)
- Custom size heuristics tuned to the project's conventions
- Additional required patterns based on the project's architecture

The generated file supplements (does not replace) this generic reference. Both are consulted during verification.
