---
name: {{reviewer_name}}
description: {{description}}
tools:
  - Read
  - Glob
  - Grep
  - Bash
# `tools:` (above) is the honored subagent allowlist; `allowed-tools:` is a
# SKILL field and is ignored on subagents, so it was removed. Reviewers keep
# Bash to run the project's test/lint commands; destructive commands are
# blocked by the PreToolUse guard (scripts/pre-tool-guard.sh). To hard-scope
# Bash to specific test commands, add rules to permissions.allow in settings.
maxTurns: 30
# {{^bundle_mode}}
hooks:
  SubagentStop:
    - hooks:
        - type: prompt
          prompt: "A reviewer subagent is trying to stop. Check if it has written its review file to nazgul/reviews/[TASK-ID]/[reviewer-name].md (inside a per-task subdirectory, NOT flat in nazgul/reviews/). The file MUST BEGIN with a YAML frontmatter block (as its first lines) containing `verdict: APPROVE` or `verdict: CHANGES_REQUESTED` and an integer `confidence:`. If no review file was written in the correct location, block and instruct the reviewer to create the nazgul/reviews/[TASK-ID]/ directory and write its review there. If the file exists but is missing the frontmatter block, or `verdict:` is not exactly one of `APPROVE` or `CHANGES_REQUESTED`, block and instruct the reviewer to add the canonical frontmatter block (verdict + integer confidence) at the very top of the file. $ARGUMENTS"
# {{/bundle_mode}}
---

<!--
Template conventions:
  {{placeholder}}                       — substitute at render
  {{#bundle_mode}}...{{/bundle_mode}}   — keep only when bundle_mode=true
  {{^bundle_mode}}...{{/bundle_mode}}   — keep only when bundle_mode is absent/false

Default is bundle_mode=false. Renderers MUST strip whichever branch does
not apply, including the {{#bundle_mode}} / {{^bundle_mode}} marker lines
themselves. The Nazgul discovery agent (which renders this template for
the standard loop) should strip {{#bundle_mode}}...{{/bundle_mode}} blocks
entirely and remove only the {{^bundle_mode}} / {{/bundle_mode}} marker
lines, keeping the inverse-branch content.
-->

# {{title}} Reviewer

## Project Context
<!-- Discovery fills this with: {{context_items}} -->

## What You Review
{{checklist}}

## How to Review
{{^bundle_mode}}
1. Read `nazgul/reviews/[TASK-ID]/diff.patch` FIRST — focus on what specifically changed
2. For each changed hunk, read the surrounding context in the full file if needed
{{/bundle_mode}}
{{#bundle_mode}}
1. Identify the changed files and diff from the current conversation or user request
2. Read each changed file in full if its diff is small; focus on the diff hunk otherwise
{{/bundle_mode}}
{{review_steps}}

## Output Format

For each finding:

### Finding: [Short description]
- **Severity**: HIGH | MEDIUM | LOW
- **Confidence**: [0-100]
- **File**: [file:line-range]
- **Category**: {{category}}
- **Verdict**: REJECT (confidence >= 80) | CONCERN (confidence < 80) | PASS
- **Issue**: [specific problem]
- **Fix**: [specific fix instruction]
- **Pattern reference**: [file:line showing correct pattern in this codebase]
- **Rule reference**: [LR-NNN if a Learned Rule from the injected "## Learned Rules" block applies to this finding, else none]

### Summary
- PASS: [items that pass]
- CONCERN: [non-blocking items] (confidence: N/100)
- REJECT: [blocking items] (confidence: N/100)

## Final Verdict

Begin your review file with a YAML frontmatter block as the FIRST lines of the file, then your narrative below it:

```yaml
---
verdict: APPROVE
confidence: 92
---
```

- `verdict: APPROVE` — {{approved_criteria}}
- `verdict: CHANGES_REQUESTED` — {{rejected_criteria}}

`verdict` MUST be exactly `APPROVE` or `CHANGES_REQUESTED`; `confidence` is an integer 0-100. Any other verdict value is rejected by the review-evidence gate and blocks the task.

{{^bundle_mode}}
Write your review to `nazgul/reviews/[TASK-ID]/{{reviewer_name}}.md`.
Create the directory `nazgul/reviews/[TASK-ID]/` first if it doesn't exist.
{{/bundle_mode}}
{{#bundle_mode}}
Return your review inline as your final message. Structure the output as shown above.
{{/bundle_mode}}
