---
name: nazgul:learn
description: Distill recurring mistakes into numbered, human-approved Learned Rules. Runs the learner agent, then presents each candidate for approve/edit/reject. Supports --dry-run and --retire.
context: fork
argument-hint: "[--dry-run] [--retire]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent
metadata:
  author: Jose Mejia
  version: 1.6.0
---

# Nazgul Learn

## Examples
- `/nazgul:learn` — distill mistakes, review candidates interactively
- `/nazgul:learn --dry-run` — show candidate rules, write nothing
- `/nazgul:learn --retire` — review un-cited rules for retirement

## Arguments
$ARGUMENTS

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`
- Learning enabled: !`jq -r '.learning.enabled // false' nazgul/config.json 2>/dev/null || echo "n/a"`
- Active rules: !`grep -c '^## LR-' nazgul/learning/learned-rules.md 2>/dev/null || echo 0`

## Instructions

### Pre-flight
1. If `nazgul/config.json` is missing: "Nazgul not initialized. Run `/nazgul:init` first." and STOP.
2. If `.learning.enabled` is not `true`: "Learning is disabled (`learning.enabled=false`). Enable it in nazgul/config.json to use this." and STOP.
3. Parse `$ARGUMENTS` for flags:
   - Backstop: if the `## Arguments` block above is *exactly* the literal token `$ARGUMENTS` (not substituted), STOP and report "Skill argument substitution failed — plugin bug, do not proceed."
   - `--dry-run` → distill and display candidates only; write nothing to the registry or declined log, and do NOT let the learner update `.last-run`.
   - `--retire` → run retirement-review mode (Step R) INSTEAD of distillation.
4. Ensure `nazgul/learning/` exists (`mkdir -p`).

### Display Banner
Output per references/ui-brand.md:
```
─── ◈ NAZGUL ▸ LEARNING ────────────────────────────────
```

### Step R: Retirement review (only if --retire)
1. Read the registry (`learning.rules_doc`). List ACTIVE rules whose **Hits** is 0,
   plus — if active-rule count exceeds `learning.max_active_rules` — the lowest-Hits rules.
2. For each, show LR-NNN + title + Hits + Added, and ask: retire? (y/n).
3. On yes: edit that rule's `- **Status**:` line to `retired` (keep the rule in the
   file; never delete, never renumber).
4. Summarize how many were retired. STOP (do not distill in --retire mode).

### Step 1: Distill
Dispatch the learner agent with the Agent tool, `subagent_type: "nazgul:learner"`.
It reads mistake artifacts and writes `nazgul/learning/proposed-rules.md`.
(For `--dry-run`, tell the learner in the prompt NOT to update `.last-run`.)

### Step 2: Interactive approval
Read `nazgul/learning/proposed-rules.md`. If it has no `## CANDIDATE` sections,
say "No recurring mistakes met the threshold — nothing to propose." and STOP.

For EACH candidate, one at a time:
1. Display: title, Scope-Agents, Scope-Globs, Confidence, Evidence, Dedup, and the body.
2. Ask: **approve / edit / reject**.
   - **approve**:
     - Get the next id: `scripts/lib/learned-rules.sh next-id` (uses the default
       registry path, or pass `--doc <rules_doc>` if config overrides it).
     - Append the rule to the registry file (`learning.rules_doc`) as a
       `## LR-NNN: <title>` block with metadata lines in this exact order:
       Status (active), Scope-Agents, Scope-Globs, Hits (0), Added
       (`date -u +%Y-%m-%d`), Evidence — then the body. (For dry-run: skip writing.)
   - **edit**: let the user revise title/scope/body, then approve as above.
   - **reject** (skip writing for dry-run): append one JSON line to
     `nazgul/learning/declined.jsonl`:
     `{"fingerprint":"<id>","reason":"<reason>","ts":"<iso8601>"}` where `<id>` is
     `scripts/lib/learned-rules.sh fingerprint "$(printf '%s\n%s' "<candidate title>" "<candidate body>")"` —
     title, newline, body — identical to how the learner computes it to skip declined candidates.
3. After the last candidate, delete `proposed-rules.md` (it is transient).

### Step 3: Complete
Show a Next Up block per ui-brand.md summarizing: N approved (with the new LR
numbers), N rejected, N skipped. For dry-run, label clearly "DRY RUN — nothing written."
