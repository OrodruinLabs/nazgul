# Companion Plugins

## Recommendations

```
ESSENTIAL:
  security-guidance    Real-time vulnerability detection in written code

RECOMMENDED:
  frontend-design      Better frontend code quality (if UI project)

OPTIONAL:
  hookify              Custom safety rules via markdown
  code-simplifier      Post-loop cleanup for code clarity

DO NOT INSTALL ALONGSIDE:
  ralph-wiggum         Conflicts with Hydra's Stop hook
  feature-dev          Conflicts with Hydra's planning phase
```

## Compatibility Matrix

| Plugin | Status | Notes |
|--------|--------|-------|
| security-guidance | ESSENTIAL | Catches code-level vulnerabilities; Hydra catches architectural issues |
| code-review | COMPATIBLE | Use for PR review AFTER Hydra loop completes |
| feature-dev | OVERLAP | Both do planning. Don't use during a Hydra loop |
| pr-review-toolkit | COMPATIBLE | Detailed PR review after Hydra creates a PR |
| code-simplifier | COMPATIBLE | Optional post-loop cleanup via `/hydra-simplify` |
| frontend-design | COMPATIBLE | Auto-invoked during frontend work |
| hookify | COMPATIBLE | Add custom guardrails on top of Hydra |
| ralph-wiggum | CONFLICTS | Both use Stop hooks. Remove before installing Hydra |
| OpenClaw | SYNERGISTIC | Voice-commanded autonomous loops via `notifications.jsonl` |

## OpenClaw Integration

Hydra is designed to work with OpenClaw for voice-commanded autonomous development:

```
You (WhatsApp voice): "Build the payment integration overnight"
OpenClaw → spawns Hydra loop → monitors progress → messages you when done
```

Hydra writes events to `hydra/notifications.jsonl` that OpenClaw (or any external tool) can `tail -f`:

```jsonl
{"event":"task_complete","task":"TASK-003","timestamp":"...","summary":"User service done"}
{"event":"blocked","task":"TASK-005","timestamp":"...","reason":"API key needed","requires_human":true}
{"event":"loop_complete","timestamp":"...","summary":"6/6 tasks done, 18 commits"}
```
