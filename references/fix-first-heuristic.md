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
