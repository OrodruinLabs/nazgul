# Changelog

All notable changes to this project will be documented in this file.

## [2.34.0] - 2026-08-18

FEAT-031, ADR-022/023/024/025 — **a state machine whose terminal edge is unreachable does not fail
loudly; it converts its own operators into forgers.** `DONE` was the last edge, and on the
configuration this repo and its consumer projects actually run it could not be reached — in four
independent places along the same edge. The aggregate review board cannot fire while any sibling is
`BLOCKED`, and `/nazgul:task skip` is what wrote `BLOCKED`. `scripts/red-run.sh` could only run this
repo's own bash harness, so `IN_PROGRESS -> IMPLEMENTED` was unsatisfiable anywhere else. Nothing in
the plugin observed a merge, so off GitHub — or on it with server-side squash — no code path closed a
task after its work shipped. And `scripts/prompt-guard.sh:40` blocked prose *about* the state machine,
so the field report describing all of the above could not be pasted into Claude Code. Four of
twenty-one manifests on the last consumer objective were closed by hand-editing frontmatter, because
every in-tool path correctly refused. This release restores a legitimate key at each point, or makes
the refusal honest about what it is refusing. **MINOR, not PATCH:** a new `/nazgul:complete` command, a
new conditional `IMPLEMENTED -> DONE` edge, a second terminal status, a readiness predicate that carves
out cancelled tasks, a red-run that executes the project's own runner, and a narrowed prompt-guard are
all operator-visible. **MAJOR is wrong:** nothing is removed, nothing is renamed, no gate changes
meaning, and no operator action is required. **`schema_version` steps 36 → 37** for two additive
`project.*` keys whose defaults reproduce today's behaviour exactly — the same additive-step-as-MINOR
precedent as 34 → 35 (2.29.0) and 35 → 36 (2.30.0).

### Added

- **`CANCELLED` — the second terminal status, and the first way to say "finished, shipped nothing".**
  `VALID_STATUSES` (`scripts/lib/structured-state.sh:17`) carries it; `ttg_valid_transition`
  (`scripts/lib/task-transition-guard.sh`) enumerates its in-edges from every non-terminal status and
  defines no `CANCELLED_*` case at all, so "terminal" is a property of the table rather than a
  convention. It is written only through `scripts/task-transition.sh`, the sole sanctioned writer, and
  it is refused out of a `Blocked kind: reconciliation` quarantine — a second terminal status reachable
  from an integrity quarantine would be a second way to make an untraceable change permanent.
  `CANCELLED_COUNT` is its own bucket (`scripts/lib/task-utils.sh:229,248`), loop completion is
  `DONE + CANCELLED == TOTAL` (`scripts/stop-hook.sh`), and the completion line says which:
  `all N/M tasks complete` when nothing was cancelled, `N/M done, K cancelled` when something was. A
  cancelled task never passes for a shipped one. `/nazgul:task skip` writes it instead of `BLOCKED`,
  records a `- **Cancelled reason**:` line first, and **no longer edits any `Depends on` line** — a
  `CANCELLED` dependency satisfies `ttg_dependency_satisfied` in every granularity, so the plan graph
  survives the cancellation instead of being destroyed to route around a predicate.
- **`## Merge Evidence` — what makes `IMPLEMENTED -> DONE` reachable, and the only thing that does.**
  `ttg_verify_merge_evidence` (`scripts/lib/task-transition-guard.sh:735`) validates four fields under
  that exact heading — `host`, `pr`, `merged-at`, `merge-commit`
  (`_TTG_MERGE_REQUIRED_FIELDS`, `:663`) — each shape-checked (`_ttg_merge_shape_ok`, `:697-706`). The
  heading IS the enforcement boundary exactly as `## Commits` is: merge fields recorded anywhere else in
  the manifest are not evidence. Four closed refusal reasons, each emitting `merge_evidence_missing`
  (`:684`): `absent`, `commented_out`, `truncated`, `malformed`. For `IN_REVIEW -> DONE` merge evidence
  is an **alternative** route, never a bypass — the review-evidence route is tried first, and the
  accepted route is always named on stderr so an auditor can tell which fact admitted the edge.
  Unlike the red-run gate this one ships with **no kill switch**, stated at `:678-679`: a switch on the
  last gate before `DONE` would be the bypass.
- **`scripts/lib/merge-provider.sh` — merge observation as a seam, with named degradations.** Three
  functions: detect the host from `git remote get-url`, ask that host's PR API for merge state, report
  whether the detected arm is usable now. Callers never speak `gh`. `merge_provider_pr_state` always
  returns one JSON object whose `result` is exactly one of `ok` (exit 0), `unsupported_host` (2),
  `no_remote` (3), `provider_unavailable` (4), `api_failure` (5), `invalid_pr` (6), and `merged` is
  three-valued — `true`/`false` only when the host answered, JSON `null` when it did not — because a
  bare `false` collapses "the host says not merged" into "we could not find out". Five additive event
  types, read out of the emitter and not out of the ADR: `merge_provider_unsupported_host` (`:166`),
  `merge_provider_no_remote` (`:171`), `merge_provider_unavailable` (`:210`),
  `merge_provider_api_failure` (`:285`), `merge_provider_invalid_pr` (`:324`). Note the deliberate
  asymmetry: the *event* is `merge_provider_unavailable` while the *result value* is
  `provider_unavailable` — the event name is already namespaced by its prefix.
- **`scripts/close-objective.sh` and `/nazgul:complete` — the honest replacement for frontmatter
  surgery.** Given a merged PR it reads merge state through the seam, writes `## Merge Evidence` into
  each stranded manifest **from the host's own answer** (with a `- **recorded-by**: scripts/close-objective.sh
  (host API, <result>)` provenance line, `:317` — the field the merge-evidence gate now REQUIRES and
  checks against a closed producer set), and walks each task to `DONE` through
  `scripts/task-transition.sh`. It is a **caller** of the sole writer and never a writer: no frontmatter
  is touched, no review directory or verdict is fabricated. Its terminal record is the §15 grammar with
  this entry point's domain nouns in the last two slots (`close-objective.sh:50,492-495`):
  `close-objective: N scanned, M skipped (already-terminal=…, not-closable-status=…, unreadable=…,
  not-this-objective=…, pr-not-this-objective=…, not-merged=…, merge-unverifiable=…,
  evidence-write-failed=…, transition-refused=…), K closed, F refused`, with `N == M + K` asserted by
  the emitter and the nine skip reasons a closed set always printed in that order. `not-merged` and
  `merge-unverifiable` are separate members on purpose — "could not look" is not "not merged", which is
  the whole thesis of the seam. Seven additive events: `close_objective_refused`,
  `close_objective_blocked`, `close_objective_closed`, `close_objective_rollback_failed`,
  `close_objective_roster_unreadable`, `coverage_vacuous`, `close_objective_summary`. Exit policy is
  blocking and stated in the file: `0` closed something with no refusal, `1` a refusal, `2` NOTHING
  CHECKED, `3` usage/precondition error or an internal coverage-accounting defect.
- **`aggregate_board_cancelled_carveout` — an additive event for readiness reached by exclusion.**
  Emitted by `scripts/stop-hook.sh`'s aggregate-review arm when a `group`/`feature` unit becomes
  review-ready only because `CANCELLED` tasks left it, carrying `unit`, `cancelled_tasks` (the ids
  carried out), `implemented`, and `total`. Both names say `cancelled` because `CANCELLED` is the only
  status the carve-out acts on: a `BLOCKED` task is deliberately NOT carried out, so a field named for
  blocking would have described the one case that never appears in it. The dispatch text carries the
  same facts as a `CARVE-OUT:` note: `N of M unit tasks reviewed — K carried out CANCELLED (ids); a
  cancelled task is removed from the unit, never approved by it.` Readiness where every task shipped and
  readiness reached by exclusion must not read identically.
- **Five test files — the discovered root suite moves 104 → 109, all green.**
  `tests/test-cancelled-status.sh` (the status itself: edges, the quarantine refusal, the dependency
  gate, the counters), `tests/test-cancelled-status-consumers.sh` (the vocabulary's whole consumer set,
  every member DRIVEN with a `CANCELLED` fixture — including the recorded NON-consumers, which are
  examined and shown exempt rather than omitted), `tests/test-merge-provider.sh`,
  `tests/test-close-objective.sh`, and `tests/test-red-run-script.sh`.

### Changed

- **`schema_version` 36 → 37, two additive `project.*` keys, and a project setting neither sees no
  behaviour change at all.** `project.test_roots` defaults to `["tests"]` and `project.test_filter_template`
  to `"--filter={filter}"` (`templates/config.json:18-19`; `migrate_36_to_37`,
  `scripts/migrate-config.sh:747-757`). Both defaults reproduce the previously hardcoded behaviour
  byte-for-byte, explicit values are preserved, and the migration is the same additive shape as
  `migrate_35_to_36`. The two keys are read by both halves of the red-run gate: which file scopes
  TRIGGER the requirement, and where a recorded entry's test path must live.
- **`scripts/red-run.sh` runs the PROJECT's runner, and the record names what ran.** Resolution order is
  stated in the file (`:19-25`): the live project root's `project.test_command`, else `tests/run-tests.sh`
  if the pre-change tree carries one, else a **named refusal** — "this is not a runner that failed: no
  runner could be determined at all" (`:205`). The scoped filter is interpolated through
  `project.test_filter_template` as a literal `{filter}` substitution, never `eval`, and a project with
  no template and a non-legacy runner is refused rather than guessed at (`:224-225`), because appending
  a flag Nazgul chose to a command the project chose has two failure modes that both look like success:
  a rejected flag exits non-zero and reads as RED confirmed, an ignored one runs the whole suite as if
  it were scoped. Every capture line now names the command (`:488`):
  `- capture: \`<cmd>\` in a detached worktree at \`<base>\`; N changed test file(s) copied in…; runner exit E in Ts`.
- **The red-run gate reports "present but commented" distinctly from "absent".** `commented_out` joins
  the closed refusal vocabulary — `absent bad_na_token commented_out corrupt exit_zero not_ancestor
  ref_unresolvable roots_undeterminable roots_unresolved`, nine members, declared at
  `scripts/lib/task-transition-guard.sh:162-163` and asserted **against that source** by
  `tests/test-red-run-evidence.sh:192`, so the list is checkable rather than narrated. A section whose
  whole payload sits inside an HTML comment is present-but-not-a-record; folding it into `absent` was
  one collapsed state wearing two names. `## Merge Evidence` reuses the one stripper for the same
  distinction (`:757-768`) rather than re-deriving it, so the two readings cannot drift.
- **`scripts/prompt-guard.sh` narrowed to the unambiguous shape (ADR-025).** The old single-line
  `grep -qE '(set.*status.*to|change.*status.*to|mark.*as).*(DONE|APPROVED|IN_REVIEW|IMPLEMENTED)'`
  matched prose, quotes, and field reports about the guard itself. The replacement requires all three of
  an imperative verb at line start (after an optional politeness prefix), a `TASK-NNN`, and a status
  word — and suppresses the match inside fenced blocks, blockquotes, and inline code spans. Two honest
  consequences ship with it: a block now prints the matched line number, the offending substring, and
  how to discuss the text instead of running it; and a candidate that only STRIPPING made invisible is
  **reported on stderr as suppressed**, never collapsed into "no match", so "looked and found none" stays
  distinct from "never looked". The file header also corrects a standing inaccuracy — this hook fires in
  every mode, not only HITL, and it is not what makes an illegitimate status change ineffective.
- **`RULES.md` gains four rule clusters and the tier counts they force.** §2 Cancellation (2 rules) and
  Merge Evidence (3), §2's Dependency Gate (1), §3 item 15 the carve-out record, and §16's
  Merge-State Provider Seam (3). Tier counts move to **88 enforced / 31 advisory / 23 hook-driven only**
  (`tests/test-rules-tiers.sh:69,78`) — bumped for genuinely new rules, never re-tagged to fit. §3.15 is
  `[hook-driven only]` and says why in its own boundary: the note and the event are produced where the
  dispatch is decided, so a board dispatched by hand for the same unit reports no carve-out even when one
  applies.
- **`scripts/close-objective.sh` is §15 registry member ten** (`RULES.md:551-565`), enrolled by
  FEAT-031/TASK-011 and actually DRIVEN by `tests/test-coverage-honesty.sh`, not merely listed. Unlike
  `scripts/doctor.sh` and `scripts/audit-agent-state-paths.sh` it is **blocking**: nothing closed while
  candidates were scanned exits non-zero.

### Fixed

- **The plan's objective binding had a gate and a template but no producer — so `IMPLEMENTED -> DONE`
  was still unreachable everywhere except this repo.** The merge-evidence gate requires
  `nazgul/plan.md`'s frontmatter `feat_id` to agree with `config.feat_id`; the template was given that
  key, as `feat_id: <FEAT-NNN>`, and **nothing ever substituted it**. `/nazgul:init` copies the template
  verbatim (`config.feat_id` is still null there) and `agents/planner.md` — the only writer of the
  `## Tasks` roster — contained zero occurrences of `feat_id`. A project built from the shipped template
  therefore refused at the last gate with a *different* message: `declares feat_id "<FEAT-NNN>" but
  config names "FEAT-030"`. The lesson is the shape of the miss, not the missing line: the earlier fix
  was verified by READING the template, and only re-running a project built from it exposed the rest.
  `scripts/stamp-plan-objective.sh` is the producer, invoked by the Planner immediately after it writes
  the roster; it takes the value from `config.feat_id`, never re-derives it, re-reads the file through
  the gate's own parser (`ttg_plan_feat_id`) and fails on mismatch. **Positioning is the argument:** the
  frontmatter is a claim ABOUT the roster, so only the roster's writer can honestly make it —
  `/nazgul:init` structurally cannot, `create_feature_branch` sees either an empty template roster or a
  plan the start skill has already archived away, and **no automatic path may stamp it at all**, because
  an unconditional copy of `config.feat_id` into whatever plan is on disk would make the gate's
  corroboration tautological. Pre-existing plans are healed by the operator running the same script,
  which REFUSES to overwrite a plan declaring a different real objective and names the roster it is
  binding before it binds it. `tests/test-plan-objective-binding.sh` drives the SHIPPED template — not a
  hand-authored plan — from `cp templates/plan.md` through `scripts/task-transition.sh` to `DONE` over
  the real merge-provider seam; that the Planner actually runs the producer is `[advisory]`.

- **An unplanned plan produced a one-task roster made entirely of the template's commented examples.**
  `ttg_objective_roster` extracted `(TASK|PATCH)-[0-9]+` from the raw `## Tasks` section, and
  `templates/plan.md` documents its format with commented example entries — so a plan nobody had planned
  into yielded `TASK-001`, and a task nobody ever wrote could be shown to belong to the objective. The
  section is now passed through the file's existing `_ttg_strip_html_comments` first, and "names ids
  ONLY inside HTML comments" is its own refusal sentence, distinct from "carries no roster at all".
  A third roster refusal is likewise named: an unsubstituted `<...>` placeholder is a producer that
  never ran, not a rival claim, and reporting it as a disagreement sent operators off to reconcile two
  objectives one of which did not exist.

- **A never-shipping task vetoed forward progress at five sites; the state machine now has a word for
  it.** Aggregate readiness (`stop-hook.sh`), loop completion, heartbeat auto-start, the parallel hard
  stop, and the dependency gate all treated "operator gave up on this task" as "this task is coming".
  `CANCELLED` resolves all five, **two of them with no edit at all**: `_pb_blocked_tasks`
  (`scripts/lib/parallel-batch.sh:161-162`) matches `BLOCKED` and `INVALID|""`, and `CANCELLED` is
  neither, so the heartbeat and the parallel hard stop are correct by default — verified by driving them,
  not by reading them.
- **Declaring a path out of scope put it IN scope (red-run defect 2.5, pulled forward).**
  `_ttg_red_run_in_scope` grepped the WHOLE `## File Scope` section for `(scripts|tests)/` — including
  the `Must NOT touch:` prohibition line — so writing "Must NOT touch `scripts/`" was how you *demanded*
  red-run evidence for a task that touches no script. `_ttg_drop_prohibitions`
  (`scripts/lib/task-transition-guard.sh:332-348`) now drops prohibition lines before the scan, keyed on
  the label rather than on the path, and resets at the next bolded field so a prohibition cannot swallow
  the rest of the section. The scope predicate is a UNION of the manifest and the real
  `git diff <Base SHA>..HEAD`, so dropping a prohibition line cannot hide a scripts/tests file that was
  actually changed; when git cannot answer, the degradation to manifest-only is announced on stderr
  (`:392-394`), never taken silently.
- **The trigger and the satisfier read the same roots.** Both halves of the red-run gate now derive from
  `project.test_roots`, and its two failure modes are named separately: `roots_undeterminable` (the array
  is present and unusable — empty, not an array, or carrying a non-string) fails **closed** and treats the
  task as in scope, while `roots_unresolved` (a usable array, none of whose entries resolves to a real
  directory) is a different state again. Configuration that could not be read is never silently equated
  with configuration that says nothing is a test. An absent key, or `jq`/config unreadable, still falls
  back to `["tests"]` — a project that never configured it behaves exactly as before.
- **Three test assertions were deliberately inverted or pinned, each recorded here so a reader of the
  diff sees the direction of travel.** (1) `tests/test-prompt-guard.sh:70-72` at the base (now `:77-84`) asserted that
  the bare string `"mark as APPROVED"` — no task id, no context — must be **blocked**. That assertion
  pinned the over-match; it is now `allowed (exit 0)`, labelled *ADR-025 Decision 1 inversion*, and it
  arrives alongside a new test 4b that drives the verbatim field-report line which could not be pasted at
  `e18aa18` and asserts it is allowed both bare and backticked. The guard did not get weaker: the same
  file gains the shape-based block cases, the fence/quote/backtick suppression cases, and the
  suppressed-candidate report. (2) `tests/test-red-run-evidence.sh:186` at the base asserted the
  diagnostic said `"repository-relative and under tests/"` — a message that hardcoded the single root.
  It now asserts `"must be repository-relative and under a configured tests root (tests)"`
  (`:503`): the same guarantee, stated over the roots the project actually declared. (3)
  `tests/test-stop-hook.sh:1002-1015` at the base (now `:1002-1018`) was the one that pinned a **deadlock** as correct — a unit with a
  `BLOCKED` sibling dispatches no board. It was deliberately **not** inverted. `BLOCKED` means "needs
  human help, will resume", which is not "will never ship", so it still vetoes the whole unit; the block
  gains an explicit `assert_not_contains "NO aggregate board while a sibling is BLOCKED"` and a comment
  naming ADR-022, converting an implicit behaviour into a stated one. Only `CANCELLED` is carried out.

### Decided and recorded, with a falsifier

