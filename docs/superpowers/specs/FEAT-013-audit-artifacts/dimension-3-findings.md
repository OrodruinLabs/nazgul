# FEAT-013 Dimension 3 Findings — Claude-side guards & hooks

**Auditor task:** TASK-003 · **Scope:** `scripts/pre-tool-guard.sh`, `scripts/task-state-guard.sh`,
`scripts/prompt-guard.sh`, `scripts/parallel-dispatch-guard.sh`, `scripts/parallel-rework-guard.sh`,
`hooks/hooks.json`, `scripts/notify.sh`, `scripts/webhook-forward.sh`, `scripts/formatter.sh`, plus
RULES.md enforcement-tier claims for these guards. Read-only; no plugin source modified.

Coverage disclosure: primary scope files were read in full. Secondary scope (RULES.md) was
targeted-grepped for every guard named in primary scope, not read end-to-end. `notify.sh` and
`webhook-forward.sh` were audited at moderate depth (full read, findings limited to what stood out
on inspection — not exhaustively fuzzed). `parallel-dispatch-guard.sh` was read in full; no findings
recorded against it (see anchor root-cause note below — it appears sound). This is a single-pass
audit with no test execution beyond static reading; nothing here was dynamically verified by
actually running the guard scripts against crafted inputs.

---

## Findings Register

### F3-01 — CRITICAL — bug — Bash-mediated writes bypass the state machine entirely
**Evidence:** `hooks/hooks.json:52-97` (task-state-guard.sh is wired only on the
`Write|Edit|MultiEdit` PreToolUse matcher, never on `Bash`); `scripts/pre-tool-guard.sh:68-87`
(the Bash-side manifest-write funnel recognizes only `sed`, `cat`, `tee`, and `echo`/`printf`
redirects); `scripts/task-state-guard.sh:1-9` (sources no Bash-command parsing at all — it only
ever sees `tool_input.file_path`/`.content`/`.new_string`); `RULES.md:39` (`[enforced]` claim:
"Illegal status writes are blocked at the tool call level regardless of who drives the loop");
`RULES.md:142` ("Write/Edit-matched guards (structurally immune — no fix required)").

**Failure scenario:** Any command that writes a file without going through the Write/Edit/MultiEdit
tools — `mv /tmp/forged.md nazgul/tasks/TASK-003.md`, `cp`, `dd of=...`, `python3 -c
"open('nazgul/tasks/TASK-003.md','w').write(...)"`, `perl -i -pe`, `node -e
"require('fs').writeFileSync(...)"`, `ex`/`vi -c wq` — hits only `pre-tool-guard.sh`, whose
manifest-write pattern set (line 69-87) doesn't recognize any of `mv`/`cp`/`dd`/`python3`/`perl`/
`node`/`ex`, so it passes unblocked. It never reaches `task-state-guard.sh` at all, because that
guard only fires on Write/Edit/MultiEdit. The entire state-machine (§2 valid-transition table),
evidence gates (commit-SHA requirement, review-directory requirement), and review-gate check are
skipped completely. A forged manifest with `status: DONE` and a fabricated `## Commits` line can be
placed with a single `mv`/`cp`, silently wedging or falsifying the "sacred" state machine.
**RULES.md:142's framing ("structurally immune — no fix required") only addresses the
false-positive angle (no whole-command-substring brittleness) and is silent on this much larger
false-negative/bypass angle** — the same class the project already recognized and fixed for base-
branch protection by moving to a git-level hook (RULES.md:214, ADR-001).

