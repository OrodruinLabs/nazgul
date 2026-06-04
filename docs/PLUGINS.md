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
  ralph-wiggum         Conflicts with Nazgul's Stop hook
  feature-dev          Conflicts with Nazgul's planning phase
```

## Compatibility Matrix

| Plugin | Status | Notes |
|--------|--------|-------|
| security-guidance | ESSENTIAL | Catches code-level vulnerabilities; Nazgul catches architectural issues |
| code-review | COMPATIBLE | Use for PR review AFTER Nazgul loop completes |
| feature-dev | OVERLAP | Both do planning. Don't use during a Nazgul loop |
| pr-review-toolkit | COMPATIBLE | Detailed PR review after Nazgul creates a PR |
| code-simplifier | COMPATIBLE | Optional post-loop cleanup via `/nazgul:simplify` |
| frontend-design | COMPATIBLE | Auto-invoked during frontend work |
| hookify | COMPATIBLE | Add custom guardrails on top of Nazgul |
| ralph-wiggum | CONFLICTS | Both use Stop hooks. Remove before installing Nazgul |
| OpenClaw | COMPATIBLE | Voice-commanded autonomous loops |