- **ADR-022 was decided as Option B, and REVERSED to Option A before any of it was implemented.** The
  original decision was a typed manifest marker, `Blocked kind: skipped`, read by the unit walk — no new
  status token. It was reversed on 2026-08-15 after operator rejection (*"that's just a comment not a
  status"*) and an architecture review that falsified the evidence B rested on. **The shipped decision is
  Option A: a new terminal status token, `CANCELLED`** — and with it the state machine has, for the first
  time, a terminal status meaning *finished, shipped nothing*, closing a gap that stood for as long as
  `DONE` was the only terminal state. **Why B was rejected, because the reason IS this objective's
  thesis:** a never-shipping task must not veto forward progress, and that veto has **five** sites —
  aggregate readiness (`stop-hook.sh:530` at `e18aa18`), loop completion (`:964-970`, which burns to
  `max_iterations` and exits at `:1288`), heartbeat auto-start (`heartbeat.sh:208` → `_pb_blocked_tasks`,
  unconditional and mode-independent, running before the enabled check), the parallel hard stop
  (`stop-hook.sh:1311-1320`, same helper), and the dependency gate (`ttg_dependency_satisfied`). The
  marker fixed **one**. ADR-022 asserted the remaining consumers were "correct unchanged", and code
  falsified it: the dependency gate is precisely why `/nazgul:task skip` used to instruct the operator to
  delete the skipped id from every downstream `Depends on` line (`skills/task/SKILL.md:97-100`),
  irreversibly destroying plan-graph state to route around a predicate. This entry states the correction
  rather than presenting A as the choice all along — a decision record that conceals its own correction
  is the failure class this objective exists to close.
- **Not `SKIPPED`, and the reason is a live collision.** That token is already a member of
  `VALID_VERDICTS` (`scripts/lib/structured-state.sh:13`) meaning *a review that was skipped*. Reusing it
  for a task status would put two meanings on one string in one vocabulary file.
  **Falsifier:** if `SKIPPED` is ever retired from `VALID_VERDICTS`, this reason expires and the naming
  is open again.
- **ADR-023 decision 1 — the host's PR API is the authority, and git ancestry is corroboration that can
  never become a predicate.** `_ttg_merge_ancestry` (`scripts/lib/task-transition-guard.sh:715-731`)
  records `corroborated`, `squash_signature`, or `unavailable`, and **every path returns 0**. This is not
  caution, it is correctness: after a server-side squash NO SHA recorded under `## Commits` is an ancestor
  of the merge commit, so on a squash host a failing ancestry check is the EXPECTED reading and blocking
  on it would report "not shipped" for work that demonstrably shipped. `scripts/close-objective.sh` states
  the same rule in its own header (`:18-25`) so a future reader does not "simplify" it into
  `git merge-base --is-ancestor`. **Falsifier:** a host that guarantees merge-commit ancestry for every
  merge strategy could take ancestry as a predicate there — no such guarantee exists on GitHub today.
- **The `## Merge Evidence` gate ships with no kill switch, deliberately.** `guards.red_run_evidence`
  exists because the red-run gate blocks on the way IN to `IMPLEMENTED`; this one is the last gate before
  `DONE`. A switch on it would be the bypass, not an escape hatch. **Falsifier:** if a legitimate host or
  workflow is found that cannot produce all four fields, the answer is a new named provider arm or a new
  named refusal reason — not a boolean.

### Known constraints (honest notes)

- **`CANCELLED` is the one status with no evidence gate, and that is a judgement, not a fact about the
  code.** An unshippable task produces no artifact to gate on. Nothing verifies the operator was right;
  what keeps the judgement visible instead of absorbed into "done" is the separate count and the
  `N/M done, K cancelled` completion line.
- **A downstream task that genuinely needed cancelled work is auto-promoted anyway.** No mechanism can
  distinguish "the dependency was optional" from "the operator cancelled something load-bearing". The
  mitigation is the record rather than a gate: `skip` writes a `Cancelled reason` line, reports how many
  downstream tasks it releases, and leaves the cancelled id on every `Depends on` line it released.
- **A merge-closed task was never reviewed, and the diagnostic says so.** `IMPLEMENTED -> DONE` on merge
  evidence is a legitimate closure for work that shipped outside the loop — not an equivalent one to a
  task that passed the board. The accepted route is always named on stderr.
- **Seven sibling red-run defects remain filed, not fixed.** Only 2.1 (the hardcoded runner), the tests-root
  addendum, and 2.5 (the scope-prohibition inversion, pulled forward per the PRD's open question 2) ship
  here. 2.2 (failure attribution parses only bash/bats markers), 2.3 (the basename fallback flattens paths
  into self-rejecting entries), 2.4/2.6/2.7 (the closed N/A token list encodes one theory of what a change
  can be — no token is truthful for tooling-only changes, shipped-behaviour measurements, or a defect whose
  subject IS the test), 2.8 (a mis-formatted N/A token is reported as *missing* evidence rather than as a
  format error), and 2.9 (a same-line rationale after the token is rejected) stay in
  `nazgul/inbox/red-run-hardcodes-nazgul-own-test-harness.md`. 2.4/2.6/2.7 are one design decision about
  whether the list stays closed at all, and are deliberately not three patches.
- **The merge seam has one arm.** Only `github.com` is implemented. `NAZGUL_MERGE_PROVIDER` overrides
  detection for an operator or a test, and an unrecognised value is NOT defaulted — it reaches the refusal
  arm. Every other host gets `unsupported_host`, which is a named refusal and not a silent failure, but it
  is still not closure.
- **The prompt-guard remains a heuristic over free text.** ADR-025's own premise is that a substring cannot
  detect intent. What makes an illegitimate status change ineffective is `task-transition.sh`'s
  compare-and-swap plus the stop-hook's reconciliation pass (ADR-020), and the guard's file header now says
  so rather than implying otherwise.
## [2.33.0] - 2026-08-17

FEAT-032 — **Cross-session messaging adoption: the loop keeps its one engine.** Thesis: *an
unguaranteed channel may shorten a wait, but may never authorize one.* Claude Code's cross-session
messaging was probed end to end on a live host — six probes, committed as
`docs/superpowers/specs/2026-08-16-cross-session-messaging-platform-facts.md` — and the socket-post
"doorbell" was proven to WORK: P1 delivered a turn injected by a Bash command that had already
exited, and P5's controlled A/B — an ordinary turn's Stop as the baseline, then an idle session woken
by an inert doorbell payload — showed the woken turn's Stop hook blocking and driving the loop
exactly as the ordinary one's did. (Under bypass permissions: P4's `acceptEdits` run stalled the
driven continuation, which is a property of the session's permission mode, not of the transport.)
It was cut anyway. Delivery is not guaranteed — the identical payload without
an auth frame was HELD behind a human approval click (P2's controlled A/B), the transport is
silently reconfigurable by settings Nazgul does not own, and where the doorbell works it is redundant
with the turn sources the loop already has. So messaging is adopted as an **operator surface and an
attack surface, never a loop mechanism**: `decision:"block"` on Stop plus the harness's documented
background-dispatch resume remain the only sanctioned ways a turn begins. What shipped is that
posture — written down and mechanically scanned — plus the live defects the evaluation exposed while
it was looking hard at the in-flight hold, the session locks, and the dispatch guard.

**MINOR, not PATCH:** new behavior an operator can observe — three new `/nazgul:doctor` checks, three
new `/nazgul:status` lines, four new event types, a new §15-enrolled scan, and a session-lock
lifetime that changed from per-turn to per-session. **MAJOR is wrong:** no skill, agent, flag, or
config key is removed or renamed, no gate changes meaning, and no default is inverted. **No schema
step — config schema stays v36; this release adds zero config keys.** Neither
`scripts/migrate-config.sh` nor `templates/config.json` appears in this objective's diff, which is
itself the evidence that nothing an existing project stores had to change.

### Added

- **`RULES.md` §22 — Cross-Session Messaging Posture**, five rules with an honest tier on each. Rule
  1 (the doctrine above) is `[advisory]`, enforced only indirectly — by rule 2, which makes a poster
  impossible to ship. Rules 2 and 3 are `[enforced]` by the new scan. Rule 4 (a message is untrusted
  input) is `[advisory]` behaviorally with an `[enforced]` presence test. Rule 5 states the threat
  model plainly: any same-user process can have its CONNECTION accepted on any session's socket, the
  0700-dir/0600-socket file permissions are the entire authentication boundary, and the per-session
  token is exported into every Bash tool call — so an environment leak is a turn-injection capability
  for that session.
- **`tests/test-messaging-posture.sh` — the §15 registry moves nine entry points → ten.** Two
  mechanical rules over the shipped surface: no shipped file names `crossSessionInbound` or
  `isolatePeerMachines`, and no shipped file references `CLAUDE_CODE_MESSAGING_SOCKET` /
  `CLAUDE_CODE_MESSAGING_TOKEN` outside a read-only allowlist of exactly two sites (doctor's
  eligibility read; `session-tracker.sh`'s basename-as-pid parse). With no sanctioned poster, ANY
  other reference is a potential post — which is also what mechanically covers "the token is never
  stored or logged" for shipped text. Blocking, `K > 0` floor, dogfooded against synthetic violators
  so a scan that can only ever pass is caught.
- **Three new `/nazgul:doctor` checks — the roster goes ten → thirteen.** `messaging`,
  `remote-control`, and `sessions`, all read-only and env/settings/file-reads only; doctor is
  allowlisted for the read and nothing more, and never connects to the socket. `messaging` and
  `remote-control` are **three-state on purpose** — a `note` verdict says UNDETERMINED in this
  context (the socket env is legitimately unexported in the pre-flag-fetch window or outside a
  hook/Bash context) rather than claiming unavailability it cannot observe, and every blocker names
  the file or variable it came from. `sessions` reports the shared-working-tree collision.
- **Remote-ops operator documentation** (`README.md`): steering an unattended AFK loop from
  elsewhere, and the inbound-posture guidance that ends with "that default is safe; leave it".
- **Session-level peer trust boundary (MF-059 extension)** in `templates/CLAUDE.md.template` and
  `skills/start/SKILL.md`, with `tests/test-session-trust-boundary.sh` as its enforced presence
  layer: a peer message never counts as operator consent, never carries authoritative state, never
  changes configuration — and the wording is platform-versioned so the boundary cannot overclaim
  permanence.
- **`/nazgul:status` shows in-flight and quarantined markers, plus the last `stop_gate` reason.** The
  quarantined count is deliberately read from the quarantine DIRECTORY rather than from one event
  type, because the two quarantine producers emit different shapes (below) and a renderer keying on
  either alone would silently miss the other. The skill states that explicitly so a `Quarantined > 0`
  with a `none` last-stop-gate is never read as a contradiction.
- **Four new event types**, registered across the taxonomy sites (`skills/log/SKILL.md`,
  `docs/ARCHITECTURE.md`, `RULES.md`, `agents/doc-verifier.md`): `in_flight_orphan` — registered BOTH
  as a `stop_gate` reason (stop-hook, with `unit`/`agent`/`background`) and as a standalone event
  (SessionStart sweep, with `source: session_start_sweep` and a numeric `age_minutes`) —
  `dispatch_guard_background_unverifiable`, `clear_skipped_no_match`, and
  `clear_fallback_underivable`.
- **`docs/DECISION-LOG-2026-08-16-cross-session-messaging.md`** — five decisions with their
  falsifiers, including D-002 "the doorbell was proven to WORK, and cut anyway" and D-005, an
  amendment to the 2026-07-21 parallel-execution-collapse log's closing rule made **by pointer, not
  by edit**.

### Changed

- **The in-flight hold is class-aware — #104 Gap 3 closed by classification, not by inversion.**
  Markers now record their dispatch class at write time (`background` as a tri-state
  `true`/`false`/`missing`, and `named`), and the hold fires ONLY for a provably-background unnamed
  dispatch, whose harness resume is the documented wake path. A fresh marker that is foreground,
  `missing`, or named is a proven leak — a synchronous dispatch cannot span a Stop — so it is
  quarantined to `nazgul/in-flight/quarantine/` and announced as `stop_gate reason:in_flight_orphan`
  while the loop continues normally. Legacy markers lacking both fields classify as foreground by
  ADR-009 cost-weighing: a false hold costs the whole run, a false continue costs one iteration.
- **Session locks live for the session, not the turn (#195).** They are registered at SessionStart,
  refreshed each Stop, released at SessionEnd (`session-staging.sh`), and swept by pid liveness —
  liveness outranks age, so a live session is never swept and a dead one goes immediately. The
  stop-hook `EXIT` trap that deleted the lock on every allowed stop is **gone**; it was deleting the
  lock in exactly the case the lock exists to make visible (a held or housekeeping session), which is
  how a live tree could show four running sessions and zero lock files. Locks now also carry
  `cwd` / `toplevel` / `branch`, and the recorded pid is the SESSION's — parsed read-only from the
  messaging socket's basename, falling back to `$PPID` — never the hook shell's own `$$`, which is
  dead moments later. RULES §11/§13 gain the matching honest scope correction: these counts are
  per-resolved-`nazgul/`-root, and "unconditional" hard stops are unconditional per root, not per
  project.
- **Two live sessions sharing one working tree now warn loudly and specifically**, naming the tree
  and the hazard (one session commits another's staged work) instead of the generic concurrent-session
  message, which is retained for the non-shared case.
- **In-flight marker clear is three-way, ending cross-unit marker theft.** A completion whose unit
  matched clears that marker (oldest-within-match, unchanged); a completion whose unit was DERIVED but
  matched nothing now clears NOTHING and emits `clear_skipped_no_match` — the collapse of that middle
  case into the fallback is what let one unit's completion delete another unit's live marker (the
  2026-08-04 incident); a completion with no derivable unit takes the newest agent-match and says so
  via `clear_fallback_underivable`.
- **SessionStart sweeps over-age in-flight markers** into the same quarantine directory, so an orphan
  backlog cannot regrow between runs. Quarantined, never deleted — a crashed subagent's marker is
  diagnostic evidence.

### Fixed

- **#205 / #94 — the review board could be disabled by a host's Agent schema.** On a host whose Agent
  tool schema has no `run_in_background` field, omission is the ONLY possible payload, and
  `parallel-dispatch-guard.sh` blocked every main-session reviewer dispatch for it. The missing-field
  case now ALLOWS with a named `dispatch_guard_background_unverifiable` event, recording that
  background-verifiability was ABSENT rather than confirmed. ADR-009 cost-weighing: a false block
  costs the entire review discipline; a false allow is bounded by this guard's other checks and by
  FEAT-024's empty-return detection. The explicit-`true` block and the `name`-absence block are
  unchanged.
- **`/nazgul:clean` left `core.hooksPath` dangling.** `nazgul/.githooks/` lives inside the directory
  clean deletes, so deleting first pointed git at a nonexistent hooks directory — which silently
  disabled ALL git hooks, the user's own pre-existing ones included. Clean now restores
  `core.hooksPath` BEFORE deleting `nazgul/`, with a belt-and-braces unset for configs installed by a
  version that never recorded `prior_hooks_path`.
- **`scripts/doctor.sh` truncated its own roster mid-run.** Three new helpers re-derived the project
  root as `proot="$(cd "$NAZGUL_DIR/.." 2>/dev/null && pwd)"`; when `nazgul/` does not exist that `cd`
  fails, and a failed command-substitution assignment under `set -euo pipefail` aborts the script. From
  any directory without `nazgul/` — the "has not run `/nazgul:init` yet" case `check_config_present`
  explicitly tolerates — the roster stopped after `messaging`: `remote-control` and `sessions` never
  ran and no coverage line printed, while the aggregate exit stayed `1`, indistinguishable from a run
  that merely found a warn. `PROJECT_ROOT` was already resolved and is `$NAZGUL_DIR/..` by
  construction, so the derivation bought nothing and cost the run. The fixture is hardened to assert
  the LAST check ran and the coverage line was reached, because an exit code cannot tell a warn from a
  truncated run.
- **`/nazgul:status`'s last-stop-gate line needed a `grep .` guard.** `jq` exits 0 on empty input, so
  the `|| echo "none"` fallback was dead code and a project with no `stop_gate` event rendered a blank
  field instead of `none`.
- **A new `stop_gate` reason, `in_flight_unverifiable`, replaces a false "proven leak" claim for an
  unobservable dispatch class (round-2 board finding F-E; TASK-004 code half, TASK-013 record half).**
  The in-flight hold (`scripts/stop-hook.sh:153-176`) read a marker's `background` field as if it had
  two reachable values and treated `"missing"` as PROVEN foreground, quarantining it under
  `stop_gate reason:"in_flight_orphan"` with stderr claiming "a foreground dispatch cannot outlive its
  turn." That claim was false: `run_in_background` is omitted from the exposed Agent tool schema under
  fork mode (the interactive default since Claude Code v2.1.232) and under
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, and absence means the OPPOSITE thing in those two
  configurations — so `"missing"` is not observed-foreground, it is not-observable-at-all.
  `in_flight_orphan` is now RESERVED for a PROVEN class (`background: "false"`, or a named dispatch
  whose report contract owns the marker); the unobservable case mints `in_flight_unverifiable` instead,
  carrying the same `unit`/`agent`/`background` fields. Behaviour is byte-for-byte unchanged — same
  `mkdir -p nazgul/in-flight/quarantine/`, same `mv`, same continue-normally — only the reason and the
  stderr text differ, because the move is irreversible and a misclassified call can never be
  reconsidered. Recorded across `RULES.md` §5, `docs/CONFIGURATION.md`, `docs/ARCHITECTURE.md`,
  `docs/SAFETY.md`, `docs/loop-engineering.md`, `skills/status/SKILL.md`, `skills/log/SKILL.md`, and
  `agents/doc-verifier.md`. Honest boundary below. Refs #104, #205, #218.
- **`tests/test-messaging-posture.sh`'s shipped-surface scan closed three round-2 board findings
  (F-A, F-B, F-C) before this release ever shipped — no live socket/token violation was found; this is
  a scanning-gap fix, not a leak fix.** (F-A) The enumerator's `*.sh|*.md|*.json` extension whitelist was
  a second, unstated definition of "the shipped surface" and could not see three shipped files:
  `scripts/git-hooks/pre-commit` and `scripts/git-hooks/pre-merge-commit` (extensionless shell git runs
  from the managed `core.hooksPath` on every commit/merge) and `templates/CLAUDE.md.template` (injected
  by `/nazgul:init`). The population is now the shipped file set (`tests/test-messaging-posture.sh:86`),
  with per-surface floors that fail an absent or zero-contributing surface (`:79-89`) instead of
  silently skipping it, pinned against a roster naming the three previously-invisible paths. (F-B) The
  scan never emitted the `NOTHING CHECKED` token its own §15 enrollment requires, and
  `tests/test-coverage-honesty.sh` captured its stderr and never read it — both now write and assert it
  (`tests/test-messaging-posture.sh:145,147`). (F-C) The two-file read allowlist (`scripts/doctor.sh`,
  `scripts/lib/session-tracker.sh`) previously skipped the socket/token scan WHOLESALE for those files,
  so a poster added inside either would have passed clean; it now applies a second-tier connect-construct
  denylist inside the allowlist (`nc -U`, `socat UNIX-CONNECT`, `openssl s_client`, `curl --unix-socket`,
  `/dev/tcp`, and any redirect/pipe targeting the socket variable — `tests/test-messaging-posture.sh:33`),
  so reading the value stays allowed and posting to it never is. `RULES.md` §22 rule 2 states the
  residual honestly: the second tier is a denylist of connect constructs, not a proof.
- **Session locks leaked for every HITL session, and the active-session count did not filter for
  liveness — both closed by round-1 board findings R2/R3.** (R2) `release_session_lock` sat at the END
  of `scripts/session-staging.sh`'s main flow, behind four early `output_result` exits unrelated to lock
  lifetime (`NAZGUL_STAGING_DISABLE`, a cwd-relative config probe, `afk.enabled != true`,
  not-in-a-git-repo) — so only an AFK session in a git repo at cwd-root ever released its lock, and every
  HITL session (`afk.enabled: false`, the template default — exactly the housekeeping-session population
  #195 is about) registered a lock at SessionStart and never released it. Fixed by hoisting the function
  and installing `trap 'release_session_lock || true' EXIT` (`scripts/session-staging.sh:66`) right after
  the stdin read and before the first gate, so release now survives every SessionEnd path, including a
  `set -e` abort. (R3) `count_active_sessions` was still `ls *.lock | wc -l` with no liveness filter, so
  one dead lock counted as an active session and blocked heartbeat auto-start until some other session
  started in that root — nothing else sweeps between ticks. `count_active_sessions`,
  `cleanup_stale_sessions`, and `duplicate_live_toplevel` now share one tri-state predicate,
  `_session_lock_is_live` (`scripts/lib/session-tracker.sh:51`: live / unreachable-by-us — `kill -0`
  cannot distinguish a gone pid from EPERM — / no numeric pid recorded, which is never treated as dead),
  and `scripts/heartbeat.sh` sweeps stale locks before counting (`:275-278`). `RULES.md` §13's
  `[enforced]` claim that the session count is "a primary, honest signal" is now actually true of the
  code it cites. New `tests/test-session-staging.sh` (14 assertions).
- **`/nazgul:doctor`'s `sessions` check — the last of the thirteen — could abort the whole roster under
  `set -euo pipefail` on the ordinary upgrade path (round-1 board finding R1).** `check_sessions`'s
  duplicate-toplevel scan ended `grep -v '^$' | sort | uniq -d | head -1`; when the loop emitted nothing
  (every pre-2.33 lock records the now-dead old hook-shell `$$`, so every lock was `continue`d), `grep -v`
  exits 1, the pipeline status is 1, the assignment fails, and `set -e` terminated `doctor.sh` before it
  ever reached `_doc_emit_coverage_line` — no coverage line, exit 1, indistinguishable from a run that
  merely found a warn, in a §15-enrolled entry point whose contract is that it always reports. Extracted
  into one shared predicate, `duplicate_live_toplevel` (`scripts/lib/session-tracker.sh:118`, guarded
  with `|| true`), used by both `doctor.sh check_sessions` and `is_concurrent_session_warning` — the twin
  expression in the latter was safe only by the accident of its caller suppressing `set -e`. New
  assertions in `tests/test-doctor.sh` and `tests/test-session-tracker.sh` pin the empty-scan case
  surviving a bare `set -euo pipefail` call.

### Known constraints (honest notes)

- **Nothing in Nazgul gates inbound messages.** The platform's own inbound controls are the only
  inbound mechanism today, and posture is the operator's decision — Nazgul documents it and never
  writes it. Receipt IS hook-observable (P6: `UserPromptSubmit` carries the message text as its
  prompt), so an enforced inbound gate is buildable if it is ever warranted. Buildable is not built.
- **UPGRADE NOTE — a pre-existing fresh foreground marker now quarantines at the next Stop instead of
  holding.** This is strictly corrective in live AFK runs: that marker was never going to be cleared
  by a completion that had already happened. No action is required.
- **The posture scan binds shipped TEXT, not runtime conduct.** Rule 2's `[enforced]` tier covers the
  files in this repository; whether a model posts to a socket on its own turn is `[advisory]`, the
  same honest boundary §21 draws for the read-back contract.
- **Suite: the discovered root suite moves 105 → 107 files, all green.** `CLAUDE.md`'s stale count of
  104 is corrected in the same pass; `/nazgul:doctor`'s roster description moves ten → thirteen in
  `CLAUDE.md` and `README.md`.
- **On a fork-mode host, the in-flight hold effectively never engages.** `run_in_background` is omitted
  from the exposed Agent tool schema there (the interactive default since Claude Code v2.1.232) and under
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, so every marker records `background: "missing"` and quarantines
  as `stop_gate reason:"in_flight_unverifiable"` rather than being held on — usually a healthy background
  dispatch, not a leak. Reading the actual dispatch class from `PostToolUse` `tool_response.status` or the
  Stop payload's `background_tasks[]`, instead of predicting it from `run_in_background` at dispatch time,
  would make the class observable rather than inferred; that is issue #218 and is deliberately NOT in this
  release.
- **Suite count correction: two board-rework fixes after the paragraph above was written add a 108th
  file.** `tests/test-session-staging.sh` is new (round-1 finding R2); the discovered root suite is 108,
  not 107 — `CLAUDE.md`'s test-count sites already read 108 to match.

## [2.32.0] - 2026-08-14

FEAT-030, ADR-021 — **"I wrote it" and "it is there" were the same claim, and they are not any more.**
A stop-hook completion gate reads a marker file the producing agent *believes* it wrote. The gate
resolves that path through `scripts/lib/nazgul-root.sh`; the agent resolved it through a bare relative
`nazgul/...` string in its own prompt, against whatever working directory its dispatch happened to
leave it in — and a subagent cannot change its own cwd, so that was never a choice of tree. When the
two answers differ, nothing errors: `mkdir -p` **creates** the wrong tree's `nazgul/logs/`, the
redirect exits 0, the agent's report of success is honest, and the gate reads the real file and sees a
value nobody wrote this objective. `NAZGUL_COMPLETE` is then withheld on a write that did happen, or
granted on a value that is stale. The blast radius was the roster, not one file. A second, independent
defect sat on the same gate: during FEAT-025 the marker held `FEAT-025` while the verifier reported
FINDINGS PRESENT and stated it had withheld the marker — because the bounded backstop writes **the
same value an honest clean pass writes**, so on exhaustion the record could not distinguish "verified
clean" from "gave up". **MINOR, not PATCH:** an operator can observe a different value in
`nazgul/logs/.comments-verified`, a new `gate_attribution` event, a new reporting contract from four
agents, and new default-on enforcement over the shipped agent roster. **MAJOR is wrong:** no skill,
agent, flag, or config key is removed or renamed, no gate changes meaning, and no backstop is removed.
**There is no config schema step — `schema_version` stays at 36**, which is itself the evidence that
nothing an existing project stores had to change.

### Added

- **`scripts/audit-agent-state-paths.sh` — a scan of the shipped roster, not of a diff.** It
  enumerates every file under `agents/` (templates included) and classifies each `nazgul/...`
  occurrence as state-write, state-read, or prose; prose is COUNTED rather than silently dropped, so
  the exemption stays visible. An occurrence is operational on any of six enumerated signals (two
  structural, four textual) with negation detection, so a conversion task can argue with a verdict
  instead of guessing at it. The current roster run reports `24 scanned, 1 skipped (non-spec=1,
  unreadable=0, not-a-file=0), 23 checked, 0 findings` over 356 classified occurrences (state-write=82,
  state-read=166, prose=108). **The auditor REPORTS and always exits 0 by design** — it shipped while
  the roster was still unconverted, and a nonzero exit would have held the suite red across five
  conversion tasks. The gate is the test, not the script.
- **`gate_attribution` — an additive event that names which writer satisfied a gate.** Emitted by
  `scripts/stop-hook.sh:1216` on every satisfied comment-verifier path, carrying `gate`, `writer`,
  `objective`, `marker`, and `attempts`. `writer` is one of `verifier-clean`, `degrade-to-allow`, or
  `backstop-exhausted`. Additive rather than a new `stop_gate` reason on purpose: `stop_gate` means a
  gate ENDED or short-circuited a run (ADR-014) and its population is deliberately narrow so a consumer
  can count stops; attribution fires on the opposite path — the gate was SATISFIED and the run
  continues.
- **`RULES.md` §21 — Runtime-State Path Addressing & Write Read-Back**, seven rules with an honest
  tier on each. Addressing, event emission, gate DELEGATE grammar and the tool-grant pin are
  `[enforced]`; the `CLAUDE_PROJECT_DIR` bridge is `[advisory]`; the read-back rule is split
  deliberately — `[enforced]` for the spec contract, `[advisory]` for whether a dispatched model
  actually performs the read-back on a given turn, because no prompt contract can be enforced inside a
  model's turn and tagging that half `[enforced]` would be exactly the dishonesty the tier legend
  exists to prevent. Rule tier counts move to **78 enforced / 31 advisory / 22 hook-driven only**. The
  section lives in `RULES.md` rather than a per-objective document for FEAT-029/TASK-012's reason: a
  durable contract citing an objective doc gets archived out from under its own citation.
- **Five test files — the discovered root suite moves 99 → 104, all green.**
  `tests/test-marker-write-tree-resolution.sh` reproduces the defect itself in a two-tree fixture built
  with a real `git worktree add`. `tests/test-agent-state-path-contract.sh` is the gate: `F == 0` over
  the shipped roster with a `K > 0` floor (a zero-file scan is a broken scan, not a clean roster) and a
  dogfooded predicate — a synthetic spec carrying a known relative state write must make the gate fail,
  because a roster clean by construction can only ever pass and would be evidence of nothing.
  `tests/test-agent-state-path-audit.sh` covers the auditor's own classification.
  `tests/test-gate-delegate-paths.sh` drives the real hook, slices each gate's message from its banner
  to its opt-out line so one gate's text cannot satisfy another gate's assertion, and PROVES the gate
  fired before asserting on it — a message never emitted would otherwise satisfy every "must not
  contain" check trivially. `tests/test-marker-readback-contract.sh` asserts the shipped specs state
  the contract AND extracts each spec's own recipe and runs it in a two-tree fixture under the
  wrong-cwd condition agents are really dispatched into, so the recipe is checked by execution rather
  than by reading.

### Changed

- **Every `nazgul/` read and write in `agents/**` is addressed, never inherited.** Twenty-two agent
  specs plus `agents/templates/reviewer-base.md` now write `<main_worktree_path>/nazgul/...`, with
  `<main_worktree_path>` supplied by the caller in the dispatch brief; if the brief omits it the agent
  falls back to `branch.main_worktree_path` in the config it was pointed at, and if that is unreadable
  too it STOPs and reports — never cwd, never a guess, never a worktree it creates for itself.
  `NAZGUL_DIR="$(pwd)/nazgul"` is the same defect under another name and is a finding too, in two
  distinct shapes: `scripts/lib/emit-event.sh:21-22` returns 0 without writing when `NAZGUL_DIR` is
  UNSET; when it is SET but names a tree with no initialised `nazgul/`, `:70-72` creates that tree's
  `logs/` and writes the event into it, so the record lands where nobody reads it. Either way the
  observability surface fails by the exact mechanism it exists to observe — but the second is a
  misdirected write, not a missing one, and you diagnose it by finding the stray tree.
- **A third resolution mechanism was deliberately NOT invented, and the reason is specific.**
  `scripts/lib/nazgul-root.sh` is unchanged and ADR-008 stands; agents pass
  `CLAUDE_PROJECT_DIR="<main_worktree_path>"` (or `--project-root=` for `scripts/red-run.sh`) when
  invoking a Nazgul script. From a task worktree with `nazgul/` gitignored — this install's own
  configuration — `resolve_project_root()` returns the TASK WORKTREE, because no
  `<candidate>/nazgul/config.json` marker exists there to arbitrate with. The resolver answers "which
  tree is this process in?"; `branch.main_worktree_path` answers the different question "where does
  runtime state live?". An agent sourcing the resolver would convert a visible relative path into an
  invisible confidently-wrong one — ADR-008's own hazard class, reintroduced.
- **The four post-loop gates instruct in the grammar they can read.** `scripts/stop-hook.sh`'s
  doc-verifier, comment-verifier, self-audit, and learner DELEGATE messages each hand the agent
  `<main_worktree_path> = ${PROJECT_ROOT}` and the resolved ABSOLUTE marker path the gate will later
  read — never a bare relative write target the gate then resolves through a different mechanism than
  the agent did.
- **A write is not written until it is read back.** The four marker-writing agents
  (`comment-verifier`, `doc-verifier`, `self-audit`, `learner`) must resolve the absolute path from
  `<main_worktree_path>`, VALIDATE the value before writing, write, RE-READ the same absolute path,
  report the resolved path and the value actually persisted in their final text, and report FAILURE on
  mismatch, unreadable file, or unresolvable path — claiming no gate satisfied. Reporting is the
  deliverable, not writing. The stop-hook still reads the marker file rather than the report; the
  report is what makes a lost write visible to a human and to `scripts/subagent-stop.sh`'s final-text
  inspection instead of disappearing into an honest-looking success.
- **`CV-8` and `CV-2` in `tests/test-comment-verifier-gate.sh` changed, and the justification is
  recorded here so a reader of the diff sees a strengthened assertion rather than a weakened one.**
  Both previously asserted `assert_eq` between the marker and the bare `feat_id` — that is, they
  asserted the give-up writers produce a value **byte-identical to a clean pass**. Those assertions
  pinned the defect. Each is now an inequality against the clean-pass value plus a `feat_id`-scoping
  containment check: a *narrower* guarantee (no single literal is pinned) that is *stronger* (the one
  value the defect produced is forbidden). CV-8 additionally proves the backstop marker satisfies the
  gate on re-run without re-blocking and is stable across it, so the strengthening cannot deadlock an
  unattended loop. New CV-10 extends this to attempt counts 3, 4, 7, and 99 — the suffix is unreachable
  from the clean-pass path at ANY count, not merely at the bound — and new CV-11/CV-12 pin the
  degrade-to-allow and clean-pass writers with their own attribution events.
- **`scripts/audit-agent-state-paths.sh` is the eighth entry point bound by the coverage-honesty
  contract** in `RULES.md` §15 (enrolled FEAT-030/TASK-002), and is actually driven by
  `tests/test-coverage-honesty.sh` — including a forced all-skip run that must still name and count its
  sole candidate — rather than merely listed. Like `scripts/self-audit.sh` and `scripts/doctor.sh` this
  advisory surface writes NO event for the vacuous case: it is a read-only repo scan with no runtime
  tree of its own, and writing runtime state from it would commit the very defect this release closes.

### Fixed

- **The comment-verifier's marker write landed in whichever tree its dispatch left it in.**
  `agents/comment-verifier.md`'s three relative paths (`mkdir -p nazgul/logs`, a `jq` read of
  `nazgul/config.json`, and the redirect into `nazgul/logs/.comments-verified`) are absolute and
  read back. The identical recipe in `doc-verifier`, `self-audit`, and `learner` is fixed the same way.
- **The marker write could silently write nothing.** The baseline sequence wrote a one-byte empty line
  when its `jq` read failed, because the command substitution captured stdout only while the redirect
  still succeeded. The value is now validated for emptiness and shape before any write; a bad value is
  a reported failure and NO write.
- **A backstop that gave up was indistinguishable from a verifier that passed.** The comment-verifier
  gate now has three writers and three values: the bare `feat_id` from a clean verifier pass,
  `CV_DEGRADED_VALUE="${CV_OBJ_ID}:NO-SOURCE-CHANGED"` (`scripts/stop-hook.sh:1135`) from
  degrade-to-allow, and `CV_EXHAUSTED_VALUE="${CV_OBJ_ID}:EXHAUSTED"` (`:1136`) from the bounded
  backstop. The `:` suffix is unreachable from the clean-pass write path, so a suffixed marker can only
  have come from a gate that gave up rather than verified. Read these values out of
  `scripts/stop-hook.sh`, never out of a design document — ADR-021 left the event type and the sentinel
  shape to implementation precisely so no document could name a value the codebase does not have.

### Decided and recorded, with a falsifier

- **ADR-021 Decision 4 — marker-writing agents keep `Bash`; `Write` is not granted.** `learner`
  **RETAINS** the `Write` grant it already held at baseline; `comment-verifier`, `doc-verifier`, and
  `self-audit` are NOT granted one. Reasons in order of weight: the tool is not the failure (a `Write`
  to a relative path resolves against the same wrong cwd, and an unverified `Write` makes the same
  unproven claim — the addressing and read-back rules fix both, for either tool); granting a general
  file-write tool to an adversarial read-only verifier is allow-widening in the direction opposite this
  repository's guard doctrine, which `tests/test-reviewer-readonly.sh` exists because of; and the
  premise for granting it — that Bash is blocked — is non-reproducible, since `pre-tool-guard.sh` and
  `local-mode-tracking-guard.sh` both exit 0 for the exact redirect. Pinned in BOTH directions by
  `tests/test-marker-readback-contract.sh` MR-C — adding `Write` to the three verifiers and stripping
  it from the learner are equally drifts from the record — with a control fixture proving the matcher
  can see a `Write` grant it is supposed to find. **Falsifier:** if a roster audit or a future install
  mode produces a guard that DOES block that redirect, this decision is revisited and the grant made,
  scoped and pinned by a test.

### Known constraints (honest notes)

- **The two sibling completion gates are filed, not fixed.** `.docs-verified` and `.self-audited` still
  share the exhaustion-write shape closed here for `.comments-verified`: all three doc-verifier writers
  and both self-audit writers produce byte-identical markers, so their satisfaction comparisons still
  read "verified" from a write that meant "gave up". PRD AC7 named the comment-verifier gate only and
  the PRD Non-Goals left the sibling call to the audit, so this is filed to `nazgul/inbox/` as a p2
  (`sibling-gate-markers-conflate-verified-with-gave-up.md`, reproduced at the FEAT-030 feature tip
  before the fix landed) rather than silently dropped or silently widened.
- **Half of the read-back rule cannot be mechanically enforced, and is tagged that way.** The specs are
  checked by execution; whether a dispatched model performs the read-back on a given turn is not
  observable from a static test, and `RULES.md` §21 item 5 says so in its tier rather than in a
  footnote.
- **The roster auditor is advisory by construction.** It always exits 0. What makes the roster stay
  clean is `tests/test-agent-state-path-contract.sh`'s `F == 0` gate with its `K > 0` floor, not the
  script's exit status.
- **The residual `Write`-grant risk is accepted and stated.** A state write on a shell redirect that no
  guard blocks is one config change from breaking. The read-back contract is the mitigation: whichever
  tool writes it, the writer must prove it landed.

## [2.31.0] - 2026-08-08

FEAT-029, ADR-020 — **a validated request is not a completed write.** The whole release follows from
that one sentence. `task-state-guard.sh` used to authorize a status transition at PreToolUse time and
the loop later treated that authorization as proof the manifest had actually changed; between the two
sat an unguarded gap in which nothing, or something else entirely, could land on disk. The same
mistake had a second face: when reconciliation caught a manifest it could not account for, it wrote a
prose blocker with no machine-readable statement of *what* disagreed and no route out except
re-implementing finished work. Alongside that, the historical v2.28.1 dogfood report's remaining
live findings — unconstrained reviewer dispatch, Bash-mediated manifest mutation, exact
generated-artifact path claims made from intent alone, worktree instructions the host does not honour
for subagents, shared prompt references that resolved only in a checkout of this repo, and a
self-audit miner producing more false findings than real ones — are closed here. **MINOR, not PATCH:**
this adds new capability an operator can invoke (`scripts/task-transition.sh`, including its `repair`
subcommand) plus new default-on enforcement (direct status writes are now denied for everyone).
**MAJOR is wrong:** no skill, agent, flag, or config key is removed or renamed, and every workflow
that was already going through sanctioned routes behaves identically. **There is no config schema
step — `schema_version` stays at 36**, which is itself the evidence that nothing an existing project
stores had to change.

### Added

- **`scripts/task-transition.sh` — the sole sanctioned task-status writer.** Under a per-task lock it
  validates one staged snapshot, rechecks the source status immediately before an atomic rename,
  verifies the target on disk, and only then records the exact `FROM -> TO` edge. The lock serializes
  authoritative writers; it makes no claim about an unrelated raw filesystem write.
- **`task-transition.sh repair TASK-NNN` — an evidence-gated exit from quarantine that never
  re-implements.** Closed to every blocker class except reconciliation, it revalidates five
  independent evidence checks from local files and Git history before any write, then takes
  `BLOCKED -> IN_REVIEW -> DONE` through the ordinary transactional primitive. It never uses `READY`
  and never dispatches an implementer. Six named refusal reasons; a spent
  `reconciliation (repaired …)` marker cannot re-authorize it.
- **Typed reconciliation quarantine.** A quarantine now records `Blocked kind: reconciliation` plus
  the checkpoint `Blocked from` and untrusted `Blocked observed` endpoints, emits
  `reconciliation_quarantine`, and names the repair route in the manifest itself. Review-evidence,
  review-provenance, and git-conflict blockers are typed too, so "the loop stopped" is no longer a
  single undifferentiated state.
- **An artifact claim evidence ledger for the doc generator** (`agents/doc-generator.md`). Source
  intent and verified output are separate facts; exact-path certainty from intent alone is
  prohibited; verification commands come from the project's own `project.*_command` config rather
  than an assumed toolchain; unsafe or unavailable verification yields a visible `UNVERIFIED` marker
  plus a test-plan obligation instead of invented evidence.
- **Five adversarial test suites** — `test-task-transition-command.sh`,
  `test-task-reconciliation-repair.sh`, `test-agent-worktree-contract.sh`,
  `test-doc-generator-contract.sh`, `test-reference-paths.sh`. The discovered root suite moves
  **93 → 98 files**, all green.

### Changed

- **Direct status writes are denied — this is the one behavior change every user sees.**
  `task-state-guard.sh` now refuses EVERY direct `Write`/`Edit`/`MultiEdit` of a task's status, legal
  or not, and routes the caller to the command. Preflight is no longer authority and can no longer
  create the record reconciliation trusts. Agents, `agents/review-gate.md`, and
  `skills/task/SKILL.md` (including its `sed` SKIPPED writer) were migrated to the command first,
  and a forbidden-form scan reporting `scanned / skipped / checked / findings` keeps them there.
- **Reconciliation resolves legitimacy from a chain of completed edges,** not one ledger entry — a
  single loop iteration legitimately spans several transitions, and demanding one entry misread
  normal progress as tampering.
- **The `PLANNED -> READY` dependency gate is granularity-aware, via one authority.**
  `ttg_dependency_satisfied` is now the sole implementation, shared by the command and the
  stop-hook's auto-promote arm. Under `group`/`feature` granularity a dependency at `IMPLEMENTED` or
  later satisfies the gate: requiring `DONE` there was **unsatisfiable**, because no task reaches
  `DONE` until the aggregate board runs at the end of the objective. That deadlock became total the
  moment direct manifest writes were closed, and it is fixed here rather than worked around.
- **Reviewer dispatch is mechanically constrained** to explicit unnamed foreground dispatch from the
  main session, enforced ahead of the parallel-mode branch. Missing background metadata is accepted
  only when the hook caller identity proves a nested synchronous-only schema. `/nazgul:patch` lost
  its background fork context and drives review from the main session under the one canonical
  returned-text contract.
- **Agents are handed an existing task worktree instead of being told to create one.** The
  `EnterWorktree`/`ExitWorktree` grants are gone from `implementer`, `simplifier`, `review-gate`, and
  `team-orchestrator` — a subagent session is not granted those tools, so the old text described a
  contract the host does not honour for that caller. Implementer and simplifier verify the supplied
  worktree with `git -C <path> rev-parse --show-toplevel` and STOP rather than creating one; every
  git command names its directory with `-C`, and file tools take absolute paths.
- **Every shared prompt reference is `${CLAUDE_PLUGIN_ROOT}`-qualified** across the agent roster and
  all shipped skills, and is resolved against a package staged from the shipped file set — so a
  reference that resolves only in a checkout of this repo now fails. `skills/start`'s
  `greenfield-scaffolding` and `tool-preflight` citations resolve to `skills/start/references/`, not
  the root directory; the naive plugin-root prefix would have broken them.

### Fixed

- **Bash-mediated manifest mutation.** `pre-tool-guard.sh`'s three text-substring rules are replaced
  by a structural closed-writer policy over the existing no-eval tokenizer: redirects into a manifest
  (any command), `mv`/`cp`/`install`/`ln` by final argument, `tee`, in-place `sed`/`perl`/`ruby`/`awk`,
  an interpreter carrying a manifest path in its program text, one `bash -c` hop, and a heredoc-fed
  interpreter. Path matching uses the strict `nazgul/tasks/TASK-<digits>.md` matcher, so patch
  manifests, per-task artifact directories, and delegation briefs stay out of the blast radius; read-only
  inspection and every spelling of the sanctioned route were verified to still work *before* the routes
  were closed. **`RULES.md` states plainly that a denylist over a Turing-complete shell is not
  exhaustive**, names what it does not catch, and names the layers that make an unsanctioned write
  ineffective anyway.
- **A lock liveness defect that could wedge a task permanently.** A writer killed between its `mkdir`
  and its owner-file write left an ownerless lock no one could ever reclaim. It is now reclaimable
  after a bounded grace via `rmdir`, which refuses a directory that has since gained an owner, and the
  acquire publishes its token before the owner write so no signal window can skip the release trap.
- **Four self-audit mining defects — the miner that audits the loop was the loudest producer of false
  findings in it.** A cross-project census of 580 `improvements.md` entries found ~352 (61%) false or
  duplicate, and 292 false model-drift findings buried 108 genuine ones 3:1. (1) Role attribution now
  comes from `message.attributionAgent`, not the opaque `agent-<hex>.jsonl` filename, which matched no
  role pattern and so compared every subagent against `models.default`; generic harness agent types are
  reported unclassifiable rather than guessed at. (2) A configured **bare alias is a family pin**
  (`sonnet` matches `claude-sonnet-5`) while a configured full model id stays an exact pin, so version
  drift still reports and true cross-family drift still emits exactly one finding. (3) The verdict is
  now the only rejection signal — the old `grep -q 'REJECT'` fallback matched `- **REJECT**: none.`,
  the line a lane writes when it has *no* rejections, so a unanimous APPROVE board emitted a full set
  of rejections; `grep -a` is mandatory on verdict reads because BSD grep reports no match in a
  NUL-bearing file, making the same board mine differently depending on a byte nobody can see.
  (4) Per-file high-water marks in `nazgul/self-audit-window.json` advance the mined window so the
  line-oriented miners start after the last run (a shrunken file is re-mined from the start, loudly),
  with a `(title, first line of evidence)` index seeded from the on-disk backlog to suppress
  re-appends.
- **Coverage honesty extended to `self-audit`.** Every miner emits `scanned / skipped / checked /
  findings` with a closed reason list and a summable run total asserting `N == M + K`; `self-audit` is
  now the seventh entry point bound by the contract in `tests/test-coverage-honesty.sh` — and is
  actually driven by it, not merely listed.
- **A durable contract that was anchored to a disposable document.** `tests/test-coverage-honesty.sh`
  cited "TRD §6" — the *FEAT-028* TRD, archived when that objective completed, so the citation pointed
  at a section the live TRD does not contain. The registry moved to `RULES.md` §15, which survives
  objective rotation. Any test or guard citing "TRD §N" or "PRD ACn" as its authority has the same
  expiry built in.

### Historical report claims — explicit dispositions, not silent omissions

FEAT-029 revalidated the v2.28.1 dogfood report against live v2.30.0 rather than trusting it. Eight
claims were **not** implemented, each for a stated reason. They are recorded here so their absence
from the "Fixed" list above is a decision with a reason attached rather than an oversight:

- **Already fixed in v2.30.0** — (1) the discovery-generated self-writing reviewer template: discovery
  renders the canonical reviewer base, generated reviewers are read-only, use `[UNIT-ID]`, return
  `APPROVE | CHANGES_REQUESTED | UNVERIFIED`, and install no self-write hook. (2) The generated
  reviewer `allowed-tools`/self-write contradiction, fixed at the template; the residual contradictory
  prose in `review-gate` was live and *is* fixed in this release.
- **Superseded** — (3) "naming alone creates an Agent-Teams teammate": named subagents and Agent Teams
  are distinct under current host semantics. FEAT-029 still forbids reviewer names, as one-shot
  hygiene, but does not rest on the historical causal claim. (4) "stale checkpoints are ignored even
  for guarded transitions": since FEAT-015 a matching ledger endpoint after the checkpoint is
  consulted; the live defects were pre-write authorization, non-contiguous trust, and no safe repair —
  all addressed above. (5) "no `BLOCKED -> IN_REVIEW` route exists": the route exists for prose reasons
  containing `review evidence`; what was genuinely missing was availability to *typed* reconciliation
  blockers, which `repair` now provides. (6) "one fresh re-dispatch for empty/stub returns": the
  universal `SubagentStop` same-context resume plus bounded gate retry and `UNVERIFIED` handling is
  strictly stronger; correct dispatch routing was still required, because teammate routes bypass that
  recovery.
- **Not reproducible as stated** — (7) "the package entirely omits `ui-brand.md`": the root file *is*
  packaged. The real defect was ambiguous relative resolution, fixed above. (8) "a normal subagent
  `Edit` never fires the task-state hook": static wiring covers `Write|Edit|MultiEdit`, and this could
  not be reproduced under the execution environment used here — so it is left open rather than
  labelled fixed.

### Known constraints (honest notes)

- **No paid Claude run was performed for this objective.** Implementation and review used
  Codex-native agents and tools; current host semantics are represented by official contract evidence
  and real hook envelopes rather than by a live authenticated Claude execution. Claim (8) above stays
  open for exactly this reason, and no assertion in this entry should be read as a result observed
  from a paid run.
- **The Bash writer denylist is not a proof of exclusion.** It closes the routes it enumerates and
  says so in `RULES.md`; a sufficiently indirect shell construction can still reach a manifest. What
  makes such a write ineffective is the layers behind it — reconciliation, the transition ledger, and
  the evidence gates — not the denylist alone.
- **`scripts/worktree-utils.sh:346` still repeats the stale claim** that `EnterWorktree` is a live
  worktree-entry path. It was reported rather than edited, being outside the scope of the task that
  found it.
- **`tests/test-doc-generator-contract.sh` pins the prompt contract, not the doc generator's
  compliance with it** — which is why the corresponding `RULES.md` §7 rule is tagged `[advisory]`
  rather than `[enforced]`. Rule tier counts move to 69 enforced / 27 advisory / 22 hook-driven only.

## [2.30.0] - 2026-08-05

FEAT-028, ADR-019 — a green test is evidence only after it proved it can turn red. The suite had
strong regression breadth but no mechanical proof that a new test failed without its change, several
entry points could report success after checking nothing, and the guard intended to police this
shell-first repository exempted shell entirely. This release turns test reality into an enforced
artifact: pre-change red runs are captured into task manifests, guards exercise real entry paths with
minimal state generated in disposable projects, and every checking entry point accounts for what it
skipped. Project-local Nazgul runtime state is never committed as test fixture data. MINOR, not PATCH:
this is new enforcement capability, an additive schema step, and a
default-on behavior change — a `scripts/**`/`tests/**` task with missing or corrupt red-run evidence is
now blocked at IMPLEMENTED. Nothing user-invoked is removed or renamed. **`schema_version` moves 35 →
36** (`migrate_35_to_36`, additive): `guards.red_run_evidence: true`, preserving explicit `false`.

### Added — the six deliverables

1. **Mechanized red-run evidence.** `scripts/red-run.sh` creates a detached worktree at a task's Base
   SHA, copies only the changed test inputs (never the changed harness), runs the scoped filter, rejects
   exit-zero vacuity and zero-match runs distinctly, and writes the parseable `## Red-Run Evidence`
   block itself. The shared task-transition library validates ref resolution, ancestry, exit status,
   scope-valid N/A tokens, and commit ordering on both guarded writes and bash-write reconciliation.
2. **Guard dogfooding on real inputs.** The suite drives generated shell bodies, hook payloads, Git
   repositories, short-SHA manifests, checkpoints, and file swaps through production entry points.
   Each test creates the smallest supported state it needs under a temporary directory instead of
   copying a working project's `nazgul/` directory into the repository.
3. **Coverage honesty across checking entry points.** Unit, E2E, smoke, JSON, guard, doctor,
   heartbeat, and reviewer-verifier surfaces report fixed-grammar
   `N scanned, M skipped (...), K checked, F findings` records with `N == M + K`; blocking runners use
   nonzero NOTHING CHECKED results, while advisory surfaces retain their exit policy and emit
   `coverage_vacuous`.
4. **True-entry headless smoke.** `tests/smoke/run-smoke.sh` exercises `/nazgul:heartbeat` and a bounded
   `/nazgul:start` loop only in disposable scratch projects, with timeout/accounting, p1 failure filing,
   and hard refusal to touch this repository's live `nazgul/` state. `.github/workflows/smoke.yml` is
   manual + nightly only and uses the `ANTHROPIC_API_KEY` secret; cheap shape checks remain in normal CI.
5. **Adversarial QA charter.** The generated `qa-reviewer` now treats unproved-green tests as presumed
   vacuous, checks red-run evidence, scratch-state construction, guard realism, and coverage accounting,
   and blocks committed Nazgul manifests, reviews, checkpoints, locks, or inbox records.
6. **Retroactive reality audit.** `docs/test-audit-2026-08.md` records exactly one verdict for all 118
   scoped files (93 root tests, 2 helpers, 12 E2E files, 11 pre-existing fixtures): 84 clean, 15
   `vacuous-fixed`, 19 `vacuous-filed`, and 0 not-audited. TASK-017 began with 34 affected files; 15
   were repaired and 19 remain explicitly filed. All nine findings have a fix or prioritized filing.

### Changed

- **Default-on IMPLEMENTED evidence gate.** A task whose declared scope touches `scripts/**` or
  `tests/**` must carry usable red-run evidence or one of the three scope-checked enumerated exemptions
  (`docs-only`, `config-only`, `deletion-only`). Missing/corrupt evidence emits `red_run_missing` and
  blocks. `guards.red_run_evidence: false` suppresses only the block — detection, stderr, and telemetry
  remain, so the kill switch cannot turn absence into a pass.
- **Suite growth and accounting.** The objective began with 86 root tests; seven adversarial/smoke
  files bring the discovered suite to 93. Shared assertions now distinguish grep errors from a real
  no-match, fail negative-file assertions when the file is absent, reject zero-assertion summaries,
  and count unavailable checks as skips rather than fabricated passes.

### Fixed — pulled-in defects, deliberately fenced

- **Lean-comments shell coverage (filing items 1–3).** `.sh`, `.bash`, and shebang-classified shell are
  now checked with one explicit header-block allowance; a real six-line shell body run is blocked, and
  `--check` reports its skipped coverage plus `coverage_vacuous`. **Remaining filed scope:** item 4,
  the measured sweep/waiver of pre-existing bloat (128 of 167 tracked shell files, 1,748 findings), was
  not silently rewritten in this objective.
- **Board-sync manifest parsing (sub-defects A/B).** Both status sites use the shared frontmatter-aware
  task parser; titles come from the real H1; bodies tolerate current planner/patch sections; missing ID
  fields no longer abort; and `sync-all` reports synced-of-total rather than claiming every attempt
  succeeded. **Remaining filed scope:** C (feature/plan/roadmap tier) and D (objective-rotation
  `task_map` reuse) remain open and the inbox item stays active.
- **Retroactive harness repairs.** JSON validation discovers all tracked plugin JSON instead of five
  hand-listed paths; E2E absent-CLI and zero-match paths return NOTHING CHECKED; session helper grep
  errors and `set -e` counter aborts are repaired. Semantic `/nazgul:init` and `/nazgul:status` E2E
  assertions remain filed until authenticated outputs can be captured rather than guessed.

### Known constraints (honest notes)

- The paid headless smoke scenarios were authored, linted, and shape-tested but were not run during
  implementation; they require an authenticated `claude -p` environment and intentionally run only by
  manual/nightly workflow. Local interactive Claude may use stored account/OAuth login without an API
  key; the GitHub headless workflows explicitly require `ANTHROPIC_API_KEY`.
- Four unit tests still replay consumer-authored `gh` response shapes (V2), and the bootstrap-transform
  golden corpus cannot establish its original authorship (V1). Both are prioritized audit filings, not
  silently labeled clean.

## [2.29.0] - 2026-08-03

FEAT-027, ADR-018 — an objective's end must not idle the loop (governing thesis for this release).
Today the loop opens a PR to `main` and stops; nothing merges it, and the next objective cannot
honestly start. Worse, the framework already stacked **accidentally, with zero management**:
`create_feature_branch()` captured whatever branch happened to be checked out as the base with no
assertion it was `main`, so a next objective started before merge silently branched off the
unmerged feature branch — un-linked, un-retargeted, un-rebased. This release ships a managed
alternative (`execution.stacking`, opt-in, default-off: objective N+1 branches off objective N's
unmerged tip and its PR stacks on top via the official `gh-stack` CLI extension) **and** closes the
accidental variant for everyone. The boundary that makes this safe: **stacking changes when work
starts, never what "done" means** — one objective is still one PR, and the task state machine,
review board, and per-objective release flow are byte-identical either way. GitHub owns every
retarget/rebase/merge mechanic server-side; Nazgul owns only the `stack.layers[]` registry and the
policy gates. There is **no hand-rolled `rebase --onto` anywhere** — a locked decision, on the
evidence of two prior non-convergent attempts at hand-rolled rebase machinery in this repo. MINOR,
not PATCH, on this repo's own precedent for exactly this shape: a new opt-in capability plus an
additive schema migration (FEAT-008's opt-in heartbeat → `2.11.0`; FEAT-012's opt-in connector →
`2.15.0`). MAJOR is wrong — nothing an operator invokes is removed or renamed, and every existing
non-stacking workflow that was already correct behaves identically. **`schema_version` moves 34 →
35** (`migrate_34_to_35`, additive; explicit values including `false` preserved).

### Changed
- **`create_feature_branch()` now asserts its base branch and refuses a stray checkout — this is the
  one behavior change users who never opt into stacking will see.** With stacking off (or enabled but
  unusable) the base is read from `branch.base` (default `main`) and the currently checked-out branch
  must equal it; a mismatch **returns non-zero and refuses loudly**, naming the stray branch and the
  remediation (`git checkout main`, or `/nazgul:start --stack`). Starting an objective from a
  non-`branch.base` checkout previously succeeded silently and produced an unmanaged accidental
  stack; it now fails. With stacking enabled and ready, the branch is created from `stack_tip` by
  explicit ref name rather than from `HEAD`, with a registry entry written at creation and a config
  rollback if that registry write fails. Task branches (`feat/<id>/TASK-NNN`) are unaffected.
- **The objective-end PR is mechanized, and `objectives_history[].pr` is now actually written.** The
  duplicated `gh pr create` prose in `skills/start/SKILL.md` (OBJECTIVE_COMPLETE) and
  `agents/review-gate.md` (Step 5.1) is replaced by one `stack_submit` call that owns the push, the
  PR, the registry update, and the history write **in both modes**. `objectives_history[].pr` was
  previously written by nobody at PR time — that mechanical write now happens for all users, stacking
  or not.
- **`/nazgul:doctor` now runs ten checks** (was eight): the two new stacking checks below.

### Added
- **`execution.stacking` (schema v35, opt-in, default-off)** — `enabled` (`false`), `max_unmerged`
  (`3`, the cap on open layers) and `rework_priority` (`1`). Three further keys are written at
  runtime by the lib and absent from a fresh config: `halted`/`halt_reason` (fail-closed flag,
  cleared only by a human) and `api_failures` (consecutive-failure counter; 3 halts stacking,
  mirroring `connectors.github.pull_failures` but halting rather than auto-disabling).
- **`stack.layers[]` — a script-owned registry.** One entry per layer (`{feat_id, branch, pr, base,
  state, opened_at, merged_at}`), idempotent per `feat_id`. `scripts/lib/stack-utils.sh` is its
  **sole writer**; operators read it and never hand-edit it.
- **`scripts/lib/stack-utils.sh`** — the only home of `gh stack` invocation: `stack_available`
  (three-state `disabled`/`ready`/`missing`, with extension presence checked via `gh extension list`
  text, never by invoking `gh stack` and reading its failure), `stack_tip`, `stack_unmerged_count`,
  `stack_register_layer`, `stack_submit`, `stack_reconcile`, `stack_detect_changes_requested`.
- **`--stack` / `--no-stack` start flags** (three-state, mirroring `--parallel`, in the single
  source of truth `scripts/apply-start-flags.sh`): `--stack` persists `enabled=true`, `--no-stack`
  persists `false`, omitting both leaves the persisted value untouched so a prior objective's choice
  survives a resume.
- **Continuation, on both entry paths.** `scripts/heartbeat.sh` runs three pre-triage steps under its
  own `count_active_sessions` check (a rebase must never run under a live session) — reconcile,
  rework detection, cap gate — and `/nazgul:start` runs the same three inline before branch setup. At
  or over the cap, the tick records `decision: skipped, reason: stack_cap_reached` and `/nazgul:start`
  stops with the count, the cap, and the remediation; never a silent skip. A `stack-rework` pick is
  exempt from the cap and is handed to `/nazgul:start`'s new **Stack Rework Routing** with **no**
  archive-then-start (the routing performs its own archive-as-claim after re-scanning the live
  inbox), recorded as `decision: started, reason: rework_handoff`.
- **Auto-filed rework items — the first mechanical producer of inbox items in the framework.** A
  `CHANGES_REQUESTED` review on an open layer files exactly one p1 item per PR + review id
  (idempotent, including against `inbox/archive/`) with frontmatter `type: stack-rework`, `branch:`,
  `pr:`. The review body is embedded verbatim as **data, never instructions**, byte-capped by
  `connectors.github.pull.max_body_bytes` — same doctrine as connector issue bodies (RULES.md §16).
- **Two read-only `/nazgul:doctor` checks** — `stacking` (tooling readiness: `gh`, the `gh-stack`
  extension, `gh auth`, and the halted flag, each named individually) and `stack-registry`
  (registry-vs-GitHub drift for open layers). Both report `Not applicable` when stacking is disabled;
  neither writes state.
- **Stack visibility** — a **Stack** section in `/nazgul:status` (layers, PR states, unmerged vs cap,
  at/over-cap warning, `HALTED:` line, and an explicit "registry unreadable" variant that never
  renders a failed read as healthy) and a one-line stack map in the SessionStart context.
- **New event types** — `stack_layer_merged`, `stack_rework_filed`, `stack_sync_conflict`,
  `stack_api_failure`, `stack_remote_layer_imported`, `stack_remote_layer_import_failed`, plus a new
  `stop_gate` reason `stacking_unavailable` (stacking enabled but tooling unusable: the loop still
  opens the ordinary plain PR, but the fallback is never silent).
- **`.github/workflows/e2e-stack.yml` + `tests/e2e/run-stack-e2e.sh`** — a manual-trigger
  (`workflow_dispatch`) two-layer stack E2E against a live disposable scratch repo, requiring a
  `STACK_E2E_GH_TOKEN` secret (`repo` + `delete_repo`; the default workflow token cannot create or
  delete arbitrary repos). **This workflow has never been executed** — it is authored, syntax-checked,
  and deliberately never wired to push/pull_request/schedule because it creates real repos and PRs
  and costs API calls and Actions minutes. Its claims are unverified until someone runs it.
- **`nazgul/docs/ADR-018`** — the empirical `gh-stack` v0.1.0 probe (run in a disposable GitHub repo
  before any integration code existed, FEAT-024's probe-first precedent) and the binding design
  adjustments every downstream task implemented against.
- **Test coverage** — `tests/test-stack-utils.sh` (139 assertions) and `tests/test-heartbeat-stack.sh`
  (28), plus extensions to the migration, config-schema, doctor, session-context, start-flags,
  worktree-utils, and heartbeat-triage/log suites.

### Known constraints (honest notes)
- **`gh pr merge` is rejected outright for a PR that is part of a stack** — GitHub's API demands the
  asynchronous merge REST endpoint. This is documented **nowhere** in gh-stack's README; ADR-018
  found it empirically. Nazgul never auto-merges, so this only affects a human merging a layer by
  hand: use `gh stack merge <pr#> --squash --yes` or the web-UI merge button.
- **`gh stack sync` exits 0 when it aborts on a real divergence**, printing its warning to stderr —
  vendor-documented, and the opposite of the exit-code-driven conflict doctrine the spec originally
  assumed. The wrapper therefore classifies gh-stack's **stderr text**, not its exit code (and splits
  exit 3 between a genuine rebase conflict and the benign `local stack composition differs from
  remote` stale-tracking case). The cost is stated plainly in ADR-018's Consequences: this matching
  is coupled to gh-stack v0.1.0's exact message strings, and a future reword would break the
  disambiguation with no signal beyond the stubbed-`gh` fixtures.
- **Remote-ahead import is narrower than ADR-018's literal wording.** A clean remote-ahead `sync`
  leaves the new layer un-imported despite the README's claim; `stack_reconcile` parses the PR number
  out of gh-stack's own warning and runs the explicit `gh stack checkout <N>` itself. ADR-018 asked
  for a full diff of the registry against `gh stack view`; the shipped detection is scoped to sync's
  warning text and imports one PR per tick, because `gh stack view`'s output contract was never
  empirically verified and implementing against an unverified CLI surface was judged worse than a
  documented, narrower mechanism. Reviewed and accepted as such (GROUP-3 Attempt 3).
- **Explicitly out of scope**, unchanged from the spec: task-level stacked PRs (the dormant
  `afk.task_pr` path), auto-merging any PR, merge-queue integration, and Linear/Slack parity for
  rework filing.

## [2.28.1] - 2026-08-02

### Fixed
- **Three stale test-description labels in `tests/test-migrate-config.sh`** left by the 2.28.0
  PR-review sweep: chain-span labels still naming an old terminal version ("v1→v29 chain",
  "v17→v27 walk", "v24→v32") on assertions that check terminal `schema_version` 34 — now
  version-agnostic ("→terminal"), so future schema bumps only change the asserted value
  (PR #78 post-merge CodeRabbit follow-up). Test-only; no behavior change.

## [2.28.0] - 2026-08-02

FEAT-026, ADR-017 — one-shot subagents for one-shot work (governing thesis for this release). Nazgul was
dispatching work that needs exactly one exchange (discovery, a review verdict, a task's implementation) onto
a primitive whose entire design premise is that it outlives one exchange — an Agent-Teams teammate, reached
either by an explicit team spawn or merely by NAMING an `Agent`-tool dispatch — and then remediating the
resulting idling with a per-iteration dismissal directive. This release fixes the choice, not the symptom:
`/nazgul:init`'s discovery dispatch converts to an unnamed one-shot `Agent` dispatch, and the teardown
subsystem the conversion makes dead is deleted outright, net negative on lines. MINOR, not PATCH, on the same
two grounds this repo has used before: user-visible behavior changes (the init dispatch primitive, the
stop-hook's directive surface, `team-orchestrator.md`'s documented capabilities) and a config schema key is
removed with a migration (`guards.team_teardown`, precedent: FEAT-016 `2.19.0`, FEAT-024 `2.26.0`). MAJOR is
wrong — nothing an operator invokes is removed or renamed; the deletions are internal remediation machinery
with no live caller. **`schema_version` moves 32 → 33 → 34**: v33 (`migrate_32_to_33`) removes
`guards.team_teardown`, preserving any customized non-default value under `._deprecated_removed`; v34
(`migrate_33_to_34`, a user-approved scope addition mid-objective) adds `guards.in_flight_hold` (default
`true`) and `guards.in_flight_stale_minutes` (default `30`) for the new in-flight hold below. Two incremental
migrations in one release do not change the verdict — the second reinforces the schema-bump ground rather
than altering it.

### Removed
- **The teardown subsystem**, made dead by the conversion below: the stop-hook `TEAM TEARDOWN` gate and
  `tt_detect_undismissed()` (`scripts/stop-hook.sh`, `scripts/lib/team-teardown.sh`), and
  `teammate-idle-guard.sh`'s `"then idle"` instruction. `team-teardown.sh` retains only the dead-session
  sweep, demoted below to a crash-only backstop.
- **`team-orchestrator.md`'s two named-teammate spawn sections** ("Spawning a Review Team" and its
  counterpart) and the naming convention that biased dispatches toward them. The `"team-orchestrator"` entry
  itself stays in `agents.pipeline` — two live consumers (`parallel-dispatch-guard.sh`'s allowlist,
  `skills/enhance/SKILL.md`'s `tools:`-block probe) still match on its name.

### Changed
- **`/nazgul:init` Step 3** dispatches discovery via the `Agent` tool with `subagent_type: "nazgul:discovery"`
  and **no `name`/`-n` parameter** — one-shot work stays on the one-shot primitive (ADR-017).
- **The dead-session sweep's current-session exclusion now actually fires.** It previously compared against
  a session id that was almost never populated; the sweep now reads the real id out of the SessionStart
  hook's own JSON payload (`.session_id` → `CLAUDE_SESSION_ID` → persisted `nazgul/.session_id` → synthetic
  epoch-pid fallback, in that order), refuses to sweep when the id is still unidentifiable (logged as
  `unresolved_session_id` rather than silently sweeping), and excludes by both the team config's
  `leadSessionId` and the `session-<first-8-chars>` name form. This closes the recurring "team file not
  found" error — `nazgul/logs/team-sweep.jsonl` had recorded five self-sweeps of the live session's own team
  across four days before this fix.

### Added
- **Stop-hook in-flight awareness (ADR-015 Part 2).** A `PreToolUse(Agent)` marker
  (`scripts/in-flight-marker.sh`) records a dispatch as running; `SubagentStop` clears it on completion
  (`scripts/subagent-stop.sh`); while a fresh marker exists, the stop-hook takes an allowed, uncounted hold
  instead of burning an iteration, emitting a `stop_gate` event (`in_flight_hold` while fresh,
  `in_flight_stale` past `guards.in_flight_stale_minutes`) either way so the hold is never silent. This stops
  the no-op iteration burn the loop suffered while dispatched work was still running underneath it.
- **`guards.in_flight_hold`** (default `true`) and **`guards.in_flight_stale_minutes`** (default `30`, schema
  v34) — the kill-switch and staleness bound for the hold above.

## [2.27.0] - 2026-08-01

`/nazgul:doctor`: a new operator cannot know the seven environment traps that silently produce
confusing failures — cache-vs-repo plugin version, `jq`/`gh` presence and auth, git-hooks drift, the
bash-vs-zsh hazard, the `NAZGUL_DIR` footgun, config-schema staleness, and the never-EOF-stdin hazard
(governing thesis for this release). Doctor **never writes state** — its only fix path is text on
stdout; that read-only boundary is the release's headline property, not a footnote. MINOR, not PATCH,
because a new user-facing capability ships (the `/nazgul:doctor` skill and `scripts/doctor.sh`),
matching this repo's own precedent for exactly this shape: FEAT-008 shipped `/nazgul:heartbeat` as
MINOR `2.10.1` → `2.11.0`. PATCH is wrong — this repo reserves PATCH for narrow, no-new-capability
precision fixes (FEAT-019 `2.22.1`, FEAT-021 `2.23.1`). MAJOR is wrong — nothing is removed and no
interface changes shape. **`schema_version` stays at 32** — no new config key ships; doctor is
invoked on demand only, has no hook binding, and gates nothing, so there is no autonomous behavior to
kill-switch.

### Added
- **`scripts/doctor.sh` + `skills/doctor/SKILL.md`**, a read-only preflight diagnostic covering
  eight checks — a config-present engine check (an uninitialized project is reported, never
  silently skipped) plus the seven environment checks below — each reported `pass`/`warn`/`fail`
  with a one-line remediation:
  (a) cache-vs-repo plugin version — an explicitly **documented workaround**, not a platform API,
  since Claude Code exposes no mechanism to compare the active plugin cache against the repo
  checkout; (b) `jq`/`gh` presence on `PATH`, with `gh auth status` checked only when connectors or
  the board integration are enabled; (c) managed git-hooks drift — reports `core.hooksPath` and guard
  presence mismatches, never fixes them; (d) the bash-vs-zsh invoking-shell hazard, warning with the
  `bash -c` remediation; (e) the `NAZGUL_DIR` footgun, naming `CLAUDE_PROJECT_DIR` as the one honored
  isolation seam; (f) config-schema staleness against the highest available `migrate_N_to_N+1`
  target; (g) an unconditional never-EOF-stdin advisory note.
- **Advisory, non-blocking `/nazgul:doctor` mentions** in `/nazgul:init` and `/nazgul:start` — one
  unconditional suggestion line each, with no exit-code branching and no state read or write to
  decide it.
- **`scripts/lib/nazgul-root.sh` header documentation fix**, closing the folded-in p3
  (`resolve-nazgul-dir-ignores-nazgul-dir-env.md`): the header now states plainly that
  `CLAUDE_PROJECT_DIR` is the only environment variable that redirects resolution and that
  `NAZGUL_DIR` is never read. This is **documentation only** — `resolve_project_root()` and
  `resolve_nazgul_dir()` are byte-identical; no behavior changes.

## [2.26.0] - 2026-07-31

Subagent non-delivery: a subagent whose model finished reasoning must not stall silently at its turn
ceiling and be read by the orchestrator as work still in progress (governing thesis for this release).
MINOR, not PATCH, on three independent grounds, any one sufficient by this repo's own precedent: (1)
agent runtime behaviour changes in both directions — every generated reviewer's `maxTurns` goes
12 → 30; (2) a new telemetry event type ships, `subagent_empty_return`; (3) a new bounded gate and a
new config key ship, `guards.subagent_resume`. MAJOR is wrong — nothing is removed and no interface
changes shape. **`schema_version` moves 31 → 32**: `guards.subagent_resume` (default `true`) is new —
a behaviour-named (not mechanism-named) kill-switch for the auto-resume backstop, consistent with
every other autonomous mechanism this repo ships with one.

### Added
- **Reviewer `maxTurns` ceiling raised 12 → 30**, across a repo-wide audit of every generated reviewer
  template and specialist agent that dispatches under the review board, not just the four core
  reviewers. More headroom before the ceiling is reached is the first of two mitigations this release
  ships; the second is the resume backstop below.
- **Universal `subagent_empty_return` telemetry event.** Emitted by `scripts/subagent-stop.sh` for
  ANY dispatched subagent — reviewer, implementer, specialist — whose SubagentStop input carries no
  usable final deliverable. Two `reason`s: `empty_final_text` (the transcript's last assistant record
  carries no text block at all — a bare tool call or nothing) and `no_verdict_line` (text is present
  but the required `verdict:`/`reviewer:` contract line is missing). Three `action`s: `resumed` (the
  bounded backstop below fired), `exhausted` (the resume cap was already spent), `detected_only` (the
  backstop is disabled by config; detection still fires).
- **Branch A: bounded in-hook auto-resume, `guards.subagent_resume`.** `scripts/subagent-stop.sh`
  itself returns `exit 2` with a `{"decision":"block","reason":...}` continuation directive when it
  detects an empty return, capped at 2 resume attempts per dispatch, kill-switched by
  `guards.subagent_resume` (default `true`); on any unexpected error the mechanism fails open to
  `detected_only` with a stderr diagnostic naming the degradation, rather than silently doing
  nothing. Branch A was selected empirically, not by design preference: a `SubagentStop` exit-2 probe
  proved live, under **direct Agent-tool dispatch** (the mode the review board actually uses — Agent
  Teams teammate mode was not tested), that an `exit 2` decision-block IS honored and continues the
  SAME subagent with the reason injected as a new turn. The alternative — a sixth `stop-hook.sh` gate
  injecting a resume directive at the orchestrator level (Branch B) — was therefore never built; it
  closes **NOT-APPLICABLE**, not abandoned or deferred.
- `RULES.md` §19, "Subagent Non-Delivery & Bounded Resume," and the matching `CLAUDE.md` Key Concepts
  paragraph, documenting universal detection, the Branch A resume mechanism, the kill-switch, and the
  resume-recovery pattern (a resumed agent needs ~zero further tool calls — it had already finished
  reasoning and simply failed to emit the terminal deliverable).

### Measured
- **Observed first-round reviewer non-delivery this objective: 2/12 ≈ 17%**, against this repo's own
  historical baseline of **~50% (24/47 across FEAT-022/FEAT-023, `maxTurns: 12`)** — a material drop,
  stated plainly. This tally is notification-derived (the orchestrator's own dispatch/resume record),
  **not** sourced from `events.jsonl`, because this session's live `SubagentStop` hook was the
  plugin's pre-instrumentation `2.23.1` version-cache copy and recorded zero `subagent_empty_return`
  events all day — a vacuous zero (the hook that could emit the event never ran live), not a
  measurement of a low rate.
- **Replay of the real transcripts through the shipped, unmodified instrument matched ground truth
  7/7**: both known real stalls reproduce `subagent_empty_return`/`empty_final_text` when replayed at
  the pre-resume boundary, and all five known clean/resumed-and-delivered cases reproduce no event —
  the strongest evidence available this session that the detector is correctly calibrated against
  real transcript shapes, not synthetic fixtures.
- **Causal attribution to the `maxTurns` bump specifically is explicitly UNPROVEN.** The one datum
  that would settle it — `turns_used` sitting at the ceiling, sourced from a live `events.jsonl`
  under the instrumented hook — was never available this session: the live hook predates this
  instrumentation (the vacuous zero above), and the replay-derived `turns_used` proxy is
  independently miscalibrated (the real transcript format writes one content-block per line, not one
  turn per line, so `turns_used: 74` was observed against `max_turns: 30` on one stalled dispatch —
  only possible because the metric counts content-block records, not turns). A live instrumented
  capture under this release or later, against a real multi-board run, is the only way to answer the
  ceiling-vs-cause question.

### Known / deferred
Five defects were found and filed to the work inbox this objective, none fixed here — findings filed,
not silently patched:
- `discovery.md`'s stale embedded reviewer-template fragment (carries `maxTurns: 30` plus
  pre-FEAT-006 tools/hooks fields) and `.claude/agents/generated/documentation.md`'s
  generated-vs-template drift (30 vs the template's 40) — both confirmed unchanged by the
  repo-wide audit and filed, not fixed.
- The DONE-gate's live blocking path never calls `validate_review_provenance` — only
  `stop-hook.sh`'s hook-driven reconciliation does, leaving a window where a direct board bypass is
  not caught until the next iteration.
- No test pins the `review_token:` contract field name.
- `turns_used` overcounts content-block records as turns (27/74 observed vs. `max_turns: 30` on real
  transcripts), the miscalibration cited above under Measured.
- `resolve_nazgul_dir()` ignores a `NAZGUL_DIR` environment override — only `CLAUDE_PROJECT_DIR` is
  read — discovered when a replay attempt silently ran against live project state instead of the
  intended isolated temp directory.

## [2.25.0] - 2026-07-30

Loop reliability: a mechanism that FAILS must not look like a mechanism that had nothing to do
(governing thesis for this release — the sibling of 2.24.0's "looked and found nothing" vs. "never
looked"). MINOR, not PATCH, because two gates change behaviour in BOTH directions and one guard
widens its allow: the AFK timeout gate now computes elapsed time correctly in every timezone — east
of UTC a run that previously stopped early now runs to its configured limit, and west of UTC a run
that previously NEVER timed out now will; the IMPLEMENTED evidence gate tightens — transitions that
pass today on a manifest's own Base SHA now BLOCK; and `task-state-guard.sh` widens — writes outside
the project root that BLOCK today (with `guards.requireActiveTask` on) are now allowed. Additive on
top of those: a new `stop_gate` telemetry event type, and the `PreToolUse` Bash-matcher hook
timeouts raised 10 s → 30 s. MAJOR is wrong — nothing is removed and no interface changes shape.
**`schema_version` stays at 31**: no config key was added, removed, or changed in meaning.

### Fixed
- **The AFK timeout gate parsed Z-suffixed UTC timestamps as LOCAL time on macOS (Defect 4).**
  BSD `date -j -f` treats a trailing literal `Z` as an ordinary character, so `stop-hook.sh`'s gate
  compared a locally-parsed start time against an absolute `date +%s` epoch: east of UTC the
  computed elapsed was inflated by the UTC offset and the gate fired EARLY (observed live: true
  elapsed 81 minutes computed as 141 against a 90-minute limit — a `--yolo` run with 9 planned
  tasks never dispatched one); west of UTC it under-enforced by hours. UTC CI could never catch it.
  Both the probe and the parse now run `date -j -u`, correct in every timezone — and the probe now
  establishes that the timestamp PARSED correctly, not merely that the command exited 0. The second
  half of the fix is observability: a gate-triggered stop no longer ends an autonomous run with a
  bare `exit 0` indistinguishable from "nothing to do" — it emits a `stop_gate` telemetry event
  carrying `reason`, `computed` and `limit`.
- **`task-state-guard.sh` gated writes OUTSIDE this project (Defect 3).** `PROJECT_ROOT` was
  resolved but never used as a bound, so with `guards.requireActiveTask` on and no task
  IN_PROGRESS, a Write to an absolute path in another repository — or to Claude Code's own session
  scratchpad — was blocked with "No task is IN_PROGRESS". The guard is now bounded by
  `PROJECT_ROOT`: both sides are canonicalized before comparison, paths outside the project root
  are never gated, and in-project paths reached non-canonically (symlink, `..`, a foreign cwd) are
  STILL gated. This is the objective's only allow-widening change, and it composes with — does not
  replace — 2.24.0's config-present/tasks-absent fail-closed behaviour.
- **`pre-tool-guard.sh` fork elimination (Defect 1a).** The reported failure mode: on a loaded
  machine (203 Bash calls, 59 concurrent subagents, `tsc`/`vitest` on the same cores) trivial
  commands hit the 10 s hook timeout, with killed `durationMs` exceeding `timeoutMs` by 1.4-2.4x —
  CPU starvation from fork volume, not slow logic. The guard's 19 per-call `echo | grep` pipelines
  (15 `check_pattern` sites, `check_sql_destructive`'s `$dbcli` gate, `check_force_push`'s three
  per-segment matches; the SQL function's three further matches only run when that gate passes, so
  a command touching a DB CLI costs 22) are now bash-native `[[ =~ ]]` via one `_ci_match()` helper: external
  invocations 20 → 3 per call, measured mean wall clock ~100-108 ms → ~30-34 ms (~68-70%
  reduction). FEAT-019's precision suite is not just preserved but PROVEN preserved: a differential
  harness replays every command the 160-assertion suite exercises against the pre-fix guard and
  asserts exit code AND stderr byte-identical — zero diffs — plus six new pinned regression cases
  for the semantic corners (`\s` vs `[[:space:]]`, scoped `nocasematch`, per-line vs whole-string
  anchoring).
- **`local-mode-tracking-guard.sh` heredoc FALSE BLOCK (Defect 1e).** A legitimate
  `git commit -m "$(cat <<'EOF' … EOF)"` whose heredoc body contained a literal `"` broke the
  scanner's quote tracking, exposing body text to the runtime-state pathspec check and falsely
  blocking the commit. After the general-tokenizer approach was retired (see Known / deferred), the
  shipped fix is a narrow rule recognizing the `cat`/`tee` heredoc command shape, with an opaque
  paren-depth fallback for every other `$(...)` — scanner state reduced from 11 variables to 7,
  87/87 guard suite green. Fixed, but NOT hardened: two accepted false-ALLOW residuals remain,
  named below. The guard also no longer pays ~27 ms resolving `PROJECT_ROOT` before its cheap
  pre-filters run — that resolution is now lazy, after the pre-filters that `exit 0` for the
  overwhelming majority of Bash calls.
- **`PreToolUse` Bash-matcher hook timeouts 10 s → 30 s (Defect 1d) — a backstop, not a fix.**
  Exactly the two `Bash`-matcher entries in `hooks/hooks.json`; every other timeout is
  byte-unchanged. The fixes are the fork eliminations above; the bump only stops a loaded machine
  from turning a guard into a stall. Whether a timed-out `PreToolUse` hook fails open or closed
  remains unverified — see Known / deferred.
- **The IMPLEMENTED evidence gate was satisfied before any work was done (Defect 5).**
  `ttg_verify_commit_evidence` extracted every hex token from the ENTIRE manifest and accepted if
  any one resolved — and every manifest carries its planner-written `Base SHA` in `## Metadata`
  from creation, which is by definition a real, reachable commit. Reproduced deterministically: a
  manifest with only a Base SHA and NO `## Commits` section passed (exit 0); deleting that one line
  made it correctly fail. The gate now scopes extraction to the `## Commits` section (agreeing with
  `pre-merge-commit`'s heading-scoped matching — one definition of evidence, so a task can no
  longer pass IMPLEMENTED and then block at merge as unverifiable) and requires the recorded commit
  to be a STRICT descendant of the manifest's own Base SHA (`git merge-base --is-ancestor`, with
  equality explicitly rejected — a commit is its own ancestor), proving forward progress rather
  than mere existence. A manifest with no Base SHA degrades to existence-only LOUDLY, with a stderr
  diagnostic naming the degradation. The authoring contract is now stated at both ends
  (`templates/task-manifest.md`, `agents/implementer.md`), and `RULES.md` Rules 2/8 plus
  `CLAUDE.md` describe the shipped gate rather than the planned one, with ADR-011/012/013 amended
  to match shipped code.
- **`webhook-forward.sh` gains `--connect-timeout 2` (Defect 2 — downgraded, see below).** One flag
  beside the PRE-EXISTING `--max-time 5`: it bounds the DNS/connect phase specifically, distinct
  from the overall wall clock. This is NOT a fix for an unbounded call — the unbounded-curl claim
  was verified false before any work started.

### Known / deferred
- **Defect 2 was DOWNGRADED from p1 to p3 before any work started.** The report's claim that
  `webhook-forward.sh` runs an unbounded `curl` was verified FALSE on disk: `--max-time 5` has been
  present since commit `08c5da84` (2026-03-16), long before this objective. Only
  `--connect-timeout 2` is new here. The reported 16,585 ms and 24,102 ms Stop-hook durations are
  NOT explained by that call — a call bounded at 5 s cannot produce a 24 s duration — and the
  better-supported explanation is the same CPU starvation as Defect 1.
- **Fix 1b (merging the two `PreToolUse` Bash guards) is DEFERRED**, with the measurement: ~13 ms
  of a ~147 ms combined per-call cost (~9%), versus ~101 ms recovered by the two single-file fixes
  that did ship. ADR-011's cheaper "shared parse helper" fallback was found to save nothing — two
  independently-registered hook processes each receive their own stdin and cannot share one `jq`
  call.
- **Fix 1c (replacing `jq` for envelope parsing) DOES NOT SHIP** — measured at 4.8 ms, ~3% of the
  combined per-call cost, against a byte-equivalence verification burden and a real corruption
  risk.
- **`webhook-forward.sh` fire-and-forget DOES NOT SHIP** — detaching the POST would trade an
  observed bounded wait for an unobservable delivery, which is the exact failure shape this release
  exists to eliminate.
- **The disposition of a timed-out `PreToolUse` hook (fail-open vs fail-closed) is UNVERIFIED.**
  The 10 s → 30 s bump ships anyway because a timeout is bad under either reading, but this release
  does not claim the question was answered. Filed to the work inbox as an open item.
- **`START_EPOCH=0` still skips the AFK gate silently** when the session-start timestamp cannot be
  parsed on either `date` dialect. Same thesis family — a failed mechanism indistinguishable from
  an idle one — but out of ADR-014's scope; filed.
- **The corrected ADRs never reach a clone.** ADR-011/012/013 were amended to `ACCEPTED (amended)`
  because their original text contradicted shipped code — ADR-011's would have a reader implement
  the fail-open variant that silently disarms `pre-tool-guard.sh` — but the project-local docs
  directory those ADRs live in is gitignored in local install mode, so the corrections exist for
  this repository's own record and its doc-verifier gate only, not for downstream users. Whether
  ADRs belong somewhere git-tracked is a standing open question FEAT-022 also raised and left
  unresolved; recorded here, not resolved here.
- **The heredoc guard shipped with two accepted residual bypasses**, by architect resolution ruling
  after retry exhaustion (3/3) — ten false-ALLOW bypasses were found across seven attempts at the
  general tokenizer. Stated honestly: Defect 1e (the heredoc false BLOCK) is FIXED, bypasses #8/#9
  and the pre-existing baseline bypass H-16 are CLOSED, but deprecated `$[...]` bracket arithmetic
  and space-separated `$(( (cmd<<n) ))` remain false-ALLOWs — filed in prose, accepted as LOW
  severity behind `.gitignore` and the session-staging chokepoint. A git-level `pre-commit`
  staged-tree guard is chartered as the durable fix — the third proof in this repository that
  command-string parsing does not converge.

## [2.24.0] - 2026-07-28

Guard integrity: a guard whose lookup misses must never report success (governing thesis for this
release — "looked and found nothing" vs. "never looked"). MINOR, not PATCH, because three checks
that previously exited 0 now BLOCK for input shapes that are legitimate today: short-SHA and
backticked-short-SHA `## Commits` manifests, refs naming a non-`DONE` task, and (in
`task-state-guard.sh`) a Nazgul project whose `nazgul/tasks/` directory is missing. MAJOR is wrong —
nothing is removed, no interface or config key changes shape. **`schema_version` stays at 31**: no
config key was added, removed, or changed in meaning.

### Fixed
- **The live merge hole — `pre-merge-commit` admitted unreviewed content on a short SHA.** The guard
  compared git's always-full-length `GITHEAD_<sha>` key against a task manifest's `## Commits` text
  with an exact-substring `grep -q`. A manifest that recorded a `git rev-parse --short` SHA (or a
  backticked one) therefore never matched, `UNIT_ID` stayed empty, and the merge fell through to
  allow. Reproduced live before the fix: full SHA in `## Commits` -> exit 1 (blocks); short SHA ->
  exit 0 (merges); backticked short SHA -> exit 0; an empty `## Commits` section -> exit 0. This
  guard's own repository dogfooded the ambiguity it missed — `scripts/stop-hook.sh` records short
  SHAs via `git rev-parse --short` in its own commit-recording path, and FEAT-021's own archived task
  manifests mixed short, backticked-short, and full forms within a single objective. Now matched by
  token/prefix extraction (`grep -oE '[0-9a-f]{7,64}'` against `## Commits`, then a `case` prefix
  test against the candidate SHA), so short, full, and backticked forms all resolve.
  This is a deliberate fail-**CLOSED** design, not FEAT-021's fail-open ADR-008 resolver precedent
  (ADR-009): a false allow here admits unreviewed code straight into the feature branch's history,
  indistinguishable from reviewed code the moment the merge lands, while a false deny stalls exactly
  one unit with a diagnostic that names it — the asymmetry ADR-009 states as its general rule for
  which guards in this family should fail open vs. closed.
- **The "never looked" half — ref-name identity, bound per-key, plus block-on-unverifiable.**
  `GITHEAD_<sha>` values carry the ref name git is actually merging (e.g. `feat/FEAT-009/TASK-165`),
  set by git itself and not omittable by an implementer — a second identity signal the guard
  previously ignored, leaving a manifest with no `## Commits` section at all invisible to it. The
  ref-derived candidate is now resolved per `GITHEAD_<sha>` key (not "first `TASK-NNN` match across
  the whole environment") and anchored to the canonical `^feat/[^/]+/(TASK-[0-9]+)$` branch shape.
  ADR-010's naive bare-`TASK-NNN` substring parse was rejected as spoof-unsafe: taking the first
  `TASK-NNN` match anywhere in the environment, independent of which `GITHEAD_<sha>` key produced it,
  could resolve identity to a decoy `GITHEAD_<sha>=feat/.../TASK-999` (DONE) instead of the genuine,
  unapproved head actually being merged — laundering exactly the content the guard exists to catch.
  The canonical-shape anchor is also what keeps `tests/test-git-hooks-premerge.sh`'s existing
  FALSE-BLOCK regression case green (`docs/TASK-001`, a non-`feat/`-prefixed branch, must still merge
  cleanly). A ref-matched unit whose `## Commits` section cannot verify the key's own SHA now BLOCKS
  as "matched but unverifiable" instead of silently falling through to allow.
- **`task-state-guard.sh` no longer disables both gates when `nazgul/tasks/` is missing under a real
  Nazgul project.** A readable `nazgul/config.json` with no (or unreadable) `nazgul/tasks/` is a
  resolved-but-incomplete project, not a non-Nazgul directory, and now BLOCKS (exit 2) with a
  diagnostic distinct from the ordinary "no active task" message, instead of collapsing into the
  same silent no-op as a genuinely non-Nazgul directory (which still safely no-ops on a
  missing/unreadable `config.json`, unchanged). Same present-but-corrupt-fails-closed /
  genuinely-absent-no-ops split as §12's MF-053 precedent, applied to this guard.
- **`slugify_objective` newline corruption, an unchecked `git checkout -b`, and the silent zsh
  half-load of `worktree-utils.sh`.** A multi-paragraph objective string produced an invalid branch
  name via `slugify_objective`; `create_feature_branch()`'s `git checkout -b` failure was previously
  swallowed, leaving config recording a branch that did not exist; and `worktree-utils.sh` sourced
  under zsh (the default interactive shell on macOS) hit `${BASH_SOURCE[0]}`, a non-fatal
  unset-parameter diagnostic under zsh, and half-loaded silently — so the managed `core.hooksPath`
  install (`create_feature_branch -> install_git_hooks`) never ran. All three were hit live during
  this objective's own setup, and they compound: the merge guard could be both bypassable (the fix
  above) and not installed at all. `worktree-utils.sh` now refuses to source outside bash, loudly,
  and `create_feature_branch()` verifies the branch exists after `checkout -b` instead of trusting
  the exit code alone.

### Added
- `docs/guard-fail-open-inventory.md` — a classified inventory of the "lookup miss -> pass" pattern:
  125 sites, exhaustively classified across the 16-file **enforcement surface** (every script whose
  empty-result path is itself an authorization decision). Its own title states the boundary explicitly
  ("Partial: 16 of ~46 Files") and it must not be cited as a repo-wide inventory: the document itself
  puts the remainder, depending on which textual forms are counted, at on the order of 190-370
  occurrences across 25-46 files — none of them an authorization decision, so a fail-open there at
  worst costs logging, a notification, or an advisory backlog entry, filed by reference rather than
  silently dropped.

### Known / deferred
- **The compound case — an off-convention branch whose manifest also has no `## Commits` entry — is
  not closed by this release.** Fix 1b's ref-derived signal only gates the canonical
  `feat/<ref>/TASK-NNN` branch shape (`pre-merge-commit:19-26,138-142`); an off-convention branch
  (e.g. `docs/TASK-001`) evades it by design and falls back to content-matching only — required by
  `tests/test-git-hooks-premerge.sh`'s FALSE-BLOCK regression case, not a gap in the fix. But if that
  same unit's manifest also never gained a `## Commits` section naming the merged SHA, content-matching
  has nothing to find either: both signals report no candidate, `UNIT_ID` stays empty, and the merge
  falls through to allow — exit 0, no diagnostic, identical to pre-1b behaviour
  (`nazgul/plan.md` Decision C1). Needs both an authoring gap AND an off-convention branch name at
  once; not closed by Fix 1a/1b/1c.
- **`pre-merge-commit`'s config/environment degrade-to-allow path is untouched by this release.** A
  missing `jq`, a missing `config.json`, `guards.git_hooks: false`, `execution.parallel` not `true`, or
  `execution.enforce.premerge_guard: false` all degrade to allow before any manifest is even read
  (`pre-merge-commit:64-80`). `docs/guard-fail-open-inventory.md` ranks the corrupt-but-present-config
  case at line 77 — `PARALLEL` silently defaults to `"false"` with no `jq -e .` validity check, unlike
  its PreToolUse sibling guards — as the single highest-severity finding in its inventory: the one
  guard ADR-009 itself names as having a catastrophic, unbounded false-allow cost. Not fixed here;
  filed for a future objective.
- No `schema_version` bump and no config migration in this release — no config key was added, removed,
  or changed in meaning.

### Changed
- The `## Commits` manifest format (full 40-hex SHA, bare, one per line) is now specified at both
  authoring ends — `agents/implementer.md` step 11 and `templates/task-manifest.md` — with an
  explicit note that this is the authoring convention, not the enforcement boundary:
  `pre-merge-commit`'s own matching accepts short and backticked forms too.

## [2.23.1] - 2026-07-28

### Fixed
- **Cross-worktree state resolution — a session inside a git worktree no longer reads the MAIN
  checkout's `nazgul/`.** Every guard/hook that hand-rolled `NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}
  /nazgul"` resolved from the process cwd, so a worktree session structurally valid at `TASK-NNN`
  (task ids restart per objective) could read a DIFFERENT objective's task state and return a
  confident WRONG verdict rather than a miss — the live 2026-07-27 incident. New shared resolver,
  `scripts/lib/nazgul-root.sh` (`resolve_project_root()` / `resolve_nazgul_dir()`), adopted at the
  **22 verified migration call sites** across `scripts/` and `scripts/lib/` (re-derived this
  objective — the TRD's "20" was an arithmetic error). Precedence: an explicit, non-empty
  `CLAUDE_PROJECT_DIR` wins unconditionally, no marker check, no fallthrough; otherwise the first of
  git-toplevel then `$(pwd)` whose `nazgul/config.json` exists and is readable wins, falling back to
  git-toplevel (or `$(pwd)` outside a git repo) if neither validates. `scripts/git-hooks/` is exempt —
  already correct via `git rev-parse --show-toplevel` run inside the hook itself. Landed as three
  passes on the resolver in this objective (ADR-008 + two amendments + a correction): the initial
  precedence tried git-toplevel first and could silently override an explicit `CLAUDE_PROJECT_DIR`;
  a first fix reordered to try the explicit var first but still marker-validated it, so a
  set-but-invalid value fell through to an unrelated repo; the final fix returns an explicit,
  non-empty `CLAUDE_PROJECT_DIR` unconditionally.
- **One new fail-OPEN, narrowly scoped.** `scripts/parallel-dispatch-guard.sh`'s
  `_resolution_integrity_ok()` allows and warns (`dispatch_guard_resolution_unconfirmed`) when
  `TASKS_DIR` fails to canonicalize as a child of the resolved `NAZGUL_DIR` — a resolution-INTEGRITY
  check only (e.g. `nazgul/tasks` symlinked outside the resolved tree), not an objective-identity
  check. MF-053's fail-CLOSED-on-corrupt-`config.json` rule is unchanged and untouched by this branch.
- **ADR-008 Option 2 — `CLAUDE_PROJECT_DIR` exported at worktree entry**, as defense-in-depth on top
  of the resolver fix (`scripts/worktree-utils.sh`), plus its six `project_root` parameter defaults
  hardened to `resolve_project_root()`.
- **`RULES.md` §17's `teammate-idle-guard.sh` known limitation is NARROWED, not closed.** The guard now
  resolves `nazgul/` through the shared resolver instead of a hand-rolled check, so a teammate whose
  session resolves to a git worktree carrying the shared `nazgul/` runtime is correctly tracked. A bare
  task-worktree teammate session (`CLAUDE_PROJECT_DIR` unset, no `nazgul/config.json` of its own — it's
  gitignored and per-worktree) still has no validating candidate. ADR-008 Option 2's export does not
  close this gap at this layer: `create_task_worktree()` is not in the production call graph, and its
  `echo`-based return means any caller capturing it via `$(...)` gets the export discarded by the
  subshell.

### Known / deferred
- **PRD AC 3 is only partially satisfied.** Detecting a stale or cross-objective `NAZGUL_UNIT` dispatch
  token requires an objective anchor on the token itself — scope item 4 (collision-resistant `feat_id`
  generation + `NAZGUL_UNIT: FEAT-NNN/TASK-NNN` namespacing), cut from this objective on cost/benefit
  (redundant against the resolution fix; changing `feat_id`'s shape is a whole objective, not a task —
  see `nazgul/docs/PRD.md`). Filed as a standalone follow-up:
  `nazgul/inbox/feat-id-collision-resistance.md` (priority 3), which also covers `plan.md`'s
  non-blocking status-table drift.
- No `schema_version` bump and no config migration in this release — `feat_id` generation, config
  shape, and `templates/config.json` are all untouched.

## [2.23.0] - 2026-07-27

### Fixed
- **Session lock lifecycle repaired — the sweep's "provably dead" signal is honest again (ADR-007).**
  `scripts/stop-hook.sh` unregistered the session lock unconditionally at the top of every Stop, so
  the lock vanished after a session's *first* Stop event rather than at the end of its life. This
  collapsed `tt_sweep_orphaned_teams`'s two-signal "provably dead" AND to transcript-staleness only,
  and silently broke the pre-existing `is_concurrent_session_warning()` guard beyond iteration 1. The
  lock now re-registers each iteration and unregisters only on a genuinely-ending path, via one
  centralized `EXIT` trap (exit 0 only). This makes `cleanup_stale_sessions()`'s 2h threshold
  load-bearing for the first time. **This is a behavioral change to the loop engine, which is why this
  release is MINOR rather than PATCH.**
- **`guards.team_sweep_min_age_hours` floored to `>=1`** at all three read sites
  (`scripts/session-context.sh`, `skills/clean/SKILL.md`'s `--teams` block, and
  `tt_sweep_orphaned_teams`'s own numeric guard in `scripts/lib/team-teardown.sh`); a configured `0`
  previously disabled the transcript-freshness AND-term entirely.
- **Sweep cwd attribution is now symlink-safe.** Both operands are normalized to physical paths via
  `pwd -P` before comparison in `scripts/lib/team-teardown.sh`, so a macOS `/tmp` vs `/private/tmp`
  divergence no longer makes `/nazgul:clean --teams` silently under-report dead teams.
- **`HEALED` marker vs. a genuine teammate named `HEALED` can no longer collide.** The self-heal
  marker line in `scripts/lib/team-teardown.sh` moved from a value check (`grep '^HEALED\t'`) to a
  field-count check (`awk -F'\t' 'NF==2'` for the marker vs. `NF==4` for real teammate rows), which
  disambiguates regardless of `$name`.
- **`migrate_30_to_31`'s comment now cites `migrate_27_to_28`** (`scripts/migrate-config.sh`) — the
  true nearest precedent for the `.guards`-type-guard idiom it reuses, not `migrate_29_to_30`, which
  never touches `.guards`.

### Added
- **`team_teardown` telemetry parity with the FEAT-018 design spec §4.4.** `scripts/stop-hook.sh` now
  also emits `leaked_detected` (any non-empty detection, independent of whether a directive is
  issued) and `verified_clean` (confirmed-dismissal self-heal only) — based on the classifications
  `scripts/lib/team-teardown.sh` returns — joining the already-shipped `directive_injected` /
  `escalated`.
- **Regression coverage**: bare-dot `team` rejection and unreadable-`stat` (`mt=""` keep) tests in
  `tests/test-team-teardown.sh`, plus a pinning test that a `HEALED` self-heal never enters the
  blocks-increment/escalation path.

### Changed
- **Docs aligned with the shipped mechanics**: `RULES.md` §18.4 describes the per-iteration
  registration and `EXIT`-trap unregistration; the redundant teardown/dismissal paragraphs in
  `templates/skill-partials/report-contract.md` were merged into one.

Accepted residual, no action taken: the concurrent-session delivered-manifest self-heal corner
degrades only to the pre-FEAT-018 status quo and was explicitly accepted rather than fixed here.

## [2.22.1] - 2026-07-25

### Fixed
- **Guard precision: SQL destructive-statement rules anchored, closing a false-positive class (LR-005).** The
  three destructive-SQL rules in `scripts/pre-tool-guard.sh` (table drop, database drop, table truncation)
  were bare case-insensitive substring greps over the whole command string, so any command whose quoted
  TEXT merely named a keyword tripped them — live evidence included a `python3` heredoc of prose, a `jq`
  write of unrelated objective text, and `grep` inspection commands during doc generation.
  `check_sql_destructive()` replaces them with a whole-command AND — an anchored destructive-statement-shape
  match plus a DB-CLI invocation token (`psql`/`mysql`/`mysqldump`/`sqlite3`/`sqlcmd`/`redis-cli`), each
  checked anywhere in the full command rather than segment-scoped like `check_force_push()`, since a first
  attempt mirroring `check_force_push()`'s segment-scoped design proved bypassable via quoted multi-statement
  args and heredocs.
  Two demonstrated bypass shapes — a quoted multi-statement `-c`/`-e` argument and a multi-line heredoc
  invocation — are now regression-tested (`tests/test-pre-tool-guard.sh` MF-029 block, cases S-1/S-2/S-3).
  This closes LR-005 for the SQL rules only; the other unanchored `check_pattern()` rules (fork bomb,
  recursive chmod, filesystem format, direct disk write, piped execution) remain out of scope for a
  future objective.

## [2.22.0] - 2026-07-24

### Added
- **FEAT-018 Teammate Teardown & Team Sweep** — Agent-Teams teammates are now
  dismissed instead of left idling forever:
  - `scripts/lib/team-teardown.sh`: undismissed-teammate detection (delivered
    report + still a team member) with dispatch-manifest self-heal, and a
    dead-session orphaned-team sweep for `~/.claude/teams/` + `~/.claude/tasks/`.
  - Stop-hook TEAM TEARDOWN gate: mandatory dismissal directive before new
    dispatch, 3-strike fail-open escalation via `raise_finding`
    (`guards.team_teardown`, default true; config schema v31).
  - SessionStart sweep (`guards.team_sweep`, default true;
    `guards.team_sweep_min_age_hours`, default 24) + `/nazgul:clean --teams`
    (`--all` for interactive foreign-team cleanup).
  - Report Contract: manifests record their `team`; dismissal
    (shutdown_request after report consumption) is now part of the contract.
  - Docs updated for the post-v2.1.178 platform (TeamCreate/TeamDelete
    removed; per-teammate shutdown_request is the only teardown primitive).

## [2.21.0] - 2026-07-23

FEAT-017, the fourth and final repair wave from the FEAT-013 360 reliability audit — reliability wave 4:
docs, config & residual findings. Closes the 62-item audit register (30 shipped in Waves 1-3, 26 fixed
here, 1 confirmed already-fixed, 5 retired as wontfix with recorded rationale). Thirty-three commits
(`ca80fdb`..`fe73660`).

### Added
- **Config schema v29 → v30** (`migrate_29_to_30`): additive kill-switched key
  `review_gate.receipt_hash_enforcement` (default `false`, opt-in), preserving any explicit pre-existing
  value.
- **Receipt-hash content gate** (LR-001 mechanical enforcement, opt-in, default off):
  `scripts/subagent-stop.sh`'s `_record_reviewer_receipt()` captures a sha256 receipt of each dispatched
  reviewer's actual raw returned text into `nazgul/logs/review-receipts.jsonl`, independent of
  review-gate's own tool-use surface (reads `.agent_transcript_path`, isolating a reviewer's own
  transcript from its concurrent siblings). `scripts/lib/review-evidence.sh`'s `validate_review_evidence()`
  recomputes the hash over up to four sanctioned-edit reconstructions of the persisted verdict file and
  reports a new `RECEIPT_MISMATCH <reviewer>` problem code when none match — mechanically detecting the
  FEAT-016/TASK-005 fabricated-board incident shape at the DONE-gate. Honestly scoped as tamper-evidence,
  not authentication.
- **Parallel-batch review-then-merge reorder** (closes the FEAT-016 HIGH finding): `stop-hook.sh`'s
  parallel-batch `DISPATCH_INSTR` now records each task's commit SHA and sets `Status: IMPLEMENTED`
  immediately after the implementer's own commit, dispatches review-gate against that task's own
  unmerged branch diff, and merges only a task that reaches `Status: DONE` — restoring the
  `pre-merge-commit` (H2) guard's precondition, which the prior merge-before-review order left
  structurally unable to ever match a candidate.
- **`models.review_orchestrator` tier restatement** (LR-002): `agents/review-gate.md` gets a static
  `model: sonnet` frontmatter pin (matching `comment-verifier.md`/`doc-verifier.md`/`learner.md`/
  `self-audit.md`); `stop-hook.sh`'s DELEGATE text and `agents/team-orchestrator.md`'s review-team spawn
  instructions both restate the tier requirement as defense-in-depth for the Agent-Teams dispatch path.

### Fixed
26 findings from the FEAT-013 register, each with a landed fix and a regression test:
- **Recovery/compaction reliability** (MF-006/007/008/012/050): the default sequential dispatch path now
  mechanically pauses on a `nazgul/.hitl-pending` marker in HITL mode; `pre-compact.sh` skips its
  checkpoint write when stop-hook's richer one already exists for the current iteration;
  `post-compact.sh`/`session-context.sh` defer to the aggregate review path in group/feature granularity;
  `.compaction_count` increments exactly once per compaction cycle via an `mkdir`-based lock (confirmed
  PostCompact and SessionStart[compact] both fire for the same event); `post-compact.sh` now calls
  `migrate-config.sh`, mirroring `session-context.sh`'s existing SessionStart call.
- **Config schema/migration hygiene** (MF-046/048/051): `migrate-config.sh` prunes `.bak` backups to the
  5 most recent; dead keys `safety.block_destructive_commands`, `safety.require_tests_pass_before_review`,
  and top-level `task_file`/`log_dir`/`review_dir` are removed (with explicit-value preservation on
  migration); `parallelism.*`/`context.*` are marked deprecated-in-place rather than removed; new test
  labels describe behavior, not a version number.
- **Guard/script cosmetic fixes** (MF-016/021/030/031/032/036): `emit-event.sh` substitutes JSON `null`
  instead of silently dropping the whole event on a malformed `:n`-suffixed numeric value;
  `reviewer-selection.sh`'s architecture-surface classifier now recognizes `templates/*`, `references/*`,
  `.github/workflows/*`, `RULES.md`, `CLAUDE.md`; `formatter.sh` queries `.tool_input.file_path` before
  falling back to a blind recursive scan; `notify.sh` resolves its `nazgul/...` paths against
  `CLAUDE_PROJECT_DIR`; `webhook-forward.sh` passes headers through a native bash array instead of an
  `xargs` pipeline that word-split values containing spaces; `git-hooks.sh` recognizes the four `p4-*`
  githooks(5) names and flags `core.hooksPath` drift against both the managed dir and the recorded prior
  value.
- **Teammate contract hardening** (MF-041/042/045/047/054/056): `teammate-idle-guard.sh`'s
  traversal-`NAME`/traversal-`report_path` fail-open branches and dual-form-`stat`-failure fallback are
  now regression-tested; the write-only `.delivered` manifest field is removed; `self-audit.sh` gained a
  spawn-vs-manifest discrepancy cross-check (`_mine_teammate_spawn_discrepancy`); an empirical dispatch
  confirmed the guard's logging mechanism works correctly (the previously-empty `teammate-idle.jsonl` log
  was explained by the known worktree-resolution gap, not a broken guard).
- **Operational surfacing** (MF-044/057): a failed heartbeat start relocates its inbox item to
  `nazgul/inbox/failed/` instead of leaving it silently archived; `test-shellcheck.sh` reports a distinct
  `SKIP` instead of a synthetic `PASS` when shellcheck is absent from `PATH`.
- **Agent-prompt cleanup** (MF-020/043): `review-gate.md`'s pipeline steps are renumbered sequentially (no
  more Step 3.6 physically preceding 3.5, no duplicate 1.5); `team-orchestrator.md`'s duplicate "3."
  review-team step is renumbered.
- **Docs drift** (MF-029/049): `docs/CONFIGURATION.md`'s Execution Engine section now describes the live
  `execution.parallel` engine instead of the deleted Conductor architecture, adds `--parallel`/
  `--conductor` to the flags list, drops the dead "Fast Mode" section, and corrects "Self-Improvement
  Mode" to the implementer's live opt-in `self_improvement.{enabled,threshold}` gate (distinct from the
  mandatory `self_audit.*` post-loop gate); `CLAUDE.md`'s `scripts/` directory map adds the five
  previously-omitted wired hook scripts (`local-mode-tracking-guard.sh`, `lean-comments-guard.sh`,
  `stop-failure.sh`, `subagent-stop.sh`, `teammate-idle-guard.sh`).

### Retired
- **MF-018** (already fixed, no code) — `review-gate.md`/`feedback-aggregator.md` already cite
  `references/fix-first-heuristic.md` by pointer, closing the duplication this finding named.
- **5 findings retired as wontfix**, with rationale recorded and human sign-off obtained (ADR-005
  Decision 1): MF-017 (misleading `resolved` field name — the one real risk is independently closed by a
  FEAT-016/TASK-001 regression test), MF-019 (`review_gate.require_all_approve` is extensively
  self-documented as intentionally informational in five places), MF-033 (two security-critical
  tokenizers solve different parsing problems — consolidation risk exceeds the cosmetic payoff), MF-037
  (`worktree-utils.sh` directory-placement nit on working code; the actual MF-034 dead-code defect is
  separately confirmed fixed), MF-061 (originally filed as no-fix-needed).
- Two FEAT-016 backlog items closed: the HIGH `stop-hook.sh` parallel-batch merge-before-review ordering
  finding (closed by the parallel-batch reorder above) and the TASK-005 fabricated-board incident item
  (closed by the receipt-hash content gate above).

This closes the FEAT-013 360 Reliability Audit's 62-item register: 30 shipped in Waves 1-3
(FEAT-014/015/016), 26 fixed + 1 already-fixed + 5 wontfix here — 62/62 dispositioned.

## [2.20.0] - 2026-07-23

FEAT-016, the third repair wave from the FEAT-013 360 reliability audit — review-pipeline
correctness. Nine commits (`5e03697`..`f1655b9`).

### Added
- **`resolve_review_unit()` shared resolver** (MF-013, `scripts/lib/review-evidence.sh`): the single
  point that maps a task to its review directory — `task_id` unchanged in `task` granularity, or the
  task's `GROUP-<n>`/`FEATURE-<feat_id>` in `group`/`feature` granularity — now bridges evidence for
  `task-state-guard.sh`'s IN_REVIEW/DONE gates and `stop-hook.sh`'s aggregate-review bookkeeping with
  no independent re-derivation at either call site.
- **Mechanical `review_unit` event field, both halves** (MF-015): `agents/review-gate.md`'s Step 2.5
  emit step computes each `reviewer_verdict` event's `review_unit` by calling
  `resolve_review_unit()` directly instead of restating its own prose `[UNIT-ID]` claim as-is
  (producer half); `subagent-stop.sh`'s review-coverage detector reads that `review_unit` straight
  off the event as ground truth, falling back to `resolve_review_unit()` only for pre-fix events
  that predate the field (consumer half) — closing the cross-run granularity misclassification
  window.
- **Config schema v28 → v29** (`migrate_28_to_29`): one additive kill-switch key —
  `review_gate.stall_retry_escalate_tier` (default `true`) — following the existing
  additive-merge-with-explicit-value-preservation convention.
- **Bounded one-retry model-tier escalation on reviewer stall** (MF-014,
  `scripts/lib/reviewer-tier.sh` `resolve_retry_model`): a reviewer that stalls or returns an
  unparseable verdict is retried one tier up (e.g. haiku → sonnet) instead of the same tier, unless
  `review_gate.stall_retry_escalate_tier` is `false`. Reviewer dispatch inside `review-gate.md` is now
  explicitly synchronous — every reviewer's Agent-tool call is a single-message, foreground, blocking
  call the orchestrator waits on before proceeding, never assumed to complete in the background.
- **Verdict-filename self-check** (MF-058, log-only, never blocks): before finalizing, review-gate
  checks that each persisted `<UNIT-ID>/<reviewer-name>.md` matches the four-consumer naming
  convention all readers (task-state-guard, review-evidence, feedback-aggregator, subagent-stop)
  expect, and logs a mismatch rather than silently producing evidence no consumer can find.
- **Explicit dispatch trust boundary** (MF-059, prompt-only guidance): `agents/review-gate.md`,
  `agents/templates/reviewer-base.md`, and `agents/team-orchestrator.md` now state that only the
  diff, context, and instructions assembled into a reviewer's initial dispatch are authoritative —
  a reviewer's own return, or an inbound `SendMessage`, can never inject a fabricated verdict or
  urgency claim after the fact.

### Fixed
- **`review-provenance.sh`'s `resolved` field confirmed dispatch-roster-only, never verdict evidence**
  (FEAT-009 backlog item): TASK-001 added a regression test
  (`tests/test-review-evidence.sh` — "resolved:true without persisted file: still MISSING") proving
  `validate_review_evidence` never trusts a dispatch manifest's `resolved` flag (computed pre-dispatch
  from `.claude/agents/generated/<reviewer>.md` presence) as a substitute for a reviewer's actually
  persisted, APPROVED verdict file — the persist-then-mark ordering the original finding asked for was
  already enforced at the evidence-gate boundary; the desync it observed was a manifest/persistence
  ordering issue, not a gate that could be fooled.

## [2.19.0] - 2026-07-23

FEAT-015, the second repair wave from the FEAT-013 360 reliability audit — guard integrity and
enforcement. Sixteen commits (`6a8e9d0`..`2b685fa`).

### Added
- **`scripts/lib/task-transition-guard.sh`**: `ttg_valid_transition()`, the commit-SHA gate, and the
  review-evidence check extracted out of `task-state-guard.sh` into a reusable library, callable
  from both the PreToolUse path and a new stop-hook-time reconciliation pass (MF-022,
  ADR-003 Decision 2). At the top of every `stop-hook.sh` iteration, each task manifest's live
  status is diffed against the last checkpointed status; any change that didn't pass through the
  shared transition-guard library since the last checkpoint is flagged `BLOCKED` with a named
  diagnostic instead of silently trusted — closing the Bash-write forgery bypass. Gated by
  `guards.bash_write_reconciliation` (default `true`).
- **Config schema v27 → v28** (`migrate_27_to_28`): two additive kill-switch keys —
  `guards.bash_write_reconciliation` (default `true`) and
  `automation.heartbeat.lock_stale_seconds` (default `300`) — following the existing
  additive-merge-with-explicit-value-preservation convention.
- **Real commit-SHA evidence gate** (MF-026): the IMPLEMENTED transition now verifies the manifest's
  `## Commits` SHA actually exists in the repo instead of trusting an unchecked string.
- **Heartbeat atomic claim** (MF-039): `heartbeat.sh` now `mkdir`s an atomic lock directory as its
  first action, so two concurrent ticks race on the `mkdir` itself instead of a stale `ls` read;
  released via `trap ... EXIT`.

### Fixed
- **Git-hooks lifecycle activation + worktree cwd-safety** (MF-034, MF-035): `skills/start/SKILL.md`'s
  five inline branch-setup prose blocks now call the existing `create_feature_branch` /
  `cleanup_all_worktrees` library functions, which already install/uninstall the managed
  `core.hooksPath` guards durably — closing both the dead-activation gap and the worktree-cwd merge
  escape it created.
- **Three dead guards revived** (MF-023, MF-024, MF-025): `scripts/lib/task-utils.sh`'s new shared
  `get_task_files_modified()` accessor (MF-025) replaces three independent ad hoc comma-split
  `Files modified` parsers across `task-state-guard.sh`'s File Scope check (MF-024 — corrects the
  field-name mismatch that left it silently dead), `parallel-batch.sh`'s disjoint-scope check, and
  `parallel-rework-guard.sh`'s `_scope_has()` — all three now correctly match bracket/quote-laden
  JSON arrays. `scripts/prompt-guard.sh` (MF-023) now reads the real `UserPromptSubmit` stdin JSON
  envelope instead of an env var Claude Code never sets in production.
- **Guard precision** (MF-027, MF-028): `pre-tool-guard.sh`'s `rm -rf` root/home patterns are now
  anchored so legitimate absolute-path deletions (`rm -rf /tmp/build-cache`) are allowed while
  `rm -rf /`, `rm -rf ~`, `rm -rf $HOME` stay blocked; the force-push check now ANDs two independent
  boolean conditions instead of two ordered regexes, so `git push origin main --force` and
  `git push origin main -f` are blocked alongside the previously-covered forms.
- **Parallel guards fail closed** (MF-053, ADR-003 Decision 3): `parallel-dispatch-guard.sh` and
  `parallel-rework-guard.sh` now distinguish "config missing" (safe no-op) from "config present but
  unparseable" (fail closed with a loud diagnostic), replacing a silent `jq ... || echo "false"`
  fallback that no-opped the guard on a torn/corrupt write.
- **Wave Groups parsing** (MF-040): `parallel-batch.sh` now parses each `### Wave N` heading plus
  all following `- TASK-NNN` bullets in any format (one-per-line or comma-grouped) instead of
  requiring same-line comma-grouped bullets, which previously silently degraded a one-bullet-per-task
  plan to fully sequential dispatch.
- **Connector push local-id threading** (MF-038): `connector_github_pull_archive` now threads the
  picked issue number through to a real local id via `heartbeat.sh`'s archive-then-start flow
  (bounded poll of `nazgul/config.json → feat_id`), so `_cgh_map_resolve` can match and
  `push_status`/`push_pr` are no longer unconditional no-ops.

## [2.18.0] - 2026-07-22

FEAT-014, the first repair wave from the FEAT-013 360 reliability audit (63
verified findings). Seven commits (`c411880`..`2a4516d`).

### Added
- **Test-realism foundation** (MF-052, MF-055): `create_task_file()` now
  emits canonical frontmatter by default instead of the legacy shape, with
  `create_task_file_legacy()` preserved for tests that still need it.
  `tests/test-shellcheck.sh` globs every script instead of a fixed list,
  growing coverage from 64 to 105 checks. The realistic fixtures immediately
  surfaced a real production bug (see Fixed).
- **Telemetry-dark detection**: SessionStart now flags a stale `plan.md`
  Status Summary against recomputed task counts instead of trusting a
  number that could silently drift from reality (MF-060). Retired 4
  already-fixed backlog items found stale during the sweep (MF-062).

### Fixed
- **`stop-hook.sh`'s git-conflict handler silently never set tasks
  `BLOCKED`** on real frontmatter-shaped manifests — `set_task_status` was
  comparing against a literal `".*"` instead of doing a proper
  compare-and-swap against the current status. Found by the MF-052/MF-055
  fixtures; this was live in production against real task files.
- **Enum drift** (MF-001, MF-010, MF-063): `APPROVED` added to
  `VALID_STATUSES`/`VALID_VERDICTS`; `task-state-guard.sh` now derives its
  status list from `structured-state.sh` instead of hand-maintaining a
  duplicate, closing the drift vector that produced MF-001. Fixes the YOLO
  wedge and completion-unreachable bugs (MF-004, MF-005).
- **Recovery Pointer**: format-tolerant label matching plus a loud no-op
  warning so a mismatched format fails loudly instead of silently returning
  nothing against a live `plan.md` (MF-003).

### Changed
- **Counting consolidation**: one shared `count_tasks_and_find_active()`
  helper replaces four duplicated blocks across `stop-hook.sh`,
  `pre-compact.sh`, `post-compact.sh`, and `session-context.sh`, with a loud
  `INVALID` arm so an off-vocabulary status is diagnosed instead of silently
  dropped (MF-002, MF-009, MF-011).

## [2.17.3] - 2026-07-22

### Removed
- **Per-skill `metadata.version` fields (all 25 skills).** The "lockstep"
  was an illusion: only `start`/`status` were ever bumped, 23 skills were
  frozen at 2.7.1, and nothing — no script, test, or platform feature —
  reads the field. Removing it closes the drift class instead of syncing 25
  files on every release. `.claude-plugin/plugin.json` is the single
  version of record.

### Changed
- Release workflow title derivation: single `git/ref/tags` API call (was
  two) and first-line extraction via jq (was a `head -1` pipeline under
  `pipefail`).

## [2.17.2] - 2026-07-22

### Fixed
- **Release-on-tag workflow checkout failure**: `fetch-tags: true` (added on
  review advice, unverified) conflicts with checkout's trigger-ref mapping on
  tag-push events (`Cannot fetch both <sha> and refs/tags/<tag>`), which
  failed the v2.17.1 run before any step executed. Reverted to the default
  shallow checkout; the release title's tag-annotation subject is now read
  via the GitHub API (`git/ref/tags` → `git/tags`), removing every local-ref
  dependence. The v2.17.1 Release itself was backfilled manually.

## [2.17.1] - 2026-07-22

### Added
- **Release-on-tag workflow** (`.github/workflows/release.yml`): every pushed
  `v*` tag now mechanically gets a GitHub Release — notes extracted from the
  matching `CHANGELOG.md` section, title derived from the annotated tag
  subject when it follows the release convention. Idempotent (no-op when the
  Release already exists), so it composes with the release-manager agent's
  own step 10. Closes the third instance of Releases drifting from tags
  (v2.14.0/v2.15.0 backfilled late; v2.17.0 published only on request) —
  instructions weren't enforcement, now the tag push is the trigger.

## [2.17.0] - 2026-07-22

### Added
- **Teammate Report Contract (3 layers).** In Agent Teams mode a teammate's
  final text is delivered to no one, so teammates finished work then idled
  without reporting, forcing a manual nudge per agent. Now: every teammate
  dispatch ends with a Report Contract block naming an explicit report file
  (`templates/skill-partials/report-contract.md`); dispatchers register the
  expected deliverable in `nazgul/dispatch/<session-name>.json`; and a new
  `TeammateIdle` hook guard (`scripts/teammate-idle-guard.sh`) blocks a
  registered teammate from idling while its report file is missing — bounded
  (≤3 blocks then fail-open escalation), fail-open on unknown payloads, and
  kill-switchable via `execution.enforce.teammate_report_guard` (config
  schema v26 → v27, additive). Completion signal is now idle notification +
  report file on disk; SendMessage is coordination-only courtesy.
- Telemetry: every TeammateIdle payload is appended to
  `nazgul/logs/teammate-idle.jsonl` (ongoing payload-schema discovery).

### Changed
- `agents/team-orchestrator.md`: explicit dispatch-manifest lifecycle
  (manifest before spawn → contract block in prompt → idle+file = complete →
  teardown deletes manifests); "signal completion to the caller" vagueness
  removed.
- `scripts/stop-hook.sh` parallel-batch dispatch: carries the Report Contract
  instruction for teammate-dispatched implementers.
- RULES.md §3.9: corrected the stale claim that subagent dispatch cannot be
  pre-gated (the PreToolUse `Agent` matcher exists and is in use).

## [2.16.0] - 2026-07-21

### Removed
- **Conductor execution engine.** `agents/conductor.md`, its libraries
  (`scripts/lib/conductor-graph.sh`, `scripts/lib/conductor-gates.sh`,
  `scripts/lib/conductor-router.sh`), its guards (`scripts/conductor-dispatch-guard.sh`,
  `scripts/conductor-rework-guard.sh`), and their tests are deleted outright. `execution.engine`
  is removed from the config schema. See `docs/DECISION-LOG-2026-07-21-parallel-execution-collapse.md`
  for the platform rationale: since Claude Code v2.1.198 subagents run in the background by
  default, nested `Agent` calls from inside a subagent do not block, and background-completion
  notifications are documented to re-engage only the main session — there is no documented
  mechanism giving a nested parent subagent a fresh turn when its children finish. That made the
  Conductor's own "wait for every dispatch to return" step stall at every wave boundary,
  post-commit review dispatch, and review tally.

### Added
- **`execution.parallel` batch dispatch in the sequential loop.** There is now one engine — the
  existing stop-hook loop — with an opt-in parallel-batch option computed deterministically by
  `compute_dispatch_batch` (`scripts/lib/parallel-batch.sh`, absorbing the wave-layering logic
  from the retired conductor libs). `/nazgul:start --parallel` enables it (composes with any mode
  flag, e.g. `--parallel --afk`); `--conductor` is now a deprecated alias that sets
  `execution.parallel: true` and prints a deprecation note. New keys: `execution.parallel` (bool,
  default `false`) and `execution.max_parallel` (int, default 3).
- **Config schema v25 → v26**, migrating conductor configs automatically: `execution.engine ==
  "conductor"` → `execution.parallel: true`; `conductor.max_parallel` → `execution.max_parallel`;
  `conductor.gates.approve_graph`/`approve_each_wave`/`approve_final_pr` → `execution.gates.
  approve_plan`/`approve_batch`/`approve_final_pr`; the `nazgul/conductor/` runtime directory
  (including `graph.json`) is deleted by the migration. In-flight conductor runs resume from task
  manifests via the ordinary loop — there is no separate graph state to recover.
- **Guards and the premerge git hook re-keyed to task manifests.** `scripts/parallel-dispatch-guard.sh`
  and `scripts/parallel-rework-guard.sh` replace the conductor dispatch/rework guards, keyed off
  task manifests instead of `graph.json`. `scripts/git-hooks/pre-merge-commit` now parses a task
  manifest's YAML frontmatter `status:` field first (falling back to the legacy `- **Status**:`
  line only when frontmatter is absent) — there is no conductor graph left to read a unit's status
  from.
- **`review_gate.granularity` gates parallel batching.** Batch dispatch only reviews per task when
  `review_gate.granularity` is `"task"`; the template default, `"group"`, stays fully sequential
  even with `execution.parallel: true` — a project opts into both independently.

## [2.15.0] - 2026-07-14

### Added
- **GitHub two-way connector (FEAT-012, ADR-001, RULES.md §16).** Completes component 4 of the loop-engineering roadmap: a real remote provider that both pulls work in and pushes results back out. `scripts/lib/connector-github.sh` implements the provider contract — `connector_github_pull_list` (open issues carrying the opt-in label, minus the already-handled set), `connector_github_pull_get` (issue → normalized `{title,body,priority,type}` JSON, byte-capped at `connectors.github.pull.max_body_bytes`, default 65536), `connector_github_pull_archive` (add the claimed label — the idempotent "I took this" signal), `connector_github_push_status` (reflect a local task/objective status onto the mapped issue as a single `nazgul-status:<status>` label), `connector_github_push_pr` (upsert one `<!-- nazgul-pr -->`-marked PR-link comment), and `connector_github_health` (gh-auth + rate-limit check). Both directions are **wired into the running loop** (FEAT-012 TASK-008): `scripts/heartbeat.sh` now consumes the `github` provider so labeled issues pull into the inbox and the heartbeat can auto-start them, and `scripts/stop-hook.sh` pushes task status (and the PR link when one exists) back to the mapped issue on a transition.
- **Generalized provider seam (file vs github).** `scripts/lib/inbox-provider.sh` routes `inbox_list`/`inbox_get`/`inbox_archive` to the GitHub connector when `automation.heartbeat.inbox.provider == "github"`, and keeps the local `file` provider behavior byte-identical otherwise. Linear/Slack are follow-on providers that slot in behind this same seam as sibling `connector-*.sh` — they are **not** shipped in this release.
- **Opt-in and default-off.** The connector is gated by `connectors.github.enabled` (default `false`); no existing project changes behavior until it is explicitly enabled. Push is separately gated by `connectors.github.push.enabled` (default `true`, but only active under the top-level `enabled`).
- **gh-auth-only security model.** Credentials come exclusively from `gh auth`/env — no token is ever written to `config.json` or logged. Remote issue title/body are treated as DATA (reach `jq` only via `--arg`/`--rawfile`, never `eval`'d), and a hostile body is bounded by `max_body_bytes`.
- **Failure degradation.** A failed pull (after retry) bumps `connectors.github.pull_failures`; at 5 consecutive failures the connector auto-disables (`enabled=false`) with a warning, and a good pull resets the counter to 0 — a network/auth/rate-limit fault degrades to a no-op tick, never a crashed hook or a stalled loop.
- **Config schema v24 → v25.** `migrate_24_to_25` (`scripts/migrate-config.sh`) additively adds `connectors.github.{enabled:false, pull.{label:"nazgul", claimed_label:"nazgul-claimed", max_body_bytes:65536}, push.{enabled:true}, pull_failures:0, map:{}}`. Additive (set only when absent); explicit values including `enabled:true`, `push.enabled:false`, and a populated `map` are preserved, and no credential key is ever added. The existing `automation.heartbeat.inbox.provider` key selects `"github"` — no new provider-selection key was needed.

## [2.14.0] - 2026-07-13

### Added
- **`UNVERIFIED` review verdict — role-aware, fail-closed (FEAT-011, ADR-001, RULES.md §3).** The shared Review Board gains a fourth verdict that separates "a reviewer could not assess the change" from "a reviewer reviewed and rejected it" (the `/deep-research` principle: a claim the verifier *could not check* is unverified, not refuted). `UNVERIFIED` is emitted either by a reviewer that self-reports it cannot assess (`agents/templates/reviewer-base.md`) or by the review-gate orchestrator as a token-stamped stub when a dispatched reviewer errors, times out, or returns unparseable text — instead of jumping straight to BLOCKED. It is added to `VALID_VERDICTS` (`scripts/lib/structured-state.sh`) and carries its own bounded counter: a terminal `UNVERIFIED` re-dispatches that one reviewer up to `review_gate.unverified_retries` (default 2) times and never increments the CHANGES_REQUESTED `retry_count`. After retries, resolution is **role-aware** (`agents/review-gate.md` Step 2.6): a critical reviewer (`review_gate.critical_reviewers`, default `["security-reviewer","architect-reviewer"]`) still `UNVERIFIED` escalates to BLOCKED (fail-closed); a non-critical reviewer becomes a non-blocking warning that satisfies the DONE gate only when `review_gate.allow_unverified_nonblocking` is `true` (default). The DONE-gate half is enforced in `scripts/lib/review-evidence.sh` (`_has_approved_verdict` treats `UNVERIFIED` as not-approved; `_re_is_authorized_unverified` admits a non-critical `UNVERIFIED` only under the toggle, falls back to the default critical list on a malformed/ambiguous config — fail closed, not open — and never admits `security-reviewer`). Each finalized `UNVERIFIED` emits a `reviewer_unverified` event.
- **Conductor `SECURITY_UNVERIFIED` hard-stop line (FEAT-011).** `_cgate_security_rejections` (`scripts/lib/conductor-gates.sh`) emits a distinct `SECURITY_UNVERIFIED` line (same unconditional halt as a security rejection) when the security reviewer's verdict is `UNVERIFIED`, so conductor logs separate "could not assess" from "rejected."
- **Bounded borderline adversarial cross-check (FEAT-011).** When `review_gate.adversarial_crosscheck` is `true` (default), a blocking finding whose confidence lands within `review_gate.adversarial_margin` (default 10) of `confidence_threshold` **and** is HIGH severity or on a security-relevant file gets exactly one fresh confirm-or-refute reviewer dispatched for that single finding (`agents/review-gate.md` Step 3); a refute at ≥ threshold downgrades it to a non-blocking CONCERN, otherwise it stays blocking. Bounded by `review_gate.adversarial_max` (default 3) cross-checks per review unit. Per FEAT-006 cost discipline this never re-reviews everything or runs a second board — worst-case added cost is `adversarial_max` single-finding dispatches, and it is a one-line opt-out.
- **Config schema v23 → v24.** `migrate_23_to_24` (`scripts/migrate-config.sh`) additively adds six `review_gate` keys — `unverified_retries` (2), `allow_unverified_nonblocking` (true), `critical_reviewers` (`["security-reviewer","architect-reviewer"]`), `adversarial_crosscheck` (true), `adversarial_margin` (10), `adversarial_max` (3). Additive (set only when absent); explicit values including `false` and a custom `critical_reviewers` list are preserved, keeping today's APPROVE/CHANGES_REQUESTED happy path byte-identical.

## [2.13.1] - 2026-07-10

### Fixed
- **Self-audit script invoked via a bare-relative path — silently never ran outside this repo.** `agents/self-audit.md` and the `stop-hook.sh` fallback hint now invoke `"${CLAUDE_PLUGIN_ROOT}/scripts/self-audit.sh"` instead of `scripts/self-audit.sh` — matching every other agent's plugin-script convention. The bare-relative path only worked when dogfooding in this repo; in a target project (local-mode install syncs only `agents/`) the script did not exist at that path, so the mining core's script-backed cost/perf signals silently never ran.
- **`_transcripts_dir()` transcript-cost resolution ignored `CLAUDE_CONFIG_DIR` and mis-encoded non-alphanumeric path characters.** `scripts/self-audit.sh` now derives the transcripts base from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and maps every non-`[A-Za-z0-9]` character (not just `/`) to `-`, matching Claude Code's own project-directory slug encoding (spaces included). Falls back to a basename glob match on residual encoding drift only when it resolves unambiguously to a single project dir (never arbitrarily picking one of several same-leaf matches), and still degrades to "cost unavailable" rather than failing the run or mining an unrelated project.
- **Fail-loud when `self_audit.enabled: true` but the resolved script is absent.** The self-audit agent now emits a visible warning instead of silently no-op'ing when its script path doesn't exist.
- **Conductor post-loop gate summaries now read from authoritative markers**, not from a subagent's prose return, so a gate that ran with only a best-effort sub-step degradation (e.g. self-audit's transcript cost mining) is no longer mis-reported as "did not run".

## [2.13.0] - 2026-07-10

### Added
- **Git-level enforcement of git-action guards (FEAT-010, ADR-001, RULES.md §15).** The base-branch commit guard and the H2 conductor pre-merge verdict guard move from `PreToolUse(Bash)` command-string parsing to real git hooks activated via `git config core.hooksPath` pointing at a plugin-managed directory (`nazgul/.githooks/`, per project). Two proven-non-convergent command-string guards — three review rounds each found new shell-expansion/wrapper bypasses — are replaced by hooks that run after the shell has fully resolved the command, closing the class of bypass entirely rather than patching another rule into a tokenizer.
- **`pre-commit` base-branch guard.** `scripts/git-hooks/pre-commit` blocks a commit on `branch.base` while `branch.feature` is set, resolving "current branch" from the repo the hook itself runs in — fixing the old guard's cwd false-positive (always resolved `$CLAUDE_PROJECT_DIR`'s branch) and its `git -C` false-negative.
- **`pre-merge-commit` H2 conductor verdict guard.** `scripts/git-hooks/pre-merge-commit` blocks `git merge --no-ff` of a Conductor unit whose `nazgul/conductor/graph.json` record lacks a `DONE` status + `APPROVE` verdict, identified via git's content-hash-keyed `GITHEAD_<sha>` environment variables (resistant to the `GIT_REFLOG_ACTION` spoof that defeated the earlier command-string design). Gated by the new `conductor.enforce.premerge_guard` (default `true`) and only active when `execution.engine == "conductor"`.
- **Generic chain-dispatcher preserves user hooks.** `scripts/git-hooks/_dispatch.sh` forwards argv/stdin/exit code to any hook that previously occupied `core.hooksPath`/`.git/hooks`; every other standard githooks(5) name ships as a pass-through shim, so pointing `core.hooksPath` at the managed dir never silently disables a user's own `commit-msg`, `pre-push`, etc.
- **Install/uninstall/self-heal lifecycle.** `scripts/lib/git-hooks.sh` installs the managed hooks inside `create_feature_branch`/`setup_worktree_dir` (`scripts/worktree-utils.sh`) at the moment `branch.feature` is assigned — durably recording the live `core.hooksPath` into the new `branch.prior_hooks_path` first — uninstalls and restores that recorded value at objective completion (`cleanup_all_worktrees`), and self-heals (re-asserts only on detected drift) from `scripts/session-context.sh`'s `SessionStart` block. Gated on the new `guards.git_hooks` toggle (default `true`).
- **Config schema v22 → v23.** `migrate_22_to_23` additively re-adds `conductor.enforce.premerge_guard` (default `true`), adds `branch.prior_hooks_path` (default `null`, the not-yet-recorded sentinel; empty string means recorded-and-was-unset), and adds `guards.git_hooks` (default `true`). Existing values are preserved.

### Removed
- **`scripts/base-branch-commit-guard.sh`.** The old command-string `PreToolUse(Bash)` guard and its `hooks/hooks.json` registration are deleted outright, fully superseded by the `pre-commit` git hook above — see ADR-001 for why it is not retained as a redundant advisory layer.

## [2.12.0] - 2026-07-10

### Added
- **Post-loop self-audit gate + durable improvements backlog (FEAT-009, ADR-001).** A new post-loop gate mines this objective's own signals — review rejections, retries, blocks, best-effort transcript token cost, and any first-party findings — and appends one structured entry per finding to a durable, append-only backlog at `nazgul/improvements.md` (path configurable via `self_audit.backlog_path`). `scripts/self-audit.sh` is the testable core (never fails the run — every source degrades to a no-op when absent); `agents/self-audit.md` is the delegated agent; `scripts/stop-hook.sh` blocks `NAZGUL_COMPLETE` until the agent writes an objective-scoped `nazgul/logs/.self-audited` marker, with a bounded ≤3-attempt backstop so it can never deadlock an unattended loop. Opt out with `self_audit.enabled: false`.
- **First-party finding-raise channel (FEAT-009, RULES.md §14).** `scripts/lib/raise-finding.sh` ships a sourceable `raise_finding <severity> <category> <title> <detail> [suggested_fix] [evidence]` helper that any Bash-capable sub-session (implementer, team-orchestrator, debugger, conductor) can call to surface an in-the-moment improvement candidate that survives it exiting — instead of silently working around an out-of-scope problem or inventing unplanned scope creep to fix it mid-task. Each call appends one JSON line to `nazgul/logs/findings.jsonl` (built data-only via `jq --arg`, embedded `\n`/`\r` neutralized before storage, `flock`-guarded when available); the file is ingested by the self-audit gate into the backlog. Reviewer sub-sessions stay read-only and note candidates in their returned review instead.
- **`models.conductor` config key (default `sonnet`).** Pins the Conductor's own model tier explicitly. `/nazgul:start` dispatches `agents/conductor.md` with `model: $(jq -r '.models.conductor // "sonnet"')`, so a Conductor run no longer silently inherits the launching session's tier.
- **`/nazgul:status` conductor-mode view.** When `execution.engine` is `conductor` and a `nazgul/conductor/graph.json` exists, `/nazgul:status` renders a Conductor Wave Progress block (current wave, next unit, per-unit verdicts) in place of the sequential Task Progress block; during the planning phase (no graph yet) it shows a one-line "no graph yet" note. All other status sections are unchanged.

### Changed
- **`models.review` split into `models.review_orchestrator` / `models.review_default`.** The single review tier is now two keys: `review_orchestrator` (the review-gate/conductor orchestrator tier) and `review_default` (the default per-reviewer tier for the mechanical code/qa reviewers). Both resolve with the exact fallback chain **new key → legacy `models.review` → hardcoded** (`sonnet` for the orchestrator, `haiku` for the default reviewer), so existing configs that still carry only `models.review` are honored unchanged. `models.review_by_reviewer` still pins `security-reviewer`/`architect-reviewer` to `sonnet` on top of this.
- **Conductor-owned per-unit fan-out for parallel mutating waves (FEAT-009 H1, ADR-004).** `route_backend`/`route_wave` (`scripts/lib/conductor-router.sh`) now resolve a Planner-marked, zero-overlap parallel mutating batch to the `subagent` backend: the Conductor dispatches each unit as its own concurrent Agent-tool implementer call in one message and waits for all to return, rather than routing the batch to `team-orchestrator` (which has no `Agent`/`Task` tool and silently serialized the wave). A lone mutating unit still routes to `worktree`; reviews always route to `subagent`. The `team` backend is retained only for a currently-unused `coordination`-isolation batch — it is deprecated from the mutating-batch routing path. This also closes the documented "Layer 1 vs. Layer 4" limitation in RULES.md §12.
- **Conductor re-work guard exempts the current task's own scope (FEAT-009 H3, ADR-006).** `scripts/conductor-rework-guard.sh` no longer blocks the actively-dispatched unit from writing inside its own `file_scope`; it still blocks writes into the scope of a *different* unit already committed in `graph.json`. This removes a false-positive that could stall an in-flight unit whose own files overlap the guard's cross-cutting check.
- **Hygiene bundle.** Stale conductor markers (`nazgul/conductor/.session`, `.resume-needed`) now self-heal on a fresh start rather than wedging a new run; starting a new plan archives the prior objective's `nazgul/tasks/` instead of leaving them to bleed into the new objective; and CLAUDE.md's command-form references and a stale migration-name reference were corrected.
- **Config schema v21 → v22.** `migrate_21_to_22` additively adds `models.conductor` (`sonnet`), splits `models.review` into `models.review_orchestrator`/`models.review_default` (seeded from an existing `models.review` when present, else `sonnet`/`haiku`; `models.review` itself is left untouched as the fallback), and adds the `self_audit.{enabled: true, backlog_path: "nazgul/improvements.md"}` block. Existing values are preserved.

### Deferred to FEAT-010
- **H2 — conductor pre-merge review-verdict guard.** A mechanical PreToolUse guard blocking a Conductor `git merge` unless the unit has a recorded `DONE` + `APPROVE` verdict (ADR-005) was reverted; its guard script, `hooks.json` registration, and the `conductor.enforce.premerge_guard` config key are NOT shipped in this release.
- **Base-branch-commit-guard cwd fix (TASK-004).** The fix for the guard's working-directory bug was reverted; the guard remains at its v2.11.0 baseline.

Both were deferred because parsing the `git merge`/`git commit` command string to infer intent proved to be an open-ended command-parsing arms race (multiple bypass classes found across review rounds); the fix belongs at a git-level enforcement layer rather than a hand-rolled tokenizer, and is tracked under "[FEAT-010] git-level enforcement" in `nazgul/improvements.md`.

## [2.11.0] - 2026-07-09

### Added
- **Opt-in Automation Heartbeat (FEAT-008).** A default-off (`automation.heartbeat.enabled: false`), trigger-agnostic tick engine (`scripts/heartbeat.sh`) lets Nazgul pick up unattended work between sessions. It is fired by hand via `/nazgul:heartbeat` (`skills/heartbeat/SKILL.md`) or by an opt-in Claude Code native scheduled agent configured outside the plugin — the heartbeat is never wired to any hook, and running it is a no-op change to the sequential or Conductor execution paths.
- **Inbox-provider seam.** `scripts/lib/inbox-provider.sh` ships a file provider (`nazgul/inbox/*.md|json`, archived on claim to `nazgul/inbox/archive/`) behind a seam a future GitHub/Linear provider can drop into without touching the tick engine; those real connectors are deferred to FEAT-009.
- **Deterministic triage.** `scripts/lib/heartbeat-triage.sh` picks one objective (or reports "nothing actionable") from the inbox candidates using `jq` only — no `eval` is run over inbox or objective text at any point in the pipeline.
- **Session-guarded, hardened auto-start.** When `count_active_sessions` (`scripts/lib/session-tracker.sh`) reports no active session, the heartbeat starts the picked objective via `/nazgul:start`, with the mode/engine flags (`--yolo`/`--afk`/`--hitl`, `--conductor` or omitted) taken from `automation.heartbeat.auto_start.{mode,engine}` — `--yolo --conductor` by default; otherwise it logs a no-op rather than colliding with a running loop. The auto-start objective is truncated to its first line and has embedded `"`/`\n`/`\r` neutralized before being spliced into the `claude -p` command, closing both a quote-breakout and a newline flag-injection vector (`tests/test-heartbeat-start-injection.sh`).
- **Two unconditional hard stops carried over to heartbeat mode.** Any `BLOCKED` task or any security rejection halts the tick regardless of `enabled` or `mode` (including yolo), reusing the same `conductor_should_halt` (`scripts/lib/conductor-gates.sh`) the Conductor engine already enforces.
- **Atomic, idempotent consumption.** Inbox items are claimed via `mv -f` into `nazgul/inbox/archive/` before start, so a crash mid-tick can't double-process a candidate (`tests/test-heartbeat-idempotency.sh`).
- **Auditable decision records.** Every tick writes one JSON line to `nazgul/logs/heartbeat-*.jsonl` (one file per UTC day), surfaced via `/nazgul:log` (`skills/log/SKILL.md`).
- **Config schema v20 → v21.** `migrate_20_to_21` adds `automation.heartbeat` additively: `enabled` (default `false`), `interval` (`"30m"`), `inbox.{provider,dir}` (`"file"`, `"nazgul/inbox"`), `auto_start.{mode,engine}` (`"yolo"`, `"conductor"`) — existing values preserved.
- **RULES.md gained an Automation Heartbeat section** documenting the tick lifecycle, the hardened auto-start sink, and the honest tier of each control (session guard and hard stops are `[enforced]`; interval scheduling itself is `[advisory]`, left to the external trigger).

Real connectors (Linear/Slack/CI), two-way sync, the GitHub inbox provider, OS cron/`claude -p` scheduling, and any default-flip to "on" are deferred to FEAT-009.

## [2.10.1] - 2026-07-08

### Fixed
- **Conductor model-tiering gap.** `agents/conductor.md` never read `nazgul/config.json → models` before dispatching an `implementer` or `agents/review-gate.md` — every such dispatch silently inherited the Conductor's own model instead of the configured tier, so a Conductor run resolving to a non-default model (e.g. Opus) paid that tier for every implementer and review-gate orchestrator call, not just the Conductor itself. Individual reviewer dispatches were unaffected (`review-gate.md` already resolves `models.review`/`models.review_by_reviewer` per reviewer) and so was the `team` backend (`team-orchestrator` already reads `models.implementation`/`models.review` for its teammates). Added a "Model Selection" step to `agents/conductor.md`: resolves `models.implementation` (default `sonnet`) and `models.review` (default `sonnet`) once, and passes them explicitly as `model` on every `subagent`/`worktree`-backend implementer dispatch and every `review-gate.md` dispatch in Step 5. No schema change — both keys already existed in config.
- **Conductor rework-guard was inert.** `scripts/conductor-rework-guard.sh` (Layer 2) and `graph_wave_digest` (`scripts/lib/conductor-graph.sh`) both keyed their lookups on a `.commit_sha` field, but `graph_set_verdict` — the only code path that ever writes a commit into `graph.json` — writes `.commit`. Since `.commit_sha` never exists in a real graph, the rework guard's `OWNER` lookup always came back empty and it silently allowed every rework, and `graph_wave_digest`'s `sha` field was always `null`. Existing tests didn't catch this because their fixtures hand-constructed graphs using the same wrong `commit_sha` field name, self-consistently matching the bug instead of production reality. Fixed all three call sites to read `.commit`; updated `tests/test-conductor-rework-guard.sh`, `tests/test-conductor-dispatch-guard.sh`, and `tests/test-conductor-recovery.sh` fixtures to match the real schema (`scripts/lib/conductor-graph.sh`'s own header comment already documented `"commit"` as the correct field).
- **Conductor dispatch-guard false-block on `review-gate` for an `IMPLEMENTED` unit.** `scripts/conductor-dispatch-guard.sh`'s Rule 2 treated any work-unit dispatch (`implementer`, `review-gate`, `team-orchestrator`) against a unit already at `IMPLEMENTED`/`DONE` status as wasted re-dispatch and denied it — but dispatching `review-gate` for an `IMPLEMENTED` unit is the correct next step (Step 5.2), not a re-dispatch; only `DONE` (already reviewed) should deny a `review-gate` call. This mattered most on resume-after-interruption, where Self-Recovery can legitimately mirror a task's real `IMPLEMENTED` manifest status into `graph.json` before its review has run — the guard would have permanently blocked that unit's review. Rule 2 now denies `implementer`/`team-orchestrator` on `IMPLEMENTED`/`DONE` (unchanged) but only denies `review-gate` on `DONE`. Added dispatch-guard test coverage for both the newly-allowed and still-denied cases.

## [2.10.0] - 2026-07-08

### Added
- **Enforced Conductor — mechanical dispatch guards, closing the FEAT-007 double-dispatch/orphan gap.** FEAT-007's Conductor engine was a working driver whose correct dispatch behavior was prose in its own prompt; five layers now back one headline invariant, **"completed = cached, never re-executed"**:
  1. `scripts/conductor-dispatch-guard.sh` — new PreToolUse guard on the `Agent` tool — denies (exit 2) running a work-unit subagent (`implementer`, `review-gate`, `team-orchestrator`) in the background, and denies re-dispatching a unit whose `graph.json` status is already `IMPLEMENTED`/`DONE`, matched via the `NAZGUL_UNIT: TASK-NNN` marker `agents/conductor.md` now emits with every unit dispatch.
  2. `scripts/conductor-rework-guard.sh` — new PreToolUse guard on `Write|Edit|MultiEdit` — denies writing to a file inside a committed unit's `file_scope`.
  3. `scripts/subagent-stop.sh` gained conductor orphan detection: on every `SubagentStop` event it checks `graph.json` for units marked `dispatched` but not yet terminal, writing `nazgul/conductor/.resume-needed` and emitting `conductor_orphan_detected`.
  4. `scripts/lib/conductor-router.sh`'s `route_backend`/`route_wave` now route a Planner-marked, zero-overlap parallel wave to `team-orchestrator` instead of one bespoke worktree per unit, reusing the sequential engine's proven Agent-Teams path.
  5. `scripts/lib/conductor-graph.sh` gained `graph_wave_digest`, a cheap `{current_wave, next_unit, units}` orientation snapshot so the Conductor doesn't pay for a full wave recomputation every turn.

  Both guards are scoped to an active conductor session (`nazgul/conductor/.session`, written/removed by `agents/conductor.md`) and no-op outside it — a stray Nazgul agent or a sequential-engine run is never touched. RULES.md gained a new §12 "Conductor Enforcement" documenting the honest tier for each layer: guards 1-2 are `[enforced]`, orphan detection and team routing are `[hook-driven only]`, the wave digest stays `[advisory]`. The two unconditional hard stops (any `BLOCKED` task, any security rejection) are unchanged and sit underneath all five layers.
- **Config schema v19 → v20.** `migrate_19_to_20` adds `conductor.enforce.{dispatch_guard,rework_guard}` (both default `true`) additively — an explicit kill-switch for either guard, existing values preserved.
- **`docs/loop-engineering.md`** gained a "Mechanical enforcement" section describing the five layers, plus a subsection contrasting Nazgul's durable Conductor with Claude Code's native dynamic Workflow runtime: Workflows are the right tool for one-off, single-session fan-outs (audits, migrations, `/deep-research`-style research), but the Conductor isn't built on them — plugins can't ship a `workflows/` directory, Workflows don't survive a session exit (breaking Nazgul's cross-session recovery), there's no mid-run human input for HITL gates, and the `Workflow` tool is main-session-only (the Conductor is itself a subagent). A "Review Board robustness" follow-up — treating a reviewer's unverified assessment as distinct from a rejection, plus adversarial cross-checking — is noted as deferred future work, not implemented in this release.