**Recommendation:** Apply the same "layer that knows the truth" migration already validated for
branch protection: validate task-manifest status transitions where the write physically lands (a
`pre-commit`/`pre-merge-commit` git-level check, or a filesystem-level integrity check run by the
stop-hook itself before trusting any manifest's status), rather than trying to enumerate every
possible Bash write path. Short of that, broaden `pre-tool-guard.sh`'s funnel to block ANY Bash
write to `nazgul/tasks/TASK-*.md` regardless of which command performs it (deny-by-default any
redirect/known-write-command targeting that path, allow-list nothing but Write/Edit).

---

### F3-02 — CRITICAL — bug — prompt-guard.sh reads a non-existent env var; dead in production
**Evidence:** `scripts/prompt-guard.sh:16-22` (`USER_PROMPT="${CLAUDE_HOOK_USER_PROMPT:-}"` — the
script never touches stdin); `hooks/hooks.json:188-198` (UserPromptSubmit wiring is a bare command
invocation, identical shape to every other hook that reads its JSON payload from stdin);
`tests/test-prompt-guard.sh:19-23,88` (the only place `CLAUDE_HOOK_USER_PROMPT` is ever set — the
test harness itself, by manual `export`, not the product).

**Failure scenario:** Every sibling guard in this same `hooks.json` (`pre-tool-guard.sh`,
`task-state-guard.sh`, `local-mode-tracking-guard.sh`, `notify.sh`, `webhook-forward.sh`,
`formatter.sh`) reads its payload via `cat` from stdin, because that is how Claude Code delivers
hook input — a JSON envelope (for `UserPromptSubmit`, a `prompt` field) piped to the command's
stdin, not an environment variable. `prompt-guard.sh` is the sole exception. In production
`CLAUDE_HOOK_USER_PROMPT` is never set, so `USER_PROMPT` is always empty, `[ -z "$USER_PROMPT" ]`
is always true, and the script exits 0 (allow) unconditionally for every real prompt except when
`nazgul/config.json` is entirely absent. This means the two protections this guard exists for —
blocking a manually-typed `NAZGUL_COMPLETE` and blocking prompt text that tries to directly set a
task's status — are both silently inert. This is the exact "unrealistic-input test" class already
named as the dimension-7 anchor lesson (the pre-tool-guard raw-envelope incident), recurring here
in dimension 3's own guard and its own test suite.

**Recommendation:** Rewrite to read stdin JSON like every sibling guard: `INPUT=$(cat 2>/dev/null
|| echo ""); USER_PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')`. Then rewrite
`tests/test-prompt-guard.sh` to pipe realistic stdin JSON instead of exporting the env var, so a
future regression here fails the test suite instead of passing it vacuously.

---

### F3-03 — HIGH — bug — File Scope enforcement is permanently dead code (field-name mismatch)
**Evidence:** `scripts/task-state-guard.sh:204-239` (queries `get_task_field "$ACTIVE_TASK_FILE"
"File Scope" ""`); `scripts/lib/task-utils.sh:90-94` (`get_task_field` only matches a literal
`^\- \*\*<field>\*\*:` inline line); `agents/planner.md:107-121` (the planner's actual, only
output format for scope is a `## File Scope` heading with `**Creates**:`/`**Modifies**:` sub-lists,
plus a differently-named inline metadata field `- **Files modified**: [...]`); confirmed against
every live manifest — `nazgul/tasks/TASK-001.md:12,74-76` and all 10 sibling `TASK-*.md` files:
zero instances of a `- **File Scope**:` line anywhere in `nazgul/tasks/`. `RULES.md:195` claims
`[enforced]`: "Only files in the task's `file_scope`. `task-state-guard.sh` (PreToolUse on
Write/Edit) blocks edits outside declared scope."

**Failure scenario:** Because the field name the guard queries (`File Scope`) never appears in any
manifest the planner actually produces, `FILE_SCOPE` (task-state-guard.sh:208) is always empty, so
`if [ -n "$FILE_SCOPE" ]` (line 211) is always false, and the entire scope-restriction block
(lines 211-239) never executes for any task, ever. In practice an IN_PROGRESS task's implementer
can edit any file in the repository with zero mechanical scope restriction, contradicting the
`[enforced]` claim in RULES.md and CLAUDE.md's "Conditional agent roster" / task-scoping model.

**Recommendation:** Point the guard at the field the planner actually writes (`Files modified`),
and fix the parsing to handle its JSON-array-string form correctly (see F3-04 — a naive
comma-split is not sufficient). Add a regression test that exercises a real planner-shaped manifest
(not a hand-synthesized `- **File Scope**:` fixture) to catch this class of drift going forward.

---

