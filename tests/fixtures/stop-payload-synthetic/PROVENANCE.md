# stop-payload-synthetic fixture provenance

tier: synthetic
consumer: the Stop-payload classification arms of `scripts/stop-hook.sh`, via `tests/test-in-flight-hold.sh` (FEAT-033 TASK-004/TASK-005/TASK-007)
reason: two of these three payloads describe states that have **never been observed** — `LIVE == 0`, `SUBAGENT_PRESENT == 0`, and any entry status other than `running` — so no captured fixture for them can exist at any tier; the third transcribes a real capture's counts but not its content, because that capture is another project's session

## Why every file here is hand-authored

The captured half of this evidence lives one directory over, in `../stop-payload/`. What is here
is what capture could not supply, for two different reasons that must not be confused:

| File | Why it is synthetic |
|---|---|
| `mixed-subagent-and-shell.json` | A real capture of this shape exists, and it is **unusable as a fixture**: it is a different project's session and carries that project's absolute paths, worktree names, and command strings. RULES §15 R3 forbids third-party subject matter in a fixture at any tier, so the *counts* were transcribed and everything else was written from scratch. |
| `background-tasks-empty.json` | **Never observed.** Every capture taken shows a non-empty array. |
| `unknown-status-queued.json` | **Never observed.** Every entry in every capture carries `"status": "running"`. |

The second and third rows are the important ones. A synthetic fixture for a state that has merely
not been captured *yet* is a stand-in; a synthetic fixture for a state nobody has ever seen is a
**hypothesis**, and the code it drives must be written to survive being wrong about it. That is
exactly why ADR-027 Q3 makes the empty-array arm detect-only — it emits
`in_flight_orphan_candidate` and leaves the marker in place rather than taking an irreversible
`mv` against a state whose existence is still unproven. Nothing here may be cited as evidence that
these payloads occur.

## `mixed-subagent-and-shell.json` — the type filter's necessity, at scale

**16 entries: 6 `subagent`, 10 `shell`**, all running. That count structure — and only that count
structure — is transcribed from a real `SubagentStop` capture taken during the FEAT-033 probe
(`nazgul/context/218-probe-results.md`); every id, description, command, and envelope field here
was written for this fixture.

It is the strongest argument for `select(.type == "subagent")` being load-bearing rather than
defensive: the other ten entries were `until …; do sleep …; done` waiters, which are polling
shells that no dispatch will ever complete. Counted unfiltered, that session's loop would have
held **forever** on its own waiters. Against this fixture the two ADR-027 Q2 counts are
`LIVE = 6` and `SUBAGENT_PRESENT = 6`, out of `entries = 16`.

The envelope follows the `Stop` key set captured in `../stop-payload/`, not the `SubagentStop` key
set of the session the counts came from: the consumer is the `Stop` hook, and inventing a
`SubagentStop` envelope would have been a second hypothesis smuggled in beside the counts.

## `background-tasks-empty.json` — the detect-only arm

`background_tasks` present and **empty**. `LIVE = 0`, `SUBAGENT_PRESENT = 0`, `entries = 0`. This
is the sole input that reaches the `in_flight_orphan_candidate` arm, and the premise it encodes —
that a finished subagent has actually left the registry by the next `Stop` — is *unverified*. If
the arm never fires in production, that premise is refuted and the follow-up `mv` must never ship
(ADR-027, open falsifier 1).

## `unknown-status-queued.json` — the third state

One `subagent` entry with `"status": "queued"`, plus one running `shell`. It exists to pin the
one behaviour the two-count predicate was designed for: a status the allowlist does not recognise
must produce **neither a hold nor a candidate**.

- `LIVE = 0` — `queued` is not `running` or `pending`, so the hold arm does not fire.
- `SUBAGENT_PRESENT = 1` — so the empty-array arm does not fire either.

Under a single-filter design this payload would have landed on the quarantine arm and taken an
irreversible `mv` against the marker of a subagent that is about to start running. `queued` is
invented; the *possibility* of an unrecognised status is not, which is the whole point of not
collapsing "present but not recognisable as live" into either neighbour.

The running `shell` entry is deliberate: it makes the payload discriminating. A reader that
counted in-flight entries without the type filter would see one running thing and hold.

## Form pins

None, and none are possible. A `pin:` line recomputes a captured producer's output against disk;
these files have no producer to drift from. `tests/test-repo-content-boundary.sh` R2 checks the
`tier`/`consumer`/`reason` fields for this tier and evaluates no pins — the authority for these
files is the consuming test's assertions, not a form pin.

## Boundary check

No string from the third-party capture appears here or anywhere under `tests/`. The absolute paths
used are `/Users/dev/…`, an allowlisted placeholder name in `tests/test-repo-content-boundary.sh`
R1, and the invented shell commands reference `/tmp/example/…` only.