## [2.9.0] - 2026-07-08

### Added
- **Opt-in conductor execution engine (FEAT-007).** A new graph-only driver agent (`agents/conductor.md`) offers an alternative to the sequential stop-hook loop for objectives whose plan has independent waves: it reads `nazgul/plan.md`'s dependency graph, computes waves via `scripts/lib/conductor-graph.sh`, and dispatches each wave's tasks through the existing Implementer → Review Board pipeline — no new reviewer logic, and the conductor + its libs never read file bodies or diffs, only paths, scope, one-line verdicts, and commit SHAs (the graph-only invariant, mechanically validated). State lives in `nazgul/conductor/graph.json`, is self-recovering across restarts, and falls back to the checkpoint if the graph file is missing or invalid.
- **`conductor.gates` — autonomous-first, opt-in approval checkpoints, plus two unconditional hard stops.** `conductor.gates.{approve_graph,approve_each_wave,approve_final_pr}` (all default `false`) let a human pause the conductor before dispatch, before each wave, or before the final PR; `scripts/lib/conductor-gates.sh` evaluates them. Independent of any gate setting or `mode` (including `yolo`), the conductor always halts for a human on a `BLOCKED` task or a security rejection — the same two hard stops the sequential engine enforces, now covered under conductor mode too.
- **`conductor.max_parallel`** (default `3`) caps how many tasks in a wave the conductor dispatches concurrently, evaluated by `scripts/lib/conductor-router.sh`, which also selects the dispatch backend (subagent, Agent Team, or worktree) per task.
- **`/nazgul:start --conductor`** opts a run into the new engine. It sets `execution.engine: "conductor"` orthogonally to `--afk`/`--hitl`/`--yolo` (composable, no interaction with `set_mode`) and is a pure no-op when omitted — `execution.engine` stays `"sequential"`, the existing default. `skills/start/SKILL.md` gained an "Engine Selection" section plus a dispatch gate at each of the four resume states.
- **`docs/loop-engineering.md`** documents the conductor architecture: graph model, wave computation, gates, hard stops, and recovery.
- **Config schema v18 → v19.** `migrate_18_to_19` adds `execution.engine` (default `"sequential"`) and `conductor.gates.{approve_graph,approve_each_wave,approve_final_pr}` (default `false`) and `conductor.max_parallel` (default `3`) additively.

