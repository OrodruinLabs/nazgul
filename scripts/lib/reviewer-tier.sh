#!/usr/bin/env bash
# Nazgul shared reviewer model-tier escalation helper (MF-014, FEAT-016 TASK-004).
# Sourced by agents/review-gate.md's Step 2.5 bounded 1-retry (via the Bash tool)
# and by tests/test-review-gate-retry.sh, so the "next tier up" rule is defined
# ONCE and is independently testable rather than an inline, untestable prose rule.
#
# Ladder: haiku -> sonnet -> opus. opus is the top tier and stays opus (no tier
# above it, never an error). This ladder applies ONLY to the DEFAULT-tier
# resolution path (models.review_default // models.review // "haiku"); a
# reviewer whose model came from an EXPLICIT models.review_by_reviewer override
# is a caller-level decision — do not call resolve_retry_model for it, retry it
# at its configured tier unchanged ("explicit override wins", per review-gate.md
# Step 2's resolution order).

# next_tier_up <tier> -> prints the one-tier-up model name.
# Usage: next_tier_up haiku   # -> sonnet
#        next_tier_up sonnet  # -> opus
#        next_tier_up opus    # -> opus (already top tier)
# An unrecognized tier is echoed back unchanged (no ladder to climb, no error).
next_tier_up() {
  case "$1" in
    haiku) echo "sonnet" ;;
    sonnet) echo "opus" ;;
    opus) echo "opus" ;;
    *) echo "$1" ;;
  esac
}

# resolve_retry_model <original_tier> <escalate> -> prints the model to use for
# Step 2.5's bounded 1-retry.
# Usage: resolve_retry_model haiku true   # -> sonnet (escalated)
#        resolve_retry_model haiku false  # -> haiku  (stall_retry_escalate_tier: false — same-tier retry, unchanged)
# <escalate> is the resolved value of review_gate.stall_retry_escalate_tier
# (default "true" when the key is absent — resolve that default at the call
# site, same as every other review_gate.* key in this pipeline).
resolve_retry_model() {
  local original="$1" escalate="$2"
  if [ "$escalate" = "false" ]; then
    echo "$original"
    return 0
  fi
  next_tier_up "$original"
}
