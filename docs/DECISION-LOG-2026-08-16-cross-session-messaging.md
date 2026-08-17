# Decision Log — Cross-Session Messaging Adoption (2026-08-16)

Design: `docs/superpowers/specs/2026-08-16-cross-session-messaging-adoption-design.md`.
Evidence: `docs/superpowers/specs/2026-08-16-cross-session-messaging-platform-facts.md` (V1–V10, P1–P6).

## D-001 — Doctrine: messaging is an operator surface and an attack surface, never a loop mechanism

Cross-session messaging (Claude Code ≥2.1.224) is adopted for operator HITL steering (native,
documented, zero Nazgul code), peer-courtesy FYI (already permitted by RULES §17), inbound
hardening, and observability corroboration. It is NOT adopted as a wake, transport, or gate input
for the loop. Adopted rule (RULES §22): **an unguaranteed channel may shorten a wait, but may
never authorize one.** Delivery is documented as not guaranteed (delivered/held/refused; refusal
produces no sender notice; throttling opaque; four unrelated settings changes silently
reconfigure the transport).

## D-002 — The doorbell was proven to WORK, and cut anyway

P2/P5 measured the full cycle: a socket post to an idle session starts a turn; that turn's Stop
hook fires, can return decision:block, and the harness honors it — the engine genuinely re-enters.
It was cut on four independently sufficient grounds: (1) the canonical unattended shape
(heartbeat's `claude -p`) has no idle state — the hold's exit 0 is process exit; (2) redundant
where it works (background dispatches already have the documented harness resume) and impossible
where it is needed (the foreground-leak case's trigger event has already fired); (3) unbounded
silent failure (checked-in project `refuse`, invisible managed settings, measured indefinite `nc`
hang inside a 10s hook budget, measured `nc -w 1` false-success); (4) the 2026-07-21 log's D-002
items 3 and 4 already rejected this shape. The record must show this was a reliability-semantics
judgment, not a capability gap.

## D-003 — #104 Gap 3's fix is per-marker classification, not a hold inversion

"Confirmed wake path" is a per-dispatch property decidable at marker-write time *when the class
is observable at all*: background dispatches have the documented harness resume; a foreground
marker present at Stop time is a proven leak (a synchronous call cannot span a Stop). Hold only
`background=="true"` unnamed markers; quarantine the rest and continue normally.

**Amended 2026-08-17 (round-2 board finding F-E).** The sentence above was written as if the
tri-state had only two reachable values. It has three, and on a fork-mode host — the interactive
default since Claude Code v2.1.232 — `"missing"` is the ONLY one ever recorded, because
`run_in_background` is omitted from the exposed Agent schema there. So the hold branch never
engages on that host class, and every marker it quarantines belongs to a healthy background
dispatch. Two consequences for this decision as recorded:

1. `"missing"` is NOT a proven leak, and is no longer reported as one. `in_flight_orphan` is now
   reserved for a PROVEN class (`background:"false"`, or a named dispatch whose report contract
   owns the marker); the unobservable case emits `stop_gate reason:"in_flight_unverifiable"`.
   #205's `dispatch_guard_background_unverifiable` had already decided this exact question the
   same way for the same field one task earlier; RULES §15/ADR-009 forbids inheriting that answer
   by proximity, so the weighing is restated rather than copied — we continue (a false hold stalls
   the run with no wake path this code reads) without claiming a leak we did not observe.
2. The cost of a false continue was understated in the original weighing as "one iteration". The
   branch `mv`s the marker to `nazgul/in-flight/quarantine/`, so the hold can never be
   reconsidered for that dispatch. The action is irreversible, not merely retried.

The decision itself — classification rather than hold inversion — stands; what was wrong was
treating an unobservable class as a decided one. Making the class OBSERVABLE (reading
`tool_response.status` at `PostToolUse`, or `background_tasks[]` on the Stop payload, instead of
predicting from `run_in_background` at dispatch time) is the real repair and is deliberately out of
this objective's scope — issue #218. The rejected
alternative (block-and-burn unless a session-global wake flag) was quantified: it force-stops a
legitimate hour-long background dispatch in ≤5 burned iterations, unrecoverably, and does not
clear the leaked marker that caused the incident.

## D-004 — Session locks are session-lifetime

`stop-hook.sh`'s EXIT trap unregistered the lock on every allowed stop, so §13's "never a second
loop" guard was vacuous outside a mid-loop turn (0 locks beside 4 live sessions, measured).
Locks now: registered at SessionStart, refreshed per Stop, released at SessionEnd, swept by pid
liveness — and carry cwd/toplevel/branch so a shared-tree collision (#195) is detectable.

## D-005 — Amendment to the 2026-07-21 log's closing rule (by pointer, not edit)

The 07-21 closing rule ("do not reintroduce a background-subagent driver unless the platform
documents parent re-engagement on child completion") stands unmodified for its subject. This log
adds the adjacent rule it never reached, now in RULES §22: no mechanism may be the sole means by
which a session obtains a turn unless the platform guarantees its delivery — `decision:"block"`
on Stop qualifies; the inbox socket does not. D-002 item 3 of the 07-21 log ("no session
resumption for a teammate that stalls") is retired for the OWN-SESSION case by P2/P5 and intact
for teammates; D-002 item 4 (watchdog re-poke) is reaffirmed — the doorbell was that shape.
Probes owed before any future revisit: harness resume for a `run_in_background:true` dispatch on
a background-capable host; whether UserPromptSubmit payloads distinguish peer-origin turns.
