# Guard Fail-Open Inventory — Enforcement Surface (Partial: 16 of ~46 Files)

## Scope boundary — read this before the table

**This document is NOT a repo-wide inventory of the "lookup miss → pass" pattern class, and must
never be cited as one.** A raw grep for the pattern class across `scripts/`, `scripts/lib/`, and
`scripts/git-hooks/` returns on the order of 190-370 occurrences across 25-46 files depending on which
textual forms are included (TRD "Scope Item 4", `nazgul/plan.md` D3). Classifying all of them has
almost no yield — the large majority are ordinary, correct loop-`continue`s.

This document covers, **exhaustively and with no truncation**, the **16-file enforcement surface**
fixed by `nazgul/plan.md` → D3: every script whose empty-result path is an **authorization decision**
(a fail-open here grants permission to bypass a guard), plus the libraries those scripts source. A
fail-open anywhere outside this set at worst loses telemetry or a notification, not a decision — that
remainder is **filed by reference, not silently dropped**, in
`nazgul/inbox/guard-fail-open-sweep-remainder.md`.

**In scope (16 files, every occurrence classified):**
`scripts/git-hooks/pre-merge-commit`, `scripts/git-hooks/pre-commit`, `scripts/git-hooks/_dispatch.sh`,
`scripts/task-state-guard.sh`, `scripts/parallel-dispatch-guard.sh`, `scripts/parallel-rework-guard.sh`,
`scripts/lean-comments-guard.sh`, `scripts/teammate-idle-guard.sh`,
`scripts/local-mode-tracking-guard.sh`, `scripts/prompt-guard.sh`, `scripts/pre-tool-guard.sh`,
`scripts/lib/task-transition-guard.sh`, `scripts/lib/review-evidence.sh`,
`scripts/lib/review-provenance.sh`, `scripts/lib/task-utils.sh`, `scripts/lib/parallel-batch.sh`.

**`scripts/pre-tool-guard.sh` is INVENTORY-ONLY.** It is classified below like every other file, but it
was not, and must not be, edited by this task or any other task in this objective — its matching
behavior is a hard-constraint exclusion owned by a separate objective (FEAT-023), and
`tests/test-pre-tool-guard.sh`'s FEAT-019 SQL-anchoring precision suite must remain untouched.

**Out of scope, filed not dropped:** ~30 non-enforcement scripts (`stop-hook.sh`, `self-audit.sh`,
`session-context.sh`, `subagent-stop.sh`, `board-sync-github.sh`, and others) whose empty-result paths
at worst affect logging, notifications, or advisory backlog entries — not an authorization decision.
See `nazgul/inbox/guard-fail-open-sweep-remainder.md` for the re-derived per-file counts, the
reproducing grep, and this same boundary rationale.

## Methodology

Per TRD "Scope Item 4 → Methodology", each site is classified into one of three buckets:

- **(a) Correctly not applicable** — the empty/missing result genuinely means the check does not
  apply. Allow is right; no change.
- **(b) Lookup failure masquerading as "nothing found"** — the empty result could mean the search
  itself broke, not that it searched and found nothing. Recorded here; not fixed in this task
  (PRD Non-Goal 4 permits this explicitly — mid-objective scope growth is how a merge queue goes bad).
- **(c) Already audited and deliberately fail-open**, with a stated reason recorded in code comments
  and/or `RULES.md`. An audited-and-deliberate fail-open is a different artifact from an accidental
  one — that distinction is this document's deliverable.

**Worked category-(c) example**, per the task's own instruction: `scripts/parallel-dispatch-guard.sh`'s
`_resolution_integrity_ok()` branch (line 83-87). If `TASKS_DIR` fails to canonicalize as a child of
the resolved `NAZGUL_DIR`, the guard allows and warns
(`emit_event "dispatch_guard_resolution_unconfirmed"`) instead of blocking — a deterministic branch,
not agent discretion, documented in `RULES.md` §15 and reasoned about explicitly in ADR-009. This is
what a complete (c) entry looks like: audited, logged, and its failure-direction choice defended
against the specific guarded action rather than inherited by proximity to another guard.

## Reproducing grep

Run from the repo root against the 16 in-scope files listed above:

```bash
grep -nE \
  '\|\| *continue\b|\|\| *exit 0\b|\|\| *_dispatch_and_exit\b|\|\| *true\b|\|\| *return 0\b|\[ *-z *"\$[A-Za-z_{}0-9]+" *\] *&&|\[ *-n *"\$[A-Za-z_{}0-9]+" *\] *\|\||if *\[ *! *-f *"\$[A-Za-z_{}0-9]+" *\]; *then|if *\[ *-z *"\$[A-Za-z_{}0-9]+" *\]; *then|\[ *-f *"\$[A-Za-z_0-9]+" *\] *&&' \
  scripts/git-hooks/pre-merge-commit scripts/git-hooks/pre-commit scripts/git-hooks/_dispatch.sh \
  scripts/task-state-guard.sh scripts/parallel-dispatch-guard.sh scripts/parallel-rework-guard.sh \
  scripts/lean-comments-guard.sh scripts/teammate-idle-guard.sh \
  scripts/local-mode-tracking-guard.sh scripts/prompt-guard.sh scripts/pre-tool-guard.sh \
  scripts/lib/task-transition-guard.sh scripts/lib/review-evidence.sh \
  scripts/lib/review-provenance.sh scripts/lib/task-utils.sh scripts/lib/parallel-batch.sh
```

The grep has ten alternations: TRD's **five** forms — its four base textual forms (`|| continue`,
`|| exit 0`, `|| _dispatch_and_exit`, `|| true`) plus `[ -z "$X" ] &&` — and **five** extensions added
here. The five extensions are `[ -n "$X" ] ||`, `|| return 0`,
`[ -f "$X" ] &&` (a guarded-presence chain whose absence silently skips a check), and
the `if [ -z "$X" ]; then` / `if [ ! -f "$X" ]; then` multi-line block-opener forms, since these are
textually different spellings of the identical "empty/missing → proceed" shape and were found by
inspection to account for roughly a third of the real sites in these 16 files. `|| return 1` was
deliberately excluded — in every instance checked, `return 1` propagates FAILURE (the fail-*closed*
direction), the opposite of this pattern class, and including it would have diluted the table with
non-findings.

**As of this task's base commit, this grep returns exactly 125 lines across the 16 files** — the table
below has exactly 125 rows, one per line, in the same order. **90 are (a), 18 are (b), 17 are (c).**
Several rows that textually match the grep are NOT themselves allow-branches (e.g. an extraction-
fallback cascade step, or a `return 1` propagation reached via the `[ -n... ] ||` clause) — these are
included for completeness per the "no truncation" mandate and their disposition says so explicitly,
rather than being silently excluded to keep the table looking cleaner.

## The most serious category-(b) findings, ranked

1. **`scripts/git-hooks/pre-merge-commit:77`** — `PARALLEL` defaults to `"false"` on a corrupt-but-
   present `config.json` (no `jq -e .` validity check, unlike its PreToolUse sibling guards), silently
   disarming the merge-verdict check on the ONE guard ADR-009 itself names as having a catastrophic,
   unbounded false-allow cost. Highest severity in this inventory.