### F3-04 — HIGH — bug — `Files modified` JSON-bracket value is never actually parsed, breaking two independent consumers
**Evidence:** `scripts/lib/task-utils.sh:90-94` (`get_task_field` returns the raw post-colon text
verbatim, including `[`, `]`, `"` — e.g. `["nazgul/context/objectives/FEAT-013/dimension-3-findings.md"]`);
`scripts/parallel-rework-guard.sh:56-66` (`_scope_has` splits on `,` and exact-string-compares each
token against the real path — every token still carries a stray leading `[`/`"` or trailing `"]`,
so it can never exact-match); `scripts/lib/parallel-batch.sh:289-303` (the parallel-dispatch
pairwise-disjoint-scope check — for a multi-file list only the first element keeps its `[` and the
last keeps its `]`, so a shared file that isn't the first element in either list produces two
non-identical lines and `sort | uniq -d` misses the real overlap). Live multi-item example:
`nazgul/tasks/TASK-010.md:12` — `["nazgul/context/objectives/FEAT-013/verification-verdicts.md",
"nazgul/context/objectives/FEAT-013/merged-findings.md"]`.

**Failure scenario:** (a) `parallel-rework-guard.sh`'s "a committed unit's file scope is never
re-worked" protection (its entire stated purpose per its own header comment) never fires, because
`OWNER` (line 70-77) can never be set — `_scope_has` never returns true against real manifests. (b)
`parallel-batch.sh`'s dispatch-time disjointness check, which is the core safety property that lets
`execution.parallel` mode dispatch multiple tasks concurrently without a race on shared files, can
silently miss a real overlap when the shared file is not the first element of either task's list —
letting two tasks that actually touch the same file get dispatched together. Fix F3-03 must not be
made without also fixing this, or the "corrected" File Scope guard would inherit the same parsing
bug.

