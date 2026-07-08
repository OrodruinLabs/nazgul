# Feasibility probe: PreToolUse(`Agent`) fires for a subagent-originated dispatch

**Date:** 2026-07-08
**Result:** ✅ PASS
**Gates:** Task 1–7 of the Enforced Conductor plan (Layer 1 dispatch guard depends on this).

## Question

The Layer 1 dispatch guard (`conductor-dispatch-guard.sh`) is a plugin PreToolUse hook on the `Agent`
tool. It must fire for an `Agent` dispatch made *by the conductor subagent* (a nested dispatch), not
only for a dispatch from the main session. This was the one unproven inference in the design.

## Method

1. Registered a throwaway logging PreToolUse hook with matcher `"Agent"` in `.claude/settings.local.json`.
2. Dispatched a parent `general-purpose` subagent whose only instruction was to dispatch ONE child
   subagent (`desc=CHILD-probe`) and return its output.
3. Inspected the hook log.

## Result (verbatim log)

```text
FIRED tool=Agent bg=? type=general-purpose desc=Parent that dispatches a child
FIRED tool=Agent bg=? type=general-purpose desc=CHILD-probe
```

Two `Agent` dispatches were observed: the parent (dispatched from the main session) **and the child
(`CHILD-probe`), which was dispatched from inside the parent subagent.** The hook fired for the nested,
subagent-originated dispatch.

## Conclusion

A plugin PreToolUse(`Agent`) hook observes dispatches made by a subagent. The conductor (itself a
subagent) cannot escape the guard. Layer 1 is feasible as designed — proceed with Tasks 1–7. No
escalation to SubagentStop enforcement required.

**Supporting facts (earlier probes, same day):** `tool_input` for an `Agent` dispatch exposes
`tool_name:"Agent"`, `run_in_background`, and `subagent_type` (a main-session probe with
`run_in_background:true` logged `bg=true`); `run_in_background` is simply absent/false when not set,
which is why this run shows `bg=?`. The guard keys on `run_in_background == true`, so an absent/false
value correctly does not trip the synchronous-dispatch rule.
