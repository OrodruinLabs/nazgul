# Dimension 5 Findings — Parallel + Heartbeat + Connectors

**Task:** TASK-005 · **Scope:** `scripts/lib/parallel-batch.sh`, `scripts/heartbeat.sh`,
`scripts/lib/heartbeat-triage.sh`, `scripts/lib/inbox-provider.sh`,
`scripts/lib/connector-github.sh`, `scripts/worktree-utils.sh`, the Teammate Report Contract
(`docs/superpowers/plans/2026-07-22-teammate-report-contract.md`,
`docs/superpowers/specs/2026-07-22-teammate-report-contract-design.md`,
`agents/team-orchestrator.md`, `scripts/teammate-idle-guard.sh`, `hooks/hooks.json`),
`skills/heartbeat/SKILL.md`, plus cross-checks against `RULES.md` §11–17,
`agents/planner.md`, `scripts/stop-hook.sh` (parallel-batch call site only),
`scripts/lib/git-hooks.sh`, `scripts/session-context.sh` (git-hooks self-heal call site only),
`scripts/lib/task-utils.sh` (`get_task_field`), and `nazgul/tasks/TASK-001..011.md` /
`nazgul/plan.md` as live-format evidence.

## Coverage disclosure

Every primary-scope file was read in full. `agents/team-orchestrator.md` was read in full
(139 lines). `RULES.md` §11–17 was read in full as cross-check context; the rest of RULES.md
was not read (out of scope). Verified anchor #2 (emit-event jq bug) required reading
`scripts/emit-event-cli.sh` and grepping `scripts/lib/emit-event.sh` — done, and it is
formally cleared below as out of dimension-5 scope. No sampling/top-N caps were applied; no
re-dispatch was needed (single pass, no tool failures). One live-repo observation
(`nazgul/logs/teammate-idle.jsonl` and `nazgul/dispatch/` both absent) is reported as
circumstantial runtime evidence, explicitly flagged PLAUSIBLE-not-CONFIRMED where I could not
rule out an innocent explanation (see Finding 7).

---

## Known anchors

### Anchor 1 — Teammate-report-contract follow-ups (v2.17.0 deferred items)

ROOT-CAUSED. All four accepted follow-ups were re-verified directly against the shipped code
(not just trusted from memory):

- **Fail-open branches without tests** — CONFIRMED still open. See Finding 6.
- **Label sweep** (stale version-number test labels in `tests/test-migrate-config.sh`) —
  CONFIRMED still open. See Finding 11.
- **First-run telemetry watch** — CONFIRMED still open (stronger than "unwatched": the log has
  literally never been created, see Finding 7).
- **`team-orchestrator.md` duplicate "3." step numbering** — CONFIRMED still present. See
  Finding 8.
- Two items from the same memory not in the manifest's literal anchor text but part of the same
  accepted-follow-ups set were also re-verified: the **worktree guard escape** is documented
  (not yet fixed) at `RULES.md:482-487` — folded into Finding 7's analysis; the **dead
  `.delivered` field** is CONFIRMED, see Finding 10.

### Anchor 2 — emit-event jq bug

CLEARED as out of dimension-5 scope. The bug lives entirely in `scripts/lib/emit-event.sh:42`
(`jq --argjson iter "$CURRENT_ITERATION"` breaking on an empty/non-numeric iteration value) and
is invoked only via `scripts/emit-event-cli.sh`, which is called from `agents/review-gate.md`,
`scripts/stop-hook.sh`, `scripts/task-completed.sh`, `scripts/subagent-stop.sh`,
`scripts/stop-failure.sh`, and `agents/doc-verifier.md` (dimensions 1, 2, and 8 territory).
Verified by grep: none of the six dimension-5 files (`parallel-batch.sh`, `heartbeat.sh`,
`heartbeat-triage.sh`, `inbox-provider.sh`, `connector-github.sh`, `worktree-utils.sh`) source
or call `emit_event`/`emit-event-cli.sh` anywhere. `nazgul/improvements.md:288-291,439-442`
records the incident under FEAT-009/FEAT-010, confirming it was raised during review-gate
finalization, not a heartbeat/parallel/connector code path.