**Recommendation:** Introduce one shared, correctly-parsing accessor (route through `jq -r '.[]'`
against the field's JSON value, or a helper that strips `[`, `]`, and `"` before the comma-split)
and have all three consumers (`task-state-guard.sh` post-fix, `parallel-rework-guard.sh`,
`parallel-batch.sh`) use it, so a parsing fix only has to happen once.

---

### F3-05 — HIGH — bug — commit-SHA evidence gate is a pattern match, not a verification
**Evidence:** `scripts/task-state-guard.sh:362-387` (the IN_PROGRESS→IMPLEMENTED gate: `if !
printf '%s' "$MANIFEST_TEXT" | grep -qE '[0-9a-f]{7,40}'`); `RULES.md:18` (`[enforced]` claim:
"Evidence gates block state transitions that would rely on unwritten state (IMPLEMENTED requires a
commit SHA in the manifest)"). No call to `git cat-file -e`, `git rev-parse --verify`, or `git log
--grep` exists anywhere in `task-state-guard.sh` or `scripts/lib/review-evidence.sh`.

**Failure scenario:** The gate blocks the *absence* of a hex-looking substring; it does nothing to
verify the *presence* of a real commit. A manifest edit containing `## Commits\n- deadbeef1 (typo,
not real)` — or even an unrelated 7+ character lowercase-hex token that happens to appear in prose
— satisfies the gate with no commit ever having been made. This is the same forged-evidence class
the project already found and fixed once, for review-manifest authenticity, via the
recompute-and-compare pattern (`_re_manifest_authentic` in `scripts/lib/review-evidence.sh`, per
RULES.md §3 item 11) — that fix was never ported to this earlier, more fundamental gate. Cross-links
dimension 1's named anchor ("evidence-gate integrity").

**Recommendation:** Verify the extracted SHA against the real repository before accepting it:
`git -C "$PROJECT_ROOT" cat-file -e "$sha^{commit}" 2>/dev/null`, consistent with the
recompute-and-compare precedent already established elsewhere in this same file.

---

### F3-06 — HIGH — false positive — `rm -rf` root/home patterns block any absolute-path deletion
**Evidence:** `scripts/pre-tool-guard.sh:43-46` — `check_pattern 'rm\s+-rf\s+/' "..."` has no
end-anchor, so it matches `rm -rf /` as a *substring* of any command containing `rm -rf
/<anything>`. `RULES.md:116` documents the intent narrowly: "`rm -rf /`, `rm -rf ~` --
filesystem destruction."

**Failure scenario:** `rm -rf /tmp/build-cache`, `rm -rf /Users/.../node_modules`, or any
legitimate AFK-mode cleanup of an absolute path is unconditionally blocked with the message
"Recursive delete of root filesystem" — a message that is actively misleading about what was
actually blocked. This is a real, high-friction false positive in exactly the AFK/YOLO unattended
mode where a spurious block has the highest cost (no human present to notice and override).

**Recommendation:** Anchor the root-only pattern precisely, e.g. `rm\s+-rf\s+/(\s|$|;|&|\|)` so it
matches bare `/` but not `/anything`; make the "block all absolute-path deletes" behavior (if
actually desired) an explicit, separately-documented policy rather than an accidental byproduct of
an unanchored regex. (`rm -rf ~` has the same unanchored shape and the same reasoning applies,
though blocking anything under `$HOME` is a more defensible conservative default than blocking
anything under `/`.)

---

### F3-07 — HIGH — bypass — force-push-to-main check is order-dependent
**Evidence:** `scripts/pre-tool-guard.sh:54-55` — `'git\s+push\s+.*--force.*\s+(main|master)'` and
`'git\s+push\s+-f\s+.*\s+(main|master)'` both require the force flag to appear *before* the branch
name in the command string. `RULES.md:114,118` claims this is unconditionally `[enforced]` ("All
hard blocks below are caught... regardless of mode or who drives the loop" / "`git push --force
main/master` -- shared branch destruction").

**Failure scenario:** `git push origin main --force` and `git push origin main -f` — both common,
idiomatic forms (flag trailing the refspec) — do not match either pattern, because `main` appears
before `--force`/`-f` in the string, not after. Neither is blocked. This directly contradicts the
"regardless of mode" guarantee RULES.md states for this exact protection.

**Recommendation:** Match the flag and the branch name independently within the same command
segment rather than requiring a fixed order — e.g. two boolean checks ANDed together: contains
`(^|[^[:alnum:]-])(--force|-f)([^[:alnum:]-]|$)` AND contains `\b(main|master)\b`, both scoped to a
`git push` invocation.

---

### F3-08 — MEDIUM — docs-drift — CLAUDE.md's directory map omits five live, wired hook scripts
**Evidence:** `CLAUDE.md:53-63` lists `pre-tool-guard.sh`, `task-state-guard.sh`,
`parallel-dispatch-guard.sh`, `parallel-rework-guard.sh`, `prompt-guard.sh`, `formatter.sh`,
`notify.sh`, `webhook-forward.sh`, `task-completed.sh` — but omits `local-mode-tracking-guard.sh`
(wired at `hooks/hooks.json:63`, runs on every Bash call), `lean-comments-guard.sh` (wired at
`hooks/hooks.json:78`, runs on every Write/Edit/MultiEdit), `stop-failure.sh` (wired at
`hooks/hooks.json:157-164`, `StopFailure`), `subagent-stop.sh` (wired at `hooks/hooks.json:169-174`,
`SubagentStop`), and `teammate-idle-guard.sh` (wired at `hooks/hooks.json:181-186`, `TeammateIdle`)
— all five are live, actively-enforcing scripts, not dead code. (RULES.md, by contrast, does
document `local-mode-tracking-guard.sh` and `lean-comments-guard.sh` in prose — the drift is
specific to CLAUDE.md's file-tree map, which is the document meant to orient a new contributor or
agent to the repo.)

**Failure scenario:** An agent or contributor reading CLAUDE.md's directory structure to understand
"what guards exist" undercounts the guard fleet by 5 scripts and may not realize `TeammateIdle`,
`StopFailure`, and `SubagentStop` are hooked at all.

**Recommendation:** Add the five missing scripts to CLAUDE.md's `scripts/` listing with one-line
descriptions, matching the existing entries' style.

---

### F3-09 — MEDIUM — fragility — formatter.sh's file-path extraction misses the standard field, falls back to a blind recursive string search
**Evidence:** `scripts/formatter.sh:72-78` — primary jq query is `.tool_result.file_path //
.file_path // .toolResult.file_path // .result.file_path`, none of which is
`.tool_input.file_path` — the field name every other guard in this fleet correctly uses for
Write/Edit payloads (`scripts/task-state-guard.sh:50`). The fallback (line 76) is `.. | strings |
select(test("^/.*\\.[a-zA-Z0-9]+$"))` — a recursive scan returning the first absolute-path-looking
string anywhere in the whole PostToolUse JSON payload.

**Failure scenario:** If the primary query never matches the real field name, formatter.sh depends
entirely on the recursive fallback returning the right value first. Since the payload also carries
`old_string`/`new_string`/tool-response content, any edited file whose diff itself contains an
absolute path with a file extension (e.g. editing a script that references `/tmp/foo.txt`) risks
the fallback picking up the wrong string before or instead of the actual edited file's path,
silently formatting nothing, formatting the wrong file, or emitting confusing debug output. Lower
severity than the other findings because `formatter.sh` is opt-in (`formatter.enabled` defaults
false) and non-blocking (PostToolUse, cosmetic).