2. **`scripts/pre-tool-guard.sh:15`** — "If no input, allow" skips every destructive-command check
   (recursive root delete, SQL table drop, piped-internet-execution, fork bombs, force-push to main) on
   a stdin-read failure. Largest blast radius of any single site; classified here but out of this
   task's edit scope (FEAT-023 owns the fix).
3. **`scripts/git-hooks/pre-commit:36`** — the same MF-053-class gap as #1, applied to the base-branch
   guard's `FEATURE` flag; lower blast radius (reversible — a human can move a stray commit) but the
   same unaudited shape, on the same file family, introduced by the same objective as #1.
4. **`scripts/task-state-guard.sh:23`** — a stdin-read failure no-ops the ENTIRE state-machine/
   file-scope/evidence-gate guard for that Write/Edit/MultiEdit call; this is the guard's own front
   door, the same shape repeated (with lower individual severity) at `parallel-dispatch-guard.sh:12`,
   `parallel-rework-guard.sh:11`, and `lean-comments-guard.sh:254`.
5. **`scripts/lib/task-utils.sh:109`** — a malformed (not just absent) `Files modified` value is
   indistinguishable, to every caller, from a genuinely-unscoped task; `task-state-guard.sh`'s file-scope
   guard then allows editing ANY file under the active task, despite `get_task_files_modified` emitting a
   loud stderr WARN that never actually gates anything.
6. **`scripts/task-state-guard.sh:320`** — an existing manifest whose status field is present but
   unparseable (a 6th, unanticipated format, or corruption) is indistinguishable from "brand-new file,"
   letting a corrupted-but-existing task manifest be reset to `PLANNED`/`READY`, bypassing the transition
   table and every evidence gate for that write.
7. **`scripts/parallel-dispatch-guard.sh:71`** (supplement, not grep-matched) — an unresolvable
   `$TASKS_DIR/$UNIT.md` for a present `NAZGUL_UNIT` marker silently allows the Agent dispatch with NO
   logging, unlike the same file's own audited `_resolution_integrity_ok()` case three lines away, which
   at least emits a named telemetry event.
8. **`scripts/task-state-guard.sh:118`** (and its two sibling case arms at 126-129, 136-139) — the
   anti-forgery defense-in-depth check for `.dispatch.json`/`diff.patch` writes defaults `_dm_blocking`
   to `false`; a lookup miss on the review unit's own task manifest is indistinguishable from
   "confirmed not IN_PROGRESS." Softened by the code's own comment naming this block as a secondary
   layer (the real fix is `review-evidence.sh`'s recompute-and-compare), but the ambiguity itself is
   unaudited.

## Findings folded in from prior review boards (this objective)

These four findings were established by earlier review boards in this same objective, not re-derived
here. Each was independently re-verified against source at this task's base commit — file:line
citations below are the CURRENT locations, confirmed, not copied forward unchecked.

### 1. `${BASH_SOURCE[0]}` unguarded under zsh — 9 sites, verified

TASK-006's security reviewer (`nazgul/reviews/TASK-006/security-reviewer.md` #4) found the same
unguarded `"${BASH_SOURCE[0]}"` expansion in nine library files. `BASH_SOURCE` is a bash-only array;
under zsh (macOS's default interactive shell, and reachable if any of these libraries is ever sourced
from a zsh-invoked context) it is unset, so `dirname "${BASH_SOURCE[0]}"` silently resolves to `.` —
the wrong directory — rather than erroring. Re-verified, all nine still present at this commit:

| File:line | In this task's 16-file scope? |
|---|---|
| `scripts/lib/git-hooks.sh:13` | No — filed to the remainder |
| `scripts/lib/raise-finding.sh:20` | No — filed to the remainder |
| `scripts/lib/review-evidence.sh:14` | **Yes** |
| `scripts/lib/review-provenance.sh:28` | **Yes** |
| `scripts/lib/heartbeat-triage.sh:14` | No — filed to the remainder |
| `scripts/lib/task-utils.sh:5` | **Yes** |
| `scripts/lib/task-transition-guard.sh:8` | **Yes** |
| `scripts/lib/inbox-provider.sh:18` | No — filed to the remainder |
| `scripts/lib/parallel-batch.sh:13` | **Yes** |

This is a *directory-resolution* defect, not itself a "lookup miss → pass" authorization site (it
doesn't have an empty-result/allow shape), so it is not folded into the (a)/(b)/(c) table above —
recorded here instead, per the task brief's instruction to verify and place it in the inventory.
**`scripts/lib/git-hooks.sh` is the most consequential of the nine** (per the source report this task
was given): sourced under zsh, `_GH_TEMPLATES_DIR` mis-resolves, `install_git_hooks`'s `cp` calls
silently fail (no `set -e` there by design), yet `git config core.hooksPath` still runs
unconditionally — producing a `core.hooksPath` that LOOKS configured but points at a directory with no
hooks in it. That file is **out of this task's 16-file scope** (it is not itself a PreToolUse/git-level
guard; it is the *installer* for the two git-level guards) — filed to the remainder with elevated
priority, since it is more deceptive than the original TASK-006 defect it's a sibling of.

### 2. `declare -F` unreliable under zsh — 1 remaining unaudited instance, verified

Found by TASK-006's implementer via a self-caught false-PASS in its own test: zsh's `declare -F`
ignores its argument and always exits 0, unlike bash's (which exits nonzero for an undefined function
name). One instance remains, confirmed still present:

`scripts/session-context.sh:132`: `if declare -F self_heal_git_hooks >/dev/null 2>&1; then ... fi` —
under zsh, this condition is always true regardless of whether `self_heal_git_hooks` was actually
defined by the `source` two lines above, so a source failure (e.g. the same zsh `BASH_SOURCE[0]`
mis-resolution from Finding 1 above, applied to `git-hooks.sh`) would silently skip the self-heal call
with no diagnostic instead of erroring loudly.

`scripts/session-context.sh` is **out of this task's 16-file scope** (SessionStart housekeeping, not a
PreToolUse/git-level guard) — filed to the remainder with elevated priority given the direct causal
chain to Finding 1's `git-hooks.sh` case.

### 3. Evidence-gate scope mismatch — confirmed still present

TASK-005's architect review (#2) found that `task-transition-guard.sh`'s `ttg_verify_commit_evidence`
scans the **entire manifest** for any hex-looking substring, while the git-level guard's equivalent
check is scoped to the `## Commits` heading only — and the user-facing error message describes the
scoped behavior that the code doesn't actually implement. Re-verified at this commit:

- `scripts/lib/task-transition-guard.sh:59`: `grep -oE '[0-9a-f]{7,40}'` runs against the **whole**
  `manifest_text` argument, unscoped.
- `scripts/git-hooks/pre-merge-commit:101`: `commits_verify()` scopes its search to
  `awk '/^## Commits/{f=1;next} /^## /{f=0} f'` — the `## Commits` section only.
- `scripts/task-state-guard.sh:378`: `"Add a ## Commits section with a real, reachable commit hash..."`
  — this message describes the git-level guard's scoped behavior, not
  `ttg_verify_commit_evidence`'s actual (unscoped) one.

Still holds. This is a **consistency/scope-mismatch defect between two evidence-checking
implementations**, not a "lookup miss → pass" fail-open in the sense this document otherwise tracks
(an unscoped scan is, if anything, MORE permissive about WHERE it finds a hex token, not about whether
it fails open on absence) — it is folded in here per the task brief rather than forced into the (a)/(b)/(c)
table, since its risk shape (a manifest containing a commit-shaped hex string anywhere outside `##
Commits`, e.g. in prose, satisfying the evidence gate) is a different class from "ambiguous absence."

