---
name: nazgul:complete
description: "Close out an objective whose PR has already merged — ask the host whether it merged, record the merge evidence, and walk every stranded task to DONE through the sole sanctioned writer. Use when asked to close the objective, finish tasks after a merge, or when manifests are stuck at IMPLEMENTED or IN_REVIEW because the PR merged outside the loop."
context: fork
allowed-tools: Bash, Read
metadata:
  author: Jose Mejia
---

# Nazgul Complete

## Examples
- `/nazgul:complete` — Resolve this objective's PR from config and close every task it shipped
- `/nazgul:complete 88` — Close against PR #88 explicitly
- `/nazgul:complete https://github.com/OrodruinLabs/nazgul/pull/88` — Same, by URL

## Arguments

$ARGUMENTS

## Instructions

Format all output per `${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md` — stage banner, status symbols,
no emoji.

`${CLAUDE_PLUGIN_ROOT}/scripts/close-objective.sh` is the entire implementation. This skill resolves
two values for it (the runtime-state root and the PR), runs it once, and reports what it said. It
adds no logic and decides nothing the script did not already decide.

### Step 1: Resolve the runtime-state root

Runtime state is addressed, never inherited (RULES.md §21 / ADR-021). The cwd may be a task worktree
whose `nazgul/` is gitignored, so a relative `nazgul/...` would read or create the wrong tree and
still exit 0. Resolve one absolute root first:

```bash
CANDIDATE="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
ROOT="$(jq -r '.branch.main_worktree_path // empty' "$CANDIDATE/nazgul/config.json" 2>/dev/null)"
[ -n "$ROOT" ] && [ -f "$ROOT/nazgul/config.json" ] || ROOT="$CANDIDATE"
[ -f "$ROOT/nazgul/config.json" ] || { echo "no Nazgul runtime state under ${ROOT:-<unresolved>}"; exit 1; }
printf 'main_worktree_path=%s\n' "$ROOT"
```

If that prints nothing usable, stop and report it — do not guess a root from the cwd and do not run
the closer against a tree you did not confirm. Otherwise substitute the printed absolute path as a
literal into every command below (each Bash call is a fresh shell; `$ROOT` does not survive between
them). Never write a relative `nazgul/...` anywhere in this skill's execution.

### Step 2: Resolve the PR

The closer takes `--pr <number|url>` and there is no default — a PR is the only thing it can ask the
host about. Resolve it in this order and stop at the first hit:

1. `$ARGUMENTS`, when it carries a PR number or a `.../pull/<n>` URL. An explicit argument always wins.
2. The objective's own recorded PR, from config:

```bash
CONFIG="<ROOT>/nazgul/config.json"
FEAT="$(jq -r '.feat_id // empty' "$CONFIG")"
jq -r --arg f "$FEAT" '
  ([.stack.layers[]? | select(.feat_id == $f) | .pr]
   + [.objectives_history[]? | select(.feat_id == $f) | .pr])
  | map(select(. != null and . != "")) | last // empty' "$CONFIG"
```

`stack.layers[]` is present only when `execution.stacking` is enabled; `objectives_history[].pr` is
written for every objective that opened a PR. If both are empty, stop and ask the operator for the PR.
Never scan open PRs and never infer one from the branch name — closing the wrong objective's tasks is
the failure mode this whole command exists to prevent.

### Step 3: Run the closer

```bash
CLAUDE_PROJECT_DIR="<ROOT>" bash "${CLAUDE_PLUGIN_ROOT}/scripts/close-objective.sh" \
  --pr "<PR>" --project-root "<ROOT>" 2>&1; echo "exit=$?"
```

`CLAUDE_PROJECT_DIR` is the bridge from an addressed path to a script that resolves its own root;
`--project-root` names the same tree to the script directly. Pass both, always the same absolute path.

**Capture both streams.** The `2>&1` is required, not incidental: the terminal coverage line, each
`closed` line, and the ancestry-corroboration line go to stdout, while every `skipped` and every
`REFUSED` record goes to stderr. Dropping stderr would make a run that refused nine tasks print
exactly like a clean one.

Run it once. It is not idempotent in a harmful way — a re-run finds already-closed tasks
`already-terminal` — but a refusal is an outcome to act on, never an error to retry blindly.

### Step 4: Report it VERBATIM

Print a `─── ◈ NAZGUL ▸ COMPLETE ────────────────────────────────` banner, then reproduce **every
captured line**, in the order printed, copied character-for-character. Drop none. In particular:

1. Every `close-objective: closed TASK-NNN (...)` line.
2. Every `close-objective: skipped TASK-NNN [reason] — ...` line and every
   `close-objective: REFUSED TASK-NNN [reason: ...] — ...` record.
3. Any run-wide line: `close-objective: no closure for PR <n> [<reason>] — ...`,
   `close-objective: NOTHING CHECKED — ...`, and every `merge-provider: ...` diagnostic. These name
   why nothing closed; a report without them is a report that a merge check silently did not happen.
4. The ancestry-corroboration line, if present. `ancestry=squash_signature` is the expected reading
   on a squash-merging host and is not a warning.
5. The terminal coverage line, exactly as printed, including its `close-objective:` prefix, all seven
   skip reasons, and every `=0` among them:

```text
close-objective: N scanned, M skipped (already-terminal=…, not-closable-status=…, unreadable=…, not-merged=…, merge-unverifiable=…, evidence-write-failed=…, transition-refused=…), K closed, F refused
```

6. The exit code and its meaning: `0` at least one task closed with no refusal (✦), `1` at least one
   refusal (✗ — the run completed, act on each record above), `2` NOTHING CHECKED, nothing was closed
   (⚠), `3` usage or precondition error, or an internal coverage-accounting mismatch (✗). The
   precedence is the script's: an accounting mismatch reports `3` even when there were refusals, and
   a refusal reports `1` even when nothing closed.

Close with the Next Up block.

> **Verbatim is a load-bearing constraint, not a formatting preference (PRD AC21). Do not soften it.**
> A friendly summary is exactly how a partially-closed objective comes to read as a clean one, which
> is the failure this command was built to remove. Do not summarise, round, re-aggregate, re-narrate,
> translate a reason token into prose, drop a zero-valued counter, or collapse per-task records into a
> count. If the output looks noisy, the noise IS the record. An editor who "tidies" this step deletes
> the guarantee, not the clutter.

### What this command does and does not do

- **Closure is on merge evidence only.** The script asks the host's PR API through
  `scripts/lib/merge-provider.sh` and closes nothing unless that host ANSWERS that the PR merged and
  returns a usable `host` / `pr` / `merged-at` / `merge-commit`. It never consults git ancestry: after
  a server-side squash merge no SHA in any manifest's `## Commits` section is an ancestor of the base
  branch, so ancestry is inverted there, not merely weak.
- **`could not look` is never `not merged`.** `merge-unverifiable` and `not-merged` are separate
  reasons on purpose. Report whichever one came back; do not translate one into the other.
- **Only `IMPLEMENTED` and `IN_REVIEW` are closable.** `DONE`/`CANCELLED` are `already-terminal`;
  everything else is `not-closable-status`. The command never invents a review verdict, a review
  directory, or a commit.
- **Every status change goes through `scripts/task-transition.sh`** — compare-and-swapped under a
  per-task lock, verified on disk, and recorded as a completed edge (ADR-020 / RULES.md §2). Neither
  the script nor this skill writes a status by any other route, and neither touches manifest
  frontmatter directly.
- **There is no manual fallback, and you must not offer one.** If the closer refuses, the answer is
  the refusal reason. Hand-editing a manifest is the failure this command replaces: a status written
  outside `scripts/task-transition.sh` is quarantined by the stop-hook's bash-write reconciliation
  pass on the next iteration, and only `scripts/task-transition.sh repair TASK-NNN` can leave that
  quarantine.

### Acting on a refusal

| Reason | What it means | Next step |
|--------|---------------|-----------|
| `already-terminal` | Task is already `DONE` or `CANCELLED` | Nothing — expected on a re-run |
| `not-closable-status` | Real status, but not `IMPLEMENTED`/`IN_REVIEW` | Finish the task normally; the closer never skips the state machine |
| `unreadable` | No resolvable regular non-symlink manifest | Inspect that manifest by hand; do not edit a status to route around it |
| `not-merged` | The host answered: this PR is not merged | Merge the PR, then re-run |
| `merge-unverifiable` | The host could not be asked, or answered unusably | Fix auth/remote/PR id (`/nazgul:doctor`), then re-run |
| `evidence-write-failed` | `## Merge Evidence` could not be recorded or did not read back | Check manifest permissions and the stderr detail, then re-run |
| `transition-refused` | The sole sanctioned writer refused the walk to `DONE` | Read the quoted refusal — it names the missing evidence; satisfy it, then re-run |