Sequential remains the default engine — zero behavior change for existing runs; no task in this objective edited `scripts/stop-hook.sh` or other sequential-path code.

### Fixed
- **`task-state-guard.sh` multi-line `old_string` (macOS/BSD awk).** The guard reconstructed an Edit's `old_string` via `awk -v old=...`, which throws `awk: newline in string` on BSD awk whenever the value spans multiple lines (e.g. the `---`/`status:`/`---` frontmatter block) — silently no-opping the state-transition check. It now passes the value via `ENVIRON[...]`, portable on GNU and BSD awk; validation semantics are unchanged.
- **Transient-artifact hygiene on new plans.** `/nazgul:plan` previously proceeded past a *completed* prior objective without clearing its `nazgul/reviews/` and `nazgul/learning/proposed-rules.md`, so a new objective could read the prior one's review verdicts and learner proposals as current. A new `scripts/scrub-stale-review-artifacts.sh` (archive-then-clear, `mv`-only, guarded to no-op while any task is active, `feat_id` path-sanitized) is now invoked by `/nazgul:plan` before task generation, and the learner overwrites (never appends) `proposed-rules.md` scoped to the current objective.

## [2.8.0] - 2026-07-07

### Added
- **Review provenance — diff-bound tamper-evidence for the DONE gate (FEAT-006, Gap A).** The only mechanical DONE gate (`validate_review_evidence`) checked the SHAPE of reviewer files, not whether they came from the review board or were run against the current diff. `review-gate` now writes a per-unit dispatch manifest (`nazgul/reviews/<unit>/.dispatch.json`, `write_dispatch_manifest` in `scripts/lib/review-provenance.sh`) BEFORE spawning reviewers — capturing a nonce, a `diff.patch` hash, and a review token — and **stamps** the matching `review_token:` into the frontmatter it authors when it persists each read-only reviewer's return (the reviewer never echoes its own token). A new `validate_review_provenance` (`scripts/lib/review-provenance.sh`, wired into `scripts/stop-hook.sh`) blocks completion when a review has no matching dispatch manifest, or when the manifest's `diff_hash` no longer matches HEAD (`DIFF_HASH_STALE`) — routed through the existing bounded reset→`IMPLEMENTED`→`BLOCKED` escalation. **Honest tier: tamper-evidence + staleness detection, not authentication** — the verifier and the orchestrator share the filesystem, so its value is catching accidental cases (board skipped, code changed after approval), not adversarial forgery. Default-on (`review_gate.require_provenance`), degrades to allow for legacy no-token reviews.
- **`comment-verifier` — inline doc-comment quality gate (FEAT-006, Gap B).** No gate previously inspected inline source doc-comments (XML `<summary>`, JSDoc, docstrings); reviewers could only flag them as sub-80 non-blocking concerns. A new language-generic `agents/comment-verifier.md` post-loop agent grades doc-comments changed this objective for templated, restatement, and contradiction defects and writes an objective-scoped completion marker; `scripts/stop-hook.sh` now blocks `NAZGUL_COMPLETE` until that marker matches (mirroring the FEAT-004 `doc-verifier` gate). Default-on (`docs.verify_comments`), bounded to 3 attempts, degrades to allow.
- **Diff-aware conditional reviewer dispatch, opt-in (FEAT-006, Gap C, Lever 3).** A new deterministic `scripts/lib/reviewer-selection.sh select` picks reviewers by changed-file scope instead of always running the full board: `security-reviewer` always runs; `architect-reviewer` only when the scope touches `skills/`, `agents/`, `scripts/`, `hooks/`, or the config schema; `qa-reviewer` only when `tests/` changed; `code-reviewer` on any non-doc change; any ambiguity falls back to the full board. `SKIPPED` is now a first-class verdict (`scripts/lib/structured-state.sh`); `review-gate` writes a `verdict: SKIPPED` stub with a reason for each skipped reviewer and emits `reviewer_skipped`, and `validate_review_evidence` treats an authorized SKIPPED stub as gate-satisfying while still hard-failing MISSING/UNAPPROVED. Gated behind `review_gate.conditional_dispatch` (default `false`, mirroring `simplify_before_review`).