### 4. `skills/start/SKILL.md` caller-propagation gap — confirmed still present

TASK-003's architect review (#2) found that all five call sites of `create_feature_branch` in
`skills/start/SKILL.md` document only the happy path, with no guidance for a non-zero return. Re-verified:
lines 167, 195, 262, 279, and 292 all say "follow **Branch Setup via `create_feature_branch`**" with
no error-handling instruction anywhere in that section. `skills/` is outside this task's file scope
(not one of the 16 enforcement-surface scripts) — recorded here per the task brief, not actioned.

## Full classification table (125 rows, one per reproducing-grep hit)

| # | Site (file:line) | Construct | What empty/missing means | Class | Disposition |
|---|---|---|---|---|---|
| 1 | `scripts/git-hooks/pre-merge-commit:48` | `[ -n "$REPO_ROOT" ] \|\| exit 0` | git rev-parse failed / not a git repo | (a) | Hook cannot function outside a git repo by construction; no change. |
| 2 | `scripts/git-hooks/pre-merge-commit:67` | `command -v jq >/dev/null 2>&1 \|\| _dispatch_and_exit` | jq absent | (c) | Audited in-file (lines 64-66): "No jq -> nothing downstream safely readable -> degrade to allow immediately." Definite environmental fact, not ambiguous. |
| 3 | `scripts/git-hooks/pre-merge-commit:69` | `[ -f "$CONFIG" ] \|\| _dispatch_and_exit` | nazgul/config.json absent | (a) | Not a Nazgul project; correct. |
| 4 | `scripts/git-hooks/pre-merge-commit:74` | `GIT_HOOKS_ENABLED=$(jq ... == false then false else true) 2>/dev/null \|\| echo "true"` | jq/config read failure | (a) | Defaults to true (enabled) on failure — safe direction; kill-switch semantics preserved. |
| 5 | `scripts/git-hooks/pre-merge-commit:77` | `PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG" 2>/dev/null \|\| echo "false"); [ "$PARALLEL" = "true" ] \|\| _dispatch_and_exit` | jq/config read failure | (b) | UNAUDITED. Unlike parallel-dispatch-guard.sh/parallel-rework-guard.sh (MF-053), this hook has no `jq -e .` JSON-validity pre-check. A corrupt-but-present config.json makes PARALLEL default to "false", and the entire merge-verdict check is skipped — allowing the merge unconditionally. ADR-009 itself states this exact guard's false-allow is catastrophic ("unreviewed code permanently enters the trunk of record"). Highest-severity finding in this inventory. |
| 6 | `scripts/git-hooks/pre-merge-commit:80` | `ENFORCE=$(jq -r 'if ... == false then false else true' 2>/dev/null \|\| echo "true"); [ "$ENFORCE" = "true" ] \|\| _dispatch_and_exit` | jq/config read failure | (a) | Defaults to true (enforced) on failure — safe direction. |
| 7 | `scripts/git-hooks/pre-merge-commit:90` | `if [ -z "$st" ]; then st=$(grep legacy-format ...); fi` | frontmatter status extraction empty | (a) | Extraction-fallback chain (2nd of 2 formats tried), not itself an allow branch; empty final `st` still compares `!= DONE` downstream and BLOCKS (fail-closed), the correct direction for this guard. |
| 8 | `scripts/git-hooks/pre-merge-commit:101` | `for tok in $(awk '...Commits...' \| grep -oE hex \|\| true); do` | no Commits section / no hex tokens found | (a) | Empty token list -> commits_verify returns 1 -> caller `continue`s to the next candidate task file (normal search-loop continuation), not a blanket allow. |
| 9 | `scripts/git-hooks/pre-merge-commit:114` | `[ "$(...CANDIDATE_PAIRS_JSON... jq length 2>/dev/null \|\| echo 0)" -gt 0 ] \|\| _dispatch_and_exit` | GITHEAD_* env parse failure / zero candidates | (c) | Audited in-file (lines 107-110): "Any failure in this pipeline... -> treat as no candidates... -> degrade to allow." CAVEAT: per ADR-009's own two-question rule this is the exact guard whose false-allow is declared catastrophic; this disposition deserves re-litigation under ADR-009 rather than being grandfathered from the comment alone — flagged, not fixed here. |
| 10 | `scripts/git-hooks/pre-merge-commit:121` | `[ -n "$CANDIDATE_SHA" ] \|\| continue` | blank GITHEAD tuple | (a) | Defensive parse loop; correct. |
| 11 | `scripts/git-hooks/pre-merge-commit:127` | `[ -f "$tf" ] \|\| continue` | glob no-match | (a) | Standard glob-loop guard. |
| 12 | `scripts/git-hooks/pre-merge-commit:128` | `commits_verify "$tf" "$CANDIDATE_SHA" \|\| continue` | this manifest doesn't record the candidate SHA | (a) | Normal search-loop continuation across all task manifests; the guard fails closed (BLOCK) if content-match and ref-derived signals both come up empty on a matched unit (Fix 1c), so this per-file `continue` does not mask a global miss. |
| 13 | `scripts/git-hooks/pre-merge-commit:163` | `[ -n "$UNIT_ID" ] \|\| _dispatch_and_exit` | no candidate flagged a problem | (a) | Reached only after CANDIDATE_PAIRS_JSON was confirmed non-empty at line 114; an exhaustive search that found nothing wrong is correctly distinguished from never having searched. |
| 14 | `scripts/git-hooks/pre-commit:12` | `[ -n "$REPO_ROOT" ] \|\| exit 0` | git rev-parse failed | (a) | Cannot function outside a git repo; no change. |
| 15 | `scripts/git-hooks/pre-commit:28` | `[ -f "$CONFIG" ] \|\| _dispatch_and_exit` | nazgul/config.json absent | (a) | Not a Nazgul project; correct. |
| 16 | `scripts/git-hooks/pre-commit:33` | `GIT_HOOKS_ENABLED=... 2>/dev/null \|\| echo "true"; [ = true ] \|\| _dispatch_and_exit` | jq/config read failure | (a) | Defaults true (enabled) on failure — safe direction. |
| 17 | `scripts/git-hooks/pre-commit:36` | `FEATURE=$(jq -r '.branch.feature // ""' 2>/dev/null \|\| echo ""); [ -n "$FEATURE" ] \|\| _dispatch_and_exit` | jq/config read failure | (b) | Same MF-053-class gap as pre-merge-commit line 77: no `jq -e .` validity pre-check on this hook. A corrupt-but-present config makes FEATURE default to "", read as "no active loop" and the base-branch guard silently disarms. Lower blast radius than the merge guard (a human can move a stray commit off base), but the same unaudited class. |
| 18 | `scripts/git-hooks/pre-commit:41` | `[ -n "$CURRENT" ] && [ "$CURRENT" = "$BASE" ] \|\| _dispatch_and_exit` | detached HEAD (git branch --show-current empty) | (a) | Guard's purpose (block commits landing ON base) is genuinely not applicable while detached; correct. |
| 19 | `scripts/git-hooks/_dispatch.sh:30` | `if [ -f "$_NAZGUL_DISPATCH_CONFIG" ] && command -v jq; then dir=$(jq ...); fi` | config/jq unavailable | (a) | Two-tier resolution: falls through to the git-common-dir fallback below rather than giving up. |
| 20 | `scripts/git-hooks/_dispatch.sh:33` | `if [ -z "$dir" ]; then ...git rev-parse --git-common-dir...; fi` | config-derived dir unresolved | (a) | Opens the fallback-resolution attempt, not itself an allow. |
| 21 | `scripts/git-hooks/_dispatch.sh:36` | `[ -n "$common_dir" ] \|\| return 0` | git rev-parse --git-common-dir failed | (b) | Low-probability (git already invoked this hook, so git-common-dir should resolve), but unaudited: a resolution failure here is read as "no prior hooks dir" and dispatch_prior_hook silently skips forwarding to the user's real prior hook, undermining the file's own stated purpose (header lines 4-7: "installing Nazgul's core.hooksPath never silently disables a hook the user already had"). |
| 22 | `scripts/git-hooks/_dispatch.sh:47` | `[ -d "$dir" ] \|\| return 0` | resolved prior-hooks dir doesn't exist | (a) | A non-existent directory genuinely has no hook to forward to; reasonable. |
| 23 | `scripts/git-hooks/_dispatch.sh:57` | `[ -n "$hook_name" ] \|\| return 0` | dispatch_prior_hook called with no hook_name | (a) | Defensive; both real call sites hardcode a name, unreachable in practice. |
| 24 | `scripts/git-hooks/_dispatch.sh:58` | `shift \|\| true` | no positional args to shift | (a) | Standard defensive shell idiom; no authorization effect. |
| 25 | `scripts/git-hooks/_dispatch.sh:61` | `prior_dir="$(_dispatch_prior_hooks_dir)" \|\| return 0` | (cd "$dir" && pwd) fails (TOCTOU) | (a) | Narrow race window on a Nazgul-controlled config value (not attacker input per lines 70-73); reasonable degrade. |
| 26 | `scripts/git-hooks/_dispatch.sh:62` | `[ -n "$prior_dir" ] \|\| return 0` | resolved dir string empty | (b) | Same finding as line 36 (shares the same root cause) — included as its own grep-matched row for completeness. |
| 27 | `scripts/git-hooks/_dispatch.sh:74` | `[ -e "$prior_hook" ] \|\| return 0` | prior hook path doesn't exist | (c) | Audited in-file (lines 70-73): "a corrupted/hand-edited value must degrade to no-op, never arbitrary exec." Deliberate trust-boundary design, worked example alongside _resolution_integrity_ok(). |
| 28 | `scripts/git-hooks/_dispatch.sh:75` | `[ ! -L "$prior_hook" ] \|\| return 0` | prior hook path is a symlink | (c) | Same trust-boundary design (lines 70-73): refuses to follow a symlink rather than silently trusting it. |
| 29 | `scripts/git-hooks/_dispatch.sh:76` | `[ -f "$prior_hook" ] \|\| return 0` | prior hook path is not a regular file | (c) | Same trust-boundary design (lines 70-73). |
| 30 | `scripts/git-hooks/_dispatch.sh:77` | `[ -x "$prior_hook" ] \|\| return 0` | prior hook path is not executable | (c) | Same trust-boundary design (lines 70-73). |
| 31 | `scripts/parallel-dispatch-guard.sh:11` | `[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null \|\| echo "")` | arg not supplied | (a) | Standard arg-then-stdin fallback shape shared by all three PreToolUse-arg guards. |
| 32 | `scripts/parallel-dispatch-guard.sh:12` | `[ -z "$INPUT" ] && exit 0` | stdin read failure / genuinely empty | (b) | A read failure is indistinguishable from "no input"; the whole re-dispatch check no-ops. Moderate severity: no-op means "allow the Agent dispatch", and the review board still runs on the dispatched unit's output later, bounding the cost (matches ADR-009's own fail-open reasoning for this guard family) — but the ambiguity itself is unaudited. |
| 33 | `scripts/parallel-dispatch-guard.sh:13` | `command -v jq >/dev/null 2>&1 \|\| exit 0` | jq absent | (a) | Definite environmental fact, not ambiguous; guard cannot function without jq. |
| 34 | `scripts/parallel-dispatch-guard.sh:26` | `[ -f "$CONFIG" ] \|\| exit 0` | nazgul/config.json absent | (a) | Not a Nazgul project; correct, and protected from the corrupt-config case by the `jq -e .` check on the next line (MF-053). |
| 35 | `scripts/parallel-dispatch-guard.sh:29` | `PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG"); [ = true ] \|\| exit 0` | config read | (a) | Preceded by `jq -e . "$CONFIG" \|\| exit 2` (MF-053 fail-closed on corrupt config); this line only runs once JSON validity is already confirmed. Safe. |
| 36 | `scripts/parallel-dispatch-guard.sh:39` | `[ "$TOOL" = "Agent" ] \|\| exit 0` | non-Agent tool call | (a) | Guard is Agent-tool-scoped by design; correct. |
| 37 | `scripts/parallel-dispatch-guard.sh:70` | `UNIT=$(... grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' ... \|\| true)` | no NAZGUL_UNIT marker in prompt | (a) | Empty UNIT correctly means "not a Nazgul-tracked dispatch"; see line 71 (supplement) for the real ambiguity this masks once UNIT IS present. |
| 38 | `scripts/task-state-guard.sh:23` | `if [ -z "$INPUT" ]; then exit 0; fi` | stdin read failure / no input | (b) | HIGH. `cat 2>/dev/null \|\| echo ""` swallows any stdin-read error; an I/O failure is indistinguishable from "no tool call happened," and the ENTIRE state-machine/file-scope/evidence-gate guard no-ops for that Write/Edit/MultiEdit. This is the guard's own front door. |
| 39 | `scripts/task-state-guard.sh:35` | `EDITS_JSON=$(... jq -c ... \|\| echo ""); if [ -z "$EDITS_JSON" ]; then exit 0; fi` | jq parse failure on MultiEdit payload | (b) | A malformed/unexpected MultiEdit tool_input is indistinguishable from "zero edits," and the entire fan-out (which is what actually re-invokes the guard per sub-edit) is skipped — the whole MultiEdit call is allowed unchecked. |
| 40 | `scripts/task-state-guard.sh:39` | `[ -z "$EDIT" ] && continue` | blank line while iterating parsed edits | (a) | Standard loop hygiene. |
| 41 | `scripts/task-state-guard.sh:118` | `if [ -f "$_dm_unit_task" ] && [ status = IN_PROGRESS ]; then _dm_blocking=true; fi` | TASK-*/PATCH-* manifest not found at either candidate path | (b) | `_dm_blocking` initializes false and is only ever set true on a positive match; a missing/unresolvable manifest for the review unit's own task silently allows the dispatch-manifest/diff.patch write. The file's own comment (lines 99-101) already names this block "defense-in-depth" with recompute-and-compare as "the real fix," which softens severity, but the lookup-miss-vs-genuinely-absent distinction is not itself audited. Same shape repeats at the GROUP-* (lines 126-129) and default (lines 136-139) case arms. |
| 42 | `scripts/task-state-guard.sh:125` | `[ -f "$_dm_task_file" ] \|\| continue` | glob no-match (GROUP-* arm) | (a) | Standard glob-loop guard. |
| 43 | `scripts/task-state-guard.sh:135` | `[ -f "$_dm_task_file" ] \|\| continue` | glob no-match (default arm) | (a) | Standard glob-loop guard. |
| 44 | `scripts/task-state-guard.sh:196` | `[ -f "$task_file" ] \|\| continue` | glob no-match (active-task scan) | (a) | Standard glob-loop guard. |
| 45 | `scripts/task-state-guard.sh:238` | `[ -z "$token" ] && continue` | blank token in file-scope list | (a) | Standard loop hygiene. |
| 46 | `scripts/task-state-guard.sh:279` | `if [ -z "$NEW_STATUS" ]; then NEW_STATUS=$(... ATX inline...); fi` | list-item extractor found nothing | (a) | Extraction-fallback chain (1 of 5), not itself an allow branch. |
| 47 | `scripts/task-state-guard.sh:282` | `if [ -z "$NEW_STATUS" ]; then NEW_STATUS=$(... ATX block...); fi` | prior extractors found nothing | (a) | Extraction-fallback chain (2 of 5), not itself an allow branch. |
| 48 | `scripts/task-state-guard.sh:286` | `if [ -z "$NEW_STATUS" ]; then NEW_STATUS=$(... YAML frontmatter...); fi` | prior extractors found nothing | (a) | Extraction-fallback chain (3 of 5), not itself an allow branch. |
| 49 | `scripts/task-state-guard.sh:298` | `_fm_line=$(... grep -m1 ... 2>/dev/null \|\| true)` | frontmatter status line not found | (a) | Feeds the same cascade as line 286; not independently an allow branch. |
| 50 | `scripts/task-state-guard.sh:301` | `if [ -z "$NEW_STATUS" ]; then NEW_STATUS=$(... bare-token catch-all...); fi` | prior extractors found nothing | (a) | Extraction-fallback chain (4 of 5), not itself an allow branch. |
| 51 | `scripts/task-state-guard.sh:306` | `NEW_STATUS=$(... \| tr -d '[:space:]' \|\| true)` | bare-token grep found nothing | (a) | Feeds the same cascade as line 301; not independently an allow branch. |
| 52 | `scripts/task-state-guard.sh:308` | `if [ -z "$NEW_STATUS" ]; then exit 0; fi` | all 5 extraction formats found nothing | (b) | Terminal cascade step: "Not a status change — allow." An edit that changes status in a 6th, unanticipated format is indistinguishable from an edit that genuinely does not touch status; the guard silently skips ALL downstream state-machine and evidence-gate enforcement for that write. |
| 53 | `scripts/task-state-guard.sh:320` | `if [ -z "$OLD_STATUS" ]; then if [ NEW_STATUS = PLANNED/READY ]; then exit 0; fi; ...; fi` | get_task_status() found no recognizable status on an EXISTING file | (b) | OLD_STATUS="" is meant to mean "brand-new manifest," but get_task_status() does not distinguish that from "existing file whose status field is present but unparseable" (corruption, or a 6th format). A corrupted-but-existing manifest could be treated as new and reset to PLANNED/READY, bypassing the transition table and evidence gates entirely for that edit. |
| 54 | `scripts/task-state-guard.sh:364` | `elif [ -f "$FILE_PATH" ] && [ -n "$OLD_STRING" ]; then MANIFEST_TEXT=$(awk reconstruct); else MANIFEST_TEXT="$NEW_CONTENT"; fi` | file missing or OLD_STRING empty | (a) | Text-reconstruction strategy choice, not an authorization decision; the commit-evidence check still runs against whichever text is chosen. |
| 55 | `scripts/task-state-guard.sh:431` | `EVIDENCE_PROBLEMS=$(ttg_verify_review_evidence ...) \|\| true` | command substitution nonzero under set -e | (a) | Required so `set -e` doesn't abort before the real `[ -n "$EVIDENCE_PROBLEMS" ]` gate two lines later, which correctly blocks; not itself a fail-open. |
| 56 | `scripts/task-state-guard.sh:454` | `if [ -z "$MISSING_LIST" ] && [ -z "$UNAPPROVED_LIST" ]; then echo "Unexpected..."; fi` | diagnostic-message selection | (a) | Reached only inside the already-blocking (exit 2) branch; purely cosmetic, no authorization effect. |
| 57 | `scripts/parallel-rework-guard.sh:10` | `[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null \|\| echo "")` | arg not supplied | (a) | Standard arg-then-stdin fallback. |
| 58 | `scripts/parallel-rework-guard.sh:11` | `[ -z "$INPUT" ] && exit 0` | stdin read failure / genuinely empty | (b) | Same class as parallel-dispatch-guard.sh:12 — a read failure silently allows the Write/Edit/MultiEdit through the re-work check. |
| 59 | `scripts/parallel-rework-guard.sh:12` | `command -v jq >/dev/null 2>&1 \|\| exit 0` | jq absent | (a) | Definite environmental fact. |
| 60 | `scripts/parallel-rework-guard.sh:25` | `[ -f "$CONFIG" ] \|\| exit 0` | nazgul/config.json absent | (a) | Not a Nazgul project; protected from corrupt-config by the `jq -e .` check on the next line (MF-053). |
| 61 | `scripts/parallel-rework-guard.sh:28` | `PARALLEL=$(jq -r ...); [ = true ] \|\| exit 0` | config read | (a) | Preceded by MF-053's fail-closed validity check; safe. |
| 62 | `scripts/parallel-rework-guard.sh:35` | `[ -n "$FILE_PATH" ] \|\| exit 0` | file_path missing from tool_input | (a) | Write/Edit/MultiEdit always carry file_path; degenerate case, not a realistic ambiguity for this guard's scope. |
| 63 | `scripts/parallel-rework-guard.sh:67` | `[ -n "$f" ] \|\| continue` | blank line in _scope_has's file-list read | (a) | Standard loop hygiene. |
| 64 | `scripts/parallel-rework-guard.sh:77` | `[ -f "$tf" ] \|\| continue` | glob no-match | (a) | Standard glob-loop guard. |
| 65 | `scripts/parallel-rework-guard.sh:80` | `_has_commit "$tf" \|\| continue` | this task manifest has no ## Commits token | (a) | Normal search-loop continuation across all task files to find the OWNER of a file; not a blanket allow. |
| 66 | `scripts/parallel-rework-guard.sh:90` | `[ -f "$tf" ] \|\| continue` | glob no-match | (a) | Standard glob-loop guard. |
| 67 | `scripts/parallel-rework-guard.sh:92` | `[ "$st" = "IN_PROGRESS" ] \|\| continue` | task not IN_PROGRESS | (a) | Correct filter for the cross-cutting-exemption count. |
| 68 | `scripts/local-mode-tracking-guard.sh:30` | `if [ -z "$INPUT" ]; then exit 0; fi` | stdin read failure / no input | (c) | Audited in the file's own header (lines 10-11, 16-18): "Degradation: exits 0 when config absent... or stdin is empty" / "degrade to allow — acceptable for normal Nazgul loop usage." This is a secondary/defense-in-depth layer per the same header (.gitignore + session-staging install_mode chokepoint are primary). |
| 69 | `scripts/local-mode-tracking-guard.sh:38` | `if [ -z "$CMD" ]; then CMD="$INPUT"; fi` | jq extraction of tool_input.command empty | (a) | Fallback to the raw envelope as the scan target — MORE conservative, not less; not an allow branch. |
| 70 | `scripts/local-mode-tracking-guard.sh:43` | `if [ -z "$CMD" ]; then exit 0; fi` | CMD still empty after the line-38 fallback | (a) | Given lines 30 and 38 already guarantee CMD is non-empty whenever INPUT was non-empty, this branch is effectively unreachable in practice; correctly defensive. |
| 71 | `scripts/local-mode-tracking-guard.sh:214` | `if [ ! -f "$CONFIG" ]; then exit 0; fi` | nazgul/config.json absent | (c) | Audited in the file's own header (line 10): "Degradation: exits 0 when config absent..." Not a Nazgul project. |
| 72 | `scripts/lean-comments-guard.sh:217` | `[ -z "$findings" ] && return 0` | detect_violations produced no findings | (a) | Genuinely clean content; correct. |
| 73 | `scripts/lean-comments-guard.sh:220` | `[ -z "$ln" ] && continue` | blank line while formatting findings | (a) | Standard loop hygiene. |
| 74 | `scripts/lean-comments-guard.sh:240` | `[ -f "$f" ] \|\| continue` | --check mode: a caller-supplied path doesn't exist | (b) | Silent skip with no diagnostic. This mode is the one the Implementer Agent protocol explicitly instructs be run manually per changed file (`lean-comments-guard.sh --check <files>`); a typo'd or already-moved path is silently treated as "clean" rather than flagged, which could let real comment bloat through undetected. |
| 75 | `scripts/lean-comments-guard.sh:242` | `[ -z "$style" ] && continue` | comment_style_for() returned nothing for this extension | (a) | Unsupported/unrecognized file type; genuinely not applicable. |
| 76 | `scripts/lean-comments-guard.sh:254` | `[ -z "$INPUT" ] && exit 0` | stdin read failure (hook mode) | (b) | Same class as task-state-guard.sh:23 — a stdin-read failure silently allows the Write/Edit/MultiEdit through the comment-bloat check. |
| 77 | `scripts/lean-comments-guard.sh:280` | `[ -z "$FILE_PATH" ] && exit 0` | jq extraction of file_path empty | (b) | A malformed tool_input envelope is indistinguishable from "no file path," and the whole hook-mode check is skipped. |
| 78 | `scripts/lean-comments-guard.sh:282` | `[ -z "$STYLE" ] && exit 0` | comment_style_for() returned nothing | (a) | Unsupported file type; genuinely not applicable. |
| 79 | `scripts/prompt-guard.sh:22` | `if [ ! -f "$CONFIG" ]; then exit 0; fi` | nazgul/config.json absent | (a) | Explicitly commented: "If Nazgul not initialized, allow all prompts." Correct. |
| 80 | `scripts/prompt-guard.sh:28` | `if [ -z "$USER_PROMPT" ]; then exit 0; fi` | jq extraction of .prompt empty / stdin read failure | (b) | A malformed UserPromptSubmit envelope or a stdin-read failure is indistinguishable from "no prompt content," and both of the guard's blocklist checks (manual NAZGUL_COMPLETE, direct status-manipulation text) are skipped for that turn. Lower severity than the PreToolUse guards (this is a HITL text-pattern safety net, not the state-machine enforcer), but unaudited. |
| 81 | `scripts/teammate-idle-guard.sh:13` | `[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null \|\| echo "")` | arg not supplied | (a) | Standard arg-then-stdin fallback. |
| 82 | `scripts/teammate-idle-guard.sh:14` | `[ -z "$INPUT" ] && exit 0` | stdin read failure / no input | (c) | Audited: file header (lines 8-10) and RULES.md §17 both state this file "Fails OPEN on unparseable payloads, unknown teammates, and stale feat_id — a deliberate inversion of the PreToolUse guards' fail-closed rule, because blocking on garbage strands live teammates." |
| 83 | `scripts/teammate-idle-guard.sh:15` | `command -v jq >/dev/null 2>&1 \|\| exit 0` | jq absent | (a) | Definite environmental fact. |
| 84 | `scripts/teammate-idle-guard.sh:28` | `[ -f "$CONFIG" ] \|\| exit 0` | nazgul/config.json absent | (a) | Explicitly commented "Not a Nazgul project -> allow." |
| 85 | `scripts/teammate-idle-guard.sh:33` | `mkdir -p "$LOG_DIR" 2>/dev/null \|\| return 0` | log directory creation failure inside log_event() | (a) | Telemetry-only helper, explicitly commented "Never fails the guard" (line 31); genuinely optional per the TRD's own cleanup exclusion. |
| 86 | `scripts/teammate-idle-guard.sh:37` | `>> "$LOG_FILE" 2>/dev/null \|\| true` | log write failure inside log_event() | (a) | Same telemetry-only helper as line 33. |
| 87 | `scripts/teammate-idle-guard.sh:57` | `if [ -z "$NAME" ]; then log_event allow; exit 0; fi` | no recognizable teammate-name field in payload | (c) | Explicitly commented (line 55): "No name -> fail open." Same RULES.md §17 design as line 14; also logged (log_event), not silent. |
| 88 | `scripts/teammate-idle-guard.sh:69` | `if [ ! -f "$MANIFEST" ]; then log_event allow; exit 0; fi` | no dispatch manifest for this teammate name | (a) | Explicitly commented: "no manifest means not a Nazgul-dispatched teammate." |
| 89 | `scripts/teammate-idle-guard.sh:83` | `if [ -z "$REPORT_PATH" ]; then log_event allow; exit 0; fi` | manifest has no report_path field | (b) | Extends the file's stated "fail open on unparseable payloads" design, but the specific sub-case of a CORRUPT/unreadable manifest (jq read failure on $MANIFEST, `// ""` default) producing the identical log line as a genuinely field-less manifest is not itself named in the header or RULES.md §17. Recommend citing this sub-case explicitly if the (c) disposition is meant to cover it. |
| 90 | `scripts/pre-tool-guard.sh:10` | `if [ -z "$INPUT" ]; then INPUT=$(cat 2>/dev/null \|\| echo ""); fi` | arg not supplied | (a) | Standard arg-then-stdin fallback. |
| 91 | `scripts/pre-tool-guard.sh:15` | `if [ -z "$INPUT" ]; then exit 0; fi` | stdin read failure / no input | (b) | HIGH — INVENTORY ONLY, no fix permitted this task (owned by FEAT-023). "If no input, allow" — the entire destructive-command blocklist (rm -rf /, DROP TABLE, curl\|sh, fork bombs, force-push to main/master) is skipped whenever both the positional arg and stdin read come back empty. Largest documented blast radius of any site in this inventory. |
| 92 | `scripts/pre-tool-guard.sh:24` | `CMD=$(printf '%s' "$INPUT" \| jq -r '.tool_input.command // empty' 2>/dev/null \|\| true)` | jq extraction failure | (a) | `\|\| true` only prevents `set -e` from killing the script; the actual recovery is the line-25/26 fallback below, which is MORE conservative (scans the whole envelope), not less. |
| 93 | `scripts/pre-tool-guard.sh:25` | `if [ -z "$CMD" ]; then CMD="$INPUT"; fi` | jq extraction returned empty | (a) | Fallback to the raw envelope as the scan target; not an allow branch. |
| 94 | `scripts/pre-tool-guard.sh:73` | `echo "$CMD" \| grep -qiE "$dbcli" \|\| return 0` | no DB-CLI token anywhere in the command | (c) | Audited in-file (lines 54-65, FEAT-019/LR-005): a deliberate scope-narrowing to avoid the over-blocking false positives the bare-keyword grep produced pre-FEAT-019 ("still requires a DB-CLI token present... immune to segment-splitting bypasses"). |
| 95 | `scripts/lib/review-evidence.sh:66` | `[ -f "$diff_path" ] \|\| return 0` | diff.patch missing | (a) | Safe by construction: `_re_diff_files` feeding empty `files` into reviewer-selection.sh's conservative "empty/unparseable --files -> select everyone, skip no one" policy makes ANY non-empty skipped[] claim fail authenticity verification (fails closed); only an also-empty claim (all reviewers dispatched) passes, which still requires every reviewer's file to exist and be APPROVED downstream. |
| 96 | `scripts/lib/review-evidence.sh:100` | `[ -f "$config" ] && conditional=$(jq ...)` | config.json absent | (a) | `conditional` stays at its "false" default when config is absent; correct (conditional dispatch is opt-in). |
| 97 | `scripts/lib/review-evidence.sh:107` | `[ -f "$config" ] && roster=$(jq ...)` | config.json absent | (a) | `roster` stays empty when config is absent; downstream reviewer-selection.sh treats empty roster conservatively. |
| 98 | `scripts/lib/review-evidence.sh:385` | `if [ -z "$receipt_hash" ]; then _re_unit_has_any_receipt && return 1; return 0; fi` | no receipt captured for this exact (unit, reviewer) | (c) | POSITIVE PRECEDENT — this is the looked/never-looked distinction this whole objective is about, already correctly implemented: "Gate-satisfying (not a mismatch) only when NOTHING was captured for this unit at all" (comment lines 386-387). If something WAS captured for the unit but not this reviewer, it fails closed (return 1). Worth citing alongside `_resolution_integrity_ok()` as a second worked example. |
| 99 | `scripts/lib/review-evidence.sh:527` | `if [ ! -f "$task_file" ]; then echo "$task_id"; return 0; fi` | resolve_review_unit(): task manifest missing (group granularity) | (c) | Audited in-file (lines 508-510): "Degrades to <task_id> on any ambiguity... never fails open on a genuine evidence check; it just falls back to the one mode where task_id IS the review unit." A safe degrade to a MORE restrictive mode, not a skip. |
| 100 | `scripts/lib/review-evidence.sh:540` | `if [ -z "$feat_id" ]; then echo "$task_id"; return 0; fi` | resolve_review_unit(): feat_id absent (feature granularity) | (c) | Same audited safe-degrade as line 527. |
| 101 | `scripts/lib/review-evidence.sh:615` | `if [ -z "$configured_reviewers" ]; then echo NO_REVIEWERS_CONFIGURED; return 1; fi` | agents.reviewers empty/config unreadable | (a) | NOT an allow branch despite matching the textual pattern — returns 1 (a blocking problem code); correctly fails closed when no reviewers are configured. |
| 102 | `scripts/lib/review-evidence.sh:631` | `[ -z "$reviewer" ] && continue` | blank line while iterating configured_reviewers | (a) | Standard loop hygiene. |
| 103 | `scripts/lib/review-evidence.sh:633` | `if [ ! -f "$rf" ]; then _re_is_authorized_skipped && continue; echo MISSING; fi` | reviewer file absent | (a) | The `continue` path requires `_re_is_authorized_skipped` to independently verify the skip against the manifest+diff (see review-provenance.sh); otherwise falls through to the MISSING problem code (blocking). Not an unconditional allow. |
| 104 | `scripts/lib/review-evidence.sh:666` | `[ -f "$rf" ] \|\| continue` | glob no-match over review_dir/*.md | (a) | Standard glob-loop guard. |
| 105 | `scripts/lib/task-transition-guard.sh:57` | `[ -n "$sha" ] \|\| continue` | blank line while iterating extracted hex candidates | (a) | Standard loop hygiene in ttg_verify_commit_evidence's search loop. |
| 106 | `scripts/lib/task-transition-guard.sh:84` | `jq ... >> "$ledger" 2>/dev/null \|\| true` | guarded-transition ledger append failure | (a) | Telemetry/audit-trail append; a failure here does not affect the transition already granted by ttg_valid_transition/evidence gates above it, and stop-hook.sh's reconciliation pass treats a missing ledger entry as unguarded (fails closed on ITS side) rather than trusting silence. |
| 107 | `scripts/lib/task-transition-guard.sh:85` | `tail -n 500 ... && mv ... \|\| true` | ledger trim/rotate failure | (a) | Same telemetry housekeeping as line 84; genuinely optional cleanup. |
| 108 | `scripts/lib/task-utils.sh:109` | `raw=$(get_task_field ...); [ -n "$raw" ] \|\| return 0` | "Files modified" field absent or malformed | (b) | A MALFORMED JSON value (line 110's `jq -r '.[]'` failing) prints a loud stderr WARN but the function still returns empty via the same path as a genuinely-absent field — both are indistinguishable to every caller. task-state-guard.sh's file-scope guard treats empty as "no restriction declared" and allows editing ANY file under the active task, so a malformed `Files modified` value silently disables file-scope enforcement despite the WARN being emitted. |
| 109 | `scripts/lib/task-utils.sh:120` | `[ -f "$f" ] \|\| continue` | glob no-match (count_tasks_by_status) | (a) | Standard glob-loop guard. |
| 110 | `scripts/lib/task-utils.sh:176` | `[ -f "$task_file" ] \|\| continue` | glob no-match (count_tasks_and_find_active, pass 1) | (a) | Standard glob-loop guard. |
| 111 | `scripts/lib/task-utils.sh:214` | `[ -f "$task_file" ] \|\| continue` | glob no-match (count_tasks_and_find_active, pass 2) | (a) | Standard glob-loop guard. |
| 112 | `scripts/lib/task-utils.sh:236` | `[ -f "$f" ] \|\| continue` | glob no-match (get_active_task) | (a) | Standard glob-loop guard. |
| 113 | `scripts/lib/review-provenance.sh:65` | `[ -n "$full" ] \|\| return 1` | sha256 of nonce/diff_hash/unit_id empty | (a) | NOT an allow branch — propagates failure (return 1) up to write_dispatch_manifest, which aborts the whole manifest write; correctly fails closed at this point. |
| 114 | `scripts/lib/review-provenance.sh:130` | `[ -z "$entry" ] && continue` | blank entry while parsing skipped_raw | (a) | Standard loop hygiene. |
| 115 | `scripts/lib/review-provenance.sh:186` | `[ -d "$review_dir" ] \|\| return 0` | reviews/<unit>/ doesn't exist yet | (a) | Task hasn't reached review stage; review-evidence.sh's NO_REVIEW_DIR gate independently covers the IN_REVIEW transition, so this is not applicable here. |
| 116 | `scripts/lib/review-provenance.sh:190` | `[ -f "$rf" ] \|\| continue` | glob no-match over review_dir/*.md | (a) | Standard glob-loop guard. |
| 117 | `scripts/lib/review-provenance.sh:198` | `if [ ! -f "$manifest" ]; then ... [ has_any_token -eq 0 ] && return 0; echo NO_DISPATCH_MANIFEST; return 1; fi` | .dispatch.json missing, no reviewer file carries a token | (c) | Audited in-file (lines 178-180): "Degrades to allow: no reviewer files yet, or a legacy review (no manifest and no reviewer file carries any review_token:)." The file's own "HONEST TIER" header additionally frames this as tamper-EVIDENCE, not authentication, by design. CAVEAT: on a host missing both sha256sum and shasum, write_dispatch_manifest (line 104) never succeeds and no manifest is EVER written for that host — this specific root cause (total, permanent degrade from a missing tool, vs. an ordinary legacy review) is not itself named in the audit comment. |
| 118 | `scripts/lib/parallel-batch.sh:24` | `[ -f "$file" ] \|\| continue` | glob no-match (_pb_task_map_from_dir) | (a) | Standard glob-loop guard. |
| 119 | `scripts/lib/parallel-batch.sh:157` | `[ -f "$file" ] \|\| continue` | glob no-match (_pb_blocked_tasks) | (a) | Standard glob-loop guard. |
| 120 | `scripts/lib/parallel-batch.sh:186` | `[ -d "$reviews_dir" ] \|\| return 0` | nazgul/reviews/ doesn't exist yet | (c) | Audited in-file (lines 176-178): "A missing nazgul_dir/reviews_dir, or a task with no security-reviewer.md yet, is a normal not-yet-reviewed state — not ambiguous, no halt." Sibling function `_pb_blocked_tasks` (same file) explicitly fails CLOSED on an unreadable tasks_dir — the contrast is itself documented. |
| 121 | `scripts/lib/parallel-batch.sh:192` | `[ -f "$file" ] \|\| continue` | glob no-match (_pb_security_rejections) | (a) | Standard glob-loop guard. |
| 122 | `scripts/lib/parallel-batch.sh:234` | `[ -f "$file" ] \|\| continue` | glob no-match (compute_dispatch_batch candidate scan) | (a) | Standard glob-loop guard. |
| 123 | `scripts/lib/parallel-batch.sh:237` | `[ "$status" = "READY" ] \|\| continue` | candidate task not READY | (a) | Correct filter; status always resolves to a value (default "PLANNED") via get_task_status. |
| 124 | `scripts/lib/parallel-batch.sh:281` | `[ -n "$cur_wave" ] \|\| continue` | plan.md line precedes any "### Wave N" heading | (a) | Standard parser hygiene. |
| 125 | `scripts/lib/parallel-batch.sh:315` | `if [ -z "$files" ]; then _pb_single_result "missing file scope"; return 0; fi` | candidate's "Files modified" empty/malformed (shares task-utils.sh:109's ambiguity) | (c) | Audited in-file (line 311): "missing/empty/malformed scope -> fallback." Degrades to a single-task (sequential) batch rather than admitting the task into a multi-task PARALLEL batch — the safe direction, since sequential dispatch sidesteps the disjointness question the missing scope would otherwise leave unverified. |

## Manually-found sites beyond the textual grep

The reproducing grep above is precise and re-runnable, but it cannot catch every semantic shape of
this pattern class — some genuine sites use comparison operators (`!=`) or multi-word variable
expansions the grep's clauses don't match. These four were found by reading the 16 files in full, not
by the grep, so they are **not counted in the 125/90/18/17 totals above** to keep that count exactly
reproducible. They are real findings and are ranked among the most serious below.

| Site | What empty/missing means | Class | Disposition |
|---|---|---|---|
| `scripts/parallel-dispatch-guard.sh:71` — `if [ -n "$UNIT" ] && [ -f "$TASKS_DIR/$UNIT.md" ] && is_work_unit "$SUBAGENT"; then` | The task file named by a present `NAZGUL_UNIT` marker doesn't exist at the resolved path | (b) | An UNAUDITED sibling to the same file's own `_resolution_integrity_ok()` (the task's cited worked (c) example): that function only covers `TASKS_DIR` failing to canonicalize under `NAZGUL_DIR`. It does NOT cover the narrower case of `$TASKS_DIR/$UNIT.md` itself not existing (stale unit ID, race, wrong root) — that case falls straight through to the file's terminal `exit 0` with no logging, unlike the audited case which at least emits `dispatch_guard_resolution_unconfirmed`. |
| `scripts/local-mode-tracking-guard.sh:219-221` — `INSTALL_MODE=$(jq -r '.install_mode // ""' "$CONFIG" 2>/dev/null \|\| echo ""); if [ "$INSTALL_MODE" != "local" ]; then exit 0; fi` | `nazgul/config.json` present but unparseable JSON | (b) | Same MF-053-class gap identified in the main table for the two git-level hooks (rows 5, 20): no `jq -e .` validity pre-check. A corrupt-but-present config makes `INSTALL_MODE` default to `""`, read as "not local mode," and the guard silently disarms — on a file whose own header (row 30/71 above) already documents OTHER degradations as deliberate, but not this one. |
| `scripts/lib/task-utils.sh:110` (documented at `scripts/task-state-guard.sh:222-223`'s comment) | task-state-guard.sh's file-scope guard treats a malformed `Files modified` value identically to a genuinely-absent one | (b) | Already covered as the disposition text for main-table row 109 (`task-utils.sh:109`); listed here only as a cross-reference so the two-file nature of the finding (library + the guard that consumes it) is visible in one place. Not double-counted. |
| `scripts/teammate-idle-guard.sh:41-45` — `if PAYLOAD_JSON=$(printf '%s' "$INPUT" \| jq -c '.' 2>/dev/null); then :; else PAYLOAD_JSON=...; log_event "allow" "unparseable payload"; exit 0; fi` | stdin content is not valid JSON | (c) | This is the CONCRETE site backing the file's header-documented "Fails OPEN on unparseable payloads" design (RULES.md §17) already cited for rows 81/87 in the main table — recorded here because it is the literal unparseable-payload branch itself, which the `if VAR=$(...); then :; else` shape put outside the grep's reach. |

## What was bounded, and what was dropped

- **File-scope boundary (D3, stated by the plan, not widened here):** this document covers exactly the
  16 files listed at the top. The ~30 remaining scripts with a `|| continue`/`|| exit 0`/`|| true`/
  `[ -z "$X" ] &&` shape are filed, with re-derived per-file counts and the reproducing grep, to
  `nazgul/inbox/guard-fail-open-sweep-remainder.md`.
- **Pattern-class boundary:** only the textual/semantic shapes enumerated in the Methodology section
  (TRD's five forms plus the five extensions the reproducing grep documents — ten alternations in
  total) were searched for.
  Other shapes of "ambiguity resolved toward permission" almost certainly exist in these same 16 files
  (e.g. a `case` statement's default arm, or a value silently coerced by a `// default` jq expression
  three call-frames away from where it's checked) that neither this grep nor a plausible one-line
  extension of it would catch without materially more manual reading time than this task budgeted.
  The four items in "Manually-found sites beyond the textual grep" above are what that additional
  reading time did surface; it should not be read as proof no more remain.
- **`scripts/pre-tool-guard.sh` was classified but not modified**, per the task's hard constraint —
  including its most serious finding (row 91: "if no input, allow" on the destructive-command
  blocklist, the largest blast-radius site in this entire inventory).
- **No site classified (a) was re-litigated for a "should it actually be (b)" second opinion beyond the
  single pass documented in each row's disposition** — a second, independent reviewer re-reading all 90
  (a) rows was outside this task's time budget; the review board is the intended second pass.
