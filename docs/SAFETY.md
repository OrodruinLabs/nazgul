# Safety & Rules

## The 10 Rules for the Hydra Loop

1. **Always read plan.md first.** The Recovery Pointer tells you exactly where you are.
2. **Files are truth, context is ephemeral.** Write state to files immediately.
3. **Follow existing patterns exactly.** Read the pattern reference before implementing.
4. **Tests are mandatory.** Every task includes tests. Don't proceed if failing.
5. **Never skip the review gate.** ALL reviewers must approve. No exceptions.
6. **Address ALL blocking feedback.** Fix every REJECT item when CHANGES_REQUESTED.
7. **One task at a time.** Unless parallel mode with Agent Teams.
8. **Update Recovery Pointer on every state change.** Survives compaction.
9. **Commit in AFK mode.** Every state transition gets a `hydra:` prefixed commit.
10. **HYDRA_COMPLETE means ALL tasks DONE and post-loop finished.** Not before.

## Safety Guardrails

- **Pre-tool guard** blocks: `rm -rf /`, `DROP TABLE`, `git push --force main`, fork bombs, `curl | sh`
- **Review gate enforcement**: 3-layer defense-in-depth — stop hook validates, task-state guard prevents bypasses, review-gate agent enforces. Tasks cannot reach DONE without ALL reviewers approving.
- **Security rejections** in AFK mode → BLOCKED (requires human review)
- **Max retries per task**: 3 (configurable)
- **Max consecutive failures**: 5 (auto-stops if no progress)
- **Confidence threshold**: Findings below 80/100 are non-blocking concerns
- **Board sync isolation**: Sync failures never block local work — auto-disables after 5 consecutive failures

## Troubleshooting

**"No Hydra config found"** — Run `/hydra-init` first.

**"Discovery not run"** — Run `/hydra-init` or `/hydra-discover`.

**Loop stops unexpectedly** — Check `hydra/config.json` for `max_iterations` or `consecutive_failures`. Run `/hydra-start --continue` to resume.

**Task stuck as BLOCKED** — Check `hydra/tasks/TASK-NNN.md` for the `blocked_reason`. Fix the issue manually, then run `/hydra-task unblock TASK-NNN` or set status to READY and `/hydra-start --continue`.

**Want to see what happened overnight?** — Run `/hydra-log` for a full timeline of iterations, commits, reviews, and blockers.

**Need to pause the loop?** — Run `/hydra-pause` to stop cleanly at the next iteration boundary.

**Hydra state is corrupted** — Run `/hydra-reset` to archive current state and start fresh. Use `--preserve-context` to keep discovery data.

**Context degradation** — If the agent seems confused after many iterations, run `/compact` with Hydra-specific instructions, then the session-context hook will re-inject state.
