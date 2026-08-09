---
name: nazgul:doctor
description: Run the Nazgul read-only preflight diagnostic — checks jq/gh presence and auth, git-hooks drift, cache-vs-repo plugin version, the bash-vs-zsh hazard, the NAZGUL_DIR footgun, config-schema staleness, and (when execution.stacking is enabled) gh-stack tooling readiness and registry-vs-GitHub drift. Use when asked to "check my nazgul environment", "run doctor", "why isn't my plugin change taking effect", or before starting a loop.
allowed-tools: Bash, Read
metadata:
  author: Jose Mejia
---

# Nazgul Doctor

## Examples
- `/nazgul:doctor` — Run all ten checks (a config-present engine check plus the nine environment checks (a)-(i), where (h)/(i) cover stacking tooling readiness and registry-vs-GitHub drift) and report pass/warn/fail with remediation

## Instructions

Format all output per `${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md` — stage banner, status symbols, no emoji.

### Step 1: Run the Check Engine

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

Capture both stdout and the exit code. This is the entire implementation — `scripts/doctor.sh` runs
all ten checks read-only. It never writes to `nazgul/`, git config, or anywhere else; this skill only
formats what it reports. Every stdout line has the shape `<verdict>\t<check-id>\t<message>`, verdict one
of `pass`/`warn`/`fail`/`note`. The exit code is the aggregate: 0 = all pass, 1 = worst is warn, 2 = worst
is fail.

### Step 2: Report

Print a `─── ◈ NAZGUL ▸ DOCTOR ──────────────────────────────────` banner, then one line per check,
verdict mapped to symbol — `✦` pass, `⚠` warn, `✗` fail, `✧` note — followed by the check id and
doctor's message printed **verbatim**: never paraphrase, re-derive, or drop a finding, including its
remediation text.

Close with a summary line stating the aggregate verdict from the exit code (0 → "All checks passed",
1 → "N check(s) need attention (warn)", 2 → "N check(s) failing"), then the Next Up block. Doctor only
reports — it never blocks, gates, or fixes anything; the remediation text in each message is the
operator's own next step to run by hand.
