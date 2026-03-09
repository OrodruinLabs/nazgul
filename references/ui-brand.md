# Hydra UI Brand Reference

Visual identity and output formatting standards for all Hydra agents and skills. Every agent MUST follow these conventions to maintain a consistent, professional output experience.

---

## 1. Stage Banners

Stage transition headers mark major pipeline phases. Use the exact format below — consistent width, uppercase stage name, `HYDRA` prefix.

```
─── ◈ HYDRA ▸ DISCOVERING ─────────────────────────────
─── ◈ HYDRA ▸ PLANNING ────────────────────────────────
─── ◈ HYDRA ▸ IMPLEMENTING ────────────────────────────
─── ◈ HYDRA ▸ REVIEWING ───────────────────────────────
─── ◈ HYDRA ▸ VERIFYING ───────────────────────────────
─── ◈ HYDRA ▸ PATCHING ────────────────────────────────
─── ◈ HYDRA ▸ COMPLETE ✦ ──────────────────────────────
```

Rules:
- Stage names are always UPPERCASE.
- The `◈ HYDRA ▸` prefix is mandatory on every banner.
- Pad the trailing `─` characters to maintain consistent width (~55 characters total).
- The COMPLETE banner appends `✦` to signal final success.

---

## 2. Status Symbols

| Symbol | Meaning                    | Usage                                      |
|--------|----------------------------|---------------------------------------------|
| `◈`    | Hydra primary              | Banners and top-level headers only          |
| `◆`    | Active / In Progress       | Currently executing tasks or agents         |
| `◇`    | Pending / Waiting          | Queued tasks, agents not yet started        |
| `✦`    | Complete / Approved        | Finished tasks, approved reviews            |
| `✧`    | Skipped / Non-blocking     | Warnings that do not block progress         |
| `✗`    | Failed / Rejected          | Blocking failures, rejected reviews         |
| `⚠`    | Warning / Non-blocking     | Issues that deserve attention but not gates  |

These symbols replace all emoji usage. Do not mix with emoji.

---

## 3. Multi-Agent Display

When multiple agents run in parallel, show each agent's status individually with its current state:

```
─── ◈ HYDRA ▸ REVIEWING ───────────────────────────────

  ✦ qa-reviewer           approved (94%)
  ◆ performance-reviewer   analyzing...
  ◇ type-reviewer          waiting

  Progress: ████████░░░░ 1/3 reviewers
```

Rules:
- Left-align agent names.
- Show the status symbol, agent name, and current action or result.
- Include a progress bar summarizing overall completion.

---

## 4. Progress Display

### Phase-level progress

```
Progress: ████████░░░░ 80%
```

### Task-level progress

```
Tasks: 6/10 complete
```

Rules:
- Use `█` for filled segments, `░` for empty segments.
- Keep the bar width consistent (12 characters recommended).
- Show the numeric value alongside the bar.

---

## 5. Checkpoint Boxes

Checkpoints require human input. Three types exist — use the matching label.

### Verification Required

```
┌─── ◈ CHECKPOINT: Verification Required ──────────────┐
│                                                       │
│  {content}                                            │
│                                                       │
│  → Type "approved" or describe issues                 │
└───────────────────────────────────────────────────────┘
```

### Decision Required

```
┌─── ◈ CHECKPOINT: Decision Required ──────────────────┐
│                                                       │
│  {content}                                            │
│                                                       │
│  → Choose an option or provide direction              │
└───────────────────────────────────────────────────────┘
```

### Action Required

```
┌─── ◈ CHECKPOINT: Action Required ────────────────────┐
│                                                       │
│  {content}                                            │
│                                                       │
│  → Complete the action, then type "done"              │
└───────────────────────────────────────────────────────┘
```

Rules:
- Box width must be consistent within a session.
- Always include the `→` prompt line telling the user what to do.
- The `◈` symbol marks the checkpoint as a Hydra-level gate.

---

## 6. Error Box

```
┌─── ✗ ERROR ──────────────────────────────────────────┐
│  {description}                                        │
│  Fix: {steps}                                         │
└───────────────────────────────────────────────────────┘
```

Rules:
- Use `✗` (not emoji) for the error marker.
- Always include a `Fix:` line with actionable remediation steps.
- Keep the same box width as checkpoint boxes.

---

## 7. Next Up Block

Shown after every major phase completion or task completion to indicate what comes next.

```
─── ◈ NEXT ─────────────────────────────────────────────
  Task 007: Add auth middleware
  /hydra:start to continue
────────────────────────────────────────────────────────
```

Rules:
- Always show after major completions — this is mandatory, not optional.
- Include the task identifier and a brief description.
- Include the command to resume work.

---

## 8. Spawning Indicators

When agents are launched, show spawning activity clearly.

### Single agent

```
◆ Spawning reviewer...
```

### Multiple agents in parallel

```
◆ Spawning 3 reviewers in parallel...
  → qa-reviewer
  → performance-reviewer
  → type-reviewer
```

### Completion callback

```
✦ qa-reviewer complete: approved (94%)
```

Rules:
- Use `◆` for active spawning.
- Use `→` to list individual agents being spawned.
- Use `✦` when reporting an agent's successful completion.

---

## 9. Task Status Display

Use a table for task overviews:

```
| Task     | Status | Description              |
|----------|--------|--------------------------|
| TASK-001 | ✦      | Project scaffolding      |
| TASK-002 | ◆      | Database schema          |
| TASK-003 | ◇      | Auth endpoints           |
| TASK-004 | ✗      | Payment integration      |
```

Rules:
- Use the status symbols from Section 2 — never emoji.
- Keep descriptions concise (under 40 characters).
- Sort by task number.

---

## 10. Review Verdicts

Standard verdict labels for review gates:

| Verdict        | Meaning                              |
|----------------|--------------------------------------|
| `✦ APPROVED`   | All checks passed, task may proceed  |
| `⚠ CONCERN`    | Non-blocking issue noted             |
| `✗ REJECTED`   | Blocking issue, changes required     |

These replace any legacy emoji verdicts. All review output must use these exact labels.

---

## 11. Anti-Patterns

The following are explicitly prohibited in Hydra output:

| Do Not                                              | Do Instead                                          |
|-----------------------------------------------------|-----------------------------------------------------|
| Vary box/banner widths within a session              | Pick a consistent width and maintain it             |
| Use random emoji (rocket, sparkle, star, etc.)       | Use only the symbols defined in Section 2           |
| Omit the Next Up block after completions             | Always show Next Up (Section 7)                     |
| Skip `◈ HYDRA ▸` prefix in banners                  | Every banner starts with `◈ HYDRA ▸`               |
| Use legacy emoji (`✅`, `⚠️`, `❌`)                  | Use `✦`, `⚠`, `✗` instead                         |
| Mix separator styles (`---`, `===`, `***`)           | Use `─` line separators exclusively                 |
| Use lowercase stage names in banners                 | Stage names are always UPPERCASE                    |
| Show raw internal state to the user                  | Format all output through these brand standards     |