---

## Findings

### Finding 1 — CRITICAL — bug — Git-level hooks (RULES §15 safety net) never install in production; `worktree-utils.sh` is dead code

**Evidence:** `scripts/worktree-utils.sh:62-64` (`create_feature_branch`) and `:62`
(`setup_worktree_dir`, via the sourced `install_git_hooks`) are the **only** call sites for
`install_git_hooks` in the entire repo (`scripts/lib/git-hooks.sh:1-5` documents this as design
intent: "Sourced by worktree-utils.sh (install/uninstall) and session-context.sh
(self-heal)"). A repo-wide grep for `worktree-utils` (excluding `nazgul/archive/`) shows it is
sourced by exactly one file: `tests/test-git-hooks-wiring.sh:10`. No production script or agent
prompt sources `scripts/worktree-utils.sh` — not `scripts/stop-hook.sh`, not
`agents/team-orchestrator.md`, not `agents/implementer.md`, not any `skills/*/SKILL.md`. The
actual branch/worktree setup in production is done as **inline Bash-tool instructions** written
directly into `skills/start/SKILL.md` (4 separate occurrences of the same
"checkout branch → create worktree dir" recipe at lines 183-191, 258-264, 282-287, 301-306) and
`agents/implementer.md:113` (`git worktree add ... ` or `EnterWorktree`), and inline in
`scripts/stop-hook.sh:1165-1167`'s batch `DISPATCH_INSTR` text for merges — none of these call
into `worktree-utils.sh`'s functions, because they are markdown-driven LLM instructions, not
bash scripts that could source a bash library.

Consequence, traced through `scripts/lib/git-hooks.sh:189-211`
(`self_heal_git_hooks`): self-heal requires `branch.prior_hooks_path != null` (line 203-204)
before it will do anything — but that field is only ever written inside `install_git_hooks`
(called from the now-confirmed-dead `create_feature_branch`/`setup_worktree_dir`). Since
`branch.feature` is set by `skills/start/SKILL.md`'s inline steps without ever calling
`install_git_hooks`, `branch.prior_hooks_path` is never recorded on a real project, so
`self_heal_git_hooks` (wired into `scripts/session-context.sh:82-90`'s SessionStart block) also
permanently no-ops. Net effect: `core.hooksPath` is **never** pointed at the managed
`nazgul/.githooks/` directory on a real Nazgul project — the pre-commit base-branch guard and
pre-merge-commit H2 parallel-unit-verdict guard (RULES.md §15, the "go git-level" fix that
closed the command-parsing arms race per this repo's own incident history) do not activate.

**Failure scenario:** A user runs `/nazgul:init` then `/nazgul:start "objective"` on a fresh
project. `branch.feature` gets set via `skills/start/SKILL.md`'s inline `git checkout -b`
step. `install_git_hooks` is never called, `core.hooksPath` is never touched, and
`branch.prior_hooks_path` stays `null` forever, so `self_heal_git_hooks` no-ops on every
subsequent SessionStart too. Any git-level protection RULES §15 claims exists — base-branch
guard, H2 pre-merge-commit verdict guard — is inert. All the safety the "go git-level" redesign
was meant to buy back (after two proven bypasses of the command-string-parsing guards) is not
actually installed for a real user, only for the isolated unit tests that source
`scripts/worktree-utils.sh` or `scripts/lib/git-hooks.sh` directly.

**Recommendation:** Either (a) wire `install_git_hooks` into the actual branch-creation call
site — add a bash step to `skills/start/SKILL.md`'s branch-setup instructions (all 4
occurrences) that shells out to `install_git_hooks`/records `branch.prior_hooks_path`, or move
the branch-setup logic itself into a sourced helper script the skill invokes — or (b) delete
`scripts/worktree-utils.sh` and `install_git_hooks`/`uninstall_git_hooks` entirely and rebuild
the install trigger directly inside `session-context.sh` (which already runs on every
SessionStart and already has the self-heal half). This is very likely this audit's single
highest-impact finding: it silently invalidates a previously-shipped safety fix
(cross-references dimension 4's git-level-hooks territory for the consequence half).

### Finding 2 — CRITICAL — bug — GitHub connector's PUSH half is an unreachable no-op; the map never gets a real local id

**Evidence:** `scripts/lib/connector-github.sh:88-99` (`_cgh_map_put`) only writes a real value
into `.connectors.github.map[$id]` when called with a non-empty 3rd argument (`feat`); called
with 2 args it writes/keeps a `null` stub. The only production caller is
`connector_github_pull_archive` (`connector-github.sh:270-282`), which calls `_cgh_map_put
"$config" "$id"` at both line 276 and line 281 — **always the 2-arg (stub) form**. A repo-wide
grep confirms `_cgh_map_put` is never called with a 3rd argument anywhere outside
`connector-github.sh` itself (no caller in `scripts/`, `agents/`, or `skills/` ever supplies a
real local id). `_cgh_map_resolve` (`connector-github.sh:121-128`) looks up an issue number by
searching for `.value == $local_id` — since every map value is permanently `null`, this can
never match a real `local_id`, so `connector_github_push_status`
(`connector-github.sh:137-155`, gated at line 141-142 on `_cgh_map_resolve` returning
non-empty) and `connector_github_push_pr` (`connector-github.sh:163-183`, same gate at line
170-171) are unconditionally unreachable no-ops in production, despite being wired live into
`scripts/stop-hook.sh:705,707` on every task status transition.

`tests/test-connector-github.sh:267-268` proves this directly: to exercise `push_status`/
`push_pr` at all, the test has to fabricate the map state by hand —
`jq '.connectors.github.map = {"43":"FEAT-012"}'` — completely bypassing
`connector_github_pull_archive`/`_cgh_map_put`. The real pull→archive→claim flow can never
produce that map shape (see Anchor 2's "43" -> null stub proof at
`tests/test-connector-github.sh:214`: `pull_archive records map[42]` only asserts `has("42")`,
never a value). No test exercises the actual production sequence
(`pull_list` → `pull_archive` → `push_status`) end-to-end.

**Failure scenario:** An operator sets `connectors.github.enabled: true` and
`connectors.github.push.enabled: true` expecting the documented two-way sync (CLAUDE.md: "pulls
opt-in-labeled issues into the inbox... pushes task status + PR links back to the mapped
issue"). Issues get pulled, claimed (labeled `nazgul-claimed`), and started correctly — the pull
half genuinely works. But no `nazgul-status:*` label and no PR-link comment ever appears on the
originating issue, because the map only ever holds `null` for every claimed issue. The feature
silently does half of what it claims to, indefinitely, with no error, warning, or log line
anywhere (`push_status`/`push_pr` both return 0 on their early "nothing mapped" exit — the same
exit code as "push gate is off" or "already up to date").

**Recommendation:** Thread the picked issue number through to a real local id. The natural spot
is `scripts/heartbeat.sh`'s archive-then-start flow: after `inbox_archive` claims candidate
`$PICKED` (an issue number, on the `github` provider) and before/around `_hb_start`, call
`_cgh_map_put "$CONFIG" "$PICKED" "<feat_id>"` once the started objective's `feat_id` is known —
but `_hb_start` invokes `claude -p` as a detached CLI call with no return channel for the new
session's assigned `feat_id`, so this likely needs a second write-back step (e.g., the started
session's branch-setup step in `skills/start/SKILL.md` writing the resolved-issue-to-feat_id
link back into config when it detects it was heartbeat-started from a github-provider pick).

### Finding 3 — HIGH — bug/fragility — parallel-batch's file-scope overlap dedup is corrupted by the JSON-array format real task manifests use

**Evidence:** `scripts/lib/parallel-batch.sh:289-303` builds the disjointness check by taking
each candidate's `Files modified` field (via `get_task_field`,
`scripts/lib/task-utils.sh:90-94` — a bare regex extraction with no JSON parsing), splitting on
literal commas (`${files//,/$'\n'}`), trimming only leading/trailing whitespace, then using
`sort | uniq -d` for exact-string duplicate detection. This assumes bare, unquoted,
comma-separated paths — exactly the format `tests/test-parallel-batch.sh:24-25`'s `make_task`
helper writes (e.g. `"src/a.sh, src/a2.sh"`). But every real task manifest in this repo uses a
**JSON array literal** instead: `nazgul/tasks/TASK-010.md:12` is
`["nazgul/context/objectives/FEAT-013/verification-verdicts.md",
"nazgul/context/objectives/FEAT-013/merged-findings.md"]` (confirmed across all of
TASK-001..011). `agents/planner.md:110` only says "Populate the `Files modified` metadata field
with this list" — it does not specify a format, and the planner (an LLM) naturally emits
JSON-array syntax.

Splitting a 2-element JSON array on the internal comma leaves the brackets/quotes attached
asymmetrically: `["a.md", "b.md"]` becomes two lines, `["a.md"` and `"b.md"]` — the first
element keeps its leading `[`, the last keeps its trailing `]`. Comparing this against a
different task whose single-file scope is `["b.md"]` (whole-string, both brackets) never
matches on exact-string dedup (`"b.md"]` ≠ `["b.md"]`), so a genuine file-scope overlap between
a multi-file-scoped task and another task touching the same file is **silently missed** unless
the overlapping file happens to sit at the same bracket-position in both scopes (e.g. both are
each task's sole/first array element).

**Failure scenario:** Planner marks two READY tasks in the same Wave Groups line, task A scoped
to `["src/shared.ts", "src/a.ts"]` and task B scoped to `["src/other.ts", "src/shared.ts"]`
(both touch `src/shared.ts`, at differing array positions). `compute_dispatch_batch`'s overlap
check compares `["src/shared.ts"` / `"src/a.ts"]` (task A) against `"src/other.ts"` /
`"src/shared.ts"]` (task B) — no exact string match, so the overlap is missed, `parallel: true`
fires, and `scripts/stop-hook.sh`'s batch `DISPATCH_INSTR` dispatches both implementers into
separate worktrees that both edit `src/shared.ts`, racing the merge step
(`stop-hook.sh:1167`, "merge each task branch... on conflict... never force-merge" — this
degrades to a manual conflict, not silent corruption, but the entire point of the disjointness
check is to prevent ever reaching that state).

**Recommendation:** Rewrite the overlap check to actually parse the field as JSON via `jq`
(`jq -c '.[]' <<< "$files"` or similar) instead of naive comma-splitting, and align
`agents/planner.md:110` and `tests/test-parallel-batch.sh`'s fixtures on one explicit,
documented format for `Files modified`.

### Finding 4 — HIGH — fragility — heartbeat's "never a second loop" concurrency guard has a TOCTOU race

**Evidence:** `scripts/heartbeat.sh:176-182` calls `count_active_sessions`
(`scripts/lib/session-tracker.sh:31-38`, a plain `ls *.lock | wc -l`) **before** archiving or
starting anything. The corresponding `.lock` file is only created by `register_session`
(`scripts/lib/session-tracker.sh:10-22`), which is called from
`scripts/session-context.sh:24` — i.e. inside the **new** session's own SessionStart hook,
which only runs once `_hb_start`'s `claude -p "/nazgul:start ..."` (`scripts/heartbeat.sh:118`)
has actually launched the CLI, authenticated, and reached its first hook. `session-tracker.sh`
provides no locking primitive (no `flock`, no atomic `mkdir`-based mutex) — it is pure
check-then-act.

**Failure scenario:** Two heartbeat ticks are invoked within the CLI-startup window (a few
seconds) — plausible whenever a scheduled routine and a manual `/nazgul:heartbeat` overlap, or
a routine's interval is shorter than a slow cold start. Both ticks reach the
`count_active_sessions` check before either's spawned session has written its `.lock` file, both
read `0`, both proceed past the guard, and both call `inbox_archive` + `_hb_start` — possibly on
two *different* inbox candidates (the archive-then-start pattern only prevents the same
candidate being double-started via `mv`'s atomicity; it does nothing to prevent two different
candidates each triggering their own full Nazgul loop concurrently against the same
`nazgul/` state). RULES.md §13 documents the guard as `[enforced]` and "the identical
session-lock mechanism `stop-hook.sh` uses," but the enforcement is check-then-act, not
atomic — the race window exists for `stop-hook.sh`'s own use of the same primitive too, though
that path is less exposed since Stop-hook firing implies a session is already active.

**Recommendation:** Make the claim atomic — e.g. `mkdir` a lock directory (atomic on POSIX
filesystems) as the very first action of `heartbeat.sh` itself (not deferred to the spawned
session's SessionStart hook), released on exit via `trap`, so two concurrent ticks race on the
`mkdir` itself rather than on a stale read of `ls`.

### Finding 5 — HIGH — fragility — Wave Groups line-format brittleness silently degrades `execution.parallel` to fully sequential

**Evidence:** `scripts/lib/parallel-batch.sh:267-282` requires `>=2` candidate `TASK-ID`s to
appear on **one** `## Wave Groups` bullet line (`grep -oE 'TASK-[0-9]+'` per line, `break` on
the first line with `>=2` matches) — matching the documented format at
`agents/planner.md:135-136`: `- TASK-001, TASK-002 (independent, no file overlap)`. But this
very objective's own `nazgul/plan.md:80-88` (Wave 1, all 8 dimension-audit tasks) lists **one
task per bullet line** (`- TASK-001 (creates ...)`, `- TASK-002 (creates ...)`, ...) — a
perfectly reasonable, more-readable Markdown convention that nonetheless means every line yields
exactly one `TASK-ID` match, so `compute_dispatch_batch` would never form a multi-task batch
from this plan.md's Wave 1 at all, permanently falling back to `"no wave line groups >=2 ready
tasks"` (line 281) with zero error, zero warning surfaced to the operator beyond a `reason`
string in a JSON blob most operators never read directly.

**Failure scenario:** This specific objective's parallel dispatch is actually driven by
`agents/team-orchestrator.md` (Agent Teams), which does not call `compute_dispatch_batch` at
all — confirmed by grep, `team-orchestrator.md` never references `compute_dispatch_batch` or
`parallel-batch.sh` — so this particular plan.md's one-task-per-line format happens not to
matter for *this* objective. But the underlying bug is general: any planner run (human-edited or
LLM-authored) that reformats a wave onto one-bullet-per-task — a natural edit for readability —
silently and permanently disables `execution.parallel` for that wave with the stop-hook's own
sequential loop, with no signal that anything is wrong (the loop just proceeds one task at a
time, indistinguishable from `execution.parallel: false`).

**Recommendation:** Make `compute_dispatch_batch` resilient to either bullet convention — parse
each wave's task membership from the `### Wave N` heading + all following `- TASK-NNN` bullets
until the next heading, rather than requiring same-line comma-grouping — or have the planner
agent emit a stop-hook-observable warning/self-check when a wave's tasks don't collapse onto
shared lines under `execution.parallel: true`.

### Finding 6 — MEDIUM — test-gap — teammate-idle-guard's newest fail-open branches are untested

**Evidence:** `scripts/teammate-idle-guard.sh:60-62` (`case "$NAME" in */*|*..*)` — rejects a
teammate name containing a path separator or `..`) and `:86-88` (`case "$REPORT_PATH" in
/*|*..*)` — rejects an absolute or traversal report path) were both added after the original
design (they don't appear in the pre-implementation plan's script draft at
`docs/superpowers/plans/2026-07-22-teammate-report-contract.md:178-286`, only in the shipped
script). `tests/test-teammate-idle-guard.sh` (147 lines, all 13 numbered + 2 renumbered cases
read) has no test that passes a `NAME` containing `/` or `..`, nor a `report_path` that is
absolute or contains `..` — test 13's "corrupt manifest" case exercises the *empty*
`report_path` branch (`:80-82`), not the unsafe-value branch. This matches
`project_teammate_report_contract_followups.md`'s "Tests for the newest fail-open branches
(unsafe NAME, absolute/`..` report_path, mktemp fail)" — re-verified true for two of the three
(mktemp fail *is* now covered, test 19).

**Failure scenario:** Both branches are currently correctly ordered before their respective
dangerous path joins (`MANIFEST="$DISPATCH_DIR/$NAME.json"` at line 65 comes after the NAME
check; `REPORT_ABS="$PROJECT_DIR/$REPORT_PATH"` at line 89 comes after the REPORT_PATH check),
so there is no live vulnerability today. But neither branch has a regression test, so a future
refactor (e.g. reordering the checks, or changing the `case` pattern) could silently reintroduce
a path-escape without any test catching it.

**Recommendation:** Add the two missing cases to `tests/test-teammate-idle-guard.sh`: a
manifest/payload combination that resolves `NAME` to something containing `/` (assert allow +
`"unsafe teammate name"` in the log), and a manifest with `report_path` set to `/etc/passwd` or
`../../etc/passwd` (assert allow + `"unsafe report_path"` in the log, and that no file at that
absolute path was touched).

### Finding 7 — MEDIUM — fragility — the TeammateIdle guard has apparently never fired in this repo's history; possibly explained by the already-known worktree gap

**Evidence:** `nazgul/logs/teammate-idle.jsonl` does not exist anywhere in the repository as of
this audit (`ls`/`wc -l` both fail with "No such file"), and `nazgul/dispatch/` (the manifest
directory) does not exist either. This matters because `log_event` in
`scripts/teammate-idle-guard.sh:29-35` fires unconditionally on **every** invocation, at the
very first gate (even the "no teammate name in payload" / "no dispatch manifest for X" allow
paths log an entry) — so if the `TeammateIdle` hook had fired even once for any teammate at all
since v2.17.0 shipped, this file would exist. `hooks/hooks.json:177-187` confirms the wiring is
present and correctly formed. This session itself has (per the system reminder) active/recent
teammates named `nazgul-TASK-001..004` and `nazgul-review-TASK-001..004`, which — per
`agents/team-orchestrator.md:69-72` — are documented to run "in its own worktree" for
implementers. `RULES.md:482-487` already documents, as a known and still-open limitation, that
`teammate-idle-guard.sh` resolves `nazgul/` via `CLAUDE_PROJECT_DIR`/cwd only, so "a teammate
whose session resolves to a git worktree without the shared `nazgul/` runtime exits untracked
(no enforcement, no telemetry)" — which is precisely the symptom observed (zero telemetry,
ever) for precisely the teammate topology (implementers in worktrees) the design documents as
standard.

**Honesty note (PLAUSIBLE, not CONFIRMED):** I cannot prove causation from static analysis
alone. The absent log/dispatch dirs are also fully consistent with an innocent explanation:
`agents/team-orchestrator.md:98-102` and `:55-59` instruct cleanup to delete
`nazgul/dispatch/<name>.json` at team teardown, and if every teammate that ever ran this
session (or in prior sessions) already went idle, reported, and had its team torn down
correctly, `nazgul/dispatch/` being empty is expected/correct behavior — but that alone doesn't
explain the *log* file's total absence, since `log_event` fires on every allow path too,
independent of cleanup. The log's total non-existence is the stronger signal; the worktree gap
is the most likely explanation already on record, but a second plausible cause is that no
implementer/reviewer teammate has gone idle yet at all during this audit (still actively
working) combined with all *prior* objectives' teammates happening to run without worktrees
(e.g., review teammates, which `team-orchestrator.md`'s review-team section does not document as
worktree-based) and never idling in a way that reached the hook either.

**Recommendation:** This is exactly the "first-run telemetry watch" follow-up already on record
— it should be escalated from "watch and see" to "actively verify": run one deliberate
minimal-worktree-free teammate dispatch and confirm `teammate-idle.jsonl` gets a first entry: if
it does, the worktree-escape theory becomes the leading explanation for gaps in
worktree-based dispatches and RULES §17's fix should be prioritized; if it does not, the guard
wiring itself needs re-verification against the live `TeammateIdle` payload shape (the design
doc already flags the payload schema as "not fully documented").

### Finding 8 — MEDIUM — docs-drift — `team-orchestrator.md`'s review-team step list has a duplicate "3."

**Evidence:** `agents/team-orchestrator.md:34-35` — both lines are numbered "3." (step 3 reads
"Read `nazgul/config.json → models.review`...", step 3 again reads "Read the changed files for
the task..."), then the list continues "4." (line 36), "5." (44), "6." (50), "7." (55) — so the
visible list has 7 real steps but shows numbers 1,2,3,3,4,5,6,7, shifting every step from the
true step 4 onward off by one relative to its printed number. Confirmed still present (this was
called out as an accepted-but-deferred follow-up in
`project_teammate_report_contract_followups.md`, not yet fixed).

**Failure scenario:** Purely cosmetic/comprehension risk — an operator or future editor reading
"step 5: Spawn a team..." following a "step 4" that's actually the fifth item could
miscount when cross-referencing step numbers elsewhere (e.g. RULES.md or a bug report
referencing "step 6" of the review-team flow would be ambiguous about which numbering they
mean).

**Recommendation:** Renumber lines 34-59 sequentially (3→4→5→6→7→8→9→10 or similar); trivial
fix, purely docs.

### Finding 9 — MEDIUM — fragility — heartbeat's archive-then-start design permanently drops an inbox item on a start-command failure, by design, with no operator-facing surfacing

**Evidence:** `scripts/heartbeat.sh:190-201` — `inbox_archive` (the atomic claim) runs before
`_hb_start`. If `_hb_start` fails (the `claude -p` invocation errors), the code explicitly
chooses to keep the item archived rather than un-archive it (comment at lines 8-10, 186-189:
"archive-then-start... a crash between the two leaves the inbox consistent... a re-run can't
repick or double-start it"). The failure is recorded as `decision: started, reason:
start_command_failed` (line 200) in `nazgul/logs/heartbeat-<date>.jsonl` — a file with no
active monitor/alerting wired to it anywhere in this repo (no hook reads it, no skill surfaces
a warning banner on the next `/nazgul:status` run based on a recent `start_command_failed`
entry).

**Failure scenario:** A transient failure in the `claude -p` invocation (network blip, API
rate-limit, auth token expiry) causes `_hb_start` to fail exactly once. The picked objective is
now permanently archived and will never be reconsidered by any future heartbeat tick (it's out
of `inbox_list`'s scope once archived) — the only way to recover it is a human manually noticing
the `start_command_failed` line in a dated JSONL file, or noticing the objective was never
actually worked. This is a deliberate, documented design tradeoff (favor never-double-start over
guaranteed-delivery) rather than a hidden bug, but it has no operator-facing surfacing beyond
the raw log.

**Recommendation:** Either surface `start_command_failed` entries in `/nazgul:status` or
`/nazgul:heartbeat`'s own report step (`skills/heartbeat/SKILL.md:47-59`'s decision table has no
row distinguishing `started` success from `started`+`start_command_failed`), or move the
archived-but-failed item into a distinct `nazgul/inbox/failed/` location so it's visibly
different from a normal successful claim.

### Finding 10 — LOW — architecture — dead `.delivered` manifest field

**Evidence:** `scripts/teammate-idle-guard.sh:100` writes `.delivered = true` onto the dispatch
manifest when a report is detected. Repo-wide grep for `\.delivered\b` across `scripts/`,
`agents/`, `skills/` finds exactly one hit — the write site itself. Nothing reads it.

**Recommendation:** Either use it (e.g. `team-orchestrator.md`'s idle-handling step could check
`.delivered` before reading the report file, as a cheap "is this really done" signal instead of
re-testing file existence itself) or remove the write to reduce surface area. Low priority,
essentially free to fix.

### Finding 11 — LOW — docs-drift/test-gap — stale version-number labels in `test-migrate-config.sh` accumulate every schema bump

**Evidence:** `tests/test-migrate-config.sh:1707`: `assert_json_field "v26 garbage conductor:
schema_version reaches 27" "$CFG" ".schema_version" "27"` — the assertion's own descriptive
label says "v26" while the assertion itself checks that the terminal schema version is `27`.
This is the exact "labels say v24/25/26 while asserting the terminal version" pattern already
flagged as an accepted-but-deferred follow-up; still present.

**Recommendation:** Reword recurring assertion labels to describe the *behavior under test*
("garbage conductor input migrates cleanly to the terminal schema version") rather than embedding
a specific version number that goes stale on every future schema bump.

---

## Structural critique

**`scripts/worktree-utils.sh` is the strongest removal/rebuild candidate in this dimension.**
206 lines of a bash helper library (`create_feature_branch`, `setup_worktree_dir`,
`create_task_worktree`, `merge_task_to_feature`, `cleanup_task_worktree`,
`cleanup_all_worktrees`) that is fully duplicated — less safely — as inline prose instructions
in `skills/start/SKILL.md` (4x) and `agents/team-orchestrator.md`/`scripts/stop-hook.sh`'s
prompt text, and is unreachable from any of those call sites because they're markdown-driven LLM
instructions rather than bash scripts. It carries a load-bearing side effect
(`install_git_hooks`) that is consequently also unreachable (Finding 1). Recommendation: either
delete the file (and move the git-hooks install trigger somewhere the branch-setup instructions
actually run, e.g. as an explicit bash step spelled out inline in `skills/start/SKILL.md`), or
actually route the skill/agent instructions through it via a `Bash` tool call
(`source scripts/worktree-utils.sh && create_feature_branch ...`) so one implementation exists.
Either is better than the current state: one silently-dead copy and one live, undocumented,
un-tested prose copy, drifting further apart every time either is edited.

**The "Files modified" field has two competing, undocumented serialization conventions** — bare
comma-separated paths (what `parallel-batch.sh`'s dedup logic and its own test suite assume) vs.
JSON-array literal (what every real planner-generated task manifest in this repo actually
contains). This isn't just Finding 3's bug; it's a missing single source of truth for the
field's format. Recommendation: pick one (JSON array is more robust and is what's actually
produced — formalize it), update `agents/planner.md:110`, and make
`get_task_field`/`compute_dispatch_batch` jq-based instead of string-splitting so the parsing is
correct by construction rather than by lucky formatting.

**The Teammate Report Contract's three layers are unevenly enforced, and the enforcement
layer's own activation is unenforced.** Only Layer 3 (the `TeammateIdle` guard) is marked
`[enforced]` in `RULES.md:473`; Layers 1 (prompt contract) and 2 (dispatch manifest) are
`[advisory]` — nothing mechanically verifies a dispatcher actually wrote
`nazgul/dispatch/<name>.json` before spawning a teammate. Critically, the guard's own design
means a *missing* manifest degrades to silent `allow` (`teammate-idle-guard.sh:66-69`, "no
dispatch manifest for $NAME... allow") — indistinguishable from "not a Nazgul-dispatched
teammate at all." A dispatcher that forgets Layer 2 gets exactly the same guard behavior as one
correctly dispatching a foreign, unrelated process: zero enforcement, zero signal that anything
went wrong. This is architecturally sound as a fail-open choice (per the stated design
philosophy), but it means the entire contract's guarantee rests on a step nothing checks ever
happened — worth at minimum a periodic self-audit assertion ("N teammates were spawned this
objective per team-orchestrator logs; M manifests were written; M should equal N") rather than
relying purely on dispatcher discipline.

**The GitHub connector's "two-way" framing (CLAUDE.md, RULES §16) currently overstates what the
code does** — the pull half is real and well-tested; the push half is unreachable (Finding 2).
Until the map-linking gap is closed, documentation describing it as bidirectional is
inaccurate — worth a one-line downgrade ("pull-only; push scaffolding exists but is not yet
wired to a real local id") until fixed, so an operator enabling the connector doesn't build an
expectation the code can't meet.

**Not overbuilt, otherwise.** `parallel-batch.sh`'s wave/gate/hard-stop split, the
provider-seam design in `inbox-provider.sh` (file vs. github, cleanly dispatched), and the
heartbeat tick's single-responsibility gating chain (hard stops → enabled → provider →
triage → concurrency → claim → start) are all reasonably scoped for what they do — no
consolidation candidates found there beyond the specific bugs above.