**Recommendation:** Query `.tool_input.file_path` first (the consistent, documented field name
across this hook fleet), retain the recursive scan only as a last-resort fallback.

---

### F3-10 — LOW — fragility — notify.sh uses bare relative paths instead of `CLAUDE_PROJECT_DIR`
**Evidence:** `scripts/notify.sh:91,108,109,125` reference `nazgul/config.json` and
`nazgul/tasks/TASK-*.md` as bare relative paths (implicitly relative to whatever `pwd` is at hook
invocation time). Every sibling guard in this fleet explicitly resolves via
`PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"` first — `task-state-guard.sh:53`,
`local-mode-tracking-guard.sh:20`, `webhook-forward.sh:9`, `parallel-rework-guard.sh:14`,
`parallel-dispatch-guard.sh:15`.

**Failure scenario:** If the Stop hook's cwd ever diverges from the project root (the very hedge
every sibling script takes pains to guard against), `notify.sh`'s completion-detection (task-DONE
count, NAZGUL_COMPLETE transcript scan) silently finds nothing and never fires — a silent
degrade-to-no-notification with no error surfaced.

**Recommendation:** Standardize on `PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"` and resolve all
paths (`$PROJECT_ROOT/nazgul/...`) through it, matching the rest of the fleet.

---

### F3-11 — LOW — fragility — webhook-forward.sh's custom-header handling breaks on header values containing spaces
**Evidence:** `scripts/webhook-forward.sh:92-104` — `HEADER_ARGS` is built as newline-joined
`-H\n<key>: <value>` pairs and piped through `echo "$HEADER_ARGS" | xargs curl ...` (line 100).
`xargs` word-splits on all whitespace, not just the injected newlines.

**Failure scenario:** Any configured `webhooks.headers` value containing a space (a very ordinary
case — e.g. `Authorization: Bearer <token>`, or any human-readable header value) gets split into
multiple, wrong curl arguments, corrupting the outgoing request. Low severity: webhooks are opt-in
(`webhooks.enabled` default false) and best-effort (`|| true`, never fails the hook).

**Recommendation:** Build a bash array of header args natively (`HEADER_ARGS+=("-H" "$key: $value")`
in a loop) and pass it directly to `curl "${HEADER_ARGS[@]}"` instead of piping through `xargs`.

---

## Structural Critique

**Duplicated bespoke shell tokenizers (guard sprawl, narrow but real).**
`pre-tool-guard.sh:88-217` and `local-mode-tracking-guard.sh:78-204` each independently implement a
~120-line, hand-rolled awk quote-aware shell tokenizer (tracking single/double-quote state, redirect
operators, fd-numbered redirects, compound-command segment boundaries) solving structurally the same
problem — safely tokenizing an arbitrary Bash command string — with independently-evolved edge-case
coverage. This is exactly the kind of duplication that produces the false-positive/bypass history
named in this dimension's second anchor: every bespoke reimplementation is a fresh opportunity for
the same class of quoting/escaping bug to reappear, and a fix discovered in one (e.g. the
`ENVIRON`-vs-`-v` multiline lesson recorded elsewhere in this codebase) has no mechanical way to
propagate to the other. Recommendation: extract a single shared tokenizer (an awk library file both
scripts `source`/invoke, or a shared function) so a correctness fix is made once and both guards
inherit it.

**The command-string-parsing architecture has already been proven non-convergent once — and the
proof applies unchanged to task-manifest protection (see F3-01).**
RULES.md §5's own "FEAT-005 Guard Audit" section documents that Bash-matched, command-string
pattern-matching guards structurally "degrade to allow" for any command form not explicitly
enumerated, and RULES.md §10 records that this exact ceiling was hit and abandoned for base-branch
protection — replaced with a git-level `pre-commit` hook because the shell-expansion bypass surface
proved non-convergent (ADR-001). The task-manifest write-protection pair
(`pre-tool-guard.sh`/`task-state-guard.sh`) sits on the identical architecture and has the identical
ceiling (F3-01): the set of shell commands capable of writing a file is unbounded, so no amount of
pattern enumeration converges. This dimension's audit finds no evidence the git-level migration was
ever considered for this specific protection, even though the "layer that knows the truth" for "did
a task manifest's status change" is unambiguously the file's content on disk, not which command
wrote it — the same reasoning that motivated the branch-protection migration.