### Changed
- **Review cost redesign (FEAT-006, Gap C, Levers 1-2).** Reviewers now receive `diff.patch` only by default — the blanket full-file-list grant in review-gate Step 2 is gone, and the code-reviewer's "read full files for any non-trivial change" override (`agents/templates/reviewer-domains.json`) is replaced by the disciplined rule in `agents/templates/reviewer-domains.json`: read a full file only when a hunk is truncated mid-function, never crawl the codebase, never re-run tests. The `learned-rules.sh select` injection is now capped (top-N by recurrence within a token budget) instead of unbounded. `models.review` now defaults to `haiku` for the mechanical reviewers (code, qa) — applied additively and only when still absent or at the old `sonnet` default; `security-reviewer` and `architect-reviewer` are pinned to `sonnet` via a new `models.review_by_reviewer` map read in review-gate Step 2.
- **`review_gate.require_all_approve` reclassified as informational.** It was already dead — no script reads it; the effective policy is the hard-coded "every non-skipped reviewer must APPROVE" loop in `scripts/lib/review-evidence.sh`. The key still documents that policy for humans but changing it has no effect.
- **Config schema v17 → v18.** `migrate_17_to_18` adds `review_gate.require_provenance` (default `true`), `review_gate.conditional_dispatch` (default `false`), `docs.verify_comments` (default `true`), and `models.review_by_reviewer` (`{"security-reviewer": "sonnet", "architect-reviewer": "sonnet"}`) additively — existing values are preserved.

