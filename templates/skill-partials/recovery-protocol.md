## Recovery Protocol

1. Read `nazgul/config.json` — mode, iteration, objective, agents
2. Read `nazgul/plan.md` — Recovery Pointer (current task, last action, next action)
3. Read active task manifest if one exists
4. Read latest checkpoint if recovering from interruption

**Files are truth.** Never assume state from conversation context.
