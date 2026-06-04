# Safety & Rules

## The 10 Rules for the Nazgul Loop

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing.
4. **Tests are mandatory.** Every task includes tests. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** Fix every REJECT item when CHANGES_REQUESTED.
7. **One task at a time.** Unless parallel mode with Agent Teams.
8. **Update Recovery Pointer on every state change.** Survives compaction. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA, IN_REVIEW requires a review directory, source edits require an IN_PROGRESS task.
9. **Commit in AFK mode.** Every state transition gets a commit with the dynamic prefix from config (e.g., `feat(FEAT-003):`).
10. **NAZGUL_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

## Safety Guardrails

- **Pre-tool guard** blocks: `rm -rf /`, `DROP TABLE`, `git push --force main`, fork bombs, `curl | sh`
- **Review gate enforcement**: 3-layer defense-in-depth — stop hook validates, task-state guard prevents bypasses, review-gate agent enforces. Tasks cannot reach DONE without ALL reviewers approving.
- **Security rejections** in AFK mode → BLOCKED (requires human review)
- **Max retries per task**: 3 (configurable)
- **Max consecutive failures**: 5 (auto-stops if no progress)
- **Confidence threshold**: Findings below 80/100 are non-blocking concerns
- **Board sync isolation**: Sync failures never block local work — auto-disables after 5 consecutive failures
- **Fix-first auto-remediation**: Mechanical review findings (dead code, style) are applied automatically; only risky changes (security, architecture) require human judgment
- **Concurrent session detection**: Filesystem locks warn when multiple Nazgul sessions run on the same project, preventing state corruption

## Troubleshooting

**"No Nazgul config found"** — Run `/nazgul:init` first.

**"Discovery not run"** — Run `/nazgul:init` or `/nazgul:discover`.

**Loop stops unexpectedly** — Check `nazgul/config.json` for `max_iterations` or `consecutive_failures`. Run `/nazgul:start` to resume.

**Task stuck as BLOCKED** — Check the `- **Blocked reason**:` line in `nazgul/tasks/TASK-NNN.md`. Fix the issue manually, then run `/nazgul:task unblock TASK-NNN` or set status to READY and `/nazgul:start`.

**Want to see what happened overnight?** — Run `/nazgul:log` for a full timeline of iterations, commits, reviews, and blockers.

**Need to pause the loop?** — Run `/nazgul:pause` to stop cleanly at the next iteration boundary.

**Nazgul state is corrupted** — Run `/nazgul:reset` to archive current state and start fresh. Use `--preserve-context` to keep discovery data.

**Context degradation** — If the agent seems confused after many iterations, run `/compact` with Nazgul-specific instructions, then the session-context hook will re-inject state.

**Concurrent session warning** (e.g., "WARNING: N concurrent Nazgul sessions detected. State corruption risk.") — Ensure only one Nazgul session per project at a time. Stale locks are cleaned after 2 hours, or delete `nazgul/sessions/*.lock` manually.