## [2.7.1] - 2026-06-25

### Fixed
- **Guard precision — no more false-positive blocks on read-only commands and commit messages (FEAT-005).** The two Bash-matched PreToolUse guards matched command *substrings* instead of the real action, so legitimate commands were blocked:
  - `local-mode-tracking-guard.sh` blocked any command containing `git add`/`stage`/`commit` and the literal `nazgul/` anywhere — including a commit whose **message** mentioned `nazgul/`, a **multiline** message, or even a read-only command whose grep *pattern* contained those tokens. It now parses the actual git **pathspec** with a no-`eval` tokenizer (skipping the subcommand and the values of message flags like `-m`/`-F`) and blocks only when a real `nazgul/` path is being staged in local mode.
  - `pre-tool-guard.sh` blocked any command where `echo`/`printf` co-occurred with `Status` and a `nazgul/tasks/TASK-` path — even a read-only `echo …; grep nazgul/tasks/TASK-*.md`. It now blocks only on an actual redirect (`>`, `>>`, the noclobber-override `>|`/`>>|`, and the combined `&>`/`&>>`) writing **into** a task manifest.
  - The Write/Edit-matched guards (`task-state-guard.sh`, `lean-comments-guard.sh`) were audited and are structurally immune (they inspect the tool's JSON input, not command strings) — recorded in RULES.md.
  No safety regression: every genuine block still blocks (verified by retained + new BLOCK tests alongside the new ALLOW false-positive tests).
- **`pre-tool-guard.sh` now reads the command from the PreToolUse JSON envelope.** The echo/printf manifest-write check tokenized raw stdin — which in production is `{"tool_input":{"command":"…"}}` JSON, so the command sat inside JSON quotes and the check never fired outside the (raw-command) test harness. The guard now extracts `.tool_input.command` (falling back to raw input for the test path, matching `local-mode-tracking-guard.sh`), and a new JSON-envelope test locks in the production contract.
- **Both Bash-matched guards harden their no-`eval` tokenizers against realistic shell forms** (surfaced by PR review): compound commands (`;`, `&&`, `||`, `|`) and unquoted newlines reset per-segment state so a later segment can't be skipped; redirect targets are reconstructed from adjacent quoted+unquoted fragments (`> "nazgul/tasks/"TASK-001.md`) and resolved before the command word (leading redirects); git global options (`-C`, `-c`, `--work-tree=`, `-p`, …) and leading `VAR=value` env assignments are skipped before the subcommand; backslash-escaped quotes inside double-quoted spans don't desync quote state; and fd-numbered/combined redirects (`1>`, `2>`, `2>&1`, `>&2`, `&>`) are handled rather than mistaken for command separators or command words. Genuinely exotic forms (process substitution, `eval`, command substitution, nested subshells) remain out of scope by design and degrade to allow — the primary protection is `.gitignore` + the session-staging chokepoint.

## [2.7.0] - 2026-06-24

### Added
- **Post-loop doc-accuracy verifier gate (FEAT-004).** A new read-only `doc-verifier` agent cross-checks the generated docs and CHANGELOG against the source — every event type, config key, command/skill, named script, and schema version a doc references must actually exist in the codebase. On a clean pass it writes an objective-scoped marker (`nazgul/logs/.docs-verified`), and the stop-hook now **blocks `NAZGUL_COMPLETE` until that marker matches the active objective** — catching invented facts (e.g. the kind of hallucinated CHANGELOG event names this project previously shipped) before release instead of relying on an external reviewer. Bounded backstop (≤3 attempts) so it can never deadlock an unattended loop; opt-out `docs.verify_post_loop` (default `true`) makes it a clean no-op. Wired into the post-loop sequence after documentation/release. Schema 16 → 17.

### Changed
- **Better defaults (FEAT-004), applied additively and only when still at the old default (hand-set values are preserved):**
  - `review_gate.granularity`: `task` → **`group`** — per-task review boards were the expensive default; group review matches how waves already run.
  - `models.post_loop`: `haiku` → **`sonnet`** — the cheap post-loop model shipped invented documentation facts; the new doc-verifier gate plus a stronger model close that gap.
  - `parallelism.wave_execution`: now defaults **`true`** — real parallel waves are safe now that the FEAT-003 granularity completion-gate backstops wrong-granularity reviews.
  - Unchanged (they behaved correctly): `confidence_threshold` (80), `require_all_approve`, `auto_approve_concerns`, `default_mode` (null), `formatter` (off).
- **Honest RULES.md.** Documentation accuracy is now recorded as `[enforced]` (via the post-loop verifier gate).

## [2.6.0] - 2026-06-24

### Added
- **Granularity completion-gate enforcement (FEAT-003).** `review_gate.granularity` is now enforced even when a human or orchestrator dispatches reviews directly (bypassing stop-hook sequencing). A `SubagentStop` detector records the review unit each review-gate actually covered into `nazgul/logs/review-coverage.jsonl` (a derived index of existing `reviewer_verdict` telemetry events, not a new state store), and the stop-hook reconciliation gate blocks (or warns) `NAZGUL_COMPLETE` when a DONE task was reviewed at the wrong granularity — with a bounded backstop so it can never deadlock an unattended loop. New config knob `review_gate.enforce_granularity` (`"block"` default, `"warn"` alternative). Subagent dispatch can't be pre-gated (no PreToolUse matcher for the Task tool), so enforcement lives at the completion gate.

### Fixed
- **State machine is now actually enforced (FEAT-003).** `task-state-guard.sh` rejected only a narrow set of transitions: a full-manifest Write whose `status:` lives in YAML frontmatter matched none of its extractors and fell through to allow — so forbidden jumps like `IN_PROGRESS → DONE` and `PLANNED → DONE` (which RULES.md §2 declares forbidden) silently passed. Added frontmatter + bare-token status extractors and per-state exit-2 messages naming the allowed next state(s); every forbidden transition is now blocked at the tool call. Also restored the missing `BLOCKED` transition arms in the allowlist.
- **Local-mode guard no longer false-blocks on commit messages.** `local-mode-tracking-guard.sh` grepped the whole command for `nazgul/`, so a `git commit -m "… nazgul/ …"` whose message merely mentioned a `nazgul/` path was wrongly blocked even when no nazgul path was staged. The guard now strips quoted segments (the message) before looking for a `nazgul/` pathspec.
- **Reviewer persistence — no more "missing review file" re-dispatch waste.** Reviewers were instructed to write their review to a file but had no `Write` tool, so they often returned the review as text and wrote nothing — forcing the review board to re-dispatch reviewers (full re-runs) or scrape output. Reviewers are now strictly read-only (`Read`/`Glob`/`Grep` — no `Write`, **no `Bash`**) and **return** their review; the review-gate orchestrator persists each returned review to `nazgul/reviews/`. Removing `Bash` also stops reviewers re-running the test suite (a major time sink) and makes "reviewers are read-only" genuinely tool-enforced. The generated reviewers were regenerated (`maxTurns` 30 → 12) and the SubagentStop file-write hook removed.

### Changed
- **Config schema 15 → 16.** `migrate_15_to_16` adds `review_gate.enforce_granularity` (additive, idempotent).
- **Honest RULES.md.** The state-machine rule (§2) and the new granularity rule (§3) are documented as genuinely `[enforced]`, with the manual-dispatch-bypass caveat made explicit.

## [2.5.0] - 2026-06-24

### Added
- **Mechanical mutation guards (FEAT-002).** Three PreToolUse guards turn rules that were prose-only into enforced invariants: `local-mode-tracking-guard.sh` blocks `git add`/`stage`/`commit` of `nazgul/` paths when `install_mode` is `"local"` (closes the runtime-state leak that put loop files into a PR); `base-branch-commit-guard.sh` blocks a `git commit` to the base branch while a feature branch is active; and `task-state-guard.sh` now blocks implementer Write/Edit outside the active task's `file_scope` (anchored path matching, `nazgul/`+`docs/` exempt). The `session-staging.sh` auto-stage is gated on `install_mode` so local-mode loops no longer track `nazgul/`.
- **Honest RULES.md.** Every rule is annotated with its real enforcement tier — `[enforced]`, `[hook-driven only]`, or `[advisory]` — with a legend. RULES.md no longer claims enforcement it doesn't have.

### Changed
- **Faster, leaner review board (~3–4×).** Reviewers are now spawned concurrently in a single message (was effectively serial); the pre-review Simplifier pass is opt-in via `review_gate.simplify_before_review` (default false; post-loop simplify already covers cleanup); reviewers no longer re-run the full test suite (pre-checks ran it once); `maxTurns` lowered (orchestrator 60→40, reviewers 30→15); `security-reviewer` pinned to `sonnet` while other reviewers honor `models.review` (set it to `haiku` to cut cost).
- **Config schema 14 → 15.** `migrate_14_to_15` adds `review_gate.simplify_before_review` (additive, idempotent, boolean-clamped).

## [2.4.0] - 2026-06-24

### Added
- **Loop Telemetry Bus — canonical `nazgul/logs/events.jsonl` event stream (FEAT-001).** Replaces the four scattered telemetry stores (iteration journal, subagent log, in-place budget estimate, compaction dotfile) with a single schema-versioned, append-only stream. 10 event types: `iteration_boundary`, `task_completed`, `reviewer_verdict`, `retry`, `blocked`, `compaction`, `subagent_stop`, `stop_failure`, `budget_threshold`, `objective_complete`. Reviewer verdicts, retries, and blocks are now first-class events (not inferrable only from task manifests).
- **5 producer hooks wired to `emit_event`.** `stop-hook.sh`, `task-completed.sh`, `subagent-stop.sh`, `stop-failure.sh`, and `post-compact.sh` now call `scripts/lib/emit-event.sh` — legacy `iterations.jsonl` / `subagents.jsonl` appends removed; those files freeze in place as historical records.
- **Review-gate agent emits `reviewer_verdict` / `retry` / `blocked`.** `agents/review-gate.md` calls `emit-event-cli.sh` at each verdict, CHANGES_REQUESTED retry, and BLOCKED escalation — fulfilling the CONCERN-1 mitigation from the architect review.
- **`/nazgul:metrics` and `/nazgul:log` dual-read the unified stream.** Both consumer skills prefer `events.jsonl` and fall back permanently to frozen legacy files (`iterations.jsonl` / `subagents.jsonl`) for pre-upgrade history — no cutover, no data loss.
- **`telemetry.bus_enabled` kill switch.** Set `telemetry.bus_enabled: false` to suppress all `emit_event` calls without touching hook scripts. `telemetry.record_metered_cost` (default `false`) is reserved for future metered-cost recording.
- **Concurrency-safe append with macOS fallback.** `scripts/lib/emit-event.sh` serialises concurrent writers with `flock` when available; on stock macOS (no `/usr/bin/flock`) it falls back to a best-effort direct append relying on `O_APPEND` atomicity for the short JSONL lines. Three concurrent emitters produce no interleaved JSON lines. Emits are best-effort — a write failure never aborts the calling hook.

### Changed
- **Config schema v13 → v14.** `migrate_13_to_14` adds a `telemetry` block (`bus_enabled: true`, `record_metered_cost: false`) additively — existing keys survive, and `bus_enabled: false` opt-outs are never overwritten. `templates/config.json` updated to v14.
- **`nazgul/logs/` gitignored (shared install mode).** The event stream is an ephemeral runtime artifact, not a decision record.

## [2.3.0] - 2026-06-24

### Added
- **Post-loop learning gate — distilling Learned Rules is now mandatory, not advisory.** Previously the learner ran only because the `/nazgul:start` OBJECTIVE_COMPLETE prose asked for it (config `learning.auto_distill_post_loop`), so it silently got skipped and no candidate rules were ever proposed. `stop-hook.sh` now **gates loop completion** on it: when all tasks are DONE (or APPROVED/DONE in YOLO) but the learner has not run for the current objective, the stop is blocked with a `DELEGATE: spawn nazgul:learner` instruction (mirroring the review-board dispatch). The learner records completion by writing the objective id (`feat_id`) to `nazgul/learning/.distilled`; the loop reaches `NAZGUL_COMPLETE` only once that marker matches. The marker is keyed to the objective, so a new objective re-triggers distillation. Honors the existing opt-out — a no-op when `learning.enabled` or `learning.auto_distill_post_loop` is `false`. A bounded attempt counter (`nazgul/learning/.distill-attempts`, scoped per objective) lets the loop complete with a loud warning after 3 attempts, so an unwritable marker can never brick an unattended loop (this exit path precedes the max-iteration backstop).

### Changed
- `agents/learner.md` now writes the `.distilled` completion marker as its final step (always, even on a clean no-rules run). `skills/start/SKILL.md` OBJECTIVE_COMPLETE documents the gate. New `tests/test-stop-hook.sh` coverage: gate blocks when undistilled, allows when the marker matches, re-gates a new objective with a stale marker, honors the opt-out, and the attempt backstop completes.

## [2.2.0] - 2026-06-24

### Added
- **Lean-comments guard — comment bloat is now mechanically blocked, not just discouraged.** A new deterministic guard (`scripts/lean-comments-guard.sh`) is wired into the plugin hooks as a `PreToolUse` matcher on `Write|Edit|MultiEdit` (alongside `task-state-guard`), and is also runnable as a pre-commit-style check (`scripts/lean-comments-guard.sh --check <files>`) that the implementer and simplifier run before review. It inspects source content (C#, TS/JS, Python, and other `//`/`#` languages; shell and config formats are intentionally exempt) and BLOCKS the write when a change introduces any of:
  - a run of 3+ consecutive line comments that is not a license header;
  - a `<remarks>`/multi-paragraph doc block on a private/internal/protected or test member;
  - a banner/separator comment (`// ── Helpers ──────`, `// =======`);
  - a comment that restates or narrates the next line of code (incl. micro-optimization noise).

  Full XML/JSDoc/docstring on PUBLIC interface members is expected (`<inheritdoc/>` on implementations), and a single short domain/venue-quirk comment is allowed. The block message names the file and offending comment and instructs the author to cut it to a one-line note or delete it. Tunable and fully opt-out-able via `guards.lean_comments` (default `true`) and `guards.max_consecutive_comment_lines` (default `2`) — when `lean_comments` is `false` the guard is a no-op, so existing projects can opt out without breaking.

- **Enforced three ways (defense in depth).** Previously the "lean comments" rule lived only as advisory prose and the review gate downgraded comment bloat to a low-confidence CONCERN that `auto_approve_concerns` waved through. Now: (1) the hook blocks the write; (2) the **code reviewer** treats comment bloat as an ALWAYS-BLOCKING finding reported at confidence >= the gate threshold (never a sub-threshold CONCERN), with explicit bad-vs-good examples — propagated to every project via `agents/templates/reviewer-domains.json` and the reviewer base template; (3) the **implementer** and **simplifier** agents carry an upfront comment-discipline rule with the same examples and run the `--check` pass before review.

### Changed
- **Schema version 12 → 13.** Added `guards.lean_comments` (default `true`) and `guards.max_consecutive_comment_lines` (default `2`). `migrate_12_to_13` sets them additively only when absent — an existing opt-out (`lean_comments: false`) or tuned threshold survives, and a non-object `guards` is clamped to `{}` first. `templates/config.json`, `scripts/migrate-config.sh`, `hooks/hooks.json`, `agents/implementer.md`, `agents/simplifier.md`, `agents/templates/reviewer-base.md`, `agents/templates/reviewer-domains.json`, `RULES.md`, `templates/CLAUDE.md.template`, and `docs/CONFIGURATION.md` updated. New `tests/test-lean-comments-guard.sh` (19 assertions covering each bad/good/allowed example, opt-out, threshold tuning, and hook mode); migration + schema coverage added to `tests/test-migrate-config.sh` and `tests/test-config-schema.sh`; the new script is registered in `tests/test-shellcheck.sh`.

## [2.1.0] - 2026-06-22

### Added
- **Configurable review granularity (`review_gate.granularity`).** New knob with three values controlling how often the review board runs and what diff it reviews:
  - `task` (default — unchanged behavior): the review board fires per task the moment it reaches IMPLEMENTED, reviewing that task's diff.
  - `group`: the board fires once per planner-defined parallel wave/group, after every task in the group is IMPLEMENTED, reviewing the group's combined diff.
  - `feature`: ALL feature tasks advance to IMPLEMENTED, then ONE review board pass covers the cumulative feature diff (`base..HEAD`).

  Backward-compatible — the default is `task`, so existing projects are unchanged. In `group`/`feature` mode tasks are parked at IMPLEMENTED ("awaiting aggregate review") while the rest of the unit is built; an explicit recovery marker in `plan.md` and the iteration checkpoint (`review_unit` block) means parked tasks survive compaction without being re-reviewed or re-implemented. A CHANGES_REQUESTED re-opens only the tasks whose files own the findings (attributed by the feedback aggregator via file scope) — not the whole group/feature. `require_all_approve`, `confidence_threshold`, and `block_on_security_reject` apply identically in all modes; `max_retries_per_task` is interpreted per review unit (task/group/feature). Configurable via `/nazgul:config` → "Review granularity".

### Changed
- **Schema version 11 → 12.** Added `review_gate.granularity` (default `"task"`). `migrate_11_to_12` sets it additively only when absent — an existing `"group"`/`"feature"` (or any hand-set) value is never overwritten, and all other `review_gate` fields are preserved. `templates/config.json`, `scripts/migrate-config.sh`, `agents/review-gate.md`, `agents/feedback-aggregator.md`, `skills/config/SKILL.md`, and `docs/CONFIGURATION.md` updated. State-machine coverage for all three granularities added to `tests/test-stop-hook.sh`; migration coverage (default + existing-value survival) added to `tests/test-migrate-config.sh`.

## [2.0.4] - 2026-06-22

### Fixed
- **Config migration no longer destroys discovery-owned state.** `migrate_4_to_5` deleted `documents.existing` and `discovery.files_scanned`/`existing_docs_count`/`existing_docs_quality` as "unused" — but these are live fields written by `agents/discovery.md` Step 8 and read downstream. Any v<5 → v5 force-march (including an unversioned modern config, treated as v1) silently wiped a project's discovery state. Those fields are now preserved; only genuinely retired fields are removed.
- **`migrate_2_to_3` no longer clobbers an existing branch section.** It assigned `.branch = { … }` wholesale, so an unversioned modern config (live `branch.feature`, no `schema_version` → migrated from v1) lost its branch isolation state on session start. The branch section is now filled non-destructively — each field is added only when absent, so an existing feature/base/worktree config survives the chain.
- **Pause now sticks.** `stop-hook.sh` cleared the `paused` flag on the first Stop, so `/nazgul:pause` only held for one iteration before the loop self-resumed. Pause is now sticky: the stop hook leaves `paused: true` and allows the stop on every iteration; only `/nazgul:start` clears it (in the mandatory Reset Loop Counters step), making resume an explicit, consented action.

### Changed
- **`agents/discovery.md` Step 8 now mandates a `jq` merge.** Discovery must update `config.json` field-by-field (preserving `schema_version` and all runtime state) rather than rewriting the object, so it can never reset the schema version or clobber loop/branch/budget/pause state.

## [2.0.3] - 2026-06-21

### Fixed
- **Stop/pre-compact hooks no longer abort on a single-commit (greenfield) repo.** `stop-hook.sh` and `pre-compact.sh` built the checkpoint's `files_modified` with `git diff … HEAD~1 … | jq … || echo "[]"`. In a fresh repo `HEAD~1` doesn't exist, so git exits non-zero; under `set -o pipefail` the `|| echo "[]"` fired *after* jq had already printed `[]`, producing `[]\n[]` (two JSON values) → `jq: invalid JSON text passed to --argjson` → the hook aborted before writing its checkpoint, and recurred on every Stop until the repo had ≥2 commits. Extracted a robust `files_modified_json` helper (`scripts/lib/git-utils.sh`) that resolves base→HEAD (valid base → `base..HEAD`; else `HEAD~1..HEAD`; else first-commit empty-tree diff; else `[]`) and always emits exactly one valid JSON array. Both hooks now use it. Added `tests/test-git-utils.sh` (incl. the single-commit regression).

## [2.0.2] - 2026-06-19

### Fixed
- **Shared-mode gitignore now excludes `nazgul/reviews/*/diff.patch`.** The review-gate writes a point-in-time captured diff to `nazgul/reviews/<task>/diff.patch` for reviewers to read first. In shared install mode that file was being committed (unlike the already-ignored `test-failures.md` / `simplify-report.md`), so a later review could read a **stale** diff and emit phantom findings against code that had since changed. `/nazgul:init` now adds `nazgul/reviews/*/diff.patch` to the ephemeral-runtime ignore block, and its reinitialization "stop tracking" one-shot includes it for projects that already committed one.

## [2.0.1] - 2026-06-19

### Changed
- **YOLO permission gate recommends `--permission-mode auto`.** `/nazgul:start`'s YOLO pre-flight now treats either `--permission-mode auto` (recommended — autonomous with a background safety classifier that still blocks dangerous actions like `curl|bash`, force-push to main, prod deploys) or `--dangerously-skip-permissions` (blunt bypass; sandbox only) as a valid non-prompting mode. The probe is unchanged (both modes skip routine prompts; there is no API to read the active mode), but the restart guidance now leads with `auto`. Per the current Claude Code docs, `--dangerously-skip-permissions` is still supported (≡ `--permission-mode bypassPermissions`) but `auto` is the recommended path for unattended runs.

## [2.0.0] - 2026-06-19

### Added
- **`/nazgul:plan` — native brainstorm → spec → tasks.** Interactive design front-end that turns a new idea/objective into a per-idea spec (`nazgul/context/objectives/<feat-id>-spec.md`) and a ready-to-run task plan (reusing the existing discovery/doc-generator/planner agents), then offers to run it. Mirrors the Superpowers brainstorm→plan flow but produces native Nazgul artifacts. `/nazgul:plan` owns objective identity (computes `feat_id`, appends `objectives_history`, sets `afk.commit_prefix`); `/nazgul:start` reuses that identity rather than recomputing it.
- **`config.default_mode`** (schema 11) — set a preferred run mode (`hitl`/`afk`/`yolo`) so `/nazgul:start` doesn't prompt; settable via `/nazgul:config`. Type-guarded `migrate_10_to_11`.
- `doc-generator` reads the active objective's per-idea spec as the PRIMARY source for that objective's docs.

### Changed (BREAKING)
- **`/nazgul:start` no longer runs non-interactively by default.** With no mode flag it now resolves the run mode as: explicit flag > `config.default_mode` > an interactive HITL/AFK/YOLO prompt (with "save as default?"). Existing flag usage (`--yolo`/`--afk`/`--hitl`) is unchanged; the change affects the no-flag default.
- **`/nazgul:start` lost its `disable-model-invocation` guard and `context: fork`.** It is now model-invocable and interactive, so `/nazgul:plan` can hand off to it and "start nazgul" in natural language no longer errors. The new safety gate is the mode prompt — **YOLO is always confirmed**, on every path including an explicit `--yolo` flag.

## [1.6.2] - 2026-06-18

### Changed
- **Release flow now publishes a GitHub Release for every tag.** The release-manager agent gained an explicit step to run `gh release create vX.Y.Z --notes-file … --verify-tag --latest` after tagging (gated on a GitHub remote + authenticated `gh`), plus a matching authority-scope entry and rule. This keeps the GitHub Releases page in sync with the git tags — previously tags could be pushed without a corresponding Release (v1.6.0/v1.6.1 had to be backfilled).

## [1.6.1] - 2026-06-18

### Fixed
- **Interactive skills can now actually prompt you.** The skills that use `AskUserQuestion` for multiple-choice prompts (`init`, `config`, `gen-spec`, `board`, `reset`, `clean`, `bootstrap-project`) ran with `context: fork` — a forked subagent has no interactive channel, so `AskUserQuestion` was unavailable in that environment and they silently degraded to printing options as plain text (which can't capture your reply). Removed `context: fork` from these seven skills so they run in the main loop where `AskUserQuestion` is available. (The ToolSearch pre-load they already do was correct; the fork was the blocker.) Mechanical/non-interactive skills keep `context: fork` for context isolation.

## [1.6.0] - 2026-06-18

### Added
- **Autolearning — Nazgul learns from its own recurring mistakes.** A new `learner` agent mines recurring review rejections, debugger diagnoses, and repeated test failures (read from existing on-disk artifacts — no new runtime hooks) and distills them into candidate **Learned Rules**. Rules are **human-gated**: proposed to `nazgul/learning/proposed-rules.md`, then approved/edited/rejected interactively via the new `/nazgul:learn` skill (also supports `--dry-run` and `--retire`). Approved rules get a stable, monotonic `LR-NNN` number and live in `nazgul/learning/learned-rules.md` (committed in shared install mode; tracked so an external AI code reviewer can be pointed at it).
- **Scoped, dispatch-time rule injection.** Each rule declares `Scope-Agents` + `Scope-Globs`; `scripts/lib/learned-rules.sh select` returns only the rules matching a given agent + the files in scope, injected into that agent's dispatch prompt (the registry can grow without bloating any one agent's context). Reviewers cite applicable rules via a new `Rule reference: LR-NNN` finding field, and each citation bumps the rule's hit counter (feeding retirement of un-cited rules).
- **Post-loop auto-distill** (config `learning.auto_distill_post_loop`, default on): the learner runs at objective completion and proposes (never approves) candidate rules for later review.
- **`/nazgul:metrics` Learning section** — active/retired rule counts, total citations, and top-cited rules.
- **Config schema 10** — new `learning` block (`enabled`, `rules_doc`, `min_recurrence`, `max_active_rules`, `auto_distill_post_loop`) with type-guarded `migrate_9_to_10`.

## [1.5.2] - 2026-06-17

### Fixed
- **`/nazgul:start` flags now take effect on every path.** `--yolo` previously set `afk.*` but never `mode`, so mode-gated branches (the objective menu, doc/plan-review pauses) ran as **HITL** under `--yolo`; `--max N` was documented but **never written** to `max_iterations` (silently ignored); `--afk`/`--hitl` were only applied in the ACTIVE_LOOP state; `--task-pr` was honored only with `--yolo`. Flag→config application is now centralized in a single tested helper (`scripts/apply-start-flags.sh`) that `start` calls in a mandatory step on every path — persisting `mode`/`afk.enabled`/`afk.yolo`/`afk.task_pr`/`max_iterations` before state detection. `--hitl` wins over `--afk`/`--yolo` (and clears the autonomous sub-flags); `--max 0`/non-numeric is ignored as a no-op (leaves `max_iterations` unchanged, so it can't brick the loop).
- **Other skills now honor documented args they previously ignored:** `/nazgul:simplify <focus>` (narrows the pass), `/nazgul:metrics reviews` (shows only reviewer stats), `/nazgul:context <type>` (selects the context section; reads `.project.classification` when no arg). `/nazgul:patch` now reads its `--no-review`/`--discuss` decision back from the manifest `## Flags` line (file-truth, compaction-safe) with an `$ARGUMENTS`-substitution backstop.

### Added
- `tests/test-start-flags.sh` — exhaustive unit tests of the flag helper (every flag, combos, precedence, `--max 0`/non-numeric, missing config). **This is the test that would have caught the `--yolo`/`--max` bugs.**
- `tests/test-skill-arguments.sh` extended with a contract check: every `--flag` documented in a skill's `argument-hint` must be referenced in its body (or handled by the helper) — catches the "documented but never handled" class going forward.

## [1.5.1] - 2026-06-17

### Added
- `/nazgul:metrics` now reports **estimated cost** and **subagent activity** (roadmap 2.3). The Cost section surfaces the budget governor's cumulative estimate (`spent_usd`, % of ceiling, cost per task/iteration) — clearly labeled an *estimate* (≈ iterations × per-tier rate, not metered spend; resets per objective). The Subagent Activity section shows total runs + per-agent-type counts from `nazgul/logs/subagents.jsonl`. Both degrade gracefully (governor disabled → "not tracked"; no subagent log → "no data yet"). Read-only, no schema change.

### Note
- Closes the planned enhancement roadmap. **Roadmap 2.2 (`Monitor` tool) was dropped** after research: its "replace bash poll-loops" premise didn't hold (Monitor is for streaming/repeated events, not "wait-for-completion"; Nazgul's test/build run synchronously), and the only substantive fit — long-running e2e smoke — was judged too risky (starts/tears down real processes in an unattended loop) for its value.

## [1.5.0] - 2026-06-17

### Added
- **Runtime-verification gate** (roadmap 2.1, start of Phase 2 "Verification & Observability"). The review gate's pre-checks now run `build_command` as a **hard gate** — previously it was read but never executed, so a task could pass review and reach DONE with code that doesn't build. A new opt-in `project.smoke_command` runs the built artifact as a short, self-terminating check (e.g. `node dist/index.js --version`, an import-smoke, a healthcheck). Pre-check order is test → lint → build → smoke (stop at first failure); build/smoke failures route through the existing IN_PROGRESS→BLOCKED retry path (captured in the task manifest and, on escalation, `test-failures.md`). Discovery suggests a smoke command. Config schema 8→9.
- Scope note: this is **not** full end-to-end verification — the smoke command is short and self-terminating; orchestrating long-running processes (servers, browsers) is deferred to the Monitor item (2.2). `smoke_command: null` ⇒ runtime smoke skipped (libraries/docs unaffected).

## [1.4.2] - 2026-06-17

### Changed
- Checkpoint retention reduced from 10 to 2 per run (roadmap 1.4.3). Recovery only ever reads the latest checkpoint, so the extra 8 were pure per-run churn; one extra is kept for diff-base safety. The diagnostic reports (`test-failures.md`/`simplify-report.md`) are intentionally kept — they're conditional human diagnostics already gitignored in shared mode.
- The AFK-timeout clock now uses `objective_set_at` as its **primary** source (oldest-checkpoint timestamp only as fallback) — more accurate (true objective start) and independent of checkpoint pruning.
- `/nazgul:metrics` and `/nazgul:log` now source iteration history (total iterations, time span, timeline) from the durable, never-pruned `nazgul/logs/iterations.jsonl` rather than the now-retention-limited checkpoint files, so reducing checkpoint retention doesn't regress those views.

## [1.4.1] - 2026-06-16

### Added
- **Cost/budget governor for AFK/YOLO loops** (roadmap 1.4.2, default disabled). When `budget.enabled` and `budget.max_usd` are set, the Stop hook accumulates an estimated per-iteration cost into `budget.spent_usd` and stops the loop once the ceiling is reached — a dollar-denominated, model-aware ceiling alongside `max_iterations` / `afk.timeout_minutes`. The per-iteration cost is `budget.per_iteration_usd` if set, else derived from `budget.model_iteration_cost[models.implementation]` (so a cheaper implementation tier buys more iterations per dollar). `est_iteration_usd` + `budget_spent_usd` are recorded into each checkpoint; `/nazgul:start` resets the accumulator on every loop-start path. Config schema 7→8.
- This is an **estimate** (≈ iterations × configured per-tier rate), a deterministic ceiling — **not** metered spend. Subagent tokens are modeled into the rate, not measured (subagents run in separate transcripts the Stop hook can't meter). Tune `budget.model_iteration_cost` per project. Non-numeric hand-edited values coerce to a safe default rather than aborting the loop.

## [1.4.0] - 2026-06-16

### Changed
- Review verdicts and task status are now read from a canonical YAML frontmatter block via a single shared parser (`scripts/lib/structured-state.sh`), replacing the regex/awk sniffing in `review-evidence.sh` and `task-utils.sh`. Verdicts validate against a fixed enum (`APPROVE`|`CHANGES_REQUESTED`) and task status against the state-machine enum; a malformed block now fails **loudly** (surfaces as `UNAPPROVED` / a blocked transition) instead of silently mis-reading. This retires the parsing-drift bug class behind the 1.3.0, 1.3.2, and #17 review-gate livelocks. Existing files keep working via an absent→legacy fallback (no forced migration). Roadmap item 1.4.1.
- Reviewer agents (`reviewer-base.md`) now write a `verdict:`/`confidence:` frontmatter block at the top of their review file; task manifests carry a canonical `status:` frontmatter block (the `- **Status**:` line is now a display mirror).

### Added
- `scripts/lib/structured-state.sh` — frontmatter parser with enum validation, CRLF tolerance, quoted-scalar handling, an idempotent source guard, and a `set -e`-safe contract.
- `tests/test-structured-state.sh`; regression cases in `test-review-evidence.sh`/`test-task-utils.sh` pinning the historical livelocks and the structured/legacy/INVALID paths.

## [1.3.5] - 2026-06-16

### Changed
- **Shared install mode no longer commits the ephemeral runtime journal to your repo.** Previously `/nazgul:init` only wrote a `.gitignore` block in `--local` mode, so the *default* shared mode tracked the entire `nazgul/` tree — every per-iteration checkpoint, log, session control file, and the write-only review reports landed in your project's git history and PRs (~95–110 files for a 10-task objective). Shared mode now gitignores the regenerable, machine-local journal (`checkpoints/`, `logs/`, `sessions/`, `.session_id`, `.compaction_count`, `archive/`, `reviews/*/test-failures.md`, `reviews/*/simplify-report.md`, `post-loop-simplify-report.md`) while keeping the **decision record** tracked (`config.json`, `plan.md`, `tasks/`, `reviews/` per-reviewer verdicts, `docs/`, `context/`, generated agents) so teammates can still resume the loop from a clone. Verified: recovery reads `plan.md` + task manifests, not checkpoint *content*, so ignoring checkpoints does not weaken cross-machine resume. `init` Step 2.5 now always runs with shared/local branches; `clean` removes either gitignore block.

### Fixed
- **`install_mode` was not durably persisted.** `migrate-config.sh` (`migrate_4_to_5`) deleted `install_mode` as an "unused" field, but `init` writes it and `clean`/the new shared-mode gitignore logic read it — so the flag was silently stripped on the first session-start migration. Re-legitimized as a first-class field: added to `templates/config.json`, schema bumped 6 → 7, and a new `migrate_6_to_7` restores it (`.install_mode // "shared"`, preserving an existing `"local"`).

### Migration
- Existing shared-mode projects that already committed the ephemeral paths: stop tracking them (files stay on disk) — `init` surfaces the one-shot, or run:
  `git rm -r --cached nazgul/{checkpoints,logs,sessions,archive,.session_id,.compaction_count}` (+ the two report files), then commit.

## [1.3.4] - 2026-06-16

### Fixed
- Subagent definitions `agents/discovery.md` and `agents/templates/reviewer-base.md` carried an `allowed-tools:` frontmatter line, which is a **skills** field and is silently ignored on subagents (the honored field is `tools:`, which both files also have). Net effect was a false sense of restriction — notably the reviewer's intended `Bash(npm test *)`-style scoping was never enforced. Removed the dead lines; reviewers keep `Bash` (needed for tests) and remain covered by the PreToolUse destructive-command guard. Verified against the official subagents frontmatter reference
- `CLAUDE.md` build rules listed `memory:` as a valid optional skill frontmatter field; it is **not** supported for skills (silently ignored) and no skill actually used it. Corrected the rule and enumerated the real optional fields (`argument-hint`, `arguments`, `disallowed-tools`, `model`, `paths`)

### Added
- `StopFailure` hook (`scripts/stop-failure.sh`): a turn ending on an API error previously left an AFK/autonomous loop silently stalled. Now records the failure to the iteration log, writes a `.stop_failure` recovery breadcrumb, runs the configured `notifications.on_failure`/`on_complete` command, and forwards a webhook event
- `SubagentStop` hook (`scripts/subagent-stop.sh`): lightweight observability — appends one line per finished subagent (with agent type when present) to `nazgul/logs/subagents.jsonl`
- `effort: high` on the `planner` and `debugger` agents (newly-supported subagent frontmatter field) to route the deepest-reasoning stages to higher reasoning effort
- `argument-hint` autocomplete hints on `init` (`[--local] [--force]`), `config` (`[models]`), and `start` — surfaces accepted flags as the user types, directly improving the discoverability gap behind the original `--local` bug
- `tests/test-observability-hooks.sh` — behavioral tests for the two new hook scripts (no-op without config, correct logging + breadcrumb with config, agent-name extraction)

### Notes
- Reviewed the plugin against current (June 2026) Claude Code docs. Confirmed already-correct and intentionally left unchanged: `PreCompact`/`PostCompact` + `SessionStart` source matching for compaction recovery, bare model aliases (`opus`/`sonnet`/`haiku` — they auto-track the latest snapshot; pinning full versioned IDs would freeze stale models), the hooks.json format, and the hand-rolled checkpoint/Recovery-Pointer system. `isolation: worktree` is a real new subagent field but was intentionally NOT adopted because Nazgul already manages worktrees manually (EnterWorktree/ExitWorktree); adding it would double-create worktrees

## [1.3.3] - 2026-06-16

### Fixed
- `/nazgul:init --local` silently behaved as shared mode: the `--local`/`--force` flags were buried inline in numbered-step prose, so the model unreliably acted on them — `.gitignore` got no `nazgul/` block, `install_mode` was never set to `local`, and the shared-mode CLAUDE.md section was appended anyway. `skills/init/SKILL.md` now carries an explicit `## Arguments` block (the convention other arg-taking skills follow); **Step 0 now parses + echoes the decision (`Parsed arguments: ... LOCAL_MODE = ... FORCE = ...`) before any branching** — including the idempotency/archive step, which now consumes the parsed `FORCE` instead of re-checking the raw token — with a backstop that halts if the `$ARGUMENTS` placeholder ever fails to substitute
- `/nazgul:config models` had the same latent defect: the `models` shortcut token was read from an inline `$ARGUMENTS` reference with no `## Arguments` block. Added the block and pointed the shortcut check at it
- `/nazgul:discover` referenced `$ARGUMENTS` inline under `## Instructions` with no dedicated block; gave it the standard `## Arguments` block
- Note: contrary to the original design spec's root-cause theory, Claude Code substitutes `$ARGUMENTS` wherever it appears in a skill body (and appends `ARGUMENTS:` when absent), so arguments always reached the model — the real defect was instruction reliability, not missing substitution. The `## Arguments` block is a clarity/consistency convention, and the forced echo in Step 0 is the actual robustness fix

### Added
- `tests/test-skill-arguments.sh` — regression test enforcing that every skill referencing `$ARGUMENTS` surfaces it in a **dedicated `## Arguments` block** (an `## Arguments` heading immediately followed by a bare `$ARGUMENTS` line), not merely a bare line buried anywhere in the body. Fails on pre-fix `main` (listing `init`, `config`), passes after the fix. Auto-discovered by `tests/run-tests.sh`

## [1.3.2] - 2026-06-04

### Fixed
- YOLO review-gate livelock from a verdict verb-form mismatch: reviewer agents write `## Verdict: APPROVE`, but `_has_approved_verdict` in `scripts/lib/review-evidence.sh` only matched the past participle `approved`, so every fully-reviewed file read as `UNAPPROVED` and the stop hook reset all tasks `DONE → IMPLEMENTED` every iteration (burning the full `--max` budget after a false `NAZGUL_COMPLETE`). The matcher now accepts `APPROVE`/`APPROVES`/`APPROVED` while keeping anchoring and a word boundary so `approval denied` and the `approved` substring in `UNAPPROVED` don't false-match
- Reviewer template (`agents/templates/reviewer-base.md`) now requires exactly one verbatim verdict line with the canonical token and explicitly forbids the imperative `APPROVE`, preventing recurrence

## [1.3.1] - 2026-06-04

### Fixed
- `/nazgul:start` now resets loop counters (`current_iteration`, `safety.consecutive_failures`, `safety._prev_done_count`) on every loop-starting path. Previously only the ACTIVE_LOOP/`--continue` resume paths reset `current_iteration` and nothing ever reset `consecutive_failures`, so starting a fresh objective (e.g. `/nazgul:start --yolo`) with stale counters at/over their caps silently bricked the loop — the Stop hook hit its max-iteration or consecutive-failure gate and exited 0 (allowed the stop) instead of re-dispatching, despite READY tasks
- Restored four README-linked docs (`docs/ARCHITECTURE.md`, `CONFIGURATION.md`, `SAFETY.md`, `PLUGINS.md`) deleted in the Hydra→Nazgul rebrand, rebranded and fact-checked against the current codebase — the README "Learn More" links no longer 404

## [1.3.0] - 2026-06-03

### Fixed
- YOLO loop livelock: tasks could never reach DONE when review verdicts were written to a consolidated `summary.md` instead of per-reviewer files — the state guard and stop hook silently fought every transition forever
- Stop hook review-gate resets are now diagnostic: the continue message and JSON reason name the exact missing/unapproved reviewers and the repair command (previously stderr-only, never surfaced)
- Evidence validation logic deduplicated into `scripts/lib/review-evidence.sh` — `task-state-guard.sh` and `stop-hook.sh` had already drifted (`simplify-report.md` exclusion differed)
- Review Gate agent now verifies every configured reviewer wrote its file before aggregating verdicts (Step 2.5), and re-reads task manifests from disk before emitting NAZGUL_COMPLETE
- `/nazgul:start` OBJECTIVE_COMPLETE state and Rule 10 require disk verification before any completion claim
- BLOCKED was a dead-end in the state guard's transition matrix — `BLOCKED → READY` (unblock) and `BLOCKED → IN_REVIEW` (materialize, review directory required) are now legal exits

### Added
- `/nazgul:review --materialize [TASK-ID | --all]` — repair command that re-runs the full reviewer board for tasks stuck without per-reviewer evidence, reconstructing `diff.patch` from manifest commit SHAs when missing
- Livelock breaker: a second consecutive review-gate reset for the same task escalates to BLOCKED with a remediation note instead of looping (reset counts in `config.json` `.safety._review_reset_counts`)
- `tests/test-review-evidence.sh` — unit tests for the shared validation library, including the summary.md-only regression case

## [1.2.2] - 2026-04-16

### Fixed
- `/nazgul:bootstrap-project` no longer asks "what are you building?" on brownfield projects — the codebase IS the spec, Discovery derives everything automatically
- `detect_project_type()` uses `-prune` instead of `! -path` filters, avoiding slow traversals into `node_modules/`, `vendor/`, etc.
- `--yes` flag now correctly aborts on greenfield projects with no objective instead of blocking on interactive prompts
- Skill frontmatter `metadata.version` synced to plugin version across all 21 SKILL.md files (was stuck at 1.0.0/1.1.0)

### Added
- `detect_project_type()` in `bootstrap-preflight.sh` — counts source files to classify brownfield (>= 5) vs greenfield
- Three-tier objective collection in bootstrap Phase 2: explicit argument > brownfield auto-derive > greenfield interactive
- 5 new test cases for `detect_project_type` (empty dir, below threshold, at threshold, excluded dirs pruned, config-only files)

## [1.2.1] - 2026-04-14

### Fixed
- Pre-load `AskUserQuestion` via `ToolSearch` in all interactive skills (was failing when the deferred tool hadn't been loaded yet)

## [1.2.0] - 2026-04-14

### Added
- Per-stage model routing — configure which AI model (Opus, Sonnet, Haiku) runs each pipeline stage
- New `/nazgul:config` skill — view and change settings (models, formatter, notifications) after init
- Model presets: Balanced (default), Quality, Fast/cheap
- Per-stage customization via interactive `AskUserQuestion` prompts
- Model configuration step in `/nazgul:init` Step 7
- Generated reviewer and specialist agents now include `model:` in frontmatter
- Unit tests for model routing config and skill wiring

### Changed
- Default model assignments updated to balanced preset (Opus for planning, Sonnet for implementation/review, Haiku for post-loop)

## [1.1.0] - 2026-04-14

### Added
- Interactive selectable prompts via `AskUserQuestion` across 6 skills (init, bootstrap-project, clean, reset, gen-spec, board)

## [1.0.0] - 2026-04-14

### Added
- Initial public release as Nazgul (renamed from Hydra)
- 17 core agents (discovery, planner, implementer, review-gate, and more)
- 20 skills (`/nazgul:init`, `/nazgul:start`, `/nazgul:status`, etc.)
- Review board with unanimous approval requirement
- Fix-first review (auto-fix mechanical issues, ask about risky changes)
- Recovery system (checkpoints, recovery pointers, session tracking)
- Agent Teams support for parallel task execution
- Bootstrap-project for portable Nazgul-free bundles
- `marketplace.json` for Orodruin Labs plugin marketplace distribution
- New logo assets (dark/light theme, transparent backgrounds)
- Modernized README install instructions (marketplace, direct install, manual clone)
- 24 unit/integration tests + E2E test suite
- CI pipelines (test, E2E, skill-docs freshness)