**Overall guard-count assessment.** The guard fleet itself (9 files audited, ~1,590 lines) is not
obviously overbuilt relative to what it's asked to enforce — most individual guards are narrowly
scoped and single-purpose. The problem this dimension surfaces is not "too many guards" but
"several load-bearing guards that silently do nothing" (F3-02, F3-03, F3-04-rework-half) or "claim
a stronger guarantee than they deliver" (F3-01, F3-05, F3-06, F3-07) — a correctness/honesty gap
between RULES.md's `[enforced]` claims and actual behavior, not a sprawl problem. No consolidation
or removal candidate stood out among files in this dimension's scope; the tokenizer-duplication item
above is the one concrete, narrow exception.

---

## Anchor Root-Cause Summary (mandatory per task manifest)

**Anchor 1 — "audit every remaining command-string-parsing guard against the proven 'enforce at
the layer that knows the truth' principle; which guards still tokenize command strings, and what
leaks?"**
Two guards in this dimension's scope still tokenize raw Bash command strings:
`pre-tool-guard.sh` and `local-mode-tracking-guard.sh`. `local-mode-tracking-guard.sh` was already
hardened in FEAT-005 (no-eval pathspec tokenizer, confirmed by direct read — no additional leak
found in this pass beyond the acknowledged "exotic shell forms... degrade to allow" scope
disclosed in its own header comment, which is an accepted, documented trade-off, not a silent gap).
`pre-tool-guard.sh` has NOT converged: it leaks on (a) the entire class of non-enumerated
write-commands against task manifests (F3-01), (b) order-dependence in the force-push check (F3-07),
and (c) an unanchored root/home pattern that over-blocks rather than under-blocks (F3-06, the
opposite failure mode but the same root cause — regex-substring matching standing in for real
command semantics). `task-state-guard.sh` and `parallel-rework-guard.sh` do NOT tokenize Bash
command strings (they read structured `tool_input` fields) and are correctly outside this anchor's
scope per RULES.md:142's own claim — but `task-state-guard.sh`'s narrow Write/Edit-only matcher is
precisely what makes F3-01's Bash-side bypass total once `pre-tool-guard.sh`'s pattern set is
evaded, so the two facts (guard 1 leaks, guard 2 never even sees the bypassing command) compound
into the dimension's most severe finding. **Cleared:** `local-mode-tracking-guard.sh`.
**Not cleared, root-caused:** `pre-tool-guard.sh` (F3-01, F3-06, F3-07).

**Anchor 2 — false-positive history (local-mode tracking guard message-grep block, base-branch-guard
cwd bug, task-state-guard awk multiline crash — are the fixed classes truly closed, and do sibling
guards repeat the same tokenizer mistakes?)**
`local-mode-tracking-guard.sh`'s originally-reported message-grep false positive (a commit message
merely *mentioning* `nazgul/` being misread as a tracked pathspec) is CLEARED: the current
implementation (lines 78-204) tokenizes actual positional pathspecs via a quote-aware awk state
machine, correctly distinguishing `-m "message with nazgul/ in it"` from a real `git add nazgul/x`
— confirmed by direct read, matching the FEAT-005 audit note in RULES.md:140. The base-branch-guard
cwd bug and task-state-guard awk multiline crash are outside this dimension's file scope (git-level
hook and a historical fix already merged, respectively — not re-verified here). However, this audit
pass found a **new, previously-unrecorded instance of the same tokenizer-mistake pattern**: F3-06
(`rm -rf` pattern over-matches — an unanchored-regex mistake, the same *family* of bug as the
original message-grep false positive, just in a different guard) and F3-07 (force-push order
dependence — a different manifestation of "matching on text shape instead of real structure"). So
the answer to "do sibling guards repeat the same tokenizer mistakes" is **yes** — not literally the
same fixed bug recurring, but the same underlying failure mode (regex-substring standing in for
real parsing) recurring in a guard (`pre-tool-guard.sh`'s hard-block patterns) that was never in
scope for the FEAT-005 remediation because that remediation targeted only the manifest-write rule
within the same file, not its unrelated destructive-command patterns.
