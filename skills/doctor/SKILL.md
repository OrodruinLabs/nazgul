---
name: nazgul:doctor
description: Run the Nazgul read-only preflight diagnostic — checks jq/gh presence and auth, git-hooks drift, cache-vs-repo plugin version, the bash-vs-zsh hazard, the NAZGUL_DIR footgun, config-schema staleness, either install mode's .gitignore Nazgul-block drift (stamp and flush-left region), cross-session messaging and Remote Control eligibility, shared-working-tree session collisions, the red-run evidence backlog across every task manifest, and (when execution.stacking is enabled) gh-stack tooling readiness and registry-vs-GitHub drift. Use when asked to "check my nazgul environment", "run doctor", "why isn't my plugin change taking effect", or before starting a loop.
allowed-tools: Bash, Read
metadata:
  author: Jose Mejia
---

# Nazgul Doctor

## Examples
- `/nazgul:doctor` — Run all sixteen checks (a config-present engine check plus the fifteen environment checks (a)-(o), where (h)/(i) cover stacking tooling readiness and registry-vs-GitHub drift, (j) reports whether an install's `.gitignore` carries the block its OWN mode wants — the ephemeral-runtime block in shared mode, the local-mode block in local, both version-stamped since #251 — at the version this plugin ships and with every region line flush-left, which is the only surface that tells a v1 install of either mode that it is v1 — (k)/(l)/(m) cover messaging eligibility, Remote Control eligibility, and shared-working-tree session collisions, and (n) reports the last Stop payload's `background_tasks` state — field present, field present but wrong shape, field absent, payload undetermined, record unselectable, never observed, telemetry bus disabled, or loop paused, and (o) re-asks the red-run evidence gate `ttg_verify_red_run_evidence` over EVERY task manifest read-only — the gate itself runs from one call site, the `IN_PROGRESS -> IMPLEMENTED` edge, so a task that never goes backwards is never re-checked and a rule tightened after it shipped leaves its own backlog invisible; (o) reports that backlog in the RULES §15 grammar and does nothing else, never transitioning, never backfilling, never writing, and counting a manifest it could not READ as a named skip rather than as a manifest found wanting) and report pass/warn/fail with remediation

## Instructions

Format all output per `${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md` — stage banner, status symbols, no emoji.

### Step 1: Run the Check Engine

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

Capture both stdout and the exit code. This is the entire implementation — `scripts/doctor.sh` runs
all sixteen checks read-only. It never writes to `nazgul/`, git config, or anywhere else; this skill only
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
