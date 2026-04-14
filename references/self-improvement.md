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

Reports are written to `nazgul/improvement-reports/` in the project runtime directory. The `/nazgul:metrics` skill aggregates these for trend analysis.

## Opt-In

Self-improvement mode is enabled via `nazgul/config.json`:
```json
{ "self_improvement": { "enabled": true, "threshold": 7 } }
```

Only agents with ratings below the threshold file reports.
